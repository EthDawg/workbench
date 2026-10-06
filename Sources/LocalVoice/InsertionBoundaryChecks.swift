import Foundation

/// Synthetic fixtures for every rule in `InsertionBoundary` (#14). No field, clipboard
/// or Accessibility is touched; every string here is invented.
enum InsertionBoundaryChecks {
    private struct Case {
        var name: String
        var before: String
        var after: String
        var dictated: String
        var expected: String
        var decisions: [InsertionBoundary.Decision] = []
        var context = InsertionBoundary.Context()
    }
    private static let dictionary = InsertionBoundary.Context(dictionaryTerms: ["Mark", "Snap & Talk"])
    private static let cases: [Case] = [
        // The issue's own examples.
        Case(name: "joins a word boundary on both sides", before: "Please bring", after: "tomorrow", dictated: "The blue folder",
             expected: " the blue folder ", decisions: [.leadingSpace, .lowercased, .trailingSpace]),
        Case(name: "an existing space is never doubled", before: "Please bring ", after: " tomorrow", dictated: "The blue folder.",
             expected: "the blue folder", decisions: [.lowercased, .droppedFullStop]),
        Case(name: "a dictionary name keeps its capital mid-sentence", before: "I spoke to ", after: " yesterday", dictated: "Mark",
             expected: "Mark", decisions: [.kept(.dictionaryTerm)], context: dictionary),
        Case(name: "a name the dictionary does not know follows the sentence", before: "I spoke to ", after: " yesterday", dictated: "Mark",
             expected: "mark", decisions: [.lowercased]),
        Case(name: "a product name the field already capitalises mid-sentence stays", before: "We use Workbench daily. I told ", after: " about it", dictated: "Workbench",
             expected: "Workbench", decisions: [.kept(.capitalisedElsewhere)]),
        Case(name: "a product name capitalised later in the dictation stays", before: "we use ", after: "", dictated: "Workbench daily, and Workbench rocks",
             expected: "Workbench daily, and Workbench rocks", decisions: [.kept(.capitalisedElsewhere)]),
        Case(name: "a sentence-start capital elsewhere is not evidence", before: "The cat sat on the mat and ", after: "", dictated: "The dog slept",
             expected: "the dog slept", decisions: [.lowercased]),
        // Sentence starts.
        Case(name: "an empty field capitalises", before: "", after: "", dictated: "hello there", expected: "Hello there", decisions: [.sentenceStart, .capitalised]),
        Case(name: "after a full stop and space capitalises", before: "Done. ", after: "", dictated: "next step", expected: "Next step", decisions: [.sentenceStart, .capitalised]),
        Case(name: "after a full stop with no space adds one and capitalises", before: "Done.", after: "", dictated: "next step", expected: " Next step", decisions: [.leadingSpace, .sentenceStart, .capitalised]),
        Case(name: "after a question mark capitalises", before: "Ready? ", after: "", dictated: "yes", expected: "Yes"),
        Case(name: "a closing quote after the full stop still starts a sentence", before: "He said \"no.\" ", after: "", dictated: "then he left", expected: "Then he left"),
        Case(name: "after a line break capitalises without a space", before: "Item one\n", after: "", dictated: "item two", expected: "Item two", decisions: [.sentenceStart, .capitalised]),
        Case(name: "after a line break and indentation capitalises", before: "Item one\n  ", after: "", dictated: "item two", expected: "Item two"),
        Case(name: "a dictated capital at a sentence start is left alone", before: "", after: "", dictated: "Hello", expected: "Hello", decisions: [.sentenceStart]),
        Case(name: "an all-caps acronym at a sentence start is left alone", before: "", after: "", dictated: "NASA launched", expected: "NASA launched"),
        Case(name: "a product spelling at a sentence start is kept", before: "", after: "", dictated: "iPhone is charged", expected: "iPhone is charged", decisions: [.kept(.notOneTitleCaseWord)]),
        Case(name: "a URL at a sentence start is kept", before: "", after: "", dictated: "github.com is down", expected: "github.com is down", decisions: [.kept(.notAPlainWord)]),
        Case(name: "an abbreviation at a sentence start is kept", before: "", after: "", dictated: "e.g. this one", expected: "e.g. this one", decisions: [.kept(.notAPlainWord)]),
        Case(name: "a contraction capitalises", before: "", after: "", dictated: "don't go", expected: "Don't go"),
        Case(name: "a hyphenated word capitalises its first letter only", before: "", after: "", dictated: "x-ray results", expected: "X-ray results"),
        Case(name: "a number at a sentence start is kept", before: "", after: "", dictated: "5 people came", expected: "5 people came"),
        // Mid-sentence spelling.
        Case(name: "an all-caps acronym keeps its capitals", before: "contact ", after: "", dictated: "NASA today", expected: "NASA today", decisions: [.kept(.notOneTitleCaseWord)]),
        Case(name: "the pronoun I stays", before: "I think ", after: "", dictated: "I'm done", expected: "I'm done", decisions: [.kept(.pronounI)]),
        Case(name: "I alone stays", before: "and then ", after: "", dictated: "I left", expected: "I left", decisions: [.kept(.pronounI)]),
        Case(name: "an inner capital keeps the spelling", before: "call ", after: "", dictated: "O'Brien", expected: "O'Brien", decisions: [.kept(.notOneTitleCaseWord)]),
        Case(name: "a camel-case name keeps the spelling", before: "visit ", after: "", dictated: "McDonald", expected: "McDonald", decisions: [.kept(.notOneTitleCaseWord)]),
        Case(name: "a lowercase-first product name is untouched", before: "use ", after: "", dictated: "iPhone", expected: "iPhone"),
        Case(name: "a URL is untouched", before: "see ", after: "", dictated: "github.com/x", expected: "github.com/x", decisions: [.kept(.notAPlainWord)]),
        Case(name: "code keeps the spelling", before: "run ", after: "", dictated: "Print(x)", expected: "Print(x)", decisions: [.kept(.notAPlainWord)]),
        Case(name: "a number keeps the spelling", before: "about ", after: "", dictated: "5 people", expected: "5 people", decisions: [.kept(.notAPlainWord)]),
        Case(name: "a letter joined to a digit keeps the spelling", before: "with ", after: "", dictated: "A4 paper", expected: "A4 paper", decisions: [.kept(.notAPlainWord)]),
        Case(name: "a word joined to punctuation keeps the spelling", before: "say ", after: "", dictated: "Hello,world", expected: "Hello,world", decisions: [.kept(.notAPlainWord)]),
        Case(name: "a Title-case word before a comma is lowercased", before: "say ", after: "", dictated: "Hello, world", expected: "hello, world", decisions: [.lowercased]),
        Case(name: "a single-letter article is lowercased", before: "bring ", after: "", dictated: "A folder", expected: "a folder", decisions: [.lowercased]),
        Case(name: "a hyphenated Title-case word is lowercased", before: "the ", after: "", dictated: "Mid-sentence case", expected: "mid-sentence case"),
        Case(name: "a Title-case contraction is lowercased", before: "I think ", after: "", dictated: "Don't", expected: "don't"),
        Case(name: "a multi-word dictionary term keeps its capital", before: "open ", after: "", dictated: "Snap & Talk now", expected: "Snap & Talk now", decisions: [.kept(.dictionaryTerm)], context: dictionary),
        Case(name: "a dictionary term is matched exactly, not by prefix", before: "open ", after: "", dictated: "Marker pens", expected: "marker pens", decisions: [.lowercased], context: dictionary),
        Case(name: "a dictated opening quote keeps the words inside it", before: "He said", after: "", dictated: "\"Hello there\"", expected: " \"Hello there\"", decisions: [.leadingSpace, .kept(.notAPlainWord)]),
        // Punctuation either side.
        Case(name: "no space before a full stop", before: "Thanks", after: ".", dictated: "a lot", expected: " a lot", decisions: [.leadingSpace]),
        Case(name: "a dictated full stop is not doubled", before: "Thanks", after: ".", dictated: "a lot.", expected: " a lot", decisions: [.leadingSpace, .droppedFullStop]),
        Case(name: "a dictated full stop before a comma is dropped", before: "", after: ", ok", dictated: "Yes.", expected: "Yes"),
        Case(name: "a full stop stays before a capital", before: "Hi.", after: "World", dictated: "there.", expected: " There. ", decisions: [.leadingSpace, .sentenceStart, .capitalised, .trailingSpace]),
        Case(name: "a full stop stays before a line break", before: "foo ", after: "\nbar", dictated: "done.", expected: "done."),
        Case(name: "a full stop stays at the end of the field", before: "foo ", after: "", dictated: "done.", expected: "done."),
        Case(name: "an ellipsis is not a full stop", before: "foo ", after: " bar", dictated: "wait...", expected: "wait..."),
        Case(name: "a full stop is dropped before a digit", before: "costs ", after: "dollars", dictated: "five.", expected: "five ", decisions: [.trailingSpace, .droppedFullStop]),
        Case(name: "a question mark stays mid-sentence", before: "", after: " then", dictated: "Really?", expected: "Really?"),
        Case(name: "no space after an opening bracket or before a closing one", before: "foo(", after: ")", dictated: "bar", expected: "bar"),
        Case(name: "a space before an opening bracket", before: "foo ", after: "(bar)", dictated: "baz", expected: "baz ", decisions: [.trailingSpace]),
        Case(name: "no space before a dictated comma", before: "foo ", after: "", dictated: ", and then", expected: ", and then"),
        Case(name: "a space after a closing bracket", before: "(foo)", after: "", dictated: "bar", expected: " bar"),
        Case(name: "no space after an opening straight quote", before: "He said \"", after: "", dictated: "hello", expected: "hello"),
        Case(name: "a space after a closing straight quote", before: "He said \"hi\"", after: "", dictated: "then", expected: " then"),
        Case(name: "no space after an opening curly quote", before: "He said “", after: "", dictated: "hello", expected: "hello"),
        Case(name: "a space after a closing curly quote", before: "He said “hi”", after: "", dictated: "then", expected: " then"),
        Case(name: "a space before an opening quote that is later closed", before: "", after: "\"quoted\" words", dictated: "say", expected: "Say "),
        Case(name: "no space before a quote that closes", before: "He said \"", after: "\"", dictated: "hello", expected: "hello"),
        Case(name: "a space after a possessive apostrophe", before: "the dogs'", after: "", dictated: "bowls", expected: " bowls"),
        Case(name: "no space after an opening single quote", before: "'", after: "", dictated: "tis", expected: "tis"),
        Case(name: "no space after a hyphen", before: "self-", after: "", dictated: "aware", expected: "aware"),
        Case(name: "no space after an at sign or slash", before: "me@", after: "", dictated: "example", expected: "example"),
        Case(name: "no space after a currency sign", before: "$", after: "", dictated: "five", expected: "five"),
        Case(name: "a space after an emoji", before: "Great 🙂", after: "", dictated: "thanks", expected: " thanks", decisions: [.leadingSpace]),
        Case(name: "a space before an emoji", before: "", after: "🙂", dictated: "hi", expected: "Hi ", decisions: [.sentenceStart, .capitalised, .trailingSpace]),
        Case(name: "a space after a percentage", before: "50%", after: "", dictated: "done", expected: " done"),
        // Whitespace and line breaks.
        Case(name: "edge spaces are dropped", before: "foo ", after: "", dictated: "  bar  ", expected: "bar", decisions: [.trimmedEdges]),
        Case(name: "a space either side is kept once", before: "foo ", after: " bar", dictated: "baz", expected: "baz"),
        Case(name: "a tab before needs no space", before: "foo\t", after: "", dictated: "bar", expected: "bar"),
        Case(name: "a space before text that follows", before: "", after: "tomorrow", dictated: "Bring it", expected: "Bring it ", decisions: [.sentenceStart, .trailingSpace]),
        Case(name: "no space before a line break", before: "foo", after: "\nbar", dictated: "baz", expected: " baz", decisions: [.leadingSpace]),
        Case(name: "dictation starting with a line break needs no space", before: "foo", after: "", dictated: "\nbar", expected: "\nbar"),
        Case(name: "dictation ending with a line break needs no space", before: "", after: "bar", dictated: "Foo\n", expected: "Foo\n"),
        Case(name: "a bulleted cleanup keeps its inner line breaks", before: "List:", after: "", dictated: "• Apples\n• Pears", expected: " • Apples\n• Pears", decisions: [.leadingSpace, .kept(.notAPlainWord)]),
        Case(name: "whitespace-only dictation is unchanged", before: "foo", after: "bar", dictated: "   ", expected: "   ", decisions: [.nothingToInsert]),
        Case(name: "empty dictation is unchanged", before: "foo", after: "bar", dictated: "", expected: "", decisions: [.nothingToInsert]),
        Case(name: "a secure field is excluded", before: "foo", after: "bar", dictated: "Secret", expected: "Secret", decisions: [.secureFieldExcluded],
             context: .init(kind: .secure)),
        Case(name: "inside a word, both sides get a space", before: "hel", after: "lo", dictated: "x", expected: " x "),
        Case(name: "a digit before gets a space", before: "Room 5", after: "", dictated: "is free", expected: " is free"),
        Case(name: "a digit after gets a space", before: "", after: "5 apples", dictated: "buy", expected: "Buy "),
    ]

    static func run() throws {
        var passed = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("INSERTION BOUNDARY CHECK FAILED: " + name) }
            passed += 1
        }
        for item in cases {
            let fit = InsertionBoundary.fit(before: item.before, after: item.after, dictated: item.dictated, context: item.context)
            try check(fit.text == item.expected, "\(item.name): expected \(item.expected.debugDescription), got \(fit.text.debugDescription) (\(fit.decisions))")
            for decision in item.decisions {
                try check(fit.decisions.contains(decision), "\(item.name): expected decision \(decision), got \(fit.decisions)")
            }
            try check(!fit.text.contains("  ") || item.dictated.contains("  ") && fit.decisions.contains(.nothingToInsert),
                      "\(item.name): never a double space")
        }
        try check(InsertionBoundary.fit(before: "", after: "", dictated: "words").decisions.allSatisfy { !$0.description.isEmpty },
                  "every decision explains itself")

        // Replacing a selection measures the text around the selection, not inside it.
        let around = InsertionBoundary.fit(dictated: "The folder", value: "Please bring OLD tomorrow", selection: NSRange(location: 13, length: 3))
        try check(around?.text == "the folder", "replacing a word between spaces adds none")
        let withSpace = InsertionBoundary.fit(dictated: "The folder", value: "Please bring OLD tomorrow", selection: NSRange(location: 12, length: 4))
        try check(withSpace?.text == " the folder", "replacing a selection that took the leading space restores it")
        let whole = InsertionBoundary.fit(dictated: "hello", value: "old words", selection: NSRange(location: 0, length: 9))
        try check(whole?.text == "Hello", "replacing the whole field is a sentence start")
        let caret = InsertionBoundary.fit(dictated: "Hello", value: "🙂 prefix OLD suffix", selection: NSRange(location: 10, length: 3))
        try check(caret?.text == "hello", "UTF-16 selection offsets past an emoji split the field correctly")
        try check(InsertionBoundary.fit(dictated: "x", value: nil, selection: NSRange(location: 0, length: 0)) == nil, "an unreadable value gives no fit")
        try check(InsertionBoundary.fit(dictated: "x", value: "ab", selection: nil) == nil, "a missing selection gives no fit")
        try check(InsertionBoundary.fit(dictated: "x", value: "ab", selection: NSRange(location: 3, length: 0)) == nil, "a selection past the end gives no fit")
        try check(InsertionBoundary.fit(dictated: "x", value: "😀", selection: NSRange(location: 1, length: 0)) == nil, "a split surrogate gives no fit")

        // Sentence detection on its own.
        for (text, expected) in [("", true), ("   ", true), ("Done. ", true), ("Done.", true), ("Done!", true), ("Why? ", true),
                                 ("Line\n", true), ("Line\n\t ", true), ("He said \"no.\" ", true), ("(Done.) ", true),
                                 ("Done, ", false), ("Done ", false), ("Done", false), ("Done; ", false), ("e.g. ", true), ("Wait… ", false)] {
            try check(InsertionBoundary.isSentenceStart(text) == expected, "sentence start for \(text.debugDescription) is \(expected)")
        }
        // A large field is scanned once, not once per occurrence.
        let large = String(repeating: "The end. ", count: 20_000) + "and "
        let started = Date()
        let scanned = InsertionBoundary.fit(before: large, after: "", dictated: "The next")
        try check(scanned.text == "the next" && Date().timeIntervalSince(started) < 2, "a large field with many sentence-start capitals is scanned in bounded time")
        print("INSERTION_BOUNDARY_CHECKS_OK: \(passed) checks over \(cases.count) synthetic fixtures; no field, clipboard or Accessibility touched")
    }
}
