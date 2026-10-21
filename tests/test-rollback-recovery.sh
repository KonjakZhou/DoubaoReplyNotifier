#!/bin/bash
# Dynamic rollback-recovery tests. Everything runs inside a sandbox HOME and
# APPS_DIR; the real gui domain, real ~/Applications and real /Applications are
# never touched. Control-plane launchctl calls go through a shim; the F case
# proves actual process recovery with a compiled harmless stand-in that writes
# its OWN health snapshot (recovery never writes/fakes health).
#
# Run: DOUBAO_TEST_PREBUILT=/path/to/Doubao\ Reply\ Notifier.app bash tests/test-rollback-recovery.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREBUILT="${DOUBAO_TEST_PREBUILT:-$ROOT/Doubao Reply Notifier.app}"
[[ -d "$PREBUILT" ]] || { echo "需要预构建 $PREBUILT（用 DOUBAO_TEST_PREBUILT 指定 4.7.4/18 App）" >&2; exit 1; }

# Prebuilt must match the pinned version, otherwise an early version-check die
# would masquerade as a rollback success. Fail loudly instead of a false pass.
PV="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$PREBUILT/Contents/Info.plist" 2>/dev/null || true)"
PB="$(/usr/bin/plutil -extract CFBundleVersion raw "$PREBUILT/Contents/Info.plist" 2>/dev/null || true)"
EXPECTED_VERSION="$(/usr/bin/python3 -c 'import re,sys; print(re.search(r"VERSION=\"([^\"]+)\"",open(sys.argv[1]).read())[1])' "$ROOT/install.sh")"
EXPECTED_BUILD="$(/usr/bin/python3 -c 'import re,sys; print(re.search(r"BUILD=\"([^\"]+)\"",open(sys.argv[1]).read())[1])' "$ROOT/install.sh")"
[[ "$PV" == "$EXPECTED_VERSION" && "$PB" == "$EXPECTED_BUILD" ]] \
  || { echo "预构建与安装器版本不匹配：$PV ($PB)" >&2; exit 1; }

FAILURES=0
BUNDLE_ID="com.local.doubao-reply-notifier"
AGENT_LABEL="com.local.doubao-reply-notifier.agent"
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES+1)); }
pass() { echo "ok: $*"; }
# Assert the injected installer actually reached the simulated failure (so an
# early version/codesign death cannot look like a rollback).
reached_injection() { grep -q "SIMULATED_FAILURE" "$1" || fail "installer died before injected failure point: $(tail -3 "$1" 2>/dev/null)"; }

SANDBOX="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/rollback-recovery.XXXXXX")"
trap '/bin/rm -rf "$SANDBOX"' EXIT
SANDBOX_HOME="$SANDBOX/home"
SANDBOX_APPS="$SANDBOX/Applications"
/bin/mkdir -p "$SANDBOX_HOME/Applications" "$SANDBOX_APPS" \
  "$SANDBOX_HOME/Library/LaunchAgents" \
  "$SANDBOX_HOME/Library/Application Support/DoubaoReplyNotifier"

STATE_FILE="$SANDBOX_HOME/Library/Application Support/DoubaoReplyNotifier/state.json"
echo '{"marker":"PREINSTALL_STATE","pendingInteractions":{}}' > "$STATE_FILE"

# Global shim launchctl: records every invocation to SHIM_LOG, honors SHIM_RC.
SHIM="$SANDBOX/shim"; mkdir -p "$SHIM"
SHIM_LOG="$SANDBOX/launchctl.log"
cat > "$SHIM/launchctl" <<EOF
#!/bin/bash
echo "\$@" >> "$SHIM_LOG"
exit "\${SHIM_RC:-0}"
EOF
chmod +x "$SHIM/launchctl"

# Injected installer copy next to a local prebuilt. $1 = marker line after which
# `die "SIMULATED_FAILURE"` is injected.
make_injected() {
  local marker="$1"
  local inj="$SANDBOX/inj-$marker"
  # Clear any reused marker dir (B and C share SWAP_COMMITTED=1) so cp -R does
  # not merge leftovers from a prior injected copy.
  /bin/rm -rf "$inj"
  mkdir -p "$inj"
  /bin/cp -R "$PREBUILT" "$inj/Doubao Reply Notifier.app"
  # Re-sign the injected copy so a sandbox cp/xattr quirk cannot produce an
  # "unsealed bundle root" at staging; this is test-only, the shipped app is
  # already sealed and untouched here.
  /usr/bin/codesign --force --deep --sign - "$inj/Doubao Reply Notifier.app"
  # Installer resolves scripts/manage-service.sh from its own dir; copy it so
  # $ROOT/scripts exists in the injected copy.
  /bin/cp -R "$ROOT/scripts" "$inj/scripts"
  # Match by substring so indented assignments (e.g. "  NEW_SERVICE_STARTED=1")
  # still match; inject die immediately after the matched line.
  /usr/bin/awk -v m="$marker" 'index($0,m){print; print "die \"SIMULATED_FAILURE\""; next} {print}' \
    "$ROOT/install.sh" > "$inj/install.sh"
  chmod +x "$inj/install.sh"
  echo "$inj"
}

LEGACY="$SANDBOX_HOME/Applications/Doubao Reply Notifier.app"
TARGET="$SANDBOX_APPS/Doubao Reply Notifier.app"
PLIST="$SANDBOX_HOME/Library/LaunchAgents/com.local.doubao-reply-notifier.agent.plist"

seed_legacy() {
  /bin/cp -R "$PREBUILT" "$LEGACY"
  /usr/bin/plutil -create xml1 "$PLIST"
  /usr/bin/plutil -insert Label -string "$AGENT_LABEL" "$PLIST"
  /usr/bin/plutil -insert ProgramArguments -json '[]' "$PLIST"
  /usr/bin/plutil -insert ProgramArguments.0 -string "$LEGACY/Contents/MacOS/DoubaoReplyNotifier" "$PLIST"
}

reset_sandbox() {
  /bin/rm -rf "$LEGACY" "$TARGET" "$PLIST"
  echo '{"marker":"PREINSTALL_STATE","pendingInteractions":{}}' > "$STATE_FILE"
}

echo "=== A. post-plist failure: legacy app+config+state restored, target gone ==="
reset_sandbox; seed_legacy
INJ="$(make_injected 'PLIST_OVERWRITTEN=1')"
HOME="$SANDBOX_HOME" DOUBAO_NOTIFIER_APPS_DIR="$SANDBOX_APPS" DOUBAO_NOTIFIER_SKIP_LAUNCH=1 \
  /bin/bash "$INJ/install.sh" >"$SANDBOX/runA.log" 2>&1 || true
reached_injection "$SANDBOX/runA.log"
[[ ! -d "$TARGET" ]] && pass "new target removed after failure" || fail "new target left behind"
[[ -d "$LEGACY" ]] && pass "legacy app preserved" || fail "legacy app lost"
PG="$(/usr/bin/plutil -extract ProgramArguments.0 raw "$PLIST" 2>/dev/null || true)"
[[ "$PG" == "$LEGACY/Contents/MacOS/DoubaoReplyNotifier" ]] && pass "plist rolled back to legacy path" || fail "plist not rolled back: $PG"
grep -q PREINSTALL_STATE "$STATE_FILE" && pass "state file preserved" || fail "state file altered"

echo "=== B0. target not writable (zero copy, not partial): legacy+state kept ==="
reset_sandbox; seed_legacy
chmod 555 "$SANDBOX_APPS"
INJ="$(make_injected 'SWAP_COMMITTED=1')"
HOME="$SANDBOX_HOME" DOUBAO_NOTIFIER_APPS_DIR="$SANDBOX_APPS" DOUBAO_NOTIFIER_SKIP_LAUNCH=1 \
  /bin/bash "$INJ/install.sh" >"$SANDBOX/runB.log" 2>&1 || true
chmod 755 "$SANDBOX_APPS"
grep -Eq "(复制到目标位置失败|目标目录不可写)" "$SANDBOX/runB.log" || fail "cp did not fail as expected: $(tail -3 "$SANDBOX/runB.log")"
[[ ! -e "$TARGET" ]] && pass "zero-copy: nothing written to target" || fail "unexpected target"
[[ -d "$LEGACY" ]] && pass "legacy app preserved" || fail "legacy lost"
grep -q PREINSTALL_STATE "$STATE_FILE" && pass "state preserved" || fail "state altered"

echo "=== B2. fault-injected partial cp: wrote part then failed; partial cleaned ==="
reset_sandbox; seed_legacy
INJ="$(make_injected 'SWAP_COMMITTED=1')"
# Replace the real cp with a fault shim that writes a partial bundle then fails,
# proving TARGET_CREATION_ARMED removes the partial target on cleanup.
/usr/bin/sed 's#/bin/cp -R "$STAGED_APP" "$APP"#"$FAULT_CP"#g' "$INJ/install.sh" > "$INJ/install.sh.tmp" && mv "$INJ/install.sh.tmp" "$INJ/install.sh"
mkdir -p "$SANDBOX/faultbin"
cat > "$SANDBOX/faultbin/cp" <<'EOF'
#!/bin/bash
# $1=staged, $2=target; write a partial copy then fail.
/bin/mkdir -p "$2/Contents/MacOS"
/bin/cp -R "$1/Contents/MacOS" "$2/Contents/MacOS/" 2>/dev/null || true
exit 1
EOF
chmod +x "$SANDBOX/faultbin/cp"
HOME="$SANDBOX_HOME" DOUBAO_NOTIFIER_APPS_DIR="$SANDBOX_APPS" DOUBAO_NOTIFIER_SKIP_LAUNCH=1 \
FAULT_CP="$SANDBOX/faultbin/cp" PATH="$SANDBOX/faultbin:/usr/bin:/bin" \
  /bin/bash "$INJ/install.sh" >"$SANDBOX/runB2.log" 2>&1 || true
grep -q "复制到目标位置失败" "$SANDBOX/runB2.log" || fail "fault cp did not fail: $(tail -3 "$SANDBOX/runB2.log")"
[[ ! -e "$TARGET" ]] && pass "partial target removed after fault failure" || fail "partial target remains"
[[ -d "$LEGACY" ]] && pass "legacy app preserved on partial cp failure" || fail "legacy lost"
grep -q PREINSTALL_STATE "$STATE_FILE" && pass "state preserved on partial cp failure" || fail "state altered"

echo "=== P. plist write failure (before overwrite): old plist untouched, target cleaned ==="
reset_sandbox; seed_legacy
INJ="$(make_injected 'chmod 600 "$TMP_PLIST"')"
HOME="$SANDBOX_HOME" DOUBAO_NOTIFIER_APPS_DIR="$SANDBOX_APPS" DOUBAO_NOTIFIER_SKIP_LAUNCH=1 \
  /bin/bash "$INJ/install.sh" >"$SANDBOX/runP.log" 2>&1 || true
reached_injection "$SANDBOX/runP.log"
# Old plist must still point at legacy (never overwritten).
PG="$(/usr/bin/plutil -extract ProgramArguments.0 raw "$PLIST" 2>/dev/null || true)"
[[ "$PG" == "$LEGACY/Contents/MacOS/DoubaoReplyNotifier" ]] && pass "old plist untouched on write failure" || fail "plist altered: $PG"
[[ ! -d "$TARGET" ]] && pass "swapped target cleaned after plist write failure" || fail "target left behind"
grep -q PREINSTALL_STATE "$STATE_FILE" && pass "state preserved" || fail "state altered"

echo "=== C. upgrade existing target: failure restores old target + plist + state ==="
reset_sandbox
/bin/cp -R "$PREBUILT" "$TARGET"
/usr/bin/plutil -create xml1 "$PLIST"
/usr/bin/plutil -insert Label -string "$AGENT_LABEL" "$PLIST"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$PLIST"
/usr/bin/plutil -insert ProgramArguments.0 -string "$TARGET/Contents/MacOS/DoubaoReplyNotifier" "$PLIST"
OLD_MARK="OLD_TARGET_TOKEN_$$"
echo "$OLD_MARK" > "$TARGET/Contents/Resources/marker.txt"
INJ="$(make_injected 'SWAP_COMMITTED=1')"
HOME="$SANDBOX_HOME" DOUBAO_NOTIFIER_APPS_DIR="$SANDBOX_APPS" DOUBAO_NOTIFIER_SKIP_LAUNCH=1 \
  /bin/bash "$INJ/install.sh" >"$SANDBOX/runC.log" 2>&1 || true
reached_injection "$SANDBOX/runC.log"
[[ -f "$TARGET/Contents/Resources/marker.txt" && "$(cat "$TARGET/Contents/Resources/marker.txt")" == "$OLD_MARK" ]] \
  && pass "old target file restored" || fail "old target not restored"
PG="$(/usr/bin/plutil -extract ProgramArguments.0 raw "$PLIST" 2>/dev/null || true)"
[[ "$PG" == "$TARGET/Contents/MacOS/DoubaoReplyNotifier" ]] && pass "old plist restored" || fail "plist altered: $PG"
grep -q PREINSTALL_STATE "$STATE_FILE" && pass "state preserved on upgrade failure" || fail "state altered"

echo "=== E. health/start failure: reclaim new service, restore old app/plist/state (control plane) ==="
reset_sandbox; seed_legacy
# Remove execute bit on the legacy binary so recovery never execs the real
# product inside the sandbox; control-plane calls are observed via the shim.
/bin/chmod -x "$LEGACY/Contents/MacOS/DoubaoReplyNotifier" 2>/dev/null || true
: > "$SHIM_LOG"; unset SHIM_RC
INJ="$(make_injected 'NEW_SERVICE_STARTED=1')"
HOME="$SANDBOX_HOME" \
DOUBAO_NOTIFIER_APPS_DIR="$SANDBOX_APPS" \
DOUBAO_NOTIFIER_SKIP_LAUNCH=0 \
DOUBAO_LAUNCHCTL="$SHIM/launchctl" \
  /bin/bash "$INJ/install.sh" >"$SANDBOX/runE.log" 2>&1 || true
reached_injection "$SANDBOX/runE.log"
[[ -s "$SHIM_LOG" ]] || fail "shim launchctl log empty: LAUNCHCTL override did not reach installer"
grep -q "bootout gui/$(/usr/bin/id -u)/$AGENT_LABEL" "$SHIM_LOG" \
  && pass "failed new service booted out" || fail "new service not reclaimed: $(cat "$SHIM_LOG")"
grep -q "bootstrap gui/$(/usr/bin/id -u) $PLIST" "$SHIM_LOG" \
  && pass "old recovery bootstrap attempted after rollback" || fail "old recovery not attempted: $(cat "$SHIM_LOG")"
[[ ! -d "$TARGET" ]] && pass "failed new target removed" || fail "failed target left behind"
[[ -d "$LEGACY" ]] && pass "legacy app restored" || fail "legacy app lost"
PG="$(/usr/bin/plutil -extract ProgramArguments.0 raw "$PLIST" 2>/dev/null || true)"
[[ "$PG" == "$LEGACY/Contents/MacOS/DoubaoReplyNotifier" ]] && pass "legacy plist restored" || fail "plist not restored: $PG"
grep -q PREINSTALL_STATE "$STATE_FILE" && pass "state preserved on health failure" || fail "state altered"

echo "=== D. recovery unit: mock bootstrap called; unready/failure warns honestly ==="
: > "$SHIM_LOG"; unset SHIM_RC
(
  export HOME="$SANDBOX_HOME" DOUBAO_NOTIFIER_SKIP_LAUNCH=0 LAUNCHCTL="$SHIM/launchctl" PATH="/usr/bin:/bin"
  export BUNDLE_ID="$BUNDLE_ID" AGENT_LABEL="$AGENT_LABEL"
  export APP_NAME="Doubao Reply Notifier.app" BIN_NAME="DoubaoReplyNotifier"
  export APP="/$SANDBOX_APPS/fake.app" LEGACY_APP="$LEGACY"
  export AGENTS_DIR="$SANDBOX_HOME/Library/LaunchAgents" LEGACY_PLIST="$PLIST" OLD_APP_BACKUP=""
  export STATE_DIR="$SANDBOX_HOME/Library/Application Support/DoubaoReplyNotifier"
  /usr/bin/sed -n '/^recover_bundle_identity_ok()/,/^}/p; /^recover_old_service()/,/^}/p' "$ROOT/install.sh" > "$SANDBOX/recover.func"
  source "$SANDBOX/recover.func"
  recover_old_service || true
)
grep -q "bootstrap gui/$(/usr/bin/id -u) $PLIST" "$SHIM_LOG" \
  && pass "recovery bootstraps restored plist" || fail "bootstrap not called: $(cat "$SHIM_LOG")"

# Negative: shim returns 1 and no health -> honest unready warning, no crash.
: > "$SHIM_LOG"; export SHIM_RC=1
WARN="$SANDBOX/warn.txt"
(
  export HOME="$SANDBOX_HOME" DOUBAO_NOTIFIER_SKIP_LAUNCH=0 LAUNCHCTL="$SHIM/launchctl" PATH="/usr/bin:/bin"
  export BUNDLE_ID="$BUNDLE_ID" AGENT_LABEL="$AGENT_LABEL"
  export APP_NAME="Doubao Reply Notifier.app" BIN_NAME="DoubaoReplyNotifier"
  export APP="/$SANDBOX_APPS/fake.app" LEGACY_APP="$LEGACY"
  export AGENTS_DIR="$SANDBOX_HOME/Library/LaunchAgents" LEGACY_PLIST="$PLIST" OLD_APP_BACKUP=""
  export STATE_DIR="$SANDBOX_HOME/Library/Application Support/DoubaoReplyNotifier"
  /usr/bin/sed -n '/^recover_bundle_identity_ok()/,/^}/p; /^recover_old_service()/,/^}/p' "$ROOT/install.sh" > "$SANDBOX/recover.func"
  source "$SANDBOX/recover.func"
  recover_old_service 2>"$WARN" || true
)
grep -q "未能恢复就绪" "$WARN" && pass "failure/unready honestly reported" || fail "warning missing: $(cat "$WARN")"

echo "=== F. real process recovery: compiled stand-in writes own health, live PID==health PID ==="
# Compiled harmless stand-in (no official-product reads) proves actual process
# recovery; it writes its OWN runtime-health.json and pauses. Recovery only
# verifies, never writes health.
STANDIN="$SANDBOX/standin.app"
mkdir -p "$STANDIN/Contents/MacOS" "$STANDIN/Contents/Resources"
STANDIN_STATE="$SANDBOX/state"
mkdir -p "$STANDIN_STATE"
cat > "$SANDBOX/standin.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(void){
  const char* p = getenv("HEALTH_PATH");
  FILE* f = fopen(p, "w");
  if (f) { fprintf(f, "{\"pid\":%d,\"ready\":true,\"version\":\"4.7.4\",\"build\":\"18\"}\n", getpid()); fclose(f); }
  pause();
  return 0;
}
EOF
/usr/bin/cc -O2 -o "$STANDIN/Contents/MacOS/DoubaoReplyNotifier" "$SANDBOX/standin.c"
/usr/bin/plutil -create xml1 "$STANDIN/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$STANDIN/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string "4.7.4" "$STANDIN/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string "18" "$STANDIN/Contents/Info.plist"
STANDIN_PLIST="$SANDBOX/standin.plist"
/usr/bin/plutil -create xml1 "$STANDIN_PLIST"
/usr/bin/plutil -insert Label -string "$AGENT_LABEL" "$STANDIN_PLIST"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$STANDIN_PLIST"
/usr/bin/plutil -insert ProgramArguments.0 -string "$STANDIN/Contents/MacOS/DoubaoReplyNotifier" "$STANDIN_PLIST"
: > "$SHIM_LOG"; unset SHIM_RC
FLOG="$SANDBOX/f.log"
# Source and call in the persistent test shell so the relaunched child survives.
export HOME="$SANDBOX_HOME" DOUBAO_NOTIFIER_SKIP_LAUNCH=0 LAUNCHCTL="$SHIM/launchctl" PATH="/usr/bin:/bin"
export BUNDLE_ID="$BUNDLE_ID" AGENT_LABEL="$AGENT_LABEL"
export APP_NAME="Doubao Reply Notifier.app" BIN_NAME="DoubaoReplyNotifier"
export APP="/$SANDBOX_APPS/fake.app" LEGACY_APP=""
export AGENTS_DIR="$SANDBOX_HOME/Library/LaunchAgents" LEGACY_PLIST="$STANDIN_PLIST"
export OLD_APP_BACKUP="$STANDIN" STATE_DIR="$STANDIN_STATE"
export HEALTH_PATH="$STANDIN_STATE/runtime-health.json"
/usr/bin/sed -n '/^recover_bundle_identity_ok()/,/^}/p; /^recover_old_service()/,/^}/p' "$ROOT/install.sh" > "$SANDBOX/recover.func"
# shellcheck disable=SC1091
source "$SANDBOX/recover.func"
recover_old_service 2>"$FLOG" || true

STANDIN_PID="$(/bin/ps -axo pid=,command= | /usr/bin/awk -v b="$STANDIN/Contents/MacOS/DoubaoReplyNotifier" '{pid=$1;$1="";sub(/^ /,"");if($0==b)print pid}')"
grep -q "bootstrap" "$SHIM_LOG" && pass "managed bootstrap attempted before fallback" || fail "bootstrap not attempted"
[[ -n "$STANDIN_PID" ]] && pass "standin process actually relaunched" || fail "no standin process"
HPID="$(/usr/bin/plutil -extract pid raw "$STANDIN_STATE/runtime-health.json" 2>/dev/null || true)"
[[ "$STANDIN_PID" == "$HPID" ]] && pass "live PID matches recovered health PID" || fail "PID mismatch: ps=$STANDIN_PID health=$HPID"
[[ "$(/usr/bin/plutil -extract ready raw "$STANDIN_STATE/runtime-health.json" 2>/dev/null)" == "true" ]] \
  && pass "standin self-reported ready=true" || fail "not ready"
grep -q "等效运行态" "$FLOG" && pass "direct relaunch reported as equivalent running state" || fail "equivalent wording missing: $(cat "$FLOG")"
[[ -n "$STANDIN_PID" ]] && /bin/kill "$STANDIN_PID" 2>/dev/null || true

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "ALL ROLLBACK-RECOVERY DYNAMIC TESTS PASSED"
else
  echo "$FAILURES FAILURES" >&2
  exit 1
fi
