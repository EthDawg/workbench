import AppKit
import AVFoundation
import Combine
import SwiftUI

/// A read-only view of the original meeting tracks. Its UUID is the History
/// transcript's UUID; generated Read audio is never a substitute.
struct MeetingRecording {
    let session: URL
    let manifest: MeetingManifest

    static func load(session: URL) throws -> Self {
        let manifest = try MeetingStore.load(from: session)
        guard manifest.state == .committed else {
            throw MeetingError.message("This recording is still unfinished. Open Meetings to recover it. The original audio is kept.")
        }
        guard !manifest.tracks.isEmpty else {
            throw MeetingError.message("This transcript has no original recording available on this Mac.")
        }
        return Self(session: session, manifest: manifest)
    }

    /// Compose preserved originals on their recorded timeline without writing
    /// or changing any session file. A failed track fails the whole preview.
    @MainActor func playerItem() async throws -> AVPlayerItem {
        let composition = AVMutableComposition()
        var inputs: [AVAudioMixInputParameters] = []
        for track in manifest.tracks {
            try Task.checkCancellation()
            let url = try MeetingStore.safeURL(session: session, relative: track.file)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0, track.seconds > 0 else {
                throw MeetingError.message("An original recording track is missing or empty. The transcript and remaining audio are kept.")
            }
            let asset = AVURLAsset(url: url)
            guard let original = try await asset.loadTracks(withMediaType: .audio).first,
                  let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw MeetingError.message("An original recording track cannot be played. The transcript and audio are kept.")
            }
            let actualDuration = try await asset.load(.duration).seconds
            guard actualDuration.isFinite, actualDuration > 0, actualDuration + 0.05 >= track.seconds else {
                throw MeetingError.message("An original recording track is incomplete. Reveal recording to inspect the retained files.")
            }
            let duration = CMTime(seconds: min(actualDuration, track.seconds), preferredTimescale: 48_000)
            try destination.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: original,
                                            at: CMTime(seconds: track.startSeconds, preferredTimescale: 48_000))
            let levels = AVMutableAudioMixInputParameters(track: destination)
            levels.setVolume(1 / Float(manifest.tracks.count), at: .zero)
            inputs.append(levels)
        }
        try Task.checkCancellation()
        guard let snapshot = composition.copy() as? AVComposition else {
            throw MeetingError.message("The recording preview could not be prepared. Its files are kept.")
        }
        let item = AVPlayerItem(asset: snapshot)
        let mix = AVMutableAudioMix(); mix.inputParameters = inputs; item.audioMix = mix
        return item
    }
}

/// One explicitly opened recording, stopped on dismissal, competing capture
/// or shutdown. Merely opening History or this sheet never starts playback.
@MainActor
final class MeetingRecordingPlayback: ObservableObject {
    @Published private(set) var recording: MeetingRecording?
    @Published private(set) var session: URL?
    @Published private(set) var loading = false
    @Published private(set) var ready = false
    @Published private(set) var playing = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var problem: String?
    private let makePlayerItem: (MeetingRecording) async throws -> AVPlayerItem
    private var player: AVPlayer?
    private var generation = UUID()
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?

    init(makePlayerItem: @escaping (MeetingRecording) async throws -> AVPlayerItem = { try await $0.playerItem() }) {
        self.makePlayerItem = makePlayerItem
    }

    func prepare(_ locate: () throws -> URL) async {
        close()
        let token = generation
        loading = true
        do {
            let session = try locate()
            try MeetingStore.rejectSymbolicLinks(in: session)
            guard (try? session.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw MeetingError.message("The original recording could not be found on this Mac. Its transcript is kept.")
            }
            self.session = session
            let recording = try MeetingRecording.load(session: session)
            self.recording = recording
            let item = try await makePlayerItem(recording)
            try Task.checkCancellation()
            guard generation == token else { return }
            let player = AVPlayer(playerItem: item)
            self.player = player
            duration = recording.manifest.tracks.map { $0.startSeconds + $0.seconds }.max() ?? 0
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
                Task { @MainActor in
                    guard let self, self.generation == token, let item else { return }
                    self.ready = item.status == .readyToPlay
                    self.loading = item.status == .unknown
                    if item.status == .failed { self.fail(item.error?.localizedDescription ?? "This recording could not be played. Its files are kept.") }
                }
            }
            rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self, weak player] _, _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.playing = (player?.rate ?? 0) != 0
                }
            }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor in
                    guard let self, self.generation == token, time.seconds.isFinite else { return }
                    self.position = min(self.duration, max(0, time.seconds))
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.playing = false; self.position = self.duration
                }
            }
            failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.fail("Playback stopped before the end. The original recording is kept; reveal it to inspect the files.")
                }
            }
        } catch is CancellationError {
            if generation == token { close() }
        } catch {
            if generation == token { fail(error.localizedDescription) }
        }
    }

    func toggle() {
        guard ready, let player else { return }
        if playing { pause(); return }
        if position >= duration - 0.05 { seek(0) }
        player.play()
    }

    func pause() { player?.pause(); playing = false }

    func seek(_ seconds: Double) {
        guard ready, seconds.isFinite else { return }
        position = min(duration, max(0, seconds))
        player?.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func reveal() {
        guard let session else { return }
        do {
            try MeetingStore.rejectSymbolicLinks(in: session)
            guard FileManager.default.fileExists(atPath: session.path) else {
                throw MeetingError.message("This recording was moved or removed. The transcript is kept.")
            }
            NSWorkspace.shared.activateFileViewerSelecting([session])
        } catch { problem = error.localizedDescription }
    }

    private func fail(_ message: String) {
        pause(); loading = false; ready = false; problem = message
    }

    func close() {
        generation = UUID()
        pause()
        statusObservation = nil; rateObservation = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil; failureObserver = nil
        player?.replaceCurrentItem(with: nil); player = nil
        recording = nil; session = nil; loading = false; ready = false; position = 0; duration = 0; problem = nil
    }
}

struct MeetingRecordingReviewView: View {
    @ObservedObject var meetings: MeetingModel
    @ObservedObject var playback: MeetingRecordingPlayback
    let transcript: Transcript
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recording").font(.title2.weight(.semibold))
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            Text(transcript.date, format: .dateTime.month().day().year().hour().minute()).foregroundStyle(.secondary)
            Text("Original meeting audio").font(.headline)
            if let recording = playback.recording {
                let sources = recording.manifest.tracks.map { $0.source == .local ? "Microphone" : recording.manifest.appName ?? "App audio" }
                Text(sources.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                if !recording.manifest.gaps.isEmpty {
                    ScrollView { Text(recording.manifest.gaps.joined(separator: "\n")).font(.callout).foregroundStyle(.orange).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90)
                }
            }
            if playback.loading { ProgressView("Opening recording…").controlSize(.small) }
            if playback.duration > 0 {
                Slider(value: Binding(get: { playback.position }, set: playback.seek), in: 0...playback.duration)
                    .disabled(!playback.ready).accessibilityLabel("Recording position")
                HStack {
                    Text(time(playback.position)); Spacer(); Text(time(playback.duration))
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let problem = playback.problem {
                Text(problem).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack(spacing: 12) {
                Button {
                    if playback.playing { playback.pause() }
                    else if meetings.mayPlayRecording?() != false { playback.toggle() }
                } label: {
                    Label(playback.playing ? "Pause recording" : "Play recording", systemImage: playback.playing ? "pause.fill" : "play.fill")
                }.disabled(!playback.ready || (!playback.playing && !meetings.canPlayRecording))
                Button("Reveal recording") { playback.reveal() }.disabled(playback.session == nil)
                Spacer()
            }
            if !meetings.canPlayRecording {
                Text("Finish the current capture or reading to play this recording.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Playback uses the saved audio. Closing this review stops playback and keeps the recording and transcript.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 520)
            .task(id: transcript.id) { await playback.prepare { try meetings.recordingURL(for: transcript.id) } }
            .onExitCommand(perform: done)
            .onDisappear { playback.close() }
    }

    private func time(_ value: Double) -> String {
        let seconds = max(0, Int(value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
