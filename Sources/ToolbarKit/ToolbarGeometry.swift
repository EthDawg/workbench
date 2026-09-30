import AppKit
import ToolbarCore

/// The compact controls' measures (#134), in points at standard text. Side attachments
/// transpose the row into an upright column. Corners keep the horizontal layout.
public enum ToolbarLayout {
    /// The compact rest: its pointer target, and the whole resting window.
    public static let mark = NSSize(width: 48, height: 28)
    public static func oriented(_ size: NSSize, for anchor: ToolbarAnchor) -> NSSize {
        anchor.isVertical ? NSSize(width: size.height, height: size.width) : size
    }
    public static func mark(for anchor: ToolbarAnchor) -> NSSize { oriented(mark, for: anchor) }
    /// The quiet handle, inside the larger pointer target. Tool identity appears on reveal.
    public static let markCapsule = NSSize(width: 48, height: 8)
    /// Only recording needs extra room; all other collapsed states stay icon-free.
    static func restingCapsuleHeight(for indicator: ToolbarStatus.Indicator) -> CGFloat {
        switch indicator {
        case .capture: return 20
        default: return markCapsule.height
        }
    }
    /// The box for a resting status glyph or voice signal.
    public static let statusHeight: CGFloat = 12
    public static let rowHeight: CGFloat = 40
    public static let controlHeight: CGFloat = 32
    public static let launcherWidth: CGFloat = 48
    public static let captureSignalWidth: CGFloat = 44
    /// Icon actions keep stable, generous targets; their words live in the hint and VoiceOver.
    public static let primaryMinimum: CGFloat = 36
    public static let accessoryWidth: CGFloat = 36
    public static let gap: CGFloat = 4
    /// At the far end of the row.
    public static let padding: CGFloat = 8
    public static let cornerRadius: CGFloat = 20
    /// The launcher's centre from the content's growth edge, at rest and revealed.
    public static let launcherInset: CGFloat = 24
    /// The legacy reference slot, retained for saved-position migration and display recovery.
    public static let dockSlot = NSSize(width: 48, height: 40)
    /// A dock keeps the row this far inside the visible display.
    public static let dockInset: CGFloat = 8
    /// Row widths: 96 points alone, 136 with one contextual control, 176 with two.
    public static let standardWidth: CGFloat = launcherWidth + gap + primaryMinimum + padding
    public static let accessoryStandardWidth: CGFloat = standardWidth + accessoryWidth + gap
    /// Contextual controls fit together when the row fits the display less this.
    public static let accessoryScreenMargin: CGFloat = 24

    /// Predict the destination row before a drag commits its orientation. Preview and
    /// release use the same measurement, including large text and omitted contextual controls.
    public static func fittedRow(_ horizontal: NSSize, accessoryAvailable: Bool, accessoryShown: Bool,
                                 anchor: ToolbarAnchor, screen: NSRect, accessoryCount: Int = 1) -> (size: NSSize, accessoryFits: Bool) {
        let accessory = CGFloat(accessoryCount) * (accessoryWidth + gap) * horizontal.height / rowHeight
        let without = horizontal.width - (accessoryShown ? accessory : 0)
        let withAccessory = without + (accessoryAvailable ? accessory : 0)
        let fits = withAccessory <= (anchor.isVertical ? screen.height : screen.width) - accessoryScreenMargin
        return (oriented(NSSize(width: fits ? withAccessory : without, height: horizontal.height), for: anchor), fits)
    }
}

public enum ToolbarGeometry {
    /// The resting reference point: the middle of a compact target, an edge attachment, or
    /// the saved free centre. The historical name is retained for saved-position callers.
    public static func launcherCentre(_ position: ToolbarPosition, screen: NSRect) -> CGPoint {
        let slot = ToolbarLayout.mark(for: rowAnchor(position))
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
            let hx = min(ToolbarLayout.dockSlot.width / 2, screen.width / 2), hy = min(ToolbarLayout.dockSlot.height / 2, screen.height / 2)
            return CGPoint(x: min(max(screen.minX + hx, x), screen.maxX - hx), y: min(max(screen.minY + hy, y), screen.maxY - hy))
        }
    }

    /// Right-side attachments preserve their outside edge. A free row expands from its
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

    /// Expand along the edge around its resting reference, preserve the outside edge,
    /// and keep the whole window on the usable screen. Free positions centre both axes.
    public static func frame(size: NSSize, position: ToolbarPosition, screen: NSRect) -> NSRect {
        let centre = launcherCentre(position, screen: screen)
        let width = min(max(1, size.width), screen.width), height = min(max(1, size.height), screen.height)
        let anchor = rowAnchor(position)
        let frame = frame(size: NSSize(width: width, height: height), reference: centre, anchor: anchor, isFloating: !isAttached(position))
        return NSRect(x: min(max(screen.minX, frame.minX), screen.maxX - width),
                      y: min(max(screen.minY, frame.minY), screen.maxY - height), width: width, height: height)
    }

    /// The legacy horizontal launcher's centre, retained for migration callers.
    public static func launcherCentre(inWindow frame: NSRect, growsLeftward: Bool) -> CGPoint {
        CGPoint(x: growsLeftward ? frame.maxX - ToolbarLayout.launcherInset : frame.minX + ToolbarLayout.launcherInset, y: frame.midY)
    }

    /// The resting mark's reference point, also used when a row changes width.
    public static func restingCentre(inWindow frame: NSRect, anchor: ToolbarAnchor, isFloating: Bool = false) -> CGPoint {
        if isFloating { return CGPoint(x: frame.midX, y: frame.midY) }
        let rest = ToolbarLayout.mark(for: anchor)
        let x = anchor == .top || anchor == .bottom ? frame.midX
            : anchor.growsLeftward ? frame.maxX - rest.width / 2 : frame.minX + rest.width / 2
        let y = anchor.isVertical ? frame.midY
            : anchor == .top || anchor == .topLeft || anchor == .topRight ? frame.maxY - rest.height / 2 : frame.minY + rest.height / 2
        return CGPoint(x: x, y: y)
    }

    /// The exact inverse of restingCentre, shared by placement and the animation clock.
    /// A dock keeps its outside edge fixed; a side column grows around its vertical centre.
    public static func frame(size: NSSize, reference: CGPoint, anchor: ToolbarAnchor, isFloating: Bool = false) -> NSRect {
        if isFloating { return NSRect(x: reference.x - size.width / 2, y: reference.y - size.height / 2, width: size.width, height: size.height) }
        let rest = ToolbarLayout.mark(for: anchor)
        let x = anchor == .top || anchor == .bottom ? reference.x - size.width / 2
            : anchor.growsLeftward ? reference.x + rest.width / 2 - size.width : reference.x - rest.width / 2
        let y = anchor.isVertical ? reference.y - size.height / 2
            : anchor == .top || anchor == .topLeft || anchor == .topRight ? reference.y + rest.height / 2 - size.height : reference.y - rest.height / 2
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// A reference slot around the resting mark, also used to read legacy positions.
    public static func slot(around centre: CGPoint) -> NSRect {
        let size = ToolbarLayout.dockSlot
        return NSRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
    }

    /// Side toolbars share an inboard lane for their chooser, prompts and Position panel.
    /// The full toolbar is excluded, including controls above and below the invoking button.
    public static func sidePanelFrame(size: NSSize, toolbar: NSRect, anchor: ToolbarAnchor, visible: NSRect,
                                      inset: CGFloat = 8, gap: CGFloat = 8) -> NSRect {
        let available = anchor == .right ? toolbar.minX - gap - visible.minX - inset : visible.maxX - inset - toolbar.maxX - gap
        let width = min(size.width, max(1, available)), height = min(size.height, max(1, visible.height - 2 * inset))
        let x = anchor == .right ? toolbar.minX - gap - width : toolbar.maxX + gap
        return NSRect(x: x, y: min(max(toolbar.midY - height / 2, visible.minY + inset), visible.maxY - inset - height),
                      width: width, height: height)
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
