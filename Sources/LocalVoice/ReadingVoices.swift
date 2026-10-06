import AppKit
import AVFoundation

/// An installed Mac voice, identified by its system identifier.
struct MacVoice: Identifiable, Hashable, Sendable {
    enum Quality: Int, Comparable, Sendable {
        case compact = 1, enhanced = 2, premium = 3
        static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }
        init(_ quality: AVSpeechSynthesisVoiceQuality) {
            switch quality {
            case .premium: self = .premium
            case .enhanced: self = .enhanced
            default: self = .compact
            }
        }
        /// Tiers named in voice identifiers such as `com.apple.voice.premium.en-AU.Matilda`.
        init(identifier: String) {
            let parts = identifier.lowercased().split(separator: ".")
            self = parts.contains("premium") ? .premium : parts.contains("enhanced") ? .enhanced : .compact
        }
        var label: String { self == .premium ? "premium" : self == .enhanced ? "enhanced" : "compact" }
    }

    let id: String
    let name: String
    /// BCP 47, for example `en-AU`.
    let language: String
    let quality: Quality
    var isNovelty = false
    /// Only `/usr/bin/say` can speak it, so it has no word timing.
    var sayOnly = false
    /// Names that earlier Workbench builds saved for this voice, such as
    /// `Karen` or `Eddy (English (UK))`.
    var legacyNames: [String] = []

    /// "Karen (Australian, compact)": the same name can exist in several accents
    /// and qualities, so the picker always shows both.
    var label: String { "\(name) (\(MacVoiceCatalog.accent(for: language)), \(quality.label))" }
    /// The name `say -v` accepts for a voice only `say` can use.
    var sayName: String { legacyNames.first ?? name }
}

/// What a saved choice refers to on this Mac.
enum MacVoiceChoice: Equatable {
    case installed(MacVoice)
    /// The chosen voice is not installed. It is kept, never silently replaced.
    case missing(String)

    var voice: MacVoice? { if case .installed(let voice) = self { return voice }; return nil }
}

/// The one-line Read page suggestion shown while every voice for the person's
/// language is compact.
struct MacVoiceHint: Equatable {
    /// A free voice for their region, when one is known.
    let suggestion: String?
    var message: String {
        suggestion.map { "\($0) sounds more natural and is free to add." }
            ?? "Enhanced and Premium voices sound more natural and are free to add."
    }
    var buttonTitle: String { "Open \(MacVoiceCatalog.settingsTitle)" }
    var help: String {
        "Opens \(MacVoiceCatalog.settingsTitle) in System Settings. Add \(suggestion ?? "a voice") from the System voice options, then choose it here."
    }
}

enum MacVoiceCatalog {
    /// Accessibility › Spoken Content, renamed Read & Speak in macOS 26. The
    /// anchor is the pane's long-standing TextToSpeech key; opening it changes
    /// no setting.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?TextToSpeech")!
    static var settingsTitle: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? "Read & Speak" : "Spoken Content"
    }

    /// Free downloads named in the hint. Only voices known to ship for the
    /// region are listed; other regions get the general wording.
    static let freeUpgrades = ["en-AU": "Matilda (Premium)", "en-US": "Ava (Premium)", "en-GB": "Serena (Premium)",
                               "en-IE": "Moira (Enhanced)", "en-ZA": "Tessa (Enhanced)"]

    /// The person's speech language, such as `en-AU`.
    static var preferredLanguage: String { AVSpeechSynthesisVoice.currentLanguageCode() }

    /// Installed voices for English and the person's own language, best first.
    /// Both listings are Accessibility framework calls, so they go through the bridge.
    static func installed(preferredLanguage: String = preferredLanguage) -> [MacVoice] {
        let voices = AccessibilityBridge.speechVoices().compactMap { voice -> MacVoice? in
            guard !voice.traits.contains(.isPersonalVoice), relevant(voice.language, preferredLanguage: preferredLanguage) else { return nil }
            return MacVoice(id: voice.identifier, name: voice.name, language: voice.language, quality: MacVoice.Quality(voice.quality),
                            isNovelty: voice.traits.contains(.isNoveltyVoice))
        }
        let sayVoices = AccessibilityBridge.sayVoices().compactMap { voice -> (id: String, name: String, language: String)? in
            guard let name = voice.attributes[.name] as? String, let locale = voice.attributes[.localeIdentifier] as? String else { return nil }
            let language = locale.replacingOccurrences(of: "_", with: "-")
            return relevant(language, preferredLanguage: preferredLanguage) ? (voice.identifier.rawValue, name, language) : nil
        }
        return ordered(merging(voices, sayVoices: sayVoices), preferredLanguage: preferredLanguage)
    }

    /// Earlier builds saved the names `say` lists. Attach them so those choices
    /// keep working, and keep the few voices only `say` can speak.
    static func merging(_ voices: [MacVoice], sayVoices: [(id: String, name: String, language: String)]) -> [MacVoice] {
        var voices = voices
        for say in sayVoices {
            let quality = MacVoice.Quality(identifier: say.id)
            if let index = voices.firstIndex(where: { $0.id == say.id })
                ?? voices.firstIndex(where: { !$0.sayOnly && $0.name == baseName(say.name) && $0.language == say.language && $0.quality == quality }) {
                voices[index].legacyNames.append(say.name)
            } else if !voices.contains(where: { $0.sayOnly && $0.legacyNames.contains(say.name) }) {
                // `say -v` selects by name, so of two voices sharing one only the
                // first is reachable (a later Siri voice can reuse a name).
                voices.append(MacVoice(id: say.id, name: baseName(say.name), language: say.language, quality: quality,
                                       sayOnly: true, legacyNames: [say.name]))
            }
        }
        return voices
    }

    static func relevant(_ language: String, preferredLanguage: String) -> Bool {
        let code = languageCode(language)
        return code == "en" || code == languageCode(preferredLanguage)
    }

    /// Picker order: better quality first, the person's accent first within a
    /// quality, Apple's natural voices before older ones; voices only `say` can
    /// speak, then novelty voices, last.
    static func ordered(_ voices: [MacVoice], preferredLanguage: String) -> [MacVoice] {
        voices.sorted { lhs, rhs in
            let left = (lhs.isNovelty ? 1 : 0, lhs.sayOnly ? 1 : 0, -lhs.quality.rawValue, affinity(lhs, preferredLanguage), family(lhs))
            let right = (rhs.isNovelty ? 1 : 0, rhs.sayOnly ? 1 : 0, -rhs.quality.rawValue, affinity(rhs, preferredLanguage), family(rhs))
            if left != right { return left < right }
            return (lhs.name, lhs.language, lhs.id) < (rhs.name, rhs.language, rhs.id)
        }
    }

    /// Resolves a saved choice: an identifier, or a name an earlier build saved.
    /// Nil means nothing was chosen yet, so the best default applies.
    static func resolve(_ saved: String, in voices: [MacVoice], preferredLanguage: String) -> MacVoiceChoice? {
        let saved = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.isEmpty else { return nil }
        if let exact = voices.first(where: { $0.id == saved }) { return .installed(exact) }
        if let named = voices.first(where: { $0.legacyNames.contains(saved) }) { return .installed(named) }
        if let parts = identifierParts(saved) {
            // Apple renames tiers (compact Karen is listed as super-compact);
            // the same name, accent and quality is the same voice.
            if let alias = voices.first(where: { $0.name == parts.name && $0.language == parts.language && $0.quality == parts.quality }) {
                return .installed(alias)
            }
            return .missing(parts.name)
        }
        let name = baseName(saved)
        let candidates = voices.filter { $0.name == saved || $0.name == name }
        guard !candidates.isEmpty else { return .missing(saved) }
        // A bare name exists in several accents: prefer the person's own, then
        // the quality `say` used for it.
        return .installed(candidates.sorted { lhs, rhs in
            (affinity(lhs, preferredLanguage), lhs.quality.rawValue, lhs.id) < (affinity(rhs, preferredLanguage), rhs.quality.rawValue, rhs.id)
        }[0])
    }

    /// For a fresh install: the best quality in the person's language, then
    /// their accent, then Apple's natural voices, then name.
    static func preferredDefault(in voices: [MacVoice], preferredLanguage: String) -> MacVoice? {
        let usable = voices.filter { !$0.isNovelty && !$0.sayOnly }
        let language = languageCode(preferredLanguage)
        let own = usable.filter { languageCode($0.language) == language }
        let english = usable.filter { languageCode($0.language) == "en" }
        let pool = !own.isEmpty ? own : !english.isEmpty ? english : usable
        return pool.min { lhs, rhs in
            (-lhs.quality.rawValue, affinity(lhs, preferredLanguage), family(lhs), lhs.name, lhs.id)
                < (-rhs.quality.rawValue, affinity(rhs, preferredLanguage), family(rhs), rhs.name, rhs.id)
        }
    }

    /// Shown until an Enhanced or Premium voice exists for the person's language.
    static func upgradeHint(for voices: [MacVoice], preferredLanguage: String) -> MacVoiceHint? {
        let language = languageCode(preferredLanguage)
        let best = voices.filter { !$0.isNovelty && !$0.sayOnly && languageCode($0.language) == language }.map(\.quality).max() ?? .compact
        guard best < .enhanced else { return nil }
        return MacVoiceHint(suggestion: freeUpgrades[normalized(preferredLanguage)])
    }

    /// "Australian" for en-AU; other languages use their localized name.
    static func accent(for language: String) -> String {
        let parts = normalized(language).split(separator: "-").map(String.init)
        let accents = ["AU": "Australian", "GB": "British", "US": "American", "IE": "Irish", "IN": "Indian",
                       "ZA": "South African", "NZ": "New Zealand", "CA": "Canadian", "SG": "Singaporean", "SCOTLAND": "Scottish"]
        if parts.first == "en", let region = parts.dropFirst().last, let accent = accents[region.uppercased()] { return accent }
        let name = Locale(identifier: "en").localizedString(forIdentifier: language.replacingOccurrences(of: "-", with: "_")) ?? language
        return name.replacingOccurrences(of: " (", with: ", ").replacingOccurrences(of: ")", with: "")
    }

    // MARK: Helpers

    static func languageCode(_ language: String) -> String {
        String(normalized(language).split(separator: "-").first ?? "").lowercased()
    }

    static func normalized(_ language: String) -> String {
        let parts = language.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let first = parts.first else { return language }
        return ([first.lowercased()] + parts.dropFirst().map { $0.count == 2 ? $0.uppercased() : $0 }).joined(separator: "-")
    }

    /// 0: the person's language and region; 1: their language; 2: other.
    private static func affinity(_ voice: MacVoice, _ preferredLanguage: String) -> Int {
        if normalized(voice.language) == normalized(preferredLanguage) { return 0 }
        return languageCode(voice.language) == languageCode(preferredLanguage) ? 1 : 2
    }

    /// Apple's natural voices, then Eloquence, then older system voices.
    private static func family(_ voice: MacVoice) -> Int {
        if voice.sayOnly { return 3 }
        if voice.id.hasPrefix("com.apple.voice.") || voice.id.hasPrefix("com.apple.ttsbundle.") { return 0 }
        return voice.id.hasPrefix("com.apple.eloquence.") ? 1 : 2
    }

    /// "Eddy (English (UK))" → "Eddy".
    private static func baseName(_ name: String) -> String {
        guard let open = name.firstIndex(of: "("), name.hasSuffix(")") else { return name }
        return name[..<open].trimmingCharacters(in: .whitespaces)
    }

    private static func identifierParts(_ identifier: String) -> (name: String, language: String, quality: MacVoice.Quality)? {
        guard identifier.hasPrefix("com."), !identifier.contains(" ") else { return nil }
        let parts = identifier.split(separator: ".").map(String.init)
        guard let name = parts.last, let language = parts.dropLast().last(where: {
            $0.range(of: #"^[a-z]{2,3}(-[A-Za-z0-9]+)+$"#, options: .regularExpression) != nil
        }) else { return nil }
        return (name, language, MacVoice.Quality(identifier: identifier))
    }
}

/// The Pace control keeps meaning words per minute as `say -r` did. These
/// anchors were measured on macOS 26.5.1 by rendering a 157-word synthetic
/// passage with Karen and Samantha through both engines: at each anchor the
/// utterance rate gives the same duration `say` gave (for example 180 wpm →
/// 0.50, 51.9 s; 240 → 0.55, 40.1 s; 300 → 0.60, 32.6 s). Both engines step in
/// the same increments, so 120 and 140, and 160 and 180, sounded alike before too.
enum MacVoicePace {
    static let anchors: [(wordsPerMinute: Double, rate: Float)] = [
        (100, 0.34), (120, 0.42), (140, 0.42), (160, 0.50), (180, 0.50), (200, 0.525),
        (220, 0.54), (240, 0.55), (260, 0.56), (280, 0.59), (300, 0.60)
    ]

    static func utteranceRate(forWordsPerMinute value: Double) -> Float {
        guard value.isFinite else { return AVSpeechUtteranceDefaultSpeechRate }
        guard let first = anchors.first, let last = anchors.last else { return AVSpeechUtteranceDefaultSpeechRate }
        if value <= first.wordsPerMinute { return first.rate }
        if value >= last.wordsPerMinute { return last.rate }
        for (lower, upper) in zip(anchors, anchors.dropFirst()) where value <= upper.wordsPerMinute {
            let fraction = Float((value - lower.wordsPerMinute) / (upper.wordsPerMinute - lower.wordsPerMinute))
            return lower.rate + (upper.rate - lower.rate) * fraction
        }
        return last.rate
    }
}
