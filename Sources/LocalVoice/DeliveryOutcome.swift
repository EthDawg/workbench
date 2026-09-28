import Foundation

/// A delivery that did not finish: the words are safe, but the person may not
/// have them where they wanted (#134 T5). It names the words' canonical record
/// and never keeps a copy of them, so the receipt going, a hidden notice, a
/// clipboard change or a quit cannot make it look delivered.
struct UnresolvedDelivery: Identifiable, Equatable {
    enum Kind: Equatable {
        case copyFailed
        /// ⌘V was sent, but the words could not be seen arriving.
        case pasteUnconfirmed
        /// Delivery stopped; `pasteSent` says whether ⌘V had already gone.
        case stopped(pasteSent: Bool)
        /// The clipboard changed first, so nothing was pasted.
        case notPasted
    }
    /// Where the words are kept.
    enum Reference: Equatable {
        /// A transcript saved in History.
        case transcript(UUID)
        /// The Dictate draft at this revision. Only that revision's words are
        /// these words: once the draft changes, the entry no longer acts.
        case draft(revision: UInt64)
    }
    var id = UUID()
    let kind: Kind
    var reference: Reference
    let wordCount: Int
    /// Set only when shown: the draft has changed since, so its words may be
    /// gone and Copy again could copy other words.
    fileprivate(set) var draftChanged = false

    init(kind: Kind, reference: Reference, wordCount: Int) {
        self.kind = kind; self.reference = reference; self.wordCount = wordCount
    }

    /// Only outcomes that leave the words undelivered or uncertain. A copy
    /// waiting for ⌘V, a confirmed paste and a paste whose old clipboard could
    /// not be restored all delivered the words.
    static func kind(of outcome: TextDelivery.Outcome) -> Kind? {
        switch outcome.failure {
        case .copyFailed?: return .copyFailed
        case .pasteUnconfirmed?: return .pasteUnconfirmed
        case .cancelled?: return .stopped(pasteSent: outcome.pasteWasAttempted)
        case .clipboardChanged?: return .notPasted
        default: return nil
        }
    }

    var isDraft: Bool { if case .draft = reference { return true } else { return false } }

    var title: String {
        switch kind {
        case .copyFailed: return "Copy failed"
        case .pasteUnconfirmed: return "Paste unconfirmed"
        case .stopped: return "Delivery stopped"
        case .notPasted: return "Not pasted"
        }
    }

    var symbolName: String {
        switch kind {
        case .copyFailed, .notPasted: return "exclamationmark.triangle"
        case .pasteUnconfirmed, .stopped: return "questionmark.circle"
        }
    }

    var detail: String {
        if draftChanged { return "Your Dictate draft has changed since. Review it before copying." }
        let kept = isDraft ? "Your words are in the Dictate draft." : "Your words are saved in History."
        switch kind {
        case .copyFailed: return "\(kept) Copy them again when you're ready."
        case .pasteUnconfirmed: return "Check where you were typing before pasting again. \(kept)"
        case .stopped(pasteSent: true): return "A paste may have been sent. Check where you were typing. \(kept)"
        case .stopped(pasteSent: false): return "Nothing was pasted. \(kept)"
        case .notPasted: return "The clipboard changed first, so nothing was pasted. \(kept)"
        }
    }

    /// Copy again only where it cannot lead to a second insertion, and only
    /// while the words are still where the entry says.
    var offersCopy: Bool {
        guard !draftChanged else { return false }
        switch kind {
        case .copyFailed, .notPasted, .stopped(pasteSent: false): return true
        case .pasteUnconfirmed, .stopped(pasteSent: true): return false
        }
    }
}

/// Saved with the session: what happened, the transcript's ID or the draft,
/// and the word count. Never the words. A saved draft entry was current when
/// it was written, so it takes the loaded draft's revision on launch.
extension UnresolvedDelivery: Codable {
    private enum CodingKeys: String, CodingKey { case kind, transcript, words }
    private enum SavedKind: String, Codable { case copyFailed, pasteUnconfirmed, stoppedAfterPaste, stoppedBeforePaste, notPasted }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind: Kind
        switch try container.decode(SavedKind.self, forKey: .kind) {
        case .copyFailed: kind = .copyFailed
        case .pasteUnconfirmed: kind = .pasteUnconfirmed
        case .stoppedAfterPaste: kind = .stopped(pasteSent: true)
        case .stoppedBeforePaste: kind = .stopped(pasteSent: false)
        case .notPasted: kind = .notPasted
        }
        let reference = try container.decodeIfPresent(UUID.self, forKey: .transcript).map(Reference.transcript) ?? .draft(revision: 0)
        self.init(kind: kind, reference: reference, wordCount: try container.decode(Int.self, forKey: .words))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let saved: SavedKind
        switch kind {
        case .copyFailed: saved = .copyFailed
        case .pasteUnconfirmed: saved = .pasteUnconfirmed
        case .stopped(pasteSent: true): saved = .stoppedAfterPaste
        case .stopped(pasteSent: false): saved = .stoppedBeforePaste
        case .notPasted: saved = .notPasted
        }
        try container.encode(saved, forKey: .kind)
        if case .transcript(let id) = reference { try container.encode(id, forKey: .transcript) }
        try container.encode(wordCount, forKey: .words)
    }
}

/// The canonical records an undelivered result can name, as its owner holds
/// them at this moment: History's transcripts, and the Dictate draft with its
/// revision.
struct DeliveryRecords {
    /// A transcript's words in History, or nil once it is gone.
    let transcript: (UUID) -> String?
    /// The draft's words and revision, or nil when what is being written is
    /// not the draft the revision counts (a write about to replace it).
    let draft: (text: String, revision: UInt64)?

    init(history: [Transcript], draft: (text: String, revision: UInt64)?) {
        transcript = { id in history.first { $0.id == id }?.text }
        self.draft = draft
    }
}

/// The one undelivered result and the only ways it changes (#134 T5). One
/// slot: a newer undelivered result takes the place of an older one, whose
/// words stay in History. It resolves only when the same words are delivered
/// again, as its canonical record holds them now, or when the person dismisses
/// it. Its owner hands in the records each time; the words are never kept here.
struct UnresolvedDeliverySlot: Equatable {
    private(set) var entry: UnresolvedDelivery?

    /// The entry's words as its record holds them now: the transcript's text,
    /// or the draft while it is still the revision that failed. Nil once the
    /// transcript is gone or the draft has changed.
    static func words(of entry: UnresolvedDelivery, in records: DeliveryRecords) -> String? {
        switch entry.reference {
        case .transcript(let id): return records.transcript(id)
        case .draft(let revision): return records.draft.flatMap { $0.revision == revision ? $0.text : nil }
        }
    }

    /// A delivery of `text`, from the record `reference` names, finished. An
    /// undelivered or uncertain outcome takes the slot. A delivered one
    /// resolves it only when these are the entry's own words.
    mutating func note(_ outcome: TextDelivery.Outcome, text: String, from reference: UnresolvedDelivery.Reference, in records: DeliveryRecords) {
        if let kind = UnresolvedDelivery.kind(of: outcome) {
            entry = UnresolvedDelivery(kind: kind, reference: reference, wordCount: TextRules.wordCount(text))
        } else if let entry, Self.words(of: entry, in: records) == text {
            self.entry = nil
        }
    }

    /// What Copy again copies: the record's words, only where copying cannot
    /// paste twice and only while the record still holds them.
    func wordsToCopy(in records: DeliveryRecords) -> String? {
        guard let entry = shown(in: records), entry.offersCopy else { return nil }
        return Self.words(of: entry, in: records)
    }

    /// What the shelf shows. A draft entry whose draft has changed says so and
    /// offers Review instead of Copy again; a transcript entry whose transcript
    /// is gone shows nothing, since there is nothing left to deliver.
    func shown(in records: DeliveryRecords) -> UnresolvedDelivery? {
        guard var entry else { return nil }
        let words = Self.words(of: entry, in: records)
        if entry.isDraft { entry.draftChanged = words == nil } else if words == nil { return nil }
        return entry
    }

    /// The person's own choice to set it aside. Hiding a notice never does this.
    mutating func dismiss() { entry = nil }

    /// The person removed this transcript from History: nothing is left to deliver.
    mutating func transcriptRemoved(_ id: UUID) {
        if entry?.reference == .transcript(id) { entry = nil }
    }

    /// The entry as a write saves it: only while what is written still holds
    /// its words, so a saved entry always names words that are there.
    func saved(in records: DeliveryRecords) -> UnresolvedDelivery? {
        guard let entry, Self.words(of: entry, in: records) != nil else { return nil }
        return entry
    }

    /// On launch, once the draft is settled: the saved entry comes back only
    /// with its words. A transcript entry needs its transcript; a draft entry
    /// needs the draft launch loaded, unchanged since (recovery can replace
    /// it), and takes that draft's revision.
    mutating func restore(_ saved: UnresolvedDelivery?, loadedDraftRevision: UInt64, in records: DeliveryRecords) {
        guard var saved else { entry = nil; return }
        switch saved.reference {
        case .transcript(let id):
            entry = records.transcript(id) == nil ? nil : saved
        case .draft:
            guard let draft = records.draft, draft.revision == loadedDraftRevision else { entry = nil; return }
            saved.reference = .draft(revision: draft.revision)
            entry = saved
        }
    }
}
