import AppKit

/// One temporary, click-through guide for the toolbar's edge rails and exact landing frame.
@MainActor public final class ToolbarSnapGuide {
    private var panel: NSPanel?
    private let accent: NSColor
    public init(accent: NSColor = .controlAccentColor) { self.accent = accent }

    public func show(frame: NSRect, screen: NSRect, candidate: ToolbarPosition, below owner: NSWindow) {
        guard owner.isVisible else { hide(); return }
        if panel == nil {
            let panel = GuidePanel(contentRect: screen, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = false; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.setAccessibilityElement(false)
            self.panel = panel
        }
        guard let panel else { return }
        let landing = ToolbarGeometry.isAttached(candidate) ? ToolbarGeometry.frame(size: frame.size, position: candidate, screen: screen) : nil
        let view = ToolbarSnapGuideView(frame: NSRect(origin: .zero, size: screen.size))
        view.landing = landing?.offsetBy(dx: -screen.minX, dy: -screen.minY)
        view.accent = accent
        panel.contentView = view; panel.setFrame(screen, display: true)
        panel.level = owner.level
        panel.order(.below, relativeTo: owner.windowNumber)
    }
    public func hide() { panel?.orderOut(nil); panel?.contentView = nil }
    public func shutdown() { hide(); panel?.close(); panel = nil }
}

private final class GuidePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ToolbarSnapGuideView: NSView {
    var landing: NSRect?
    var accent: NSColor = .controlAccentColor
    override func draw(_ dirtyRect: NSRect) {
        let rail = NSBezierPath(roundedRect: bounds.insetBy(dx: ToolbarLayout.dockInset, dy: ToolbarLayout.dockInset), xRadius: 12, yRadius: 12)
        NSColor.white.withAlphaComponent(0.7).setStroke(); rail.lineWidth = 3; rail.stroke()
        accent.withAlphaComponent(0.55).setStroke(); rail.lineWidth = 1
        rail.setLineDash([5, 4], count: 2, phase: 0); rail.stroke()
        if let landing {
            let path = NSBezierPath(roundedRect: landing.insetBy(dx: -4, dy: -4).intersection(bounds), xRadius: 16, yRadius: 16)
            NSColor.white.setStroke(); path.lineWidth = 5; path.stroke()
            accent.setStroke(); path.lineWidth = 3; path.stroke()
        }
    }
}
