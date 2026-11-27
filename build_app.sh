#!/bin/zsh
# 개발용 TouchBridge.app 빌드 → build/TouchBridge.app
# 고정 인증서로 서명해야 재빌드 후에도 입력 모니터링/손쉬운 사용 권한이 유지된다.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="-"
    echo "⚠️  ad-hoc 서명 — 재빌드할 때마다 권한을 다시 허용해야 합니다"
else
    echo "서명: $IDENTITY"
fi
APP_ENTITLEMENTS=Resources/TouchBridge.entitlements \
    scripts/bundle-app.sh "$BIN_DIR" build/TouchBridge.app "$IDENTITY" "--timestamp=none"
echo "✅ build/TouchBridge.app"
