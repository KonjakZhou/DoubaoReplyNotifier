#!/bin/bash
# Installer migration / rollback / uninstall coverage tests.
# All paths are redirected to a temp root. Real /Applications and real $HOME
# are never touched. Run with: bash tests/test-install-migration.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREBUILT="$ROOT/Doubao Reply Notifier.app"
[[ -d "$PREBUILT" ]] || { echo "需要先构建 $PREBUILT" >&2; exit 1; }

REAL_APP="/Applications/Doubao Reply Notifier.app"
REAL_BEFORE="$(if [[ -f "$REAL_APP/Contents/MacOS/DoubaoReplyNotifier" ]]; then /usr/bin/shasum -a 256 "$REAL_APP/Contents/MacOS/DoubaoReplyNotifier"; else printf absent; fi)"
FAILURES=0
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES+1)); }
pass() { echo "ok: $*"; }

# Build a sandbox home + apps dir.
SANDBOX="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doubao-install-test.XXXXXX")"
trap '/bin/rm -rf "$SANDBOX"' EXIT
SANDBOX_HOME="$SANDBOX/home"
# Run against a disposable distribution; never corrupt the source prebuilt.
SOURCE_ROOT="$ROOT"
ROOT="$SANDBOX/distribution"
/bin/mkdir -p "$ROOT/scripts"
/bin/cp "$SOURCE_ROOT/install.sh" "$SOURCE_ROOT/uninstall.sh" "$ROOT/"
/bin/cp "$SOURCE_ROOT/scripts/manage-service.sh" "$ROOT/scripts/"
/bin/cp -R "$PREBUILT" "$ROOT/Doubao Reply Notifier.app"
PREBUILT="$ROOT/Doubao Reply Notifier.app"
# A sandbox HOME is not a launchd isolation boundary. Block all real calls.
export DOUBAO_LAUNCHCTL=/usr/bin/false
SANDBOX_APPS="$SANDBOX/Applications"
/bin/mkdir -p "$SANDBOX_HOME/Applications" "$SANDBOX_APPS"

# Make a minimal "legacy" install at $SANDBOX_HOME/Applications (simulating old ~/Applications install).
LEGACY="$SANDBOX_HOME/Applications/Doubao Reply Notifier.app"
/bin/cp -R "$PREBUILT" "$LEGACY"

# Install env: redirect HOME and APPS_DIR, skip launchd.
export HOME="$SANDBOX_HOME"
export DOUBAO_NOTIFIER_APPS_DIR="$SANDBOX_APPS"
export DOUBAO_NOTIFIER_SKIP_LAUNCH=1

echo "=== Test 1: fresh install migrates legacy away ==="
/bin/bash "$ROOT/install.sh" >"$SANDBOX/install1.log" 2>&1 || { cat "$SANDBOX/install1.log" >&2; fail "install.sh exited nonzero"; }
[[ -d "$SANDBOX_APPS/Doubao Reply Notifier.app" ]] && pass "target app exists in \$APPS_DIR" || fail "target app missing"
[[ ! -d "$LEGACY" ]] && pass "legacy ~/Applications copy removed after successful install" || fail "legacy copy still present"
PLIST="$SANDBOX_HOME/Library/LaunchAgents/com.local.doubao-reply-notifier.agent.plist"
[[ -f "$PLIST" ]] && pass "LaunchAgent plist written" || fail "plist missing"
if [[ -f "$PLIST" ]]; then
  PG="$(/usr/bin/plutil -extract ProgramArguments.0 raw "$PLIST" 2>/dev/null || true)"
  [[ "$PG" == "$SANDBOX_APPS/Doubao Reply Notifier.app/Contents/MacOS/DoubaoReplyNotifier" ]] \
    && pass "plist ProgramArguments points to final target path" \
    || fail "plist ProgramArguments wrong: $PG"
fi
# State dir must have been created but not migrated/deleted.
[[ -d "$SANDBOX_HOME/Library/Application Support/DoubaoReplyNotifier" ]] && pass "state dir present" || fail "state dir missing"

echo "=== Test 2: re-install over existing target is idempotent ==="
/bin/bash "$ROOT/install.sh" >"$SANDBOX/install2.log" 2>&1 || { cat "$SANDBOX/install2.log" >&2; fail "second install failed"; }
[[ -d "$SANDBOX_APPS/Doubao Reply Notifier.app" ]] && pass "target still present after re-install" || fail "target missing after re-install"

echo "=== Test 3: rollback on signature-verification failure preserves legacy/target ==="
# Corrupt the staged prebuilt by flipping a byte in the Mach-O, then expect install to fail AND roll back.
# We do this by making codesign verification fail on the source prebuilt copy. Save it first.
/bin/cp -R "$PREBUILT" "$SANDBOX/backup-prebuilt.app"
# Tamper: append a byte to the Mach-O so signature seals break.
printf 'X' >> "$PREBUILT/Contents/MacOS/DoubaoReplyNotifier"
# Restore legacy so we can test rollback from a "legacy exists" state.
/bin/rm -rf "$SANDBOX_APPS/Doubao Reply Notifier.app"
/bin/cp -R "$SANDBOX/backup-prebuilt.app" "$LEGACY"
if /bin/bash "$ROOT/install.sh" >"$SANDBOX/install3.log" 2>&1; then
  fail "corrupted prebuilt should have failed install"
else
  pass "install rejected corrupted prebuilt"
fi
# Rollback: target should not exist (we had removed it), legacy should remain.
[[ ! -d "$SANDBOX_APPS/Doubao Reply Notifier.app" ]] && pass "no partial target after failure" || fail "partial target left behind"
[[ -d "$LEGACY" ]] && pass "legacy copy preserved after failed install" || fail "legacy copy lost after failed install"
# Restore prebuilt for subsequent tests.
/bin/rm -rf "$PREBUILT"
/bin/cp -R "$SANDBOX/backup-prebuilt.app" "$PREBUILT"

echo "=== Test 4: uninstall removes both copies, plist, state dir ==="
# First do a clean install to set up state.
/bin/bash "$ROOT/install.sh" >"$SANDBOX/install4.log" 2>&1 || { cat "$SANDBOX/install4.log" >&2; fail "setup install failed"; }
# Re-create a stray legacy copy to ensure uninstall catches it.
/bin/cp -R "$PREBUILT" "$LEGACY"
/bin/bash "$ROOT/uninstall.sh" >"$SANDBOX/uninstall.log" 2>&1 || { cat "$SANDBOX/uninstall.log" >&2; fail "uninstall failed"; }
[[ ! -d "$SANDBOX_APPS/Doubao Reply Notifier.app" ]] && pass "system copy removed" || fail "system copy still present"
[[ ! -d "$LEGACY" ]] && pass "legacy copy removed" || fail "legacy copy still present"
[[ ! -f "$PLIST" ]] && pass "plist removed" || fail "plist still present"
[[ ! -d "$SANDBOX_HOME/Library/Application Support/DoubaoReplyNotifier" ]] && pass "state dir removed" || fail "state dir still present"

echo "=== Test 6: legacy copy with FOREIGN bundle identity is preserved ==="
# Fresh install to get a clean target.
/bin/bash "$ROOT/install.sh" >"$SANDBOX/install6.log" 2>&1 || { cat "$SANDBOX/install6.log" >&2; fail "setup install 6 failed"; }
# Plant a foreign bundle at the legacy path.
/bin/cp -R "$PREBUILT" "$LEGACY"
/usr/bin/plutil -replace CFBundleIdentifier -string "com.evil.impostor" "$LEGACY/Contents/Info.plist"
if /bin/bash "$ROOT/install.sh" >"$SANDBOX/install6b.log" 2>&1; then
  pass "install over foreign legacy succeeds"
else
  cat "$SANDBOX/install6b.log" >&2; fail "install over foreign legacy failed"
fi
[[ -d "$LEGACY" ]] && pass "foreign legacy copy preserved (not deleted)" || fail "foreign legacy copy was deleted!"
FID="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$LEGACY/Contents/Info.plist" 2>/dev/null || true)"
[[ "$FID" == "com.evil.impostor" ]] && pass "foreign bundle identity untouched" || fail "foreign bundle identity altered: $FID"

echo "=== Test 5: no real /Applications touched ==="
REAL_AFTER="$(if [[ -f "$REAL_APP/Contents/MacOS/DoubaoReplyNotifier" ]]; then /usr/bin/shasum -a 256 "$REAL_APP/Contents/MacOS/DoubaoReplyNotifier"; else printf absent; fi)"
[[ "$REAL_BEFORE" == "$REAL_AFTER" ]] && pass "real production app unchanged" || fail "real production app changed"
[[ ! -e "/Applications/Doubao.app" ]] || echo "note: /Applications/Doubao.app exists (must not be touched by this script)"

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "ALL INSTALL-MIGRATION TESTS PASSED"
else
  echo "$FAILURES FAILURES" >&2
  exit 1
fi
