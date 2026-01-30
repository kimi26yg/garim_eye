import Flutter
import UIKit
import WebRTC

@main
@objc class AppDelegate: FlutterAppDelegate {
  
  private var predictor: Any? = nil // Type 'Any' to avoid compile error before model exists
  
  // Native-First Pipeline
  private var customVideoSink: CustomVideoSink?
  private var nativeEventChannel: FlutterEventChannel?
  private var nativeControlChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
      
    let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
    let messenger = controller.binaryMessenger
    
    // Original Method Channel (Dart → Swift path)
    let channel = FlutterMethodChannel(name: "com.garim.eye/inference",
                                              binaryMessenger: messenger)
    
    if #available(iOS 14.0, *) {
        self.predictor = DeepfakePredictor()
        
        // Initialize Native-First Pipeline
        self.customVideoSink = CustomVideoSink()
        
        // EventChannel for Native → Dart results
        nativeEventChannel = FlutterEventChannel(
            name: "com.garim.eye/native_inference",
            binaryMessenger: messenger
        )
        nativeEventChannel?.setStreamHandler(customVideoSink!)
        
        // MethodChannel for control (attach/detach sink)
        nativeControlChannel = FlutterMethodChannel(
            name: "com.garim.eye/native_control",
            binaryMessenger: messenger
        )
        
        // Set control method handler
        nativeControlChannel?.setMethodCallHandler { [weak self] (call, result) in
            self?.handleNativeControl(call: call, result: result)
        }
    }

    channel.setMethodCallHandler({
      [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
        
      if call.method == "processFrame" {
          guard let args = call.arguments as? FlutterStandardTypedData else {
              result(FlutterError(code: "INVALID_ARGS", message: "Image bytes required", details: nil))
              return
          }
          
          if #available(iOS 14.0, *) {
              if let predictor = self?.predictor as? DeepfakePredictor {
                   // Run on background thread
                   DispatchQueue.global(qos: .userInteractive).async {
                       let response = predictor.processFrame(imageData: args)
                       DispatchQueue.main.async {
                           result(response)
                       }
                   }
              } else {
                  result(FlutterError(code: "MODEL_NOT_READY", message: "Predictor not initialized", details: nil))
              }
          } else {
              result(FlutterError(code: "UNSUPPORTED_OS", message: "iOS 14.0+ required", details: nil))
          }
      } else {
        result(FlutterMethodNotImplemented)
      }
    })

    GeneratedPluginRegistrant.register(with: self)
    
    // Trigger plugin capture
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue]
        )
    }
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
    // MARK: - Native Control Handler
    
    override init() {
        super.init()
        // Swizzle FlutterWebRTCPlugin to capture instance
        MethodSwizzler.swizzleWebRTCPlugin()
    }
  
    private func handleNativeControl(call: FlutterMethodCall, result: @escaping FlutterResult) {
      if call.method == "attach" {
          guard let args = call.arguments as? [String: Any],
                let trackId = args["trackId"] as? String else {
              result(FlutterError(code: "INVALID_ARGS", message: "trackId required", details: nil))
              return
          }
          
          guard let plugin = capturedWebRTCPlugin else {
              result(FlutterError(code: "PLUGIN_NOT_FOUND", message: "FlutterWebRTCPlugin not captured", details: nil))
              return
          }
          
          print("🔵 [AppDelegate] Attaching sink to track: \(trackId)")
          
          // Use KVC/Reflection to access localTracks property
          // Note: "localTracks" is a property of FlutterWebRTCPlugin
          if let localTracks = plugin.value(forKey: "localTracks") as? [String: Any] {
              if let track = localTracks[trackId] as? RTCVideoTrack {
                  print("✅ [AppDelegate] Track found! Adding renderer.")
                  track.add(self.customVideoSink!)
                  result(true)
                  return
              }
          }
          
          // Check remote tracks via peer connections if needed (omitted for local preview focus)
          // Ideally check: Plugin -> peerConnections -> remoteTracks
          
          print("🔴 [AppDelegate] Track not found with ID: \(trackId)")
          result(FlutterError(code: "TRACK_NOT_FOUND", message: "Track not found", details: nil))
          
      } else if call.method == "detach" {
          // Detach logic (simplified)
           print("🔵 [AppDelegate] Detach called")
           // We might need to keep track of attached tracks to remove them
           result(true)
      } else {
          result(FlutterMethodNotImplemented)
      }
    }
}
