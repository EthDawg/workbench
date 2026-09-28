import AppKit
import ObjectiveC
import SwiftUI

/// `LocalVoice --check-snap-capture` (#151): every Snap door finishes through
/// the host's one completion path. From a page other than Snap, with the main
/// window shown, minimised or closed, and with Workbench or another app in
/// front, a capture opens the editor on the Snap page, a problem shows there,
/// a cancelled selector puts back what was on screen, and Save & Copy returns
/// to the app the capture began in. The real Snap page then presents the
/// editor for the draft. The Snap owner uses a synthetic store, image source,
/// preferences file and pasteboard in a new temporary folder: nothing captures
/// the screen, touches the clipboard or reads the person's own Snaps, and the
/// check window is never on a display.
@MainActor
enum SnapCaptureChecks {
    static func run() async throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("SNAP_CAPTURE_CHECK_FAILED: " + name) }
            count += 1
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("SnapCaptureChecks-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        // An absolute suite path keeps the preferences in this folder, never in ~/Library/Preferences (#128).
        let suite = root.appendingPathComponent("SnapCapturePreferences").path
        guard let preferences = UserDefaults(suiteName: suite) else { throw VoiceError.message("Could not isolate the check's preferences.") }
        defer { preferences.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let image = try syntheticScreen()
        func snapModel(_ name: String, source: SyntheticImageSource) -> SnapModel {
            SnapModel(store: SnapStore(root: root.appendingPathComponent(name, isDirectory: true)), desktop: root.appendingPathComponent("Desktop"),
                      screenshotLocation: FixedScreenshotLocation(), preferences: preferences, screenshotInbox: root.appendingPathComponent("Inbox"),
                      trash: { _ in throw SnapError.message("This check never moves a file to the Trash.") },
                      applyScreenshotLocation: {}, imageSource: source, pasteboard: pasteboard)
        }

        // Each door starts the same capture; what differs is what was on screen.
        let safari: pid_t = 41_001, mail: pid_t = 41_002
        let doors: [(name: String, page: String, windowOnScreen: Bool, inFront: pid_t?, lastOther: pid_t?, origin: pid_t?)] = [
            ("the Home tile", "home", true, nil, safari, nil),
            ("History, another page", "history", true, nil, safari, nil),
            ("the panel over another app, window closed", "dictate", false, nil, safari, safari),
            ("the toolbar over another app, window minimised", "home", false, safari, mail, safari),
            ("the Snap shortcut with the window behind another app", "settings", true, mail, safari, mail)]
        var resolution = 0
        for mode in SnapCapture.Mode.allCases {
            for door in doors {
                let source = SyntheticImageSource(next: .success(image))
                let snap = snapModel("doors-\(mode.rawValue)-\(resolution)", source: source)
                let desktop = RecordingDesktop(page: door.page, windowOnScreen: door.windowOnScreen, inFront: door.inFront, lastOther: door.lastOther)
                SnapCaptureHost(desktop: desktop).attach(to: snap) { desktop.log.append("close controls") }
                let journey = "\(mode.title) from \(door.name)"
                await snap.capture(mode)
                try check(desktop.page == "snap" && desktop.windowOnScreen && desktop.log.last == "open snap"
                          && desktop.log.filter { $0 == "open snap" }.count == 1, "\(journey) opens the Snap page once with the window forward")
                try check(snap.draft?.source == mode.source && snap.draft?.originalPNG == image && !snap.isCapturing && snap.items.isEmpty,
                          "\(journey) leaves one \(mode.title) draft in the editor and nothing saved yet")
                try check(desktop.log.contains("hide") == door.windowOnScreen && !desktop.log.contains { $0.hasPrefix("activate") },
                          "\(journey) hides only a window that was on screen and brings nothing else forward")
                // Save & Copy, Save and Cancel each resolve the draft; only Save & Copy of a capture from another app returns there.
                guard let draft = snap.draft else { throw VoiceError.message("SNAP_CAPTURE_CHECK_FAILED: \(journey) has no draft") }
                desktop.log.removeAll()
                switch resolution % 3 {
                case 0:
                    try check(snap.saveDraft(draft, copyAfterSaving: true) && snap.items.count == 1
                              && pasteboard.data(forType: .png) == snap.items.first.flatMap { try? snap.store.snapshot($0.id).imagePNG },
                              "\(journey): Save & Copy saves one Snap and copies it")
                    try check(desktop.log == (door.origin.map { ["activate \($0)"] } ?? []),
                              "\(journey): Save & Copy returns to the app the capture began in, and only then")
                case 1:
                    try check(snap.saveDraft(draft, copyAfterSaving: false) && snap.items.count == 1 && desktop.log.isEmpty,
                              "\(journey): Save keeps Workbench in front")
                default:
                    snap.draft = nil
                    try check(snap.items.isEmpty && desktop.log.isEmpty, "\(journey): Cancel saves nothing and keeps Workbench in front")
                }
                let saved = snap.items.count
                await snap.capture(mode)
                try check(snap.draft != nil && source.requests == [mode, mode] && snap.items.count == saved,
                          "\(journey): another capture opens after the draft closes, with no hidden or duplicate item")
                resolution += 1
            }
        }

        // Escape in the selector adds nothing, shows no Workbench window it did not
        // show before, and returns to the app you were in.
        let cancels: [(name: String, windowOnScreen: Bool, inFront: pid_t?, lastOther: pid_t?, expected: [String])] = [
            ("from the panel with the window closed", false, nil, safari, ["close controls", "activate \(safari)"]),
            ("from the toolbar over another app, window behind it", true, safari, mail, ["hide", "close controls", "show", "activate \(safari)"]),
            ("from the Snap page", true, nil, safari, ["hide", "close controls", "show and activate Workbench"]),
            ("from the shortcut with the window minimised", false, mail, safari, ["close controls", "activate \(mail)"])]
        for (index, cancel) in cancels.enumerated() {
            let snap = snapModel("cancel-\(index)", source: SyntheticImageSource(next: .success(nil)))
            let desktop = RecordingDesktop(page: "history", windowOnScreen: cancel.windowOnScreen, inFront: cancel.inFront, lastOther: cancel.lastOther)
            SnapCaptureHost(desktop: desktop).attach(to: snap) { desktop.log.append("close controls") }
            await snap.capture(.region)
            try check(desktop.log == cancel.expected && desktop.page == "history" && desktop.windowOnScreen == cancel.windowOnScreen,
                      "a cancelled selector \(cancel.name) restores the window and the app in front: \(desktop.log)")
            try check(snap.draft == nil && snap.items.isEmpty && !snap.isBusy && snap.notice == "Capture cancelled. Nothing was added to history.",
                      "a cancelled selector \(cancel.name) adds nothing and allows another capture")
        }

        // A problem is shown where it can be acted on.
        do {
            let snap = snapModel("failure", source: SyntheticImageSource(next: .failure(SnapError.message("Synthetic capture failure."))))
            let desktop = RecordingDesktop(page: "home", windowOnScreen: false, inFront: safari, lastOther: mail)
            SnapCaptureHost(desktop: desktop).attach(to: snap) { desktop.log.append("close controls") }
            await snap.capture(.window)
            try check(desktop.page == "snap" && desktop.log.last == "open snap" && snap.notice == "Synthetic capture failure."
                      && snap.draft == nil && snap.items.isEmpty && !snap.isBusy, "an acquisition problem opens the Snap page with its explanation")
        }

        // An editor left hidden (its window minimised or closed) never silently
        // blocks the next door: that door brings the same draft back.
        do {
            let source = SyntheticImageSource(next: .success(image))
            let snap = snapModel("pending", source: source)
            let desktop = RecordingDesktop(page: "home", windowOnScreen: true, inFront: nil, lastOther: safari)
            SnapCaptureHost(desktop: desktop).attach(to: snap) { desktop.log.append("close controls") }
            await snap.capture(.screen)
            let first = snap.draft?.id
            desktop.windowOnScreen = false; desktop.inFront = mail; desktop.log.removeAll()
            await snap.capture(.region)
            try check(first != nil && snap.draft?.id == first && source.requests == [.screen] && desktop.log == ["open snap"]
                      && snap.notice == "Finish or cancel the current Snap first.", "a hidden draft is brought back instead of blocking a new capture")
            snap.draft = nil
            await snap.capture(.region)
            try check(snap.draft != nil && snap.draft?.id != first && source.requests == [.screen, .region], "cancelling it lets the next capture start")
        }

        try await checkEditorExposure(makeSnap: { snapModel($0, source: SyntheticImageSource(next: .success(image))) }, check: check)
        print("SNAP_CAPTURE_CHECKS_OK: \(count) checks for every door's editor, Save & Copy, cancelled selectors, problems and hidden drafts")
    }

    /// The Snap page the host opens presents the editor for the captured draft,
    /// while Home, where the capture began, does not. SwiftUI asks the window for
    /// a sheet only while the window is visible, so each check window is ordered
    /// in far off every display, and sheets are recorded as attached instead of
    /// shown. A window restored from the Dock returns on a later turn, after the
    /// draft opened, and the editor must still appear then.
    private static func checkEditorExposure(makeSnap: (String) -> SnapModel, check: (Bool, String) throws -> Void) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let sheets = SheetRequests()
        sheets.start()
        defer { sheets.stop() }
        func fixture(_ snap: SnapModel, page: String) -> (NSWindow, CheckRoute) {
            let route = CheckRoute(); route.page = page
            let window = OffscreenCheckWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1_000, height: 720),
                                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0
            let hosting = NSHostingController(rootView: ExposureFixture(route: route, snap: snap))
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.setFrame(NSRect(x: -30_000, y: -30_000, width: 1_000, height: 720), display: false)
            return (window, route)
        }
        let journeys: [(name: String, page: String, onScreen: Bool, returnsLater: Bool)] = [
            ("from Home with the window on screen", "home", true, false),
            ("from Home with the window minimised, restored from the Dock", "home", false, true),
            ("from the Snap page, with the window restored after the draft opened", "snap", true, true)]
        for (index, journey) in journeys.enumerated() {
            let snap = makeSnap("exposure-\(index)")
            let (window, route) = fixture(snap, page: journey.page)
            defer { window.contentViewController = nil; window.close() }
            if journey.onScreen { window.orderFrontRegardless() }
            try await settle()
            let before = sheets.requests
            try check(before == sheets.requests && window.frame.minX < -20_000, "the check window starts \(journey.name) off every display, with no sheet")
            let host = SnapCaptureHost(desktop: WindowDesktop(window: window, route: route, returnsLater: journey.returnsLater))
            host.attach(to: snap) {}
            await snap.capture(.region)
            try await settle(for: 3) { sheets.requests > before }
            try await settle()
            try check(route.page == "snap" && snap.draft != nil && window.isVisible && sheets.requests == before + 1,
                      "a capture \(journey.name) opens the Snap page, which presents the editor once")
            try check(window.frame.minX < -20_000, "the check window stayed off every display")
            snap.draft = nil
            try await settle()
        }
        // The fixture's own control: a draft while Home shows is never presented.
        let snap = makeSnap("exposure-control")
        let (window, _) = fixture(snap, page: "home")
        defer { window.contentViewController = nil; window.close() }
        window.orderFrontRegardless()
        try await settle()
        let before = sheets.requests
        snap.draft = SnapDraft(originalPNG: try syntheticScreen(), source: .clipboard, title: "Fixture control", notes: "", tags: [], edit: .init())
        try await settle()
        try check(sheets.requests == before, "Home by itself never presents a draft, which is why the host opens the Snap page")
        snap.draft = nil
    }

    /// Lets the main run loop, where SwiftUI updates, run until `done` or the deadline.
    private static func settle(for seconds: TimeInterval = 0.6, until done: () -> Bool = { false }) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    /// A small synthetic screen with a heading and a line of small text.
    static func syntheticScreen() throws -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 640, height: 400).fill()
        ("Synthetic release notes" as NSString).draw(at: NSPoint(x: 32, y: 330), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 28)])
        ("Build 20260928 · 21 checks passed" as NSString).draw(at: NSPoint(x: 32, y: 290), withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw VoiceError.message("Could not draw a synthetic screen.") }
        return png
    }
}

/// Answers each capture with a fixed result and records the modes asked for.
@MainActor
private final class SyntheticImageSource: SnapImageSource {
    let next: Result<Data?, Error>
    private(set) var requests: [SnapCapture.Mode] = []
    init(next: Result<Data?, Error>) { self.next = next }
    func capture(_ mode: SnapCapture.Mode) async throws -> Data? { requests.append(mode); return try next.get() }
    func cancel() {}
}

private final class FixedScreenshotLocation: ScreenshotLocationStore { var location: String? }

/// Records what the host asks of the window and the apps, and plays it out on
/// a page name and a window flag, as AppDelegate's window and navigation would.
@MainActor
private final class RecordingDesktop: SnapCaptureDesktop {
    var page: String
    var windowOnScreen: Bool
    var inFront: pid_t?
    let lastOther: pid_t?
    var log: [String] = []
    init(page: String, windowOnScreen: Bool, inFront: pid_t?, lastOther: pid_t?) {
        self.page = page; self.windowOnScreen = windowOnScreen; self.inFront = inFront; self.lastOther = lastOther
    }
    var appInFront: pid_t? { inFront }
    var lastOtherApp: pid_t? { lastOther }
    func hideWindow() { log.append("hide"); windowOnScreen = false }
    func showWindow(activatingWorkbench: Bool) {
        log.append(activatingWorkbench ? "show and activate Workbench" : "show"); windowOnScreen = true
        if activatingWorkbench { inFront = nil }
    }
    func openSnapPage() { log.append("open snap"); page = "snap"; windowOnScreen = true; inFront = nil }
    func activate(_ app: pid_t) { log.append("activate \(app)"); inFront = app }
}

@MainActor
private final class CheckRoute: ObservableObject { @Published var page = "home" }

/// The window side of the host for the exposure check: a real window, ordered
/// in and out off every display, and a page route like WorkbenchHome's.
@MainActor
private final class WindowDesktop: SnapCaptureDesktop {
    let window: NSWindow
    let route: CheckRoute
    /// Like a minimised window, it comes back on a later turn, after the draft opened.
    let returnsLater: Bool
    init(window: NSWindow, route: CheckRoute, returnsLater: Bool) { self.window = window; self.route = route; self.returnsLater = returnsLater }
    var windowOnScreen: Bool { window.isVisible && !window.isMiniaturized }
    var appInFront: pid_t? { nil }
    var lastOtherApp: pid_t? { nil }
    func hideWindow() { window.orderOut(nil) }
    func showWindow(activatingWorkbench: Bool) { window.orderFrontRegardless() }
    /// In the order AppDelegate.navigate uses: the page, then the window.
    func openSnapPage() {
        route.page = "snap"
        guard returnsLater else { window.orderFrontRegardless(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [window] in
            window.orderFrontRegardless()
            NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        }
    }
    func activate(_ app: pid_t) {}
}

/// WorkbenchHome's page switch, reduced to Home and the real Snap page.
private struct ExposureFixture: View {
    @ObservedObject var route: CheckRoute
    let snap: SnapModel
    var body: some View {
        if route.page == "snap" { SnapWorkspaceView(model: snap, selectedIDs: .constant([])) }
        else { Text("Home").frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
}

/// AppKit moves a titled window onto a display when it is ordered in; this one stays where it is put.
private final class OffscreenCheckWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// While started, a sheet request to any window is counted and recorded as
/// attached, and ending it removes the record. The window's sheet, the
/// sheet's parent and its sheet flag read from that record, so SwiftUI and the
/// Snap page see an attached sheet while none can appear on a display. The
/// original methods return on stop.
@MainActor
private final class SheetRequests {
    private(set) var requests = 0
    private var sheets: [ObjectIdentifier: NSWindow] = [:]
    private var parents: [ObjectIdentifier: NSWindow] = [:]
    private var saved: [(Method, IMP)] = []
    private func replace(_ name: String, with block: Any) -> IMP? {
        guard let method = class_getInstanceMethod(NSWindow.self, NSSelectorFromString(name)) else { return nil }
        let original = method_setImplementation(method, imp_implementationWithBlock(block))
        saved.append((method, original))
        return original
    }
    private func attach(_ sheet: NSWindow, to parent: NSWindow) {
        requests += 1; sheets[ObjectIdentifier(parent)] = sheet; parents[ObjectIdentifier(sheet)] = parent
    }
    private func end(_ sheet: NSWindow?, on parent: NSWindow) {
        if let recorded = sheets.removeValue(forKey: ObjectIdentifier(parent)) { parents.removeValue(forKey: ObjectIdentifier(recorded)) }
        if let sheet { parents.removeValue(forKey: ObjectIdentifier(sheet)) }
    }
    func start() {
        let begin: @convention(block) (NSWindow, NSWindow, Any?) -> Void = { [weak self] parent, sheet, _ in
            MainActor.assumeIsolated { self?.attach(sheet, to: parent) }
        }
        _ = replace("beginSheet:completionHandler:", with: begin)
        _ = replace("beginCriticalSheet:completionHandler:", with: begin)
        let end: @convention(block) (NSWindow, NSWindow) -> Void = { [weak self] parent, sheet in
            MainActor.assumeIsolated { self?.end(sheet, on: parent) }
        }
        _ = replace("endSheet:", with: end)
        let endReturning: @convention(block) (NSWindow, NSWindow, Int) -> Void = { [weak self] parent, sheet, _ in
            MainActor.assumeIsolated { self?.end(sheet, on: parent) }
        }
        _ = replace("endSheet:returnCode:", with: endReturning)
        typealias WindowGetter = @convention(c) (NSWindow, Selector) -> NSWindow?
        typealias ListGetter = @convention(c) (NSWindow, Selector) -> NSArray
        typealias FlagGetter = @convention(c) (NSWindow, Selector) -> Bool
        var attachedSheet: WindowGetter?, sheetParent: WindowGetter?, sheetList: ListGetter?, isSheet: FlagGetter?
        let readSheet: @convention(block) (NSWindow) -> NSWindow? = { [weak self] window in
            MainActor.assumeIsolated { self?.sheets[ObjectIdentifier(window)] } ?? attachedSheet?(window, NSSelectorFromString("attachedSheet"))
        }
        let readParent: @convention(block) (NSWindow) -> NSWindow? = { [weak self] window in
            MainActor.assumeIsolated { self?.parents[ObjectIdentifier(window)] } ?? sheetParent?(window, NSSelectorFromString("sheetParent"))
        }
        let readList: @convention(block) (NSWindow) -> NSArray = { [weak self] window in
            if let sheet = MainActor.assumeIsolated({ self?.sheets[ObjectIdentifier(window)] }) { return [sheet] as NSArray }
            return sheetList?(window, NSSelectorFromString("sheets")) ?? []
        }
        let readFlag: @convention(block) (NSWindow) -> Bool = { [weak self] window in
            MainActor.assumeIsolated { self?.parents[ObjectIdentifier(window)] != nil } || (isSheet?(window, NSSelectorFromString("isSheet")) ?? false)
        }
        attachedSheet = replace("attachedSheet", with: readSheet).map { unsafeBitCast($0, to: WindowGetter.self) }
        sheetParent = replace("sheetParent", with: readParent).map { unsafeBitCast($0, to: WindowGetter.self) }
        sheetList = replace("sheets", with: readList).map { unsafeBitCast($0, to: ListGetter.self) }
        isSheet = replace("isSheet", with: readFlag).map { unsafeBitCast($0, to: FlagGetter.self) }
    }
    func stop() {
        for (method, original) in saved.reversed() { method_setImplementation(method, original) }
        saved.removeAll(); sheets.removeAll(); parents.removeAll()
    }
}
