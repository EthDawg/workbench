import SwiftUI
import ToolbarCore

/// The outer dock measures the host's available space, while the row continues
/// to report its full intended size. A layout value, never another state owner.
private struct ToolbarViewportKey: EnvironmentKey {
    static let defaultValue: CGSize? = nil
}
extension EnvironmentValues {
    var toolbarViewport: CGSize? {
        get { self[ToolbarViewportKey.self] }
        set { self[ToolbarViewportKey.self] = newValue }
    }
}

/// Controls become visible only once the growing capsule has room for them.
struct ToolbarControlReveal: ViewModifier {
    let viewport: CGSize?
    let anchor: ToolbarAnchor
    func body(content: Content) -> some View {
        content.visualEffect { effect, geometry in
            effect.opacity(ToolbarRevealVisuals.controlOpacity(
                frame: geometry.frame(in: .named(ToolbarRevealVisuals.coordinateSpace)),
                viewport: viewport, growsLeftward: anchor.growsLeftward, growsFromCentre: anchor.growsFromCentre, vertical: anchor.isVertical))
        }
    }
}

/// No independent animation curve: the host's window height is the progress.
enum ToolbarRevealVisuals {
    static let coordinateSpace = "workbench.toolbar.viewport"
    /// The capsule opens first. White glyphs arrive together during its final fifth, and
    /// disappear before the closing edge can cut through a control. No second timer.
    static func glyphOpacity(progress: CGFloat) -> CGFloat { min(1, max(0, (progress - 0.8) / 0.2)) }
    /// Reveal a control after its entire label fits, over the last eight points
    /// of breathing room. The same rule hides it before the edge cuts through it.
    static func controlOpacity(frame: CGRect, viewport: CGSize?, growsLeftward: Bool, growsFromCentre: Bool = false, vertical: Bool = false) -> Double {
        guard let viewport else { return 1 }
        let clearance = vertical ? min(frame.minY, viewport.height - frame.maxY) : growsFromCentre ? min(frame.minX, viewport.width - frame.maxX)
            : growsLeftward ? frame.minX : viewport.width - frame.maxX
        return Double(min(1, max(0, clearance / ToolbarLayout.padding)))
    }

    static func progress(viewportHeight: CGFloat, rowHeight: CGFloat) -> CGFloat {
        min(1, max(0, (viewportHeight - ToolbarLayout.mark.height) / max(1, rowHeight - ToolbarLayout.mark.height)))
    }
    static func capsuleHeight(progress: CGFloat, rowHeight: CGFloat, indicator: ToolbarStatus.Indicator) -> CGFloat {
        let rest = ToolbarLayout.restingCapsuleHeight(for: indicator)
        return rest + (rowHeight - rest) * min(1, max(0, progress))
    }
}
