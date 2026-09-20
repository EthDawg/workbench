import AppKit

/// One placed copy. Its ID is independent of the saved artwork's identity.
struct PersonaOverlayItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var personaID: UUID
    var placement = PersonaOverlayState(locked: true)
    var visible = true
    var publicLabel: String? = nil

    func validated(allowed: Set<UUID>) throws -> Self {
        guard allowed.contains(personaID) else { throw PersonaError.invalidSettings }
        var copy = self
        copy.placement = try placement.validated()
        copy.publicLabel = try PersonaSessionLabels.validated(publicLabel)
        return copy
    }
}

enum PersonaSessionLabels {
    static func validated(_ label: String?) throws -> String? {
        guard let label else { return nil }
        guard label.count <= 80, label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw PersonaError.invalidSettings }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct PersonaSessionGroupChoice: Identifiable {
    let id: UUID
    let label: String
}
struct PersonaSessionCandidate: Identifiable {
    let id: UUID
    let label: String
    let image: NSImage
}
struct PersonaSessionInstance: Identifiable {
    let id: UUID
    let personaID: UUID
    let label: String
    let image: NSImage
    let visible: Bool
    let placement: PersonaOverlayState
    var locked: Bool { placement.locked }
    var width: Double { placement.width }
}
struct PersonaSessionViewState {
    enum Phase { case idle, active, paused }
    var phase = Phase.idle
    var groups: [PersonaSessionGroupChoice] = []
    var currentGroupID: UUID?
    var instances: [PersonaSessionInstance] = []
    var selectedInstanceID: UUID?
    var candidates: [PersonaSessionCandidate] = []
    var feedback: String?
    var hasUnsavedLayout = false
    var canSaveLayout = false
    var selectedInstance: PersonaSessionInstance? { instances.first { $0.id == selectedInstanceID } }
}

enum PersonaSessionAction {
    case selectGroup(UUID), stepGroup(Int), selectInstance(UUID), add(UUID)
    case replace(instanceID: UUID, personaID: UUID)
    case remove(UUID), move(UUID, Int), visible(UUID, Bool), locked(UUID, Bool)
    case width(UUID, Double), position(UUID, Double, Double)
    case pauseResume, saveLayout, dismissFeedback, end
}
struct PersonaSessionHUDModel {
    let state: PersonaSessionViewState
    let perform: (PersonaSessionAction) -> Void
}

enum PersonaSessionError: LocalizedError {
    case missingGroup, needsSelection, tooManyOverlays, tooManyCandidates, changedLayout, missingArtwork
    var errorDescription: String? {
        switch self {
        case .missingGroup: return "Choose a prepared group for this demo. The current overlays are unchanged."
        case .needsSelection: return "Choose a persona or prepare this group's layout before starting."
        case .tooManyOverlays: return "Use up to eight overlays in a group and eight groups in one demo."
        case .tooManyCandidates: return "Use up to 32 different personas in one demo, with artwork under the 256 MB preview limit."
        case .changedLayout: return "This group's layout or members changed during the demo. Reopen preparation to review them; your current overlays are unchanged."
        case .missingArtwork: return "A prepared persona image is missing or unreadable. Repair it in Personas before starting this group."
        }
    }
}
enum PersonaSessionInteractionError: LocalizedError {
    case busy
    var errorDescription: String? { "Finish your current recording or keyboard practice before showing or switching overlays." }
}

/// Native windows are injected in focused checks; tests never need to show artwork
/// over the user's apps to verify the actual session owner and lifecycle.
protocol PersonaSessionDisplaying: AnyObject {
    var onPlacementChange: ((PersonaOverlayState) -> Void)? { get set }
    var onSelection: (() -> Void)? { get set }
    var frame: CGRect? { get }
    func show(image: NSImage, name: String, state: PersonaOverlayState, animated: Bool) -> PersonaOverlayState
    func configure(image: NSImage, name: String, state: PersonaOverlayState)
    func hide()
    func shutdown()
}

struct PersonaPreparedSessionGroup {
    let source: PersonaGroup
    let label: String
    let candidates: [PersonaSessionCandidate]
    var overlays: [PersonaOverlayItem]
}

/// One main-thread session, independent of preparation selection and saved scenes.
/// Only validated, already rendered snapshots cross this boundary.
final class PersonaSessionController {
    static let maximumOverlays = 8
    static let maximumGroups = 8
    static let maximumCandidates = 32
    static let maximumImageBytes = 256 * 1024 * 1024
    var onChange: (() -> Void)?
    private(set) var phase = PersonaSessionViewState.Phase.idle
    private(set) var currentGroupID: UUID
    private(set) var selectedInstanceID: UUID?
    private var groups: [PersonaPreparedSessionGroup]
    private var savedLayouts: [UUID: [PersonaOverlayItem]?]
    private var panels: [UUID: any PersonaSessionDisplaying] = [:]
    private let makePanel: () -> any PersonaSessionDisplaying
    private let canSave: Bool
    private let softReveal: Bool

    init(groups: [PersonaPreparedSessionGroup], initialGroupID: UUID, canSave: Bool, softReveal: Bool = false,
         makePanel: @escaping () -> any PersonaSessionDisplaying = { PersonaOverlayController() }) throws {
        guard !groups.isEmpty, groups.contains(where: { $0.source.id == initialGroupID }),
              Set(groups.map { $0.source.id }).count == groups.count else { throw PersonaSessionError.missingGroup }
        guard groups.count <= Self.maximumGroups else { throw PersonaSessionError.tooManyOverlays }
        var normalized = groups
        for (index, group) in groups.enumerated() {
            guard group.overlays.count <= Self.maximumOverlays,
                  Set(group.overlays.map(\.id)).count == group.overlays.count else { throw PersonaSessionError.tooManyOverlays }
            let ids = Set(group.candidates.map(\.id))
            guard ids.count == group.candidates.count else { throw PersonaError.invalidSettings }
            normalized[index].overlays = try group.overlays.map { try $0.validated(allowed: ids) }
        }
        self.groups = normalized; self.currentGroupID = initialGroupID; self.canSave = canSave; self.makePanel = makePanel
        self.softReveal = softReveal
        savedLayouts = Dictionary(uniqueKeysWithValues: groups.map { ($0.source.id, $0.source.overlays) })
        selectedInstanceID = groups.first { $0.source.id == initialGroupID }?.overlays.first?.id
    }

    private var groupIndex: Int? { groups.firstIndex { $0.source.id == currentGroupID } }
    var currentSource: PersonaGroup? { groups.first { $0.source.id == currentGroupID }?.source }
    var currentLayout: [PersonaOverlayItem] { groups.first { $0.source.id == currentGroupID }?.overlays ?? [] }
    var selectedFrame: CGRect? { selectedInstanceID.flatMap { panels[$0]?.frame } }
    var visibleCount: Int { phase == .active ? currentLayout.filter(\.visible).count : 0 }
    var state: PersonaSessionViewState {
        guard phase != .idle, let index = groupIndex else { return PersonaSessionViewState() }
        let group = groups[index]
        let instances = group.overlays.enumerated().compactMap { ordinal, item -> PersonaSessionInstance? in
            guard let candidate = group.candidates.first(where: { $0.id == item.personaID }) else { return nil }
            return PersonaSessionInstance(id: item.id, personaID: item.personaID,
                label: item.publicLabel ?? (candidate.label.isEmpty ? "Overlay \(ordinal + 1)" : candidate.label),
                image: candidate.image, visible: item.visible, placement: item.placement)
        }
        return PersonaSessionViewState(phase: phase, groups: groups.map { PersonaSessionGroupChoice(id: $0.source.id, label: $0.label) },
            currentGroupID: currentGroupID, instances: instances, selectedInstanceID: selectedInstanceID,
            candidates: group.candidates, hasUnsavedLayout: group.overlays != (savedLayouts[currentGroupID] ?? nil), canSaveLayout: canSave)
    }

    func start() { phase = .active; render(animated: softReveal); onChange?() }
    func selectGroup(_ id: UUID) throws {
        guard phase != .idle, let target = groups.first(where: { $0.source.id == id }) else { throw PersonaSessionError.missingGroup }
        guard id != currentGroupID else { return }
        // Every candidate was decoded before Start; preparation can neither
        // replace its bytes nor introduce a new candidate while this runs.
        closePanels()
        currentGroupID = target.source.id; selectedInstanceID = target.overlays.first?.id
        render(animated: false); onChange?()
    }
    func stepGroup(_ offset: Int) throws {
        guard let index = groupIndex, !groups.isEmpty else { return }
        let next = (index + offset % groups.count + groups.count) % groups.count
        try selectGroup(groups[next].source.id)
    }
    func selectInstance(_ id: UUID) {
        guard currentLayout.contains(where: { $0.id == id }) else { return }
        selectedInstanceID = id; onChange?()
    }
    @discardableResult func addOverlay(personaID: UUID) throws -> UUID {
        guard let index = groupIndex, groups[index].candidates.contains(where: { $0.id == personaID }) else { throw PersonaError.invalidSettings }
        guard groups[index].overlays.count < Self.maximumOverlays else { throw PersonaSessionError.tooManyOverlays }
        let count = groups[index].overlays.count
        var position = PersonaOverlayState(locked: true)
        // A second card must not be born exactly behind the first one.
        position.x = [0.98, 0.02, 0.5, 0.98, 0.02, 0.5, 0.02, 0.98][count]
        position.y = [0.02, 0.02, 0.02, 0.98, 0.98, 0.98, 0.5, 0.5][count]
        let item = PersonaOverlayItem(personaID: personaID, placement: position)
        groups[index].overlays.append(item); selectedInstanceID = item.id
        render(animated: softReveal && phase == .active); onChange?(); return item.id
    }
    func replace(_ id: UUID, personaID: UUID) throws {
        guard let index = groupIndex, groups[index].candidates.contains(where: { $0.id == personaID }) else { throw PersonaError.invalidSettings }
        update(id) { $0.personaID = personaID }
    }
    func removeOverlay(_ id: UUID) {
        guard let index = groupIndex else { return }
        groups[index].overlays.removeAll { $0.id == id }
        if selectedInstanceID == id { selectedInstanceID = nil }
        render(); onChange?()
    }
    func move(_ id: UUID, by offset: Int) {
        guard let groupIndex, let index = groups[groupIndex].overlays.firstIndex(where: { $0.id == id }),
              groups[groupIndex].overlays.indices.contains(index + offset) else { return }
        groups[groupIndex].overlays.swapAt(index, index + offset); render(); onChange?()
    }
    func setVisible(_ value: Bool, for id: UUID) { update(id) { $0.visible = value } }
    func setLocked(_ value: Bool, for id: UUID) { update(id) { $0.placement.locked = value } }
    func setWidth(_ value: Double, for id: UUID) {
        guard value.isFinite else { return }; update(id) { $0.placement.width = min(0.40, max(0.06, value)) }
    }
    func setPosition(x: Double, y: Double, for id: UUID) {
        guard x.isFinite, y.isFinite else { return }
        update(id) { $0.placement.x = min(1, max(0, x)); $0.placement.y = min(1, max(0, y)) }
    }
    func pause() { guard phase == .active else { return }; phase = .paused; panels.values.forEach { $0.hide() }; onChange?() }
    func resume() { guard phase == .paused else { return }; phase = .active; render(animated: false); onChange?() }
    func end() { closePanels(); phase = .idle; selectedInstanceID = nil; groups.removeAll(); savedLayouts.removeAll(); onChange?() }
    func markSaved(_ group: PersonaGroup) {
        guard let index = groups.firstIndex(where: { $0.source.id == group.id }) else { return }
        // Advance only the save baseline. A newly edited public label/candidate
        // remains outside the original frozen presentation data.
        let old = groups[index]
        groups[index] = PersonaPreparedSessionGroup(source: group, label: old.label, candidates: old.candidates, overlays: old.overlays)
        savedLayouts[group.id] = .some(group.overlays); onChange?()
    }
    func reconcile(availableGroups: [PersonaGroup], existingPersonas: Set<UUID>) {
        guard phase != .idle else { return }
        let byID = Dictionary(uniqueKeysWithValues: availableGroups.map { ($0.id, $0) })
        guard byID[currentGroupID] != nil else { end(); return }
        for index in groups.indices {
            let old = groups[index]
            guard let saved = byID[old.source.id] else { continue }
            let allowed = Set(saved.personaIDs).intersection(existingPersonas)
            let candidates = old.candidates.filter { allowed.contains($0.id) }
            let overlays = old.overlays.filter { allowed.contains($0.personaID) }
            groups[index] = PersonaPreparedSessionGroup(source: old.source, label: old.label, candidates: candidates, overlays: overlays)
        }
        groups.removeAll { byID[$0.source.id] == nil }
        if let selectedInstanceID, !currentLayout.contains(where: { $0.id == selectedInstanceID }) { self.selectedInstanceID = nil }
        render(); onChange?()
    }
    private func update(_ id: UUID, change: (inout PersonaOverlayItem) -> Void) {
        guard phase != .idle, let groupIndex, let index = groups[groupIndex].overlays.firstIndex(where: { $0.id == id }) else { return }
        change(&groups[groupIndex].overlays[index]); render(); onChange?()
    }
    private func closePanels() { panels.values.forEach { $0.shutdown() }; panels.removeAll() }
    private func render(animated: Bool = false) {
        guard phase != .idle else { return }
        let current = state
        let retained = Set(current.instances.map(\.id))
        for id in Array(panels.keys) where !retained.contains(id) { panels.removeValue(forKey: id)?.shutdown() }
        for item in current.instances {
            let panel: any PersonaSessionDisplaying
            if let existing = panels[item.id] { panel = existing }
            else {
                panel = makePanel(); panels[item.id] = panel
                panel.onSelection = { [weak self] in self?.selectInstance(item.id) }
                panel.onPlacementChange = { [weak self] position in self?.update(item.id) { $0.placement = position } }
            }
            if phase == .active && item.visible {
                let placed = panel.show(image: item.image, name: item.label, state: item.placement, animated: animated)
                if let groupIndex, let index = groups[groupIndex].overlays.firstIndex(where: { $0.id == item.id }) {
                    groups[groupIndex].overlays[index].placement.screenID = placed.screenID
                }
            } else { panel.configure(image: item.image, name: item.label, state: item.placement); panel.hide() }
        }
    }
}
