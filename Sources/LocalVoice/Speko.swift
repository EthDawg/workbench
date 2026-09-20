import Foundation
import Security

enum ReadingProvider: String, CaseIterable {
    case mac = "Mac voices"
    case speko = "Speko · online"
}

struct SpekoVoice: Codable, Hashable, Identifiable, Sendable {
    struct Route: Codable, Hashable, Sendable {
        let provider: String
        let model: String
        let voice: String
    }

    let id: String
    let name: String
    let vendor: String
    let gender: String?
    let accent: String?
    let languages: [String]
    let useWith: Route

    enum CodingKeys: String, CodingKey {
        case id, name, vendor, gender, accent, languages
        case useWith = "use_with"
    }

    var detail: String {
        [vendor.capitalized, accent, gender].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " · ")
    }

    var requestSignature: String {
        "\(useWith.provider)|\(useWith.model)|\(useWith.voice)"
    }

    func validated() throws -> SpekoVoice {
        let required = [id, name, vendor, useWith.provider, useWith.model, useWith.voice]
        guard required.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 512 }),
              [gender, accent].compactMap({ $0 }).allSatisfy({ $0.count <= 512 }),
              languages.count <= 100,
              languages.allSatisfy({ !$0.isEmpty && $0.count <= 128 }) else {
            throw VoiceError.message("Speko returned an invalid voice catalogue.")
        }
        return self
    }
}

enum SpekoVoicePreference {
    private static let key = "readingProvider.spekoVoice.v1"

    static func load(defaults: UserDefaults = .standard) -> SpekoVoice? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SpekoVoice.self, from: data).validated()
    }

    static func save(_ voice: SpekoVoice?, defaults: UserDefaults = .standard) {
        guard let voice, let data = try? JSONEncoder().encode(voice) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}

enum SpekoKeychain {
    static var service: String { (Bundle.main.bundleIdentifier ?? "com.ethdawg.localvoice.development") + ".speko" }
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key"] }
    static var hasKey: Bool {
        var query = query
        query[kSecReturnAttributes as String] = true
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
    static func read() throws -> String {
        var query = query; query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw VoiceError.message(status == errSecItemNotFound ? "Add your Speko API key in Read aloud first." : "Could not read the Speko key. Unlock Keychain and try again.")
        }
        return key
    }
    static func save(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count < 4096, !value.contains(where: { $0.isWhitespace }) else { throw VoiceError.message("Paste a valid Speko API key without spaces.") }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw VoiceError.message("Could not save the key in Keychain. Your previous key was not removed.") }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VoiceError.message("Could not remove the Speko key. Unlock Keychain and try again.") }
    }
}

/// Never forward the key or reading to a redirected host.
private final class SpekoSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum SpekoVoiceCatalog {
    struct Page: Decodable {
        let data: [SpekoVoice]
        let nextCursor: String?

        enum CodingKeys: String, CodingKey {
            case data
            case nextCursor = "next_cursor"
        }
    }

    static let maximumResponseBytes = 2 * 1024 * 1024
    static let maximumVoices = 1_000
    // Bound requests independently of voice count: a service can return empty
    // pages with a different cursor each time.
    static let maximumPages = 20

    static func request(key: String, cursor: String? = nil) throws -> URLRequest {
        var components = URLComponents(string: "https://api.speko.dev/v1/tts/voices")!
        components.queryItems = [
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "min_chars_per_call", value: "5000"),
            URLQueryItem(name: "sort", value: "name"),
            URLQueryItem(name: "limit", value: "100")
        ]
        if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
        guard let url = components.url else { throw VoiceError.message("The Speko voice catalogue URL could not be prepared.") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func decode(_ data: Data) throws -> Page {
        guard !data.isEmpty, data.count <= maximumResponseBytes else {
            throw VoiceError.message("Speko returned an empty or oversized voice catalogue.")
        }
        do {
            let page = try JSONDecoder().decode(Page.self, from: data)
            _ = try page.data.map { try $0.validated() }
            if let cursor = page.nextCursor,
               cursor.isEmpty || cursor.count > 2_048 {
                throw VoiceError.message("Speko returned an invalid voice catalogue.")
            }
            return page
        } catch let error as VoiceError {
            throw error
        } catch {
            throw VoiceError.message("Speko returned an invalid voice catalogue.")
        }
    }

    static func validate(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200...299: break
        case 401, 403: throw VoiceError.message("Speko rejected this key or its catalogue access. Check your API key and account permissions.")
        case 429: throw VoiceError.message("Speko is rate-limiting voice catalogue requests. Wait before refreshing.")
        default: throw VoiceError.message("Speko could not load its voice catalogue (HTTP \(response.statusCode)).")
        }
        guard response.mimeType == "application/json", response.expectedContentLength <= maximumResponseBytes else {
            throw VoiceError.message("Speko returned an unsupported voice catalogue response.")
        }
    }

    static func load(key: String, configuration: URLSessionConfiguration = .ephemeral) async throws -> [SpekoVoice] {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: SpekoSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var voices: [SpekoVoice] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        var pageCount = 0
        repeat {
            try Task.checkCancellation()
            guard pageCount < maximumPages else { throw VoiceError.message("Speko returned too many voice catalogue pages. Try refreshing later.") }
            pageCount += 1
            let (stream, response) = try await session.bytes(for: request(key: key, cursor: cursor))
            guard let http = response as? HTTPURLResponse else { throw VoiceError.message("Speko returned an invalid voice catalogue response.") }
            try validate(http)
            var data = Data()
            for try await byte in stream {
                if data.count.isMultiple(of: 16384) { try Task.checkCancellation() }
                guard data.count < maximumResponseBytes else { throw VoiceError.message("Speko returned an oversized voice catalogue.") }
                data.append(byte)
            }
            try Task.checkCancellation()
            let page = try decode(data)
            voices.append(contentsOf: page.data)
            guard voices.count <= maximumVoices else { throw VoiceError.message("Speko returned too many voices to display safely.") }
            cursor = page.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw VoiceError.message("Speko repeated a voice catalogue page.")
            }
        } while cursor != nil

        var seen: Set<String> = []
        return voices.filter { seen.insert($0.id).inserted }
    }
}

enum SpekoRenderer {
    static let maximumCharacters = 5_000
    static let maximumAudioBytes = 64 * 1024 * 1024
    static func request(text: String, key: String, voice: SpekoVoice? = nil) throws -> URLRequest {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= maximumCharacters else {
            throw VoiceError.message("Keep each Speko reading between 1 and 5,000 characters.")
        }
        var request = URLRequest(url: URL(string: "https://router.speko.dev/v1/tts/speech")!)
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "routing": ["mode": "auto", "objective": "balanced"], "input": text,
            "audio": ["encoding": "pcm_s16le", "sample_rate_hz": 24000, "channels": 1]
        ]
        if let voice = try voice?.validated() {
            body["routing"] = ["mode": "explicit", "provider": voice.useWith.provider, "model": voice.useWith.model]
            body["voice"] = voice.useWith.voice
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    static func validate(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200...299: break
        case 401, 403: throw VoiceError.message("Speko rejected this key or its access. Check your API key and account permissions.")
        case 402: throw VoiceError.message("Speko needs account credit or billing setup. Check your Speko account.")
        case 429: throw VoiceError.message("Speko is rate-limiting this request. Wait before trying again.")
        default: throw VoiceError.message("Speko could not generate audio (HTTP \(response.statusCode)). No automatic retry was made.")
        }
        guard response.mimeType == "application/octet-stream", response.expectedContentLength <= maximumAudioBytes else {
            throw VoiceError.message("Speko returned an unsupported audio response.")
        }
    }
    static func wav(_ pcm: Data) throws -> Data {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2), pcm.count <= maximumAudioBytes else { throw VoiceError.message("Speko returned empty, incomplete or oversized audio.") }
        var data = Data("RIFF".utf8)
        func number<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        number(UInt32(pcm.count + 36)); data.append(Data("WAVEfmt ".utf8)); number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(UInt32(24000)); number(UInt32(48000)); number(UInt16(2)); number(UInt16(16))
        data.append(Data("data".utf8)); number(UInt32(pcm.count)); data.append(pcm)
        return data
    }
    static func render(text: String, key: String, voice: SpekoVoice? = nil) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration, delegate: SpekoSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (stream, response) = try await session.bytes(for: request(text: text, key: key, voice: voice))
            guard let http = response as? HTTPURLResponse else { throw VoiceError.message("Speko returned an invalid response.") }
            try validate(http)
            var pcm = Data()
            for try await byte in stream {
                if pcm.count.isMultiple(of: 16384) { try Task.checkCancellation() }
                guard pcm.count < maximumAudioBytes else { throw VoiceError.message("Speko audio exceeded the reading size limit.") }
                pcm.append(byte)
            }
            try Task.checkCancellation()
            let data = try wav(pcm)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalVoice-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let output = folder.appendingPathComponent("speech.wav")
            do { try data.write(to: output, options: .atomic); return output }
            catch { try? FileManager.default.removeItem(at: folder); throw error }
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw VoiceError.message("Could not reach Speko. Check your connection and try again. No automatic retry was made.")
        }
    }
}
