import AppKit

/// The main window and the apps around a standalone Snap capture. The app
/// supplies its window and NSWorkspace; checks supply a recording double.
@MainActor
protocol SnapCaptureDesktop: AnyObject {
    /// The main window is on screen: open, not minimised and not hidden.
    var windowOnScreen: Bool { get }
    /// The app in front when it is not Workbench.
    var appInFront: pid_t? { get }
    /// The last other app that was in front, for a capture that began from
    /// Workbench's panel or toolbar while the main window was away.
    var lastOtherApp: pid_t? { get }
    func hideWindow()
    /// Puts the window back where it was, in front of Workbench's own windows.
    func showWindow(activatingWorkbench: Bool)
    /// Brings the window forward on the Snap page, deminiaturising or
    /// reopening it, where the editor or the problem is shown.
    func openSnapPage()
    func activate(_ app: pid_t)
}

/// The host's one completion path for a standalone Snap capture, whichever
/// door started it: Home, the Snap page, the panel, the toolbar or the Snap
/// shortcut. `SnapModel` stays the one draft owner and editor; this only
/// decides what the person sees when the capture ends.
///
/// - A capture opens the Snap page with its editor, from any page, with the
///   window hidden, minimised or closed.
/// - An acquisition problem opens the Snap page, where it can be acted on.
/// - A cancelled selector adds nothing and shows nothing: the main window
///   returns to how it was and the app you were in comes back to the front.
/// - Save & Copy of a capture that began in another app returns to that app,
///   so the image can be pasted there at once. Save and Cancel stay here.
@MainActor
final class SnapCaptureHost {
    /// What was on screen when the capture began.
    struct Scene: Equatable {
        var windowOnScreen: Bool
        /// The app the person was working in, or nil for Workbench itself.
        var origin: pid_t?
    }

    let desktop: any SnapCaptureDesktop
    private(set) var scene: Scene?
    /// A capture from another app, waiting for its draft to be saved and copied.
    private(set) var returning: (draft: UUID, origin: pid_t)?

    init(desktop: any SnapCaptureDesktop) { self.desktop = desktop }

    /// Wires the Snap owner's capture callbacks to this path, and the owner
    /// keeps this host. `closeControls` puts away the panel and toolbar, which
    /// never appear in a capture.
    func attach(to snap: SnapModel, closeControls: @escaping () -> Void) {
        snap.onHideForCapture = { origin in self.begin(origin: origin); closeControls() }
        snap.onRestoreAfterCapture = { outcome in self.finish(outcome) }
        snap.onDraftClosed = { id, copied in self.draftClosed(id, copied: copied) }
    }

    /// Before acquisition: remember what was on screen, then hide the window.
    /// A minimised window is off screen already and stays in the Dock. A door
    /// that knows the app the person was in passes it: the panel activates
    /// Workbench, so the frontmost app no longer says where they were.
    func begin(origin known: pid_t? = nil) {
        let onScreen = desktop.windowOnScreen
        // Workbench in front with its window away means the person reached the
        // panel or toolbar from another app: that app is where they were.
        let origin = known ?? desktop.appInFront ?? (onScreen ? nil : desktop.lastOtherApp)
        scene = Scene(windowOnScreen: onScreen, origin: origin)
        if onScreen { desktop.hideWindow() }
    }

    func finish(_ outcome: SnapCaptureOutcome) {
        let scene = self.scene
        self.scene = nil
        switch outcome {
        case .draft(let id):
            returning = scene?.origin.map { (draft: id, origin: $0) }
            desktop.openSnapPage()
        case .pending, .failed:
            desktop.openSnapPage()
        case .cancelled:
            guard let scene else { return }
            if scene.windowOnScreen { desktop.showWindow(activatingWorkbench: scene.origin == nil) }
            if let origin = scene.origin { desktop.activate(origin) }
        }
    }

    func draftClosed(_ id: UUID, copied: Bool) {
        guard let returning, returning.draft == id else { return }
        self.returning = nil
        if copied { desktop.activate(returning.origin) }
    }
}

/// The app's desktop: its main window and NSWorkspace.
@MainActor
final class AppKitSnapCaptureDesktop: SnapCaptureDesktop {
    private let window: () -> NSWindow?
    private let showSnapPage: () -> Void
    private var lastApp: NSRunningApplication?
    private var observer: NSObjectProtocol?

    init(window: @escaping () -> NSWindow?, openSnapPage: @escaping () -> Void) {
        self.window = window
        self.showSnapPage = openSnapPage
        let own = ProcessInfo.processInfo.processIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                    object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != own else { return }
            MainActor.assumeIsolated { self?.lastApp = app }
        }
    }

    var windowOnScreen: Bool { window().map { $0.isVisible && !$0.isMiniaturized } ?? false }
    var appInFront: pid_t? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app.processIdentifier
    }
    var lastOtherApp: pid_t? { lastApp.flatMap { $0.isTerminated ? nil : $0.processIdentifier } }
    func hideWindow() { window()?.orderOut(nil) }
    func showWindow(activatingWorkbench: Bool) {
        guard let window = window() else { return }
        if activatingWorkbench { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        else { window.orderFront(nil) }
    }
    func openSnapPage() { showSnapPage() }
    func activate(_ app: pid_t) {
        guard let running = NSRunningApplication(processIdentifier: app), !running.isTerminated else { return }
        running.activate(options: [])
    }
}
