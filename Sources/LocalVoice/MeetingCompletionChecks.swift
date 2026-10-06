import AppKit

@MainActor
enum MeetingCompletionChecks {
    static func run() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw MeetingError.message("Meeting completion check failed: " + label) }
            checks += 1
        }
        let board = NSPasteboard(name: .init("workbench-meeting-copy-check-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let finalWords = "\nFinal decision: Zoë owns the café review — 完了.\n\n"
        let text = String(repeating: "A complete saved conversation, including its unchanged wording.\n", count: 4_000) + finalWords
        let completed = Transcript(text: text, seconds: 2_401, rawText: "Original wording stays separate.")
        let newer = Transcript(text: "A newer unrelated capture must not be copied.", seconds: 3)
        var history = [newer, completed]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(history)
        var copiedIDs: [UUID] = []
        let write: (Transcript) -> String? = { item in
            copiedIDs.append(item.id)
            return TextDelivery.copy(item.text, to: board) == nil ? "Could not copy the transcript." : nil
        }
        try expect(MeetingTranscriptCopy.copy(completed.id, in: history, write: write) == nil,
                   "a completed transcript copies without a speech engine or assistant")
        try expect(copiedIDs == [completed.id], "Copy resolves the committed UUID, not the newest record")
        try expect(board.string(forType: .string).map { Data($0.utf8) } == Data(text.utf8),
                   "the private clipboard holds the complete Unicode text and final marker byte-for-byte")
        try expect(try encoder.encode(history) == original,
                   "copy preserves the saved current text, original wording and unrelated record")

        // The visible completion snapshot may be older than History's saved wording.
        history[1].text = text + "Later saved correction.\n"
        try expect(MeetingTranscriptCopy.copy(completed.id, in: history, write: write) == nil,
                   "a later saved correction can be copied from the same UUID")
        try expect(board.string(forType: .string) == history[1].text && history[1].text != completed.text,
                   "Copy uses current History text rather than a completion-time or visible snapshot")

        let beforeFailure = try encoder.encode(history)
        let unchangedClipboard = board.string(forType: .string)
        let failure = MeetingTranscriptCopy.copy(completed.id, in: history) { _ in "Could not copy the transcript." }
        try expect(failure == "Could not copy the transcript.", "a clipboard failure cannot become success")
        try expect(try encoder.encode(history) == beforeFailure,
                   "a reported clipboard failure preserves both saved wordings")

        let calls = copiedIDs.count
        try expect(MeetingTranscriptCopy.copy(UUID(), in: history, write: write) != nil,
                   "an unknown UUID reports a problem")
        history.removeAll { $0.id == completed.id }
        try expect(MeetingTranscriptCopy.copy(completed.id, in: history, write: write) != nil,
                   "a deleted transcript is not replaced with cached or unrelated words")
        let empty = Transcript(text: "", seconds: 0, rawText: "Original words are not an implicit fallback.")
        try expect(MeetingTranscriptCopy.copy(empty.id, in: [empty], write: write) != nil,
                   "empty current text cannot report copied or silently use original wording")
        try expect(copiedIDs.count == calls && board.string(forType: .string) == unchangedClipboard,
                   "missing, deleted and empty records never invoke the clipboard writer")
        return checks
    }
}
