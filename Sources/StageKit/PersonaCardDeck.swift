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
        switch (reason, keepsShownCard) {
        case (.unreadable, false):
            return "“\(label)” can’t be shown: its image is missing or unreadable. Import the finished image again."
        case (.unreadable, true):
            return "“\(label)” can’t be shown: its image is missing or unreadable. " + Self.stays
        case (.changed, false):
            return "“\(label)” can’t be shown: its image changed while it was loading. Try again."
        case (.changed, true):
            return "“\(label)” can’t be shown: its image changed after you showed this card. " + Self.stays
                + " To use the new image, hide the card and show it again."
        case (.tooLarge, false):
            return "“\(label)” is too large to show within the \(PersonaSessionController.maximumImageBytes / 1_048_576) MB image limit."
        case (.tooLarge, true):
            return "“\(label)” is too large to show beside the current card within the \(PersonaSessionController.maximumImageBytes / 1_048_576) MB image limit. " + Self.stays
        }
    }
    /// Either direction passes over the card, so the notice promises no particular key.
    private static let stays = "The current card stays up, and Next and Previous skip it for now."
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
    /// Cards that could not show while the current card has been up. Next and
    /// Previous count from the shown card and pass over these, so neither traps
    /// the cycle or does nothing; each is tried again once another card shows.
    private(set) var unavailable: Set<UUID> = []
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

    /// The card Next or Previous reaches from the shown card, passing over cards
    /// that could not show while it has been up. nil when no other card can be tried.
    func step(from shown: UUID, by offset: Int) -> UUID? {
        guard offset != 0, order.count > 1, var index = order.firstIndex(of: shown) else { return nil }
        for _ in 1..<order.count {
            index = (index + offset % order.count + order.count) % order.count
            if order[index] == shown { return nil }
            if !unavailable.contains(order[index]) { return order[index] }
        }
        return nil
    }

    /// The card's image, decoding it within the budget unless it is already kept.
    /// `shown` is this deck's card on screen: it stays decoded until its replacement
    /// is ready, and a card that cannot show beside it is passed over by later steps.
    /// `reserved` counts decoded images another deck keeps on screen meanwhile.
    func image(for id: UUID, shown: UUID?, reserved: Int = 0, render: (SavedPersona) -> NSImage?) throws -> NSImage {
        if let image = images[id] { return image }
        func failure(_ reason: PersonaCardUnavailable.Reason) -> PersonaCardUnavailable {
            if shown != nil { unavailable.insert(id) }
            return PersonaCardUnavailable(label: name(of: id), reason: reason, keepsShownCard: shown != nil)
        }
        guard let source = sources[id], let frozen = source.revision else { throw failure(.unreadable) }
        let url = root.appendingPathComponent(source.persona.image)
        guard let current = PersonaImageRevision(fileAt: url) else { throw failure(.unreadable) }
        guard current == frozen else { throw failure(.changed) }
        guard let needed = Self.decodedBytes(ofImageAt: url, card: source.persona.card != nil) else { throw failure(.unreadable) }
        // Keep what stays useful once this card shows: the shown card until it is
        // replaced, and this card's decoded neighbours, while they all fit.
        let onScreen = Set([shown].compactMap { $0 })
        keep(onScreen.union(neighbours(of: id)))
        if retainedBytes + reserved + needed > budget { keep(onScreen) }
        guard retainedBytes + reserved + needed <= budget else { throw failure(.tooLarge) }
        guard let rendered = render(source.persona),
              let cgImage = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw failure(.unreadable) }
        let bytes = cgImage.bytesPerRow * cgImage.height
        // Decoded rows can be padded beyond the estimate; drop the neighbours once more before refusing.
        if retainedBytes + reserved + bytes > budget { keep(onScreen) }
        guard retainedBytes + reserved + bytes <= budget else { throw failure(.tooLarge) }
        let image = NSImage(cgImage: cgImage, size: rendered.size)
        images[id] = image
        imageBytes[id] = bytes
        return image
    }

    /// Once a card shows, only it and its decoded neighbours stay decoded, and
    /// every other card can be tried again.
    func didShow(_ id: UUID) {
        unavailable.removeAll()
        keep(Set([id] + neighbours(of: id)))
    }

    /// Before another deck replaces this one, keep only the card on screen.
    func release(keeping id: UUID) { keep([id]) }

    /// Library removals take candidates out of the frozen set.
    func keepOnly(_ ids: [UUID]) {
        let allowed = Set(ids)
        order.removeAll { !allowed.contains($0) }
        sources = sources.filter { allowed.contains($0.key) }
        labels = labels.filter { allowed.contains($0.key) }
        keep(allowed)
        unavailable.formIntersection(allowed)
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
    /// an editable card the rendered card as well. Rows are rounded up to 64 bytes,
    /// as decoders usually pad them.
    static func decodedBytes(ofImageAt url: URL, card: Bool) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0 else { return nil }
        func bytes(_ width: Int, _ height: Int) -> Int { (width * 4 + 63) / 64 * 64 * height }
        let scale = min(1, 4096 / max(width, height))
        let decoded = bytes(Int((width * scale).rounded(.up)), Int((height * scale).rounded(.up)))
        let rendered = card ? bytes(Int(PersonaCardRenderer.size.width), Int(PersonaCardRenderer.size.height)) : 0
        return decoded + rendered
    }
}
