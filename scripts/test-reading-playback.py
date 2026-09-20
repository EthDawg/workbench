#!/usr/bin/env python3
"""Check the exact reading controls without app initialization or user state.

The model fixture controls playback failures and delayed completion callbacks.
A second harness checks the exact seek methods with a real AVAudioPlayer and a
synthetic silent WAV, without calling play or opening an audio output device.
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
source = (PROJECT / "Sources/LocalVoice/AppModel.swift").read_text()


def extract(start: str, end: str) -> str:
    begin = source.index(start)
    return source[begin:source.index(end, begin)].rstrip()


seek_methods = extract("    var canSeekReading: Bool", "\n    func listen()")
cancel_method = extract("    func cancelReading()", "\n    @Published private(set) var readingGenerationActive")
methods = "\n".join([
    seek_methods,
    cancel_method,
    extract("    func listen()", "\n    private func generateAudio(generationID:"),
    extract("    func stopPlayback()", "\n    nonisolated func audioRecorderEncodeErrorDidOccur"),
])


def write_audio(path: Path) -> None:
    with wave.open(str(path), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(16000)
        audio.writeframes(bytes(45 * 16000 * 2))


model_fixture = r'''
import Foundation

enum VoiceError: Error { case message(String) }
enum ReadingProvider { case mac, speko }
final class AVAudioPlayer {
    struct Format { let sampleRate = 16000.0 }
    let format = Format()
    let duration = 45.0
    var currentTime = 0.0
    weak var delegate: AnyObject?
    var playSucceeds = true
    var plays = 0
    var pauses = 0
    var stops = 0
    var isPlaying = false
    init(contentsOf: URL) throws {}
    func play() -> Bool { plays += 1; isPlaying = playSucceeds; return playSucceeds }
    func pause() { pauses += 1; isPlaying = false }
    func stop() { stops += 1; isPlaying = false }
}
@MainActor final class AppModelPlaybackHarness {
    enum Phase { case idle, recording }
    var phase: Phase = .idle
    var rendering = false
    var playing = false
    var paused = false
    var player: AVAudioPlayer?
    var playTimer: Timer?
    var playbackID: UUID?
    var audioDuration = 0.0
    var playbackTime = 0.0
    var status = "Ready"
    var error: String?
    var signature = "Unchanged fixture reading"
    var audioSignature = "Unchanged fixture reading"
    var readingTask: Task<Void, Never>?
    var readingGenerationID: UUID?
    var readingGenerationActive = false
    var cloudRequestActive = false
    var readingProvider = ReadingProvider.mac
    var generationCalls = 0
    var suspendNextGeneration = false
    var generationContinuation: CheckedContinuation<URL, Never>?
    func generateAudio(generationID: UUID) async throws -> URL {
        generationCalls += 1
        readingGenerationActive = true
        defer {
            if readingGenerationID == generationID { readingGenerationActive = false }
        }
        if suspendNextGeneration {
            suspendNextGeneration = false
            return await withCheckedContinuation { generationContinuation = $0 }
        }
        return URL(fileURLWithPath: "/private/tmp/synthetic-fixture-\(generationCalls)-not-read.wav")
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
        func flushCallbacks() async {
            for _ in 0..<10 { await Task.yield() }
        }
        let model = AppModelPlaybackHarness()
        try check(!model.canSeekReading, "No seek control without loaded playback")
        model.listen(); await model.readingTask?.value
        let first = model.player!
        let firstTimer = model.playTimer!
        let firstPlaybackID = model.playbackID
        try check(model.canSeekReading && model.playing && !model.paused && model.audioDuration == 45,
                  "Listen loads a seekable player and publishes its duration")
        try check(model.generationCalls == 1 && first.plays == 1, "Listen requests audio once")
        model.seekReading(to: 30)
        try check(first.currentTime == 30 && model.playbackTime == 30 && model.playing && first.isPlaying,
                  "Seeking changes current audio position without interrupting playback")
        model.skipReading(by: -15)
        try check(model.playbackTime == 15, "Back 15 uses the actual player position")
        model.skipReading(by: 15)
        try check(model.playbackTime == 30, "Forward 15 uses the actual player position")
        first.currentTime = 32; model.playbackTime = 10
        model.skipReading(by: -15)
        try check(model.playbackTime == 17, "Skip ignores a stale timer/display position")
        model.seekReading(to: -90)
        try check(first.currentTime == 0 && model.playbackTime == 0, "Negative seek clamps to the beginning")
        model.seekReading(to: 45)
        let finalFrame = 45.0 - 1.0 / 16000
        try check(first.currentTime == finalFrame, "Seek to EOF stays on the last playable frame")
        model.skipReading(by: 15)
        try check(first.currentTime == finalFrame, "Skip beyond EOF remains at the end instead of wrapping")
        model.seekReading(to: 12.75)
        try check(model.playbackTime == 12.75, "Scrubber preserves fractional seconds")
        model.listen()
        try check(!model.playing && model.paused && !first.isPlaying && model.status == "Reading paused.",
                  "Pause retains the loaded reading with truthful state")
        model.seekReading(to: 20); model.skipReading(by: -15)
        try check(model.playbackTime == 5 && model.paused && !model.playing && !first.isPlaying,
                  "Seek and skip while paused must not start playback")
        model.seekReading(to: 1000)
        try check(model.paused && first.currentTime == finalFrame, "Paused seek to the end preserves pause")
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            model.seekReading(to: invalid); model.skipReading(by: invalid)
            try check(first.currentTime == finalFrame && model.paused, "Non-finite input leaves playback unchanged")
        }
        model.seekReading(to: 20)
        model.rendering = true
        model.seekReading(to: 1); model.skipReading(by: 15)
        try check(!model.canSeekReading && first.currentTime == 20, "Seek stays disabled during generation/export")
        model.rendering = false
        model.audioDuration = .nan
        try check(!model.canSeekReading, "An invalid duration cannot create a seek range")
        model.audioDuration = 45
        model.signature = "Text edited while audio remains loaded"
        model.seekReading(to: 8)
        try check(first.currentTime == 8 && model.generationCalls == 1,
                  "Seeking edits the current audio, even when draft settings have changed")
        model.signature = model.audioSignature
        model.listen()
        try check(model.playing && !model.paused && first.currentTime == 8 && first.plays == 2,
                  "Resume starts at the newly chosen position")
        try check(model.generationCalls == 1 && model.player === first && first.pauses == 1,
                  "All seek/skip/pause/resume operations reuse the same audio without renderer calls")
        model.stopPlayback()
        try check(model.player == nil && !model.playing && !model.paused && !model.canSeekReading
                  && model.audioDuration == 0 && model.playbackTime == 0 && model.status == "Reading stopped.",
                  "Stop clears all playback state consistently")
        try check(!firstTimer.isValid && model.playTimer == nil && model.playbackID == nil && first.stops == 1,
                  "Stop invalidates its timer and queued updates, then stops its player")
        model.seekReading(to: 12); model.skipReading(by: 15)
        try check(model.playbackTime == 0 && model.generationCalls == 1, "Seek after Stop is a no-op")

        model.listen(); await model.readingTask?.value
        let second = model.player!
        try check(model.playbackID != nil && model.playbackID != firstPlaybackID, "A new reading rejects queued timer updates from the previous reading")
        model.seekReading(to: 18)
        model.audioPlayerDidFinishPlaying(first, successfully: true)
        await flushCallbacks()
        try check(model.player === second && model.playing && model.playbackTime == 18 && second.stops == 0,
                  "A stale completion cannot stop or reset a newer reading")
        model.audioPlayerDidFinishPlaying(second, successfully: true)
        await flushCallbacks()
        try check(model.player == nil && model.audioDuration == 0 && model.playbackTime == 0 && !model.playing
                  && !model.paused && model.playTimer == nil && model.status == "Finished reading.",
                  "Natural completion clears the same state as Stop")
        model.status = "A newer operation"
        model.audioPlayerDidFinishPlaying(second, successfully: false)
        await flushCallbacks()
        try check(model.status == "A newer operation", "Completion after disposal cannot replace current status")

        model.listen(); await model.readingTask?.value
        model.audioPlayerDidFinishPlaying(model.player!, successfully: false)
        await flushCallbacks()
        try check(model.player == nil && !model.canSeekReading && model.status == "Playback interrupted.",
                  "Interrupted completion releases the player and explains the outcome")
        model.listen(); await model.readingTask?.value
        let failing = model.player!
        model.listen(); failing.playSucceeds = false
        let callsBeforeResume = model.generationCalls
        model.listen()
        try check(model.player == nil && !model.paused && !model.playing && model.playbackTime == 0 && model.audioDuration == 0,
                  "Failed resume cannot claim to be playing or retain an unusable seek control")
        try check(model.error?.contains("could not resume") == true && model.generationCalls == callsBeforeResume,
                  "Failed resume reports the error without regenerating or retrying")

        let delayed = AppModelPlaybackHarness()
        delayed.suspendNextGeneration = true
        delayed.listen()
        while delayed.generationContinuation == nil { await Task.yield() }
        let staleTask = delayed.readingTask
        try check(delayed.rendering && delayed.readingGenerationActive,
                  "A slow local generation exposes the same cancellable state as a remote request")
        delayed.cancelReading()
        try check(!delayed.rendering && !delayed.readingGenerationActive && delayed.readingTask == nil,
                  "Cancel immediately restores truthful idle generation state")
        try check(delayed.status == "Reading generation cancelled.",
                  "Local cancellation does not show the Speko billing warning")
        delayed.listen(); await delayed.readingTask?.value
        let replacement = delayed.player
        let replacementStatus = delayed.status
        try check(delayed.generationCalls == 2 && replacement != nil && delayed.playing,
                  "A new reading can start while the cancelled provider finishes late")
        delayed.generationContinuation?.resume(returning: URL(fileURLWithPath: "/private/tmp/stale-fixture-not-read.wav"))
        delayed.generationContinuation = nil
        await staleTask?.value
        try check(delayed.player === replacement && delayed.playing && delayed.status == replacementStatus,
                  "A cancelled late completion cannot replace newer playback or status")

        let remote = AppModelPlaybackHarness()
        remote.readingProvider = .speko
        remote.suspendNextGeneration = true
        remote.listen()
        while remote.generationContinuation == nil { await Task.yield() }
        let remoteTask = remote.readingTask
        remote.cancelReading()
        try check(!remote.rendering && !remote.readingGenerationActive && remote.readingTask == nil,
                  "A delayed remote request reaches the same truthful idle state")
        try check(remote.status.contains("may still bill"),
                  "Remote cancellation retains the provider billing warning")
        remote.generationContinuation?.resume(returning: URL(fileURLWithPath: "/private/tmp/stale-remote-fixture-not-read.wav"))
        remote.generationContinuation = nil
        await remoteTask?.value
        try check(remote.player == nil && !remote.playing && remote.status.contains("cancelled"),
                  "A delayed remote completion cannot start playback after cancellation")
        print("READING_PLAYBACK_MODEL_OK: \(count) checks")
    }
}
'''.replace("__EXACT_METHODS__", methods)

real_fixture = r'''
import Foundation
import AVFoundation

enum VoiceError: Error { case message(String) }
enum ReadingProvider { case mac, speko }
@MainActor final class RealPlayerHarness: NSObject, AVAudioPlayerDelegate {
    enum Phase { case idle }
    var phase: Phase = .idle
    var rendering = false
    var playing = false
    var paused = true
    var player: AVAudioPlayer?
    var playTimer: Timer?
    var playbackID: UUID?
    var audioDuration = 0.0
    var playbackTime = 0.0
    var status = "Ready"
    var error: String?
    var signature = "Synthetic reading"
    var audioSignature = "Synthetic reading"
    var readingTask: Task<Void, Never>?
    var readingGenerationID: UUID?
    var readingGenerationActive = false
    var cloudRequestActive = false
    var readingProvider = ReadingProvider.mac
    func generateAudio(generationID: UUID) async throws -> URL {
        fatalError("Seeking must never call the renderer")
    }
    __EXACT_METHODS__
}
@main struct Checks {
    @MainActor static func main() throws {
        let model = RealPlayerHarness()
        let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        model.player = player; model.audioDuration = player.duration
        var count = 0
        func check(_ condition: Bool, _ description: String) {
            guard condition else { fatalError("READING_REAL_PLAYER_FAILED: \(description)") }; count += 1
        }
        check(abs(player.duration - 45) < 0.001 && model.canSeekReading, "Real WAV duration is seekable")
        model.seekReading(to: 30)
        check(abs(player.currentTime - 30) < 0.002 && abs(model.playbackTime - 30) < 0.002, "Real seek updates the displayed position")
        model.skipReading(by: -15)
        check(abs(player.currentTime - 15) < 0.002, "Real skip back")
        model.skipReading(by: 15)
        check(abs(player.currentTime - 30) < 0.002, "Real skip forward")
        model.seekReading(to: 45)
        check(player.currentTime > 44.99 && player.currentTime <= player.duration, "Real EOF seek does not wrap to zero")
        model.skipReading(by: 15)
        check(player.currentTime > 44.99, "Real skip past EOF stays at the end")
        model.seekReading(to: -15)
        check(player.currentTime == 0 && model.playbackTime == 0, "Real seek before start clamps to zero")
        check(model.paused && !model.playing && !player.isPlaying, "Real seek never starts audio output")
        print("READING_PLAYBACK_REAL_PLAYER_OK: \(count) checks; 45-second synthetic WAV, no playback")
    }
}
'''.replace("__EXACT_METHODS__", methods)

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
    audio = directory / "synthetic-silence.wav"
    write_audio(audio)
    for name, fixture, arguments in [
        ("ModelChecks", model_fixture, []),
        ("RealPlayerChecks", real_fixture, [str(audio)]),
    ]:
        harness = directory / f"{name}.swift"
        harness.write_text(fixture)
        binary = directory / name
        subprocess.run([
            "swiftc", "-parse-as-library", "-swift-version", "5", "-module-cache-path", str(directory / "ModuleCache"),
            str(harness), "-o", str(binary),
        ], check=True, timeout=120)
        subprocess.run([str(binary), *arguments], check=True, timeout=15)
print(f"Exact application methods SHA-256: {hashlib.sha256(methods.encode()).hexdigest()}")
print(f"Compilation and checks: {time.monotonic() - started:.3f}s")
