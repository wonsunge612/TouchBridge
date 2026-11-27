#!/bin/zsh
# 명령 한 번으로 빌드 확인 → 개인정보 검사 → 커밋 → GitHub push
#
# 사용법
#   ./commit.sh "핀치 감도 조정"     설명을 커밋 메시지로 사용
#   ./commit.sh                     바뀐 파일 이름으로 메시지 자동 생성
#   ./commit.sh -n "설명"           커밋만 하고 push는 하지 않음
#
# 커밋하지 않고 멈추는 경우
#   - 커밋 이메일이 GitHub noreply 주소가 아님 (개인 이메일이 기록에 남는 것 방지)
#   - 바뀐 내용에 이메일·인증서 ID·토큰처럼 보이는 값이 있음
#   - swift build 실패 (깨진 코드는 올리지 않음)
#   - rebase/merge 진행 중

set -euo pipefail
cd "${0:A:h}"

PUSH=true
if [[ "${1:-}" == "-n" || "${1:-}" == "--no-push" ]]; then PUSH=false; shift; fi
MESSAGE="${*:-}"

# 메시지에 %가 있어도 색 코드로 해석되지 않도록 색 부분만 -P로 출력
ok()   { print -nP "%F{green}✔%f "; print -r -- "$1"; }
info() { print -nP "%F{cyan}▶%f "; print -r -- "$1"; }
fail() { print -nP "%F{red}✖ "; print -nr -- "$1"; print -P "%f"; git reset -q 2>/dev/null || true; exit 1; }

# ---------- 상태 ----------
[[ -n "$(git status --porcelain)" ]] || { ok "바뀐 파일이 없습니다."; exit 0; }
GITDIR="$(git rev-parse --git-dir)"
[[ -d "$GITDIR/rebase-merge" || -d "$GITDIR/rebase-apply" || -f "$GITDIR/MERGE_HEAD" ]] && fail "rebase/merge가 진행 중입니다. 먼저 끝내세요."

EMAIL="$(git config user.email || true)"
[[ "$EMAIL" == *@users.noreply.github.com ]] || fail "커밋 이메일이 noreply 주소가 아닙니다: git config user.email <id>+<계정>@users.noreply.github.com"

git add -A
info "커밋할 변경"
git diff --cached --stat --no-color | sed 's/^/   /'

# ---------- 개인정보·비밀값 검사 (추가되는 줄만) ----------
info "개인정보·비밀값 검사"
# 일반 패턴 + 이 맥에서 실행 시점에 읽은 내 정보(전역 git 이메일, 서명 인증서 이름·ID).
# 내 정보를 스크립트에 적어 두면 그 자체가 저장소에 올라가므로 매번 읽어 온다.
PATTERNS=('@naver\.com' '@gmail\.com' '@daum\.net' '@kakao\.com' 'sk-[a-z]{2}-[0-9a-f]{8}' 'sk-ant-'
          'ghp_[A-Za-z0-9]{20,}' 'github_pat_' 'AKIA[0-9A-Z]{16}' '-----BEGIN [A-Z ]*PRIVATE KEY')
GLOBAL_EMAIL="$(git config --global user.email 2>/dev/null || true)"
[[ -n "$GLOBAL_EMAIL" && "$GLOBAL_EMAIL" != *noreply* ]] && PATTERNS+=("${GLOBAL_EMAIL//./\\.}")
for id in ${(f)"$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '\(([A-Z0-9]{10})\)' | tr -d '()' | sort -u)"}; do
    PATTERNS+=("$id")
done
LEAKS="$(git diff --cached -U0 --no-color -- . ':(exclude)commit.sh' \
    | grep -E '^\+[^+]' \
    | grep -Ei -- "${(j:|:)PATTERNS}" \
    | head -3 || true)"
if [[ -n "$LEAKS" ]]; then
    print -r -- "$LEAKS" | cut -c1-100 | sed 's/^/   /'
    fail "개인정보나 비밀값으로 보이는 내용이 있어 멈췄습니다. 지우거나 직접 확인한 뒤 git commit 하세요."
fi
ok "문제 없음"

# ---------- 빌드 ----------
info "빌드 확인 (swift build)"
if ! BUILD_LOG="$(swift build -c release 2>&1)"; then
    BUILD_LOG="$(print -r -- "$BUILD_LOG" | sed $'s/\x1b\\[[0-9;]*m//g')"   # 색상 코드 제거
    ERRS="$(print -r -- "$BUILD_LOG" | grep -E '\.swift:[0-9]+:[0-9]+: error:' | sort -u | head -5 || true)"
    [[ -z "$ERRS" ]] && ERRS="$(print -r -- "$BUILD_LOG" | grep -m3 'error:' || true)"
    print -r -- "$ERRS" | sed -E 's#^.*/(Sources/)#\1#; s/^/   /' | cut -c1-160
    fail "빌드가 실패해 커밋하지 않았습니다."
fi
ok "빌드 성공"

# ---------- 커밋 ----------
if [[ -z "$MESSAGE" ]]; then
    FILES=("${(@f)$(git diff --cached --name-only)}")
    NAMES=("${FILES[@]:t}")
    if (( ${#NAMES} <= 3 )); then
        MESSAGE="${(j:, :)NAMES} 수정"
    else
        MESSAGE="${(j:, :)NAMES[1,3]} 외 $(( ${#NAMES} - 3 ))개 파일 수정"
    fi
fi
git commit -q -m "$MESSAGE" || fail "git commit 실패"
ok "커밋 $(git rev-parse --short HEAD): $MESSAGE"

# ---------- push ----------
if $PUSH; then
    if git rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
        info "GitHub push"
        git push -q && ok "push 완료 ($(git rev-parse --abbrev-ref '@{u}'))" \
            || { print -P "%F{yellow}⚠ push 실패 — 커밋은 로컬에 남아 있습니다. 네트워크 확인 후 git push 하세요.%f"; exit 1; }
    else
        print -P "%F{yellow}⚠ 원격 브랜치가 없어 push하지 않았습니다 (git push -u origin <브랜치>).%f"
    fi
fi
