import Foundation

/// Dictated words fit the insertion point (#14). A pure rule set over the text
/// either side of the caret or selection and the dictated words; nothing here
/// reads a field, logs its contents or touches the saved transcript.
///
/// The rules, in the order they apply:
///
/// 1. Secure fields are excluded; empty or whitespace-only dictation is returned as it is.
/// 2. Spaces and tabs at the dictated edges are dropped, so the field decides the spacing.
/// 3. Leading space when the previous character is a letter, digit, emoji or closing
///    punctuation (`. , ; : ! ? ) ] } %`, a closing quote, or a straight quote that an
///    earlier quote opened) and the dictated text does not start with closing
///    punctuation or a line break. None after whitespace, a line break, `( [ {` or an
///    opening quote. Never a double space.
/// 4. Trailing space when the next character is a letter, digit, emoji, `( [ {` or an
///    opening quote. None before whitespace, a line break or `, . ; : ! ? ) ] }`.
/// 5. Sentence start = start of field, after a line break, or after `. ! ?` (closing
///    quotes and brackets may follow) plus whitespace. There the first word is
///    capitalised only when it is all lowercase letters and ends at a space or clause
///    punctuation; `iPhone`, `github.com`, `e.g.` and code keep their spelling.
/// 6. Mid-sentence lowercasing applies only when the first token is a single
///    Title-case word (one capital, then lowercase letters, apostrophes or hyphens)
///    ending at a space or clause punctuation, is not `I` or a contraction of it, is not
///    a dictionary term and is not already written with that capital mid-sentence in
///    the field or later in the dictation. Names the recogniser capitalised at the
///    start of an utterance are indistinguishable from `The`, so the dictionary and the
///    field's own spelling are the evidence; everything else keeps the dictated spelling:
///    all-caps acronyms, numbers, URLs, code, `McDonald`, `O'Brien`.
/// 7. One final full stop is dropped when the sentence continues after it (the next
///    character, past spaces, is a lowercase letter or digit) or the field already ends
///    it there (`. , ; : ! ?`). A full stop before a line break or a capital stays.
///
/// Decisions are reported as values so checks can assert on them without the text.
enum InsertionBoundary {
    enum FieldKind: Equatable { case text, secure }
    struct Context: Equatable {
        var kind: FieldKind = .text
        /// The dictionary's written spellings: a first word matching one keeps its capital.
        var dictionaryTerms: [String] = []
    }
    enum KeepReason: Equatable {
        /// Punctuation, a digit, or a word that runs into symbols or digits: `"Hi"`, `5`, `github.com`, `e.g.`, `print(x)`.
        case notAPlainWord
        /// Capitals beyond the first, or none where one would be added: `NASA`, `McDonald`, `O'Brien`, `iPhone`.
        case notOneTitleCaseWord, pronounI, dictionaryTerm, capitalisedElsewhere
    }
    enum Decision: Equatable, CustomStringConvertible {
        case secureFieldExcluded, nothingToInsert, trimmedEdges
        case leadingSpace, trailingSpace
        case sentenceStart, capitalised, lowercased, kept(KeepReason), droppedFullStop
        var description: String {
            switch self {
            case .secureFieldExcluded: return "secure field, text unchanged"
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
        guard context.kind != .secure else { return Fit(prefix: "", body: dictated, suffix: "", decisions: [.secureFieldExcluded]) }
        var decisions: [Decision] = []
        let edges = CharacterSet(charactersIn: " \t")
        var body = dictated.trimmingCharacters(in: edges)
        guard !body.isEmpty, !body.allSatisfy(\.isWhitespace) else {
            return Fit(prefix: "", body: dictated, suffix: "", decisions: [.nothingToInsert])
        }
        if body != dictated { decisions.append(.trimmedEdges) }

        var prefix = ""
        if let previous = before.last, let first = body.first, !first.isNewline, !closing.contains(first),
           previous.isLetter || previous.isNumber || isEmoji(previous) || closesBefore(before) {
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
        while index > before.startIndex, ["\"", "'", "”", "’", ")", "]", "}", "»"].contains(before[before.index(before: index)]) {
            index = before.index(before: index)
        }
        guard index > before.startIndex else { return false }
        return terminal.contains(before[before.index(before: index)])
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
        return nil
    }
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
