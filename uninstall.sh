#!/bin/bash
# Uninstall Doubao Reply Notifier.
# Covers: system copy (/Applications), legacy user copy (~/Applications),
# LaunchAgent plist, state directory, and logs.
# Never touches /Applications/Doubao.app or /Applications/DoubaoWork.app.
set -euo pipefail
BUNDLE_ID="com.local.doubao-reply-notifier"
AGENT_LABEL="com.local.doubao-reply-notifier.agent"
APP_NAME="Doubao Reply Notifier.app"
BIN_NAME="DoubaoReplyNotifier"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

APPS_DIR="${DOUBAO_NOTIFIER_APPS_DIR:-/Applications}"
TARGETS=(
  "$APPS_DIR/$APP_NAME"
  "$HOME/Applications/$APP_NAME"
)
SERVICE="gui/$(/usr/bin/id -u)/$AGENT_LABEL"

# 1. Boot out the LaunchAgent if loaded.
LAUNCHCTL="${DOUBAO_LAUNCHCTL:-/bin/launchctl}"
if "$LAUNCHCTL" print "$SERVICE" >/dev/null 2>&1; then
  "$LAUNCHCTL" bootout "$SERVICE"
fi
/bin/rm -f "$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

# 2. Kill processes whose exec path matches any known installed copy exactly.
#    No pgrep -f substring matching: avoid killing shells/scripts that merely
#    mention the path on the command line.
kill_matching() {
  local a="$1"; local b="$2"
  local pids
  pids="$(/bin/ps -axo pid=,command= 2>/dev/null | /usr/bin/awk -v a="$a" -v b="$b" '
    { pid=$1; $1=""; sub(/^ /, ""); if ($0==a || $0==b) print pid }')"
  [[ -z "$pids" ]] && return 0
  for pid in $pids; do /bin/kill -TERM "$pid" 2>/dev/null || true; done
  for _ in {1..20}; do
    pids="$(/bin/ps -axo pid=,command= 2>/dev/null | /usr/bin/awk -v a="$a" -v b="$b" '
      { pid=$1; $1=""; sub(/^ /, ""); if ($0==a || $0==b) print pid }')"
    [[ -z "$pids" ]] && return 0
    /bin/sleep 0.1
  done
  for pid in $pids; do /bin/kill -KILL "$pid" 2>/dev/null || true; done
}
kill_matching "$APPS_DIR/$APP_NAME/Contents/MacOS/$BIN_NAME" "$HOME/Applications/$APP_NAME/Contents/MacOS/$BIN_NAME"

# 3. Unregister LaunchServices entries only for bundles whose identity we
#    recognize.
for t in "${TARGETS[@]}"; do
  if [[ -d "$t" && -x "$LSREGISTER" ]] \
     && [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$t/Contents/Info.plist" 2>/dev/null || true)" == "$BUNDLE_ID" ]]; then
    "$LSREGISTER" -u "$t" 2>/dev/null || true
  fi
done

# 4. Remove app bundles. Only delete bundles whose CFBundleIdentifier we
# recognize; anything else sitting at a known path is left untouched.
for t in "${TARGETS[@]}"; do
  if [[ -d "$t" ]]; then
    if [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$t/Contents/Info.plist" 2>/dev/null || true)" == "$BUNDLE_ID" ]]; then
      /bin/rm -rf "$t"
      printf '已删除：%s\n' "$t"
    else
      printf '跳过删除：%s 的 CFBundleIdentifier 不是 %s。\n' "$t" "$BUNDLE_ID" >&2
    fi
  fi
done

# 5. Remove state directory and logs.
/bin/rm -rf "$HOME/Library/Application Support/DoubaoReplyNotifier"
/bin/rm -f "$HOME/Library/Logs/DoubaoReplyNotifier.log" "$HOME/Library/Logs/DoubaoReplyNotifier.error.log"

printf '%s\n' "Doubao Reply Notifier 已卸载。"
