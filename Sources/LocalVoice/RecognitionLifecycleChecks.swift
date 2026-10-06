import Foundation
import FluidAudio

enum RecognitionLifecycleChecks {
    static func run() async throws {
        var count = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw VoiceError.message("RECOGNITION LIFECYCLE CHECK FAILED: " + name) }
            count += 1; print("PASS: " + name)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench.SpeechChecks." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Workbench.SpeechChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = SpeechPreparationProbe()
        let counters = SpeechPreparationCounters()
        let backend = RecognitionBackend(transcribe: { _ in "Synthetic words" }, transcribeLive: { _ in [] })
        let engine = RecognitionEngine(store: .init(defaults: defaults), services: .init(prepareCached: { progress in
            await probe.prepare(acquire: false, progress: progress)
            return .init(backend: backend, adopt: { counters.adopt() }, discard: { counters.discard() })
        }, acquire: { progress in
            await probe.prepare(acquire: true, progress: progress)
            return .init(backend: backend, adopt: { counters.adopt() }, discard: { counters.discard() })
        }, send: { _ in throw URLError(.cannotConnectToHost) }))
        let audio = root.appendingPathComponent("retained.wav")
        let original = Data("synthetic retained audio".utf8)
        try original.write(to: audio)
        do { _ = try await engine.transcribe(audio); throw CheckFailure.expectedRefusal } catch is RecognitionFailure { }
        do { _ = try await engine.beginLiveSession(UUID()); throw CheckFailure.expectedRefusal } catch is RecognitionFailure { }
        try check(await probe.calls == 0, "fresh engine and both transcription doors cannot acquire or prepare assets")
        let first = Task { try await engine.acquireSelectedModel() }
        try await probe.waitForCall(1)
        try check((await engine.snapshot()).phase == .loading, "real operation phase is observable")
        do { try await engine.acquireSelectedModel(); throw CheckFailure.expectedRefusal } catch is VoiceError { }
        try check(await probe.calls == 1, "duplicate setup cannot start a second heavy load")
        await engine.cancelPreparation()
        let cancelling = await engine.snapshot()
        try check(!cancelling.canTranscribe && cancelling.phase == .cancelling, "Cancel immediately revokes admission while load slot remains occupied")
        await probe.lateProgress()
        try check((await engine.snapshot()).phase == .cancelling, "late progress cannot overwrite cancellation")
        do { try await engine.prepareCached(); throw CheckFailure.expectedRefusal } catch is VoiceError { }
        let server = RecognitionConfiguration(provider: .localServer, model: "synthetic-server")
        try await engine.configure(server)
        let switched = await engine.snapshot()
        try check(switched.configurationRevision == 1 && !switched.canTranscribe, "switch preserves noninterruptible occupied slot with new configuration revision")
        await probe.release()
        do { try await first.value; throw CheckFailure.expectedRefusal } catch is CancellationError { }
        try check(counters.values == [0, 1], "cancelled completion is discarded without cache adoption")
        let unverified = await engine.snapshot()
        try check(unverified.admission == .serverUnverified && unverified.canTranscribe, "configured unverified server admits its first deliberate attempt")
        do { _ = try await engine.transcribe(audio); throw CheckFailure.expectedRefusal } catch is URLError { }
        let failedServer = await engine.snapshot()
        try check(try Data(contentsOf: audio) == original && failedServer.admission == .serverUnverified, "failed server attempt keeps exact audio and never declares verification or fallback")
        try check(await probe.calls == 1, "server configure and failed request never call local preparation")
        try await engine.configure(RecognitionConfiguration())
        let second = Task { try await engine.prepareCached() }
        try await probe.waitForCall(2)
        await probe.lateProgress()
        try check((await engine.snapshot()).detail == "Synthetic noninterruptible load", "previous operation progress cannot overwrite a newer operation")
        await probe.release()
        try await second.value
        try check(await engine.isReady, "explicit cached preparation admits speech only after current completion")
        let acquisitions = await probe.acquisitions
        try check(counters.values == [1, 1] && acquisitions == 1, "cached retry uses no acquisition and adopts only current backend")
        try check(try await engine.transcribe(audio) == "Synthetic words", "prepared backend handles transcription without another preparation")
        try check(await probe.maximumActive == 1, "cancel, configuration reversal and retry never overlap heavy operations")
        let session = UUID(); _ = try await engine.beginLiveSession(session)
        try check(try await engine.transcribeLive(Array(repeating: 0, count: 4_800), sessionID: session).isEmpty, "live windows use admitted backend without preparing assets")
        await engine.endLiveSession(session)

        let cache = root.appendingPathComponent("parakeet-tdt-0.6b-v2-coreml", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let sentinel = cache.appendingPathComponent("old-cache")
        try original.write(to: sentinel)
        do { _ = try await RecognitionLocalModels.prepareCached(cache: cache, progress: { _, _ in }); throw CheckFailure.expectedRefusal }
        catch let failure as RecognitionFailure { try check(failure.kind == .missingAssets, "cached-only loader reports missing assets without repair APIs") }
        try check(try Data(contentsOf: sentinel) == original, "missing cached components remain byte-identical")
        for name in [ModelNames.ASR.preprocessorFile, ModelNames.ASR.encoderFile, ModelNames.ASR.decoderFile, ModelNames.ASR.jointFile] {
            try FileManager.default.createDirectory(at: cache.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let invalidVocabulary = Data("{ malformed synthetic vocabulary".utf8)
        let vocabularyURL = cache.appendingPathComponent(ModelNames.ASR.vocabularyFile)
        try invalidVocabulary.write(to: vocabularyURL)
        do { _ = try await RecognitionLocalModels.prepareCached(cache: cache, progress: { _, _ in }); throw CheckFailure.expectedRefusal }
        catch let failure as RecognitionFailure { try check(failure.kind == .invalidCache, "corrupt cached vocabulary is refused before any model load") }
        try check(try Data(contentsOf: vocabularyURL) == invalidVocabulary && Data(contentsOf: sentinel) == original, "corrupt cached bytes are retained exactly without repair or purge")
        let badOperations = RecognitionLocalModels.Operations(download: { candidate, _ in
            guard candidate != cache && candidate.deletingLastPathComponent() == cache.deletingLastPathComponent() else { throw CheckFailure.expectedRefusal }
            let downloaded = candidate.appendingPathComponent(cache.lastPathComponent)
            try FileManager.default.createDirectory(at: downloaded, withIntermediateDirectories: true)
            try Data("invalid replacement".utf8).write(to: downloaded.appendingPathComponent("new-cache"))
        }, load: { _, _ in throw RecognitionFailure(kind: .invalidCache, message: "Synthetic invalid model") })
        do { _ = try await RecognitionLocalModels.acquire(cache: cache, operations: badOperations, progress: { _, _ in }); throw CheckFailure.expectedRefusal }
        catch let failure as RecognitionFailure { try check(failure.kind == .invalidCache, "replacement validates isolated candidate before adoption") }
        try check(try Data(contentsOf: sentinel) == original && FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".workbench-parakeet-candidate-") }.isEmpty, "failed candidate leaves old cache exact and removes only its own partial files")
        let goodOperations = RecognitionLocalModels.Operations(download: badOperations.download, load: { _, _ in backend })
        let discardedCandidate = try await RecognitionLocalModels.acquire(cache: cache, operations: goodOperations, progress: { _, _ in })
        discardedCandidate.discard()
        try check(try Data(contentsOf: sentinel) == original && FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".workbench-parakeet-candidate-") }.isEmpty, "cancellation before adoption removes only the private candidate and preserves current cache")
        let prepared = try await RecognitionLocalModels.acquire(cache: cache, operations: goodOperations, progress: { _, _ in })
        try check(try Data(contentsOf: sentinel) == original, "validated candidate does not replace cache before engine admission")
        try prepared.adopt()
        let retained = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".workbench-parakeet-candidate-") }
        try check(retained.count == 1 && (try Data(contentsOf: retained[0].appendingPathComponent(cache.lastPathComponent).appendingPathComponent("old-cache"))) == original, "atomic replacement retains previous cache bytes in private candidate directory")
        try check(FileManager.default.fileExists(atPath: cache.appendingPathComponent("new-cache").path), "only validated replacement is activated")
        do { try RecognitionLocalModels.adopt(candidate: root.appendingPathComponent("absent"), cache: cache); throw CheckFailure.expectedRefusal }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain { }
        try check(FileManager.default.fileExists(atPath: cache.appendingPathComponent("new-cache").path), "failed atomic adoption retains active cache")

        let vocabulary = Dictionary(uniqueKeysWithValues: (0..<1024).map { (String($0), "token-\($0)") })
        try check(try RecognitionLocalModels.vocabulary(JSONEncoder().encode(vocabulary)).count == 1024, "v2 vocabulary accepts complete token coverage")
        for invalid in [["0": "only one"], vocabulary.merging(["01": "alias"]) { _, new in new }] {
            do { _ = try RecognitionLocalModels.vocabulary(JSONEncoder().encode(invalid)); throw CheckFailure.expectedRefusal }
            catch let failure as RecognitionFailure { try check(failure.kind == .invalidCache, "v2 vocabulary rejects missing or ambiguous token identifiers") }
        }
        try check(await MainActor.run { AppModel.microphoneMessage(.restricted).contains("restricted") && !AppModel.microphoneMessage(.notDetermined).contains("restricted") }, "microphone recovery uses actual restricted versus undetermined status")
        let idle = ReadbackView.NarrationEngine(name: "Download when ready", ready: false)
        try check(!idle.preparing, "an unavailable narration model does not invent a preparation spinner")
        print("RECOGNITION_LIFECYCLE_CHECKS_OK: \(count) checks; synthetic operations only")
    }
    private enum CheckFailure: Error { case expectedRefusal }
}

private final class SpeechPreparationCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var adopted = 0, discarded = 0
    func adopt() { lock.lock(); adopted += 1; lock.unlock() }
    func discard() { lock.lock(); discarded += 1; lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return [adopted, discarded] }
}

private actor SpeechPreparationProbe {
    private(set) var calls = 0, acquisitions = 0, active = 0, maximumActive = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var firstProgress: RecognitionLocalModels.Progress?
    func prepare(acquire: Bool, progress: @escaping RecognitionLocalModels.Progress) async {
        calls += 1; if acquire { acquisitions += 1 }; active += 1; maximumActive = max(maximumActive, active)
        if firstProgress == nil { firstProgress = progress }
        await progress(.loading, "Synthetic noninterruptible load")
        await withCheckedContinuation { continuation = $0 }
        active -= 1
    }
    func waitForCall(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while calls < count || continuation == nil {
            guard Date() < deadline else { throw VoiceError.message("Synthetic preparation did not start.") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func release() { continuation?.resume(); continuation = nil }
    func lateProgress() async { await firstProgress?(.downloading, "Stale download") }
}
