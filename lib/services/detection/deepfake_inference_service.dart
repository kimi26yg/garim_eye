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

// --- Service ---

class DeepfakeInferenceService {
  static const double PADDING_FACTOR = 0.2; // 0.2 padding (20% each side)
  static const int BATCH_SIZE = 1;

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
  final _scoreController = StreamController<double>.broadcast();
  Stream<double> get scoreStream => _scoreController.stream;

  // Logging
  IOSink? _logSink;

  // Debug
  Interpreter? _debugInterpreter;

  Future<void> initialize() async {
    // 1. Clean up previous session garbage to prevent "No Space Left"
    await _clearDiskCache();

    // 0. Prepare Model File (Main Thread) - Avoids AssetBundle issues in Isolate
    final modelBytes = await rootBundle.load(
      'assets/models/garim_model_fp16.tflite',
    );
    final tempDir = await getTemporaryDirectory();
    final modelFile = File('${tempDir.path}/model.tflite');
    await modelFile.writeAsBytes(modelBytes.buffer.asUint8List());

    // --- DEBUG: Run on Main Thread to bypass silent Isolate ---
    try {
      debugPrint("[InferenceService] DEBUG: Loading model on Main Thread...");
      _debugInterpreter = Interpreter.fromFile(modelFile);
      debugPrint("[InferenceService] DEBUG: Model loaded on Main Thread.");
    } catch (e) {
      debugPrint("[InferenceService] DEBUG: Model load failed: $e");
    }
    // -----------------------------------------------------------

    if (_isolate != null) return;

    final receivePort = ReceivePort();
    final rootToken = RootIsolateToken.instance;

    _isolate = await Isolate.spawn(_inferenceWorker, [
      receivePort.sendPort,
      rootToken,
      modelFile.path, // Pass file path instead of asset name
    ]);

    // _sendPort = await receivePort.first as SendPort; // REMOVE: This consumes the stream!

    // Listen for results
    receivePort.listen((message) {
      if (message is SendPort) {
        _sendPort = message; // Handshake received here
        debugPrint("[InferenceService] Handshake received. Pipeline ready.");
      } else if (message is InferenceResponse) {
        if (!message.isError) {
          _scoreController.add(message.score);
          _logInference(message.score);
        } else {
          debugPrint("[InferenceService] Error: ${message.errorMessage}");
        }
      }
    });

    debugPrint("[InferenceService] Initialized & Cache Cleared.");
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
      _logSink?.writeln('Timestamp,Raw_Score,Inference_Time_ms');
      debugPrint("[InferenceService] Logging to: ${logFile.path}");
    } catch (e) {
      debugPrint("[InferenceService] Failed to init logger: $e");
    }
  }

  void _logInference(double score) {
    if (_logSink != null) {
      final time = DateTime.now().toIso8601String();
      _logSink?.writeln(
        '$time,$score,',
      ); // Inference_Time_ms is not available here yet
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
        debugPrint("[InferenceService] Face detected: $rect.");

        // --- DEBUG: Main Thread Inference ---
        if (_debugInterpreter != null) {
          debugPrint(
            "[InferenceService] DEBUG: Running inference on Main Thread...",
          );
          try {
            final bytes = await tempFile.readAsBytes();
            final image = img.decodeImage(bytes);

            if (image != null) {
              // Crop & Resize (Simplified)
              // Assuming exact same logic as worker
              // Just for quick test
              final x = rect.left.toInt();
              final y = rect.top.toInt();
              final w = rect.width.toInt();
              final h = rect.height.toInt();

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
              final resized = img.copyResize(cropped, width: 224, height: 224);

              // Normalization
              final inputBuffer = Float32List(1 * 224 * 224 * 3);
              int index = 0;
              for (final pixel in resized) {
                inputBuffer[index++] = pixel.r / 255.0;
                inputBuffer[index++] = pixel.g / 255.0;
                inputBuffer[index++] = pixel.b / 255.0;
              }

              var inputShape = [
                1,
                20,
                224,
                224,
                3,
              ]; // The model expects 20 frames!
              // But we only have 1 frame here.
              // We must DUPLICATE this frame 20 times to fill the tensor if BATCH=1 doesn't work for model.
              // Wait, if model expects [1, 20, ...], we MUST provide [1, 20, ...].
              // If BATCH_SIZE=1, that was my logic variable, but MODEL is fixed structure.

              // CRITICAL: If model input is [1, 20, 224, 224, 3], and we pass [1, 1, ...], it will crash.
              // We need to fill the buffer with 20 copies of the same frame for this debug test.

              final fullInputBuffer = Float32List(1 * 20 * 224 * 224 * 3);
              for (int i = 0; i < 20; i++) {
                fullInputBuffer.setRange(
                  i * inputBuffer.length,
                  (i + 1) * inputBuffer.length,
                  inputBuffer,
                );
              }

              final outputBuffer = Float32List(1);
              _debugInterpreter!.run(
                fullInputBuffer.reshape([1, 20, 224, 224, 3]),
                outputBuffer.reshape([1, 1]),
              );

              final score = outputBuffer[0];
              debugPrint(
                "[InferenceService] DEBUG RESULT: $score (Scientific: ${score.toStringAsExponential()})",
              );
              _scoreController.add(score);
            }
          } catch (e) {
            debugPrint("[InferenceService] DEBUG Error: $e");
          }

          await tempFile.delete();
          return; // Skip Isolate
        }
        // ------------------------------------

        // Send to Isolate - Isolate becomes responsible for deletion
        debugPrint("Sending to Isolate.");
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
    _scoreController.close();
    _sendPort?.send('close');
    _isolate?.kill();
    // Final cleanup attempt
    _clearDiskCache();
  }

  // --- Isolate Worker ---

  static Future<void> _inferenceWorker(List<dynamic> args) async {
    print("[Isolate] Worker Start");
    final SendPort mainSendPort = args[0];
    final RootIsolateToken? rootToken = args[1];
    final String modelPath = args[2];

    if (rootToken != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken);
    }

    final receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort);

    // Initialize Interpreter from File
    Interpreter? interpreter;
    try {
      print("[Isolate] Loading model from $modelPath...");
      interpreter = Interpreter.fromFile(File(modelPath));
      print("[Isolate] Model loaded successfully.");
    } catch (e) {
      print("[Isolate] Model load failed: $e");
      mainSendPort.send(
        InferenceResponse(
          score: 0.0,
          isError: true,
          errorMessage: "Model load failed: $e",
        ),
      );
      return;
    }

    // Inference State
    final List<List<double>> frameQueue = [];

    // Model specific: Get Input Shape
    // Assuming [1, 20, 224, 224, 3]
    var inputShape = [1, 20, 224, 224, 3];
    try {
      // Try getting actual shape if possible, or fallback to fixed
      final tensor = interpreter.getInputTensor(0);
      inputShape = tensor.shape;
    } catch (e) {
      print(
        "[Isolate] Warning: Could not get input tensor shape, using default $inputShape",
      );
    }

    print("[Isolate] Expected Input Shape: $inputShape");

    await for (final message in receivePort) {
      if (message is InferenceRequest) {
        try {
          final file = File(message.imagePath);
          if (!await file.exists()) {
            print("[Isolate] File missing: ${message.imagePath}");
            continue;
          }

          // Decode
          final bytes = await file.readAsBytes();
          final image = img.decodeImage(bytes);

          // Delete file after read
          await file.delete();

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

          // Add to Queue
          debugPrint(
            "[Isolate] Buffering frame: ${frameQueue.length + 1}/$BATCH_SIZE",
          );
          if (frameQueue.length >= BATCH_SIZE) {
            frameQueue.removeAt(0);
          }
          frameQueue.add(frameData);

          // Run Inference if Queue Full
          if (frameQueue.length == BATCH_SIZE) {
            // Flatten
            // 20 * 224 * 224 * 3
            // Pre-allocate buffer reuse could be optimization later
            final inputBuffer = Float32List(1 * 20 * 224 * 224 * 3);
            int offset = 0;
            for (final frame in frameQueue) {
              for (int i = 0; i < frame.length; i++) {
                inputBuffer[offset++] = frame[i];
              }
            }

            // Output Buffer
            // Determine output shape
            var outputShape = [1, 1];
            try {
              outputShape = interpreter.getOutputTensor(0).shape;
            } catch (_) {}

            final outputSize = outputShape.reduce((a, b) => a * b);
            final outputBuffer = Float32List(outputSize);

            // Run Inference
            interpreter.run(
              inputBuffer.reshape(inputShape),
              outputBuffer.reshape(outputShape),
            );

            final score = outputBuffer[0];
            print(
              "[Isolate] Raw Output Score: $score (Scientific: ${score.toStringAsExponential()})",
            );
            mainSendPort.send(InferenceResponse(score: score));
          }
        } catch (e) {
          print("[Isolate] Processing Error: $e");
        }
      } else if (message == 'close') {
        interpreter?.close();
        Isolate.exit();
      }
    }
  }

  static List<double> _imageToFloat32(img.Image image) {
    // 224 * 224 * 3
    final buffer = List<double>.filled(224 * 224 * 3, 0.0);
    int index = 0;

    // Debug: Check First Pixel
    if (image.length > 0) {
      final p = image.first;
      print("[Isolate] Sample Pixel Input (R,G,B): ${p.r}, ${p.g}, ${p.b}");
      print(
        "[Isolate] Sample Pixel Normalized (0~1): ${p.r / 255.0}, ${p.g / 255.0}, ${p.b / 255.0}",
      );
    }

    // Iterate pixels - 'image' package standardizes memory layout
    for (final pixel in image) {
      buffer[index++] = pixel.r / 255.0;
      buffer[index++] = pixel.g / 255.0;
      buffer[index++] = pixel.b / 255.0;
    }
    return buffer;
  }
}
