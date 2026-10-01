import AVFoundation
import FluidAudio
import Foundation

/// The neural reading voices: one download, then every reading is made on this Mac.
/// The model is Pocket TTS by Kyutai (CC BY 4.0), in FluidInference's Core ML conversion.
enum NeuralVoiceCatalog {
    static let attribution = "Voice model: Pocket TTS by Kyutai, CC BY 4.0."
    static let downloadSize = "about 530 MB"
    static let defaultVoice = "alba"
    /// The English voices in the download. Each is a file name there, never a path.
    static let voices = ["alba", "anna", "azelma", "bill_boerst", "caro_davy", "charles", "cosette", "eponine", "eve", "fantine",
                         "george", "jane", "javert", "jean", "marius", "mary", "michael", "paul", "peter_yearsley", "stuart_bell", "vera"]
    /// "bill_boerst" reads "Bill Boerst".
    static func title(_ voice: String) -> String {
        voice.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
    /// A saved voice that is still in the catalogue, else the default.
    static func resolve(_ saved: String?) -> String {
        saved.flatMap { voices.contains($0) ? $0 : nil } ?? defaultVoice
    }

    /// One mark per sentence: the model reports no word timing, so follow-along moves a
    /// sentence at a time. Ranges are UTF-16 ranges in the spoken text.
    static func sentences(in spoken: String) -> [(range: NSRange, text: String)] {
        let source = spoken as NSString
        var result: [(NSRange, String)] = []
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .bySentences) { sentence, range, _, _ in
            guard let sentence else { return }
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let lead = (sentence as NSString).range(of: trimmed).location
            result.append((NSRange(location: range.location + lead, length: (trimmed as NSString).length), trimmed))
        }
        return result
    }
}

/// Where the download lives and the one loaded model. Nothing here downloads on its own:
/// a reading with a missing download fails with the way to get it.
actor NeuralVoiceStore {
    /// Beside the speech model, so Workbench's models share one folder.
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FluidAudio")
    }
    static let missingMessage = "Neural voices are not downloaded yet. Download them in Settings › Models, or choose Mac voices."

    /// The loaded model uses about 0.7 GB, so it is let go this long after the last reading
    /// asked for it. A reading still being made keeps what it needs; the next one reloads.
    static let idleSeconds: TimeInterval = 300

    let root: URL
    private var manager: PocketTtsManager?
    private var loading: Task<PocketTtsManager, Error>?
    private var uses = 0

    init(root: URL = NeuralVoiceStore.defaultRoot) { self.root = root }

    private nonisolated var repository: URL {
        root.appendingPathComponent(PocketTtsConstants.defaultModelsSubdirectory).appendingPathComponent(Repo.pocketTts.folderName)
    }
    /// Every file a reading loads is present. A stopped download leaves this false.
    nonisolated var isDownloaded: Bool {
        let pack = repository.appendingPathComponent(PocketTtsLanguage.english.repoSubdirectory)
        let files = ModelNames.PocketTTS.requiredModels(precision: .fp16, placement: .gpu)
        return files.allSatisfy { FileManager.default.fileExists(atPath: pack.appendingPathComponent($0).path) }
    }

    /// Fetches the voices once. Progress arrives as whole percentages, in the words the
    /// speech model's setup uses.
    func download(progress: @escaping @Sendable (String) -> Void) async throws {
        let throttle = NeuralVoiceProgress(progress)
        _ = try await PocketTtsResourceDownloader.ensureModels(language: .english, directory: root, progressHandler: { throttle.report($0) })
        try Task.checkCancellation()
        guard isDownloaded else { throw VoiceError.message("The neural voices did not finish downloading. Try again.") }
    }

    /// The loaded model. The first load in a session takes a few seconds.
    func ready() async throws -> PocketTtsManager {
        guard isDownloaded else { throw VoiceError.message(Self.missingMessage) }
        uses += 1
        let use = uses
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleSeconds * 1_000_000_000))
            await self?.release(ifUnusedSince: use)
        }
        if let manager { return manager }
        let task: Task<PocketTtsManager, Error>
        if let loading { task = loading }
        else {
            let root = self.root
            task = Task {
                let manager = PocketTtsManager(directory: root)
                try await manager.initialize()
                return manager
            }
            loading = task
        }
        do { let loaded = try await task.value; loading = nil; manager = loaded; return loaded }
        catch { loading = nil; throw error }
    }

    /// Frees the model's memory when Read moves to another voice source.
    func release() { manager = nil }
    private func release(ifUnusedSince use: Int) { if uses == use, loading == nil { manager = nil } }

    /// Removes the download. The voices can be downloaded again at any time.
    func remove() throws {
        guard loading == nil else { throw VoiceError.message("Wait for the neural voices to finish loading, then remove them.") }
        manager = nil
        guard FileManager.default.fileExists(atPath: repository.path) else { return }
        try FileManager.default.removeItem(at: repository)
    }
}

/// The downloader reports thousands of times; the readiness line needs one per percent.
private final class NeuralVoiceProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ""
    private let forward: @Sendable (String) -> Void
    init(_ forward: @escaping @Sendable (String) -> Void) { self.forward = forward }
    func report(_ progress: DownloadProgress) {
        let line = RecognitionEngine.progressLine(progress, model: "neural voices")
        lock.lock()
        let changed = line != last
        last = line
        lock.unlock()
        if changed { forward(line) }
    }
}

/// The two filters FluidAudio applies to a whole Pocket TTS reading (an 80 Hz rumble filter,
/// then 3 dB less above 6 kHz to soften sibilants), kept running across streamed frames so
/// audio that plays as it is made sounds the same as audio made in one piece.
struct NeuralVoiceFilter {
    private var previousInput: Float = 0, previousOutput: Float = 0, started = false
    private var z1: Float = 0, z2: Float = 0
    private let highPass: Float
    private let b0: Float, b1: Float, b2: Float, a1: Float, a2: Float

    init(sampleRate: Float = 24_000) {
        let rc = 1 / (2 * Float.pi * 80)
        highPass = rc / (rc + 1 / sampleRate)
        let gain = powf(10, -3.0 / 40), omega = 2 * Float.pi * 6_000 / sampleRate
        let cosine = cos(omega), alpha = sin(omega) / (2 * 0.707), root = sqrt(gain)
        let a0 = (gain + 1) - (gain - 1) * cosine + 2 * root * alpha
        b0 = gain * ((gain + 1) + (gain - 1) * cosine + 2 * root * alpha) / a0
        b1 = -2 * gain * ((gain - 1) + (gain + 1) * cosine) / a0
        b2 = gain * ((gain + 1) + (gain - 1) * cosine - 2 * root * alpha) / a0
        a1 = 2 * ((gain - 1) - (gain + 1) * cosine) / a0
        a2 = ((gain + 1) - (gain - 1) * cosine - 2 * root * alpha) / a0
    }

    mutating func apply(_ samples: inout [Float]) {
        for index in samples.indices {
            let input = samples[index]
            // The first sample passes through, as it does in the one-piece filter.
            let passed = started ? highPass * (previousOutput + input - previousInput) : input
            previousOutput = started ? passed : 0
            previousInput = input
            started = true
            let output = b0 * passed + z1
            z1 = b1 * passed - a1 * output + z2
            z2 = b2 * passed - a2 * output
            samples[index] = output
        }
    }
}

/// Renders one reading with a neural voice, faster than real time. Audio is appended to a
/// growing WAV as each 80 ms frame arrives, so playback starts with the first fraction of a
/// second, and each sentence is marked at the frame where it begins.
@MainActor
final class NeuralSpeechRenderer: ReadingRenderer {
    static let sampleRate = 24_000.0
    /// The first reading in a session also loads the model, so allow longer than a Mac voice.
    static let stallSeconds: TimeInterval = 45

    let text: ListeningText
    let folder: URL
    private(set) var audio: ReadingAudioFile?
    private(set) var marks = ReadingMarks()
    private(set) var isFinished = false
    private(set) var failure: Error?
    var onAudio: (() -> Void)?
    var onFinish: ((Error?) -> Void)?

    private var task: Task<Void, Never>?
    private var session: PocketTtsSession?
    private var watchdog: Timer?
    private var lastActivity = Date()
    private var stopped = false
    private var filter = NeuralVoiceFilter(sampleRate: Float(NeuralSpeechRenderer.sampleRate))
    private var waiters: [(complete: Bool, continuation: CheckedContinuation<Void, Error>)] = []

    init(text: ListeningText) throws {
        self.text = text
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalVoice-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    typealias Frames = AsyncThrowingStream<(samples: [Float], sentence: Int?), Error>

    /// Starts with the loaded model. Checks supply `frames` in the model's place: the audio
    /// for the given sentences, each frame naming the sentence it belongs to.
    func start(voice: String, store: NeuralVoiceStore, frames: (([String]) async throws -> Frames)? = nil) {
        guard !stopped, task == nil else { return }
        let sentences = NeuralVoiceCatalog.sentences(in: text.spoken)
        lastActivity = Date()
        let watchdog = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, Date().timeIntervalSince(self.lastActivity) > Self.stallSeconds else { return }
                self.fail(VoiceError.message("The neural voice stopped responding. Try Listen again, or choose Mac voices."))
            }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
        task = Task { [weak self] in
            do {
                guard !sentences.isEmpty else { throw VoiceError.message("This text has nothing to read aloud.") }
                let stream: Frames
                if let frames { stream = try await frames(sentences.map(\.text)) }
                else {
                    let manager = try await store.ready()
                    try Task.checkCancellation()
                    let session = try await manager.makeSession(voice: voice)
                    guard let self, !self.stopped else { await session.cancel(); return }
                    self.session = session
                    for sentence in sentences { session.enqueue(sentence.text) }
                    session.finish()
                    let source = session.frames
                    stream = AsyncThrowingStream { continuation in
                        let pump = Task {
                            do {
                                for try await frame in source { continuation.yield((frame.samples, frame.utteranceIndex)) }
                                continuation.finish()
                            } catch { continuation.finish(throwing: error) }
                        }
                        continuation.onTermination = { _ in pump.cancel() }
                    }
                }
                var marked = -1
                for try await frame in stream {
                    guard let self, !self.stopped else { return }
                    if let sentence = frame.sentence, sentence > marked, sentences.indices.contains(sentence) {
                        marked = sentence
                        self.marks.append(frame: self.audio?.availableFrames ?? 0, range: self.text.originalRange(forSpoken: sentences[sentence].range))
                    }
                    try self.receive(frame.samples)
                }
                // A cancelled stream ends without throwing: only an uncancelled end is a finished reading.
                guard let self, !self.stopped, !Task.isCancelled else { return }
                self.finish()
            } catch is CancellationError {
            } catch { self?.fail(error) }
        }
    }

    /// Returns once playback can start, or with `complete`, once the whole reading exists.
    /// Cancelling the task stops rendering and removes its audio.
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

    /// Stops rendering at once and removes its files. Later frames are ignored.
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

    private func receive(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        lastActivity = Date()
        var samples = samples
        filter.apply(&samples)
        if audio == nil { audio = try ReadingAudioFile(url: folder.appendingPathComponent("speech.wav"), sampleRate: Self.sampleRate) }
        guard let audio, let buffer = AVAudioPCMBuffer(pcmFormat: audio.format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw VoiceError.message("Could not create temporary reading audio.")
        }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try audio.append(buffer)
        resumeSatisfiedWaiters()
        onAudio?()
    }

    private func finish() {
        guard !stopped else { return }
        do {
            guard let audio, audio.availableFrames > 0 else {
                throw VoiceError.message("The neural voice produced no audio. Try Listen again, or choose Mac voices.")
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

    /// Cancelling the session is what stops the model; the task alone would finish its frame.
    private func release() {
        watchdog?.invalidate()
        watchdog = nil
        task?.cancel()
        if let session { self.session = nil; Task { await session.cancel() } }
    }

    private func satisfied(_ complete: Bool) -> Bool {
        if isFinished { return true }
        guard !complete, let audio else { return false }
        return Double(audio.availableFrames) >= MacSpeechRenderer.startSeconds * audio.format.sampleRate
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
}
