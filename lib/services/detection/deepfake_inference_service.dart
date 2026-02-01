import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'frame_extractor.dart';

// --- DTOs ---

class DetectionStatus {
  static const safe = const DetectionStatus._('safe');
  static const warning = const DetectionStatus._('warning');
  static const danger = const DetectionStatus._('danger');

  final String name;
  const DetectionStatus._(this.name);

  @override
  String toString() => name;
}

class DeepfakeState {
  final double rawScore;
  final double confidence; // Legacy EMA
  final DetectionStatus status;

  // v4.5 Hybrid Metadata
  final double fftScore;
  final double fftVariance;
  final bool isPenalized;
  final double aiScore;
  final double finalScore; // Native calculated
  final double interval;

  DeepfakeState({
    required this.rawScore,
    required this.confidence,
    required this.status,
    this.fftScore = 0.0,
    this.fftVariance = 0.0,
    this.isPenalized = false,
    this.aiScore = 0.0,
    this.finalScore = 0.0,
    this.interval = 1.25,
  });

  @override
  String toString() =>
      'State(final: $finalScore, status: ${status.name}, interval: $interval)';
}

// --- Service ---

class DeepfakeInferenceService {
  // Original Method Channel (Dart → Swift → Dart)
  static const MethodChannel _channel = MethodChannel(
    'com.garim.eye/inference',
  );

  // Native-First Pipeline channels
  static const EventChannel _nativeEventChannel = EventChannel(
    'com.garim.eye/native_inference',
  );
  static const MethodChannel _nativeControlChannel = MethodChannel(
    'com.garim.eye/native_control',
  );

  final FrameExtractor _frameExtractor = FrameExtractor();
  StreamSubscription? _frameSub;
  StreamSubscription? _nativeResultSub; // For native event channel

  // Intelligent Engine State
  final _stateController = StreamController<DeepfakeState>.broadcast();
  Stream<DeepfakeState> get stateStream => _stateController.stream;

  // EMA State
  double _emaScore = 0.0;
  double _previousRawScore = 0.0;
  bool _isFirstRun = true;

  // Frame sampling
  int _frameCounter = 0;

  // Logging
  IOSink? _logSink;

  // Pipeline Stats
  int _pipelineFpsCounter = 0;
  DateTime _lastFpsTime = DateTime.now();

  Future<void> initialize() async {
    debugPrint("[InferenceService] Initialized (Full-Native Pipeline).");
  }

  Future<void> start(MediaStreamTrack track) async {
    // Phase 4.5: Attach Native Sink (PRIORITY 1) - Must happen before anything else
    debugPrint(
      "🚀 [InferenceService] STARTING PIPELINE for track: ${track.id}",
    );
    try {
      debugPrint("🔗 [InferenceService] Attempting to attach native sink...");
      final result = await _nativeControlChannel.invokeMethod('attach', {
        'trackId': track.id,
      });
      debugPrint("✅ [InferenceService] Native sink attached result: $result");
    } catch (e) {
      debugPrint("❌ [InferenceService] Failed to attach native sink: $e");
    }

    _isFirstRun = true;
    _previousRawScore = 0.0;

    await _initLogger();

    // Subscribe to native event channel for results
    _nativeResultSub = _nativeEventChannel.receiveBroadcastStream().listen(
      (result) {
        if (result is Map) {
          _handleNativeResult(Map<String, dynamic>.from(result));
        }
      },
      onError: (error) {
        debugPrint("❌ [InferenceService] Native channel error: $error");
      },
    );

    // Pure Native Mode: Disable Dart frame extraction to verify Native connection
    await _frameExtractor.startExtraction(track);

    // Process all frames for maximum accuracy
    // Expected: 20 frames in ~3 seconds at 16.8 FPS
    _frameSub = _frameExtractor.frameStream.listen((bytes) {
      _frameCounter++;
      unawaited(_handleFrame(bytes));
    });

    debugPrint(
      "[InferenceService] Pipeline Started (Dart -> Swift Bridge Restored).",
    );
  }

  Future<void> _handleFrame(Uint8List bytes) async {
    try {
      // 1. Send to Native Pipeline
      //    We send raw bytes. Native does Detection -> Crop -> Buffer -> Inference.
      final result = await _channel.invokeMethod('processFrame', bytes);

      if (result != null && result is Map) {
        _handleNativeResult(result);
      }
    } catch (e, stackTrace) {
      debugPrint("❌ [InferenceService] Pipeline Error: $e");
      debugPrint("Stack trace: $stackTrace");
    }
  }

  void _handleNativeResult(Map result) {
    // debugPrint("🔄 [InferenceService] Processing native result: $result");
    final status = result['status'] as String;
    // debugPrint("📊 [InferenceService] Status: $status");

    // Update Pipeline FPS
    _pipelineFpsCounter++;
    final now = DateTime.now();
    if (now.difference(_lastFpsTime).inSeconds >= 1) {
      final fps = _pipelineFpsCounter;
      // Log FPS
      _logSink?.writeln("${now.toIso8601String()},PIPELINE_FPS,,,,,$fps");
      _pipelineFpsCounter = 0;
      _lastFpsTime = now;
    }

    final detectMs = (result['detection_ms'] as num?)?.toDouble() ?? 0.0;
    final cropMs = (result['cropping_ms'] as num?)?.toDouble() ?? 0.0;

    if (status == "skipped" || status == "collecting") {
      // debugPrint("⏭️ [InferenceService] Frame skipped/collecting: $status");
      // Do NOT emit state update here to prevent UI flicker (0.0 score)
      return;
    }

    if (status == "inference") {
      final score = (result['score'] as num?)?.toDouble() ?? 0.0;
      final inferMs = (result['inference_ms'] as num?)?.toDouble() ?? 0.0;

      // v4.5 Metadata
      final fftScore = (result['fft_score'] as num?)?.toDouble() ?? 0.0;
      final fftVariance = (result['fft_variance'] as num?)?.toDouble() ?? 0.0;
      final isPenalized = (result['is_penalized'] as bool?) ?? false;
      final aiScore = (result['ai_score'] as num?)?.toDouble() ?? 0.0;
      final finalScore = (result['final_score'] as num?)?.toDouble() ?? 0.0;
      final interval = (result['interval'] as num?)?.toDouble() ?? 1.25;

      // Intelligent Engine Logic
      _processIntelligentScore(
        score,
        detectMs,
        cropMs,
        inferMs,
        fftScore,
        fftVariance,
        isPenalized,
        aiScore,
        finalScore,
        interval,
      );
    }
  }

  // --- Intelligent Reliability Engine ---

  void _processIntelligentScore(
    double rawCnnScore,
    double detectMs,
    double cropMs,
    double inferMs,
    double fftScore,
    double fftVariance,
    bool isPenalized,
    double aiScore,
    double finalScore,
    double interval,
  ) {
    // v4.5 Logic: Trust Native Final Score (0.0 ~ 10.0)
    // Map Final Score to DetectionStatus
    // Safe: >= 9.5 (Ultra), >= 8.0 (High)
    // Warning: ???
    // The previous logic used 0.7 (7.0) threshold for Danger.

    DetectionStatus status;
    String triggerType = "HYBRID_v4.5";

    // v4.5 100-Point Scale Thresholds
    // Ultra Safe: >= 95.0
    // Safe: >= 80.0
    // Warning: >= 40.0
    // Danger: < 40.0
    if (finalScore >= 95.0) {
      status = DetectionStatus.safe;
    } else if (finalScore >= 80.0) {
      status = DetectionStatus.safe;
    } else if (finalScore >= 40.0) {
      status = DetectionStatus.warning;
    } else {
      status = DetectionStatus.danger;
    }

    final state = DeepfakeState(
      rawScore: rawCnnScore,
      confidence: finalScore / 100.0, // Norm 0.0-1.0 for UI %
      status: status,
      fftScore: fftScore,
      fftVariance: fftVariance,
      isPenalized: isPenalized,
      aiScore: aiScore,
      finalScore: finalScore,
      interval: interval,
    );
    _stateController.add(state);

    // 6. Log
    _logInference(state, fftScore, triggerType, detectMs, cropMs, inferMs);

    // debugPrint(
    //   "🎯 [Engine] Hybrid: ${finalScore.toStringAsFixed(2)} | AI: $aiScore | FFT: $fftScore | Interval: $interval",
    // );
  }

  // --- Logging & Utilities ---

  Future<void> _initLogger() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${docDir.path}/logs');
      if (!await logDir.exists()) await logDir.create(recursive: true);

      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final logFile = File('${logDir.path}/log_native_$timestamp.txt');

      _logSink = logFile.openWrite();
      _logSink?.writeln(
        'Timestamp,Raw_CNN,Raw_FFT,Fused,EMA,Status,Trigger_Type,Detect_ms,Crop_ms,Inference_ms,Pipeline_FPS',
      );
    } catch (e) {
      debugPrint("[InferenceService] Failed to init logger: $e");
    }
  }

  void _logInference(
    DeepfakeState state,
    double fft,
    String trigger,
    double detectMs,
    double cropMs,
    double inferMs,
  ) {
    if (_logSink != null) {
      final time = DateTime.now().toIso8601String();
      _logSink?.writeln(
        '$time,${state.rawScore.toStringAsFixed(4)},${fft.toStringAsFixed(4)},'
        '${state.rawScore.toStringAsFixed(4)},${state.confidence.toStringAsFixed(4)},'
        '${state.status.name},$trigger,${detectMs.toStringAsFixed(2)},${cropMs.toStringAsFixed(2)},${inferMs.toStringAsFixed(2)},',
      );
    }
  }

  Future<void> stop() async {
    await _frameSub?.cancel();
    _frameSub = null;

    await _nativeResultSub?.cancel();
    _nativeResultSub = null;
    _frameExtractor.stopExtraction();

    // Close log file safely
    if (_logSink != null) {
      try {
        await _logSink!.flush();
        await _logSink!.close();
      } catch (e) {
        // Ignore flush errors during shutdown
        debugPrint("[InferenceService] Log flush error (safe to ignore): $e");
      }
      _logSink = null;
    }

    debugPrint("[InferenceService] Pipeline Stopped.");
  }

  void dispose() {
    stop();
    _stateController.close();
  }
}
