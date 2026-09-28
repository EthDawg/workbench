import AppKit

/// "Set up automatic paste…" always leads somewhere visible (#165). macOS shows
/// its Accessibility request once per app, so only the first click asks for it.
/// If no request comes forward, because this Mac already showed one, System
/// Settings opens instead, and every later click opens Privacy & Security ›
/// Accessibility directly. Workbench never grants, resets or bypasses the approval.
@MainActor
struct AccessibilitySetup {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    /// How long a first request has to come forward before Settings opens.
    static let requestWait: TimeInterval = 1.5
    enum Step: Equatable { case approved, askedMacOS, openedSettings, settingsUnavailable }

    /// Asks macOS to show its request; returns whether Workbench is already approved.
    var request: () -> Bool
    var isTrusted: () -> Bool
    var openSettings: (URL) -> Bool
    /// Workbench still in front means no request came forward.
    var isFrontmost: () -> Bool
    var after: (TimeInterval, @escaping () -> Void) -> Void

    static var live: AccessibilitySetup {
        AccessibilitySetup(
            request: {
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            },
            isTrusted: { AXIsProcessTrusted() },
            openSettings: { NSWorkspace.shared.open($0) },
            isFrontmost: { NSApp.isActive },
            after: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) })
    }

    /// `asked` is the saved record that Workbench has already asked macOS.
    /// `unavailable` reports a Settings pane that could not be opened.
    func run(asked: inout Bool?, unavailable: @escaping () -> Void = {}) -> Step {
        guard asked == true else {
            asked = true
            if request() { return .approved }
            after(Self.requestWait) {
                guard !isTrusted(), isFrontmost() else { return }
                if !openSettings(Self.settingsURL) { unavailable() }
            }
            return .askedMacOS
        }
        if openSettings(Self.settingsURL) { return .openedSettings }
        unavailable()
        return .settingsUnavailable
    }
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
        var scheduled: [() -> Void] = [], unavailable = 0
        let setup = AccessibilitySetup(request: { requests += 1; return trusted }, isTrusted: { trusted },
                                       openSettings: { opened.append($0); return settingsOpen }, isFrontmost: { frontmost },
                                       after: { _, work in scheduled.append(work) })
        func runScheduled() { let work = scheduled; scheduled = []; work.forEach { $0() } }

        var asked: Bool? = nil
        try check(setup.run(asked: &asked, unavailable: { unavailable += 1 }) == .askedMacOS && requests == 1 && opened.isEmpty
                  && asked == true, "the first click asks macOS once and records that it asked")
        frontmost = false; runScheduled()
        try check(opened.isEmpty, "when macOS's request comes forward, Settings stays closed")

        asked = nil; requests = 0; frontmost = true
        _ = setup.run(asked: &asked, unavailable: { unavailable += 1 })
        runScheduled()
        try check(requests == 1 && opened == [AccessibilitySetup.settingsURL],
                  "when no request comes forward, because this Mac already showed one, Settings opens instead")

        opened = []; requests = 0
        try check(setup.run(asked: &asked, unavailable: { unavailable += 1 }) == .openedSettings && requests == 0
                  && opened == [AccessibilitySetup.settingsURL] && scheduled.isEmpty,
                  "every later click opens Privacy & Security › Accessibility without asking again")
        _ = setup.run(asked: &asked, unavailable: { unavailable += 1 })
        try check(opened.count == 2 && requests == 0, "repeated clicks keep opening Settings; none is a dead end")

        asked = nil; opened = []; requests = 0; trusted = true
        try check(setup.run(asked: &asked, unavailable: { unavailable += 1 }) == .approved && opened.isEmpty && scheduled.isEmpty,
                  "an already approved Mac needs no Settings")

        trusted = false; settingsOpen = false; opened = []
        try check(setup.run(asked: &asked, unavailable: { unavailable += 1 }) == .settingsUnavailable && unavailable == 1,
                  "a Settings pane that cannot open is reported, not silent")

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
