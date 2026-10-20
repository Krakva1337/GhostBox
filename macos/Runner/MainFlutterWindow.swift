import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let iconChannel = FlutterMethodChannel(
      name: "app.ghostbox.ghostbox/app_icon",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    iconChannel.setMethodCallHandler { call, result in
      guard call.method == "setAppIcon",
            let arguments = call.arguments as? [String: Any],
            let variant = arguments["variant"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      let icon: NSImage?
      if variant == "custom",
         let arguments = call.arguments as? [String: Any],
         let png = arguments["customPng"] as? FlutterStandardTypedData {
        icon = NSImage(data: png.data)
      } else {
        let relativePath = "Contents/Frameworks/App.framework/Resources/flutter_assets/assets/icons/\(variant).png"
        let path = Bundle.main.bundleURL.appendingPathComponent(relativePath)
        icon = NSImage(contentsOf: path)
      }
      guard let icon else {
        result(false)
        return
      }
      NSApp.applicationIconImage = icon
      result(true)
    }

    super.awakeFromNib()
  }
}
