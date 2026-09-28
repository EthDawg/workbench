import Foundation

/// A delivery that did not finish: the words are safe, but the person may not
/// have them where they wanted (#134 T5). Its owner, the dictation delivery,
/// keeps it with the words' canonical record, so the receipt going, a hidden
/// notice or a clipboard change cannot make it look delivered. A later copy of
/// the same words, or the person's Dismiss, resolves it. A newer one takes its
/// place; the older words stay in History, where Copy still works.
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
        /// The current Dictate draft.
        case draft
    }
    let id = UUID()
    let kind: Kind
    let reference: Reference
    let wordCount: Int

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
        let kept = reference == .draft ? "Your words are in the Dictate draft." : "Your words are saved in History."
        switch kind {
        case .copyFailed: return "\(kept) Copy them again when you're ready."
        case .pasteUnconfirmed: return "Check where you were typing before pasting again. \(kept)"
        case .stopped(pasteSent: true): return "A paste may have been sent. Check where you were typing. \(kept)"
        case .stopped(pasteSent: false): return "Nothing was pasted. \(kept)"
        case .notPasted: return "The clipboard changed first, so nothing was pasted. \(kept)"
        }
    }

    /// Copy again only where it cannot lead to a second insertion.
    var offersCopy: Bool {
        switch kind {
        case .copyFailed, .notPasted, .stopped(pasteSent: false): return true
        case .pasteUnconfirmed, .stopped(pasteSent: true): return false
        }
    }
}
