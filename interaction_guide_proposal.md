# Deepfake Defense Interaction Guide Proposal

## 1. 개요 (Overview)

신뢰도가 낮아질 때(Warning/Danger), 사용자에게 능동적인 대처를 가이드하는 **인터랙션 오버레이**를 화면 중앙에 표시합니다.
단순한 경고를 넘어, 딥페이크 모델의 약점을 파고드는 행동(Occlusion, Profile, Lighting)을 유도하여 사용자가 스스로 진위를 판별하도록 돕습니다.

## 2. 디자인 및 UI 사양

- **위치**: 화면 정중앙 (Center Overlay)
- **스타일**:
  - 반투명 배경 (Opacity 60% ~ 80% 블랙 글래스모피즘)
  - 큰 아이콘/이모티콘 + 행동 지침 텍스트
- **구성**: 3가지 방어 기법 중 하나를 랜덤 또는 순차적으로 제안

## 3. 방어 기법 (Defense Tactics)

### A. Occlusion Test (가림 현상 테스트) 👋

- **설명**: "얼굴 앞으로 손을 흔들어보라고 하세요."
- **원리**: 딥페이크는 얼굴과 카메라 사이에 물체가 지나갈 때(Occlusion) 합성이 풀리거나 깨지는 경우가 많습니다.
- **아이콘**: 손 흔드는 이모지 (`hand_wave_icon.png`)

### B. Profile Check (측면 확인) 🔄

- **설명**: "고개를 좌우로 천천히 돌려보세요."
- **원리**: 정면 데이터로만 학습된 저가형 피싱 모델은 측면(Profile)에서 급격히 화질이 무너집니다.
- **아이콘**: 회전/새로고침 스타일 이모지 (`head_turn_icon.png`)

### C. Lighting Shift (조명 변화) 💡

- **설명**: "휴대폰 조명을 켜보세요." (또는 손전등 비추기)
- **원리**: 실제 얼굴은 조명에 따라 그림자가 자연스럽게 변하지만, 합성된 얼굴은 학습된 조명(보통 정면)에 고정되어 있어 그림자가 부자연스럽습니다.
- **아이콘**: 전구 이모지 (`light_bulb_icon.png`)

## 4. 구현 계획 (Implementation)

### 4.1 리소스 제작

- `generate_image` 도구를 사용하여 3종의 **3D 스타일 이모지 아이콘**을 생성합니다.
- 파일명: `interaction_hand.png`, `interaction_turn.png`, `interaction_light.png`

### 4.2 로직 연동

- **Trigger**: `ReliabilityManager` 점수가 **Warning (40~70)** 구간에 진입하면 5초마다 위 3가지 가이드를 롤링하며 표시합니다.
- **Dismiss**: 점수가 Safe로 회복되거나 사용자가 탭하면 사라집니다.

### 4.3 UI 위젯

- `InteractionGuideOverlay`: 애니메이션이 포함된 투명도 조절 위젯
