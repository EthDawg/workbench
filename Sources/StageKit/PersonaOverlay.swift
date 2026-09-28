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
        artwork.resumeRing()
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
    func hide() { artwork.cancelDragging(); artwork.pauseRing(); window?.orderOut(nil); window?.alphaValue = 1 }
    /// The voice outline makes room for itself: the window grows around the
    /// artwork, which keeps its size and moves in from a screen edge only as far
    /// as the outline needs, so it is never cut off by the edge or the Dock.
    func setVoiceRing(_ on: Bool) {
        guard artwork.ringOn != on else { return }
        artwork.ringOn = on
        if window?.isVisible == true { position() }
    }
    func showVoice(_ frames: [PersonaVoiceFrame]) { artwork.showVoice(frames) }
    /// The visible edge the voice outline follows. nil measures it from the
    /// artwork's pixels; an appearance that knows its shape passes it in.
    func setOutline(_ outline: PersonaArtworkOutline?) {
        guard artwork.outline != outline else { return }
        artwork.outline = outline
        if window?.isVisible == true { position() }
    }
    func shutdown() { hide(); artwork.ringOn = false; screenChanges = nil; onPlacementChange = nil; onSelection = nil }

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
        let available = screen.visibleFrame
        let placement = PersonaPlacement(image: "persona.png", x: state.x, y: state.y, width: state.width)
        let placed = PersonaGeometry.rect(placement, imageSize: image.size, in: available.size)
        let insets = artwork.ringInsets(for: placed.size)
        artwork.artworkInsets = insets
        window.setFrame(Self.placedFrame(placed, insets: insets, x: state.x, y: state.y, in: available), display: true)
        // Remember the chosen monitor for this session even before the first
        // drag, so moving the pointer to another screen cannot move the card.
        state.screenID = Self.screenID(screen)
    }
    /// The artwork and its ring placed with the same normalised travel as the
    /// artwork alone, so both stay wholly on screen at either end of each axis.
    static func placedFrame(_ placed: CGRect, insets: NSEdgeInsets, x: Double, y: Double, in available: CGRect) -> CGRect {
        guard insets.left + insets.right + insets.top + insets.bottom > 0 else { return placed.offsetBy(dx: available.minX, dy: available.minY) }
        let size = CGSize(width: placed.width + insets.left + insets.right, height: placed.height + insets.top + insets.bottom)
        return CGRect(x: available.minX + max(0, available.width - size.width) * min(1, max(0, x)),
                      y: available.minY + max(0, available.height - size.height) * min(1, max(0, y)),
                      width: size.width, height: size.height)
    }
    private func finishDragging() {
        guard let window, let image = artwork.image else { return }
        let screen = NSScreen.screens.max { lhs, rhs in
            Self.overlap(window.frame, lhs.visibleFrame) < Self.overlap(window.frame, rhs.visibleFrame)
        } ?? preferredScreen()
        guard let screen else { return }
        let available = screen.visibleFrame
        let placement = PersonaPlacement(image: "persona.png", width: state.width)
        let artworkSize = PersonaGeometry.rect(placement, imageSize: image.size, in: available.size).size
        let insets = artwork.ringInsets(for: artworkSize)
        let size = CGSize(width: artworkSize.width + insets.left + insets.right, height: artworkSize.height + insets.top + insets.bottom)
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
    var image: NSImage? { didSet { if image !== oldValue { analysis = nil }; artworkChanged() } }
    var onFinishDragging: (() -> Void)?
    var onSelection: (() -> Void)?
    /// Off leaves the artwork exactly as it was: no room, layer or microphone.
    var ringOn = false { didSet { if ringOn != oldValue { ringChanged() } } }
    /// Where the artwork sits inside the window; the rest belongs to the outline.
    var artworkInsets = NSEdgeInsetsZero { didSet { needsLayout = true } }
    private var anchor: CGPoint?
    private var startingOrigin: CGPoint?
    /// The artwork's visible edge when its appearance knows it; otherwise it
    /// is measured from the pixels.
    var outline: PersonaArtworkOutline? { didSet { if outline != oldValue { needsLayout = true } } }
    private let artworkLayer = CALayer()
    private let ring = PersonaVoiceRingLayer()
    private var analysis: (image: ObjectIdentifier, outline: PersonaArtworkOutline, tint: NSColor)?
    private var ringLink: CADisplayLink?
    private var displayOptions: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        // No generated frame, label, material or shadow is baked over the user's
        // finished artwork. An opaque imported background remains opaque. The
        // optional voice outline stands behind it, in room the window makes for it.
        artworkLayer.contentsGravity = .resizeAspect
        artworkLayer.minificationFilter = .trilinear
        artworkLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        ring.isHidden = true
        layer?.addSublayer(ring)
        layer?.addSublayer(artworkLayer)
        setAccessibilityElement(true); setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let rect = CGRect(x: artworkInsets.left, y: artworkInsets.bottom,
                          width: max(0, bounds.width - artworkInsets.left - artworkInsets.right),
                          height: max(0, bounds.height - artworkInsets.top - artworkInsets.bottom))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        artworkLayer.frame = rect
        ring.frame = bounds
        if ringOn, let analysis = analyzed() {
            ring.tint = analysis.tint
            ring.geometry = PersonaVoiceRingGeometry(outline: outline ?? analysis.outline, artwork: rect)
        }
        CATransaction.commit()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        artworkChanged()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopTicking() }
    }

    /// Room the outline needs around artwork of this size; none while it is off.
    func ringInsets(for size: CGSize) -> NSEdgeInsets {
        guard ringOn, size.width > 0, size.height > 0, let analysis = analyzed() else { return NSEdgeInsetsZero }
        return PersonaVoiceRingGeometry(outline: outline ?? analysis.outline, artwork: CGRect(origin: .zero, size: size)).outsets
    }
    /// Silence costs nothing: the display link sleeps until there is a voice.
    func showVoice(_ frames: [PersonaVoiceFrame]) {
        guard ringOn, !frames.isEmpty else { return }
        ring.receive(frames, at: CACurrentMediaTime())
        if ring.isMoving { tick() }
    }
    func pauseRing() { ring.reset(); stopTicking() }
    func resumeRing() { if ringOn { ring.reset() } }

    private func artworkChanged() {
        guard let image else { artworkLayer.contents = nil; return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let desired = image.recommendedLayerContentsScale(scale)
        artworkLayer.contents = image.layerContents(forContentsScale: desired)
        artworkLayer.contentsScale = desired
        ring.contentsScale = scale; ring.setNeedsLayout()
        needsLayout = true
    }
    /// Measured once per artwork: the edge to follow and the colour to use.
    private func analyzed() -> (image: ObjectIdentifier, outline: PersonaArtworkOutline, tint: NSColor)? {
        guard let image else { return nil }
        let key = ObjectIdentifier(image)
        if let analysis, analysis.image == key { return analysis }
        guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let result = PersonaArtworkOutline.analyze(bitmap)
        analysis = (key, result.outline, result.tint)
        return analysis
    }
    private func ringChanged() {
        ring.reset()
        applyDisplayOptions()
        ring.isHidden = !ringOn
        if let displayOptions { NSWorkspace.shared.notificationCenter.removeObserver(displayOptions) }
        displayOptions = nil
        if ringOn {
            // Reduce Motion and Increase Contrast apply at once, mid-presentation too.
            displayOptions = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.applyDisplayOptions()
                }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.25
            ring.add(fade, forKey: "appear")
        } else {
            stopTicking(); ring.geometry = nil
        }
        needsLayout = true
    }

    private func applyDisplayOptions() {
        ring.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ring.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// The display link runs only while the outline is lit or easing.
    private func tick() {
        if ringLink == nil {
            let link = displayLink(target: self, selector: #selector(advance(_:)))
            link.add(to: .main, forMode: .common)
            ringLink = link
        }
        ringLink?.isPaused = false
    }
    /// Each frame is drawn for the moment it reaches the screen.
    @objc private func advance(_ link: CADisplayLink) {
        if !ring.advance(to: link.targetTimestamp) { link.isPaused = true }
    }
    private func stopTicking() { ringLink?.invalidate(); ringLink = nil }

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
