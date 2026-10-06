import Foundation
import AVFoundation
import AppIntents
import UniformTypeIdentifiers



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
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalVoice-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wav = folder.appendingPathComponent("synthetic.wav"), m4a = folder.appendingPathComponent("synthetic.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)!
        buffer.frameLength = 24000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 24000)
        func writeAudio(_ url: URL, settings: [String: Any]) throws {
            let output = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try output.write(from: buffer)
        }
        try writeAudio(wav, settings: format.settings)
        let file = try AVAudioFile(forReading: wav)
        try check(file.length == 24000 && file.processingFormat.sampleRate == 24000, "PCM wrapped as playable mono 24 kHz WAV")
        try writeAudio(m4a, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1])
        try check(try AVAudioFile(forReading: m4a).length > 0, "synthetic M4A remains usable as a recognition input")

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
