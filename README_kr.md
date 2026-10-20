# DeskPad

DeskPad는 iPhone 및 iPad용 네이티브 SwiftUI VNC 클라이언트입니다. 서버 연결 정보를 저장하고, 원격 데스크톱을 보거나 터치·키보드·포인터로 조작할 수 있습니다.

[English](README.md)

<p align="left">
  <img src="AppIcon.png" alt="DeskPad 앱 아이콘" width="120" />
</p>

## 주요 기능

- 표시 이름, 호스트, 포트, 선택적 사용자 이름으로 연결을 추가·편집·삭제
- 연결 메타데이터는 앱에 저장하고 암호는 iOS 키체인에 저장하며, 기존 연결 데이터 마이그레이션 지원
- VNC 서버와 RFB 3.3, 3.7, 3.8 협상
- 서버가 제공하는 경우 None, 표준 VNC 암호, Apple Diffie–Hellman 인증 지원
- Raw, CopyRect, DesktopSize, ZRLE 프레임버퍼 업데이트 디코딩 및 원격 커서 지원
- 화면 맞춤 또는 실제 크기로 보기, 핀치 확대/축소 및 화면 이동
- 터치 또는 호환 포인터/트랙패드를 통한 포인터 이동, 클릭, 드래그, 스크롤, 보조 클릭
- 소프트웨어·하드웨어 키보드로 텍스트, 키 조합, 특수 키 전송 및 한국어를 포함한 IME 조합 입력 지원
- 기존 RFB Latin-1 텍스트 클립보드 송수신(최대 1MiB)
- 풀 컬러 또는 저지연 화면 품질 선택, 연결 오류 표시 및 재시도

## 보안 및 제한 사항

DeskPad는 일반 RFB 세션에 TLS 또는 전송 암호화를 제공하지 않습니다. 인증을 사용해도 세션 자체는 암호화되지 않으므로 원격 화면 내용과 입력 데이터가 전송 중 보호되지 않습니다. 표준 VNC 암호 인증은 취약한 DES 기반 챌린지-응답 방식을 사용하며, None 보안 방식은 인증을 제공하지 않습니다. Apple Diffie–Hellman 인증도 이후의 모든 RFB 트래픽을 암호화하지 않습니다. 신뢰할 수 있는 사설 네트워크나 VPN을 통해서만 DeskPad를 사용하고, VNC 서버를 인터넷에 직접 노출하지 마세요.

클립보드는 기존 RFB Latin-1 텍스트로 제한되며, 확장 Unicode 클립보드 인코딩은 협상하지 않습니다. 키보드 텍스트 입력에는 RFB keysym 및 서버의 제약이 있습니다. 포인터 및 제스처 기능은 기기와 입력 방식에 따라 달라질 수 있습니다.

`DeskPad/HighPerformance/`의 Apple 전용 고성능 미디어 코드는 실험 단계이며, 정식 배포 준비가 되었거나 일반적으로 지원되는 기능이 아닙니다. 화면 재생, 오디오/비디오 동기화, 안정적인 연결 종료 처리 및 디스플레이 복구는 검증되지 않았습니다. [실험 상태 문서](docs/HP-EXPERIMENT-STATUS.md)를 참고하고, 일반 연결에 이 경로를 사용하지 마세요.

## 요구 사항

- Xcode 27 이상
- iOS/iPadOS 27.0 이상(현재 Xcode 프로젝트의 최소 배포 대상)
- iPhone 또는 iPad

## 시작하기

1. 이 저장소를 복제합니다.
2. Xcode에서 `DeskPad.xcodeproj`를 엽니다.
3. iPhone 또는 iPad 시뮬레이터나 연결된 기기를 선택합니다.
4. `DeskPad` 앱을 빌드하고 실행합니다.
5. VNC 서버 연결을 추가합니다. 기본 포트는 `5900`입니다.

테스트·빌드 명령, 시뮬레이터 관련 참고 사항, 독립 프로토콜 하네스는 [docs/TESTING.md](docs/TESTING.md)를 참고하세요.

## 프로젝트 구조

- `DeskPad/App/`: 앱 진입점
- `DeskPad/Connections/`: 저장된 연결 메타데이터, 레거시 마이그레이션, 키체인 자격 증명
- `DeskPad/Models/`: 앱 데이터 모델
- `DeskPad/UI/`: 연결 목록/편집, 세션 UI, 원격 화면, 포인터 및 키보드 입력
- `DeskPad/VNC/`: RFB 세션과 입력 대기열, 프레임버퍼 디코딩, 커서 지원 및 프로토콜 처리
- `DeskPad/HighPerformance/`: 실험 단계인 Apple 전용 미디어 인증, 전송, 디코딩 및 재생
- `DeskPad/Assets.xcassets/`: 앱 아이콘 및 포인트 색상
- `DeskPadTests/`: 원격 입력, 렌더링 및 IME 동작을 검증하는 Xcode 테스트
- `Tests/`: 독립 프로토콜·저장소·미디어 테스트 하네스

## 기여하기

이슈와 풀 리퀘스트를 환영합니다. 큰 변경 사항은 먼저 이슈를 열어 범위와 구현 방향을 논의해 주세요.

## 크레딧

- [Ned Park](https://africastart.com)

## 라이선스

[MIT](LICENSE) 라이선스로 제공됩니다.
