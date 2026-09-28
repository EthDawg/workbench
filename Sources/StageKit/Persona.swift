import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

struct SavedPersona: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var image: String
    /// The label and colour Card draws. Circle and Original keep them unused.
    var card: PersonaCardStyle? = nil
    /// Circle, Card or Original, with Circle's framing. Personas saved before the
    /// choice existed have none and keep their look: Card with a card, else Original.
    var appearance: PersonaAppearance? = nil

    /// The look this persona is shown, placed and exported in.
    var effectiveAppearance: PersonaAppearance { appearance ?? PersonaAppearance(shape: card == nil ? .original : .card) }

    func validated() throws -> SavedPersona {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 160 else { throw PersonaError.invalidSettings }
        _ = try PersonaPlacement(image: image).validated()
        _ = try card?.validated()
        _ = try appearance?.validated()
        return self
    }
}

struct PersonaPlacement: Codable, Equatable {
    var image: String
    var x = 0.98
    var y = 0.02
    var width = 0.16

    func validated() throws -> PersonaPlacement {
        guard PersonaStorage.isImageName(image), [x, y, width].allSatisfy(\.isFinite)
        else { throw PersonaError.invalidSettings }
        var result = self
        result.x = min(1, max(0, x)); result.y = min(1, max(0, y))
        result.width = min(0.40, max(0.06, width))
        return result
    }
}

enum PersonaGeometry {
    /// Normalized travel in unflipped AppKit coordinates; the entire card stays
    /// inside the canvas at both ends of each axis, regardless of aspect ratio.
    static func rect(_ placement: PersonaPlacement, imageSize: CGSize, in size: CGSize) -> CGRect {
        guard [size.width, size.height, imageSize.width, imageSize.height].allSatisfy({ $0.isFinite && $0 > 0 })
        else { return .zero }
        let fraction = placement.width.isFinite ? min(0.40, max(0.06, placement.width)) : 0.16
        let longest = max(imageSize.width, imageSize.height)
        let unit = CGSize(width: imageSize.width / longest, height: imageSize.height / longest)
        let scale = min(size.width * fraction / unit.width, size.height * 0.6 / unit.height)
        let width = unit.width * scale, height = unit.height * scale
        let x = placement.x.isFinite ? min(1, max(0, placement.x)) : 0.98
        let y = placement.y.isFinite ? min(1, max(0, placement.y)) : 0.02
        return CGRect(x: max(0, size.width - width) * x, y: max(0, size.height - height) * y,
                      width: width, height: height)
    }
}

enum PersonaError: LocalizedError {
    case invalidSettings, changedOnDisk, unreadableImage, outsidePreparedGroup, alreadyAdded
    var errorDescription: String? {
        switch self {
        case .invalidSettings: return "The saved personas contain unsupported or invalid settings. The original files are unchanged."
        case .changedOnDisk: return "The persona files changed outside this window. Reopen Workbench before saving changes."
        case .unreadableImage: return "This persona image is missing or unreadable. Import the finished image again."
        case .outsidePreparedGroup: return "Choose a persona in the prepared group."
        case .alreadyAdded: return "This persona is already in your library."
        }
    }
}

/// A new editable portrait between choosing its picture and Add persona. It
/// lives only in memory: nothing is written, selected or added to a group until
/// `PersonaLibrary.add(_:)`, so Cancel or Escape at any step leaves the library
/// exactly as it was, with no file behind.
struct PersonaPortraitDraft: Identifiable {
    /// The saved persona's identity, fixed when the picture is chosen, so a
    /// repeated Add can never make a second copy.
    let id: UUID
    /// The library name: the chosen file's name, as for every import.
    let name: String
    /// The chosen picture, normalised to PNG like every import. Add saves these bytes.
    let png: Data
    /// The same picture decoded once, for the editor's preview.
    let portrait: NSImage
    var card: PersonaCardStyle
    /// A new profile portrait starts as a Circle: centred for an imported
    /// picture, or with a bundled starter's curated framing.
    var appearance: PersonaAppearance

    init(_ imported: LogoImport.Image, card: PersonaCardStyle, name: String? = nil, framing: PersonaFraming? = nil) throws {
        guard let portrait = NSImage(data: imported.png), portrait.size.width > 0, portrait.size.height > 0
        else { throw PersonaError.unreadableImage }
        let proposed = (name ?? imported.name).trimmingCharacters(in: .whitespacesAndNewlines)
        id = UUID(); self.name = proposed.isEmpty ? "Persona" : String(proposed.prefix(160))
        png = imported.png; self.portrait = portrait; self.card = card
        appearance = PersonaAppearance(shape: .circle, automaticFraming: framing)
    }

    /// How the draft looks now, for the editor's preview.
    func image() throws -> NSImage { try appearance.image(portrait: portrait, card: card) }
}

struct PersonaGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var personaIDs: [UUID] = []
    var suggestedSceneID: UUID? = nil
    var suggestedLogoID: UUID? = nil
    var overlays: [PersonaOverlayItem]? = nil
    var publicLabel: String? = nil
}

/// Only these deliberately prepared candidates can appear in live controls.
/// Reconciliation can remove candidates, but never adds or reorders them.
struct PersonaLiveSelection: Equatable {
    let groupID: UUID?
    private(set) var candidateIDs: [UUID]
    private(set) var currentID: UUID?
    init(group: PersonaGroup, selectedID: UUID?) {
        groupID = group.id; candidateIDs = group.personaIDs
        currentID = selectedID.flatMap { candidateIDs.contains($0) ? $0 : nil }
    }
    init(personaIDs: [UUID], selectedID: UUID?) {
        groupID = nil; candidateIDs = personaIDs
        currentID = selectedID.flatMap { candidateIDs.contains($0) ? $0 : nil }
    }
    mutating func select(_ id: UUID) {
        guard candidateIDs.contains(id) else { return }
        currentID = id
    }
    mutating func step(_ offset: Int) {
        guard let currentID, let index = candidateIDs.firstIndex(of: currentID), !candidateIDs.isEmpty else { return }
        let destination = (index + offset % candidateIDs.count + candidateIDs.count) % candidateIDs.count
        self.currentID = candidateIDs[destination]
    }
    mutating func reconcile(group: PersonaGroup?, existingIDs: Set<UUID>) {
        let allowed: Set<UUID>
        if let groupID {
            guard let group, group.id == groupID else { candidateIDs = []; currentID = nil; return }
            allowed = Set(group.personaIDs).intersection(existingIDs)
        } else { allowed = existingIDs }
        candidateIDs.removeAll { !allowed.contains($0) }
        if let currentID, !candidateIDs.contains(currentID) { self.currentID = nil }
    }
}

struct PersonaArchive: Codable {
    var version = 2
    var items: [SavedPersona] = []
    var selectedID: UUID?
    var groups: [PersonaGroup] = []
    var activeGroupID: UUID?
    var preparedGroupIDs: [UUID] = []

    init(version: Int = 2, items: [SavedPersona] = [], selectedID: UUID? = nil,
         groups: [PersonaGroup] = [], activeGroupID: UUID? = nil, preparedGroupIDs: [UUID] = []) {
        self.version = version; self.items = items; self.selectedID = selectedID
        self.groups = groups; self.activeGroupID = activeGroupID
        self.preparedGroupIDs = preparedGroupIDs
    }
    private enum CodingKeys: String, CodingKey { case version, items, selectedID, groups, activeGroupID, preparedGroupIDs }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        items = try values.decode([SavedPersona].self, forKey: .items)
        selectedID = try values.decodeIfPresent(UUID.self, forKey: .selectedID)
        groups = try values.decodeIfPresent([PersonaGroup].self, forKey: .groups) ?? []
        activeGroupID = try values.decodeIfPresent(UUID.self, forKey: .activeGroupID)
        preparedGroupIDs = try values.decodeIfPresent([UUID].self, forKey: .preparedGroupIDs) ?? []
    }

    func validated() throws -> PersonaArchive {
        guard [1, 2, 3].contains(version), items.count <= 10_000, groups.count <= 1_000,
              Set(items.map(\.id)).count == items.count,
              Set(items.map(\.image)).count == items.count,
              Set(groups.map(\.id)).count == groups.count,
              selectedID == nil || items.contains(where: { $0.id == selectedID }),
              activeGroupID == nil || groups.contains(where: { $0.id == activeGroupID }),
              version != 1 || (groups.isEmpty && activeGroupID == nil && items.allSatisfy { $0.card == nil && $0.appearance == nil }),
              version == 3 || (preparedGroupIDs.isEmpty && groups.allSatisfy { $0.overlays == nil && $0.publicLabel == nil }),
              preparedGroupIDs.count <= PersonaSessionController.maximumGroups,
              Set(preparedGroupIDs).count == preparedGroupIDs.count,
              Set(preparedGroupIDs).isSubset(of: Set(groups.map(\.id)))
        else { throw PersonaError.invalidSettings }
        _ = try items.map { try $0.validated() }
        let ids = Set(items.map(\.id))
        var result = self
        for (index, group) in groups.enumerated() {
            guard !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  group.name.count <= 160, group.name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  group.personaIDs.count <= 1_000, Set(group.personaIDs).count == group.personaIDs.count,
                  Set(group.personaIDs).isSubset(of: ids) else { throw PersonaError.invalidSettings }
            result.groups[index].publicLabel = try PersonaSessionLabels.validated(group.publicLabel)
            if let overlays = group.overlays {
                guard overlays.count <= PersonaSessionController.maximumOverlays,
                      Set(overlays.map(\.id)).count == overlays.count else { throw PersonaError.invalidSettings }
                result.groups[index].overlays = try overlays.map { try $0.validated(allowed: Set(group.personaIDs)) }
            }
        }
        return result
    }
}

/// Desktop placement is independent of every scene's PersonaPlacement. Visibility
/// is deliberately absent: a previously shown card never reopens at launch.
struct PersonaOverlayState: Codable, Equatable {
    var version = 1
    var x = 0.98
    var y = 0.02
    var width = 0.16
    var screenID: UInt32?
    var locked = false

    func validated() throws -> PersonaOverlayState {
        guard version == 1 else { throw PersonaError.invalidSettings }
        let placement = try PersonaPlacement(image: "persona.png", x: x, y: y, width: width).validated()
        var result = self
        result.x = placement.x; result.y = placement.y; result.width = placement.width
        return result
    }
}

enum PersonaStorage {
    static func isImageName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 255 && !name.hasPrefix(".") &&
        !name.contains("/") && !name.contains("\\") && !name.contains("\0") &&
        name == URL(fileURLWithPath: name).lastPathComponent && name.lowercased().hasSuffix(".png")
    }
    static func read(_ url: URL, maximumBytes: Int = 4 * 1024 * 1024) throws -> Data? {
        let manager = FileManager.default
        // lstat semantics also reject broken symlinks rather than treating them
        // as an absent archive and overwriting them.
        let attributes: [FileAttributeKey: Any]
        do { attributes = try manager.attributesOfItem(atPath: url.path) }
        catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) { return nil }
            throw error
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let count = attributes[.size] as? NSNumber, count.intValue <= maximumBytes
        else { throw PersonaError.invalidSettings }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw PersonaError.invalidSettings }
        return data
    }
    static func write<T: Encodable>(_ value: T, to url: URL, expected: Data?) throws -> Data {
        guard try read(url) == expected else { throw PersonaError.changedOnDisk }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return data
    }
}

/// Like DemoScenes, this UI model is owned and called by StageKit's main-thread
/// coordinator. Keep storage and scene rendering on that same synchronous path.
final class PersonaLibrary: NSObject, ObservableObject {
    let root: URL
    @Published private(set) var items: [SavedPersona] = []
    @Published private(set) var groups: [PersonaGroup] = []
    @Published private(set) var activeGroupID: UUID?
    @Published private(set) var liveSelection: PersonaLiveSelection?
    @Published private(set) var preparedGroupIDs: [UUID] = []
    @Published private(set) var sessionState = PersonaSessionViewState()
    @Published var selectedID: UUID? { didSet { if !applyingArchive { select(previous: oldValue) } } }
    @Published var notice: String?
    /// Live persona keys for help text, set by the shortcut owner.
    @Published var shortcutHint: String?
    @Published private(set) var overlayVisible = false { didSet { updateVoice() } }
    /// React to my voice: a quiet outline around the shown persona that
    /// brightens as the presenter speaks. Off by default and remembered. It
    /// listens only while the persona it frames is showing, measures loudness
    /// and records nothing.
    @Published private(set) var voiceRing = false
    /// The input the ring is listening to; nil whenever the microphone is closed.
    @Published private(set) var voiceDevice: String?
    @Published private(set) var voicePermissionPending = false
    var voiceAvailable: Bool { voiceAccess != nil }
    @Published private(set) var overlayLocked = false
    @Published private(set) var overlayWidth = 0.16
    var usesSharedControls = false { didSet { if usesSharedControls { hud?.hide() } } }
    var onFocusSharedControls: (() -> Void)?
    var onShow: (() -> Void)?
    var mayBeginInteraction: (() -> Bool)?
    private var sessionFeedback: String?
    var selected: SavedPersona? { items.first { $0.id == selectedID } }
    var activeGroup: PersonaGroup? { groups.first { $0.id == activeGroupID } }
    var visibleItems: [SavedPersona] {
        guard let group = activeGroup else { return items }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return group.personaIDs.compactMap { byID[$0] }
    }
    var isReadOnly: Bool { readOnlyReason != nil }
    private var readOnlyReason: String?
    private var libraryData: Data?
    private var overlayData: Data?
    private var overlayState = PersonaOverlayState()
    private var overlay: PersonaOverlayController?
    private var hud: PersonaHUDController?
    private var displayedID: UUID?
    private var displayedImage: NSImage?
    private var displayedLabel: String?
    /// The frozen candidates behind the floating card, and the few decoded images it keeps.
    private(set) var cardDeck: PersonaCardDeck?
    /// The floating card on screen: its copy identity and the frozen source it shows.
    @Published private(set) var shownCard: PersonaShownCard?
    /// Decoded images the floating card may keep, counting a pending replacement.
    /// The same 256 MB as a prepared session; checks lower it.
    var cardImageBudget = PersonaSessionController.maximumImageBytes
    /// Why the last one-card Show, Next, Previous or Choose Persona could not show
    /// its card. It lasts until a card shows or the floating card is hidden.
    private(set) var cardFailure: String?
    /// The one-card failure while it is still the notice, for live controls and the menu panel.
    var cardFeedback: String? { cardFailure.flatMap { $0 == notice ? $0 : nil } }
    private var liveImages: [UUID: NSImage] { cardDeck?.images ?? [:] }
    private var liveLabels: [UUID: String] { cardDeck?.labels ?? [:] }
    private var session: PersonaSessionController?
    private var overlayGeneration = UUID()
    private let sessionPanelFactory: (() -> any PersonaSessionDisplaying)?
    private let sessionHUDEnabled: Bool
    private let voiceAccess: PersonaVoiceAccess?
    private var voice: (any PersonaVoiceSource)?
    private var archiveVersion = 2
    private let imageCache = NSCache<NSString, NSImage>()
    private var applyingArchive = false
    private var libraryURL: URL { root.appendingPathComponent("persona-library.json") }
    private var overlayURL: URL { root.appendingPathComponent("persona-overlay.json") }

    /// Without `voice`, React to my voice is unavailable: no switch, microphone
    /// or saved preference. Only the app's own library passes the system one.
    init(root: URL, readOnlyReason: String? = nil, sessionPanelFactory: (() -> any PersonaSessionDisplaying)? = nil, sessionHUDEnabled: Bool = true,
         voice: PersonaVoiceAccess? = nil) {
        self.root = root; self.readOnlyReason = readOnlyReason
        self.sessionPanelFactory = sessionPanelFactory
        self.sessionHUDEnabled = sessionHUDEnabled
        self.voiceAccess = voice
        self.voiceRing = voice?.savedChoice() ?? false
        super.init()
        imageCache.totalCostLimit = 128 * 1024 * 1024
        applyingArchive = true
        defer { applyingArchive = false }
        do {
            libraryData = try PersonaStorage.read(libraryURL)
            if let libraryData {
                let archive = try JSONDecoder().decode(PersonaArchive.self, from: libraryData).validated()
                items = archive.items; selectedID = archive.selectedID
                groups = archive.groups; activeGroupID = archive.activeGroupID
                preparedGroupIDs = archive.preparedGroupIDs; archiveVersion = max(2, archive.version)
            }
        } catch { self.readOnlyReason = readOnlyReason ?? error.localizedDescription }
        do {
            overlayData = try PersonaStorage.read(overlayURL)
            if let overlayData { overlayState = try JSONDecoder().decode(PersonaOverlayState.self, from: overlayData).validated() }
            overlayWidth = overlayState.width; overlayLocked = overlayState.locked
        } catch { self.readOnlyReason = self.readOnlyReason ?? error.localizedDescription }
        notice = self.readOnlyReason
    }

    func image(named name: String) -> NSImage? {
        guard PersonaStorage.isImageName(name) else { return nil }
        let url = root.appendingPathComponent(name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let count = attributes[.size] as? NSNumber, count.intValue <= LogoImport.maximumBytes,
              let date = attributes[.modificationDate] as? Date else { return nil }
        let key = "\(name)|\(count)|\(date.timeIntervalSince1970)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let data = try? PersonaStorage.read(url, maximumBytes: LogoImport.maximumBytes),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0, width * height <= 50_000_000,
              let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: bitmap, size: CGSize(width: bitmap.width, height: bitmap.height))
        imageCache.setObject(image, forKey: key, cost: bitmap.width * bitmap.height * 4)
        return image
    }

    /// The persona drawn in its appearance: Original is the saved image itself;
    /// Card and Circle are drawn from it and cached, never saved over it.
    func renderedImage(for persona: SavedPersona) -> NSImage? {
        guard (try? persona.validated()) != nil, let image = image(named: persona.image) else { return nil }
        let look = persona.effectiveAppearance
        // Include the file revision: NSCache may evict a portrait and AppKit can
        // later reuse its object address for a different image.
        let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(persona.image).path)
        let revision = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let bytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let key: NSString
        switch look.shape {
        case .original: return image
        case .card:
            let card = persona.card ?? PersonaCardStyle()
            key = "card|\(persona.image)|\(revision)|\(bytes)|\(card.label)|\(card.background.r)|\(card.background.g)|\(card.background.b)" as NSString
        case .circle:
            let framing = look.currentFraming
            key = "circle|\(persona.image)|\(revision)|\(bytes)|\(framing.x)|\(framing.y)|\(framing.zoom)" as NSString
        }
        if let rendered = imageCache.object(forKey: key) { return rendered }
        guard let rendered = try? look.image(portrait: image, card: persona.card),
              let bitmap = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        imageCache.setObject(rendered, forKey: key, cost: bitmap.bytesPerRow * bitmap.height)
        return rendered
    }
    /// A frozen source drawn in another shape for one shown copy: its saved record
    /// as it was frozen, from its image only if the file is unchanged since then.
    func draw(_ source: PersonaSourceSnapshot, as shape: PersonaAppearance.Shape) throws -> NSImage {
        guard let revision = source.revision, PersonaStorage.isImageName(source.persona.image),
              PersonaImageRevision(fileAt: root.appendingPathComponent(source.persona.image)) == revision
        else { throw PersonaSessionError.missingArtwork }
        var persona = source.persona, look = persona.effectiveAppearance
        look.shape = shape; persona.appearance = look
        guard let image = renderedImage(for: persona) else { throw PersonaSessionError.missingArtwork }
        return image
    }
    /// The caller owns any scene/export copy. This never changes the portrait or a scene.
    func renderedPNG(for persona: SavedPersona) throws -> Data {
        _ = try persona.validated()
        guard let image = renderedImage(for: persona) else { throw PersonaError.unreadableImage }
        if persona.effectiveAppearance.shape == .original {
            guard let data = try PersonaStorage.read(root.appendingPathComponent(persona.image), maximumBytes: LogoImport.maximumBytes) else { throw PersonaError.unreadableImage }
            return data
        }
        return try PersonaCardRenderer.png(image)
    }

    /// Import finished card: the image is added at once, unchanged, as its label says.
    func importImage(onSelect: ((SavedPersona) -> Void)? = nil) {
        guard writable() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = LogoImport.contentTypes
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a finished persona image. Existing transparency is preserved."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { let item = try self.addImage(url); onSelect?(item) }
            catch { self.reportImport(error) }
        }
    }

    /// Chooses the picture for a new editable portrait. The picture is only read
    /// here; `add(_:)` saves it when the person chooses Add persona.
    func importPortrait(onDraft: @escaping (PersonaPortraitDraft) -> Void) {
        guard writable() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = LogoImport.contentTypes
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a portrait without baked labels. Workbench keeps the original and shows it as a circle, a labelled card or as it is."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { onDraft(try self.portraitDraft(from: url, card: PersonaCardStyle())) }
            catch { self.reportImport(error) }
        }
    }

    /// Reads a picture into a new portrait draft without writing anything.
    func portraitDraft(from url: URL, card: PersonaCardStyle, name: String? = nil, framing: PersonaFraming? = nil) throws -> PersonaPortraitDraft {
        guard writable() else { throw PersonaError.invalidSettings }
        return try PersonaPortraitDraft(LogoImport.read(url), card: card.validated(), name: name, framing: framing?.validated())
    }

    /// Add persona: saves the draft's picture and card, selects it and adds it to
    /// the active group, together and once. A failure leaves no new file and
    /// changes nothing, so the same draft can be added again.
    @discardableResult func add(_ draft: PersonaPortraitDraft) throws -> SavedPersona {
        guard writable() else { throw PersonaError.invalidSettings }
        guard !items.contains(where: { $0.id == draft.id }) else { throw PersonaError.alreadyAdded }
        return try add(LogoImport.Image(png: draft.png, name: draft.name), id: draft.id, card: draft.card.validated(),
                       appearance: draft.appearance.validated())
    }

    func pasteImage(onSelect: ((SavedPersona) -> Void)? = nil) {
        guard writable() else { return }
        do { let item = try add(LogoImport.read(.general), fallbackName: "Pasted persona"); onSelect?(item) }
        catch { reportImport(error) }
    }

    @discardableResult func addImage(_ url: URL, name: String? = nil, card: PersonaCardStyle? = nil) throws -> SavedPersona {
        try add(LogoImport.read(url), fallbackName: name, card: card)
    }

    private func add(_ imported: LogoImport.Image, fallbackName: String? = nil, id: UUID = UUID(), card: PersonaCardStyle? = nil,
                     appearance: PersonaAppearance? = nil) throws -> SavedPersona {
        guard writable() else { throw PersonaError.invalidSettings }
        let file = "persona-" + UUID().uuidString + ".png"
        let proposedName = (fallbackName ?? imported.name).trimmingCharacters(in: .whitespacesAndNewlines)
        let item = try SavedPersona(id: id, name: proposedName.isEmpty ? "Persona" : String(proposedName.prefix(160)), image: file,
                                    card: card, appearance: appearance).validated()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(file)
        try imported.png.write(to: destination, options: .atomic)
        do {
            var next = archive; next.items.append(item); next.selectedID = item.id
            if let index = next.groups.firstIndex(where: { $0.id == activeGroupID }) { next.groups[index].personaIDs.append(item.id) }
            try commit(next)
        }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        notice = nil
        return item
    }

    func rename(_ id: UUID, name: String) {
        guard writable(), let index = items.firstIndex(where: { $0.id == id }) else { return }
        var changed = items; changed[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try commit(changed, selection: selectedID); notice = nil } catch { notice = error.localizedDescription }
    }

    func remove(_ id: UUID) {
        guard writable() else { return }
        let changed = items.filter { $0.id != id }
        do {
            var next = archive; next.items = changed; next.selectedID = selectedID == id ? nil : selectedID
            for index in next.groups.indices {
                next.groups[index].personaIDs.removeAll { $0 == id }
                next.groups[index].overlays?.removeAll { $0.personaID == id }
            }
            try commit(next)
            // Scenes may still reference this file. Removing a library entry is
            // never permission to delete its image from the shared scene folder.
            notice = "Removed from saved personas. Scenes using the image are unchanged."
        } catch { notice = error.localizedDescription }
    }

    @discardableResult func updateCard(_ id: UUID, style: PersonaCardStyle?) -> Bool {
        guard let persona = items.first(where: { $0.id == id }) else { return false }
        // Keep the look as it is: adding a label to finished artwork must not turn it into a card.
        return updateAppearance(id, appearance: persona.effectiveAppearance, card: style)
    }
    /// The workspace's quick Circle, Card or Original choice for a saved persona.
    /// It is the look used the next time the persona is shown or placed; a card
    /// already shown keeps its own until Update shown card.
    @discardableResult func setShape(_ shape: PersonaAppearance.Shape, for id: UUID) -> Bool {
        guard let persona = items.first(where: { $0.id == id }) else { return false }
        var appearance = persona.effectiveAppearance
        guard appearance.shape != shape else { return true }
        appearance.shape = shape
        return updateAppearance(id, appearance: appearance, card: persona.card)
    }
    /// Saves an appearance with its label and colour together, as the editor's Save does.
    @discardableResult func updateAppearance(_ id: UUID, appearance: PersonaAppearance, card: PersonaCardStyle?) -> Bool {
        guard writable(), let index = items.firstIndex(where: { $0.id == id }) else { return false }
        do {
            var next = archive
            next.items[index].card = try card?.validated()
            next.items[index].appearance = try appearance.validated()
            try commit(next); notice = nil; return true
        } catch { notice = error.localizedDescription; return false }
    }
    @discardableResult func createGroup(name: String, members: [UUID] = []) throws -> UUID {
        guard writable() else { throw PersonaError.invalidSettings }
        let group = PersonaGroup(name: name.trimmingCharacters(in: .whitespacesAndNewlines), personaIDs: members)
        var next = archive; next.groups.append(group); next.activeGroupID = group.id; next.selectedID = members.first
        try commit(next); if session == nil { hideOverlay() }; notice = nil; return group.id
    }
    func renameGroup(_ id: UUID, name: String) {
        guard writable(), let index = groups.firstIndex(where: { $0.id == id }) else { return }
        var next = archive; next.groups[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try commit(next); notice = nil } catch { notice = error.localizedDescription }
    }
    func removeGroup(_ id: UUID) {
        guard writable() else { return }
        var next = archive; next.groups.removeAll { $0.id == id }
        next.preparedGroupIDs.removeAll { $0 == id }
        if activeGroupID == id { next.activeGroupID = nil; next.selectedID = nil }
        do { try commit(next); notice = "Group removed. Its personas, images and scenes are kept." }
        catch { notice = error.localizedDescription }
    }
    func prepareGroup(_ id: UUID?) {
        guard writable(), id == nil || groups.contains(where: { $0.id == id }) else { return }
        var next = archive; next.activeGroupID = id
        next.selectedID = id.flatMap { target in groups.first { $0.id == target }?.personaIDs.first }
        do { try commit(next); if session == nil { hideOverlay() }; notice = nil } catch { notice = error.localizedDescription }
    }
    func setGroupMembers(_ members: [UUID], in id: UUID) {
        guard writable(), let index = groups.firstIndex(where: { $0.id == id }) else { return }
        var next = archive; next.groups[index].personaIDs = members
        next.groups[index].overlays?.removeAll { !members.contains($0.personaID) }
        if activeGroupID == id, let selectedID, !members.contains(selectedID) { next.selectedID = nil }
        do { try commit(next); notice = nil } catch { notice = error.localizedDescription }
    }
    func moveMember(_ id: UUID, by offset: Int) {
        guard let group = activeGroup, let index = group.personaIDs.firstIndex(of: id),
              group.personaIDs.indices.contains(index + offset) else { return }
        var members = group.personaIDs; members.swapAt(index, index + offset)
        setGroupMembers(members, in: group.id)
    }

    func saveGroupLayout(_ id: UUID, overlays: [PersonaOverlayItem], publicLabel: String?, expected: PersonaGroup? = nil) throws {
        guard writable(), let index = groups.firstIndex(where: { $0.id == id }) else { throw PersonaSessionError.missingGroup }
        let current = groups[index]
        if let expected {
            guard expected.id == id, expected.personaIDs == current.personaIDs,
                  expected.overlays == current.overlays, expected.publicLabel == current.publicLabel
            else { throw PersonaSessionError.changedLayout }
        }
        guard overlays.count <= PersonaSessionController.maximumOverlays else { throw PersonaSessionError.tooManyOverlays }
        var next = archive; next.version = 3
        next.groups[index].overlays = try overlays.map { try $0.validated(allowed: Set(current.personaIDs)) }
        next.groups[index].publicLabel = try PersonaSessionLabels.validated(publicLabel)
        try commit(next); notice = nil
    }

    func savePreparedGroups(_ ids: [UUID]) throws {
        guard writable() else { throw PersonaError.invalidSettings }
        var next = archive; next.version = 3; next.preparedGroupIDs = ids
        try commit(next); notice = nil
    }

    /// All images and allowed groups are validated before replacing a live session.
    /// No image files or prepared layouts are written by Start.
    func startOverlaySession(groupIDs: [UUID], initialGroupID: UUID, softReveal: Bool = false) throws {
        guard mayBeginInteraction?() != false else { throw PersonaSessionInteractionError.busy }
        guard !groupIDs.isEmpty, Set(groupIDs).count == groupIDs.count,
              groupIDs.contains(initialGroupID) else { throw PersonaSessionError.missingGroup }
        guard groupIDs.count <= PersonaSessionController.maximumGroups else { throw PersonaSessionError.tooManyOverlays }
        let chosen = try groupIDs.map { id -> PersonaGroup in
            guard let group = groups.first(where: { $0.id == id }) else { throw PersonaSessionError.missingGroup }
            guard let overlays = group.overlays, !overlays.isEmpty else { throw PersonaSessionError.needsSelection }
            return group
        }
        let allowed = Set(chosen.flatMap(\.personaIDs))
        guard allowed.count <= PersonaSessionController.maximumCandidates else { throw PersonaSessionError.tooManyCandidates }
        var frozen: [UUID: NSImage] = [:], sources: [UUID: PersonaSourceSnapshot] = [:], cost = 0
        for id in allowed {
            guard let item = items.first(where: { $0.id == id }), let image = renderedImage(for: item),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw PersonaSessionError.missingArtwork }
            cost += cg.bytesPerRow * cg.height
            guard cost <= PersonaSessionController.maximumImageBytes else { throw PersonaSessionError.tooManyCandidates }
            frozen[id] = NSImage(cgImage: cg, size: image.size)
            // The record and image revision, so a copy's other look is drawn from these same ingredients.
            sources[id] = PersonaSourceSnapshot(persona: item, revision: PersonaImageRevision(fileAt: root.appendingPathComponent(item.image)))
        }
        let snapshots = try chosen.enumerated().map { index, group -> PersonaPreparedSessionGroup in
            let candidates = try group.personaIDs.enumerated().map { ordinal, id -> PersonaSessionCandidate in
                guard let item = items.first(where: { $0.id == id }), let image = frozen[id] else { throw PersonaSessionError.missingArtwork }
                let label = try PersonaSessionLabels.validated(item.card?.label) ?? "Persona \(ordinal + 1)"
                return PersonaSessionCandidate(id: id, label: label, image: image, shape: item.effectiveAppearance.shape, source: sources[id])
            }
            return PersonaPreparedSessionGroup(source: group,
                label: try PersonaSessionLabels.validated(group.publicLabel) ?? "Set \(index + 1)",
                candidates: candidates, overlays: group.overlays ?? [])
        }
        let proposed = try PersonaSessionController(groups: snapshots, initialGroupID: initialGroupID,
            canSave: !isReadOnly, softReveal: softReveal, imageBytes: cost, draw: { [weak self] source, shape in
                guard let self else { throw PersonaSessionError.missingArtwork }
                return try self.draw(source, as: shape)
            }, makePanel: sessionPanelFactory ?? { PersonaOverlayController() })
        // A layout saved with a copy's own look is drawn now, within the budget, or Start fails here.
        try proposed.prepareSavedLooks()
        hideOverlay()
        session = proposed
        proposed.onChange = { [weak self] in self?.refreshSessionState() }
        proposed.setVoiceRing(voiceRing && voiceAccess != nil)
        notice = nil
        onShow?()
        proposed.start()
    }

    func pauseOverlaySession() {
        if let session { session.pause() }
        else { hideOverlay() }
    }
    func resumeOverlaySession() throws {
        guard mayBeginInteraction?() != false else { throw PersonaSessionInteractionError.busy }
        session?.resume()
    }
    func endOverlaySession() {
        overlayGeneration = UUID()
        session?.onChange = nil; session?.end(); session = nil
        sessionFeedback = nil
        sessionState = PersonaSessionViewState(); overlayVisible = false; hud?.hide()
        overlay?.hide(); liveSelection = nil; displayedID = nil
        displayedImage = nil; displayedLabel = nil; cardDeck = nil; shownCard = nil
        clearCardFailure()
    }
    private func reportCardFailure(_ error: Error) {
        notice = error.localizedDescription; cardFailure = notice
    }
    /// A failure notice goes with its card set; any other notice stays.
    private func clearCardFailure() {
        if notice != nil && notice == cardFailure { notice = nil }
        cardFailure = nil
    }
    func saveSessionLayout() throws {
        guard let session, let source = session.currentSource else { throw PersonaSessionError.missingGroup }
        try saveGroupLayout(source.id, overlays: session.currentLayout, publicLabel: source.publicLabel, expected: source)
        if let saved = groups.first(where: { $0.id == source.id }) { session.markSaved(saved) }
    }
    func performOverlayAction(_ action: PersonaSessionAction) {
        guard let session else { return }
        sessionFeedback = nil
        do {
            switch action {
            case .selectGroup(let id):
                guard mayBeginInteraction?() != false else { throw PersonaSessionInteractionError.busy }; try session.selectGroup(id)
            case .stepGroup(let offset):
                guard mayBeginInteraction?() != false else { throw PersonaSessionInteractionError.busy }; try session.stepGroup(offset)
            case .selectInstance(let id): session.selectInstance(id)
            case .add(let id):
                guard mayBeginInteraction?() != false else { throw PersonaSessionInteractionError.busy }; _ = try session.addOverlay(personaID: id)
            case .replace(let instanceID, let personaID):
                guard mayBeginInteraction?() != false else { throw PersonaSessionInteractionError.busy }; try session.replace(instanceID, personaID: personaID)
            case .remove(let id): session.removeOverlay(id)
            case .move(let id, let offset): session.move(id, by: offset)
            case .visible(let id, let value):
                if value && mayBeginInteraction?() == false { throw PersonaSessionInteractionError.busy }
                session.setVisible(value, for: id)
            case .locked(let id, let value): session.setLocked(value, for: id)
            case .width(let id, let value): session.setWidth(value, for: id)
            case .position(let id, let x, let y): session.setPosition(x: x, y: y, for: id)
            case .shape(let id, let shape): try session.setShape(shape, for: id)
            case .pauseResume: if session.phase == .paused { try resumeOverlaySession() } else { pauseOverlaySession() }
            case .saveLayout: try saveSessionLayout(); sessionFeedback = "Layout saved for next time."
            case .dismissFeedback: break
            case .end: endOverlaySession()
            }
        } catch {
            notice = error.localizedDescription
            // The floating surface must never expose a file path or private
            // group name from a storage error. Details stay in preparation.
            if error is PersonaSessionInteractionError {
                sessionFeedback = "Finish recording or keyboard practice first."
            } else if error as? PersonaSessionError == .changedLayout {
                sessionFeedback = "Layout not saved: preparation changed. Review it in Personas."
            } else {
                sessionFeedback = "That change could not be completed. Review it in Personas."
            }
        }
        refreshSessionState()
    }
    private func refreshSessionState() {
        guard let session else { return }
        sessionState = session.state; sessionState.feedback = sessionFeedback
        overlayVisible = session.visibleCount > 0
        if let selected = sessionState.selectedInstance { overlayLocked = selected.locked; overlayWidth = selected.width }
        if sessionState.phase == .idle { endOverlaySession() }
        else { refreshHUD() }
    }

    /// Next and Previous count from the shown card and pass over cards that could
    /// not show while it has been up, so every press moves on when another card can.
    func stepLivePersona(_ offset: Int) {
        guard let shown = displayedID, let target = cardDeck?.step(from: shown, by: offset) else { return }
        selectLivePersona(target)
    }
    /// Decodes the requested frozen card before it replaces the shown one. If it
    /// cannot show, the shown card stays up and the notice names the card.
    func selectLivePersona(_ id: UUID) {
        guard var session = liveSelection, session.candidateIDs.contains(id), let deck = cardDeck else { return }
        // A shape chosen live for this copy stays with it through Next and Previous.
        let copyShape = shownCard?.shape
        let image: NSImage
        do { image = try deck.image(for: id, shown: displayedID, shape: copyShape, render: { renderedImage(for: $0) }) }
        catch { reportCardFailure(error); return }
        if !isReadOnly {
            do { try commit(items, selection: id) }
            catch { notice = error.localizedDescription; return }
        }
        clearCardFailure()
        session.select(id); liveSelection = session; displayedID = id
        deck.didShow(id, shape: copyShape)
        if let source = deck.sources[id] {
            shownCard = PersonaShownCard(copyID: shownCard?.copyID ?? UUID(), source: source, shape: copyShape)
        }
        displayedImage = image; displayedLabel = liveLabels[id]
        overlay?.setOutline(shownCard?.appearance.outline)
        refreshOverlay()
    }
    /// The live copy Persona's Options act on now: the selected copy of a
    /// prepared set, or else the one floating card. nil when nothing is live.
    var selectedLiveCopy: PersonaLiveCopy? {
        if let session { return session.selectedInstanceID.map { .overlay($0, group: session.currentGroupID) } }
        return shownCard.map { .card($0.copyID) }
    }
    /// The look an explicit live copy shows now; nil once that copy is gone.
    func liveShape(of copy: PersonaLiveCopy) -> PersonaAppearance.Shape? {
        switch copy {
        case .card(let id):
            return session == nil && shownCard?.copyID == id ? shownCard?.appearance : nil
        case .overlay(let id, let group):
            guard sessionState.currentGroupID == group else { return nil }
            return sessionState.instances.first { $0.id == id }?.shape
        }
    }
    /// Circle, Card or Original for exactly one live copy, from its Options or the
    /// toolbar. A copy that is no longer live is left alone; no other copy and no
    /// saved persona changes.
    func setLiveShape(_ shape: PersonaAppearance.Shape, for copy: PersonaLiveCopy) {
        switch copy {
        case .card(let id):
            guard session == nil, shownCard?.copyID == id else { return }
            setShownShape(shape)
        case .overlay(let id, let group):
            guard session != nil, sessionState.currentGroupID == group else { return }
            performOverlayAction(.shape(id, shape))
        }
    }
    /// Circle, Card or Original for the one floating card only. It is drawn from
    /// the copy's frozen source, never from later library edits, and it keeps the
    /// artwork's width and centre, moving it only to stay on screen. The lock, the
    /// voice outline and every other copy are unchanged; the saved persona keeps
    /// its own appearance. A hidden card shows the new look when shown again.
    private func setShownShape(_ shape: PersonaAppearance.Shape) {
        guard var card = shownCard, let deck = cardDeck, let id = displayedID, card.appearance != shape else { return }
        let image: NSImage
        do { image = try deck.image(for: id, shown: id, shape: shape, render: { renderedImage(for: $0) }) }
        catch {
            let name = deck.name(of: id)
            notice = "“\(name)” stays as it is: it couldn’t be drawn as \(shape.title). " + ((error as? PersonaCardUnavailable)?.reason == .changed
                ? "Its image changed after you showed this card." : "Its image is missing, unreadable or too large.")
            cardFailure = notice
            return
        }
        clearCardFailure()
        card.shape = shape; shownCard = card
        deck.didShow(id, shape: shape)
        displayedImage = image
        guard let overlay else { return }
        let kept = overlay.reshape(image: image, outline: shape.outline, name: displayedLabel ?? "Floating persona", state: overlayState)
        updateOverlay(kept)
    }
    func focusOverlayControls() {
        guard mayBeginInteraction?() != false else { notice = PersonaSessionInteractionError.busy.localizedDescription; return }
        if usesSharedControls { onFocusSharedControls?() }
        else { hud?.focusControls() }
    }

    /// The main Persona action hides/resumes a prepared arrangement instead of
    /// discarding its frozen cards. The single-card global shortcut below keeps
    /// its existing refusal to replace an active prepared session.
    @discardableResult func togglePersonaVisibility() -> Result<Void, Error> {
        switch sessionState.phase {
        case .active:
            pauseOverlaySession(); return .success(())
        case .paused:
            do { try resumeOverlaySession(); return .success(()) }
            catch { notice = error.localizedDescription; return .failure(error) }
        case .idle:
            if overlayVisible { hideOverlay(); return .success(()) }
            return showOverlay()
        }
    }

    func toggleQuickPersona() {
        guard session == nil else {
            notice = "End the prepared overlay session before showing one floating persona."
            return
        }
        if overlayVisible { hideOverlay() } else { showOverlay() }
    }

    func stepQuickPersona(_ offset: Int) {
        guard session == nil else {
            notice = "Use Previous or Next prepared overlay set during a multi-overlay presentation."
            return
        }
        guard overlayVisible else { showOverlay(); return }
        stepLivePersona(offset)
    }

    /// Dismissed preparation views must receive the failure, because notice is
    /// otherwise visible only when Personas is opened again.
    @discardableResult func showOverlay() -> Result<Void, Error> {
        do { try showOverlayChecked(); return .success(()) }
        catch { reportCardFailure(error); return .failure(error) }
    }
    /// Freezes who can follow this card and how each looks, but decodes only the
    /// requested card: unrelated missing, large or numerous saved items cannot
    /// block it. It replaces any shown overlay only once it has decoded.
    private func showOverlayChecked() throws {
        guard mayBeginInteraction?() != false else { throw PersonaSessionInteractionError.busy }
        let candidateIDs = activeGroup?.personaIDs ?? items.map(\.id)
        guard let initialID = selectedID.flatMap({ candidateIDs.contains($0) ? $0 : nil }) ?? candidateIDs.first
        else { throw PersonaError.unreadableImage }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let deck = PersonaCardDeck(candidates: candidateIDs.compactMap { byID[$0] }, root: root,
                                   budget: cardImageBudget, label: publicLabel(for:))
        // A card already up stays decoded until this one is ready, so it counts too.
        if let shown = displayedID { cardDeck?.release(keeping: shown) }
        let image = try deck.image(for: initialID, shown: nil, reserved: cardDeck?.retainedBytes ?? 0,
                                   render: { renderedImage(for: $0) })
        endOverlaySession()
        liveSelection = activeGroup.map { PersonaLiveSelection(group: $0, selectedID: initialID) }
            ?? PersonaLiveSelection(personaIDs: candidateIDs, selectedID: initialID)
        cardDeck = deck; deck.didShow(initialID)
        shownCard = deck.sources[initialID].map { PersonaShownCard(copyID: UUID(), source: $0) }
        displayedID = initialID
        displayedImage = image; displayedLabel = deck.labels[initialID]
        if overlay == nil {
            overlay = PersonaOverlayController()
            overlay?.onPlacementChange = { [weak self] state in self?.updateOverlay(state) }
        }
        overlay?.setVoiceRing(voiceRing && voiceAccess != nil)
        overlay?.setOutline(shownCard?.appearance.outline)
        let placed = overlay?.show(image: displayedImage ?? image, name: displayedLabel ?? "Floating persona", state: overlayState)
        overlayVisible = true
        if let placed { updateOverlay(placed) }
        refreshHUD()
        onShow?()
    }
    func hideOverlay() { endOverlaySession() }
    func shutdown() {
        hideOverlay(); stopVoice(); overlay?.shutdown(); overlay = nil; hud?.shutdown(); hud = nil; imageCache.removeAllObjects()
    }

    /// Remembered for next time. Turning it on asks macOS for the microphone
    /// at once, while the presenter is preparing, never later in front of an
    /// audience. Turning it off stops the microphone at once.
    func setVoiceRing(_ enabled: Bool) {
        guard let access = voiceAccess else { return }
        if enabled && access.permission() == .denied {
            rememberVoiceRing(false); notice = PersonaVoiceError.microphoneDenied.localizedDescription; return
        }
        rememberVoiceRing(enabled)
    }
    /// A short line under the switch and menu item while the ring is on.
    var voiceStatus: String? {
        guard voiceRing, voiceAccess != nil else { return nil }
        if voicePermissionPending { return "Waiting for microphone access" }
        if let voiceDevice { return "Listening · \(voiceDevice)" }
        return session == nil ? "Listens while a persona shows" : "Listens while the selected overlay shows"
    }
    private func rememberVoiceRing(_ enabled: Bool) {
        voiceRing = enabled
        voiceAccess?.saveChoice(enabled)
        updateVoice()
    }
    /// The one place that decides whether the ring shows and the microphone runs.
    private func updateVoice() {
        guard let access = voiceAccess else { return }
        // A persona being hidden keeps its place until it is gone; the next
        // show sets its ring before placing it.
        if overlayVisible && session == nil { overlay?.setVoiceRing(voiceRing) }
        session?.setVoiceRing(voiceRing)
        guard voiceRing else { stopVoice(); return }
        switch access.permission() {
        case .allowed:
            let framing = session.map { $0.voiceTargetID != nil } ?? overlayVisible
            if framing { startVoice() } else { stopVoice() }
        case .undecided:
            stopVoice(); requestVoicePermission(access)
        case .denied:
            voiceUnavailable(PersonaVoiceError.microphoneDenied.localizedDescription)
        }
    }
    private func requestVoicePermission(_ access: PersonaVoiceAccess) {
        guard !voicePermissionPending else { return }
        voicePermissionPending = true
        access.requestPermission { [weak self] granted in
            guard let self else { return }
            self.voicePermissionPending = false
            if granted { self.updateVoice() }
            else if self.voiceRing { self.voiceUnavailable(PersonaVoiceError.microphoneDenied.localizedDescription) }
        }
    }
    private func startVoice() {
        guard voice == nil, let access = voiceAccess else { return }
        let source = access.makeSource()
        source.onFrames = { [weak self] frames in self?.deliverVoice(frames) }
        source.onUnavailable = { [weak self] reason in self?.voiceUnavailable(reason) }
        source.onDevice = { [weak self] name in self?.voiceDevice = name }
        voice = source
        do { try source.start(); voiceDevice = source.deviceName }
        catch { voiceUnavailable(error.localizedDescription) }
    }
    private func stopVoice() {
        guard let source = voice else { return }
        voice = nil
        source.onFrames = nil; source.onUnavailable = nil; source.onDevice = nil
        source.stop()
        voiceDevice = nil
    }
    private func deliverVoice(_ frames: [PersonaVoiceFrame]) {
        if let session { session.showVoice(frames) } else { overlay?.showVoice(frames) }
    }
    private func voiceUnavailable(_ reason: String) {
        stopVoice(); rememberVoiceRing(false); notice = reason
    }

    func setOverlayLocked(_ locked: Bool) {
        if let session, let id = session.selectedInstanceID { session.setLocked(locked, for: id); return }
        var state = overlayState; state.locked = locked; updateOverlay(state)
    }
    func setOverlayWidth(_ width: Double) {
        guard width.isFinite else { return }
        if let session, let id = session.selectedInstanceID { session.setWidth(width, for: id); return }
        var state = overlayState; state.width = min(0.40, max(0.06, width)); updateOverlay(state)
    }
    func setOverlayPosition(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        if let session, let id = session.selectedInstanceID { session.setPosition(x: x, y: y, for: id); return }
        var state = overlayState; state.x = min(1, max(0, x)); state.y = min(1, max(0, y)); updateOverlay(state)
    }

    private func updateOverlay(_ state: PersonaOverlayState) {
        guard let valid = try? state.validated() else { return }
        overlayState = valid; overlayLocked = valid.locked; overlayWidth = valid.width
        if !isReadOnly {
            do { overlayData = try PersonaStorage.write(valid, to: overlayURL, expected: overlayData) }
            catch { notice = error.localizedDescription }
        }
        refreshOverlay()
    }
    private func refreshOverlay() {
        if session != nil { return }
        guard overlayVisible else { return }
        guard items.contains(where: { $0.id == displayedID }), let image = displayedImage else { hideOverlay(); return }
        overlay?.configure(image: image, name: displayedLabel ?? "Floating persona", state: overlayState)
        refreshHUD()
    }
    private func publicLabel(for persona: SavedPersona) -> String {
        let label = persona.card?.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? "Floating persona" : label
    }
    private func refreshHUD() {
        guard !usesSharedControls else { hud?.hide(); return }
        if let session, session.phase != .idle {
            guard sessionHUDEnabled else { return }
            if hud == nil { hud = PersonaHUDController(root: root, allowsSaving: !isReadOnly) }
            hud?.showSession(viewModel: PersonaSessionHUDModel(state: sessionState,
                perform: { [weak self] in self?.performOverlayAction($0) }), near: session.selectedFrame)
            return
        }
        guard overlayVisible, let current = displayedID else { hud?.hide(); return }
        // Browsing the preparation library never changes a running overlay.
        // Ungrouped artwork gets the same controls, scoped to that one item.
        let candidateIDs = liveSelection?.candidateIDs ?? [current]
        if hud == nil {
            let controls = PersonaHUDController(root: root, allowsSaving: !isReadOnly)
            if let message = controls.notice { notice = message }
            hud = controls
        }
        hud?.onSelect = { [weak self] in self?.selectLivePersona($0) }
        hud?.onStep = { [weak self] in self?.stepLivePersona($0) }
        hud?.onHide = { [weak self] in self?.hideOverlay() }
        hud?.onLock = { [weak self] in self?.setOverlayLocked($0) }
        hud?.onSizeChange = { [weak self] delta in guard let self else { return }; self.setOverlayWidth(self.overlayWidth + delta) }
        hud?.onSetSize = { [weak self] in self?.setOverlayWidth($0) }
        let candidates = candidateIDs.enumerated().compactMap { index, id -> PersonaHUDItem? in
            guard items.contains(where: { $0.id == id }) else { return nil }
            let label = liveLabels[id].flatMap { $0 == "Floating persona" ? nil : $0 } ?? "Persona \(index + 1)"
            return PersonaHUDItem(id: id, label: label, image: liveImages[id])
        }
        hud?.show(items: candidates, selectedID: current, locked: overlayLocked, width: overlayWidth, near: overlay?.window?.frame)
    }
    func makeControlsMenu() -> NSMenu {
        let menu = NSMenu(title: "Persona Overlay"); menu.autoenablesItems = false
        let generation = overlayGeneration
        let groupID = sessionState.currentGroupID
        func action(_ title: String, _ operation: PersonaSessionAction, checked: Bool = false, enabled: Bool = true) -> NSMenuItem {
            StageMenuAction(title, checked: checked, enabled: enabled) { [weak self] in
                guard let self, self.overlayGeneration == generation, self.sessionState.currentGroupID == groupID else { return }
                self.performOverlayAction(operation)
            }
        }
        // One switch for the voice ring in both live menus. Its second line
        // names the microphone while it listens.
        func voiceSwitch() -> NSMenuItem? {
            guard voiceAccess != nil else { return nil }
            let item = StageMenuAction("React to My Voice · Uses Microphone", checked: voiceRing) { [weak self] in
                guard let self, self.overlayGeneration == generation else { return }; self.setVoiceRing(!self.voiceRing)
            }
            if #available(macOS 14.4, *), let status = voiceStatus { item.subtitle = status }
            return item
        }
        if sessionState.phase != .idle {
            let state = sessionState
            if let feedback = state.feedback { menu.addItem(StageMenuAction(feedback, enabled: false) {}) }
            menu.addSubmenu("Choose Set", items: state.groups.map { action($0.label, .selectGroup($0.id), checked: $0.id == state.currentGroupID) })
            menu.addSubmenu("Choose Overlay", items: state.instances.enumerated().map { index, item in
                action("\(index + 1). \(item.label)", .selectInstance(item.id), checked: item.id == state.selectedInstanceID)
            })
            if let selected = state.selectedInstance {
                let size = NSMenuItem(); size.view = PersonaSizeMenuView(width: selected.width) { [weak self] in
                    guard let self, self.overlayGeneration == generation, self.sessionState.currentGroupID == groupID else { return }
                    self.performOverlayAction(.width(selected.id, $0))
                }; menu.addItem(size)
                menu.addItem(action("Lock Artwork · Clicks Pass Through", .locked(selected.id, !selected.locked), checked: selected.locked))
                menu.addSubmenu("Position Artwork", items: FloatingControlAnchor.allCases.map { anchor in
                    action(anchor.title, .position(selected.id, anchor.unitPoint.x, anchor.unitPoint.y))
                })
                // One choice for the selected copy; the current look is checked.
                menu.addSubmenu("Appearance", items: PersonaAppearance.Shape.allCases.map { shape in
                    action(shape.title, .shape(selected.id, shape), checked: shape == selected.shape)
                })
                menu.addSubmenu("Replace Selected", items: state.candidates.map { action($0.label, .replace(instanceID: selected.id, personaID: $0.id), checked: $0.id == selected.personaID) })
                menu.addItem(action(selected.visible ? "Hide Selected" : "Show Selected", .visible(selected.id, !selected.visible)))
                menu.addItem(action("Bring Forward", .move(selected.id, 1)))
                menu.addItem(action("Send Backward", .move(selected.id, -1)))
                menu.addItem(action("Remove Selected", .remove(selected.id)))
            }
            menu.addSubmenu("Add Overlay", items: state.candidates.map { action($0.label, .add($0.id), enabled: state.instances.count < PersonaSessionController.maximumOverlays) })
            menu.addItem(.separator())
            menu.addItem(action(state.phase == .paused ? "Show Again" : "Hide All Temporarily", .pauseResume))
            if let item = voiceSwitch() { menu.addItem(item) }
            menu.addItem(action("Save Layout for Next Time", .saveLayout, enabled: state.canSaveLayout && state.hasUnsavedLayout))
            menu.addItem(action("End Overlays", .end))
        } else if overlayVisible, let current = displayedID {
            // A Next, Previous or choice that could not show says why where it happened.
            if let failure = cardFeedback { menu.addItem(StageMenuAction(failure, enabled: false) {}) }
            let ids = liveSelection?.candidateIDs ?? [current]
            menu.addSubmenu("Choose Persona", items: ids.enumerated().map { index, id in
                StageMenuAction(liveLabels[id].flatMap { $0 == "Floating persona" ? nil : $0 } ?? "Persona \(index + 1)", checked: id == current) { [weak self] in
                    guard let self, self.overlayGeneration == generation else { return }; self.selectLivePersona(id)
                }
            })
            let size = NSMenuItem(); size.view = PersonaSizeMenuView(width: overlayWidth) { [weak self] width in
                guard let self, self.overlayGeneration == generation, self.displayedID == current, self.session == nil else { return }; self.setOverlayWidth(width)
            }; menu.addItem(size)
            menu.addItem(StageMenuAction("Lock Artwork · Clicks Pass Through", checked: overlayLocked) { [weak self] in
                guard let self, self.overlayGeneration == generation, self.displayedID == current, self.session == nil else { return }; self.setOverlayLocked(!self.overlayLocked)
            })
            menu.addSubmenu("Position Artwork", items: FloatingControlAnchor.allCases.map { anchor in
                StageMenuAction(anchor.title) { [weak self] in
                    guard let self, self.overlayGeneration == generation, self.displayedID == current, self.session == nil else { return }
                    self.setOverlayPosition(x: anchor.unitPoint.x, y: anchor.unitPoint.y)
                }
            })
            // This shown copy only, drawn from its frozen source; the current look is checked.
            if let copy = shownCard.map({ PersonaLiveCopy.card($0.copyID) }) {
                menu.addSubmenu("Appearance", items: PersonaAppearance.Shape.allCases.map { shape in
                    StageMenuAction(shape.title, checked: shape == self.liveShape(of: copy)) { [weak self] in
                        guard let self, self.overlayGeneration == generation else { return }
                        self.setLiveShape(shape, for: copy)
                    }
                })
            }
            if let item = voiceSwitch() { menu.addItem(item) }
            menu.addItem(StageMenuAction("End Overlay") { [weak self] in
                guard let self, self.overlayGeneration == generation else { return }; self.hideOverlay()
            })
        } else {
            menu.addItem(StageMenuAction("Show Selected Persona", enabled: !visibleItems.isEmpty) { [weak self] in
                guard let self, self.overlayGeneration == generation else { return }; self.showOverlay()
            })
            let ready = groups.filter { preparedGroupIDs.contains($0.id) && $0.overlays?.isEmpty == false }
            if !ready.isEmpty {
                menu.addSubmenu("Start Prepared Set", items: ready.enumerated().map { index, group in
                    StageMenuAction(group.publicLabel ?? "Set \(index + 1)") { [weak self] in
                        guard let self, self.overlayGeneration == generation else { return }
                        do { try self.startOverlaySession(groupIDs: ready.map(\.id), initialGroupID: group.id) }
                        catch { self.notice = error.localizedDescription }
                    }
                })
            }
            if visibleItems.isEmpty { menu.addItem(StageMenuAction("Prepare a persona in Workbench first.", enabled: false) {}) }
        }
        return menu
    }
    private var archive: PersonaArchive { PersonaArchive(version: archiveVersion, items: items, selectedID: selectedID, groups: groups, activeGroupID: activeGroupID, preparedGroupIDs: preparedGroupIDs) }
    private func commit(_ items: [SavedPersona], selection: UUID?) throws {
        var next = archive; next.items = items; next.selectedID = selection; try commit(next)
    }
    private func commit(_ proposed: PersonaArchive) throws {
        let next = try proposed.validated()
        if next.version == 3, archiveVersion < 3, let libraryData {
            guard try PersonaStorage.read(libraryURL) == libraryData else { throw PersonaError.changedOnDisk }
            let hash = SHA256.hash(data: libraryData).map { String(format: "%02x", $0) }.joined()
            let backup = root.appendingPathComponent("persona-library.before-overlays-\(hash).json")
            if let existing = try PersonaStorage.read(backup) {
                guard existing == libraryData else { throw PersonaError.changedOnDisk }
            } else { try libraryData.write(to: backup, options: .withoutOverwriting) }
            guard try PersonaStorage.read(backup) == libraryData else { throw PersonaError.changedOnDisk }
        }
        libraryData = try PersonaStorage.write(next, to: libraryURL, expected: libraryData)
        applyingArchive = true
        items = next.items; selectedID = next.selectedID; groups = next.groups; activeGroupID = next.activeGroupID
        preparedGroupIDs = next.preparedGroupIDs; archiveVersion = next.version
        applyingArchive = false
        session?.reconcile(availableGroups: groups, existingPersonas: Set(items.map(\.id)))
        if var session = liveSelection {
            session.reconcile(group: activeGroup, existingIDs: Set(items.map(\.id)))
            liveSelection = session
            cardDeck?.keepOnly(session.candidateIDs)
            if session.currentID == nil { hideOverlay() }
        }
        if let displayedID, !items.contains(where: { $0.id == displayedID }) { hideOverlay() }
        refreshOverlay()
    }
    private func select(previous: UUID?) {
        guard selectedID == nil || selected != nil else {
            applyingArchive = true; selectedID = previous; applyingArchive = false; return
        }
        if !isReadOnly {
            do { try commit(items, selection: selectedID) }
            catch {
                applyingArchive = true; selectedID = previous; applyingArchive = false
                notice = error.localizedDescription; return
            }
        }
        refreshOverlay()
    }
    private func writable() -> Bool {
        if let readOnlyReason { notice = readOnlyReason; return false }
        return true
    }
    private func reportImport(_ error: Error) {
        switch error as? LogoImportError {
        case .emptyClipboard: notice = "Copy an image in your browser or an image file in Finder, then paste the persona here."
        case .emptyImage: notice = "This image is completely transparent. Choose a persona with visible artwork."
        case .invalidImage: notice = "Choose a PNG, JPEG, WebP, HEIC, GIF or TIFF persona under 40 MB and 50 megapixels."
        case nil: notice = error.localizedDescription
        }
    }
}
