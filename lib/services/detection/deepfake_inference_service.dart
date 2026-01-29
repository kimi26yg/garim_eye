import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'frame_extractor.dart';

// --- DTOs ---

class InferenceRequest {
  final String imagePath;
  final List<int> faceRect; // [left, top, width, height]

  InferenceRequest(this.imagePath, this.faceRect);
}

class InferenceResponse {
  final double score;
  final bool isError;
  final String? errorMessage;

  InferenceResponse({
    required this.score,
    this.isError = false,
    this.errorMessage,
  });
}

enum DetectionStatus { safe, warning, danger }

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
  static const double PADDING_FACTOR = 0.2; // 0.2 padding (20% each side)
  static const int BATCH_SIZE = 20;
  static const int MA_WINDOW_SIZE = 5; // Moving Average Window

  final FrameExtractor _frameExtractor = FrameExtractor();
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.fast,
      enableLandmarks: false,
      enableContours: false,
    ),
  );

  Isolate? _isolate;
  SendPort? _sendPort;
  StreamSubscription? _frameSub;

  // State
  bool _isProcessing = false;

  // Reliability State
  final List<double> _scoreBuffer = [];
  final _stateController = StreamController<DeepfakeState>.broadcast();
  Stream<DeepfakeState> get stateStream => _stateController.stream;

  // Logging
  IOSink? _logSink;

  // Debug (Unused for now, keeping for reference if needed)
  Interpreter? _debugInterpreter;

  Future<void> initialize() async {
    // 1. Clean up previous session garbage to prevent "No Space Left"
    await _clearDiskCache();

    // 0. Prepare Model File (Main Thread) - Avoids AssetBundle issues in Isolate
    final modelBytes = await rootBundle.load(
      'assets/models/garim_model_v214_final_fp16.tflite',
    );
    final tempDir = await getTemporaryDirectory();
    final modelFile = File('${tempDir.path}/model.tflite');
    await modelFile.writeAsBytes(modelBytes.buffer.asUint8List());

    if (_isolate != null) return;

    final receivePort = ReceivePort();
    final rootToken = RootIsolateToken.instance;

    _isolate = await Isolate.spawn(_inferenceWorker, [
      receivePort.sendPort,
      rootToken,
      modelFile.path, // Pass file path instead of asset name
    ]);

    // Listen for results
    receivePort.listen((message) {
      if (message is SendPort) {
        _sendPort = message; // Handshake received here
        debugPrint("[InferenceService] Handshake received. Pipeline ready.");
      } else if (message is InferenceResponse) {
        if (!message.isError) {
          _processScore(message.score);
        } else {
          debugPrint("[InferenceService] Error: ${message.errorMessage}");
        }
      }
    });

    debugPrint("[InferenceService] Initialized & Cache Cleared.");
  }

  void _processScore(double rawScore) {
    // 1. Update Buffer (First-In, First-Out)
    _scoreBuffer.add(rawScore);
    if (_scoreBuffer.length > MA_WINDOW_SIZE) {
      _scoreBuffer.removeAt(0);
    }

    // 2. Calculate Moving Average
    double maScore = 0.0;
    if (_scoreBuffer.isNotEmpty) {
      maScore = _scoreBuffer.reduce((a, b) => a + b) / _scoreBuffer.length;
    }

    // 3. Determine State
    DetectionStatus status;
    if (maScore >= 0.7) {
      status = DetectionStatus.danger;
    } else if (maScore >= 0.4) {
      status = DetectionStatus.warning;
    } else {
      status = DetectionStatus.safe;
    }

    // 4. Emit State
    final state = DeepfakeState(
      rawScore: rawScore,
      confidence: maScore,
      status: status,
    );
    _stateController.add(state);

    // 5. Log
    _logInference(state);
  }

  /// Deletes all temporary frame files to free up space.
  Future<void> _clearDiskCache() async {
    try {
      final tempDir = await getTemporaryDirectory();
      if (tempDir.existsSync()) {
        final files = tempDir.listSync();
        int deletedCount = 0;
        for (final file in files) {
          if (file is File &&
              file.path.contains('frame_') &&
              file.path.endsWith('.png')) {
            try {
              await file.delete();
              deletedCount++;
            } catch (_) {}
          }
        }
        if (deletedCount > 0) {
          debugPrint(
            "[InferenceService] Cleared $deletedCount temporary frame files.",
          );
        }
      }
    } catch (e) {
      debugPrint("[InferenceService] Failed to clear cache: $e");
    }
  }

  Future<void> _initLogger() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${docDir.path}/logs');
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final logFile = File('${logDir.path}/log_session_$timestamp.csv');

      _logSink = logFile.openWrite();
      _logSink?.writeln('Timestamp,Raw_Score,MA_Score,Status');
      debugPrint("[InferenceService] Logging to: ${logFile.path}");
    } catch (e) {
      debugPrint("[InferenceService] Failed to init logger: $e");
    }
  }

  void _logInference(DeepfakeState state) {
    if (_logSink != null) {
      final time = DateTime.now().toIso8601String();
      _logSink?.writeln(
        '$time,${state.rawScore.toStringAsFixed(4)},${state.confidence.toStringAsFixed(4)},${state.status.name}',
      );
    }
  }

  Future<void> start(MediaStreamTrack track) async {
    if (_isProcessing) return;
    _isProcessing = true;

    await _initLogger();

    // Start Extraction
    await _frameExtractor.startExtraction(track);

    // Subscribe to frames
    _frameSub = _frameExtractor.frameStream.listen(_handleFrame);
    debugPrint("[InferenceService] Started processing pipeline.");
  }

  Future<void> stop() async {
    _isProcessing = false;
    _frameExtractor.stopExtraction();
    await _frameSub?.cancel();
    _frameSub = null;

    await _logSink?.flush();
    await _logSink?.close();
    _logSink = null;

    // Clear buffer on stop
    _scoreBuffer.clear();

    debugPrint("[InferenceService] Stopped.");
  }

  // Define a temporary directory cache
  Directory? _tempDir;

  Future<void> _handleFrame(Uint8List bytes) async {
    if (_sendPort == null) return;

    // Optional: Add simple throttling if needed
    // if (Random().nextDouble() > 0.5) return; // Drop 50% frames if needed

    File? tempFile;
    try {
      _tempDir ??= await getTemporaryDirectory();
      // Use unique name to check for race conditions
      tempFile = File(
        '${_tempDir!.path}/frame_${DateTime.now().millisecondsSinceEpoch}_${math.Random().nextInt(1000)}.png',
      );
      await tempFile.writeAsBytes(bytes);

      // 1. Face Detection (Main Thread - Native Optimized)
      final inputImage = InputImage.fromFilePath(tempFile.path);
      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isNotEmpty) {
        // Take the largest face
        final face = faces.reduce(
          (curr, next) =>
              (curr.boundingBox.width * curr.boundingBox.height) >
                  (next.boundingBox.width * next.boundingBox.height)
              ? curr
              : next,
        );

        final rect = face.boundingBox;
        debugPrint(
          "[InferenceService] Face detected: $rect. Sending to Isolate.",
        );

        // Send to Isolate - Isolate becomes responsible for deletion
        _sendPort!.send(
          InferenceRequest(tempFile.path, [
            rect.left.toInt(),
            rect.top.toInt(),
            rect.width.toInt(),
            rect.height.toInt(),
          ]),
        );
        // DO NOT delete here, Isolate needs it.
      } else {
        debugPrint("[InferenceService] No faces detected in frame.");
        // No face found, delete file immediately
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      }
    } catch (e) {
      debugPrint("[InferenceService] Frame handling error: $e");
      // Safety delete in case of error
      if (tempFile != null && await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
    }
  }

  void dispose() {
    stop();
    _faceDetector.close();
    _stateController.close();
    _sendPort?.send('close');
    _isolate?.kill();
    // Final cleanup attempt
    _clearDiskCache();
  }

  // --- Isolate Worker ---

  static Future<void> _inferenceWorker(List<dynamic> args) async {
    print('🚀 [SYSTEM] Isolate Worker가 메모리에 로드되었습니다.');

    try {
      final SendPort mainSendPort = args[0];
      final RootIsolateToken? rootToken = args[1];
      final String modelPath = args[2];

      if (rootToken != null) {
        BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken);
        print('✅ [CHECK] 바이너리 메신저 초기화 성공');
      } else {
        print('⚠️ [WARNING] RootToken이 null입니다. 바이너리 메신저 초기화 실패 가능성 있음.');
      }

      final receivePort = ReceivePort();
      mainSendPort.send(receivePort.sendPort);

      // Check Model File
      final file = File(modelPath);
      if (await file.exists()) {
        print('✅ [CHECK] 모델 파일 확인됨: $modelPath (${await file.length()} bytes)');
      } else {
        print('🔥 [CRITICAL] 모델 파일이 존재하지 않음: $modelPath');
        throw Exception('Model file missing');
      }

      // Initialize Interpreter
      Interpreter? interpreter;
      try {
        print('⏳ [LOADING] 모델 로딩 중...');
        interpreter = Interpreter.fromFile(file);
        print('✅ [CHECK] 모델 로드 완료');
      } catch (e) {
        throw Exception('Interpreter init failed: $e');
      }

      // Inference State
      final List<List<double>> frameQueue = [];

      // Model specific: Get Input Shape
      // Assuming [1, 20, 224, 224, 3]
      var inputShape = [1, 20, 224, 224, 3];
      try {
        final tensor = interpreter.getInputTensor(0);
        inputShape = tensor.shape;
        print('📊 [DATA] 모델 입력 텐서 정보: Shape=$inputShape, Type=${tensor.type}');
      } catch (e) {
        print('⚠️ [WARNING] 텐서 정보 가져오기 실패: $e');
      }

      print("[Isolate] Expected Input Shape: $inputShape");

      await for (final message in receivePort) {
        if (message is InferenceRequest) {
          try {
            final imgFile = File(message.imagePath);
            if (!await imgFile.exists()) {
              print("[Isolate] File missing: ${message.imagePath}");
              continue;
            }

            // Decode
            final bytes = await imgFile.readAsBytes();
            final image = img.decodeImage(bytes);

            // Delete file after read
            await imgFile.delete();

            if (image == null) continue;

            // Crop with Padding
            final faceRect = message.faceRect;
            final x = faceRect[0];
            final y = faceRect[1];
            final w = faceRect[2];
            final h = faceRect[3];

            final padW = (w * PADDING_FACTOR).toInt();
            final padH = (h * PADDING_FACTOR).toInt();

            final cropX = math.max(0, x - padW);
            final cropY = math.max(0, y - padH);
            final cropW = math.min(image.width - cropX, w + (padW * 2));
            final cropH = math.min(image.height - cropY, h + (padH * 2));

            final cropped = img.copyCrop(
              image,
              x: cropX,
              y: cropY,
              width: cropW,
              height: cropH,
            );

            // Resize to 224x224
            final resized = img.copyResize(cropped, width: 224, height: 224);

            // Normalize & Convert to List<double>
            final frameData = _imageToFloat32(resized);

            // Add to Queue (Sliding Window)
            if (frameQueue.length >= BATCH_SIZE) {
              frameQueue.removeAt(0);
            }
            frameQueue.add(frameData);

            print("[Isolate] Buffer size: ${frameQueue.length}/$BATCH_SIZE");

            // Run Inference (Allow partial buffer with padding)
            if (frameQueue.isNotEmpty) {
              // Flatten
              final inputBuffer = Float32List(1 * 20 * 224 * 224 * 3);
              int offset = 0;

              // 1. Fill with actual frames
              for (final frame in frameQueue) {
                for (int i = 0; i < frame.length; i++) {
                  inputBuffer[offset++] = frame[i];
                }
              }

              // 2. Pad with the LAST frame if not full (Replicate Strategy)
              if (frameQueue.length < BATCH_SIZE) {
                final lastFrame = frameQueue.last;
                final missingFrames = BATCH_SIZE - frameQueue.length;
                for (int k = 0; k < missingFrames; k++) {
                  for (int i = 0; i < lastFrame.length; i++) {
                    inputBuffer[offset++] = lastFrame[i];
                  }
                }
              }

              // Output Buffer
              var outputShape = [1, 1];
              try {
                outputShape = interpreter.getOutputTensor(0).shape;
              } catch (_) {}

              final outputSize = outputShape.reduce((a, b) => a * b);
              final outputBuffer = Float32List(outputSize);

              // Run Inference
              double minVal = inputBuffer[0];
              double maxVal = inputBuffer[0];
              double sumVal = 0.0;
              for (var v in inputBuffer) {
                if (v < minVal) minVal = v;
                if (v > maxVal) maxVal = v;
                sumVal += v;
              }
              print(
                "📊 [Isolate] Input Mean: ${(sumVal / inputBuffer.length).toStringAsFixed(3)}, Min: ${minVal.toStringAsFixed(3)}, Max: ${maxVal.toStringAsFixed(3)}",
              );

              interpreter.run(
                inputBuffer.reshape([1, 20, 224, 224, 3]), // Ensure fixed
                outputBuffer.reshape(outputShape),
              );

              final score = outputBuffer[0];
              print('🎯 [RAW SCORE] 모델 출력 원본: $score');
              mainSendPort.send(InferenceResponse(score: score));
            }
          } catch (e, s) {
            print('🔥 [CRITICAL] Isolate 내부 처리 오류: $e');
            print('📚 스택트레이스: $s');
          }
        } else if (message == 'close') {
          interpreter?.close();
          Isolate.exit();
        }
      }
    } catch (e, s) {
      print('🔥 [CRITICAL] Isolate 초기화/실행 중 치명적 오류: $e');
      print('📚 스택트레이스: $s');
    }
  }

  static List<double> _imageToFloat32(img.Image image) {
    // 224 * 224 * 3
    final buffer = List<double>.filled(224 * 224 * 3, 0.0);
    int index = 0;

    // Debug: Check First Pixel
    if (image.length > 0) {
      final p = image.first;
      // print("[Isolate] Sample Pixel Input (R,G,B): ${p.r}, ${p.g}, ${p.b}");
      // print(
      //   "[Isolate] Sample Pixel Normalized (-1~1): ${(p.r / 127.5) - 1.0}, ...",
      // );
    }

    // Iterate pixels - 'image' package standardizes memory layout
    for (final pixel in image) {
      buffer[index++] = (pixel.r / 127.5) - 1.0;
      buffer[index++] = (pixel.g / 127.5) - 1.0;
      buffer[index++] = (pixel.b / 127.5) - 1.0;
    }
    return buffer;
  }
}
