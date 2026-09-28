import Foundation

/// Synthetic checks for the History page's list: the merge, kind filters and
/// search over transcripts, Snaps and Hand off tasks, the selection notes and
/// the labels on a task's frozen inputs. Every store lives in a temporary
/// folder; no saved history, preference, clipboard, Vision pass or provider is used.
enum HistoryChecks {
    @MainActor
    static func run() async throws {
        var passed = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw VoiceError.message("HISTORY_CHECK_FAILED: \(name)") }
            passed += 1
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Workbench-history-page-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let suite = "Workbench.synthetic.history-page." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw VoiceError.message("Could not create isolated test preferences.") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

        // Transcripts, with their details in an isolated library.
        let library = WorkbenchHistoryModel(directory: root.appendingPathComponent("LocalVoice"))
        let prompt = Transcript(date: at(2), text: "Ask Matt why sign-in fails on staging", seconds: 3,
                                rawText: "um ask Matt why sign in fails on staging")
        let meeting = Transcript(date: at(0), text: "We agreed to ship the pilot on Friday.", seconds: 40)
        library.setMetadata(TranscriptMetadata(purpose: .meeting, person: "Avery Example", company: "Example Company"), for: meeting.id)
        try check(library.error == nil, "synthetic transcript details save")
        var transcripts = [prompt, meeting]

        // Snaps in a synthetic store. Their image text is saved beside them as
        // Vision would leave it, so SnapModel's own search reads it.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==")!
        let store = SnapStore(root: root.appendingPathComponent("Snaps"))
        let errorPage = try store.insert(originalPNG: png, width: 1, height: 1, title: "Staging screen", source: .region, createdAt: at(3))
        let dashboard = try store.insert(originalPNG: png, width: 1, height: 1, title: "Dashboard", source: .window, tags: ["metrics"], createdAt: at(1))
        let pricing = try store.insert(originalPNG: png, width: 1, height: 1, title: "Old pricing page", source: .screen, createdAt: at(-5))
        try store.setArchived(true, ids: [pricing.id])
        for (item, text) in [(errorPage, "Sign-in failed: token expired"), (dashboard, "Weekly active users"), (pricing, "Pricing tiers")] {
            try store.writeDerived(SnapDerivedData(imageSHA256: item.imageSHA256, text: text, featurePrint: nil), for: item.id)
        }
        let snap = SnapModel(store: store, desktop: root.appendingPathComponent("Desktop"),
                             trash: { _ in throw VoiceError.message("This check never moves a file to the Trash.") })
        let deadline = Date().addingTimeInterval(20)
        while snap.recognizedText.count < 3 && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(snap.recognizedText.count == 3 && snap.items.count == 3, "each Snap's saved image text is loaded for search")

        // A Hand off task made from the prompt and the error Snap.
        let jobs = HandoffJobsModel(directory: root.appendingPathComponent("Handoffs"), defaults: defaults)
        let skill = try TranscriptHandoffSkills.followUpSnapshot()
        let sources = [
            HandoffSourceSnapshot(reference: .init(kind: .transcript, id: prompt.id), title: "Prompt · sign-in", capturedAt: prompt.date,
                text: prompt.text, originalText: prompt.rawText!, role: .instructions),
            HandoffSourceSnapshot(reference: .init(kind: .snap, id: errorPage.id), title: errorPage.title, capturedAt: errorPage.createdAt,
                text: "", originalText: "", role: .reference, images: [png])
        ]
        let task = try jobs.prepare(sources: sources, task: "Draft a follow-up for Matt about the staging outage.", skill: skill)

        func list(_ filter: HistoryFilter, _ query: String = "") -> [HistoryEntry.ID] {
            HistoryList.entries(transcripts: transcripts, snaps: snap.items, results: jobs.visibleJobs, filter: filter, query: query,
                matchTranscripts: { library.matching($0, query: $1) }, matchSnap: { snap.matches($0, query: $1) },
                resultText: { jobs.inputs($0).task }).map(\.id)
        }
        try check(list(.all) == [.result(task.id), .snap(errorPage.id), .transcript(prompt.id), .snap(dashboard.id), .transcript(meeting.id)],
                  "All merges results, active Snaps and transcripts newest first and leaves archived Snaps out")
        try check(list(.transcripts) == [.transcript(prompt.id), .transcript(meeting.id)], "Transcripts shows only transcripts")
        try check(list(.snaps) == [.snap(errorPage.id), .snap(dashboard.id)], "Snaps shows only active Snaps")
        try check(list(.results) == [.result(task.id)], "Results shows only Hand off tasks")
        try check(list(.archived) == [.snap(pricing.id)], "Archived shows the archived Snap")

        // One search, each kind through its own matcher.
        try check(list(.all, "sign") == [.snap(errorPage.id), .transcript(prompt.id)],
                  "one search finds a dictation by its words and a Snap by the text in its image")
        try check(list(.all, "token expired") == [.snap(errorPage.id)], "every term must match, image text included")
        try check(list(.all, "Avery") == [.transcript(meeting.id)], "transcripts match their saved details")
        try check(list(.transcripts, "um") == [.transcript(prompt.id)], "transcripts match their original wording")
        try check(list(.all, "metrics") == [.snap(dashboard.id)], "Snaps match their tags")
        try check(list(.all, "Matt outage") == [.result(task.id)], "results match their task text from selection.json")
        try check(list(.results, "follow-up") == [.result(task.id)], "results match their title")
        try check(list(.archived, "pricing tiers") == [.snap(pricing.id)] && list(.snaps, "pricing").isEmpty,
                  "archived Snaps are searched only under Archived")
        try check(list(.all, "nothing-matches-this").isEmpty, "a search can find nothing")

        var tiedJob = task; tiedJob.createdAt = at(10)
        var tiedSnap = dashboard; tiedSnap.createdAt = at(10)
        let tiedTranscript = Transcript(date: at(10), text: "Tied", seconds: 1)
        let tied = HistoryList.entries(transcripts: [tiedTranscript], snaps: [tiedSnap], results: [tiedJob], filter: .all, query: "",
            matchTranscripts: { items, _ in items }, matchSnap: { _, _ in true }, resultText: { _ in "" }).map(\.id)
        try check(tied == [.result(task.id), .snap(dashboard.id), .transcript(tiedTranscript.id)], "equal times keep one order")

        // Filters and searches never change the selection; the footer explains
        // what the view does not show.
        let goneTranscript = UUID(), goneSnap = UUID(), session = UUID()
        library.setSelected([.init(kind: .transcript, id: prompt.id), .init(kind: .transcript, id: meeting.id),
                             .init(kind: .snap, id: errorPage.id), .init(kind: .snap, id: pricing.id),
                             .init(kind: .transcript, id: goneTranscript), .init(kind: .snap, id: goneSnap),
                             .init(kind: .snapAndTalk, id: session)])
        let selected = library.selected
        let snapsByID = Dictionary(uniqueKeysWithValues: snap.items.map { ($0.id, $0) })
        func notes(_ filter: HistoryFilter, _ query: String = "") -> HistoryList.SelectionNotes {
            HistoryList.selectionNotes(selected: library.selected, shown: Set(list(filter, query)),
                                       transcripts: Set(transcripts.map(\.id)), snaps: snapsByID)
        }
        let all = notes(.all)
        try check(all.hidden == 0 && all.archivedSnaps == [pricing.id] && all.missingTranscripts == [goneTranscript]
                  && all.unavailable == [.init(kind: .snap, id: goneSnap), .init(kind: .snapAndTalk, id: session)],
                  "archived, removed and unavailable selections are told apart")
        try check(notes(.results).hidden == 3 && notes(.all, "sign").hidden == 1 && notes(.archived).archivedSnaps == [pricing.id],
                  "items hidden by a filter or search are counted, and archived stays archived under Archived")
        for filter in HistoryFilter.allCases { _ = list(filter, "sign"); _ = notes(filter) }
        try check(library.selected == selected && library.error == nil, "filters and searches never change the selection")

        // A task keeps labelled frozen copies after its items leave History.
        let frozen = jobs.inputs(task)
        try check(frozen.problem == nil && frozen.items.map(\.title) == ["Prompt · sign-in", "Staging screen"],
                  "a task is made from its frozen inputs")
        func labels() -> [HistoryInputAvailability] {
            let snapsNow = Dictionary(uniqueKeysWithValues: snap.items.map { ($0.id, $0) })
            return frozen.items.map { HistoryList.availability(of: $0.reference, transcripts: Set(transcripts.map(\.id)), snaps: snapsNow) }
        }
        try check(labels() == [.inHistory, .inHistory] && HistoryInputAvailability.inHistory.label == nil, "live inputs carry no warning")
        snap.archive([errorPage.id], archived: true)
        transcripts.removeAll { $0.id == prompt.id }
        try check(labels() == [.removed, .archived], "a removed transcript and an archived Snap are labelled as such")
        try check(jobs.inputs(task) == frozen && jobs.inputImageURL(task, path: frozen.items[1].images[0]) != nil,
                  "their frozen copies stay readable")
        try check(HistoryList.availability(of: .init(kind: .snap, id: UUID()), transcripts: [], snaps: [:]) == .missing
                  && HistoryList.availability(of: .init(kind: .snapAndTalk, id: UUID()), transcripts: [], snaps: [:]) == .notInHistory,
                  "a vanished Snap is missing and Snap & Talk evidence says where it came from")
        try check([HistoryInputAvailability.archived, .removed, .missing, .notInHistory].allSatisfy { $0.label?.contains("saved copy kept") == true },
                  "every unavailable input says its saved copy is kept")

        // Tasks grouped under one Snap review appear once, as they did on Handoffs.
        let reviewSnap = try store.insert(originalPNG: png, width: 1, height: 1, title: "Review source", source: .region)
        let reviewSource = HandoffSourceSnapshot(reference: .init(kind: .snap, id: reviewSnap.id), title: reviewSnap.title,
            capturedAt: reviewSnap.createdAt, text: "First note", originalText: "First note", role: .reference, images: [png])
        let context = try SnapOrganization.context(store: store, ids: [reviewSnap.id], selectionID: nil, title: "Synthetic review")
        let firstReview = try jobs.prepare(sources: [reviewSource], task: SnapOrganization.assistantInstruction, skill: skill, review: context)
        var changed = reviewSource; changed.text = "Second note"
        let secondReview = try jobs.prepare(sources: [changed], task: SnapOrganization.assistantInstruction, skill: skill, review: context)
        try check(firstReview.id != secondReview.id && list(.results) == [.result(secondReview.id), .result(task.id)],
                  "tasks for one review are listed once, newest first")

        // A large synthetic library: the list is rebuilt as a search is typed.
        let many = (0..<5_000).map { Transcript(date: base.addingTimeInterval(Double($0)), text: "Synthetic capture \($0) about release \($0 % 40)", seconds: 2) }
        let manySnaps = (0..<1_500).map { index in
            SnapItem(id: UUID(), createdAt: base.addingTimeInterval(Double(index) * 3), updatedAt: base, title: "Screen \(index)",
                     tags: ["release"], source: .region, pixelWidth: 1, pixelHeight: 1,
                     originalSHA256: String(repeating: "a", count: 64), imageSHA256: String(repeating: "a", count: 64))
        }
        let started = Date()
        var shown = 0
        for query in ["", "r", "re", "release", "release 7", "screen 99"] {
            shown += HistoryList.entries(transcripts: many, snaps: manySnaps, results: jobs.visibleJobs, filter: .all, query: query,
                matchTranscripts: { library.matching($0, query: $1) }, matchSnap: { snap.matches($0, query: $1) },
                resultText: { jobs.inputs($0).task }).count
        }
        let average = Date().timeIntervalSince(started) / 6
        try check(shown > 0 && average < 0.5, "6,500 items are merged, filtered and searched in under half a second per keystroke")
        print("HISTORY_LIST_TIMING: \(Int((average * 1_000).rounded())) ms per rebuild of 5,000 transcripts, 1,500 Snaps and \(jobs.visibleJobs.count) tasks")
        print("HISTORY_PAGE_CHECKS_OK: \(passed) checks")
    }
}
