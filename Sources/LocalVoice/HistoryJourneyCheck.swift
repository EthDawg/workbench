import AppKit
import Foundation

/// The acceptance journey in #137 at model level, for a run through the signed
/// Preview: a dictated transcript and an imported Snap are found by one
/// search, selected together and handed off with Copy instructions, which
/// leaves a Ready task rather than a result. History then lists all three,
/// with what the task was made from; a restart keeps them and the selection;
/// a task open at quit returns as Interrupted with Retry; and after the Snap
/// is archived and the transcript removed, the task keeps labelled frozen
/// copies. Every store lives in the given folder. Nothing uses the pointer,
/// the microphone, the screen, the clipboard or the person's own stores and
/// preferences.
enum HistoryJourneyCheck {
    @MainActor static func run(stores root: URL) async throws -> [String] {
        var lines: [String] = []
        func step(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw VoiceError.message("HISTORY_JOURNEY_FAILED: " + message) }
            lines.append("PASS " + message)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let voice = root.appendingPathComponent("LocalVoice"), snaps = root.appendingPathComponent("Snaps"),
            handoffs = root.appendingPathComponent("Handoffs")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let noSwitches: (read: (SubscriptionProvider) -> Bool, write: (SubscriptionProvider, Bool) -> Void) = ({ _ in false }, { _, _ in })
        func snapModel() -> SnapModel {
            SnapModel(store: SnapStore(root: snaps), desktop: root.appendingPathComponent("Desktop"),
                      trash: { _ in throw VoiceError.message("This check never moves a file to the Trash.") })
        }
        func waitForImageText(_ model: SnapModel, _ id: UUID) async {
            let deadline = Date().addingTimeInterval(60)
            while model.recognizedText[id] == nil && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
        }

        // 1. Dictate a line and Snap a synthetic error page.
        let state = StateStore(directory: voice)
        let dictated = Transcript(text: "Ask Matt why sign-in fails on staging", seconds: 3,
                                  rawText: "um ask Matt why sign in fails on staging")
        try state.save(SavedState(history: [dictated]))
        var transcripts = try state.load().history
        let library = WorkbenchHistoryModel(directory: voice)
        let snap = snapModel()
        let page = errorPage()
        try step(snap.saveDraft(SnapDraft(originalPNG: page, source: .imported, title: "Staging error", notes: "", tags: [], edit: .init()),
                                copyAfterSaving: false) && snap.items.count == 1, "an imported synthetic error page is saved as a Snap")
        let snapItem = snap.items[0]
        await waitForImageText(snap, snapItem.id)
        try step(snap.recognizedText[snapItem.id]?.localizedCaseInsensitiveContains("token expired") == true,
                 "Snap reads the text in the image on this Mac")

        // 2. One search finds both, each through its own matcher.
        let jobs = HandoffJobsModel(directory: handoffs, switches: noSwitches, pasteboard: pasteboard)
        func rows(_ filter: HistoryFilter = .all, _ query: String = "", transcripts: [Transcript], snap: SnapModel,
                  jobs: HandoffJobsModel, library: WorkbenchHistoryModel) -> [HistoryEntry.ID] {
            HistoryList.entries(transcripts: transcripts, snaps: snap.items, results: jobs.visibleJobs, filter: filter, query: query,
                matchTranscripts: { library.matching($0, query: $1) }, matchSnap: { snap.matches($0, query: $1) },
                resultText: { jobs.files($0)?.inputs.task ?? "" }).map(\.id)
        }
        try step(Set(rows(.all, "sign", transcripts: transcripts, snap: snap, jobs: jobs, library: library))
                    == [.transcript(dictated.id), .snap(snapItem.id)], "one search for sign finds the dictation and the Snap")
        try step(rows(.all, "token expired", transcripts: transcripts, snap: snap, jobs: jobs, library: library) == [.snap(snapItem.id)],
                 "the Snap is found by the words in its image")

        // 3. Select both, then Hand off with Copy instructions.
        let selection: Set<WorkbenchItemReference> = [.init(kind: .transcript, id: dictated.id), .init(kind: .snap, id: snapItem.id)]
        library.setSelected(selection)
        try step(library.selected == selection && library.error == nil, "both are selected in the shared selection")
        let resolveSnaps: (Set<WorkbenchItemReference>) throws -> [HandoffSourceSnapshot] = { references in
            try snap.handoffSnapshots(ids: Set(references.map(\.id))).map(\.reviewedHandoffSource)
        }
        let sources = try AppModel.handoffSources(selected: library.selected, history: transcripts, library: library, additional: resolveSnaps)
        let skill = TranscriptHandoffSkill.followUp
        let task = skill.defaultTask ?? "Prepare a clear follow-up."
        var revealed: [UUID] = []
        try jobs.handOff(sources: sources, task: task, skill: skill.load(), provider: nil) { revealed.append($0) }
        guard let prepared = revealed.first, let job = jobs.jobs.first(where: { $0.id == prepared }) else {
            throw VoiceError.message("HISTORY_JOURNEY_FAILED: Hand off reported no task. " + (jobs.error ?? ""))
        }
        try step(job.status == .ready && jobs.result(job) == nil, "Copy instructions leaves a Ready task, not a result")
        try step(pasteboard.string(forType: .string)?.contains(dictated.text) == true, "the instructions carry the dictated words")
        try step(HistoryList.revealTarget(prepared, jobs: jobs.jobs, visible: jobs.visibleJobs).map { [$0.card, $0.task] } == [prepared, prepared],
                 "History reveals the task Hand off prepared")
        try jobs.handOff(sources: sources, task: task, skill: skill.load(), provider: nil) { revealed.append($0) }
        try step(revealed == [prepared, prepared] && jobs.jobs.count == 1, "handing off the same items again reveals the same task")

        // 4. History lists all three, and the task shows what it was made from.
        await jobs.loadTaskFiles(jobs.jobs)
        try step(Set(rows(transcripts: transcripts, snap: snap, jobs: jobs, library: library))
                    == [.transcript(dictated.id), .snap(snapItem.id), .result(prepared)], "History lists the dictation, the Snap and the task")
        func madeFrom(_ jobs: HandoffJobsModel, transcripts: [Transcript], snap: SnapModel) -> [(String, HistoryInputAvailability)] {
            let items = jobs.files(job)?.inputs.items ?? []
            let snapsByID = Dictionary(uniqueKeysWithValues: snap.items.map { ($0.id, $0) })
            return items.map { ($0.title, HistoryList.availability(of: $0.reference, transcripts: Set(transcripts.map(\.id)), snaps: snapsByID)) }
        }
        let before = madeFrom(jobs, transcripts: transcripts, snap: snap)
        try step(before.count == 2 && before.allSatisfy { $0.1 == .inHistory } && before.contains { $0.0 == "Staging error" },
                 "Made from lists both inputs, still in History")

        // 5. Restart: every store is read again from disk.
        transcripts = try StateStore(directory: voice).load().history
        let relaunchedLibrary = WorkbenchHistoryModel(directory: voice)
        let relaunchedSnap = snapModel()
        let relaunchedJobs = HandoffJobsModel(directory: handoffs, switches: noSwitches, pasteboard: pasteboard)
        await relaunchedJobs.loadTaskFiles(relaunchedJobs.jobs)
        try step(transcripts.map(\.id) == [dictated.id] && relaunchedSnap.items.map(\.id) == [snapItem.id]
                    && relaunchedJobs.jobs.map(\.id) == [prepared] && relaunchedJobs.jobs[0].status == .ready,
                 "after a restart the same transcript, Snap and Ready task are there")
        try step(relaunchedLibrary.selected == selection, "after a restart the same two items are selected")
        try step(madeFrom(relaunchedJobs, transcripts: transcripts, snap: relaunchedSnap).map(\.0) == before.map(\.0),
                 "after a restart the task still shows both inputs")

        // 6. A task running at quit returns as Interrupted, with Retry.
        let second = try relaunchedJobs.prepare(sources: [sources[0]], task: "Sharpen this prompt.", skill: skill.load())
        var running = second; running.status = .running; running.detail = "Running."
        try HandoffJobStore.write(HandoffJobStore.encode(running), to: relaunchedJobs.folder(second).appendingPathComponent("receipt.json"))
        let afterQuit = HandoffJobsModel(directory: handoffs, switches: noSwitches, pasteboard: pasteboard)
        let interrupted = afterQuit.jobs.first(where: { $0.id == second.id })
        try step(interrupted?.status == .interrupted && interrupted?.detail.contains("Review the provider receipt") == true && !afterQuit.isBusy,
                 "a task running at quit returns as Interrupted with its explanation, and nothing restarts on its own")
        try step([.failed, .cancelled, .interrupted].contains(interrupted?.status ?? .ready), "Interrupted offers Retry")

        // 7. Archive the Snap and remove the transcript: the task keeps labelled copies.
        relaunchedSnap.archive([snapItem.id], archived: true)
        try StateStore(directory: voice).save(SavedState(history: []))
        transcripts = try StateStore(directory: voice).load().history
        await afterQuit.loadTaskFiles(afterQuit.jobs)
        let after = afterQuit.files(job)?.inputs.items ?? []
        let snapsNow = Dictionary(uniqueKeysWithValues: relaunchedSnap.items.map { ($0.id, $0) })
        let labels = after.map { HistoryList.availability(of: $0.reference, transcripts: Set(transcripts.map(\.id)), snaps: snapsNow) }
        try step(Set(labels) == [.removed, .archived] && labels.allSatisfy { $0.label?.contains("saved copy kept") == true },
                 "the removed transcript and the archived Snap are labelled, saved copies kept")
        try step(after.first(where: { $0.reference.kind == .transcript })?.text == dictated.text,
                 "the frozen transcript keeps the dictated words")
        let frozenImage = after.first(where: { $0.reference.kind == .snap })?.images.first
        try step(try frozenImage.flatMap { afterQuit.inputImageURL(job, path: $0) }.map { try Data(contentsOf: $0) } == page,
                 "the frozen Snap image is the saved image")
        try step(rows(.archived, transcripts: transcripts, snap: relaunchedSnap, jobs: afterQuit, library: relaunchedLibrary) == [.snap(snapItem.id)],
                 "Archived shows the archived Snap")
        lines.append("HISTORY_JOURNEY_OK: \(lines.count) steps")
        return lines
    }

    /// A synthetic sign-in error page: a red banner and one line of text.
    private static func errorPage() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1_200, pixelsHigh: 700, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1_200, height: 700).fill()
        NSColor.systemRed.setFill(); NSRect(x: 0, y: 560, width: 1_200, height: 140).fill()
        ("Sign-in failed" as NSString).draw(at: NSPoint(x: 60, y: 600), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 56), .foregroundColor: NSColor.white])
        ("Your session token expired. Sign in again." as NSString).draw(at: NSPoint(x: 60, y: 380),
            withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}
