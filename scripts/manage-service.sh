#!/bin/bash
# Current-user background service lifecycle only. No client GUI automation.
# Usage: manage-service.sh start <absolute-app-path> <home> <version> <build>
# The LaunchAgent ProgramArguments is written to the FINAL absolute executable
# path passed in by the installer. Process matching is by exact exec path only.
set -euo pipefail
[[ "$#" == 5 && "$1" == start ]] || { printf '%s\n' '用法：manage-service.sh start app home version build' >&2; exit 2; }
APP="$2"; TARGET_HOME="$3"; VERSION="$4"; BUILD="$5"
[[ "$TARGET_HOME" == "$HOME" ]] || { printf '%s\n' '服务仅在当前用户 HOME 启动。' >&2; exit 1; }
LABEL="com.local.doubao-reply-notifier.agent"
BUNDLE_ID="com.local.doubao-reply-notifier"
# launchctl overridable for isolated tests; production defaults to /bin/launchctl.
LAUNCHCTL="${DOUBAO_LAUNCHCTL:-/bin/launchctl}"
DOMAIN="gui/$(/usr/bin/id -u)"
SERVICE="$DOMAIN/$LABEL"
INFO="$APP/Contents/Info.plist"
BIN="$APP/Contents/MacOS/DoubaoReplyNotifier"
[[ -x "$BIN" ]] || { printf '%s\n' "可执行文件不存在或不可执行：$BIN" >&2; exit 1; }
[[ -f "$INFO" ]] || { printf '%s\n' "Info.plist 不存在：$INFO" >&2; exit 1; }
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$INFO" 2>/dev/null || true)" == "$BUNDLE_ID" ]] || { printf '%s\n' '拒绝启动其他 App。' >&2; exit 1; }
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$INFO" 2>/dev/null)" == "$VERSION" && \
   "$(/usr/bin/plutil -extract CFBundleVersion raw "$INFO" 2>/dev/null)" == "$BUILD" ]] || { printf '%s\n' '安装版本不匹配。' >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$APP"
if "$LAUNCHCTL" print "$SERVICE" >/dev/null 2>&1; then "$LAUNCHCTL" bootout "$SERVICE"; fi

# Print PIDs of processes whose exec path is EXACTLY $BIN. No substring match.
exact_pids() {
  /bin/ps -axo pid=,command= 2>/dev/null | /usr/bin/awk -v b="$BIN" '
    { pid=$1; $1=""; sub(/^ /, ""); if ($0==b) print pid }'
}
[[ -z "$(exact_pids)" ]] || { printf '%s\n' '仍有手工启动实例，拒绝制造重复进程。' >&2; exit 1; }

FOLDER="$HOME/Library/Application Support/DoubaoReplyNotifier"
AGENTS="$HOME/Library/LaunchAgents"
HEALTH="$FOLDER/runtime-health.json"
/bin/mkdir -p "$FOLDER" "$AGENTS"
/bin/rm -f "$HEALTH"
TMP="$(/usr/bin/mktemp "$AGENTS/.notifier.XXXXXX")"
trap '/bin/rm -f "$TMP"' EXIT
/usr/bin/plutil -create xml1 "$TMP"
/usr/bin/plutil -insert Label -string "$LABEL" "$TMP"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$TMP"
/usr/bin/plutil -insert ProgramArguments.0 -string "$BIN" "$TMP"
/usr/bin/plutil -insert RunAtLoad -bool true "$TMP"
/usr/bin/plutil -insert KeepAlive -bool false "$TMP"
/usr/bin/plutil -insert ProcessType -string Interactive "$TMP"
/usr/bin/plutil -insert ThrottleInterval -integer 10 "$TMP"
/usr/bin/plutil -insert EnvironmentVariables -json '{"DOUBAO_NOTIFIER_MANAGED_SERVICE":"1"}' "$TMP"
/usr/bin/plutil -insert StandardOutPath -string "$FOLDER/service.stdout.log" "$TMP"
/usr/bin/plutil -insert StandardErrorPath -string "$FOLDER/service.stderr.log" "$TMP"
/bin/chmod 600 "$TMP"
PLIST="$AGENTS/$LABEL.plist"
/bin/mv "$TMP" "$PLIST"
"$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST"
for _ in {1..180}; do
  PIDS="$(exact_pids)"
  HEALTH_PID="$(/usr/bin/plutil -extract pid raw "$HEALTH" 2>/dev/null || true)"
  READY="$(/usr/bin/plutil -extract ready raw "$HEALTH" 2>/dev/null || true)"
  if [[ -n "$PIDS" && "$PIDS" == "$HEALTH_PID" && "$READY" == true ]]; then
    [[ "$(/usr/bin/plutil -extract version raw "$HEALTH" 2>/dev/null)" == "$VERSION" && \
       "$(/usr/bin/plutil -extract build raw "$HEALTH" 2>/dev/null)" == "$BUILD" ]] || { printf '%s\n' '就绪进程版本不匹配。' >&2; exit 1; }
    # Re-verify the PID actually corresponds to $BIN (not a stale health file).
    [[ "$(/bin/ps -p "$HEALTH_PID" -o command= 2>/dev/null || true)" == "$BIN" ]] || { printf '%s\n' 'health PID 与可执行路径不一致。' >&2; exit 1; }
    /bin/sleep 1
    [[ "$(exact_pids)" == "$PIDS" ]] || { printf '%s\n' '进程启动后未稳定存活。' >&2; exit 1; }
    # Acceptance BEFORE declaring ready: exactly one exact-path instance, and
    # the agent must actually be loaded in the launchd gui domain (a manually
    # started process alone is not accepted). The detection logic above
    # (exact exec path, health PID == live PID, ready, version/build match) is
    # unchanged; this only adds the loaded-state and uniqueness gates.
    INSTANCE_COUNT="$(exact_pids | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    [[ "$INSTANCE_COUNT" == "1" ]] \
      || { printf '%s\n' "检测到 $INSTANCE_COUNT 个实例，拒绝重复启动。" >&2; exit 1; }
    "$LAUNCHCTL" print "$SERVICE" >/dev/null 2>&1 \
      || { printf '%s\n' '服务未在 launchd 域加载，拒绝宣称就绪。' >&2; exit 1; }
    printf '%s\n' "服务已自动启动并验证：${VERSION}（build ${BUILD}），唯一实例且原生扫描已就绪。"
    exit 0
  fi
  /bin/sleep 0.25
done
printf '%s\n' "服务未在45秒内就绪，请检查 $FOLDER/service.stderr.log；未宣称启动成功。" >&2
exit 1
