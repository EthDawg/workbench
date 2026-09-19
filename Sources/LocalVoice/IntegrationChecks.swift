import Foundation
import AVFoundation
import AppIntents
import UniformTypeIdentifiers

enum SpekoChecks {
    @discardableResult
    static func run(printResult: Bool = true) throws -> Int {
        var count = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw VoiceError.message("Speko check failed: " + name) }
            count += 1
        }
        let http = try SpekoRenderer.request(text: "Synthetic reading.", key: "synthetic-key")
        let body = try JSONSerialization.jsonObject(with: http.httpBody!) as! [String: Any]
        try check(http.url?.absoluteString == "https://router.speko.dev/v1/tts/speech" && http.httpMethod == "POST", "fixed HTTPS endpoint")
        try check(http.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-key" && body["input"] as? String == "Synthetic reading.", "explicit reading and key only")
        try check(body["voice"] == nil && body["messages"] == nil && body["history"] == nil, "automatic mode omits provider-specific voice and history")
        let catalogueJSON = """
        {
          "data": [{
            "id": "cartesia:voice-1",
            "name": "Synthetic narrator",
            "vendor": "cartesia",
            "gender": "neutral",
            "accent": "New Zealand",
            "languages": ["en-NZ", "en"],
            "use_with": {"provider": "cartesia", "model": "sonic-3.5", "voice": "voice-1"}
          }],
          "next_cursor": null
        }
        """
        let page = try SpekoVoiceCatalog.decode(Data(catalogueJSON.utf8))
        let selectedVoice = page.data[0]
        try check(page.data.count == 1 && selectedVoice.name == "Synthetic narrator" && selectedVoice.useWith.model == "sonic-3.5", "voice catalogue decodes its explicit route")
        let catalogueRequest = try SpekoVoiceCatalog.request(key: "synthetic-key")
        try check(catalogueRequest.url?.host == "api.speko.dev" && catalogueRequest.url?.path == "/v1/tts/voices", "voice catalogue uses the fixed Speko API endpoint")
        try check(catalogueRequest.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-key"
            && catalogueRequest.url?.query?.contains("language=en") == true
            && catalogueRequest.url?.query?.contains("min_chars_per_call=5000") == true, "voice catalogue requests suitable English voices with the key")
        let catalogueResponse = HTTPURLResponse(url: catalogueRequest.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        try SpekoVoiceCatalog.validate(catalogueResponse)
        try check(true, "JSON voice catalogue response accepted")
        for status in [301, 401, 403, 429, 500] {
            let response = HTTPURLResponse(url: catalogueRequest.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            var rejected = false
            do { try SpekoVoiceCatalog.validate(response) } catch { rejected = true }
            try check(rejected, "voice catalogue HTTP \(status) rejected")
        }
        let wrongCatalogueType = HTTPURLResponse(url: catalogueRequest.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        var wrongCatalogueTypeRejected = false
        do { try SpekoVoiceCatalog.validate(wrongCatalogueType) } catch { wrongCatalogueTypeRejected = true }
        try check(wrongCatalogueTypeRejected, "non-JSON voice catalogue rejected")
        let oversizedCatalogue = HTTPURLResponse(url: catalogueRequest.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json", "Content-Length": String(SpekoVoiceCatalog.maximumResponseBytes + 1)])!
        var oversizedCatalogueRejected = false
        do { try SpekoVoiceCatalog.validate(oversizedCatalogue) } catch { oversizedCatalogueRejected = true }
        try check(oversizedCatalogueRejected, "oversized voice catalogue rejected before download")
        let explicit = try SpekoRenderer.request(text: "Synthetic reading.", key: "synthetic-key", voice: selectedVoice)
        let explicitBody = try JSONSerialization.jsonObject(with: explicit.httpBody!) as! [String: Any]
        let explicitRoute = explicitBody["routing"] as? [String: String]
        try check(explicitBody["voice"] as? String == "voice-1"
            && explicitRoute?["mode"] == "explicit"
            && explicitRoute?["provider"] == "cartesia"
            && explicitRoute?["model"] == "sonic-3.5", "selected voice pins its compatible provider and model")
        let defaultsName = "Workbench.SpekoVoiceChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        SpekoVoicePreference.save(selectedVoice, defaults: defaults)
        try check(SpekoVoicePreference.load(defaults: defaults) == selectedVoice, "selected Speko voice survives reload")
        SpekoVoicePreference.save(nil, defaults: defaults)
        try check(SpekoVoicePreference.load(defaults: defaults) == nil, "automatic Speko voice clears the saved explicit route")
        let invalidCatalogue = catalogueJSON.replacingOccurrences(of: "\"voice\": \"voice-1\"", with: "\"voice\": \"\"")
        var invalidVoiceRejected = false
        do { _ = try SpekoVoiceCatalog.decode(Data(invalidCatalogue.utf8)) } catch { invalidVoiceRejected = true }
        try check(invalidVoiceRejected, "invalid catalogue routes are rejected")
        let next = try SpekoRenderer.request(text: "Synthetic reading.", key: "synthetic-key")
        try check(http.value(forHTTPHeaderField: "Idempotency-Key") != next.value(forHTTPHeaderField: "Idempotency-Key"), "distinct user actions have distinct request IDs")
        for text in ["", "   ", String(repeating: "a", count: 5001)] {
            var rejected = false
            do { _ = try SpekoRenderer.request(text: text, key: "synthetic-key") } catch { rejected = true }
            try check(rejected, "invalid length rejected before network")
        }
        for status in [301, 400, 401, 402, 403, 429, 500] {
            let response = HTTPURLResponse(url: http.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/octet-stream"])!
            var rejected = false; do { try SpekoRenderer.validate(response) } catch { rejected = true }
            try check(rejected, "HTTP \(status) rejected")
        }
        for type in ["text/html", "application/json", "audio/mpeg"] {
            let response = HTTPURLResponse(url: http.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": type])!
            var rejected = false; do { try SpekoRenderer.validate(response) } catch { rejected = true }
            try check(rejected, "unexpected content rejected")
        }
        for pcm in [Data(), Data([1])] {
            var rejected = false; do { _ = try SpekoRenderer.wav(pcm) } catch { rejected = true }
            try check(rejected, "empty or partial sample rejected")
        }
        if printResult { print("SPEKO_CHECKS_OK: \(count) checks (synthetic; no network or credentials)") }
        return count
    }
}

enum IntegrationChecks {
    @MainActor static func run() throws {
        var count = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw VoiceError.message("Integration check failed: " + name) }; count += 1
        }
        let request = DictationRequest(), first = UUID(), second = UUID()
        var results: [Result<String, Error>] = []
        try request.begin(id: first) { results.append($0) }
        do { try request.begin(id: second) { results.append($0) }; throw VoiceError.message("Concurrent capture accepted") }
        catch { try check(request.id == first, "concurrent invocation preserves original owner") }
        request.finish(id: second, result: .success("stale"))
        try check(results.isEmpty, "wrong invocation cannot complete")
        request.finish(id: first, result: .success("New capture"))
        request.finish(id: first, result: .success("duplicate"))
        try check(results.count == 1 && (try? results[0].get()) == "New capture", "exactly one owned result")
        try request.begin(id: second) { results.append($0) }
        request.cancel(); request.cancel()
        try check(results.count == 2 && request.id == nil, "cancellation releases owner exactly once")
        if case .failure(let error) = results[1] { try check(error is CancellationError, "cancel returns error, never old text") }
        let third = UUID()
        try request.begin(id: third) { results.append($0) }
        request.finish(id: second, result: .success("late previous result"))
        try check(request.id == third && results.count == 2, "late callback cannot affect next invocation")
        request.finish(id: third, result: .failure(VoiceError.message("Microphone unavailable")))
        try check(results.count == 3 && request.id == nil, "errors release request")
        count += try SpekoChecks.run(printResult: false)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalVoice-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wav = folder.appendingPathComponent("synthetic.wav"), m4a = folder.appendingPathComponent("synthetic.m4a")
        try SpekoRenderer.wav(Data(repeating: 0, count: 48000)).write(to: wav)
        let file = try AVAudioFile(forReading: wav)
        try check(file.length == 24000 && file.processingFormat.sampleRate == 24000, "PCM wrapped as playable mono 24 kHz WAV")
        try AudioRenderer.export(wav, to: m4a)
        try check(try AVAudioFile(forReading: m4a).length > 0, "Speko format exports using existing M4A path")

        let server = RecognitionConfiguration(provider: .localServer, model: "synthetic-check")
        let wavData = try Data(contentsOf: wav)
        let wavIntent = IntentFile(data: wavData, filename: "Recorded audio.wav", type: .wav)
        let stagedWav = try ShortcutAudioFile.stage(wavIntent, in: folder.appendingPathComponent("shortcut-wav"))
        try ShortcutAudioFile.validateSize(stagedWav)
        let wavRequest = try LocalTranscriptionEndpoint.request(audio: stagedWav, configuration: server)
        try check(stagedWav.pathExtension == "wav" && (try AVAudioFile(forReading: stagedWav)).length == file.length,
                  "IntentFile data fallback remains a playable WAV")
        try check(wavRequest.httpBody?.range(of: Data("filename=\"audio.wav\"".utf8)) != nil,
                  "Shortcuts WAV reaches the actual loopback provider builder")
        let m4aIntent = IntentFile(data: try Data(contentsOf: m4a), filename: "Audio", type: .mpeg4Audio)
        let stagedM4A = try ShortcutAudioFile.stage(m4aIntent, in: folder.appendingPathComponent("shortcut-m4a"))
        let m4aRequest = try LocalTranscriptionEndpoint.request(audio: stagedM4A, configuration: server)
        try check(stagedM4A.pathExtension == "m4a" && (try AVAudioFile(forReading: stagedM4A)).length > 0,
                  "declared M4A type survives an extensionless Shortcuts filename")
        try check(m4aRequest.httpBody?.range(of: Data("Content-Type: audio/mp4".utf8)) != nil,
                  "Shortcuts M4A reaches provider with supported audio MIME type")
        try check(try ShortcutAudioFile.fileExtension(filename: "recording.WAV", type: .audio) == "wav",
                  "generic audio type uses a known case-insensitive filename extension")
        let unsafe = IntentFile(data: wavData, filename: "../../outside.wav", type: .wav)
        let safeDirectory = folder.appendingPathComponent("shortcut-unsafe-name")
        let safeCopy = try ShortcutAudioFile.stage(unsafe, in: safeDirectory)
        try check(safeCopy.standardizedFileURL == safeDirectory.appendingPathComponent("input.wav").standardizedFileURL,
                  "untrusted original path cannot escape the private staging folder")
        let permissions = try FileManager.default.attributesOfItem(atPath: safeCopy.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o600, "staged Shortcuts audio is private to the user")
        let existing = IntentFile(fileURL: wav, type: .wav)
        try check(existing.fileURL == wav, "file-backed IntentFile retains its original security-scope URL")
        for (filename, type) in [("unknown.audio", UTType.audio), ("../unsafe.wav/..", UTType.audio),
                                 ("named.wav", UTType.plainText), ("recording.wav\r\nInjected", UTType.audio)] {
            var rejected = false
            do { _ = try ShortcutAudioFile.fileExtension(filename: filename, type: type) } catch { rejected = true }
            try check(rejected, "unknown or misleading Shortcuts format rejected")
        }
        for bytes in [Data(), Data(repeating: 0, count: ShortcutAudioFile.maximumBytes + 1)] {
            var rejected = false
            do { _ = try ShortcutAudioFile.stage(IntentFile(data: bytes, filename: "recording.wav", type: .wav), in: folder.appendingPathComponent("invalid-size")) }
            catch { rejected = true }
            try check(rejected, "empty and oversized IntentFile data rejected before staging")
        }
        print("INTEGRATIONS_OK: \(count) checks (synthetic; no network or credentials)")
    }
}
