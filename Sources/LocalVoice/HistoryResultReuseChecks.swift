import AppKit
import Foundation

/// Synthetic saved results and a private pasteboard; no provider, live History,
/// playback or global shortcut is involved.
enum HistoryResultReuseChecks {
    private actor ReadGate {
        private var held = false
        private var continuation: CheckedContinuation<Void, Never>?
        func holdFirst() async {
            guard !held else { return }
            held = true
            await withCheckedContinuation { continuation = $0 }
        }
        func hasStarted() -> Bool { held }
        func release() { continuation?.resume(); continuation = nil }
    }

    @MainActor static func run(root: URL) async throws -> Int {
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw VoiceError.message("RESULT_REUSE_CHECK_FAILED: " + message) }
            count += 1
        }
        let fm = FileManager.default
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let switches: (read: (SubscriptionProvider) -> Bool, write: (SubscriptionProvider, Bool) -> Void) = ({ _ in false }, { _, _ in })
        let preparing = HandoffJobsModel(directory: root, switches: switches, pasteboard: board)
        let source = HandoffSourceSnapshot(reference: .init(kind: .transcript, id: UUID()), title: "Synthetic notes",
            capturedAt: Date(timeIntervalSince1970: 10), text: "Source words", originalText: "Source words", role: .reference)
        let skill = try TranscriptHandoffSkills.followUpSnapshot()
        var older = try preparing.prepare(sources: [source], task: "Summarize the meeting.", skill: skill)
        var newer = try preparing.prepare(sources: [source], task: "Prepare next steps.", skill: skill)
        older.reviewKey = "synthetic-review"; newer.reviewKey = older.reviewKey
        older.status = .completed; newer.status = .completed
        older.createdAt = Date(timeIntervalSince1970: 20); newer.createdAt = Date(timeIntervalSince1970: 30)
        for job in [older, newer] {
            try HandoffJobStore.write(HandoffJobStore.encode(job), to: preparing.folder(job).appendingPathComponent("receipt.json"))
        }
        let exact = "  # Synthetic result\r\n\r\nUnique sapphire phrase. Café 👋\n  "
        let resultURL = preparing.folder(older).appendingPathComponent("result.md")
        try HandoffJobStore.write(Data(exact.utf8), to: resultURL)
        try HandoffJobStore.write(Data("Newest amber response.".utf8), to: preparing.folder(newer).appendingPathComponent("result.md"))
        let jobs = HandoffJobsModel(directory: root, switches: switches, pasteboard: board)
        try check(jobs.files(older) == nil, "the cache starts without synchronous result reads")
        await jobs.loadTaskFiles(jobs.jobs)
        try check(jobs.files(older)?.resultText == exact && jobs.files(older)?.resultReadable == true,
                  "bounded UTF-8 results preserve whitespace, line endings and Unicode")
        try check(jobs.matchesResult(newer, query: "sapphire café") && !jobs.matchesResult(newer, query: "sapphire café", includingGrouped: false),
                  "an earlier result matches its parent card without claiming the current result matched")
        try check(!jobs.matchesResult(newer, query: "sapphire amber"), "search terms cannot combine words from different grouped tasks")
        let rows = HistoryList.entries(transcripts: [], snaps: [], results: jobs.visibleJobs, filter: .results, query: "sapphire",
            matchTranscripts: { items, _ in items }, matchSnap: { _, _ in false }, resultText: { jobs.files($0)?.inputs.task ?? "" },
            matchResult: { jobs.matchesResult($0, query: $1) })
        try check(rows.map(\.id) == [.result(newer.id)], "a grouped content match appears once in History Results")

        let reviewed = jobs.files(older)!.resultText!
        try HandoffJobStore.write(Data("Externally edited jade result.".utf8), to: resultURL)
        let receipt = ClipboardReceiptModel(clipboardChangeCount: { board.changeCount }, automaticallySchedules: false)
        let copied = HistoryResultReuse.copy(reviewed, jobID: older.id, receipts: receipt, pasteboard: board)
        try check(board.string(forType: .string) == exact && copied.failure == nil && !copied.wasPasted && !copied.pasteWasAttempted,
                  "Copy result uses the exact reviewed value despite a later external edit, without pasting")
        try check(receipt.receipt?.source == .result(older.id) && receipt.receipt?.title == "Copied" && receipt.receipt?.canSuggestPaste == true,
                  "Copy result issues the existing receipt with the exact result identity")
        await jobs.loadTaskFiles(jobs.jobs)
        try check(jobs.files(older)?.resultText == "Externally edited jade result."
                  && jobs.matchesResult(newer, query: "jade") && !jobs.matchesResult(newer, query: "sapphire"),
                  "activation reload updates visible text and search without a receipt timestamp change")
        try fm.removeItem(at: resultURL)
        await jobs.loadTaskFiles(jobs.jobs)
        try check(jobs.files(older)?.resultText == nil && jobs.files(older)?.resultReadable == false
                  && !jobs.matchesResult(newer, query: "jade"), "removing a result removes its cached words and reuse availability")
        for bytes in [Data([0xFF, 0xFE]), Data("nul\u{0000}text".utf8), Data(repeating: 65, count: HandoffResultFile.maximumBytes + 1)] {
            try HandoffJobStore.write(bytes, to: resultURL)
            await jobs.loadTaskFiles([older])
            try check(jobs.files(older)?.resultText == nil && jobs.files(older)?.resultReadable == false
                      && jobs.files(older)?.resultProblem != nil, "invalid or oversized text is unavailable with a reason")
        }
        try check(jobs.files(older)?.resultProblem?.contains("2 MB") == true, "oversized results explain their limit")
        try fm.removeItem(at: resultURL)
        let target = root.appendingPathComponent("outside.md")
        try HandoffJobStore.write(Data("Must not read through a link.".utf8), to: target)
        try fm.createSymbolicLink(at: resultURL, withDestinationURL: target)
        await jobs.loadTaskFiles([older])
        try check(jobs.files(older)?.resultText == nil, "a replacement symlink is never read")
        try fm.removeItem(at: resultURL)
        try HandoffJobStore.write(Data(exact.utf8), to: resultURL)
        await jobs.loadTaskFiles([older])
        try check(jobs.files(older)?.resultText == exact, "an ordinary replacement result becomes available again")

        // Hold one read after it captured old text; a newer activation finishes
        // first. Releasing or cancelling the older request cannot erase it.
        for cancelled in [false, true] {
            let gate = ReadGate()
            jobs.taskFileReader = { job, directory, folder in
                let files = HandoffTaskFiles.read(job, directory: directory, folder: folder)
                await gate.holdFirst()
                return files
            }
            try HandoffJobStore.write(Data("Before overlapping activation.".utf8), to: resultURL)
            let first = Task { await jobs.loadTaskFiles([older]) }
            let deadline = Date().addingTimeInterval(5)
            while !(await gate.hasStarted()) && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
            guard await gate.hasStarted() else { first.cancel(); throw VoiceError.message("Result read did not reach its synthetic gate.") }
            try HandoffJobStore.write(Data("Newest activation stays visible.".utf8), to: resultURL)
            await jobs.loadTaskFiles([older])
            if cancelled { first.cancel() }
            await gate.release()
            await first.value
            try check(jobs.files(older)?.resultText == "Newest activation stays visible.",
                      "a late or cancelled read cannot replace the newest cached result")
        }
        jobs.taskFileReader = { HandoffTaskFiles.read($0, directory: $1, folder: $2) }
        return count
    }
}
