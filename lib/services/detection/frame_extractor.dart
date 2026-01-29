import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class FrameExtractor {
  final StreamController<Uint8List> _frameController =
      StreamController<Uint8List>.broadcast();
  bool _isExtracting = false;

  Stream<Uint8List> get frameStream => _frameController.stream;

  /// Starts extracting frames from the given [track].
  Future<void> startExtraction(MediaStreamTrack track) async {
    if (_isExtracting) return;
    _isExtracting = true;
    debugPrint("[FrameExtractor] Starting extraction on track ${track.id}");

    // Start extraction loop WITHOUT await to run in parallel
    _extractionLoop(track);
  }

  Future<void> _extractionLoop(MediaStreamTrack track) async {
    while (_isExtracting) {
      final start = DateTime.now();
      try {
        // Strategy D: captureFrame returns ByteBuffer (PNG encoded usually)
        dynamic result = await track.captureFrame();

        if (result is ByteBuffer) {
          _frameController.add(result.asUint8List());
        } else if (result is List<int>) {
          _frameController.add(Uint8List.fromList(result));
        }
      } catch (e) {
        debugPrint("[FrameExtractor] Error: $e");
      }

      final elapsed = DateTime.now().difference(start).inMilliseconds;
      // Target ~10 FPS (100ms interval). Adjust delay based on processing time.
      final delay = (100 - elapsed).clamp(10, 100);
      await Future.delayed(Duration(milliseconds: delay));
    }
  }

  void stopExtraction() {
    _isExtracting = false;
    debugPrint("[FrameExtractor] Stopped extraction");
  }

  void dispose() {
    stopExtraction();
    _frameController.close();
  }
}
