import AppKit
import StageKit
import SwiftUI
import ToolbarCore
import ToolbarKit

/// Position… (#163): the toolbar's named docks and a reset in one compact control, in place
/// of an eight-item submenu. The control itself is StageKit's `FloatingPositionControl`, which
/// the Timer window shares (#134 Fit rule 1); this names the toolbar's wording and Reset.
struct ToolbarPositionControl: View {
    let current: FloatingControlAnchor?
    let choose: (FloatingControlAnchor) -> Void
    let reset: () -> Void
    let close: () -> Void
    static let hint = "Or drag the toolbar anywhere."
    static let accessibilityLabel = "Toolbar position"

    var body: some View {
        FloatingPositionControl(current: current, choose: choose, reset: reset, close: close,
                                hint: Self.hint, accessibilityLabel: Self.accessibilityLabel)
            .workbenchTheme()
    }

    /// Where each dock sits in the three-by-three grid; the middle is empty.
    static func cell(_ anchor: FloatingControlAnchor) -> (column: Int, row: Int) { FloatingPositionControl.cell(anchor) }

    /// The dock an arrow key reaches from `anchor`, stepping over the empty middle.
    static func neighbour(of anchor: FloatingControlAnchor, column dx: Int, row dy: Int) -> FloatingControlAnchor {
        FloatingPositionControl.neighbour(of: anchor, column: dx, row: dy)
    }
}

/// Why Position… closed, which decides where the keyboard goes next.
typealias ToolbarPositionClose = FloatingPositionClose

/// Shows Position… beside the toolbar and closes it on a choice, Escape or a click elsewhere.
@MainActor final class ToolbarPositionPanel {
    private let panel = FloatingPositionPanel()
    var isShown: Bool { panel.isShown }

    func show(beside toolbar: NSRect, level: NSWindow.Level, current: FloatingControlAnchor?,
              anchor: ToolbarAnchor = .bottom,
              choose: @escaping (FloatingControlAnchor) -> Void, reset: @escaping () -> Void,
              closed: @escaping (ToolbarPositionClose) -> Void = { _ in }) {
        panel.show(title: "Toolbar position", level: level, current: current,
                   hint: ToolbarPositionControl.hint, accessibilityLabel: ToolbarPositionControl.accessibilityLabel,
                   choose: choose, reset: reset, closed: closed,
                   theme: { AnyView($0.workbenchTheme()) },
                   frame: { Self.frame(size: $0, beside: toolbar, anchor: anchor) })
    }

    /// Above a toolbar in the lower half of its display, otherwise below it, kept on screen.
    static func frame(size: NSSize, beside toolbar: NSRect,
                      anchor: ToolbarAnchor = .bottom,
                      screens: [NSRect] = NSScreen.screens.map(\.visibleFrame)) -> NSRect {
        let screen = FloatingControlPlacement.screen(for: toolbar, screens: screens, preferred: screens.first ?? toolbar)
        if anchor.isVertical { return ToolbarGeometry.sidePanelFrame(size: size, toolbar: toolbar, anchor: anchor, visible: screen) }
        let y = toolbar.midY < screen.midY ? toolbar.maxY + 8 : toolbar.minY - 8 - size.height
        return FloatingControlGeometry.clamp(NSRect(origin: NSPoint(x: toolbar.minX, y: y), size: size), to: screen, inset: 0)
    }

    func close(_ reason: ToolbarPositionClose = .dismissed) { panel.close(reason) }
}
