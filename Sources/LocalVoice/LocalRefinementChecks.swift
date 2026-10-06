import AppKit
import Foundation
import Network
import SwiftUI

enum LocalRefinementChecks {
    static func run() throws {
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw LocalRefinementError.message("REFINEMENT CHECK FAILED: " + label) }
            count += 1
        }
        func rejects(_ label: String, _ body: () throws -> Void) throws {
            do { try body() } catch { count += 1; return }
            throw LocalRefinementError.message("REFINEMENT CHECK FAILED: " + label)
        }
        for url in ["http://127.0.0.1:11434", "http://localhost:11434/", "https://[::1]:11434"] {
            _ = try OllamaEndpoint.baseURL(url); count += 1
        }
        try check(OllamaEndpoint.baseURL("http://localhost:11434").host == "127.0.0.1", "localhost bypasses DNS")
        for url in ["https://ollama.com", "http://localhost.example.com", "http://127.1", "http://2130706433", "http://127.0.0.2", "http://user:secret@localhost", "http://127.0.0.1?key=secret", "http://127.0.0.1#x", "file:///tmp/model", "ftp://127.0.0.1", "http://127.0.0.1/api", "http://127.0.0.1:0", "http://127.0.0.1:65536", "http://%6cocalhost"] {
            try rejects("unsafe origin " + url) { _ = try OllamaEndpoint.baseURL(url) }
        }
        for model in ["gemma3:1b", "qwen2.5:3b", "team/local-model:q4_K_M"] {
            try OllamaEndpoint.validateModel(model); count += 1
        }
        for model in ["", " ", "../model", "host.example/model", "http://host/model", "gpt-oss:120b-cloud", "model\nInjected: true", String(repeating: "m", count: 161)] {
            try rejects("unsafe model") { try OllamaEndpoint.validateModel(model) }
        }
        try rejects("large JSON rejected before request") {
            _ = try OllamaEndpoint.request(base: "http://127.0.0.1", path: "generate", body: ["prompt": String(repeating: "x", count: 65536)])
        }
        try rejects("unsupported operation") { _ = try OllamaEndpoint.request(base: "http://127.0.0.1", path: "push") }
        try OllamaEndpoint.requireLocalModel(Data(localMetadata.utf8)); count += 1
        for metadata in ["{}", "{\"remote_host\":\"https://ollama.com\",\"model_info\":{}}", "{\"details\":{\"format\":\"gguf\"},\"model_info\":{\"general.architecture\":\"bert\"},\"capabilities\":[\"embedding\"]}"] {
            try rejects("unknown, remote or nontext model refused") { try OllamaEndpoint.requireLocalModel(Data(metadata.utf8)) }
        }
        try check(OllamaPullProgress.decode(Data("{\"status\":\"pulling\",\"total\":100,\"completed\":50}".utf8)).fraction == 0.5, "download fraction")
        try check(OllamaPullProgress.decode(Data("{\"status\":\"pulling\",\"total\":0,\"completed\":50}".utf8)).fraction == nil, "unknown size stays indeterminate")
        try rejects("pull error is failure") { _ = try OllamaPullProgress.decode(Data("{\"error\":\"failed\"}".utf8)) }
        try check(OllamaClient.decodeEditedText("{\"text\":\"Hello, Sam.\\nBring apples.\"}") == "Hello, Sam.\nBring apples.", "structured output decoded once")
        for invalid in ["Hello, Sam.", "```json\n{\"text\":\"Hello\"}\n```", "{\"text\":\"Hello\",\"advice\":\"Bring a bag\"}", "{\"text\":12}", "{\"text\":\" \"}"] {
            try rejects("wrong response shape is not salvaged") { _ = try OllamaClient.decodeEditedText(invalid) }
        }
        let list = "Shopping list:\n• Apples\n• Pears"
        try check(!DictationCleanup.isFaithful("Shopping list: • Apples • Pears", to: list), "flattened list rejected despite matching words")
        try check(DictationCleanup.isFaithful("Shopping list:\n- Apples.\n- Pears.", to: list), "bullet punctuation preserves item boundaries")
        let suite = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench.RefinementChecks." + UUID().uuidString).path
        guard let defaults = UserDefaults(suiteName: suite) else { throw LocalRefinementError.message("Cannot create isolated test defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CleanupConfigurationStore(defaults: defaults)
        try check(store.snapshot().naturalProvider == .apple, "existing Natural remains Apple by default")
        let first = CleanupConfiguration(naturalProvider: .ollama, model: "gemma3:1b")
        try store.save(first)
        let captured = store.snapshot()
        try store.save(.init(naturalProvider: .ollama, model: "qwen2.5:3b"))
        try check(captured == first && store.snapshot().model == "qwen2.5:3b", "capture snapshot does not follow later selection")
        defaults.set(Data("broken".utf8), forKey: CleanupConfigurationStore.key)
        try check(store.snapshot().settingsIssue != nil, "corrupt configuration requests conservative fallback")
        try check(defaults.data(forKey: CleanupConfigurationStore.key) == Data("broken".utf8), "corrupt configuration preserved for explicit repair")
        print("REFINEMENT_CHECKS_OK: \(count) checks passed")
    }

    private static let localMetadata = "{\"details\":{\"format\":\"gguf\"},\"model_info\":{\"general.architecture\":\"gemma3\"},\"capabilities\":[\"completion\"]}"
    static func runTransportChecks() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw LocalRefinementError.message("REFINEMENT TRANSPORT FAILED: " + label) }
            count += 1
        }
        func rejects(_ label: String, _ body: () async throws -> Void) async throws {
            do { try await body() } catch { count += 1; return }
            throw LocalRefinementError.message("REFINEMENT TRANSPORT FAILED: " + label)
        }
        func config(_ fixture: RefinementFixture) -> CleanupConfiguration {
            .init(naturalProvider: .ollama, endpoint: "http://127.0.0.1:\(fixture.port)", model: "fixture:small")
        }
        let source = "Hello Sam bring 2 apples."
        let faithful = try await RefinementFixture.start { request in
            if request.path == "/api/show" { return RefinementFixture.json(localMetadata) }
            return RefinementFixture.generated("Hello, Sam. Bring 2 apples!")
        }
        defer { faithful.stop() }
        let configuration = config(faithful)
        let result = await CleanupEngine().clean(source, style: .natural, configuration: configuration)
        try check(result.text == "Hello, Sam. Bring 2 apples!" && result.method.contains("Ollama"), "real HTTP model edit accepted")
        try check(source == "Hello Sam bring 2 apples.", "original value preserved")
        try check(faithful.requests.map(\.path) == ["/api/show", "/api/generate"], "local metadata verified before any transcript")
        let generated = try JSONSerialization.jsonObject(with: faithful.requests.last!.body) as! [String: Any]
        try check(generated["model"] as? String == "fixture:small" && generated["stream"] as? Bool == false && generated["think"] as? Bool == false, "frozen model and bounded generation contract")
        let schema = generated["format"] as? [String: Any]
        try check(schema?["required"] as? [String] == ["text"] && schema?["additionalProperties"] as? Bool == false, "generation requires one text field")
        let requestsBeforeLight = faithful.requests.count
        _ = await CleanupEngine().clean(source, style: .light, configuration: configuration)
        _ = await CleanupEngine().clean(source, style: .original, configuration: configuration)
        try check(faithful.requests.count == requestsBeforeLight, "Original and Light never contact Ollama")

        let changedMeaning = try await RefinementFixture.start { request in
            request.path == "/api/show" ? RefinementFixture.json(localMetadata) : RefinementFixture.generated("Hello, Sam. Bring 3 apples!")
        }
        defer { changedMeaning.stop() }
        let rejected = await CleanupEngine().clean(source, style: .natural, configuration: config(changedMeaning))
        try check(rejected.text == DictationCleanup.light(source) && rejected.method.contains("rejected"), "changed number falls back visibly")
        let chatter = try await RefinementFixture.start { request in
            request.path == "/api/show" ? RefinementFixture.json(localMetadata) : RefinementFixture.json("{\"response\":\"Hello, Sam. Bring 2 apples!\",\"done\":true}")
        }
        defer { chatter.stop() }
        let invalidShape = await CleanupEngine().clean(source, style: .natural, configuration: config(chatter))
        try check(invalidShape.text == DictationCleanup.light(source) && invalidShape.method.contains("text format"), "unstructured server response falls back visibly")
        let remote = try await RefinementFixture.start { _ in
            RefinementFixture.json("{\"remote_host\":\"https://ollama.com\",\"remote_model\":\"private-cloud-alias\",\"details\":{\"format\":\"gguf\"},\"model_info\":{\"general.architecture\":\"gemma3\"},\"capabilities\":[\"completion\"]}")
        }
        defer { remote.stop() }
        let remoteResult = await CleanupEngine().clean(source, style: .natural, configuration: config(remote))
        try check(remoteResult.method.hasPrefix("Light cleanup") && remote.requests.count == 1 && remote.requests.first?.path == "/api/show", "cloud alias refused before text leaves Workbench")
        try check(!(String(data: remote.requests.first!.body, encoding: .utf8) ?? "").contains(source), "preflight contains no transcript")

        let unavailable = try await RefinementFixture.start { _ in RefinementFixture.json("{}", status: 503) }
        defer { unavailable.stop() }
        let unavailableResult = await CleanupEngine().clean(source, style: .natural, configuration: config(unavailable))
        try check(unavailableResult.text == DictationCleanup.light(source) && unavailableResult.method.contains("503"), "HTTP failure visibly uses Light")

        let stalled = try await RefinementFixture.start { request in request.path == "/api/show" ? RefinementFixture.json(localMetadata) : nil }
        defer { stalled.stop() }
        let task = Task { await CleanupEngine().clean(source, style: .natural, configuration: config(stalled)) }
        try await Task.sleep(nanoseconds: 150_000_000)
        let cancelStart = Date(); task.cancel()
        let cancelled = await task.value
        try check(Date().timeIntervalSince(cancelStart) < 2 && cancelled.method.contains("cancelled"), "cancellation promptly returns conservative result")
        var timeoutRequest = try OllamaEndpoint.request(base: config(stalled).endpoint, path: "generate", body: [:], timeout: 0.2)
        timeoutRequest.timeoutInterval = 0.2
        try await rejects("bounded timeout") { _ = try await OllamaTransport(resourceTimeout: 0.3).send(timeoutRequest) }

        let redirectDestination = try await RefinementFixture.start { _ in RefinementFixture.json("{}") }
        defer { redirectDestination.stop() }
        let redirect = try await RefinementFixture.start { _ in
            "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(redirectDestination.port)/api/show\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        }
        defer { redirect.stop() }
        try await rejects("redirect rejected") { try await OllamaClient(configuration: config(redirect)).verifyModel() }
        try check(redirectDestination.requests.isEmpty, "redirect destination not contacted")
        let oversized = try await RefinementFixture.start { _ in RefinementFixture.json(String(repeating: "x", count: OllamaEndpoint.maximumResponseBytes + 1)) }
        defer { oversized.stop() }
        try await rejects("response bounded") { try await OllamaClient(configuration: config(oversized)).verifyModel() }

        let progress = RefinementProgressCapture()
        let pull = try await RefinementFixture.start { request in
            switch request.path {
            case "/api/show": return RefinementFixture.json(localMetadata)
            case "/api/pull": return RefinementFixture.json("{\"status\":\"pulling\",\"total\":100,\"completed\":50}\n{\"status\":\"success\"}\n")
            case "/api/generate": return RefinementFixture.json("{\"done\":true,\"response\":\"\",\"done_reason\":\"load\"}")
            default: return RefinementFixture.json("{\"models\":[{\"name\":\"fixture:small\",\"size\":1000,\"details\":{\"format\":\"gguf\"}},{\"name\":\"alias\",\"size\":1000,\"remote_host\":\"https://ollama.com\",\"details\":{\"format\":\"gguf\"}}]}")
            }
        }
        defer { pull.stop() }
        let client = OllamaClient(configuration: config(pull))
        try await client.pull { progress.append($0) }
        try check(progress.values.contains { $0.fraction == 0.5 } && progress.values.last?.status == "success", "NDJSON download progress and completion")
        try await client.load()
        let loadBody = pull.requests.last!.body
        let loadObject = try JSONSerialization.jsonObject(with: loadBody) as! [String: Any]
        try check(loadObject["prompt"] as? String == "" && loadObject["keep_alive"] as? String == "5m", "explicit load uses empty prompt")
        let models = try await client.installedModels()
        try check(models.map(\.name) == ["fixture:small"], "model discovery excludes cloud aliases")

        let gate = RefinementUncooperativeFixture()
        let deadlineStart = Date()
        try await rejects("framework timeout does not await non-cooperative child") {
            _ = try await CleanupDeadline().run(seconds: 0.05) { await gate.wait(); return "late framework output" }
        }
        try check(Date().timeIntervalSince(deadlineStart) < 1, "framework timeout returns promptly")
        gate.release()
        let cancellationGate = RefinementUncooperativeFixture()
        let framework = Task { try await CleanupDeadline().run(seconds: 10) { await cancellationGate.wait(); return "late output after cancellation" } }
        try await Task.sleep(nanoseconds: 50_000_000)
        let frameworkCancelStart = Date(); framework.cancel()
        try await rejects("framework cancellation ignores late result") { _ = try await framework.value }
        try check(Date().timeIntervalSince(frameworkCancelStart) < 1, "framework cancellation does not wait for child")
        cancellationGate.release()
        print("REFINEMENT_TRANSPORT_CHECKS_OK: \(count) checks passed")
    }
}

extension LocalRefinementChecks {
    /// The app owns an Ollama download (#134, 1 October): Settings › Models leaving changes nothing,
    /// Cancel is explicit and prompt, a failure keeps its reason for the readiness line, and a finished
    /// download says whether Natural is ready. Loopback fixtures only; no Ollama runs.
    @MainActor static func runOwnershipChecks() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw LocalRefinementError.message("REFINEMENT OWNERSHIP FAILED: " + label) }
            count += 1
        }
        let suite = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench.RefinementOwnership." + UUID().uuidString).path
        guard let defaults = UserDefaults(suiteName: suite) else { throw LocalRefinementError.message("Cannot create isolated test defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CleanupConfigurationStore(defaults: defaults)
        func config(_ fixture: RefinementFixture) -> CleanupConfiguration {
            .init(naturalProvider: .ollama, endpoint: "http://127.0.0.1:\(fixture.port)", model: "fixture:small")
        }
        func settle(_ seconds: TimeInterval) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

        // A download that never answers stands in for a long one. The view that started it goes away.
        let stalled = try await RefinementFixture.start { _ in nil }
        defer { stalled.stop() }
        let manager = CleanupModelManager(store: store)
        manager.download(config(stalled))
        await settle(0.15)
        try check(manager.isWorking && manager.downloading == "fixture:small" && manager.downloadLine == "Downloading fixture:small…", "download starts with its one line")
        manager.resetStatus()
        try check(manager.downloading == "fixture:small" && manager.status == "Downloading fixture:small…", "a draft change does not disturb the running download")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory); NSApp.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        window.contentViewController = NSHostingController(rootView: CleanupModelSettingsView(manager: manager, isBusy: false))
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        window.contentViewController = nil; window.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try check(manager.isWorking && manager.downloading == "fixture:small", "leaving Settings › Models does not cancel the download")
        try check(manager.operation != nil, "the request still belongs to the app's manager")
        let cancelStart = Date()
        manager.cancel()
        try check(!manager.isWorking && manager.downloading == nil && manager.downloadLine == nil && manager.failure == nil && manager.status.contains("cancelled"), "explicit Cancel clears the line without a failure")
        try check(Date().timeIntervalSince(cancelStart) < 2, "cancel returns promptly")

        // A refused download keeps its reason wherever readiness shows, until the next request or Save.
        let refused = try await RefinementFixture.start { _ in RefinementFixture.json("{}", status: 503) }
        defer { refused.stop() }
        manager.download(config(refused))
        await manager.operation?.value
        try check(!manager.isWorking && manager.downloadLine == nil, "a refused download ends its line")
        try check(manager.failure?.hasPrefix("fixture:small couldn’t be downloaded.") == true && manager.failure?.contains("503") == true, "the failure names the model and the reason")
        try check(manager.status.contains("Light cleanup remains available"), "Models keeps the Light fallback in its status")
        manager.clearFailure()
        try check(manager.failure == nil, "Save clears the failure")

        // A finished download says whether Natural can use it now.
        let pull = try await RefinementFixture.start { request in
            switch request.path {
            case "/api/show": return RefinementFixture.json(localMetadata)
            case "/api/pull": return RefinementFixture.json("{\"status\":\"pulling\",\"total\":100,\"completed\":50}\n{\"status\":\"success\"}\n")
            default: return RefinementFixture.json("{\"models\":[{\"name\":\"fixture:small\",\"size\":1000,\"details\":{\"format\":\"gguf\"}}]}")
            }
        }
        defer { pull.stop() }
        manager.download(config(pull))
        await manager.operation?.value
        try check(manager.failure == nil && manager.status.contains("Save refinement choice to use it for Natural"), "a model that is not the saved choice asks for Save, never opting anyone in")
        try store.save(config(pull))
        manager.download(config(pull))
        await manager.operation?.value
        try check(manager.status.contains("ready for the Natural text style"), "the saved model's download makes Natural ready")
        try check(manager.models.map(\.name) == ["fixture:small"], "the installed list refreshes after a download")

        // The render-only presentation reads as a real download and clears the same way.
        manager.presentDownload("gemma3:1b", fraction: 0.42)
        try check(manager.downloadLine == "Downloading gemma3:1b · 42%" && manager.isWorking, "the one line carries the percentage")
        manager.cancel()
        try check(manager.downloadLine == nil && !manager.isWorking, "presentation clears with Cancel")
        print("REFINEMENT_OWNERSHIP_CHECKS_OK: \(count) checks passed")
    }
}

private final class RefinementUncooperativeFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released { lock.unlock(); continuation.resume() }
            else { self.continuation = continuation; lock.unlock() }
        }
    }
    func release() {
        lock.lock(); released = true; let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume()
    }
}

private final class RefinementProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [OllamaPullProgress] = []
    var values: [OllamaPullProgress] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ progress: OllamaPullProgress) { lock.lock(); stored.append(progress); lock.unlock() }
}

/// Real loopback HTTP protocol fixture; only synthetic text, isolated ephemeral ports.
private final class RefinementFixture: @unchecked Sendable {
    struct Request: Sendable { var path: String; var body: Data }
    private let listener: NWListener
    private let response: @Sendable (Request) -> String?
    private let queue = DispatchQueue(label: "Workbench.RefinementFixture")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var received: [Request] = []
    private var started = false
    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return received }
    var port: UInt16 { listener.port!.rawValue }
    private init(response: @escaping @Sendable (Request) -> String?) throws {
        self.response = response
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    static func json(_ body: String, status: Int = 200) -> String {
        "HTTP/1.1 \(status) Fixture\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
    }
    static func generated(_ text: String) -> String {
        let inner = String(decoding: try! JSONSerialization.data(withJSONObject: ["text": text]), as: UTF8.self)
        let outer = String(decoding: try! JSONSerialization.data(withJSONObject: ["response": inner, "done": true]), as: UTF8.self)
        return json(outer)
    }
    static func start(response: @escaping @Sendable (Request) -> String?) async throws -> RefinementFixture {
        let fixture = try RefinementFixture(response: response)
        return try await withCheckedThrowingContinuation { continuation in
            fixture.listener.stateUpdateHandler = { state in
                switch state {
                case .ready where !fixture.started: fixture.started = true; continuation.resume(returning: fixture)
                case .failed(let error) where !fixture.started: fixture.started = true; continuation.resume(throwing: error)
                default: break
                }
            }
            fixture.listener.newConnectionHandler = { [weak fixture] connection in
                guard let fixture else { connection.cancel(); return }
                fixture.lock.lock(); fixture.connections.append(connection); fixture.lock.unlock()
                connection.start(queue: fixture.queue); fixture.receive(connection, buffer: Data())
            }
            fixture.listener.start(queue: fixture.queue)
        }
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, complete, error in
            guard let self else { return }
            var buffer = buffer; if let bytes { buffer.append(bytes) }
            if let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(data: buffer[..<boundary.lowerBound], encoding: .utf8) ?? ""
                let lines = header.components(separatedBy: "\r\n")
                let length = lines.first(where: { $0.lowercased().hasPrefix("content-length:") }).flatMap { Int($0.split(separator: ":", maxSplits: 1).last!.trimmingCharacters(in: .whitespaces)) } ?? 0
                if buffer.count - boundary.upperBound >= length {
                    let request = Request(path: lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "", body: Data(buffer[boundary.upperBound..<boundary.upperBound + length]))
                    self.lock.lock(); self.received.append(request); self.lock.unlock()
                    if let response = self.response(request) { connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() }) }
                    return
                }
            }
            if !complete && error == nil && buffer.count < 128 * 1024 { self.receive(connection, buffer: buffer) }
            else { connection.cancel() }
        }
    }
    func stop() {
        listener.cancel(); lock.lock(); let current = connections; connections = []; lock.unlock()
        current.forEach { $0.cancel() }
    }
}
