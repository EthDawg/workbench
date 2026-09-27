import AVFoundation
import Foundation

struct MeetingRecoveryEntry: Identifiable {
    var session: URL
    var manifest: MeetingManifest?
    var problem: String?
    var id: String { session.lastPathComponent }
    var isReadable: Bool { manifest != nil }
}

enum MeetingRecovery {
    /// Read only. Future/corrupt records remain byte-for-byte untouched.
    static func scan(root: URL) -> [MeetingRecoveryEntry] {
        MeetingStore.sessions(in: root).compactMap { session in
            do {
                let manifest = try MeetingStore.load(from: session)
                guard manifest.needsRecovery else { return nil }
                return MeetingRecoveryEntry(session: session, manifest: manifest)
            } catch {
                return MeetingRecoveryEntry(session: session, manifest: nil, problem: error.localizedDescription)
            }
        }
    }

    /// The timing sidecars are committed before audio, so a crash does not
    /// shift one whole source to the start of the other source.
    static func rebuildTracks(session: URL, manifest: MeetingManifest) throws -> MeetingManifest {
        var result = manifest
        var tracks: [MeetingTrack] = []
        for source in [MeetingTrackSource.remote, .local] {
            let relative = "\(MeetingStore.tracksDirectory)/\(source.rawValue).caf"
            let url = try MeetingStore.safeURL(session: session, relative: relative)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0 else { continue }
            let rate = file.processingFormat.sampleRate
            let seconds = Double(file.length) / rate
            guard (8_000...192_000).contains(rate), seconds.isFinite,
                  seconds <= MeetingSegmentPlan.maximumMeetingSeconds + 60 else {
                throw MeetingError.message("An original track has an invalid duration or format. Its folder was left unchanged.")
            }
            let timingURL = try MeetingStore.safeURL(session: session, relative: "\(MeetingStore.tracksDirectory)/\(source.rawValue).json")
            let timingSize = try timingURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard timingSize.isRegularFile == true, (timingSize.fileSize ?? Int.max) <= 1_024 else {
                throw MeetingError.message("The source timing record could not be read safely.")
            }
            let timingData = try Data(contentsOf: timingURL)
            let timing = try JSONDecoder().decode(MeetingTrackTiming.self, from: timingData)
            guard timing.source == source, timing.startSeconds.isFinite, timing.startSeconds >= 0,
                  timing.startSeconds + seconds <= MeetingSegmentPlan.maximumMeetingSeconds + 60,
                  timing.sampleRate == rate else {
                throw MeetingError.message("The original track's timing record is invalid. Its folder was left unchanged.")
            }
            let previous = manifest.tracks.first { $0.source == source }
            tracks.append(MeetingTrack(source: source, file: relative, startSeconds: timing.startSeconds,
                                       seconds: seconds, sampleRate: rate, peak: previous?.peak ?? -1,
                                       droppedSeconds: previous?.droppedSeconds ?? 0))
        }
        result.tracks = tracks
        result.seconds = tracks.map { $0.startSeconds + $0.seconds }.max() ?? 0
        if manifest.state == .recording {
            result.gaps.append("Workbench stopped before this recording finished. Saved audio was recovered; the final in-memory audio buffer may be missing.")
        }
        result.state = .stopped
        try MeetingStore.save(result, at: session, replacing: manifest)
        return result
    }
}

/// File IO and conversion run away from the main actor; cancellation also
/// reaches the detached mixer rather than leaving it running after Cancel.
enum MeetingFileWork {
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility, operation: body)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

/// Explicit post-Stop processing with a checkpoint after every segment and
/// one stable transcript ID. The host's history writer upserts that same ID.
@MainActor
struct MeetingProcessor {
    let session: URL
    let transcribe: (URL) async throws -> String
    let commit: (Transcript, String, [String]) async throws -> Void
    var isCurrent: () -> Bool = { true }
    var writeManifest: (@Sendable (MeetingManifest, MeetingManifest) throws -> Void)? = nil

    struct Outcome {
        var manifest: MeetingManifest
        var committed: Bool
        var notes: [String]
    }

    func run() async throws -> Outcome {
        let session = session
        var manifest = try await MeetingFileWork.run { try MeetingStore.load(from: session) }
        try check()
        if manifest.state == .committed {
            return Outcome(manifest: manifest, committed: true, notes: notes(manifest))
        }
        if manifest.state == .recording || manifest.tracks.isEmpty {
            let previous = manifest
            manifest = try await MeetingFileWork.run { try MeetingRecovery.rebuildTracks(session: session, manifest: previous) }
            try check()
        }
        guard manifest.seconds > 0, !manifest.tracks.isEmpty else {
            throw MeetingError.message("No readable audio was recorded. Nothing was added to Recent transcripts; the session folder was kept.")
        }
        if manifest.segments.isEmpty {
            let tracks = manifest.tracks
            let segments = try await MeetingFileWork.run { try MeetingMixer.writeSegments(tracks: tracks, session: session) }
            try check()
            guard !segments.isEmpty else {
                throw MeetingError.message("This recording was too short to transcribe. Its original audio was kept.")
            }
            var next = manifest
            next.segments = segments; next.state = .segmented; next.failure = nil
            try await persist(next, replacing: manifest)
            manifest = next
        }
        for segment in manifest.orderedSegments where segment.text == nil {
            try check()
            let url = try MeetingStore.safeURL(session: session, relative: segment.file)
            try await MeetingFileWork.run {
                let size = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard size.isRegularFile == true, size.fileSize == segment.bytes else {
                    throw MeetingError.message("A recognition segment was changed or removed. Its folder was left unchanged.")
                }
                let file = try AVAudioFile(forReading: url)
                guard file.fileFormat.sampleRate == MeetingSegmentPlan.sampleRate,
                      file.fileFormat.channelCount == 1,
                      abs(Double(file.length) / MeetingSegmentPlan.sampleRate - segment.seconds) < 0.01 else {
                    throw MeetingError.message("A recognition segment has an unexpected format or duration.")
                }
            }
            try check()
            let text = try await transcribe(url)
            try check()
            var next = manifest
            next.segments[segment.index].text = text
            try await persist(next, replacing: manifest)
            manifest = next
        }
        try check()
        if manifest.isFullyRecognized, manifest.state != .recognized {
            var next = manifest; next.state = .recognized
            try await persist(next, replacing: manifest); manifest = next
        }
        let text = manifest.recognizedText
        guard !text.isEmpty else {
            var next = manifest
            next.failure = "No speech was recognised. Original audio was kept in the Meetings folder."
            try await persist(next, replacing: manifest)
            return Outcome(manifest: next, committed: false, notes: notes(next) + [next.failure!])
        }
        try check()
        let conversation = await separatedConversation(manifest)
        try check()
        let transcript = Transcript(id: manifest.id, date: manifest.createdAt, text: conversation ?? text,
                                    seconds: manifest.seconds, rawText: text,
                                    cleanupMethod: conversation == nil ? nil : Self.speakersMethod)
        try await commit(transcript, manifest.purpose, notes(manifest))
        // History has now committed. Complete the journal even if cancellation
        // arrived at that boundary; no delivery/paste follows this commit.
        var next = manifest; next.state = .committed; next.failure = nil
        try await persist(next, replacing: manifest, allowCancelled: true)
        return Outcome(manifest: next, committed: true, notes: notes(next))
    }

    static let speakersMethod = "You and Others separated on this Mac"

    /// With both the microphone and an app's audio, label who spoke. Nil keeps
    /// the mixed transcript: one track, no usable speech, a recogniser failure
    /// or cancellation all leave today's result intact. The mixed words remain
    /// the original wording either way.
    private func separatedConversation(_ manifest: MeetingManifest) async -> String? {
        guard let local = manifest.tracks.first(where: { $0.source == .local }),
              let remote = manifest.tracks.first(where: { $0.source == .remote }) else { return nil }
        let session = session
        let directory = session.appendingPathComponent(".speakers-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let files = try await MeetingFileWork.run {
                try MeetingStore.createPrivateDirectory(directory)
                return try MeetingConversation.writeUtterances(track: local, session: session, speaker: .you, directory: directory)
                    + MeetingConversation.writeUtterances(track: remote, session: session, speaker: .others, directory: directory)
            }
            var utterances: [MeetingConversation.Utterance] = []
            for file in files {
                try check()
                // One unrecognisable clip should not cost the whole conversation.
                guard let text = try? await transcribe(file.url) else { continue }
                utterances.append(.init(speaker: file.speaker, start: file.start, end: file.end, text: text))
            }
            let conversation = MeetingConversation.conversation(utterances)
            return conversation.isEmpty ? nil : conversation
        } catch { return nil }
    }

    private func notes(_ manifest: MeetingManifest) -> [String] { manifest.gaps + MeetingSummary.gaps(for: manifest) }
    private func check() throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
    }
    private func persist(_ next: MeetingManifest, replacing previous: MeetingManifest, allowCancelled: Bool = false) async throws {
        if !allowCancelled { try check() }
        let session = session, writer = writeManifest
        // A journal write is atomic and short; it must finish even if its
        // calling task is cancelled after recognition/history committed.
        try await Task.detached(priority: .utility) {
            if let writer { try writer(next, previous) }
            else { try MeetingStore.save(next, at: session, replacing: previous) }
        }.value
        if !allowCancelled { try check() }
    }
}
