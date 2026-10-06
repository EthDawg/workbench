import AVFoundation
import Foundation

/// Renders one reading with a Mac voice through AVSpeechSynthesizer, far faster
/// than real time. Audio is appended to a growing WAV as it arrives, so playback
/// can start with the first fraction of a second. Word callbacks arrive during
/// rendering, not playback, so each word is recorded at the audio frame reached
/// when its callback arrives; playback then follows its own clock.
@MainActor
final class MacSpeechRenderer: NSObject, AVSpeechSynthesizerDelegate, ReadingRenderer {
    /// Playback may start once this much audio exists (or the reading ended).
    static let startSeconds = 0.25
    /// No audio for this long means the voice stopped responding.
    static let stallSeconds: TimeInterval = 20

    let text: ListeningText
    let folder: URL
    private(set) var audio: ReadingAudioFile?
    private(set) var marks = ReadingMarks()
    private(set) var isFinished = false
    private(set) var failure: Error?
    /// New audio exists. Called for every rendered buffer, so keep it cheap.
    var onAudio: (() -> Void)?
    /// Called once, when the reading has completely rendered or failed.
    var onFinish: ((Error?) -> Void)?

    private var synthesizer: AVSpeechSynthesizer?
    private var utterance: AVSpeechUtterance?
    private var watchdog: Timer?
    private var lastActivity = Date()
    private var stopped = false
    private var waiters: [(complete: Bool, continuation: CheckedContinuation<Void, Error>)] = []

    init(text: ListeningText) throws {
        self.text = text
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalVoice-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        super.init()
    }

    func start(voiceIdentifier: String, rate: Float) throws {
        guard !stopped, synthesizer == nil else { return }
        // The listed voice object: a reading starts from a Swift task, where a
        // voice lookup would log an Accessibility fault (#269).
        guard let voice = MacVoiceCatalog.voice(identifier: voiceIdentifier) else {
            fail(VoiceError.message("This voice is no longer installed. Choose another voice."))
            throw failure!
        }
        let utterance = AVSpeechUtterance(string: text.spoken)
        utterance.voice = voice
        utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        self.utterance = utterance
        self.synthesizer = synthesizer
        lastActivity = Date()
        let watchdog = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, Date().timeIntervalSince(self.lastActivity) > Self.stallSeconds else { return }
                self.fail(VoiceError.message("The voice stopped responding. Try Listen again, or choose another voice."))
            }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
        // Buffers arrive on the main queue; a zero-length buffer marks the end
        // (it can arrive twice, so completion is idempotent).
        synthesizer.write(utterance) { [weak self] buffer in
            Self.onMain { self?.receive(buffer) }
        }
    }

    /// Returns once playback can start, or with `complete`, once the whole
    /// reading exists. Cancelling the task stops rendering and removes its audio.
    func ready(complete: Bool) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if let failure { continuation.resume(throwing: failure) }
                else if stopped && !isFinished { continuation.resume(throwing: CancellationError()) }
                else if satisfied(complete) { continuation.resume() }
                else { waiters.append((complete, continuation)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    /// Stops rendering at once and removes its files. Later callbacks are ignored.
    func cancel() {
        let wasRunning = !stopped
        stopped = true
        release()
        discard()
        if wasRunning { resumeWaiters(throwing: CancellationError()) }
    }

    func discard() {
        audio?.close()
        try? FileManager.default.removeItem(at: folder)
    }

    private func receive(_ buffer: AVAudioBuffer) {
        guard !stopped, let buffer = buffer as? AVAudioPCMBuffer else { return }
        lastActivity = Date()
        guard buffer.frameLength > 0 else { finish(); return }
        do {
            if audio == nil {
                audio = try ReadingAudioFile(url: folder.appendingPathComponent("speech.wav"), sampleRate: buffer.format.sampleRate)
            }
            try audio?.append(buffer)
        } catch {
            fail(error)
            return
        }
        resumeSatisfiedWaiters()
        onAudio?()
    }

    private func finish() {
        guard !stopped else { return }
        do {
            guard let audio, audio.availableFrames > 0 else {
                throw VoiceError.message("This voice produced no audio. Choose another installed voice and try again.")
            }
            try audio.finish()
        } catch {
            fail(error)
            return
        }
        stopped = true
        isFinished = true
        release()
        onFinish?(nil)
        resumeSatisfiedWaiters()
    }

    private func fail(_ error: Error) {
        guard !stopped else { return }
        stopped = true
        failure = error
        release()
        discard()
        onFinish?(error)
        resumeWaiters(throwing: error)
    }

    /// Releasing the synthesizer is what actually stops a write in progress;
    /// stopSpeaking alone lets it keep rendering.
    private func release() {
        watchdog?.invalidate()
        watchdog = nil
        synthesizer?.delegate = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
    }

    private func satisfied(_ complete: Bool) -> Bool {
        if isFinished { return true }
        guard !complete, let audio else { return false }
        return Double(audio.availableFrames) >= Self.startSeconds * audio.format.sampleRate
    }

    private func resumeSatisfiedWaiters() {
        guard !waiters.isEmpty else { return }
        let ready = waiters.filter { satisfied($0.complete) }
        waiters.removeAll { satisfied($0.complete) }
        ready.forEach { $0.continuation.resume() }
    }

    private func resumeWaiters(throwing error: Error) {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume(throwing: error) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Self.onMain { [weak self] in
            guard let self, !self.stopped, utterance === self.utterance else { return }
            self.marks.append(frame: self.audio?.availableFrames ?? 0, range: self.text.originalRange(forSpoken: characterRange))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Normally the zero-length buffer already finished the reading.
        Self.onMain { [weak self] in
            guard let self, utterance === self.utterance else { return }
            self.finish()
        }
    }

    /// Speech callbacks arrive on the main queue; run them in order right away,
    /// and hop there if a future system delivers them elsewhere.
    nonisolated private static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated(work) } else { DispatchQueue.main.async { MainActor.assumeIsolated(work) } }
    }
}
