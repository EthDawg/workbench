import AppKit
import ToolbarCore

/// A single native tracking area around the content; no global event monitors.
@MainActor public final class ToolbarTrackingView: NSView {
    public var event: ((ToolbarEvent) -> Void)?
    public var acceptsCrossings = false
    private var area: NSTrackingArea?
    private var gate = ToolbarPointerGate(point: NSEvent.mouseLocation)

    public init(content: NSView) {
        super.init(frame: content.frame)
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(next); area = next
    }

    public var pointerInside: Bool {
        guard let window, window.isVisible else { return false }
        return bounds.contains(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }

    public func settle() {
        let inside = pointerInside
        gate.settled(at: NSEvent.mouseLocation, inside: inside)
        event?(inside ? .pointerEntered : .pointerLeft)
    }

    public override func mouseEntered(with event: NSEvent) { cross(event, inside: true) }
    public override func mouseExited(with event: NSEvent) { cross(event, inside: false) }
    public override func mouseMoved(with event: NSEvent) {
        // Enter may have been suppressed while the window settled. A real move
        // across the final boundary remains authoritative.
        cross(event, inside: pointerInside)
    }
    private func cross(_ event: NSEvent, inside: Bool) {
        guard acceptsCrossings, let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        if let next = gate.crossing(at: point, inside: inside) { self.event?(next) }
    }
}
