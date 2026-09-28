import Foundation

struct RememberedCorrection {
    let written: String
    let beforeRules: [Replacement]
    let afterRules: [Replacement]
    let beforeDraft: String
    let afterDraft: String
    let appliedRevision: UInt64
}

/// A value proposal only: the caller decides whether to save the rule and whether
/// to apply previewText. Recreate it from current draft/rules before committing.
struct CorrectionRuleProposal {
    let rule: Replacement
    let previousRule: Replacement?
    let updatedRules: [Replacement]
    let sourceDraft: String
    let previewText: String
    /// Whole phrase occurrences, including occurrences already using the desired casing.
    let matchCount: Int
    var replacesExisting: Bool { previousRule != nil && previousRule != rule }
    var isAlreadyRemembered: Bool { previousRule == rule }
    var changesDraft: Bool { sourceDraft != previewText }
}

/// What saving one phrase does to the dictionary. Dictionary's Add and Update and
/// Remember correction all decide through this, so they agree on what is new,
/// what is already saved and what an Update would change.
struct CorrectionRuleChange: Equatable {
    /// The rule to save. When nothing changes it is the saved rule itself; an
    /// update keeps the saved rule's identity.
    let rule: Replacement
    /// The saved rule for the same phrase, if there is one.
    let previousRule: Replacement?
    /// The whole dictionary after saving: a new phrase goes last, and an updated
    /// one keeps its place among the unrelated rules.
    let updatedRules: [Replacement]
    var isNew: Bool { previousRule == nil }
    /// The phrase already writes exactly this. A change only to Heard's casing is
    /// the same rule, because matching ignores case.
    var isAlreadySaved: Bool { previousRule != nil && previousRule == rule }
    /// The phrase is saved with a different output, including different casing.
    var updatesExisting: Bool { previousRule != nil && previousRule != rule }
}

enum CorrectionRuleError: LocalizedError, Equatable {
    case emptyField(String)
    case tooLong(String)
    case unsupportedCharacters(String)
    case noChange
    case duplicateRules(heard: String, count: Int)
    case conflictChanged(heard: String)

    var errorDescription: String? {
        switch self {
        case .emptyField(let field): return "Add some text to \(field)."
        case .tooLong(let field): return "Keep \(field) to \(CorrectionRule.maximumCharacters) characters or fewer."
        case .unsupportedCharacters(let field): return "Use one line of text in \(field), without tabs or control characters."
        case .noChange: return "Heard and Write instead already match, so there is nothing to correct."
        case .duplicateRules(let heard, let count):
            return "There are \(count) dictionary rules for “\(heard)”. Choose the spelling to keep in Dictionary first."
        case .conflictChanged(let heard):
            return "The rules for “\(heard)” changed. Review them in Dictionary again."
        }
    }
}

enum CorrectionRule {
    static let maximumCharacters = 120

    /// A saved phrase's identity. TextRules matches Heard ignoring case, so two
    /// Heard phrases are one rule when they fold to the same text. The folding is
    /// the full case folding TextRules' matching uses (“straße” and “STRASSE”
    /// agree), and canonically different spellings stay apart, as they do there.
    static func phraseKey(_ heard: String) -> [Unicode.Scalar] {
        Array(heard.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive], locale: nil).unicodeScalars)
    }

    /// Validates Heard and Write instead and finds the saved rule for that phrase.
    /// An exact saved pair changes nothing; a different output for a saved phrase
    /// keeps that rule's identity and place. Several saved rules for the phrase
    /// are an unresolved conflict, never silently repaired here.
    static func change(heard: String, written: String, replacements: [Replacement]) throws -> CorrectionRuleChange {
        let heard = try validated(heard, field: "Heard")
        let written = try validated(written, field: "Write instead")
        guard heard != written else { throw CorrectionRuleError.noChange }
        let key = phraseKey(heard)
        let matches = replacements.indices.filter { phraseKey(replacements[$0].heard) == key }
        guard matches.count <= 1 else { throw CorrectionRuleError.duplicateRules(heard: heard, count: matches.count) }
        guard let index = matches.first else {
            let rule = Replacement(heard: heard, written: written)
            return CorrectionRuleChange(rule: rule, previousRule: nil, updatedRules: replacements + [rule])
        }
        let previous = replacements[index]
        guard previous.written != written else {
            return CorrectionRuleChange(rule: previous, previousRule: previous, updatedRules: replacements)
        }
        var rule = Replacement(heard: heard, written: written)
        rule.id = previous.id
        var updated = replacements
        updated[index] = rule
        return CorrectionRuleChange(rule: rule, previousRule: previous, updatedRules: updated)
    }

    /// Saved phrases with more than one rule, each in dictionary order. TextRules
    /// applies only the first of them, so each needs one explicit choice.
    static func conflicts(in replacements: [Replacement]) -> [[Replacement]] {
        var groups: [[Unicode.Scalar]: [Replacement]] = [:]
        var order: [[Unicode.Scalar]] = []
        for rule in replacements {
            let key = phraseKey(rule.heard)
            guard !key.isEmpty else { continue }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(rule)
        }
        return order.compactMap { key in groups[key].flatMap { $0.count > 1 ? $0 : nil } }
    }

    /// Keeps one output for a phrase with several rules. The first of them keeps
    /// its identity and place and writes the chosen output; that phrase's other
    /// rules go, and every unrelated rule stays exactly where it was.
    static func resolvingConflict(keeping chosen: Replacement, in replacements: [Replacement]) throws -> [Replacement] {
        let key = phraseKey(chosen.heard)
        let matches = replacements.indices.filter { phraseKey(replacements[$0].heard) == key }
        guard matches.count > 1, let first = matches.first, replacements.contains(chosen) else {
            throw CorrectionRuleError.conflictChanged(heard: chosen.heard.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var kept = replacements[first]
        kept.written = chosen.written
        return replacements.indices.compactMap { index in
            if index == first { return kept }
            return matches.contains(index) ? nil : replacements[index]
        }
    }

    /// Matches TextRules' case-insensitive literal phrase and Unicode word boundaries.
    /// The current draft preview applies this rule alone, without trimming the draft
    /// or replaying unrelated dictionary rules. No matches still permits future use.
    static func propose(heard: String, written: String, draft: String, replacements: [Replacement]) throws -> CorrectionRuleProposal {
        let change = try change(heard: heard, written: written, replacements: replacements)
        let literal = NSRegularExpression.escapedPattern(for: heard.trimmingCharacters(in: .whitespacesAndNewlines))
        let pattern = "(?<![\\p{L}\\p{N}_])" + literal + "(?![\\p{L}\\p{N}_])"
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(draft.startIndex..., in: draft)
        let count = regex.numberOfMatches(in: draft, range: range)
        let preview = regex.stringByReplacingMatches(in: draft, range: range,
                                                     withTemplate: NSRegularExpression.escapedTemplate(for: change.rule.written))
        return CorrectionRuleProposal(rule: change.rule, previousRule: change.previousRule, updatedRules: change.updatedRules,
                                      sourceDraft: draft, previewText: preview, matchCount: count)
    }

    private static func validated(_ source: String, field: String) throws -> String {
        // Inspect before trimming so pasted line breaks or invisible controls cannot
        // silently turn into a different rule from the one the user entered.
        guard !source.unicodeScalars.contains(where: {
            CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) else { throw CorrectionRuleError.unsupportedCharacters(field) }
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw CorrectionRuleError.emptyField(field) }
        guard value.count <= maximumCharacters else { throw CorrectionRuleError.tooLong(field) }
        return value
    }
}
