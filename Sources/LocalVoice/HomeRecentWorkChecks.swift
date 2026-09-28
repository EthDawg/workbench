import Foundation

/// Home's Recent work is History All's newest five (#134 H1). Six synthetic transcripts are
/// interleaved with Snaps and Hand off tasks, with two items at the same time, an archived
/// Snap, a removed transcript, retries grouped under one review and days-old iPhone photos.
/// Home used to take one item of each kind and date photos by the clock, so an old photo led
/// and newer dictations were left out; photos are Library's and never enter this list.
/// Nothing is rendered.
enum HomeRecentWorkChecks {
    @MainActor static func run() throws {
        var passed = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("HOME_RECENT_WORK_CHECK_FAILED: \(name)") }
            passed += 1
        }
        let base = Date(timeIntervalSince1970: 1_789_000_000)
        func transcript(_ offset: TimeInterval, _ text: String) -> Transcript {
            Transcript(date: base.addingTimeInterval(offset), text: text, seconds: 2)
        }
        func snap(_ offset: TimeInterval, _ title: String, archived: Bool = false) -> SnapItem {
            SnapItem(id: UUID(), createdAt: base.addingTimeInterval(offset), updatedAt: base.addingTimeInterval(offset), title: title,
                     source: .region, pixelWidth: 10, pixelHeight: 10, originalSHA256: "synthetic", imageSHA256: "synthetic",
                     archivedAt: archived ? base.addingTimeInterval(offset + 1) : nil)
        }
        func job(_ offset: TimeInterval, _ title: String, review: String? = nil, status: HandoffJobStatus = .completed) -> HandoffJob {
            HandoffJob(id: UUID(), createdAt: base.addingTimeInterval(offset), updatedAt: base.addingTimeInterval(offset + 9_000), title: title,
                       fingerprint: title, provider: nil, providerSessionID: nil, status: status, detail: "", attempts: 1, itemCount: 1,
                       inputFiles: [], inputDigest: title, supportsConnectedText: false, reviewKey: review)
        }
        // Six transcripts; one more was removed from History and must not come back.
        let t1 = transcript(600, "Book the quiet room"), t2 = transcript(500, "Send Sam the agenda"), t3 = transcript(400, "Ask about pricing")
        let t4 = transcript(300, "Check the build"), t5 = transcript(200, "Call the venue"), t6 = transcript(100, "Plan Thursday")
        let removed = transcript(800, "Removed from History")
        let transcripts = [t1, t2, t3, t4, t5, t6]
        // A Snap between t1 and t2, one at exactly t3's time, and a newer one that is archived.
        let visibleSnap = snap(550, "Pricing table"), sameTime = snap(400, "Onboarding checklist"), archived = snap(700, "Archived error", archived: true)
        let snaps = [archived, visibleSnap, sameTime]
        // A review retried: the newer task stands for the review and the older retry is grouped
        // inside it, even though its time would place it among the five. Its update times are
        // later than everything else and move nothing.
        let retry = job(450, "Prepare follow-up", review: "review-1"), groupedRetry = job(350, "Prepare follow-up", review: "review-1", status: .failed)
        let old = job(50, "Old summary")
        let jobs = HandoffJobsModel.visible([retry, groupedRetry, old])
        try check(jobs.map(\.id) == [retry.id, old.id], "History's grouped results stand one task for a retried review")

        let cache = HistoryRowsCache()
        var reads = 0
        func counted<T>(_ value: T) -> T { reads += 1; return value }
        let newest = HomeRecentWork.newest(cache, revision: 1, transcripts: counted(transcripts), snaps: counted(snaps), results: counted(jobs))
        let expected: [HistoryEntry.ID] = [.transcript(t1.id), .snap(visibleSnap.id), .transcript(t2.id), .result(retry.id), .snap(sameTime.id)]
        try check(newest.map(\.id) == expected, "Recent work is the five newest: \(newest.map(\.id))")
        let historyAll = HistoryList.shown(HistoryList.merged(transcripts: transcripts, snaps: snaps, results: jobs), filter: .all, query: "",
                                           matchTranscripts: { list, _ in list }, matchSnap: { _, _ in true }, resultText: { _ in "" })
        try check(newest.map(\.id) == Array(historyAll.prefix(5)).map(\.id), "Recent work is exactly History All's first five")
        try check(newest.firstIndex { $0.id == .snap(sameTime.id) } ?? 9 < historyAll.firstIndex { $0.id == .transcript(t3.id) } ?? 0,
                  "two items at the same time keep History's order: the Snap, then the transcript")
        try check(!newest.contains { $0.id == .snap(archived.id) || $0.id == .transcript(removed.id) || $0.id == .result(groupedRetry.id) },
                  "an archived Snap, a removed transcript and a grouped retry stay out")
        try check(newest.allSatisfy { $0.date <= base.addingTimeInterval(600) }, "nothing is dated by the clock, as a photo once was")

        // Photos saved from iPhone days before any of these are Library's: not Recent work, which
        // takes no photos at all, and Home's link names their stored date, never the clock's.
        let daysOld = base.addingTimeInterval(-4 * 86_400), older = base.addingTimeInterval(-9 * 86_400)
        let saved = HomeRecentWork.savedFromIPhone([older, daysOld])
        try check(saved == "Saved from iPhone · 2 photos · newest " + daysOld.formatted(date: .abbreviated, time: .shortened),
                  "the iPhone link gives the count and the newest photo's stored date: \(saved ?? "none")")
        try check(HomeRecentWork.savedFromIPhone([daysOld])?.contains("· 1 photo ·") == true && HomeRecentWork.savedFromIPhone([]) == nil,
                  "one photo reads as one, and no photos add no link")
        try check(!(saved ?? "").split(separator: " ").contains("new"), "the link never calls the photos new")

        // A redraw with the same stores reads nothing and sorts nothing again (#150).
        reads = 0
        let newer = transcript(900, "A newer dictation")
        let redrawn = HomeRecentWork.newest(cache, revision: 1, transcripts: counted([newer] + transcripts), snaps: counted(snaps), results: counted(jobs))
        try check(reads == 0 && redrawn.map(\.id) == expected, "a redraw with unchanged stores does not rebuild the list")
        let changed = HomeRecentWork.newest(cache, revision: 2, transcripts: counted([newer] + transcripts), snaps: counted(snaps), results: counted(jobs))
        try check(reads == 3 && changed.map(\.id) == [.transcript(newer.id)] + expected.prefix(4), "a store change rebuilds it, newest first")

        // Each row reviews its exact item without selecting it or opening it in Dictate.
        let transcriptDoor = HomeRecentWork.review(for: .transcript(t2))
        try check(transcriptDoor?.transcript == t2.id && transcriptDoor?.job == nil && transcriptDoor?.filter == .all,
                  "a transcript opens History on All, showing that transcript")
        let resultDoor = HomeRecentWork.review(for: .result(retry))
        try check(resultDoor?.job == retry.id && resultDoor?.transcript == nil, "a result opens its History detail")
        try check(HomeRecentWork.review(for: .snap(visibleSnap)) == nil, "a Snap opens its own preview, not History")
        print("HOME_RECENT_WORK_CHECKS_OK: \(passed) checks; History All's newest five, grouped results, equal times, days-old photos and no redraw rebuild")
    }
}
