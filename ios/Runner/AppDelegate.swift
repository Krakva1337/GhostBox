import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "GhostBoxAppIcon")
    let channel = FlutterMethodChannel(
      name: "app.ghostbox.ghostbox/app_icon",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "setAppIcon",
            let arguments = call.arguments as? [String: Any],
            let variant = arguments["variant"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard UIApplication.shared.supportsAlternateIcons else {
        result(false)
        return
      }
      guard variant != "custom" else {
        result(false)
        return
      }
      let iconName = variant == "aurora" ? nil : "AppIcon_\(variant.capitalized)"
      UIApplication.shared.setAlternateIconName(iconName) { error in
        if let error = error {
          result(FlutterError(code: "icon_change_failed", message: error.localizedDescription, details: nil))
        } else {
          result(true)
        }
      }
    }
  }
}
