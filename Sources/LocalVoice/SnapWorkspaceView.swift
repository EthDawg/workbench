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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Snap").font(.largeTitle.weight(.semibold))
                    Text("Capture, mark up and keep what matters.").foregroundStyle(.secondary)
                }
                Spacer()
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
                ForEach(SnapCapture.Mode.allCases) { mode in
                    Button { Task { await model.capture(mode) } } label: {
                        Label(mode.title, systemImage: mode == .region ? "viewfinder" : mode == .window ? "macwindow" : "display")
                    }.disabled(model.isBusy)
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
                Text("macOS now saves screenshots somewhere else, so Workbench stopped collecting them. Turn Keep new screenshots off the Desktop off, then on, to collect them again.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                TextField("Search titles, notes and tags", text: $model.search).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search Snaps")
                Picker("Show", selection: $model.showingArchived) { Text("Snaps").tag(false); Text("Archived").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 175)
            }
            if !model.problems.isEmpty {
                DisclosureGroup("\(model.problems.count) Snap record\(model.problems.count == 1 ? " needs" : "s need") attention") {
                    ForEach(model.problems, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    Button("Reload history") { model.refresh() }
                }.foregroundStyle(.orange)
            }
            if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if model.visibleItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: model.search.isEmpty ? "photo.on.rectangle" : "magnifyingglass").font(.largeTitle)
                    Text(emptyTitle).font(.headline)
                    Text(model.search.isEmpty ? (model.showingArchived ? "Archived Snaps stay here until you restore them." : "Choose Region, Window or Screen, then save your capture here.") : "Try another title, note or tag. Your selection is kept.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 205, maximum: 310), spacing: 12)], spacing: 12) {
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
            .sheet(item: $model.draft) { draft in SnapEditorView(model: model, draft: draft) }
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
            .onAppear { model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    /// Region, Window and Screen need Screen Recording (#112). Everything already
    /// saved keeps working, and an image the person already has can still come in.
    private var screenAccessCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Screen Recording is off for Workbench", systemImage: "rectangle.dashed.badge.record")
                .font(.callout.weight(.semibold))
            Text("Region, Window and Screen need it to capture. Your Snaps stay here to view, copy, edit and hand off, and you can add an image you already have.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Paste image") { model.pasteImage() }.disabled(model.isBusy)
                Button("Import image…") { model.importImage() }.disabled(model.isBusy)
                Spacer(minLength: 8)
                Button("Open System Settings…") { model.openScreenRecordingSettings() }
                    .help("Privacy & Security → Screen Recording. Workbench changes no setting itself.")
            }
            if model.suggestsReopenForScreenAccess {
                Text(ScreenCaptureAccess.reopenHint).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            }
            Text("Allow Workbench under Privacy & Security → Screen Recording. macOS may ask you to quit and reopen Workbench afterwards. If your organisation manages this Mac, it may keep screen capture off.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.25)))
            .accessibilityElement(children: .contain)
    }

    private var emptyTitle: String {
        if !model.search.isEmpty { return "No matching Snaps" }
        return model.showingArchived ? "Nothing archived" : "Your Snaps start here"
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
        }
    }
    private func card(_ item: SnapItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Select \(item.title)", isOn: Binding(get: { selectedIDs.contains(item.id) }, set: { value in
                    if value { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) }
                })).labelsHidden().toggleStyle(.checkbox)
                Text(item.source.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if item.edit != SnapEdit() { Image(systemName: "pencil").font(.caption).accessibilityLabel("Edited; original preserved") }
            }
            // The image opens read-only, archived or not; Edit… is its own action.
            CapturePreviewButton("View \(item.title)", item: { .snap(item, store: model.store) }) {
                SnapThumbnail(model: model, item: item).frame(height: 118).frame(maxWidth: .infinity)
            }
            Text(item.title).font(.callout.weight(.semibold)).lineLimit(2).frame(height: 34, alignment: .topLeading)
            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            if !item.tags.isEmpty { Text(item.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            HStack {
                Button("Copy") { model.copy(item.id) }.controlSize(.small)
                if item.archivedAt == nil {
                    Button("Edit…") { model.edit(item.id) }.controlSize(.small).disabled(model.isBusy).accessibilityLabel("Edit \(item.title)")
                }
                Spacer()
                Menu {
                    Button("View image") { CaptureImagePreview.shared.show(.snap(item, store: model.store)) }
                    Divider()
                    Button("Export image…") { model.export(item.id) }
                    if item.archivedAt == nil {
                        Button("Edit…") { model.edit(item.id) }
                        Button("Archive") { model.archive([item.id], archived: true) }
                    } else { Button("Restore") { model.archive([item.id], archived: false) } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(item.title)")
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
