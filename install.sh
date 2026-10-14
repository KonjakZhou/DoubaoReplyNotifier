#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="4.6.0"
BUILD="11"
APP="$HOME/Applications/Doubao Reply Notifier.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
STAGE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doubao-reply-notifier.XXXXXX")"
STAGED_APP="$STAGE/Doubao Reply Notifier.app"
STAGED_CONTENTS="$STAGED_APP/Contents"
STAGED_MACOS="$STAGED_CONTENTS/MacOS"
STAGED_RESOURCES="$STAGED_CONTENTS/Resources"
trap '/bin/rm -rf "$STAGE"' EXIT

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

SWIFTC="$(/usr/bin/xcrun --find swiftc 2>/dev/null || true)"
SDKROOT="$(/usr/bin/xcrun --show-sdk-path 2>/dev/null || true)"
HOST_ARCH="$(/usr/bin/uname -m)"
if [[ "$HOST_ARCH" != "arm64" && "$HOST_ARCH" != "x86_64" ]]; then
  printf '%s\n' "不支持的 Mac 架构：$HOST_ARCH" >&2
  exit 1
fi
if [[ -z "$SWIFTC" || -z "$SDKROOT" ]]; then
  printf '%s\n' "未找到 Swift 编译器或 macOS SDK。请先安装 Apple Command Line Tools：xcode-select --install" >&2
  exit 1
fi

/bin/mkdir -p "$STAGED_MACOS" "$STAGED_RESOURCES"
"$SWIFTC" -O \
  -sdk "$SDKROOT" \
  -target "${HOST_ARCH}-apple-macosx13.0" \
  -framework AppKit \
  -framework UserNotifications \
  -framework CryptoKit \
  -framework ServiceManagement \
  "$ROOT/Sources/EventArchitecture.swift" \
  "$ROOT/Sources/PermissionReviewSource.swift" \
  "$ROOT/Sources/ConversationTitleReader.swift" \
  "$ROOT/Sources/IndexedDBInteractionReader.swift" \
  "$ROOT/Sources/main.swift" -o "$STAGED_MACOS/DoubaoReplyNotifier"
/bin/cp "$ROOT/assets/AppIcon.icns" "$STAGED_RESOURCES/AppIcon.icns"
/usr/bin/plutil -create xml1 "$STAGED_CONTENTS/Info.plist"
/usr/bin/plutil -insert CFBundleName -string "Doubao Reply Notifier" "$STAGED_CONTENTS/Info.plist"
/usr/bin/plutil -insert CFBundleDisplayName -string "豆包回复通知" "$STAGED_CONTENTS/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string "com.local.doubao-reply-notifier" "$STAGED_CONTENTS/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string "$BUILD" "$STAGED_CONTENTS/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$VERSION" "$STAGED_CONTENTS/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string "APPL" "$STAGED_CONTENTS/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string "DoubaoReplyNotifier" "$STAGED_CONTENTS/Info.plist"
/usr/bin/plutil -insert CFBundleIconFile -string "AppIcon.icns" "$STAGED_CONTENTS/Info.plist"
/usr/bin/plutil -insert LSUIElement -bool true "$STAGED_CONTENTS/Info.plist"
/usr/bin/codesign --force --deep --sign - "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"

if ! stop_previous; then
  printf '%s\n' "无法停止旧版通知器，请退出菜单栏中的旧通知器后重试。" >&2
  exit 1
fi

/bin/mkdir -p "$HOME/Applications"
/bin/rm -rf "$APP"
/bin/cp -R "$STAGED_APP" "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
INSTALLED_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$CONTENTS/Info.plist")"
INSTALLED_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw "$CONTENTS/Info.plist")"
if [[ "$INSTALLED_VERSION" != "$VERSION" || "$INSTALLED_BUILD" != "$BUILD" ]]; then
  printf '%s\n' "安装版本校验失败：期望 $VERSION ($BUILD)，实际 $INSTALLED_VERSION ($INSTALLED_BUILD)。" >&2
  exit 1
fi
if [[ "${DOUBAO_NOTIFIER_SKIP_LAUNCH:-0}" != "1" ]]; then
  /usr/bin/open -g "$APP"
fi
printf '%s\n' \
  "安装成功：$APP" \
  "版本：${VERSION}（build ${BUILD}）" \
  "架构：$(/usr/bin/file "$MACOS/DoubaoReplyNotifier" | /usr/bin/sed 's/.*: //')" \
  "监听方式：统一事件模型 + Resolver + 会话状态机（Saman 审阅/Toolcall/Blocker + trajectory + IndexedDB）"
