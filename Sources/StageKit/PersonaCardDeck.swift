import AppKit
import ImageIO

/// A saved image file's revision when a card set is frozen. If the file changes
/// later, its card is reported as changed instead of showing different pixels.
struct PersonaImageRevision: Equatable {
    let bytes: Int
    let modified: Date
    let fileNumber: Int

    init?(fileAt url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = (attributes[.size] as? NSNumber)?.intValue,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        self.bytes = bytes
        self.modified = modified
        fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.intValue ?? 0
    }
}

/// One candidate for the floating card, frozen when the card is shown: the saved
/// record as it was, which names the image file and carries every appearance
/// choice, such as the editable card, and that image's revision. A shown set
/// renders from this, never from the live library, so later library edits
/// cannot change how it looks.
struct PersonaSourceSnapshot: Equatable {
    let persona: SavedPersona
    /// nil when the image was already missing or unreadable when frozen.
    let revision: PersonaImageRevision?
    var id: UUID { persona.id }
}

/// The floating card on screen: one copy identity, kept while Next, Previous or
/// Choose Persona change the frozen source it shows, and that source. Showing
/// the card again starts a new copy.
struct PersonaShownCard: Equatable {
    let copyID: UUID
    let source: PersonaSourceSnapshot
}

/// Why a requested card cannot show. It names the card by its public label only,
/// never by a private library name or a file path.
struct PersonaCardUnavailable: LocalizedError, Equatable {
    enum Reason: Equatable { case unreadable, changed, tooLarge }
    let label: String
    let reason: Reason
    /// Whether another card stays on screen. A failed first show has none.
    let keepsShownCard: Bool

    var errorDescription: String? {
        let stays = "The current card stays up, and Next moves on."
        switch reason {
        case .unreadable:
            return "“\(label)” can’t be shown: its image is missing or unreadable. " + (keepsShownCard ? stays : "Import the finished image again.")
        case .changed:
            return "“\(label)” can’t be shown: its image changed after this card was shown. Hide and show the card again to use it."
                + (keepsShownCard ? " The current card stays up." : "")
        case .tooLarge:
            return "“\(label)” is too large to show within the \(PersonaSessionController.maximumImageBytes / 1_048_576) MB image limit."
                + (keepsShownCard ? " " + stays : "")
        }
    }
}

/// The frozen candidates behind one floating card and the few decoded images it
/// keeps. Who can follow the shown card, in which order and how each looks is
/// fixed when the card is shown, without decoding any of them. A requested card
/// decodes only if the images kept plus its own decoded size fit the budget; once
/// it shows, only it and its already decoded neighbours stay decoded.
final class PersonaCardDeck {
    /// Frozen candidate order. Library removals can take identities out; nothing is added or reordered.
    private(set) var order: [UUID]
    private(set) var sources: [UUID: PersonaSourceSnapshot]
    /// Each candidate's public label: its card label, or "Floating persona".
    private(set) var labels: [UUID: String]
    /// Decoded images kept: the shown card and nearby cards already decoded.
    private(set) var images: [UUID: NSImage] = [:]
    private var imageBytes: [UUID: Int] = [:]
    /// Retained plus pending decoded bytes never exceed this.
    let budget: Int
    /// The last card requested, shown or not. Next and Previous continue from it,
    /// so an unavailable card is passed over instead of trapping the cycle.
    var cursor: UUID?
    var retainedBytes: Int { imageBytes.values.reduce(0, +) }
    private let root: URL

    init(candidates: [SavedPersona], root: URL, budget: Int, label: (SavedPersona) -> String) {
        self.root = root
        self.budget = budget
        order = candidates.map(\.id)
        sources = Dictionary(uniqueKeysWithValues: candidates.map { persona in
            let revision = PersonaStorage.isImageName(persona.image)
                ? PersonaImageRevision(fileAt: root.appendingPathComponent(persona.image)) : nil
            return (persona.id, PersonaSourceSnapshot(persona: persona, revision: revision))
        })
        labels = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, label($0)) })
    }

    /// A candidate's public name: its card label, or its place in the set.
    func name(of id: UUID) -> String {
        if let label = labels[id], label != "Floating persona" { return label }
        return "Persona \((order.firstIndex(of: id) ?? 0) + 1)"
    }

    /// The card's image, decoding it within the budget unless it is already kept.
    /// `shown` is the card on screen: it stays decoded until its replacement is ready.
    func image(for id: UUID, shown: UUID?, render: (SavedPersona) -> NSImage?) throws -> NSImage {
        if let image = images[id] { return image }
        func unavailable(_ reason: PersonaCardUnavailable.Reason) -> PersonaCardUnavailable {
            PersonaCardUnavailable(label: name(of: id), reason: reason, keepsShownCard: shown != nil)
        }
        guard let source = sources[id], let frozen = source.revision else { throw unavailable(.unreadable) }
        let url = root.appendingPathComponent(source.persona.image)
        guard let current = PersonaImageRevision(fileAt: url) else { throw unavailable(.unreadable) }
        guard current == frozen else { throw unavailable(.changed) }
        guard let needed = Self.decodedBytes(ofImageAt: url, card: source.persona.card != nil) else { throw unavailable(.unreadable) }
        // Keep what stays useful once this card shows: the shown card until it is
        // replaced, and this card's decoded neighbours, while they all fit.
        let onScreen = Set([shown].compactMap { $0 })
        keep(onScreen.union(neighbours(of: id)))
        if retainedBytes + needed > budget { keep(onScreen) }
        guard retainedBytes + needed <= budget else { throw unavailable(.tooLarge) }
        guard let rendered = render(source.persona),
              let cgImage = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw unavailable(.unreadable) }
        let bytes = cgImage.bytesPerRow * cgImage.height
        guard retainedBytes + bytes <= budget else { throw unavailable(.tooLarge) }
        let image = NSImage(cgImage: cgImage, size: rendered.size)
        images[id] = image
        imageBytes[id] = bytes
        return image
    }

    /// Once a card shows, only it and its decoded neighbours stay decoded.
    func didShow(_ id: UUID) {
        cursor = id
        keep(Set([id] + neighbours(of: id)))
    }

    /// Library removals take candidates out of the frozen set.
    func keepOnly(_ ids: [UUID]) {
        let allowed = Set(ids)
        order.removeAll { !allowed.contains($0) }
        sources = sources.filter { allowed.contains($0.key) }
        labels = labels.filter { allowed.contains($0.key) }
        keep(allowed)
        if let cursor, !allowed.contains(cursor) { self.cursor = nil }
    }

    private func neighbours(of id: UUID) -> [UUID] {
        guard order.count > 1, let index = order.firstIndex(of: id) else { return [] }
        return [order[(index + order.count - 1) % order.count], order[(index + 1) % order.count]]
    }

    private func keep(_ ids: Set<UUID>) {
        for id in Array(images.keys) where !ids.contains(id) {
            images[id] = nil
            imageBytes[id] = nil
        }
    }

    /// Decoded bytes a card needs before it can replace the shown one: its image
    /// as the library decodes it, at most 4096 pixels on the longer side, and for
    /// an editable card the rendered card as well.
    static func decodedBytes(ofImageAt url: URL, card: Bool) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0 else { return nil }
        let scale = min(1, 4096 / max(width, height))
        let decoded = Int((width * scale).rounded(.up)) * Int((height * scale).rounded(.up)) * 4
        let rendered = card ? Int(PersonaCardRenderer.size.width) * Int(PersonaCardRenderer.size.height) * 4 : 0
        return decoded + rendered
    }
}
