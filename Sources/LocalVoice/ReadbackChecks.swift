import Carbon
import Foundation

enum ReadbackChecks {
    /// Safe to run from an extracted app: no app lifecycle, permissions, models,
    /// or user preferences. This exercises the actual new-session resource path.
    static func runPackagedResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench-packaged-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = try ReadbackResources.deckPayload()
        let session = try ReadbackStore.create(at: root, title: "Synthetic packaged session")
        for (path, bytes) in expected {
            guard try Data(contentsOf: root.appendingPathComponent(path)) == bytes else {
                throw ReadbackError.message("Packaged Snap & Talk companion differs: \(path)")
            }
        }
        let reopened = try ReadbackStore.load(from: root)
        guard reopened.id == session.id,
              FileManager.default.fileExists(atPath: root.appendingPathComponent("README.md").path) else {
            throw ReadbackError.message("Packaged Snap & Talk session creation did not preserve its companion files.")
        }
        print("READBACK_PACKAGED_RESOURCES_OK: new session, exact complete skill payload, README and reopened manifest")
    }

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
        try check(skill.hasPrefix("---\nname: build-snap-and-talk-deck\n"), "portable skill retains its discoverable identity")
        try check(skill.contains("template.pptx") && skill.contains("visible title") && skill.contains("supporting copy"), "neutral skill retains the optional-template route and narration-grounded copy")
        let payload = try ReadbackResources.deckPayload()
        let copiesMatch = try payload.allSatisfy { path, bytes in
            try Data(contentsOf: root.appendingPathComponent(path)) == bytes
        }
        try check(copiesMatch && manifest.skillPack == .neutral, "new session defaults to the complete, exact neutral payload")
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
        try check(VoicePreferences().shortcut(5) == VoiceShortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(optionKey)) && VoicePreferences().shortcut(5) != VoicePreferences().shortcut(1), "Snap & Talk defaults to Option-C")
        var legacyPreferences = VoicePreferences()
        legacyPreferences.readbackShortcut = VoicePreferences.legacyReadbackShortcut
        try check(VoicePreferences.migratingLegacyDefaults(legacyPreferences).shortcut(5) == VoicePreferences.defaultReadbackShortcut, "the conflicting legacy Control-Option-R default migrates")
        print("READBACK_CHECKS_OK: \(passed) checks")
    }

    @MainActor
    static func runAdmissionChecks() async throws {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw ReadbackError.message("READBACK_ADMISSION_CHECK_FAILED: \(message)") }
            passed += 1
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Workbench-readback-admission-\(UUID().uuidString)")
        let domain = "Workbench.ReadbackAdmissionChecks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else { throw ReadbackError.message("Unable to isolate check preferences") }
        defer { defaults.removePersistentDomain(forName: domain); try? fm.removeItem(at: root) }
        var manifest = try ReadbackStore.create(at: root, title: "Synthetic admission")
        let id = UUID(), directory = "items/\(id.uuidString.lowercased())"
        try ReadbackStore.createPrivateDirectory(root.appendingPathComponent(directory))
        let section = ReadbackSection(id: id, capturedAt: Date(timeIntervalSince1970: 10), displayName: "Synthetic display", directory: directory,
            screenshot: directory + "/screen.png", audio: directory + "/narration.wav", originalTranscript: directory + "/narration-original.txt",
            transcript: directory + "/narration.txt", status: .ready, failure: nil, deletedAt: nil)
        for path in [section.screenshot, section.audio!, section.originalTranscript!, section.transcript!] {
            try ReadbackStore.writePrivate(Data("Original synthetic \(path)".utf8), to: root.appendingPathComponent(path))
        }
        manifest.sections = [section]; try ReadbackStore.save(manifest, at: root)
        func snapshot() throws -> [String: Data] {
            var files: [String: Data] = [:]
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
                throw ReadbackError.message("Unable to enumerate synthetic session")
            }
            for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[url.path] = try Data(contentsOf: url)
            }
            return files
        }
        let before = try snapshot()
        defaults.set([root.path], forKey: "readback.recentSessionPaths.v1")
        var denial: String? = "Synthetic ordinary dictation is active"
        var captureCount = 0
        var duringCapture: (() -> Void)?
        let model = ReadbackModel(engine: RecognitionEngine(store: RecognitionConfigurationStore(defaults: defaults)), defaults: defaults) {
            captureCount += 1
            await Task.yield()
            duringCapture?()
            return ReadbackScreenshot(data: Data("Replacement synthetic screenshot".utf8), displayName: "Synthetic capture", screenFrame: .zero)
        }
        defer { duringCapture = nil; model.shutdown() }
        model.mayBeginCapture = { denial }
        try check(model.manifest?.sections.first == section, "isolated model loads the ready synthetic section without permission prompts")
        await model.redoBoth(id)
        model.startNarration(for: id)
        await model.captureNewSection(fromEditor: true)
        let earlyDenied = try snapshot()
        try check(captureCount == 0, "busy admission blocks redo and new capture before invoking the capture service")
        try check(!model.isRecording && !model.isCapturing, "busy admission never starts a recorder")
        try check(earlyDenied == before, "early denial preserves manifest, original screenshot, audio and both transcripts byte for byte")
        try check(model.notice == denial, "early denial explains the owning operation")

        denial = nil
        var dictationBlockedDuringCapture = false
        duringCapture = {
            dictationBlockedDuringCapture = model.blocksDictation
            denial = "Synthetic reading started while capture awaited"
        }
        await model.redoBoth(id)
        let lateDenied = try snapshot()
        try check(captureCount == 1 && dictationBlockedDuringCapture, "in-flight screenshot capture reserves ordinary dictation admission")
        try check(lateDenied == before, "late admission denial occurs before archiving or replacing any previous section files")
        try check(model.manifest?.sections.first == section && !model.isRecording && !model.blocksDictation, "late denial retains ready state and releases the capture gate")
        try check(model.notice?.contains(denial!) == true, "late denial gives the busy reason")

        denial = nil
        duringCapture = { model.closeSession() }
        await model.redoBoth(id)
        let switched = try snapshot()
        try check(captureCount == 2 && switched == before, "closing the session during redo never modifies the previous session")
        try check(model.sessionURL == nil && !model.isRecording && !model.blocksDictation, "session change leaves no hidden recorder or capture reservation")
        print("READBACK_ADMISSION_CHECKS_OK: \(passed) checks")
    }

    @MainActor
    static func runAvailabilityChecks() async throws {
        var passed = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw ReadbackError.message("READBACK_AVAILABILITY_CHECK_FAILED: \(message)") }
            passed += 1
        }
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("Workbench-session-availability-\(UUID().uuidString)")
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        let root = fixture.appendingPathComponent("Original"), moved = fixture.appendingPathComponent("Moved")
        let other = fixture.appendingPathComponent("Different")
        let domain = "Workbench.SessionAvailability.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain); try? fm.removeItem(at: fixture) }
        let original = try ReadbackStore.create(at: root, title: "Synthetic session")
        _ = try ReadbackStore.create(at: other, title: "Different session")
        defaults.set([root.path, other.path], forKey: "readback.recentSessionPaths.v1")
        var captures = 0
        let model = ReadbackModel(engine: RecognitionEngine(store: RecognitionConfigurationStore(defaults: defaults)), defaults: defaults) {
            captures += 1
            return ReadbackScreenshot(data: Data(), displayName: "Synthetic", screenFrame: .zero)
        }
        defer { model.shutdown() }
        try check(model.currentSessionProblem == nil && model.manifest?.id == original.id, "existing session starts available")
        let originalBytes = try Data(contentsOf: root.appendingPathComponent("session.json"))
        try fm.moveItem(at: root, to: moved)
        model.refreshSessionAvailability()
        try check(model.currentSessionProblem != nil, "moving the open folder is reflected in current UI state")
        try check(model.unavailableSessions[root.standardizedFileURL.path] != nil, "missing recent gets an unavailable badge regardless of URL directory hint")
        try check(model.manifest?.id == original.id && model.recentSessionURLs.count == 2, "missing paths retain session identity and recents for recovery")
        await model.captureNewSection(fromEditor: false)
        try check(captures == 0 && !fm.fileExists(atPath: root.path), "capture refuses before permission/capture and never recreates the folder")
        do {
            try ReadbackStore.createPrivateDirectory(root.appendingPathComponent("items/\(UUID().uuidString)"), includingParents: false)
            throw ReadbackError.message("READBACK_AVAILABILITY_CHECK_FAILED: missing parents were recreated")
        } catch {
            try check(!fm.fileExists(atPath: root.path), "section creation cannot recreate parents even if the folder disappears after validation")
        }
        model.handOff(to: .claude)
        try check(model.notice?.contains("Locate") == true, "missing session cannot hand off stale paths")
        try check(!model.relinkSession(root, to: other), "locating cannot substitute a different active session")
        try check(model.sessionURL?.path == root.standardizedFileURL.path, "failed locate preserves the old selection")
        try fm.moveItem(at: moved, to: root)
        model.refreshSessionAvailability()
        try check(model.currentSessionProblem == nil, "restoring a folder clears its unavailable state")
        let manifestURL = root.appendingPathComponent("session.json"), held = fixture.appendingPathComponent("held.json")
        try fm.moveItem(at: manifestURL, to: held)
        model.refreshSessionAvailability()
        try check(model.currentSessionProblem != nil, "missing manifest also marks the session unavailable")
        try fm.moveItem(at: held, to: manifestURL)
        model.refreshSessionAvailability()
        try check(model.currentSessionProblem == nil, "manifest restoration recovers without restarting")
        try fm.moveItem(at: root, to: moved)
        model.refreshSessionAvailability()
        try check(model.relinkSession(root, to: moved), "locating the moved session succeeds")
        try check(model.sessionURL?.path == moved.standardizedFileURL.path && !model.recentSessionURLs.contains(where: { $0.path == root.path }), "relink replaces the stale path without duplicates")
        let movedBytes = try Data(contentsOf: moved.appendingPathComponent("session.json"))
        try check(movedBytes == originalBytes && !fm.fileExists(atPath: root.path), "locating does not rewrite or recreate session files")
        model.forgetRecentSession(moved)
        try check(model.sessionURL == nil && model.manifest == nil, "forgetting the current entry clears the editor")
        try check(fm.fileExists(atPath: moved.appendingPathComponent("session.json").path), "forgetting never deletes the user's session")
        try check(defaults.stringArray(forKey: "readback.recentSessionPaths.v1") == [other.path], "forgetting persists and preserves other recents")
        let reopened = ReadbackModel(engine: RecognitionEngine(store: RecognitionConfigurationStore(defaults: defaults)), defaults: defaults)
        defer { reopened.shutdown() }
        try check(reopened.recentSessionURLs.map(\.path) == [other.standardizedFileURL.path], "forgotten entry stays removed after reopening")
        print("READBACK_AVAILABILITY_CHECKS_OK: \(passed) checks")
        try await runRecoveryChecks()
        try ReadbackPackChecks.run()
    }

    @MainActor
    private static func runRecoveryChecks() async throws {
        var passed = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw ReadbackError.message("READBACK_RECOVERY_CHECK_FAILED: \(message)") }
            passed += 1
        }
        func waitFor(_ message: String, _ ready: () -> Bool) async throws {
            for _ in 0..<500 {
                if ready() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw ReadbackError.message("READBACK_RECOVERY_CHECK_FAILED: timed out waiting for \(message)")
        }
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("Workbench-session-recovery-\(UUID().uuidString)")
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        var domains: [String] = []
        defer {
            for domain in domains { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
            try? fm.removeItem(at: fixture)
        }
        func preferences(_ root: URL) -> UserDefaults {
            let domain = "Workbench.SessionRecovery.\(UUID().uuidString)"
            domains.append(domain)
            let defaults = UserDefaults(suiteName: domain)!
            defaults.set([root.path], forKey: "readback.recentSessionPaths.v1")
            return defaults
        }
        func session(_ name: String, statuses: [ReadbackSectionStatus] = []) throws -> (URL, ReadbackManifest) {
            let root = fixture.appendingPathComponent(name)
            var value = try ReadbackStore.create(at: root, title: name)
            for status in statuses {
                let id = UUID(), directory = "items/\(id.uuidString.lowercased())"
                try ReadbackStore.createPrivateDirectory(root.appendingPathComponent(directory), includingParents: false)
                try ReadbackStore.writePrivate(Data("Synthetic original audio".utf8), to: root.appendingPathComponent(directory + "/narration.wav"))
                value.sections.append(ReadbackSection(id: id, capturedAt: Date(), displayName: "Synthetic", directory: directory,
                    screenshot: directory + "/screen.png", audio: directory + "/narration.wav", originalTranscript: nil,
                    transcript: nil, status: status, failure: nil, deletedAt: nil))
            }
            try ReadbackStore.save(value, at: root)
            return (root, value)
        }

        // No refresh observes the missing interval: availability still has to
        // compare identity before handoff or showing the cached session's grid.
        do {
            let (root, original) = try session("Original identity")
            let (other, replacement) = try session("Replacement identity")
            let defaults = preferences(root)
            let model = ReadbackModel(engine: RecognitionEngine(store: RecognitionConfigurationStore(defaults: defaults)), defaults: defaults)
            defer { model.shutdown() }
            let held = fixture.appendingPathComponent("Original held")
            let replacementBytes = try Data(contentsOf: other.appendingPathComponent("session.json"))
            try fm.moveItem(at: root, to: held); try fm.moveItem(at: other, to: root)
            model.refreshSessionAvailability()
            try check(model.currentSessionProblem?.contains("different session") == true, "same-path replacement is unavailable even when no poll observed absence")
            try check(model.manifest?.id == original.id, "replacement never adopts a different UUID implicitly")
            model.handOff(to: .claude)
            try check(model.notice?.contains("Locate") == true, "handoff refuses a replacement session before copying or opening an app")
            let unchanged = try Data(contentsOf: root.appendingPathComponent("session.json"))
            let stillReplacement = try ReadbackStore.load(from: root)
            try check(unchanged == replacementBytes && stillReplacement.id == replacement.id, "rejecting replacement preserves its manifest bytes")
            try fm.moveItem(at: root, to: other); try fm.moveItem(at: held, to: root)
            model.refreshSessionAvailability()
            try check(model.currentSessionProblem == nil && model.manifest?.id == original.id, "returning the original identity clears the problem")
        }

        // Lose one active and one queued job while the destination is absent.
        // Returning the folder must restart both from saved audio exactly once.
        do {
            let (root, original) = try session("Disconnected work", statuses: [.queued, .queued])
            let defaults = preferences(root), transcriber = ControlledTranscriber()
            let model = ReadbackModel(engine: RecognitionEngine(store: RecognitionConfigurationStore(defaults: defaults)), defaults: defaults,
                transcribeAudio: { try await transcriber.transcribe($0) })
            defer { model.shutdown(); transcriber.cancel() }
            try await waitFor("first recognition") { transcriber.calls == 1 }
            let held = fixture.appendingPathComponent("Disconnected work held")
            try fm.moveItem(at: root, to: held); model.refreshSessionAvailability()
            try check(model.currentSessionProblem != nil, "an active job's missing folder is visible")
            transcriber.complete("Result completed while folder was absent")
            try await waitFor("missing jobs to leave the worker") { !model.hasPendingTranscriptions }
            let interrupted = try ReadbackStore.load(from: held)
            try check(interrupted.sections.map(\.status) == [.transcribing, .queued], "the saved folder retains active and queued work during absence")
            try fm.moveItem(at: held, to: root); model.refreshSessionAvailability()
            try await waitFor("first recovered recognition") { transcriber.calls == 2 }
            try check(model.currentSessionProblem == nil && model.pendingTranscriptionCount == 2, "reconnection schedules the orphaned active and queued jobs")
            transcriber.complete("Recovered first narration")
            try await waitFor("second recovered recognition") { transcriber.calls == 3 }
            transcriber.complete("Recovered second narration")
            try await waitFor("recovered jobs to finish") { !model.hasPendingTranscriptions }
            let completed = try ReadbackStore.load(from: root)
            try check(completed.sections.allSatisfy { $0.status == .ready }, "all recovered work reaches ready")
            try check(ReadbackStore.readText(root: root, relative: completed.sections[0].transcript) == "Recovered first narration"
                && ReadbackStore.readText(root: root, relative: completed.sections[1].transcript) == "Recovered second narration", "recovered results commit to their original sections")
            let originalAudio = try original.sections.map { try Data(contentsOf: root.appendingPathComponent($0.audio!)) }
            try check(originalAudio.allSatisfy { $0 == Data("Synthetic original audio".utf8) }, "recovery preserves original audio bytes")
            try check(transcriber.calls == 3, "recovery does not duplicate either completed job")
        }

        // A slow worker still owns its section when the folder reconnects.
        // Repeated refreshes, path normalization and forgetting are not restarts.
        do {
            let (root, _) = try session("Still running", statuses: [.queued])
            let defaults = preferences(root), transcriber = ControlledTranscriber()
            let model = ReadbackModel(engine: RecognitionEngine(store: RecognitionConfigurationStore(defaults: defaults)), defaults: defaults,
                transcribeAudio: { try await transcriber.transcribe($0) })
            defer { model.shutdown(); transcriber.cancel() }
            try await waitFor("still-running recognition") { transcriber.calls == 1 }
            let held = fixture.appendingPathComponent("Still running held")
            try fm.moveItem(at: root, to: held); model.refreshSessionAvailability()
            try fm.moveItem(at: held, to: root); model.refreshSessionAvailability(); model.refreshSessionAvailability()
            let active = try ReadbackStore.load(from: root)
            try check(active.sections[0].status == .transcribing, "reconnection preserves a live worker's status")
            try check(model.pendingTranscriptionCount == 1 && transcriber.calls == 1, "reconnection never queues a duplicate for a live worker")
            model.forgetRecentSession(root)
            try check(model.sessionURL == nil && model.hasPendingTranscriptions, "forgetting clears only the editor while recognition continues")
            transcriber.complete("Completed after forgetting")
            try await waitFor("forgotten job to finish") { !model.hasPendingTranscriptions }
            let completed = try ReadbackStore.load(from: root)
            try check(completed.sections[0].status == .ready && transcriber.calls == 1, "independent recognition commits once after forgetting")
        }

        // Recording ownership is tested without opening the microphone.
        let (_, recording) = try session("Recording ownership", statuses: [.recording, .recording, .transcribing])
        let reconciled = ReadbackRecovery.reconcile(recording, activeTranscription: recording.sections[2].id, activeRecording: recording.sections[0].id)
        try check(reconciled.sections[0] == recording.sections[0] && reconciled.sections[2] == recording.sections[2], "live recording and recognition retain every saved field")
        try check(reconciled.sections[1].status == .needsNarration && reconciled.sections[1].failure?.contains("interrupted") == true, "only an orphaned recording is marked interrupted")
        print("READBACK_RECOVERY_CHECKS_OK: \(passed) checks")
    }

    @MainActor
    private final class ControlledTranscriber {
        private(set) var calls = 0
        private var pending: [CheckedContinuation<String, Error>] = []

        func transcribe(_ url: URL) async throws -> String {
            calls += 1
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }

        func complete(_ result: String) { pending.removeFirst().resume(returning: result) }
        func cancel() {
            let continuations = pending; pending = []
            for continuation in continuations { continuation.resume(throwing: CancellationError()) }
        }
    }
}
