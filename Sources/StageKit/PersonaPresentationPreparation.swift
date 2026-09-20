import SwiftUI

/// Preparation owns a draft. Saving never changes a running session's images.
struct PersonaPresentationPreparation: View {
    @ObservedObject var library: PersonaLibrary
    let onStart: ([UUID], Bool) -> Void
    let onResume: () -> Void
    let onManageGroups: () -> Void
    let onDraftChanged: (Bool) -> Void
    @State private var groupID: UUID?
    @State private var loaded = false
    @State private var original: PersonaGroup?
    @State private var overlays: [PersonaOverlayItem] = []
    @State private var publicLabel = ""
    @State private var selectedID: UUID?
    @State private var addingPersonaID: UUID?
    @State private var choosingGroups = false
    @State private var softReveal = false
    @State private var pendingGroupID: UUID?
    @State private var confirmingGroupChange = false

    private var group: PersonaGroup? { library.groups.first { $0.id == groupID } }
    private var dirty: Bool { original.map { overlays != ($0.overlays ?? []) || publicLabel != ($0.publicLabel ?? "") } ?? false }
    private var valid: Bool {
        guard original != nil, overlays.count <= PersonaSessionController.maximumOverlays, validLabel(publicLabel) else { return false }
        let allowed = Set(original?.personaIDs ?? [])
        return overlays.allSatisfy { (try? $0.validated(allowed: allowed)) != nil }
    }
    private var preparedReady: Bool {
        !library.preparedGroupIDs.isEmpty && library.preparedGroupIDs.allSatisfy { id in
            library.groups.first { $0.id == id }?.overlays?.isEmpty == false
        }
    }
    private var isRunning: Bool { library.sessionState.phase != .idle }
    private var memberItems: [SavedPersona] {
        let byID = Dictionary(uniqueKeysWithValues: library.items.map { ($0.id, $0) })
        return (group?.personaIDs ?? []).compactMap { byID[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Arrange this group's overlays, then choose the groups to present. Private names stay in preparation.")
                .font(.callout).foregroundStyle(.secondary)
            if library.groups.isEmpty {
                ContentUnavailableView {
                    Label("Create a persona group first", systemImage: "person.2")
                } description: {
                    Text("A group keeps the cards for one audience together. Add its members in Personas.")
                } actions: { Button("Manage persona groups", action: onManageGroups) }
                    .frame(height: 330)
            } else {
                HStack {
                    Picker("Edit group", selection: Binding(get: { groupID }, set: chooseGroup)) {
                        Text("Choose a group").tag(UUID?.none)
                        ForEach(library.groups) { group in Text(group.name).tag(Optional(group.id)) }
                    }
                    Button("Manage groups…", action: onManageGroups)
                    Button("Demo groups…") { choosingGroups = true }
                        .accessibilityLabel("Choose and order the groups in this presentation")
                }
                HStack(alignment: .top, spacing: 18) {
                    overlayList.frame(width: 255)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Layout preview").font(.caption).foregroundStyle(.secondary)
                        layoutPreview.frame(height: 125)
                        if let index = overlays.firstIndex(where: { $0.id == selectedID }) {
                            itemControls(overlays[index])
                        } else {
                            Text("Select an overlay to change its public label, size or position.")
                                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 140)
                        }
                    }.frame(maxWidth: .infinity)
                }
                HStack {
                    TextField("Public group label (optional)", text: $publicLabel).textFieldStyle(.roundedBorder)
                    Text("Otherwise: Set 1, Set 2…").font(.caption).foregroundStyle(.secondary)
                    Button("Revert") { load(groupID) }.disabled(!dirty)
                    Button("Save layout", action: save).disabled(!dirty || !valid || library.isReadOnly)
                }
                Text(validLabel(publicLabel) ? "Layout changes are saved only with Save layout. A running presentation keeps its prepared images." : "Public labels need at most 80 characters on one line.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                if isRunning {
                    Label(library.sessionState.phase == .paused ? "Presentation hidden" : "Presentation running",
                          systemImage: library.sessionState.phase == .paused ? "eye.slash" : "rectangle.on.rectangle")
                        .font(.callout)
                    Spacer()
                    if library.sessionState.phase == .paused {
                        Button("Resume", action: onResume).disabled(dirty)
                    } else { Button("Hide all") { library.pauseOverlaySession() } }
                    Button("Save live layout") {
                        do { try library.saveSessionLayout(); if !dirty { load(groupID) } }
                        catch { library.notice = error.localizedDescription }
                    }.disabled(dirty || !library.sessionState.hasUnsavedLayout || !library.sessionState.canSaveLayout || library.isReadOnly)
                    Button("End overlays") { library.endOverlaySession() }
                } else {
                    Text(library.preparedGroupIDs.isEmpty ? "Choose Demo groups to prepare your sequence." :
                         (preparedReady ? "\(library.preparedGroupIDs.count) groups prepared" : "A prepared group needs a saved layout."))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Soft reveal", isOn: $softReveal).fixedSize()
                        .help("Briefly fade in new overlays. Group switching remains immediate, and Reduce Motion turns the fade off.")
                    Button("Start overlays") { onStart(library.preparedGroupIDs, softReveal) }
                        .disabled(dirty || !preparedReady || library.isReadOnly)
                }
            }
        }
        .onAppear {
            if !loaded { loaded = true; load(library.activeGroupID ?? library.groups.first?.id) }
            onDraftChanged(dirty)
        }
        .onChange(of: dirty) { _, value in onDraftChanged(value) }
        .onChange(of: library.groups) { _, _ in
            if !dirty { load(groupID.flatMap { id in library.groups.contains { $0.id == id } ? id : nil } ?? library.groups.first?.id) }
        }
        .onDisappear { onDraftChanged(false) }
        .confirmationDialog("Discard the unsaved layout?", isPresented: $confirmingGroupChange, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { load(pendingGroupID); pendingGroupID = nil }
            Button("Keep editing", role: .cancel) { pendingGroupID = nil }
        }
        .sheet(isPresented: $choosingGroups) { PersonaDemoGroupChooser(library: library) }
    }

    private var overlayList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Overlays · frontmost last").font(.headline)
            List(selection: $selectedID) {
                ForEach(Array(overlays.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 8) {
                        Image(systemName: item.visible ? "eye" : "eye.slash").foregroundStyle(.secondary)
                        Text(label(for: item, index: index)).lineLimit(1)
                        Spacer()
                        if item.placement.locked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                    }.tag(item.id).padding(.vertical, 3)
                }
            }.frame(height: 176).overlay {
                if overlays.isEmpty { Text("Add a group member as an overlay.").foregroundStyle(.secondary).multilineTextAlignment(.center).padding() }
            }
            Picker("Card", selection: $addingPersonaID) {
                Text("Choose a group member").tag(UUID?.none)
                ForEach(memberItems) { Text($0.name).tag(Optional($0.id)) }
            }.labelsHidden().accessibilityLabel("Group member to add as an overlay")
            Button("Add overlay") {
                guard let id = addingPersonaID, memberItems.contains(where: { $0.id == id }) else { return }
                var placement = PersonaOverlayState(); placement.locked = true
                let anchors: [FloatingControlAnchor] = [.bottomLeft, .bottomRight, .topLeft, .topRight, .left, .right, .top, .bottom]
                let point = anchors[min(overlays.count, anchors.count - 1)].unitPoint
                placement.x = point.x; placement.y = point.y
                let item = PersonaOverlayItem(personaID: id, placement: placement)
                overlays.append(item); selectedID = item.id
            }.disabled(addingPersonaID == nil || overlays.count >= PersonaSessionController.maximumOverlays || library.isReadOnly)
        }
    }

    private var layoutPreview: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.045))
                ForEach(overlays.filter(\.visible)) { item in
                    if let persona = library.items.first(where: { $0.id == item.personaID }), let image = library.renderedImage(for: persona) {
                        let placement = PersonaPlacement(image: persona.image, x: item.placement.x, y: item.placement.y, width: item.placement.width)
                        let frame = PersonaGeometry.rect(placement, imageSize: image.size, in: geometry.size)
                        Image(nsImage: image).resizable().scaledToFit().frame(width: frame.width, height: frame.height)
                            .overlay { if item.id == selectedID { Rectangle().stroke(Color.accentColor, lineWidth: 1) } }
                            .position(x: frame.midX, y: geometry.size.height - frame.midY).accessibilityHidden(true)
                    }
                }
                if !overlays.contains(where: \.visible) { Text("No visible overlays").font(.caption).foregroundStyle(.secondary) }
            }.accessibilityElement(children: .ignore).accessibilityLabel("Layout preview. \(overlays.filter(\.visible).count) visible overlays.")
        }
    }

    @ViewBuilder private func itemControls(_ item: PersonaOverlayItem) -> some View {
        TextField("Public overlay label (optional)", text: binding(item, get: { $0.publicLabel ?? "" }, set: { $0.publicLabel = $1.isEmpty ? nil : $1 }))
            .textFieldStyle(.roundedBorder)
        Text("Labels name the controls; the card artwork stays unchanged.").font(.caption).foregroundStyle(.secondary)
        HStack {
            Toggle("Visible", isOn: binding(item, get: { $0.visible }, set: { $0.visible = $1 }))
            Toggle("Locked · click through", isOn: binding(item, get: { $0.placement.locked }, set: { $0.placement.locked = $1 }))
        }
        HStack {
            Text("Size").font(.callout)
            Slider(value: binding(item, get: { $0.placement.width }, set: { $0.placement.width = $1 }), in: 0.06...0.40)
                .accessibilityLabel("Overlay width")
            Menu("Position") {
                ForEach(FloatingControlAnchor.allCases) { anchor in
                    Button(anchor.title) { update(item.id) { $0.placement.x = anchor.unitPoint.x; $0.placement.y = anchor.unitPoint.y } }
                }
            }.fixedSize()
        }
        HStack {
            Button("Duplicate") {
                var copy = item; copy.id = UUID(); copy.placement.x = min(1, copy.placement.x + 0.06)
                copy.placement.y = max(0, copy.placement.y - 0.06)
                overlays.append(copy); selectedID = copy.id
            }.disabled(overlays.count >= PersonaSessionController.maximumOverlays)
            Menu("Order") {
                Button("Bring forward") { move(item.id, by: 1) }.disabled(overlays.last?.id == item.id)
                Button("Send backward") { move(item.id, by: -1) }.disabled(overlays.first?.id == item.id)
            }
            Spacer()
            Button("Remove overlay", role: .destructive) {
                overlays.removeAll { $0.id == item.id }; selectedID = overlays.last?.id
            }
        }.disabled(library.isReadOnly)
        if !validLabel(item.publicLabel ?? "") { Text("Use at most 80 characters on one line.").font(.caption).foregroundStyle(.orange) }
    }

    private func chooseGroup(_ id: UUID?) {
        guard id != groupID else { return }
        if dirty { pendingGroupID = id; confirmingGroupChange = true } else { load(id) }
    }
    private func load(_ id: UUID?) {
        groupID = id; original = library.groups.first { $0.id == id }
        overlays = original?.overlays ?? []; publicLabel = original?.publicLabel ?? ""
        selectedID = overlays.first?.id; addingPersonaID = original?.personaIDs.first
        onDraftChanged(false)
    }
    private func save() {
        guard let original else { return }
        do {
            try library.saveGroupLayout(original.id, overlays: overlays, publicLabel: publicLabel.isEmpty ? nil : publicLabel, expected: original)
            load(original.id)
        } catch { library.notice = error.localizedDescription }
    }
    private func validLabel(_ value: String) -> Bool {
        do { _ = try PersonaSessionLabels.validated(value); return true }
        catch { return false }
    }
    private func label(for item: PersonaOverlayItem, index: Int) -> String {
        let custom = item.publicLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let card = library.items.first { $0.id == item.personaID }?.card?.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !custom.isEmpty ? custom : (!card.isEmpty ? card : "Overlay \(index + 1)")
    }
    private func update(_ id: UUID, _ mutate: (inout PersonaOverlayItem) -> Void) {
        guard let index = overlays.firstIndex(where: { $0.id == id }) else { return }; mutate(&overlays[index])
    }
    private func binding<Value>(_ item: PersonaOverlayItem, get: @escaping (PersonaOverlayItem) -> Value,
                                set: @escaping (inout PersonaOverlayItem, Value) -> Void) -> Binding<Value> {
        let fallback = get(item)
        return Binding(get: { overlays.first { $0.id == item.id }.map(get) ?? fallback }, set: { value in update(item.id) { set(&$0, value) } })
    }
    private func move(_ id: UUID, by delta: Int) {
        guard let index = overlays.firstIndex(where: { $0.id == id }), overlays.indices.contains(index + delta) else { return }
        overlays.swapAt(index, index + delta)
    }
}

private struct PersonaDemoGroupChooser: View {
    @ObservedObject var library: PersonaLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var ordered: [UUID]
    init(library: PersonaLibrary) { self.library = library; _ordered = State(initialValue: library.preparedGroupIDs) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose demo groups").font(.title2.bold())
            Text("Only these groups appear in the running controls. Private names are shown here only.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(ordered.compactMap { id in library.groups.first { $0.id == id } }) { group in
                    HStack {
                        Toggle(group.name, isOn: Binding(get: { ordered.contains(group.id) }, set: { if !$0 { ordered.removeAll { $0 == group.id } } }))
                        Spacer()
                        Button { move(group.id, by: -1) } label: { Image(systemName: "arrow.up") }
                            .buttonStyle(.borderless).accessibilityLabel("Move \(group.name) earlier").disabled(ordered.first == group.id)
                        Button { move(group.id, by: 1) } label: { Image(systemName: "arrow.down") }
                            .buttonStyle(.borderless).accessibilityLabel("Move \(group.name) later").disabled(ordered.last == group.id)
                    }.accessibilityElement(children: .contain)
                }
                ForEach(library.groups.filter { !ordered.contains($0.id) }) { group in
                    Toggle(group.name, isOn: Binding(get: { false }, set: { if $0 { ordered.append(group.id) } }))
                        .disabled(group.overlays?.isEmpty != false || ordered.count >= PersonaSessionController.maximumGroups)
                        .help(group.overlays?.isEmpty != false ? "Save this group's overlay layout first." : "Add to the end of this demo sequence.")
                }
            }.frame(height: 260)
            Text("Choose up to eight groups with saved layouts. Sequence order is the default Set 1, Set 2… labelling.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save sequence") {
                    do { try library.savePreparedGroups(ordered); dismiss() }
                    catch { library.notice = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(library.isReadOnly)
            }
            if let notice = library.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
        }.padding(24).frame(width: 510).background(Workbench.background).workbenchTheme()
    }
    private func move(_ id: UUID, by delta: Int) {
        guard let index = ordered.firstIndex(of: id), ordered.indices.contains(index + delta) else { return }
        ordered.swapAt(index, index + delta)
    }
}
