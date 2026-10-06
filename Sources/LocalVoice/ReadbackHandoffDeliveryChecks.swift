import AppKit
import Foundation

/// Exercise the production action with delayed platform callbacks. Never opens
/// an app, reveals files, requests permissions or writes the general clipboard.
enum ReadbackHandoffDeliveryChecks {
    @MainActor static func run() async throws -> Int {
        var passed = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw VoiceError.message("HANDOFF_DELIVERY_CHECK_FAILED: " + message) }
            passed += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench-handoff-delivery-" + UUID().uuidString).resolvingSymlinksInPath()
        let suite = root.path + "/preferences"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        func session(_ name: String) throws -> URL {
            let folder = root.appendingPathComponent(name)
            var manifest = try ReadbackStore.create(at: folder, title: name)
            let id = UUID(), directory = "items/" + id.uuidString.lowercased()
            try ReadbackStore.createPrivateDirectory(folder.appendingPathComponent(directory))
            let screen = directory + "/screen.png"
            try ReadbackStore.writePrivate(Data("synthetic image".utf8), to: folder.appendingPathComponent(screen))
            manifest.sections = [ReadbackSection(id: id, capturedAt: .distantPast, displayName: "Synthetic", directory: directory,
                screenshot: screen, audio: nil, originalTranscript: nil, transcript: nil, status: .ready, failure: nil, deletedAt: nil)]
            try ReadbackStore.save(manifest, at: folder)
            return folder
        }
        let first = try session("first"), second = try session("second")
        defaults.set([first.path], forKey: "readback.recentSessionPaths.v1")
        let model = ReadbackModel(engine: RecognitionEngine(store: RecognitionConfigurationStore(defaults: defaults)), defaults: defaults,
            skillPacks: ReadbackSkillPackStore(root: root.appendingPathComponent("packs")),
            screenAccess: .fixed(false), microphoneAccess: { .denied })
        defer { model.shutdown() }
        var copied: [String] = [], revealed: [URL] = [], launches: [ReadbackHandoffApplication] = [], callbacks: [(Error?) -> Void] = []
        let fallback = ReadbackHandoffApplication(url: root.appendingPathComponent("Actual fallback.app"))
        let primary = ReadbackHandoffApplication(url: root.appendingPathComponent("New receiver.app"))
        model.handoffCopy = { copied.append($0); return true }
        model.handoffReveal = { revealed.append($0) }
        model.handoffResolve = { $0 == .codex ? fallback : primary }
        model.handoffOpen = { launches.append($0); callbacks.append($1) }
        let failure = NSError(domain: "Synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic launch failure"])
        func drain() async { for _ in 0..<10 { await Task.yield() } }
        model.handOff(to: .codex)
        model.handOff(to: .claude)
        try check(!model.permissionsReady && !model.isRecording && !model.isCapturing, "manual handoff remains usable with both capture permissions off")
        try check(copied.count == 2 && copied.allSatisfy { $0.contains(first.path) } && revealed.map(\.path) == [first.path, first.path], "each attempt copies and reveals its own complete session")
        try check(copied.allSatisfy { $0.contains("under this session's `outputs/`") && $0.contains("only after I choose it") },
                  "production handoff copies the new neutral contract for the actual session")
        try check(launches.map(\.title) == [fallback.title, primary.title], "launches preserve the actual resolved app")
        callbacks[1](nil); await drain()
        try check(model.notice == primary.openedNotice, "the newer successful callback names its actual receiver")
        callbacks[0](failure); await drain()
        try check(model.notice == primary.openedNotice, "an older failure cannot replace the newer success")
        model.handOff(to: .codex); model.handOff(to: .claude)
        callbacks[3](failure); await drain()
        callbacks[2](nil); await drain()
        try check(model.notice == primary.failureNotice(failure), "an older success cannot erase the newer failure")
        model.handOff(to: .codex)
        model.closeSession(); callbacks[4](failure); await drain()
        try check(model.sessionURL == nil && model.notice == nil, "closing invalidates outstanding launch feedback")
        model.openRecent(first); await drain()
        model.handOff(to: .codex)
        model.openRecent(second); await drain()
        let replacementNotice = model.notice
        callbacks[5](failure); await drain()
        try check(model.sessionURL?.path == second.path && model.notice == replacementNotice, "replacing the open session invalidates outstanding launch feedback")
        model.handOff(to: .codex)
        model.notice = "A newer action needs attention."
        callbacks[6](failure); await drain()
        try check(model.notice == "A newer action needs attention.", "a newer notice is not replaced by an old launch callback")
        model.handoffCopy = { _ in false }
        model.handOff(to: .claude)
        try check(launches.count == 7 && model.notice?.contains("could not be copied") == true, "clipboard failure never launches or claims delivery")
        model.handoffCopy = { _ in true }; model.handoffResolve = { _ in nil }
        model.handOff(to: .claude)
        try check(launches.count == 7 && model.notice?.contains("Open Claude") == true && model.notice?.contains("Nothing was uploaded") == true,
                  "an absent host leaves the copied prompt and an honest manual next step")
        return passed
    }
}
