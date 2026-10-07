import SwiftUI
import AppKit
import ImageIO

struct SnapWorkspaceView: View {
    @ObservedObject var model: SnapModel
    @Binding var selectedIDs: Set<UUID>
    var savedSelectionID: UUID?
    /// The shared selection owner's problem, such as a selection that could not be saved.
    var selectionProblem: String?
    var onAddToNarratedSession: ([UUID]) -> Void = { _ in }
    var onOrganiseHandOff: (String) -> Void = { _ in }
    @State private var reviewingOrganization = false
    @State private var importCandidates: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
            WorkbenchPageHeader("snap", summary: "Capture, mark up and keep what matters.") {
                // ✓ Saved or exported for four seconds, in space kept for it (#134 T5).
                ConfirmationLabel(text: model.confirmation?.kind.rawValue, reserving: SnapConfirmation.texts)
                if model.isCapturing { Button("Cancel capture") { model.cancelCapture() } }
                Menu {
                    Button("Paste image") { model.pasteImage() }
                    Button("Import image…") { model.importImage() }
                    #if !APP_STORE
                    Divider()
                    Button("Import Desktop screenshots…") {
                        if let found = model.desktopScreenshots() {
                            if found.isEmpty { model.notice = "There are no screenshots on the Desktop." } else { importCandidates = found }
                        }
                    }
                    #endif
                } label: { Label("Add image", systemImage: "plus") }.disabled(model.isBusy || model.importingScreenshots)
            }
            HStack(spacing: 10) {
                if let draft = model.draft {
                    Button("Review") { model.reviewDraft() }.buttonStyle(.borderedProminent)
                        .help("Resume the unfinished Snap with its original image and edits")
                    Text("Unfinished Snap · \(draft.title)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    // Region is the page's one accent action; Window and Screen stay neutral.
                    ForEach(SnapCapture.Mode.allCases) { mode in
                        let capture = Button { Task { await model.capture(mode) } } label: {
                            Label(mode.title, systemImage: mode == .region ? "viewfinder" : mode == .window ? "macwindow" : "display")
                        }.disabled(model.isBusy)
                        if mode == .region { capture.buttonStyle(.borderedProminent) } else { capture }
                    }
                }
                Spacer()
                #if APP_STORE
                // A promise about Snap's own captures, true in every build.
                Text("Captures save to History, not the Desktop").font(.caption).foregroundStyle(.secondary)
                #else
                Toggle("Keep new screenshots off the Desktop", isOn: Binding(get: { model.keepsScreenshotsOffDesktop },
                                                                           set: { model.setKeepsScreenshotsOffDesktop($0) }))
                    .toggleStyle(.checkbox).font(.caption).fixedSize().disabled(model.isBusy)
                    .help("Snap never saves to the Desktop. This also sends screenshots taken with the macOS shortcuts to History, by changing where macOS saves them. The menu bar refreshes once to apply it; turning it off restores your previous location.")
                #endif
            }
            if !model.screenAccessGranted { screenAccessCard }
            if model.screenshotRedirectPaused {
                WorkbenchNote("macOS now saves screenshots somewhere else, so Workbench stopped collecting them. Turn Keep new screenshots off the Desktop off, then on, to collect them again.", font: .caption)
            }
            Divider()
            HStack {
                TextField("Search titles, notes and tags", text: $model.search).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search Snaps")
                Picker("Show", selection: $model.showingArchived) { Text("Snaps").tag(false); Text("Archived").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 175)
            }
            if !model.problems.isEmpty {
                DisclosureGroup {
                    ForEach(model.problems, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    Button("Reload history") { model.requestRefresh() }
                } label: {
                    WorkbenchNote("\(model.problems.count) Snap record\(model.problems.count == 1 ? "" : "s") couldn’t be read", selectable: false)
                }
            }
            if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if model.visibleItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: model.search.isEmpty ? "photo.on.rectangle" : "magnifyingglass").font(.largeTitle)
                    Text(emptyTitle).font(.headline)
                    Text(emptyDetail)
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 205, maximum: 310), spacing: 12, alignment: .top)], spacing: 12) {
                        ForEach(model.visibleItems) { item in card(item) }
                    }.padding(.vertical, 4)
                }
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack { selectionSummary; Spacer(); selectionActions }
                VStack(alignment: .leading, spacing: 8) { selectionSummary; selectionActions }
            }
        }.padding(24)
            .confirmationDialog("Import \(importCandidates.count) Desktop screenshot\(importCandidates.count == 1 ? "" : "s") into History?",
                                isPresented: Binding(get: { !importCandidates.isEmpty }, set: { if !$0 { importCandidates = [] } })) {
                Button("Import and Move Originals to Trash") {
                    let files = importCandidates; importCandidates = []
                    Task {
                        let added = await model.importDesktopScreenshots(files)
                        if !added.isEmpty { selectedIDs = Set(added) }
                    }
                }
                Button("Cancel", role: .cancel) { importCandidates = [] }
            } message: {
                Text("Only files macOS marked as screenshots are included. Each is saved in History with its original date before its file moves to the Trash, where you can restore it.")
            }
            .sheet(isPresented: $reviewingOrganization) {
                SnapOrganizationView(model: model, selectedIDs: selectedIDs, savedSelectionID: savedSelectionID,
                    onHandOff: onOrganiseHandOff, onExclude: { ids in selectedIDs.subtract(ids) })
            }
            .onAppear { model.requestRefresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.requestRefresh() }
    }

    /// Region, Window and Screen need Screen Recording (#112). Everything already
    /// saved keeps working, and an image the person already has can still come in.
    private var screenAccessCard: some View {
        CaptureAccessCard(title: "Screen Recording is off for Workbench",
                          detail: "Region, Window and Screen need it to capture. Your Snaps stay here to view, copy, edit and hand off, and you can add an image you already have.",
                          reopenHint: model.suggestsReopenForScreenAccess ? ScreenCaptureAccess.reopenHint : nil,
                          footnote: "Allow Workbench under Privacy & Security › Screen Recording. macOS may ask you to quit and reopen Workbench afterwards. If your organisation manages this Mac, it may keep screen capture off.") {
            Button("Paste image") { model.pasteImage() }.disabled(model.isBusy)
            Button("Import image…") { model.importImage() }.disabled(model.isBusy)
            Spacer(minLength: 8)
            Button("Open System Settings…") { model.openScreenRecordingSettings() }
                .help("Privacy & Security › Screen Recording. Workbench changes no setting itself.")
        }
    }

    private var emptyTitle: String {
        if !model.search.isEmpty { return "No matching Snaps" }
        return model.showingArchived ? "Nothing archived" : "Your Snaps start here"
    }
    private var emptyDetail: String {
        if !model.search.isEmpty { return "Try another title, note or tag. Your selection is kept." }
        if model.showingArchived { return "Archived Snaps stay here until you restore them." }
        if model.draft != nil { return "Review your unfinished Snap, then save it to History." }
        return "Choose Region, Window or Screen, then save your capture here."
    }
    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(selectedIDs.count) Snap\(selectedIDs.count == 1 ? "" : "s") selected").font(.callout.weight(.medium))
            let available = Set(model.items.map(\.id))
            let missing = selectedIDs.subtracting(available)
            let archived = selectedIDs.intersection(model.items.filter { $0.archivedAt != nil }.map(\.id))
            let hidden = selectedIDs.subtracting(Set(model.visibleItems.map(\.id))).subtracting(missing).subtracting(archived).count
            if hidden > 0 { Text("\(hidden) hidden by this view").font(.caption).foregroundStyle(.secondary) }
            if !missing.isEmpty {
                Button("Remove \(missing.count) unavailable from selection") { selectedIDs.subtract(missing) }.font(.caption)
            }
            if !archived.isEmpty {
                Button("Exclude \(archived.count) archived from selection") { selectedIDs.subtract(archived) }.font(.caption)
            }
            if !missing.isEmpty || !archived.isEmpty {
                Text("Other selected evidence stays selected. Use Update in History to change a saved selection.").font(.caption2).foregroundStyle(.secondary)
            }
            if let selectionProblem { Text(selectionProblem).foregroundStyle(.red).font(.caption) }
            // A kept draft disables the selection's actions; say why and where to resolve it.
            if model.draft != nil, !selectedIDs.isEmpty {
                Text("Save or discard the unfinished Snap, using Review above, to use these.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var selectionActions: some View {
        HStack {
            Button("Select visible") { selectedIDs.formUnion(model.visibleItems.map(\.id)) }.disabled(model.visibleItems.isEmpty)
            Button("Clear") { selectedIDs.removeAll() }.disabled(selectedIDs.isEmpty)
            Menu("Use selected") {
                Button("Add to Snap & Talk") { onAddToNarratedSession(Array(selectedIDs)) }
                Button("Organise…") { reviewingOrganization = true }
                Divider()
                Button(model.showingArchived ? "Restore selected" : "Archive selected") { model.archive(selectedIDs, archived: !model.showingArchived) }
            }.disabled(selectedIDs.isEmpty || model.isBusy)
                .help(model.draft != nil ? "Save or discard the unfinished Snap first" : "")
        }
    }
    private func card(_ item: SnapItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Select \(item.title)", isOn: Binding(get: { selectedIDs.contains(item.id) }, set: { value in
                    if value { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) }
                })).labelsHidden().toggleStyle(.checkbox)
                Spacer()
                if item.edit != SnapEdit() { Image(systemName: "pencil").font(.caption).accessibilityLabel("Edited; original preserved") }
            }
            // The image opens read-only, archived or not; Edit… is its own action.
            CapturePreviewButton("View \(item.title)", item: { .snap(item, store: model.store) }, collection: { model.visibleItems.map { .snap($0, store: model.store) } }) {
                // A faint mat, so a tall or wide capture's letterboxing reads as intended.
                SnapThumbnail(model: model, item: item).frame(height: 118).frame(maxWidth: .infinity)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
            Text(item.title).font(.callout.weight(.semibold)).lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(item.source.title) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if !item.tags.isEmpty { Text(item.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            HStack {
                Button("Copy") { model.copy(item.id) }.controlSize(.small)
                if item.archivedAt == nil {
                    Button("Edit…") { model.edit(item.id) }.controlSize(.small).disabled(model.isBusy).accessibilityLabel("Edit \(item.title)")
                        .help(model.draft != nil ? "Save or discard the unfinished Snap first" : "Edit a copy; the original stays")
                }
                Spacer()
                Menu {
                    Button("View image") { CaptureImagePreview.shared.show(.snap(item, store: model.store), collection: model.visibleItems.map { .snap($0, store: model.store) }) }
                    Divider()
                    Button("Export image…") { model.export(item.id) }
                    // Edit… is the card's own button, so the menu holds only what the card does not show.
                    if item.archivedAt == nil {
                        Button("Archive") { model.archive([item.id], archived: true) }
                    } else { Button("Restore") { model.archive([item.id], archived: false) } }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Actions for \(item.title)")
            }
        }.padding(12).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selectedIDs.contains(item.id) ? Workbench.accent : Workbench.border, lineWidth: selectedIDs.contains(item.id) ? 2 : 1))
    }
}

struct SnapThumbnail: View {
    let model: SnapModel
    let item: SnapItem
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) }
        }.task(id: item.revision) {
            // Read and decode away from the main thread, through a store of its
            // own: SnapStore's load state belongs to the main thread's owner.
            let root = model.store.root, id = item.id
            image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let url = try? SnapStore(root: root).imageURL(id),
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
                return NSImage(cgImage: cgImage, size: .zero)
            }.value
        }
    }
}

/// Snap's and Snap & Talk's card for capture access that is off: what stopped, what still
/// works, then its buttons below the words, so a long sentence never squeezes them.
struct CaptureAccessCard<Actions: View>: View {
    let title: String
    let detail: String
    var reopenHint: String?
    var footnote: String?
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A problem reads the same on every page: the kit's note, triangle and primary words.
            WorkbenchNote(title, font: .callout.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { actions() }.padding(.top, 2)
            if let reopenHint {
                Text(reopenHint).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            }
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.workbenchCard()
            .accessibilityElement(children: .contain)
    }
}
