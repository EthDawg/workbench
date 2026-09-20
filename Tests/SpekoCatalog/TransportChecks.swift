import Foundation

enum VoiceError: Error { case message(String) }
struct CheckFailure: Error, CustomStringConvertible { let description: String }

/// Every URL is intercepted; no key, DNS lookup, or provider request is needed.
final class CatalogueProtocol: URLProtocol {
    static let lock = NSLock()
    static var scenario = ""
    static var requests: [URLRequest] = []
    static var stops = 0
    static let voice = #"{"id":"synthetic","name":"Synthetic narrator","vendor":"test","languages":["en"],"use_with":{"provider":"test","model":"test","voice":"test"}}"#

    static func reset(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        scenario = name; requests = []; stops = 0
    }
    static func snapshot() -> ([URLRequest], Int) {
        lock.lock(); defer { lock.unlock() }
        return (requests, stops)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let number = Self.requests.count
        let scenario = Self.scenario
        Self.lock.unlock()
        var headers = ["Content-Type": "application/json"]
        var status = 200
        switch scenario {
        case "advertisedOversize": headers["Content-Length"] = String(SpekoVoiceCatalog.maximumResponseBytes + 1)
        case "wrongType": headers["Content-Type"] = "text/html"
        case "unauthorized": status = 401
        case "redirect":
            let redirected = URLRequest(url: URL(string: "https://untrusted.invalid/catalogue")!)
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": redirected.url!.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        default: break
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        switch scenario {
        case "advertisedOversize", "wrongType", "unauthorized": return // Never completes: headers must be rejected immediately.
        case "oversize":
            let chunk = Data(repeating: 32, count: 65536)
            for _ in 0..<(SpekoVoiceCatalog.maximumResponseBytes / chunk.count) {
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocol(self, didLoad: Data([32]))
            return // Never completes: a post-download check would hang.
        case "cancel":
            client?.urlProtocol(self, didLoad: Data("{".utf8))
            return
        case "exactLimit":
            var data = Data(#"{"data":[]}"#.utf8)
            data.append(Data(repeating: 32, count: SpekoVoiceCatalog.maximumResponseBytes - data.count))
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        default: break
        }
        let body: String
        switch scenario {
        case "endless": body = #"{"data":[],"next_cursor":"page-\#(number)"}"#
        case "lastPage": body = number < SpekoVoiceCatalog.maximumPages
            ? #"{"data":[],"next_cursor":"page-\#(number)"}"# : #"{"data":[]}"#
        case "repeat": body = #"{"data":[],"next_cursor":"same"}"#
        case "tooManyVoices": body = #"{"data":[\#(Array(repeating: Self.voice, count: SpekoVoiceCatalog.maximumVoices + 1).joined(separator: ","))]}"#
        default:
            body = number == 1
                ? #"{"data":[\#(Self.voice)],"next_cursor":"cursor +&?/"}"#
                : #"{"data":[\#(Self.voice)],"next_cursor":null}"#
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.lock.lock(); Self.stops += 1; Self.lock.unlock()
    }
}

@main struct Checks {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure(description: message) }
    }
    static func load() async throws -> [SpekoVoice] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogueProtocol.self]
        return try await SpekoVoiceCatalog.load(key: "synthetic-key", configuration: configuration)
    }
    static func rejection(_ scenario: String, containing text: String) async throws {
        CatalogueProtocol.reset(scenario)
        do {
            _ = try await load()
            throw CheckFailure(description: "\(scenario) unexpectedly succeeded")
        } catch VoiceError.message(let message) {
            try check(message.contains(text), "\(scenario) returned wrong error: \(message)")
        }
        print("PASS \(scenario)")
    }
    static func waitForStop() async throws {
        for _ in 0..<100 {
            if CatalogueProtocol.snapshot().1 > 0 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CheckFailure(description: "In-flight response was not cancelled")
    }
    static func run() async throws {
        CatalogueProtocol.reset("valid")
        let voices = try await load()
        let requests = CatalogueProtocol.snapshot().0
        try check(voices.count == 1 && voices[0].id == "synthetic", "Pagination deduplicates voice IDs")
        try check(requests.count == 2, "Valid catalogue follows one cursor")
        let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        try check(query.first(where: { $0.name == "cursor" })?.value == "cursor +&?/", "Cursor remains query data")
        try check(requests.allSatisfy { $0.url?.scheme == "https" && $0.url?.host == "api.speko.dev" && $0.url?.path == "/v1/tts/voices" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-key" }, "Credentials use the fixed catalogue origin")
        print("PASS valid pagination, deduplication, cursor encoding, and credential origin")

        CatalogueProtocol.reset("exactLimit")
        let atLimit = try await load()
        try check(atLimit.isEmpty, "Exactly the byte limit remains valid")
        CatalogueProtocol.reset("lastPage")
        let finalPage = try await load()
        try check(finalPage.isEmpty && CatalogueProtocol.snapshot().0.count == SpekoVoiceCatalog.maximumPages, "Exactly the page limit can complete")
        print("PASS exact byte and page boundaries")

        try await rejection("oversize", containing: "oversized")
        try await waitForStop()
        print("PASS unknown-length stream stops before EOF and cancels transport")
        for scenario in ["advertisedOversize", "wrongType"] {
            try await rejection(scenario, containing: "unsupported")
            try await waitForStop()
        }
        try await rejection("unauthorized", containing: "rejected this key")
        try await waitForStop()
        try await rejection("endless", containing: "too many voice catalogue pages")
        try check(CatalogueProtocol.snapshot().0.count == SpekoVoiceCatalog.maximumPages, "Empty fresh-cursor pages cannot exceed the request cap")
        try await rejection("repeat", containing: "repeated")
        try check(CatalogueProtocol.snapshot().0.count == 2, "Repeated cursor stops promptly")
        try await rejection("tooManyVoices", containing: "too many voices")
        try await rejection("redirect", containing: "HTTP 302")
        try check(CatalogueProtocol.snapshot().0.count == 1, "Redirect did not send another request")

        CatalogueProtocol.reset("cancel")
        let task = Task { try await load() }
        for _ in 0..<100 {
            if !CatalogueProtocol.snapshot().0.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try check(!CatalogueProtocol.snapshot().0.isEmpty, "Cancellation test started a request")
        task.cancel()
        do {
            _ = try await task.value
            throw CheckFailure(description: "Cancelled catalogue unexpectedly succeeded")
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        }
        try await waitForStop()
        try check(CatalogueProtocol.snapshot().0.count == 1, "Cancellation starts no further page")
        print("PASS cancellation releases a stalled stream")
    }
    static func main() async {
        setbuf(stdout, nil)
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("SPEKO_CATALOGUE_CHECK_FAILED: \(error)\n".utf8))
            exit(1)
        }
    }
}
