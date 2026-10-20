import Cocoa
import FlutterMacOS

private func macIconColor(_ hex: UInt32) -> NSColor {
  NSColor(
    srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
    green: CGFloat((hex >> 8) & 0xff) / 255,
    blue: CGFloat(hex & 0xff) / 255,
    alpha: CGFloat((hex >> 24) & 0xff) / 255
  )
}

private func macIconColor(_ value: Any?, fallback: NSColor) -> NSColor {
  guard let number = value as? NSNumber else { return fallback }
  return macIconColor(UInt32(truncatingIfNeeded: number.intValue))
}

private func renderMacAppIcon(foreground: NSColor, background: NSColor) -> NSImage {
  let size = CGFloat(1024)
  let image = NSImage(size: NSSize(width: size, height: size))
  image.lockFocus()
  let canvas = NSRect(x: 0, y: 0, width: size, height: size)
  let top = background.blended(withFraction: 0.14, of: .white) ?? background
  NSGradient(starting: top, ending: background)?.draw(in: canvas, angle: -90)

  let glow = NSGradient(colors: [
    foreground.withAlphaComponent(0.21),
    foreground.withAlphaComponent(0.045),
    foreground.withAlphaComponent(0),
  ])
  glow?.draw(
    fromCenter: NSPoint(x: 325, y: 780), radius: 20,
    toCenter: NSPoint(x: 325, y: 780), radius: 690,
    options: [.drawsAfterEndingLocation]
  )

  // macOS applies its own rounded mask to app icons, so draw a full-bleed
  // square and keep the GhostBox mark inset to a regular macOS icon safe area.
  func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    NSPoint(x: x * 14.5 + 48, y: size - (y * 14.5 + 41))
  }
  let ghost = NSBezierPath()
  ghost.move(to: point(17.6, 22.4))
  ghost.curve(
    to: point(46.4, 22.4), controlPoint1: point(17.6, 6.5), controlPoint2: point(46.4, 6.5))
  ghost.line(to: point(46.4, 30))
  ghost.curve(to: point(48.7, 50.1), controlPoint1: point(46.4, 40), controlPoint2: point(49, 44))
  ghost.curve(to: point(44.5, 56), controlPoint1: point(48.7, 54), controlPoint2: point(46.6, 56))
  ghost.curve(to: point(38, 46.5), controlPoint1: point(41, 56), controlPoint2: point(38.8, 52))
  ghost.curve(to: point(37, 46.5), controlPoint1: point(37.9, 45), controlPoint2: point(37.1, 45))
  ghost.curve(to: point(32, 57), controlPoint1: point(36.4, 52), controlPoint2: point(35, 57))
  ghost.curve(to: point(27, 46.5), controlPoint1: point(29, 57), controlPoint2: point(27.6, 52))
  ghost.curve(to: point(26, 46.5), controlPoint1: point(26.9, 45), controlPoint2: point(26.1, 45))
  ghost.curve(to: point(19.5, 56), controlPoint1: point(25.2, 52), controlPoint2: point(23, 56))
  ghost.curve(to: point(15.3, 50.1), controlPoint1: point(17.4, 56), controlPoint2: point(15.3, 54))
  ghost.curve(to: point(17.6, 30), controlPoint1: point(15, 44), controlPoint2: point(17.6, 40))
  ghost.close()

  let shadow = NSShadow()
  shadow.shadowColor = foreground.withAlphaComponent(0.2)
  shadow.shadowBlurRadius = 26
  shadow.shadowOffset = NSSize(width: 0, height: -8)
  shadow.set()
  NSGradient(
    starting: foreground.blended(withFraction: 0.18, of: .white) ?? foreground,
    ending: foreground.blended(withFraction: 0.22, of: background) ?? foreground)?
    .draw(in: ghost, angle: -90)
  NSShadow().set()

  let eyeColor = background.blended(withFraction: 0.48, of: .black) ?? background
  for x in [26.9, 37.1] {
    let center = point(CGFloat(x), 21)
    let eye = NSBezierPath(
      ovalIn: NSRect(x: center.x - 48, y: center.y - 54, width: 96, height: 108))
    eyeColor.setFill()
    eye.fill()
    let glint = NSBezierPath(
      ovalIn: NSRect(x: center.x - 24, y: center.y + 11, width: 24, height: 24))
    NSColor.white.withAlphaComponent(0.56).setFill()
    glint.fill()
  }
  image.unlockFocus()
  return image
}

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
        let variant = arguments["variant"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      let palettes: [String: (UInt32, UInt32)] = [
        "classic": (0xffb9_cbe7, 0xff10_1a2c), "midnight": (0xff8b_b9f4, 0xff07_0612),
        "graphite": (0xffb6_bdc9, 0xff0d_0f13), "ocean": (0xff4d_c9e8, 0xff06_1522),
        "emerald": (0xff7c_ddb6, 0xff09_1812), "amethyst": (0xffb9_a0ff, 0xff12_0d20),
        "sapphire": (0xff78_a9ff, 0xff09_1426), "ruby": (0xffff_8295, 0xff1a_1018),
        "lavender": (0xffc7_b5ff, 0xff17_1326), "forest": (0xff8b_cf9b, 0xff0d_1b15),
        "sand": (0xffe5_bf8c, 0xff20_1a12), "daylight": (0xff35_5fbb, 0xffe8_eef8),
        "paper": (0xff68_57b8, 0xfff0_ebe2), "mist": (0xff34_7f8a, 0xffe5_eeee),
        "aurora": (0xff53_d6c2, 0xff07_1a20), "obsidian": (0xff90_a4c3, 0xff11_1722),
        "sunset": (0xffff_9568, 0xff20_120f), "arctic": (0xff24_7d9b, 0xffe2_f0f4),
      ]
      let palette = palettes[variant] ?? palettes["midnight"]!
      let foreground =
        variant == "custom"
        ? macIconColor(arguments["foreground"], fallback: macIconColor(palette.0))
        : macIconColor(palette.0)
      let background =
        variant == "custom"
        ? macIconColor(arguments["background"], fallback: macIconColor(palette.1))
        : macIconColor(palette.1)
      NSApp.applicationIconImage = renderMacAppIcon(foreground: foreground, background: background)
      result(true)
    }

    super.awakeFromNib()
  }
}
