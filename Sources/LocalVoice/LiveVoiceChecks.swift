import Foundation

/// Timed synthetic samples and an injected recognizer. No device, provider or model access.
enum LiveVoiceChecks {
    static func run() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/Workbench-LiveVoiceChecks-\(UUID().uuidString)")
        try MeetingStore.createPrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        var count = 0
        func expect(_ value: Bool, _ label: String) throws {
            guard value else { throw VoiceError.message("Live voice check failed: \(label)") }
            count += 1
        }
        func samples(_ words: Range<Int>) -> [Float] {
            words.flatMap { [Float](repeating: Float($0) / 100, count: 16_000) }
        }
        let decoder = FixtureDecoder()
        let journal = root.appendingPathComponent("checkpoint.json")
        let id = UUID()
        let service = LiveVoiceService(id: id,
            sources: [.init(source: .microphone, name: "Fixture mic"), .init(source: .app, name: "Fixture call")],
            journal: journal, recognize: { try await decoder.recognize($0) }, update: { _ in })
        service.input.append(.init(source: .microphone, samples: samples(1..<14), sampleRate: 16_000, start: 0))
        service.input.append(.init(source: .app, samples: samples(20..<23), sampleRate: 16_000, start: 1))
        // Pause/device loss keeps the actual gap; it must not move the later words to 13 s.
        service.input.append(.init(source: .microphone, samples: samples(14..<16), sampleRate: 16_000, start: 30))
        let final = await service.finish()
        try expect(final.complete, "both source runs finish")
        let mic = final.orderedSegments.filter { $0.source == .microphone }.map(\.text).joined(separator: " ")
        try expect(mic == (1..<16).map { "word\($0)" }.joined(separator: " "), "overlap neither repeats nor loses words")
        try expect(final.orderedSegments.filter { $0.source == .app }.map(\.text).joined(separator: " ") == "word20 word21 word22", "simultaneous sources retain separate words")
        try expect(final.orderedSegments.first(where: { $0.text == "word14" })?.start == 30 && final.completedThrough["microphone"] == 32, "route gap preserves absolute time")
        try expect(final.segments.allSatisfy(\.isFinal), "journal contains no provisional words")
        try expect(try LiveVoiceJournal.load(from: journal, sessionID: id) == final, "confirmed words survive a fresh read")
        let maximumConcurrency = await decoder.maximumConcurrency
        try expect(maximumConcurrency == 1, "one inference at a time across sources")
        do { _ = try LiveVoiceJournal.load(from: journal, sessionID: UUID()); throw CheckFailure() }
        catch is CheckFailure { throw VoiceError.message("Live voice check failed: stale identity accepted") }
        catch { count += 1 }

        var window = LiveVoiceWindow(source: .microphone, start: 0, rate: 16_000, samples: samples(1..<4))
        let preview = window.request(finishing: false)!
        let provisional = try window.segments(words: await decoder.recognize(preview.audio), request: preview)
        try expect(provisional.allSatisfy { !$0.isFinal } && provisional.map(\.text).joined(separator: " ") == "word1 word2 word3", "progressive tail available before a commit window")
        window.accept(preview)
        _ = window.append(.init(source: .microphone, samples: samples(4..<11), sampleRate: 16_000, start: 3))
        let completed = window.request(finishing: false)!
        let stable = try window.segments(words: await decoder.recognize(completed.audio), request: completed)
        try expect(stable.first?.id == provisional.first?.id && stable.allSatisfy(\.isFinal), "final words replace the provisional segment using its stable ID")

        for firstMidpoint in [7.98, 8.02] {
            var seam = LiveVoiceWindow(source: .microphone, start: 0, rate: 16_000,
                                       samples: [Float](repeating: 0.1, count: 160_000))
            let firstRequest = seam.request(finishing: false)!
            let first = try seam.segments(words: [.init(text: "Before", start: 6.9, end: 7.1),
                .init(text: "Yes", start: firstMidpoint - 0.1, end: firstMidpoint + 0.1)], request: firstRequest)
            seam.accept(firstRequest)
            let secondRequest = seam.request(finishing: true)!
            let secondMidpoint = firstMidpoint == 7.98 ? 8.02 : 7.98
            let second = try seam.segments(words: [.init(text: "Before", start: 0.9, end: 1.1),
                .init(text: "Yes", start: secondMidpoint - 6.1, end: secondMidpoint - 5.9)], request: secondRequest)
            try expect((first + second).filter { $0.text == "Yes" }.count == 1, "boundary jitter in either direction retains a word exactly once")
        }
        let replies = LiveVoiceCheckpoint(sessionID: UUID(), segments: [
            .init(source: .microphone, start: 1, end: 1.2, text: "Yes", isFinal: true),
            .init(source: .app, start: 6, end: 6.2, text: "Yes", isFinal: true),
            .init(source: .microphone, start: 7, end: 7.2, text: "Certainly", isFinal: true)])
        try expect(replies.conversation == "You: Yes\n\nOthers: Yes\n\nYou: Certainly", "separate identical replies survive in their actual turn order")

        let failingDecoder = FixtureDecoder(failOn: 2)
        let failed = LiveVoiceService(id: UUID(), sources: [.init(source: .microphone, name: "Fixture")], journal: nil,
            recognize: { try await failingDecoder.recognize($0) }, update: { _ in })
        failed.input.append(.init(source: .microphone, samples: samples(1..<19), sampleRate: 16_000, start: 0))
        let partial = await failed.finish()
        try expect(!partial.complete && !partial.notes.isEmpty && partial.completedThrough["microphone"] == 8, "failed second window cannot silently finalize partial text")
        try expect(partial.text == (1..<9).map { "word\($0)" }.joined(separator: " "), "failure retains confirmed earlier words")

        let shortDecoder = FixtureDecoder()
        let short = LiveVoiceService(id: UUID(), sources: [.init(source: .microphone, name: "Fixture")], journal: nil,
            recognize: { audio in
                await shortDecoder.recordLength(audio.count)
                return [.init(text: "Yes", start: 0, end: 0.1)]
            }, update: { _ in })
        short.input.append(.init(source: .microphone, samples: [Float](repeating: 0.1, count: 1_600), sampleRate: 16_000, start: 4))
        let tiny = await short.finish()
        try expect(tiny.complete && tiny.text == "Yes" && tiny.completedThrough["microphone"] == 4.1, "very short final reply survives")
        let length = await shortDecoder.lastLength
        try expect(length == 4_800, "short tail is padded only for the recognizer")

        let mailbox = LiveVoiceInput(maximumFrames: 10)
        mailbox.append(.init(source: .microphone, samples: [Float](repeating: 0.1, count: 11), sampleRate: 16_000, start: 0))
        let overflow = mailbox.drain()
        try expect(overflow.audio.isEmpty && overflow.problem != nil, "bounded input explicitly reports loss instead of pretending silence")
        let empty = LiveVoiceService(id: UUID(), sources: [.init(source: .app, name: "Fixture")], journal: nil,
            recognize: { _ in throw CheckFailure() }, update: { _ in })
        try expect(!(await empty.finish()).complete, "missing source cannot become a complete transcript")
        let heldDecoder = FixtureDecoder(suspendFirst: true)
        let cancelled = LiveVoiceService(id: UUID(), sources: [.init(source: .microphone, name: "Fixture")], journal: nil,
            recognize: { try await heldDecoder.recognize($0) }, update: { _ in })
        cancelled.input.append(.init(source: .microphone, samples: samples(1..<19), sampleRate: 16_000, start: 0))
        for _ in 0..<1_000 {
            if await heldDecoder.isWaiting { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try expect(await heldDecoder.isWaiting, "cancellation fixture reaches inference")
        cancelled.requestCancel()
        await heldDecoder.resume()
        let cancelledResult = await cancelled.finish()
        let cancelledCalls = await heldDecoder.calls
        try expect(!cancelledResult.complete && cancelledCalls == 1 && cancelledResult.segments.isEmpty,
                   "Cancel waits for the running model request but never starts a queued window")
        print("Live voice checks passed (\(count)): overlap, source separation, gaps, progressive text, journal recovery, short replies, bounded input and failure. No devices or models were used.")
    }

    private struct CheckFailure: Error {}
    private actor FixtureDecoder {
        var calls = 0
        var active = 0
        var maximumConcurrency = 0
        var lastLength = 0
        let failOn: Int?
        let suspendFirst: Bool
        private var continuation: CheckedContinuation<Void, Never>?
        var isWaiting: Bool { continuation != nil }
        init(failOn: Int? = nil, suspendFirst: Bool = false) { self.failOn = failOn; self.suspendFirst = suspendFirst }
        func resume() { continuation?.resume(); continuation = nil }
        func recordLength(_ length: Int) { lastLength = length }
        func recognize(_ samples: [Float]) async throws -> [LiveVoiceWord] {
            calls += 1; active += 1; maximumConcurrency = max(maximumConcurrency, active)
            defer { active -= 1 }
            if calls == failOn { throw CheckFailure() }
            if suspendFirst && calls == 1 { await withCheckedContinuation { continuation = $0 } }
            await Task.yield()
            var words: [LiveVoiceWord] = []
            var start = 0
            while start < samples.count {
                let word = Int((samples[start] * 100).rounded())
                var end = start + 1
                while end < samples.count && Int((samples[end] * 100).rounded()) == word { end += 1 }
                if word > 0 { words.append(.init(text: "word\(word)", start: Double(start) / 16_000, end: Double(end) / 16_000)) }
                start = end
            }
            return words
        }
    }
}
