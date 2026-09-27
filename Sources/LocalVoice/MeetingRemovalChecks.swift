import Foundation

/// Disposable storage fixtures only. Track contents are synthetic byte markers;
/// no recording, user history, device or installed-app state is opened.
enum MeetingRemovalChecks {
    private struct Fixture {
        let meetings: URL
        let session: URL
        let history: StateStore
        let transcript: Transcript
        let other: Transcript
        let originalHistory: Data
        var staged: URL {
            MeetingStore.sessionURL(root: MeetingTranscriptRemoval.pendingRoot(meetings), id: transcript.id)
        }
        func commit() throws { try history.save(SavedState(history: [other])) }
    }

    static func run(root: URL) throws -> Int {
        let fm = FileManager.default
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { throw MeetingError.message("Removal check failed: " + label) }
            count += 1
        }
        func rejects(_ label: String, _ action: () throws -> Void) throws {
            do { try action() } catch { count += 1; return }
            throw MeetingError.message("Removal check did not reject: " + label)
        }
        func make(_ name: String, state: MeetingState = .committed) throws -> Fixture {
            let base = root.appendingPathComponent(name, isDirectory: true)
            let meetings = base.appendingPathComponent("Meetings", isDirectory: true)
            let transcript = Transcript(text: "Synthetic completed call", seconds: 1)
            let other = Transcript(text: "An unrelated transcript", seconds: 2)
            let manifest = MeetingManifest(id: transcript.id, createdAt: transcript.date, updatedAt: transcript.date,
                purpose: "call", appName: "Synthetic app", appBundleID: "example.synthetic",
                includesMicrophone: false, includesRemote: true, state: state, seconds: 1,
                tracks: [.init(source: .remote, file: "tracks/remote.caf", startSeconds: 0, seconds: 1,
                               sampleRate: 16_000, peak: 0.25, droppedSeconds: 0)],
                segments: [.init(index: 0, file: "segments/segment-0000.wav", startSeconds: 0, seconds: 1,
                                 bytes: 32_000, text: "Synthetic completed call")])
            let session = try MeetingStore.create(root: meetings, manifest: manifest)
            try MeetingStore.writePrivate(Data("original-track".utf8), to: session.appendingPathComponent("tracks/remote.caf"))
            try MeetingStore.writePrivate(Data("recognition-segment".utf8), to: session.appendingPathComponent("segments/segment-0000.wav"))
            let history = StateStore(directory: base.appendingPathComponent("history"))
            try history.save(SavedState(history: [transcript, other]))
            return Fixture(meetings: meetings, session: session, history: history, transcript: transcript,
                           other: other, originalHistory: try Data(contentsOf: history.url))
        }
        func stage(_ fixture: Fixture) throws {
            try MeetingStore.createPrivateDirectory(MeetingTranscriptRemoval.pendingRoot(fixture.meetings))
            try fm.moveItem(at: fixture.session, to: fixture.staged)
        }

        let removed = try make("success")
        let unrelated = removed.meetings.appendingPathComponent("unrelated.txt")
        try Data("unrelated".utf8).write(to: unrelated)
        try check(MeetingTranscriptRemoval.hasRecording(root: removed.meetings, id: removed.transcript.id), "stable UUID identifies the recording")
        let warning = try MeetingTranscriptRemoval.remove(root: removed.meetings, id: removed.transcript.id, commit: removed.commit)
        try check(warning == nil && !fm.fileExists(atPath: removed.session.path) && !fm.fileExists(atPath: removed.staged.path), "confirmed removal deletes original and segmented audio")
        try check(removed.history.load().history.map(\.id) == [removed.other.id], "only the confirmed transcript leaves history")
        try check(Data(contentsOf: unrelated) == Data("unrelated".utf8), "unrelated files remain unchanged")

        let failedSave = try make("history-failure")
        try rejects("history save failure") {
            _ = try MeetingTranscriptRemoval.remove(root: failedSave.meetings, id: failedSave.transcript.id,
                commit: { throw POSIXError(.ENOSPC) })
        }
        try check(Data(contentsOf: failedSave.history.url) == failedSave.originalHistory &&
                  Data(contentsOf: failedSave.session.appendingPathComponent("tracks/remote.caf")) == Data("original-track".utf8), "failed history save restores exact original bytes")
        try check(!fm.fileExists(atPath: failedSave.staged.path), "successful rollback leaves no pending recording")

        let blockedStage = try make("staging-failure")
        try Data("occupied".utf8).write(to: MeetingTranscriptRemoval.pendingRoot(blockedStage.meetings))
        try rejects("staging failure precedes history commit") {
            _ = try MeetingTranscriptRemoval.remove(root: blockedStage.meetings, id: blockedStage.transcript.id, commit: blockedStage.commit)
        }
        try check(Data(contentsOf: blockedStage.history.url) == blockedStage.originalHistory && fm.fileExists(atPath: blockedStage.session.path), "failed staging preserves history and recording")

        let cleanup = try make("partial-cleanup")
        let cleanupWarning = try MeetingTranscriptRemoval.remove(root: cleanup.meetings, id: cleanup.transcript.id,
            commit: cleanup.commit, removeDirectory: { folder in
                try fm.removeItem(at: folder.appendingPathComponent("tracks/remote.caf"))
                throw POSIXError(.EACCES)
            })
        try check(cleanupWarning?.contains("will retry") == true && fm.fileExists(atPath: cleanup.staged.path), "partial cleanup is visible and retains its journal")
        try check(MeetingTranscriptRemoval.hasRecording(root: cleanup.meetings, id: cleanup.transcript.id), "staged audio still gets a recording confirmation")
        try check(MeetingTranscriptRemoval.reconcile(root: cleanup.meetings, history: cleanup.history).isEmpty && !fm.fileExists(atPath: cleanup.staged.path), "restart finishes partial cleanup after history committed")

        let beforeCommit = try make("interrupted-before-commit")
        try stage(beforeCommit)
        try check(MeetingTranscriptRemoval.reconcile(root: beforeCommit.meetings, history: beforeCommit.history).isEmpty, "restart restores a removal interrupted before commit")
        try check(Data(contentsOf: beforeCommit.session.appendingPathComponent("tracks/remote.caf")) == Data("original-track".utf8) &&
                  Data(contentsOf: beforeCommit.history.url) == beforeCommit.originalHistory, "pre-commit restart retains exact recording and history")

        let afterCommit = try make("interrupted-after-commit")
        try stage(afterCommit); try afterCommit.commit()
        try MeetingTranscriptRemoval.markCommitted(afterCommit.staged, id: afterCommit.transcript.id)
        try check(MeetingTranscriptRemoval.reconcile(root: afterCommit.meetings, history: afterCommit.history).isEmpty && !fm.fileExists(atPath: afterCommit.staged.path), "restart finishes a removal interrupted after commit")

        let beforeReceipt = try make("interrupted-before-receipt")
        try stage(beforeReceipt); try beforeReceipt.commit()
        try check(!MeetingTranscriptRemoval.reconcile(root: beforeReceipt.meetings, history: beforeReceipt.history).isEmpty &&
                  fm.fileExists(atPath: beforeReceipt.session.path), "a history commit without its removal receipt conservatively retains audio")

        let unreadable = try make("unreadable-history")
        try stage(unreadable)
        try Data("broken".utf8).write(to: unreadable.history.url)
        try check(!MeetingTranscriptRemoval.reconcile(root: unreadable.meetings, history: unreadable.history).isEmpty && fm.fileExists(atPath: unreadable.staged.path), "unreadable history cannot authorize audio removal")
        try fm.removeItem(at: unreadable.history.url)
        try check(!MeetingTranscriptRemoval.reconcile(root: unreadable.meetings, history: unreadable.history).isEmpty && fm.fileExists(atPath: unreadable.staged.path), "missing history cannot become an empty-history deletion")
        try unreadable.history.save(SavedState())
        try check(!MeetingTranscriptRemoval.reconcile(root: unreadable.meetings, history: unreadable.history).isEmpty &&
                  Data(contentsOf: unreadable.session.appendingPathComponent("tracks/remote.caf")) == Data("original-track".utf8), "a later reset history cannot authorize an uncommitted recording removal")

        let unfinished = try make("unfinished", state: .recognized)
        try rejects("an unfinished recovery is not a completed-recording removal") {
            _ = try MeetingTranscriptRemoval.remove(root: unfinished.meetings, id: unfinished.transcript.id, commit: unfinished.commit)
        }
        try check(Data(contentsOf: unfinished.history.url) == unfinished.originalHistory && fm.fileExists(atPath: unfinished.session.path), "refusal never silently becomes transcript-only removal")

        let future = try make("future")
        let manifestURL = future.session.appendingPathComponent(MeetingStore.manifestName)
        var futureJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        futureJSON["formatVersion"] = 999
        try MeetingStore.writePrivate(JSONSerialization.data(withJSONObject: futureJSON), to: manifestURL)
        try rejects("future-format recording") {
            _ = try MeetingTranscriptRemoval.remove(root: future.meetings, id: future.transcript.id, commit: future.commit)
        }
        try check(Data(contentsOf: future.history.url) == future.originalHistory && fm.fileExists(atPath: future.session.path), "future-format bytes remain outside deletion authority")
        try Data("corrupt manifest".utf8).write(to: manifestURL)
        try rejects("corrupt recording manifest") {
            _ = try MeetingTranscriptRemoval.remove(root: future.meetings, id: future.transcript.id, commit: future.commit)
        }
        try check(Data(contentsOf: future.history.url) == future.originalHistory, "corrupt metadata cannot turn confirmed audio removal into text-only removal")

        let symlink = try make("symlink")
        let outside = symlink.meetings.appendingPathComponent("outside", isDirectory: true)
        try fm.moveItem(at: symlink.session, to: outside)
        try fm.createSymbolicLink(at: symlink.session, withDestinationURL: outside)
        try rejects("live session symlink") {
            _ = try MeetingTranscriptRemoval.remove(root: symlink.meetings, id: symlink.transcript.id, commit: symlink.commit)
        }
        try fm.removeItem(at: symlink.session)
        try MeetingStore.createPrivateDirectory(MeetingTranscriptRemoval.pendingRoot(symlink.meetings))
        try fm.createSymbolicLink(at: symlink.staged, withDestinationURL: outside)
        try check(!MeetingTranscriptRemoval.reconcile(root: symlink.meetings, history: symlink.history).isEmpty &&
                  Data(contentsOf: outside.appendingPathComponent("tracks/remote.caf")) == Data("original-track".utf8), "staged symlinks cannot remove or restore outside contents")

        let linkedRoot = try make("linked-staging-root")
        try fm.createSymbolicLink(at: MeetingTranscriptRemoval.pendingRoot(linkedRoot.meetings), withDestinationURL: linkedRoot.session)
        try check(!MeetingTranscriptRemoval.reconcile(root: linkedRoot.meetings, history: linkedRoot.history).isEmpty &&
                  fm.fileExists(atPath: linkedRoot.session.appendingPathComponent("tracks/remote.caf").path), "a symlinked staging root is refused before recovery reads its entries")

        let badReceipt = try make("bad-receipt")
        try stage(badReceipt); try badReceipt.commit()
        try Data("not a receipt".utf8).write(to: badReceipt.staged.appendingPathComponent(MeetingTranscriptRemoval.receiptName))
        try check(!MeetingTranscriptRemoval.reconcile(root: badReceipt.meetings, history: badReceipt.history).isEmpty &&
                  fm.fileExists(atPath: badReceipt.staged.appendingPathComponent("tracks/remote.caf").path), "invalid commit evidence cannot authorize cleanup")

        let finalCleanup = try make("final-cleanup")
        try stage(finalCleanup); try finalCleanup.commit()
        try MeetingTranscriptRemoval.markCommitted(finalCleanup.staged, id: finalCleanup.transcript.id)
        for child in try fm.contentsOfDirectory(at: finalCleanup.staged, includingPropertiesForKeys: nil)
            where child.lastPathComponent != MeetingTranscriptRemoval.receiptName { try fm.removeItem(at: child) }
        try check(MeetingTranscriptRemoval.reconcile(root: finalCleanup.meetings, history: finalCleanup.history).isEmpty &&
                  !fm.fileExists(atPath: finalCleanup.staged.path), "restart completes cleanup after audio and manifest were already removed")

        let collision = try make("collision")
        try stage(collision)
        try fm.createDirectory(at: collision.session, withIntermediateDirectories: false)
        let collisionMarker = collision.session.appendingPathComponent("keep.txt")
        try Data("newer".utf8).write(to: collisionMarker)
        try check(!MeetingTranscriptRemoval.reconcile(root: collision.meetings, history: collision.history).isEmpty &&
                  Data(contentsOf: collisionMarker) == Data("newer".utf8) && fm.fileExists(atPath: collision.staged.path), "recovery reports a collision without overwriting either copy")
        var duplicateCommits = 0
        try rejects("a second pending removal") {
            _ = try MeetingTranscriptRemoval.remove(root: collision.meetings, id: collision.transcript.id, commit: { duplicateCommits += 1 })
        }
        try check(duplicateCommits == 0, "duplicate removal cannot commit history a second time")

        var textOnlyCommits = 0
        _ = try MeetingTranscriptRemoval.remove(root: root.appendingPathComponent("no-recording"), id: UUID(), commit: { textOnlyCommits += 1 })
        try check(textOnlyCommits == 1, "ordinary transcript removal creates no recording requirement")
        print("MEETING_REMOVAL_CHECKS_OK: \(count) checks passed")
        return count
    }
}
