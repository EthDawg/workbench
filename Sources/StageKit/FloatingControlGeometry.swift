import AppKit

public enum FloatingControlAnchor: String, CaseIterable, Codable, Identifiable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .top: return "Top centre"
        case .topRight: return "Top right"
        case .left: return "Left centre"
        case .right: return "Right centre"
        case .bottomLeft: return "Bottom left"
        case .bottom: return "Bottom centre"
        case .bottomRight: return "Bottom right"
        }
    }
    var unitPoint: NSPoint {
        switch self {
        case .topLeft: return NSPoint(x: 0, y: 1)
        case .top: return NSPoint(x: 0.5, y: 1)
        case .topRight: return NSPoint(x: 1, y: 1)
        case .left: return NSPoint(x: 0, y: 0.5)
        case .right: return NSPoint(x: 1, y: 0.5)
        case .bottomLeft: return NSPoint(x: 0, y: 0)
        case .bottom: return NSPoint(x: 0.5, y: 0)
        case .bottomRight: return NSPoint(x: 1, y: 0)
        }
    }
}

public struct FloatingControlTarget: Identifiable, Equatable {
    public let anchor: FloatingControlAnchor
    public let frame: NSRect
    public var id: FloatingControlAnchor { anchor }
}

/// AppKit coordinates, including displays left of or below the main display.
/// Every result fits the visible frame. Tiny frames reduce the margin before
/// reducing the control size, so a disconnected display cannot strand controls.
public enum FloatingControlGeometry {
    /// Every distinct valid destination, in the same stable order as Position.
    /// Coincident footprints on a small display are one target, not stacked guides.
    public static func targets(size: NSSize, visibleFrame: NSRect, inset: CGFloat = 16) -> [FloatingControlTarget] {
        var result: [FloatingControlTarget] = []
        for anchor in FloatingControlAnchor.allCases {
            let frame = self.frame(anchor: anchor, size: size, visibleFrame: visibleFrame, inset: inset)
            guard valid(frame), !result.contains(where: { $0.frame == frame }) else { continue }
            result.append(FloatingControlTarget(anchor: anchor, frame: frame))
        }
        return result
    }

    public static func frame(anchor: FloatingControlAnchor, size: NSSize, visibleFrame: NSRect, inset: CGFloat = 16) -> NSRect {
        let bounded = clamp(NSRect(origin: visibleFrame.origin, size: size), to: visibleFrame, inset: inset)
        guard valid(visibleFrame) else { return .zero }
        let margin = margins(size: bounded.size, visible: visibleFrame.size, inset: inset)
        let available = visibleFrame.insetBy(dx: margin.width, dy: margin.height)
        let unit = anchor.unitPoint
        return NSRect(x: available.minX + (available.width - bounded.width) * unit.x,
                      y: available.minY + (available.height - bounded.height) * unit.y,
                      width: bounded.width, height: bounded.height)
    }

    public static func clamp(_ frame: NSRect, to visibleFrame: NSRect, inset: CGFloat = 16) -> NSRect {
        guard valid(visibleFrame) else { return .zero }
        let size = NSSize(width: min(visibleFrame.width, frame.width.isFinite ? max(0, frame.width) : 0),
                          height: min(visibleFrame.height, frame.height.isFinite ? max(0, frame.height) : 0))
        let margin = margins(size: size, visible: visibleFrame.size, inset: inset)
        let available = visibleFrame.insetBy(dx: margin.width, dy: margin.height)
        let x = frame.minX.isFinite ? frame.minX : available.minX
        let y = frame.minY.isFinite ? frame.minY : available.minY
        return NSRect(x: min(max(x, available.minX), available.maxX - size.width),
                      y: min(max(y, available.minY), available.maxY - size.height),
                      width: size.width, height: size.height)
    }

    public static func nearestAnchor(to frame: NSRect, in visibleFrame: NSRect, threshold: CGFloat = 28, inset: CGFloat = 16) -> FloatingControlAnchor? {
        guard valid(visibleFrame), [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width >= 0, frame.height >= 0, threshold.isFinite, threshold >= 0 else { return nil }
        let candidates = FloatingControlAnchor.allCases.map { anchor -> (FloatingControlAnchor, CGFloat) in
            let target = self.frame(anchor: anchor, size: frame.size, visibleFrame: visibleFrame, inset: inset)
            return (anchor, hypot(frame.minX - target.minX, frame.minY - target.minY))
        }
        guard let closest = candidates.min(by: { $0.1 < $1.1 }), closest.1 <= threshold else { return nil }
        return closest.0
    }

    fileprivate static func valid(_ frame: NSRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0
    }
    private static func margins(size: NSSize, visible: NSSize, inset: CGFloat) -> NSSize {
        let requested = inset.isFinite ? max(0, inset) : 16
        return NSSize(width: min(requested, max(0, (visible.width - size.width) / 2)),
                      height: min(requested, max(0, (visible.height - size.height) / 2)))
    }
}

/// Direct manipulation shared by floating controls (#163). The floating toolbar uses it, and
/// Persona overlays can adopt it while keeping their own per-copy state (#157). A press moves
/// the control only after `dragThreshold` points; less is a click. A release within
/// `snapDistance` of a named destination docks there, which is when its guide is active;
/// anywhere else keeps the free position, whole on the display it covers most.
public enum FloatingControlPlacement {
    public static let dragThreshold: CGFloat = 4
    public static let snapDistance: CGFloat = 16

    public static func isDrag(from start: NSPoint, to point: NSPoint) -> Bool {
        hypot(point.x - start.x, point.y - start.y) >= dragThreshold
    }

    /// The named destination a release at `frame` docks to, if one is within `snapDistance`.
    public static func snapAnchor(for frame: NSRect, in visibleFrame: NSRect, inset: CGFloat = 16) -> FloatingControlAnchor? {
        FloatingControlGeometry.nearestAnchor(to: frame, in: visibleFrame, threshold: snapDistance, inset: inset)
    }

    /// The display a frame belongs to: the visible frame it covers most, or `preferred` when it
    /// covers none, such as after its display was removed.
    public static func screen(for frame: NSRect, screens: [NSRect], preferred: NSRect) -> NSRect {
        guard FloatingControlGeometry.valid(frame) else { return preferred }
        let best = screens.map { screen -> (NSRect, CGFloat) in
            let overlap = screen.intersection(frame)
            return (screen, overlap.isNull ? 0 : overlap.width * overlap.height)
        }.max { $0.1 < $1.1 }
        guard let best, best.1 > 0 else { return preferred }
        return best.0
    }

    /// A free frame recovered whole onto the display it belongs to, flush edges allowed.
    public static func recover(_ frame: NSRect, screens: [NSRect], preferred: NSRect) -> NSRect {
        FloatingControlGeometry.clamp(frame, to: screen(for: frame, screens: screens, preferred: preferred), inset: 0)
    }
}
