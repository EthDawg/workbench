import AppKit

/// One placed copy. Its ID is independent of the saved artwork's identity.
struct PersonaOverlayItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var personaID: UUID
    var placement = PersonaOverlayState(locked: true)
    var visible = true
    var publicLabel: String? = nil
    /// This copy's own Circle, Card or Original, chosen live; nil shows the
    /// persona as it was prepared. Saved only with an explicit layout save.
    var shape: PersonaAppearance.Shape? = nil

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
    /// The look `image` was drawn in when the session started.
    var shape: PersonaAppearance.Shape = .original
    /// The saved record and image revision frozen at Start, so a copy shown in
    /// another look is drawn from the same ingredients, never from later edits.
    var source: PersonaSourceSnapshot? = nil
}
struct PersonaSessionInstance: Identifiable {
    let id: UUID
    let personaID: UUID
    let label: String
    let image: NSImage
    let visible: Bool
    let placement: PersonaOverlayState
    /// The look this copy shows now.
    var shape: PersonaAppearance.Shape = .original
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
    case width(UUID, Double), position(UUID, Double, Double), shape(UUID, PersonaAppearance.Shape), update(UUID)
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
    /// Shows or removes the voice ring around this overlay.
    func setVoiceRing(_ on: Bool)
    /// The colour its voice ring draws in.
    func setVoiceColor(_ color: InkColor)
    func showVoice(_ frames: [PersonaVoiceFrame])
    /// The visible edge of a look that knows its shape, for the outline and handles.
    func setOutline(_ outline: PersonaArtworkOutline?)
    /// Another look for this copy, keeping its width and centre on screen.
    func reshape(image: NSImage, outline: PersonaArtworkOutline?, name: String, state: PersonaOverlayState) -> PersonaOverlayState
}

extension PersonaSessionDisplaying {
    func setVoiceRing(_ on: Bool) {}
    func setVoiceColor(_ color: InkColor) {}
    func showVoice(_ frames: [PersonaVoiceFrame]) {}
    func setOutline(_ outline: PersonaArtworkOutline?) {}
    func reshape(image: NSImage, outline: PersonaArtworkOutline?, name: String, state: PersonaOverlayState) -> PersonaOverlayState {
        configure(image: image, name: name, state: state); return state
    }
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
    private(set) var voiceRing = false
    private(set) var voiceColor = PersonaVoiceRingLayer.usualColor
    /// Draws a frozen candidate in another look for one copy. The library checks
    /// the image is unchanged since Start; without it, copies keep their looks.
    private let draw: ((PersonaSourceSnapshot, PersonaAppearance.Shape) throws -> NSImage)?
    /// Decoded bytes of the images frozen at Start.
    private let startBytes: Int
    /// Other looks drawn for copies, counted with the Start images in the same budget.
    private var looks: [LookKey: (image: NSImage, bytes: Int)] = [:]
    /// A look is one persona's source, frozen at Start (token 0) or updated for
    /// one copy (its own token), drawn in one shape.
    private struct LookKey: Hashable { let personaID: UUID; let token: Int; let shape: PersonaAppearance.Shape }
    /// Copies updated to their persona's newer saved look, each with its own
    /// source; every other copy keeps the candidate frozen at Start.
    private var updatedSources: [CopyKey: (source: PersonaSourceSnapshot, token: Int)] = [:]
    /// One copy in one set: the same overlay identity can appear in two sets.
    private struct CopyKey: Hashable { let group: UUID; let instance: UUID }
    private var nextToken = 1
    var imageBytes: Int { startBytes + looks.values.reduce(0) { $0 + $1.bytes } }

    init(groups: [PersonaPreparedSessionGroup], initialGroupID: UUID, canSave: Bool, softReveal: Bool = false,
         imageBytes: Int = 0, draw: ((PersonaSourceSnapshot, PersonaAppearance.Shape) throws -> NSImage)? = nil,
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
        self.softReveal = softReveal; self.startBytes = imageBytes; self.draw = draw
        savedLayouts = Dictionary(uniqueKeysWithValues: groups.map { ($0.source.id, $0.source.overlays) })
        selectedInstanceID = groups.first { $0.source.id == initialGroupID }?.overlays.first?.id
    }

    private var groupIndex: Int? { groups.firstIndex { $0.source.id == currentGroupID } }
    var currentSource: PersonaGroup? { groups.first { $0.source.id == currentGroupID }?.source }
    var currentLayout: [PersonaOverlayItem] { groups.first { $0.source.id == currentGroupID }?.overlays ?? [] }
    var selectedFrame: CGRect? { selectedInstanceID.flatMap { panels[$0]?.frame } }
    var visibleCount: Int { phase == .active ? currentLayout.filter(\.visible).count : 0 }
    /// The ring frames the selected overlay, so choosing another passes the
    /// voice to it. A hidden selection has no ring; with nothing selected the
    /// first shown overlay has it.
    var voiceTargetID: UUID? {
        guard voiceRing, phase == .active else { return nil }
        if let selectedInstanceID { return currentLayout.first { $0.id == selectedInstanceID && $0.visible }?.id }
        return currentLayout.first(where: \.visible)?.id
    }
    var state: PersonaSessionViewState {
        guard phase != .idle, let index = groupIndex else { return PersonaSessionViewState() }
        let group = groups[index]
        let instances = group.overlays.enumerated().compactMap { ordinal, item -> PersonaSessionInstance? in
            guard let candidate = group.candidates.first(where: { $0.id == item.personaID }) else { return nil }
            let copy = origin(of: item, in: group, candidate: candidate)
            let shape = item.shape ?? copy.shape
            let image = copy.token == 0 && shape == candidate.shape ? candidate.image
                : looks[LookKey(personaID: candidate.id, token: copy.token, shape: shape)]?.image ?? candidate.image
            return PersonaSessionInstance(id: item.id, personaID: item.personaID,
                label: item.publicLabel ?? (candidate.label.isEmpty ? "Overlay \(ordinal + 1)" : candidate.label),
                image: image, visible: item.visible, placement: item.placement,
                shape: image === candidate.image ? candidate.shape : shape)
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
        selectedInstanceID = id; applyVoiceRing(); onChange?()
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
    /// The replacement shows as it was prepared, in the copy's place: it keeps
    /// the copy's width and centre, and its lock, whatever its shape.
    func replace(_ id: UUID, personaID: UUID) throws {
        guard let index = groupIndex, let candidate = groups[index].candidates.first(where: { $0.id == personaID })
        else { throw PersonaError.invalidSettings }
        guard let item = groups[index].overlays.first(where: { $0.id == id }) else { return }
        updatedSources[CopyKey(group: currentGroupID, instance: id)] = nil
        var placement = item.placement
        if let panel = panels[id] {
            let label = item.publicLabel ?? (candidate.label.isEmpty ? "Overlay" : candidate.label)
            placement = panel.reshape(image: candidate.image, outline: candidate.shape.outline, name: label, state: item.placement)
            placement.locked = item.placement.locked
        }
        update(id) { $0.personaID = personaID; $0.shape = nil; $0.placement = placement }
        releaseUnusedLooks()
    }
    /// The frozen source a copy in the current set shows: its update, if it has
    /// one, else its candidate's, frozen at Start.
    func source(of id: UUID) -> PersonaSourceSnapshot? {
        guard let groupIndex, let item = groups[groupIndex].overlays.first(where: { $0.id == id }),
              let candidate = groups[groupIndex].candidates.first(where: { $0.id == item.personaID }) else { return nil }
        return origin(of: item, in: groups[groupIndex], candidate: candidate).source
    }
    /// Update: one copy shows its persona as it is saved now, drawn within the
    /// budget before anything changes. It keeps its width, centre and lock; every
    /// other copy, even of the same persona, keeps its frozen look. Replace or the
    /// end of the session forgets the update; saving the layout never saves pixels.
    func update(_ id: UUID, to source: PersonaSourceSnapshot) throws {
        guard phase != .idle, let groupIndex, let item = groups[groupIndex].overlays.first(where: { $0.id == id }),
              item.personaID == source.id,
              let candidate = groups[groupIndex].candidates.first(where: { $0.id == item.personaID }) else { return }
        let token = nextToken; nextToken += 1
        let shape = source.persona.effectiveAppearance.shape
        let image = try look(of: candidate, token: token, source: source, in: shape)
        var placement = item.placement
        // Shown, paused or hidden, the copy keeps its centre.
        if let panel = panels[id], let label = state.instances.first(where: { $0.id == id })?.label {
            placement = panel.reshape(image: image, outline: shape.outline, name: label, state: item.placement)
            placement.locked = item.placement.locked
        }
        updatedSources[CopyKey(group: currentGroupID, instance: id)] = (source, token)
        update(id) { $0.shape = nil; $0.placement = placement }
        releaseUnusedLooks()
    }
    /// Circle, Card or Original for one copy, drawn from its frozen candidate. The
    /// copy keeps its width and centre; other copies, even of the same persona,
    /// keep their looks, and the layout is saved only when asked.
    func setShape(_ shape: PersonaAppearance.Shape, for id: UUID) throws {
        guard phase != .idle, let groupIndex, let index = groups[groupIndex].overlays.firstIndex(where: { $0.id == id }) else { return }
        let item = groups[groupIndex].overlays[index]
        guard let candidate = groups[groupIndex].candidates.first(where: { $0.id == item.personaID }) else { return }
        let copy = origin(of: item, in: groups[groupIndex], candidate: candidate)
        guard (item.shape ?? copy.shape) != shape else { return }
        let image = try look(of: candidate, token: copy.token, source: copy.source, in: shape)
        var placement = item.placement
        // Shown, paused or hidden, the copy keeps its centre: a paused set comes back in place.
        if let panel = panels[id], let label = state.instances.first(where: { $0.id == id })?.label {
            placement = panel.reshape(image: image, outline: shape.outline, name: label, state: item.placement)
            placement.locked = item.placement.locked
        }
        update(id) { $0.shape = shape == copy.shape ? nil : shape; $0.placement = placement }
        releaseUnusedLooks()
    }
    /// Draws every look saved in these layouts before Start replaces anything,
    /// within the same image budget, so a prepared copy's saved shape cannot fail later.
    func prepareSavedLooks() throws {
        for group in groups {
            for item in group.overlays {
                guard let shape = item.shape, let candidate = group.candidates.first(where: { $0.id == item.personaID }) else { continue }
                _ = try look(of: candidate, token: 0, source: candidate.source, in: shape)
            }
        }
    }
    /// Where a copy's look comes from: its update, or the candidate frozen at Start.
    private func origin(of item: PersonaOverlayItem, in group: PersonaPreparedSessionGroup,
                        candidate: PersonaSessionCandidate) -> (token: Int, shape: PersonaAppearance.Shape, source: PersonaSourceSnapshot?) {
        if let updated = updatedSources[CopyKey(group: group.source.id, instance: item.id)], updated.source.id == item.personaID {
            return (updated.token, updated.source.persona.effectiveAppearance.shape, updated.source)
        }
        return (0, candidate.shape, candidate.source)
    }
    private func look(of candidate: PersonaSessionCandidate, token: Int, source: PersonaSourceSnapshot?,
                      in shape: PersonaAppearance.Shape) throws -> NSImage {
        if token == 0 && shape == candidate.shape { return candidate.image }
        let key = LookKey(personaID: candidate.id, token: token, shape: shape)
        if let kept = looks[key] { return kept.image }
        guard let draw, let source else { throw PersonaSessionError.missingArtwork }
        let drawn = try draw(source, shape)
        guard let bitmap = drawn.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw PersonaSessionError.missingArtwork }
        let bytes = bitmap.bytesPerRow * bitmap.height
        releaseUnusedLooks()
        guard imageBytes + bytes <= Self.maximumImageBytes else { throw PersonaSessionError.tooManyCandidates }
        let image = NSImage(cgImage: bitmap, size: drawn.size)
        looks[key] = (image, bytes)
        return image
    }
    /// Looks and updates no copy shows any more are released.
    private func releaseUnusedLooks() {
        var used = Set<LookKey>(), copies = Set<CopyKey>()
        for group in groups {
            for item in group.overlays {
                guard let candidate = group.candidates.first(where: { $0.id == item.personaID }) else { continue }
                let copy = origin(of: item, in: group, candidate: candidate)
                if copy.token != 0 { copies.insert(CopyKey(group: group.source.id, instance: item.id)) }
                let shape = item.shape ?? copy.shape
                if copy.token != 0 || shape != candidate.shape { used.insert(LookKey(personaID: candidate.id, token: copy.token, shape: shape)) }
            }
        }
        looks = looks.filter { used.contains($0.key) }
        updatedSources = updatedSources.filter { copies.contains($0.key) }
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
    func pause() { guard phase == .active else { return }; phase = .paused; panels.values.forEach { $0.hide() }; applyVoiceRing(); onChange?() }
    func setVoiceRing(_ on: Bool) { guard voiceRing != on else { return }; voiceRing = on; applyVoiceRing() }
    func setVoiceColor(_ color: InkColor) { voiceColor = color; panels.values.forEach { $0.setVoiceColor(color) } }
    func showVoice(_ frames: [PersonaVoiceFrame]) { if let id = voiceTargetID { panels[id]?.showVoice(frames) } }
    func resume() { guard phase == .paused else { return }; phase = .active; render(animated: false); onChange?() }
    func end() {
        closePanels(); phase = .idle; selectedInstanceID = nil; groups.removeAll(); savedLayouts.removeAll()
        looks.removeAll(); updatedSources.removeAll(); onChange?()
    }
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
        releaseUnusedLooks()
        render(); onChange?()
    }
    private func update(_ id: UUID, change: (inout PersonaOverlayItem) -> Void) {
        guard phase != .idle, let groupIndex, let index = groups[groupIndex].overlays.firstIndex(where: { $0.id == id }) else { return }
        change(&groups[groupIndex].overlays[index]); render(); onChange?()
    }
    private func closePanels() { panels.values.forEach { $0.shutdown() }; panels.removeAll() }
    private func applyVoiceRing() {
        let target = voiceTargetID
        for (id, panel) in panels { panel.setVoiceRing(id == target) }
    }
    private func render(animated: Bool = false) {
        guard phase != .idle else { return }
        let current = state
        let retained = Set(current.instances.map(\.id))
        let voiceTarget = voiceTargetID
        for id in Array(panels.keys) where !retained.contains(id) { panels.removeValue(forKey: id)?.shutdown() }
        for item in current.instances {
            let panel: any PersonaSessionDisplaying
            if let existing = panels[item.id] { panel = existing }
            else {
                panel = makePanel(); panels[item.id] = panel
                panel.onSelection = { [weak self] in self?.selectInstance(item.id) }
                panel.onPlacementChange = { [weak self] position in self?.update(item.id) { $0.placement = position } }
                panel.setVoiceColor(voiceColor)
            }
            panel.setOutline(item.shape.outline)
            if phase == .active && item.visible {
                // Before showing, so the overlay is placed with its ring's room at once.
                panel.setVoiceRing(item.id == voiceTarget)
                let placed = panel.show(image: item.image, name: item.label, state: item.placement, animated: animated)
                if let groupIndex, let index = groups[groupIndex].overlays.firstIndex(where: { $0.id == item.id }) {
                    groups[groupIndex].overlays[index].placement.screenID = placed.screenID
                }
            } else { panel.configure(image: item.image, name: item.label, state: item.placement); panel.hide(); panel.setVoiceRing(false) }
        }
    }
}
