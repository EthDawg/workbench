import AppKit
import ToolbarCore

public enum ToolbarGeometry {
    /// Dock the resting element, not the row's centre. The same element stays
    /// under the pointer at all eight anchors as the measured content grows
    /// inward; `restingWidth` is the measured width of `[glyph][next action]`.
    public static func frame(size: NSSize, restingWidth: CGFloat, anchor: ToolbarAnchor,
                             screen: NSRect, inset: CGFloat = 16) -> NSRect {
        let width = min(max(1, size.width), screen.width)
        let height = min(max(1, size.height), screen.height)
        let mx = min(inset, max(0, (screen.width - width) / 2))
        let my = min(inset, max(0, (screen.height - height) / 2))
        let x: CGFloat
        switch anchor {
        case .topLeft, .left, .bottomLeft: x = screen.minX + mx
        case .topRight, .right, .bottomRight: x = screen.maxX - mx - width
        case .top, .bottom: x = screen.midX - restingWidth / 2
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

    /// The resting element's frame: at its dock, or at its free origin kept whole on `screen`.
    public static func restingFrame(size: NSSize, position: ToolbarPosition, screen: NSRect) -> NSRect {
        switch position {
        case .docked(let anchor): return frame(size: size, restingWidth: size.width, anchor: anchor, screen: screen)
        case .free(let origin): return clamp(NSRect(origin: origin, size: size), to: screen)
        }
    }

    /// A row grows inward: a dock by its anchor, a free position toward the middle of its
    /// screen. That depends only on where the resting element is, so no reveal, mode or
    /// label ever turns the row round under the pointer.
    public static func growsLeftward(_ position: ToolbarPosition, restingSize: NSSize, screen: NSRect) -> Bool {
        switch position {
        case .docked(let anchor): return anchor.growsLeftward
        case .free: return restingFrame(size: restingSize, position: position, screen: screen).midX > screen.midX
        }
    }

    /// The anchor the row is drawn for: its dock, or the side a free row grows from.
    public static func rowAnchor(_ position: ToolbarPosition, restingSize: NSSize, screen: NSRect) -> ToolbarAnchor {
        if case .docked(let anchor) = position { return anchor }
        return growsLeftward(position, restingSize: restingSize, screen: screen) ? .right : .left
    }

    /// The window for a row of `size`. The resting element keeps its place and the row
    /// grows inward from it, so revealing or collapsing never moves what is under the pointer.
    public static func frame(size: NSSize, restingSize: NSSize, position: ToolbarPosition, screen: NSRect) -> NSRect {
        if case .docked(let anchor) = position {
            return frame(size: size, restingWidth: restingSize.width, anchor: anchor, screen: screen)
        }
        let resting = restingFrame(size: restingSize, position: position, screen: screen)
        let width = min(max(1, size.width), screen.width), height = min(max(1, size.height), screen.height)
        let x = growsLeftward(position, restingSize: restingSize, screen: screen) ? resting.maxX - width : resting.minX
        return NSRect(x: min(max(screen.minX, x), screen.maxX - width),
                      y: min(max(screen.minY, resting.minY), screen.maxY - height), width: width, height: height)
    }

    /// A frame kept whole inside `screen`, shrunk only if it is larger than the screen.
    static func clamp(_ frame: NSRect, to screen: NSRect) -> NSRect {
        let width = min(max(1, frame.width), screen.width), height = min(max(1, frame.height), screen.height)
        let x = frame.minX.isFinite ? frame.minX : screen.minX, y = frame.minY.isFinite ? frame.minY : screen.minY
        return NSRect(x: min(max(screen.minX, x), screen.maxX - width),
                      y: min(max(screen.minY, y), screen.maxY - height), width: width, height: height)
    }
}

/// Where the tools rest (#163): at a named dock, or wherever they were dragged. A free
/// position is the resting element's origin, so a reveal or collapse never moves it.
public enum ToolbarPosition: Equatable, Sendable {
    case docked(ToolbarAnchor)
    case free(CGPoint)
}

/// A press on the glyph, the next action or the row's empty chrome moves the toolbar only
/// after this much travel; less is a click and its action runs (#163). StageKit's
/// `FloatingControlPlacement.dragThreshold` is the same value for other floating controls.
public enum ToolbarDrag {
    public static let threshold: CGFloat = 4
    public static func isDrag(from start: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - start.x, point.y - start.y) >= threshold
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
