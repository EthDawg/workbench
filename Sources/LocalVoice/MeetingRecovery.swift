import AVFoundation
import CryptoKit
import Foundation

struct MeetingRecoveryEntry: Identifiable, Sendable {
    var session: URL
    var manifest: MeetingManifest?
    var problem: String?
    var checkpoint: MeetingRecoveryCheckpoint?
    var id: String { session.lastPathComponent }
    var isReadable: Bool { manifest != nil }
    var canSaveTranscript: Bool { checkpoint?.text != nil }
}

/// A reviewed snapshot of existing journal bytes, not another persistent store.
struct MeetingRecoveryCheckpoint: Sendable {
    var manifest: MeetingManifest
    var manifestDigest: Data
    var liveDigest: Data?
    var text: String?
    var conversation: String?
    var originalsAvailable: Bool
    func matches(_ other: Self) -> Bool { manifestDigest == other.manifestDigest && liveDigest == other.liveDigest }
}

enum MeetingRecovery {
    /// Read only. Future/corrupt records remain byte-for-byte untouched.
    static func scan(root: URL) -> [MeetingRecoveryEntry] {
        MeetingStore.sessions(in: root).compactMap { session in
            do {
                let entry = try inspect(session: session)
                guard entry.manifest?.needsRecovery == true else { return nil }
                return entry
            } catch {
                return MeetingRecoveryEntry(session: session, manifest: nil, problem: error.localizedDescription)
            }
        }
    }

    static func inspect(session: URL) throws -> MeetingRecoveryEntry {
        let saved = try MeetingStore.loadCheckpoint(from: session), manifest = saved.manifest
        var checkpoint = MeetingRecoveryCheckpoint(manifest: manifest, manifestDigest: Data(SHA256.hash(data: saved.bytes)),
            text: manifest.isFullyRecognized ? manifest.recognizedText : nil, originalsAvailable: !manifest.tracks.isEmpty)
        for track in manifest.tracks {
            let url = try MeetingStore.safeURL(session: session, relative: track.file)
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true { checkpoint.originalsAvailable = false }
        }
        // An interrupted capture may have durable tracks before its manifest
        // records them. The existing processor still owns rebuilding timing.
        if manifest.tracks.isEmpty {
            checkpoint.originalsAvailable = try [MeetingTrackSource.local, .remote].contains { source in
                let url = try MeetingStore.safeURL(session: session, relative: "tracks/\(source.rawValue).caf")
                return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
        }
        let liveURL = try MeetingStore.safeURL(session: session, relative: "live-transcript.json")
        if let live = try? LiveVoiceJournal.load(from: liveURL, sessionID: manifest.id),
           let bytes = try? Data(contentsOf: liveURL), bytes.count <= 16 * 1024 * 1024,
           (try? JSONDecoder().decode(LiveVoiceCheckpoint.self, from: bytes)) == live {
            checkpoint.liveDigest = Data(SHA256.hash(data: bytes))
            if complete(live, for: manifest) {
                checkpoint.text = live.text
                if manifest.includesMicrophone && manifest.includesRemote { checkpoint.conversation = live.conversation }
            }
        }
        return MeetingRecoveryEntry(session: session, manifest: manifest, checkpoint: checkpoint)
    }

    static func complete(_ live: LiveVoiceCheckpoint, for manifest: MeetingManifest) -> Bool {
        manifest.hasValidTimeline && live.complete && manifest.tracks.allSatisfy { track in
            let source: LiveVoiceSource = track.source == .local ? .microphone : .app
            return abs((live.completedThrough[source.rawValue] ?? -1) - (track.startSeconds + track.seconds)) < 0.001
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
            guard timingSize.isRegularFile == true, (timingSize.fileSize ?? Int.max) <= 128 * 1_024 else {
                throw MeetingError.message("The source timing record could not be read safely.")
            }
            let timingData = try Data(contentsOf: timingURL)
            let timing = try JSONDecoder().decode(MeetingTrackTiming.self, from: timingData)
            guard timing.source == source, timing.startSeconds.isFinite, timing.startSeconds >= 0,
                  timing.startSeconds + seconds <= MeetingSegmentPlan.maximumMeetingSeconds + 60,
                  timing.sampleRate == rate else {
                throw MeetingError.message("The original track's timing record is invalid. Its folder was left unchanged.")
            }
            let gaps = timing.gaps ?? []
            guard gaps.count <= 256, gaps.allSatisfy({ gap in
                gap.startSeconds.isFinite && gap.seconds.isFinite && gap.startSeconds >= timing.startSeconds
                    && gap.seconds > 0 && gap.startSeconds + gap.seconds <= MeetingSegmentPlan.maximumMeetingSeconds + 60
                    && gap.reason.utf8.count <= 1_024
            }) else {
                throw MeetingError.message("The original track's interruption record is invalid. Its folder was left unchanged.")
            }
            for gap in gaps {
                let end = min(timing.startSeconds + seconds, gap.startSeconds + gap.seconds)
                guard end > gap.startSeconds else { continue }
                let note = "\(source.rawValue): \(gap.reason) Gap at \(String(format: "%.2f", gap.startSeconds))s for \(String(format: "%.2f", end - gap.startSeconds))s; the saved timeline includes silence."
                if !result.gaps.contains(note) { result.gaps.append(note) }
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

    enum Intent { case recognize, commitOnly(MeetingRecoveryCheckpoint) }

    func run(intent: Intent = .recognize) async throws -> Outcome {
        let session = session
        let entry = try await MeetingFileWork.run { try MeetingRecovery.inspect(session: session) }
        try check()
        guard let current = entry.checkpoint else { throw MeetingProblem.checkpoint("The saved checkpoint could not be reviewed. Its files were kept.") }
        var manifest = current.manifest
        if case .commitOnly(let selected) = intent {
            guard selected.matches(current), current.text != nil else {
                throw MeetingProblem.checkpoint("The selected transcript checkpoint changed or is incomplete. Review the recording again; no recognition or save was started.")
            }
            return try await commitCheckpoint(current)
        }
        if manifest.state == .committed {
            return Outcome(manifest: manifest, committed: true, notes: notes(manifest))
        }
        if current.text != nil { return try await commitCheckpoint(current) }
        if manifest.state == .recording || manifest.tracks.isEmpty {
            let previous = manifest
            manifest = try await MeetingFileWork.run { try MeetingRecovery.rebuildTracks(session: session, manifest: previous) }
            try check()
        }
        guard manifest.seconds > 0, !manifest.tracks.isEmpty else {
            throw MeetingProblem.noSamples
        }
        guard manifest.hasValidTimeline else {
            throw MeetingProblem.checkpoint("The recording duration does not match its full source timeline or exceeds two hours. Its files were kept; no partial transcript was saved.")
        }
        // Completed live checkpoints avoid replaying a whole meeting at Stop. An incomplete,
        // stale or damaged checkpoint can never replace recognition of the saved originals.
        let liveURL = try MeetingStore.safeURL(session: session, relative: "live-transcript.json")
        if let live = try? LiveVoiceJournal.load(from: liveURL, sessionID: manifest.id), MeetingRecovery.complete(live, for: manifest) {
            let refreshed = try await MeetingFileWork.run { try MeetingRecovery.inspect(session: session) }
            try check()
            guard let complete = refreshed.checkpoint, complete.text != nil else { throw MeetingProblem.checkpoint("The live transcript changed during review. Its files were kept.") }
            return try await commitCheckpoint(complete)
        }
        if !manifest.segments.isEmpty, !manifest.hasCompleteSegmentPlan {
            throw MeetingProblem.checkpoint("The saved recognition segments do not cover the complete recording. Its files were kept; a partial transcript was not saved.")
        }
        if manifest.segments.isEmpty {
            let tracks = manifest.tracks
            let segments = try await MeetingFileWork.run { try MeetingMixer.writeSegments(tracks: tracks, session: session) }
            try check()
            guard !segments.isEmpty else {
                // Nothing long enough to recognise is settled like silence, so it is never
                // offered for retry again. Its audio stays until the person removes it.
                var next = manifest
                next.state = .recognized; next.failure = "This recording was too short to transcribe. Its original audio was kept."
                try await persist(next, replacing: manifest)
                return Outcome(manifest: next, committed: false, notes: notes(next))
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
        guard manifest.isFullyRecognized else { throw MeetingProblem.checkpoint("The complete recording has not been recognized. Its checkpoint was kept.") }
        if manifest.isFullyRecognized, manifest.state != .recognized {
            var next = manifest; next.state = .recognized
            try await persist(next, replacing: manifest); manifest = next
        }
        let text = manifest.recognizedText
        guard !text.isEmpty else {
            var next = manifest
            next.failure = "No speech was recognised. Original audio was kept in the Meetings folder."
            try await persist(next, replacing: manifest)
            return Outcome(manifest: next, committed: false, notes: notes(next))
        }
        try check()
        let conversation = await separatedConversation(manifest)
        try check()
        let transcript = Transcript(id: manifest.id, date: manifest.createdAt, text: conversation ?? text,
                                    seconds: manifest.seconds, rawText: text,
                                    cleanupMethod: conversation == nil ? nil : Self.speakersMethod)
        try await commitTranscript(transcript, purpose: manifest.purpose, notes: notes(manifest))
        // History has now committed. Complete the journal even if cancellation
        // arrived at that boundary; no delivery/paste follows this commit.
        var next = manifest; next.state = .committed; next.failure = nil
        try await persist(next, replacing: manifest, allowCancelled: true)
        return Outcome(manifest: next, committed: true, notes: notes(next))
    }

    /// This intent deliberately has no call to mixing, recognition or optional
    /// speaker separation. Missing originals cannot invalidate proven saved text.
    private func commitCheckpoint(_ checkpoint: MeetingRecoveryCheckpoint) async throws -> Outcome {
        try check()
        guard let text = checkpoint.text else { throw MeetingProblem.checkpoint("The transcript is incomplete. Its checkpoint was kept.") }
        var manifest = checkpoint.manifest
        var next = manifest
        next.state = .recognized
        if checkpoint.liveDigest != nil, !manifest.isFullyRecognized {
            next.formatVersion = 2; next.liveText = text
        }
        if next != manifest { try await persist(next, replacing: manifest); manifest = next }
        var details = notes(manifest)
        if !checkpoint.originalsAvailable { details.append("Original audio is missing. This saved text remains available; playback and retranscription are unavailable.") }
        if text.isEmpty {
            next = manifest
            next.failure = checkpoint.originalsAvailable ? "No speech was recognised. Original audio was kept in the Meetings folder." : "No speech was recognised. Original audio is unavailable."
            try await persist(next, replacing: manifest)
            return Outcome(manifest: next, committed: false, notes: details)
        }
        let conversation = checkpoint.conversation.flatMap { $0.isEmpty ? nil : $0 }
        let transcript = Transcript(id: manifest.id, date: manifest.createdAt, text: conversation ?? text,
            seconds: manifest.seconds, rawText: text, cleanupMethod: conversation == nil ? nil : Self.speakersMethod)
        try check()
        try await commitTranscript(transcript, purpose: manifest.purpose, notes: details)
        next = manifest; next.state = .committed; next.failure = nil
        try await persist(next, replacing: manifest, allowCancelled: true)
        return Outcome(manifest: next, committed: true, notes: details)
    }

    static let speakersMethod = "You and Others separated on this Mac"

    private func commitTranscript(_ transcript: Transcript, purpose: String, notes: [String]) async throws {
        do { try await commit(transcript, purpose, notes) }
        catch is CancellationError { throw CancellationError() }
        catch let problem as MeetingProblem { throw problem }
        catch { throw MeetingProblem.save(error.localizedDescription) }
    }

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
                // A partial speaker pass must never silently replace the complete mixed text.
                let text = try await transcribe(file.url)
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
        do {
            try await Task.detached(priority: .utility) {
                if let writer { try writer(next, previous) }
                else { try MeetingStore.save(next, at: session, replacing: previous) }
            }.value
        } catch { throw MeetingProblem.save(error.localizedDescription) }
        if !allowCancelled { try check() }
    }
}
