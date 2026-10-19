# DeskPad

DeskPad는 SwiftUI로 제작된 iPhone 및 iPad용 네이티브 VNC 클라이언트입니다. VNC 서버 연결 정보를 저장하고, 원격 데스크톱에 연결해 터치나 키보드로 조작할 수 있습니다.

<p align="left">
  <img src="AppIcon.png" alt="DeskPad 앱 아이콘" width="120" />
</p>

## 주요 기능

- 서버 이름, 호스트, 포트, 선택적 사용자 이름을 설정해 VNC 연결 추가·편집·삭제
- 연결 정보는 앱에 저장하고 암호는 iOS 키체인에 안전하게 저장
- RFB 3.3–3.8 버전 협상을 통한 VNC 서버 연결
- None, 표준 VNC 암호, Apple Diffie–Hellman 인증 보안 방식 지원
- Raw, CopyRect, DesktopSize 프레임버퍼 업데이트 렌더링
- 원격 데스크톱 화면에서 포인터 이동, 클릭, 드래그 입력 전송
- 소프트웨어 키보드 또는 하드웨어 키보드로 텍스트와 일반적인 특수 키 입력 전송
- 연결 진행 상황 및 실패 표시, 재시도 기능 제공

## 보안 및 제한 사항

DeskPad는 TLS 암호화를 제공하지 않습니다. 인증을 사용해도 VNC 세션 자체는 암호화되지 않으므로 원격 화면 내용과 입력 데이터가 전송 중에 보호되지 않습니다. 표준 VNC 암호 인증 또한 취약한 DES 기반 챌린지-응답 방식을 사용합니다. 신뢰할 수 있는 사설 네트워크나 VPN을 통해서만 DeskPad를 사용하고, VNC 서버를 인터넷에 직접 노출하지 마세요.

현재 클라이언트는 위에 명시된 인증 방식과 프레임버퍼 인코딩만 지원합니다. 확대/축소, 패닝, 스크롤, 보조 클릭과 같은 고급 제스처, 클립보드 동기화 및 TLS는 현재 지원하지 않습니다.

## 요구 사항

- Xcode 27 이상
- iOS/iPadOS 27.0 이상
- iPhone 또는 iPad

## 시작하기

1. 이 저장소를 복제합니다.
2. Xcode에서 `DeskPad.xcodeproj`를 엽니다.
3. iPhone 또는 iPad 시뮬레이터나 연결된 기기를 선택합니다.
4. `DeskPad` 앱 타깃을 빌드하고 실행합니다.
5. VNC 서버 연결을 추가합니다. 기본 포트는 `5900`입니다.

## 프로젝트 구조

- `DeskPad/ContentView.swift`: 연결 목록, 연결 편집 화면, 원격 데스크톱 UI
- `DeskPad/ConnectionStore.swift`: 저장된 연결 정보 및 키체인 자격 증명 관리
- `DeskPad/VNCSession.swift`: TCP 전송, RFB 협상 및 메시지, 인증, 프레임버퍼 업데이트, 원격 입력 처리
- `DeskPad/Assets.xcassets`: 앱 아이콘 및 포인트 색상

## 기여하기

이슈와 풀 리퀘스트를 환영합니다. 큰 변경 사항은 먼저 이슈를 열어 범위와 구현 방향을 논의해 주세요.

## 크레딧

- [Ned Park](https://africastart.com)

## 라이선스

[MIT](LICENSE) 라이선스로 제공됩니다.
