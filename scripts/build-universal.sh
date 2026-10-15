#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/bin/python3 -c 'import re,sys;print(re.search(r"VERSION=\"([^\"]+)\"",open(sys.argv[1]).read())[1])' "$ROOT/install.sh")"
BUILD="$(/usr/bin/python3 -c 'import re,sys;print(re.search(r"BUILD=\"([^\"]+)\"",open(sys.argv[1]).read())[1])' "$ROOT/install.sh")"
STAGE="$(mktemp -d)"
APP="$STAGE/Doubao Reply Notifier.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SDK="$(xcrun --show-sdk-path)"
for ARCH in arm64 x86_64; do
  swiftc -O -warnings-as-errors -sdk "$SDK" -target "${ARCH}-apple-macosx13.0" \
    -framework AppKit -framework UserNotifications -framework CryptoKit -framework ServiceManagement \
    "$ROOT/Sources/EventArchitecture.swift" "$ROOT/Sources/PermissionReviewSource.swift" \
    "$ROOT/Sources/ConversationTitleReader.swift" "$ROOT/Sources/IndexedDBInteractionReader.swift" \
    "$ROOT/Sources/main.swift" -o "$STAGE/$ARCH"
done
lipo -create "$STAGE/arm64" "$STAGE/x86_64" -output "$APP/Contents/MacOS/DoubaoReplyNotifier"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
python3 - "$APP/Contents/Info.plist" "$VERSION" "$BUILD" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f:
    plistlib.dump(dict(CFBundleName='Doubao Reply Notifier',CFBundleDisplayName='豆包回复通知',
        CFBundleIdentifier='com.local.doubao-reply-notifier',CFBundleVersion=sys.argv[3],
        CFBundleShortVersionString=sys.argv[2],CFBundlePackageType='APPL',CFBundleExecutable='DoubaoReplyNotifier',
        CFBundleIconFile='AppIcon.icns',LSUIElement=True,LSMinimumSystemVersion='13.0'),f)
PY
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
if [[ -e "$ROOT/Doubao Reply Notifier.app" ]]; then
  printf '%s\n' '构建输出已存在，请先检查旧产物，避免覆盖。' >&2
  exit 1
fi
cp -R "$APP" "$ROOT/Doubao Reply Notifier.app"
printf '%s\n' "built=$ROOT/Doubao Reply Notifier.app" "temporary_build=$STAGE"
