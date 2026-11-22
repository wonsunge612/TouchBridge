#!/bin/zsh
# TouchBridge 배포 빌드: universal 빌드 → Developer ID 서명(강화된 런타임) → 공증 → DMG
#
# 사용법
#   ./release.sh 1.0.0          정식 배포 (Developer ID 인증서 + 공증 자격 증명 필요)
#   ./release.sh 1.0.0 --dev    파이프라인 시험용: Apple Development 인증서로 서명, 공증 생략
#
# 처음 한 번 필요한 준비 (정식 배포)
#   1. Apple Developer Program 가입 후 Xcode › Settings › Accounts › Manage Certificates 에서
#      "Developer ID Application" 인증서 생성
#   2. 공증 자격 증명을 키체인에 저장 (앱 암호는 appleid.apple.com 에서 발급):
#        xcrun notarytool store-credentials TouchBridgeNotary \
#          --apple-id "you@example.com" --team-id "TEAMID" --password "앱 암호"
#
# 환경 변수 (선택)
#   SIGN_IDENTITY   서명 인증서 이름 (기본: 키체인에서 자동 탐색)
#   NOTARY_PROFILE  notarytool 키체인 프로필 이름 (기본: TouchBridgeNotary)
#
# 결과물: dist/TouchBridge-<버전>.dmg (+ .sha256)

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="TouchBridge"
VERSION="${1:-}"
MODE="${2:-release}"
NOTARY_PROFILE="${NOTARY_PROFILE:-TouchBridgeNotary}"

if [[ -z "$VERSION" || ! "$VERSION" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]]; then
    echo "사용법: ./release.sh <버전> [--dev]   예) ./release.sh 1.0.0"; exit 1
fi
DEV=false
[[ "$MODE" == "--dev" ]] && DEV=true

step() { print -P "\n%F{cyan}▶ $1%f"; }
fail() { print -P "\n%F{red}✖ $1%f"; exit 1; }

# ---------- 서명 인증서 ----------
step "서명 인증서 확인"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    if $DEV; then
        SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
    else
        SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
    fi
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    $DEV && fail "Apple Development 인증서가 없습니다."
    fail "Developer ID Application 인증서가 없습니다.
   Apple Developer Program 가입 후 Xcode › Settings › Accounts › Manage Certificates 에서 만드세요.
   인증서 없이 파이프라인만 시험하려면:  ./release.sh $VERSION --dev"
fi
echo "   $SIGN_IDENTITY"
if ! $DEV; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || fail "공증 자격 증명 '$NOTARY_PROFILE' 을(를) 찾을 수 없습니다.
   xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <이메일> --team-id <팀ID> --password <앱 암호>"
fi

# ---------- 빌드 ----------
step "universal 빌드 (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -vE "x86_64 architecture is deprecated" | tail -3
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"
ARCHS="$(lipo -archs "$BIN")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || fail "universal 바이너리가 아닙니다: $ARCHS"
echo "   아키텍처: $ARCHS"

# ---------- 앱 번들 ----------
step "앱 번들 구성 (버전 $VERSION)"
OUT="dist"
STAGE="$OUT/stage"
APP="$STAGE/$APP_NAME.app"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
echo "   CFBundleShortVersionString=$VERSION  CFBundleVersion=$BUILD_NUMBER"

# ---------- 서명 ----------
step "서명 (강화된 런타임)"
TS="--timestamp"; $DEV && TS="--timestamp=none"
codesign --force --options runtime $TS --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/   /'
codesign -d --verbose=2 "$APP" 2>&1 | grep -E "^(Authority|Runtime Version|flags)" | head -3 | sed 's/^/   /'

notarize() {   # $1: 제출할 파일
    local log="$OUT/notary-$(basename "$1").json"
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$log" || true
    local st id
    st="$(/usr/bin/plutil -extract status raw -o - "$log" 2>/dev/null || echo unknown)"
    id="$(/usr/bin/plutil -extract id raw -o - "$log" 2>/dev/null || echo)"
    if [[ "$st" != "Accepted" ]]; then
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
        fail "공증 실패 (status: $st)"
    fi
    echo "   공증 통과 (id $id)"
}

# ---------- 앱 공증 + staple (오프라인에서도 Gatekeeper 통과) ----------
if ! $DEV; then
    step "앱 공증 (수 분 걸릴 수 있음)"
    ditto -c -k --keepParent "$APP" "$OUT/$APP_NAME-notarize.zip"
    notarize "$OUT/$APP_NAME-notarize.zip"
    rm -f "$OUT/$APP_NAME-notarize.zip"
    xcrun stapler staple "$APP" | tail -1 | sed 's/^/   /'
fi

# ---------- DMG ----------
step "DMG 만들기"
DMG="$OUT/$APP_NAME-$VERSION.dmg"
$DEV && DMG="$OUT/$APP_NAME-$VERSION-dev.dmg"
ln -sfn /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force $TS --sign "$SIGN_IDENTITY" "$DMG"

if ! $DEV; then
    step "DMG 공증"
    notarize "$DMG"
    xcrun stapler staple "$DMG" | tail -1 | sed 's/^/   /'
fi

# ---------- 확인 ----------
step "확인"
if $DEV; then
    echo "   --dev: 공증하지 않았으므로 다른 맥에서는 Gatekeeper 경고가 뜹니다 (시험용)."
else
    spctl -a -t exec -vv "$APP" 2>&1 | sed 's/^/   /'
    spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/   /'
fi
shasum -a 256 "$DMG" | tee "$DMG.sha256" | sed 's/^/   sha256 /'
rm -rf "$STAGE"
print -P "\n%F{green}✅ $DMG%f"
