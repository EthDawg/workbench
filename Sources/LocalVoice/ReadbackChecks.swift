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

        // Malformed portable manifests must be rejected before deletion can touch a parent or sibling.
        func writeUnchecked(_ value: ReadbackManifest) throws {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(value).write(to: root.appendingPathComponent(ReadbackStore.manifestName))
        }
        func rejectsManifest(_ message: String, _ edit: (inout ReadbackManifest) -> Void) throws {
            var invalid = loaded; edit(&invalid)
            try writeUnchecked(invalid)
            try rejects(message) { _ = try ReadbackStore.load(from: root) }
            try rejects(message + " on save") { try ReadbackStore.save(invalid, at: root) }
            try ReadbackStore.save(loaded, at: root)
        }
        for directory in ["items", "trash", ".", "items/" + secondID.uuidString.lowercased(), firstDirectory + "/nested"] {
            try rejectsManifest("section directory must belong to its UUID: \(directory)") { $0.sections[0].directory = directory }
        }
        try rejectsManifest("deleted sections cannot reference active directories") { $0.sections[0].deletedAt = Date() }
        try rejectsManifest("duplicate IDs are rejected before draft dictionaries or deletion") { $0.sections.append($0.sections[0]) }
        try rejectsManifest("screenshots cannot reference sibling files") { $0.sections[0].screenshot = secondDirectory + "/screen.png" }
        try rejectsManifest("audio cannot reference sibling files") { $0.sections[0].audio = secondDirectory + "/narration.wav" }
        try rejectsManifest("original transcripts cannot reference session metadata") { $0.sections[0].originalTranscript = "session.json" }
        try rejectsManifest("editable transcripts cannot reference sibling files") { $0.sections[0].transcript = secondDirectory + "/narration.txt" }
        try rejectsManifest("linked files cannot be the section directory itself") { $0.sections[0].screenshot = firstDirectory }
        try rejectsManifest("linked paths cannot traverse to another section") { $0.sections[0].screenshot = firstDirectory + "/../" + secondID.uuidString.lowercased() + "/screen.png" }
        let firstScreenshot = try Data(contentsOf: root.appendingPathComponent(firstDirectory + "/screen.png"))
        let secondScreenshot = try Data(contentsOf: root.appendingPathComponent(secondDirectory + "/screen.png"))
        try check(firstScreenshot == secondScreenshot && firstScreenshot.count == 4, "rejected manifests leave both synthetic screenshots untouched")

        let aliasID = UUID(), aliasDirectory = "items/\(aliasID.uuidString.lowercased())"
        let directoryAlias = root.appendingPathComponent(aliasDirectory)
        try FileManager.default.createSymbolicLink(at: directoryAlias, withDestinationURL: root.appendingPathComponent(secondDirectory))
        try rejectsManifest("section directories cannot alias a sibling") {
            $0.sections[0] = ReadbackSection(id: aliasID, capturedAt: Date(), displayName: "Alias", directory: aliasDirectory,
                screenshot: aliasDirectory + "/screen.png", audio: nil, originalTranscript: nil, transcript: nil,
                status: .needsNarration, failure: nil, deletedAt: nil)
        }
        try FileManager.default.removeItem(at: directoryAlias)
        let alias = root.appendingPathComponent(firstDirectory + "/alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent(secondDirectory))
        try rejectsManifest("internal links cannot alias a sibling's files") { $0.sections[0].screenshot = firstDirectory + "/alias/screen.png" }
        try rejects("archive folders cannot alias siblings") { _ = try ReadbackStore.safeURL(root: root, relative: firstDirectory + "/alias/history") }
        try FileManager.default.removeItem(at: alias)
        let missing = root.appendingPathComponent(firstDirectory + "/missing")
        try FileManager.default.createSymbolicLink(at: missing, withDestinationURL: root.appendingPathComponent("not-created"))
        try rejects("dangling symbolic links are rejected before writing") { _ = try ReadbackStore.safeURL(root: root, relative: firstDirectory + "/missing/narration.txt") }
        try FileManager.default.removeItem(at: missing)

        // Reproduce transcription finishing during the asynchronous screen capture.
        var completed = loaded
        completed.sections[0].audio = firstDirectory + "/narration.wav"
        completed.sections[0].originalTranscript = firstDirectory + "/narration-original.txt"
        completed.sections[0].transcript = firstDirectory + "/narration.txt"
        completed.sections[0].status = .ready
        let audioBytes = Data("synthetic saved audio".utf8)
        try audioBytes.write(to: root.appendingPathComponent(completed.sections[0].audio!))
        try Data("Original words".utf8).write(to: root.appendingPathComponent(completed.sections[0].originalTranscript!))
        try Data("Edited words".utf8).write(to: root.appendingPathComponent(completed.sections[0].transcript!))
        try ReadbackStore.save(completed, at: root)
        let thirdID = UUID(), thirdDirectory = "items/\(thirdID.uuidString.lowercased())"
        let appendedSection = ReadbackSection(id: thirdID, capturedAt: Date(), displayName: "Display 3", directory: thirdDirectory,
            screenshot: thirdDirectory + "/screen.png", audio: nil, originalTranscript: nil, transcript: nil, status: .needsNarration, failure: nil, deletedAt: nil)
        _ = try ReadbackStore.append(appendedSection, at: root)
        let appended = try ReadbackStore.load(from: root)
        try check(appended.sections.map(\.id) == [firstID, secondID, thirdID], "capture appends to the latest committed section order")
        try check(appended.sections[0] == completed.sections[0], "capture retains transcription completed after its initial snapshot")
        try check(ReadbackStore.readText(root: root, relative: appended.sections[0].transcript) == "Edited words", "capture retains the completed transcript file")

        // Beginning a rerecord changes only status; cancellation must restore that status and prior error.
        for previousStatus in [ReadbackSectionStatus.ready, .failed, .needsNarration] {
            var before = appended
            before.sections[0].status = previousStatus
            before.sections[0].failure = previousStatus == .failed ? "Original recognition failure" : nil
            var recording = before
            recording.sections[0].status = .recording; recording.sections[0].failure = nil
            try ReadbackStore.save(recording, at: root)
            let restored = try ReadbackStore.restoreNarrationState(before.sections[0], at: root)
            try check(restored.sections[0] == before.sections[0], "cancel rerecord restores previous \(previousStatus.rawValue) state and file links")
            let savedAudio = try Data(contentsOf: root.appendingPathComponent(restored.sections[0].audio!))
            try check(savedAudio == audioBytes, "cancel rerecord preserves original audio bytes")
            try check(ReadbackStore.readText(root: root, relative: restored.sections[0].originalTranscript) == "Original words"
                && ReadbackStore.readText(root: root, relative: restored.sections[0].transcript) == "Edited words", "cancel rerecord preserves original and edited transcripts")
            try check(restored.sections.dropFirst() == appended.sections.dropFirst(), "cancel rerecord preserves other sections")
        }
        var trashed = loaded
        trashed.sections[0].moveFiles(from: firstDirectory, to: "trash/\(firstID.uuidString.lowercased())")
        trashed.sections[0].deletedAt = Date()
        try ReadbackStore.save(trashed, at: root)
        let reloadedTrash = try ReadbackStore.load(from: root)
        try check(reloadedTrash.sections[0].directory.hasPrefix("trash/"), "valid recoverable-deletion paths still load")
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
