import AppKit
import Carbon

/// A test throws this when the Mac it runs on cannot meet a precondition. The runner
/// reports it as SKIP with the reason and leaves it out of the count, as it does for
/// optional renders; it is never a pass and never a failure.
struct TestSkipped: Error, CustomStringConvertible {
    let reason: String
    var description: String { reason }
}

/// Global shortcuts are exclusive: the first process to register ⌥D keeps it until it
/// quits. On a Mac where an installed Workbench is running, that process is the app, so
/// a test that needs the default shortcuts registered to this process cannot run here.
/// CI has no running edition, so the same tests run there in full.
enum ExclusiveShortcuts {
    static let editionIdentifiers: Set<String> = [
        "com.ethdawg.workbench", "com.ethdawg.workbench.preview",
        "com.ethdawg.localvoice", "com.ethdawg.localvoice.preview",
        "local.ethan.StageMark", "local.ethan.StageMark.preview"
    ]

    /// Why the default shortcuts cannot be registered by this process, or nil when every one can.
    static func holdingProblem() -> String? {
        let manager = HotkeyManager()
        manager.register(Preferences())
        defer { manager.unregister() }
        let taken = "code \(eventHotKeyExistsErr)"
        let held = Action.allCases.filter { manager.failures[$0]?.contains(taken) == true }
        guard !held.isEmpty else { return nil }
        let keys = held.map { Preferences().shortcut(for: $0).label }.joined(separator: " ")
        let editions = NSWorkspace.shared.runningApplications
            .filter { editionIdentifiers.contains($0.bundleIdentifier ?? "") }
            .map { "\($0.localizedName ?? $0.bundleIdentifier ?? "Workbench") (pid \($0.processIdentifier))" }
        let holder = editions.isEmpty ? "another process" : editions.joined(separator: ", ")
        return "\(keys) already registered by \(holder); quit it to check exclusive shortcuts on this Mac. CI checks them."
    }
}
