import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
  fputs("Usage: swift generate_macos_app_icon.swift <source.png> <output.appiconset>\n", stderr)
  exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = NSImage(contentsOf: sourceURL) else {
  fputs("Could not read source icon: \(sourceURL.path)\n", stderr)
  exit(1)
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
    NSBezierPath(
      roundedRect: frame,
      xRadius: cornerRadius,
      yRadius: cornerRadius
    ).addClip()
    source.draw(in: canvas, from: .zero, operation: .copy, fraction: 1)
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
