#!/usr/bin/env python3
"""Check the exact reading controls without app initialization or user state.

The harness compiles the production reading methods from AppModel with the
real listening transform, voice catalogue, growing audio file, track and
player. The player renders offline, so no audio device opens and nothing is
heard. A scripted Mac voice renderer delivers synthetic audio and word marks,
fails, finishes late or calls back after being replaced, so streaming,
cancellation and stale-callback guards are deterministic.
Optional --write-fixture DIR produces disposable material for native UI checks.
"""

import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile
import time
import wave


PROJECT = Path(__file__).resolve().parents[1]
SOURCES = PROJECT / "Sources/LocalVoice"
source = (SOURCES / "AppModel.swift").read_text()


def extract(start: str, end: str) -> str:
    begin = source.index(start)
    return source[begin:source.index(end, begin)].rstrip()


methods = "\n".join([
    extract("    var canSeekReading: Bool", "\n    func listen()"),
    extract("    func cancelReading()", "\n    @Published private(set) var readingGenerationActive"),
    extract("    func listen()", "\n    func saveAudio()"),
    extract("    func stopPlayback()", "\n    nonisolated func audioRecorderEncodeErrorDidOccur"),
])
# The checks drive the private playback step directly instead of waiting for timers.
exposed = methods.replace("    private func ", "    func ")


def write_audio(path: Path, seconds: int = 45) -> None:
    with wave.open(str(path), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(16000)
        audio.writeframes(bytes(seconds * 16000 * 2))


harness = r'''
import AVFoundation
import Foundation

enum VoiceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
enum ReadingProvider: String { case mac = "Mac voices", speko = "Speko · online" }
struct SpekoVoice { let requestSignature: String }

/// Every synthetic file lives under the disposable folder the script passes in.
let scratch = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func scratchFolders() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).filter { $0.hasPrefix("LocalVoice-") }
}

/// A silent 16 kHz WAV inside the same LocalVoice- folder shape production uses.
func silentFile(seconds: Int) throws -> URL {
    let folder = scratch.appendingPathComponent("LocalVoice-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("speech.wav")
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 16_000))!
    buffer.frameLength = buffer.frameCapacity
    try file.write(from: buffer)
    return url
}

enum AudioRenderer {
    static var sayCalls: [(text: String, voice: String, rate: Int)] = []
    static func remove(_ url: URL?) {
        guard let url, url.deletingLastPathComponent().lastPathComponent.hasPrefix("LocalVoice-") else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
    static func renderCancellable(text: String, voice: String, rate: Int) async throws -> URL {
        sayCalls.append((text, voice, rate))
        return try silentFile(seconds: 45)
    }
}
enum SpekoKeychain { static func read() throws -> String { "synthetic-key" } }
enum SpekoRenderer {
    static let maximumCharacters = 5_000
    static var texts: [String] = []
    static var holdNext = false
    static var held: CheckedContinuation<Void, Never>?
    static func render(text: String, key: String, voice: SpekoVoice?) async throws -> URL {
        texts.append(text)
        if holdNext { holdNext = false; await withCheckedContinuation { held = $0 } }
        return try silentFile(seconds: 45)
    }
}

/// Scripted stand-in for the AVSpeechSynthesizer renderer, with the same
/// readiness, cancellation and callback contract.
@MainActor final class MacSpeechRenderer {
    static var created: [MacSpeechRenderer] = []
    static let startSeconds = 0.25
    let text: ListeningText
    let folder: URL
    private(set) var audio: ReadingAudioFile?
    private(set) var marks = ReadingMarks()
    private(set) var isFinished = false
    var onAudio: (() -> Void)?
    var onFinish: ((Error?) -> Void)?
    var startedVoice: String?
    var startedRate: Float?
    var cancelled = false
    private var stopped = false
    private var waiters: [(complete: Bool, continuation: CheckedContinuation<Void, Error>)] = []

    init(text: ListeningText) throws {
        self.text = text
        folder = scratch.appendingPathComponent("LocalVoice-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Self.created.append(self)
    }
    func start(voiceIdentifier: String, rate: Float) throws { startedVoice = voiceIdentifier; startedRate = rate }
    func ready(complete: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if stopped && !isFinished { continuation.resume(throwing: CancellationError()) }
            else if satisfied(complete) { continuation.resume() }
            else { waiters.append((complete, continuation)) }
        }
    }
    func cancel() {
        let wasRunning = !stopped
        stopped = true; cancelled = true
        discard()
        if wasRunning { resume(throwing: CancellationError()) }
    }
    func discard() { audio?.close(); try? FileManager.default.removeItem(at: folder) }

    // Script controls. The forced variants model a callback already queued
    // before the renderer was replaced or stopped.
    func deliver(seconds: Double, force: Bool = false) throws {
        guard force || !stopped else { return }
        if audio == nil {
            // A removed render has nowhere to write; its callback still arrives.
            guard FileManager.default.fileExists(atPath: folder.path) else { onAudio?(); return }
            audio = try ReadingAudioFile(url: folder.appendingPathComponent("speech.wav"), sampleRate: 22_050)
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22_050, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 22_050))!
        buffer.frameLength = buffer.frameCapacity
        try audio?.append(buffer)
        resumeSatisfied()
        onAudio?()
    }
    func mark(_ word: String) {
        guard !stopped else { return }
        let range = (text.spoken as NSString).range(of: word)
        marks.append(frame: audio?.availableFrames ?? 0, range: text.originalRange(forSpoken: range))
    }
    func complete(force: Bool = false) throws {
        guard force || !stopped else { return }
        try audio?.finish()
        stopped = true; isFinished = true
        onFinish?(nil)
        resumeSatisfied()
    }
    func fail(_ message: String, force: Bool = false) {
        guard force || !stopped else { return }
        stopped = true
        discard()
        let error = VoiceError.message(message)
        onFinish?(error)
        resume(throwing: error)
    }
    private func satisfied(_ complete: Bool) -> Bool {
        if isFinished { return true }
        guard !complete, let audio else { return false }
        return Double(audio.availableFrames) >= Self.startSeconds * 22_050
    }
    private func resumeSatisfied() {
        let ready = waiters.filter { satisfied($0.complete) }
        waiters.removeAll { satisfied($0.complete) }
        ready.forEach { $0.continuation.resume() }
    }
    private func resume(throwing error: Error) {
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.continuation.resume(throwing: error) }
    }
}

@MainActor final class ReadingHarness {
    struct MeetingWork { var isBusy = false }
    var meetings = MeetingWork()
    enum Phase { case idle, recording }
    var phase: Phase = .idle
    var rendering = false
    var playing = false
    var paused = false
    var player: ReadingPlayer?
    var playTimer: Timer?
    var playbackID: UUID?
    var audio: ReadingTrack?
    var playingTrack: ReadingTrack?
    var pendingRender: MacSpeechRenderer?
    var audioSignature: String { audio?.signature ?? "" }
    var renderingAhead = false
    var readingHighlight: NSRange?
    var audioDuration = 0.0
    var playbackTime = 0.0
    var status = "Ready"
    var error: String?
    var speechText = "# Notes\nHello there. Read **this** with `Sources/App/Core.swift` open."
    var signature = "mac|karen|180|synthetic"
    var rate = 180.0
    var readingProvider = ReadingProvider.mac
    var selectedSpekoVoice: SpekoVoice?
    var voiceChoice: MacVoiceChoice? = .installed(MacVoice(id: "com.apple.voice.super-compact.en-AU.Karen", name: "Karen", language: "en-AU", quality: .compact))
    var missingVoiceMessage: String {
        if case .missing(let name) = voiceChoice { return "\(name) is not installed on this Mac. Choose another voice." }
        return "No Mac voice is installed."
    }
    var readingTask: Task<Void, Never>?
    var readingGenerationID: UUID?
    var readingGenerationActive = false
    var cloudRequestActive = false
    var previewStops = 0
    func stopVoicePreview() { previewStops += 1 }
    func makeReadingPlayer(_ source: ReadingAudioSource) throws -> ReadingPlayer { try ReadingPlayer(source: source, output: .offline) }
    __EXACT_METHODS__
}

struct CheckFailure: Error, CustomStringConvertible { let description: String }
@main struct Checks {
    @MainActor static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("READING_PLAYBACK_CHECK_FAILED: \(error)\n".utf8)); exit(1)
        }
    }
    @MainActor static func run() async throws {
        var count = 0
        func check(_ condition: Bool, _ description: String) throws {
            guard condition else { throw CheckFailure(description: description) }; count += 1
        }
        func settle(_ condition: () -> Bool = { false }) async {
            for _ in 0..<500 where !condition() { await Task.yield() }
        }
        func exists(_ url: URL?) -> Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
        func highlighted(_ model: ReadingHarness) -> String? {
            model.readingHighlight.map { (model.speechText as NSString).substring(with: $0) }
        }

        // Streaming with a Mac voice.
        let model = ReadingHarness()
        try check(!model.canSeekReading, "No seek control without loaded playback")
        model.listen()
        await settle { MacSpeechRenderer.created.count == 1 }
        let first = MacSpeechRenderer.created[0]
        try check(model.rendering && model.readingGenerationActive && model.player == nil, "A starting Mac voice shows cancellable generation")
        try check(first.startedVoice == "com.apple.voice.super-compact.en-AU.Karen" && first.startedRate == 0.5,
                  "The chosen voice renders at the pace mapped from 180 words per minute")
        try check(first.text.spoken == "Notes.\nHello there. Read this with file Core.swift open.", "Only prepared text is spoken")
        first.mark("Notes")
        try first.deliver(seconds: 0.1)
        await settle()
        try check(model.player == nil, "Playback waits for the first quarter second of audio")
        first.mark("Hello")
        try first.deliver(seconds: 0.3)
        await settle { model.playing }
        let firstTimer = model.playTimer!
        try check(model.playing && !model.rendering && !model.readingGenerationActive && model.renderingAhead,
                  "Playback starts while the voice keeps rendering")
        try check(abs(model.audioDuration - 0.4) < 0.001 && model.canSeekReading, "The seek range covers what has rendered")
        first.mark("there")
        try first.deliver(seconds: 1.0)
        first.mark("file")
        try first.deliver(seconds: 1.0)
        model.seekReading(to: 60)
        try check(abs(model.playbackTime - (2.4 - 1.0 / 22_050)) < 0.0001, "Seeking past rendered audio stops at its last frame")
        model.seekReading(to: 0.05)
        try check(highlighted(model) == "Notes", "Seeking shows the word at that point")
        model.seekReading(to: 0.45)
        try check(highlighted(model) == "there", "Each word lasts until the next begins")
        model.seekReading(to: 2.0)
        try check(highlighted(model) == "`Sources/App/Core.swift`", "A shortened path highlights the whole displayed path")
        model.seekReading(to: 0.2)
        _ = try model.player!.renderOffline(3_000)
        model.followPlayback(model.player!)
        try check(highlighted(model) == "Hello" && abs(model.playbackTime - (0.2 + 3_000.0 / 22_050)) < 0.001,
                  "The playback clock drives the highlight, not the render position")
        model.listen()
        try check(model.paused && !model.playing && model.status == "Reading paused.", "Pause keeps the streaming reading")
        model.seekReading(to: 1.0)
        try check(model.paused && !model.player!.isPlaying && highlighted(model) == "there", "Seeking while paused stays paused")
        model.listen()
        try check(model.playing && MacSpeechRenderer.created.count == 1 && model.previewStops > 0, "Resume continues the same rendering")
        try first.complete()
        try check(!model.renderingAhead && model.audio?.isComplete == true && model.audio?.renderer == nil, "Finishing keeps the audio for reuse")
        let savedURL = model.audio!.url
        model.stopPlayback()
        try check(model.player == nil && !model.playing && !model.paused && model.readingHighlight == nil && model.playbackTime == 0
                  && model.audioDuration == 0 && model.status == "Reading stopped.", "Stop clears all playback state consistently")
        try check(!firstTimer.isValid && model.playTimer == nil && model.playbackID == nil && exists(savedURL),
                  "Stop invalidates its timer and keeps finished audio")
        model.seekReading(to: 1); model.skipReading(by: 15)
        try check(model.playbackTime == 0, "Seek after Stop is a no-op")
        model.listen()
        await settle { model.playing }
        try check(MacSpeechRenderer.created.count == 1 && model.player?.source === model.audio?.source && !model.renderingAhead,
                  "The same signature reuses finished audio without rendering again")
        model.seekReading(to: 1.0)
        try check(highlighted(model) == "there", "Reused audio keeps its word timing")
        model.seekReading(to: 2.4)
        _ = try model.player!.renderOffline(4_096)
        model.followPlayback(model.player!)
        try check(model.player == nil && model.status == "Finished reading.", "Natural completion clears the same state as Stop")

        // A changed text renders again and replaces the old audio.
        model.signature = "mac|karen|180|changed"
        model.listen()
        await settle { MacSpeechRenderer.created.count == 2 }
        let second = MacSpeechRenderer.created[1]
        try second.deliver(seconds: 0.5)
        await settle { model.playing }
        try check(model.audio?.url.deletingLastPathComponent().path == second.folder.path && !exists(savedURL),
                  "New audio replaces the old reusable copy")

        // Stop mid-render leaves no audio or files; late callbacks change nothing.
        let partial = second.folder
        model.stopPlayback()
        try check(second.cancelled && !exists(partial) && model.audio == nil && !model.renderingAhead && model.player == nil,
                  "Stop while rendering cancels it and removes the partial audio")
        try second.complete(force: true)
        try second.deliver(seconds: 0.5, force: true)
        second.fail("late", force: true)
        try check(model.audio == nil && model.player == nil && model.error == nil && model.status == "Reading stopped.",
                  "Late callbacks from a stopped render change nothing")

        // Cancel before the first audio.
        model.signature = "mac|karen|180|third"
        model.listen()
        await settle { MacSpeechRenderer.created.count == 3 }
        let third = MacSpeechRenderer.created[2]
        let pending = model.readingTask
        model.cancelReading()
        await pending?.value
        try check(third.cancelled && !exists(third.folder) && model.player == nil && !model.rendering && !model.readingGenerationActive
                  && model.readingTask == nil && model.status == "Reading generation cancelled.", "Cancel before audio leaves nothing behind")
        try third.deliver(seconds: 1, force: true)
        try check(model.player == nil && model.audio == nil, "A cancelled render cannot start playback later")

        // A newer reading ignores callbacks from the one it replaced.
        model.signature = "mac|karen|180|fourth"
        model.listen()
        await settle { MacSpeechRenderer.created.count == 4 }
        let fourth = MacSpeechRenderer.created[3]
        try fourth.deliver(seconds: 0.5)
        await settle { model.playing }
        let current = model.player
        third.fail("stale failure", force: true)
        try third.complete(force: true)
        second.fail("stale failure", force: true)
        try check(model.player === current && model.playing && model.error == nil && model.renderingAhead,
                  "Stale renders cannot stop, finish or fail a newer reading")

        // A render that fails partway stops honestly and keeps nothing.
        let failing = fourth.folder
        fourth.fail("The voice stopped responding. Try Listen again, or choose another voice.")
        try check(model.player == nil && !model.playing && model.audio == nil && !exists(failing)
                  && model.error?.contains("stopped responding") == true, "A failed render stops playback and reports it")

        // Guards that keep other work and other providers unchanged.
        let busy = ReadingHarness()
        busy.meetings.isBusy = true
        busy.listen()
        try check(busy.error?.contains("meeting") == true && busy.readingTask == nil, "A meeting in progress blocks reading")
        let missing = ReadingHarness()
        missing.voiceChoice = .missing("Matilda")
        let before = MacSpeechRenderer.created.count
        missing.listen(); await missing.readingTask?.value
        try check(missing.error == "Matilda is not installed on this Mac. Choose another voice." && MacSpeechRenderer.created.count == before
                  && missing.player == nil, "A missing chosen voice is reported instead of replaced")
        let speko = ReadingHarness()
        speko.readingProvider = .speko
        speko.listen(); await speko.readingTask?.value
        try check(SpekoRenderer.texts == ["Notes.\nHello there. Read this with file Core.swift open."] && speko.playing && !speko.renderingAhead,
                  "Speko renders the prepared text to a file, then plays it")
        speko.seekReading(to: 3)
        try check(speko.readingHighlight == nil && speko.playingTrack?.marks == nil, "Speko has no timing data, so nothing is highlighted")
        let legacy = ReadingHarness()
        legacy.voiceChoice = .installed(MacVoice(id: "com.apple.voice.Aman", name: "Aman", language: "en-IN", quality: .compact, sayOnly: true, legacyNames: ["Aman"]))
        legacy.listen(); await legacy.readingTask?.value
        try check(AudioRenderer.sayCalls.map(\.voice) == ["Aman"] && AudioRenderer.sayCalls.first?.rate == 180 && legacy.playing,
                  "A voice only `say` can speak keeps working through say")

        // Seeking in finished audio keeps the existing player contract.
        let player = legacy.player!
        legacy.seekReading(to: 30)
        try check(player.currentTime == 30 && legacy.playbackTime == 30 && legacy.playing && player.isPlaying,
                  "Seeking changes the audio position without interrupting playback")
        legacy.skipReading(by: -15)
        try check(legacy.playbackTime == 15, "Back 15 uses the actual player position")
        legacy.skipReading(by: 15)
        try check(legacy.playbackTime == 30, "Forward 15 uses the actual player position")
        player.currentTime = 32; legacy.playbackTime = 10
        legacy.skipReading(by: -15)
        try check(legacy.playbackTime == 17, "Skip ignores a stale timer/display position")
        legacy.seekReading(to: -90)
        try check(player.currentTime == 0 && legacy.playbackTime == 0, "Negative seek clamps to the beginning")
        let finalFrame = 45.0 - 1.0 / 16_000
        legacy.seekReading(to: 45)
        try check(player.currentTime == finalFrame, "Seek to the end stays on the last playable frame")
        legacy.skipReading(by: 15)
        try check(player.currentTime == finalFrame, "Skip beyond the end remains at the end instead of wrapping")
        legacy.seekReading(to: 12.75)
        try check(legacy.playbackTime == 12.75, "Scrubber preserves fractional seconds")
        legacy.listen()
        legacy.seekReading(to: 20); legacy.skipReading(by: -15)
        try check(legacy.playbackTime == 5 && legacy.paused && !legacy.playing && !player.isPlaying,
                  "Seek and skip while paused must not start playback")
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            legacy.seekReading(to: invalid); legacy.skipReading(by: invalid)
            try check(player.currentTime == 5 && legacy.paused, "Non-finite input leaves playback unchanged")
        }
        legacy.rendering = true
        legacy.seekReading(to: 1); legacy.skipReading(by: 15)
        try check(!legacy.canSeekReading && player.currentTime == 5, "Seek stays disabled during generation/export")
        legacy.rendering = false
        legacy.audioDuration = .nan
        try check(!legacy.canSeekReading, "An invalid duration cannot create a seek range")
        legacy.audioDuration = 45
        legacy.listen()
        try check(legacy.playing && player.isPlaying && player.currentTime == 5 && legacy.player === player,
                  "Resume starts at the chosen position with the same audio")
        let stale = try ReadingPlayer(source: try ReadingFileSource(url: legacy.audio!.url), output: .offline)
        legacy.readingPlayerDidFinish(stale, successfully: true)
        try check(legacy.player === player && legacy.playing, "A stale completion cannot stop or reset a newer reading")
        legacy.readingPlayerDidFinish(player, successfully: false)
        try check(legacy.player == nil && legacy.status == "Playback interrupted.", "An interrupted player releases and explains the outcome")
        legacy.status = "A newer operation"
        legacy.readingPlayerDidFinish(player, successfully: true)
        try check(legacy.status == "A newer operation", "Completion after disposal cannot replace current status")

        // Remote cancellation keeps its billing warning.
        let remote = ReadingHarness()
        remote.readingProvider = .speko
        SpekoRenderer.holdNext = true
        remote.listen()
        await settle { SpekoRenderer.held != nil }
        let remoteTask = remote.readingTask
        remote.cancelReading()
        try check(remote.status.contains("may still bill") && !remote.rendering && !remote.readingGenerationActive,
                  "Remote cancellation retains the provider billing warning")
        SpekoRenderer.held?.resume(); SpekoRenderer.held = nil
        await remoteTask?.value
        try check(remote.player == nil && !remote.playing && remote.audio == nil, "A delayed remote completion cannot start playback after cancellation")

        // Stopping and discarding every reading leaves no audio behind.
        for harness in [model, busy, missing, speko, legacy, remote] {
            harness.stopPlayback(); harness.audio?.discard(); harness.audio = nil
        }
        try check(scratchFolders().isEmpty, "No temporary reading audio remains: \(scratchFolders())")
        print("READING_PLAYBACK_MODEL_OK: \(count) checks; offline engine, no audio device")
    }
}
'''.replace("__EXACT_METHODS__", exposed)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--write-fixture", type=Path, help="Write synthetic WAV and reading text here, then exit")
args = parser.parse_args()
if args.write_fixture:
    folder = args.write_fixture.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    write_audio(folder / "synthetic-silence.wav")
    paragraph = (
        "This is a synthetic reading for checking playback controls. "
        "Pause the reading, move the position slider, and resume from the new position. "
        "Skip back fifteen seconds to hear an earlier passage. "
        "Skip forward fifteen seconds to move ahead. "
        "At the end, playback should finish cleanly. "
    )
    (folder / "Reading.txt").write_text("\n\n".join([paragraph] * 3))
    print(f"Disposable fixtures: {folder}")
    print("Native check: paste Reading.txt into Read aloud using Mac voices; Listen, pause, seek, resume, skip and Stop.")
    raise SystemExit(0)

started = time.monotonic()
with tempfile.TemporaryDirectory(prefix="workbench-reading-playback-", dir="/private/tmp") as directory:
    directory = Path(directory)
    main = directory / "ReadingChecks.swift"
    main.write_text(harness)
    binary = directory / "ReadingChecks"
    subprocess.run([
        "swiftc", "-parse-as-library", "-swift-version", "5", "-suppress-warnings", "-module-cache-path", str(directory / "ModuleCache"),
        str(SOURCES / "ListeningText.swift"), str(SOURCES / "ReadingAudio.swift"), str(SOURCES / "ReadingVoices.swift"),
        str(main), "-o", str(binary),
    ], check=True, timeout=240)
    # Synthetic audio stays inside this disposable directory.
    scratch = directory / "audio"
    scratch.mkdir()
    subprocess.run([str(binary), str(scratch)], check=True, timeout=60)
print(f"Exact application methods SHA-256: {hashlib.sha256(methods.encode()).hexdigest()}")
print(f"Compilation and checks: {time.monotonic() - started:.3f}s")
