#!/bin/bash
set -euo pipefail
# Current-user background service lifecycle only. No client GUI automation.
[[ "$#" == 5 && "$1" == start ]] || { printf '%s\n' '用法：manage-service.sh start app home version build' >&2; exit 2; }
APP="$2"; TARGET_HOME="$3"; VERSION="$4"; BUILD="$5"
[[ "$TARGET_HOME" == "$HOME" ]] || { printf '%s\n' '服务仅在当前用户 HOME 启动。' >&2; exit 1; }
LABEL="com.local.doubao-reply-notifier.agent"
DOMAIN="gui/$(/usr/bin/id -u)"
SERVICE="$DOMAIN/$LABEL"
INFO="$APP/Contents/Info.plist"
BIN="$APP/Contents/MacOS/DoubaoReplyNotifier"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$INFO")" == "com.local.doubao-reply-notifier" ]] || { printf '%s\n' '拒绝启动其他 App。' >&2; exit 1; }
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$INFO")" == "$VERSION" && "$(/usr/bin/plutil -extract CFBundleVersion raw "$INFO")" == "$BUILD" ]] || { printf '%s\n' '安装版本不匹配。' >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$APP"
if /bin/launchctl print "$SERVICE" >/dev/null 2>&1; then /bin/launchctl bootout "$SERVICE"; fi
exact_pids() {
  local candidate command
  for candidate in $(/usr/bin/pgrep -f "$BIN" || true); do
    command="$(/bin/ps -p "$candidate" -o command= 2>/dev/null || true)"
    [[ "$command" != "$BIN" ]] || printf '%s\n' "$candidate"
  done
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
/bin/launchctl bootstrap "$DOMAIN" "$PLIST"
for _ in {1..180}; do
  PIDS="$(exact_pids)"
  HEALTH_PID="$(/usr/bin/plutil -extract pid raw "$HEALTH" 2>/dev/null || true)"
  READY="$(/usr/bin/plutil -extract ready raw "$HEALTH" 2>/dev/null || true)"
  if [[ -n "$PIDS" && "$PIDS" == "$HEALTH_PID" && "$READY" == true ]]; then
    [[ "$(/usr/bin/plutil -extract version raw "$HEALTH")" == "$VERSION" && "$(/usr/bin/plutil -extract build raw "$HEALTH")" == "$BUILD" ]] || { printf '%s\n' '就绪进程版本不匹配。' >&2; exit 1; }
    /bin/sleep 1
    [[ "$(exact_pids)" == "$PIDS" ]] || { printf '%s\n' '进程启动后未稳定存活。' >&2; exit 1; }
    printf '%s\n' "服务已自动启动并验证：${VERSION}（build ${BUILD}），唯一实例且原生扫描已就绪。"
    exit 0
  fi
  /bin/sleep 0.25
done
printf '%s\n' "服务未在45秒内就绪，请检查 $FOLDER/service.stderr.log；未宣称启动成功。" >&2
exit 1
