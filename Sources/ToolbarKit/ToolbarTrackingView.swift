import AppKit
import ToolbarCore

/// A single native tracking area around the content; no global event monitors.
///
/// Entry into a resting toolbar is debounced: a pointer passing across the
/// resting element on its way somewhere else must not spring the row open. The
/// entry is delivered after `revealDelay` only if the pointer is still inside.
/// An exit before then cancels it and delivers nothing, because the core never
/// learned of the entry. Entries into an already revealed row, every exit and
/// `settle()` stay immediate. The reducer is untouched: it still sees one
/// crossing, just a slightly later one.
@MainActor public final class ToolbarTrackingView: NSView {
    public var event: ((ToolbarEvent) -> Void)?
    /// Resize, drag and surface changes suspend tracking. They also cancel any
    /// resting-pill dwell: a reveal from the previous geometry is no longer intent.
    public var acceptsCrossings = false {
        didSet { if !acceptsCrossings { cancelPendingEntry() } }
    }
    /// True while the window shows the resting element rather than the row.
    public var isRestingSized: () -> Bool = { false }
    /// The one reveal delay, in seconds, for measured tuning.
    public static let revealDelay: TimeInterval = 0.12
    private var area: NSTrackingArea?
    private var gate = ToolbarPointerGate(point: NSEvent.mouseLocation)
    private let clock: ToolbarGraceClock
    private var entryPending = false
    private var entryGeneration = 0
    /// Where the pointer is on screen. Tests inject it; production asks AppKit.
    var locatePointer: () -> NSPoint = { NSEvent.mouseLocation }

    public init(content: NSView, clock: ToolbarGraceClock? = nil) {
        self.clock = clock ?? ToolbarTaskClock(delay: Self.revealDelay)
        super.init(frame: content.frame)
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelPendingEntry() }
        super.viewWillMove(toWindow: newWindow)
    }

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
        return bounds.contains(convert(window.convertPoint(fromScreen: locatePointer()), from: nil))
    }

    public func settle() {
        cancelPendingEntry()
        let inside = pointerInside
        gate.settled(at: locatePointer(), inside: inside)
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
        guard let window else { return }
        cross(at: window.convertPoint(toScreen: event.locationInWindow), inside: inside)
    }

    /// One crossing at a screen point. The gate drops the synthetic ones.
    func cross(at point: NSPoint, inside: Bool) {
        guard acceptsCrossings, window != nil else { return }
        guard let next = gate.crossing(at: point, inside: inside) else { return }
        switch next {
        case .pointerEntered where isRestingSized():
            entryPending = true
            entryGeneration += 1
            let generation = entryGeneration
            clock.start { [weak self] in
                guard let self, self.entryPending, self.acceptsCrossings,
                      self.entryGeneration == generation else { return }
                self.entryPending = false
                if self.pointerInside { self.event?(.pointerEntered) }
                else {
                    // An exit can be swallowed by native tracking. The core never
                    // saw the entry; reset the gate so the next real entry can dwell.
                    self.gate.settled(at: self.locatePointer(), inside: false)
                }
            }
        case .pointerLeft where entryPending:
            cancelPendingEntry()
        default:
            event?(next)
        }
    }

    private func cancelPendingEntry() {
        guard entryPending else { return }
        entryPending = false
        entryGeneration += 1
        clock.cancel()
    }
}
