# Deepfake 탐지 신뢰도 시스템 분석 보고서

## 1. 분석 개요

사용자께서 문의하신 "최근 20초의 로그를 기반으로 가중치를 적용한 신뢰도 산출 구조"가 현재 코드에 존재하는지 여부를 확인하기 위해 Dart(`DeepfakeInferenceService.dart`) 및 Native iOS(`DeepfakePredictor.swift`) 코드를 정밀 분석하였습니다.

## 2. 현황 분석 결과 (Status Check)

### 2.1 Dart `DeepfakeInferenceService.dart`

- **현황**: 현재 `_emaScore` 변수가 선언되어 있으나 실제 로직에는 사용되지 않고 있습니다 (`Unused variable`).
- **로직**: Native에서 전달받은 `finalScore`를 그대로 UI 상태(`SAFE`, `WARNING`, `DANGER`)로 매핑하고 있습니다. 별도의 히스토리 버퍼나 과거 데이터를 저장하는 로직이 **존재하지 않습니다.**

### 2.2 Native iOS `DeepfakePredictor.swift`

- **현황**: `frameBuffer`라는 배열이 존재하지만, 이는 LSTM 모델 입력을 위한 **입력 프레임 20장 버퍼링** 용도이며, **출력 점수의 히스토리 관리** 용도가 아닙니다.
- **로직**:
  - `consecutiveRealCount`: 연속된 SAFE 판정 횟수를 카운트하여 추론 주기(Interval)를 조절하는 로직(Adaptive Scheduling)은 존재합니다.
  - **결론**: 추론된 *결과값*들을 저장해두고 최근 값에 가중치를 주어 평균을 내는 "후처리 필터링(Smoothing)" 로직은 **구현되어 있지 않습니다.**

## 3. 구현 제안 (Implementation Proposal)

삭제된 것으로 파악되며, Dart 레이어에서 복구 및 구현하는 것이 효율적입니다.

### 3.1 목표 기능

- **History Size**: 최근 20회의 추론 결과 (약 20초 분량) 유지.
- **Weighted Scoring**: 최근 데이터일수록 높은 가중치를 부여하여, 일시적인 튀는 값(Outlier)은 무시하되 트렌드 변화는 반영.

### 3.2 알고리즘 공식 (Proposed Logic)

단순 평균이 아닌, **가중 이동 평균 (Weighted Moving Average)** 사용:

$$ Score\_{final} = \frac{\sum (Score_i \times Weight_i)}{\sum Weight_i} $$

- $i$: 인덱스 (0 = 가장 오래된 값, 19 = 가장 최근 값)
- $Weight_i$: 선형 증가 가중치 (예: 1, 2, 3... 20) 또는 지수 가중치.

### 3.3 구현 예시 (Dart)

```dart
class ReliabilityManager {
  final int maxHistory = 20;
  final List<double> _scoreHistory = [];

  void addScore(double newScore) {
    if (_scoreHistory.length >= maxHistory) {
      _scoreHistory.removeAt(0); // 가장 오래된 값 제거
    }
    _scoreHistory.add(newScore);
  }

  double calculateWeightedReliability() {
    if (_scoreHistory.isEmpty) return 0.0;

    double weightedSum = 0.0;
    double weightTotal = 0.0;

    // 최근 값일수록 높은 가중치 (선형 가중치 예시)
    for (int i = 0; i < _scoreHistory.length; i++) {
        double weight = (i + 1).toDouble(); // 1, 2, 3...
        weightedSum += _scoreHistory[i] * weight;
        weightTotal += weight;
    }

    return weightedSum / weightTotal;
  }
}
```

## 4. 결론 및 향후 계획

- **결론**: 말씀하신 기능은 현재 코드베이스에서 **누락**된 상태입니다.
- **실행 계획**:
  1. `DeepfakeInferenceService` 내에 `ReliabilityManager` 클래스 구현.
  2. 추론 결과 수신 시 히스토리에 저장 및 가중 평균 계산.
  3. UI(`DeepfakeState`)에 계산된 `reliableScore` 반영.
  4. 로그 파일에 `Reliable_Score` 컬럼 추가하여 기록.

승인해주시면 즉시 구현을 시작하겠습니다.
