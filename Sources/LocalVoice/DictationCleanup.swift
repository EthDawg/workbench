import Foundation
import NaturalLanguage

enum CleanupStyle: String, Codable, CaseIterable, Sendable {
    case original = "Original", light = "Light", natural = "Natural"
    var detail: String {
        switch self {
        case .original: return "Your words, with dictionary corrections only."
        case .light: return "Remove fillers, resolve explicit corrections, and format lists."
        case .natural: return "Light cleanup plus careful punctuation and formatting with your selected local text model."
        }
    }
    /// One short example beside the description (#134). CleanupChecks runs each one through the
    /// real cleanup: Original leaves the words as heard, Light gives exactly this result, and
    /// Natural's is one its meaning check accepts, which the text model may produce.
    var example: (heard: String, result: String) {
        switch self {
        case .original: return ("Um, meet at 3pm, no actually 4pm.", "Um, meet at 3pm, no actually 4pm.")
        case .light: return ("Um, meet at 3pm, no actually 4pm.", "Meet at 4pm.")
        case .natural: return ("book the room then send the notes", "Book the room, then send the notes.")
        }
    }
    /// The example in words, for the Dictate page.
    var exampleText: String {
        let (heard, result) = example
        switch self {
        case .original: return "For example, “\(heard)” stays as it was heard."
        case .light: return "For example, “\(heard)” becomes “\(result)”"
        case .natural: return "For example, “\(heard)” can become “\(result)”"
        }
    }
}
struct CleanupResult: Sendable {
    var text: String
    var method: String
}

enum DictationCleanup {
    static func replacing(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
    static func times(_ text: String) -> String {
        let normalized = replacing(text, #"(?<![\p{L}\p{N}:])((?:1[0-2]|0?[1-9])(?::[0-5]\d)?)[ \t]*([ap])[ \t]*\.?[ \t]*m\b"#, "$1$2m")
        return replacing(normalized, #"\b(\d{1,2}):00([ap]m)\b"#, "$1$2")
    }
    static func light(_ raw: String) -> String {
        var text = times(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        text = resolveAdjacentTimeCorrections(text)
        text = resolveExplicitCorrections(text)
        text = replacing(text, #"\b(?:u+m+|u+h+|e+rm+|hmm+)\b[,\s]*"#, "")
        text = replacing(text, #"^(?:okay|ok)[,\s]+(?:so[,\s]+)?(?:to\s+)?(?=hello\b|I\b|we\b|the\b)"#, "")
        text = replacing(text, #"\b(I|we|the|a|to|and)(?:,\s*|\s+)\1\b"#, "$1")
        text = replacing(text, #"\brock\s+melon\b"#, "rockmelon")
        text = replacing(text, #"[ \t]{2,}"#, " ")
        text = replacing(text, #"\s+([,.;!?])"#, "$1")
        if let starts = try? NSRegularExpression(pattern: #"(?:^|[.!?]\s+)([a-z])"#) {
            for match in starts.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                if let range = Range(match.range(at: 1), in: text) { text.replaceSubrange(range, with: text[range].uppercased()) }
            }
        }
        text = formatList(text)
        if let first = text.first { text = String(first).uppercased() + text.dropFirst() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func resolveAdjacentTimeCorrections(_ text: String) -> String {
        // Only two valid adjacent clock times with an explicit correction cue.
        // Do not infer a replacement across another clause or a paragraph. A
        // lookahead retains the corrected time and permits a chain of corrections.
        let time = #"(?<![\p{L}\p{N}:])(?:1[0-2]|0?[1-9])(?::[0-5]\d)?[ap]m\b"#
        let cue = #"(?:no[, \t]+)?(?:actually|sorry|make[ \t]+that|I[ \t]+mean)"#
        return replacing(text, time + #"[,;. \t]+"# + cue + #"[, \t]+(?="# + time + ")", "")
    }
    static func resolveExplicitCorrections(_ source: String) -> String {
        var text = source
        // Apply only when the rejected phrase actually occurs immediately before
        // the correction, in the current or preceding sentence. No guessed facts.
        let pattern = #"(?:[.!?]\s*|[,;]\s*|\s+)(?:(?:oh[,\s]+)?wait[,\s]+)?not\s+([^,;.!?\n]{1,60})[,;]\s*([^.!?\n]{1,60})[.!?]?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: text), let wrongRange = Range(match.range(at: 1), in: text), let rightRange = Range(match.range(at: 2), in: text) else { continue }
            let wrong = String(text[wrongRange]).trimmingCharacters(in: .whitespaces)
            let right = String(text[rightRange]).trimmingCharacters(in: .whitespaces)
            let prefix = String(text[..<whole.lowerBound])
            guard let old = prefix.range(of: wrong, options: [.backwards, .caseInsensitive]), prefix.distance(from: old.upperBound, to: prefix.endIndex) < 12,
                  !right.isEmpty, !right.lowercased().hasPrefix("but ") else { continue }
            let beforeOld = old.lowerBound == prefix.startIndex ? nil : prefix[prefix.index(before: old.lowerBound)]
            guard beforeOld == nil || !(beforeOld!.isLetter || beforeOld!.isNumber) else { continue }
            var revised = prefix; revised.replaceSubrange(old, with: right)
            let suffix = String(text[whole.upperBound...])
            text = revised + (suffix.first == "." ? "" : ".") + suffix
        }
        return text
    }
    static func formatList(_ text: String) -> String {
        guard let cue = text.range(of: #"\b(?:(?:grocery|shopping|packing|task|to-do)\s+)?list\b"#, options: [.regularExpression, .caseInsensitive]) else { return text }
        let after = String(text[cue.upperBound...])
        guard let start = after.range(of: #"^\s*(?::\s*(?:(?:I(?:'ll| will)?|we(?:'ll| will)?)\s+(?:need|want)\s+)?|[.,]?\s*(?:(?:I(?:'ll| will)?|we(?:'ll| will)?)\s+(?:need|want)|(?:the\s+)?items?\s+are|include|add)\s+)"#, options: [.regularExpression, .caseInsensitive]) else { return text }
        let remaining = String(after[start.upperBound...])
        guard !remaining.isEmpty else { return text }
        let tokenizer = NLTokenizer(unit: .sentence); tokenizer.string = remaining
        guard let sentenceRange = tokenizer.tokens(for: remaining.startIndex..<remaining.endIndex).first else { return text }
        let sentence = String(remaining[sentenceRange]).trimmingCharacters(in: CharacterSet(charactersIn: " .!?\n"))
        let separated = replacing(sentence, #",\s+and\s+"#, ", ")
        var parts: [String] = [], itemStart = separated.startIndex
        for index in separated.indices where separated[index] == "," {
            let before = index > separated.startIndex ? separated[separated.index(before: index)] : " "
            let next = separated.index(after: index)
            let after = next < separated.endIndex ? separated[next] : " "
            if before.isNumber && after.isNumber { continue }
            parts.append(String(separated[itemStart..<index])); itemStart = next
        }
        parts.append(String(separated[itemStart...]))
        let items = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard items.count >= 2, items.count <= 30, items.allSatisfy({ !$0.isEmpty && $0.count <= 100 }), sentence.contains(",") else { return text }
        let prefix = String(text[..<cue.upperBound]) + ":"
        let bullets = items.map { item in "• " + String(item.prefix(1)).uppercased() + item.dropFirst() }.joined(separator: "\n")
        let suffix = String(remaining[sentenceRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix + "\n" + bullets + (suffix.isEmpty ? "" : "\n\n" + suffix)
    }
    static func chunks(_ text: String, limit: Int = 1800) -> [String] {
        if text.count <= limit { return [text] }
        // Prefer sentence boundaries; very long sentences fall back to word boundaries.
        let tokenizer = NLTokenizer(unit: .sentence); tokenizer.string = text
        let sentences = tokenizer.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]) }
        var result: [String] = [], current = ""
        for sentence in sentences {
            if sentence.count > limit {
                if !current.isEmpty { result.append(current); current = "" }
                for word in sentence.split(whereSeparator: \.isWhitespace) {
                    if current.count + word.count + 1 > limit && !current.isEmpty { result.append(current); current = "" }
                    current += (current.isEmpty ? "" : " ") + word
                }
            } else if current.count + sentence.count > limit {
                result.append(current); current = sentence
            } else { current += (current.isEmpty ? "" : " ") + sentence }
        }
        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [text] : result
    }
    static func isFaithful(_ candidate: String, to source: String) -> Bool {
        guard !candidate.isEmpty, candidate.count <= source.count * 2 + 80 else { return false }
        func numbers(_ s: String) -> Set<String> {
            let normalized = times(s).lowercased()
            let regex = try! NSRegularExpression(pattern: #"\d+(?:[.:]\d+)*(?:[ap]m)?"#)
            return Set(regex.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)).compactMap { Range($0.range, in: normalized).map { String(normalized[$0]) } })
        }
        guard numbers(candidate) == numbers(source) else { return false }
        let negatives = ["not", "never", "don't", "doesn't", "can't", "won't", "isn't", "no"]
        func tokens(_ s: String) -> [String] {
            s.lowercased().replacingOccurrences(of: "’", with: "'").split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
        }
        let before = tokens(source), after = tokens(candidate)
        for word in negatives where before.filter({ $0 == word }).count != after.filter({ $0 == word }).count { return false }
        func bulletItems(_ text: String) -> [[String]] {
            text.components(separatedBy: .newlines).compactMap { line in
                let line = line.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("• ") || line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
                return tokens(String(line.dropFirst(2)))
            }
        }
        let originalItems = bulletItems(source)
        // Small models sometimes flatten a list without changing the word sequence.
        // Preserve each existing item on its own line as well as its factual tokens.
        if !originalItems.isEmpty && bulletItems(candidate) != originalItems { return false }
        let ignored: Set<String> = ["okay", "ok", "um", "uh", "erm", "hmm"]
        // Keep factual tokens in order. A bag-of-words check would accept swapped
        // names or times even though their meaning changed. Prefer light fallback.
        return before.filter { !ignored.contains($0) } == after.filter { !ignored.contains($0) }

    }
}
