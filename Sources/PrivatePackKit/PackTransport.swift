import Foundation

/// One request this library is willing to make. The host is part of the request
/// and is checked against the URL before anything is sent, so an Authorization
/// header cannot reach a host the caller did not name.
public struct PackHTTPRequest: Equatable, Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }

    public let url: URL
    public let host: String
    public let method: Method
    public let accept: String
    /// Sent only to `host`, never logged, never persisted by this library and
    /// never repeated after a redirect.
    public let authorization: String?
    /// Form body for the device-authorization endpoints.
    public let form: [String: String]?
    /// Maximum response bytes this caller will accumulate.
    public let limit: Int
    public let timeout: TimeInterval

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public init(url: URL, host: String, method: Method = .get, accept: String,
                authorization: String? = nil, form: [String: String]? = nil,
                limit: Int, timeout: TimeInterval = 30) throws {
        let expected = host.lowercased()
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == expected,
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              url.path.hasPrefix("/"), !url.path.contains(".."), url.absoluteString.count <= 2_000 else {
            throw PackError.transport("Workbench only contacts \(expected) over HTTPS for packs.")
        }
        guard (1...PackLimits.maximumFileBytes).contains(limit), timeout >= 1, timeout <= 180 else {
            throw PackError.transport("A pack request used an unsupported size or timeout.")
        }
        if let authorization {
            let printable = authorization.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 32 && $0.value != 127 }
            guard !authorization.isEmpty, authorization.count <= 4_096, printable else {
                throw PackError.authorization("This GitHub token contains characters Workbench cannot send safely.")
            }
        }
        if let form {
            let usable = form.allSatisfy { key, value in
                !key.isEmpty && key.count <= 64 && value.count <= 4_096
                    && (key + value).unicodeScalars.allSatisfy { $0.isASCII && $0.value > 32 && $0.value != 127 }
            }
            guard form.count <= 12, usable else {
                throw PackError.transport("A pack request body contains unsupported characters.")
            }
        }
        self.url = url; self.host = expected; self.method = method; self.accept = accept
        self.authorization = authorization; self.form = form; self.limit = limit; self.timeout = timeout
    }

    var encodedForm: Data? {
        guard let form else { return nil }
        let body = form.sorted { $0.key < $1.key }.map { pair in
            let key = pair.key.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
            let value = pair.value.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
            return key + "=" + value
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    func urlRequest() -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.timeoutInterval = timeout
        request.httpShouldHandleCookies = false
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Workbench", forHTTPHeaderField: "User-Agent")
        // This library only ever speaks to GitHub; pinning the API version keeps
        // a future default change from altering these responses.
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let authorization { request.setValue("Bearer " + authorization, forHTTPHeaderField: "Authorization") }
        if let body = encodedForm {
            request.httpBody = body
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

public struct PackHTTPResponse: Equatable, Sendable {
    public let status: Int
    public let body: Data
    public let mimeType: String?
    /// A small allowlist of lowercase header names, for rate-limit handling.
    public let headers: [String: String]

    public init(status: Int, body: Data, mimeType: String? = nil, headers: [String: String] = [:]) {
        self.status = status; self.body = body; self.mimeType = mimeType; self.headers = headers
    }

    static let readableHeaders = ["content-type", "retry-after", "x-ratelimit-remaining", "x-ratelimit-reset"]
}

/// The seam the pack core is written against, so every caller can be exercised
/// without a network. Implementations must bound the body, refuse redirects and
/// honour cancellation.
public protocol PackHTTPClient: Sendable {
    func send(_ request: PackHTTPRequest) async throws -> PackHTTPResponse
}

/// Never forward an Authorization header to a redirected host. The task
/// delegate is applied per request, so even a caller-supplied session cannot
/// follow a redirect.
final class PackRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The production client. The `URLSession` is injected, so tests can supply a
/// stubbed protocol and the app can own the session's lifetime.
public final class URLSessionPackClient: PackHTTPClient {
    private let session: URLSession
    private let redirects = PackRedirectGuard()

    public init(session: URLSession) {
        self.session = session
    }

    deinit { session.invalidateAndCancel() }

    public convenience init() {
        self.init(session: URLSessionPackClient.makeSession())
    }

    /// An ephemeral session with no cache, no cookies and bounded timeouts.
    public static func makeSession(timeout: TimeInterval = 60) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 4
        return URLSession(configuration: configuration)
    }

    public func send(_ request: PackHTTPRequest) async throws -> PackHTTPResponse {
        try Task.checkCancellation()
        do {
            let (stream, response) = try await session.bytes(for: request.urlRequest(), delegate: redirects)
            guard let http = response as? HTTPURLResponse else {
                throw PackError.transport("\(request.host) returned a reply Workbench could not read.")
            }
            guard http.url?.host?.lowercased() == request.host else {
                throw PackError.transport("A reply arrived from an unexpected host. Workbench sent nothing to it.")
            }
            guard !(300...399).contains(http.statusCode) else {
                throw PackError.transport("\(request.host) tried to redirect this request. Workbench refuses redirects so a sign-in never leaves that host.")
            }
            guard http.expectedContentLength <= Int64(request.limit) else {
                throw PackError.transport("\(request.host) announced more data than the \(request.limit / 1_024) KB Workbench accepts here.")
            }
            var body = Data()
            var buffer: [UInt8] = []
            buffer.reserveCapacity(65_536)
            var count = 0
            for try await byte in stream {
                count += 1
                guard count <= request.limit else {
                    throw PackError.transport("\(request.host) sent more data than Workbench accepts here. Nothing was installed.")
                }
                buffer.append(byte)
                if buffer.count == 65_536 {
                    body.append(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    try Task.checkCancellation()
                }
            }
            body.append(contentsOf: buffer)
            try Task.checkCancellation()
            var headers: [String: String] = [:]
            for name in PackHTTPResponse.readableHeaders {
                if let value = http.value(forHTTPHeaderField: name), value.count <= 256 { headers[name] = value }
            }
            return PackHTTPResponse(status: http.statusCode, body: body, mimeType: http.mimeType, headers: headers)
        } catch let error as PackError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut {
                throw PackError.transport("\(request.host) took too long to answer. The installed pack is unchanged.")
            }
            throw PackError.transport("Could not reach \(request.host). Check your connection and try again.")
        }
    }
}
