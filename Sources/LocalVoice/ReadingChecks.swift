import AppKit
import AVFoundation
import SwiftUI

/// Read aloud checks. `run()` is deterministic: synthetic text, voice catalogues
/// and audio, with playback rendered offline so nothing reaches the speakers.
/// `runRender()` renders synthetic text with an installed Mac voice to a file.
@MainActor
enum ReadingChecks {
    private struct Failure: LocalizedError {
        let label: String
        var errorDescription: String? { "READING CHECK FAILED: \(label)" }
    }

    nonisolated private static func voice(_ id: String, _ name: String, _ language: String, _ quality: MacVoice.Quality = .compact,
                              novelty: Bool = false, sayOnly: Bool = false, legacy: [String] = []) -> MacVoice {
        MacVoice(id: id, name: name, language: language, quality: quality, isNovelty: novelty, sayOnly: sayOnly, legacyNames: legacy)
    }

    /// The compact English voices a fresh macOS 26 install lists, in shuffled order.
    nonisolated static let compactCatalogue: [MacVoice] = [
        voice("com.apple.eloquence.en-US.Eddy", "Eddy", "en-US", legacy: ["Eddy (English (US))"]),
        voice("com.apple.voice.compact.en-US.Samantha", "Samantha", "en-US", legacy: ["Samantha"]),
        voice("com.apple.speech.synthesis.voice.Albert", "Albert", "en-US", novelty: true, legacy: ["Albert"]),
        voice("com.apple.voice.super-compact.en-AU.Karen", "Karen", "en-AU", legacy: ["Karen"]),
        voice("com.apple.eloquence.en-GB.Eddy", "Eddy", "en-GB", legacy: ["Eddy (English (UK))"]),
        voice("com.apple.voice.compact.en-GB.Daniel", "Daniel", "en-GB", legacy: ["Daniel"]),
        voice("com.apple.speech.synthesis.voice.Fred", "Fred", "en-US", legacy: ["Fred"]),
        voice("com.apple.voice.Aman", "Aman", "en-IN", sayOnly: true, legacy: ["Aman"])
    ]

    static func run() throws {
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw Failure(label: label) }
            count += 1
        }
        try checkListening(check)
        try checkVoices(check)
        try checkPace(check)
        try checkMarks(check)
        try checkAudioFile(check)
        try checkPlayer(check)
        try checkSourceFailure(check)
        print("READING_CHECKS_OK: \(count) checks passed")
    }

    // MARK: Prepare for listening

    private static func checkListening(_ check: (@autoclosure () throws -> Bool, String) throws -> Void) throws {
        func spoken(_ text: String) -> String { ListeningText(text).spoken }
        func said(_ text: String, _ word: String) -> String? {
            let prepared = ListeningText(text)
            let range = (prepared.spoken as NSString).range(of: word)
            guard range.location != NSNotFound, let original = prepared.originalRange(forSpoken: range) else { return nil }
            return (text as NSString).substring(with: original)
        }
        let prose = "The workshop starts at 9:30 on 27/09/2026. Bring the A5 notebook, e.g. the blue one, and/or a laptop; 5 * 3 = 15, 24/7 support, snake_case_names and 2*3*4 stay as written."
        try check(spoken(prose) == prose, "plain prose passes through unchanged")
        try check(ListeningText(prose).segments.count == 1 && ListeningText(prose).segments[0].exact, "plain prose keeps one exact word map")
        try check(spoken("# Setup\nInstall the **Workbench** app _first_ and ***now***.") == "Setup.\nInstall the Workbench app first and now.",
                  "heading and emphasis markers are dropped, and headings end as sentences")
        try check(spoken("- Apples\n* Pears!\n+ Plums (ripe)") == "Apples.\nPears!\nPlums (ripe).", "bullets become separate sentences")
        try check(spoken("1. Open the app\n2) Choose Listen.") == "1. Open the app.\n2) Choose Listen.", "numbered items keep their numbers as separate sentences")
        let fenced = "Run this:\n```swift\nlet rate = 0.5\nprint(rate)\n```\nThen listen."
        try check(spoken(fenced) == "Run this:\nCode block skipped.\nThen listen.", "fenced code is announced by a short placeholder")
        try check(said(fenced, "skipped") == "```swift\nlet rate = 0.5\nprint(rate)\n```", "the placeholder highlights the whole code block")
        try check(spoken("Unclosed:\n~~~\ncode") == "Unclosed:\nCode block skipped.", "an unclosed fence runs to the end")
        try check(spoken("Call `AVSpeechSynthesizer.write(_:toBufferCallback:)` with `rate = 0.5`.") == "Call AVSpeechSynthesizer.write(_:toBufferCallback:) with rate = 0.5.",
                  "inline code keeps identifiers and numbers literal")
        try check(spoken("Edit `Sources/LocalVoice/Core.swift` and docs/workbench.md.") == "Edit file Core.swift and file workbench.md.", "file paths speak the file name")
        try check(spoken("See ~/Library/Caches, /usr/bin/say and Sources/LocalVoice/.") == "See path Caches, path say and folder LocalVoice.", "folders and other paths announce what was shortened")
        try check(said("Edit `Sources/LocalVoice/Core.swift` now.", "Core.swift") == "`Sources/LocalVoice/Core.swift`", "a shortened path highlights the whole path")
        try check(spoken("Read [the guide](https://example.com/guide) first.") == "Read the guide first.", "links speak their text, not the address")
        try check(spoken("Docs: https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer.") == "Docs: link to developer.apple.com.",
                  "bare addresses are announced by host")
        try check(spoken("Visit <https://www.apple.com/mac/> or [https://swift.org](https://swift.org).") == "Visit link to apple.com or link to swift.org.",
                  "autolinks and address-text links are announced")
        try check(spoken("| Voice | Quality |\n| --- | :---: |\n| Karen | compact |") == "Voice, Quality.\n\nKaren, compact.", "table rows read as sentences and the delimiter is silent")
        try check(spoken("> Quoted *advice*\n\n---\nEnd") == "Quoted advice\n\n\nEnd", "quotes and rules are formatting only")
        try check(spoken("Keep \\*literal\\* stars, C# and #1 priority.") == "Keep \\*literal\\* stars, C# and #1 priority.", "escapes and hashes inside prose stay")
        let markdown = "# Plan\n\n- Read `docs/plan.md`\n- Visit https://example.com/a/b\n\n```\nx = 1\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n1. **Bold** step"
        for sample in [prose, markdown, fenced, "- a\n- b", "Title\n===\nText", "Ends with URL https://example.com"] {
            let once = ListeningText(sample).spoken
            try check(ListeningText(once).spoken == once, "preparation is idempotent: \(sample.prefix(24))")
        }
        let prepared = ListeningText(markdown)
        var mapped = true
        (prepared.spoken as NSString).enumerateSubstrings(in: NSRange(location: 0, length: (prepared.spoken as NSString).length), options: .byWords) { word, range, _, _ in
            guard let word, let original = prepared.originalRange(forSpoken: range) else { mapped = false; return }
            let source = (markdown as NSString).substring(with: original)
            // Exact words map to themselves; replaced words map to the element they replace.
            if prepared.segments.first(where: { NSLocationInRange(range.location, $0.spoken) })?.exact == true, source != word { mapped = false }
        }
        try check(mapped, "every spoken word maps back to displayed characters")
        try check(said(markdown, "Bold") == "Bold", "emphasised words highlight without their markers")
        try check(ListeningText(String(repeating: "Word ", count: 10_000)).spoken.count == 50_000, "the 50,000-character limit prepares in one pass")
    }

    // MARK: Voices

    private static func checkVoices(_ check: (@autoclosure () throws -> Bool, String) throws -> Void) throws {
        let voices = MacVoiceCatalog.ordered(compactCatalogue, preferredLanguage: "en-AU")
        func resolved(_ saved: String, _ language: String, in catalogue: [MacVoice] = voices) -> String? {
            MacVoiceCatalog.resolve(saved, in: catalogue, preferredLanguage: language)?.voice?.id
        }
        try check(voices.first?.id == "com.apple.voice.super-compact.en-AU.Karen" && voices.last?.isNovelty == true,
                  "picker order puts the person's accent first and novelty voices last")
        try check(voices.first?.label == "Karen (Australian, compact)", "labels show accent and quality")
        let eddies = voices.filter { $0.name == "Eddy" }.map(\.label)
        try check(Set(eddies) == ["Eddy (British, compact)", "Eddy (American, compact)"], "same-name voices in several accents are told apart")
        try check(SavedState().voice.isEmpty, "a fresh install has no saved voice, so the best default applies")
        let earlier = try JSONDecoder().decode(SavedState.self, from: Data(#"{"draft":"","speechText":"","history":[],"replacements":[],"voice":"Karen","rate":230}"#.utf8))
        try check(earlier.voice == "Karen" && earlier.rate == 230, "an earlier saved voice and pace load unchanged")
        try check(resolved("Karen", "en-AU") == "com.apple.voice.super-compact.en-AU.Karen", "a saved name resolves to that voice")
        try check(resolved("Eddy", "en-GB") == "com.apple.eloquence.en-GB.Eddy" && resolved("Eddy", "en-US") == "com.apple.eloquence.en-US.Eddy",
                  "a saved name in several locales prefers the person's locale")
        try check(resolved("Eddy", "en-AU") == "com.apple.eloquence.en-GB.Eddy", "without a locale match the choice is still deterministic")
        try check(resolved("Eddy (English (UK))", "en-US") == "com.apple.eloquence.en-GB.Eddy", "the exact name `say` listed keeps its accent")
        try check(resolved("Eddy (English (US))", "en-GB") == "com.apple.eloquence.en-US.Eddy"
                  && MacVoiceCatalog.sayDescriptor(for: "en-IN") == "English (India)" && MacVoiceCatalog.sayDescriptor(for: "ja-JP") == "Japanese (Japan)",
                  "a `say` name keeps its accent without the `say` list")
        let tiers = [voice("com.apple.voice.compact.en-GB.Daniel", "Daniel", "en-GB"), voice("com.apple.voice.enhanced.en-GB.Daniel", "Daniel", "en-GB", .enhanced)]
        try check(resolved("Daniel", "en-AU", in: tiers) == "com.apple.voice.compact.en-GB.Daniel"
                  && resolved("Daniel (Enhanced)", "en-AU", in: tiers) == "com.apple.voice.enhanced.en-GB.Daniel",
                  "a `say` name keeps its tier: the bare name was the compact voice")
        try check(resolved("com.apple.voice.compact.en-AU.Karen", "en-US") == "com.apple.voice.super-compact.en-AU.Karen",
                  "a renamed quality tier still finds the same voice")
        try check(resolved("Aman", "en-AU") == "com.apple.voice.Aman", "a voice only `say` can speak keeps working")
        try check(MacVoiceCatalog.resolve("com.apple.voice.premium.en-AU.Matilda", in: voices, preferredLanguage: "en-AU") == .missing("Matilda"),
                  "a missing chosen voice is reported, not replaced")
        try check(MacVoiceCatalog.resolve("Zelda", in: voices, preferredLanguage: "en-AU") == .missing("Zelda"), "a missing saved name is reported")
        try check(MacVoiceCatalog.resolve(" ", in: voices, preferredLanguage: "en-AU") == nil, "no saved choice means the default applies")
        // The `say` list is the one lookup that asks macOS about voices by
        // language and name (#140); the catalogue asks for it only when a
        // saved choice can be nothing else.
        let bare = voices.map { voice in MacVoice(id: voice.id, name: voice.name, language: voice.language, quality: voice.quality,
                                                   isNovelty: voice.isNovelty, sayOnly: voice.sayOnly) }
        let plain = bare.filter { !$0.sayOnly }
        try check(["", "com.apple.voice.super-compact.en-AU.Karen", "com.apple.voice.compact.en-AU.Karen", "Karen", "Eddy (English (UK))"]
                  .allSatisfy { !MacVoiceCatalog.needsSayVoices(for: $0, in: plain, preferredLanguage: "en-AU") },
                  "an identifier, a name or no choice never needs the `say` list")
        try check(MacVoiceCatalog.needsSayVoices(for: "Aman", in: plain, preferredLanguage: "en-AU")
                  && MacVoiceCatalog.needsSayVoices(for: "com.apple.voice.Aman", in: plain, preferredLanguage: "en-AU")
                  && !MacVoiceCatalog.needsSayVoices(for: "Aman", in: bare, preferredLanguage: "en-AU"),
                  "only a choice that can be a voice `say` alone lists asks for it, and once listed it resolves")
        try check(MacVoiceCatalog.installed(preferredLanguage: "en-AU").allSatisfy { !$0.sayOnly && $0.legacyNames.isEmpty }
                  && MacVoiceCatalog.sayScanCount == 0, "listing installed voices never asks NSSpeechSynthesizer")
        func fresh(_ language: String, _ catalogue: [MacVoice] = compactCatalogue) -> String? {
            MacVoiceCatalog.preferredDefault(in: catalogue, preferredLanguage: language)?.id
        }
        try check(fresh("en-AU") == "com.apple.voice.super-compact.en-AU.Karen" && fresh("en-US") == "com.apple.voice.compact.en-US.Samantha"
                  && fresh("en-GB") == "com.apple.voice.compact.en-GB.Daniel", "a fresh install uses the person's region")
        try check(fresh("en-NZ") == "com.apple.voice.compact.en-GB.Daniel", "a region without voices falls back by quality, then name")
        let premium = compactCatalogue + [voice("com.apple.voice.premium.en-AU.Matilda", "Matilda", "en-AU", .premium),
                                          voice("com.apple.voice.enhanced.en-US.Ava", "Ava", "en-US", .enhanced)]
        try check(fresh("en-AU", premium) == "com.apple.voice.premium.en-AU.Matilda" && fresh("en-US", premium) == "com.apple.voice.premium.en-AU.Matilda",
                  "the highest-quality voice in the person's language wins")
        try check(fresh("en-AU", [voice("com.apple.speech.synthesis.voice.Bells", "Bells", "en-US", novelty: true), compactCatalogue[7]]) == nil,
                  "novelty and say-only voices are never a default")
        try check(resolved("Karen", "en-AU", in: premium) == "com.apple.voice.super-compact.en-AU.Karen", "installing a better voice never replaces a saved choice")
        let merged = MacVoiceCatalog.merging([voice("com.apple.voice.super-compact.en-AU.Karen", "Karen", "en-AU"),
                                              voice("com.apple.eloquence.en-GB.Eddy", "Eddy", "en-GB")], sayVoices: [
            ("com.apple.voice.compact.en-AU.Karen", "Karen", "en-AU"), ("com.apple.eloquence.en-GB.Eddy", "Eddy (English (UK))", "en-GB"),
            ("com.apple.voice.Aman", "Aman (English (India))", "en-IN"), ("com.apple.voice.Aman.premium", "Aman (English (India))", "en-IN")])
        try check(merged.map(\.legacyNames) == [["Karen"], ["Eddy (English (UK))"], ["Aman (English (India))"]]
                  && merged.last?.sayOnly == true && merged.last?.id == "com.apple.voice.Aman",
                  "names `say` listed attach to the same voices; a say-only voice is kept once per name")
        try check(MacVoiceCatalog.upgradeHint(for: merged + [voice("com.apple.voice.Tara.premium", "Tara", "en-IN", .premium, sayOnly: true)],
                                              preferredLanguage: "en-AU") != nil, "a say-only voice never hides the hint")
        let hint = MacVoiceCatalog.upgradeHint(for: compactCatalogue, preferredLanguage: "en-AU")
        try check(hint?.suggestion == "Matilda (Premium)" && hint?.message == "Matilda (Premium) sounds more natural and is free to add.",
                  "the hint names a free better voice for the region")
        try check(MacVoiceCatalog.upgradeHint(for: compactCatalogue, preferredLanguage: "en-NZ")?.suggestion == nil,
                  "without a known voice for the region the hint stays general")
        try check(MacVoiceCatalog.upgradeHint(for: premium, preferredLanguage: "en-AU") == nil
                  && MacVoiceCatalog.upgradeHint(for: compactCatalogue + [premium[9]], preferredLanguage: "en-GB") == nil,
                  "the hint disappears once an Enhanced or Premium voice is installed")
        let copy = [hint?.message, hint?.buttonTitle, hint?.help, MacVoiceHint(suggestion: nil).message].compactMap { $0 }.joined()
        try check(!copy.contains("—") && !copy.contains("–") && !copy.contains(" - "), "hint copy has no dash punctuation")
        try check(MacVoiceCatalog.settingsURL.scheme == "x-apple.systempreferences"
                  && MacVoiceCatalog.settingsURL.absoluteString.contains("com.apple.Accessibility-Settings.extension"),
                  "the button opens the Accessibility settings extension pane")
        try check(MacVoiceCatalog.accent(for: "en-IE") == "Irish" && MacVoiceCatalog.accent(for: "fr-CA") == "French, Canada",
                  "accents are named plainly")
    }

    // MARK: Pace

    private static func checkPace(_ check: (@autoclosure () throws -> Bool, String) throws -> Void) throws {
        let rate = MacVoicePace.utteranceRate(forWordsPerMinute:)
        try check(rate(180) == 0.5 && rate(300) == 0.6 && rate(100) == 0.34 && rate(240) == 0.55, "measured anchors map exactly")
        try check(abs(rate(150) - 0.46) < 0.0001 && abs(rate(190) - 0.5125) < 0.0001, "pace between anchors interpolates")
        try check(rate(40) == 0.34 && rate(500) == 0.6 && rate(.nan) == AVSpeechUtteranceDefaultSpeechRate, "out-of-range pace is clamped")
        let rates = stride(from: 100.0, through: 300.0, by: 5).map(rate)
        try check(zip(rates, rates.dropFirst()).allSatisfy { $0 <= $1 }, "a faster pace never renders slower")
    }

    // MARK: Word timing

    private static func checkMarks(_ check: (@autoclosure () throws -> Bool, String) throws -> Void) throws {
        let text = "## Steps\n- Open `docs/plan.md` today\n- Listen"
        let prepared = ListeningText(text)
        let spoken = prepared.spoken as NSString
        // Simulate rendering: every word callback arrives when this much audio exists.
        var marks = ReadingMarks()
        var frame: AVAudioFramePosition = 100
        spoken.enumerateSubstrings(in: NSRange(location: 0, length: spoken.length), options: .byWords) { _, range, _, _ in
            marks.append(frame: frame, range: prepared.originalRange(forSpoken: range))
            frame += 5_000
        }
        func word(at frame: AVAudioFramePosition) -> String? {
            marks.range(at: frame).map { (text as NSString).substring(with: $0) }
        }
        try check(marks.frames == marks.frames.sorted() && Set(marks.frames).count == marks.frames.count, "recorded frames are increasing")
        try check(word(at: 0) == nil && word(at: 100) == "Steps" && word(at: 5_099) == "Steps", "no word before the first starts; each lasts until the next")
        try check(word(at: 5_100) == "Open" && word(at: 10_100) == "`docs/plan.md`" && word(at: 20_100) == "today",
                  "a replaced path is one mark covering the whole path")
        try check(word(at: 1_000_000) == "Listen", "after the last word it stays highlighted")
        var repeated = ReadingMarks()
        repeated.append(frame: 50, range: NSRange(location: 0, length: 4))
        repeated.append(frame: 40, range: NSRange(location: 5, length: 3))
        repeated.append(frame: 60, range: NSRange(location: 5, length: 3))
        repeated.append(frame: 70, range: nil)
        try check(repeated.frames == [50, 50] && repeated.ranges.count == 2, "out-of-order and repeated callbacks cannot move backwards or duplicate")
    }

    // MARK: Growing audio file

    nonisolated private static func ramp(from start: Int, count: Int, sampleRate: Double = 22_050) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for index in 0..<count { buffer.floatChannelData![0][index] = rampValue(start + index) }
        return buffer
    }
    /// Exactly representable in 16 bits, so round trips compare equal.
    nonisolated private static func rampValue(_ frame: Int) -> Float { Float(frame % 20_000 - 10_000) / 32_768 }
    private static func matchesRamp(_ buffer: AVAudioPCMBuffer, from start: Int, count: Int? = nil) -> Bool {
        let frames = count ?? Int(buffer.frameLength)
        guard Int(buffer.frameLength) >= frames, let channel = buffer.floatChannelData?[0] else { return false }
        return (0..<frames).allSatisfy { channel[$0] == rampValue(start + $0) }
    }

    private static func checkAudioFile(_ check: (@autoclosure () throws -> Bool, String) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalVoice-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try ReadingAudioFile(url: folder.appendingPathComponent("speech.wav"), sampleRate: 22_050)
        try file.append(ramp(from: 0, count: 256))
        try check(file.availableFrames == 256 && !file.isComplete, "appended frames are available at once")
        try check(try file.read(from: 0, count: 256).map { matchesRamp($0, from: 0) } == true, "rendered frames read back exactly before any flush")
        for chunk in 1..<200 { try file.append(ramp(from: chunk * 256, count: 256)) }
        try check(try file.read(from: 30_000, count: 5_000).map { matchesRamp($0, from: 30_000) } == true, "a later range reads back while rendering continues")
        try check(try file.read(from: 51_000, count: 5_000)?.frameLength == 200, "reads stop at what has rendered")
        try check(try file.read(from: 60_000, count: 10) == nil, "nothing exists beyond the rendered audio")
        try file.finish()
        let saved = try AVAudioFile(forReading: file.url)
        try check(file.isComplete && saved.length == 51_200 && saved.fileFormat.sampleRate == 22_050, "finishing writes an ordinary WAV")
        let copy = AVAudioPCMBuffer(pcmFormat: saved.processingFormat, frameCapacity: 51_200)!
        try saved.read(into: copy)
        try check(matchesRamp(copy, from: 0), "the saved WAV holds exactly the rendered samples")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o600, "reading audio is private to the current user")
        try check(try file.read(from: 51_199, count: 5).map { matchesRamp($0, from: 51_199) } == true, "a finished file stays readable for replay")
    }

    // MARK: Player

    private static func checkPlayer(_ check: (@autoclosure () throws -> Bool, String) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalVoice-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try ReadingAudioFile(url: folder.appendingPathComponent("speech.wav"), sampleRate: 22_050)
        try file.append(ramp(from: 0, count: 22_050))
        let player = try ReadingPlayer(source: file, output: .offline)
        var finishes = 0
        player.onFinish = { _, success in if success { finishes += 1 } }
        try check(player.play() && player.isPlaying, "playback starts while the voice is still rendering")
        var output = try player.renderOffline(4_096)
        player.tick()
        try check(matchesRamp(output, from: 0) && player.positionFrame == 4_096, "the playback clock follows the audio actually rendered")
        player.currentTime = 30
        try check(player.positionFrame == 22_049, "seeking beyond what has rendered stops at the last rendered frame")
        player.currentTime = 0.5
        output = try player.renderOffline(1_000)
        try check(matchesRamp(output, from: 11_025) && player.positionFrame == 12_025, "seeking within rendered audio plays from that frame")
        player.pause()
        output = try player.renderOffline(1_000)
        try check(!player.isPlaying && player.positionFrame == 12_025 && (0..<1_000).allSatisfy { output.floatChannelData![0][$0] == 0 },
                  "pause is silent and holds the position")
        try check(player.play(), "resume continues")
        output = try player.renderOffline(4_096)
        try check(matchesRamp(output, from: 12_025), "resume continues from the held frame")
        // Play past everything rendered so far: the player waits instead of
        // counting silence, then continues from the same frame.
        for _ in 0..<5 { _ = try player.renderOffline(4_096); player.tick() }
        try check(player.isWaitingForAudio && player.positionFrame == 22_050, "catching up with rendering waits at the last frame")
        try file.append(ramp(from: 22_050, count: 11_025))
        player.tick()
        output = try player.renderOffline(1_024)
        try check(matchesRamp(output, from: 22_050) && !player.isWaitingForAudio, "new audio continues without skipping or repeating")
        try file.finish()
        for _ in 0..<5 { _ = try player.renderOffline(4_096); player.tick() }
        try check(finishes == 1 && player.isFinished && !player.isPlaying, "the end of a finished reading is reported once")
        player.tick(); player.stop()
        try check(finishes == 1 && !player.play(), "a finished player cannot restart or report again")
        let replay = try ReadingPlayer(source: try ReadingFileSource(url: file.url), output: .offline)
        try check(replay.play() && replay.duration == 33_075.0 / 22_050, "the finished file replays through the same player")
        replay.currentTime = 1.0
        output = try replay.renderOffline(512)
        try check(matchesRamp(output, from: 22_050), "a finished file seeks exactly")
        replay.stop()
    }

    /// Ramp audio held in memory that throws once a read reaches `failFrom`,
    /// like a reading whose file became unreadable. `streaming` lists only what
    /// has been "rendered" so far; a read beyond that is not ready yet, which is
    /// not a failure. `emptyFrom` returns nothing instead of throwing, like a
    /// finished file shorter than it claims. It counts every read and throw.
    private final class FaultySource: ReadingAudioSource {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22_050, channels: 1, interleaved: false)!
        var availableFrames: AVAudioFramePosition
        var isComplete: Bool
        let failFrom: AVAudioFramePosition?
        let emptyFrom: AVAudioFramePosition?
        private(set) var reads = 0
        private(set) var failures = 0

        init(frames: AVAudioFramePosition, complete: Bool = true, failFrom: AVAudioFramePosition? = nil, emptyFrom: AVAudioFramePosition? = nil) {
            availableFrames = frames
            isComplete = complete
            self.failFrom = failFrom
            self.emptyFrom = emptyFrom
        }

        func read(from frame: AVAudioFramePosition, count: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
            reads += 1
            let frames = min(AVAudioFramePosition(count), availableFrames - frame)
            guard frames > 0 else { return nil }
            if let failFrom, frame + frames > failFrom {
                failures += 1
                throw VoiceError.message("Synthetic read failure.")
            }
            if let emptyFrom, frame + frames > emptyFrom { return nil }
            return ReadingChecks.ramp(from: Int(frame), count: Int(frames))
        }
    }

    /// A source that throws ends the reading once, whether it fails before the
    /// first frame or after audio has played. A source that is only not ready
    /// yet keeps waiting and then continues.
    private static func checkSourceFailure(_ check: (@autoclosure () throws -> Bool, String) throws -> Void) throws {
        func play(_ source: FaultySource) throws -> (player: ReadingPlayer, finishes: () -> [Bool]) {
            let player = try ReadingPlayer(source: source, output: .offline)
            var reports: [Bool] = []
            player.onFinish = { _, success in reports.append(success) }
            return (player, { reports })
        }

        // Fails before the first frame: nothing can be scheduled.
        let early = FaultySource(frames: 44_100, failFrom: 0)
        let (first, firstReports) = try play(early)
        _ = first.play()
        for _ in 0..<10 { _ = try first.renderOffline(1_024); first.tick() }
        try check(firstReports() == [false] && first.isFinished && !first.isPlaying && !first.isWaitingForAudio,
                  "a source that fails before its first frame ends the reading once, as a failure")
        try check(early.failures == 1, "a failed source is read no more: \(early.failures) failures in \(early.reads) reads")
        try check(!first.play() && firstReports() == [false], "a failed reading cannot restart or report again")

        // Fails after some audio has played, beyond the first lookahead.
        let late = FaultySource(frames: 22_050 * 10, failFrom: 22_050 * 5)
        let (second, secondReports) = try play(late)
        _ = second.play()
        var played = 0, heard = true
        while secondReports().isEmpty && played < 22_050 * 10 {
            let output = try second.renderOffline(4_096)
            if played < 22_050 { heard = heard && matchesRamp(output, from: played) }
            played += 4_096
            second.tick()
        }
        try check(heard && played > 22_050, "audio before a failure plays exactly (\(played) frames)")
        try check(secondReports() == [false] && second.isFinished && !second.isPlaying,
                  "a source that fails after buffered audio ends the reading once, as a failure")
        for _ in 0..<10 { second.tick() }
        try check(late.failures == 1 && secondReports() == [false], "no retry loop or repeated error after a failure")

        // A failure found just before a pause is still reported once: the paused
        // reading ends at the next tick instead of waiting to be resumed.
        let paused = FaultySource(frames: 22_050 * 10, failFrom: 22_050 * 5)
        let (held, heldReports) = try play(paused)
        _ = held.play()
        while held.readFailure == nil && !held.isFinished { _ = try held.renderOffline(4_096); held.tick() }
        held.pause()
        try check(!held.isPlaying && !held.isFinished && heldReports().isEmpty, "the reading paused after its source failed, before the next tick")
        for _ in 0..<5 { held.tick() }
        try check(heldReports() == [false] && held.isFinished && paused.failures == 1, "a paused reading whose source failed ends once, as a failure")
        try check(!held.play() && heldReports() == [false], "a paused reading that failed cannot resume")

        // A finished source that has nothing where it claims audio cannot catch up.
        let short = FaultySource(frames: 44_100, emptyFrom: 11_025)
        let (third, thirdReports) = try play(short)
        _ = third.play()
        for _ in 0..<10 { _ = try third.renderOffline(4_096); third.tick() }
        try check(thirdReports() == [false] && third.isFinished, "a finished source that returns no audio inside its length ends as a failure")

        // Not rendered yet is not a failure: the reading waits, then continues.
        let streaming = FaultySource(frames: 0, complete: false)
        let (fourth, fourthReports) = try play(streaming)
        try check(fourth.play() && fourth.isWaitingForAudio, "a reading with no audio yet waits for it")
        for _ in 0..<10 { _ = try fourth.renderOffline(1_024); fourth.tick() }
        try check(fourth.isWaitingForAudio && !fourth.isFinished && fourthReports().isEmpty && streaming.failures == 0,
                  "audio that is not rendered yet keeps the reading waiting, with no failure")
        streaming.availableFrames = 22_050
        fourth.tick()
        let output = try fourth.renderOffline(1_024)
        try check(matchesRamp(output, from: 0) && !fourth.isWaitingForAudio, "the reading continues once audio exists")
        streaming.isComplete = true
        for _ in 0..<10 { _ = try fourth.renderOffline(4_096); fourth.tick() }
        try check(fourthReports() == [true], "a reading that waited finishes normally")
    }

    // MARK: Rendering with an installed voice

    /// Renders synthetic text with an installed English voice into a file and
    /// checks word timing against the audio itself. Nothing is played.
    static func runRender() async throws {
        let installed = MacVoiceCatalog.installed(preferredLanguage: "en-US")
        var voices = ["com.apple.voice.compact.en-US.Samantha", "com.apple.voice.super-compact.en-AU.Karen", "com.apple.voice.compact.en-GB.Daniel"]
            .compactMap { id in installed.first { $0.id == id } }
        if voices.isEmpty, let any = installed.first(where: { !$0.isNovelty && !$0.sayOnly && $0.language.hasPrefix("en") }) { voices = [any] }
        guard let first = voices.first else { print("READING_RENDER_SKIPPED: no installed English Mac voice"); return }
        var count = 0
        // A listed voice is reachable by its installed identifier alone, so
        // rendering never looks a voice up by language or name (#140).
        guard voices.allSatisfy({ AVSpeechSynthesisVoice(identifier: $0.id) != nil }), MacVoiceCatalog.sayScanCount == 0 else {
            throw Failure(label: "a listed voice is constructed from its identifier without the `say` list")
        }
        count += 1
        for voice in voices {
            func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
                guard try value() else { throw Failure(label: "\(label) (\(voice.id))") }
                count += 1
            }
            // Sentence breaks leave silence between words, and vowel onsets are
            // loud at once, so the audio itself shows where each word starts.
            let words = ["Alpha", "Echo", "India", "Oscar", "Amber", "Olive"]
            let render = try MacSpeechRenderer(text: ListeningText(words.joined(separator: ". ") + "."))
            try render.start(voiceIdentifier: voice.id, rate: MacVoicePace.utteranceRate(forWordsPerMinute: 180))
            try await render.ready(complete: true)
            guard let audio = render.audio else { throw Failure(label: "rendered audio exists") }
            defer { render.discard() }
            let rate = audio.format.sampleRate, total = audio.availableFrames
            let marks = render.marks
            try check(marks.frames.count == words.count, "one word callback per word")
            try check(zip(marks.frames, marks.frames.dropFirst()).allSatisfy { $0 < $1 }, "word frames are strictly increasing")
            try check(Double(marks.frames[0]) / rate < 0.3, "the first word starts near zero")
            let tail = Double(total - marks.frames.last!) / rate
            try check(tail > 0.1 && tail < 1.5, "the last word starts in the final stretch of the audio")
            guard let buffer = try audio.read(from: 0, count: AVAudioFrameCount(total)) else { throw Failure(label: "audio reads back") }
            let onsets = voicedOnsets(buffer)
            try check(onsets.count == words.count, "the audio has one voiced stretch per word (found \(onsets.count))")
            let offsets = zip(marks.frames, onsets).map { Double($0 - $1) / rate }
            try check(offsets.allSatisfy { abs($0) < 0.08 }, "each word's frame is within 80 ms of its voiced onset: \(offsets.map { String(format: "%+.3f", $0) })")
            let saved = try AVAudioFile(forReading: audio.url)
            try check(saved.length == total, "the finished file holds the rendered audio")
            print(String(format: "READING_RENDER_OK: %@; word onsets %@ s from the recorded frames; last word %.2f s before the end",
                         voice.label, offsets.map { String(format: "%+.3f", $0) }.joined(separator: " "), tail))
        }

        // Streaming: playback may start long before a long reading finishes, and
        // cancelling stops rendering and removes the file.
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw Failure(label: label) }
            count += 1
        }
        let long = ListeningText(String(repeating: "The workshop starts at nine with a short review of last week's notes. ", count: 400))
        let started = Date()
        let streaming = try MacSpeechRenderer(text: long)
        try streaming.start(voiceIdentifier: first.id, rate: 0.5)
        try await streaming.ready(complete: false)
        let firstAudio = Date().timeIntervalSince(started)
        try check(!streaming.isFinished && streaming.audio != nil, "playback can start before the reading has rendered")
        let folder = streaming.folder
        streaming.cancel()
        let frames = streaming.audio?.availableFrames, marksCount = streaming.marks.frames.count
        try await Task.sleep(nanoseconds: 300_000_000)
        try check(!FileManager.default.fileExists(atPath: folder.path), "cancelling removes the partial audio")
        try check(streaming.audio?.availableFrames == frames && streaming.marks.frames.count == marksCount, "no callbacks arrive after cancelling")
        print(String(format: "READING_STREAM_OK: first audio after %.2f s of a %d-character reading; %d render checks passed", firstAudio, long.spoken.count, count))
    }

    /// Frames where speech resumes after at least 120 ms below the noise floor:
    /// sentence pauses measure about 220 ms, gaps inside a word under 70 ms.
    private static func voicedOnsets(_ buffer: AVAudioPCMBuffer) -> [AVAudioFramePosition] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        let window = max(1, Int(buffer.format.sampleRate / 100))
        let frames = Int(buffer.frameLength)
        var onsets: [AVAudioFramePosition] = []
        var quiet = 12
        var start = 0
        while start < frames {
            let end = min(frames, start + window)
            var energy: Float = 0
            for index in start..<end { energy += channel[index] * channel[index] }
            let voiced = (energy / Float(end - start)).squareRoot() > 0.02
            if voiced {
                if quiet >= 12 {
                    // Refine the onset to the first loud sample in this window.
                    let first = (start..<end).first { abs(channel[$0]) > 0.02 } ?? start
                    onsets.append(AVAudioFramePosition(first))
                }
                quiet = 0
            } else {
                quiet += 1
            }
            start = end
        }
        return onsets
    }
}

extension ReadingChecks {
    /// Time to first audio through the production path: prepare the text,
    /// render with a Mac voice, and start a player once the first audio exists.
    /// The player renders offline, so nothing is heard; the device engine's
    /// start-up is timed separately without scheduling any audio.
    static func measureLatency(voices: [String], files: [URL], runs: Int = 3) async throws {
        print("voice | passage | words | first audio (s), median of \(runs) | full render (s)")
        for voiceID in voices {
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                var firsts: [Double] = [], totals: [Double] = []
                for _ in 0..<runs {
                    let started = Date()
                    let render = try MacSpeechRenderer(text: ListeningText(text))
                    try render.start(voiceIdentifier: voiceID, rate: MacVoicePace.utteranceRate(forWordsPerMinute: 180))
                    try await render.ready(complete: false)
                    guard let audio = render.audio else { throw Failure(label: "latency render produced audio") }
                    let player = try ReadingPlayer(source: audio, output: .offline)
                    guard player.play() else { throw Failure(label: "latency player started") }
                    firsts.append(Date().timeIntervalSince(started))
                    try await render.ready(complete: true)
                    totals.append(Date().timeIntervalSince(started))
                    player.stop(); render.discard()
                }
                let median = { (values: [Double]) in values.sorted()[values.count / 2] }
                print(String(format: "%@ | %@ | %d | %.3f | %.3f", voiceID, file.lastPathComponent, TextRules.wordCount(text), median(firsts), median(totals)))
            }
        }
        var starts: [Double] = []
        for _ in 0..<runs {
            let engine = AVAudioEngine(), node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
            let started = Date()
            try engine.start()
            starts.append(Date().timeIntervalSince(started))
            engine.stop()
        }
        print(String(format: "device engine start with no audio scheduled: %.3f s median", starts.sorted()[starts.count / 2]))
    }

    /// Offscreen renders of the Read page mid-reading, built from the production
    /// voice panel, follow-along text and playback strip with synthetic content.
    static func renderFixtures(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = """
        # Launch notes

        The workshop starts at nine with a short review of last week's notes. Maya walks through the revised budget, then the team compares two layouts for the reception display.

        - Open `Sources/Reception/Layout.swift` before the review
        - Read [the design guide](https://example.com/guide) first
        - Keep the logo small and the welcome message clear
        """
        let prepared = ListeningText(text)
        let spoken = prepared.spoken as NSString
        let spokenWord = spoken.range(of: "budget")
        let highlight = prepared.originalRange(forSpoken: spokenWord)
        let voices = MacVoiceCatalog.ordered(compactCatalogue.filter { !$0.sayOnly }, preferredLanguage: "en-AU")
        let karen = voices.first { $0.name == "Karen" }!
        for (name, scheme) in [("reading-mid-dark", ColorScheme.dark), ("reading-mid-light", ColorScheme.light)] {
            let page = VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
                WorkbenchPageHeader("speak", summary: "Paste something to hear it aloud, or save a reading to take with you.")
                Picker("Read with", selection: .constant(ReadingProvider.mac)) {
                    ForEach(ReadingProvider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                MacVoicePanel(voices: voices, choice: .installed(karen), hint: MacVoiceCatalog.upgradeHint(for: voices, preferredLanguage: "en-AU"),
                              rate: .constant(180), choose: { _ in }, preview: {}, openSettings: {})
                ReadingFollowAlongView(text: text, highlight: highlight)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Workbench.surface.opacity(0.6)))
                    .frame(height: 250)
                ReadingPlaybackStrip(elapsed: 7, duration: 41, renderingAhead: true, seek: { _ in }, skip: { _ in })
                HStack(spacing: 12) {
                    Button {} label: { Label("Pause", systemImage: "pause.fill") }.buttonStyle(PrimaryButton())
                    Button("Stop") {}
                    Spacer()
                    Button {} label: { Label("Save audio…", systemImage: "square.and.arrow.down") }.disabled(true)
                }.controlSize(.large)
            }
            .padding(Workbench.pagePadding).frame(width: 860, height: 900, alignment: .topLeading)
            .background(Workbench.background).tint(Workbench.accent).environment(\.colorScheme, scheme)
            try snapshot(page, size: NSSize(width: 860, height: 900), scheme: scheme, to: folder.appendingPathComponent(name + ".png"))
        }
        let hintOnly = MacVoicePanel(voices: voices, choice: .installed(karen), hint: MacVoiceCatalog.upgradeHint(for: voices, preferredLanguage: "en-AU"),
                                     rate: .constant(180), choose: { _ in }, preview: {}, openSettings: {})
            .padding(24).frame(width: 760, alignment: .topLeading).background(Workbench.background).tint(Workbench.accent)
            .environment(\.colorScheme, .light)
        try snapshot(hintOnly, size: NSSize(width: 760, height: 190), scheme: .light, to: folder.appendingPathComponent("voice-hint-light.png"))
        print("READING_FIXTURE_RENDER_OK: \(folder.path); highlighted “\((text as NSString).substring(with: highlight!))” while “\(spoken.substring(with: spokenWord))” is spoken")
    }

    private static func snapshot<Content: View>(_ content: Content, size: NSSize, scheme: ColorScheme, to url: URL) throws {
        let view = NSHostingView(rootView: content)
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        // Let the text view settle its layout and highlight before drawing.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(label: "fixture bitmap allocation") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(label: "fixture PNG encoding") }
        try png.write(to: url, options: .atomic)
    }
}
