import SwiftUI

/// The prepared session's live copies. Library selection and saved layout editing stay
/// separate; every callback retains the group and instance it was drawn for.
struct PersonaLiveSettings: View {
    @ObservedObject var library: PersonaLibrary
    let generation: UUID
    var body: some View {
        if library.sessionState.phase != .idle {
            let state = library.sessionState
            VStack(alignment: .leading, spacing: 10) {
                Text("Live Persona set").font(.headline)
                Picker("Choose overlay", selection: Binding(get: { state.selectedInstanceID }, set: { id in
                    if let id { perform(.selectInstance(id), group: state.currentGroupID) }
                })) {
                    ForEach(state.instances) { item in Text(item.label).tag(Optional(item.id)) }
                }
                if let copy = state.selectedInstance {
                    HStack {
                        Text("Size \(Int((copy.width * 100).rounded()))%").font(.caption.monospacedDigit())
                        Slider(value: Binding(get: { copy.width }, set: { perform(.width(copy.id, $0), group: state.currentGroupID) }), in: 0.06...0.40)
                            .accessibilityLabel("Size of selected live overlay")
                    }
                    Picker("Appearance", selection: Binding(get: { copy.shape }, set: { perform(.shape(copy.id, $0), group: state.currentGroupID) })) {
                        ForEach(PersonaAppearance.Shape.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    Toggle("Lock artwork · clicks pass through", isOn: Binding(get: { copy.locked }, set: {
                        perform(.locked(copy.id, $0), group: state.currentGroupID)
                    }))
                    HStack {
                        Menu("Position artwork") {
                            ForEach(FloatingControlAnchor.allCases, id: \.self) { anchor in
                                Button(anchor.title) { perform(.position(copy.id, anchor.unitPoint.x, anchor.unitPoint.y), group: state.currentGroupID) }
                            }
                        }
                        Menu("Replace selected") {
                            ForEach(state.candidates) { item in
                                Button(item.label) { perform(.replace(instanceID: copy.id, personaID: item.id), group: state.currentGroupID) }
                            }
                        }
                        if library.shownCardHasNewerLook {
                            Button("Update selected") { perform(.update(copy.id), group: state.currentGroupID) }
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { copyActions(copy, group: state.currentGroupID) }
                        VStack(alignment: .leading) { copyActions(copy, group: state.currentGroupID) }
                    }
                }
                HStack {
                    Menu("Add overlay") {
                        ForEach(state.candidates) { item in Button(item.label) { perform(.add(item.id), group: state.currentGroupID) } }
                    }.disabled(state.instances.count >= PersonaSessionController.maximumOverlays)
                    Button("Save live layout") { perform(.saveLayout, group: state.currentGroupID) }
                        .disabled(!state.canSaveLayout || !state.hasUnsavedLayout)
                }
                Text("These controls change the selected live copy. Save live layout updates the prepared set for next time.")
                    .font(.caption).foregroundStyle(.secondary)
                if let feedback = state.feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
            }.padding(12).background(Workbench.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    @ViewBuilder private func copyActions(_ copy: PersonaSessionInstance, group: UUID?) -> some View {
        Button(copy.visible ? "Hide selected" : "Show selected") { perform(.visible(copy.id, !copy.visible), group: group) }
        Button("Bring forward") { perform(.move(copy.id, 1), group: group) }
        Button("Send backward") { perform(.move(copy.id, -1), group: group) }
        Button("Remove selected") { perform(.remove(copy.id), group: group) }
    }
    private func perform(_ action: PersonaSessionAction, group: UUID?) {
        guard library.liveControlsGeneration == generation,
              library.sessionState.currentGroupID == group, library.sessionState.phase != .idle else { return }
        library.performOverlayAction(action)
    }
}
