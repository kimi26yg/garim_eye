# Deepfake 탐지 신뢰도 산출 및 로깅 전략 제안서

## 1. 개요

본 문서는 `specifications.md`에 명시된 요구사항을 바탕으로, **Garim Eye v2**의 딥페이크 탐지 엔진이 단순 확률값을 넘어 사용자에게 신뢰할 수 있는 경고를 제공하기 위한 논리적 구조를 제안합니다.

## 2. 신뢰도 산출 알고리즘 (Scoring Strategy)

### 2.1 기본 단위

- **Unit Inference**: 20프레임 (약 1초 분량) 단위로 1회 추론.
- **Raw Score ($S_t$)**: 모델이 출력하는 $0.0 \sim 1.0$ 사이의 실수값. (1.0 = Deepfake)

### 2.2 이동 평균 (Moving Average) 필터

일시적인 노이즈나 네트워크 버퍼링으로 인한 오탐지(False Positive)를 방지하기 위해, 최근 5회의 추론 결과를 평균하여 **최종 신뢰도($C_t$)**를 산출합니다.

$$ C*t = \frac{1}{N} \sum*{i=0}^{N-1} S\_{t-i} $$

- $N = 5$ (최근 5초/100프레임 데이터)
- **초기 상태 처리**: 데이터가 5개 미만일 경우, 수집된 데이터 $k$개의 평균으로 계산합니다.

### 2.3 상태 판별 임계값 (Thresholding)

사용자 UI에 표시될 상태를 최종 신뢰도 $C_t$에 따라 3단계로 구분합니다.

| 상태 (Status) | 신뢰도 범위 ($C_t$)   | UI 표현 (제안)        | 액션                                       |
| :------------ | :-------------------- | :-------------------- | :----------------------------------------- |
| **SAFE**      | $0.0 \le C_t < 0.4$   | 🟢 녹색 테두리/아이콘 | 특별한 조치 없음                           |
| **WARNING**   | $0.4 \le C_t < 0.7$   | 🟡 황색 경고등        | 주의 문구 표시 ("화면이 부자연스럽습니다") |
| **DANGER**    | $0.7 \le C_t \le 1.0$ | 🔴 적색 경고 및 블러  | **알림음 송출** 및 화면 블러 처리 권장     |

---

## 3. 데이터 로깅 아키텍처 (Auditing)

추론 결과의 사후 검증 및 모델 개선을 위해 구조화된 로그를 로컬 파일 시스템에 저장합니다.

### 3.1 로그 포맷 (CSV/JSON)

각 추론 이벤트마다 한 줄의 로그를 생성합니다.

```csv
Timestamp, Frame_Seq_Start, Frame_Seq_End, Raw_Score, Confidence_Score, Inference_Time_ms
```

- **Timestamp**: `YYYY-MM-DD HH:mm:ss.ms`
- **Frame_Seq**: 영상 스트림 내 프레임 번호 (0부터 시작)
- **Raw_Score**: 해당 20프레임에 대한 모델 예측값
- **Confidence_Score**: 이동 평균 적용 후 신뢰도
- **Inference_Time_ms**: 순수 연산 소요 시간 (성능 모니터링용)

### 3.2 파일 저장 정책

- **파일명**: `log_session_{roomId}_{timestamp}.txt`
- **저장 위치**: `ApplicationDocumentsDirectory/logs/`
- **Lifecycle**: 통화 종료(`CallEndedScreen`) 시 로그 파일을 닫고 저장 완료.

---

## 4. 시스템 구조도 (System Flow)

```mermaid
graph TD
    A[Remote Stream (WebRTC)] -->|Frame Capture| B(Frame Queue)
    B -->|Size >= 20| C{Isolate Worker}
    C -->|Input| D[TFLite Interpreter]
    D -->|Output Score| E[Score Aggregator]
    E -->|Moving Average| F[Final Confidence]
    F -->|Update| G[UI Layer (Main Thread)]
    E -->|Write| H[Local Log File]
```

## 5. 결론

이 전략은 단일 프레임의 오차가 사용자 경험을 해치지 않도록 **평활화(Smoothing)** 과정을 거치며, 상세한 로그 기록을 통해 향후 모델 성능 분석(EDA)을 가능하게 합니다.
