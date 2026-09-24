import AppKit
import ToolbarCore

public enum ToolbarGeometry {
    /// Dock the glyph, not the row's centre. The same glyph stays under the
    /// pointer at all eight anchors as the measured content grows inward.
    public static func frame(size: NSSize, glyphWidth: CGFloat, anchor: ToolbarAnchor,
                             screen: NSRect, inset: CGFloat = 16) -> NSRect {
        let width = min(max(1, size.width), screen.width)
        let height = min(max(1, size.height), screen.height)
        let mx = min(inset, max(0, (screen.width - width) / 2))
        let my = min(inset, max(0, (screen.height - height) / 2))
        let x: CGFloat
        switch anchor {
        case .topLeft, .left, .bottomLeft: x = screen.minX + mx
        case .topRight, .right, .bottomRight: x = screen.maxX - mx - width
        case .top, .bottom: x = screen.midX - glyphWidth / 2
        }
        let y: CGFloat
        switch anchor {
        case .topLeft, .top, .topRight: y = screen.maxY - my - height
        case .left, .right: y = screen.midY - height / 2
        case .bottomLeft, .bottom, .bottomRight: y = screen.minY + my
        }
        return NSRect(x: min(max(screen.minX + mx, x), screen.maxX - mx - width),
                      y: y, width: width, height: height)
    }
}

/// Filters synthetic tracking-area crossings caused by geometry changes. Only
/// actual pointer movement delivers crossings; the host reconciles once after
/// a geometry or surface change even when the pointer has not moved.
public struct ToolbarPointerGate {
    public private(set) var lastPoint: NSPoint
    public private(set) var inside = false
    public init(point: NSPoint) { lastPoint = point }
    public mutating func settled(at point: NSPoint, inside: Bool) {
        lastPoint = point; self.inside = inside
    }
    public mutating func crossing(at point: NSPoint, inside: Bool) -> ToolbarEvent? {
        guard point != lastPoint else { return nil }
        lastPoint = point
        guard self.inside != inside else { return nil }
        self.inside = inside
        return inside ? .pointerEntered : .pointerLeft
    }
}
