import Foundation

/// Dictated words fit the insertion point (#14). A pure rule set over the text
/// either side of the caret or selection and the dictated words; nothing here
/// reads a field, logs its contents or touches the saved transcript.
///
/// The rules, in the order they apply:
///
/// 1. Secure fields never reach the rules: delivery reads no value for them, so the
///    field-based entry returns nil and the words go in as dictated. Empty or
///    whitespace-only dictation is returned as it is.
/// 2. Spaces and tabs at the dictated edges are dropped, so the field decides the spacing.
/// 3. Leading space when the previous character is a letter, digit, emoji or closing
///    punctuation (`. , ; : ! ? ) ] } %`, a closing quote, or a straight quote that an
///    earlier quote opened) and the dictated text does not start with closing
///    punctuation or a line break. None after whitespace, a line break, `( [ {` or an
///    opening quote. Never a double space.
/// 4. Trailing space when the next character is a letter, digit, emoji, `( [ {` or an
///    opening quote. None before whitespace, a line break or `, . ; : ! ? ) ] }`.
/// 5. Sentence start = start of field, after a line break (a line holding only list or
///    quote markers such as `- * + • > # [ ] 1. 1)` still counts), or after `. ! ?`
///    (closing quotes and brackets may follow) plus whitespace. A full stop that ends
///    a title or Latin abbreviation (`Dr. Mr. Mrs. Ms. Prof. St. Mt. vs. e.g. i.e. cf.
///    approx.`) does not end a sentence. There the first word is capitalised only when
///    it is all lowercase letters and ends at a space or clause punctuation; `iPhone`,
///    `github.com`, `e.g.` and code keep their spelling.
/// 6. Mid-sentence lowercasing applies only when the first token is a single
///    Title-case word (one capital, then lowercase letters, apostrophes or hyphens)
///    ending at a space or clause punctuation and its lowercase form is one of the
///    everyday words a recogniser capitalises at the start of an utterance (`the`, `a`,
///    `it`, `we`, `this`, `and`, `is`, `can't`, and so on: the closed list below). A name
///    the recogniser capitalised at the start of an utterance is indistinguishable from
///    a product name or a verb such as `Make`, so everything outside that list keeps the
///    dictated spelling: `Mark`, `Google Docs`, `Send`, all-caps acronyms, numbers, URLs,
///    code, `McDonald`, `O'Brien`, and a title abbreviation such as `Dr.`. `I` and its
///    contractions stay, a dictionary term keeps its capital even when it is in the list
///    (a dictionary entry `Will`), and so does a word already written with that capital
///    mid-sentence in the field or later in the dictation.
/// 7. One final full stop is dropped when the sentence continues after it (the next
///    character, past spaces, is a lowercase letter or digit) or the field already ends
///    it there (`. , ; : ! ?`). A full stop before a line break or a capital stays, and
///    so does one that belongs to an abbreviation (`Dr.`, `etc.`).
///
/// Decisions are reported as values so checks can assert on them without the text.
enum InsertionBoundary {
    struct Context: Equatable {
        /// The dictionary's written spellings: a first word matching one keeps its capital.
        var dictionaryTerms: [String] = []
    }
    enum KeepReason: Equatable {
        /// Punctuation, a digit, or a word that runs into symbols or digits: `"Hi"`, `5`, `github.com`, `e.g.`, `print(x)`.
        case notAPlainWord
        /// Capitals beyond the first, or none where one would be added: `NASA`, `McDonald`, `O'Brien`, `iPhone`.
        case notOneTitleCaseWord, pronounI, dictionaryTerm, capitalisedElsewhere
        /// A title or Latin abbreviation with its full stop: `Dr.`, `e.g.`.
        case abbreviation
        /// Not in the closed list of everyday words a recogniser capitalises at an
        /// utterance start, so it is read as a name or a dictated capital: `Mark`, `Google`, `Send`.
        case notAnEverydayWord
    }
    enum Decision: Equatable, CustomStringConvertible {
        case nothingToInsert, trimmedEdges
        case leadingSpace, trailingSpace
        case sentenceStart, capitalised, lowercased, kept(KeepReason), droppedFullStop
        var description: String {
            switch self {
            case .nothingToInsert: return "nothing to insert"
            case .trimmedEdges: return "edge spaces dropped"
            case .leadingSpace: return "space before"
            case .trailingSpace: return "space after"
            case .sentenceStart: return "sentence start"
            case .capitalised: return "first word capitalised"
            case .lowercased: return "first word lowercased"
            case .kept(let reason): return "spelling kept (\(reason))"
            case .droppedFullStop: return "final full stop dropped"
            }
        }
    }
    struct Fit: Equatable {
        var prefix: String
        var body: String
        var suffix: String
        var decisions: [Decision]
        var text: String { prefix + body + suffix }
    }

    /// `before` and `after` are the field's text either side of the caret, or
    /// around the selection being replaced.
    static func fit(before: String, after: String, dictated: String, context: Context = .init()) -> Fit {
        var decisions: [Decision] = []
        let edges = CharacterSet(charactersIn: " \t")
        var body = dictated.trimmingCharacters(in: edges)
        guard !body.isEmpty, !body.allSatisfy(\.isWhitespace) else {
            return Fit(prefix: "", body: dictated, suffix: "", decisions: [.nothingToInsert])
        }
        if body != dictated { decisions.append(.trimmedEdges) }

        var prefix = ""
        if let previous = before.last, let first = body.first, !first.isNewline, !closing.contains(first),
           previous.isLetter || previous.isNumber || isEmoji(previous) || closesBefore(before)
           || !previous.isWhitespace && isMarkerLine(before) {
            prefix = " "; decisions.append(.leadingSpace)
        }

        let sentenceStart = isSentenceStart(before)
        if sentenceStart { decisions.append(.sentenceStart) }
        if let token = firstToken(of: body) {
            let first = token.word.first!
            if sentenceStart {
                if first.isLowercase, token.word.allSatisfy({ $0.isLowercase || $0 == "'" || $0 == "’" || $0 == "-" }) {
                    body = first.uppercased() + body.dropFirst(); decisions.append(.capitalised)
                } else if first.isLowercase { decisions.append(.kept(.notOneTitleCaseWord)) }
            } else if body[token.range.upperBound...].first == ".", isAbbreviation(token.word) {
                decisions.append(.kept(.abbreviation))
            } else if let reason = keepReason(token.word, context: context, before: before, after: after, rest: body[token.range.upperBound...]) {
                decisions.append(.kept(reason))
            } else if first.isUppercase {
                body = first.lowercased() + body.dropFirst(); decisions.append(.lowercased)
            }
        } else if body.first?.isLetter == true || !sentenceStart {
            decisions.append(.kept(.notAPlainWord))
        }

        var suffix = ""
        if let next = after.first, let last = body.last, !last.isWhitespace,
           next.isLetter || next.isNumber || isEmoji(next) || opensAfter(after) {
            suffix = " "; decisions.append(.trailingSpace)
        }
        if body.hasSuffix("."), !body.hasSuffix(".."), body.dropLast().last.map({ $0.isLetter || $0.isNumber }) == true,
           !isAbbreviation(wordEnding(body.dropLast()), dictated: true),
           let continues = after.drop(while: { $0 == " " || $0 == "\t" }).first,
           continues.isLowercase || continues.isNumber || ".,;:!?".contains(continues) {
            body.removeLast(); decisions.append(.droppedFullStop)
        }
        return Fit(prefix: prefix, body: body, suffix: suffix, decisions: decisions)
    }

    /// The field's value split at its caret or selection. Nil when the field could not
    /// be read or its range does not fit the value: the words then go in unchanged.
    static func fit(dictated: String, value: String?, selection: NSRange?, context: Context = .init()) -> Fit? {
        guard let value, let selection, selection.location >= 0, selection.length >= 0,
              let range = Range(selection, in: value), !splitsSurrogate(value, at: selection.location),
              !splitsSurrogate(value, at: selection.location + selection.length) else { return nil }
        return fit(before: String(value[..<range.lowerBound]), after: String(value[range.upperBound...]),
                   dictated: dictated, context: context)
    }

    private static func splitsSurrogate(_ value: String, at offset: Int) -> Bool {
        let units = value as NSString
        return offset > 0 && offset < units.length && (0xD800...0xDBFF).contains(units.character(at: offset - 1))
            && (0xDC00...0xDFFF).contains(units.character(at: offset))
    }

    // MARK: Boundary characters

    private static let closing: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "”", "’", "»", "…", "%"]
    private static let opening: Set<Character> = ["(", "[", "{", "“", "‘", "«"]
    private static let terminal: Set<Character> = [".", "!", "?"]

    private static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.first?.properties.isEmojiPresentation == true
    }
    /// A straight quote is closing when the text before it has already opened one.
    private static func closesBefore(_ before: String) -> Bool {
        guard let previous = before.last else { return false }
        if closing.contains(previous) { return true }
        if previous == "\"" { return before.filter({ $0 == "\"" }).count % 2 == 0 }
        if previous == "'" {
            let earlier = before.dropLast().last
            return earlier?.isLetter == true || earlier?.isNumber == true
        }
        return false
    }
    /// A straight quote is opening when another quote later closes it.
    private static func opensAfter(_ after: String) -> Bool {
        guard let next = after.first else { return false }
        if opening.contains(next) { return true }
        if next == "\"" { return after.filter({ $0 == "\"" }).count % 2 == 0 }
        return false
    }
    static func isSentenceStart<Text: StringProtocol>(_ before: Text) -> Bool {
        var index = before.endIndex
        while index > before.startIndex {
            let character = before[before.index(before: index)]
            if character.isNewline { return true }
            guard character.isWhitespace else { break }
            index = before.index(before: index)
        }
        guard index > before.startIndex else { return true }
        if isMarkerLine(before[..<index]) { return true }
        while index > before.startIndex, ["\"", "'", "”", "’", ")", "]", "}", "»"].contains(before[before.index(before: index)]) {
            index = before.index(before: index)
        }
        guard index > before.startIndex else { return false }
        let last = before[before.index(before: index)]
        guard terminal.contains(last) else { return false }
        return last != "." || !isAbbreviation(wordEnding(before[..<before.index(before: index)]))
    }

    // MARK: Markers and abbreviations

    private static let markers: Set<String> = ["-", "*", "+", "•", "·", "–", "—", ">", "[]", "[x]", "[X]", "□", "☐", "☑", "✓", "✔"]
    /// The current line holds only list or quote markers, each a separate token: the
    /// caret is at the start of the item. Lines longer than a few markers never qualify,
    /// so a long single-line field is not rescanned.
    static func isMarkerLine<Text: StringProtocol>(_ before: Text) -> Bool {
        var start = before.endIndex, length = 0
        while start > before.startIndex, !before[before.index(before: start)].isNewline {
            start = before.index(before: start); length += 1
            if length > 16 { return false }
        }
        let line = before[start...].replacingOccurrences(of: "[ ]", with: "[]")
        let tokens = line.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { token in
            if markers.contains(String(token)) { return true }
            if token.count <= 6, token.allSatisfy({ $0 == "#" }) { return true }
            guard let last = token.last, last == "." || last == ")", token.count <= 4 else { return false }
            return token.dropLast().allSatisfy(\.isNumber)
        }
    }
    private static let abbreviations: Set<String> = ["dr", "mr", "mrs", "ms", "prof", "st", "mt", "vs", "e.g", "i.e", "cf", "approx"]
    /// Titles and Latin abbreviations that rarely end a sentence. `etc.` often does,
    /// so it only protects its own dictated full stop.
    private static func isAbbreviation<Text: StringProtocol>(_ word: Text, dictated: Bool = false) -> Bool {
        let lowered = word.lowercased()
        return abbreviations.contains(lowered) || dictated && lowered == "etc"
    }
    /// The run of letters and inner full stops that ends `text`: `e.g` in `see e.g`.
    private static func wordEnding<Text: StringProtocol>(_ text: Text) -> Text.SubSequence {
        var start = text.endIndex, length = 0
        while start > text.startIndex, length < 8 {
            let character = text[text.index(before: start)]
            guard character.isLetter || character == "." && start < text.endIndex else { break }
            start = text.index(before: start); length += 1
        }
        return text[start...]
    }

    // MARK: First word

    private struct Token { var word: Substring; var range: Range<String.Index> }

    /// The run of letters, apostrophes and inner hyphens at the very start, when it
    /// ends at a space, the end, or clause punctuation followed by a space or the end.
    private static func firstToken(of text: String) -> Token? {
        var end = text.startIndex
        while end < text.endIndex {
            let character = text[end]
            if character.isLetter || character == "'" || character == "’" { end = text.index(after: end); continue }
            if character == "-", end > text.startIndex, text.index(after: end) < text.endIndex, text[text.index(after: end)].isLetter {
                end = text.index(after: end); continue
            }
            break
        }
        guard end > text.startIndex else { return nil }
        if end < text.endIndex {
            let following = text[end]
            let afterFollowing = text.index(after: end) < text.endIndex ? text[text.index(after: end)] : nil
            guard following.isWhitespace || (closing.contains(following) && (afterFollowing?.isWhitespace ?? true))
                || ["\"", "”", "’"].contains(following) else { return nil }
        }
        return Token(word: text[text.startIndex..<end], range: text.startIndex..<end)
    }
    private static func keepReason(_ word: Substring, context: Context, before: String, after: String, rest: Substring) -> KeepReason? {
        guard let first = word.first, first.isUppercase else { return nil }
        guard word.dropFirst().allSatisfy({ $0.isLowercase || $0 == "'" || $0 == "’" || $0 == "-" }) else { return .notOneTitleCaseWord }
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return .pronounI }
        let text = String(word)
        if context.dictionaryTerms.contains(where: { term in
            let term = term.trimmingCharacters(in: .whitespaces)
            return term == text || (term.hasPrefix(text) && (text + rest).hasPrefix(term)
                                    && term.dropFirst(text.count).first?.isLetter == false)
        }) { return .dictionaryTerm }
        if [before, after, String(rest)].contains(where: { capitalisedMidSentence(text, in: $0) }) { return .capitalisedElsewhere }
        guard everydayWords.contains(text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")) else { return .notAnEverydayWord }
        return nil
    }
    /// The everyday words a recogniser capitalises at the start of an utterance: articles,
    /// pronouns and their contractions, conjunctions, prepositions, determiners, auxiliaries
    /// and modals, common adverbs and discourse words. Mid-sentence these are lowercased;
    /// any other Title-case first word is taken to be a name and kept. `I` has its own rule.
    static let everydayWords: Set<String> = [
        "the", "a", "an", "and", "but", "or", "so", "nor", "yet",
        "it", "it's", "its", "this", "that", "these", "those", "there", "there's", "here",
        "we", "we're", "we'll", "you", "you're", "you'll", "they", "they're", "he", "she",
        "is", "are", "was", "were", "be", "been", "being", "am",
        "can", "can't", "could", "would", "should", "will", "won't",
        "do", "don't", "does", "doesn't", "did", "didn't", "have", "haven't", "has", "hasn't", "had", "not",
        "to", "for", "of", "in", "on", "at", "with", "from", "by", "about", "as",
        "if", "when", "where", "while", "then", "than", "also", "just", "please", "okay", "ok", "yes", "no",
        "now", "again", "still", "very", "really", "maybe",
        "some", "any", "all", "each", "every", "more", "most", "much", "many",
        "my", "your", "our", "their", "his", "her", "me", "him", "them", "us",
        "who", "what", "which", "how", "why", "because",
        "into", "onto", "over", "under", "up", "down", "out", "off", "let's",
    ]
    /// The same Title-case word used as a whole word somewhere that is not a sentence start.
    private static func capitalisedMidSentence(_ word: String, in text: String) -> Bool {
        var search = text.startIndex
        while search < text.endIndex, let found = text.range(of: word, range: search..<text.endIndex) {
            search = text.index(after: found.lowerBound)
            let preceded = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : nil
            let followed = found.upperBound < text.endIndex ? text[found.upperBound] : nil
            guard preceded.map({ !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }) ?? true,
                  followed.map({ !$0.isLetter && !$0.isNumber }) ?? true,
                  !isSentenceStart(text[..<found.lowerBound]) else { continue }
            return true
        }
        return false
    }
}
