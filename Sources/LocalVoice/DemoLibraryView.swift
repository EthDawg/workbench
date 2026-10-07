import AppKit
import SwiftUI

/// Return belongs to text composition/editing until the search field submits it.
/// Caps Lock and keypad flags do not change the action; modified/repeated keys do.
enum DemoLibraryReturnPolicy {
    static func allows(fromSearch: Bool, editableText: Bool, hasMarkedText: Bool,
                       modifiers: NSEvent.ModifierFlags, isRepeat: Bool) -> Bool {
        !hasMarkedText && !isRepeat && (fromSearch || !editableText)
            && modifiers.intersection([.command, .control, .option, .shift]).isEmpty
    }
}

struct DemoLibraryView: View {
    @ObservedObject var library: DemoLibraryModel
    @ObservedObject var model: AppModel
    var browserDefaults: UserDefaults = .standard
    var onUseImageInPresent: ((DemoLibraryImageSnapshot) -> Void)? = nil
    var onUseImageInPersona: ((DemoLibraryImageSnapshot) -> Void)? = nil
    @FocusState private var searching: Bool
    @State private var removal: DemoResource?
    /// The selected text's own height, so its actions sit under it rather than at the window's foot.
    @State private var contentHeight: CGFloat = 0

    /// Library's Resources section. Library's switcher, in WorkbenchHome, shows Packs and
    /// From iPhone beside it.
    var body: some View { resources }

    private var savedBrowserSettings: SavedBrowserSettings {
        SavedBrowserSettings(resources: library.resources, defaults: browserDefaults)
    }

    @ViewBuilder private var readPreservationRecovery: some View {
        if let problem = library.readPreservationFailure {
            VStack(alignment: .leading, spacing: 6) {
                WorkbenchNote("Workbench couldn’t finish preserving your old Read text. The original is still saved.")
                DisclosureGroup("Details") { Text(problem).font(.caption).textSelection(.enabled) }
                HStack {
                    Button("Retry saving Read text") { library.retryReadPreservation() }
                    Button("Show original saved state") {
                        NSWorkspace.shared.activateFileViewerSelecting([library.readPreservationSource])
                    }
                }
            }
        }
    }

    private var resources: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                // Library's header carries this section's summary (WorkbenchHome.sectionSummaries),
                // so its actions sit at the trailing edge.
                Spacer()
                LibraryPromptButton(model: model).fixedSize().frame(height: 26)
                Menu {
                    // Each opens an editor, so each asks for more (…).
                    Button("New prompt…") { library.newPrompt() }
                    Button("New link…") { library.draft = DemoResource(kind: .link) }
                    Button("Add local file…") { library.chooseFile() }
                    Divider()
                    // Opens the prompt editor with the clipboard's text, so it asks for more (…).
                    // The shortcut shows here and works while this menu is open.
                    Button("Save clipboard as prompt…") { saveClipboard() }.keyboardShortcut("s", modifiers: [.command, .shift])
                    Button("Save Dictate transcript as prompt…") { library.newPrompt(model.transcript) }.disabled(model.transcript.isEmpty)
                } label: { Label("Add", systemImage: "plus") }
                    .disabled(library.savingDisabled || library.importReview != nil).fixedSize()
            }
            HStack(spacing: 10) {
                TextField("Search resources…", text: $library.query)
                    .textFieldStyle(.roundedBorder).focused($searching).accessibilityLabel("Search resources")
                    // Native submission lets Return confirm an IME candidate first.
                    .onSubmit { _ = performReturnAction(fromSearch: true) }
                Toggle(isOn: $library.favoritesOnly) { Image(systemName: library.favoritesOnly ? "star.fill" : "star") }
                    .toggleStyle(.button).help("Show favorites only").accessibilityLabel("Favorites only")
            }
            readPreservationRecovery
            if let problem = library.storageFailure {
                VStack(alignment: .leading, spacing: 6) {
                    WorkbenchNote("Saved resources are preserved. Editing is paused.")
                    DisclosureGroup("Library details") { Text(problem).font(.caption).textSelection(.enabled) }
                    Button("Show saved library") { NSWorkspace.shared.activateFileViewerSelecting([library.store.url]) }
                }
            }
            if let error = library.error {
                HStack(alignment: .top) {
                    WorkbenchNote(error)
                    Spacer()
                    Button { library.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss library error")
                }
            }
            if library.resources.isEmpty && library.savingDisabled {
                WorkbenchEmptyState(symbol: "exclamationmark.triangle", title: "Your saved Library could not be displayed",
                    detail: "Its file has not been replaced.") { EmptyView() }
                    .frame(maxWidth: 520, alignment: .leading).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if library.resources.isEmpty {
                emptyLibrary
            } else if library.matches.isEmpty {
                WorkbenchEmptyState(symbol: "magnifyingglass", title: "No matching resources",
                    detail: "Try other words, or show every resource.") {
                    Button("Clear filters") { library.query = ""; library.favoritesOnly = false }
                }.frame(maxWidth: 520, alignment: .leading).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(selection: $library.selection) {
                        ForEach(library.matches) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: item.kind.symbol).foregroundStyle(Workbench.accent).frame(width: 18).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack { Text(item.title).fontWeight(.medium).lineLimit(2); if item.favorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Workbench.accent) } }
                                    Text(item.group.isEmpty ? item.kind.rawValue : item.group).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }.padding(.vertical, 6).tag(item.id)
                        }
                    // An inset list inside the card: a sidebar style here read as a second sidebar,
                    // with titles too faint to read.
                    }.listStyle(.inset).scrollContentBackground(.hidden).frame(minWidth: 190, idealWidth: 220, maxWidth: 300)
                        .onKeyPress(.return, phases: .down) { _ in performReturnAction(fromSearch: false) }
                    if let item = library.selected { detail(item).frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
                    else {
                        Text("Choose a resource to review or reuse.").foregroundStyle(.secondary)
                            .frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.background(Workbench.surface, in: RoundedRectangle(cornerRadius: Workbench.tileRadius))
                    .clipShape(RoundedRectangle(cornerRadius: Workbench.tileRadius))
                    .overlay(RoundedRectangle(cornerRadius: Workbench.tileRadius).strokeBorder(Workbench.border))
            }
            HStack {
                Text(library.notice ?? footerSummary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Menu {
                    Button("Import library…") { library.importLibrary() }.disabled(library.savingDisabled || library.draft != nil || library.importReview != nil)
                    Button("Export library…") { library.exportLibrary() }.disabled(library.resources.isEmpty)
                    if savedBrowserSettings.hasSavedSettings {
                        Divider()
                        Text("Browser switching is paused")
                        if let summary = savedBrowserSettings.shortcutSummary { Text(summary) }
                        Button("Export saved browser settings…") { library.exportSavedBrowserSettings(savedBrowserSettings) }
                    }
                } label: { Label("More", systemImage: "ellipsis.circle") }.fixedSize().font(.caption)
                    .accessibilityLabel("More library actions")
            }
        }
        .onAppear { focusSearchWhenReady() }
        .onChange(of: model.libraryFocusToken) { _, _ in focusSearchWhenReady() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window === NSApp.mainWindow { focusSearchWhenReady() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { notification in
            if let window = notification.object as? NSWindow, window === NSApp.keyWindow { focusSearchWhenReady() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in focusSearchWhenReady() }
        .onDisappear { library.closePreview() }
        .sheet(item: $library.draft) { item in DemoResourceEditor(library: library, initial: item) }
        .sheet(isPresented: Binding(get: { library.importReview != nil }, set: { if !$0 { library.cancelImport() } })) {
            DemoLibraryImportView(library: library)
        }
        .confirmationDialog("Remove this resource from the library?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("Remove resource", role: .destructive) { if let item = removal { library.remove(item) }; removal = nil }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: { Text("“\(removal?.title ?? "This resource")” will be removed from Library. The original file will stay where it is.") }
        .background {
            Group {
                Button("Find resource") { focusSearchWhenReady() }.keyboardShortcut("f")
                    .disabled(library.draft != nil || library.importReview != nil || removal != nil)
                Button("New prompt…") { library.newPrompt() }.keyboardShortcut("n")
                    .disabled(library.savingDisabled || library.importReview != nil || removal != nil)
                // Save clipboard as prompt lives with the prompts it makes, and keeps ⇧⌘S while
                // they show; it left the Window menu (#134). A closed menu's items never receive
                // a key, so this carries ⇧⌘S until Add is opened. Both call saveClipboard(), and
                // one press reaches only one of them.
                Button("Save clipboard as prompt…") { saveClipboard() }.keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(library.savingDisabled || library.importReview != nil || removal != nil)
            }.hidden()
        }
    }
    /// The count, and the recall key only while it is on: “Off to recall” said nothing useful.
    private var footerSummary: String {
        let count = "\(library.resources.count) \(library.resources.count == 1 ? "resource" : "resources")"
        let recall = model.preferences.shortcut(3)
        return recall.enabled ? count + " · \(recall.label) to recall" : count
    }
    private func performReturnAction(fromSearch: Bool) -> KeyPress.Result {
        guard WorkbenchHome.destination(model.page).section == "library", library.draft == nil, removal == nil,
              let window = NSApp.keyWindow, window === NSApp.mainWindow, window.attachedSheet == nil else { return .ignored }
        let editor = window.firstResponder as? NSTextView
        let event = NSApp.currentEvent
        guard DemoLibraryReturnPolicy.allows(fromSearch: fromSearch, editableText: editor?.isEditable == true,
            hasMarkedText: editor?.hasMarkedText() == true, modifiers: event?.modifierFlags ?? [],
            isRepeat: event?.type == .keyDown && event?.isARepeat == true) else { return .ignored }
        return library.performPrimaryAction() ? .handled : .ignored
    }
    private func focusSearchWhenReady() {
        guard WorkbenchHome.destination(model.page).section == "library", library.draft == nil, library.importReview == nil, removal == nil,
              let window = NSApp.keyWindow, window === NSApp.mainWindow, window.attachedSheet == nil else { return }
        // Recall can reveal a hidden editor before SwiftUI has mounted the search
        // field. Re-arm focus on the next main-loop turn, after the window is key.
        searching = false
        DispatchQueue.main.async {
            guard WorkbenchHome.destination(model.page).section == "library", library.draft == nil, library.importReview == nil, removal == nil,
                  window.attachedSheet == nil, window.isVisible, window === NSApp.keyWindow else { return }
            searching = true
        }
    }
    /// The page's one empty state, centred as a whole empty page is, with the Add menu's own words.
    private var emptyLibrary: some View {
        WorkbenchEmptyState(symbol: "square.stack", title: "Keep something useful",
            detail: "Save a prompt, link or file reference to find it here later. Files stay in their original folders; download cloud files before using them offline.") {
            Group {
                Button("New prompt…") { library.newPrompt() }.buttonStyle(.borderedProminent)
                Button("Add local file…") { library.chooseFile() }
                Button("New link…") { library.draft = DemoResource(kind: .link) }
            }.disabled(library.savingDisabled)
        }.frame(maxWidth: 520, alignment: .leading).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func detail(_ item: DemoResource) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    if !item.group.isEmpty { Text(item.group).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                Spacer()
                Button { library.favorite(item) } label: { Image(systemName: item.favorite ? "star.fill" : "star") }
                    .buttonStyle(.borderless).help(item.favorite ? "Remove favorite" : "Favorite").accessibilityLabel(item.favorite ? "Remove favorite" : "Favorite resource")
                    .disabled(library.savingDisabled)
            }
            if item.kind == .file {
                // What actually happened: found, missing, or there but unreadable.
                WorkbenchStatusBadge(text: item.fileAvailable ? "File found"
                    : item.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } == true ? "Can’t read file" : "File not found",
                    tone: item.fileAvailable ? .done : .attention)
                Text(item.fileName).font(.callout).textSelection(.enabled)
                Text("In \(item.fileLocation)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(item.fileAvailable ? "The original stays in its folder. Keep cloud files downloaded for offline use." : "Connect its drive or locate the file again.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    primaryActionButton(item)
                    Button("Quick Look") { library.preview(item) }
                        .disabled(!item.canPreviewFile)
                        .accessibilityHint("Previews the original file without modifying or copying it.")
                    Button("Show in Finder") { library.open(item, reveal: true) }.disabled(!item.fileAvailable)
                }
                if item.fileAvailable && !item.canOpenFile { Text("Applications and executable files are available in Finder only.").font(.caption).foregroundStyle(.secondary) }
                else if item.fileAvailable && !item.canPreviewFile { Text("This file type opens in its usual app but is not available for Quick Look here.").font(.caption).foregroundStyle(.secondary) }
                if DemoLibraryImageUse.present.supports(item) || DemoLibraryImageUse.persona.supports(item) {
                    ViewThatFits(in: .horizontal) {
                        HStack { imageReuseActions(item) }
                        VStack(alignment: .leading) { imageReuseActions(item) }
                    }
                    Text("Prepare an independent scene or persona. Choose Present or Show when you are ready.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("File details") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.fileURL?.path ?? item.content).font(.caption).textSelection(.enabled)
                        HStack {
                            Button("Copy path") { library.copy(item) }
                            if item.fileAvailable {
                                Button("Change file…") { library.chooseFile(for: item) }.disabled(library.savingDisabled)
                            }
                        }
                    }
                }.font(.caption)
            } else {
                if let target = item.browserTarget {
                    Label("Chrome · \(target.profileName)", systemImage: "arrow.up.forward.app").font(.caption).foregroundStyle(.secondary)
                    Text("Browser switching is paused. The saved profile is kept; opening this link uses your default browser and may use a different profile.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let summary = savedBrowserSettings.shortcutSummary {
                        Text(summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                // As tall as the text, up to a cap, so the actions follow the words.
                ScrollView {
                    Text(item.content).font(Workbench.bodyText).lineSpacing(4).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }.frame(height: min(max(contentHeight, 18), 360))
                HStack {
                    primaryActionButton(item)
                    if item.kind == .link { Button("Copy link") { library.copy(item) } }
                }
                // How the toolbar's Prompts delivers, kept here with the prompts rather than in the picker (#159).
                if item.kind == .prompt {
                    Text("With Present on the toolbar, its Prompts types this into the field in front, or pastes it once where typing isn't supported. Saved Prompts… here copies it for ⌘V. Nothing is submitted automatically.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !item.notes.isEmpty {
                Divider()
                ScrollView { Text(item.notes).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90)
            }
            HStack {
                Button("Edit…") { library.draft = item }.disabled(library.savingDisabled)
                Spacer()
                Button { removal = item } label: { Image(systemName: "trash") }.accessibilityLabel("Remove resource").disabled(library.savingDisabled)
            }.font(.callout).buttonStyle(.borderless)
        }.padding(Workbench.tilePadding)
    }
    @ViewBuilder private func imageReuseActions(_ item: DemoResource) -> some View {
        if DemoLibraryImageUse.present.supports(item), let onUseImageInPresent {
            Button("Use in Present…") {
                if let image = library.prepareImage(item, for: .present) { onUseImageInPresent(image) }
            }.disabled(!item.fileAvailable || !item.canOpenFile)
        }
        if DemoLibraryImageUse.persona.supports(item), let onUseImageInPersona {
            Button("Use in Persona…") {
                if let image = library.prepareImage(item, for: .persona) { onUseImageInPersona(image) }
            }.disabled(!item.fileAvailable || !item.canOpenFile)
        }
    }
    private func primaryActionButton(_ item: DemoResource) -> some View {
        Button { library.performPrimaryAction(expectedID: item.id) } label: {
            HStack(spacing: 8) {
                Text(item.primaryActionTitle)
                Image(systemName: "return").font(.caption).accessibilityHidden(true)
            }
        }
        .buttonStyle(.borderedProminent).disabled(!item.primaryActionAvailable || library.draft != nil || library.importReview != nil
            || (item.kind == .file && !item.fileAvailable && library.savingDisabled))
        .accessibilityLabel(item.primaryActionTitle)
        .accessibilityHint("Press Return from search or the results list.")
        .help("\(item.primaryActionTitle) · Return from search or the results list")
    }
    private func saveClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { library.notice = "Copy some text first."; return }
        library.newPrompt(text)
    }
}

private struct DemoResourceEditor: View {
    @ObservedObject var library: DemoLibraryModel
    @State var item: DemoResource
    @FocusState private var titleFocused: Bool
    init(library: DemoLibraryModel, initial: DemoResource) { self.library = library; _item = State(initialValue: initial) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(library.resources.contains { $0.id == item.id } ? "Edit" : "Save") \(item.kind.rawValue.lowercased())").font(.title2.weight(.semibold))
            TextField("Name", text: $item.title).textFieldStyle(.roundedBorder).focused($titleFocused).accessibilityLabel("Resource name")
            HStack {
                VStack(alignment: .leading, spacing: 5) { Text("Product (optional)").font(.caption).foregroundStyle(.secondary); TextField("Optional", text: $item.product).accessibilityLabel("Product, optional") }
                VStack(alignment: .leading, spacing: 5) { Text("Persona (optional)").font(.caption).foregroundStyle(.secondary); TextField("Optional", text: $item.persona).accessibilityLabel("Persona, optional") }
            }.textFieldStyle(.roundedBorder)
            if item.kind == .prompt {
                Text("Prompt").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $item.content).font(.system(size: 13)).frame(minHeight: 180).accessibilityLabel("Prompt text")
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Workbench.border))
            } else if item.kind == .link {
                TextField("https://…", text: $item.content).textFieldStyle(.roundedBorder).accessibilityLabel("Link URL")
                Text("Opens in your default browser when you choose Open link.").font(.caption).foregroundStyle(.secondary)
            } else {
                Label(item.content, systemImage: "doc").font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                Text("The original file stays in its folder.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Notes (optional)").font(.caption).foregroundStyle(.secondary)
            TextField("Useful context or reminders", text: $item.notes, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder).accessibilityLabel("Notes, optional")
            Toggle("Favorite", isOn: $item.favorite)
            if let problem = item.validationMessage { Text(problem).font(.caption).foregroundStyle(.secondary) }
            if let notice = library.draftNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if let error = library.error { WorkbenchNote(error).lineLimit(3) }
            if let problem = library.storageFailure {
                WorkbenchNote("Saving is paused to preserve the saved Library. Cancel to return to its recovery details.")
                DisclosureGroup("Library details") { Text(problem).font(.caption).textSelection(.enabled) }
            }
            HStack {
                Button("Cancel") { library.draft = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { if library.save(item) { library.draft = nil } }.keyboardShortcut(.defaultAction)
                    .disabled(item.validationMessage != nil || library.savingDisabled)
            }
        }.padding(24).frame(width: 520).onAppear { titleFocused = true }.workbenchTheme()
    }
}
