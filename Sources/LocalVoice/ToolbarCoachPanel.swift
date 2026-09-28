import AppKit
import SwiftUI

/// Where the one-time coaching card goes (#134 T5): above the toolbar's place with a 12-point
/// gap, below it when the display has no room above, centred on the launcher and kept 8 points
/// inside the display. `host` is what the toolbar's window shows now: the compact mark, or the
/// row or cue it was replaced by, so the card never covers it and the mark never moves for it.
enum ToolbarCoachPlacement {
    static let gap: CGFloat = 12
    static let edgeMargin: CGFloat = 8

    static func frame(card: NSSize, host: NSRect, launcherX: CGFloat, visible: NSRect) -> NSRect {
        let width = min(card.width, visible.width - 2 * edgeMargin)
        let above = host.maxY + gap
        let fitsAbove = above + card.height <= visible.maxY - edgeMargin
        let y = fitsAbove ? above : host.minY - gap - card.height
        let x = min(max(launcherX - width / 2, visible.minX + edgeMargin), visible.maxX - edgeMargin - width)
        return NSRect(x: x.rounded(), y: max(y, visible.minY + edgeMargin).rounded(), width: width.rounded(), height: card.height.rounded())
    }
}

/// A card panel that never activates Workbench. It can take the keyboard when the person moves
/// focus into it, so Escape dismisses it while it has focus, as the card expects.
private final class ToolbarCoachWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows the coach's card for the toolbar's host (#134 T5). It sizes a panel to the card alone,
/// so the gap between the card and the toolbar belongs to no window and passes clicks through;
/// it reports the card presented once it is really on screen, and fades it out when it goes.
@MainActor final class ToolbarCoachPanel {
    private var panel: ToolbarCoachWindow?
    private(set) var shownCard: UUID?
    /// The gallery shows the real panel invisibly, taking no pointer.
    var offscreenForChecks = false
    var shownFrame: NSRect? { panel?.isVisible == true ? panel?.frame : nil }

    /// Shows `coach`'s pending card beside `host`, or moves a shown one after the host moved.
    /// Returns false, having shown nothing, when there is no display to put it on.
    @discardableResult
    func show(_ coach: FeedbackCoachModel, host: NSRect, launcherX: CGFloat, level: NSWindow.Level) -> Bool {
        guard let card = coach.card else { hide(); return false }
        guard let visible = (NSScreen.screens.first { $0.frame.intersects(host) } ?? NSScreen.main)?.visibleFrame else { return false }
        let panel = self.panel ?? makePanel(coach)
        self.panel = panel
        let appearing = !panel.isVisible
        // Measured on its own, as the chooser is: the panel's view never sizes the panel itself.
        let size = NSHostingView(rootView: Self.card(coach)).fittingSize
        panel.setFrame(ToolbarCoachPlacement.frame(card: size, host: host, launcherX: launcherX, visible: visible), display: false)
        panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
        panel.ignoresMouseEvents = offscreenForChecks
        // A new card fades in over 160 ms, or appears at once with Reduce Motion; a shown card
        // that follows the toolbar just moves.
        let fades = !offscreenForChecks && appearing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = offscreenForChecks || fades ? 0 : 1
        panel.orderFrontRegardless()
        if fades {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        guard shownCard != card.id else { return true }
        shownCard = card.id
        // Presented once it has been on screen for a display pass, never on a mere request.
        DispatchQueue.main.async { [weak self, weak coach] in
            guard let self, let coach, self.shownCard == card.id, self.panel?.isVisible == true else { return }
            coach.didPresent(card.id)
        }
        return true
    }

    /// Takes the card down: a 160 ms fade, as it came, or at once with Reduce Motion.
    func hide() {
        guard let panel else { return }
        self.panel = nil; shownCard = nil
        if offscreenForChecks || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil); panel.contentView = nil
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil); panel.contentView = nil }
        })
    }

    private func makePanel(_ coach: FeedbackCoachModel) -> ToolbarCoachWindow {
        let panel = ToolbarCoachWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Hint"
        panel.isFloatingPanel = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSHostingView(rootView: Self.card(coach))
        view.sizingOptions = []
        panel.contentView = view
        return panel
    }

    /// The card at its standard 320-point width; larger text wraps and grows it downward.
    private static func card(_ coach: FeedbackCoachModel) -> some View {
        CoachCardView(coach: coach).frame(width: 320).fixedSize(horizontal: false, vertical: true)
            .tint(Workbench.accent).workbenchTheme()
    }
}
