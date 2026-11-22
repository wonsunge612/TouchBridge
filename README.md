# TouchBridge

외장 USB 터치 모니터(브랜드 무관)의 터치를 선택한 모니터 영역에 매핑하는 macOS 메뉴 막대 앱.

## 빌드 / 실행
```sh
./build_app.sh            # → build/TouchBridge.app (ad-hoc 서명)
open build/TouchBridge.app
```
처음 실행하면 **입력 모니터링**과 **손쉬운 사용** 권한을 허용해야 합니다
(시스템 설정 › 개인정보 보호 및 보안). ad-hoc 서명은 빌드할 때마다 서명이 바뀌므로,
다시 빌드한 뒤에는 목록에서 TouchBridge를 지웠다가 다시 허용해야 할 수 있습니다.

## 배포
```sh
./release.sh 1.0.0         # universal 빌드 → Developer ID 서명(강화된 런타임) → 앱 공증·staple → DMG 서명·공증·staple
./release.sh 1.0.0 --dev   # 시험용: Apple Development 인증서로 서명, 공증 생략
./release.sh 1.0.0 --publish         # 빌드 후 v1.0.0 태그를 만들고 GitHub Releases에 DMG 업로드
./release.sh 1.0.0 --dev --publish   # 시험 빌드를 초안 + 사전 릴리스로 업로드
```
`--publish`는 커밋하지 않은 변경, push 안 된 커밋, 이미 있는 태그가 있으면 빌드를 시작하기 전에 멈춥니다.
결과물은 `dist/TouchBridge-<버전>.dmg`와 `.sha256` 파일입니다. 정식 배포에는 다음 두 가지를 한 번 준비해야 합니다.
1. Apple Developer Program에 가입한 뒤 **Developer ID Application** 인증서를 만듭니다 (Xcode › Settings › Accounts › Manage Certificates).
2. 공증 자격 증명을 키체인에 저장합니다:
   `xcrun notarytool store-credentials TouchBridgeNotary --apple-id <이메일> --team-id <팀ID> --password <앱 암호>`

샌드박스에서는 장치 독점, 이벤트 주입, 손쉬운 사용 API를 쓸 수 없어 Mac App Store로는 배포할 수 없습니다. 사용자는 첫 실행 때 입력 모니터링과 손쉬운 사용 권한을 허용해야 합니다.

## 동작 방식
| 단계 | 구현 |
|---|---|
| 감지 | `IOHIDManager`에서 Usage Page 0x0D / Usage 0x04 (Touch Screen) 매칭, VID 고정 없음. 연결/해제 콜백 실시간 처리 |
| 형제 인터페이스 | 대부분의 패널은 같은 USB 장치에 절대좌표 Mouse 인터페이스도 노출함 → VID/PID/LocationID가 같고 **절대좌표 X/Y**를 가진 포인터만 함께 엶. 상대좌표 마우스와 트랙패드는 건드리지 않음 |
| 가로채기 | 각 인터페이스를 `kIOHIDOptionsTypeSeizeDevice`로 독점해 macOS가 주 모니터 기준으로 커서를 움직이지 못하게 함. 실패하면 **호환 모드**로 전환: CGEventTap이 터치 리포트와 같은 시점에 들어온 시스템 이벤트만 삼킴 |
| 멀티터치 활성화 | 연결될 때 디지타이저 Feature 리포트(Contact Count Maximum 등)를 Windows처럼 읽음. ILITEK 등 일부 패널은 이 요청을 받아야 단일 터치(마우스) 모드에서 멀티터치 모드로 바뀜 |
| 파싱 | 리포트가 올 때마다 Finger 슬롯 전체를 읽어 Contact ID별로 모든 접점을 추적(Parallel/Hybrid 모드, Contact Count 반영). 디지타이저가 조용하면 포인터 인터페이스 값을 사용 |
| 제스처 | `GestureEngine`: 탭 = 처음 닿은 위치에서 클릭(10pt 이내 흔들림 무시). 움직이면 0.25초 동안 두 번째 손가락을 기다린 뒤 드래그, 가만히 0.35초 누르면 마우스 다운. 두 손가락 함께 이동 = 트랙패드식 스크롤(phase와 관성 포함), 벌리기/오므리기 = 핀치 줌(magnify 제스처, 처음 결정된 모드로 고정). **두 손가락 제스처 중과 끝난 직후 0.3초 동안은 클릭이 생기지 않음** |
| 스크롤 출력 | 대상 모니터 주사율(`NSScreen.displayLink`)에 맞춰 프레임마다 출력, 24ms 평활화. 패널(약 135Hz)과 모니터(144Hz) 주기 차이로 생기던 끊김 제거. 손을 떼면 같은 속도로 바로 관성 시작 |
| 창 활성화 | 터치가 시작될 때 손가락 아래 창이 키 창이 아니면 그 앱을 활성화하고 창을 올림(손쉬운 사용 API). 활성화가 끝날 때까지(최대 150ms) 출력을 모아 뒀다가 보냄. macOS는 비활성 창에 핀치 이벤트를 보내지 않고 첫 클릭을 활성화에만 쓰기 때문 |
| 매핑 | 패널 0…1 → 아핀 보정 → `CGDisplayBounds(대상)`. 이벤트마다 영역을 다시 읽고, `CGDisplayRegisterReconfigurationCallback`과 `didChangeScreenParameters`로 목록을 갱신 |
| 보정 | 4점을 최소제곱 아핀으로 풀어 회전·반전·축 교환·기울어짐까지 보정. 모니터와 회전 상태(`key@rotation`)별로 저장 |

## 메뉴
- 장치 상태 (독점 / 호환 모드)
- 터치 기능 켜기/끄기 (⌘T). 끄면 장치 독점을 풀고 macOS 기본 동작으로 돌아감
- 대상 모니터 목록 (재연결 후에도 vendor-model-serial로 기억)
- 핀치 줌 감도: 낮게 / 보통(기본) / 높게 / 손가락과 1:1. 출력 배율 = 손가락 간격 비율^감도(0.35 / 0.5 / 0.75 / 1.0)
- 4포인트 터치 보정… (⌘K, ESC 취소, R 다시 시작) / 보정 초기화
- 권한이 없으면 권한 안내 항목 표시
- 로그인 시 자동 실행 (`SMAppService`, 응용 프로그램 폴더에 설치한 뒤 켜는 것을 권장)
- 종료 (⌘Q)

## 진단
`~/Library/Logs/TouchBridge.log`에 권한, 장치 독점 결과, 좌표 경로(디지타이저인지 마우스 인터페이스인지), 매핑된 좌표, 클릭과 스크롤 판정이 기록됩니다.

## 한계
- 핀치 줌은 비공개 CGEvent 필드(type 29, field 110/113/132)로 만듭니다. 트랙패드 핀치를 지원하는 앱(Safari, 미리보기, 지도, 사진 등)에서 동작하며, macOS 업데이트로 바뀔 수 있습니다.
- 세 손가락 제스처와 회전은 지원하지 않습니다.
- 가만히 누른 채 시작하는 드래그는 0.35초 뒤에 시작됩니다. 두 손가락 탭 오른쪽 클릭은 기본으로 꺼져 있습니다(`Tuning.twoFingerTapRightClick`).
- 호환 모드에서는 터치하는 동안(그리고 직후 80ms) 실제 마우스 클릭도 무시되고, 마우스 클릭이 약 35ms 늦게 전달됩니다.
- 모니터를 회전한 경우, 그 회전 상태에서 한 번 보정해야 합니다.
