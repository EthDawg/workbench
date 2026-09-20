import AppKit
import SceneSyncKit
import Accessibility

struct AmbientSceneImages {
    let preset: String
    let cleanPlate: CGImage
    let detail: CGImage
}

/// One native photograph layer, with stationary authored foreground. Layout
/// and image changes redraw; compositor motion never calls the scene renderer.
class MovingSceneView: NSView {
    private let photograph = CALayer()
    private let ambient = AmbientPhotoLayer()
    private var ambientImages: AmbientSceneImages?
    private var hasAmbience = false
    private let foreground = MovingSceneForeground()
    private let branding = MovingSceneBranding()
    private var scene: DemoScene?
    private var backdrop: NSImage?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var sleepReasons = Set<String>()
    var motionRequested = false { didSet { updateMotion() } }
    var motionSuspended = false { didSet { updateMotion() } }
    var isAnimating: Bool { ambient.isPlaying || photograph.animation(forKey: GentlePhotoMotion.animationKey) != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.masksToBounds = true
        photograph.contentsGravity = .resize; photograph.magnificationFilter = .linear
        layer?.addSublayer(photograph)
        ambient.isHidden = true; layer?.addSublayer(ambient)
        foreground.wantsLayer = true; branding.wantsLayer = true
        addSubview(foreground); addSubview(branding)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(scene: DemoScene, backdrop: NSImage, logo: NSImage?, hand: NSImage?, persona: NSImage?, ambience: AmbientSceneImages? = nil) {
        let changed = self.scene != scene || self.backdrop !== backdrop
        self.scene = scene
        // PNG transparency must reveal the same base as the still renderer,
        // not the black desktop window behind this view.
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        if self.backdrop !== backdrop {
            self.backdrop = backdrop
            photograph.contents = backdrop.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        if ambientImages?.preset != ambience?.preset || ambientImages?.cleanPlate !== ambience?.cleanPlate || ambientImages?.detail !== ambience?.detail {
            ambientImages = ambience
            ambient.setPlaying(false)
            hasAmbience = ambience.map { ambient.configure(preset: $0.preset, cleanPlate: $0.cleanPlate, detail: $0.detail) } ?? false
            ambient.isHidden = !hasAmbience; photograph.isHidden = hasAmbience
            photograph.removeAnimation(forKey: GentlePhotoMotion.animationKey)
            needsLayout = true
        }
        foreground.configure(scene: scene, backdrop: backdrop, hand: hand)
        branding.configure(scene: scene, logo: logo, persona: persona)
        if changed { needsLayout = true }
    }
    func insertVideoLayer(_ layer: CALayer) {
        self.layer?.insertSublayer(layer, below: branding.layer)
    }
    override func layout() {
        super.layout()
        guard let scene, let backdrop, backdrop.size.width > 0, backdrop.size.height > 0 else { return }
        let fit = max(bounds.width / backdrop.size.width, bounds.height / backdrop.size.height) * scene.zoom
        let size = CGSize(width: backdrop.size.width * fit, height: backdrop.size.height * fit)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        photograph.frame = CGRect(x: (bounds.width - size.width) * scene.backgroundX,
                                 y: (bounds.height - size.height) * scene.backgroundY,
                                 width: size.width, height: size.height)
        ambient.frame = photograph.frame; ambient.layoutIfNeeded()
        foreground.frame = bounds; branding.frame = bounds
        foreground.needsDisplay = true; branding.needsDisplay = true
        CATransaction.commit()
        updateMotion()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        if let window {
            observe(.default, NSWindow.didChangeOcclusionStateNotification, object: window) { $0.updateMotion() }
            observe(.default, .NSProcessInfoPowerStateDidChange) { $0.updateMotion() }
            if #available(macOS 15.0, *) {
                observe(.default, AccessibilitySettings.animatedImagesEnabledDidChangeNotification) { $0.updateMotion() }
            } else {
                observe(.default, .AXAnimatedImagesEnabledDidChange) { $0.updateMotion() }
            }
            observe(.default, ProcessInfo.thermalStateDidChangeNotification) { $0.updateMotion() }
            let center = NSWorkspace.shared.notificationCenter
            observe(center, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { $0.updateMotion() }
            let sleepPairs: [(Notification.Name, Notification.Name, String)] = [
                (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "computer"),
                (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "display"),
                (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "session")
            ]
            for (sleep, wake, reason) in sleepPairs {
                observe(center, sleep) { $0.sleepReasons.insert(reason); $0.updateMotion() }
                observe(center, wake) { $0.sleepReasons.remove(reason); $0.updateMotion() }
            }
        }
        updateMotion()
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, object: Any? = nil,
                         action: @escaping (MovingSceneView) -> Void) {
        let observer = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            guard let self else { return }; action(self)
        }
        observers.append((center, observer))
    }
    private func removeObservers() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }
    private func updateMotion() {
        let playsAnimatedImages: Bool
        if #available(macOS 15.0, *) { playsAnimatedImages = AccessibilitySettings.animatedImagesEnabled }
        else { playsAnimatedImages = AXAnimatedImagesEnabled() }
        let allowed = GentlePhotoMotion.permitted(requested: motionRequested && !motionSuspended && sleepReasons.isEmpty && playsAnimatedImages,
            visible: window?.isVisible == true && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermalState: ProcessInfo.processInfo.thermalState)
        if hasAmbience {
            photograph.removeAnimation(forKey: GentlePhotoMotion.animationKey)
            ambient.setPlaying(allowed)
            return
        }
        // A missing authored detail keeps its poster still. It must not silently
        // become a whole-picture zoom of the room, buildings or device.
        let fallbackAllowed = allowed && scene?.ambience == nil
        if fallbackAllowed && !isAnimating && photograph.contents != nil {
            photograph.add(GentlePhotoMotion.animation(), forKey: GentlePhotoMotion.animationKey)
        } else if !fallbackAllowed && isAnimating { photograph.removeAnimation(forKey: GentlePhotoMotion.animationKey) }
    }
    deinit { removeObservers() }
}

private final class MovingSceneForeground: NSView {
    private var scene: DemoScene?
    private var backdrop: NSImage?
    private var hand: NSImage?
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func configure(scene: DemoScene, backdrop: NSImage, hand: NSImage?) {
        if self.scene != scene || self.backdrop !== backdrop || self.hand !== hand {
            self.scene = scene; self.backdrop = backdrop; self.hand = hand; needsDisplay = true
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let scene, let backdrop else { return }
        SceneRenderer.draw(scene, image: backdrop, size: bounds.size, handImage: hand, drawsBackground: false)
    }
}

private final class MovingSceneBranding: NSView {
    private var scene: DemoScene?
    private var logo: NSImage?
    private var persona: NSImage?
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func configure(scene: DemoScene, logo: NSImage?, persona: NSImage?) {
        if self.scene != scene || self.logo !== logo || self.persona !== persona {
            self.scene = scene; self.logo = logo; self.persona = persona; needsDisplay = true
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let scene else { return }
        SceneRenderer.drawLogo(scene, size: bounds.size, image: logo)
        SceneRenderer.drawPersona(scene, size: bounds.size, image: persona)
    }
}
