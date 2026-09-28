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

    /// The resting element's frame: at its dock, or at its free position kept whole on `screen`.
    public static func restingFrame(size: NSSize, position: ToolbarPosition, screen: NSRect) -> NSRect {
        switch position {
        case .docked(let anchor): return frame(size: size, restingWidth: size.width, anchor: anchor, screen: screen)
        case .free(let free): return clamp(free.restingFrame(size: size), to: screen)
        }
    }

    /// A row grows inward: a dock by its anchor, a free position by the side decided when
    /// it was released. Neither depends on the resting element's width, so no reveal, mode
    /// or live label ever turns the row round under the pointer.
    public static func growsLeftward(_ position: ToolbarPosition) -> Bool {
        switch position {
        case .docked(let anchor): return anchor.growsLeftward
        case .free(let free): return free.growsLeftward
        }
    }

    /// The anchor the row is drawn for: its dock, or the side a free row grows from.
    public static func rowAnchor(_ position: ToolbarPosition) -> ToolbarAnchor {
        if case .docked(let anchor) = position { return anchor }
        return growsLeftward(position) ? .right : .left
    }

    /// The window for a row of `size`. The resting element keeps its place and the row
    /// grows inward from it, so revealing or collapsing never moves what is under the pointer.
    public static func frame(size: NSSize, restingSize: NSSize, position: ToolbarPosition, screen: NSRect) -> NSRect {
        if case .docked(let anchor) = position {
            return frame(size: size, restingWidth: restingSize.width, anchor: anchor, screen: screen)
        }
        let resting = restingFrame(size: restingSize, position: position, screen: screen)
        let width = min(max(1, size.width), screen.width), height = min(max(1, size.height), screen.height)
        let x = growsLeftward(position) ? resting.maxX - width : resting.minX
        return NSRect(x: min(max(screen.minX, x), screen.maxX - width),
                      y: min(max(screen.minY, resting.midY - height / 2), screen.maxY - height), width: width, height: height)
    }

    /// A frame kept whole inside `screen`, shrunk only if it is larger than the screen.
    static func clamp(_ frame: NSRect, to screen: NSRect) -> NSRect {
        let width = min(max(1, frame.width), screen.width), height = min(max(1, frame.height), screen.height)
        let x = frame.minX.isFinite ? frame.minX : screen.minX, y = frame.minY.isFinite ? frame.minY : screen.minY
        return NSRect(x: min(max(screen.minX, x), screen.maxX - width),
                      y: min(max(screen.minY, y), screen.maxY - height), width: width, height: height)
    }
}

/// Where the tools rest (#163): at a named dock, or wherever they were dragged.
public enum ToolbarPosition: Equatable, Sendable {
    case docked(ToolbarAnchor)
    case free(ToolbarFreePosition)
}

/// A free position. The side the row grows toward is decided once, when the toolbar is
/// released (or when an older save is first read), and kept with the position. The glyph's
/// side of the resting element is what is pinned: its left edge for a row that grows
/// rightward, its right edge for one that grows leftward. So a resting element that changes
/// width, as live labels do, never moves its glyph, and only a new placement turns it round.
public struct ToolbarFreePosition: Equatable, Sendable {
    /// The glyph's edge of the resting element, in screen coordinates.
    public var glyphEdge: CGFloat
    /// The resting element's vertical centre.
    public var centreY: CGFloat
    /// The row grows leftward from its glyph, toward the middle of its display.
    public var growsLeftward: Bool

    public init(glyphEdge: CGFloat, centreY: CGFloat, growsLeftward: Bool) {
        self.glyphEdge = glyphEdge; self.centreY = centreY; self.growsLeftward = growsLeftward
    }

    /// Decided where the resting element was released: its row grows toward the middle of
    /// the display it rests on, and its glyph's edge stays where it was let go.
    public init(released resting: NSRect, on screen: NSRect) {
        growsLeftward = resting.midX > screen.midX
        glyphEdge = growsLeftward ? resting.maxX : resting.minX
        centreY = resting.midY
    }

    /// The resting element of `size` at this position, before it is kept on a display.
    public func restingFrame(size: NSSize) -> NSRect {
        NSRect(x: growsLeftward ? glyphEdge - size.width : glyphEdge, y: centreY - size.height / 2,
               width: size.width, height: size.height)
    }

    public var isFinite: Bool { glyphEdge.isFinite && centreY.isFinite }
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
