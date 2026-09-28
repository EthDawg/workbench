import SwiftUI

enum PersonaLibraryMode { case sheet, workspace }

/// Sheets release preparation before showing artwork; the independent workspace
/// can act immediately. Consume deferred requests once so unrelated navigation
/// cannot replay an earlier Start or Resume.
struct PersonaLibraryLaunchState {
    enum Request {
        case oneCard
        case prepared(groupIDs: [UUID], softReveal: Bool)
        case resume
        var isResume: Bool { if case .resume = self { return true }; return false }
        func perform(in library: PersonaLibrary) -> Result<Void, Error> {
            switch self {
            case .oneCard: return library.showOverlay()
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
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: UUID?
    @State private var name = ""
    @State private var groupName = ""
    @State private var creatingGroup = false
    @State private var renamingGroup = false
    @State private var editingGroup: PersonaGroup?
    /// The one editor open at a time: a saved card, or a new portrait's draft,
    /// which exists only there until Add persona. A second draft never replaces it.
    @State private var editors = PersonaEditorHolder()
    @State private var choosingStarter = false
    @State private var starterDraft: PersonaPortraitDraft?
    @State private var preparingPresentation = false
    @State private var launchState = PersonaLibraryLaunchState()
    @State private var unsavedPresentationLayout = false
    @State private var confirmingDiscard = false
    @State private var dismissAfterDiscard = false
    @State private var removingPersona: SavedPersona?

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

    private func content(availableWidth: CGFloat) -> some View {
        let usesColumns = availableWidth >= 640
        let layout = usesColumns ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                if preparingPresentation {
                    Button { leavePreparation(dismissLibrary: false) } label: { Label("Personas", systemImage: "chevron.left") }
                }
                Text(preparingPresentation ? "Arrange overlays" : (onChoose == nil ? "Personas" : "Choose persona")).font(.title2.bold())
                Spacer()
                if !preparingPresentation {
                    Menu {
                        Button("Choose a starter portrait…") { choosingStarter = true }
                        Divider()
                        Button("Import portrait for an editable card…") {
                            library.importPortrait(in: NSApp.keyWindow) { editors.open(.new($0)) }
                        }
                        Button("Import finished card…") { library.importImage() }
                        Button("Paste finished image") { library.pasteImage() }
                    } label: { Label("Add persona…", systemImage: "plus.circle.fill") }
                        .menuStyle(.borderlessButton).fixedSize().disabled(library.isReadOnly)
                }
                if mode == .sheet || preparingPresentation {
                    Button("Done") { leavePreparation(dismissLibrary: mode == .sheet) }.keyboardShortcut(.cancelAction)
                }
            }
            if !preparingPresentation {
                Text(onChoose == nil ? "Show a persona card over your apps, or arrange several cards together." : "Choose a persona card to place in this scene.")
                    .font(.callout).foregroundStyle(.secondary)
                if onChoose == nil { overlayActions }
                ViewThatFits(in: .horizontal) {
                    HStack { groupPicker; groupActions }
                    VStack(alignment: .leading, spacing: 8) { groupPicker; groupActions }
                }
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
                            thumbnail(selected, width: 265, height: 155)
                                .frame(maxWidth: .infinity)
                            Text(selected.name).font(.headline).lineLimit(2)
                            Button(role: .destructive) { removingPersona = selected } label: {
                                Label("Remove saved persona…", systemImage: "trash")
                            }.disabled(library.isReadOnly)
                                .help("Remove this library entry and its group memberships; retain artwork used by saved scenes")
                            if selected.card != nil {
                                Button("Edit visible label and colour…") { editors.open(.saved(selected)) }.disabled(library.isReadOnly)
                            } else {
                                Text("Finished artwork stays as imported. For editable text and colour, add a portrait without baked labels.")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            HStack {
                                if let onChoose {
                                    Button("Use in scene") { onChoose(selected); dismiss() }
                                        .disabled(library.renderedImage(for: selected) == nil)
                                }
                            }
                            if onChoose == nil && library.sessionState.phase == .idle {
                                Toggle("Lock artwork · clicks pass through", isOn: Binding(
                                    get: { library.overlayLocked }, set: { library.setOverlayLocked($0) }))
                                HStack(spacing: 8) {
                                    Text("Size \(Int((library.overlayWidth * 100).rounded()))%")
                                        .font(.caption.monospacedDigit()).frame(width: 58, alignment: .leading)
                                    Slider(value: Binding(get: { library.overlayWidth }, set: { library.setOverlayWidth($0) }), in: 0.06...0.40)
                                        .accessibilityLabel("Floating persona size")
                                        .help("Width as a percentage of the display; changes the floating card immediately")
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
                                    }.fixedSize()
                                }
                                Text("Drag Size toward the left for a smaller card. Hide removes it from the screen, not your saved personas." + (library.shortcutHint.map { " " + $0 } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                            Image(systemName: "person.crop.rectangle.stack").font(.system(size: 38)).foregroundStyle(.secondary)
                            Text("Choose or import a persona").font(.headline)
                            Text("Use the same saved image over your browser or inside a Present scene.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if onChoose == nil && (library.overlayVisible || library.sessionState.phase != .idle) {
                            Button("Focus floating controls for keyboard") { library.focusOverlayControls() }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if onChoose == nil {
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
            if let notice = library.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Whole-screen sharing includes preparation and floating controls. Use a persona in a scene when sharing that presentation window.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(width: mode == .sheet ? (preparingPresentation ? 780 : 660) : nil)
            .alert("Remove saved persona?", isPresented: Binding(get: { removingPersona != nil }, set: { if !$0 { removingPersona = nil } })) {
                Button("Cancel", role: .cancel) { removingPersona = nil }
                Button("Remove", role: .destructive) {
                    if let persona = removingPersona { library.remove(persona.id) }
                    removingPersona = nil
                }
            } message: {
                Text("This removes \(removingPersona?.name ?? "the persona") from the library, groups and active overlays. Its original image is retained for saved scenes. To only hide an on-screen card, use Hide instead.")
            }
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
                Button(library.overlayVisible ? "Hide floating persona" : "Show one card") {
                    if library.overlayVisible { library.hideOverlay() }
                    else { requestLaunch(.oneCard) }
                }.buttonStyle(.borderedProminent)
                    .disabled(!library.overlayVisible && library.selected.flatMap { library.renderedImage(for: $0) } == nil)
                Text(library.overlayVisible ? "Shown over your apps" : "Separate from Present")
                    .font(.caption).foregroundStyle(.secondary)
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
                }
                .help("A ring around the shown persona moves as you speak, so your audience sees who is talking. Workbench listens only while it shows, measures loudness and records nothing. In a prepared set, the ring follows the selected overlay.")
            }
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
            Text("Choose one portrait, then edit its role label and background colour.")
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
                                .background(selectedID == portrait.id ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035),
                                            in: RoundedRectangle(cornerRadius: 10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10).strokeBorder(
                                        selectedID == portrait.id ? Color.accentColor : Color.primary.opacity(0.10),
                                        lineWidth: selectedID == portrait.id ? 2 : 1)
                                }
                                .overlay(alignment: .topTrailing) {
                                    if selectedID == portrait.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
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
            if let notice { Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
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

/// What the persona card editor changes before Save or Add: a saved card's
/// label and colour, or a new portrait's draft. Nothing is written until
/// `commit`, so Cancel, and Escape, which presses Cancel, simply drop it.
final class PersonaEditorSession: ObservableObject, Identifiable {
    enum Subject { case saved(SavedPersona), new(PersonaPortraitDraft) }
    let id = UUID()
    let subject: Subject
    @Published var style: PersonaCardStyle
    /// Why the last Add could not save. The draft stays for another try.
    @Published private(set) var failure: String?
    /// False once the saved personas cannot be read: Add is not offered again
    /// until Workbench is reopened, though Cancel still is.
    @Published private(set) var canRetry = true
    /// Saved, added or cancelled: the editor can close.
    private(set) var isFinished = false

    init(_ subject: Subject) {
        self.subject = subject
        switch subject {
        case .saved(let persona): style = persona.card ?? PersonaCardStyle()
        case .new(let draft): style = draft.card
        }
    }
    var isNew: Bool { if case .new = subject { return true }; return false }

    func preview(in library: PersonaLibrary) -> NSImage? {
        switch subject {
        case .saved(let persona): var item = persona; item.card = style; return library.renderedImage(for: item)
        case .new(let draft): return try? PersonaCardRenderer.image(portrait: draft.portrait, style: style)
        }
    }

    /// Save card, or Add persona. Returns whether the editor can close. An Add
    /// that finds the persona already saved, as a second press would, is done.
    @discardableResult func commit(to library: PersonaLibrary) -> Bool {
        guard !isFinished else { return true }
        switch subject {
        case .saved(let persona):
            guard library.updateCard(persona.id, style: style) else { return false }
        case .new(var draft):
            draft.card = style
            do { try library.add(draft) }
            catch PersonaError.alreadyAdded {}
            catch PersonaError.libraryUnavailable {
                failure = "Couldn’t add this persona: the saved personas are missing, unreadable or from a newer Workbench."
                    + " Reopen Workbench, then add the portrait again."
                canRetry = false
                return false
            }
            catch {
                let reason = (error as? PersonaError) == .changedOnDisk
                    ? "Couldn’t add this persona: the saved personas changed on disk again while it was being added."
                    : "Couldn’t add this persona. " + (error.localizedDescription)
                failure = reason + " Your picture and changes are kept here, so you can choose Add persona again."
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

/// Edits a saved card, or finishes a new editable portrait. A saved card keeps
/// Save and Cancel. A new portrait is a draft until Add persona, which saves its
/// picture, card, selection and group membership together; Cancel or Escape
/// drops it without a trace, and a failed Add keeps it here to try again.
struct PersonaCardEditor: View {
    @ObservedObject var library: PersonaLibrary
    @ObservedObject var session: PersonaEditorSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(session.isNew ? "New persona card" : "Edit persona card").font(.title2.bold())
            TextField("Visible label", text: $session.style.label).textFieldStyle(.roundedBorder)
            ColorPicker("Background colour", selection: Binding(get: { Color(nsColor: session.style.background.nsColor) },
                set: { session.style.background = InkColor(NSColor($0)) }), supportsOpacity: false)
            if let image = session.preview(in: library) {
                Image(nsImage: image).resizable().scaledToFit().frame(height: 265).frame(maxWidth: .infinity)
                    .accessibilityLabel("Preview of the persona card")
            }
            Text(session.isNew ? "Nothing is saved until you choose Add persona. Leave the label empty to hide it."
                               : "Leave the label empty to hide it. Scenes keep their existing copy until you use the card again.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let failure = session.failure {
                Text(failure).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if let notice = library.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Cancel") { session.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(session.isNew ? "Add persona" : "Save card") { if session.commit(to: library) { dismiss() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(library.isReadOnly || !session.canRetry || (try? session.style.validated()) == nil)
            }
        }.padding(24).frame(width: 420).background(Workbench.background).workbenchTheme()
            // However the sheet closes, an unfinished edit is dropped.
            .onDisappear { session.cancel() }
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
            if let notice = library.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
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
