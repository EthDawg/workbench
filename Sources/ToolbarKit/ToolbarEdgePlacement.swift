import AppKit
import ToolbarCore

public enum ToolbarEdge: String, CaseIterable, Sendable { case top, bottom, left, right }

/// The fraction along an edge survives a display resolution change. The free position
/// also keeps its absolute centre for compatibility; displayID retains the chosen display.
public struct ToolbarEdgeAttachment: Equatable, Sendable {
    public var edge: ToolbarEdge
    public var fraction: CGFloat
    public var displayID: String?
    public init(edge: ToolbarEdge, fraction: CGFloat, displayID: String? = nil) {
        self.edge = edge; self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0.5
        self.displayID = displayID
    }
    public func screen(in displays: [String: NSRect], fallback: NSRect) -> NSRect {
        displayID.flatMap { displays[$0] } ?? fallback
    }
    public func centre(on screen: NSRect) -> CGPoint {
        let low = ToolbarGeometry.launcherCentre(.docked(.bottomLeft), screen: screen)
        let high = ToolbarGeometry.launcherCentre(.docked(.topRight), screen: screen)
        switch edge {
        case .top: return CGPoint(x: low.x + (high.x - low.x) * fraction, y: high.y)
        case .bottom: return CGPoint(x: low.x + (high.x - low.x) * fraction, y: low.y)
        case .left: return CGPoint(x: low.x, y: low.y + (high.y - low.y) * fraction)
        case .right: return CGPoint(x: high.x, y: low.y + (high.y - low.y) * fraction)
        }
    }
}

public extension ToolbarGeometry {
    static let snapDistance: CGFloat = 16

    /// The full dragged window meets an edge, rather than a tiny point at one of eight
    /// docks. Corners and edge midpoints attract within the same distance. Preview and
    /// release use this exact result, including a release beyond the visible work area.
    static func releasedPosition(frame: NSRect, screen: NSRect) -> ToolbarPosition {
        let low = launcherCentre(.docked(.bottomLeft), screen: screen)
        let high = launcherCentre(.docked(.topRight), screen: screen)
        let centre = CGPoint(x: min(high.x, max(low.x, frame.midX)), y: min(high.y, max(low.y, frame.midY)))
        let nearLeft = frame.minX <= screen.minX + ToolbarLayout.dockInset + snapDistance
        let nearRight = frame.maxX >= screen.maxX - ToolbarLayout.dockInset - snapDistance
        let nearBottom = frame.minY <= screen.minY + ToolbarLayout.dockInset + snapDistance
        let nearTop = frame.maxY >= screen.maxY - ToolbarLayout.dockInset - snapDistance
        let horizontal: ToolbarEdge? = nearLeft && (!nearRight || frame.midX < screen.midX) ? .left : nearRight ? .right : nil
        let vertical: ToolbarEdge? = nearBottom && (!nearTop || frame.midY < screen.midY) ? .bottom : nearTop ? .top : nil
        if let horizontal, let vertical {
            return .docked(vertical == .top ? (horizontal == .left ? .topLeft : .topRight)
                                            : (horizontal == .left ? .bottomLeft : .bottomRight))
        }
        if let vertical, abs(centre.x - screen.midX) <= snapDistance { return .docked(vertical == .top ? .top : .bottom) }
        if let horizontal, abs(centre.y - screen.midY) <= snapDistance { return .docked(horizontal == .left ? .left : .right) }
        if let edge = vertical ?? horizontal {
            let fraction = vertical != nil ? (centre.x - low.x) / max(1, high.x - low.x)
                                          : (centre.y - low.y) / max(1, high.y - low.y)
            let attachment = ToolbarEdgeAttachment(edge: edge, fraction: fraction)
            return .free(ToolbarFreePosition(centre: attachment.centre(on: screen), growsLeftward: edge == .right, attachment: attachment))
        }
        return .free(ToolbarFreePosition(releasedAt: centre, on: screen))
    }

    static func isAttached(_ position: ToolbarPosition) -> Bool {
        switch position {
        case .docked: return true
        case .free(let free): return free.attachment != nil
        }
    }
}
