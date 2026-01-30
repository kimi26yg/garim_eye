import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  
  private var predictor: Any? = nil // Type 'Any' to avoid compile error before model exists

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
      
    let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(name: "com.garim.eye/inference",
                                              binaryMessenger: controller.binaryMessenger)
    
    if #available(iOS 14.0, *) {
        self.predictor = DeepfakePredictor()
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
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
