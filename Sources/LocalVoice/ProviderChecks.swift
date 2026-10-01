import Foundation
import Network

enum ProviderChecks {
    static func run() throws {
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw VoiceError.message("PROVIDER CHECK FAILED: \(label)") }
            count += 1
        }
        func rejects(_ label: String, _ body: () throws -> Void) throws {
            do { try body() } catch { count += 1; return }
            throw VoiceError.message("PROVIDER CHECK FAILED: \(label)")
        }
        for url in ["http://127.0.0.1:8080/v1/audio/transcriptions", "https://[::1]:8080/transcribe", "http://localhost:8080/v1/audio/transcriptions"] {
            _ = try LocalTranscriptionEndpoint.validate(url); count += 1
        }
        try check(LocalTranscriptionEndpoint.validate("http://localhost:8080/v1/audio/transcriptions").host == "127.0.0.1", "localhost pinned without DNS")
        for url in ["https://api.openai.com/v1/audio/transcriptions", "http://localhost.example.com/transcribe", "http://127.0.0.1.example.com/transcribe", "http://127.1/transcribe", "http://2130706433/transcribe", "http://127.0.0.2/transcribe", "http://user:secret@127.0.0.1/transcribe", "http://127.0.0.1/transcribe?key=secret", "http://127.0.0.1/transcribe#fragment", "file:///tmp/audio.wav", "ftp://127.0.0.1/transcribe", "http://127.0.0.1/", "http://127.0.0.1:0/transcribe", "http://127.0.0.1:65536/transcribe"] {
            try rejects("unsafe endpoint: \(url)") { _ = try LocalTranscriptionEndpoint.validate(url) }
        }
        try rejects("multipart model injection") { _ = try RecognitionConfiguration(model: "whisper\r\nInjected: value").validated() }
        try rejects("empty model") { _ = try RecognitionConfiguration(model: "  ").validated() }
        try rejects("oversized model") { _ = try RecognitionConfiguration(model: String(repeating: "m", count: 257)).validated() }
        let suiteName = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench.ProviderChecks." + UUID().uuidString).path
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RecognitionConfigurationStore(defaults: defaults)
        try check(store.load() == RecognitionConfiguration(), "fresh provider selection")
        let local = RecognitionConfiguration(provider: .localServer, model: "local-test-model")
        try store.save(local)
        try check(store.load() == local, "provider selection survives reload")
        defaults.set(Data("broken".utf8), forKey: "workbench.recognition.configuration.v1")
        try rejects("damaged settings reported rather than silently overwritten") { _ = try store.load() }
        try check(defaults.data(forKey: "workbench.recognition.configuration.v1") == Data("broken".utf8), "damaged settings preserved")
        try check(LocalTranscriptionEndpoint.decode(Data("{\"text\":\"  synthetic words  \"}".utf8)) == "synthetic words", "transcription JSON contract")
        for invalid in ["{}", "{\"text\":12}", "{\"text\":\"  \"}", "<html>server error</html>"] {
            try rejects("malformed or empty response") { _ = try LocalTranscriptionEndpoint.decode(Data(invalid.utf8)) }
        }
        try rejects("response size bounded") { _ = try LocalTranscriptionEndpoint.decode(Data(repeating: 32, count: LocalTranscriptionEndpoint.maximumResponseBytes + 1)) }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProviderChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("private-original-name.wav")
        try Data("synthetic-audio-test-bytes".utf8).write(to: audio)
        let request = try LocalTranscriptionEndpoint.request(audio: audio, configuration: local)
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        try check(request.httpMethod == "POST" && request.url?.host == "127.0.0.1", "POST routed to chosen loopback endpoint")
        try check(body.contains("name=\"model\"\r\n\r\nlocal-test-model") && body.contains("name=\"response_format\"\r\n\r\njson"), "selected model and JSON format sent")
        try check(body.contains("filename=\"audio.wav\"") && !body.contains("private-original-name"), "original filename omitted")
        let unsupported = directory.appendingPathComponent("model.gguf")
        try Data("not-audio".utf8).write(to: unsupported)
        try rejects("arbitrary model file not treated as audio") { _ = try LocalTranscriptionEndpoint.request(audio: unsupported, configuration: local) }
        let empty = directory.appendingPathComponent("empty.wav")
        try Data().write(to: empty)
        try rejects("empty audio rejected") { _ = try LocalTranscriptionEndpoint.request(audio: empty, configuration: local) }
        let oversized = directory.appendingPathComponent("oversized.wav")
        _ = FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(LocalTranscriptionEndpoint.maximumAudioBytes + 1)); try handle.close()
        try rejects("oversized audio rejected before reading") { _ = try LocalTranscriptionEndpoint.request(audio: oversized, configuration: local) }
        print("PROVIDER_CHECKS_OK: \(count) checks passed")
    }

    /// Exercises the real URLSession stack against an ephemeral loopback fixture.
    /// This sends synthetic bytes, never microphone or user recordings.
    static func runTransportChecks() async throws {
        func step(_ label: String) { print("PROVIDER_TRANSPORT: \(label)"); fflush(stdout) }
        func assert(_ value: Bool, _ label: String) throws {
            guard value else { throw VoiceError.message("PROVIDER TRANSPORT CHECK FAILED: \(label)") }
        }
        func request(_ port: UInt16, path: String = "/transcribe") -> URLRequest {
            var result = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, timeoutInterval: 2)
            result.httpMethod = "POST"; result.httpBody = Data("synthetic".utf8)
            return result
        }
        step("successful response")
        let success = try await ProviderFixture.start(response: "HTTP/1.1 200 OK\r\nContent-Length: 26\r\nConnection: close\r\n\r\n{\"text\":\"fixture success\"}")
        defer { success.stop() }
        let data = try await LocalTranscriptionTransport().send(request(success.port))
        try assert(try LocalTranscriptionEndpoint.decode(data) == "fixture success", "real loopback request succeeds")

        step("redirect refusal")
        let redirect = try await ProviderFixture.start(response: "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(success.port)/should-not-be-called\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { redirect.stop() }
        do { _ = try await LocalTranscriptionTransport().send(request(redirect.port)); throw VoiceError.message("PROVIDER TRANSPORT CHECK FAILED: redirect followed") }
        catch let error as VoiceError { try assert(error.localizedDescription.contains("redirected"), "redirect has actionable failure") }
        try assert(success.requestCount == 1, "redirect target never receives another request")

        step("HTTP error")
        let failure = try await ProviderFixture.start(response: "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { failure.stop() }
        do { _ = try await LocalTranscriptionTransport().send(request(failure.port)); throw VoiceError.message("PROVIDER TRANSPORT CHECK FAILED: 503 accepted") }
        catch let error as VoiceError { try assert(error.localizedDescription.contains("HTTP 503"), "HTTP failure explained") }

        step("advertised response size")
        let oversized = try await ProviderFixture.start(response: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(LocalTranscriptionEndpoint.maximumResponseBytes + 1)\r\nConnection: close\r\n\r\nx", holdOpen: true)
        defer { oversized.stop() }
        do { _ = try await LocalTranscriptionTransport().send(request(oversized.port)); throw VoiceError.message("PROVIDER TRANSPORT CHECK FAILED: oversized accepted") }
        catch let error as VoiceError { try assert(error.localizedDescription.contains("2 MB"), "response rejected from headers; received: \(error.localizedDescription)") }

        step("streamed response size")
        let streamed = try await ProviderFixture.start(response: "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n" + String(repeating: "x", count: LocalTranscriptionEndpoint.maximumResponseBytes + 8192), holdOpen: true)
        defer { streamed.stop() }
        do { _ = try await LocalTranscriptionTransport().send(request(streamed.port)); throw VoiceError.message("PROVIDER TRANSPORT CHECK FAILED: unbounded streamed response accepted") }
        catch let error as VoiceError { try assert(error.localizedDescription.contains("2 MB"), "response bounded without content length") }

        step("cancellation")
        let hanging = try await ProviderFixture.start(response: nil)
        defer { hanging.stop() }
        let task = Task { try await LocalTranscriptionTransport().send(request(hanging.port)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; throw VoiceError.message("PROVIDER TRANSPORT CHECK FAILED: cancellation ignored") }
        catch is CancellationError { }

        step("model switch isolation")
        let suiteName = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench.ProviderEngineChecks." + UUID().uuidString).path
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let engine = RecognitionEngine(store: RecognitionConfigurationStore(defaults: defaults))
        let configuration = RecognitionConfiguration(provider: .localServer, endpoint: "http://127.0.0.1:\(hanging.port)/transcribe", model: "fixture")
        try await engine.configure(configuration); try await engine.prepare()
        try assert(await engine.isReady, "local-server readiness is configuration readiness")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ProviderEngine-" + UUID().uuidString + ".wav")
        try Data("synthetic".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let inFlight = Task { try await engine.transcribe(file) }
        try await Task.sleep(for: .milliseconds(100))
        do { try await engine.configure(RecognitionConfiguration()); throw VoiceError.message("PROVIDER TRANSPORT CHECK FAILED: in-flight selection mutated") }
        catch let error as VoiceError { try assert(error.localizedDescription.contains("Finish the current"), "model switch refused while processing") }
        inFlight.cancel()
        do { _ = try await inFlight.value; throw VoiceError.message("PROVIDER TRANSPORT CHECK FAILED: engine cancellation ignored") }
        catch is CancellationError { }
        try assert(await engine.configuration() == configuration, "cancelled request retains selection and never falls back")
        print("PROVIDER_TRANSPORT_CHECKS_OK: loopback, redirect, HTTP failure, size bound, cancellation, switch isolation")
    }
}

/// Test-only fixture. Listener binds explicitly to IPv4 loopback on an unused port.
private final class ProviderFixture: @unchecked Sendable {
    private let listener: NWListener
    private let response: Data?
    private let holdOpen: Bool
    private let queue = DispatchQueue(label: "Workbench.ProviderFixture")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var count = 0
    private var deliveredStartup = false
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    var port: UInt16 { listener.port!.rawValue }

    private init(response: String?, holdOpen: Bool) throws {
        self.response = response.map { Data($0.utf8) }
        self.holdOpen = holdOpen
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start(response: String?, holdOpen: Bool = false) async throws -> ProviderFixture {
        let fixture = try ProviderFixture(response: response, holdOpen: holdOpen)
        return try await withCheckedThrowingContinuation { continuation in
            // Listener callbacks are serial on its private queue.
            fixture.listener.stateUpdateHandler = { state in
                switch state {
                case .ready where !fixture.deliveredStartup:
                    fixture.deliveredStartup = true; continuation.resume(returning: fixture)
                case .failed(let error) where !fixture.deliveredStartup:
                    fixture.deliveredStartup = true; continuation.resume(throwing: error)
                default: break
                }
            }
            fixture.listener.newConnectionHandler = { [weak fixture] connection in
                guard let fixture else { connection.cancel(); return }
                fixture.lock.lock(); fixture.connections.append(connection); fixture.lock.unlock()
                connection.start(queue: fixture.queue)
                fixture.receive(connection, buffer: Data())
            }
            fixture.listener.start(queue: fixture.queue)
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, complete, error in
            guard let self else { return }
            var buffer = buffer; if let bytes { buffer.append(bytes) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.lock.lock(); self.count += 1; self.lock.unlock()
                guard let response = self.response else { return }
                // Oversize fixtures stay alive so an intentionally incomplete body
                // cannot mask the limit check with a connection-truncated error.
                connection.send(content: response, completion: .contentProcessed { _ in
                    if !self.holdOpen { connection.cancel() }
                })
            } else if !complete && error == nil && buffer.count < 32_768 {
                self.receive(connection, buffer: buffer)
            } else { connection.cancel() }
        }
    }

    func stop() {
        listener.cancel()
        lock.lock(); let current = connections; connections = []; lock.unlock()
        current.forEach { $0.cancel() }
    }
}
