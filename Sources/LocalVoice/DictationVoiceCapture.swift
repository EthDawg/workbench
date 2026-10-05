import Foundation

/// Dictate uses the same recoverable microphone and live recognizer as Meetings. The owned
/// WAV is the recovery store's file from the first sample; there is no export step at Stop.
@MainActor
final class DictationVoiceCapture {
    private let capture: MeetingCapture
    private let engine: RecognitionEngine
    let id: UUID
    private var live: LiveVoiceService?
    private var finishing: Task<(MeetingCaptureReport, LiveVoiceCheckpoint?), Never>?
    private let meter = DictationVoiceMeter()
    var elapsed: Double { capture.elapsedSeconds }
    var peak: Float { meter.values.peak }
    var level: Double { meter.values.level }
    var isPaused: Bool { capture.isPaused }
    var problem: String? { capture.stopReason }
    var recoveryMessage: String? { capture.recoveryMessage }

    init(id: UUID, engine: RecognitionEngine, capture: MeetingCapture = MeetingSystemCapture()) {
        self.id = id; self.engine = engine; self.capture = capture
    }

    func start(url: URL, update: @escaping @Sendable (LiveVoiceSnapshot) -> Void) async throws {
        let sidecars = url.deletingLastPathComponent().appendingPathComponent("live-\(id.uuidString)", isDirectory: true)
        try MeetingStore.createPrivateDirectory(sidecars)
        do {
            if try await engine.beginLiveSession(id) {
                let engine = engine, id = id
                live = LiveVoiceService(id: id, sources: [.init(source: .microphone, name: "Microphone")],
                    journal: sidecars.appendingPathComponent("live-transcript.json"),
                    recognize: { try await engine.transcribeLive($0, sessionID: id) }, update: update)
            } else {
                update(LiveVoiceSnapshot(sessionID: id, phase: .listening,
                    sources: [.init(source: .microphone, name: "Microphone")],
                    message: "This model transcribes saved audio when you finish. Live words are available with Parakeet."))
            }
            let input = live?.input, meter = meter
            try await capture.start(MeetingCaptureRequest(tracksDirectory: sidecars, app: nil, includeMicrophone: true,
                onAudio: { audio in
                    meter.append(audio.samples)
                    input?.append(LiveVoiceAudio(source: .microphone, samples: audio.samples,
                        sampleRate: audio.sampleRate, start: audio.startSeconds))
                }, microphoneFileURL: url))
        } catch {
            _ = await finish(recognize: false)
            throw error
        }
    }

    func requestStop() { capture.requestStop() }
    func cancelRecognition() { live?.requestCancel() }
    func pause() async throws { try await capture.pause() }
    func resume() async throws { try await capture.resume() }
    func finish(recognize: Bool = true) async -> (MeetingCaptureReport, LiveVoiceCheckpoint?) {
        if !recognize { live?.requestCancel() }
        if let finishing { return await finishing.value }
        capture.requestStop()
        let task = Task { [capture, live, engine, id] in
            let report = await capture.finish()
            var checkpoint = recognize ? await live?.finish() : await live?.cancel()
            if !report.liveAudioComplete || abs((checkpoint?.completedThrough["microphone"] ?? -1) - report.seconds) >= 0.25 {
                checkpoint?.complete = false
            }
            await engine.endLiveSession(id)
            return (report, checkpoint)
        }
        finishing = task
        return await task.value
    }
}

private final class DictationVoiceMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = -160
    private var level = 0.0
    var values: (peak: Float, level: Double) {
        lock.lock(); defer { lock.unlock() }; return (peak, level)
    }
    func append(_ samples: [Float]) {
        let maximum = samples.reduce(Float(0)) { max($0, abs($1)) }
        let db = maximum > 0 ? 20 * log10(maximum) : -160
        lock.lock(); defer { lock.unlock() }
        peak = max(peak, db); level = max(0, min(1, Double(db + 55) / 55))
    }
}
