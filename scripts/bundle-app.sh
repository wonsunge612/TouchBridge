#!/bin/zsh
# 빌드된 바이너리로 TouchBridge.app 을 구성하고 서명한다. (build_app.sh, release.sh 공용)
#
#   scripts/bundle-app.sh <바이너리 폴더> <출력 .app> <서명 인증서|-> <timestamp 옵션> [버전] [빌드 번호]
#
# 서명 순서는 Sparkle 문서대로 안쪽 구성 요소부터:
#   XPC 서비스(Installer, Downloader) → Autoupdate → Updater.app → Sparkle.framework → 앱
# --deep 서명은 Downloader.xpc 의 entitlements 를 지워 버리므로 쓰지 않는다.

set -euo pipefail
BIN_DIR="$1"; APP="$2"; IDENTITY="$3"; TS="$4"; VERSION="${5:-}"; BUILD="${6:-}"
ROOT="${0:A:h:h}"
NAME="TouchBridge"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/$NAME" "$APP/Contents/MacOS/$NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"   # 심볼릭 링크 보존

PLIST="$APP/Contents/Info.plist"
[[ -n "$VERSION" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
[[ -n "$BUILD" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"

sign() { codesign --force --options runtime $TS --sign "$IDENTITY" "$@"; }
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SP/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
sign "$SP/Autoupdate"
sign "$SP/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP"

codesign --verify --deep --strict "$APP"
