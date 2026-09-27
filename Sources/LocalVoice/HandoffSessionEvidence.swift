import Foundation

enum HandoffSessionEvidence {
    /// Only the live screenshots and their own saved words are selected. Audio
    /// recordings and removed/replaced items never enter the text/image job.
    static func snapshots(at url: URL) throws -> [HandoffSourceSnapshot] {
        let source = try TranscriptHandoffStore.evidence(at: url)
        guard source.record.sections.count <= HandoffJobStore.maximumImages else {
            throw VoiceError.message("This session has more than 100 screenshots. Use its own complete Hand off workflow or choose a smaller session.")
        }
        var imageBytes = 0
        func read(_ relative: String, maximum: Int) throws -> Data {
            guard let file = source.files.first(where: { $0.relative == relative }) else {
                throw VoiceError.message("A selected session file is missing. The source session was kept.")
            }
            let info = try file.source.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
            guard info.isSymbolicLink != true, info.isRegularFile == true, (info.fileSize ?? Int.max) <= maximum else {
                throw VoiceError.message("A selected session file exceeds this handoff’s limits.")
            }
            return try Data(contentsOf: file.source)
        }
        return try source.record.sections.map { section in
            let image = try read(section.screenshot, maximum: 16_000_000)
            imageBytes += image.count
            guard imageBytes <= HandoffJobStore.maximumImageBytes else { throw VoiceError.message("The selected session images total more than 256 MB.") }
            func words(_ relative: String?) throws -> String {
                guard let relative else { return "" }
                guard let value = String(data: try read(relative, maximum: 2_000_000), encoding: .utf8) else {
                    throw VoiceError.message("A selected session transcript is not readable text.")
                }
                return value
            }
            let original = try words(section.originalTranscript)
            let edited = try words(section.editedTranscript)
            return HandoffSourceSnapshot(reference: WorkbenchItemReference(kind: .snapAndTalk, id: section.id),
                title: "Snap & Talk · " + source.record.sessionTitle + " · " + String(section.index),
                capturedAt: section.capturedAt,
                text: edited.isEmpty ? original : edited, originalText: original.isEmpty ? edited : original,
                role: .reference, images: [image])
        }
    }
}
