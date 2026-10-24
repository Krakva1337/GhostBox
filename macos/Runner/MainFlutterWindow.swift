import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    let visibleFrame = (self.screen ?? NSScreen.main)?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let windowSize = NSSize(
      width: min(720, visibleFrame.width * 0.88),
      height: min(860, visibleFrame.height * 0.92)
    )
    self.contentMinSize = NSSize(width: 420, height: 640)
    self.setFrame(NSRect(origin: .zero, size: windowSize), display: true)
    self.center()

    // Keep the bundle's static AppIcon. macOS applies the user's Dock icon
    // appearance itself; overriding NSApp.applicationIconImage bypasses it.
    RegisterGeneratedPlugins(registry: flutterViewController)
    super.awakeFromNib()
  }
}
