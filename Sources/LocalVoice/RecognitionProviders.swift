import Foundation
import FluidAudio

enum RecognitionProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case parakeet, localServer
    var id: String { rawValue }
    var title: String { self == .parakeet ? "Parakeet on this Mac" : "Local model server" }
}

struct RecognitionConfiguration: Codable, Equatable, Sendable {
    var provider: RecognitionProvider = .parakeet
    var endpoint = "http://127.0.0.1:8080/v1/audio/transcriptions"
    var model = "whisper-1"

    var summary: String {
        provider == .parakeet ? "Parakeet v2 · English · on this Mac" : "\(model) · local server · connection checked on use"
    }

    func validated() throws -> RecognitionConfiguration {
        var result = self
        result.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        result.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        // Also validate inactive server settings: no unsafe URL is persisted for a later switch.
        _ = try LocalTranscriptionEndpoint.validate(result.endpoint)
        guard !result.model.isEmpty, result.model.utf8.count <= 256,
              !result.model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw VoiceError.message("Enter the model name your local server expects (up to 256 bytes, without line breaks).")
        }
        return result
    }
}

struct RecognitionConfigurationStore {
    private let defaults: UserDefaults
    private let key = "workbench.recognition.configuration.v1"
    // Standard defaults use the current bundle domain, isolating Workbench and Workbench Preview.
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() throws -> RecognitionConfiguration {
        guard let data = defaults.data(forKey: key) else { return RecognitionConfiguration() }
        return try JSONDecoder().decode(RecognitionConfiguration.self, from: data).validated()
    }
    func save(_ configuration: RecognitionConfiguration) throws {
        defaults.set(try JSONEncoder().encode(configuration.validated()), forKey: key)
    }
}

/// The app calls one engine from its window, hotkeys and App Intents.
/// A selection is captured before any await. Changes are refused while a request is active.
actor RecognitionEngine {
    private let store: RecognitionConfigurationStore
    private var selected = RecognitionConfiguration()
    private var configurationError: String?
    private var manager: AsrManager?
    private var preparation: Task<AsrManager, Error>?
    private var preparedConfiguration: RecognitionConfiguration?
    private var transcribing = false
    private var liveSessionID: UUID?
    /// Told what a model setup is doing now, from whichever door started it: Home, Settings ›
    /// Models or a first transcription. Each word is the person's, never a file name.
    private var progressObserver: (@Sendable (String) -> Void)?
    func observeProgress(_ observer: @escaping @Sendable (String) -> Void) { progressObserver = observer }
    /// One line for a download step: checking the files, the share downloaded, then the
    /// one-time preparation for this Mac.
    static func progressLine(_ progress: DownloadProgress, model: String = "Parakeet") -> String {
        switch progress.phase {
        case .listing: return "Checking \(model) files…"
        case .downloading:
            let percent = Int((min(1, max(0, progress.fractionCompleted)) * 100).rounded(.down))
            return "Downloading \(model) · \(percent)%"
        case .compiling: return "Preparing \(model) for this Mac…"
        }
    }

    init(store: RecognitionConfigurationStore = RecognitionConfigurationStore()) {
        self.store = store
        do { selected = try store.load() }
        catch { configurationError = "Saved model settings could not be read. Choose and apply a model in Settings. \(error.localizedDescription)" }
    }

    var isReady: Bool { configurationError == nil && preparedConfiguration == selected }
    func configuration() -> RecognitionConfiguration { selected }
    func statusDescription() -> String { configurationError ?? (isReady ? selected.summary : "\(selected.provider.title) · needs setup") }

    func configure(_ configuration: RecognitionConfiguration) throws {
        guard !transcribing, preparation == nil, liveSessionID == nil else {
            throw VoiceError.message("Finish the current model setup or transcription before switching models.")
        }
        let validated = try configuration.validated()
        try store.save(validated)
        if validated != selected { preparedConfiguration = nil }
        selected = validated
        configurationError = nil
        // Keep only the selected engine in memory. FluidAudio's disk cache remains reusable.
        if selected.provider != .parakeet { manager = nil }
    }

    func prepare() async throws {
        if let configurationError { throw VoiceError.message(configurationError) }
        let snapshot = selected
        if preparedConfiguration == snapshot { return }
        _ = try snapshot.validated()
        switch snapshot.provider {
        case .parakeet:
            if manager == nil {
                let task: Task<AsrManager, Error>
                if let preparation { task = preparation }
                else {
                    let observer = progressObserver
                    task = Task {
                        let models = try await AsrModels.downloadAndLoad(version: .v2, progressHandler: { progress in
                            observer?(RecognitionEngine.progressLine(progress))
                        })
                        try Task.checkCancellation()
                        let engine = AsrManager(config: .default)
                        try await engine.loadModels(models)
                        return engine
                    }
                    preparation = task
                }
                do { manager = try await task.value; preparation = nil }
                catch { preparation = nil; throw error }
            }
        case .localServer:
            // There is no universal readiness API for transcription servers. Never call an
            // unrelated health URL or send private audio as a hidden probe.
            break
        }
        try Task.checkCancellation()
        preparedConfiguration = snapshot
    }

    func transcribe(_ url: URL) async throws -> String {
        guard !transcribing, liveSessionID == nil else { throw VoiceError.message("A transcription is already running. Wait for it to finish.") }
        try Task.checkCancellation()
        let snapshot = selected
        transcribing = true
        defer { transcribing = false }
        try await prepare()
        let text: String
        switch snapshot.provider {
        case .parakeet:
            guard let manager else { throw VoiceError.message("The speech model is not ready. Try preparing it again.") }
            var decoderState = try TdtDecoderState(decoderLayers: 2)
            var transcript = try await manager.transcribe(url, decoderState: &decoderState).text
            // A recording longer than one window gets its ending read again (TranscriptEnding).
            // A file whose ending cannot be read keeps the transcript it has.
            if let ending = try? TranscriptEnding.window(of: url) {
                try Task.checkCancellation()
                var endingState = try TdtDecoderState(decoderLayers: 2)
                transcript = TranscriptEnding.stitch(transcript, ending: try await manager.transcribe(ending, decoderState: &endingState).text)
            }
            text = transcript
        case .localServer:
            let request = try LocalTranscriptionEndpoint.request(audio: url, configuration: snapshot)
            text = try LocalTranscriptionEndpoint.decode(await LocalTranscriptionTransport().send(request))
        }
        try Task.checkCancellation()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reserve the selected model for the entire capture, including the gaps between live
    /// windows. Local servers retain their explicit file-transcription path.
    func beginLiveSession(_ id: UUID) throws -> Bool {
        guard !transcribing, liveSessionID == nil else { throw VoiceError.message("Finish the current transcription first.") }
        if let configurationError { throw VoiceError.message(configurationError) }
        liveSessionID = id
        return selected.provider == .parakeet
    }

    func endLiveSession(_ id: UUID) { if liveSessionID == id { liveSessionID = nil } }

    func transcribeLive(_ samples: [Float], sessionID: UUID) async throws -> [LiveVoiceWord] {
        guard liveSessionID == sessionID, !transcribing else { throw VoiceError.message("The live speech session is no longer available.") }
        guard (4_800...240_000).contains(samples.count) else { throw VoiceError.message("The live audio window has an invalid length.") }
        transcribing = true
        defer { transcribing = false }
        try Task.checkCancellation()
        try await prepare()
        guard liveSessionID == sessionID, let manager else { throw CancellationError() }
        // Fresh state per overlapping window and source. Its internal arrays are references.
        var decoderState = try TdtDecoderState(decoderLayers: 2)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        try Task.checkCancellation()
        guard liveSessionID == sessionID else { throw CancellationError() }
        let words = result.tokenTimings.map { buildWordTimings(from: $0) } ?? []
        guard result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !words.isEmpty else {
            throw VoiceError.message("The speech model did not return word timing. The original recording is kept for transcription.")
        }
        return words.map { LiveVoiceWord(text: $0.word, start: $0.startTime, end: $0.endTime) }
    }
}

enum LocalTranscriptionEndpoint {
    static let maximumAudioBytes = 64 * 1024 * 1024
    static let maximumResponseBytes = 2 * 1024 * 1024
    static let timeout: TimeInterval = 180

    static func validate(_ value: String) throws -> URL {
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !components.path.isEmpty, components.path != "/",
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw VoiceError.message("Use a full HTTP or HTTPS transcription URL on 127.0.0.1, localhost or [::1]. Remote hosts, credentials and query strings are not allowed.")
        }
        // Do not resolve localhost through DNS, a proxy, or an editable hosts entry.
        if host == "localhost" { components.host = "127.0.0.1" }
        guard let url = components.url else { throw VoiceError.message("The local transcription URL is invalid.") }
        return url
    }

    static func request(audio: URL, configuration: RecognitionConfiguration) throws -> URLRequest {
        let configuration = try configuration.validated()
        let endpoint = try validate(configuration.endpoint)
        guard audio.isFileURL else { throw VoiceError.message("Choose an audio file stored on this Mac.") }
        let attributes = try audio.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, let size = attributes.fileSize, size > 0, size <= maximumAudioBytes else {
            throw VoiceError.message("Choose a non-empty audio file up to 64 MB for the local server.")
        }
        let ext = audio.pathExtension.lowercased()
        let types = ["wav": "audio/wav", "m4a": "audio/mp4", "mp3": "audio/mpeg", "flac": "audio/flac"]
        guard let mime = types[ext] else {
            throw VoiceError.message("The local server connection accepts WAV, M4A, MP3 or FLAC files. Convert this recording to WAV or use Parakeet.")
        }
        let handle = try FileHandle(forReadingFrom: audio)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: maximumAudioBytes + 1) ?? Data()
        guard !bytes.isEmpty, bytes.count <= maximumAudioBytes else {
            throw VoiceError.message("The audio file is empty or exceeds the 64 MB local-server limit.")
        }
        let boundary = "Workbench-" + UUID().uuidString
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(configuration.model)\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.\(ext)\"\r\nContent-Type: \(mime)\r\n\r\n")
        body.append(bytes)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    static func decode(_ data: Data) throws -> String {
        guard data.count <= maximumResponseBytes else { throw VoiceError.message("The local server response exceeded 2 MB.") }
        struct Response: Decodable { let text: String }
        guard let result = try? JSONDecoder().decode(Response.self, from: data) else {
            throw VoiceError.message("The local server must return a JSON object with a text field. Check its transcription endpoint and model name.")
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceError.message("The local server returned no speech. Check the audio and selected model.") }
        return text
    }
}

/// A fresh ephemeral session per invocation. The delegate enforces the response limit
/// while bytes arrive, refuses every redirect, and resolves cancellation exactly once.
final class LocalTranscriptionTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var finished = false
    private var cancelled = false

    func send(_ request: URLRequest) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = LocalTranscriptionEndpoint.timeout
                config.timeoutIntervalForResource = LocalTranscriptionEndpoint.timeout
                config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
                config.urlCredentialStorage = nil; config.connectionProxyDictionary = [:]
                config.waitsForConnectivity = false
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true; self.continuation = nil
        let session = self.session; self.session = nil; self.task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        finish(.failure(VoiceError.message("The local server redirected the request. Use its final loopback transcription URL; redirects are never followed.")))
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            finish(.failure(VoiceError.message("Local transcription server returned HTTP \(status). Check its endpoint, model and server log. No other provider was used.")))
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Int64(LocalTranscriptionEndpoint.maximumResponseBytes) else {
            finish(.failure(VoiceError.message("The local server response exceeded 2 MB.")))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count + chunk.count <= LocalTranscriptionEndpoint.maximumResponseBytes else {
            lock.unlock(); finish(.failure(VoiceError.message("The local server response exceeded 2 MB."))); return
        }
        data.append(chunk)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let urlError = error as? URLError
            let message = urlError?.code == .timedOut
                ? "The local server did not finish within 3 minutes. Try a shorter recording or a faster model."
                : "Could not reach the local transcription server. Start it on this Mac and check the endpoint. No other provider was used."
            finish(.failure(VoiceError.message(message)))
        } else {
            lock.lock(); let result = data; lock.unlock()
            finish(.success(result))
        }
    }
}
