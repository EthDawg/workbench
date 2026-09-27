import Foundation

/// A confirmed history removal owns only the meeting directory with that same
/// UUID. Staging lets a failed history write keep the recording intact. On app
/// restart, a positive commit receipt and decoded history decide whether to
/// restore the recording or finish removing it.
enum MeetingTranscriptRemoval {
    static let pendingDirectory = ".transcript-removals"
    static let receiptName = ".removal-committed.json"

    private struct CommitReceipt: Codable {
        var formatVersion = 1
        let id: UUID
    }

    static func pendingRoot(_ root: URL) -> URL {
        root.appendingPathComponent(pendingDirectory, isDirectory: true)
    }

    static func hasRecording(root: URL, id: UUID) -> Bool {
        exists(MeetingStore.sessionURL(root: root, id: id)) ||
            exists(MeetingStore.sessionURL(root: pendingRoot(root), id: id))
    }

    /// Call synchronously from MeetingModel's actor after checking its active
    /// UUID. The commit must atomically save history and only then publish it.
    /// A cleanup warning means history committed, but audio removal is pending.
    static func remove(root: URL, id: UUID, commit: () throws -> Void,
                       removeDirectory: (URL) throws -> Void = finishRemoval) throws -> String? {
        let session = MeetingStore.sessionURL(root: root, id: id)
        let pending = MeetingStore.sessionURL(root: pendingRoot(root), id: id)
        guard !exists(pending) else {
            throw MeetingError.message("An earlier removal of this recording needs recovery. Reopen Workbench before trying again. No further files were removed.")
        }
        guard exists(session) else { try commit(); return nil }
        try validateCompleted(session)
        try MeetingStore.createPrivateDirectory(pendingRoot(root))
        try MeetingStore.rejectSymbolicLinks(in: session)
        try FileManager.default.moveItem(at: session, to: pending)
        do { try commit() }
        catch {
            do { try FileManager.default.moveItem(at: pending, to: session) }
            catch {
                throw MeetingError.message("The transcript was not removed. Its recording is kept for recovery; reopen Workbench to restore it. No recording was deleted.")
            }
            throw error
        }
        do { try markCommitted(pending, id: id) }
        catch {
            return "The transcript was removed, but its recording was kept because removal could not be confirmed. Reopen Workbench to recover the recording. " + error.localizedDescription
        }
        do {
            try validateCompleted(pending)
            try removeDirectory(pending)
            return nil
        } catch {
            return "The transcript was removed, but its recording could not be fully removed. Workbench will retry when you reopen it. " + error.localizedDescription
        }
    }

    /// A missing or unreadable history cannot authorize cleanup. Even a valid
    /// empty history needs positive commit evidence for the staged recording.
    static func reconcile(root: URL, history: StateStore,
                          removeDirectory: (URL) throws -> Void = finishRemoval) -> [String] {
        let staging = pendingRoot(root)
        guard exists(staging) else { return [] }
        do {
            try MeetingStore.rejectSymbolicLinks(in: staging)
            let entries = try FileManager.default.contentsOfDirectory(at: staging,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            guard !entries.isEmpty else { return [] }
            guard FileManager.default.fileExists(atPath: history.url.path) else {
                throw MeetingError.message("Saved transcript history is unavailable. Pending recordings were kept.")
            }
            let retained = Set(try history.load().history.map(\.id))
            var issues: [String] = []
            for pending in entries {
                do {
                    let id = UUID(uuidString: pending.lastPathComponent)!
                    let session = MeetingStore.sessionURL(root: root, id: id)
                    guard !exists(session) else {
                        throw MeetingError.message("A recording has both a saved and a pending copy. Both were kept; removal needs review.")
                    }
                    try MeetingStore.rejectSymbolicLinks(in: pending)
                    let remaining = try FileManager.default.contentsOfDirectory(atPath: pending.path)
                    if !retained.contains(id), remaining.isEmpty {
                        try FileManager.default.removeItem(at: pending)
                        continue
                    }
                    let committed = try hasCommitReceipt(pending, id: id)
                    // The receipt outlives all audio and the final manifest.
                    if committed && !retained.contains(id) && remaining == [receiptName] {
                        try FileManager.default.removeItem(at: pending.appendingPathComponent(receiptName))
                        try FileManager.default.removeItem(at: pending)
                        continue
                    }
                    try validateCompleted(pending)
                    if retained.contains(id) || !committed {
                        if committed { try FileManager.default.removeItem(at: pending.appendingPathComponent(receiptName)) }
                        try FileManager.default.moveItem(at: pending, to: session)
                        if !retained.contains(id) {
                            issues.append("An interrupted removal kept its recording because completion could not be confirmed. The audio remains in the Meetings folder; its transcript entry was already removed.")
                        }
                    } else { try removeDirectory(pending) }
                } catch { issues.append(error.localizedDescription) }
            }
            return issues
        } catch { return [error.localizedDescription] }
    }

    /// Keep the validating manifest until every audio/derived file is gone, so
    /// a partial filesystem failure can be resumed without orphaning audio.
    static func finishRemoval(_ session: URL) throws {
        try validateCompleted(session)
        let manifest = try MeetingStore.safeURL(session: session, relative: MeetingStore.manifestName)
        let children = try FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)
        for child in children where child.lastPathComponent != MeetingStore.manifestName && child.lastPathComponent != receiptName {
            try FileManager.default.removeItem(at: child)
        }
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.removeItem(at: session.appendingPathComponent(receiptName))
        try FileManager.default.removeItem(at: session)
    }

    /// Positive evidence of the successful history commit. A later missing or
    /// reset history file is never enough on its own to authorize audio cleanup.
    static func markCommitted(_ session: URL, id: UUID) throws {
        let receipt = try MeetingStore.safeURL(session: session, relative: receiptName)
        try MeetingStore.writePrivate(JSONEncoder().encode(CommitReceipt(id: id)), to: receipt)
    }

    private static func hasCommitReceipt(_ session: URL, id: UUID) throws -> Bool {
        let url = try MeetingStore.safeURL(session: session, relative: receiptName)
        guard exists(url) else { return false }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 1_024 else { throw MeetingError.unsafePath }
        let receipt = try JSONDecoder().decode(CommitReceipt.self, from: Data(contentsOf: url))
        guard receipt.formatVersion == 1, receipt.id == id else {
            throw MeetingError.message("A recording removal receipt could not be verified. Its audio was kept.")
        }
        return true
    }

    private static func validateCompleted(_ session: URL) throws {
        let manifest = try MeetingStore.load(from: session)
        guard manifest.state == .committed else {
            throw MeetingError.message("This recording still needs transcription recovery. The transcript and recording were kept. Finish recovery before removing them.")
        }
    }

    /// resourceValues also catches a dangling symlink; it must not turn an
    /// unsafe recording path into a transcript-only confirmation.
    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) ||
            (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
