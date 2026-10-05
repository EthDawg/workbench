import FluidAudio
import Foundation

/// Explicit developer check with supplied synthetic audio and an already cached model.
/// This is not part of the default suite and never downloads weights or opens a device.
enum LiveVoiceModelCheck {
    static func run(audio: URL, twoSources: Bool = false) async throws {
        guard AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v2), version: .v2) else {
            throw VoiceError.message("The cached Parakeet v2 model is required for this optional check. No download was started.")
        }
        let samples = try AudioConverter().resampleAudioFile(audio)
        guard samples.count >= 16_000 && samples.count <= 960_000 else {
            throw VoiceError.message("Use a synthetic audio fixture between one and sixty seconds.")
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(AsrModels.loadFromCache(version: .v2))
        let probe = Probe(), start = Date()
        let sources: [LiveVoiceSourceStatus] = [.init(source: .microphone, name: "Synthetic fixture")]
            + (twoSources ? [.init(source: .app, name: "Second synthetic source")] : [])
        let service = LiveVoiceService(id: UUID(), sources: sources, journal: nil,
            recognize: { audio in
                var state = try TdtDecoderState(decoderLayers: 2)
                let result = try await manager.transcribe(audio, decoderState: &state)
                guard result.text.isEmpty || result.tokenTimings?.isEmpty == false else { throw VoiceError.message("No word timing returned.") }
                return buildWordTimings(from: result.tokenTimings ?? []).map { .init(text: $0.word, start: $0.startTime, end: $0.endTime) }
            }, update: { probe.observe($0) })
        for offset in stride(from: 0, to: samples.count, by: 16_000) {
            let end = min(samples.count, offset + 16_000)
            try await Task.sleep(nanoseconds: UInt64(Double(end - offset) / 16_000 * 1_000_000_000))
            service.input.append(.init(source: .microphone, samples: Array(samples[offset..<end]), sampleRate: 16_000, start: Double(offset) / 16_000))
            if twoSources { service.input.append(.init(source: .app, samples: Array(samples[offset..<end]), sampleRate: 16_000, start: Double(offset) / 16_000)) }
        }
        let stopped = Date()
        let result = await service.finish()
        print("LIVE_MODEL_FIXTURE sources=\(sources.count) audio_seconds=\(Double(samples.count) / 16_000) first_words_seconds=\(probe.firstWords.map { $0.timeIntervalSince(start) } ?? -1) stop_flush_seconds=\(Date().timeIntervalSince(stopped)) complete=\(result.complete)")
        print("LIVE_MODEL_TEXT: \(result.text)")
        if !result.notes.isEmpty { print("LIVE_MODEL_NOTES: \(result.notes.joined(separator: " "))") }
        guard result.complete else { throw VoiceError.message("The live model fixture required saved-audio fallback.") }
    }
    private final class Probe: @unchecked Sendable {
        let lock = NSLock()
        private var first: Date?
        var firstWords: Date? { lock.lock(); defer { lock.unlock() }; return first }
        func observe(_ snapshot: LiveVoiceSnapshot) {
            lock.lock(); defer { lock.unlock() }
            if first == nil && !snapshot.text.isEmpty { first = Date() }
        }
    }
}
