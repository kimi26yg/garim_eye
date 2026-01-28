# 프로젝트: 실시간 딥페이크 탐지 화상통화 앱 (MVP)

## 목표: WebRTC 연동 및 실시간 1:1 통화 구현

### 1. 개발 환경 및 기술 스택

- **Framework**: Flutter (Riverpod, go_router 사용)
- **Real-time**: flutter_webrtc
- **Signaling**: Node.js + Socket.io (Port: 3000)
- **STUN Server**: Google STUN (stun:stun.l.google.com:19302)

### 2. 핵심 구현 태스크

#### [Task 1] Node.js 시그널링 서버 구축

- `socket.io`를 사용하여 `offer`, `answer`, `ice-candidate` 이벤트를 중계하는 서버를 작성하세요.
- 같은 호스트(Local) 환경에서 두 클라이언트가 연결될 수 있도록 매칭 로직을 구현합니다.

#### [Task 2] Flutter WebRTC 서비스 및 상태 관리 (Riverpod)

- `WebRTCService` 클래스 생성:
  - `RTCPeerConnection` 설정 시 Google STUN 서버 주소를 `iceServers`에 포함하세요.
  - 로컬/원격 미디어 스트림 획득 및 트랙 추가 로직을 구현합니다.
- `CallNotifier` (StateNotifier 또는 AsyncNotifier):
  - `callState` (idle, calling, connected)를 관리합니다.
  - `RTCVideoRenderer` 2개(local, remote)를 관리하며, 생명주기(init/dispose)를 엄격히 제어합니다.

#### [Task 3] UI 통합 및 go_router 네비게이션

- `/call` 경로를 `go_router`에 등록하고 `VideoCallScreen`을 연결합니다.
- **VideoCallScreen 구성**:
  - **전체 화면**: 원격 사용자의 화면 (`RTCVideoView`)
  - **PiP (Overlay)**: 내 화면을 보여주는 작은 창. `Positioned`와 `GestureDetector`를 사용하여 화면 내에서 **드래그 가능**하게 만드세요.
- 카메라/마이크 권한 요청 로직을 포함합니다 (`permission_handler`).

### 3. 주요 주의사항 (필독)

- **IP 설정**: 스마트폰 실기기 테스트를 위해 `localhost` 대신 개발 PC의 **사설 IP(예: 192.168.x.x)**를 서버 URL로 사용하도록 코드를 작성하세요.
- **자원 해제**: 통화 종료 시 모든 미디어 스트림을 stop하고, renderer를 dispose하여 메모리 누수를 방지하세요.
- **보안**: 영상 데이터는 WebRTC 표준(DTLS/SRTP)에 의해 암호화됨을 전제로 하며, 시그널링 단계에서만 소켓을 사용합니다.

### 4. Definition of Done (완료 기준)

- [ ] 시그널링 서버가 정상 작동하며 소켓 연결을 수락함.
- [ ] 앱에서 `/call` 페이지 진입 시 내 카메라 화면이 PiP로 보임.
- [ ] 상대방(PC/다른 기기) 연결 시 서로의 영상과 음성이 실시간으로 전달됨.
- [ ] PiP 화면이 사용자의 드래그에 따라 부드럽게 이동함.
