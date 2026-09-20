import AppKit
import Combine

/// A desktop layer is allowed only while the still image we applied is still
/// owned on the original display and Space. This state never reapplies a picture.
struct DesktopMotionSession {
    enum Suspension: Hashable { case computerSleep, displaySleep, inactiveSession }
    enum Decision: Equatable { case show, hide, stop }

    let displayID: UInt32
    let expectedStill: URL
    private(set) var isPaused = false
    private(set) var suspensions: Set<Suspension> = []
    private(set) var isValid = true

    init?(displayID: UInt32, expectedStill: URL) {
        guard expectedStill.isFileURL, !expectedStill.hasDirectoryPath else { return nil }
        self.displayID = displayID
        self.expectedStill = expectedStill.standardizedFileURL
    }

    mutating func pause(_ value: Bool) { isPaused = value }
    mutating func suspend(_ reason: Suspension, _ value: Bool) {
        if value { suspensions.insert(reason) } else { suspensions.remove(reason) }
    }
    mutating func invalidate() { isValid = false }

    mutating func evaluate(displayExists: Bool, currentStill: URL?) -> Decision {
        guard isValid, displayExists else { isValid = false; return .stop }
        // Desktop queries can be temporarily unavailable during sleep/session
        // changes. Check again before showing, without showing in the meantime.
        guard suspensions.isEmpty else { return .hide }
        guard let currentStill, currentStill.isFileURL,
              DesktopImageVerification.matches(currentStill, expectedStill) else {
            isValid = false; return .stop
        }
        return isPaused ? .hide : .show
    }
}

private final class DesktopMotionWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Explicit, app-owned motion over an already verified native still wallpaper.
/// No login persistence, wallpaper writes, Space switching or presentation owner.
@MainActor
final class DesktopMotionController: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var status = "Desktop motion is off."

    private var session: DesktopMotionSession?
    private var window: DesktopMotionWindow?
    private var movingView: MovingSceneView?
    private var displayName = "display"
    private var timer: Timer?
    private var observations = Set<AnyCancellable>()
    private var suspended: Set<DesktopMotionSession.Suspension> = []

    override init() {
        super.init()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.activeSpaceDidChangeNotification, in: workspace) { [weak self] in
            guard let self, self.isRunning else { return }
            self.finish("Desktop motion stopped because the desktop Space changed.")
        }
        observe(NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.checkOwnership() }
        observe(NSApplication.willTerminateNotification) { [weak self] in self?.stop() }
        observe(NSWorkspace.willSleepNotification, in: workspace) { [weak self] in self?.suspend(.computerSleep, true) }
        observe(NSWorkspace.didWakeNotification, in: workspace) { [weak self] in self?.suspend(.computerSleep, false) }
        observe(NSWorkspace.screensDidSleepNotification, in: workspace) { [weak self] in self?.suspend(.displaySleep, true) }
        observe(NSWorkspace.screensDidWakeNotification, in: workspace) { [weak self] in self?.suspend(.displaySleep, false) }
        observe(NSWorkspace.sessionDidResignActiveNotification, in: workspace) { [weak self] in self?.suspend(.inactiveSession, true) }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, in: workspace) { [weak self] in self?.suspend(.inactiveSession, false) }
    }

    /// Call only after native wallpaper application and verification succeeded.
    /// The caller passes its applied scene snapshot, with desktop motion enabled.
    @discardableResult
    func start(scene: DemoScene, backdrop: NSImage, logo: NSImage? = nil,
               hand: NSImage? = nil, persona: NSImage? = nil,
               screen: NSScreen, expectedStill: URL, ambience: AmbientSceneImages? = nil) -> Bool {
        stop()
        guard let id = Self.displayID(screen), let currentScreen = Self.screen(id),
              var proposed = DesktopMotionSession(displayID: id, expectedStill: expectedStill),
              proposed.evaluate(displayExists: true, currentStill: NSWorkspace.shared.desktopImageURL(for: currentScreen)) == .show else {
            status = "Desktop motion could not start. Apply and verify a still wallpaper on this display first."
            return false
        }
        for reason in suspended { proposed.suspend(reason, true) }
        let view = MovingSceneView(frame: NSRect(origin: .zero, size: currentScreen.frame.size))
        view.configure(scene: scene, backdrop: Self.snapshot(backdrop), logo: logo.map(Self.snapshot),
                       hand: hand.map(Self.snapshot), persona: persona.map(Self.snapshot), ambience: ambience)
        view.motionRequested = false
        view.motionSuspended = !suspended.isEmpty
        view.autoresizingMask = [.width, .height]

        let window = DesktopMotionWindow(contentRect: currentScreen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.setAccessibilityElement(false)
        window.contentView = view
        self.window = window; movingView = view; session = proposed
        displayName = currentScreen.localizedName
        isRunning = true; isPaused = false
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkOwnership() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        checkOwnership()
        return isRunning
    }

    func stop() { finish("Desktop motion is off. The native still wallpaper is unchanged.") }
    func pause() {
        guard session != nil else { return }
        session?.pause(true); isPaused = true; checkOwnership()
    }
    func resume() {
        guard session != nil else { return }
        session?.pause(false); isPaused = false; checkOwnership()
    }
    func togglePause() { if isPaused { resume() } else { pause() } }

    private func suspend(_ reason: DesktopMotionSession.Suspension, _ value: Bool) {
        if value { suspended.insert(reason) } else { suspended.remove(reason) }
        session?.suspend(reason, value)
        checkOwnership()
    }

    private func checkOwnership() {
        guard var session else { return }
        // Do not ask WindowServer for a desktop image while the session sleeps.
        let screen = Self.screen(session.displayID)
        let currentStill = suspended.isEmpty ? screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) } : nil
        let decision = session.evaluate(displayExists: screen != nil, currentStill: currentStill)
        self.session = session
        switch decision {
        case .stop:
            finish(screen == nil ? "Desktop motion stopped because its display is unavailable."
                   : "Desktop motion stopped because the native wallpaper changed or could not be verified.")
        case .hide:
            movingView?.motionRequested = false
            movingView?.motionSuspended = !suspended.isEmpty
            window?.orderOut(nil)
            status = isPaused ? "Desktop motion is paused. The native still wallpaper is showing."
                : "Desktop motion is suspended until this display and session wake."
        case .show:
            guard let screen, let window else { finish("Desktop motion stopped because its display is unavailable."); return }
            if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
            movingView?.motionSuspended = false
            movingView?.motionRequested = true
            if !window.isVisible { window.orderFrontRegardless() }
            status = "Enabled on \(displayName) while Workbench is open. Pauses when hidden, with Reduce Motion or Low Power Mode, or when the Mac gets hot."
        }
    }

    private func finish(_ message: String) {
        timer?.invalidate(); timer = nil
        session?.invalidate(); session = nil
        movingView?.motionRequested = false; movingView?.motionSuspended = true
        window?.orderOut(nil); window?.contentView = nil; window?.close()
        movingView = nil; window = nil
        isRunning = false; isPaused = false; status = message
    }

    private func observe(_ name: Notification.Name, in center: NotificationCenter = .default,
                         perform action: @escaping @MainActor () -> Void) {
        center.publisher(for: name).receive(on: RunLoop.main).sink { _ in
            MainActor.assumeIsolated { action() }
        }.store(in: &observations)
    }
    private static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
    private static func screen(_ id: UInt32) -> NSScreen? { NSScreen.screens.first { displayID($0) == id } }
    private static func snapshot(_ image: NSImage) -> NSImage { (image.copy() as? NSImage) ?? image }
    deinit {
        timer?.invalidate()
        // Normal Quit calls stop(); also release an unexpectedly discarded owner
        // on AppKit's thread without leaving its non-released window behind.
        if let window {
            DispatchQueue.main.async { window.orderOut(nil); window.contentView = nil; window.close() }
        }
    }
}
