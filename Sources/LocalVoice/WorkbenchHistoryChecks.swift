import Foundation

/// Synthetic checks for transcript details and selection. Like the other scripted
/// checks they build their own folders under the temporary directory: no saved
/// history, preferences, microphone, screen recording or network is touched, and
/// no live user data is read or replaced.
enum WorkbenchHistoryChecks {
    @MainActor
    static func run() throws -> String {
        var passed = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw VoiceError.message("WORKBENCH_HISTORY_CHECK_FAILED: \(name)") }
            passed += 1
        }
        func rejects(_ name: String, _ work: () throws -> Void) throws {
            do { try work() } catch { passed += 1; return }
            throw VoiceError.message("WORKBENCH_HISTORY_CHECK_FAILED: \(name)")
        }
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("Workbench-history-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: fixture) }
        func mode(_ url: URL) throws -> Int? {
            (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        }
        func makeDirectory(_ name: String) throws -> URL {
            let url = fixture.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return url
        }
        // A steady, advancing clock, so saved snapshots have distinguishable times
        // without depending on how fast the check runs.
        var tick = Date(timeIntervalSince1970: 1_700_000_000)
        func clock() -> Date { tick.addTimeInterval(1); return tick }

        // 1. Dictation history keeps every capture, including the oldest one a
        //    saved selection can point at.
        var history: [Transcript] = []
        for index in 0...TranscriptHistory.limit {
            history = TranscriptHistory.adding(
                Transcript(date: Date(timeIntervalSince1970: 1_600_000_000 + Double(index)), text: "Capture \(index)", seconds: 1),
                to: history)
        }
        try check(history.count == TranscriptHistory.limit + 1, "the 101st dictation keeps all 101 captures")
        try check(history.first?.text == "Capture 100" && history.last?.text == "Capture 0",
                  "the newest capture is first and the oldest one is still in history")
        let oldest = history[history.count - 1], newest = history[0]
        let updated = Transcript(id: oldest.id, date: oldest.date, text: "Corrected oldest wording", seconds: 1)
        let afterUpdate = TranscriptHistory.adding(updated, to: history)
        try check(afterUpdate.filter { $0.id == oldest.id }.count == 1 && afterUpdate.count == history.count,
                  "saving an existing capture id updates one record instead of adding another")

        // 2. A first run owns nothing and writes nothing.
        let directory = fixture.appendingPathComponent("Library", isDirectory: true)
        let model = WorkbenchHistoryModel(directory: directory, now: clock)
        try check(model.error == nil && !model.isBlocked && model.selected.isEmpty && model.savedSelections.isEmpty,
                  "a first run starts empty and reports no problem")
        try check(!fm.fileExists(atPath: model.store.url.path), "nothing is written before anything is chosen")

        // 3. Captures saved before details existed stay ordinary prompts.
        try check(model.metadata(for: oldest.id) == TranscriptMetadata() && model.metadata(for: oldest.id).purpose == .prompt,
                  "a capture without saved details is an ordinary Prompt")
        try check(model.metadata(for: oldest.id).person.isEmpty && model.metadata(for: oldest.id).company.isEmpty
                    && model.metadata(for: oldest.id).tags.isEmpty,
                  "no person, company or tag is ever inferred for an existing capture")
        try check(TranscriptPurpose.allCases.map(\.title) == ["Prompt", "Meeting", "Call", "Note"],
                  "the purposes are the four plain categories, Prompt included")

        // 4. One selection across transcripts and Snap & Talk, saved as a snapshot.
        let snapRef = WorkbenchItemReference(kind: .snap, id: UUID())
        // A reference whose capture is no longer in history.
        let missing = WorkbenchItemReference(kind: .transcript, id: UUID())
        let firstSelection: Set<WorkbenchItemReference> = [WorkbenchItemReference(kind: .transcript, id: oldest.id),
                                                           WorkbenchItemReference(kind: .transcript, id: newest.id),
                                                           snapRef, missing]
        let laterSelection: Set<WorkbenchItemReference> = [WorkbenchItemReference(kind: .transcript, id: newest.id)]
        model.setSelected(firstSelection)
        try check(model.selected == firstSelection && model.error == nil,
                  "the chosen transcripts and Snap & Talk section are selected together")
        try check(mode(model.store.url) == 0o600 && mode(directory) == 0o700, "the sidecar and its folder are private to the user")

        model.saveSelection(name: "  Pilot follow-up  ")
        guard let firstSaved = model.savedSelections.first else {
            throw VoiceError.message("WORKBENCH_HISTORY_CHECK_FAILED: naming a selection saved nothing")
        }
        try check(model.savedSelections.count == 1 && firstSaved.name == "Pilot follow-up",
                  "a named selection trims its name and is saved once")
        try check(Set(firstSaved.items) == firstSelection, "the snapshot holds exactly the chosen references")

        model.setSelected(laterSelection)
        try check(model.selected == laterSelection && Set(model.savedSelections[0].items) == firstSelection,
                  "changing the selection later never rewrites an existing snapshot")
        model.saveSelection(name: "Ad hoc", id: firstSaved.id)
        try check(model.savedSelections.count == 1 && model.savedSelections[0].id == firstSaved.id
                    && Set(model.savedSelections[0].items) == laterSelection
                    && model.savedSelections[0].updatedAt > firstSaved.updatedAt,
                  "saving with an existing id updates that one record")
        model.setSelected(firstSelection)
        model.saveSelection(name: "Reference material")
        try check(model.savedSelections.count == 2 && Set(model.savedSelections[1].items) == firstSelection
                    && Set(model.savedSelections[0].items) == laterSelection,
                  "a second name adds an independent snapshot beside the first")
        let adHocID = model.savedSelections[0].id, referenceID = model.savedSelections[1].id

        // 5. The selection survives a restart, and searching never changes it.
        let restarted = WorkbenchHistoryModel(directory: directory, now: clock)
        try check(restarted.error == nil && restarted.selected == firstSelection, "the current selection is the same after a restart")
        try check(restarted.savedSelections == model.savedSelections, "saved selections, names and times survive a restart unchanged")
        _ = restarted.matching(history, query: "Capture 3")
        _ = restarted.matching([], query: "")
        try check(restarted.selected == firstSelection, "searching and filtering never change the selection")
        restarted.loadSelection(adHocID)
        try check(restarted.selected == laterSelection && restarted.error == nil, "loading a saved selection restores its snapshot")
        restarted.loadSelection(referenceID)
        try check(restarted.selected == firstSelection, "loading the other snapshot restores its own references")
        restarted.loadSelection(UUID())
        try check(restarted.error != nil && restarted.selected == firstSelection,
                  "loading a selection that is gone reports it and changes nothing")

        // 6. Optional details, trimmed and de-duplicated, then search over them.
        var details = TranscriptMetadata()
        details.purpose = .meeting
        details.person = "  Dana Lopez "
        details.company = "Northwind "
        details.tags = ["Pilot", "pilot ", "   ", "renewal"]
        restarted.setMetadata(details, for: oldest.id)
        let stored = restarted.metadata(for: oldest.id)
        try check(restarted.error == nil && stored.purpose == .meeting && stored.person == "Dana Lopez" && stored.company == "Northwind",
                  "saved details are trimmed and kept with the capture")
        try check(stored.tags == ["Pilot", "renewal"], "blank tags are dropped and a repeated tag is kept once")
        let reopenedDetails = WorkbenchHistoryModel(directory: directory, now: clock)
        try check(reopenedDetails.error == nil && reopenedDetails.metadata(for: oldest.id) == stored
                    && reopenedDetails.metadata(for: newest.id) == TranscriptMetadata(),
                  "saved details survive a restart and no other capture gains any")

        let meeting = Transcript(id: oldest.id, date: oldest.date, text: "We agreed to run the pilot.", seconds: 4,
                                 rawText: "um we agreed to run the pilot", cleanupMethod: "Light")
        let ordinary = Transcript(id: newest.id, date: newest.date, text: "Remind me about the invoice.", seconds: 2)
        let searchable = [meeting, ordinary]
        try check(restarted.matching(searchable, query: "dana").map(\.id) == [meeting.id], "search finds a capture by the person on it")
        try check(restarted.matching(searchable, query: "NORTHWIND").map(\.id) == [meeting.id], "search finds a company without matching case")
        try check(restarted.matching(searchable, query: "renewal").map(\.id) == [meeting.id], "search finds a capture by one of its tags")
        try check(restarted.matching(searchable, query: "meeting").map(\.id) == [meeting.id], "search finds a capture by its purpose")
        try check(restarted.matching(searchable, query: "um we agreed").map(\.id) == [meeting.id], "search still finds the original recognised wording")
        try check(restarted.matching(searchable, query: "invoice").map(\.id) == [ordinary.id], "search still finds the cleaned wording")
        try check(restarted.matching(searchable, query: "dana pilot").map(\.id) == [meeting.id], "several terms match details and wording together")
        try check(restarted.matching(searchable, query: "dana invoice").isEmpty, "every term has to match something")
        try check(restarted.matching(searchable, query: "   ").map(\.id) == searchable.map(\.id), "clearing the search restores every capture")
        let found = restarted.matching(searchable, query: "dana").first
        try check(found?.text == meeting.text && found?.rawText == meeting.rawText && found?.cleanupMethod == "Light",
                  "search returns the capture with its cleaned and original wording untouched")

        // 7. References only, in one file, with no folder per selection.
        let bytes = try Data(contentsOf: restarted.store.url)
        let text = String(decoding: bytes, as: UTF8.self)
        try check(!text.contains("agreed to run the pilot") && !text.contains("um we agreed") && !text.contains("invoice"),
                  "the sidecar records references only, never transcript text")
        try check(text.contains("Dana Lopez") && text.contains("\"version\":1"),
                  "it does keep the details the person typed, under a format version")
        try check(fm.contentsOfDirectory(atPath: directory.path) == [WorkbenchHistoryStore.fileName],
                  "no extra folder or staging file is created for a selection")

        // 8. A reference whose capture is gone stays until it is removed on purpose.
        try check(restarted.selected.contains(missing) && restarted.savedSelections.contains { $0.items.contains(missing) },
                  "a missing reference stays visible in the selection and in its snapshot")
        restarted.removeReferences(kind: .transcript, ids: [])
        try check(restarted.selected.contains(missing), "an empty removal changes nothing")
        restarted.removeReferences(kind: .snap, ids: [missing.id])
        try check(restarted.selected.contains(missing), "removing a Snap & Talk id never touches a transcript reference")
        restarted.removeReferences(kind: .transcript, ids: [missing.id])
        try check(!restarted.selected.contains(missing) && !restarted.savedSelections.contains { $0.items.contains(missing) },
                  "deliberate removal clears that reference from the selection and every snapshot")
        try check(restarted.selected.contains(snapRef), "removing transcripts leaves the Snap & Talk reference selected")
        restarted.removeReferences(kind: .transcript, ids: [oldest.id])
        try check(restarted.metadata(for: oldest.id) == TranscriptMetadata(), "removing a capture removes the details saved for it")

        // 9. Bounded, validated input. A refusal keeps the existing library.
        let saveBefore = restarted.savedSelections
        for (name, reason) in [("   ", "without a name"), (String(repeating: "n", count: WorkbenchHistoryLibrary.maximumNameCharacters + 1), "with an unusable length"),
                               ("Line\nbreak", "with a line break")] {
            restarted.saveSelection(name: name)
            try check(restarted.error != nil && restarted.savedSelections == saveBefore, "a selection \(reason) is refused and the library is unchanged")
        }
        restarted.saveSelection(name: String(repeating: "n", count: WorkbenchHistoryLibrary.maximumNameCharacters))
        try check(restarted.error == nil && restarted.savedSelections.count == saveBefore.count + 1, "a name at the limit is accepted")
        restarted.removeSelection(restarted.savedSelections[restarted.savedSelections.count - 1].id)
        try check(restarted.error == nil && restarted.savedSelections == saveBefore, "removing a saved selection leaves the others alone")
        restarted.removeSelection(UUID())
        try check(restarted.error != nil && restarted.savedSelections == saveBefore, "removing a selection that is gone changes nothing")

        var tooManyTags = TranscriptMetadata()
        tooManyTags.tags = (0...WorkbenchHistoryLibrary.maximumTags).map { "tag\($0)" }
        let keptDetails = restarted.metadata(for: newest.id)
        restarted.setMetadata(tooManyTags, for: newest.id)
        try check(restarted.error != nil && restarted.metadata(for: newest.id) == keptDetails,
                  "more tags than the limit are refused and the earlier details stay")
        var longPerson = TranscriptMetadata()
        longPerson.person = String(repeating: "p", count: WorkbenchHistoryLibrary.maximumFieldCharacters + 1)
        restarted.setMetadata(longPerson, for: newest.id)
        try check(restarted.error != nil && restarted.metadata(for: newest.id) == keptDetails, "an unusable person field is refused")
        restarted.setMetadata(TranscriptMetadata(), for: newest.id)
        try check(restarted.error == nil && restarted.metadata(for: newest.id) == TranscriptMetadata(),
                  "clearing details returns that capture to the ordinary Prompt default")

        let beforeRefusals = try Data(contentsOf: restarted.store.url)
        var oversized = WorkbenchHistoryLibrary()
        oversized.savedSelections = (0...WorkbenchHistoryLibrary.maximumSelections).map {
            SavedWorkbenchSelection(id: UUID(), name: "Selection \($0)", items: [], updatedAt: tick)
        }
        try rejects("a library with more saved selections than the limit is refused before it is written") {
            _ = try restarted.store.save(oversized)
        }
        var duplicated = WorkbenchHistoryLibrary()
        let repeatedID = UUID()
        duplicated.savedSelections = [SavedWorkbenchSelection(id: repeatedID, name: "One", items: [], updatedAt: tick),
                                      SavedWorkbenchSelection(id: repeatedID, name: "Two", items: [], updatedAt: tick)]
        try rejects("a library whose saved selections share one identifier is refused") { _ = try restarted.store.save(duplicated) }
        try check(Data(contentsOf: restarted.store.url) == beforeRefusals, "a refused library never replaces the saved file")

        // 10. A failing write publishes nothing and claims nothing.
        let occupied = fixture.appendingPathComponent("Occupied by a file")
        let occupiedBytes = Data("a file, not a folder".utf8)
        try occupiedBytes.write(to: occupied)
        let failing = WorkbenchHistoryModel(directory: occupied.appendingPathComponent("Library", isDirectory: true), now: clock)
        try check(failing.error == nil && !failing.isBlocked, "a sidecar that was never written is not reported as damage")
        failing.setSelected([snapRef])
        try check(failing.error != nil && failing.selected.isEmpty, "a failed write reports the problem and publishes no selection")
        failing.saveSelection(name: "Cannot be saved")
        try check(failing.error?.contains("not saved") == true && failing.savedSelections.isEmpty,
                  "the failure says plainly that nothing was saved")
        try check(Data(contentsOf: occupied) == occupiedBytes, "the failed save changed nothing on disk")

        // 11. A damaged sidecar is kept exactly as found.
        let damagedDirectory = try makeDirectory("Damaged")
        let damagedURL = damagedDirectory.appendingPathComponent(WorkbenchHistoryStore.fileName)
        let damagedBytes = Data("{ not json".utf8)
        try damagedBytes.write(to: damagedURL)
        let damaged = WorkbenchHistoryModel(directory: damagedDirectory, now: clock)
        try check(damaged.isBlocked && damaged.error?.contains("kept") == true, "a damaged sidecar is reported and kept")
        try check(damaged.selected.isEmpty && damaged.savedSelections.isEmpty, "damaged state is never published as if it had been read")
        damaged.setSelected([snapRef])
        damaged.saveSelection(name: "Would overwrite")
        damaged.setMetadata(details, for: oldest.id)
        damaged.removeReferences(kind: .transcript, ids: [oldest.id])
        try check(Data(contentsOf: damagedURL) == damagedBytes, "no later change silently overwrites a damaged sidecar")
        try check(damaged.error != nil && damaged.selected.isEmpty && damaged.savedSelections.isEmpty,
                  "changes are refused while the damaged file is in place")

        // 12. A sidecar from a newer Workbench, including fields this version
        //     does not know, is preserved rather than rewritten.
        let futureDirectory = try makeDirectory("Future")
        let futureURL = futureDirectory.appendingPathComponent(WorkbenchHistoryStore.fileName)
        let futureBytes = Data("""
        {"version":99,"selected":[{"kind":"transcript","id":"\(oldest.id.uuidString)"}],"folders":[{"name":"Kept"}]}
        """.utf8)
        try futureBytes.write(to: futureURL)
        let future = WorkbenchHistoryModel(directory: futureDirectory, now: clock)
        try check(future.isBlocked && future.error?.contains("99") == true, "a sidecar from a newer version is identified by its format")
        try check(future.selected.isEmpty, "state in an unknown format is not published")
        future.setSelected([snapRef])
        future.saveSelection(name: "Would overwrite")
        try check(Data(contentsOf: futureURL) == futureBytes, "a newer sidecar and its unknown fields are preserved exactly")

        let reshapedDirectory = try makeDirectory("Reshaped")
        let reshapedURL = reshapedDirectory.appendingPathComponent(WorkbenchHistoryStore.fileName)
        let reshapedBytes = Data("{\"version\":100,\"selected\":\"everything\"}".utf8)
        try reshapedBytes.write(to: reshapedURL)
        let reshaped = WorkbenchHistoryModel(directory: reshapedDirectory, now: clock)
        try check(reshaped.isBlocked && reshaped.error?.contains("100") == true,
                  "a newer sidecar this version cannot even read is still reported as newer, not damaged")
        reshaped.setSelected([snapRef])
        try check(Data(contentsOf: reshapedURL) == reshapedBytes, "it is left exactly as the newer version wrote it")

        // 13. An implausibly large library is refused instead of loaded.
        let hugeDirectory = try makeDirectory("Huge")
        let hugeURL = hugeDirectory.appendingPathComponent(WorkbenchHistoryStore.fileName)
        let hugeBytes = Data(repeating: 0x20, count: WorkbenchHistoryStore.maximumBytes + 1)
        try hugeBytes.write(to: hugeURL)
        let huge = WorkbenchHistoryModel(directory: hugeDirectory, now: clock)
        try check(huge.isBlocked && huge.error?.contains("kept") == true, "an implausibly large library is refused instead of read")
        huge.setSelected([snapRef])
        try check(Data(contentsOf: hugeURL).count == hugeBytes.count, "the oversized file is left in place")

        // 14. After every refusal the real library is still readable and intact.
        let reopened = WorkbenchHistoryModel(directory: directory, now: clock)
        try check(reopened.error == nil && !reopened.isBlocked, "the working library is still readable")
        try check(reopened.selected == restarted.selected && reopened.savedSelections == restarted.savedSelections,
                  "the saved selection and its snapshots match the last accepted change")
        try check(reopened.metadata(for: oldest.id) == restarted.metadata(for: oldest.id)
                    && reopened.metadata(for: newest.id) == restarted.metadata(for: newest.id),
                  "saved capture details match the last accepted change")
        let concurrencyDirectory = try makeDirectory("Concurrent")
        let firstOwner = WorkbenchHistoryModel(directory: concurrencyDirectory, now: clock)
        let staleOwner = WorkbenchHistoryModel(directory: concurrencyDirectory, now: clock)
        var newDetails = TranscriptMetadata()
        newDetails.person = "Alex Example"
        firstOwner.setMetadata(newDetails, for: oldest.id)
        staleOwner.setSelected([snapRef])
        try check(staleOwner.error != nil && staleOwner.selected.isEmpty, "a stale owner cannot overwrite newer disk state")
        try check(WorkbenchHistoryModel(directory: concurrencyDirectory).metadata(for: oldest.id).person == "Alex Example",
                  "another owner's details survive a refused stale write")
        firstOwner.setSelected([snapRef])
        firstOwner.saveSelection(name: "Keep")
        let removedID = firstOwner.savedSelections[0].id
        firstOwner.removeSelection(removedID)
        let beforeStaleUpdate = try Data(contentsOf: firstOwner.store.url)
        firstOwner.saveSelection(name: "Stale update", id: removedID)
        try check(firstOwner.error != nil && firstOwner.savedSelections.isEmpty, "an explicit missing id cannot resurrect a removed selection")
        try check(Data(contentsOf: firstOwner.store.url) == beforeStaleUpdate, "stale selection edit preserves exact bytes")
        let named = WorkbenchHistoryModel(directory: try makeDirectory("Named"), now: clock)
        named.setSelected([snapRef]); named.saveSelection(name: "Stable overview")
        let stableID = named.savedSelections[0].id
        try check(named.activeSelectionID == stableID, "explicit save sets one active named identity")
        named.setSelected([snapRef, .init(kind: .transcript, id: oldest.id)])
        try check(named.activeSelectionID == nil, "changing membership becomes ad hoc until deliberate Update")
        named.saveSelection(name: "Updated overview", id: stableID)
        try check(named.activeSelectionID == stableID, "deliberate update keeps overview identity")
        let reloadedNamed = WorkbenchHistoryModel(directory: named.store.url.deletingLastPathComponent())
        try check(reloadedNamed.activeSelectionID == stableID, "named identity survives relaunch")
        named.removeSelection(stableID)
        try check(named.activeSelectionID == nil, "removing the saved selection clears its active identity")
        var warningMetadata = TranscriptMetadata(purpose: .meeting)
        warningMetadata.captureNotes = ["The selected app stopped producing audio."]
        warningMetadata.reviewedSuggestion = "Codex · synthetic receipt"
        named.setMetadata(warningMetadata, for: oldest.id)
        let notesReloaded = WorkbenchHistoryModel(directory: named.store.url.deletingLastPathComponent())
        try check(notesReloaded.metadata(for: oldest.id) == warningMetadata, "capture warning and reviewed provenance survive relaunch")

        // On-device suggestions: names must be in the words, and nothing typed is replaced.
        let spoken = "Thanks for joining, Priya. The Acme Health pilot starts on the fourteenth and Tom sends the agreement by Friday."
        try check(LocalDetailSuggestions.grounded(["Priya", "Tom", "Acme Health", "Jordan", "pilot", "Pilot", "agreement"], in: spoken)
                  == ["Priya", "Tom", "Acme Health"], "suggested names must appear capitalised in the transcript")
        let suggestion = LocalDetailSuggestions.Suggestion(people: ["Priya", "Tom"], companies: ["Acme Health"],
                                                           tags: ["pilot schedule", "data sharing"], source: "synthetic")
        let filled = LocalDetailSuggestions.merged(TranscriptMetadata(), with: suggestion)
        try check(filled.purpose == TranscriptMetadata().purpose && filled.person == "Priya, Tom" && filled.company == "Acme Health"
                  && filled.tags == ["pilot schedule", "data sharing"], "suggestions fill empty names and tags, never purpose")
        let typed = TranscriptMetadata(purpose: .note, person: "Sam", company: "", tags: ["Data sharing", "mine"])
        let kept = LocalDetailSuggestions.merged(typed, with: suggestion)
        try check(kept.purpose == .note && kept.person == "Sam" && kept.company == "Acme Health"
                  && kept.tags == ["Data sharing", "mine", "pilot schedule"], "suggestions never replace typed details or duplicate tags")
        try check((try? kept.validated()) != nil, "merged suggestions pass the saved-detail limits")
        return "WORKBENCH_HISTORY_CHECKS_OK: \(passed) checks"
    }
}
