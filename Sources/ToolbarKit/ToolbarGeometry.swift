import AppKit
import ToolbarCore

/// The compact controls' measures (#134), in points at standard text. The compact mark and
/// the revealed row's launcher share one centre on screen, and both meet their growth edge
/// 24 points from it: the mark is the resting window, and the launcher's 48-point target is
/// the row's end, so its margin lies inside it. Nothing moves under a pointer that stays on
/// that centre while the row opens or closes.
public enum ToolbarLayout {
    /// The compact rest: its pointer target, and the whole resting window.
    public static let mark = NSSize(width: 48, height: 28)
    /// The idle mark, a capsule inside the target.
    public static let markCapsule = NSSize(width: 48, height: 8)
    /// A status glyph raises the mark's visible height to this, inside the same target.
    public static let statusHeight: CGFloat = 12
    public static let rowHeight: CGFloat = 40
    public static let controlHeight: CGFloat = 32
    public static let launcherWidth: CGFloat = 48
    /// 144 points, plus the 8 the launcher's end does not need as padding.
    public static let primaryMinimum: CGFloat = 152
    public static let accessoryWidth: CGFloat = 88
    public static let moreWidth: CGFloat = 32
    public static let gap: CGFloat = 4
    /// At the far end of the row.
    public static let padding: CGFloat = 8
    public static let cornerRadius: CGFloat = 20
    /// The launcher's centre from the content's growth edge, at rest and revealed.
    public static let launcherInset: CGFloat = 24
    /// The launcher's end of the row: what a dock places and what snapping compares.
    public static let dockSlot = NSSize(width: 48, height: 40)
    /// A dock keeps the row this far inside the visible display.
    public static let dockInset: CGFloat = 16
    /// 248 points without an accessory, 340 with one, at standard text.
    public static let standardWidth: CGFloat = launcherWidth + gap + primaryMinimum + gap + moreWidth + padding
    public static let accessoryStandardWidth: CGFloat = standardWidth + accessoryWidth + gap
    /// The accessory waits in More unless the row with it fits the display less this.
    public static let accessoryScreenMargin: CGFloat = 24
}

public enum ToolbarGeometry {
    /// The launcher's centre: the middle of the dock slot at a dock, or the free centre kept
    /// far enough inside the display for the slot to stay whole.
    public static func launcherCentre(_ position: ToolbarPosition, screen: NSRect) -> CGPoint {
        let slot = ToolbarLayout.dockSlot
        switch position {
        case .docked(let anchor):
            let mx = min(ToolbarLayout.dockInset, max(0, (screen.width - slot.width) / 2))
            let my = min(ToolbarLayout.dockInset, max(0, (screen.height - slot.height) / 2))
            let x: CGFloat
            switch anchor {
            case .topLeft, .left, .bottomLeft: x = screen.minX + mx + slot.width / 2
            case .topRight, .right, .bottomRight: x = screen.maxX - mx - slot.width / 2
            case .top, .bottom: x = screen.midX
            }
            let y: CGFloat
            switch anchor {
            case .topLeft, .top, .topRight: y = screen.maxY - my - slot.height / 2
            case .left, .right: y = screen.midY
            case .bottomLeft, .bottom, .bottomRight: y = screen.minY + my + slot.height / 2
            }
            return CGPoint(x: x, y: y)
        case .free(let free):
            let x = free.centre.x.isFinite ? free.centre.x : screen.midX, y = free.centre.y.isFinite ? free.centre.y : screen.midY
            let hx = min(slot.width / 2, screen.width / 2), hy = min(slot.height / 2, screen.height / 2)
            return CGPoint(x: min(max(screen.minX + hx, x), screen.maxX - hx), y: min(max(screen.minY + hy, y), screen.maxY - hy))
        }
    }

    /// A row grows inward: a dock by its anchor, a free position by the side decided when
    /// it was released. Neither depends on the content's width, so no reveal, tool or live
    /// label ever turns the row round under the pointer.
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

    /// The window for content of `size`, the compact mark or the row: its launcher on the
    /// launcher centre, growing inward, kept whole on `screen`.
    public static func frame(size: NSSize, position: ToolbarPosition, screen: NSRect) -> NSRect {
        let centre = launcherCentre(position, screen: screen)
        let width = min(max(1, size.width), screen.width), height = min(max(1, size.height), screen.height)
        let x = growsLeftward(position) ? centre.x + ToolbarLayout.launcherInset - width : centre.x - ToolbarLayout.launcherInset
        return NSRect(x: min(max(screen.minX, x), screen.maxX - width),
                      y: min(max(screen.minY, centre.y - height / 2), screen.maxY - height), width: width, height: height)
    }

    /// Where the launcher's centre is in a window of the tools, as a drag carries it.
    public static func launcherCentre(inWindow frame: NSRect, growsLeftward: Bool) -> CGPoint {
        CGPoint(x: growsLeftward ? frame.maxX - ToolbarLayout.launcherInset : frame.minX + ToolbarLayout.launcherInset, y: frame.midY)
    }

    /// The dock slot around a launcher centre: what the drag's guides outline and what
    /// snapping compares with each dock's own slot.
    public static func slot(around centre: CGPoint) -> NSRect {
        let size = ToolbarLayout.dockSlot
        return NSRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
    }
}

/// Where the tools rest (#163): at a named dock, or wherever they were dragged.
public enum ToolbarPosition: Equatable, Sendable {
    case docked(ToolbarAnchor)
    case free(ToolbarFreePosition)
}

/// A free position (#163, #134): the launcher's centre, which is also the compact mark's,
/// and the side the row grows toward. The side is decided once, when the toolbar is released
/// (or when an earlier save is first read), and kept with the position, so a change of
/// content width never moves the launcher or turns the row round.
public struct ToolbarFreePosition: Equatable, Sendable {
    public var centre: CGPoint
    /// The row grows leftward from its launcher, toward the middle of its display.
    public var growsLeftward: Bool

    public init(centre: CGPoint, growsLeftward: Bool) {
        self.centre = centre; self.growsLeftward = growsLeftward
    }

    /// Decided where the launcher was let go: the row grows toward the middle of the display.
    public init(releasedAt centre: CGPoint, on screen: NSRect) {
        self.centre = centre
        growsLeftward = centre.x > screen.midX
    }

    /// An earlier save, which pinned the glyph edge of a 36-point glyph at the resting
    /// element's end: the launcher takes the glyph's centre.
    public init(glyphEdge: CGFloat, centreY: CGFloat, growsLeftward: Bool) {
        self.init(centre: CGPoint(x: growsLeftward ? glyphEdge - 18 : glyphEdge + 18, y: centreY), growsLeftward: growsLeftward)
    }

    /// An earlier save that kept only the resting element's frame: its side is decided once,
    /// where it was left, and the launcher takes the glyph's centre at that end.
    public init(earlierResting frame: NSRect, on screen: NSRect) {
        let leftward = frame.midX > screen.midX
        self.init(glyphEdge: leftward ? frame.maxX : frame.minX, centreY: frame.midY, growsLeftward: leftward)
    }

    /// The same position in an earlier build's terms, for a downgrade: the edge of a
    /// 36-point glyph centred on the launcher.
    public var glyphEdge: CGFloat { growsLeftward ? centre.x + 18 : centre.x - 18 }

    public var isFinite: Bool { centre.x.isFinite && centre.y.isFinite }
}

/// A press on the compact mark, the launcher, the next action or the row's empty chrome
/// moves the toolbar only after this much travel; less is a click and its action runs (#163). StageKit's
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
