#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="4.2.0"
APP="$HOME/Applications/Doubao Reply Notifier.app"
PREBUILT="$ROOT/Doubao Reply Notifier.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

stop_previous() {
  local pids
  pids="$(/usr/bin/pgrep -f "$MACOS/DoubaoReplyNotifier" || true)"
  [[ -z "$pids" ]] && return 0
  for pid in $pids; do /bin/kill -TERM "$pid" 2>/dev/null || true; done
  for _ in {1..20}; do
    pids="$(/usr/bin/pgrep -f "$MACOS/DoubaoReplyNotifier" || true)"
    [[ -z "$pids" ]] && return 0
    /bin/sleep 0.1
  done
  for pid in $pids; do /bin/kill -KILL "$pid" 2>/dev/null || true; done
  /bin/sleep 0.2
  pids="$(/usr/bin/pgrep -f "$MACOS/DoubaoReplyNotifier" || true)"
  [[ -z "$pids" ]]
}

if ! stop_previous; then
  printf '%s\n' "无法停止旧版通知器，请退出菜单栏中的旧通知器后重试。" >&2
  exit 1
fi

/bin/mkdir -p "$HOME/Applications"
if [[ -d "$PREBUILT" ]]; then
  /bin/rm -rf "$APP"
  /bin/cp -R "$PREBUILT" "$APP"
else
  /bin/mkdir -p "$MACOS" "$RESOURCES"
  /usr/bin/swiftc -O \
    -framework AppKit \
    -framework UserNotifications \
    -framework CryptoKit \
    -framework ServiceManagement \
    "$ROOT/Sources/ConversationTitleReader.swift" \
    "$ROOT/Sources/main.swift" -o "$MACOS/DoubaoReplyNotifier"
  /bin/cp "$ROOT/assets/AppIcon.icns" "$RESOURCES/AppIcon.icns"
  /usr/bin/plutil -create xml1 "$CONTENTS/Info.plist"
  /usr/bin/plutil -insert CFBundleName -string "Doubao Reply Notifier" "$CONTENTS/Info.plist"
  /usr/bin/plutil -insert CFBundleDisplayName -string "豆包回复通知" "$CONTENTS/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "com.local.doubao-reply-notifier" "$CONTENTS/Info.plist"
  /usr/bin/plutil -insert CFBundleVersion -string "6" "$CONTENTS/Info.plist"
  /usr/bin/plutil -insert CFBundleShortVersionString -string "$VERSION" "$CONTENTS/Info.plist"
  /usr/bin/plutil -insert CFBundlePackageType -string "APPL" "$CONTENTS/Info.plist"
  /usr/bin/plutil -insert CFBundleExecutable -string "DoubaoReplyNotifier" "$CONTENTS/Info.plist"
  /usr/bin/plutil -insert CFBundleIconFile -string "AppIcon.icns" "$CONTENTS/Info.plist"
  /usr/bin/plutil -insert LSUIElement -bool true "$CONTENTS/Info.plist"
  /usr/bin/codesign --force --deep --sign - "$APP"
fi

/usr/bin/codesign --verify --deep --strict "$APP"
INSTALLED_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$CONTENTS/Info.plist")"
if [[ "$INSTALLED_VERSION" != "$VERSION" ]]; then
  printf '%s\n' "安装版本校验失败：期望 $VERSION，实际 $INSTALLED_VERSION。" >&2
  exit 1
fi
/usr/bin/open -g "$APP"
printf '%s\n' \
  "安装并启动成功：$APP" \
  "版本：$VERSION" \
  "监听方式：豆包主进程任务 blocker + 主 Agent 明确交互事件（不使用 DOM、CDP 或辅助功能）"
