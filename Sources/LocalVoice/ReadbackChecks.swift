import Carbon
import Foundation

enum ReadbackChecks {
    static func run() throws {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw ReadbackError.message("READBACK_CHECK_FAILED: \(message)") }
            passed += 1
        }
        func rejects(_ message: String, _ work: () throws -> Void) throws {
            do { try work() }
            catch { passed += 1; return }
            throw ReadbackError.message("READBACK_CHECK_FAILED: \(message)")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench-readback-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = try ReadbackStore.create(at: root, title: "Synthetic review")
        try check(FileManager.default.fileExists(atPath: root.appendingPathComponent("README.md").path), "new session includes a portable README")
        try check(FileManager.default.fileExists(atPath: root.appendingPathComponent("SKILL.md").path), "new session includes the deck-building skill")
        let rootMode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        let manifestMode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(ReadbackStore.manifestName).path)[.posixPermissions] as? NSNumber
        try check(rootMode?.intValue == 0o700 && manifestMode?.intValue == 0o600, "new session metadata is private to the user")
        let skill = try String(contentsOf: root.appendingPathComponent("SKILL.md"), encoding: .utf8)
        try check(skill.contains("name: build-snap-and-talk-deck") && skill.contains("speaker notes verbatim"), "skill preserves the agreed deck contract")
        try check(skill.contains("template.pptx") && skill.contains("visible title") && skill.contains("supporting copy"), "skill describes the optional template and visible narration-grounded copy")
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        try check(readme.contains("complete edited narration verbatim") && readme.contains("does not upload or submit"), "portable README explains slide copy and local handoff")
        let handoffRoot = root.appendingPathComponent("Folder with spaces", isDirectory: true)
        for target in ReadbackHandoffTarget.allCases {
            let prompt = target.prompt(for: handoffRoot)
            try check(prompt.contains("SKILL.md") && prompt.contains("session.json") && prompt.contains(handoffRoot.path), "\(target.title) handoff identifies the portable session")
            try check(prompt.contains("Keep the original session") && prompt.contains("Keep the work local"), "\(target.title) handoff preserves originals and external-service consent")
        }
        try check(manifest.formatVersion == 1 && manifest.title == "Synthetic review" && manifest.sections.isEmpty, "new manifest is versioned and empty")

        let firstID = UUID(), secondID = UUID()
        let firstDirectory = "items/\(firstID.uuidString.lowercased())"
        let secondDirectory = "items/\(secondID.uuidString.lowercased())"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(firstDirectory), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(secondDirectory), withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: root.appendingPathComponent(firstDirectory + "/screen.png"))
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: root.appendingPathComponent(secondDirectory + "/screen.png"))
        manifest.sections = [
            ReadbackSection(id: firstID, capturedAt: Date(timeIntervalSince1970: 10), displayName: "Display 1", directory: firstDirectory,
                screenshot: firstDirectory + "/screen.png", audio: nil, originalTranscript: nil, transcript: nil, status: .needsNarration, failure: nil, deletedAt: nil),
            ReadbackSection(id: secondID, capturedAt: Date(timeIntervalSince1970: 20), displayName: "Display 2", directory: secondDirectory,
                screenshot: secondDirectory + "/screen.png", audio: nil, originalTranscript: nil, transcript: nil, status: .ready, failure: nil, deletedAt: nil)
        ]
        try ReadbackStore.save(manifest, at: root)
        let loaded = try ReadbackStore.load(from: root)
        try check(loaded.sections.map(\.id) == [firstID, secondID], "manifest round-trip preserves slide order")
        try check(loaded.sections[0].status == .needsNarration && loaded.sections[1].status == .ready, "unfinished and ready states remain distinct")
        var future = loaded
        future.formatVersion = 999
        try ReadbackStore.save(future, at: root)
        do {
            _ = try ReadbackStore.load(from: root)
            throw ReadbackError.message("READBACK_CHECK_FAILED: future manifests are rejected")
        } catch {
            try check(error.localizedDescription.contains("999") && error.localizedDescription.contains("1"), "unsupported format errors identify both versions")
        }
        try ReadbackStore.save(loaded, at: root)
        try rejects("parent traversal is rejected") { _ = try ReadbackStore.safeURL(root: root, relative: "../outside") }
        try rejects("absolute paths are rejected") { _ = try ReadbackStore.safeURL(root: root, relative: "/tmp/outside") }
        let outside = root.deletingLastPathComponent().appendingPathComponent("Workbench-readback-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("items/escape"), withDestinationURL: outside)
        try rejects("symbolic-link escapes are rejected") { _ = try ReadbackStore.safeURL(root: root, relative: "items/escape/private.txt") }
        try rejects("non-empty folders are never replaced") { _ = try ReadbackStore.create(at: root, title: "Replacement") }

        var moved = loaded.sections[0]
        moved.moveFiles(from: firstDirectory, to: "trash/\(firstID.uuidString.lowercased())")
        try check(moved.screenshot.hasPrefix("trash/") && moved.directory.hasPrefix("trash/"), "recoverable deletion keeps linked paths together")
        try check(VoicePreferences().shortcut(4).keyCode == UInt32(kVK_ANSI_Backslash) && VoicePreferences().shortcut(4) != VoicePreferences().shortcut(1), "Snap & Talk defaults to Control-Option-Backslash")
        var legacyPreferences = VoicePreferences()
        legacyPreferences.readbackShortcut = VoicePreferences.legacyReadbackShortcut
        try check(VoicePreferences.migratingLegacyDefaults(legacyPreferences).shortcut(4) == VoicePreferences.defaultReadbackShortcut, "the conflicting legacy Control-Option-R default migrates")
        print("READBACK_CHECKS_OK: \(passed) checks")
    }
}
