#!/usr/bin/env python3
"""Exercise the real audio writer with synthetic PCM, without audio devices."""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from swift_extract import SwiftFile

ROOT = Path(__file__).resolve().parents[1]
audio = SwiftFile(ROOT / "Sources/LocalVoice/MeetingAudio.swift").extract([
    "MeetingClock", "MeetingAudioChunk", "MeetingCaptureTimeline", "MeetingTrackTiming",
    "MeetingAudioGap", "MeetingAudioFeed", "MeetingTrackRecorder",
])
models = SwiftFile(ROOT / "Sources/LocalVoice/MeetingModels.swift").extract([
    "MeetingTrackSource", "MeetingTrack", "MeetingError",
])
harness = r'''
import AVFoundation
import CoreAudio
import Darwin
import Foundation

enum MeetingDiskBudget { static let captureBufferSeconds = 8.0 }
enum MeetingSegmentPlan { static let maximumMeetingSeconds = 7_200.0 }
enum MeetingManifest { static let currentFormat = 1 }
enum MeetingStore {
    static let tracksDirectory = "tracks"
    static func rejectSymbolicLinks(in url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw MeetingError.message("Symlink refused")
        }
    }
    static func writePrivate(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
}
final class Chunks: @unchecked Sendable {
    let lock = NSLock()
    var chunks: [MeetingAudioChunk] = []
    func add(_ chunk: MeetingAudioChunk) { lock.lock(); chunks.append(chunk); lock.unlock() }
    var values: [MeetingAudioChunk] { lock.lock(); defer { lock.unlock() }; return chunks }
}

@main struct Checks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw MeetingError.message("CAPTURE_CONTINUITY_FAILED: " + label) }
            count += 1
        }
        func directory(_ name: String) throws -> URL {
            let result = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
            return result
        }
        func append(_ recorder: MeetingTrackRecorder, _ samples: [Float], _ start: Double, _ rate: Double, _ host: UInt64) {
            samples.withUnsafeBufferPointer {
                recorder.append($0.baseAddress!, count: samples.count,
                                hostTime: host + AVAudioTime.hostTime(forSeconds: start), sourceRate: rate)
            }
        }
        let host = MeetingClock.now()
        let chunks = Chunks()
        let dir = try directory("continuity")
        let writer = try MeetingTrackRecorder(source: .local, directory: dir, sampleRate: 16_000,
            timeline: MeetingCaptureTimeline(), allowsDiscontinuities: true, onAudio: { chunks.add($0) })
        try writer.open()
        // 100ms at16k, then a48k route, then a resumed16k route21s later.
        append(writer, [Float](repeating: 0.25, count: 1_600), 0, 16_000, host)
        for index in 0..<10 {
            append(writer, [Float](repeating: 0.5, count: 4_800), 0.1 + Double(index) * 0.1, 48_000, host)
        }
        writer.markDiscontinuity("Recording was paused.")
        append(writer, [Float](repeating: 0.75, count: 1_600), 21, 16_000, host)
        let track = writer.close()
        try check(writer.failure == nil, "rate switch and pause keep original open")
        try check(abs(track.seconds - 21.1) < 0.003, "the pause keeps wall-clock placement")
        try check(track.sampleRate == 16_000 && track.droppedSeconds == 0, "fixed original sample rate loses no buffers")
        let file = try AVAudioFile(forReading: writer.url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let pcm = buffer.floatChannelData![0]
        try check(abs(pcm[800] - 0.25) < 0.001 && abs(pcm[8_000] - 0.5) < 0.02,
                  "original and changed-route speech retain samples")
        try check(abs(pcm[160_000]) < 0.0001 && abs(pcm[336_800] - 0.75) < 0.001,
                  "pause is silence and resumed speech is at its real timestamp")
        let timing = try JSONDecoder().decode(MeetingTrackTiming.self, from: Data(contentsOf: dir.appendingPathComponent("local.json")))
        try check(timing.gaps?.count == 1 && timing.gaps?.first?.reason == "Recording was paused.", "gap reason survives in sidecar: \(String(describing: timing.gaps))")
        try check(abs((timing.gaps?.first?.startSeconds ?? 0) - 1.1) < 0.003 && abs((timing.gaps?.first?.seconds ?? 0) - 19.9) < 0.003,
                  "sidecar records the actual missing interval")
        let live = chunks.values
        let liveEnd = live.last.map { $0.startSeconds + Double($0.samples.count) / $0.sampleRate } ?? 0
        try check(abs(liveEnd - track.seconds) < 0.0001 && live.allSatisfy { $0.sampleRate == 16_000 },
                  "preview uses exact preserved source extents after conversion")
        try check(writer.liveAudioComplete && live.reduce(0) { $0 + $1.samples.count } < 20_000,
                  "preview skips gap padding without dropping speech")

        let strict = try MeetingTrackRecorder(source: .local, directory: directory("strict"), sampleRate: 16_000,
            timeline: MeetingCaptureTimeline())
        try strict.open()
        append(strict, [Float](repeating: 0.25, count: 1_600), 0, 16_000, host)
        append(strict, [Float](repeating: 0.25, count: 1_600), 2, 16_000, host)
        let strictTrack = strict.close()
        try check(abs(strictTrack.seconds - 0.1) < 0.001 && strict.failure != nil,
                  "existing strict writer refuses unapproved discontinuity")

        let waveDir = try directory("dictate")
        let wave = root.appendingPathComponent("dictation.wav")
        let wavWriter = try MeetingTrackRecorder(source: .local, directory: waveDir, sampleRate: 16_000,
            timeline: MeetingCaptureTimeline(), allowsDiscontinuities: true, explicitFileURL: wave)
        try wavWriter.open()
        for index in 0..<10 { append(wavWriter, [Float](repeating: 0.3, count: 4_800), Double(index) * 0.1, 48_000, host) }
        let wavTrack = wavWriter.close()
        let saved = try AVAudioFile(forReading: wave)
        try check(wavWriter.failure == nil && abs(wavTrack.seconds - 1) < 0.003 && saved.fileFormat.sampleRate == 16_000,
                  "Dictate's existing WAV receives converted16k audio directly")
        let before = try Data(contentsOf: wave)
        do {
            let duplicate = try MeetingTrackRecorder(source: .local, directory: waveDir, sampleRate: 16_000,
                timeline: MeetingCaptureTimeline(), explicitFileURL: wave)
            try duplicate.open()
            throw MeetingError.message("existing original overwritten")
        } catch { }
        try check(try Data(contentsOf: wave) == before, "an existing original is never overwritten")

        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let feed = MeetingAudioFeed { _ in entered.signal(); release.wait() }
        let oneSecond = MeetingAudioChunk(source: .local, samples: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000, startSeconds: 0)
        feed.append(oneSecond)
        try check(entered.wait(timeout: .now() + 2) == .success, "slow consumer starts")
        for _ in 0..<12 { feed.append(oneSecond) }
        let began = Date()
        let omitted = feed.finish()
        try check(omitted && Date().timeIntervalSince(began) < 1.5, "preview backlog is bounded and cannot block closing originals")
        release.signal()
        print("CAPTURE_CONTINUITY_OK: \(count) checks; real writer, PCM conversion, timeline, recoverable WAV and bounded preview; no live devices")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="workbench-capture-continuity-", dir="/private/tmp") as temporary:
    directory = Path(temporary)
    fixture = directory / "CaptureChecks.swift"
    fixture.write_text(harness.replace("@main struct Checks", models + "\n" + audio + "\n@main struct Checks"))
    executable = directory / "Checks"
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", "-module-cache-path", str(directory / "ModuleCache"),
                    str(fixture), "-o", str(executable)], check=True, timeout=120)
    subprocess.run([str(executable), str(directory)], check=True, timeout=30)
