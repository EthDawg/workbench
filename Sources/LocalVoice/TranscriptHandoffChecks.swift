import Foundation

/// Synthetic checks for the selected-transcript handoff. Like the other
/// scripted checks they build their own folders under the temporary directory:
/// no microphone, screen recording, saved history, preferences or network is
/// touched, and nothing is copied to the clipboard or handed to another app.
enum TranscriptHandoffChecks {
    private static let unselectedMarker = "UNSELECTED-TRANSCRIPT-MARKER"
    private static let unselectedOriginalMarker = "UNSELECTED-ORIGINAL-MARKER"
    private static let deletedMarker = "RECENTLY-DELETED-SECTION-MARKER"
    private static let unreferencedMarker = "UNREFERENCED-LEFTOVER-MARKER"

    /// The Snap & Talk deck prompt exactly as it shipped, so making the handoff
    /// prompt skill-driven cannot quietly change the existing behaviour.
    private static func expectedDeckPrompt(_ url: URL) -> String {
        """
        Use the `SKILL.md` in this Workbench Snap & Talk session folder as the task instructions.

        Session folder: \(url.standardizedFileURL.path)

        Read `session.json`, use only files inside the session folder, and build the requested slide deck. Keep the original session and any `template.pptx` unchanged. Keep the work local unless I explicitly authorize an external upload or service.
        """
    }

    @MainActor
    static func runAll() throws {
        try run()
        try runRunnerChecks()
    }

    static func run() throws {
        var passed = 0
        // A plain Bool, so a check can compare values read from the file system.
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw TranscriptHandoffError.message("TRANSCRIPT_HANDOFF_CHECK_FAILED: \(message)") }
            passed += 1
        }
        func rejects(_ message: String, _ work: () throws -> Void) throws {
            do { try work() }
            catch { passed += 1; return }
            throw TranscriptHandoffError.message("TRANSCRIPT_HANDOFF_CHECK_FAILED: \(message)")
        }

        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("Workbench-transcript-handoff-\(UUID().uuidString)", isDirectory: true)
        try ReadbackStore.createPrivateDirectory(fixture)
        defer { try? fm.removeItem(at: fixture) }

        func write(_ root: URL, _ relative: String, _ text: String) throws {
            try ReadbackStore.writePrivate(Data(text.utf8), to: root.appendingPathComponent(relative))
        }
        func files(in root: URL) throws -> [String: Data] {
            var found: [String: Data] = [:]
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
                throw TranscriptHandoffError.message("TRANSCRIPT_HANDOFF_CHECK_FAILED: unable to enumerate \(root.lastPathComponent)")
            }
            for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                found[String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))] = try Data(contentsOf: url)
            }
            return found
        }
        func mode(_ url: URL) throws -> Int? {
            (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        }
        func stagingLeftovers() throws -> [String] {
            try fm.contentsOfDirectory(at: fixture, includingPropertiesForKeys: nil)
                .map(\.lastPathComponent).filter { $0.hasPrefix(TranscriptHandoffStore.stagingPrefix) }
        }

        /// A synthetic Snap & Talk session: live screenshot/narration pairs, an
        /// optional Recently Deleted section and an unreferenced leftover file.
        func makeSession(_ name: String, live: Int = 2, trashed: Bool = true) throws -> (URL, ReadbackManifest) {
            let root = fixture.appendingPathComponent(name, isDirectory: true)
            try ReadbackStore.createPrivateDirectory(root)
            try ReadbackStore.createPrivateDirectory(root.appendingPathComponent("items"))
            try ReadbackStore.createPrivateDirectory(root.appendingPathComponent("trash"))
            var sections: [ReadbackSection] = []
            for index in stride(from: 1, through: live, by: 1) {
                let id = UUID(), directory = "items/\(id.uuidString.lowercased())"
                try ReadbackStore.createPrivateDirectory(root.appendingPathComponent(directory))
                try write(root, directory + "/screen.png", "screenshot \(index)")
                try write(root, directory + "/narration.wav", "audio \(index)")
                try write(root, directory + "/narration-original.txt", "original narration \(index)")
                try write(root, directory + "/narration.txt", "edited narration \(index)")
                sections.append(ReadbackSection(id: id, capturedAt: Date(timeIntervalSince1970: Double(index) * 100),
                    displayName: "Display \(index)", directory: directory, screenshot: directory + "/screen.png",
                    audio: directory + "/narration.wav", originalTranscript: directory + "/narration-original.txt",
                    transcript: directory + "/narration.txt", status: .ready, failure: nil, deletedAt: nil))
            }
            if trashed {
                let id = UUID(), directory = "trash/\(id.uuidString.lowercased())"
                try ReadbackStore.createPrivateDirectory(root.appendingPathComponent(directory))
                try write(root, directory + "/screen.png", deletedMarker)
                sections.append(ReadbackSection(id: id, capturedAt: Date(timeIntervalSince1970: 900), displayName: "Deleted display",
                    directory: directory, screenshot: directory + "/screen.png", audio: nil, originalTranscript: nil,
                    transcript: nil, status: .ready, failure: nil, deletedAt: Date(timeIntervalSince1970: 950)))
            }
            // A leftover the session no longer links: recovery files never travel.
            try write(root, "items/leftover-recovered.txt", unreferencedMarker)
            let manifest = ReadbackManifest(id: UUID(), title: name, createdAt: Date(timeIntervalSince1970: 10),
                                            updatedAt: Date(timeIntervalSince1970: 20), sections: sections)
            try ReadbackStore.save(manifest, at: root)
            try ReadbackStore.writePrivate(try JSONEncoder().encode(ReadbackSkillPackProvenance(pack: .neutral)),
                                           to: root.appendingPathComponent(ReadbackStore.skillPackReceiptName))
            return (root, manifest)
        }

        // The selected transcripts, plus one the person did not select.
        let firstSelected = Transcript(date: Date(timeIntervalSince1970: 1_700_000_100), text: "We agreed to run the pilot next month.",
                                       seconds: 12.5, rawText: "um we agreed to run the pilot next month", cleanupMethod: "Light")
        let secondSelected = Transcript(date: Date(timeIntervalSince1970: 1_700_000_200), text: "The second selected capture has no separate original.", seconds: 4)
        let notSelected = Transcript(date: Date(timeIntervalSince1970: 1_700_000_300), text: "Unrelated private capture \(unselectedMarker).",
                                     seconds: 7, rawText: "unrelated private capture \(unselectedOriginalMarker)")

        // 1. The built-in neutral skill is a complete, structurally valid entry point.
        let builtIn = TranscriptHandoffSkills.followUpSnapshot()
        try TranscriptHandoffSkillCheck.validate(builtIn)
        passed += 1
        guard let entry = builtIn.files[TranscriptHandoffStore.skillEntryPoint],
              let skillText = String(data: entry, encoding: .utf8) else {
            throw TranscriptHandoffError.message("TRANSCRIPT_HANDOFF_CHECK_FAILED: the built-in skill has no readable SKILL.md")
        }
        try check(builtIn.files.count == 1 && builtIn.reference.id == "workbench-follow-up", "the built-in follow-up skill is one self-contained entry point")
        try check(skillText.contains("handoff.json") && skillText.contains("original") && skillText.contains("cleaned"),
                  "the skill reads the manifest and distinguishes original from cleaned wording")
        try check(skillText.contains("transcriptRole") && skillText.contains("adopted") && skillText.contains("reference"),
                  "the skill respects the person's chosen dictation role")
        try check(skillText.contains("Do not invent") && skillText.contains("commitments"), "the skill forbids invented commitments")
        try check(skillText.contains("outputs/") && skillText.contains("unchanged"), "the skill preserves originals")
        try check(skillText.contains("direct authorization"), "the skill does not authorize external delivery")

        // 2. Selection is resolved against the saved history by identifier, the
        // same rule the full history view applies to its checkboxes.
        let history = [notSelected, firstSelected, secondSelected]
        let chosen: Set<UUID> = [firstSelected.id, secondSelected.id]
        let selected = TranscriptHandoffSelection.resolve(chosen, in: history)
        try check(selected.map(\.id) == [firstSelected.id, secondSelected.id], "selection follows the saved history and leaves unselected captures out")
        try check(TranscriptHandoffSelection.resolve(chosen, in: history.filter { $0.id != firstSelected.id }).map(\.id) == [secondSelected.id],
                  "a transcript removed from history can no longer be handed off")
        try check(TranscriptHandoffSelection.resolve([], in: history).isEmpty, "nothing is selected by default")
        try check(TranscriptHandoffSelection.resolve([UUID()], in: history).isEmpty, "an unknown identifier selects nothing")

        // 3. Only the selected captures become records, with both wordings kept apart.
        let records = try TranscriptHandoffStore.records(for: selected)
        try check(records.map(\.id) == [firstSelected.id, secondSelected.id] && records.map(\.index) == [1, 2],
                  "records keep the selected transcripts in the order they were chosen")
        try check(records[0].hasSeparateOriginal && records[0].cleanedText == firstSelected.text && records[0].originalText == firstSelected.rawText,
                  "a cleaned capture keeps its original recognised wording separately")
        try check(!records[1].hasSeparateOriginal && records[1].originalText == secondSelected.text,
                  "a capture without a separate original repeats its wording instead of losing it")
        try check(records[0].capturedAt == firstSelected.date && records[0].cleanup == "Light", "records carry the original capture time and cleanup method")
        try rejects("an empty selection is refused") { _ = try TranscriptHandoffStore.records(for: []) }
        try rejects("the same transcript cannot be selected twice") { _ = try TranscriptHandoffStore.records(for: [firstSelected, firstSelected]) }

        // 4. One complete handoff: selected transcripts, built-in skill, one session as evidence.
        let (session, sessionManifest) = try makeSession("Snap and Talk session")
        let sourceBefore = try files(in: session)
        let destination = fixture.appendingPathComponent("Handoff with spaces", isDirectory: true)
        var request = TranscriptHandoffRequest(title: "Synthetic follow-up", transcripts: selected,
                                               skill: builtIn, evidenceSession: session)
        request.createdAt = Date(timeIntervalSince1970: 1_700_000_500)
        try TranscriptHandoffStore.validate(request)
        passed += 1
        let result = try TranscriptHandoffStore.create(request, at: destination)
        let produced = try files(in: result.folder)
        let manifest = result.manifest
        try check(result.folder.standardizedFileURL == destination.standardizedFileURL, "the handoff is created exactly where it was named")
        try check(produced[TranscriptHandoffStore.skillEntryPoint] == builtIn.files[TranscriptHandoffStore.skillEntryPoint],
                  "the chosen skill is copied byte for byte as the single entry point")
        try check(produced[TranscriptHandoffStore.manifestName] != nil && produced["README.md"] != nil,
                  "the folder carries one typed manifest and a plain-language README")
        try check(produced[TranscriptHandoffStore.outputsDirectory + "/" + TranscriptHandoffStore.outputsPlaceholder] != nil
                    && produced.keys.filter { $0.hasPrefix(TranscriptHandoffStore.outputsDirectory + "/") }.count == 1,
                  "outputs/ exists for results and starts with nothing but its placeholder note")
        try check(mode(result.folder) == 0o700 && mode(result.folder.appendingPathComponent(TranscriptHandoffStore.manifestName)) == 0o600,
                  "the handoff folder and its manifest are private to the user")
        try check(stagingLeftovers().isEmpty, "a successful handoff leaves no staging folder behind")

        // 4a. The manifest is the authoritative record and survives a round trip.
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TranscriptHandoffManifest.self, from: produced[TranscriptHandoffStore.manifestName]!)
        try check(decoded.formatVersion == TranscriptHandoffManifest.currentFormat && decoded.id == manifest.id
                    && decoded.transcripts == manifest.transcripts && decoded.skill == manifest.skill
                    && decoded.skillEntryPoint == TranscriptHandoffStore.skillEntryPoint,
                  "handoff.json round-trips the selected transcripts, skill and identity")
        try check(decoded.skill.id == TranscriptHandoffSkills.followUpReference.id && decoded.skill.version == "1.0.0",
                  "the manifest records the skill id and version that produced the instructions")
        try check(decoded.transcripts.map(\.id) == [firstSelected.id, secondSelected.id]
                    && decoded.transcripts.map(\.capturedAt) == [firstSelected.date, secondSelected.date],
                  "the manifest records the original transcript ids and capture times")

        // 4b. Original and cleaned wording travel as distinguishable files.
        let cleanedCopy = produced[records[0].cleanedFile].flatMap { String(data: $0, encoding: .utf8) }
        let originalCopy = produced[records[0].originalFile].flatMap { String(data: $0, encoding: .utf8) }
        try check(cleanedCopy == firstSelected.text && originalCopy == firstSelected.rawText,
                  "the copied text files keep cleaned and original wording apart")
        try check(produced.keys.filter { $0.hasPrefix(TranscriptHandoffStore.transcriptsDirectory + "/") }.count == 4,
                  "exactly two text files per selected transcript are copied")

        // 4c. Nothing but the selection travels.
        let allText = produced.values.compactMap { String(data: $0, encoding: .utf8) }.joined(separator: "\n")
        try check(!allText.contains(unselectedMarker) && !allText.contains(unselectedOriginalMarker),
                  "an unselected transcript never appears anywhere in the handoff folder")
        try check(!allText.contains(deletedMarker), "a Recently Deleted section is never copied as evidence")
        try check(!allText.contains(unreferencedMarker), "an unreferenced leftover file in the session is never copied")
        try check(!allText.contains(session.path) && !allText.contains(fixture.path),
                  "no absolute session, history or home path is recorded in the handoff folder")
        try check(manifest.evidence?.sourceFolderName == session.lastPathComponent, "only the session's folder name is recorded")

        // 4d. Screenshots stay paired with the narration recorded for them.
        guard let evidence = manifest.evidence else {
            throw TranscriptHandoffError.message("TRANSCRIPT_HANDOFF_CHECK_FAILED: the explicitly selected session produced no evidence record")
        }
        try check(evidence.sections.count == 2 && evidence.sessionID == sessionManifest.id && evidence.sessionSkill == .neutral,
                  "the whole live session travels with its own skill provenance and no deleted sections")
        for (offset, section) in evidence.sections.enumerated() {
            let index = offset + 1
            let screenshot = produced[section.screenshot].flatMap { String(data: $0, encoding: .utf8) }
            let audio = section.audio.flatMap { produced[$0] }.flatMap { String(data: $0, encoding: .utf8) }
            let originalNarration = section.originalTranscript.flatMap { produced[$0] }.flatMap { String(data: $0, encoding: .utf8) }
            let editedNarration = section.editedTranscript.flatMap { produced[$0] }.flatMap { String(data: $0, encoding: .utf8) }
            try check(screenshot == "screenshot \(index)" && audio == "audio \(index)", "section \(index) keeps its screenshot beside its own narration audio")
            try check(originalNarration == "original narration \(index)" && editedNarration == "edited narration \(index)",
                      "section \(index) keeps both narration versions of the same screenshot")
            try check(section.screenshot.hasPrefix(TranscriptHandoffStore.evidenceDirectory + "/") && section.index == index,
                      "section \(index) is stored under inputs/ with a stable order")
            try check(mode(result.folder.appendingPathComponent(section.screenshot)) == 0o600, "copied section \(index) media stays private")
        }
        try check(files(in: session) == sourceBefore, "copying evidence never modifies or moves the source session")

        // 5. The copied prompt follows the chosen skill, and Snap & Talk keeps its deck prompt.
        for target in ReadbackHandoffTarget.allCases {
            let prompt = target.prompt(for: result.folder, brief: .transcriptHandoff(manifest))
            try check(prompt.contains("`\(TranscriptHandoffStore.skillEntryPoint)`") && prompt.contains("`\(TranscriptHandoffStore.manifestName)`")
                        && prompt.contains(result.folder.standardizedFileURL.path), "\(target.title) handoff identifies the portable folder, its skill and its manifest")
            try check(prompt.contains(manifest.skill.name) && !prompt.contains("slide deck"), "\(target.title) handoff follows the chosen skill instead of forcing a deck")
            try check(prompt.contains("selected these dictations as my instructions") && prompt.contains("does not authorize sending or publishing")
                        && prompt.contains("Keep the work local"), "\(target.title) handoff keeps the work local and claims no sending authority")
            try check(target.prompt(for: session) == expectedDeckPrompt(session), "\(target.title) Snap & Talk handoff still points at session.json and the deck skill")
        }

        // 6. Invalid inputs fail before anything is published, and clean up only their own staging.
        func rejectsCreate(_ message: String, _ name: String, _ candidate: TranscriptHandoffRequest) throws {
            let target = fixture.appendingPathComponent(name, isDirectory: true)
            try rejects(message) { _ = try TranscriptHandoffStore.create(candidate, at: target) }
            try check(!fm.fileExists(atPath: target.path), "\(message): no half-finished folder is published")
            try check(stagingLeftovers().isEmpty, "\(message): no staging folder is left behind")
        }
        func skillRequest(_ reference: ReadbackSkillPackReference, _ payload: [String: Data]) -> TranscriptHandoffRequest {
            TranscriptHandoffRequest(title: "Synthetic", transcripts: [firstSelected],
                                     skill: ReadbackSkillPackSnapshot(reference: reference, files: payload))
        }
        let synthetic = ReadbackSkillPackReference(id: "synthetic-skill", version: "1.0.0", name: "Synthetic skill")
        let entryData = Data("---\nname: synthetic\n---\n\n# Synthetic\n".utf8)
        try rejectsCreate("a skill without a SKILL.md entry point", "No entry point", skillRequest(synthetic, ["notes.md": entryData]))
        try rejectsCreate("a skill with an empty entry point", "Empty entry point", skillRequest(synthetic, [TranscriptHandoffStore.skillEntryPoint: Data()]))
        try rejectsCreate("a skill with an unusable version", "Bad version",
                          skillRequest(ReadbackSkillPackReference(id: "synthetic-skill", version: "1.0", name: "Synthetic skill"),
                                       [TranscriptHandoffStore.skillEntryPoint: entryData]))
        for unsafe in ["../escape.md", "/absolute.md", "nested/../escape.md", ".hidden/asset.md", "inputs/transcripts/fake.txt",
                       TranscriptHandoffStore.manifestName, "README.md", "outputs/result.md"] {
            try rejectsCreate("a skill supplying \(unsafe)", "Unsafe \(UUID().uuidString)",
                              skillRequest(synthetic, [TranscriptHandoffStore.skillEntryPoint: entryData, unsafe: entryData]))
        }
        try rejectsCreate("an incomplete bundled deck pack", "Incomplete pack",
                          skillRequest(.serviceNow, [TranscriptHandoffStore.skillEntryPoint: entryData]))
        try rejectsCreate("no selected transcripts", "No transcripts",
                          TranscriptHandoffRequest(title: "Synthetic", transcripts: [], skill: builtIn))

        // A skill whose own paths collide fails while staging, after writing began.
        try rejectsCreate("a skill whose file and folder names collide", "Colliding skill",
                          skillRequest(synthetic, [TranscriptHandoffStore.skillEntryPoint: entryData, "asset": entryData, "asset/inner.md": entryData]))

        // 7. Malformed, aliased and incomplete evidence.
        func evidenceRequest(_ url: URL) -> TranscriptHandoffRequest {
            TranscriptHandoffRequest(title: "Synthetic", transcripts: [firstSelected], skill: builtIn, evidenceSession: url)
        }
        let notASession = fixture.appendingPathComponent("Not a session", isDirectory: true)
        try ReadbackStore.createPrivateDirectory(notASession)
        try write(notASession, "notes.txt", "Just a folder")
        try rejectsCreate("a folder that is not a Snap & Talk session", "No session", evidenceRequest(notASession))
        try rejectsCreate("a session folder that does not exist", "Missing session",
                          evidenceRequest(fixture.appendingPathComponent("Absent session", isDirectory: true)))
        let aliasedSession = fixture.appendingPathComponent("Aliased session")
        try fm.createSymbolicLink(at: aliasedSession, withDestinationURL: session)
        try rejectsCreate("a session folder that is a symbolic link", "Aliased root", evidenceRequest(aliasedSession))
        try fm.removeItem(at: aliasedSession)

        let (aliasedMedia, aliasedManifest) = try makeSession("Session with an aliased screenshot")
        let aliasedScreenshot = aliasedMedia.appendingPathComponent(aliasedManifest.sections[0].screenshot)
        try fm.removeItem(at: aliasedScreenshot)
        try fm.createSymbolicLink(at: aliasedScreenshot, withDestinationURL: aliasedMedia.appendingPathComponent(aliasedManifest.sections[1].screenshot))
        try rejectsCreate("a section screenshot that aliases another section", "Aliased media", evidenceRequest(aliasedMedia))

        let (incomplete, incompleteManifest) = try makeSession("Session missing a screenshot")
        try fm.removeItem(at: incomplete.appendingPathComponent(incompleteManifest.sections[0].screenshot))
        try rejectsCreate("a session whose screenshot file is missing", "Missing media", evidenceRequest(incomplete))

        let (emptied, _) = try makeSession("Session with only deleted sections", live: 0, trashed: true)
        try rejectsCreate("a session with nothing but Recently Deleted sections", "Only deleted", evidenceRequest(emptied))
        do {
            _ = try TranscriptHandoffStore.evidence(at: emptied)
            throw TranscriptHandoffError.message("TRANSCRIPT_HANDOFF_CHECK_FAILED: deleted-only sessions must be refused")
        } catch {
            try check(error.localizedDescription.contains("Recently Deleted"), "the deleted-only refusal explains that deleted items are never copied")
        }
        try check(files(in: session) == sourceBefore, "every refused handoff leaves the chosen session untouched")

        // 8. Existing destinations are never replaced, and an empty one is usable.
        let occupied = fixture.appendingPathComponent("Occupied", isDirectory: true)
        try ReadbackStore.createPrivateDirectory(occupied)
        try write(occupied, "existing.txt", "Existing work")
        try rejects("a folder with existing files is never replaced") {
            _ = try TranscriptHandoffStore.create(TranscriptHandoffRequest(title: "Synthetic", transcripts: [firstSelected], skill: builtIn), at: occupied)
        }
        try check(files(in: occupied) == ["existing.txt": Data("Existing work".utf8)], "the rejected destination keeps its files unchanged")
        let occupyingFile = fixture.appendingPathComponent("Occupying file")
        try write(fixture, "Occupying file", "A file, not a folder")
        try rejects("a name already used by a file is refused") {
            _ = try TranscriptHandoffStore.create(TranscriptHandoffRequest(title: "Synthetic", transcripts: [firstSelected], skill: builtIn), at: occupyingFile)
        }
        try check(Data(contentsOf: occupyingFile) == Data("A file, not a folder".utf8), "the existing file is preserved")
        let aliasedDestination = fixture.appendingPathComponent("Aliased destination")
        try fm.createSymbolicLink(at: aliasedDestination, withDestinationURL: session)
        try rejects("a destination that is a symbolic link is refused") {
            _ = try TranscriptHandoffStore.create(TranscriptHandoffRequest(title: "Synthetic", transcripts: [firstSelected], skill: builtIn), at: aliasedDestination)
        }
        try check(files(in: session) == sourceBefore, "refusing an aliased destination never writes into the session it points at")
        try fm.removeItem(at: aliasedDestination)
        let emptyDestination = fixture.appendingPathComponent("Prepared empty folder", isDirectory: true)
        try ReadbackStore.createPrivateDirectory(emptyDestination)
        let second = try TranscriptHandoffStore.create(
            TranscriptHandoffRequest(title: "Second synthetic", transcripts: [secondSelected], skill: builtIn), at: emptyDestination)
        let secondFiles = try files(in: second.folder)
        try check(second.manifest.transcripts.map(\.id) == [secondSelected.id] && second.manifest.evidence == nil,
                  "a second handoff carries only its own selection and no evidence")
        try check(!secondFiles.values.compactMap { String(data: $0, encoding: .utf8) }.joined().contains(firstSelected.text),
                  "an earlier handoff's transcripts never leak into a later one")
        try check(second.manifest.id != manifest.id, "each handoff has its own identifier")
        try check(stagingLeftovers().isEmpty, "no staging folder survives the whole run")
        try check(files(in: notASession) == ["notes.txt": Data("Just a folder".utf8)], "unrelated folders beside the destination are untouched")
        print("TRANSCRIPT_HANDOFF_CHECKS_OK: \(passed) checks")
    }

    /// The panel-driven runner, with the native choosers replaced. No folder is
    /// created, no prompt is copied and no application is opened here.
    @MainActor
    static func runRunnerChecks() throws {
        var passed = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw TranscriptHandoffError.message("TRANSCRIPT_HANDOFF_RUNNER_CHECK_FAILED: \(message)") }
            passed += 1
        }
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("Workbench-transcript-handoff-runner-\(UUID().uuidString)", isDirectory: true)
        try ReadbackStore.createPrivateDirectory(fixture)
        defer { try? fm.removeItem(at: fixture) }

        let session = fixture.appendingPathComponent("Runner session", isDirectory: true)
        try ReadbackStore.createPrivateDirectory(session)
        try ReadbackStore.createPrivateDirectory(session.appendingPathComponent("items"))
        try ReadbackStore.createPrivateDirectory(session.appendingPathComponent("trash"))
        let sectionID = UUID(), directory = "items/\(sectionID.uuidString.lowercased())"
        try ReadbackStore.createPrivateDirectory(session.appendingPathComponent(directory))
        try ReadbackStore.writePrivate(Data("screenshot".utf8), to: session.appendingPathComponent(directory + "/screen.png"))
        let manifest = ReadbackManifest(id: UUID(), title: "Runner session", createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            sections: [ReadbackSection(id: sectionID, capturedAt: Date(timeIntervalSince1970: 30), displayName: "Display 1",
                directory: directory, screenshot: directory + "/screen.png", audio: nil, originalTranscript: nil,
                transcript: nil, status: .ready, failure: nil, deletedAt: nil)])
        try ReadbackStore.save(manifest, at: session)
        let notASession = fixture.appendingPathComponent("Runner not a session", isDirectory: true)
        try ReadbackStore.createPrivateDirectory(notASession)

        let capture = Transcript(date: Date(timeIntervalSince1970: 1_700_000_100), text: "One selected capture.", seconds: 3)
        let runner = TranscriptHandoffRunner()
        var destinationPrompts = 0
        runner.chooseDestination = { _ in destinationPrompts += 1; return nil }

        runner.handOff(to: .claude, transcripts: [], skill: .followUp, evidence: nil)
        try check(destinationPrompts == 0, "an unusable selection never reaches the folder panel")
        try check(runner.lastFolder == nil && runner.status == nil, "a refused handoff reports no folder and no status")
        try check(runner.failure?.contains("Nothing was created") == true, "the refusal says plainly that nothing was created")
        try check(runner.failure?.lowercased().contains("sent") != true && runner.failure?.lowercased().contains("uploaded") != true,
                  "the refusal never claims anything was sent or uploaded")

        runner.handOff(to: .claude, transcripts: [capture], skill: .followUp, evidence: nil)
        try check(destinationPrompts == 1 && runner.lastFolder == nil && runner.status == nil && runner.failure == nil,
                  "cancelling the folder panel creates nothing and reports no failure")
        try check(fm.contentsOfDirectory(at: fixture, includingPropertiesForKeys: nil)
                    .allSatisfy { !$0.lastPathComponent.hasPrefix(TranscriptHandoffStore.stagingPrefix) },
                  "cancelling leaves no staging folder")

        runner.chooseEvidenceSession = { notASession }
        try check(runner.chooseEvidence() == nil && runner.failure != nil, "an unreadable evidence folder is refused when it is chosen")
        runner.chooseEvidenceSession = { session }
        try check(runner.chooseEvidence()?.standardizedFileURL == session.standardizedFileURL && runner.failure == nil,
                  "a readable session is accepted and clears the earlier problem")
        try check(runner.useEvidence(session)?.standardizedFileURL == session.standardizedFileURL,
                  "a host-selected session is validated without opening a panel")
        runner.chooseEvidenceSession = { nil }
        try check(runner.chooseEvidence() == nil, "cancelling the session chooser selects nothing")
        runner.reset()
        try check(runner.status == nil && runner.failure == nil, "resetting clears earlier feedback")
        print("TRANSCRIPT_HANDOFF_RUNNER_CHECKS_OK: \(passed) checks")
    }
}
