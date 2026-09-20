import AppKit

/// Reference helper for StageMark's existing unflipped AppKit SceneRenderer.
/// Source rectangles use PNG top-left coordinates; target uses AppKit bottom-left.
struct GripSource {
    let imageSize: CGSize
    let phone: CGRect
}

struct GripPlacement {
    let palm: CGRect
    let fingers: CGRect

    init(source: GripSource, targetPhone: CGRect) {
        precondition(source.phone.height > 0 && targetPhone.height > 0)
        let scale = targetPhone.height / source.phone.height
        let sourceBottom = source.imageSize.height - source.phone.maxY
        let y = targetPhone.minY - sourceBottom * scale
        let size = CGSize(width: source.imageSize.width * scale,
                          height: source.imageSize.height * scale)
        palm = CGRect(origin: CGPoint(x: targetPhone.maxX - source.phone.maxX * scale, y: y), size: size)
        fingers = CGRect(origin: CGPoint(x: targetPhone.minX - source.phone.minX * scale, y: y), size: size)
    }

    /// Call after drawing the background, immediately before drawing the phone.
    /// Both NSImages must retain the full canvas declared in manifest.json.
    func draw(palmImage: NSImage, fingerImage: NSImage) {
        palmImage.draw(in: palm, from: .zero, operation: .sourceOver, fraction: 1)
        fingerImage.draw(in: fingers, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
