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
import re
import subprocess
import sys
import tempfile
import time
import wave

sys.dont_write_bytecode = True
from swift_extract import SwiftFile


PROJECT = Path(__file__).resolve().parents[1]
SOURCES = PROJECT / "Sources/LocalVoice"

model = SwiftFile(SOURCES / "AppModel.swift").type("AppModel")
methods = model.extract([
    # Listen, pause, seek and the reading's own failure.
    "followAlongText", "canSeekReading", "seekReading", "skipReading", "listen()", "followPlayback",
    "showReadingPosition", "generateAudio", "streamMacVoice", "keepAudio", "canSaveAudio", "saveAudio(to:completion:)",
    "canCancelReading", "cancelReading", "stopPlayback", "ReadingFailure", "canRetryReading", "retryReading", "reportReadingFailure",
    "dismissReadingFailure", "report", "dismissError", "clearReadingFailure", "readingPlayerDidFinish",
    # The one owner of text arriving in Read, with the step that ends the old reading.
    "invalidateAudio", "receiveReadingSelection", "importReading", "listen(to:)", "canReplaceReading",
    "replaceWaitsForSave", "replaceReadingWithSelection", "keepCurrentReading", "readingLimitMessage",
    "applyReadingSelection", "endReadingForNewText",
    # What the selected provider can read, and the reason copied text is refused (#173).
    "readingProviderName", "ReadingRejection", "readingRejection", "copiedTextRefusal",
])
# The checks drive the private playback step directly instead of waiting for timers.
exposed = methods.replace("    private func ", "    func ")
# Home's Read tile shows only what the tile itself reported (#173). Its tags, however they are
# spelled, appear nowhere in Sources but listen(to:), once each; Attention.swift only declares
# and reads them. The Speko key doors, which these checks cannot drive, report untagged.
tile = model.select(["listen(to:)"])[0]
tags = []
for path in sorted((PROJECT / "Sources").rglob("*.swift")):
    if path.name == "Attention.swift":
        continue
    for found in re.finditer(r"\bhomeReadTile\w*", path.read_text()):
        inside = path == SOURCES / "AppModel.swift" and tile.at <= found.start() < tile.end
        tags.append((path.relative_to(PROJECT).as_posix(), found.group(), inside))
assert all(inside for _, _, inside in tags) and sorted(tag for _, tag, _ in tags) == ["homeReadTileMeeting", "homeReadTileRefused"], \
    f"only listen(to:) tags its reports, its refusal and its meeting wait once each: {tags}"
for door in ("saveSpekoKey", "removeSpekoKey"):
    body = model.select([door])[0].code
    assert "report(" in body and "from:" not in body, door + " reports on Read without the tile's tag"


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
    /// Save audio's M4A export, recorded instead of running afconvert. A held export waits for
    /// the check to let it go, as afconvert runs until it finishes or Cancel terminates it.
    static var exports: [(source: URL, destination: URL)] = []
    static var holdNextExport = false, writeBeforeHold = false, heldExportCancelled = false
    static var heldExport: CheckedContinuation<Void, Never>?
    static func exportBounded(_ source: URL, to destination: URL) async throws {
        exports.append((source, destination))
        guard holdNextExport else { return }
        holdNextExport = false
        // A written export models a Cancel that lands as the file is written: it returns as saved.
        let written = writeBeforeHold; writeBeforeHold = false
        if written { try Data("synthetic m4a".utf8).write(to: destination) }
        await withCheckedContinuation { heldExport = $0 }
        heldExportCancelled = Task.isCancelled
        // Terminated partway, the real conversion throws and writes nothing.
        if !written { try Task.checkCancellation() }
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

/// Wraps the real audio and throws once a read reaches `failFrom`, like a
/// reading whose file became unreadable. It counts reads and throws, so a
/// retry loop or repeated error would show.
final class FailingSource: ReadingAudioSource {
    let inner: ReadingAudioSource
    let failFrom: AVAudioFramePosition
    private(set) var reads = 0
    private(set) var failures = 0
    init(_ inner: ReadingAudioSource, failFrom: AVAudioFramePosition) { self.inner = inner; self.failFrom = failFrom }
    var format: AVAudioFormat { inner.format }
    var availableFrames: AVAudioFramePosition { inner.availableFrames }
    var isComplete: Bool { inner.isComplete }
    func read(from frame: AVAudioFramePosition, count: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        reads += 1
        if frame + AVAudioFramePosition(count) > failFrom { failures += 1; throw VoiceError.message("Synthetic read failure.") }
        return try inner.read(from: frame, count: count)
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
    var attention: Attention? { didSet { if attention != nil { errorReports += 1 } } }
    var error: String? { attention?.message }
    var errorReports = 0
    var speechText = "# Notes\nHello there. Read **this** with `Sources/App/Core.swift` open."
    /// Like AppModel's, the signature follows the text; a check can pin it to force a new render.
    var signatureOverride: String?
    var signature: String {
        get { signatureOverride ?? "mac|karen|180|synthetic|" + speechText }
        set { signatureOverride = newValue }
    }
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
    var savingAudioID: UUID?
    var savingAudio: Bool { savingAudioID != nil }
    var cloudRequestActive = false
    // Read imports: the review, where the window goes and the provider's limit.
    final class Receipt { func dismissHUD() {} }
    let clipboardReceipt = Receipt()
    var pendingReadingSelection: ReadingSelectionImport?
    var readingFailure: ReadingFailure?
    var announcements: [String] = []
    lazy var announceForAccessibility: (String) -> Void = { [unowned self] in self.announcements.append($0) }
    var page = "home"
    var onShowEditor: ((String) -> Void)?
    var readingLimit: Int { readingProvider == .speko ? SpekoRenderer.maximumCharacters : 50_000 }
    var previewStops = 0
    func stopVoicePreview() { previewStops += 1 }
    /// A check can wrap the audio the player reads, to inject a read failure.
    var sourceFault: ((ReadingAudioSource) -> ReadingAudioSource)?
    func makeReadingPlayer(_ source: ReadingAudioSource) throws -> ReadingPlayer {
        try ReadingPlayer(source: sourceFault?(source) ?? source, output: .offline)
    }
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
        try check(model.attention?.page == .read, "A render that failed partway is Read's problem, so the menu-bar panel opens Read (#134)")
        try check(Attention.besideHomeReadTile(model.attention, meetingBusy: model.meetings.isBusy) == nil, "a render that stopped partway never shows beside Home's Read tile (#173)")

        // Guards that keep other work and other providers unchanged.
        let busy = ReadingHarness()
        busy.meetings.isBusy = true
        busy.listen()
        try check(busy.error?.contains("meeting") == true && busy.readingTask == nil, "A meeting in progress blocks reading")
        try check(busy.attention?.page == .read, "A reading a meeting blocked is Read's to explain (#134)")
        try check(Attention.besideHomeReadTile(busy.attention, meetingBusy: busy.meetings.isBusy) == nil, "Listen on Read during a meeting never shows beside Home's Read tile (#173)")
        busy.listen(to: "Copied during the meeting.")
        try check(Attention.besideHomeReadTile(busy.attention, meetingBusy: busy.meetings.isBusy) == busy.error && busy.error?.contains("meeting") == true
                  && busy.speechText != "Copied during the meeting.", "the tile's own meeting wait shows beside it, and the draft stays")
        busy.meetings.isBusy = false
        try check(Attention.besideHomeReadTile(busy.attention, meetingBusy: busy.meetings.isBusy) == nil && busy.error?.contains("meeting") == true,
                  "once the meeting ends, the wait leaves the tile; Read's banner keeps it until it is replaced or dismissed")
        let missing = ReadingHarness()
        missing.voiceChoice = .missing("Matilda")
        let before = MacSpeechRenderer.created.count
        missing.listen(); await missing.readingTask?.value
        try check(missing.error == "Matilda is not installed on this Mac. Choose another voice." && MacSpeechRenderer.created.count == before
                  && missing.player == nil, "A missing chosen voice is reported instead of replaced")
        try check(missing.attention?.page == .read, "Audio that could not be made is Read's problem, so the menu-bar panel opens Read (#134)")
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

        // An audio source that throws ends the reading visibly, once, and keeps
        // the text and voice. It is not mistaken for audio still rendering.
        let sayVoice = MacVoiceChoice.installed(MacVoice(id: "com.apple.voice.Aman", name: "Aman", language: "en-IN", quality: .compact, sayOnly: true, legacyNames: ["Aman"]))
        func faultyReading(from frame: AVAudioFramePosition) -> (ReadingHarness, () -> FailingSource?) {
            let harness = ReadingHarness()
            harness.voiceChoice = sayVoice
            var wrapped: FailingSource?
            harness.sourceFault = { let source = FailingSource($0, failFrom: frame); wrapped = source; return source }
            return (harness, { wrapped })
        }
        func playUntilStopped(_ harness: ReadingHarness, maximumFrames: Int = 16_000 * 50) throws -> (frames: Int, lastTime: Double) {
            var frames = 0, lastTime = 0.0
            while let player = harness.player, frames < maximumFrames {
                lastTime = harness.playbackTime
                _ = try player.renderOffline(4_096); frames += 4_096
                harness.followPlayback(player)
            }
            return (frames, lastTime)
        }
        let (early, earlySource) = faultyReading(from: 0)
        let earlyText = early.speechText
        early.listen(); await early.readingTask?.value
        let earlyPlayer = early.player, earlyURL = early.playingTrack?.url
        _ = try playUntilStopped(early)
        try check(early.player == nil && !early.playing && !early.paused && !early.rendering && early.playTimer == nil,
                  "A source that fails before its first frame ends the reading")
        try check(early.errorReports == 1 && early.readingFailure == .audioUnreadable && early.error == ReadingHarness.ReadingFailure.audioUnreadable.message,
                  "The failure shows one error: \(early.errorReports) reports, \(early.error ?? "none")")
        try check(early.speechText == earlyText && early.voiceChoice == sayVoice && early.rate == 180, "The text, voice and pace survive a failed reading")
        try check(earlyURL != nil && early.audio == nil && !exists(earlyURL), "Unreadable audio is discarded so Retry makes it again")
        for _ in 0..<20 { if let earlyPlayer { early.followPlayback(earlyPlayer) } }
        try check(earlySource()?.failures == 1 && early.errorReports == 1, "No retry loop or repeated error after a failure")
        try check(early.canRetryReading, "Retry is offered beside the failure")
        early.sourceFault = nil
        let rendersBefore = AudioRenderer.sayCalls.count
        early.retryReading(); await early.readingTask?.value
        try check(early.playing && early.error == nil && AudioRenderer.sayCalls.count == rendersBefore + 1 && early.audio?.url != earlyURL,
                  "Retry makes new audio and plays it")
        _ = try playUntilStopped(early)
        try check(early.player == nil && early.status == "Finished reading." && early.error == nil && early.errorReports == 1,
                  "Retry with a good source completes the reading")

        let (late, lateSource) = faultyReading(from: 16_000 * 5)
        late.listen(); await late.readingTask?.value
        let (lateFrames, lateTime) = try playUntilStopped(late)
        try check(lateFrames > 16_000 && lateTime > 0.5, "Audio before the failure plays (\(lateFrames) frames, \(lateTime) s)")
        try check(late.player == nil && !late.playing && !late.paused && late.errorReports == 1
                  && late.readingFailure == .audioUnreadable && lateSource()?.failures == 1 && late.audio == nil,
                  "A source that fails after buffered audio ends the reading with one error")
        late.sourceFault = nil
        late.listen(); await late.readingTask?.value
        try check(late.playing && late.error == nil && late.readingFailure == nil && !late.canRetryReading,
                  "Listen after a failure also makes new audio, and Retry goes")
        late.stopPlayback()

        // Retry is a typed state, not the banner's text: a later error leaves it,
        // Dismiss clears it and the message with it.
        let (typed, _) = faultyReading(from: 0)
        typed.listen(); await typed.readingTask?.value
        _ = try playUntilStopped(typed)
        typed.report("Could not save the audio file.", on: .read)
        try check(typed.canRetryReading && typed.readingFailure == .audioUnreadable, "A later, unrelated error does not hide Retry")
        typed.dismissError()
        try check(typed.error == nil && typed.canRetryReading, "Dismissing an unrelated error leaves the reading failure")
        typed.reportReadingFailure(.audioUnreadable)
        typed.dismissError()
        try check(typed.error == nil && typed.readingFailure == nil && !typed.canRetryReading, "Dismissing the failure's own message clears it")
        typed.reportReadingFailure(.audioUnreadable)
        typed.dismissReadingFailure()
        try check(typed.error == nil && typed.readingFailure == nil, "Dismiss beside Retry clears the failure and its message")

        // A paused reading whose audio cannot start again is Read's problem: the page is recorded
        // where it is raised, so the menu-bar panel opens Read. Guessing from the words opened Dictate (#134).
        let resuming = ReadingHarness()
        resuming.voiceChoice = sayVoice
        resuming.listen(); await resuming.readingTask?.value
        resuming.listen()
        try check(resuming.paused && resuming.player != nil, "A reading pauses before its output is lost")
        resuming.player?.stop()
        resuming.listen()
        try check(resuming.attention == Attention(message: "Audio could not resume. Check your Mac's audio output.", page: .read)
                  && resuming.player == nil && !resuming.playing && !resuming.paused,
                  "A reading that cannot resume stops, and Read owns the problem")

        // A failure found just before a pause is still reported once, and ends the paused reading.
        let (pausing, pausingSource) = faultyReading(from: 16_000 * 5)
        pausing.listen(); await pausing.readingTask?.value
        var pausingPlayer = pausing.player
        while let player = pausingPlayer, player.readFailure == nil {
            _ = try player.renderOffline(4_096); pausing.followPlayback(player); pausingPlayer = pausing.player
        }
        pausing.listen()
        try check(pausing.paused && !pausing.playing && pausing.player != nil, "The reading pauses after its source failed, before the next tick")
        if let pausingPlayer { pausing.followPlayback(pausingPlayer); pausing.followPlayback(pausingPlayer) }
        try check(pausing.player == nil && !pausing.paused && !pausing.playing && pausing.readingFailure == .audioUnreadable
                  && pausing.errorReports == 1 && pausingSource()?.failures == 1, "A paused reading whose source failed ends once, with one error")

        // Audio a Mac voice has not rendered yet is not a failure: playback waits, then continues.
        let waiting = ReadingHarness()
        waiting.signature = "mac|karen|180|waiting"
        let renderers = MacSpeechRenderer.created.count
        waiting.listen()
        await settle { MacSpeechRenderer.created.count == renderers + 1 }
        let fifth = MacSpeechRenderer.created.last!
        try fifth.deliver(seconds: 0.3)
        await settle { waiting.playing }
        for _ in 0..<5 { _ = try waiting.player!.renderOffline(4_096); waiting.followPlayback(waiting.player!) }
        try check(waiting.playing && waiting.player?.isWaitingForAudio == true && waiting.error == nil && waiting.errorReports == 0,
                  "Playback that catches up with rendering waits without an error")
        try fifth.deliver(seconds: 0.5)
        try fifth.complete()
        _ = try playUntilStopped(waiting)
        try check(waiting.status == "Finished reading." && waiting.error == nil, "A reading that waited for rendering finishes normally")

        // Text from History or Library goes through the one import
        // decision (#173). Keep current leaves the reading exactly as it was;
        // Replace ends it, shows the new text and waits for Listen; nothing late
        // from the old reading lands over the new text.
        func pausedReading(_ text: String) async throws -> ReadingHarness {
            let harness = ReadingHarness()
            harness.speechText = text
            let before = MacSpeechRenderer.created.count
            harness.listen()
            await settle { MacSpeechRenderer.created.count == before + 1 }
            let render = MacSpeechRenderer.created.last!
            try render.deliver(seconds: 3)
            try render.complete()
            await settle { harness.playing }
            harness.seekReading(to: 1.5)
            harness.listen()
            return harness
        }
        let passageA = "Passage A is being read aloud. It keeps going for a while."
        let promptB = "Prompt B, a different passage."

        let kept = try await pausedReading(passageA)
        let keptPlayer = kept.player, keptTime = kept.playbackTime
        try check(kept.paused && keptTime == 1.5 && kept.followAlongText == passageA, "A paused reading of A at 0:01")
        kept.importReading(promptB, from: .savedText)
        try check(kept.pendingReadingSelection?.origin == .savedText && kept.speechText == passageA && kept.page == "speak"
                  && kept.player === keptPlayer && kept.paused && kept.playbackTime == keptTime && kept.followAlongText == passageA,
                  "A different import waits for review; the paused reading, its position and its text are untouched")
        kept.keepCurrentReading()
        try check(kept.pendingReadingSelection == nil && kept.speechText == passageA && kept.player === keptPlayer && kept.paused
                  && kept.playbackTime == keptTime && kept.audio != nil, "Keep current keeps the exact draft, player and position")
        kept.listen()
        try check(kept.playing && kept.player === keptPlayer && abs(kept.player!.currentTime - keptTime) < 0.001,
                  "Resume after Keep current continues from the same position")
        kept.stopPlayback()

        let replaced = try await pausedReading(passageA)
        let replacedURL = replaced.audio?.url
        replaced.importReading(promptB, from: .transcript)
        replaced.replaceReadingWithSelection()
        try check(replaced.speechText == promptB && replaced.player == nil && !replaced.playing && !replaced.paused && replaced.playbackTime == 0
                  && replaced.audioDuration == 0 && replaced.readingHighlight == nil && replaced.followAlongText == nil && replaced.pendingReadingSelection == nil,
                  "Replace stops the paused reading, so text, count, progress and the next action all agree on B")
        try check(replacedURL != nil && replaced.audio == nil && !exists(replacedURL), "Replace discards A's audio so it cannot be reused for B")
        try check(replaced.status == "The transcript is ready. Choose Listen to hear it.", "Replace says what to do next: \(replaced.status)")
        let rendersBeforeListen = MacSpeechRenderer.created.count
        await settle()
        try check(replaced.player == nil && MacSpeechRenderer.created.count == rendersBeforeListen, "Nothing plays or renders until Listen")
        replaced.listen()
        await settle { MacSpeechRenderer.created.count == rendersBeforeListen + 1 }
        try check(MacSpeechRenderer.created.last!.text.spoken == promptB, "Listen after Replace reads the new text")
        replaced.stopPlayback()

        let playingA = try await pausedReading(passageA)
        playingA.listen()
        let playingPlayer = playingA.player
        playingA.importReading(passageA, from: .transcript)
        try check(playingA.playing && playingA.player === playingPlayer && playingA.pendingReadingSelection == nil,
                  "The same text does not restart a reading that is playing")
        playingA.importReading(promptB, from: .savedText)
        playingA.replaceReadingWithSelection()
        try check(playingA.player == nil && !playingA.playing && playingA.speechText == promptB, "Replace stops a playing reading too")

        // A meeting can start while a reading plays. Pause then still pauses it, from
        // every door that calls listen(), so the reading never keeps playing into the
        // meeting; Resume waits for the meeting and says why.
        let duringMeeting = try await pausedReading(passageA)
        duringMeeting.listen()
        try check(duringMeeting.playing, "The reading is playing when the meeting starts")
        duringMeeting.meetings.isBusy = true
        duringMeeting.listen()
        try check(duringMeeting.paused && !duringMeeting.playing && duringMeeting.player?.isPlaying == false
                  && duringMeeting.status == "Reading paused.", "Pause pauses a reading while a meeting is busy")
        let heldTime = duringMeeting.playbackTime
        duringMeeting.listen()
        try check(duringMeeting.paused && !duringMeeting.playing && duringMeeting.playbackTime == heldTime
                  && duringMeeting.error?.contains("meeting") == true, "Resume waits for the meeting, keeps the position and says why")
        duringMeeting.meetings.isBusy = false
        duringMeeting.listen()
        try check(duringMeeting.playing, "Resume plays once the meeting is done")

        // During generation: Keep current lets it finish; Replace cancels it and drops anything late.
        let generating = ReadingHarness()
        generating.speechText = passageA
        var renders = MacSpeechRenderer.created.count
        generating.listen()
        await settle { MacSpeechRenderer.created.count == renders + 1 }
        let keptRender = MacSpeechRenderer.created.last!
        generating.importReading(promptB, from: .savedText)
        try check(generating.rendering && generating.readingGenerationActive && !keptRender.cancelled && generating.pendingReadingSelection != nil
                  && generating.canReplaceReading, "An import during generation leaves it running until a choice, and Replace is available")
        generating.keepCurrentReading()
        try keptRender.deliver(seconds: 0.5)
        await settle { generating.playing }
        try check(generating.playing && generating.speechText == passageA && generating.followAlongText == passageA,
                  "Keep current preserves the generation, which then plays A")
        generating.stopPlayback()

        let cancelling = ReadingHarness()
        cancelling.speechText = passageA
        renders = MacSpeechRenderer.created.count
        cancelling.listen()
        await settle { MacSpeechRenderer.created.count == renders + 1 }
        let cancelledRender = MacSpeechRenderer.created.last!
        let cancelledTask = cancelling.readingTask
        cancelling.importReading(promptB, from: .transcript)
        cancelling.replaceReadingWithSelection()
        try check(cancelledRender.cancelled && !exists(cancelledRender.folder) && !cancelling.rendering && !cancelling.readingGenerationActive
                  && cancelling.readingTask == nil && cancelling.speechText == promptB && cancelling.player == nil,
                  "Replace during generation cancels it before installing the new text")
        await cancelledTask?.value
        try cancelledRender.deliver(seconds: 1, force: true)
        try cancelledRender.complete(force: true)
        cancelledRender.fail("A late failure", force: true)
        await settle()
        try check(cancelling.player == nil && cancelling.audio == nil && !cancelling.playing && cancelling.error == nil
                  && cancelling.status == "The transcript is ready. Choose Listen to hear it.",
                  "Late audio, completion or errors from the cancelled generation change nothing")

        let online = ReadingHarness()
        online.readingProvider = .speko
        let sentBefore = SpekoRenderer.texts.count
        SpekoRenderer.holdNext = true
        online.listen()
        await settle { SpekoRenderer.held != nil }
        let onlineTask = online.readingTask
        online.importReading(promptB, from: .savedText)
        try check(SpekoRenderer.texts.count == sentBefore + 1, "An import sends nothing online")
        online.replaceReadingWithSelection()
        try check(online.speechText == promptB && !online.rendering && online.status.hasSuffix("Speko may still bill text already accepted."),
                  "Replacing an online generation keeps its billing note: \(online.status)")
        SpekoRenderer.held?.resume(); SpekoRenderer.held = nil
        await onlineTask?.value
        try check(online.player == nil && online.audio == nil && !online.playing && online.error == nil && SpekoRenderer.texts.count == sentBefore + 1,
                  "A late online result cannot play over the new text")

        // Save audio is a choice with a file: Replace and Home's tile wait for it
        // instead of cancelling it, and say why.
        let saving = ReadingHarness()
        saving.speechText = passageA
        renders = MacSpeechRenderer.created.count
        let savePath = scratch.appendingPathComponent("Saved reading.m4a")
        var saveResults: [String] = []
        saving.saveAudio(to: savePath) { saveResults.append($0) }
        await settle { MacSpeechRenderer.created.count == renders + 1 }
        let savingRender = MacSpeechRenderer.created.last!
        try check(saving.savingAudio && saving.readingGenerationActive && !saving.canReplaceReading, "Save audio is making its audio")
        saving.importReading(promptB, from: .savedText)
        saving.replaceReadingWithSelection()
        try check(!savingRender.cancelled && saving.speechText == passageA && saving.pendingReadingSelection != nil
                  && saving.status == ReadingHarness.replaceWaitsForSave, "Replace waits for Save audio instead of cancelling it, and says why")
        saving.listen(to: promptB)
        try check(saving.speechText == passageA && saving.savingAudio && !savingRender.cancelled, "Home's tile waits for Save audio too")
        try savingRender.deliver(seconds: 0.5)
        try savingRender.complete()
        await saving.readingTask?.value
        try check(!saving.savingAudio && AudioRenderer.exports.last?.destination == savePath && saving.status == "Audio saved to Saved reading.m4a.",
                  "The save finishes with A's audio")
        saving.saveAudio(to: savePath) { saveResults.append($0) }
        await saving.readingTask?.value
        try check(saveResults == ["Audio saved to Saved reading.m4a.", "Audio saved to Saved reading.m4a."],
                  "saving the same cached audio twice reports both completed exports")
        saving.replaceReadingWithSelection()
        try check(saving.speechText == promptB && saving.pendingReadingSelection == nil, "Replace goes ahead once the save is done")

        // Save audio's preconditions are the same whether the panel or a check starts it.
        let unsaved = ReadingHarness()
        unsaved.speechText = "  \n "
        unsaved.saveAudio(to: savePath)
        let aheadSave = ReadingHarness()
        aheadSave.renderingAhead = true
        aheadSave.saveAudio(to: savePath)
        try check(!unsaved.savingAudio && !unsaved.rendering && !aheadSave.savingAudio && !aheadSave.rendering,
                  "Save audio does not start for an empty draft or while a reading is still being prepared")

        let cancelSave = ReadingHarness()
        cancelSave.speechText = passageA
        renders = MacSpeechRenderer.created.count
        var cancelledSaveResults: [String] = []
        cancelSave.saveAudio(to: savePath) { cancelledSaveResults.append($0) }
        await settle { MacSpeechRenderer.created.count == renders + 1 }
        cancelSave.cancelReading()
        try check(!cancelSave.savingAudio && cancelSave.canReplaceReading && !cancelSave.rendering, "Cancel generation ends a save, so it no longer holds Replace")
        try check(cancelledSaveResults.isEmpty && cancelSave.status == "Save audio cancelled.", "cancelled audio export never reports a successful save")

        // Save audio's export runs after its audio is made, with no generation left to cancel. Read's
        // Cancel stays shown and every Cancel door still ends it: the conversion is stopped, nothing
        // is written and Read is idle again (1 October audit, finding 6).
        let exporting = ReadingHarness()
        exporting.speechText = passageA
        renders = MacSpeechRenderer.created.count
        var exportResults: [String] = []
        let exportPath = scratch.appendingPathComponent("Cancelled export.m4a")
        AudioRenderer.holdNextExport = true
        exporting.saveAudio(to: exportPath) { exportResults.append($0) }
        await settle { MacSpeechRenderer.created.count == renders + 1 }
        let exportRender = MacSpeechRenderer.created.last!
        try exportRender.deliver(seconds: 0.5)
        try exportRender.complete()
        await settle { AudioRenderer.heldExport != nil }
        try check(AudioRenderer.heldExport != nil && exporting.savingAudio && exporting.rendering && !exporting.readingGenerationActive
                  && exporting.canCancelReading, "During the export Read's Cancel is still shown")
        let exportTask = exporting.readingTask
        exporting.cancelReading()
        try check(!exporting.savingAudio && !exporting.rendering && exporting.readingTask == nil && exporting.readingGenerationID == nil
                  && !exporting.canCancelReading && exporting.canReplaceReading && exporting.canSaveAudio && exporting.status == "Save audio cancelled.",
                  "Cancel during the export restores idle Read and says so: \(exporting.status)")
        AudioRenderer.heldExport?.resume(); AudioRenderer.heldExport = nil
        await exportTask?.value
        try check(AudioRenderer.heldExportCancelled && !exists(exportPath) && exportResults.isEmpty && exporting.error == nil
                  && exporting.status == "Save audio cancelled.", "The cancelled export is stopped, writes no file and reports no save")
        // Reused audio goes straight to its export; a Cancel landing as the file is written removes it.
        let writtenPath = scratch.appendingPathComponent("Written export.m4a")
        AudioRenderer.holdNextExport = true; AudioRenderer.writeBeforeHold = true
        exporting.saveAudio(to: writtenPath) { exportResults.append($0) }
        await settle { AudioRenderer.heldExport != nil }
        try check(AudioRenderer.heldExport != nil && exists(writtenPath) && exporting.canCancelReading && MacSpeechRenderer.created.count == renders + 1,
                  "A second save reuses the audio and is in its export")
        let writtenTask = exporting.readingTask
        exporting.cancelReading()
        AudioRenderer.heldExport?.resume(); AudioRenderer.heldExport = nil
        await writtenTask?.value
        try check(!exists(writtenPath) && exportResults.isEmpty && !exporting.savingAudio && exporting.status == "Save audio cancelled.",
                  "A Cancel that lands as the file is written leaves no file and no saved report")

        // Listen's generation has not begun yet: Replace still cancels it cleanly.
        let preListen = ReadingHarness()
        preListen.speechText = passageA
        renders = MacSpeechRenderer.created.count
        preListen.listen()
        try check(preListen.rendering && !preListen.readingGenerationActive && preListen.readingTask != nil && preListen.canReplaceReading,
                  "Listen's generation has not begun, and Replace is available")
        let unstarted = preListen.readingTask
        preListen.importReading(promptB, from: .transcript)
        preListen.replaceReadingWithSelection()
        try check(!preListen.rendering && preListen.readingTask == nil && preListen.readingGenerationID == nil && preListen.speechText == promptB,
                  "Replace before generation begins cancels the pending Listen")
        await unstarted?.value
        await settle()
        try check(MacSpeechRenderer.created.count == renders && preListen.player == nil && !preListen.playing && preListen.error == nil,
                  "The cancelled Listen never renders or plays")

        // #161's failure and #173's import are one model: Replace clears a stale Retry.
        let (retried, _) = faultyReading(from: 0)
        retried.listen(); await retried.readingTask?.value
        _ = try playUntilStopped(retried)
        try check(retried.canRetryReading, "A failed reading offers Retry")
        retried.importReading(promptB, from: .transcript)
        try check(retried.canRetryReading && retried.pendingReadingSelection?.text == promptB,
                  "An import under review leaves A's failure and Retry, because A is still the draft")
        retried.replaceReadingWithSelection()
        try check(retried.readingFailure == nil && !retried.canRetryReading && retried.error == nil && retried.speechText == promptB,
                  "Replace clears the failed reading's Retry with the rest of A")

        // Home's Read tile: the click is the choice, through the same replace step, then Listen.
        let tile = try await pausedReading(passageA)
        let tileURL = tile.audio?.url
        renders = MacSpeechRenderer.created.count
        tile.listen(to: promptB)
        await settle { MacSpeechRenderer.created.count == renders + 1 }
        let tileRender = MacSpeechRenderer.created.last!
        try check(tile.speechText == promptB && tileRender.text.spoken == promptB && !exists(tileURL),
                  "Home's tile ends A through the replace step and reads the copied text")
        try tileRender.deliver(seconds: 0.5)
        await settle { tile.playing }
        let tilePlayer = tile.player
        tile.listen(to: promptB)
        try check(tile.playing && tile.player === tilePlayer && MacSpeechRenderer.created.count == renders + 1,
                  "The same copied text already playing carries on")

        // #173: Home's tile turns away text the selected provider cannot read before it touches
        // Read: the draft, its audio, player, playhead and review stay, nothing starts, and the
        // reason is Read's, announced where the tile was. The idle draft is the case Home can reach;
        // paused, playing and generating readings are defensive API coverage of listen(to:) only,
        // since Home hides its Read tile while a reading is live.
        func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
        func refused(_ count: String, _ provider: String, _ limit: String) -> String {
            "The copied text has \(count) characters, more than \(provider) accepts (\(limit)). Your reading draft is unchanged."
        }
        let draftA = String(String(repeating: "Idle draft A keeps every one of its words. ", count: 70).prefix(2_727))
        let macOver = String(repeating: "x", count: 50_001), macLimit = String(repeating: "x", count: 50_000)
        let idle = ReadingHarness()
        idle.speechText = draftA
        renders = MacSpeechRenderer.created.count
        idle.listen()
        await settle { MacSpeechRenderer.created.count == renders + 1 }
        try MacSpeechRenderer.created.last!.deliver(seconds: 1)
        try MacSpeechRenderer.created.last!.complete()
        await settle { idle.playing }
        idle.stopPlayback()
        let idleAudio = idle.audio, idleStatus = idle.status
        renders = MacSpeechRenderer.created.count
        try check(draftA.count == 2_727 && !idle.playing && !idle.paused && idleAudio != nil && exists(idleAudio?.url),
                  "Read is idle with draft A (2,727 characters) and the audio it last made")
        idle.listen(to: macOver)
        try check(bytes(idle.speechText) == bytes(draftA), "50,001 copied characters leave idle draft A byte for byte (#173)")
        try check(idle.audio === idleAudio && exists(idleAudio?.url) && !idle.rendering && idle.readingTask == nil
                  && idle.readingGenerationID == nil && !idle.playing && idle.status == idleStatus,
                  "the refused text keeps A's audio and starts nothing")
        await settle()
        try check(MacSpeechRenderer.created.count == renders && bytes(idle.speechText) == bytes(draftA), "nothing renders later either")
        let macReason = refused("50,001", "Mac reading", "50,000")
        try check(idle.error == macReason && idle.attention?.page == .read, "Read shows why, in the words Home's tile gives: \(idle.error ?? "nothing")")
        try check(idle.announcements.last == macReason, "VoiceOver hears the reason where the tile was clicked")
        try check(Attention.besideHomeReadTile(idle.attention, meetingBusy: idle.meetings.isBusy) == macReason, "Home shows the refusal under the tile that was clicked")
        idle.report("Speko could not save that key.", on: .read)
        try check(idle.error == "Speko could not save that key." && Attention.besideHomeReadTile(idle.attention, meetingBusy: idle.meetings.isBusy) == nil,
                  "a Speko key that failed to save shows on Read, never beside Home's tile, and replaces the tile's notice there")
        idle.listen(to: macOver)
        idle.dismissError()
        try check(idle.attention == nil && Attention.besideHomeReadTile(idle.attention, meetingBusy: idle.meetings.isBusy) == nil, "dismissing the notice takes it from beside the tile")
        idle.listen(to: macOver)
        idle.listen(to: macLimit)
        await settle { MacSpeechRenderer.created.count == renders + 1 }
        let limitRender = MacSpeechRenderer.created.last!
        try check(idle.speechText == macLimit && limitRender.text.spoken.count == 50_000 && !exists(idleAudio?.url) && idle.error == nil,
                  "50,000 characters, the Mac limit, still replace A and read the copied text")
        try check(Attention.besideHomeReadTile(idle.attention, meetingBusy: idle.meetings.isBusy) == nil, "a reading that starts clears the tile's notice")
        try limitRender.deliver(seconds: 0.5)
        await settle { idle.playing }
        let limitPlayer = idle.player
        idle.listen(to: macLimit)
        try check(idle.playing && idle.player === limitPlayer && MacSpeechRenderer.created.count == renders + 1,
                  "the valid text plays once, and the same copied text carries on")

        let unreadable = ReadingHarness()
        unreadable.speechText = draftA
        renders = MacSpeechRenderer.created.count
        unreadable.listen(to: "---\n***\n")
        await settle()
        try check(bytes(unreadable.speechText) == bytes(draftA) && MacSpeechRenderer.created.count == renders && !unreadable.rendering
                  && unreadable.error == "The copied text has nothing to read aloud. Your reading draft is unchanged."
                  && unreadable.announcements.last == unreadable.error, "copied text with nothing to say leaves the draft and says why")

        // The online provider: its raw and prepared limits, through its fake transport only.
        let onlineIdle = ReadingHarness()
        onlineIdle.readingProvider = .speko
        onlineIdle.speechText = passageA
        let spekoOver = String(repeating: "x", count: 5_001), spekoLimit = String(repeating: "x", count: 5_000)
        let sentBeforeRefusals = SpekoRenderer.texts.count
        onlineIdle.listen(to: spekoOver)
        try check(onlineIdle.speechText == passageA && !onlineIdle.rendering && onlineIdle.error == refused("5,001", "Speko", "5,000"),
                  "5,001 copied characters are refused for Speko before anything is sent")
        // Code blocks are spoken as a placeholder, so their prepared text is longer than what is shown.
        func prepared(to spoken: Int) -> String {
            var text = String(repeating: "```\n```\n", count: 240)
            while ListeningText(text).spoken.count < spoken { text += "y" }
            return text
        }
        let preparedFits = prepared(to: 5_000), preparedOver = prepared(to: 5_001)
        try check(preparedFits.count < 5_000 && preparedOver.count < 5_000 && ListeningText(preparedFits).spoken.count == 5_000
                  && ListeningText(preparedOver).spoken.count == 5_001, "fixtures under the limit as shown, at and over it as prepared")
        onlineIdle.listen(to: preparedOver)
        await settle()
        try check(onlineIdle.speechText == passageA && SpekoRenderer.texts.count == sentBeforeRefusals && !onlineIdle.rendering
                  && onlineIdle.error == "Prepared for listening, the copied text is longer than Speko accepts (5,000 characters). Your reading draft is unchanged.",
                  "text within Speko's limit as shown but over it as prepared is refused, and nothing is sent")
        onlineIdle.listen(to: spekoLimit)
        await onlineIdle.readingTask?.value
        try check(onlineIdle.speechText == spekoLimit && SpekoRenderer.texts.count == sentBeforeRefusals + 1 && SpekoRenderer.texts.last == spekoLimit
                  && onlineIdle.playing && onlineIdle.error == nil, "5,000 characters, Speko's limit, replace the draft and play through the fake transport")
        onlineIdle.stopPlayback()
        onlineIdle.listen(to: preparedFits)
        await onlineIdle.readingTask?.value
        try check(onlineIdle.speechText == preparedFits && SpekoRenderer.texts.count == sentBeforeRefusals + 2
                  && SpekoRenderer.texts.last?.count == 5_000 && onlineIdle.playing, "prepared text exactly at Speko's limit is read")

        // Save audio still comes first: the tile waits for it, whatever the text.
        let savingIdle = ReadingHarness()
        savingIdle.speechText = draftA
        renders = MacSpeechRenderer.created.count
        savingIdle.saveAudio(to: scratch.appendingPathComponent("Saved idle reading.m4a"))
        await settle { MacSpeechRenderer.created.count == renders + 1 }
        let idleSave = MacSpeechRenderer.created.last!
        savingIdle.listen(to: macOver)
        try check(bytes(savingIdle.speechText) == bytes(draftA) && savingIdle.savingAudio && !idleSave.cancelled
                  && savingIdle.status == ReadingHarness.replaceWaitsForSave, "during Save audio the tile waits, even for text it would refuse")
        savingIdle.cancelReading()

        // Defensive API coverage only (Home hides Read while a reading is live): a refused text
        // leaves a paused reading, its player, playhead, audio and pending review untouched...
        let pausedDefensive = try await pausedReading(passageA)
        pausedDefensive.importReading(promptB, from: .transcript)
        let pausedPlayer = pausedDefensive.player, pausedTime = pausedDefensive.playbackTime, pausedURL = pausedDefensive.audio?.url
        renders = MacSpeechRenderer.created.count
        pausedDefensive.listen(to: macOver)
        await settle()
        try check(pausedDefensive.speechText == passageA && pausedDefensive.paused && pausedDefensive.player === pausedPlayer
                  && pausedDefensive.playbackTime == pausedTime && exists(pausedURL) && pausedDefensive.pendingReadingSelection?.text == promptB
                  && MacSpeechRenderer.created.count == renders, "defensive: a paused reading, its playhead, audio and review survive a refused text")
        // ...a playing reading keeps playing...
        pausedDefensive.keepCurrentReading()
        pausedDefensive.listen()
        await settle { pausedDefensive.playing }
        pausedDefensive.listen(to: macOver)
        try check(pausedDefensive.playing && pausedDefensive.player === pausedPlayer && pausedDefensive.speechText == passageA,
                  "defensive: a playing reading carries on past a refused text")
        // ...and a generation in progress is not cancelled.
        let generatingDefensive = ReadingHarness()
        generatingDefensive.speechText = passageA
        renders = MacSpeechRenderer.created.count
        generatingDefensive.listen()
        await settle { MacSpeechRenderer.created.count == renders + 1 }
        let defensiveRender = MacSpeechRenderer.created.last!
        generatingDefensive.listen(to: macOver)
        try check(generatingDefensive.rendering && !defensiveRender.cancelled && generatingDefensive.speechText == passageA,
                  "defensive: a generation in progress survives a refused text")
        try defensiveRender.deliver(seconds: 0.5)
        await settle { generatingDefensive.playing }
        try check(generatingDefensive.playing && generatingDefensive.followAlongText == passageA, "and then reads A")

        for harness in [idle, unreadable, onlineIdle, savingIdle, pausedDefensive, generatingDefensive] {
            harness.stopPlayback(); harness.audio?.discard(); harness.audio = nil
        }

        // Stopping and discarding every reading leaves no audio behind.
        for harness in [model, busy, duringMeeting, missing, speko, legacy, remote, early, late, waiting, kept, replaced, playingA, generating, cancelling, online, retried, tile, typed, resuming, pausing, saving, unsaved, aheadSave, cancelSave, exporting, preListen] {
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
        str(SOURCES / "ReadSelectionService.swift"), str(SOURCES / "Attention.swift"),
        str(main), "-o", str(binary),
    ], check=True, timeout=240)
    # Synthetic audio stays inside this disposable directory.
    scratch = directory / "audio"
    scratch.mkdir()
    subprocess.run([str(binary), str(scratch)], check=True, timeout=60)
print(f"Exact application methods SHA-256: {hashlib.sha256(methods.encode()).hexdigest()}")
print(f"Compilation and checks: {time.monotonic() - started:.3f}s")
