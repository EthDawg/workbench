import AVFoundation
import FluidAudio
import Foundation

/// `--check-neural-voice` needs no download: it drives the renderer with synthetic frames.
/// `--check-neural-voice-render [FOLDER]` reads with the real model, from Workbench's own
/// download or from FOLDER, and is skipped when the voices are not there.
/// `--check-neural-voice-download NEW_FOLDER` runs the real download there, then removes it.
@MainActor
enum NeuralVoiceChecks {
    private struct Failure: LocalizedError {
        let label: String
        var errorDescription: String? { "NEURAL VOICE CHECK FAILED: \(label)" }
    }

    static func run() async throws {
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw Failure(label: label) }
            count += 1
        }

        // Names and saved choices.
        try check(NeuralVoiceCatalog.title("bill_boerst") == "Bill Boerst" && NeuralVoiceCatalog.title("alba") == "Alba", "a voice shows its name, not its file name")
        try check(NeuralVoiceCatalog.resolve(nil) == "alba" && NeuralVoiceCatalog.resolve("../secret") == "alba" && NeuralVoiceCatalog.resolve("jane") == "jane",
                  "a saved voice outside the catalogue falls back to the default")
        try check(Set(NeuralVoiceCatalog.voices).count == NeuralVoiceCatalog.voices.count
                  && NeuralVoiceCatalog.voices.allSatisfy { $0.allSatisfy { $0.isLetter || $0 == "_" } }, "voice names are distinct file names with no path")
        try check(ReadingProvider(rawValue: "Mac voices") == .mac && ReadingProvider(rawValue: "Speko · online") == .speko
                  && ReadingProvider(rawValue: "Neural voices") == .neural, "saved reading choices keep their meaning")

        // Sentences carry the range follow-along highlights.
        let spoken = "Send Sam the agenda.  Ask which slides need the new numbers!\nThanks"
        let sentences = NeuralVoiceCatalog.sentences(in: spoken)
        try check(sentences.map(\.text) == ["Send Sam the agenda.", "Ask which slides need the new numbers!", "Thanks"], "text is read a sentence at a time")
        try check(sentences.allSatisfy { (spoken as NSString).substring(with: $0.range) == $0.text }, "each sentence's range is its own characters")
        try check(NeuralVoiceCatalog.sentences(in: " \n ").isEmpty, "blank text has no sentences")

        // The running filter matches the one-piece filter, whatever the frame boundaries.
        var whole = (0..<9_600).map { index -> Float in
            let low = Float(sin(Double(index) * 0.21)), high = Float(sin(Double(index) * 1.9))
            return low * 0.4 + high * 0.2 + 0.05
        }
        let source = whole
        AudioPostProcessor.applyTtsPostProcessing(&whole, sampleRate: 24_000, deEssAmount: -3, smoothing: false)
        var filter = NeuralVoiceFilter(sampleRate: 24_000), streamed: [Float] = []
        for start in stride(from: 0, to: source.count, by: 1_920) {
            var frame = Array(source[start..<min(start + 1_920, source.count)])
            filter.apply(&frame)
            streamed += frame
        }
        let difference = zip(whole, streamed).map { abs($0 - $1) }.max() ?? 1
        try check(streamed.count == whole.count && difference < 1e-4, "streamed frames get the same filtering as a whole reading (largest difference \(difference))")

        // An empty folder is not a download, and a reading there never fetches one.
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("NeuralVoiceChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let store = NeuralVoiceStore(root: empty)
        try check(!store.isDownloaded, "an empty folder holds no voices")
        do { _ = try await store.ready(); throw Failure(label: "a reading without the download is refused") }
        catch let error as VoiceError { try check(error.localizedDescription == NeuralVoiceStore.missingMessage, "the refusal says where to download the voices") }
        try check((try? FileManager.default.contentsOfDirectory(atPath: empty.path))?.isEmpty == true, "a refused reading downloads nothing")
        try await store.remove()
        count += 1

        // The renderer: one mark per sentence at the frame where its audio begins.
        func frames(_ perSentence: [Int], failAfter: Int? = nil, hold: Bool = false) -> ([String]) async throws -> NeuralSpeechRenderer.Frames {
            { _ in
                NeuralSpeechRenderer.Frames { continuation in
                    let task = Task {
                        var sent = 0
                        for (sentence, total) in perSentence.enumerated() {
                            for _ in 0..<total {
                                if let failAfter, sent == failAfter { continuation.finish(throwing: VoiceError.message("synthetic model failure")); return }
                                continuation.yield((samples: [Float](repeating: 0.25, count: 1_920), sentence: sentence))
                                sent += 1
                                try? await Task.sleep(nanoseconds: 2_000_000)
                            }
                        }
                        if hold { try? await Task.sleep(nanoseconds: 5_000_000_000) }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        }
        let text = ListeningText("Send Sam the agenda. Ask which slides need the new numbers. Thanks.")
        let render = try NeuralSpeechRenderer(text: text)
        var audioCallbacks = 0, finished: [Error?] = []
        render.onAudio = { audioCallbacks += 1 }
        render.onFinish = { finished.append($0) }
        render.start(voice: "alba", store: store, frames: frames([5, 10, 3]))
        try await render.ready(complete: false)
        try check(render.audio != nil && (render.audio?.availableFrames ?? 0) >= 6_000, "playback can start once a quarter second exists")
        try await render.ready(complete: true)
        guard let audio = render.audio else { throw Failure(label: "rendered audio exists") }
        try check(render.isFinished && audio.isComplete && audio.availableFrames == 18 * 1_920, "every frame is in the finished audio")
        try check(audio.format.sampleRate == 24_000, "neural audio is 24 kHz")
        try check(render.marks.frames == [0, 5 * 1_920, 15 * 1_920], "each sentence is marked at the frame where it begins")
        let original = text.original as NSString
        try check(render.marks.ranges.map { original.substring(with: $0) } == ["Send Sam the agenda.", "Ask which slides need the new numbers.", "Thanks."],
                  "a mark highlights its sentence as displayed")
        try check(render.marks.range(at: 6 * 1_920).map { original.substring(with: $0) } == "Ask which slides need the new numbers.", "follow-along finds the sentence playing")
        try check(audioCallbacks == 18 && finished.count == 1 && finished[0] == nil, "playback hears of every frame and one finish")
        try check(try AVAudioFile(forReading: audio.url).length == audio.availableFrames, "the finished file is an ordinary WAV")
        render.discard()
        try check(!FileManager.default.fileExists(atPath: render.folder.path), "discarding removes the audio")

        // Cancelling stops at once, removes the partial audio and reports no finish.
        let cancelled = try NeuralSpeechRenderer(text: text)
        var cancelledFinish = 0
        cancelled.onFinish = { _ in cancelledFinish += 1 }
        cancelled.start(voice: "alba", store: store, frames: frames([200, 200, 200]))
        try await cancelled.ready(complete: false)
        cancelled.cancel()
        let kept = cancelled.audio?.availableFrames
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(!cancelled.isFinished && cancelledFinish == 0 && cancelled.audio?.availableFrames == kept, "no frames or finish arrive after cancelling")
        try check(!FileManager.default.fileExists(atPath: cancelled.folder.path), "cancelling removes the partial audio")
        do { try await cancelled.ready(complete: true); throw Failure(label: "a cancelled reading is not ready") }
        catch is CancellationError { count += 1 }

        // A model failure partway ends the reading with its reason and no audio.
        let failing = try NeuralSpeechRenderer(text: text)
        var failures: [Error?] = []
        failing.onFinish = { failures.append($0) }
        failing.start(voice: "alba", store: store, frames: frames([5, 5, 5], failAfter: 7))
        do { try await failing.ready(complete: true); throw Failure(label: "a failed reading is not ready") }
        catch let error as VoiceError { try check(error.localizedDescription == "synthetic model failure", "the failure keeps its reason") }
        try check(failures.count == 1 && failures[0] != nil && !failing.isFinished && !FileManager.default.fileExists(atPath: failing.folder.path),
                  "a failed reading reports once and leaves no audio")

        // Text with nothing to say fails rather than waiting.
        let silent = try NeuralSpeechRenderer(text: ListeningText("   "))
        silent.start(voice: "alba", store: store, frames: frames([]))
        do { try await silent.ready(complete: true); throw Failure(label: "empty text is not ready") }
        catch let error as VoiceError { try check(error.localizedDescription == "This text has nothing to read aloud.", "empty text says so") }

        print("NEURAL_VOICE_CHECKS_OK: \(count) checks passed")
    }

    /// The real download, into a new folder the caller names: about 530 MB over the network.
    /// It follows the Download button's path (progress, then the files, then a first load)
    /// and Remove download's, and leaves the folder empty of voices.
    static func runDownload(root: URL) async throws {
        guard !FileManager.default.fileExists(atPath: root.path) else { throw Failure(label: "the download check needs a new folder") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw Failure(label: label) }
            count += 1
        }
        final class Lines: @unchecked Sendable {
            private let lock = NSLock(); private var lines: [String] = []
            func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
        }
        let store = NeuralVoiceStore(root: root), lines = Lines()
        try check(!store.isDownloaded, "a new folder holds no voices")
        let started = Date()
        try await store.download { lines.add($0) }
        let seconds = Date().timeIntervalSince(started), seen = lines.all
        try check(store.isDownloaded, "the download leaves every file a reading loads")
        try check(seen.contains { $0.hasPrefix("Downloading neural voices · ") } && seen.count <= 110 && Set(seen).count == seen.count,
                  "progress arrives as distinct lines, at most one per percent (\(seen.count) lines)")
        let pack = root.appendingPathComponent("Models/pocket-tts")
        let bytes = (FileManager.default.enumerator(at: pack, includingPropertiesForKeys: [.fileSizeKey])?.compactMap {
            (try? ($0 as? URL)?.resourceValues(forKeys: [.fileSizeKey]))?.fileSize } ?? []).reduce(0, +)
        try check(bytes > 300_000_000 && bytes < 900_000_000, "the download is about the size the button says (\(bytes / 1_000_000) MB)")
        try check(NeuralVoiceCatalog.voices.allSatisfy { FileManager.default.fileExists(atPath: pack.appendingPathComponent("v2.1/english/constants_bin/\($0).safetensors").path) },
                  "every listed voice is in the download")
        let loadStarted = Date()
        _ = try await store.ready()
        let loadSeconds = Date().timeIntervalSince(loadStarted)
        try await store.download { lines.add($0) }
        try check(lines.all.count == seen.count || lines.all.count == seen.count + 1, "downloading again fetches nothing")
        try await store.remove()
        try check(!store.isDownloaded && !FileManager.default.fileExists(atPath: pack.path), "Remove download deletes the voices and nothing else in the folder")
        do { _ = try await store.ready(); throw Failure(label: "a reading after removal is refused") }
        catch let error as VoiceError { try check(error.localizedDescription == NeuralVoiceStore.missingMessage, "after removal a reading says where to download") }
        print(String(format: "NEURAL_VOICE_DOWNLOAD_OK: %d MB in %.0f s, first load %.1f s, last line \"%@\"; %d checks passed", bytes / 1_000_000, seconds, loadSeconds, seen.last ?? "", count))
    }

    /// The real model. Writes nothing outside temporary folders and plays nothing aloud.
    static func runRender(root: URL?) async throws {
        let store = NeuralVoiceStore(root: root ?? NeuralVoiceStore.defaultRoot)
        guard store.isDownloaded else { print("NEURAL_VOICE_RENDER_SKIPPED: the voices are not downloaded in \(store.root.path)"); return }
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw Failure(label: label) }
            count += 1
        }
        let sentences = ["Send Sam the revised agenda before the Thursday review.", "Ask which slides need the new numbers.", "Then book the room for two o'clock."]
        let text = ListeningText(sentences.joined(separator: " "))
        let started = Date()
        let render = try NeuralSpeechRenderer(text: text)
        render.start(voice: NeuralVoiceCatalog.defaultVoice, store: store)
        try await render.ready(complete: false)
        let firstAudio = Date().timeIntervalSince(started)
        guard let audio = render.audio else { throw Failure(label: "rendered audio exists") }
        defer { render.discard() }
        // Read's own player, with no audio device, plays the reading while the model makes the rest.
        let player = try ReadingPlayer(source: audio, output: .offline)
        var finishes = 0
        player.onFinish = { _, success in if success { finishes += 1 } }
        try check(!render.isFinished && player.play(), "playback starts while the model is still reading")
        _ = try player.renderOffline(4_096)
        player.tick()
        try check(player.positionFrame == 4_096 && player.duration > 0, "the playback clock follows the neural audio")
        try await render.ready(complete: true)
        let total = Date().timeIntervalSince(started)
        let spoken = text.original as NSString
        try check(render.marks.range(at: player.positionFrame).map { spoken.substring(with: $0) } == sentences[0], "follow-along marks the sentence being played")
        player.currentTime = Double(render.marks.frames.last ?? 0) / audio.format.sampleRate + 0.2
        try check(render.marks.range(at: player.positionFrame).map { spoken.substring(with: $0) } == sentences[2], "seeking to the last sentence marks it")
        while !player.isFinished && player.positionFrame < audio.availableFrames + 48_000 { _ = try player.renderOffline(4_096); player.tick() }
        try check(finishes == 1 && player.isFinished, "the reading plays to its end and finishes once")
        let seconds = Double(audio.availableFrames) / audio.format.sampleRate
        try check(render.isFinished && audio.isComplete, "the reading finished")
        try check(seconds > 5 && seconds < 20, "three sentences make between 5 and 20 seconds of audio (\(String(format: "%.1f", seconds)) s)")
        try check(render.marks.frames.count == sentences.count, "one mark per sentence (\(render.marks.frames.count))")
        try check(render.marks.frames.first == 0 && zip(render.marks.frames, render.marks.frames.dropFirst()).allSatisfy { $0 < $1 }, "sentence marks start at zero and increase")
        let original = text.original as NSString
        try check(render.marks.ranges.map { original.substring(with: $0) } == sentences, "each mark highlights its sentence")
        guard let buffer = try audio.read(from: 0, count: AVAudioFrameCount(audio.availableFrames)), let channel = buffer.floatChannelData?[0] else {
            throw Failure(label: "audio reads back")
        }
        let peak = (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(channel[$1])) }
        try check(peak > 0.05 && peak <= 1, "the audio is audible and unclipped (peak \(peak))")
        print(String(format: "NEURAL_VOICE_RENDER_OK: %@; first audio after %.2f s, %.1f s of audio in %.1f s (%.1f× real time)",
                     NeuralVoiceCatalog.title(NeuralVoiceCatalog.defaultVoice), firstAudio, seconds, total, seconds / total))

        // A second reading reuses the loaded model, and cancelling it stops the model.
        let long = ListeningText(String(repeating: "The workshop starts at nine with a short review of last week's notes. ", count: 60))
        let again = Date()
        let streaming = try NeuralSpeechRenderer(text: long)
        streaming.start(voice: "jane", store: store)
        try await streaming.ready(complete: false)
        let warm = Date().timeIntervalSince(again)
        try check(!streaming.isFinished && streaming.audio != nil, "playback can start before a long reading has rendered")
        let folder = streaming.folder
        streaming.cancel()
        let frames = streaming.audio?.availableFrames
        try await Task.sleep(nanoseconds: 500_000_000)
        try check(!FileManager.default.fileExists(atPath: folder.path), "cancelling removes the partial audio")
        try check(streaming.audio?.availableFrames == frames, "no audio arrives after cancelling")
        print(String(format: "NEURAL_VOICE_STREAM_OK: first audio after %.2f s of a %d-character reading with the model loaded; %d render checks passed", warm, long.spoken.count, count))
    }
}
