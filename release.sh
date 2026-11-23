#!/bin/zsh
# TouchBridge 배포 빌드: universal 빌드 → Developer ID 서명(강화된 런타임) → 공증 → DMG
#
# 사용법
#   ./release.sh 1.0.0          정식 배포 (Developer ID 인증서 + 공증 자격 증명 필요)
#   ./release.sh 1.0.0 --dev    파이프라인 시험용: Apple Development 인증서로 서명, 공증 생략
#   ./release.sh 1.0.0 --publish         빌드 후 GitHub Releases에 v1.0.0으로 업로드
#   ./release.sh 1.0.0 --dev --publish   시험 빌드를 '초안 + 사전 릴리스'로 업로드 (공개되지 않음)
#   ./release.sh 1.0.0 --dev --public    공증 없는 빌드를 바로 정식(최신) 릴리스로 공개 (--publish 포함)
#                                        고정 다운로드 링크가 이 버전을 가리키고, 노트에 '그래도 열기' 안내가 들어간다
#
# --publish 조건: gh 로그인, 커밋 안 된 변경 없음, 현재 커밋이 원격에 push됨, 같은 버전 태그 없음
#   (공증처럼 오래 걸리는 단계 전에 미리 확인한다)
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
#   DOWNLOAD_BASE   appcast 안 DMG 다운로드 주소의 앞부분 (기본: GitHub 릴리스 주소. 로컬 업데이트 시험용)
#
# Sparkle 자동 업데이트: DMG를 EdDSA 키로 서명해 dist/appcast.xml 을 만들고, --publish 시 릴리스에 함께 올린다.
#   앱은 releases/latest/download/appcast.xml 을 확인하므로 항상 최신 릴리스의 appcast 가 쓰인다.
#   서명 키는 로그인 키체인에 있으며(.build/artifacts/sparkle/Sparkle/bin/generate_keys), 잃어버리면
#   기존 사용자에게 업데이트를 보낼 수 없으니 generate_keys -x <파일> 로 내보내 안전한 곳에 백업할 것.
#
# 결과물: dist/TouchBridge-<버전>.dmg (+ .sha256)
# --publish는 버전 없는 TouchBridge.dmg도 함께 올린다 → 항상 최신을 가리키는 고정 링크:
#   https://github.com/<소유자>/<저장소>/releases/latest/download/TouchBridge.dmg

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="TouchBridge"
VERSION="${1:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-TouchBridgeNotary}"

if [[ -z "$VERSION" || ! "$VERSION" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]]; then
    echo "사용법: ./release.sh <버전> [--dev] [--publish] [--public]   예) ./release.sh 1.0.0 --publish"; exit 1
fi
DEV=false
PUBLISH=false
PUBLIC=false
for arg in "${@:2}"; do
    case "$arg" in
        --dev) DEV=true ;;
        --publish) PUBLISH=true ;;
        --public) PUBLIC=true; PUBLISH=true ;;
        *) echo "알 수 없는 옵션: $arg"; exit 1 ;;
    esac
done
TAG="v$VERSION"
# 초안 + 사전 릴리스로 올릴지: --dev 이면서 --public 이 아닐 때만
DRAFT=false
$DEV && ! $PUBLIC && DRAFT=true
if $PUBLIC && ! $DEV; then echo "--public 은 --dev 와 함께 씁니다 (정식 빌드는 --publish 만으로 공개됩니다)."; exit 1; fi

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

# ---------- Sparkle 서명 키 ----------
step "Sparkle 업데이트 서명 키 확인"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/sign_update" ]] || swift package resolve >/dev/null
KEYCHAIN_PUB="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null)" || fail "Sparkle 서명 키가 키체인에 없습니다.
   새로 만들려면: $SPARKLE_BIN/generate_keys   (만든 공개 키를 Resources/Info.plist 의 SUPublicEDKey 에 넣기)"
PLIST_PUB="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)"
[[ "$KEYCHAIN_PUB" == "$PLIST_PUB" ]] || fail "키체인의 Sparkle 키와 Info.plist 의 SUPublicEDKey 가 다릅니다. 이대로 배포하면 업데이트가 거부됩니다."
echo "   공개 키 일치 (${PLIST_PUB[1,12]}…)"
REPO_SLUG="$(git remote get-url origin 2>/dev/null | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')"

# ---------- GitHub 업로드 사전 확인 ----------
if $PUBLISH; then
    step "GitHub 업로드 사전 확인"
    GH="$(command -v gh || true)"
    [[ -z "$GH" && -x "$HOME/.local/bin/gh" ]] && GH="$HOME/.local/bin/gh"
    [[ -n "$GH" ]] || fail "gh(GitHub CLI)가 없습니다."
    "$GH" auth status >/dev/null 2>&1 || fail "gh 로그인이 필요합니다:  gh auth login"
    REPO="$("$GH" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || fail "GitHub 저장소를 찾을 수 없습니다 (origin 원격 확인)."
    [[ -z "$(git status --porcelain)" ]] || fail "커밋하지 않은 변경이 있습니다. 릴리스는 커밋된 코드로만 만듭니다."
    git fetch -q origin
    BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    git rev-parse -q --verify "origin/$BRANCH" >/dev/null || fail "원격에 '$BRANCH' 브랜치가 없습니다. 먼저 git push 하세요."
    [[ "$(git rev-list --count "origin/$BRANCH..HEAD")" == 0 ]] || fail "push 안 된 커밋이 있습니다. 먼저 git push 하세요."
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
        fail "태그 $TAG 이(가) 이미 있습니다. 버전을 올리세요."
    fi
    echo "   $REPO · $BRANCH @ $(git rev-parse --short HEAD) → $TAG"
fi

# ---------- 빌드 ----------
step "universal 빌드 (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -vE "x86_64 architecture is deprecated" | tail -3
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"
ARCHS="$(lipo -archs "$BIN")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || fail "universal 바이너리가 아닙니다: $ARCHS"
echo "   아키텍처: $ARCHS"

# ---------- 앱 번들 + 서명 ----------
step "앱 번들 구성 + 서명 (버전 $VERSION, 강화된 런타임)"
OUT="dist"
STAGE="$OUT/stage"
APP="$STAGE/$APP_NAME.app"
rm -rf "$STAGE"
mkdir -p "$STAGE"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
TS="--timestamp"; $DEV && TS="--timestamp=none"
scripts/bundle-app.sh "${BIN:h}" "$APP" "$SIGN_IDENTITY" "$TS" "$VERSION" "$BUILD_NUMBER"
echo "   CFBundleShortVersionString=$VERSION  CFBundleVersion=$BUILD_NUMBER"
codesign -d --verbose=2 "$APP" 2>&1 | grep -E "^Authority" | head -1 | sed 's/^/   /'
codesign -d --verbose=2 "$APP" 2>&1 | grep -oE "flags=0x[0-9a-f]+\([a-z,-]+\)" | sed 's/^/   /'
echo "   Sparkle $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Frameworks/Sparkle.framework/Resources/Info.plist") 포함"

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

# ---------- Sparkle appcast ----------
step "업데이트 정보 (appcast.xml)"
SIG_ATTRS="$("$SPARKLE_BIN/sign_update" "$DMG")"     # sparkle:edSignature="…" length="…"
DMG_URL="${DOWNLOAD_BASE:-https://github.com/$REPO_SLUG/releases/download/$TAG}/$(basename "$DMG")"
NOTES_LINK=""
[[ -z "${DOWNLOAD_BASE:-}" ]] && NOTES_LINK="      <sparkle:releaseNotesLink>https://github.com/$REPO_SLUG/releases/tag/$TAG</sparkle:releaseNotesLink>"
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP_NAME</title>
    <item>
      <title>$APP_NAME $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
$NOTES_LINK
      <enclosure url="$DMG_URL" type="application/octet-stream" $SIG_ATTRS />
    </item>
  </channel>
</rss>
XML
xmllint --noout "$OUT/appcast.xml" || fail "appcast.xml 형식 오류"
echo "   $OUT/appcast.xml → $DMG_URL"

# ---------- 확인 ----------
step "확인"
if $DEV; then
    echo "   --dev: 공증하지 않았으므로 다른 맥에서는 Gatekeeper 경고가 뜹니다 (시험용)."
else
    spctl -a -t exec -vv "$APP" 2>&1 | sed 's/^/   /'
    spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/   /'
fi
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")") | tee "$DMG.sha256" | sed 's/^/   sha256 /'
rm -rf "$STAGE"

# ---------- GitHub Releases 업로드 ----------
if $PUBLISH; then
    step "GitHub Releases 업로드 ($TAG)"
    git tag -a "$TAG" -m "$APP_NAME $VERSION"
    git push -q origin "$TAG"
    # 고정 링크용 사본 (releases/latest/download/TouchBridge.dmg)
    LATEST_DMG="$OUT/$APP_NAME.dmg"
    cp "$DMG" "$LATEST_DMG"
    LATEST_URL="https://github.com/$REPO/releases/latest/download/$APP_NAME.dmg"
    NOTES="$OUT/release-notes.md"
    {
        $DRAFT && echo "> ⚠️ 시험 빌드입니다. 공증되지 않아 다른 맥에서는 Gatekeeper 경고가 뜹니다.\n"
        $DRAFT || echo "**바로 받기:** [$APP_NAME.dmg]($LATEST_URL) (항상 최신 버전)\n"
        echo "## 설치"
        echo "1. \`$(basename "$DMG")\`을 열고 TouchBridge를 응용 프로그램 폴더로 끌어다 놓습니다."
        echo "2. 처음 실행할 때 **입력 모니터링**과 **손쉬운 사용** 권한을 허용합니다 (시스템 설정 › 개인정보 보호 및 보안)."
        echo "3. 메뉴 막대 아이콘에서 대상 모니터를 고르고, 필요하면 **로그인 시 자동 실행**을 켭니다."
        echo ""
        if $DEV; then   # 공증 안 된 빌드: Gatekeeper '그래도 열기' 안내 (README와 같은 내용)
            echo "### \"확인할 수 없는 개발자\" 경고가 뜰 때"
            echo "이 빌드는 Apple 공증을 받지 않아 처음 열 때 경고가 뜹니다. 한 번만 허용하면 이후에는 바로 열립니다."
            echo ""
            echo "1. 응용 프로그램 폴더의 TouchBridge를 엽니다. 경고 창이 뜨면 **완료**(또는 **취소**)를 누릅니다."
            echo "2. **시스템 설정 › 개인정보 보호 및 보안**을 열고 맨 아래 보안 항목으로 내려갑니다."
            echo "3. \"TouchBridge이(가) 확인된 개발자가 아니므로 차단되었습니다\" 옆의 **그래도 열기**를 누르고, 암호(또는 Touch ID)로 확인합니다."
            echo "4. 다시 뜨는 창에서 **열기**를 누릅니다."
            echo ""
            echo "macOS 13·14에서는 Finder에서 앱을 Control-클릭(우클릭) › **열기**로도 같은 효과를 낼 수 있습니다."
            echo ""
        fi
        echo "문제가 있으면 \`~/Library/Logs/TouchBridge.log\`를 첨부해 이슈로 알려 주세요."
        echo ""
        echo "SHA-256: \`$(awk '{print $1}' "$DMG.sha256")\`"
    } > "$NOTES"
    FLAGS=()
    if $DRAFT; then FLAGS=(--draft --prerelease); else FLAGS=(--latest); fi
    URL="$("$GH" release create "$TAG" "$DMG" "$DMG.sha256" "$LATEST_DMG" "$OUT/appcast.xml" --title "$APP_NAME $VERSION$($DRAFT && echo ' (시험 빌드)')" \
        --notes-file "$NOTES" --generate-notes --verify-tag "${FLAGS[@]}")" || {
        echo "   업로드 실패 — 만든 태그를 되돌립니다."
        git push -q origin ":refs/tags/$TAG" || true
        git tag -d "$TAG" >/dev/null || true
        fail "GitHub 릴리스 생성 실패"
    }
    rm -f "$NOTES" "$LATEST_DMG"
    echo "   $URL"
    $DRAFT || echo "   고정 다운로드 링크: $LATEST_URL"
    $DRAFT && echo "   (초안 + 사전 릴리스: GitHub에서 확인 후 직접 게시하거나 삭제하세요)"
fi
print -P "\n%F{green}✅ $DMG%f"
