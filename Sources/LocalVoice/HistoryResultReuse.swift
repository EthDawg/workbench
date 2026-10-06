import AppKit

extension AppModel {
    /// An explicit reuse of the reviewed text, with the existing transient
    /// clipboard receipt. It has no dictation target or unresolved-delivery state.
    func copySavedResult(_ text: String, jobID: UUID) {
        status = HistoryResultReuse.copy(text, jobID: jobID, receipts: clipboardReceipt).message
    }
}

@MainActor
enum HistoryResultReuse {
    @discardableResult
    static func copy(_ text: String, jobID: UUID, receipts: ClipboardReceiptModel,
                     pasteboard: NSPasteboard = .general) -> TextDelivery.Outcome {
        let count = TextDelivery.copy(text, to: pasteboard)
        let outcome = TextDelivery.Outcome(message: count == nil ? "Could not copy the saved result." : TextDelivery.copiedMessage,
            clipboardChangeCount: count, wasPasted: false, destinationName: nil, failure: count == nil ? .copyFailed : nil)
        receipts.record(outcome: outcome, wordCount: TextRules.wordCount(text), source: .result(jobID))
        return outcome
    }
}
