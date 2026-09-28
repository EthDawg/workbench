import Foundation

/// Prepares Markdown and agent output for listening. Only the spoken copy
/// changes: the Read page keeps showing the original, and every spoken range maps
/// back to the original characters it came from, so word highlighting follows
/// the displayed text.
///
/// Text read as written keeps an exact word map. A replaced element (a code
/// block, a link address or a shortened path) maps to its whole original span,
/// so its highlight covers that element while the short spoken form plays.
/// Nothing is dropped silently: omitted code and addresses are announced, and
/// numbers, names and identifiers are spoken exactly as written.
struct ListeningText: Equatable {
    /// Part of the audio signature: changing these rules renders audio again.
    static let version = 1
    static let codeBlockPlaceholder = "Code block skipped."

    struct Segment: Equatable {
        /// UTF-16 range in `spoken`.
        let spoken: NSRange
        /// UTF-16 range in `original`. Zero length for inserted punctuation.
        let original: NSRange
        /// The spoken characters are the original characters, one for one.
        let exact: Bool
    }

    let original: String
    let spoken: String
    let segments: [Segment]

    init(_ original: String) {
        self.original = original
        var builder = Builder(source: original as NSString)
        builder.build()
        spoken = builder.output
        segments = builder.segments
    }

    /// The displayed characters behind a spoken range, or nil when the range is
    /// only inserted punctuation.
    func originalRange(forSpoken range: NSRange) -> NSRange? {
        guard range.location != NSNotFound, range.length >= 0 else { return nil }
        let end = range.location + max(range.length, 1)
        var lower = Int.max, upper = Int.min
        var index = firstSegment(endingAfter: range.location)
        while index < segments.count, segments[index].spoken.location < end {
            let segment = segments[index]
            index += 1
            guard segment.original.length > 0 else { continue }
            if segment.exact {
                let start = max(range.location, segment.spoken.location)
                let stop = min(range.location + range.length, segment.spoken.location + segment.spoken.length)
                guard stop > start else { continue }
                lower = min(lower, segment.original.location + start - segment.spoken.location)
                upper = max(upper, segment.original.location + stop - segment.spoken.location)
            } else {
                lower = min(lower, segment.original.location)
                upper = max(upper, segment.original.location + segment.original.length)
            }
        }
        return lower < upper ? NSRange(location: lower, length: upper - lower) : nil
    }

    private func firstSegment(endingAfter location: Int) -> Int {
        var low = 0, high = segments.count
        while low < high {
            let middle = (low + high) / 2
            let segment = segments[middle].spoken
            if segment.location + segment.length <= location { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

private struct Builder {
    let source: NSString
    var output = ""
    var outputLength = 0
    var segments: [ListeningText.Segment] = []
    /// The last few spoken characters that are not whitespace, for sentence endings.
    var recent: [unichar] = []

    init(source: NSString) { self.source = source }

    // MARK: Output

    mutating func copy(_ range: NSRange) {
        guard range.length > 0 else { return }
        let text = source.substring(with: range)
        if let last = segments.last, last.exact,
           last.original.location + last.original.length == range.location,
           last.spoken.location + last.spoken.length == outputLength {
            segments[segments.count - 1] = .init(spoken: NSRange(location: last.spoken.location, length: last.spoken.length + range.length),
                                                 original: NSRange(location: last.original.location, length: last.original.length + range.length),
                                                 exact: true)
        } else {
            segments.append(.init(spoken: NSRange(location: outputLength, length: range.length), original: range, exact: true))
        }
        append(text)
    }

    /// Speaks `text` in place of `range`; an empty range inserts it at that location.
    mutating func replace(_ range: NSRange, with text: String) {
        let length = (text as NSString).length
        guard length > 0 else { return }
        segments.append(.init(spoken: NSRange(location: outputLength, length: length), original: range, exact: false))
        append(text)
    }

    private mutating func append(_ text: String) {
        output += text
        let utf16 = text.utf16
        outputLength += utf16.count
        for character in utf16 where !Self.isSpace(character) && !Self.isNewline(character) {
            recent.append(character)
            if recent.count > 8 { recent.removeFirst(recent.count - 8) }
        }
    }

    /// Ends a heading, list item or table row as a sentence so the voice pauses.
    mutating func endSentence(at location: Int) {
        guard !recent.isEmpty else { return }
        // A closing quote or bracket can follow the punctuation: "Done." counts.
        if let last = recent.reversed().first(where: { !Self.closers.contains($0) }), Self.sentenceEnds.contains(last) { return }
        replace(NSRange(location: location, length: 0), with: ".")
    }

    // MARK: Lines

    mutating func build() {
        var lines: [(content: NSRange, terminator: NSRange)] = []
        var location = 0
        while location < source.length {
            var start = 0, end = 0, contentsEnd = 0
            source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            lines.append((NSRange(location: start, length: contentsEnd - start), NSRange(location: contentsEnd, length: end - contentsEnd)))
            location = end
        }
        let delimiterRows = lines.map { isTableDelimiter($0.content) }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let fence = fenceOpening(line.content) {
                var close = index + 1
                while close < lines.count, !isFenceClose(lines[close].content, fence: fence) { close += 1 }
                let last = min(close, lines.count - 1)
                let end = lines[last].content.location + lines[last].content.length
                let block = NSRange(location: line.content.location, length: end - line.content.location)
                recent = []
                replace(block, with: ListeningText.codeBlockPlaceholder)
                copy(lines[last].terminator)
                index = last + 1
                continue
            }
            let tableRow = !delimiterRows[index] && isTableRow(line.content,
                nextToDelimiter: (index > 0 && delimiterRows[index - 1]) || (index + 1 < lines.count && delimiterRows[index + 1]))
            if delimiterRows[index] || isRule(line.content) {
                // Formatting only: nothing to say.
            } else if tableRow {
                speakTableRow(line.content)
            } else {
                speakLine(line.content)
            }
            copy(line.terminator)
            index += 1
        }
    }

    private mutating func speakLine(_ content: NSRange) {
        var content = content
        // Quote markers are formatting; their contents read as ordinary lines.
        while let quote = firstMatch(Self.quote, in: content) {
            content = NSRange(location: quote.range.location + quote.range.length,
                              length: content.location + content.length - quote.range.location - quote.range.length)
        }
        recent = []
        if let heading = firstMatch(Self.heading, in: content) {
            var body = heading.range(at: 2)
            if body.location != NSNotFound, let closing = firstMatch(Self.closingHashes, in: body) {
                body.length = closing.range.location - body.location
            }
            guard body.location != NSNotFound, body.length > 0 else { return }
            speakInline(body)
            endSentence(at: body.location + body.length)
        } else if let bullet = firstMatch(Self.bullet, in: content) {
            let body = remainder(of: content, after: bullet.range)
            speakInline(body)
            endSentence(at: body.location + body.length)
        } else if let numbered = firstMatch(Self.numbered, in: content) {
            let marker = numbered.range(at: 1).location
            copy(NSRange(location: marker, length: numbered.range.location + numbered.range.length - marker))
            let body = remainder(of: content, after: numbered.range)
            speakInline(body)
            endSentence(at: body.location + body.length)
        } else {
            speakInline(content)
        }
    }

    private mutating func speakTableRow(_ content: NSRange) {
        recent = []
        var cells: [NSRange] = []
        var cellStart = content.location
        var position = content.location
        let end = content.location + content.length
        while position < end {
            let character = source.character(at: position)
            if character == Self.backslash { position += 2; continue }
            if character == Self.pipe {
                cells.append(NSRange(location: cellStart, length: position - cellStart))
                cellStart = position + 1
            }
            position += 1
        }
        cells.append(NSRange(location: cellStart, length: max(0, end - cellStart)))
        var spokeCell = false
        for cell in cells {
            let trimmed = trim(cell)
            guard trimmed.length > 0 else { continue }
            if spokeCell { replace(NSRange(location: trimmed.location, length: 0), with: ", ") }
            speakInline(trimmed)
            spokeCell = true
        }
        if spokeCell { endSentence(at: end) }
    }

    // MARK: Inline

    private enum Token {
        case code(NSRange, content: NSRange)
        case image(NSRange, alt: NSRange)
        case link(NSRange, text: NSRange)
        case address(NSRange, url: NSRange)
        case path(NSRange)
        var range: NSRange {
            switch self {
            case .code(let range, _), .image(let range, _), .link(let range, _), .address(let range, _), .path(let range): return range
            }
        }
    }

    private mutating func speakInline(_ content: NSRange) {
        guard content.length > 0 else { return }
        let tokens = inlineTokens(in: content)
        // Emphasis may wrap a link or code span, so pair delimiters across the
        // whole line while treating tokens as ordinary characters.
        var textRegions: [NSRange] = []
        var cursor = content.location
        for token in tokens {
            textRegions.append(NSRange(location: cursor, length: token.range.location - cursor))
            if case .link(_, let text) = token { textRegions.append(text) }
            if case .image(_, let alt) = token { textRegions.append(alt) }
            cursor = token.range.location + token.range.length
        }
        textRegions.append(NSRange(location: cursor, length: content.location + content.length - cursor))
        let silent = emphasisDelimiters(in: textRegions, line: content)

        cursor = content.location
        for token in tokens {
            speakText(NSRange(location: cursor, length: token.range.location - cursor), silent: silent)
            switch token {
            case .code(let range, let inner):
                if let spokenPath = spokenPath(inner) { replace(range, with: spokenPath) }
                else if isAddress(inner), let spokenAddress = spokenAddress(inner) { replace(range, with: spokenAddress) }
                else { copy(inner) }
            case .image(let range, let alt):
                let trimmedAlt = trim(alt)
                if trimmedAlt.length > 0 {
                    replace(NSRange(location: range.location, length: alt.location - range.location), with: "image, ")
                    speakText(alt, silent: silent)
                } else {
                    replace(range, with: "image")
                }
            case .link(let range, let text):
                if isAddress(trim(text)), let spokenAddress = spokenAddress(trim(text)) { replace(range, with: spokenAddress) }
                else { speakText(text, silent: silent) }
            case .address(let range, let url):
                replace(range, with: spokenAddress(url) ?? "link")
            case .path(let range):
                replace(range, with: spokenPath(range) ?? source.substring(with: range))
            }
            cursor = token.range.location + token.range.length
        }
        speakText(NSRange(location: cursor, length: content.location + content.length - cursor), silent: silent)
    }

    /// Copies ordinary text, leaving out paired emphasis markers. Escapes stay:
    /// voices do not speak them, and keeping them makes the rules idempotent.
    private mutating func speakText(_ range: NSRange, silent: Set<Int>) {
        guard range.length > 0 else { return }
        var runStart = range.location
        let end = range.location + range.length
        for position in range.location..<end where silent.contains(position) {
            copy(NSRange(location: runStart, length: position - runStart))
            runStart = position + 1
        }
        copy(NSRange(location: runStart, length: end - runStart))
    }

    private func inlineTokens(in content: NSRange) -> [Token] {
        var tokens: [Token] = codeSpans(in: content)
        func free(_ range: NSRange) -> Bool {
            !tokens.contains { NSIntersectionRange($0.range, range).length > 0 }
        }
        for match in matches(Self.image, in: content) where free(match.range) {
            tokens.append(.image(match.range, alt: match.range(at: 1)))
        }
        for match in matches(Self.link, in: content) where free(match.range) {
            tokens.append(.link(match.range, text: match.range(at: 1)))
        }
        for match in matches(Self.autolink, in: content) where free(match.range) {
            tokens.append(.address(match.range, url: match.range(at: 1)))
        }
        for match in matches(Self.bareAddress, in: content) {
            let trimmed = trimAddress(match.range)
            if trimmed.length > 0, free(trimmed) { tokens.append(.address(trimmed, url: trimmed)) }
        }
        for match in matches(Self.pathCandidate, in: content) {
            let trimmed = trimTrailing(match.range, characters: ".,;:!?")
            if free(trimmed), spokenPath(trimmed) != nil { tokens.append(.path(trimmed)) }
        }
        return tokens.sorted { $0.range.location < $1.range.location }
    }

    /// CommonMark code spans: a backtick run closed by a run of the same length.
    private func codeSpans(in content: NSRange) -> [Token] {
        var spans: [Token] = []
        var position = content.location
        let end = content.location + content.length
        func runLength(at index: Int) -> Int {
            var length = 0
            while index + length < end, source.character(at: index + length) == Self.backtick { length += 1 }
            return length
        }
        while position < end {
            let character = source.character(at: position)
            if character == Self.backslash { position += 2; continue }
            guard character == Self.backtick else { position += 1; continue }
            let opening = runLength(at: position)
            var search = position + opening
            var closed = false
            while search < end {
                if source.character(at: search) == Self.backtick {
                    let closing = runLength(at: search)
                    if closing == opening {
                        var inner = NSRange(location: position + opening, length: search - position - opening)
                        if inner.length >= 2, source.character(at: inner.location) == Self.space,
                           source.character(at: inner.location + inner.length - 1) == Self.space,
                           trim(inner).length > 0 {
                            inner = NSRange(location: inner.location + 1, length: inner.length - 2)
                        }
                        if inner.length > 0 {
                            spans.append(.code(NSRange(location: position, length: search + closing - position), content: inner))
                        }
                        position = search + closing
                        closed = true
                        break
                    }
                    search += closing
                } else {
                    search += 1
                }
            }
            if !closed { position += opening }
        }
        return spans
    }

    /// Positions of emphasis delimiters that pair up (`*`, `_`, `**`, `__`, `***`).
    /// Unpaired stars and underscores, such as `5 * 3` or `snake_case`, stay.
    private func emphasisDelimiters(in regions: [NSRange], line: NSRange) -> Set<Int> {
        struct Run { let location: Int; let length: Int; let character: unichar; let opens: Bool; let closes: Bool }
        var runs: [Run] = []
        let lineEnd = line.location + line.length
        for region in regions where region.length > 0 {
            var position = region.location
            let end = region.location + region.length
            while position < end {
                let character = source.character(at: position)
                if character == Self.backslash { position += 2; continue }
                guard character == Self.star || character == Self.underscore else { position += 1; continue }
                var length = 1
                while position + length < end, source.character(at: position + length) == character { length += 1 }
                let before: unichar? = position > line.location ? source.character(at: position - 1) : nil
                let after: unichar? = position + length < lineEnd ? source.character(at: position + length) : nil
                let leftFlanking = after.map { !Self.isSpace($0) } ?? false
                let rightFlanking = before.map { !Self.isSpace($0) } ?? false
                // Unlike CommonMark, intraword runs never pair, so 2*3*4 and
                // snake_case_names are spoken exactly as written.
                let opens = leftFlanking && !(before.map(Self.isWordCharacter) ?? false)
                let closes = rightFlanking && !(after.map(Self.isWordCharacter) ?? false)
                if length <= 3 { runs.append(Run(location: position, length: length, character: character, opens: opens, closes: closes)) }
                position += length
            }
        }
        var silent: Set<Int> = []
        var openers: [Run] = []
        for run in runs {
            if run.closes, let index = openers.lastIndex(where: { $0.character == run.character && $0.length == run.length }) {
                let opener = openers[index]
                for offset in 0..<run.length {
                    silent.insert(opener.location + offset)
                    silent.insert(run.location + offset)
                }
                openers.removeSubrange(index...)
            } else if run.opens {
                openers.append(run)
            }
        }
        return silent
    }

    // MARK: Addresses and paths

    private func isAddress(_ range: NSRange) -> Bool {
        firstMatch(Self.wholeAddress, in: range) != nil
    }

    /// "link to example.com": the address itself is replaced, and announced.
    private func spokenAddress(_ range: NSRange) -> String? {
        guard let host = URLComponents(string: source.substring(with: range))?.host, !host.isEmpty else { return nil }
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return "link to " + name
    }

    /// "file Core.swift" for `Sources/LocalVoice/Core.swift`; nil when the text
    /// is not clearly a path (and/or, 24/7, TCP/IP, dates and fractions).
    private func spokenPath(_ range: NSRange) -> String? {
        let text = source.substring(with: range)
        guard text.contains("/"), !text.contains("://"), !text.contains(where: { $0.isWhitespace }) else { return nil }
        let components = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let name = components.last, !components.isEmpty,
              !components.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        let anchored = text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("./") || text.hasPrefix("../")
        let slashes = text.filter { $0 == "/" }.count
        let folder = text.hasSuffix("/")
        let hasExtension = name.range(of: #"^[^.].*\.[A-Za-z0-9]{1,8}$"#, options: .regularExpression) != nil
        let hasLowercaseOrDot = components.contains { $0.contains(where: { $0.isLowercase || $0 == "." }) }
        let isPath = (anchored && components.count >= 1 && !(text == "~/" || text == "./" || text == "../"))
            || (slashes >= 2 && hasLowercaseOrDot)
            || (slashes == 1 && components.count == 2 && hasExtension)
        guard isPath else { return nil }
        if folder { return "folder " + name }
        return (hasExtension ? "file " : "path ") + name
    }

    private func trimAddress(_ range: NSRange) -> NSRange {
        var range = trimTrailing(range, characters: ".,;:!?'\"")
        let text = source.substring(with: range)
        if text.hasSuffix(")"), text.filter({ $0 == ")" }).count > text.filter({ $0 == "(" }).count {
            range.length -= 1
            range = trimTrailing(range, characters: ".,;:!?'\"")
        }
        return range
    }

    // MARK: Line classes

    private struct Fence { let character: unichar; let length: Int }

    private func fenceOpening(_ content: NSRange) -> Fence? {
        guard let match = firstMatch(Self.fence, in: content) else { return nil }
        let marker = match.range(at: 1)
        let character = source.character(at: marker.location)
        if character == Self.backtick, source.substring(with: match.range(at: 2)).contains("`") { return nil }
        return Fence(character: character, length: marker.length)
    }

    private func isFenceClose(_ content: NSRange, fence: Fence) -> Bool {
        let trimmed = trim(content)
        guard trimmed.length >= fence.length else { return false }
        for offset in 0..<trimmed.length where source.character(at: trimmed.location + offset) != fence.character { return false }
        return true
    }

    private func isRule(_ content: NSRange) -> Bool {
        firstMatch(Self.rule, in: content) != nil || firstMatch(Self.setextUnderline, in: content) != nil
    }

    private func isTableDelimiter(_ content: NSRange) -> Bool {
        let text = source.substring(with: content)
        guard text.contains("|"), text.filter({ $0 == "-" }).count >= 3 else { return false }
        return text.allSatisfy { "|-: \t".contains($0) }
    }

    private func isTableRow(_ content: NSRange, nextToDelimiter: Bool) -> Bool {
        let text = source.substring(with: trim(content))
        guard text.contains("|") else { return false }
        return nextToDelimiter || (text.hasPrefix("|") && text.hasSuffix("|") && text.count > 1)
    }

    // MARK: Helpers

    private func matches(_ expression: NSRegularExpression, in range: NSRange) -> [NSTextCheckingResult] {
        expression.matches(in: source as String, range: range)
    }

    private func firstMatch(_ expression: NSRegularExpression, in range: NSRange) -> NSTextCheckingResult? {
        expression.firstMatch(in: source as String, range: range)
    }

    private func remainder(of content: NSRange, after match: NSRange) -> NSRange {
        let start = match.location + match.length
        return NSRange(location: start, length: content.location + content.length - start)
    }

    private func trim(_ range: NSRange) -> NSRange {
        var start = range.location, end = range.location + range.length
        while start < end, Self.isSpace(source.character(at: start)) { start += 1 }
        while end > start, Self.isSpace(source.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private func trimTrailing(_ range: NSRange, characters: String) -> NSRange {
        let set = Set(characters.utf16)
        var end = range.location + range.length
        while end > range.location, set.contains(source.character(at: end - 1)) { end -= 1 }
        return NSRange(location: range.location, length: end - range.location)
    }

    private static func isSpace(_ character: unichar) -> Bool { character == 0x20 || character == 0x09 }
    private static func isNewline(_ character: unichar) -> Bool { [0x0A, 0x0D, 0x2028, 0x2029].contains(character) }
    private static func isWordCharacter(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return true }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private static let space: unichar = 0x20, backslash: unichar = 0x5C, backtick: unichar = 0x60
    private static let star: unichar = 0x2A, underscore: unichar = 0x5F, pipe: unichar = 0x7C
    private static let sentenceEnds = Set(".!?:;…".utf16)
    private static let closers = Set("\"'”’)]}".utf16)

    private static func pattern(_ text: String) -> NSRegularExpression {
        // Patterns are constants; a mistake fails the focused checks at once.
        try! NSRegularExpression(pattern: text, options: [.anchorsMatchLines])
    }
    private static let fence = pattern(#"^[ \t]*(`{3,}|~{3,})(.*)$"#)
    private static let rule = pattern(#"^[ \t]{0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$"#)
    private static let setextUnderline = pattern(#"^[ \t]{0,3}=+[ \t]*$"#)
    private static let quote = pattern(#"^[ \t]{0,3}>[ \t]?"#)
    private static let heading = pattern(#"^[ \t]{0,3}(#{1,6})(?:[ \t]+(.*))?$"#)
    private static let closingHashes = pattern(#"[ \t]+#+[ \t]*$"#)
    private static let bullet = pattern(#"^[ \t]*[-*+][ \t]+(?=\S)"#)
    private static let numbered = pattern(#"^[ \t]*(\d{1,3})([.)])[ \t]+(?=\S)"#)
    private static let image = pattern(#"!\[([^\]\n]*)\]\(([^()\s]+)(?:[ \t]+"[^"\n]*")?\)"#)
    private static let link = pattern(#"(?<!!)\[([^\]\n]+)\]\(([^()\s]*)(?:[ \t]+"[^"\n]*")?\)"#)
    private static let autolink = pattern(#"<(https?://[^>\s]+)>"#)
    private static let bareAddress = pattern(#"\bhttps?://[^\s<>"`\[\]]+"#)
    private static let wholeAddress = pattern(#"^https?://\S+$"#)
    private static let pathCandidate = pattern(#"(?<![\w/:.@~-])(?:(?:~|\.{1,2})?/[\w@+-][\w.@+-]*(?:/[\w.@+-]*)*|[\w@+-][\w.@+-]*(?:/[\w.@+-]*)+)"#)
}
