import AppKit

/// "Set up automatic paste…" always leads somewhere visible (#165). macOS shows
/// its Accessibility request once per app. The first click asks for it and
/// waits briefly: if Workbench keeps focus the whole time, no request came
/// forward (this Mac already showed one), so System Settings opens instead.
/// A first click while Workbench is not in front, and every later click, opens
/// Privacy & Security › Accessibility at once, after asking again so a list
/// cleared by a reset gets Workbench back. Workbench never grants, resets or
/// bypasses the approval. Home's Screen Recording row takes the same route
/// through Snap's request (`screenRecording`).
@MainActor
struct AccessibilitySetup {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    /// How long a first request has to come forward before Settings opens.
    static let requestWait: TimeInterval = 1.5
    enum Step: Equatable { case approved, askedMacOS, openedSettings, settingsUnavailable }

    /// Asks macOS for approval. It shows its request only when it has not
    /// already, and it lists Workbench again if a reset removed it. Returns
    /// whether Workbench is already approved.
    var request: () -> Bool
    var isTrusted: () -> Bool
    var openSettings: (URL) -> Bool
    var isFrontmost: () -> Bool
    /// Calls back if Workbench gives up focus, until the returned stop is called.
    var watchResign: (@escaping () -> Void) -> () -> Void
    var after: (TimeInterval, @escaping () -> Void) -> Void
    /// The list Settings opens at.
    var settings: URL = AccessibilitySetup.settingsURL

    static var live: AccessibilitySetup {
        AccessibilitySetup(
            request: {
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            },
            isTrusted: { AXIsProcessTrusted() },
            openSettings: { NSWorkspace.shared.open($0) },
            isFrontmost: { NSApp.isActive },
            watchResign: { resigned in
                let watcher = ResignWatcher(resigned)
                return { watcher.stop() }
            },
            after: { delay, work in
                Task { @MainActor in try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)); work() }
            })
    }
    /// Screen Recording: macOS also shows its request once per app, and a running app keeps it
    /// off until it reopens. The request records that Workbench asked (`ScreenCaptureAccess`).
    static var screenRecording: AccessibilitySetup {
        var setup = live
        setup.request = { ScreenCaptureAccess.system.request() }
        setup.isTrusted = { ScreenCaptureAccess.system.isGranted() }
        setup.settings = ScreenCaptureAccess.settingsURL
        return setup
    }

    /// `asked` is the saved record that Workbench has already asked macOS.
    /// `unavailable` reports a Settings pane that could not be opened.
    func run(asked: inout Bool?, unavailable: @escaping () -> Void = {}) -> Step {
        let firstTime = asked != true
        asked = true
        if request() { return .approved }
        if firstTime && isFrontmost() {
            // A request that comes forward takes focus, even if it is declined at once.
            var resigned = false
            let stop = watchResign { resigned = true }
            after(Self.requestWait) {
                stop()
                guard !resigned, !isTrusted() else { return }
                if !openSettings(settings) { unavailable() }
            }
            return .askedMacOS
        }
        if openSettings(settings) { return .openedSettings }
        unavailable()
        return .settingsUnavailable
    }
}

/// Watches for Workbench giving up focus while a first request may show.
private final class ResignWatcher: NSObject {
    private let resigned: () -> Void
    init(_ resigned: @escaping () -> Void) {
        self.resigned = resigned
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(resign), name: NSApplication.didResignActiveNotification, object: nil)
    }
    @objc private func resign() { resigned() }
    func stop() { NotificationCenter.default.removeObserver(self) }
}

/// The setup route with injected effects: no real request, Settings or TCC.
@MainActor
enum AccessibilitySetupChecks {
    static func run() throws {
        var passed = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("ACCESSIBILITY SETUP CHECK FAILED: " + name) }
            passed += 1
        }
        var requests = 0, opened: [URL] = [], trusted = false, frontmost = true, settingsOpen = true
        var scheduled: [() -> Void] = [], unavailable = 0, watching: [() -> Void] = [], stopped = 0
        let setup = AccessibilitySetup(request: { requests += 1; return trusted }, isTrusted: { trusted },
                                       openSettings: { opened.append($0); return settingsOpen }, isFrontmost: { frontmost },
                                       watchResign: { resigned in watching.append(resigned); return { stopped += 1 } },
                                       after: { _, work in scheduled.append(work) })
        func wait() { let work = scheduled; scheduled = []; work.forEach { $0() } }
        func resign() { watching.forEach { $0() } }
        func click(_ asked: inout Bool?) -> AccessibilitySetup.Step { setup.run(asked: &asked, unavailable: { unavailable += 1 }) }

        var asked: Bool? = nil
        try check(click(&asked) == .askedMacOS && requests == 1 && opened.isEmpty && asked == true,
                  "the first click asks macOS once and records that it asked")
        resign(); frontmost = true; wait()
        try check(opened.isEmpty && stopped == 1,
                  "a request that took focus, even one declined within the wait, leaves Settings closed")

        asked = nil; requests = 0; watching = []
        _ = click(&asked); wait()
        try check(requests == 1 && opened == [AccessibilitySetup.settingsURL],
                  "when Workbench keeps focus, because this Mac already showed its request, Settings opens instead")

        asked = nil; requests = 0; opened = []; watching = []; frontmost = false
        try check(click(&asked) == .openedSettings && requests == 1 && opened == [AccessibilitySetup.settingsURL] && scheduled.isEmpty,
                  "a first click while Workbench is not in front opens Settings at once")

        requests = 0; opened = []; frontmost = true
        try check(click(&asked) == .openedSettings && requests == 1 && opened == [AccessibilitySetup.settingsURL] && scheduled.isEmpty,
                  "a later click asks again, so a reset list gets Workbench back, then opens Settings")
        _ = click(&asked)
        try check(opened.count == 2 && requests == 2, "repeated clicks keep opening Settings; none is a dead end")

        asked = nil; opened = []; requests = 0; trusted = true
        try check(click(&asked) == .approved && opened.isEmpty && scheduled.isEmpty, "an already approved Mac needs no Settings")

        trusted = false; settingsOpen = false; opened = []
        try check(click(&asked) == .settingsUnavailable && unavailable == 1, "a Settings pane that cannot open is reported, not silent")

        // Home's Screen Recording row takes the same route to its own list.
        var screen = setup; screen.settings = ScreenCaptureAccess.settingsURL
        settingsOpen = true; opened = []; requests = 0; scheduled = []; watching = []; frontmost = true
        var screenAsked: Bool? = nil
        try check(screen.run(asked: &screenAsked) == .askedMacOS && requests == 1 && opened.isEmpty,
                  "Screen Recording's first Set up… asks macOS and waits")
        resign(); wait()
        try check(opened.isEmpty, "a Screen Recording request that took focus, even one declined at once, leaves Settings closed")
        try check(screen.run(asked: &screenAsked) == .openedSettings && opened == [ScreenCaptureAccess.settingsURL] && requests == 2,
                  "a later Screen Recording press asks again, so a cleared list can show Workbench, then opens its own list")

        // The saved record survives a reload, and older preferences without it still load.
        var preferences = VoicePreferences(); preferences.accessibilityRequested = true
        let restored = try JSONDecoder().decode(VoicePreferences.self, from: JSONEncoder().encode(preferences))
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(VoicePreferences())) as! [String: Any]
        legacy.removeValue(forKey: "accessibilityRequested")
        let older = try JSONDecoder().decode(VoicePreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        try check(restored.accessibilityRequested == true && older.accessibilityRequested == nil && older.delivery == .paste,
                  "the record reloads, and preferences saved before it still load unchanged")
        print("ACCESSIBILITY_SETUP_CHECKS_OK: \(passed) checks; injected request, Settings and timing only")
    }
}
