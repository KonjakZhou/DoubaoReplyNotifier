#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="4.7.2"
BUILD="16"
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
  local service="gui/$(/usr/bin/id -u)/com.local.doubao-reply-notifier.agent"
  if /bin/launchctl print "$service" >/dev/null 2>&1; then
    /bin/launchctl bootout "$service" || return 1
  fi
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

PREBUILT_APP="$ROOT/Doubao Reply Notifier.app"
HOST_ARCH="$(/usr/bin/uname -m)"
if [[ "$HOST_ARCH" != "arm64" && "$HOST_ARCH" != "x86_64" ]]; then
  printf '%s\n' "不支持的 Mac 架构：$HOST_ARCH" >&2
  exit 1
fi

if [[ -d "$PREBUILT_APP" ]]; then
  /bin/cp -R "$PREBUILT_APP" "$STAGED_APP"
  PREBUILT_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$STAGED_CONTENTS/Info.plist")"
  PREBUILT_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw "$STAGED_CONTENTS/Info.plist")"
  if [[ "$PREBUILT_VERSION" != "$VERSION" || "$PREBUILT_BUILD" != "$BUILD" ]]; then
    printf '%s\n' "分发包版本校验失败：期望 $VERSION ($BUILD)，实际 $PREBUILT_VERSION ($PREBUILT_BUILD)。" >&2
    exit 1
  fi
  /usr/bin/codesign --verify --deep --strict "$STAGED_APP"
  if ! /usr/bin/file "$STAGED_MACOS/DoubaoReplyNotifier" | /usr/bin/grep -q "$HOST_ARCH"; then
    printf '%s\n' "分发包不包含当前 Mac 架构：$HOST_ARCH" >&2
    exit 1
  fi
else
  SWIFTC="$(/usr/bin/xcrun --find swiftc 2>/dev/null || true)"
  SDKROOT="$(/usr/bin/xcrun --show-sdk-path 2>/dev/null || true)"
  if [[ -z "$SWIFTC" || -z "$SDKROOT" ]]; then
    printf '%s\n' "未找到预编译 App，且本机缺少 Apple Command Line Tools。请使用完整分发包，或执行 xcode-select --install。" >&2
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
fi

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
  if ! /bin/bash "$ROOT/scripts/manage-service.sh" start "$APP" "$HOME" "$VERSION" "$BUILD"; then
    printf '%s\n' '新版文件已安装，但服务启动验证失败；未宣称启动成功。' >&2
    exit 1
  fi
fi
printf '%s\n' \
  "安装成功：$APP" \
  "版本：${VERSION}（build ${BUILD}）" \
  "架构：$(/usr/bin/file "$MACOS/DoubaoReplyNotifier" | /usr/bin/sed 's/.*: //')" \
  "监听方式：统一事件模型 + Resolver + 会话状态机（Saman 审阅/Toolcall/Blocker + trajectory + IndexedDB）"
