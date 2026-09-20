import AppKit

// Resize the PNG produced by the repository's canonical scripts/icon.swift.
// The original five-bar artwork, colors and rounded shape are unchanged.
// Usage: swift render-assets.swift canonical-icon.png BrowserExtension
let arguments = CommandLine.arguments
guard arguments.count == 3, let source = NSImage(contentsOfFile: arguments[1]) else {
    fatalError("Usage: render-assets.swift canonical-icon.png extension-directory")
}
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)

func writePNG(width: Int, height: Int, to destination: URL, draw: (CGFloat, CGFloat) -> Void) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Could not create icon bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill(using: .copy)
    draw(CGFloat(width), CGFloat(height))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode icon") }
    try data.write(to: destination, options: .atomic)
}

for size in [16, 32, 48, 128] {
    try writePNG(width: size, height: size, to: output.appendingPathComponent("icons/icon\(size).png")) { width, height in
        // Original artwork has a 4.5% inset. At 128px the visible rounded
        // square occupies 96px, with at least 16px transparent padding.
        let artworkWidth = size == 128 ? 95.0 : Double(size) * 0.875
        let sourceWidth = CGFloat(artworkWidth / 0.91)
        source.draw(in: NSRect(x: (width - sourceWidth) / 2, y: (height - sourceWidth) / 2,
            width: sourceWidth, height: sourceWidth), from: .zero, operation: .sourceOver, fraction: 1)
    }
}

try writePNG(width: 440, height: 280, to: output.appendingPathComponent("store/promo-440x280.png")) { width, height in
    NSColor(red: 0.078, green: 0.169, blue: 0.192, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSColor(red: 0.604, green: 0.941, blue: 0.776, alpha: 0.11).setFill()
    NSBezierPath(roundedRect: NSRect(x: 125, y: 45, width: 190, height: 190), xRadius: 48, yRadius: 48).fill()
    source.draw(in: NSRect(x: 140, y: 60, width: 160, height: 160), from: .zero, operation: .sourceOver, fraction: 1)
}
