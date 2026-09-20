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
    @FocusState private var searching: Bool
    @State private var removal: DemoResource?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Saved resources", selection: $model.showingPhonePhotos) {
                Text("Resources").tag(false)
                Text("From iPhone").tag(true)
            }.pickerStyle(.segmented).frame(maxWidth: 340)
                .accessibilityIdentifier("saved.collection")
            if model.showingPhonePhotos {
                PhotoHandoffView(handoff: model.photoHandoff, onUseAsBackdrop: model.onUsePhotoAsBackdrop)
            } else {
                resources
            }
        }
        .onChange(of: model.libraryFocusToken) { _, _ in model.showingPhonePhotos = false }
    }

    private var resources: some View {
        VStack(alignment: .leading, spacing: 16) {
            ChromeConnectionView(presenter: model.presenter)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Ready when they ask.").font(.system(size: 30, weight: .semibold)).tracking(-0.8)
                    Text("Find a prompt, video, deck, or demo link by product or persona.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("New prompt") { library.newPrompt() }
                    Button("New link") { library.draft = DemoResource(kind: .link) }
                    Button("Add local file…") { library.chooseFile() }
                    Divider()
                    Button("Save clipboard as prompt") { saveClipboard() }
                    Button("Save current transcript") { library.newPrompt(model.transcript) }.disabled(model.transcript.isEmpty)
                } label: { Label("Add", systemImage: "plus") }
                    .disabled(library.savingDisabled).fixedSize()
            }
            HStack(spacing: 10) {
                TextField("Search resources, products, personas…", text: $library.query)
                    .textFieldStyle(.roundedBorder).focused($searching).accessibilityLabel("Search demo library")
                    // Native submission lets Return confirm an IME candidate first.
                    .onSubmit { _ = performReturnAction(fromSearch: true) }
                Toggle(isOn: $library.favoritesOnly) { Image(systemName: library.favoritesOnly ? "star.fill" : "star") }
                    .toggleStyle(.button).help("Show favorites only").accessibilityLabel("Favorites only")
            }
            if let error = library.error {
                HStack(alignment: .top) {
                    Text(error).textSelection(.enabled)
                    Spacer()
                    if library.savingDisabled { Button("Show saved library") { NSWorkspace.shared.activateFileViewerSelecting([library.store.url]) } }
                    else { Button { library.error = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss library error") }
                }.font(.caption).foregroundStyle(.orange)
            }
            if library.resources.isEmpty {
                emptyLibrary
            } else if library.matches.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.title)
                    Text("No matching resources.").font(.headline)
                    Button("Clear filters") { library.query = ""; library.favoritesOnly = false }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    }.listStyle(.sidebar).frame(minWidth: 190, idealWidth: 220, maxWidth: 300)
                        .onKeyPress(.return, phases: .down) { _ in performReturnAction(fromSearch: false) }
                    if let item = library.selected { detail(item).frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
                }.background(Workbench.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                Text(library.notice ?? "\(library.resources.count) \(library.resources.count == 1 ? "resource" : "resources") · \(model.preferences.shortcut(3).label) to recall")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Menu {
                    Button("Import library…") { library.importLibrary() }.disabled(library.savingDisabled)
                    Button("Export library…") { library.exportLibrary() }.disabled(library.resources.isEmpty)
                } label: { Label("Library", systemImage: "ellipsis.circle") }.fixedSize().font(.caption)
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
        .confirmationDialog("Remove this resource from the library?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("Remove resource", role: .destructive) { if let item = removal { library.remove(item) }; removal = nil }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: { Text("The original file will stay where it is.") }
        .background {
            Group {
                Button("Find resource") { searching = true }.keyboardShortcut("f")
                Button("New prompt") { library.newPrompt() }.keyboardShortcut("n").disabled(library.savingDisabled)
            }.hidden()
        }
    }
    private func performReturnAction(fromSearch: Bool) -> KeyPress.Result {
        guard model.page == "library", !model.showingPhonePhotos, library.draft == nil, removal == nil,
              let window = NSApp.keyWindow, window === NSApp.mainWindow, window.attachedSheet == nil else { return .ignored }
        let editor = window.firstResponder as? NSTextView
        let event = NSApp.currentEvent
        guard DemoLibraryReturnPolicy.allows(fromSearch: fromSearch, editableText: editor?.isEditable == true,
            hasMarkedText: editor?.hasMarkedText() == true, modifiers: event?.modifierFlags ?? [],
            isRepeat: event?.type == .keyDown && event?.isARepeat == true) else { return .ignored }
        return library.performPrimaryAction() ? .handled : .ignored
    }
    private func focusSearchWhenReady() {
        guard model.page == "library", !model.showingPhonePhotos, library.draft == nil, let window = NSApp.keyWindow, window === NSApp.mainWindow else { return }
        // Recall can reveal a hidden editor before SwiftUI has mounted the search
        // field. Re-arm focus on the next main-loop turn, after the window is key.
        searching = false
        DispatchQueue.main.async {
            guard model.page == "library", !model.showingPhonePhotos, library.draft == nil, window.isVisible, window === NSApp.keyWindow else { return }
            searching = true
        }
    }
    private var emptyLibrary: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 42, weight: .light)).foregroundStyle(Workbench.accent)
            Text("Your next demo, within reach.").font(.title2.weight(.medium))
            Text("Keep useful prompts, launch links, and local files together.\nSearch a product or persona when you need it.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Add a prompt") { library.newPrompt() }.buttonStyle(.borderedProminent)
                Button("Add a file…") { library.chooseFile() }
                Button("Add a link") { library.draft = DemoResource(kind: .link) }
            }.disabled(library.savingDisabled)
            Text("Files open in their usual app. Download cloud media before an offline demo.")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Label(item.fileAvailable ? "File found" : "File needs attention", systemImage: item.fileAvailable ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.caption).foregroundStyle(item.fileAvailable ? Workbench.accent : .orange)
                Text(item.fileURL?.path ?? item.content).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(5)
                Text(item.fileAvailable ? "Opens in its usual app. Keep cloud files downloaded for an offline demo." : "Connect its drive or locate the file again.")
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
                Button("Locate file…") { library.chooseFile(for: item) }.disabled(library.savingDisabled)
            } else {
                if let target = item.browserTarget {
                    Label("Chrome · \(target.profileName)", systemImage: "arrow.up.forward.app").font(.caption).foregroundStyle(.secondary)
                    Button("Use default browser instead") { var copy = item; copy.browserTarget = nil; _ = library.save(copy) }
                        .font(.caption).disabled(library.savingDisabled)
                }
                ScrollView { Text(item.content).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: .infinity)
                HStack {
                    primaryActionButton(item)
                    if item.kind == .link { Button("Copy link") { library.copy(item) } }
                    else { Button("Read aloud") { model.speechText = item.content; model.page = "speak" } }
                }
            }
            if !item.notes.isEmpty {
                Divider()
                ScrollView { Text(item.notes).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Edit") { library.draft = item }.disabled(library.savingDisabled)
                if item.kind == .file { Button("Copy path") { library.copy(item) } }
                Spacer()
                Button { removal = item } label: { Image(systemName: "trash") }.accessibilityLabel("Remove resource").disabled(library.savingDisabled)
            }.font(.caption).buttonStyle(.borderless)
        }.padding(18)
    }
    private func primaryActionButton(_ item: DemoResource) -> some View {
        Button { library.performPrimaryAction() } label: {
            HStack(spacing: 8) {
                Text(item.primaryActionTitle)
                Image(systemName: "return").font(.caption).accessibilityHidden(true)
            }
        }
        .buttonStyle(.borderedProminent).disabled(!item.primaryActionAvailable || library.draft != nil)
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
                VStack(alignment: .leading, spacing: 5) { Text("Product or demo").font(.caption).foregroundStyle(.secondary); TextField("Optional", text: $item.product).accessibilityLabel("Product or demo") }
                VStack(alignment: .leading, spacing: 5) { Text("Persona").font(.caption).foregroundStyle(.secondary); TextField("Optional", text: $item.persona).accessibilityLabel("Persona") }
            }.textFieldStyle(.roundedBorder)
            if item.kind == .prompt {
                Text("Prompt").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $item.content).font(.system(size: 13)).frame(minHeight: 180).accessibilityLabel("Prompt text")
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Workbench.border))
            } else if item.kind == .link {
                TextField("https://…", text: $item.content).textFieldStyle(.roundedBorder).accessibilityLabel("Demo URL")
                Text("Opens in your default browser when you choose Open link.").font(.caption).foregroundStyle(.secondary)
            } else {
                Label(item.content, systemImage: "doc").font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                Text("The original file stays in its folder.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Preparation notes").font(.caption).foregroundStyle(.secondary)
            TextField("Starting step, fallback, or context (optional)", text: $item.notes, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder).accessibilityLabel("Preparation notes")
            Toggle("Favorite", isOn: $item.favorite)
            if let problem = item.validationMessage { Text(problem).font(.caption).foregroundStyle(.secondary) }
            if let notice = library.draftNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if let error = library.error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3) }
            HStack {
                Button("Cancel") { library.draft = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { if library.save(item) { library.draft = nil } }.keyboardShortcut(.defaultAction)
                    .disabled(item.validationMessage != nil || library.savingDisabled)
            }
        }.padding(24).frame(width: 520).onAppear { titleFocused = true }.workbenchTheme()
    }
}
