import Foundation
import WebRTC
import Flutter

// MARK: - Custom Video Sink for Deepfake Detection
class CustomVideoSink: NSObject {
    // Reference to predictor
    private var predictor: DeepfakePredictor?
    
    // EventSink for sending results to Dart
    private var eventSink: FlutterEventSink?
    
    // Thread-safe processing flag
    private var isProcessing = false
    private let processingQueue = DispatchQueue(label: "com.garim.eye.video.processing")
    
    // Statistics
    private var frameCount: Int = 0
    private var lastLogTime: CFAbsoluteTime = 0
    
    override init() {
        super.init()
        if #available(iOS 14.0, *) {
            self.predictor = DeepfakePredictor()
            print("✅ [CustomVideoSink] Initialized with predictor")
        } else {
            print("⚠️ [CustomVideoSink] iOS 14.0+ required for predictor")
        }
    }
}

// MARK: - RTCVideoRenderer Protocol
extension CustomVideoSink: RTCVideoRenderer {
    func setSize(_ size: CGSize) {
        // Required by protocol, but we don't need to do anything
        // Frame size is handled per-frame
    }
    
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame = frame else {
            return
        }
        
        // Frame statistics
        frameCount += 1
        let currentTime = CFAbsoluteTimeGetCurrent()
        if currentTime - lastLogTime >= 1.0 {
            print("📊 [CustomVideoSink] Received \(frameCount) frames in last second")
            frameCount = 0
            lastLogTime = currentTime
        }
        
        // Use autoreleasepool for memory management
        autoreleasepool {
            // Skip if already processing (prevent queue buildup)
            processingQueue.async { [weak self] in
                guard let self = self else { return }
                
                if self.isProcessing {
                    // Skip this frame
                    return
                }
                
                self.isProcessing = true
                defer { self.isProcessing = false }
                
                // Extract CVPixelBuffer
                if let pixelBuffer = self.extractPixelBuffer(from: frame) {
                    self.processPixelBuffer(pixelBuffer)
                } else {
                    print("⚠️ [CustomVideoSink] Failed to extract CVPixelBuffer")
                }
            }
        }
    }
}

// MARK: - CVPixelBuffer Extraction
extension CustomVideoSink {
    private func extractPixelBuffer(from frame: RTCVideoFrame) -> CVPixelBuffer? {
        let buffer = frame.buffer
        
        // Case A: Direct CVPixelBuffer access (optimal)
        if let cvBuffer = buffer as? RTCCVPixelBuffer {
            print("✅ [CustomVideoSink] Direct CVPixelBuffer access")
            return cvBuffer.pixelBuffer
        }
        
        // For now,  skip I420 buffers to avoid WebRTC API compatibility issues
        // TODO: Implement I420 conversion when WebRTC API is stable
        print("🔴 [CustomVideoSink] Unsupported buffer type: \(type(of: buffer))")
        print("⚠️ [CustomVideoSink] Only RTCCVPixelBuffer supported currently")
        return nil
    }
}

// MARK: - Frame Processing
extension CustomVideoSink {
    private func processPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        guard let predictor = self.predictor else {
            print("⚠️ [CustomVideoSink] Predictor not available")
            return
        }
        
        // Call DeepfakePredictor's new method
        if let result = predictor.processPixelBuffer(pixelBuffer) {
            sendResultToDart(result)
        }
    }
    
    private func sendResultToDart(_ result: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let sink = self.eventSink else {
                return
            }
            sink(result)
        }
    }
}

// MARK: - FlutterStreamHandler
extension CustomVideoSink: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, 
                  eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        print("✅ [CustomVideoSink] EventSink attached")
        self.eventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        print("⚠️ [CustomVideoSink] EventSink detached")
        self.eventSink = nil
        return nil
    }
}
