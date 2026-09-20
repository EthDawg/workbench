import Foundation

enum LogoWebImportError: LocalizedError {
    case invalidURL, notImage, tooLarge, download, redirects

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Choose an image on the page, or enter a direct http or https image URL."
        case .notImage: return "That address did not return a supported image. Open the larger image or try its direct image URL."
        case .tooLarge: return "This image is larger than 40 MB. Choose a smaller logo."
        case .download: return "The image could not be downloaded. Try again or choose another image."
        case .redirects: return "That image address could not be followed. Try its final direct image URL."
        }
    }
}

enum LogoWebImport {
    static let maximumAddressLength = 16_384
    static let maximumDataURLLength = (LogoImport.maximumBytes + 2) / 3 * 4 + 128

    static func remoteURL(_ value: String) -> URL? {
        guard value.utf8.count <= maximumAddressLength, let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func searchURL(_ query: String) -> URL? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "tbm", value: "isch"),
                                 URLQueryItem(name: "q", value: String(query.prefix(240)))]
        return components.url
    }

    static func inlineImage(_ value: String) throws -> Data {
        guard value.utf8.count <= maximumDataURLLength, let comma = value.firstIndex(of: ",") else {
            throw LogoWebImportError.tooLarge
        }
        let header = value[..<comma].lowercased()
        guard header.hasPrefix("data:image/"), header.hasSuffix(";base64"),
              let data = Data(base64Encoded: String(value[value.index(after: comma)...])),
              !data.isEmpty else { throw LogoWebImportError.notImage }
        guard data.count <= LogoImport.maximumBytes else { throw LogoWebImportError.tooLarge }
        return data
    }

    static func load(_ address: String, name: String = "Web logo",
                     configuration: URLSessionConfiguration = .ephemeral) async throws -> LogoImport.Image {
        try Task.checkCancellation()
        let data: Data
        if address.lowercased().hasPrefix("data:") {
            data = try inlineImage(address)
        } else {
            guard let url = remoteURL(address) else { throw LogoWebImportError.invalidURL }
            data = try await LogoImageDownload(configuration: configuration).load(url)
        }
        try Task.checkCancellation()
        let image = LogoImport.Image(png: try LogoImport.normalizedPNG(data), name: String(name.prefix(160)))
        try Task.checkCancellation()
        return image
    }
}

/// One cancellable, cookie-free download. Enforce the limit before decoding and
/// while receiving chunked bodies; Content-Length alone is not a bound.
final class LogoImageDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var data = Data()
    private var redirectCount = 0
    private var finished = false
    private var cancelled = false

    init(configuration: URLSessionConfiguration = .ephemeral) { self.configuration = configuration }

    func load(_ url: URL) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = configuration.copy() as! URLSessionConfiguration
                config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 40
                config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
                config.urlCredentialStorage = nil; config.waitsForConnectivity = false
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                request.setValue("image/png,image/jpeg,image/webp,image/heic,image/gif,image/tiff", forHTTPHeaderField: "Accept")
                let task = session.dataTask(with: request)
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
        let session = self.session; self.session = nil
        data.removeAll()
        lock.unlock()
        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); redirectCount += 1; let count = redirectCount; lock.unlock()
        guard count <= 5, let address = request.url?.absoluteString, LogoWebImport.remoteURL(address) != nil else {
            finish(.failure(LogoWebImportError.redirects)); completionHandler(nil); return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            finish(.failure(LogoWebImportError.download)); completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= Int64(LogoImport.maximumBytes) else {
            finish(.failure(LogoWebImportError.tooLarge)); completionHandler(.cancel); return
        }
        if let mime = response.mimeType?.lowercased(), !mime.hasPrefix("image/"), mime != "application/octet-stream" {
            finish(.failure(LogoWebImportError.notImage)); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard chunk.count <= LogoImport.maximumBytes - data.count else {
            lock.unlock(); finish(.failure(LogoWebImportError.tooLarge)); return
        }
        data.append(chunk); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { finish(.failure(LogoWebImportError.download)) }
        else { lock.lock(); let result = data; lock.unlock(); finish(.success(result)) }
    }
}
