import SwiftUI
import AppKit
import ImageIO

struct SnapWorkspaceView: View {
    @ObservedObject var model: SnapModel
    @Binding var selectedIDs: Set<UUID>
    var savedSelectionID: UUID?
    var selectionControls = AnyView(EmptyView())
    var onHandOff: () -> Void = {}
    var onAddToNarratedSession: ([UUID]) -> Void = { _ in }
    var onOrganiseHandOff: (String) -> Void = { _ in }
    @State private var reviewingOrganization = false
    @State private var tidyCandidates: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Snap").font(.largeTitle.weight(.semibold))
                    Text("Capture, mark up and keep what matters.").foregroundStyle(.secondary)
                }
                Spacer()
                if model.isCapturing { Button("Cancel capture") { model.cancelCapture() } }
                Menu {
                    Button("Paste image") { model.pasteImage() }
                    Button("Import image…") { model.importImage() }
                } label: { Label("Add image", systemImage: "plus") }.disabled(model.isBusy)
            }
            HStack(spacing: 10) {
                ForEach(SnapCapture.Mode.allCases) { mode in
                    Button { Task { await model.capture(mode) } } label: {
                        Label(mode.title, systemImage: mode == .region ? "viewfinder" : mode == .window ? "macwindow" : "display")
                    }.disabled(model.isBusy)
                }
                Spacer()
                #if APP_STORE
                Text("No Desktop files").font(.caption).foregroundStyle(.secondary)
                #else
                Menu {
                    Toggle("Keep new screenshots off the Desktop", isOn: Binding(get: { model.keepsScreenshotsOffDesktop },
                                                                               set: { model.setKeepsScreenshotsOffDesktop($0) }))
                    Button("Tidy Desktop screenshots…") {
                        let found = model.desktopScreenshots()
                        if found.isEmpty { model.notice = "There are no screenshots on the Desktop." } else { tidyCandidates = found }
                    }
                } label: {
                    Label(model.keepsScreenshotsOffDesktop ? "Screenshots go to Snap" : "Desktop screenshots", systemImage: "menubar.dock.rectangle")
                }.fixedSize().disabled(model.isBusy || model.tidyingScreenshots)
                    .help("Snap never saves to the Desktop. These choices also gather screenshots taken with macOS shortcuts.")
                #endif
            }
            if model.screenshotRedirectPaused {
                Text("macOS now saves screenshots somewhere else, so Workbench stopped collecting them. Turn Keep new screenshots off the Desktop off, then on, to collect them again.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                TextField("Search titles, notes and tags", text: $model.search).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search Snap History")
                Picker("History", selection: $model.showingArchived) { Text("History").tag(false); Text("Archived").tag(true) }
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
            selectionControls
            ViewThatFits(in: .horizontal) {
                HStack { selectionSummary; Spacer(); selectionActions }
                VStack(alignment: .leading, spacing: 8) { selectionSummary; selectionActions }
            }
        }.padding(24)
            .sheet(item: $model.draft) { draft in SnapEditorView(model: model, draft: draft) }
            .confirmationDialog("Move \(tidyCandidates.count) screenshot\(tidyCandidates.count == 1 ? "" : "s") into Snap History?",
                            isPresented: Binding(get: { !tidyCandidates.isEmpty }, set: { if !$0 { tidyCandidates = [] } })) {
            Button("Move \(tidyCandidates.count) screenshot\(tidyCandidates.count == 1 ? "" : "s")") {
                let files = tidyCandidates; tidyCandidates = []
                Task { await model.tidyDesktopScreenshots(files) }
            }
            Button("Cancel", role: .cancel) { tidyCandidates = [] }
        } message: {
            Text("Only files macOS marked as screenshots are moved. Each is added to Snap History first, with its original date; the originals then go to the Trash, where you can restore them.")
        }
        .sheet(isPresented: $reviewingOrganization) {
                SnapOrganizationView(model: model, selectedIDs: selectedIDs, savedSelectionID: savedSelectionID,
                    onHandOff: onOrganiseHandOff, onExclude: { ids in selectedIDs.subtract(ids) })
            }
            .onAppear { model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    private var emptyTitle: String {
        if !model.search.isEmpty { return "No matching Snaps" }
        return model.showingArchived ? "Nothing archived" : "Your Snap History starts here"
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
                Text("Other selected evidence stays selected. Use Update to change a saved selection.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private var selectionActions: some View {
        HStack {
            Button("Select visible") { selectedIDs.formUnion(model.visibleItems.map(\.id)) }.disabled(model.visibleItems.isEmpty)
            Button("Clear") { selectedIDs.removeAll() }.disabled(selectedIDs.isEmpty)
            Menu("Use selected") {
                Button("Hand off…", action: onHandOff)
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
            Button { if item.archivedAt == nil { model.edit(item.id) } } label: {
                SnapThumbnail(model: model, item: item).frame(height: 118).frame(maxWidth: .infinity)
            }.buttonStyle(.plain).accessibilityLabel("Edit \(item.title)").disabled(item.archivedAt != nil)
            Text(item.title).font(.callout.weight(.semibold)).lineLimit(2).frame(height: 34, alignment: .topLeading)
            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            if !item.tags.isEmpty { Text(item.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            HStack {
                Button("Copy") { model.copy(item.id) }.controlSize(.small)
                Spacer()
                Menu {
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

private struct SnapThumbnail: View {
    let model: SnapModel
    let item: SnapItem
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) }
        }.task(id: item.revision) {
            guard let url = try? model.store.imageURL(item.id),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { image = nil; return }
            image = NSImage(cgImage: cgImage, size: .zero)
        }
    }
}
