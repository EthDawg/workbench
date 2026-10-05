import Foundation
import FluidAudio

struct LiveVoiceWord: Sendable {
    var text: String
    var start: Double
    var end: Double
}

struct LiveVoiceAudio: Sendable {
    var source: LiveVoiceSource
    var samples: [Float]
    var sampleRate: Double
    var start: Double
}

/// A bounded mailbox, rather than one Task per audio callback. Overflow invalidates live
/// completion, never the independently saved original audio or the committed words.
final class LiveVoiceInput: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [LiveVoiceAudio] = []
    private var frames = 0
    private var closed = false
    private var problem: String?
    private let maximumFrames: Int
    init(maximumFrames: Int = 12_000_000) { self.maximumFrames = maximumFrames }

    func append(_ audio: LiveVoiceAudio) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, problem == nil, !audio.samples.isEmpty else { return }
        guard audio.sampleRate.isFinite, (8_000...192_000).contains(audio.sampleRate),
              audio.start.isFinite, audio.start >= 0,
              audio.samples.allSatisfy(\.isFinite), frames + audio.samples.count <= maximumFrames else {
            problem = "Live text fell behind. The original recording is still being saved for transcription."
            pending.removeAll(); frames = 0; return
        }
        pending.append(audio); frames += audio.samples.count
    }
    func close() { lock.lock(); closed = true; lock.unlock() }
    func drain() -> (audio: [LiveVoiceAudio], closed: Bool, problem: String?) {
        lock.lock(); defer { lock.unlock() }
        let result = (pending, closed, problem)
        pending.removeAll(keepingCapacity: true); frames = 0
        return result
    }
}

/// The window boundary is based on the word's midpoint, not textual overlap. Repeated
/// phrases and simultaneous sources therefore keep their own words and absolute times.
struct LiveVoiceWindow {
    var source: LiveVoiceSource
    var start: Double
    var rate: Double
    var samples: [Float] = []
    var committed = 0
    var previewed = 0
    var segmentID = UUID()
    private var seamAnchor: LiveVoiceWord?
    private var seamPending: [LiveVoiceWord] = []
    init(source: LiveVoiceSource, start: Double, rate: Double, samples: [Float] = []) {
        self.source = source; self.start = start; self.rate = rate; self.samples = samples
    }
    var end: Double { start + Double(samples.count) / rate }
    var uncommittedSeconds: Double { Double(samples.count - committed) / rate }

    mutating func append(_ audio: LiveVoiceAudio) -> Bool {
        guard rate == audio.sampleRate, abs(end - audio.start) < 0.1 else { return false }
        samples += audio.samples
        return true
    }

    struct Request {
        var audio: [Float]
        var audioStart: Double
        var from: Double
        var through: Double
        var final: Bool
        var commitFrame: Int
    }
    func request(finishing: Bool) -> Request? {
        guard samples.count > committed else { return nil }
        let commit = uncommittedSeconds >= 10 || finishing
        guard commit || Double(samples.count - previewed) / rate >= 2 else { return nil }
        let from = max(0, committed - Int(2 * rate))
        let through = commit ? min(samples.count, committed + Int(8 * rate)) : samples.count
        let audioEnd = min(samples.count, through + (commit ? Int(2 * rate) : 0))
        return Request(audio: Array(samples[from..<audioEnd]), audioStart: start + Double(from) / rate,
                       from: start + Double(committed) / rate, through: start + Double(through) / rate,
                       final: commit, commitFrame: through)
    }
    mutating func segments(words: [LiveVoiceWord], request: Request) throws -> [LiveVoiceSegment] {
        guard words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }) else {
            throw VoiceError.message("The speech model returned invalid word timing. Original audio is kept.")
        }
        let absolute = words.map { LiveVoiceWord(text: $0.text, start: request.audioStart + $0.start, end: request.audioStart + $0.end) }
        func midpoint(_ word: LiveVoiceWord) -> Double { (word.start + word.end) / 2 }
        func normal(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        func match(_ word: LiveVoiceWord) -> Int? {
            let matches = absolute.indices.filter { normal(absolute[$0].text) == normal(word.text) && abs(midpoint(absolute[$0]) - midpoint(word)) <= 0.6 }
            // Repeated words can make a single-word anchor ambiguous. Preserve originals
            // for the complete pass instead of guessing which occurrence was committed.
            return matches.count == 1 ? matches.first : nil
        }
        let anchorIndex = seamAnchor.flatMap(match)
        if seamAnchor != nil && anchorIndex == nil {
            throw VoiceError.message("Words at a live transcription boundary could not be reconciled. The original audio is kept for a complete transcription.")
        }
        let pendingMatches = Set(seamPending.compactMap(match))
        if seamAnchor == nil && pendingMatches.count != seamPending.count {
            throw VoiceError.message("The live transcription boundary changed. The original audio is kept for a complete transcription.")
        }
        let included = absolute.indices.filter { index in
            let pastBoundary = anchorIndex.map { index > $0 } ?? (midpoint(absolute[index]) >= request.from || pendingMatches.contains(index))
            return pastBoundary && midpoint(absolute[index]) < request.through
        }.map { absolute[$0] }
        if request.final {
            // Match the last committed word on the next re-decode, allowing timing jitter.
            // A pending word crossing the numeric seam still belongs to the later range.
            seamAnchor = included.last.flatMap { midpoint($0) >= request.through - 1.5 ? $0 : nil }
            seamPending = absolute.filter { midpoint($0) >= request.through && midpoint($0) <= request.through + 0.6 }
        }
        return included.enumerated().map { index, word in
            var identity = segmentID.uuid
            withUnsafeMutableBytes(of: &identity) { bytes in
                let suffix = UInt32(index)
                for offset in 0..<4 { bytes[12 + offset] ^= UInt8(truncatingIfNeeded: suffix >> (offset * 8)) }
            }
            return LiveVoiceSegment(id: UUID(uuid: identity), source: source, start: word.start, end: word.end,
                                    text: word.text, isFinal: request.final)
        }
    }
    mutating func accept(_ request: Request) {
        previewed = samples.count
        guard request.final else { return }
        committed = request.commitFrame
        previewed = committed
        segmentID = UUID()
        // Keep two seconds of left context and at most the current uncommitted backlog.
        let discard = max(0, committed - Int(2 * rate))
        samples.removeFirst(discard); start += Double(discard) / rate
        committed -= discard; previewed -= discard
    }
}

enum LiveVoiceJournal {
    static func save(_ checkpoint: LiveVoiceCheckpoint, to url: URL) throws {
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func load(from url: URL, sessionID: UUID) throws -> LiveVoiceCheckpoint {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= 16 * 1024 * 1024 else {
            throw VoiceError.message("The live transcript checkpoint could not be read safely.")
        }
        let checkpoint = try JSONDecoder().decode(LiveVoiceCheckpoint.self, from: Data(contentsOf: url))
        guard checkpoint.formatVersion == 1, checkpoint.sessionID == sessionID,
              checkpoint.segments.count <= 100_000, Set(checkpoint.segments.map(\.id)).count == checkpoint.segments.count,
              checkpoint.segments.allSatisfy({ $0.isFinal && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= 7_260 }),
              checkpoint.completedThrough.keys.allSatisfy({ LiveVoiceSource(rawValue: $0) != nil }),
              checkpoint.completedThrough.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 7_260 }) else {
            throw VoiceError.message("The live transcript checkpoint has invalid timing or identity.")
        }
        return checkpoint
    }
}

/// One serial inference loop for both sources. Recognition never runs on an audio callback
/// or the main actor. A failed/overloaded live pass leaves batch recovery fully available.
final class LiveVoiceService: @unchecked Sendable {
    typealias Recognize = @Sendable ([Float]) async throws -> [LiveVoiceWord]
    let input = LiveVoiceInput()
    private let task: Task<LiveVoiceCheckpoint, Never>

    init(id: UUID, sources: [LiveVoiceSourceStatus], journal: URL?, recognize: @escaping Recognize,
         update: @escaping @Sendable (LiveVoiceSnapshot) -> Void) {
        let input = input
        task = Task.detached(priority: .utility) {
            defer { input.close() }
            var checkpoint = LiveVoiceCheckpoint(sessionID: id)
            var runs: [LiveVoiceSource: [LiveVoiceWindow]] = [:]
            var tails: [LiveVoiceSource: [LiveVoiceSegment]] = [:]
            var snapshot = LiveVoiceSnapshot(sessionID: id, phase: .listening, sources: sources)
            var stopped = false
            do {
                while true {
                    try Task.checkCancellation()
                    let batch = input.drain()
                    if let problem = batch.problem { throw VoiceError.message(problem) }
                    stopped = batch.closed
                    for audio in batch.audio {
                        if let index = snapshot.sources.firstIndex(where: { $0.source == audio.source }) {
                            let peak = audio.samples.map { abs($0) }.max() ?? 0
                            snapshot.sources[index].health = peak > 0.001 ? .receiving : .quiet
                            snapshot.sources[index].level = min(1, Double(peak) * 4)
                        }
                        snapshot.elapsed = max(snapshot.elapsed, audio.start + Double(audio.samples.count) / audio.sampleRate)
                        var queue = runs[audio.source] ?? []
                        if queue.isEmpty || !queue[queue.count - 1].append(audio) {
                            queue.append(LiveVoiceWindow(source: audio.source, start: audio.start, rate: audio.sampleRate, samples: audio.samples))
                        }
                        // Bound both the mailbox and audio retained during inference.
                        guard queue.reduce(0, { $0 + Double($1.samples.count) / $1.rate }) <= 60 else {
                            throw VoiceError.message("Live text fell behind. Finish to transcribe the saved original audio.")
                        }
                        runs[audio.source] = queue
                    }
                    var worked = false
                    for source in LiveVoiceSource.allCases {
                        guard var queue = runs[source], !queue.isEmpty else { continue }
                        let finishing = stopped || queue.count > 1
                        if let request = queue[0].request(finishing: finishing) {
                            worked = true
                            var samples = try AudioConverter().resample(request.audio, from: queue[0].rate)
                            // FluidAudio needs 0.3 s. Keep short final replies by padding, not dropping.
                            if samples.count < 4_800 { samples += [Float](repeating: 0, count: 4_800 - samples.count) }
                            let words = samples.allSatisfy({ abs($0) < 0.000001 }) ? [] : try await recognize(samples)
                            try Task.checkCancellation()
                            let segments = try queue[0].segments(words: words, request: request)
                            tails[source] = request.final ? [] : segments
                            if request.final {
                                checkpoint.segments += segments
                                checkpoint.completedThrough[source.rawValue] = request.through
                                if let journal { try LiveVoiceJournal.save(checkpoint, to: journal) }
                            }
                            queue[0].accept(request)
                        }
                        if finishing && queue[0].uncommittedSeconds == 0 { queue.removeFirst() }
                        runs[source] = queue
                    }
                    snapshot.segments = LiveVoiceTurns.group(checkpoint.segments + tails.values.flatMap { $0 })
                    snapshot.recognitionDelayed = runs.values.flatMap { $0 }.contains { $0.uncommittedSeconds > 12 }
                    snapshot.phase = stopped ? .finishing : .listening
                    update(snapshot)
                    if stopped && runs.values.allSatisfy(\.isEmpty) { break }
                    if !worked { try await Task.sleep(nanoseconds: 100_000_000) }
                }
                checkpoint.complete = sources.allSatisfy { checkpoint.completedThrough[$0.source.rawValue] != nil }
                if let journal { try LiveVoiceJournal.save(checkpoint, to: journal) }
                snapshot.phase = checkpoint.complete ? .completed : .recoverableFailure
            } catch {
                checkpoint.complete = false
                checkpoint.notes.append(error is CancellationError ? "Live text was cancelled. Original audio is kept." : error.localizedDescription)
                if let journal { try? LiveVoiceJournal.save(checkpoint, to: journal) }
                snapshot.phase = .recoverableFailure
                snapshot.recognitionDelayed = true
                snapshot.message = checkpoint.notes.last
            }
            update(snapshot)
            return checkpoint
        }
    }
    func finish() async -> LiveVoiceCheckpoint { input.close(); return await task.value }
    func requestCancel() { input.close(); task.cancel() }
    func cancel() async -> LiveVoiceCheckpoint { requestCancel(); return await task.value }
}
