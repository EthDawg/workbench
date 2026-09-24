import AppKit
let directory = CommandLine.arguments[1]
let preview = CommandLine.arguments.contains("--preview")
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = CGFloat(size), inset = s * 0.045
    let shape = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2), xRadius: s * 0.21, yRadius: s * 0.21)
    NSGradient(starting: preview ? NSColor(red: 0.43, green: 0.23, blue: 0.66, alpha: 1) : NSColor(red: 0.15, green: 0.20, blue: 0.26, alpha: 1), ending: NSColor(red: 0.035, green: 0.055, blue: 0.09, alpha: 1))!.draw(in: shape, angle: -65)
    NSColor(red: 0.43, green: 0.89, blue: 0.73, alpha: 1).setFill()
    for (i, height) in [0.19, 0.36, 0.54, 0.40, 0.25].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: s * (0.235 + Double(i) * 0.115), y: s * (0.5 - height / 2), width: s * 0.07, height: s * height), xRadius: s * 0.035, yRadius: s * 0.035).fill()
    }
    if preview {
        let badge = NSRect(x: s * 0.60, y: s * 0.08, width: s * 0.30, height: s * 0.30)
        NSColor.white.setFill(); NSBezierPath(roundedRect: badge, xRadius: s * 0.07, yRadius: s * 0.07).fill()
        let font = NSFont.systemFont(ofSize: s * 0.235, weight: .heavy)
        let text = NSAttributedString(string: "P", attributes: [.font: font, .foregroundColor: NSColor(srgbRed: 0.34, green: 0.16, blue: 0.55, alpha: 1)])
        text.draw(at: NSPoint(x: badge.midX - text.size().width / 2, y: badge.midY - text.size().height / 2))
    }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let data = bitmap.representation(using: .png, properties: [:])!
    if size <= 512 { try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("icon_\(size)x\(size).png")) }
    if size >= 32 { let base = size / 2; try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("icon_\(base)x\(base)@2x.png")) }
}
