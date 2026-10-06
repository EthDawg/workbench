@preconcurrency import CoreML
import Foundation
import FluidAudio
import Darwin

/// FluidAudio 0.15.6's repair loaders may download or purge. This v2-only path
/// reads the existing layout directly, and never passes cached files to those APIs.
enum RecognitionLocalModels {
    typealias Progress = @Sendable (RecognitionSnapshot.Phase, String) async -> Void
    struct Operations: Sendable {
        var download: @Sendable (URL, @escaping Progress) async throws -> Void
        var load: @Sendable (URL, @escaping Progress) async throws -> RecognitionBackend
        static let live = Operations(download: { candidate, progress in
            try await ModelHub.download(.parakeetV2, to: candidate, additionalModelNames: [ModelNames.ASR.vocabularyFile], progressHandler: { value in
                Task { await progress(.downloading, RecognitionEngine.progressLine(value)) }
            })
        }, load: { try await RecognitionLocalModels.load($0, progress: $1) })
    }
    static var live: RecognitionServices {
        .init(prepareCached: { progress in
            try await prepareCached(cache: AsrModels.defaultCacheDirectory(for: .v2), progress: progress)
        }, acquire: { progress in
            try await acquire(cache: AsrModels.defaultCacheDirectory(for: .v2), progress: progress)
        }, send: { try await LocalTranscriptionTransport().send($0) })
    }

    static func vocabulary(_ data: Data) throws -> [Int: String] {
        guard data.count <= 4 * 1024 * 1024, String(data: data, encoding: .utf8) != nil,
              let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: String], !values.isEmpty else {
            throw RecognitionFailure(kind: .invalidCache, message: "The saved speech vocabulary is invalid. Download a replacement to try again.")
        }
        // JSONSerialization otherwise collapses repeated identical keys. After
        // validating an object of string values, each unquoted ':' is exactly
        // one member separator; quoted/escaped punctuation is not a separator.
        var quoted = false, escaped = false, members = 0
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 58 { members += 1 }
        }
        guard members == values.count else {
            throw RecognitionFailure(kind: .invalidCache, message: "The saved speech vocabulary repeats a token identifier. Download a replacement to try again.")
        }
        var result: [Int: String] = [:]
        for (key, value) in values {
            guard let index = Int(key), index >= 0, String(index) == key, result[index] == nil else {
                throw RecognitionFailure(kind: .invalidCache, message: "The saved speech vocabulary has invalid token identifiers. Download a replacement to try again.")
            }
            result[index] = value
        }
        // v2 predicts tokens 0..<1024; blank 1024 is handled by the decoder.
        guard (0..<AsrModelVersion.v2.blankId).allSatisfy({ result[$0] != nil }) else {
            throw RecognitionFailure(kind: .invalidCache, message: "The saved speech vocabulary is incomplete. Download a replacement to try again.")
        }
        return result
    }

    /// This function has no downloader, candidate, adoption or cleanup capability.
    static func prepareCached(cache: URL, progress: @escaping Progress) async throws -> PreparedRecognition {
        await progress(.checkingCache, "Checking saved Parakeet files…")
        return PreparedRecognition(backend: try await load(cache, progress: progress))
    }

    static func acquire(cache: URL, operations: Operations = .live,
                        progress: @escaping @Sendable (RecognitionSnapshot.Phase, String) async -> Void) async throws -> PreparedRecognition {
        let fm = FileManager.default
        let candidate = cache.deletingLastPathComponent().appendingPathComponent(".workbench-parakeet-candidate-" + UUID().uuidString, isDirectory: true)
        let source = candidate.appendingPathComponent(cache.lastPathComponent, isDirectory: true)
        do {
            try fm.createDirectory(at: candidate, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            await progress(.downloading, "Downloading Parakeet…")
            try await operations.download(candidate, progress)
            try Task.checkCancellation()
            await progress(.checkingCache, "Checking saved Parakeet files…")
            let backend = try await operations.load(source, progress)
            try Task.checkCancellation()
            return PreparedRecognition(backend: backend, adopt: {
                let retainedPrevious = try adopt(candidate: source, cache: cache)
                if !retainedPrevious { try? FileManager.default.removeItem(at: candidate) }
            }, discard: { try? FileManager.default.removeItem(at: candidate) })
        } catch {
            try? fm.removeItem(at: candidate)
            throw error
        }
    }

    /// Exchange complete directories atomically. A crash cannot leave a missing
    /// active cache between two moves. The previous bytes stay in the private
    /// candidate directory; no force-download, purge, or cache cleanup is used.
    @discardableResult static func adopt(candidate: URL, cache: URL) throws -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: cache.path) {
            guard renamex_np(candidate.path, cache.path, UInt32(RENAME_SWAP)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return true
        }
        try fm.moveItem(at: candidate, to: cache)
        return false
    }

    private static func load(_ directory: URL,
                             progress: @escaping @Sendable (RecognitionSnapshot.Phase, String) async -> Void) async throws -> RecognitionBackend {
        // Detached from both MainActor and RecognitionEngine. CoreML's synchronous
        // load cannot be interrupted; the engine keeps this slot until it returns.
        let worker = Task.detached(priority: .userInitiated) {
            let names = [ModelNames.ASR.preprocessorFile, ModelNames.ASR.encoderFile, ModelNames.ASR.decoderFile, ModelNames.ASR.jointFile]
            guard names.allSatisfy({ FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }),
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent(ModelNames.ASR.vocabularyFile).path) else {
                throw RecognitionFailure(kind: .missingAssets, message: "Parakeet needs a download before speech can be transcribed. Your saved work is available now.")
            }
            let vocabulary = try vocabulary(Data(contentsOf: directory.appendingPathComponent(ModelNames.ASR.vocabularyFile)))
            var models: [MLModel] = []
            for (index, name) in names.enumerated() {
                try Task.checkCancellation()
                await progress(.loading, "Preparing Parakeet on this Mac · \(index + 1) of \(names.count)…")
                let config = AsrModels.defaultConfiguration()
                if index == 0 { config.computeUnits = .cpuOnly }
                models.append(try MLModel(contentsOf: directory.appendingPathComponent(name), configuration: config))
            }
            try Task.checkCancellation()
            let modelsValue = AsrModels(encoder: models[1], preprocessor: models[0], decoder: models[2], joint: models[3],
                                        configuration: AsrModels.defaultConfiguration(), vocabulary: vocabulary, version: .v2)
            let manager = AsrManager(config: .default, models: modelsValue)
            return RecognitionBackend(transcribe: { url in
                var state = try TdtDecoderState(decoderLayers: 2)
                var text = try await manager.transcribe(url, decoderState: &state).text
                if let ending = try? TranscriptEnding.window(of: url) {
                    try Task.checkCancellation()
                    var tail = try TdtDecoderState(decoderLayers: 2)
                    text = TranscriptEnding.stitch(text, ending: try await manager.transcribe(ending, decoderState: &tail).text)
                }
                return text
            }, transcribeLive: { samples in
                var state = try TdtDecoderState(decoderLayers: 2)
                let result = try await manager.transcribe(samples, decoderState: &state)
                let words = result.tokenTimings.map { buildWordTimings(from: $0) } ?? []
                guard result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !words.isEmpty else {
                    throw VoiceError.message("The speech model did not return word timing. The original recording is kept for transcription.")
                }
                return words.map { LiveVoiceWord(text: $0.word, start: $0.startTime, end: $0.endTime) }
            })
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
