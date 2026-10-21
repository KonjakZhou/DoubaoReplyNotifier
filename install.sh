#!/bin/bash
# Doubao Reply Notifier installer.
#
# Production default install location: /Applications/Doubao Reply Notifier.app
# Override: DOUBAO_NOTIFIER_APPS_DIR=/custom/path ./install.sh
#
# Migration: if a previous copy exists at ~/Applications/Doubao Reply Notifier.app
# (the historical location), it is detected, the old service is stopped, the new
# copy is staged+verified+swapped into place, and only after the new service
# reports healthy is the legacy copy removed. On any failure before that point
# the legacy copy is left untouched and still runnable.
#
# State directory (~/Library/Application Support/DoubaoReplyNotifier) is NEVER
# moved or removed by install. It persists across upgrades.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="4.7.5"
BUILD="19"
BUNDLE_ID="com.local.doubao-reply-notifier"
AGENT_LABEL="com.local.doubao-reply-notifier.agent"
APP_NAME="Doubao Reply Notifier.app"
BIN_NAME="DoubaoReplyNotifier"

# Resolve install target. Default /Applications; env override for testing/reloc.
APPS_DIR="${DOUBAO_NOTIFIER_APPS_DIR:-/Applications}"
APP="$APPS_DIR/$APP_NAME"
LEGACY_APP="$HOME/Applications/$APP_NAME"

STATE_DIR="$HOME/Library/Application Support/DoubaoReplyNotifier"
AGENTS_DIR="$HOME/Library/LaunchAgents"
LEGACY_PLIST="$AGENTS_DIR/$AGENT_LABEL.plist"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
# launchctl path overridable for isolated tests; production defaults to /bin/launchctl.
LAUNCHCTL="${DOUBAO_LAUNCHCTL:-/bin/launchctl}"

STAGE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doubao-reply-notifier.stage.XXXXXX")"
STAGED_APP="$STAGE/$APP_NAME"
STAGED_CONTENTS="$STAGED_APP/Contents"
STAGED_MACOS="$STAGED_CONTENTS/MacOS"
STAGED_RESOURCES="$STAGED_CONTENTS/Resources"
BACKUP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doubao-reply-notifier.bak.XXXXXX")"
OLD_APP_BACKUP="$BACKUP_DIR/$APP_NAME"
OLD_PLIST_BACKUP="$BACKUP_DIR/$AGENT_LABEL.plist"
HEALTH_BACKUP="$BACKUP_DIR/runtime-health.json"
# ROLLBACK_NEEDED: a pre-existing target was moved aside and must be restored.
# SWAP_COMMITTED: the new copy was written to $APP (fresh install, no prior
#   target to restore) — on failure the partial new copy must be removed.
# PLIST_OVERWRITTEN: the LaunchAgent plist was replaced — on failure restore the
#   previous plist when one existed, otherwise remove ours so launchd never keeps
#   an orphaned RunAtLoad entry pointing at a broken or removed binary.
# NEW_SERVICE_STARTED: the new LaunchAgent was bootstrapped (non-SKIP mode).
#   On a later failure, cleanup must stop the new service/processes FIRST,
#   before any file rollback, so a failed new service does not linger against
#   restored files.
ROLLBACK_NEEDED=0
SWAP_COMMITTED=0
PLIST_OVERWRITTEN=0
TARGET_CREATION_ARMED=0
NEW_SERVICE_STARTED=0

cleanup() {
  # If the new service was already bootstrapped, tear it down first: bootout
  # the LaunchAgent and kill only processes whose exec path is EXACTLY the new
  # target binary. launchctl/kill failures are surfaced honestly — they mean
  # the service is left in a stopped state, NOT that the old service is
  # running again.
  if [[ "$NEW_SERVICE_STARTED" == "1" ]]; then
    local svc="gui/$(/usr/bin/id -u)/$AGENT_LABEL"
    if ! "$LAUNCHCTL" bootout "$svc" 2>/dev/null; then
      printf '警告：无法 bootout 新服务（权限/launchctl 状态）；服务为停止态，请手动确认。\n' >&2
    fi
    local pids
    pids="$(/bin/ps -axo pid=,command= 2>/dev/null | /usr/bin/awk -v b="$APP/Contents/MacOS/$BIN_NAME" '{pid=$1; $1=""; sub(/^ /, ""); if ($0==b) print pid}')"
    for pid in $pids; do /bin/kill -TERM "$pid" 2>/dev/null || true; done
  fi
  if [[ "$ROLLBACK_NEEDED" == "1" ]]; then
    # Pre-existing target: restore it so the old install stays usable.
    /bin/rm -rf "$APP" 2>/dev/null || true
    if [[ -d "$OLD_APP_BACKUP" ]]; then /bin/mv "$OLD_APP_BACKUP" "$APP" 2>/dev/null || true; fi
  elif [[ "$SWAP_COMMITTED" == "1" || "$TARGET_CREATION_ARMED" == "1" ]]; then
    # Fresh/migration install: no prior target existed (or the copy failed
    # mid-way); drop the partial copy we created.
    /bin/rm -rf "$APP" 2>/dev/null || true
  fi
  if [[ "$PLIST_OVERWRITTEN" == "1" ]]; then
    if [[ -f "$OLD_PLIST_BACKUP" ]]; then
      /bin/mkdir -p "$AGENTS_DIR"; /bin/cp "$OLD_PLIST_BACKUP" "$LEGACY_PLIST" 2>/dev/null || true
    else
      /bin/rm -f "$LEGACY_PLIST" 2>/dev/null || true
    fi
  fi
  # On any rollback, restore the previous readiness snapshot (it is a pure
  # handshake artifact; the next service start refreshes it). manage-service.sh
  # never accepts a stale pid anyway: it re-checks PIDS==HEALTH_PID, exact
  # exec path and version/build match before declaring ready.
  if [[ -f "$HEALTH_BACKUP" && ( "$ROLLBACK_NEEDED" == "1" || "$SWAP_COMMITTED" == "1" || "$TARGET_CREATION_ARMED" == "1" ) ]]; then
    /bin/mkdir -p "$STATE_DIR"; /bin/cp "$HEALTH_BACKUP" "$STATE_DIR/runtime-health.json" 2>/dev/null || true
  fi
  # Files/config/state are restored; now try to bring the old service back
  # immediately (real mode only). Permission/launchctl failures are reported
  # honestly and never upgraded to "running".
  if [[ "$ROLLBACK_NEEDED" == "1" || "$SWAP_COMMITTED" == "1" || "$TARGET_CREATION_ARMED" == "1" || "$PLIST_OVERWRITTEN" == "1" ]]; then
    recover_old_service || true
  fi
  /bin/rm -rf "$STAGE" "$BACKUP_DIR"
}
trap cleanup EXIT

die() {
  printf '安装失败：%s\n' "$*" >&2
  exit 1
}

# --- Bundle identity verification --------------------------------------------
# Before stopping, unregistering, or deleting the legacy ~/Applications copy,
# prove it is actually OUR bundle via an exact CFBundleIdentifier match. Never
# touch an arbitrary directory that merely sits at the legacy path.
legacy_identity_ok() {
  local info="$LEGACY_APP/Contents/Info.plist"
  [[ -f "$info" ]] || return 1
  [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$info" 2>/dev/null || true)" == "$BUNDLE_ID" ]]
}

# --- Process identification -------------------------------------------------
# Match only processes whose exec path is EXACTLY one of the known bundle
# MacOS binaries. Never use pgrep -f substring matching: that would kill shells,
# scripts, or any other process that merely mentions the path on its command line.
# The legacy path participates only after a positive bundle-identity check.
pids_matching_known_exec() {
  local a="$APP/Contents/MacOS/$BIN_NAME"
  local b=""
  if [[ "$LEGACY_APP" != "$APP" && -d "$LEGACY_APP" ]] && legacy_identity_ok; then
    b="$LEGACY_APP/Contents/MacOS/$BIN_NAME"
  fi
  /bin/ps -axo pid=,command= 2>/dev/null | /usr/bin/awk -v a="$a" -v b="$b" '
    {
      pid=$1; $1=""; sub(/^ /, "")
      if ($0 == a || (b != "" && $0 == b)) print pid
    }'
}

stop_service_and_processes() {
  local service="gui/$(/usr/bin/id -u)/$AGENT_LABEL"
  if "$LAUNCHCTL" print "$service" >/dev/null 2>&1; then
    "$LAUNCHCTL" bootout "$service" || return 1
  fi
  local pids
  pids="$(pids_matching_known_exec)"
  [[ -z "$pids" ]] && return 0
  for pid in $pids; do /bin/kill -TERM "$pid" 2>/dev/null || true; done
  for _ in {1..30}; do
    pids="$(pids_matching_known_exec)"
    [[ -z "$pids" ]] && return 0
    /bin/sleep 0.1
  done
  for pid in $pids; do /bin/kill -KILL "$pid" 2>/dev/null || true; done
  /bin/sleep 0.2
  [[ -z "$(pids_matching_known_exec)" ]]
}

# --- Old-service recovery after rollback (real mode only) -------------------
# The pre-existing process may be a managed agent OR a plain application job
# (application.com.local.*, launched by Finder/open). We never assume the old
# agent label exists: first try managed bootstrap when a restored plist points
# at the old binary; if that yields no exact-path process (application-job
# case), relaunch the identity-checked old binary directly as an equivalent
# running state. A claim of "running" always requires observing the exact-path
# process; permission/bootstrap failure is reported honestly as stopped.
recover_bundle_identity_ok() {
  local info="$1/Contents/Info.plist"
  [[ -f "$info" ]] || return 1
  [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$info" 2>/dev/null || true)" == "$BUNDLE_ID" ]]
}

recover_old_service() {
  [[ "${DOUBAO_NOTIFIER_SKIP_LAUNCH:-0}" == "1" ]] && return 0
  local domain="gui/$(/usr/bin/id -u)"
  local old_bin="" old_app=""
  if [[ -f "$LEGACY_PLIST" ]]; then
    old_bin="$(/usr/bin/plutil -extract ProgramArguments.0 raw "$LEGACY_PLIST" 2>/dev/null || true)"
  fi
  if [[ -z "$old_bin" && "$LEGACY_APP" != "$APP" && -d "$LEGACY_APP" ]]; then
    old_app="$LEGACY_APP"; old_bin="$LEGACY_APP/Contents/MacOS/$BIN_NAME"
  fi
  if [[ -z "$old_bin" && -d "$OLD_APP_BACKUP" ]]; then
    old_app="$OLD_APP_BACKUP"; old_bin="$OLD_APP_BACKUP/Contents/MacOS/$BIN_NAME"
  fi
  [[ -n "$old_bin" ]] || return 0
  # Identity gate: only exec a restored bundle that proves our Bundle ID.
  # Derive and verify the bundle for ALL recovery paths, including plist input.
  old_app="${old_bin%/Contents/MacOS/$BIN_NAME}"
  [[ "$old_bin" == "$old_app/Contents/MacOS/$BIN_NAME" ]] || return 1
  if ! recover_bundle_identity_ok "$old_app"; then
    printf '警告：待恢复 Bundle 身份不匹配，拒绝启动；文件已恢复，请手动打开旧版。\n' >&2
    return 1
  fi

  local exact_pid
  exact_pid() {
    /bin/ps -axo pid=,command= 2>/dev/null | /usr/bin/awk -v b="$old_bin" '{pid=$1;$1="";sub(/^ /,"");if($0==b)print pid}'
  }
  local baseline; baseline="$(/bin/date +%s)"
  local started=""
  if [[ -f "$LEGACY_PLIST" ]] && "$LAUNCHCTL" bootstrap "$domain" "$LEGACY_PLIST" 2>/dev/null; then
    started="managed"
  fi
  local pid="" i
  for i in {1..20}; do
    pid="$(exact_pid)"; [[ -n "$pid" ]] && break; /bin/sleep 0.1
  done
  # Managed bootstrap produced no process: original was likely a plain
  # application job; relaunch the old binary directly (equivalent running).
  if [[ -z "$pid" && -x "$old_bin" ]]; then
    /bin/mkdir -p "$STATE_DIR"
    DOUBAO_NOTIFIER_MANAGED_SERVICE=1 /usr/bin/nohup "$old_bin" >>"$STATE_DIR/service.recover.log" 2>&1 &
    /usr/bin/disown 2>/dev/null || true
    for i in {1..30}; do
      pid="$(exact_pid)"; [[ -n "$pid" ]] && { started="direct"; break; }; /bin/sleep 0.1
    done
  fi
  # Expected old version/build from the restored bundle; health alone is never
  # trusted. Freshness baseline: health must be written AFTER recovery starts, so
  # a stale pre-install ready snapshot is rejected.
  local old_ver="" old_build=""
  if [[ -n "$old_app" && -f "$old_app/Contents/Info.plist" ]]; then
    old_ver="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$old_app/Contents/Info.plist" 2>/dev/null || true)"
    old_build="$(/usr/bin/plutil -extract CFBundleVersion raw "$old_app/Contents/Info.plist" 2>/dev/null || true)"
  fi
  # baseline was captured before starting the old process.
  # Require the app's OWN readiness snapshot: live PID == health PID, ready=true,
  # version/build match the restored bundle, and freshly written. Recovery never
  # writes or fakes health; an unready/stale process is reported honestly.
  local HEALTH_FILE="$STATE_DIR/runtime-health.json" ready=0
  for i in {1..50}; do
    if [[ -n "$pid" && -f "$HEALTH_FILE" ]]; then
      local hpid hready hver hbuild mtime
      hpid="$(/usr/bin/plutil -extract pid raw "$HEALTH_FILE" 2>/dev/null || true)"
      hready="$(/usr/bin/plutil -extract ready raw "$HEALTH_FILE" 2>/dev/null || true)"
      hver="$(/usr/bin/plutil -extract version raw "$HEALTH_FILE" 2>/dev/null || true)"
      hbuild="$(/usr/bin/plutil -extract build raw "$HEALTH_FILE" 2>/dev/null || true)"
      mtime="$(/usr/bin/stat -f %m "$HEALTH_FILE" 2>/dev/null || echo 0)"
      if [[ "$pid" == "$hpid" && "$hready" == "true" && "$mtime" -ge "$baseline" \
            && ( -z "$old_ver" || "$hver" == "$old_ver" ) \
            && ( -z "$old_build" || "$hbuild" == "$old_build" ) ]]; then
        ready=1; break
      fi
    fi
    /bin/sleep 0.1
  done
  if [[ "$ready" == "1" && "$started" == "managed" ]]; then
    printf '旧版受管服务已恢复运行（%s，PID %s，健康就绪）。\n' "$old_bin" "$pid" >&2
  elif [[ "$ready" == "1" && "$started" == "direct" ]]; then
    printf '旧版已直接重启为等效运行态（%s，PID %s，健康就绪；非受管 agent，原应用任务已恢复）。\n' "$old_bin" "$pid" >&2
  else
    printf '警告：旧服务未能恢复就绪（bootstrap/直启失败、进程未活或健康未就绪）；文件已恢复，请手动打开旧版。\n' >&2
    printf '恢复检查：live=%s health=%s ready=%s version=%s/%s build=%s/%s mtime=%s baseline=%s started=%s\n' "$pid" "${hpid:-}" "${hready:-}" "${hver:-}" "$old_ver" "${hbuild:-}" "$old_build" "${mtime:-}" "$baseline" "$started" >&2
    return 1
  fi
}

# --- Staging -----------------------------------------------------------------
HOST_ARCH="$(/usr/bin/uname -m)"
[[ "$HOST_ARCH" == "arm64" || "$HOST_ARCH" == "x86_64" ]] || die "不支持的 Mac 架构：$HOST_ARCH"

PREBUILT_APP="$ROOT/$APP_NAME"
if [[ -d "$PREBUILT_APP" ]]; then
  /bin/cp -R "$PREBUILT_APP" "$STAGED_APP"
  PREBUILT_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$STAGED_CONTENTS/Info.plist")"
  PREBUILT_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw "$STAGED_CONTENTS/Info.plist")"
  [[ "$PREBUILT_VERSION" == "$VERSION" && "$PREBUILT_BUILD" == "$BUILD" ]] \
    || die "分发包版本校验失败：期望 $VERSION ($BUILD)，实际 $PREBUILT_VERSION ($PREBUILT_BUILD)。"
  /usr/bin/codesign --verify --deep --strict "$STAGED_APP"
  /usr/bin/file "$STAGED_MACOS/$BIN_NAME" | /usr/bin/grep -q "$HOST_ARCH" \
    || die "分发包不包含当前 Mac 架构：$HOST_ARCH"
else
  SWIFTC="$(/usr/bin/xcrun --find swiftc 2>/dev/null || true)"
  SDKROOT="$(/usr/bin/xcrun --show-sdk-path 2>/dev/null || true)"
  [[ -n "$SWIFTC" && -n "$SDKROOT" ]] \
    || die "未找到预编译 App，且本机缺少 Apple Command Line Tools。请使用完整分发包，或执行 xcode-select --install。"
  /bin/mkdir -p "$STAGED_MACOS" "$STAGED_RESOURCES"
  "$SWIFTC" -O -sdk "$SDKROOT" -target "${HOST_ARCH}-apple-macosx13.0" \
    -framework AppKit -framework UserNotifications -framework CryptoKit -framework ServiceManagement \
    "$ROOT/Sources/EventArchitecture.swift" "$ROOT/Sources/PermissionReviewSource.swift" \
    "$ROOT/Sources/ConversationTitleReader.swift" "$ROOT/Sources/IndexedDBInteractionReader.swift" \
    "$ROOT/Sources/main.swift" -o "$STAGED_MACOS/$BIN_NAME"
  /bin/cp "$ROOT/assets/AppIcon.icns" "$STAGED_RESOURCES/AppIcon.icns"
  /usr/bin/plutil -create xml1 "$STAGED_CONTENTS/Info.plist"
  /usr/bin/plutil -insert CFBundleName -string "Doubao Reply Notifier" "$STAGED_CONTENTS/Info.plist"
  /usr/bin/plutil -insert CFBundleDisplayName -string "豆包回复通知" "$STAGED_CONTENTS/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$STAGED_CONTENTS/Info.plist"
  /usr/bin/plutil -insert CFBundleVersion -string "$BUILD" "$STAGED_CONTENTS/Info.plist"
  /usr/bin/plutil -insert CFBundleShortVersionString -string "$VERSION" "$STAGED_CONTENTS/Info.plist"
  /usr/bin/plutil -insert CFBundlePackageType -string "APPL" "$STAGED_CONTENTS/Info.plist"
  /usr/bin/plutil -insert CFBundleExecutable -string "$BIN_NAME" "$STAGED_CONTENTS/Info.plist"
  /usr/bin/plutil -insert CFBundleIconFile -string "AppIcon.icns" "$STAGED_CONTENTS/Info.plist"
  /usr/bin/plutil -insert LSUIElement -bool true "$STAGED_CONTENTS/Info.plist"
  /usr/bin/codesign --force --deep --sign - "$STAGED_APP"
  /usr/bin/codesign --verify --deep --strict "$STAGED_APP"
fi

# --- Pre-install safety snapshot --------------------------------------------
# Snapshot an existing target only when it is provably OUR bundle. A foreign
# directory or a symlink at the target path is never moved, modified or
# deleted: the install refuses and leaves it untouched.
if [[ -L "$APP" ]]; then
  die "目标位置是符号链接：$APP（未改动）。请先手动移开后重试。"
fi
if [[ -e "$APP" && ! -d "$APP" ]]; then
  die "目标位置不是 App 目录：$APP（未改动）。"
fi
if [[ -d "$APP" ]]; then
  if [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist" 2>/dev/null || true)" != "$BUNDLE_ID" ]]; then
    die "目标位置已有非本产品的 App：$APP（未改动、未删除）。请先手动处理后重试。"
  fi
fi
if [[ -L "$LEGACY_APP" ]]; then
  die "旧安装位置是符号链接，拒绝迁移：$LEGACY_APP"
fi
[[ -d "$APPS_DIR" && -w "$APPS_DIR" ]] || die "目标目录不可写：${APPS_DIR}；旧服务未停止。"
if [[ -f "$LEGACY_PLIST" ]]; then
  /bin/cp "$LEGACY_PLIST" "$OLD_PLIST_BACKUP"
fi

# --- Stop old service/process before swap (skipped in test/CI mode) ---------
if [[ "${DOUBAO_NOTIFIER_SKIP_LAUNCH:-0}" != "1" ]]; then
  if ! stop_service_and_processes; then
    die "无法停止旧版通知器，请退出菜单栏中的旧通知器后重试。"
  fi
fi

# --- Swap new app into place ------------------------------------------------
# Stop the old executable before moving its bundle (process path stays stable).
if [[ -d "$APP" ]]; then
  /bin/mv "$APP" "$OLD_APP_BACKUP"
  ROLLBACK_NEEDED=1
fi
/bin/mkdir -p "$APPS_DIR"
# Arm the "fresh target creation" rollback BEFORE the copy, so a partially
# failed cp still tears down the partial target. Arm only when nothing
# pre-existing was moved aside and the target path is absent or not a symlink
# we must not disturb.
if [[ ! -e "$APP" && ! -L "$APP" && ! -d "$OLD_APP_BACKUP" ]]; then
  TARGET_CREATION_ARMED=1
fi
if ! /bin/cp -R "$STAGED_APP" "$APP"; then
  die "复制到目标位置失败（$APPS_DIR 可能不可写）。"
fi
# From here on, a failure must tear down the partial target (fresh install) or
# restore the moved-aside target (upgrade) via cleanup.
SWAP_COMMITTED=1

# Verify installed copy on its final location.
/usr/bin/codesign --verify --deep --strict "$APP" \
  || die "安装后签名校验失败。"
INSTALLED_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
INSTALLED_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"
[[ "$INSTALLED_VERSION" == "$VERSION" && "$INSTALLED_BUILD" == "$BUILD" ]] \
  || die "安装版本校验失败：期望 $VERSION ($BUILD)，实际 $INSTALLED_VERSION ($INSTALLED_BUILD)。"

# --- LaunchAgent plist points at the FINAL path -----------------------------
/bin/mkdir -p "$AGENTS_DIR" "$STATE_DIR"
# Back up the previous readiness snapshot before clearing it, so a later
# failure can restore the pre-install state instead of leaving a gap.
[[ -f "$STATE_DIR/runtime-health.json" ]] && /bin/cp "$STATE_DIR/runtime-health.json" "$HEALTH_BACKUP"
/bin/rm -f "$STATE_DIR/runtime-health.json"
# Write the plist unconditionally (even in SKIP_LAUNCH/test mode) so it is
# loaded by launchd at next login. manage-service.sh overwrites it identically
# when actually bootstrapping.
FINAL_BIN="$APP/Contents/MacOS/$BIN_NAME"
TMP_PLIST="$AGENTS_DIR/.notifier.install.$$"
/usr/bin/plutil -create xml1 "$TMP_PLIST"
/usr/bin/plutil -insert Label -string "$AGENT_LABEL" "$TMP_PLIST"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$TMP_PLIST"
/usr/bin/plutil -insert ProgramArguments.0 -string "$FINAL_BIN" "$TMP_PLIST"
/usr/bin/plutil -insert RunAtLoad -bool true "$TMP_PLIST"
/usr/bin/plutil -insert KeepAlive -bool false "$TMP_PLIST"
/usr/bin/plutil -insert ProcessType -string Interactive "$TMP_PLIST"
/usr/bin/plutil -insert ThrottleInterval -integer 10 "$TMP_PLIST"
/usr/bin/plutil -insert EnvironmentVariables -json '{"DOUBAO_NOTIFIER_MANAGED_SERVICE":"1"}' "$TMP_PLIST"
/usr/bin/plutil -insert StandardOutPath -string "$STATE_DIR/service.stdout.log" "$TMP_PLIST"
/usr/bin/plutil -insert StandardErrorPath -string "$STATE_DIR/service.stderr.log" "$TMP_PLIST"
/bin/chmod 600 "$TMP_PLIST"
/bin/mv "$TMP_PLIST" "$LEGACY_PLIST"
# Plist has been replaced; a later failure must roll it back (restore previous
# or remove ours — never leave an orphaned RunAtLoad entry).
PLIST_OVERWRITTEN=1

# --- LaunchServices: register new, unregister legacy to avoid multi-copy ---
# Legacy unregistration only after proving the legacy copy is our bundle.
if [[ -x "$LSREGISTER" ]]; then
  if [[ "$LEGACY_APP" != "$APP" && -d "$LEGACY_APP" ]] && legacy_identity_ok; then
    "$LSREGISTER" -u "$LEGACY_APP" 2>/dev/null || true
  fi
  "$LSREGISTER" -f "$APP" 2>/dev/null || true
fi

# --- Start / verify service -------------------------------------------------
if [[ "${DOUBAO_NOTIFIER_SKIP_LAUNCH:-0}" == "1" ]]; then
  printf '%s\n' "已跳过 LaunchAgent 启动（DOUBAO_NOTIFIER_SKIP_LAUNCH=1）。"
else
  NEW_SERVICE_STARTED=1
  if ! /bin/bash "$ROOT/scripts/manage-service.sh" start "$APP" "$HOME" "$VERSION" "$BUILD"; then
    die "新版文件已就位，但服务启动健康校验失败；已回滚，旧版仍可用。"
  fi
fi

# --- Success: commit. No rollback. ------------------------------------------
ROLLBACK_NEEDED=0
SWAP_COMMITTED=0
PLIST_OVERWRITTEN=0
TARGET_CREATION_ARMED=0
NEW_SERVICE_STARTED=0
# Remove legacy copy only after the new install is verified AND only after its
# bundle identity has been proven. An unrecognized directory at the legacy path
# is left untouched with a warning.
if [[ -d "$LEGACY_APP" && "$LEGACY_APP" != "$APP" ]]; then
  if legacy_identity_ok; then
    /bin/rm -rf "$LEGACY_APP"
    if [[ -x "$LSREGISTER" ]]; then "$LSREGISTER" -u "$LEGACY_APP" 2>/dev/null || true; fi
  else
    printf '警告：旧位置 %s 的 Bundle 身份不是 %s，已保留未删除。\n' "$LEGACY_APP" "$BUNDLE_ID" >&2
  fi
fi
# Drop the pre-existing target backup (new install is good).
if [[ -d "$OLD_APP_BACKUP" ]]; then /bin/rm -rf "$OLD_APP_BACKUP"; fi

# --- Multi-copy ambiguity self-check (warning only, non-fatal) -------------
DUP_WARNING=""
if [[ -x "$LSREGISTER" ]]; then
  registered="$("$LSREGISTER" -dump 2>/dev/null | /usr/bin/awk '/^path:/{print $2}' | /usr/bin/grep "/$APP_NAME$" || true)"
  if [[ $(printf '%s\n' "$registered" | /usr/bin/grep -c . || true) -gt 1 ]]; then
    DUP_WARNING="警告：LaunchServices 仍注册了多个副本：$registered"
  fi
fi
md_results="$(/usr/bin/mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null || true)"
if [[ $(printf '%s\n' "$md_results" | /usr/bin/grep -c . || true) -gt 1 ]]; then
  DUP_WARNING="$DUP_WARNING 警告：Spotlight 索引到多个副本：$md_results"
fi

printf '%s\n' \
  "安装成功：$APP" \
  "版本：${VERSION}（build ${BUILD}）" \
  "架构：$(/usr/bin/file "$APP/Contents/MacOS/$BIN_NAME" | /usr/bin/sed 's/.*: //')" \
  "监听方式：统一事件模型 + Resolver + 会话状态机（Saman 审阅/Toolcall/Blocker + trajectory + IndexedDB）"
[[ -n "$DUP_WARNING" ]] && printf '%s\n' "$DUP_WARNING" >&2
exit 0
