import AppKit
import ToolbarCore

/// The compact controls' measures (#134), in points at standard text. Top, bottom and
/// unattached positions grow around the resting mark. Side and corner positions keep
/// the launcher's 48-point target at the inward growth edge.
public enum ToolbarLayout {
    /// The compact rest: its pointer target, and the whole resting window.
    public static let mark = NSSize(width: 48, height: 28)
    /// The quiet handle, inside the larger pointer target. Tool identity appears on reveal.
    public static let markCapsule = NSSize(width: 48, height: 8)
    /// Make room for a recording, transport or recovery signal without moving the target.
    static func restingCapsuleHeight(for indicator: ToolbarStatus.Indicator) -> CGFloat {
        switch indicator {
        case .idle, .live: return markCapsule.height
        default: return 20
        }
    }
    /// The box for a resting status glyph or voice signal.
    public static let statusHeight: CGFloat = 12
    /// A badge on the capture signal or the launcher: a fixed square, whatever its symbol's metrics.
    public static let badge: CGFloat = 7
    public static let rowHeight: CGFloat = 40
    public static let controlHeight: CGFloat = 32
    public static let launcherWidth: CGFloat = 48
    /// Icon actions keep stable, generous targets; their words live in the hint and VoiceOver.
    public static let primaryMinimum: CGFloat = 36
    public static let accessoryWidth: CGFloat = 36
    public static let moreWidth: CGFloat = 32
    public static let gap: CGFloat = 4
    /// At the far end of the row.
    public static let padding: CGFloat = 8
    public static let cornerRadius: CGFloat = 20
    /// The launcher's centre from the content's growth edge, at rest and revealed.
    public static let launcherInset: CGFloat = 24
    /// The reference slot used to place the resting mark and reserve the row's height.
    public static let dockSlot = NSSize(width: 48, height: 40)
    /// A dock keeps the row this far inside the visible display.
    public static let dockInset: CGFloat = 16
    /// Row widths: 132 points without an accessory, 172 with one, at standard scale.
    public static let standardWidth: CGFloat = launcherWidth + gap + primaryMinimum + gap + moreWidth + padding
    public static let accessoryStandardWidth: CGFloat = standardWidth + accessoryWidth + gap
    /// The accessory waits in More unless the row with it fits the display less this.
    public static let accessoryScreenMargin: CGFloat = 24
}

public enum ToolbarGeometry {
    /// The resting reference point: the middle of a dock slot, an edge attachment, or
    /// the saved free centre. The historical name is retained for saved-position callers.
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
            if let attachment = free.attachment { return attachment.centre(on: screen) }
            let x = free.centre.x.isFinite ? free.centre.x : screen.midX, y = free.centre.y.isFinite ? free.centre.y : screen.midY
            let hx = min(slot.width / 2, screen.width / 2), hy = min(slot.height / 2, screen.height / 2)
            return CGPoint(x: min(max(screen.minX + hx, x), screen.maxX - hx), y: min(max(screen.minY + hy, y), screen.maxY - hy))
        }
    }

    /// Only right-side attachments reverse the controls. A free row expands from its
    /// centre; its legacy direction remains in the save solely for older builds.
    public static func growsLeftward(_ position: ToolbarPosition) -> Bool {
        switch position {
        case .docked(let anchor): return anchor.growsLeftward
        case .free(let free): return free.attachment?.edge == .right
        }
    }

    /// The row's growth policy follows its attachment; unattached rows use centred growth.
    public static func rowAnchor(_ position: ToolbarPosition) -> ToolbarAnchor {
        if case .docked(let anchor) = position { return anchor }
        if case .free(let free) = position, let edge = free.attachment?.edge {
            switch edge {
            case .top: return .top
            case .bottom: return .bottom
            case .left: return .left
            case .right: return .right
            }
        }
        return .bottom
    }

    /// Centre top/bottom/free content on the resting reference, grow side/corner content
    /// inward, and keep the whole window on the usable screen.
    public static func frame(size: NSSize, position: ToolbarPosition, screen: NSRect) -> NSRect {
        let centre = launcherCentre(position, screen: screen)
        let width = min(max(1, size.width), screen.width), height = min(max(1, size.height), screen.height)
        let anchor = rowAnchor(position)
        let x = anchor.growsFromCentre ? centre.x - width / 2
            : anchor.growsLeftward ? centre.x + ToolbarLayout.launcherInset - width : centre.x - ToolbarLayout.launcherInset
        return NSRect(x: min(max(screen.minX, x), screen.maxX - width),
                      y: min(max(screen.minY, centre.y - height / 2), screen.maxY - height), width: width, height: height)
    }

    /// Where the launcher's centre is in a window of the tools, as a drag carries it.
    public static func launcherCentre(inWindow frame: NSRect, growsLeftward: Bool) -> CGPoint {
        CGPoint(x: growsLeftward ? frame.maxX - ToolbarLayout.launcherInset : frame.minX + ToolbarLayout.launcherInset, y: frame.midY)
    }

    /// The resting mark's reference point, also used when a row changes width.
    public static func restingCentre(inWindow frame: NSRect, anchor: ToolbarAnchor) -> CGPoint {
        anchor.growsFromCentre ? CGPoint(x: frame.midX, y: frame.midY)
            : launcherCentre(inWindow: frame, growsLeftward: anchor.growsLeftward)
    }

    /// A reference slot around the resting mark, also used to read legacy positions.
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

/// A saved resting centre with an optional edge attachment. The historical direction
/// and absolute centre remain compatible with older builds; current growth follows
/// the attachment, or the centre when free.
public struct ToolbarFreePosition: Equatable, Sendable {
    public var centre: CGPoint
    public var attachment: ToolbarEdgeAttachment?
    /// The direction an older build uses after a downgrade.
    public var growsLeftward: Bool

    public init(centre: CGPoint, growsLeftward: Bool, attachment: ToolbarEdgeAttachment? = nil) {
        self.centre = centre; self.growsLeftward = growsLeftward; self.attachment = attachment
    }

    /// Keep the old direction convention alongside the current resting centre.
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
