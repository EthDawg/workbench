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
/// check window is never on a display. A watchdog on its own thread ends the
/// process if any step stops making progress for two minutes. It names the
/// step, logs every thread's stack and aborts, so a hang fails in CI instead of
/// holding the job (#181). It stays armed while the process exits, so this
/// check runs in a process of its own.
@MainActor
enum SnapCaptureChecks {
    static func run() async throws {
        let started = Date(), priority = Task.currentPriority.checkName
        let watchdog = CheckWatchdog("SNAP_CAPTURE_CHECK_FAILED", limit: 120, context: "check task at \(priority) priority")
        var count = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("SNAP_CAPTURE_CHECK_FAILED: " + name) }
            count += 1
            watchdog.passed(name)
        }
        watchdog.step("launching AppKit without a Dock icon")
        // As the surface gallery does, which renders windows reliably on the CI runners.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        watchdog.step("preparing the synthetic store")
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
            let snap = SnapModel(store: SnapStore(root: root.appendingPathComponent(name, isDirectory: true)), desktop: root.appendingPathComponent("Desktop"),
                                 screenshotLocation: FixedScreenshotLocation(), preferences: preferences, screenshotInbox: root.appendingPathComponent("Inbox"),
                                 trash: { _ in throw SnapError.message("This check never moves a file to the Trash.") },
                                 applyScreenshotLocation: {}, imageSource: source, pasteboard: pasteboard)
            // Search is not what this check tests: saved Snaps get empty search data, never Vision (#181).
            snap.analyzeImage = { _, digest in SnapDerivedData(imageSHA256: digest, text: "", featurePrint: nil) }
            return snap
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
                watchdog.step("\(journey): capture")
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
                watchdog.step("\(journey): " + ["Save & Copy", "Save", "Cancel"][resolution % 3])
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
                watchdog.step("\(journey): the next capture")
                await snap.capture(mode)
                try check(snap.draft != nil && source.requests == [mode, mode] && snap.items.count == saved,
                          "\(journey): another capture opens after the draft closes, with no hidden or duplicate item")
                resolution += 1
            }
        }

        // Escape in the selector adds nothing, shows no Workbench window it did not
        // show before, and returns to the app you were in.
        // `origin` is what the door knows: the panel passes the app its visit was opened over.
        let cancels: [(name: String, windowOnScreen: Bool, inFront: pid_t?, lastOther: pid_t?, origin: pid_t?, expected: [String])] = [
            ("from the panel with the window closed", false, nil, safari, nil, ["close controls", "activate \(safari)"]),
            ("from the panel over another app, window behind it", true, nil, mail, safari, ["hide", "close controls", "show", "activate \(safari)"]),
            ("from the toolbar over another app, window behind it", true, safari, mail, nil, ["hide", "close controls", "show", "activate \(safari)"]),
            ("from the Snap page", true, nil, safari, nil, ["hide", "close controls", "show and activate Workbench"]),
            ("from the shortcut with the window minimised", false, mail, safari, nil, ["close controls", "activate \(mail)"])]
        for (index, cancel) in cancels.enumerated() {
            let snap = snapModel("cancel-\(index)", source: SyntheticImageSource(next: .success(nil)))
            let desktop = RecordingDesktop(page: "history", windowOnScreen: cancel.windowOnScreen, inFront: cancel.inFront, lastOther: cancel.lastOther)
            SnapCaptureHost(desktop: desktop).attach(to: snap) { desktop.log.append("close controls") }
            watchdog.step("a cancelled selector \(cancel.name)")
            await snap.capture(.region, origin: cancel.origin)
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
            watchdog.step("an acquisition problem")
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
            watchdog.step("a draft left in a hidden editor")
            await snap.capture(.screen)
            let first = snap.draft?.id
            try check(snap.isBusy && !snap.disablesCaptureDoors,
                      "a pending draft keeps the capture doors open, so they can bring its editor back")
            desktop.windowOnScreen = false; desktop.inFront = mail; desktop.log.removeAll()
            await snap.capture(.region)
            try check(first != nil && snap.draft?.id == first && source.requests == [.screen] && desktop.log == ["open snap"]
                      && snap.notice == "Finish or cancel the current Snap first.", "a hidden draft is brought back instead of blocking a new capture")
            snap.draft = nil
            await snap.capture(.region)
            try check(snap.draft != nil && snap.draft?.id != first && source.requests == [.screen, .region], "cancelling it lets the next capture start")
        }

        try await checkEditorExposure(makeSnap: { snapModel($0, source: SyntheticImageSource(next: .success(image))) }, watchdog: watchdog, check: check)
        print("SNAP_CAPTURE_CHECKS_OK: \(count) checks for every door's editor, Save & Copy, cancelled selectors, problems and hidden drafts, in "
              + String(format: "%.1f s", Date().timeIntervalSince(started)) + " at \(priority) priority")
        // Written now, so a slow exit cannot hide the result; the watchdog still covers the exit.
        fflush(stdout)
        watchdog.expectExit(within: 30)
    }

    /// The Snap page the host opens presents the editor for the captured draft,
    /// while Home, where the capture began, does not. SwiftUI asks the window for
    /// a sheet only while the window is visible, so each check window is ordered
    /// in far off every display, and sheets are recorded as attached instead of
    /// shown. A window restored from the Dock returns on a later turn, after the
    /// draft opened, and the editor must still appear then.
    private static func checkEditorExposure(makeSnap: (String) -> SnapModel, watchdog: CheckWatchdog,
                                            check: (Bool, String) throws -> Void) async throws {
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
        /// Closes a check window only once no sheet is recorded on it.
        func close(_ window: NSWindow) {
            sheets.forget(window)
            window.contentViewController = nil; window.close()
        }
        for (index, journey) in journeys.enumerated() {
            let name = "the editor for a capture \(journey.name)"
            watchdog.step("\(name): opening the check window")
            let snap = makeSnap("exposure-\(index)")
            let (window, route) = fixture(snap, page: journey.page)
            defer { watchdog.step("\(name): closing the check window"); close(window) }
            if journey.onScreen { window.orderFrontRegardless() }
            try await settle(for: 0.3)
            let before = sheets.requests
            try check(!sheets.isAttached(to: window) && window.frame.minX < -20_000, "the check window starts \(journey.name) off every display, with no sheet")
            let host = SnapCaptureHost(desktop: WindowDesktop(window: window, route: route, returnsLater: journey.returnsLater))
            host.attach(to: snap) {}
            watchdog.step("\(name): capture")
            await snap.capture(.region)
            watchdog.step("\(name): waiting for the editor")
            try await settle(for: 5) { sheets.requests > before }
            // Long enough for a second presentation to show up.
            try await settle(for: 0.3)
            try check(route.page == "snap" && snap.draft != nil && window.isVisible && sheets.requests == before + 1 && sheets.isAttached(to: window),
                      "a capture \(journey.name) opens the Snap page, which presents the editor once")
            try check(window.frame.minX < -20_000, "the check window stayed off every display")
            watchdog.step("\(name): cancelling the editor")
            snap.draft = nil
            try await settle(for: 3) { !sheets.isAttached(to: window) }
            try check(!sheets.isAttached(to: window), "cancelling the editor \(journey.name) ends its sheet")
        }
        // The fixture's own control: a draft while Home shows is never presented.
        watchdog.step("the control: a draft while Home shows")
        let snap = makeSnap("exposure-control")
        let (window, _) = fixture(snap, page: "home")
        defer { watchdog.step("the control: closing the check window"); close(window) }
        window.orderFrontRegardless()
        try await settle(for: 0.3)
        let before = sheets.requests
        snap.draft = SnapDraft(originalPNG: try syntheticScreen(), source: .clipboard, title: "Fixture control", notes: "", tags: [], edit: .init())
        try await settle(for: 0.6)
        try check(sheets.requests == before, "Home by itself never presents a draft, which is why the host opens the Snap page")
        snap.draft = nil
    }

    /// Lets the main run loop, where SwiftUI updates, run until `done` or the deadline.
    private static func settle(for seconds: TimeInterval, until done: () -> Bool = { false }) async throws {
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
    /// Nothing is on screen to wait for.
    let settleDelay: UInt64 = 0
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
/// records are locked and answer only on the main thread; AppKit asking from any
/// other thread gets its own answer. The original methods return on stop.
private final class SheetRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var sheets: [ObjectIdentifier: NSWindow] = [:]
    private var parents: [ObjectIdentifier: NSWindow] = [:]
    private var saved: [(Method, IMP)] = []

    var requests: Int { lock.withLock { count } }
    func isAttached(to window: NSWindow) -> Bool { lock.withLock { sheets[ObjectIdentifier(window)] != nil } }
    /// Drops any record on `window`, so closing it never meets a recorded sheet.
    func forget(_ window: NSWindow) { end(nil, on: window) }

    private func attach(_ sheet: NSWindow, to parent: NSWindow) {
        lock.withLock { count += 1; sheets[ObjectIdentifier(parent)] = sheet; parents[ObjectIdentifier(sheet)] = parent }
    }
    private func end(_ sheet: NSWindow?, on parent: NSWindow) {
        lock.withLock {
            if let recorded = sheets.removeValue(forKey: ObjectIdentifier(parent)) { parents.removeValue(forKey: ObjectIdentifier(recorded)) }
            if let sheet { parents.removeValue(forKey: ObjectIdentifier(sheet)) }
        }
    }
    private func sheet(on window: NSWindow) -> NSWindow? { lock.withLock { sheets[ObjectIdentifier(window)] } }
    private func parent(of window: NSWindow) -> NSWindow? { lock.withLock { parents[ObjectIdentifier(window)] } }

    private func replace(_ name: String, with block: Any) -> IMP? {
        guard let method = class_getInstanceMethod(NSWindow.self, NSSelectorFromString(name)) else { return nil }
        let original = method_setImplementation(method, imp_implementationWithBlock(block))
        saved.append((method, original))
        return original
    }
    func start() {
        let begin: @convention(block) (NSWindow, NSWindow, Any?) -> Void = { [weak self] parent, sheet, _ in self?.attach(sheet, to: parent) }
        _ = replace("beginSheet:completionHandler:", with: begin)
        _ = replace("beginCriticalSheet:completionHandler:", with: begin)
        let end: @convention(block) (NSWindow, NSWindow) -> Void = { [weak self] parent, sheet in self?.end(sheet, on: parent) }
        _ = replace("endSheet:", with: end)
        let endReturning: @convention(block) (NSWindow, NSWindow, Int) -> Void = { [weak self] parent, sheet, _ in self?.end(sheet, on: parent) }
        _ = replace("endSheet:returnCode:", with: endReturning)
        typealias WindowGetter = @convention(c) (NSWindow, Selector) -> NSWindow?
        typealias ListGetter = @convention(c) (NSWindow, Selector) -> NSArray
        typealias FlagGetter = @convention(c) (NSWindow, Selector) -> Bool
        var attachedSheet: WindowGetter?, sheetParent: WindowGetter?, sheetList: ListGetter?, isSheet: FlagGetter?
        // Only the main thread, where SwiftUI and the check ask, sees the records.
        // Any other thread gets AppKit's own answer.
        let readSheet: @convention(block) (NSWindow) -> NSWindow? = { [weak self] window in
            (Thread.isMainThread ? self?.sheet(on: window) : nil) ?? attachedSheet?(window, NSSelectorFromString("attachedSheet"))
        }
        let readParent: @convention(block) (NSWindow) -> NSWindow? = { [weak self] window in
            (Thread.isMainThread ? self?.parent(of: window) : nil) ?? sheetParent?(window, NSSelectorFromString("sheetParent"))
        }
        let readList: @convention(block) (NSWindow) -> NSArray = { [weak self] window in
            if Thread.isMainThread, let sheet = self?.sheet(on: window) { return [sheet] as NSArray }
            return sheetList?(window, NSSelectorFromString("sheets")) ?? []
        }
        let readFlag: @convention(block) (NSWindow) -> Bool = { [weak self] window in
            (Thread.isMainThread && self?.parent(of: window) != nil) || (isSheet?(window, NSSelectorFromString("isSheet")) ?? false)
        }
        attachedSheet = replace("attachedSheet", with: readSheet).map { unsafeBitCast($0, to: WindowGetter.self) }
        sheetParent = replace("sheetParent", with: readParent).map { unsafeBitCast($0, to: WindowGetter.self) }
        sheetList = replace("sheets", with: readList).map { unsafeBitCast($0, to: ListGetter.self) }
        isSheet = replace("isSheet", with: readFlag).map { unsafeBitCast($0, to: FlagGetter.self) }
    }
    func stop() {
        for (method, original) in saved.reversed() { method_setImplementation(method, original) }
        saved.removeAll()
        lock.withLock { sheets.removeAll(); parents.removeAll() }
    }
}

/// Ends a check that stops making progress, naming the step it stopped in and
/// the last check that passed, so a hang fails in minutes instead of holding
/// CI until its job limit. It waits on a thread of its own, never on the main
/// thread or Swift's shared pool, which a hang may hold. When it fires it
/// writes its message with plain system calls, adds a `sample` of every
/// thread's stack to the log, and aborts, which also leaves a crash report in
/// ~/Library/Logs/DiagnosticReports. It runs no exit handlers a stuck thread could block.
final class CheckWatchdog: @unchecked Sendable {
    private let prefix: String
    private let context: String
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private var limit: TimeInterval
    private var deadline: Date
    private var current = "starting"
    private var lastPassed: String?
    /// Prepared now, so sampling a stuck process needs no Foundation call.
    private let samplePath: [CChar]
    private let sampleArguments: [UnsafeMutablePointer<CChar>?]

    init(_ prefix: String, limit: TimeInterval, context: String) {
        self.prefix = prefix; self.context = context; self.limit = limit
        deadline = Date().addingTimeInterval(limit)
        let path = NSTemporaryDirectory() + "check-watchdog-\(getpid()).sample.txt"
        samplePath = Array(path.utf8CString)
        let arguments: [String] = ["/usr/bin/sample", String(getpid()), "3", "-mayDie", "-file", path]
        sampleArguments = arguments.map { strdup($0) } + [nil]
        let thread = Thread { [self] in watch() }
        thread.name = "\(prefix) watchdog"
        thread.start()
    }

    func step(_ name: String) { lock.withLock { current = name } }
    func passed(_ name: String) { lock.withLock { lastPassed = name } }
    /// After the checks pass: the process must end within `seconds` more.
    func expectExit(within seconds: TimeInterval) {
        lock.withLock { current = "exiting after all checks passed"; limit = seconds; deadline = Date().addingTimeInterval(seconds) }
        changed.signal()
    }

    private func watch() {
        while true {
            let remaining = lock.withLock { deadline.timeIntervalSinceNow }
            if remaining <= 0 { fire() }
            _ = changed.wait(timeout: .now() + remaining)
        }
    }

    private func fire() -> Never {
        let message = lock.withLock {
            "\(prefix): timed out after \(Int(limit)) s during \(current)" + (lastPassed.map { "; last passed: \($0)" } ?? "") + " (\(context))\n"
        }
        Self.writeError(message)
        // Keep what was already printed, unless the stuck thread holds stdout.
        if ftrylockfile(stdout) == 0 { fflush(stdout); funlockfile(stdout) }
        Self.writeError("Every thread's stack follows, from `sample` of this process:\n")
        sampleStacks()
        Self.writeError("\n\(prefix): end of sample. Aborting, which leaves a crash report.\n")
        abort()
    }

    /// Runs `sample` on this process for 3 s, gives it 30 s to finish, then copies its report to stderr.
    private func sampleStacks() {
        var child: pid_t = 0
        let started = sampleArguments.withUnsafeBufferPointer { arguments in
            posix_spawn(&child, "/usr/bin/sample", nil, nil, UnsafeMutablePointer(mutating: arguments.baseAddress), environ)
        }
        guard started == 0 else { Self.writeError("`sample` could not start (error \(started)).\n"); return }
        var status: Int32 = 0, finished = false
        for _ in 0..<300 {
            if waitpid(child, &status, WNOHANG) == child { finished = true; break }
            usleep(100_000)
        }
        if !finished { kill(child, SIGKILL); _ = waitpid(child, &status, 0); Self.writeError("`sample` did not finish in 30 s.\n") }
        let file = samplePath.withUnsafeBufferPointer { open($0.baseAddress!, O_RDONLY) }
        guard file >= 0 else { Self.writeError("The sample report could not be read.\n"); return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(file, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            _ = buffer.withUnsafeBytes { write(STDERR_FILENO, $0.baseAddress, count) }
        }
        close(file)
        _ = samplePath.withUnsafeBufferPointer { unlink($0.baseAddress!) }
    }

    private static func writeError(_ text: String) {
        _ = text.withCString { write(STDERR_FILENO, $0, strlen($0)) }
    }
}

extension TaskPriority {
    /// A plain name for check output, such as "utility" rather than a raw value.
    var checkName: String {
        switch self {
        case .high: "high"
        case .medium: "medium"
        case .low: "utility"
        case .background: "background"
        default: "priority \(rawValue)"
        }
    }
}
