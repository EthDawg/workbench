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
    case invalidSettings, changedOnDisk, unreadableImage, outsidePreparedGroup, alreadyAdded, libraryUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidSettings: return "The saved personas contain unsupported or invalid settings. The original files are unchanged."
        case .changedOnDisk: return "The persona files changed outside this window. Reopen Workbench before saving changes."
        case .unreadableImage: return "This persona image is missing or unreadable. Import the finished image again."
        case .outsidePreparedGroup: return "Choose a persona in the prepared group."
        case .alreadyAdded: return "This persona is already in your library."
        case .libraryUnavailable: return "The saved personas are missing, unreadable or from a newer Workbench. Reopen Workbench before adding a persona."
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
/// The Persona page's My Profile button: show the photo, or end the Live Camera visit
/// starting or failed beside it.
enum PersonaProfileAction: Equatable { case show, endLiveCamera }

struct PersonaLiveSelection: Equatable {
    let groupID: UUID?
    /// A persona outside the group that joined it for this visit: My Profile shown while a
    /// group without it is prepared. It goes first, as My Profile is first in every menu.
    let guestID: UUID?
    private(set) var candidateIDs: [UUID]
    private(set) var currentID: UUID?
    init(group: PersonaGroup, selectedID: UUID?, guest: UUID? = nil) {
        groupID = group.id
        guestID = guest.flatMap { group.personaIDs.contains($0) ? nil : $0 }
        candidateIDs = (guestID.map { [$0] } ?? []) + group.personaIDs
        currentID = selectedID.flatMap { candidateIDs.contains($0) ? $0 : nil }
    }
    init(personaIDs: [UUID], selectedID: UUID?) {
        groupID = nil; guestID = nil; candidateIDs = personaIDs
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
            allowed = Set(group.personaIDs + (guestID.map { [$0] } ?? [])).intersection(existingIDs)
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

/// What Persona's one floating slot is showing: the saved artwork it has always
/// shown, or this Mac's live camera in a floating bubble. One at a time, and only
/// an explicit start moves between them.
enum PersonaLiveSource: Equatable { case artwork, camera }

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

/// What the Persona workspace names as Shown: the saved persona a live copy
/// shows, its frozen image, and whether it is hidden. The name is the private
/// library name, for preparation only; floating controls use public labels.
struct PersonaShownIdentity {
    let personaID: UUID
    let name: String
    let image: NSImage?
    let hidden: Bool
    /// Which copy, for a prepared set: "Copy 2 of 3 in Set 1".
    let place: String?
}

/// Like DemoScenes, this UI model is owned and called by StageKit's main-thread
/// coordinator. Keep storage and scene rendering on that same synchronous path.
final class PersonaLibrary: NSObject, ObservableObject {
    var onViewImages: (([StageImagePreview], UUID) -> Void)?
    let root: URL
    @Published private(set) var items: [SavedPersona] = []
    @Published private(set) var groups: [PersonaGroup] = []
    @Published private(set) var activeGroupID: UUID?
    @Published private(set) var liveSelection: PersonaLiveSelection?
    @Published private(set) var preparedGroupIDs: [UUID] = []
    @Published private(set) var sessionState = PersonaSessionViewState() {
        didSet {
            if oldValue.currentGroupID != sessionState.currentGroupID || oldValue.phase != sessionState.phase { toolbarCycleRevision = UUID() }
        }
    }
    @Published var selectedID: UUID? { didSet { if !applyingArchive { select(previous: oldValue) } } }
    @Published var notice: String?
    /// Live persona keys for help text, set by the shortcut owner.
    @Published var shortcutHint: String?
    /// Saved artwork on screen: the one floating card, or a prepared set's
    /// visible copies. The camera bubble is a separate source with its own owner.
    @Published private(set) var artworkVisible = false {
        didSet { if oldValue != artworkVisible { toolbarCycleRevision = UUID() }; updateVoice(); publishLiveState() }
    }
    /// Anything Persona is showing now: saved artwork, or the live camera bubble.
    /// Every live door reads this, so it always follows the actual active source.
    @Published private(set) var overlayVisible = false
    /// Which source the one floating slot belongs to. A prepared overlay set is
    /// its own session and keeps the camera out; Camera and the one floating card
    /// replace each other only through an explicit start.
    @Published private(set) var liveSource: PersonaLiveSource = .artwork
    /// Persona's local camera bubble: one session, its own temporary placement,
    /// and no saved artwork, photo or library file of its own.
    let camera: PersonaLiveCamera
    /// React to my voice: a ring of dots around the shown persona that rises
    /// into bars as the presenter speaks. Off by default and remembered. It
    /// listens only while the persona it frames is showing, measures the sound
    /// and records nothing.
    @Published private(set) var voiceRing = false
    /// The ring's colour: mint until the presenter chooses another, and remembered.
    @Published private(set) var voiceColor = PersonaVoiceRingLayer.usualColor
    /// The input the ring is listening to; nil whenever the microphone is closed.
    @Published private(set) var voiceDevice: String?
    @Published private(set) var voicePermissionPending = false
    /// macOS refused the microphone when the switch needed it. The reason stays beside the
    /// switch, with Microphone Settings…, until access changes: Show, Hide and other notices
    /// never take it away, so the switch is never off without saying why.
    @Published private(set) var voiceRefused = false
    /// The last fault that stopped the ring, while it is the notice; turning the switch on
    /// again takes it away, as it does a refusal.
    private var voiceFault: String?
    /// What Next or Previous last said about Live Camera, while it is still the notice: it describes
    /// the camera at that moment, so a change of the camera's state takes it away.
    private var cameraCycleNotice: String?
    private var activation: NSObjectProtocol?
    var voiceAvailable: Bool { voiceAccess != nil }
    /// My Profile: the saved persona the local profile names. The host reads it from its own
    /// preference (`LocalPersonaProfile`), so this library keeps no second record of it.
    var profilePersonaID: (() -> UUID?)? { didSet { objectWillChange.send() } }
    /// Opens the local profile editor, so My Profile… can set a photo where none is saved yet.
    var onEditProfile: (() -> Void)?
    /// My Profile's persona while a profile photo is set and still saved.
    var profileID: UUID? { profilePersonaID?().flatMap { id in items.contains { $0.id == id } ? id : nil } }
    /// The one floating card shows My Profile now.
    var showsProfile: Bool { artworkVisible && session == nil && displayedID != nil && displayedID == profileID }
    /// What the Persona page's My Profile button would do now: nil when it would change nothing
    /// another button there does not, because the photo is up or Show again brings it back.
    /// With the photo up beside a starting or failed Live Camera, it only ends that visit.
    var profileAction: PersonaProfileAction? {
        guard let profile = profileID, session == nil else { return nil }
        guard displayedID == profile else { return .show }
        if artworkVisible { return cameraOwnsSlot ? .endLiveCamera : nil }
        // Show again brings back the photo as it was frozen; retaken since, My Profile shows it as saved now.
        return hasHiddenCard && !shownCardHasNewerLook ? nil : .show
    }
    /// The name a heading gives a saved persona: the local profile reads My Profile, whatever
    /// its saved name (earlier builds saved every profile as "Me"). Nothing is renamed on disk.
    func headingName(for id: UUID?, name: String) -> String { id != nil && id == profileID ? "My Profile" : name }
    /// A library row keeps the persona's own name; the profile's legacy default name reads My Profile.
    func rowName(for id: UUID, name: String) -> String { id == profileID && name == "Me" ? "My Profile" : name }
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
    /// The one floating card's own placement, for checks.
    var cardPlacement: PersonaOverlayState { overlayState }
    private var overlay: PersonaOverlayController?
    private var hud: PersonaHUDController?
    /// The one floating card's persona, derived from its frozen source so there is
    /// one owner of what is shown, never a second record of it.
    private var displayedID: UUID? { shownCard?.source.id }
    /// Its decoded image and public label, which the deck keeps with the card.
    private var displayedImage: NSImage? { displayedID.flatMap { cardDeck?.images[$0] } }
    private var displayedLabel: String? { displayedID.flatMap { cardDeck?.labels[$0] } }
    /// The frozen candidates behind the floating card, and the few decoded images it keeps.
    private(set) var cardDeck: PersonaCardDeck?
    /// The floating card on screen: its copy identity and the frozen source it shows.
    @Published private(set) var shownCard: PersonaShownCard? {
        didSet {
            if oldValue?.source.id != shownCard?.source.id || oldValue?.copyID != shownCard?.copyID { toolbarCycleRevision = UUID() }
        }
    }
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
    private var toolbarCycleRevision = UUID()
    var liveControlsGeneration: UUID { cameraOwnsSlot ? camera.visit : overlayGeneration }
    private let sessionPanelFactory: (() -> any PersonaSessionDisplaying)?
    private let sessionHUDEnabled: Bool
    private var voiceAccess: PersonaVoiceAccess?
    private var voice: (any PersonaVoiceSource)?
    private var archiveVersion = 2
    private let imageCache = NSCache<NSString, NSImage>()
    private var applyingArchive = false
    private var libraryURL: URL { root.appendingPathComponent("persona-library.json") }
    private var overlayURL: URL { root.appendingPathComponent("persona-overlay.json") }

    /// Without `voice`, React to my voice is unavailable: no switch, microphone
    /// or saved preference. Only the app's own library passes the system one.
    init(root: URL, readOnlyReason: String? = nil, sessionPanelFactory: (() -> any PersonaSessionDisplaying)? = nil, sessionHUDEnabled: Bool = true,
         voice: PersonaVoiceAccess? = nil, camera: PersonaLiveCamera? = nil) {
        self.root = root; self.readOnlyReason = readOnlyReason
        self.sessionPanelFactory = sessionPanelFactory
        self.sessionHUDEnabled = sessionHUDEnabled
        self.voiceAccess = voice
        self.voiceRing = voice?.savedChoice() ?? false
        self.voiceColor = voice?.savedColor() ?? PersonaVoiceRingLayer.usualColor
        // Creating the owner opens nothing: it has no session, window or camera
        // until Start camera, so visiting Persona costs no hardware.
        self.camera = camera ?? PersonaLiveCamera()
        super.init()
        self.camera.onChange = { [weak self] in self?.cameraChanged() }
        // Live Camera draws the ring as a card does, in the same colour.
        self.camera.setVoiceColor(voiceColor)
        self.camera.setVoiceRing(voiceRing && voice != nil)
        // Microphone access can change in System Settings, Home or Dictate while Workbench is
        // away; coming back reads it again.
        if voice != nil {
            activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recheckVoiceAccess() }
            }
        }
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
    /// `window` holds the chooser as a sheet, so nothing else in it can start a
    /// second draft while it is open.
    func importPortrait(in window: NSWindow? = nil, onDraft: @escaping (PersonaPortraitDraft) -> Void) {
        guard writable() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = LogoImport.contentTypes
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a portrait without baked labels. Workbench keeps the original and shows it as a circle, a labelled card or as it is."
        let chosen: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { onDraft(try self.portraitDraft(from: url, card: PersonaCardStyle())) }
            catch { self.reportImport(error) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: chosen) } else { panel.begin(completionHandler: chosen) }
    }

    /// Reads a picture into a new portrait draft without writing anything. An
    /// earlier library notice is cleared, so the new editor starts clean.
    func portraitDraft(from url: URL, card: PersonaCardStyle, name: String? = nil, framing: PersonaFraming? = nil) throws -> PersonaPortraitDraft {
        guard writable() else { throw PersonaError.invalidSettings }
        let draft = try PersonaPortraitDraft(LogoImport.read(url), card: card.validated(), name: name, framing: framing?.validated())
        notice = nil
        return draft
    }

    /// A Library image keeps its frozen bytes while the same portrait editor
    /// prepares an independent persona. Nothing is selected or saved here.
    func portraitDraft(imageData: Data, name: String) throws -> PersonaPortraitDraft {
        guard writable() else { throw PersonaError.invalidSettings }
        let image = LogoImport.Image(png: try LogoImport.normalizedPNG(imageData), name: name)
        let draft = try PersonaPortraitDraft(image, card: PersonaCardStyle().validated(), name: name)
        notice = nil
        return draft
    }

    /// Add persona: saves the draft's picture and card, selects it and adds it to
    /// the active group, together and once. If the library changed on disk while
    /// the draft was open, it is read again and the draft is added to it once.
    /// A failure leaves no new file and changes nothing, so the same draft can
    /// be added again.
    @discardableResult func add(_ draft: PersonaPortraitDraft) throws -> SavedPersona {
        guard writable() else { throw PersonaError.invalidSettings }
        guard !items.contains(where: { $0.id == draft.id }) else { throw PersonaError.alreadyAdded }
        let picture = LogoImport.Image(png: draft.png, name: draft.name), card = try draft.card.validated()
        let appearance = try draft.appearance.validated()
        do { return try add(picture, id: draft.id, card: card, appearance: appearance) }
        catch PersonaError.changedOnDisk {
            try reloadArchive()
            guard !items.contains(where: { $0.id == draft.id }) else { throw PersonaError.alreadyAdded }
            return try add(picture, id: draft.id, card: card, appearance: appearance)
        }
    }

    /// Replace one explicitly chosen profile portrait while keeping its identity and groups.
    /// The earlier image stays available to saved scenes and already shown copies. A failed
    /// commit removes only the candidate file; the previous record and artwork stay intact.
    @discardableResult func replacePortrait(_ draft: PersonaPortraitDraft, replacing original: SavedPersona) throws -> SavedPersona {
        guard writable() else { throw PersonaError.invalidSettings }
        guard let index = items.firstIndex(where: { $0.id == original.id }), items[index] == original
        else { throw PersonaError.changedOnDisk }
        let file = "persona-" + UUID().uuidString + ".png"
        var replacement = original
        replacement.image = file; replacement.card = try draft.card.validated()
        replacement.appearance = try draft.appearance.validated()
        _ = try replacement.validated()
        let destination = root.appendingPathComponent(file)
        try draft.png.write(to: destination, options: .atomic)
        do {
            var next = archive; next.items[index] = replacement
            try commit(next)
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
        notice = nil
        return replacement
    }

    /// Reads the library file again after something else changed it, so an Add
    /// applies to what is saved now. Nothing is written. A missing, unreadable,
    /// invalid or newer file stays untouched, the library keeps what it had, and
    /// the Add fails with `.libraryUnavailable`, which trying again cannot fix.
    private func reloadArchive() throws {
        let data: Data, archive: PersonaArchive
        do {
            guard let read = try PersonaStorage.read(libraryURL) else { throw PersonaError.libraryUnavailable }
            data = read
            archive = try JSONDecoder().decode(PersonaArchive.self, from: data).validated()
        } catch { throw PersonaError.libraryUnavailable }
        libraryData = data
        applyingArchive = true
        items = archive.items; selectedID = archive.selectedID; groups = archive.groups
        activeGroupID = archive.activeGroupID; preparedGroupIDs = archive.preparedGroupIDs; archiveVersion = max(2, archive.version)
        applyingArchive = false
        reconcileLive()
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
        try commit(next); notice = nil; return group.id
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
        do { try commit(next); notice = nil } catch { notice = error.localizedDescription }
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
        // Start is explicit, so it takes the slot from a live camera and releases
        // the device. A failure above leaves the camera exactly as it was.
        endCameraForArtwork()
        endOverlaySession()
        session = proposed
        proposed.onChange = { [weak self] in self?.refreshSessionState() }
        proposed.setVoiceColor(voiceColor)
        proposed.setVoiceRing(voiceRing && voiceAccess != nil)
        notice = nil
        onShow?()
        proposed.start()
    }

    func pauseOverlaySession() {
        if let session { session.pause(); clearLiveNotices() }
        else { hideOverlay() }
    }
    func resumeOverlaySession() throws {
        guard mayBeginInteraction?() != false else { throw PersonaSessionInteractionError.busy }
        session?.resume()
        clearLiveNotices()
    }
    func endOverlaySession() {
        overlayGeneration = UUID()
        session?.onChange = nil; session?.end(); session = nil
        sessionFeedback = nil
        sessionState = PersonaSessionViewState(); artworkVisible = false; hud?.hide()
        overlay?.hide(); liveSelection = nil; cardDeck = nil; shownCard = nil
        clearCardFailure()
    }
    /// The shared End door ends only the source its label names. End camera
    /// keeps the card it replaced, so Show again can restore that exact card.
    /// Ending artwork ends its card or set, without changing saved preparation.
    func endLivePersona() {
        if cameraOwnsSlot { endCamera() }
        else { endOverlaySession() }
    }
    private func reportCardFailure(_ error: Error) {
        notice = error.localizedDescription; cardFailure = notice
    }
    /// A failure notice goes with its card set; any other notice stays.
    private func clearCardFailure() {
        if notice != nil && notice == cardFailure { notice = nil }
        cardFailure = nil
    }
    /// Hide and Show start fresh: an earlier failure or informational notice
    /// leaves the panel. A library that cannot be saved keeps saying so.
    private func clearLiveNotices() {
        // A voice fault found by this very show keeps its reason until the switch turns on again,
        // as a refusal does, so the switch is never off without saying why.
        if notice != readOnlyReason && (voiceFault == nil || notice != voiceFault) { notice = nil }
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
            case .update(let id):
                guard mayBeginInteraction?() != false else { throw PersonaSessionInteractionError.busy }
                guard let personaID = session.state.instances.first(where: { $0.id == id })?.personaID,
                      let saved = items.first(where: { $0.id == personaID }) else { break }
                try session.update(id, to: PersonaSourceSnapshot(persona: saved,
                    revision: PersonaImageRevision(fileAt: root.appendingPathComponent(saved.image))))
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
        artworkVisible = session.visibleCount > 0
        if let selected = sessionState.selectedInstance { overlayLocked = selected.locked; overlayWidth = selected.width }
        if sessionState.phase == .idle { endOverlaySession() }
        else { refreshHUD() }
    }

    /// Next and Previous count from the shown card and pass over cards that could
    /// not show while it has been up, so every press moves on when another card can.
    func stepLivePersona(_ offset: Int) {
        guard let shown = displayedID, let deck = cardDeck else { return }
        guard let target = deck.step(from: shown, by: offset) else {
            // Every other card has failed while this one is up: say so, rather than nothing.
            if deck.order.count > 1 { notice = "No other card can show right now."; cardFailure = notice }
            return
        }
        selectLivePersona(target)
    }
    /// Decodes the requested frozen card before it replaces the shown one. If it
    /// cannot show, the shown card stays up and the notice names the card.
    func selectLivePersona(_ id: UUID) {
        guard var session = liveSelection, session.candidateIDs.contains(id), let deck = cardDeck else { return }
        // A shape chosen live for this copy stays with it through Next and Previous.
        let copyShape = shownCard?.shape
        do { _ = try deck.image(for: id, shown: displayedID, shape: copyShape, render: { renderedImage(for: $0) }) }
        catch { reportCardFailure(error); return }
        // My Profile joins a prepared group only for this visit, so it never becomes the group's
        // selection: Show selected after End shows the group's own card, as the page names it.
        if !isReadOnly, session.guestID != id {
            do { try commit(items, selection: id) }
            catch { notice = error.localizedDescription; return }
        }
        clearCardFailure()
        session.select(id); liveSelection = session
        deck.didShow(id, shape: copyShape)
        if let source = deck.sources[id] {
            shownCard = PersonaShownCard(copyID: shownCard?.copyID ?? UUID(), source: source, shape: copyShape)
        }
        overlay?.setOutline(shownCard?.appearance.outline)
        refreshOverlay()
    }
    /// The live copy Persona's Options act on now: the selected copy of a
    /// prepared set, or else the one floating card. nil when nothing is live, and
    /// nil while the camera owns the slot, so live controls never offer a hidden
    /// card's appearance as though it were the source on screen.
    var selectedLiveCopy: PersonaLiveCopy? {
        if let session { return session.selectedInstanceID.map { .overlay($0, group: session.currentGroupID, generation: overlayGeneration) } }
        guard liveSource == .artwork else { return nil }
        return shownCard.map { .card($0.copyID, generation: overlayGeneration) }
    }
    /// The look an explicit live copy shows now; nil once that copy is gone.
    func liveShape(of copy: PersonaLiveCopy) -> PersonaAppearance.Shape? {
        guard copy.generation == overlayGeneration else { return nil }
        switch copy {
        case .card(let id, _):
            return session == nil && shownCard?.copyID == id ? shownCard?.appearance : nil
        case .overlay(let id, let group, _):
            guard sessionState.currentGroupID == group else { return nil }
            return sessionState.instances.first { $0.id == id }?.shape
        }
    }
    /// Whether an explicit live copy is hidden now: the one floating card kept for
    /// Show Again, or a set's copy while the set is hidden or the copy itself is.
    /// nil once that copy is no longer live.
    func liveCopyHidden(_ copy: PersonaLiveCopy) -> Bool? {
        guard copy.generation == overlayGeneration else { return nil }
        switch copy {
        case .card(let id, _):
            return session == nil && shownCard?.copyID == id ? !artworkVisible : nil
        case .overlay(let id, let group, _):
            guard sessionState.currentGroupID == group, let instance = sessionState.instances.first(where: { $0.id == id }) else { return nil }
            return sessionState.phase == .paused || !instance.visible
        }
    }
    /// Circle, Card or Original for exactly one live copy, from its Options or the
    /// toolbar. A copy that is no longer live is left alone; no other copy and no
    /// saved persona changes.
    func setLiveShape(_ shape: PersonaAppearance.Shape, for copy: PersonaLiveCopy) {
        guard copy.generation == overlayGeneration else { return }
        switch copy {
        case .card(let id, _):
            guard session == nil, shownCard?.copyID == id else { return }
            setShownShape(shape)
        case .overlay(let id, let group, _):
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
        // Shown or hidden, the card keeps its centre; a hidden one comes back there.
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
        if let result = toggleCamera() { return result }
        switch sessionState.phase {
        case .active:
            pauseOverlaySession(); return .success(())
        case .paused:
            do { try resumeOverlaySession(); return .success(()) }
            catch { notice = error.localizedDescription; return .failure(error) }
        case .idle:
            if artworkVisible { hideOverlay(); return .success(()) }
            return hasHiddenCard ? showAgain() : showOverlay()
        }
    }

    func toggleQuickPersona() {
        if toggleCamera() != nil { return }
        guard session == nil else {
            notice = "End the prepared overlay session before showing one floating persona."
            return
        }
        if artworkVisible { hideOverlay() } else if hasHiddenCard { showAgain() } else { showOverlay() }
    }
    /// The live camera's own answer to every show/hide door, or nil when the
    /// camera is not the live source and artwork owns the slot. Starting is
    /// cancelled, a showing bubble is hidden, and a hidden or stopped one is
    /// started again, which is always the person pressing something.
    private func toggleCamera() -> Result<Void, Error>? {
        guard liveSource == .camera else { return nil }
        switch camera.state {
        case .off: return nil
        case .permission, .starting: endCamera(); return .success(())
        case .live: hideCamera(); return .success(())
        case .hidden, .failed: return startCamera()
        }
    }

    func stepQuickPersona(_ offset: Int) {
        // Cycling never replaces the live camera: it is not a source choice. The notice says
        // what the camera is doing now, which is not always showing.
        guard !cameraOwnsSlot else {
            let state: String
            switch camera.state {
            case .permission, .starting: state = "Live Camera is starting."
            case .hidden: state = "Live Camera is hidden."
            case .failed: state = "Live Camera stopped."
            case .live, .off: state = "Persona is showing Live Camera."
            }
            notice = state + " End Live Camera, then Next or Previous shows a saved card."
            cardFailure = notice; cameraCycleNotice = notice
            return
        }
        guard session == nil else {
            notice = "Use Previous or Next prepared overlay set during a multi-overlay presentation."
            return
        }
        guard artworkVisible else { if hasHiddenCard { showAgain() } else { showOverlay() }; return }
        stepLivePersona(offset)
    }

    /// Dismissed preparation views must receive the failure, because notice is
    /// otherwise visible only when Personas is opened again.
    @discardableResult func showOverlay() -> Result<Void, Error> {
        do {
            try showOverlayChecked()
            endCameraForArtwork(handingOff: true)
            clearLiveNotices()
            return .success(())
        }
        catch { reportCardFailure(error); return .failure(error) }
    }
    /// Freezes who can follow this card and how each looks, but decodes only the
    /// requested card: unrelated missing, large or numerous saved items cannot
    /// block it. It replaces any shown overlay only once it has decoded.
    /// `requested` shows that persona, such as My Profile, in place of the preparation
    /// selection; outside the prepared group it joins the group for this visit, first, so
    /// Next and Previous still go through the group and nothing else.
    private func showOverlayChecked(showing requested: UUID? = nil) throws {
        guard mayBeginInteraction?() != false else { throw PersonaSessionInteractionError.busy }
        // Showing saved artwork is an explicit source choice, so it ends a live
        // camera and says so. A failure below leaves the camera running.
        if hasHiddenCard, !cameraOwnsSlot { endOverlaySession() }
        let group = activeGroup
        let guest = requested.flatMap { id in group.map { $0.personaIDs.contains(id) } == false ? id : nil }
        let candidateIDs = group.map { (guest.map { [$0] } ?? []) + $0.personaIDs } ?? items.map(\.id)
        guard let initialID = (requested ?? selectedID).flatMap({ candidateIDs.contains($0) ? $0 : nil }) ?? candidateIDs.first
        else { throw PersonaError.unreadableImage }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let deck = PersonaCardDeck(candidates: candidateIDs.compactMap { byID[$0] }, root: root,
                                   budget: cardImageBudget, label: publicLabel(for:))
        // A card already up stays decoded until this one is ready, so it counts too.
        if let shown = displayedID { cardDeck?.release(keeping: shown) }
        let image = try deck.image(for: initialID, shown: nil, reserved: cardDeck?.retainedBytes ?? 0,
                                   render: { renderedImage(for: $0) })
        endOverlaySession()
        liveSelection = group.map { PersonaLiveSelection(group: $0, selectedID: initialID, guest: guest) }
            ?? PersonaLiveSelection(personaIDs: candidateIDs, selectedID: initialID)
        cardDeck = deck; deck.didShow(initialID)
        shownCard = deck.sources[initialID].map { PersonaShownCard(copyID: UUID(), source: $0) }
        present(image)
    }
    /// Puts the card on screen with its voice outline, edge and placement.
    /// Replacing Live Camera on screen, the card takes the bubble's place and size, keeps its
    /// own lock, and fades in over the bubble, which stays whole until covered and then goes.
    private func present(_ image: NSImage) {
        if overlay == nil {
            overlay = PersonaOverlayController(persistentLockedHandle: true)
            overlay?.onPlacementChange = { [weak self] state in self?.updateOverlay(state) }
        }
        let replacingCamera = cameraOwnsSlot && camera.isLive
        if replacingCamera {
            var next = overlayState
            next.x = camera.placement.x; next.y = camera.placement.y
            next.width = camera.placement.width; next.screenID = camera.placement.screenID
            if let valid = try? next.validated() { overlayState = valid }
        }
        overlay?.setVoiceColor(voiceColor)
        overlay?.setVoiceRing(voiceRing && voiceAccess != nil)
        overlay?.setOutline(shownCard?.appearance.outline)
        let placed = overlay?.show(image: image, name: displayedLabel ?? "Floating persona", state: overlayState, animated: replacingCamera)
        artworkVisible = true
        if let placed { updateOverlay(placed) }
        refreshHUD()
        onShow?()
    }
    /// Hide. A prepared set ends, as before. The one floating card leaves the
    /// screen but stays this session's card, so Show again brings back the same
    /// card, look, size and place, whatever preparation selects meanwhile. Its
    /// microphone stops while it is hidden. End overlay or Quit releases it.
    func hideOverlay() {
        // Hide always acts on the source that is actually showing.
        if cameraOwnsSlot { hideCamera(); return }
        hideArtwork()
    }
    /// The workspace's artwork command remains usable while a separate camera
    /// request is pending or has failed and left the shown card in place.
    func hideArtwork() {
        guard session == nil else { endOverlaySession(); clearLiveNotices(); return }
        guard artworkVisible else { return }
        overlay?.hide(); hud?.hide()
        artworkVisible = false
        if !cameraOwnsSlot { clearLiveNotices() }
    }
    /// A floating card hidden with Hide, kept for Show again. A card the camera
    /// took the slot from is kept the same way, and End camera brings it back
    /// within reach of Show again.
    var hasHiddenCard: Bool { session == nil && !artworkVisible && shownCard != nil }
    /// Show again: the hidden card exactly as it was, not the preparation selection.
    @discardableResult func showAgain() -> Result<Void, Error> {
        guard hasHiddenCard else { return showOverlay() }
        guard mayBeginInteraction?() != false else {
            let error = PersonaSessionInteractionError.busy
            notice = error.localizedDescription; return .failure(error)
        }
        guard let image = displayedImage else { endOverlaySession(); return showOverlay() }
        present(image)
        endCameraForArtwork(handingOff: true)
        clearLiveNotices()
        return .success(())
    }
    /// My Profile: the profile photo as the one floating card, as it is saved now, so a photo
    /// retaken since the deck began shows the new one. A shown card's deck keeps the photo
    /// when it holds it, so Next and Previous carry on from it; otherwise the photo starts a
    /// deck of the prepared group, joining it first when the group lacks it, or of all saved
    /// personas. It takes the slot's place, ends Live Camera with a crossfade and opens no
    /// camera. A prepared set keeps the slot.
    @discardableResult func showProfile() -> Result<Void, Error> {
        guard let profile = profileID else {
            let error = PersonaProfileRefusal.noProfile
            reportCardFailure(error); return .failure(error)
        }
        guard session == nil else {
            let error = PersonaProfileRefusal.preparedSession
            notice = error.localizedDescription; cardFailure = notice
            return .failure(error)
        }
        if shownCard != nil, let deck = cardDeck, liveSelection?.candidateIDs.contains(profile) == true {
            if displayedID == profile {
                if shownCardHasNewerLook, case .failure(let error) = updateShownCard() { return .failure(error) }
            } else {
                if let frozen = deck.sources[profile]?.persona, let saved = newerSaved(than: frozen) {
                    do { _ = try deck.refresh(saved, label: publicLabel(for: saved), shown: displayedID, render: { renderedImage(for: $0) }) }
                    catch { reportCardFailure(error); return .failure(error) }
                }
                selectLivePersona(profile)
                guard displayedID == profile else { return .failure(PersonaError.unreadableImage) }
            }
            if hasHiddenCard { return showAgain() }
            // The photo is already up while Live Camera waits for access, starts or has failed:
            // choosing My Profile still ends that visit, so a late frame cannot replace it.
            endCameraForArtwork(handingOff: true)
            clearLiveNotices()
            return .success(())
        }
        do {
            try showOverlayChecked(showing: profile)
            endCameraForArtwork(handingOff: true)
            clearLiveNotices()
            return .success(())
        } catch { reportCardFailure(error); return .failure(error) }
    }
    func shutdown() {
        if let activation { NotificationCenter.default.removeObserver(activation); self.activation = nil }
        camera.shutdown()
        endOverlaySession(); stopVoice(); overlay?.shutdown(); overlay = nil; hud?.shutdown(); hud = nil; imageCache.removeAllObjects()
    }

    // MARK: The live camera source

    /// Whether the camera is the source on screen or kept for Show camera again.
    var cameraOwnsSlot: Bool { liveSource == .camera && camera.isActive }
    /// A prepared overlay set is running or paused, so it owns the slot and its device.
    var hasPreparedSession: Bool { sessionState.phase != .idle }
    /// Start camera, the explicit start of Persona's local camera bubble. Nothing
    /// before this reaches the hardware. A prepared overlay set keeps the slot,
    /// and its device, to itself. Any shown card stays exactly as it is until a
    /// real picture arrives, so a refused permission or a camera that never
    /// starts leaves the artwork untouched.
    @discardableResult func startCamera(deviceID: String? = nil) -> Result<Void, Error> {
        guard session == nil else {
            let message = "End the prepared overlay set before starting Live Camera."
            notice = message; cardFailure = message
            return .failure(PersonaCameraRefusal.preparedSession)
        }
        guard mayBeginInteraction?() != false else {
            let error = PersonaSessionInteractionError.busy
            notice = error.localizedDescription; cardFailure = notice
            return .failure(error)
        }
        clearCardFailure()
        liveSource = .camera
        // Switching from a card on screen: the bubble takes its place and size, read when the
        // first frame arrives, so a card moved while the camera starts is followed.
        let replacing: (() -> PersonaOverlayState?)? = session == nil && artworkVisible ? { [weak self] in
            guard let self, self.session == nil, self.artworkVisible else { return nil }
            return self.overlayState
        } : nil
        camera.start(deviceID: deviceID, replacing: replacing)
        return .success(())
    }
    /// Show camera again: the same camera, back in the bubble's kept place. It is
    /// a start, so it asks the hardware again rather than resuming a held device.
    @discardableResult func showCameraAgain() -> Result<Void, Error> { startCamera() }
    /// Try again after a failure, on the same camera.
    @discardableResult func retryCamera() -> Result<Void, Error> { startCamera(deviceID: camera.preparedID ?? camera.selectedID) }
    /// Hide camera: the device is released at once and the bubble's place is kept.
    func hideCamera() {
        guard camera.isActive else { return }
        camera.hide()
        clearLiveNotices()
    }
    /// End camera: the device and the bubble go. Saved personas, a hidden card and
    /// a paused set are untouched, and their own Show again and Resume bring them
    /// back. It ends no presentation and deletes nothing.
    func endCamera() {
        guard camera.isActive || liveSource == .camera else { return }
        camera.end()
        liveSource = .artwork
        publishLiveState()
        clearLiveNotices()
    }
    /// Saved artwork has just taken the slot: the camera is released without
    /// disturbing the artwork that is now showing.
    /// `handingOff`: a card has just been shown in the bubble's place, fading in on top; the
    /// bubble stays whole beneath it until covered, then goes, and only then is the camera
    /// released. A prepared set starting elsewhere releases it at once.
    private func endCameraForArtwork(handingOff: Bool = false) {
        guard liveSource == .camera else { return }
        let wasLive = camera.isActive
        camera.end(handingOff: handingOff && camera.isLive)
        liveSource = .artwork
        publishLiveState()
        if wasLive { notice = "Live Camera ended. Showing your saved artwork." }
    }
    /// The camera's state changed: the one live slot follows it, the artwork it
    /// replaced is kept for Show again, and every door reads the new source.
    private func cameraChanged() {
        // Next or Previous described the camera as it was; another notice raised since stays.
        if let cycle = cameraCycleNotice {
            cameraCycleNotice = nil
            if notice == cycle && cardFailure == cycle { notice = nil; cardFailure = nil }
        }
        if camera.isLive, artworkVisible {
            // The bubble is up, fading in over the card, which stays whole beneath it until it is
            // covered and is kept for Show again.
            if session != nil { pauseOverlaySession() }
            else { overlay?.hide(steppingAside: true); hud?.hide(); artworkVisible = false }
        }
        if case .failed(let failure) = camera.state {
            notice = failure.message; cardFailure = notice
        }
        if camera.state == .off, liveSource == .camera { liveSource = .artwork }
        publishLiveState()
        // The bubble showing, hiding or ending opens or closes the ring's microphone.
        updateVoice()
        objectWillChange.send()
    }
    /// One place decides what Persona is showing and whose size, lock and place
    /// the live controls change.
    private func publishLiveState() {
        let showing = artworkVisible || camera.isLive
        if overlayVisible != showing { overlayVisible = showing }
        publishPlacement()
    }
    /// The live placement controls belong to whichever source is live.
    private func publishPlacement() {
        if cameraOwnsSlot {
            overlayWidth = camera.placement.width; overlayLocked = camera.placement.locked
        } else if session == nil {
            overlayWidth = overlayState.width; overlayLocked = overlayState.locked
        }
    }

    /// The live copy the workspace labels Shown, beside its live controls: the one
    /// floating card, shown or hidden, or a prepared set's selected copy.
    var shownIdentity: PersonaShownIdentity? {
        if session != nil {
            guard let instance = sessionState.selectedInstance else { return nil }
            let name = items.first { $0.id == instance.personaID }?.name ?? instance.label
            let index = (sessionState.instances.firstIndex { $0.id == instance.id } ?? 0) + 1
            let set = sessionState.groups.first { $0.id == sessionState.currentGroupID }?.label ?? "this set"
            return PersonaShownIdentity(personaID: instance.personaID, name: name, image: instance.image,
                                        hidden: sessionState.phase == .paused || !instance.visible,
                                        place: "Copy \(index) of \(sessionState.instances.count) in \(set)")
        }
        guard let card = shownCard else { return nil }
        let name = items.first { $0.id == card.source.id }?.name ?? card.source.persona.name
        return PersonaShownIdentity(personaID: card.source.id, name: name, image: displayedImage, hidden: !artworkVisible, place: nil)
    }
    /// The persona Replace shown would bring in: the preparation selection, when
    /// it is not already the shown card. For a prepared set, only a persona that
    /// set can show, for its selected copy.
    var replacementForShown: SavedPersona? {
        guard let selected else { return nil }
        if session != nil {
            guard let instance = sessionState.selectedInstance, instance.personaID != selected.id,
                  sessionState.candidates.contains(where: { $0.id == selected.id }) else { return nil }
            return selected
        }
        guard let shown = displayedID, shown != selected.id else { return nil }
        return selected
    }
    /// Replace shown with the selected persona. The same copy, with its size,
    /// place and lock, shows the selected persona as it is saved; for the one
    /// floating card, Next and Previous then follow that persona's group, or all
    /// saved personas. A hidden card stays hidden until Show again. If the new
    /// persona cannot show, the shown card stays as it was and the notice says why.
    @discardableResult func replaceShownWithSelected() -> Result<Void, Error> {
        guard let replacement = replacementForShown else { return .success(()) }
        if session != nil, let instance = sessionState.selectedInstance {
            performOverlayAction(.replace(instanceID: instance.id, personaID: replacement.id))
            return .success(())
        }
        do { try replaceCard(with: replacement); return .success(()) }
        catch { reportCardFailure(error); return .failure(error) }
    }
    private func replaceCard(with replacement: SavedPersona) throws {
        guard mayBeginInteraction?() != false else { throw PersonaSessionInteractionError.busy }
        guard let card = shownCard else { return }
        let groupIDs = activeGroup?.personaIDs ?? items.map(\.id)
        let candidateIDs = groupIDs.contains(replacement.id) ? groupIDs : [replacement.id]
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let deck = PersonaCardDeck(candidates: candidateIDs.compactMap { byID[$0] }, root: root,
                                   budget: cardImageBudget, label: publicLabel(for:))
        // The shown card stays decoded, and counted, until the replacement is ready.
        cardDeck?.release(keeping: card.source.id)
        let image = try deck.image(for: replacement.id, shown: nil, reserved: cardDeck?.retainedBytes ?? 0,
                                   render: { renderedImage(for: $0) })
        guard let source = deck.sources[replacement.id] else { return }
        clearCardFailure()
        liveSelection = activeGroup.flatMap { groupIDs.contains(replacement.id) ? PersonaLiveSelection(group: $0, selectedID: replacement.id) : nil }
            ?? PersonaLiveSelection(personaIDs: candidateIDs, selectedID: replacement.id)
        cardDeck = deck; deck.didShow(replacement.id)
        shownCard = PersonaShownCard(copyID: card.copyID, source: source)
        showInPlace(image)
    }
    /// Whether the shown card's persona was saved with another look since it was
    /// shown: another shape, framing, label, colour or picture. For a prepared
    /// set, the selected copy's persona.
    var shownCardHasNewerLook: Bool {
        let frozen: SavedPersona?
        if session != nil {
            frozen = sessionState.selectedInstance.flatMap { session?.source(of: $0.id)?.persona }
        } else { frozen = shownCard?.source.persona }
        guard let frozen else { return false }
        return newerSaved(than: frozen) != nil
    }
    /// The persona as it is saved now, when that differs from the look frozen into a deck.
    private func newerSaved(than frozen: SavedPersona) -> SavedPersona? {
        guard let saved = items.first(where: { $0.id == frozen.id }) else { return nil }
        let newer = frozen.image != saved.image || frozen.card != saved.card || frozen.effectiveAppearance != saved.effectiveAppearance
        return newer ? saved : nil
    }
    /// Update shown card: the shown copy shows its persona as it is saved now,
    /// keeping its size, place and lock. Only that copy changes, and a hidden card
    /// stays hidden. If the saved look cannot show, the copy stays as it was.
    @discardableResult func updateShownCard() -> Result<Void, Error> {
        guard shownCardHasNewerLook else { return .success(()) }
        if session != nil, let instance = sessionState.selectedInstance {
            performOverlayAction(.update(instance.id)); return .success(())
        }
        guard let card = shownCard, let deck = cardDeck, let saved = items.first(where: { $0.id == card.source.id }) else { return .success(()) }
        do {
            guard mayBeginInteraction?() != false else { throw PersonaSessionInteractionError.busy }
            let image = try deck.refresh(saved, label: publicLabel(for: saved), shown: saved.id, render: { renderedImage(for: $0) })
            guard let source = deck.sources[saved.id] else { return .success(()) }
            clearCardFailure()
            shownCard = PersonaShownCard(copyID: card.copyID, source: source)
            deck.didShow(saved.id)
            showInPlace(image)
            return .success(())
        } catch { reportCardFailure(error); return .failure(error) }
    }
    /// New artwork for the same copy, keeping its width and centre; a hidden card
    /// comes back there with Show again.
    private func showInPlace(_ image: NSImage) {
        guard let overlay else { return }
        let kept = overlay.reshape(image: image, outline: shownCard?.appearance.outline,
                                   name: displayedLabel ?? "Floating persona", state: overlayState)
        updateOverlay(kept)
    }

    /// Remembered for next time. Turning it on asks macOS for the microphone
    /// at once, while the presenter is preparing, never later in front of an
    /// audience. Turning it off stops the microphone at once.
    func setVoiceRing(_ enabled: Bool) {
        guard let access = voiceAccess else { return }
        if enabled && access.permission() == .denied {
            rememberVoiceRing(false); voiceRefused = true
            notice = PersonaVoiceError.microphoneDenied.localizedDescription; return
        }
        // Allowed since: the refusal and its door leave with the switch turning on, and so does
        // an earlier fault's reason.
        if enabled, voiceRefused { clearVoiceRefusal() }
        if enabled, let fault = voiceFault { voiceFault = nil; if notice == fault { notice = nil } }
        rememberVoiceRing(enabled)
        // The one place macOS is asked: switching it on, while preparing. Showing a card or
        // starting Live Camera never asks, so no prompt appears in front of an audience.
        if enabled, access.permission() == .undecided { requestVoicePermission(access) }
    }
    /// The ring's colour, remembered for next time. Changing it never opens
    /// or closes the microphone.
    func setVoiceColor(_ color: InkColor) {
        guard voiceAccess != nil, color != voiceColor else { return }
        voiceColor = color
        voiceAccess?.saveColor(color)
        overlay?.setVoiceColor(color); session?.setVoiceColor(color); camera.setVoiceColor(color)
    }
    /// macOS's shared colour picker for a ring colour outside the presets.
    private(set) lazy var voiceColourPicker = PersonaVoiceColourPicker(library: self)
    /// A short line under the switch and menu item while the ring is on.
    var voiceStatus: String? {
        guard voiceRing, let access = voiceAccess else { return nil }
        if voicePermissionPending { return "Waiting for microphone access" }
        switch access.permission() {
        case .undecided: return "Microphone not allowed yet"
        case .denied: return "Microphone access is off"
        case .allowed: break
        }
        if let voiceDevice { return "Listening · \(voiceDevice)" }
        return session == nil ? "Listens while a persona or Live Camera shows" : "Listens while the selected overlay shows"
    }
    /// Allow Microphone…: shown beside the status while the switch is on and macOS has not
    /// been asked, as after a permission reset. The presenter's click is the question.
    var voiceNeedsAllowing: Bool { voiceRing && !voicePermissionPending && voiceAccess?.permission() == .undecided }
    func allowMicrophone() {
        guard voiceNeedsAllowing, let access = voiceAccess else { return }
        requestVoicePermission(access)
    }
    /// The microphone refusal: the switch stays off and the reason shows beside it with
    /// Microphone Settings…, on the page and in the live menus (#134 Fit rule 2).
    var voiceRefusal: String? {
        guard voiceAccess != nil, voiceRefused else { return nil }
        return PersonaVoiceError.microphoneDenied.localizedDescription
    }
    private func clearVoiceRefusal() {
        voiceRefused = false
        if notice == PersonaVoiceError.microphoneDenied.localizedDescription { notice = nil }
    }
    /// Reads microphone access again, on coming back to Workbench and when a live menu opens.
    /// Allowed since a refusal, the switch comes back on, as the presenter asked; refused
    /// while on, it turns off and says why.
    func recheckVoiceAccess() {
        guard let access = voiceAccess else { return }
        if voiceRefused, access.permission() != .denied {
            clearVoiceRefusal()
            if access.permission() == .allowed { rememberVoiceRing(true); return }
        }
        updateVoice()
    }
    /// Microphone Settings…: opens Privacy & Security › Microphone, as Dictate's does.
    func openMicrophoneSettings() { voiceAccess?.openMicrophoneSettings() }
    /// Swaps the microphone access for renders and checks. The ring stops and turns off first,
    /// so no real microphone outlives its owner; the earlier access comes back the same way.
    func replaceVoiceAccess(_ access: PersonaVoiceAccess?) -> PersonaVoiceAccess? {
        let previous = voiceAccess
        stopVoice(); voiceRing = false; voicePermissionPending = false
        clearVoiceRefusal()
        voiceAccess = access
        return previous
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
        if artworkVisible && session == nil { overlay?.setVoiceRing(voiceRing) }
        // Live Camera's bubble carries the ring too; its owner keeps it while hidden.
        camera.setVoiceRing(voiceRing)
        session?.setVoiceRing(voiceRing)
        guard voiceRing else { stopVoice(); return }
        switch access.permission() {
        case .allowed:
            // The ring listens only while the persona it frames shows: a prepared set's
            // selected overlay, the one floating card, or Live Camera's bubble.
            let framing = session.map { $0.voiceTargetID != nil } ?? (artworkVisible || (cameraOwnsSlot && camera.isLive))
            if framing { startVoice() } else { stopVoice() }
        case .undecided:
            // Only switching it on asks; until then the microphone stays closed and the
            // status line says how to allow it.
            stopVoice()
        case .denied:
            voiceUnavailable(PersonaVoiceError.microphoneDenied.localizedDescription, refused: true)
        }
    }
    private func requestVoicePermission(_ access: PersonaVoiceAccess) {
        guard !voicePermissionPending else { return }
        voicePermissionPending = true
        access.requestPermission { [weak self] granted in
            guard let self else { return }
            self.voicePermissionPending = false
            if granted { self.updateVoice() }
            else if self.voiceRing { self.voiceUnavailable(PersonaVoiceError.microphoneDenied.localizedDescription, refused: true) }
        }
    }
    private func startVoice() {
        guard voice == nil, let access = voiceAccess else { return }
        let source = access.makeSource()
        source.onFrames = { [weak self] frames in self?.deliverVoice(frames) }
        // A lost input or an engine that cannot restart, as when a Continuity Camera iPhone
        // becomes the input, is a fault, not a refusal.
        source.onUnavailable = { [weak self] reason in self?.voiceUnavailable(reason, refused: false) }
        source.onDevice = { [weak self] name in self?.voiceDevice = name }
        voice = source
        do { try source.start(); voiceDevice = source.deviceName }
        catch {
            let refused: Bool
            if case .microphoneDenied? = error as? PersonaVoiceError { refused = true } else { refused = false }
            voiceUnavailable(error.localizedDescription, refused: refused)
        }
    }
    private func stopVoice() {
        guard let source = voice else { return }
        voice = nil
        source.onFrames = nil; source.onUnavailable = nil; source.onDevice = nil
        source.stop()
        voiceDevice = nil
    }
    private func deliverVoice(_ frames: [PersonaVoiceFrame]) {
        if let session { session.showVoice(frames) }
        else if cameraOwnsSlot && camera.isLive { camera.showVoice(frames) }
        else { overlay?.showVoice(frames) }
    }
    /// The ring stops with the reason. A refusal turns the switch off and is remembered; a
    /// fault turns it off for now and keeps the saved choice, so it is on again next time.
    private func voiceUnavailable(_ reason: String, refused: Bool) {
        stopVoice()
        if refused { rememberVoiceRing(false); voiceRefused = true } else { voiceRing = false; updateVoice(); voiceFault = reason }
        notice = reason
    }

    /// Size, Position and Lock act on the live source, so the camera bubble's
    /// temporary placement is never written over saved artwork's own, and saved
    /// artwork is never silently unlocked by a change to the bubble.
    func setOverlayLocked(_ locked: Bool) {
        if cameraOwnsSlot { camera.setLocked(locked); return }
        if let session, let id = session.selectedInstanceID { session.setLocked(locked, for: id); return }
        var state = overlayState; state.locked = locked; updateOverlay(state)
    }
    func setOverlayWidth(_ width: Double) {
        guard width.isFinite else { return }
        if cameraOwnsSlot { camera.setWidth(width); return }
        if let session, let id = session.selectedInstanceID { session.setWidth(width, for: id); return }
        var state = overlayState; state.width = min(0.40, max(0.06, width)); updateOverlay(state)
    }
    func setOverlayPosition(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        if cameraOwnsSlot { camera.setPosition(x: x, y: y); return }
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
        guard artworkVisible else { return }
        guard items.contains(where: { $0.id == displayedID }), let image = displayedImage else { endOverlaySession(); return }
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
        guard artworkVisible, let current = displayedID else { hud?.hide(); return }
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
    /// Uses the frozen live deck, never the library's current selection.
    var toolbarCycle: StageKitController.PersonaCycle? {
        if sessionState.phase != .idle {
            guard sessionState.phase != .paused, let id = sessionState.currentGroupID else { return nil }
            return .init(generation: overlayGeneration, revision: toolbarCycleRevision, selection: id,
                         title: sessionState.groups.first(where: { $0.id == id })?.label ?? "Choose set",
                         isSet: true, canAdvance: sessionState.groups.count > 1)
        }
        // The camera is not a deck: Next and the picker never cycle it away.
        guard !cameraOwnsSlot, artworkVisible, let id = displayedID else { return nil }
        return .init(generation: overlayGeneration, revision: toolbarCycleRevision, selection: id, title: displayedLabel ?? "Choose Persona",
                     isSet: false, canAdvance: (liveSelection?.candidateIDs.count ?? 1) > 1)
    }
    func stepToolbarPersona(expected: StageKitController.PersonaCycle, offset: Int) {
        guard toolbarCycle == expected, expected.canAdvance else { return }
        if expected.isSet { performOverlayAction(.stepGroup(offset)) }
        else { stepQuickPersona(offset) }
    }

    // MARK: The pill's Persona picker

    /// What the pill's one Persona picker names as current. A prepared set keeps
    /// its Choose set; otherwise Persona always has a choice, because the live
    /// camera is one of its sources beside the saved cards. An empty title means
    /// nothing is live yet.
    var toolbarPicker: StageKitController.PersonaPicker? {
        if sessionState.phase != .idle { return toolbarCycle.map { .init(title: $0.title, isSet: true) } }
        if cameraOwnsSlot { return .init(title: "Live Camera", isSet: false) }
        if shownCard != nil {
            if displayedID != nil && displayedID == profileID { return .init(title: "My Profile", isSet: false) }
            return .init(title: displayedLabel.flatMap { $0 == "Floating persona" ? nil : $0 } ?? "Persona", isSet: false)
        }
        return .init(title: "", isSet: false)
    }
    /// The picker's choices: My Profile and Live Camera, then the cards Persona can show now.
    /// Choosing is the explicit start or switch: a card or My Profile ends Live Camera and
    /// shows that card; Live Camera opens the camera while the shown card stays up until its
    /// first frame.
    func makeToolbarPickerMenu() -> NSMenu {
        let menu = NSMenu(title: "Choose Persona"); menu.autoenablesItems = false
        if sessionState.phase != .idle {
            // A prepared set chooses among its sets, as its own live menu does.
            let state = sessionState, generation = overlayGeneration
            if let feedback = state.feedback { menu.addItem(StageMenuAction(feedback, enabled: false) {}) }
            for group in state.groups {
                menu.addItem(StageMenuAction(group.label, checked: group.id == state.currentGroupID) { [weak self] in
                    guard let self, self.overlayGeneration == generation, self.sessionState.currentGroupID == state.currentGroupID else { return }
                    self.performOverlayAction(.selectGroup(group.id))
                })
            }
            return menu
        }
        if let notice = cameraOwnsSlot ? camera.failure?.message : cardFeedback {
            menu.addItem(StageMenuAction(notice, enabled: false) {})
        }
        sourceChoices().forEach(menu.addItem)
        return menu
    }

    /// Persona's sources as one list, in the same words in the pill's Choose Persona and the
    /// live Persona Overlay menu's: My Profile (while a profile photo is saved) and Live
    /// Camera first, then the cards Persona can show now, the shown card's frozen candidates
    /// or the saved cards Show selected would offer. The profile photo is named once, as My
    /// Profile. Every item checks again that Persona is as it was drawn, so a menu left open
    /// across a change does nothing rather than start something else.
    private func sourceChoices() -> [NSMenuItem] {
        let generation = overlayGeneration, visit = camera.visit, source = liveSource, cameraState = camera.state
        let drawnCard = shownCard?.copyID, showing = artworkVisible
        func unchanged(_ library: PersonaLibrary) -> Bool {
            library.overlayGeneration == generation && library.camera.visit == visit && library.liveSource == source
                && library.camera.state == cameraState && library.shownCard?.copyID == drawnCard && library.artworkVisible == showing
        }
        var items: [NSMenuItem] = []
        let profile = profileID
        if let profile {
            items.append(StageMenuAction("My Profile", checked: showing && !cameraOwnsSlot && displayedID == profile) { [weak self] in
                guard let self, unchanged(self) else { return }
                self.showProfile()
            })
        } else if let edit = onEditProfile {
            // My Profile is always the first row: with no photo yet, it opens the profile editor.
            items.append(StageMenuAction("My Profile…") { edit() })
        }
        // Checked only while the bubble shows; restricted access cannot be retried, and the
        // camera's own line above says so.
        items.append(StageMenuAction("Live Camera", checked: camera.isLive, enabled: camera.failure?.offersRetry != false) { [weak self] in
            guard let self, unchanged(self), !(self.camera.isLive || self.camera.isStarting) else { return }
            self.startCamera()
        })
        var cards: [NSMenuItem] = []
        if shownCard != nil {
            // The frozen candidates behind the shown or kept card, numbered as Next counts them.
            let current = displayedID
            let ids = liveSelection?.candidateIDs ?? current.map { [$0] } ?? []
            for (index, id) in ids.enumerated() where id != profile {
                let label = liveLabels[id].flatMap { $0 == "Floating persona" ? nil : $0 } ?? "Persona \(index + 1)"
                cards.append(StageMenuAction(label, checked: showing && !cameraOwnsSlot && id == current) { [weak self] in
                    guard let self, unchanged(self) else { return }
                    if id != self.displayedID {
                        self.selectLivePersona(id)
                        guard self.displayedID == id else { return }
                    }
                    // A card already up beside a starting or failed Live Camera ends that visit too.
                    if self.hasHiddenCard { self.showAgain() }
                    else { self.endCameraForArtwork(handingOff: true); self.clearLiveNotices() }
                })
            }
        } else {
            // Nothing is live yet: the saved cards Show selected would offer.
            for (index, persona) in visibleItems.enumerated() where persona.id != profile {
                let label = publicLabel(for: persona)
                cards.append(StageMenuAction(label == "Floating persona" ? "Persona \(index + 1)" : label) { [weak self] in
                    guard let self, unchanged(self) else { return }
                    self.selectedID = persona.id
                    self.showOverlay()
                })
            }
        }
        if !cards.isEmpty { items.append(.separator()); items += cards }
        return items
    }

    /// The live camera's own items for both live menus, named by what is on
    /// screen. Each one freezes this visit and checks it again before acting, so
    /// a Hide or Try Again left over from an earlier visit does nothing. Only
    /// public words appear: no device path, library name or file name.
    /// `sources` is Choose Persona, under the explanation; `voice` is React to my voice and its
    /// colour. Grouped as the card's menu is, in its title case and order: what is showing and
    /// where it can switch; its size, lock, place and camera; its effects; the voice ring; Hide
    /// and End. Hidden, as a hidden card's: sources; Show Again; the voice ring; End.
    private func cameraItems(sources: NSMenuItem? = nil, voice: [NSMenuItem] = []) -> [NSMenuItem] {
        let visit = camera.visit
        func item(_ title: String, checked: Bool = false, enabled: Bool = true, run: @escaping (PersonaLibrary) -> Void) -> NSMenuItem {
            StageMenuAction(title, checked: checked, enabled: enabled) { [weak self] in
                guard let self, self.camera.visit == visit, self.cameraOwnsSlot else { return }
                run(self)
            }
        }
        guard camera.state != .off else { return [] }
        var groups: [[NSMenuItem]] = [[StageMenuAction(camera.explanation, enabled: false) {}] + (sources.map { [$0] } ?? [])]
        switch camera.state {
        case .off: return []
        case .permission, .starting:
            groups.append([StageMenuAction("Cancel Starting Live Camera") { [weak self] in
                guard let self, self.camera.visit == visit, self.cameraOwnsSlot else { return }
                self.endCamera()
            }])
            // The card still up beside it keeps its ring, so its switch stays reachable.
            groups.append(voice)
        case .live:
            let size = NSMenuItem()
            size.view = PersonaSizeMenuView(width: camera.placement.width) { [weak self] width in
                guard let self, self.camera.visit == visit, self.cameraOwnsSlot else { return }
                self.setOverlayWidth(width)
            }
            let locked = camera.placement.locked
            var place: [NSMenuItem] = [size, StageMenuAction("Lock Live Camera · Clicks Pass Through", checked: locked) { [weak self] in
                guard let self, self.camera.visit == visit, self.cameraOwnsSlot else { return }
                self.setOverlayLocked(!locked)
            }]
            let positions = FloatingControlAnchor.allCases.map { anchor in
                item(anchor.title) { $0.setOverlayPosition(x: anchor.unitPoint.x, y: anchor.unitPoint.y) }
            }
            let position = NSMenuItem(title: "Position Live Camera", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "Position Live Camera"); submenu.autoenablesItems = false
            positions.forEach(submenu.addItem)
            position.submenu = submenu
            place.append(position)
            if camera.sources.count > 1 {
                let cameras = NSMenuItem(title: "Switch Camera", action: nil, keyEquivalent: "")
                let list = NSMenu(title: "Switch Camera"); list.autoenablesItems = false
                for source in camera.sources {
                    let id = source.id
                    list.addItem(StageMenuAction(source.name, checked: id == camera.selectedID) { [weak self] in
                        guard let self, self.camera.visit == visit, self.cameraOwnsSlot else { return }
                        self.startCamera(deviceID: id)
                    })
                }
                cameras.submenu = list
                place.append(cameras)
            }
            groups.append(place)
            // Only where this camera can frame you, and the system's own effects for it.
            var effects: [NSMenuItem] = []
            if camera.offersCenterStage {
                let on = camera.centerStageOn
                effects.append(StageMenuAction("Centre Stage", checked: on) { [weak self] in
                    guard let self, self.camera.visit == visit, self.cameraOwnsSlot else { return }
                    self.camera.setCenterStage(!on)
                })
            }
            effects.append(item("Video Effects…") { $0.camera.showVideoEffects() })
            groups.append(effects)
            groups.append(voice)
            groups.append([StageMenuAction("Hide Live Camera") { [weak self] in
                guard let self, self.camera.visit == visit, self.cameraOwnsSlot else { return }
                self.hideCamera()
            }])
        case .hidden:
            groups.append([StageMenuAction("Show Live Camera Again") { [weak self] in
                guard let self, self.camera.visit == visit, self.cameraOwnsSlot else { return }
                self.showCameraAgain()
            }])
            groups.append(voice)
        case .failed(let failure):
            if failure.offersRetry { groups.append([StageMenuAction("Try Again") { [weak self] in
                guard let self, self.camera.visit == visit, self.cameraOwnsSlot else { return }
                self.retryCamera()
            }]) }
            groups.append(voice)
        }
        let end = StageMenuAction("End Live Camera") { [weak self] in
            guard let self, self.camera.visit == visit, self.cameraOwnsSlot else { return }
            self.endCamera()
        }
        // Hide and End share the last group.
        if case .live = camera.state, var last = groups.popLast() { last.append(end); groups.append(last) }
        else { groups.append([end]) }
        return NSMenuItem.grouped(groups)
    }
    /// Choose Persona as a submenu of the live menu: the pill's own choices.
    private func sourcesSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Choose Persona", action: nil, keyEquivalent: "")
        let list = NSMenu(title: "Choose Persona"); list.autoenablesItems = false
        sourceChoices().forEach(list.addItem)
        item.submenu = list
        return item
    }

    func makeControlsMenu() -> NSMenu {
        // Access may have changed elsewhere since the last look; the switch shows it as it is.
        recheckVoiceAccess()
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
        // names the microphone while it listens. A refused microphone keeps the
        // switch off and says so under it, with the door Dictate offers.
        func voiceSwitch() -> [NSMenuItem] {
            guard voiceAccess != nil else { return [] }
            let item = StageMenuAction("React to My Voice · Uses Microphone", checked: voiceRing) { [weak self] in
                guard let self, self.overlayGeneration == generation else { return }; self.setVoiceRing(!self.voiceRing)
            }
            if #available(macOS 14.4, *), let status = voiceStatus { item.subtitle = status }
            if voiceNeedsAllowing {
                return [item, StageMenuAction("Allow Microphone…") { [weak self] in
                    guard let self, self.overlayGeneration == generation else { return }; self.allowMicrophone()
                }]
            }
            guard let refusal = voiceRefusal else { return [item] }
            return [item, StageMenuAction(refusal, enabled: false) {},
                    StageMenuAction("Microphone Settings…") { [weak self] in self?.openMicrophoneSettings() }]
        }
        // The ring's colour, chosen as Draw's ink colour is: the presets,
        // black, and macOS's own picker for any other.
        func voiceColour() -> NSMenuItem? {
            guard voiceAccess != nil, voiceRing else { return nil }
            func choice(_ title: String, _ color: InkColor) -> NSMenuItem {
                let item = StageMenuAction(title, checked: voiceColor == color) { [weak self] in
                    guard let self, self.overlayGeneration == generation else { return }; self.setVoiceColor(color)
                }
                item.image = color.menuSwatch
                return item
            }
            var items = InkColor.presets.enumerated().map { choice(InkColor.presetName(at: $0.offset), $0.element) }
            items.append(choice("Black", .black))
            items.append(.separator())
            let custom = !InkColor.presets.contains(voiceColor) && voiceColor != .black
            items.append(StageMenuAction("Choose Colour…", checked: custom) { [weak self] in
                guard let self, self.overlayGeneration == generation else { return }; self.voiceColourPicker.show()
            })
            let item = NSMenuItem(title: "Voice Colour", action: nil, keyEquivalent: "")
            let menu = NSMenu(title: "Voice Colour"); menu.autoenablesItems = false
            items.forEach { menu.addItem($0) }
            item.submenu = menu
            return item
        }
        // The one floating card, shown or hidden: replace it with the preparation
        // selection, or bring it up to its persona's newer saved look. Public
        // labels only; the card keeps its size, place and lock.
        func cardChanges() -> [NSMenuItem] {
            guard let card = shownCard else { return [] }
            var items: [NSMenuItem] = []
            if let replacement = replacementForShown {
                let label = publicLabel(for: replacement)
                let name = label == "Floating persona" ? "Selected Persona" : label
                items.append(StageMenuAction("Replace Shown with " + name) { [weak self] in
                    guard let self, self.overlayGeneration == generation, self.shownCard?.copyID == card.copyID,
                          self.replacementForShown?.id == replacement.id else { return }
                    self.replaceShownWithSelected()
                })
            }
            if shownCardHasNewerLook {
                items.append(StageMenuAction("Update Shown Card") { [weak self] in
                    guard let self, self.overlayGeneration == generation, self.shownCard?.copyID == card.copyID else { return }
                    self.updateShownCard()
                })
            }
            return items
        }
        /// End overlay releases the one card, shown or hidden.
        func endCard() -> NSMenuItem {
            StageMenuAction("End Overlay") { [weak self] in
                guard let self, self.overlayGeneration == generation else { return }; self.endOverlaySession()
            }
        }
        if cameraOwnsSlot {
            // Live Camera owns the slot, so this menu names the camera, the sources it can
            // switch to and the ring around it. Every item revalidates this visit before acting.
            var voice = voiceSwitch(); if let item = voiceColour() { voice.append(item) }
            cameraItems(sources: sourcesSubmenu(), voice: voice).forEach(menu.addItem)
            return menu
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
                // The selected copy's persona was saved with another look since the set started.
                if shownCardHasNewerLook { menu.addItem(action("Update Selected", .update(selected.id))) }
                menu.addItem(action(selected.visible ? "Hide Selected" : "Show Selected", .visible(selected.id, !selected.visible)))
                menu.addItem(action("Bring Forward", .move(selected.id, 1)))
                menu.addItem(action("Send Backward", .move(selected.id, -1)))
                menu.addItem(action("Remove Selected", .remove(selected.id)))
            }
            menu.addSubmenu("Add Overlay", items: state.candidates.map { action($0.label, .add($0.id), enabled: state.instances.count < PersonaSessionController.maximumOverlays) })
            menu.addItem(.separator())
            menu.addItem(action(state.phase == .paused ? "Show Again" : "Hide All Temporarily", .pauseResume))
            voiceSwitch().forEach(menu.addItem); if let item = voiceColour() { menu.addItem(item) }
            menu.addItem(action("Save Layout for Next Time", .saveLayout, enabled: state.canSaveLayout && state.hasUnsavedLayout))
            menu.addItem(action("End Overlays", .end))
        } else if overlayVisible, let current = displayedID {
            // Grouped as Live Camera's menu is, in the same order: what is showing and where it
            // can switch; its size, lock, place and look; the voice ring; Hide and End.
            func unchanged(_ library: PersonaLibrary) -> Bool {
                library.overlayGeneration == generation && library.displayedID == current && library.session == nil
            }
            // A Next, Previous or choice that could not show says why where it happened. Then
            // My Profile, Live Camera and the cards, as the pill's picker offers them.
            var sources: [NSMenuItem] = cardFeedback.map { [StageMenuAction($0, enabled: false) {}] } ?? []
            sources.append(sourcesSubmenu()); sources += cardChanges()
            sources.forEach(menu.addItem)
            menu.addItem(.separator())
            let size = NSMenuItem(); size.view = PersonaSizeMenuView(width: overlayWidth) { [weak self] width in
                guard let self, unchanged(self) else { return }; self.setOverlayWidth(width)
            }; menu.addItem(size)
            menu.addItem(StageMenuAction("Lock Artwork · Clicks Pass Through", checked: overlayLocked) { [weak self] in
                guard let self, unchanged(self) else { return }; self.setOverlayLocked(!self.overlayLocked)
            })
            menu.addSubmenu("Position Artwork", items: FloatingControlAnchor.allCases.map { anchor in
                StageMenuAction(anchor.title) { [weak self] in
                    guard let self, unchanged(self) else { return }
                    self.setOverlayPosition(x: anchor.unitPoint.x, y: anchor.unitPoint.y)
                }
            })
            // This shown copy only, drawn from its frozen source; the current look is checked.
            if let copy = shownCard.map({ PersonaLiveCopy.card($0.copyID, generation: generation) }) {
                menu.addSubmenu("Appearance", items: PersonaAppearance.Shape.allCases.map { shape in
                    StageMenuAction(shape.title, checked: shape == self.liveShape(of: copy)) { [weak self] in
                        guard let self, self.overlayGeneration == generation else { return }
                        self.setLiveShape(shape, for: copy)
                    }
                })
            }
            var voice = voiceSwitch(); if let item = voiceColour() { voice.append(item) }
            // Hide names what is on screen, as Hide Live Camera does; Show Again brings it back.
            let hide: () -> Void = { [weak self] in guard let self, unchanged(self) else { return }; self.hideArtwork() }
            let hideItem = showsProfile ? StageMenuAction("Hide My Profile", run: hide) : StageMenuAction("Hide Persona", run: hide)
            menu.addGroups([voice, [hideItem, endCard()]])
        } else {
            if let card = shownCard {
                // A hidden card is kept: Show again brings back this card, not the selection.
                // The same groups and order as a hidden Live Camera's menu.
                var sources: [NSMenuItem] = cardFeedback.map { [StageMenuAction($0, enabled: false) {}] } ?? []
                sources.append(sourcesSubmenu()); sources += cardChanges()
                let show = StageMenuAction("Show Again") { [weak self] in
                    guard let self, self.overlayGeneration == generation, self.shownCard?.copyID == card.copyID else { return }
                    self.showAgain()
                }
                var voice = voiceSwitch(); if let item = voiceColour() { voice.append(item) }
                menu.addGroups([sources, [show], voice, [endCard()]])
            } else {
                menu.addItem(StageMenuAction("Show Selected Persona", enabled: !visibleItems.isEmpty) { [weak self] in
                    guard let self, self.overlayGeneration == generation else { return }; self.showOverlay()
                })
                menu.addItem(sourcesSubmenu())
            }
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
        reconcileLive()
    }
    /// Live overlays keep only what the library still has; nothing is added.
    private func reconcileLive() {
        session?.reconcile(availableGroups: groups, existingPersonas: Set(items.map(\.id)))
        if var live = liveSelection {
            // Against the card's own group, never whichever group preparation shows
            // now: browsing groups neither hides nor narrows the shown card. Removing
            // its persona, or its group or membership, subtracts it and ends the card.
            live.reconcile(group: live.groupID.flatMap { id in groups.first { $0.id == id } }, existingIDs: Set(items.map(\.id)))
            liveSelection = live
            cardDeck?.keepOnly(live.candidateIDs)
            if live.currentID == nil { endOverlaySession() }
        }
        if let displayedID, !items.contains(where: { $0.id == displayedID }) { endOverlaySession() }
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
