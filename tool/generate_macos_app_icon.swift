import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
  fputs("Usage: swift generate_macos_app_icon.swift <source.png> <output.appiconset>\n", stderr)
  exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard NSImage(contentsOf: sourceURL) != nil else {
  fputs("Could not read source icon: \(sourceURL.path)\n", stderr)
  exit(1)
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
  NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

func iconPoint(_ x: CGFloat, _ y: CGFloat, scale: CGFloat, size: CGFloat) -> NSPoint {
  NSPoint(x: (size - scale * 64) / 2 + x * scale,
          y: size - ((size - scale * 64) / 2 + y * scale))
}

func ghostPath(scale: CGFloat, size: CGFloat) -> NSBezierPath {
  let path = NSBezierPath()
  func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    iconPoint(x, y, scale: scale, size: size)
  }

  path.move(to: p(17.6, 22.4))
  path.curve(to: p(46.4, 22.4), controlPoint1: p(17.6, 3.5), controlPoint2: p(46.4, 3.5))
  path.line(to: p(46.4, 30))
  path.curve(to: p(48.7, 50.1), controlPoint1: p(46.4, 40), controlPoint2: p(49, 44))
  path.curve(to: p(44.5, 56), controlPoint1: p(48.7, 54), controlPoint2: p(46.6, 56))
  path.curve(to: p(38, 46.5), controlPoint1: p(41, 56), controlPoint2: p(38.8, 52))
  path.curve(to: p(37, 46.5), controlPoint1: p(37.9, 45), controlPoint2: p(37.1, 45))
  path.curve(to: p(32, 57), controlPoint1: p(36.4, 52), controlPoint2: p(35, 57))
  path.curve(to: p(27, 46.5), controlPoint1: p(29, 57), controlPoint2: p(27.6, 52))
  path.curve(to: p(26, 46.5), controlPoint1: p(26.9, 45), controlPoint2: p(26.1, 45))
  path.curve(to: p(19.5, 56), controlPoint1: p(25.2, 52), controlPoint2: p(23, 56))
  path.curve(to: p(15.3, 50.1), controlPoint1: p(17.4, 56), controlPoint2: p(15.3, 54))
  path.curve(to: p(17.6, 30), controlPoint1: p(15, 44), controlPoint2: p(17.6, 40))
  path.close()
  return path
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
do {
  try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
  for pixels in sizes {
    let size = CGFloat(pixels)
    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixels,
      pixelsHigh: pixels,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
      throw NSError(domain: "GhostBoxIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create \(pixels)px bitmap"])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    canvas.fill()

    let inset = size * 0.047
    let frame = canvas.insetBy(dx: inset, dy: inset)
    let cornerRadius = frame.width * 0.235
    let backgroundPath = NSBezierPath(
      roundedRect: frame,
      xRadius: cornerRadius,
      yRadius: cornerRadius
    )
    backgroundPath.addClip()
    // The packaged icon uses GhostBox's default Midnight appearance. At
    // runtime the Dock icon follows the selected macOS theme.
    NSGradient(colors: [color(16, 28, 48), color(7, 13, 24)])?.draw(in: frame, angle: 90)

    // Keep the full background while leaving more breathing room around the mascot.
    let mascotScale = size * 0.90 / 64
    color(139, 185, 244).setFill()
    ghostPath(scale: mascotScale, size: size).fill()
    let eyeRadiusX = mascotScale * 3.3
    let eyeRadiusY = mascotScale * 3.7
    color(17, 21, 30).setFill()
    for eyeX: CGFloat in [26.9, 37.1] {
      let center = iconPoint(eyeX, 21, scale: mascotScale, size: size)
      NSBezierPath(ovalIn: NSRect(x: center.x - eyeRadiusX,
                                  y: center.y - eyeRadiusY,
                                  width: eyeRadiusX * 2,
                                  height: eyeRadiusY * 2)).fill()
    }
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw NSError(domain: "GhostBoxIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode \(pixels)px PNG"])
    }
    let filename: String
    switch pixels {
    case 16, 32, 128, 256, 512, 1024: filename = "app_icon_\(pixels).png"
    case 64: filename = "app_icon_64.png"
    default: filename = "app_icon_\(pixels).png"
    }
    try png.write(to: outputURL.appendingPathComponent(filename), options: .atomic)
  }
} catch {
  fputs("Could not generate rounded macOS app icons: \(error)\n", stderr)
  exit(1)
}
