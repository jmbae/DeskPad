# DeskPad 수정 및 통합 기록 — 2026-10-19

## 기준과 보존

점검 당시 로컬 HEAD는 `cca257c`였으나, 원격 main에는 앱 구조를 전면 교체한 `1467afa`가 있었다. 최신 upstream 구조를 기준으로 세 수정 브랜치를 만들고 기존 IME·인증 요구사항을 새 구조에 반영했다. 이전 구현 전체를 되살리면 최신 구조와 중복되므로, 로컬 과거 이력은 새 구조를 유지하는 병합으로 연결했다.

기존 미커밋 인증 수정과 최초 점검 문서는 `codex/preserve-local-auth-20261019` (`7ba99b0`)에 보존했다. 이후 같은 폴더에 추가된 인증 수정도 `codex/preserve-local-auth-latest-20261019` (`4fa4445`)에 따로 보존했다. 원본 코드가 필요하면 이 브랜치에서 확인할 수 있다. 두 선택의 비용은 구형 구현에만 있던 동작을 새 구조에 별도로 포팅해야 한다는 점이며, IME 회귀 테스트와 인증 wire-format 테스트로 핵심 동작을 검증했다.

## PR

- [#2 저장 정보의 안전한 마이그레이션](https://github.com/nedpark/DeskPad/pull/2): 기존 JSON/AppStorage → Keychain, 중단/실패 복구, 기존 값 보존, 손상 파일 덮어쓰기 방지.
- [#3 연결 및 프로토콜 안정화](https://github.com/nedpark/DeskPad/pull/3): 세션 격리, 취소/종료, 실제 첫 픽셀과 timeout, 인증 실패, 입력 순서, 명시적 clipboard API, resize 중 입력 해제.
- [#4 iPad 입력과 화면 조작](https://github.com/nedpark/DeskPad/pull/4): IME·Unicode·물리 키보드, viewport 조작, 클립보드 UI, 오류 표시, 테스트 타깃. #3에 의존하며 해당 커밋을 포함한다.

원격 PR은 열린 상태이며 원격 main에는 병합하지 않았다. 요청에 따라 로컬 main에 통합한다. 기존 PR #1은 자동 종료하지 않았다.

## 검증과 제한

- 저장소 실패 복구 시나리오 11개.
- 실제 loopback TCP 세션 시나리오 12개: 인증, 취소/재접속, 실제 첫 프레임, 잘못된 좌표, deadline, clipboard, 순서 보장, resize 중 해제.
- UIKit 입력 16케이스: XCTest 5개와 파라미터 확장 IME 11개.
- Xcode 27.1에서 원래 iOS 27 deployment 설정의 unsigned Release 기기 빌드.
- 설치된 시뮬레이터는 iOS 26.5라 UIKit 테스트 때만 deployment를 임시 조정하고 복원했다.

이 결과는 실물 iPad의 한글 IME/키보드/트랙패드, 실제 Mac 화면 공유 및 서명된 설치 패키지를 검증한 것은 아니다. 압축 인코딩, 서버 커서 모양, Unicode 확장 클립보드는 아직 지원하지 않는다. 기본 클립보드는 Latin-1/1MiB 제한을 UI에 명시한다. 고해상도 장시간 성능은 실환경 측정이 필요하다.

재현 명령은 `docs/TESTING.md`, `Tests/Storage/README.md`, `Tests/Session/README.md`에 있다.

## 후속 실제 연결 QA

이 문서의 과거 검증 기록은 유지한다. 이후 PR #5·#6 통합 및 실제 Mac 연결에서 확인한 입력 동작, 남은 성능 문제와 보류 항목은 [2026-10-20 실제 연결 QA](LIVE-QA-2026-10-20.md)에 기록했다.
