import SwiftUI

enum PersonaLibraryMode { case sheet, workspace }

/// Sheets release preparation before showing artwork; the independent workspace
/// can act immediately. Consume deferred requests once so unrelated navigation
/// cannot replay an earlier Start or Resume.
struct PersonaLibraryLaunchState {
    enum Request {
        case oneCard
        /// The hidden floating card, as it was.
        case showAgain
        case prepared(groupIDs: [UUID], softReveal: Bool)
        case resume
        var isResume: Bool { if case .resume = self { return true }; return false }
        func perform(in library: PersonaLibrary) -> Result<Void, Error> {
            switch self {
            case .oneCard: return library.showOverlay()
            case .showAgain: return library.showAgain()
            case .prepared(let groupIDs, let softReveal):
                return Result {
                    guard let first = groupIDs.first else { throw PersonaSessionError.missingGroup }
                    try library.startOverlaySession(groupIDs: groupIDs, initialGroupID: first, softReveal: softReveal)
                }
            case .resume: return Result { try library.resumeOverlaySession() }
            }
        }
    }
    private(set) var pending: Request?
    mutating func request(_ request: Request, from mode: PersonaLibraryMode, in library: PersonaLibrary) -> Result<Void, Error>? {
        if mode == .sheet { pending = request; return nil }
        return request.perform(in: library)
    }
    mutating func dismissed(in library: PersonaLibrary) -> Result<Void, Error>? {
        guard let request = pending else { return nil }
        pending = nil
        return request.perform(in: library)
    }
}

struct PersonaLibraryView: View {
    @ObservedObject var library: PersonaLibrary
    var onChoose: ((SavedPersona) -> Void)? = nil
    var mode: PersonaLibraryMode = .sheet
    var editProfile: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: UUID?
    @State private var name = ""
    @State private var groupName = ""
    @State private var creatingGroup = false
    @State private var renamingGroup = false
    @State private var editingGroup: PersonaGroup?
    /// The one editor open at a time: a saved persona's appearance, or a new
    /// portrait's draft, which exists only there until Add persona. A second
    /// draft never replaces it.
    @State private var editors = PersonaEditorHolder()
    @State private var choosingStarter = false
    @State private var starterDraft: PersonaPortraitDraft?
    @State private var preparingPresentation = false
    @State private var launchState = PersonaLibraryLaunchState()
    @State private var unsavedPresentationLayout = false
    @State private var confirmingDiscard = false
    @State private var dismissAfterDiscard = false
    @State private var removingPersona: SavedPersona?
    /// Which source this page is preparing. It follows the live source, so the
    /// page always shows what is actually on screen, and changing it starts nothing.
    @State private var source: PersonaLiveSource = .artwork

    var body: some View {
        Group {
            if mode == .workspace {
                GeometryReader { geometry in
                    ScrollView {
                        content(availableWidth: geometry.size.width)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            } else { content(availableWidth: preparingPresentation ? 780 : 660) }
        }.background(Workbench.background).workbenchTheme()
    }

    private var liveSourceControl: some View {
        Picker("Live source", selection: $source) {
            Text("Artwork").tag(PersonaLiveSource.artwork)
            Text("Camera").tag(PersonaLiveSource.camera)
        }.pickerStyle(.segmented).fixedSize()
            .help("Prepare saved artwork or a camera bubble. Choosing a source starts nothing.")
    }

    private func content(availableWidth: CGFloat) -> some View {
        let usesColumns = availableWidth >= 640
        let layout = usesColumns ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                if preparingPresentation {
                    Button { leavePreparation(dismissLibrary: false) } label: { Label("Personas", systemImage: "chevron.left") }
                }
                // As a Workbench page it carries the page's name and title type (#134); as a sheet it is
                // the library of personas. Its summary sits 4 points under it in body text, as the page
                // kit's header has it.
                VStack(alignment: .leading, spacing: 4) {
                    Text(preparingPresentation ? "Arrange overlays" : onChoose != nil ? "Choose persona" : mode == .workspace ? "Persona" : "Personas")
                        .font(mode == .workspace && !preparingPresentation ? .title.weight(.semibold) : .title2.bold()).accessibilityAddTraits(.isHeader)
                    if !preparingPresentation {
                        Text(onChoose == nil ? "Show saved artwork or a live camera bubble over your apps." : "Choose a persona card to place in this scene.")
                            .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if !preparingPresentation, mode == .workspace, let editProfile {
                    Button("Me…", action: editProfile).help("Edit your photo and Me persona")
                        .accessibilityIdentifier("persona.profile")
                }
                if !preparingPresentation {
                    // A menu whose items act, so its own title takes no ellipsis.
                    Menu {
                        Button("Choose a starter portrait…") { choosingStarter = true }
                        Divider()
                        Button("Import portrait…") {
                            library.importPortrait(in: NSApp.keyWindow) { editors.open(.new($0)) }
                        }
                        Button("Import finished card…") { library.importImage() }
                        Button("Paste finished image") { library.pasteImage() }
                    } label: { Label("Add persona", systemImage: "plus.circle.fill") }
                        .menuStyle(.borderlessButton).fixedSize().disabled(library.isReadOnly)
                }
                if mode == .sheet || preparingPresentation {
                    // Done means one thing on every sheet: Return, and Escape below.
                    Button("Done") { leavePreparation(dismissLibrary: mode == .sheet) }.keyboardShortcut(.defaultAction)
                }
            }
            if !preparingPresentation {
                if onChoose == nil {
                    overlayActions
                    // One live slot, two sources. Choosing a source shows its own
                    // preparation; only Show selected or Start camera starts anything.
                    if library.sessionState.phase == .idle {
                        liveSourceControl
                        if source == .camera { PersonaCameraPanel(library: library, camera: library.camera) } else { shownPanel }
                    } else { PersonaLiveSettings(library: library, generation: library.liveControlsGeneration) }
                }
                // Groups and layouts wait until there is something to group (mac-foundation §1:
                // not exposed to single-card first use), and a first visit has one empty state.
                if !library.items.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack { groupPicker; groupActions }
                        VStack(alignment: .leading, spacing: 8) { groupPicker; groupActions }
                    }
                }
                if library.items.isEmpty { firstPersona } else {
                    layout {
                        List(selection: $library.selectedID) {
                            ForEach(library.visibleItems) { persona in
                                HStack(spacing: 10) {
                                    thumbnail(persona, width: 52, height: 54)
                                    Text(persona.name).lineLimit(2)
                                }.padding(.vertical, 4).tag(persona.id)
                                    .contextMenu {
                                        Button("Rename library item…") { renaming = persona.id; name = persona.name }.disabled(library.isReadOnly)
                                        Button("Remove from saved personas…") { removingPersona = persona }.disabled(library.isReadOnly)
                                        if let group = library.activeGroup, let index = group.personaIDs.firstIndex(of: persona.id) {
                                            Divider()
                                            Button("Move earlier") { library.moveMember(persona.id, by: -1) }.disabled(library.isReadOnly || index == 0)
                                            Button("Move later") { library.moveMember(persona.id, by: 1) }.disabled(library.isReadOnly || index == group.personaIDs.count - 1)
                                        }
                                    }
                            }
                        }.frame(width: usesColumns ? 250 : nil, height: usesColumns ? 360 : 220).overlay {
                            if library.visibleItems.isEmpty {
                                VStack(spacing: 10) {
                                    Text(library.activeGroup == nil ? "Your saved personas appear here." : "Choose this group's members.")
                                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                                    if let group = library.activeGroup {
                                        Button("Choose members…") { editingGroup = group }.disabled(library.isReadOnly)
                                    } else {
                                        Button("Add starter portrait…") { choosingStarter = true }.disabled(library.isReadOnly)
                                        Button("Import finished card…") { library.importImage() }.disabled(library.isReadOnly)
                                    }
                                }.padding()
                            }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            if let selected = library.selected {
                                if library.onViewImages != nil {
                                    Button { library.viewImages(startingAt: selected.id) } label: {
                                        thumbnail(selected, width: 265, height: 155).frame(maxWidth: .infinity)
                                    }.buttonStyle(.plain).accessibilityLabel("View " + selected.name).help("View image")
                                } else {
                                    thumbnail(selected, width: 265, height: 155).frame(maxWidth: .infinity)
                                }
                                // Selected is what you browse and prepare; Shown, above, is what is live.
                                Text("Selected: " + selected.name).font(.headline).lineLimit(2)
                                    .accessibilityLabel("Selected persona: " + selected.name)
                                // One quick choice; it is the look used the next time this persona is shown or placed.
                                Picker("Appearance", selection: Binding(get: { selected.effectiveAppearance.shape },
                                                                        set: { library.setShape($0, for: selected.id) })) {
                                    ForEach(PersonaAppearance.Shape.allCases) { Text($0.title).tag($0) }
                                }.pickerStyle(.segmented).fixedSize().disabled(library.isReadOnly)
                                    .help("Circle, Card or Original, the next time this persona is shown or placed. A card already shown keeps its look until you choose Update shown card.")
                                HStack {
                                    Button("Edit appearance…") { editors.open(.saved(selected)) }.disabled(library.isReadOnly)
                                    Button(role: .destructive) { removingPersona = selected } label: {
                                        Label("Remove saved persona…", systemImage: "trash")
                                    }.disabled(library.isReadOnly)
                                        .help("Remove this library entry and its group memberships; retain artwork used by saved scenes")
                                }
                                HStack {
                                    if let onChoose {
                                        Button("Use in scene") { onChoose(selected); dismiss() }
                                            .disabled(library.renderedImage(for: selected) == nil)
                                    }
                                }
                                if let group = library.activeGroup, let index = group.personaIDs.firstIndex(of: selected.id) {
                                    HStack {
                                        Text("Group order \(index + 1) of \(group.personaIDs.count)").font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Button { library.moveMember(selected.id, by: -1) } label: { Image(systemName: "arrow.up") }
                                            .accessibilityLabel("Move earlier in group").disabled(library.isReadOnly || index == 0)
                                        Button { library.moveMember(selected.id, by: 1) } label: { Image(systemName: "arrow.down") }
                                            .accessibilityLabel("Move later in group").disabled(library.isReadOnly || index == group.personaIDs.count - 1)
                                    }
                                }
                            } else {
                                // The page kit's empty-state type: one title style and one symbol size.
                                Image(systemName: "person.crop.rectangle.stack").font(.system(size: 22)).foregroundStyle(Workbench.accent)
                                    .accessibilityHidden(true)
                                Text("Choose a persona").font(.callout.weight(.semibold))
                                Text("Use the same saved image over your browser or inside a Present scene.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            if onChoose == nil && (library.artworkVisible || library.sessionState.phase != .idle) {
                                Button("Focus floating controls for keyboard") { library.focusOverlayControls() }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if onChoose == nil && !library.items.isEmpty {
                    HStack {
                        Text("Need several overlays at once?").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Arrange overlays…") { preparingPresentation = true }
                            .help("Place several persona cards over your apps")
                            .disabled(library.isReadOnly)
                    }
                }
            } else {
                PersonaPresentationPreparation(library: library, onStart: { ids, softReveal in
                    requestLaunch(.prepared(groupIDs: ids, softReveal: softReveal))
                }, onResume: { requestLaunch(.resume) },
                   onManageGroups: { leavePreparation(dismissLibrary: false) },
                   onDraftChanged: { unsavedPresentationLayout = $0 })
            }
            // A refused microphone shows under React to my voice, where the switch was turned on.
            if let notice = library.notice, library.voiceRefusal == nil {
                Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Whole-screen sharing includes preparation and floating controls. Use a persona in a scene when sharing that presentation window.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(width: mode == .sheet ? (preparingPresentation ? 780 : 660) : nil)
            .onExitCommand { if mode == .sheet || preparingPresentation { leavePreparation(dismissLibrary: mode == .sheet) } }
            // Escape is Done even when no control has keyboard focus.
            .background {
                if mode == .sheet || preparingPresentation {
                    Button("Done") { leavePreparation(dismissLibrary: mode == .sheet) }.keyboardShortcut(.cancelAction).hidden()
                }
            }
            .alert("Remove saved persona?", isPresented: Binding(get: { removingPersona != nil }, set: { if !$0 { removingPersona = nil } })) {
                Button("Cancel", role: .cancel) { removingPersona = nil }
                Button("Remove", role: .destructive) {
                    if let persona = removingPersona { library.remove(persona.id) }
                    removingPersona = nil
                }
            } message: {
                Text("This removes \(removingPersona?.name ?? "the persona") from the library, groups and active overlays. Its original image is retained for saved scenes. To only hide an on-screen card, use Hide instead.")
            }
            .onAppear { if library.cameraOwnsSlot { source = .camera } }
            .onChange(of: library.liveSource) { _, value in source = value }
            .onDisappear {
                let resuming = launchState.pending?.isResume == true
                if case .failure(let error) = launchState.dismissed(in: library) {
                    reportLaunchFailure(error, resuming: resuming)
                }
            }
            .confirmationDialog("Discard the unsaved layout?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) {
                    unsavedPresentationLayout = false
                    if dismissAfterDiscard { dismiss() } else { preparingPresentation = false }
                }
                Button("Keep editing", role: .cancel) { }
            }
            .sheet(item: $editors.current) { PersonaCardEditor(library: library, session: $0) }
            .sheet(isPresented: $choosingStarter, onDismiss: {
                if let draft = starterDraft { starterDraft = nil; editors.open(.new(draft)) }
            }) {
                PersonaStarterChooser(library: library) { starterDraft = $0 }
            }
            .sheet(item: $editingGroup) { PersonaGroupEditor(library: library, group: $0) }
            .alert("Rename persona", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $name)
                Button("Save") { if let id = renaming { library.rename(id, name: name) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .alert("New persona group", isPresented: $creatingGroup) {
                TextField("Private group name", text: $groupName)
                Button("Create") {
                    do { _ = try library.createGroup(name: groupName, members: library.selectedID.map { [$0] } ?? []) }
                    catch { library.notice = error.localizedDescription }
                }.disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { }
            } message: { Text("The selected persona is included. Choose members to add others. Group names never appear in floating controls.") }
            .alert("Rename group", isPresented: $renamingGroup) {
                TextField("Private group name", text: $groupName)
                Button("Save") { if let id = library.activeGroupID { library.renameGroup(id, name: groupName) } }
                Button("Cancel", role: .cancel) { }
            }
    }

    /// The one empty state while nothing is saved: what a persona is for, with Add starter
    /// portrait… as the prominent first step and the finished-card import beside it.
    private var firstPersona: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.crop.rectangle.stack").font(.system(size: 22)).foregroundStyle(Workbench.accent)
                .frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("No saved personas yet").font(.callout.weight(.semibold))
                Text(onChoose == nil ? "A persona is a picture of you to show over your apps or place in a Present scene. Start from a portrait, or import a card you already made."
                     : "Saved personas appear here to place in this scene. Start from a portrait, or import a card you already made.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Add starter portrait…") { choosingStarter = true }.buttonStyle(.borderedProminent)
                    Button("Import finished card…") { library.importImage() }
                }.disabled(library.isReadOnly).padding(.top, 4)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Workbench.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Workbench.border))
            .accessibilityElement(children: .contain)
    }

    private var groupPicker: some View {
        Picker("Group", selection: Binding(get: { library.activeGroupID }, set: { library.prepareGroup($0) })) {
            Text("All saved · one at a time").tag(UUID?.none)
            ForEach(library.groups) { group in Text(group.name).tag(Optional(group.id)) }
        }.disabled(library.isReadOnly)
    }
    private var groupActions: some View {
        HStack {
            Button("New…") { groupName = ""; creatingGroup = true }.disabled(library.isReadOnly)
                .accessibilityLabel("Create persona group")
            if let group = library.activeGroup {
                Button("Members…") { editingGroup = group }.disabled(library.isReadOnly)
                    .accessibilityLabel("Add or remove persona group members")
                Menu("Edit group") {
                    Button("Choose members…") { editingGroup = group }
                    Button("Rename…") { groupName = group.name; renamingGroup = true }
                    Button("Remove group", role: .destructive) { library.removeGroup(group.id) }
                }.disabled(library.isReadOnly)
            }
        }.fixedSize()
    }
    private var overlayActions: some View {
        HStack(spacing: 10) {
            if library.sessionState.phase == .idle {
                // These name saved artwork only; the camera keeps its own controls.
                if library.artworkVisible {
                    Button("Hide floating persona") { library.hideArtwork() }.buttonStyle(.borderedProminent)
                        .help("Hide keeps this card for Show again")
                    Button("End overlay") { library.endOverlaySession() }
                } else if library.hasHiddenCard {
                    Button("Show again") { requestLaunch(.showAgain) }.buttonStyle(.borderedProminent)
                        .help("Shows the hidden card as it was, whatever is selected")
                    Button("End overlay") { library.endOverlaySession() }
                } else if !library.items.isEmpty {
                    // With nothing saved, the empty state's Add starter portrait… is the one prominent action.
                    Button("Show selected") { requestLaunch(.oneCard) }.buttonStyle(.borderedProminent)
                        .disabled(library.selected.flatMap { library.renderedImage(for: $0) } == nil)
                    Text("Separate from Present").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                if library.sessionState.phase == .paused {
                    Button("Resume overlays") { requestLaunch(.resume) }.buttonStyle(.borderedProminent)
                } else {
                    Button("Hide all") { library.pauseOverlaySession() }.buttonStyle(.borderedProminent)
                }
                Button("End overlays") { library.endOverlaySession() }
                Text(library.sessionState.phase == .paused ? "Hidden · layout retained" : "Overlays active")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if library.voiceAvailable {
                VStack(alignment: .trailing, spacing: 1) {
                    Toggle("React to my voice", isOn: Binding(get: { library.voiceRing }, set: { library.setVoiceRing($0) }))
                        .toggleStyle(.switch).controlSize(.small)
                    if let status = library.voiceStatus {
                        Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    // The switch stays off; the reason and its one fix sit beside it, as on Dictate
                    // and Meetings (#134 Fit rule 2). Only the microphone refusal gets this door.
                    if library.voiceRefusal != nil {
                        // The state in primary words with an orange symbol, beside its one fix; the
                        // button says where to go, so the sentence does not repeat it.
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            PersonaNote("Microphone access is off.")
                            Button("Microphone Settings…") { library.openMicrophoneSettings() }.controlSize(.small)
                                .help("Open Privacy & Security › Microphone in System Settings")
                        }.frame(maxWidth: 420, alignment: .trailing)
                    }
                    if library.voiceRing {
                        HStack(spacing: 8) {
                            InkSwatches(selected: library.voiceColor, purpose: "voice colour") { library.setVoiceColor($0) }
                            // A hairline and the visible word set the well apart from the presets, so it
                            // reads as a picker rather than one more swatch.
                            Divider().frame(height: 16)
                            ColorPicker("Custom", selection: Binding(get: { Color(nsColor: library.voiceColor.nsColor) },
                                                                     set: { library.setVoiceColor(InkColor(NSColor($0))) }), supportsOpacity: false)
                                .font(.caption).foregroundStyle(.secondary).fixedSize().accessibilityLabel("Custom voice colour")
                                .accessibilityValue(library.voiceColor.accessibilityDescription).help("Custom voice colour")
                        }.padding(.top, 3)
                    }
                }
                .help("A ring of dots around the shown persona rises into bars as you speak, so your audience sees who is talking. Workbench listens only while it shows, measures the sound and records nothing. In a prepared set, the ring follows the selected overlay.")
            }
        }
    }
    /// Shown: the live copy, beside its size, lock and position, with Replace
    /// shown and Update shown card when they apply. Browsing Selected below never
    /// changes it.
    @ViewBuilder private var shownPanel: some View {
        // While the camera owns the slot, Size, Position and Lock belong to its
        // bubble, so they are offered there and not repeated here.
        if let shown = library.shownIdentity, !library.cameraOwnsSlot {
            VStack(alignment: .leading, spacing: 10) {
                if let copy = library.selectedLiveCopy, let shape = library.liveShape(of: copy) {
                    Picker("Live appearance", selection: Binding(get: { shape }, set: { library.setLiveShape($0, for: copy) })) {
                        ForEach(PersonaAppearance.Shape.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                }
                // Narrow windows put the actions under the name.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) { shownName(shown); Spacer(minLength: 8); shownActions(shown) }
                    VStack(alignment: .leading, spacing: 8) { shownName(shown); HStack { shownActions(shown) } }
                }
                HStack(spacing: 8) {
                    Text("Size \(Int((library.overlayWidth * 100).rounded()))%")
                        .font(.caption.monospacedDigit()).frame(width: 58, alignment: .leading)
                    Slider(value: Binding(get: { library.overlayWidth }, set: { library.setOverlayWidth($0) }), in: 0.06...0.40)
                        .accessibilityLabel("Size of the shown card, " + shown.name)
                        .help("Width as a percentage of the display; changes the shown card immediately")
                    Menu("Position") {
                        Button("Top left") { library.setOverlayPosition(x: 0.02, y: 0.98) }
                        Button("Top centre") { library.setOverlayPosition(x: 0.5, y: 0.98) }
                        Button("Top right") { library.setOverlayPosition(x: 0.98, y: 0.98) }
                        Divider()
                        Button("Left centre") { library.setOverlayPosition(x: 0.02, y: 0.5) }
                        Button("Right centre") { library.setOverlayPosition(x: 0.98, y: 0.5) }
                        Divider()
                        Button("Bottom left") { library.setOverlayPosition(x: 0.02, y: 0.02) }
                        Button("Bottom centre") { library.setOverlayPosition(x: 0.5, y: 0.02) }
                        Button("Bottom right") { library.setOverlayPosition(x: 0.98, y: 0.02) }
                    }.fixedSize().accessibilityLabel("Position of the shown card, " + shown.name)
                }
                Toggle("Lock artwork · clicks pass through", isOn: Binding(
                    get: { library.overlayLocked }, set: { library.setOverlayLocked($0) }))
                    .accessibilityLabel("Lock the shown card, " + shown.name + ", so clicks pass through")
                Text("Size, position and lock change this card only. Hide keeps it for Show again; End releases it. Your saved personas stay as they are." + (library.shortcutHint.map { " " + $0 } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Workbench.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
            .accessibilityLabel((shown.hidden ? "Hidden card: " : "Shown card: ") + shown.name)
        }
    }
    private func shownName(_ shown: PersonaShownIdentity) -> some View {
        HStack(spacing: 12) {
            Group {
                if let image = shown.image {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                } else { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
            }.frame(width: 54, height: 54).opacity(shown.hidden ? 0.5 : 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text((shown.hidden ? "Hidden: " : "Shown: ") + shown.name).font(.headline).lineLimit(1)
                    .accessibilityLabel((shown.hidden ? "Hidden persona: " : "Shown persona: ") + shown.name)
                Text(shown.place ?? (shown.hidden ? "Kept for Show again" : "Floating over your apps"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private func shownActions(_ shown: PersonaShownIdentity) -> some View {
        if let replacement = library.replacementForShown {
            Button("Replace shown with \(replacement.name)") { library.replaceShownWithSelected() }
                .lineLimit(1)
                .help("Shows \(replacement.name) in this card's place, keeping its size, position and lock")
        }
        if library.shownCardHasNewerLook {
            Button("Update shown card") { library.updateShownCard() }
                .help("Shows \(shown.name) as it is saved now, in this card only")
        }
    }
    private func requestLaunch(_ request: PersonaLibraryLaunchState.Request) {
        if let result = launchState.request(request, from: mode, in: library) {
            if case .failure(let error) = result { reportLaunchFailure(error, resuming: request.isResume) }
        } else { dismiss() }
    }

    private func reportLaunchFailure(_ error: Error, resuming: Bool) {
        let message = error.localizedDescription
        library.notice = message
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = resuming ? "Couldn’t resume overlays" : "Couldn’t start overlays"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func leavePreparation(dismissLibrary: Bool) {
        if preparingPresentation && unsavedPresentationLayout {
            dismissAfterDiscard = dismissLibrary; confirmingDiscard = true
        } else if dismissLibrary { dismiss() } else { preparingPresentation = false }
    }

    @ViewBuilder private func thumbnail(_ persona: SavedPersona, width: CGFloat, height: CGFloat) -> some View {
        if let image = library.renderedImage(for: persona) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: width, height: height)
                .accessibilityLabel(persona.name)
        } else {
            VStack(spacing: 5) {
                Image(systemName: "photo.badge.exclamationmark")
                if width > 100 { Text("Image missing").font(.caption) }
            }.foregroundStyle(.secondary).frame(width: width, height: height)
                .accessibilityLabel("Missing image: " + persona.name)
        }
    }
}

private struct PersonaStarterChooser: View {
    @ObservedObject var library: PersonaLibrary
    /// Receives the chosen starter as a draft; nothing is saved until Add persona.
    let onChoose: (PersonaPortraitDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var thumbnails: [String: NSImage] = [:]
    @State private var loading = true
    @State private var importing = false
    @State private var notice: String?
    private let starters = PersonaStarterLibrary()
    private var available: [PersonaStarter] { PersonaStarterLibrary.portraits.filter { thumbnails[$0.id] != nil } }
    private var selected: PersonaStarter? { available.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a starter portrait").font(.title2.bold())
            Text("Choose one portrait, then choose how it looks: Circle, Card or Original.")
                .font(.callout).foregroundStyle(.secondary)
            if loading {
                ProgressView("Opening portraits…").frame(maxWidth: .infinity, minHeight: 280)
            } else if available.isEmpty {
                ContentUnavailableView("Starter portraits unavailable", systemImage: "person.crop.rectangle",
                    description: Text("This build does not include readable starter portraits. Import your own from Add persona."))
                    .frame(height: 280)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(available) { portrait in
                        Button { selectedID = portrait.id; notice = nil } label: {
                            VStack(spacing: 8) {
                                if let image = thumbnails[portrait.id] {
                                    Image(nsImage: image).resizable().scaledToFit().frame(height: 128)
                                        .frame(maxWidth: .infinity).accessibilityHidden(true)
                                }
                                Text(portrait.label).font(.caption).lineLimit(2).frame(height: 30)
                            }.padding(8).frame(maxWidth: .infinity)
                                .background(selectedID == portrait.id ? Workbench.accent.opacity(0.12) : Color.primary.opacity(0.035),
                                            in: RoundedRectangle(cornerRadius: 10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10).strokeBorder(
                                        selectedID == portrait.id ? Workbench.accent : Color.primary.opacity(0.10),
                                        lineWidth: selectedID == portrait.id ? 2 : 1)
                                }
                                .overlay(alignment: .topTrailing) {
                                    if selectedID == portrait.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Workbench.accent)
                                            .padding(6).accessibilityHidden(true)
                                    }
                                }
                        }.buttonStyle(.plain).accessibilityLabel(portrait.label)
                            .accessibilityValue(selectedID == portrait.id ? "Selected" : "")
                    }
                }
                if available.count < PersonaStarterLibrary.portraits.count {
                    Text("Some starter portraits are unavailable in this build.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let notice { PersonaNote(notice) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use portrait") {
                    guard let selected, !importing else { return }
                    importing = true
                    do { onChoose(try starters.draft(selected, for: library)); dismiss() }
                    catch { notice = error.localizedDescription; importing = false }
                }.keyboardShortcut(.defaultAction).disabled(selected == nil || library.isReadOnly || importing)
            }
        }.padding(24).frame(width: 620).background(Workbench.background).workbenchTheme()
            .task {
                for portrait in PersonaStarterLibrary.portraits {
                    guard !Task.isCancelled else { return }
                    if let image = starters.thumbnail(for: portrait) { thumbnails[portrait.id] = image }
                    await Task.yield()
                }
                loading = false
            }
    }
}

/// Holds a Library image's editor through host and sheet recomputations.
/// It has the same Add/Cancel transaction as Import portrait.
struct PersonaImageImportView: View {
    @ObservedObject var library: PersonaLibrary
    @StateObject private var session: PersonaEditorSession
    init(library: PersonaLibrary, draft: PersonaPortraitDraft) {
        self.library = library
        _session = StateObject(wrappedValue: PersonaEditorSession(.new(draft)))
    }
    var body: some View { PersonaCardEditor(library: library, session: session) }
}

/// What the persona editor changes before Save or Add: a saved persona's
/// appearance, label and colour, or a new portrait's draft. Nothing is written
/// until `commit`, so Cancel, and Escape, which presses Cancel, simply drop it.
final class PersonaEditorSession: ObservableObject, Identifiable {
    enum Subject { case saved(SavedPersona), new(PersonaPortraitDraft) }
    let id = UUID()
    let subject: Subject
    @Published var style: PersonaCardStyle
    /// Circle, Card or Original, with Circle's framing. Card's label and colour
    /// stay in `style` whichever is chosen.
    @Published var appearance: PersonaAppearance
    /// Why the last Add could not save. The draft stays for another try.
    @Published private(set) var failure: String?
    /// False once the saved personas cannot be read: Add is not offered again
    /// until Workbench is reopened, though Cancel still is.
    @Published private(set) var canRetry = true
    /// Saved, added or cancelled: the editor can close.
    private(set) var isFinished = false
    private(set) var committedID: UUID?

    init(_ subject: Subject) {
        self.subject = subject
        switch subject {
        case .saved(let persona): style = persona.card ?? PersonaCardStyle(); appearance = persona.effectiveAppearance
        case .new(let draft): style = draft.card; appearance = draft.appearance
        }
    }
    var isNew: Bool { if case .new = subject { return true }; return false }
    /// The picture every look is drawn from, never changed by the editor.
    func portrait(in library: PersonaLibrary) -> NSImage? {
        switch subject {
        case .saved(let persona): return library.image(named: persona.image)
        case .new(let draft): return draft.portrait
        }
    }

    /// Save, or Add persona. Returns whether the editor can close. An Add that
    /// finds the persona already saved, as a second press would, is done.
    @discardableResult func commit(to library: PersonaLibrary, replacing original: SavedPersona? = nil) -> Bool {
        guard !isFinished else { return true }
        switch subject {
        case .saved(let persona):
            guard library.updateAppearance(persona.id, appearance: appearance, card: style) else { return false }
            committedID = persona.id
        case .new(var draft):
            draft.card = style; draft.appearance = appearance
            do {
                committedID = try original.map { try library.replacePortrait(draft, replacing: $0).id } ?? library.add(draft).id
            }
            catch PersonaError.alreadyAdded { committedID = draft.id }
            catch PersonaError.libraryUnavailable {
                failure = "Couldn’t add this persona: the saved personas are missing, unreadable or from a newer Workbench."
                    + " Reopen Workbench, then add the portrait again."
                canRetry = false
                return false
            }
            catch {
                if original != nil, (error as? PersonaError) == .changedOnDisk {
                    failure = "The saved persona changed while this photo preview was open. Your existing artwork is preserved. Cancel this preview and reopen Workbench to review the persona before replacing its photo."
                    canRetry = false
                    return false
                }
                let reason = (error as? PersonaError) == .changedOnDisk
                    ? "Couldn’t save this persona: the saved personas changed on disk again while it was being saved."
                    : "Couldn’t save this persona. " + error.localizedDescription
                failure = reason + " Your picture and changes are kept here, so you can try saving again."
                return false
            }
        }
        isFinished = true; failure = nil
        return true
    }

    /// Cancel, or Escape: the edits and any new picture go, and nothing is written.
    func cancel() { isFinished = true }
}

/// The one persona editor open at a time. A second draft, from another import
/// or starter, never replaces an open one, so its edits are never lost.
struct PersonaEditorHolder {
    var current: PersonaEditorSession?
    @discardableResult mutating func open(_ subject: PersonaEditorSession.Subject) -> Bool {
        guard current == nil else { return false }
        current = PersonaEditorSession(subject)
        return true
    }
}

/// Edits a saved persona's appearance, or finishes a new editable portrait.
/// Circle, Card and Original are one choice; Circle's framing and Card's label
/// and colour are kept whichever is chosen. A saved persona keeps Save and
/// Cancel. A new portrait is a draft until Add persona, which saves its picture,
/// appearance, selection and group membership together; Cancel or Escape drops
/// it without a trace, and a failed Add keeps it here to try again.
struct PersonaCardEditor: View {
    @ObservedObject var library: PersonaLibrary
    @ObservedObject var session: PersonaEditorSession
    var replacing: SavedPersona? = nil
    var confirmationTitle: String? = nil
    var onSave: ((UUID) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    private var saveTitle: String { confirmationTitle ?? (session.isNew ? "Add persona" : "Save") }
    private var framing: Binding<PersonaFraming> {
        Binding(get: { session.appearance.currentFraming }, set: { session.appearance.framing = $0 })
    }
    var body: some View {
        let portrait = session.portrait(in: library)
        VStack(alignment: .leading, spacing: 14) {
            Text(session.isNew ? "New persona" : "Edit appearance").font(.title2.bold())
            Picker("Appearance", selection: $session.appearance.shape) {
                ForEach(PersonaAppearance.Shape.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            preview(portrait).frame(height: 265).frame(maxWidth: .infinity)
            switch session.appearance.shape {
            case .circle:
                if let portrait {
                    HStack(spacing: 8) {
                        Text("Zoom")
                        Slider(value: Binding(get: { session.appearance.currentFraming.zoom },
                                              set: { session.appearance.framing = session.appearance.currentFraming.zoomed(to: $0, portrait: portrait.size) }),
                               in: PersonaFraming.zoomRange)
                            .accessibilityLabel("Circle zoom")
                        Button("Reset framing") { session.appearance.framing = nil }.disabled(session.appearance.framing == nil)
                    }
                }
                Text("Drag the picture, or focus it and use the arrow keys, to frame it. The label and colour stay with Card.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .card:
                TextField("Visible label", text: $session.style.label).textFieldStyle(.roundedBorder)
                ColorPicker("Background colour", selection: Binding(get: { Color(nsColor: session.style.background.nsColor) },
                    set: { session.style.background = InkColor(NSColor($0)) }), supportsOpacity: false)
                Text("Leave the label empty to hide it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .original:
                Text("Shows the picture exactly as imported, including its transparency and any text in it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(session.isNew ? "Nothing is saved until you choose \(saveTitle)."
                               : "A card already shown keeps its look until you choose Update shown card. Scenes keep their existing copy until you use the persona again.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let failure = session.failure {
                PersonaNote(failure)
            } else if let notice = library.notice { PersonaNote(notice) }
            HStack {
                Button("Cancel") { session.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(saveTitle) {
                    if session.commit(to: library, replacing: replacing) {
                        if let id = session.committedID { onSave?(id) }
                        dismiss()
                    }
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(library.isReadOnly || !session.canRetry || (try? session.style.validated()) == nil
                              || (try? session.appearance.validated()) == nil)
            }
        }.padding(24).frame(width: 420).background(Workbench.background).workbenchTheme()
            // However the sheet closes, an unfinished edit is dropped.
            .onDisappear { session.cancel() }
    }
    @ViewBuilder private func preview(_ portrait: NSImage?) -> some View {
        if let portrait {
            switch session.appearance.shape {
            case .circle:
                PersonaFramingPreview(portrait: portrait, framing: framing)
            case .card, .original:
                if let image = try? session.appearance.image(portrait: portrait, card: session.style) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                        .accessibilityLabel(session.appearance.shape == .card ? "Preview of the card" : "Preview of the original picture")
                }
            }
        } else {
            Label("Image missing", systemImage: "photo.badge.exclamationmark").foregroundStyle(.secondary)
        }
    }
}

/// Circle's framing: the picture under a round window, exactly as Circle draws it.
/// Drag the picture, pinch or use Zoom, or focus it and use the arrow keys;
/// VoiceOver can zoom it and move it with named actions.
struct PersonaFramingPreview: View {
    let portrait: NSImage
    @Binding var framing: PersonaFraming
    var diameter: CGFloat = 240
    @State private var dragStart: PersonaFraming?
    @State private var pinchStart: PersonaFraming?

    /// One arrow-key step: the picture moves a twentieth of the circle that way.
    static func nudged(_ framing: PersonaFraming, _ direction: MoveCommandDirection, diameter: CGFloat, portrait size: CGSize) -> PersonaFraming {
        let step = diameter * 0.05
        let move: CGSize
        switch direction {
        case .left: move = CGSize(width: -step, height: 0)
        case .right: move = CGSize(width: step, height: 0)
        case .up: move = CGSize(width: 0, height: -step)
        case .down: move = CGSize(width: 0, height: step)
        @unknown default: move = .zero
        }
        return framing.dragged(by: move, diameter: diameter, portrait: size)
    }

    var body: some View {
        let size = portrait.size
        let crop = framing.crop(in: size)
        let scale = crop.width > 0 ? diameter / crop.width : 1
        Image(nsImage: portrait).resizable().interpolation(.high)
            .frame(width: size.width * scale, height: size.height * scale)
            .offset(x: -crop.minX * scale, y: -(size.height - crop.maxY) * scale)
            .frame(width: diameter, height: diameter, alignment: .topLeading)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                let start = dragStart ?? framing
                dragStart = start
                framing = start.dragged(by: value.translation, diameter: diameter, portrait: size)
            }.onEnded { _ in dragStart = nil })
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                let start = pinchStart ?? framing
                pinchStart = start
                framing = start.zoomed(to: start.zoom * value.magnification, portrait: size)
            }.onEnded { _ in pinchStart = nil })
            .focusable()
            .onMoveCommand { direction in framing = Self.nudged(framing, direction, diameter: diameter, portrait: size) }
            .accessibilityElement()
            .accessibilityLabel("Circle framing")
            .accessibilityValue("Zoom \(String(format: "%.1f", framing.zoom)) times")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: framing = framing.zoomed(to: framing.zoom + 0.25, portrait: size)
                case .decrement: framing = framing.zoomed(to: framing.zoom - 0.25, portrait: size)
                @unknown default: break
                }
            }
            // VoiceOver moves the picture with the same step as the arrow keys.
            .accessibilityAction(named: "Move left") { framing = Self.nudged(framing, .left, diameter: diameter, portrait: size) }
            .accessibilityAction(named: "Move right") { framing = Self.nudged(framing, .right, diameter: diameter, portrait: size) }
            .accessibilityAction(named: "Move up") { framing = Self.nudged(framing, .up, diameter: diameter, portrait: size) }
            .accessibilityAction(named: "Move down") { framing = Self.nudged(framing, .down, diameter: diameter, portrait: size) }
            .help("Drag to frame the picture in the circle")
    }
}

private struct PersonaGroupEditor: View {
    @ObservedObject var library: PersonaLibrary
    let group: PersonaGroup
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<UUID>
    init(library: PersonaLibrary, group: PersonaGroup) {
        self.library = library; self.group = group; _chosen = State(initialValue: Set(group.personaIDs))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose group members").font(.title2.bold())
            Text(group.name).font(.headline)
            Text("Preparation only. Floating controls use the members chosen when you show this group.")
                .font(.callout).foregroundStyle(.secondary)
            List(library.items) { item in
                Toggle(item.name, isOn: Binding(get: { chosen.contains(item.id) }, set: { if $0 { chosen.insert(item.id) } else { chosen.remove(item.id) } }))
            }.frame(height: 280)
            if let notice = library.notice { PersonaNote(notice) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save members") {
                    let ordered = group.personaIDs.filter { chosen.contains($0) } + library.items.map(\.id).filter { chosen.contains($0) && !group.personaIDs.contains($0) }
                    library.setGroupMembers(ordered, in: group.id)
                    if library.groups.first(where: { $0.id == group.id })?.personaIDs == ordered { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(library.isReadOnly)
            }
        }.padding(24).frame(width: 460).background(Workbench.background).workbenchTheme()
    }
}

/// A problem or caution in Persona: primary words beside an orange filled triangle, as LocalVoice's
/// WorkbenchNote has it (StageKit cannot see that kit). Orange carries only the symbol; it is too
/// faint to read as text on a light sheet. Red stays for recording and removal.
struct PersonaNote: View {
    let text: String
    var font: Font = .caption
    init(_ text: String, font: Font = .caption) { self.text = text; self.font = font }
    var body: some View {
        Label {
            Text(text).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange).accessibilityHidden(true)
        }.font(font).accessibilityElement(children: .combine)
    }
}
