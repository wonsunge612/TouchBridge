#!/bin/zsh
# TouchBridge.app 번들 빌드 (ad-hoc 서명)
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/TouchBridge"
APP="build/TouchBridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TouchBridge"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 고정 인증서로 서명해야 재빌드 후에도 입력 모니터링/손쉬운 사용 권한이 유지된다.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
    echo "서명: $IDENTITY"
else
    codesign --force --sign - --timestamp=none "$APP"
    echo "⚠️  ad-hoc 서명 — 재빌드할 때마다 권한을 다시 허용해야 합니다"
fi
echo "✅ $APP"
