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
  final double confidence; // Moving Average
  final DetectionStatus status;

  DeepfakeState({
    required this.rawScore,
    required this.confidence,
    required this.status,
  });

  @override
  String toString() =>
      'State(conf: ${(confidence * 100).toStringAsFixed(1)}%, status: ${status.name})';
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
      // Note: We keep this for now as a fallback/dual-mode test
      unawaited(_handleFrame(bytes));
    });

    debugPrint(
      "[InferenceService] Pipeline Started (Native-First + Method Channel Fallback).",
    );
  }

  Future<void> _handleFrame(Uint8List bytes) async {
    try {
      // debugPrint(
      //   "📸 [InferenceService] Calling processFrame with ${bytes.length} bytes",
      // );

      // 1. Send to Native Pipeline (Zero Logic in Dart)
      //    We send raw bytes. Native does Detection -> Crop -> Buffer -> Inference.
      //    This is async but we don't await to allow concurrent processing
      final result = await _channel.invokeMethod('processFrame', bytes);

      // debugPrint("📦 [InferenceService] Received result: $result");

      if (result != null && result is Map) {
        _handleNativeResult(result);
      } else {
        // debugPrint(
        //   "⚠️ [InferenceService] Result is null or not a Map: $result",
        // );
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

    if (status == "skipped") {
      // debugPrint("⏭️ [InferenceService] Frame skipped: ${result['reason']}");
      // Log skip?
      // _logSink?.writeln("... SKIPPED (${result['reason']}) ...");
      return;
    }

    if (status == "inference") {
      final score = (result['score'] as num).toDouble();
      final inferMs = (result['inference_ms'] as num).toDouble();

      // Intelligent Engine Logic
      _processIntelligentScore(score, detectMs, cropMs, inferMs);
    }
  }

  // --- Intelligent Reliability Engine ---

  void _processIntelligentScore(
    double rawCnnScore,
    double detectMs,
    double cropMs,
    double inferMs,
  ) {
    // 1. Fast-Trigger
    bool fastTrigger = false;
    if (rawCnnScore >= 0.95 && _previousRawScore >= 0.95) {
      fastTrigger = true;
    }
    _previousRawScore = rawCnnScore;

    // 2. Hybrid Fusion (Placeholder)
    double fftScore = 0.0;
    double beta = 1.0;
    double hybridScore = (beta * rawCnnScore) + ((1 - beta) * fftScore);

    // 3. EMA
    const double alpha = 0.33;

    if (_isFirstRun) {
      _emaScore = hybridScore;
      _isFirstRun = false;
    } else {
      if (fastTrigger) {
        _emaScore = 0.95;
      } else {
        _emaScore = (alpha * hybridScore) + ((1 - alpha) * _emaScore);
      }
    }

    // 4. Decision
    DetectionStatus status;
    String triggerType = "NORMAL";

    if (fastTrigger) {
      status = DetectionStatus.danger;
      triggerType = "FAST_TRIGGER";
    } else {
      if (_emaScore >= 0.7) {
        status = DetectionStatus.danger;
      } else if (_emaScore >= 0.4) {
        status = DetectionStatus.warning;
      } else {
        status = DetectionStatus.safe;
      }
    }

    // 5. Emit
    final state = DeepfakeState(
      rawScore: rawCnnScore,
      confidence: _emaScore,
      status: status,
    );
    _stateController.add(state);

    // 6. Log
    _logInference(state, fftScore, triggerType, detectMs, cropMs, inferMs);

    debugPrint(
      "🎯 [Engine] $triggerType | Raw: ${rawCnnScore.toStringAsFixed(3)} | EMA: ${_emaScore.toStringAsFixed(3)} | Latency: ${detectMs + cropMs + inferMs}ms",
    );
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
