import Foundation

/// Resolve saved wording when Copy is pressed, rather than using the live
/// transcript view or the meeting's completion-time display snapshot.
enum MeetingTranscriptCopy {
    static func copy(_ id: UUID, in history: [Transcript], write: (Transcript) -> String?) -> String? {
        guard let transcript = history.first(where: { $0.id == id }) else {
            return "This transcript is no longer in History. Nothing was copied."
        }
        guard !transcript.text.isEmpty else {
            return "This saved transcript has no text to copy. Review it in History."
        }
        return write(transcript)
    }
}

extension AppModel {
    /// Copy uses History's complete current record and its existing clipboard
    /// receipt/recovery owner. It does not require a ready model or assistant.
    func copyMeetingTranscript(_ id: UUID) -> String? {
        MeetingTranscriptCopy.copy(id, in: history) { item in
            copyCapture(item)
            return status == TextDelivery.copiedMessage ? nil : status
        }
    }
}
