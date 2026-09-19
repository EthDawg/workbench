import AppKit
import Combine

private final class PersonaPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PersonaOverlayController: NSWindowController, PersonaSessionDisplaying {
    var onPlacementChange: ((PersonaOverlayState) -> Void)?
    var onSelection: (() -> Void)?
    var frame: CGRect? { window?.frame }
    private var state = PersonaOverlayState()
    private let artwork = PersonaArtworkView()
    private var screenChanges: AnyCancellable?

    init() {
        let panel = PersonaPanel(contentRect: CGRect(x: 0, y: 0, width: 160, height: 160),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Workbench persona"
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = artwork
        artwork.onFinishDragging = { [weak self] in self?.finishDragging() }
        artwork.onSelection = { [weak self] in self?.onSelection?() }
        screenChanges = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self, self.window?.isVisible == true else { return }
                self.artwork.cancelDragging()
                self.position(); self.onPlacementChange?(self.state)
            }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(image: NSImage, name: String, state: PersonaOverlayState, animated: Bool = false) -> PersonaOverlayState {
        let wasVisible = window?.isVisible == true
        configure(image: image, name: name, state: state)
        let fade = animated && !wasVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window?.alphaValue = fade ? 0 : 1
        window?.orderFrontRegardless()
        if fade {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                window?.animator().alphaValue = 1
            }
        }
        return self.state
    }
    func configure(image: NSImage, name: String, state: PersonaOverlayState) {
        self.state = state
        artwork.image = image
        artwork.setAccessibilityLabel(name)
        artwork.setAccessibilityHelp(state.locked ? "Floating persona. Unlock it in Workbench to move it." : "Drag to move this persona. Lock it in Workbench to let clicks pass through.")
        artwork.toolTip = state.locked ? nil : "Drag to move. Lock in Workbench to let clicks pass through."
        window?.ignoresMouseEvents = state.locked
        position()
    }
    func hide() { artwork.cancelDragging(); window?.orderOut(nil); window?.alphaValue = 1 }
    func shutdown() { hide(); screenChanges = nil; onPlacementChange = nil; onSelection = nil }

    private static func screenID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
    private func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { Self.screenID($0) == state.screenID && state.screenID != nil }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }
    private func position() {
        guard let window, let image = artwork.image, let screen = preferredScreen() else { return }
        let placement = PersonaPlacement(image: "persona.png", x: state.x, y: state.y, width: state.width)
        let rect = PersonaGeometry.rect(placement, imageSize: image.size, in: screen.visibleFrame.size)
            .offsetBy(dx: screen.visibleFrame.minX, dy: screen.visibleFrame.minY)
        window.setFrame(rect, display: true)
        // Remember the chosen monitor for this session even before the first
        // drag, so moving the pointer to another screen cannot move the card.
        state.screenID = Self.screenID(screen)
    }
    private func finishDragging() {
        guard let window, let image = artwork.image else { return }
        let screen = NSScreen.screens.max { lhs, rhs in
            Self.overlap(window.frame, lhs.visibleFrame) < Self.overlap(window.frame, rhs.visibleFrame)
        } ?? preferredScreen()
        guard let screen else { return }
        let available = screen.visibleFrame
        let placement = PersonaPlacement(image: "persona.png", width: state.width)
        let size = PersonaGeometry.rect(placement, imageSize: image.size, in: available.size).size
        let travelX = max(0, available.width - size.width), travelY = max(0, available.height - size.height)
        state.x = travelX > 0 ? min(1, max(0, (window.frame.minX - available.minX) / travelX)) : 0
        state.y = travelY > 0 ? min(1, max(0, (window.frame.minY - available.minY) / travelY)) : 0
        state.screenID = Self.screenID(screen)
        position()
        onPlacementChange?(state)
    }
    private static func overlap(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

private final class PersonaArtworkView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var onFinishDragging: (() -> Void)?
    var onSelection: (() -> Void)?
    private var anchor: CGPoint?
    private var startingOrigin: CGPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // No generated frame, label, material or shadow is baked over the user's
        // finished artwork. An opaque imported background remains opaque.
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
    }
    override func mouseDown(with event: NSEvent) {
        guard let window, !window.ignoresMouseEvents else { return }
        onSelection?()
        anchor = window.convertPoint(toScreen: event.locationInWindow)
        startingOrigin = window.frame.origin
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, !window.ignoresMouseEvents, let anchor, let startingOrigin else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(CGPoint(x: startingOrigin.x + point.x - anchor.x,
                                      y: startingOrigin.y + point.y - anchor.y))
    }
    override func mouseUp(with event: NSEvent) {
        if anchor != nil { onFinishDragging?() }
        cancelDragging()
    }
    func cancelDragging() { anchor = nil; startingOrigin = nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
