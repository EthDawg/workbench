import Foundation

// Self-contained checks keep a full Xcode installation out of the install path.
enum CoreChecks {
    static func run() throws {
        var passed = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw VoiceError.message("CHECK FAILED: \(name)") }
            passed += 1; print("PASS: \(name)")
        }
        func rejects(_ name: String, _ body: () throws -> Void) throws {
            do { try body() } catch { passed += 1; print("PASS: \(name)"); return }
            throw VoiceError.message("CHECK FAILED: \(name)")
        }
        let wordRules = [Replacement(heard: "cat", written: "CAT"), Replacement(heard: "git hub", written: "GitHub")]
        try check(TextRules.apply("  Cat, concatenate. GIT HUB!  ", replacements: wordRules) == "CAT, concatenate. GitHub!", "whole-word correction and case folding")
        let literals = [Replacement(heard: "a.b", written: "$1\\files"), Replacement(heard: "c++", written: "C++")]
        try check(TextRules.apply("a.b c++ axb", replacements: literals) == "$1\\files C++ axb", "literal regex and replacement characters")
        let unicode = [Replacement(heard: "café", written: "Coffee"), Replacement(heard: "", written: "BAD")]
        try check(TextRules.apply("café, cafés, décafé", replacements: unicode) == "Coffee, cafés, décafé", "Unicode word boundaries and empty rules")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StateStore(directory: directory)
        try check(store.load().history.isEmpty, "first launch with no saved state")
        let original = SavedState(draft: "Draft\nwith a new line", speechText: "Read me.", history: [Transcript(text: "A thought", seconds: 3.25)], replacements: [Replacement(heard: "git hub", written: "GitHub")], voice: "Daniel", rate: 210)
        try store.save(original)
        let restored = try store.load()
        try check(restored.draft == original.draft && restored.speechText == original.speechText, "draft and reading restored")
        try check(restored.history.first?.text == "A thought" && restored.history.first?.seconds == 3.25, "history restored")
        let earlier = Transcript(text: "Same words", seconds: 2, rawText: "Um, same words", cleanupMethod: "Light")
        let later = Transcript(text: "Same words", seconds: 4, rawText: "Same words")
        let captures = TranscriptHistory.adding(later, to: [earlier])
        try check(captures.count == 2 && captures[0].id == later.id && captures[1].id == earlier.id, "repeated words remain distinct captures in newest-first order")
        var many: [Transcript] = []
        for i in 0...TranscriptHistory.limit { many = TranscriptHistory.adding(Transcript(text: "Capture \(i)", seconds: 1), to: many) }
        try check(many.count == TranscriptHistory.limit && many.first?.text == "Capture 100" && many.last?.text == "Capture 1", "bounded history retains the newest 100 captures")
        try store.save(SavedState(draft: "Independently edited draft", history: captures))
        let recovered = try store.load()
        try check(recovered.history.map(\.id) == captures.map(\.id) && recovered.history.last?.rawText == earlier.rawText, "multiple captures and originals survive saving an unrelated draft")
        try check(TranscriptHistory.matching(captures, query: "UM,").map(\.id) == [earlier.id], "search finds original wording without requiring exact case")
        try check(TranscriptHistory.matching(captures, query: " ").count == 2, "clearing history search restores every capture")
        let screen = NSRect(x: 0, y: 30, width: 1440, height: 870)
        let moved = NSPoint(x: 100, y: 320)
        try check(CapturePanelPlacement.origin(saved: moved, screens: [screen], preferred: screen) == moved, "dictation panel preserves a user-chosen visible position")
        let recoveredOrigin = CapturePanelPlacement.origin(saved: NSPoint(x: 5000, y: -900), screens: [screen], preferred: screen)
        try check(screen.contains(NSRect(origin: recoveredOrigin, size: CapturePanelPlacement.size)), "dictation panel recovers onto a connected display")
        try check(restored.replacements == original.replacements && restored.voice == "Daniel" && restored.rate == 210, "dictionary and voice preferences restored")
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o600, "state file private to current user")
        try Data("not json".utf8).write(to: store.url)
        try rejects("damaged state reports an error") { _ = try store.load() }
        try check(String(contentsOf: store.url, encoding: .utf8) == "not json", "damaged state is not silently erased")
        try rejects("empty reading rejected") { _ = try AudioRenderer.render(text: " \n ", voice: "Karen", rate: 180) }
        try rejects("oversized reading rejected") { _ = try AudioRenderer.render(text: String(repeating: "a", count: 50_001), voice: "Karen", rate: 180) }
        try check(TextRules.wordCount(" one\n two\tthree ") == 3, "word count handles mixed whitespace")
        try check(time(65.8) == "1:05" && time(-1) == "0:00", "recording duration formatting")
        print("CORE_CHECKS_OK: \(passed) checks passed")
    }
}

enum AudioRendererCancellationChecks {
    static func run() async throws {
        let task = Task {
            try await AudioRenderer.runCancellable("/bin/sleep", ["30"])
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancellationStarted = Date()
        task.cancel()
        var reportedCancellation = false
        do { try await task.value }
        catch is CancellationError { reportedCancellation = true }
        guard reportedCancellation else { throw VoiceError.message("CHECK FAILED: cancelled renderer reports cancellation") }
        guard Date().timeIntervalSince(cancellationStarted) < 2 else {
            throw VoiceError.message("CHECK FAILED: cancelled renderer terminates its child process promptly")
        }
        try await AudioRenderer.runCancellable("/usr/bin/true", [])
        print("AUDIO_RENDERER_CANCELLATION_OK: child process terminated and a later render can start")
    }
}
