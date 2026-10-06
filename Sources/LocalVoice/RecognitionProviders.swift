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
    private let services: RecognitionServices
    private var selected = RecognitionConfiguration()
    private var backend: RecognitionBackend?
    private var preparation: Task<PreparedRecognition, Error>?
    private var cancelled = false
    private var transcribing = false
    private var liveSessionID: UUID?
    private var state = RecognitionSnapshot()
    private var observer: (@Sendable (RecognitionSnapshot) -> Void)?

    init(store: RecognitionConfigurationStore = RecognitionConfigurationStore(), services: RecognitionServices = RecognitionLocalModels.live) {
        self.store = store; self.services = services
        do {
            selected = try store.load(); state.configuration = selected
            if selected.provider == .localServer { state.admission = .serverUnverified }
        } catch {
            state.failure = .init(kind: .configuration, message: "Saved model settings could not be read. Choose and apply a model in Models.", details: error.localizedDescription)
        }
    }

    func observe(_ observer: @escaping @Sendable (RecognitionSnapshot) -> Void) { self.observer = observer; observer(state) }
    private func publish() { state.sequence &+= 1; observer?(state) }
    func snapshot() -> RecognitionSnapshot { state }
    var isReady: Bool { state.canTranscribe }
    func configuration() -> RecognitionConfiguration { selected }
    func statusDescription() -> String { state.line }

    static func progressLine(_ progress: DownloadProgress, model: String = "Parakeet") -> String {
        switch progress.phase {
        case .listing: return "Checking \(model) files…"
        case .downloading:
            let percent = Int((min(1, max(0, progress.fractionCompleted)) * 100).rounded(.down))
            return "Downloading \(model) · \(percent)%"
        case .compiling: return "Preparing \(model) for this Mac…"
        }
    }

    func configure(_ configuration: RecognitionConfiguration) throws {
        guard !transcribing, liveSessionID == nil else { throw VoiceError.message("Finish the current transcription before switching models.") }
        let validated = try configuration.validated()
        try store.save(validated)
        guard validated != selected || state.failure?.kind == .configuration else { return }
        cancelPreparation()
        selected = validated; backend = nil
        state.configurationRevision &+= 1; state.configuration = validated
        state.failure = nil
        state.admission = validated.provider == .localServer ? .serverUnverified : .unavailable
        if preparation == nil { state.detail = nil }
        publish()
    }

    /// Startup and Retry saved files may read local files only. Transcription never calls it.
    func prepareCached() async throws { try await prepare(acquire: false) }
    /// The only recognition acquisition door, reached by a deliberate Download action.
    func acquireSelectedModel() async throws { try await prepare(acquire: true) }

    func cancelPreparation() {
        guard preparation != nil else { return }
        cancelled = true; preparation?.cancel()
        state.phase = .cancelling
        state.detail = "Setup cancelled. Any model load already in progress is finishing safely; recording will not start."
        publish()
    }

    private func prepare(acquire: Bool) async throws {
        if state.failure?.kind == .configuration { throw state.failure! }
        guard !transcribing, liveSessionID == nil else { throw VoiceError.message("Finish the current transcription before preparing a model.") }
        guard preparation == nil else { throw VoiceError.message("The previous model operation is still finishing. Wait before trying again.") }
        if state.canTranscribe { return }
        guard selected.provider == .parakeet else { return }
        let id = UUID(), revision = state.configurationRevision
        cancelled = false; state.operationID = id; state.admission = .unavailable; state.failure = nil
        state.phase = acquire ? .downloading : .checkingCache
        state.detail = acquire ? "Downloading Parakeet…" : "Checking saved Parakeet files…"
        publish()
        let services = self.services
        let operation = acquire ? services.acquire : services.prepareCached
        let task = Task { try await operation { phase, line in await self.progress(phase, line, id: id, revision: revision) } }
        preparation = task
        do {
            let prepared = try await task.value
            guard !cancelled, !Task.isCancelled, state.configurationRevision == revision else {
                prepared.discard(); throw CancellationError()
            }
            do { try prepared.adopt() } catch { prepared.discard(); throw error }
            backend = prepared.backend; state.admission = .localReady
            finishPreparation()
        } catch {
            let intentionallyCancelled = cancelled || Task.isCancelled || state.configurationRevision != revision || error is CancellationError
            if !intentionallyCancelled {
                state.failure = RecognitionFailure.classify(error, acquiring: acquire)
            }
            finishPreparation()
            if intentionallyCancelled { throw CancellationError() }
            throw error
        }
    }

    private func finishPreparation() {
        preparation = nil; state.operationID = nil; state.phase = .idle; state.detail = nil; cancelled = false
        publish()
    }
    private func progress(_ phase: RecognitionSnapshot.Phase, _ line: String, id: UUID, revision: UInt64) {
        guard state.operationID == id, state.configurationRevision == revision, !cancelled else { return }
        // Download callbacks can arrive after the loader has moved on; they cannot
        // roll the displayed phase backwards or overwrite a cancelled operation.
        if state.phase == .loading && phase != .loading { return }
        if state.phase == .checkingCache && phase == .downloading { return }
        state.phase = phase; state.detail = line; publish()
    }

    private func requireAdmission() throws {
        guard state.canTranscribe else { throw state.failure ?? RecognitionFailure(kind: .missingAssets, message: "Open Models to prepare speech first. Your recording and saved work are kept.") }
    }

    func transcribe(_ url: URL) async throws -> String {
        guard !transcribing, liveSessionID == nil else { throw VoiceError.message("A transcription is already running. Wait for it to finish.") }
        try Task.checkCancellation(); try requireAdmission()
        let configuration = selected
        transcribing = true; defer { transcribing = false }
        let text: String
        switch configuration.provider {
        case .parakeet:
            guard let backend else { throw CancellationError() }
            text = try await backend.transcribe(url)
        case .localServer:
            do {
                let request = try LocalTranscriptionEndpoint.request(audio: url, configuration: configuration)
                text = try LocalTranscriptionEndpoint.decode(await services.send(request))
                try Task.checkCancellation()
                state.admission = .serverVerified; state.failure = nil; publish()
            } catch {
                if !(error is CancellationError) {
                    state.admission = .serverUnverified
                    state.failure = .init(kind: .service, message: "The configured local server could not transcribe this recording. The original audio is kept; check the server and retry.", details: error.localizedDescription)
                    publish()
                }
                throw error
            }
        }
        try Task.checkCancellation()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func beginLiveSession(_ id: UUID) throws -> Bool {
        guard !transcribing, liveSessionID == nil else { throw VoiceError.message("Finish the current transcription first.") }
        try requireAdmission()
        liveSessionID = id
        return selected.provider == .parakeet
    }
    func endLiveSession(_ id: UUID) { if liveSessionID == id { liveSessionID = nil } }
    func transcribeLive(_ samples: [Float], sessionID: UUID) async throws -> [LiveVoiceWord] {
        guard liveSessionID == sessionID, !transcribing else { throw VoiceError.message("The live speech session is no longer available.") }
        guard (4_800...240_000).contains(samples.count) else { throw VoiceError.message("The live audio window has an invalid length.") }
        try requireAdmission(); try Task.checkCancellation()
        guard let backend else { throw VoiceError.message("The selected server uses the saved recording after capture finishes.") }
        transcribing = true; defer { transcribing = false }
        let words = try await backend.transcribeLive(samples)
        try Task.checkCancellation()
        guard liveSessionID == sessionID else { throw CancellationError() }
        return words
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
