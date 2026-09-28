import SwiftUI
import AppKit
import ImageIO

/// History's kind filters. Archived shows archived Snaps; results have no
/// archive yet. A filter only changes what is shown, never what is selected.
enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, transcripts, snaps, results, archived
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All"
        case .transcripts: "Transcripts"
        case .snaps: "Snaps"
        case .results: "Results"
        case .archived: "Archived"
        }
    }
}

/// How one visit to History begins: its filter and, after Hand off, the task
/// to reveal. Each door makes a new one, so it applies even when History is
/// already showing.
struct HistoryDoor: Equatable {
    var id = UUID()
    var filter = HistoryFilter.all
    var job: UUID? = nil
}

/// One row of History, read from the store that already owns it.
enum HistoryEntry: Identifiable {
    case transcript(Transcript)
    case snap(SnapItem)
    case result(HandoffJob)

    enum ID: Hashable { case transcript(UUID), snap(UUID), result(UUID) }
    var id: ID {
        switch self {
        case .transcript(let item): .transcript(item.id)
        case .snap(let item): .snap(item.id)
        case .result(let job): .result(job.id)
        }
    }
    var date: Date {
        switch self {
        case .transcript(let item): item.date
        case .snap(let item): item.createdAt
        case .result(let job): job.createdAt
        }
    }
    /// Equal times keep one order: results, then Snaps, then transcripts.
    fileprivate var tieBreak: (Int, String) {
        switch self {
        case .result(let job): (0, job.id.uuidString)
        case .snap(let item): (1, item.id.uuidString)
        case .transcript(let item): (2, item.id.uuidString)
        }
    }
}

/// Whether the live item behind a task's frozen input is still in History.
enum HistoryInputAvailability: Equatable {
    case inHistory, archived, removed, missing, notInHistory
    /// Said beside the frozen copy; nothing when the item is still in History.
    var label: String? {
        switch self {
        case .inHistory: nil
        case .archived: "Archived since · saved copy kept"
        case .removed: "Removed since · saved copy kept"
        case .missing: "Missing · saved copy kept"
        case .notInHistory: "From Snap & Talk · saved copy kept"
        }
    }
}

/// The page's logic, kept apart from its view so checks can run it on
/// synthetic stores. Each kind keeps its own search.
@MainActor
enum HistoryList {
    /// One newest-first list. Transcripts use their existing matcher, Snaps
    /// SnapModel's search (which includes the text read from each image) and
    /// results their title and task text. Every term must match.
    static func entries(transcripts: [Transcript], snaps: [SnapItem], results: [HandoffJob],
                        filter: HistoryFilter, query: String,
                        matchTranscripts: ([Transcript], String) -> [Transcript],
                        matchSnap: (SnapItem, String) -> Bool,
                        resultText: (HandoffJob) -> String) -> [HistoryEntry] {
        var found: [HistoryEntry] = []
        if filter == .all || filter == .transcripts {
            found += matchTranscripts(transcripts, query).map(HistoryEntry.transcript)
        }
        if filter == .all || filter == .snaps || filter == .archived {
            let archived = filter == .archived
            found += snaps.filter { ($0.archivedAt != nil) == archived && matchSnap($0, query) }.map(HistoryEntry.snap)
        }
        if filter == .all || filter == .results {
            let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
            found += results.filter { job in
                guard !terms.isEmpty else { return true }
                let text = job.title + "\n" + resultText(job)
                return terms.allSatisfy { text.localizedCaseInsensitiveContains($0) }
            }.map(HistoryEntry.result)
        }
        return found.sorted { $0.date != $1.date ? $0.date > $1.date : $0.tieBreak < $1.tieBreak }
    }

    static func availability(of reference: WorkbenchItemReference, transcripts: Set<UUID>,
                             snaps: [UUID: SnapItem]) -> HistoryInputAvailability {
        switch reference.kind {
        case .transcript: return transcripts.contains(reference.id) ? .inHistory : .removed
        case .snap:
            guard let item = snaps[reference.id] else { return .missing }
            return item.archivedAt == nil ? .inHistory : .archived
        case .snapAndTalk: return .notInHistory
        }
    }

    /// Selected items this view does not show, each with the reason a person
    /// needs: hidden by the filter or search, an archived Snap, or gone.
    struct SelectionNotes: Equatable {
        var hidden = 0
        var archivedSnaps: Set<UUID> = []
        var missingTranscripts: Set<UUID> = []
        var unavailable: Set<WorkbenchItemReference> = []
    }

    static func selectionNotes(selected: Set<WorkbenchItemReference>, shown: Set<HistoryEntry.ID>,
                               transcripts: Set<UUID>, snaps: [UUID: SnapItem]) -> SelectionNotes {
        var notes = SelectionNotes()
        for reference in selected {
            switch reference.kind {
            case .transcript:
                if !transcripts.contains(reference.id) { notes.missingTranscripts.insert(reference.id) }
                else if !shown.contains(.transcript(reference.id)) { notes.hidden += 1 }
            case .snap:
                if let item = snaps[reference.id] {
                    if item.archivedAt != nil { notes.archivedSnaps.insert(reference.id) }
                    else if !shown.contains(.snap(reference.id)) { notes.hidden += 1 }
                } else { notes.unavailable.insert(reference) }
            case .snapAndTalk: notes.unavailable.insert(reference)
            }
        }
        return notes
    }
}

/// History: transcripts, Snaps and Hand off results in one newest-first list,
/// with one search, kind filters and the shared selection footer that holds
/// the page's only Hand off. It reads the existing stores and owns none.
struct HistoryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var snap: SnapModel
    @ObservedObject private var library: WorkbenchHistoryModel
    @ObservedObject private var jobs: HandoffJobsModel
    var applySuggestedMetadata: (HandoffJob, String) -> Void
    @State private var filter: HistoryFilter
    @State private var query = ""
    @State private var expandedResult: UUID?
    @State private var revealed: UUID?
    @State private var revealRequest: UUID?
    @State private var showingConnections = false
    @State private var original: Transcript?
    @State private var details: Transcript?
    @State private var removal: TranscriptRemoval?

    init(model: AppModel, snap: SnapModel, applySuggestedMetadata: @escaping (HandoffJob, String) -> Void) {
        self.model = model; self.snap = snap
        self.library = model.historyLibrary; self.jobs = model.handoffJobs
        self.applySuggestedMetadata = applySuggestedMetadata
        _filter = State(initialValue: model.historyDoor?.filter ?? .all)
    }

    var body: some View {
        let transcriptIDs = Set(model.history.map(\.id))
        let snapsByID = Dictionary(snap.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let entries = HistoryList.entries(transcripts: model.history, snaps: snap.items, results: jobs.visibleJobs,
            filter: filter, query: query, matchTranscripts: { library.matching($0, query: $1) },
            matchSnap: { snap.matches($0, query: $1) }, resultText: { jobs.inputs($0).task })
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("History").font(.largeTitle.weight(.semibold))
                    Text("What you dictated, snapped and handed off, newest first.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Connections…") { showingConnections = true }
            }
            runningTask
            notices
            if model.history.isEmpty && snap.items.isEmpty && jobs.jobs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Dictations, Snaps and Hand off results land here, newest first.").font(.headline)
                    let dictate = model.preferences.dictationShortcut
                    Text(dictate.enabled ? "Press \(dictate.label) to dictate, or choose Snap in the menu bar." : "Choose Dictate or Snap in the menu bar.")
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextField("Search transcripts, Snaps and results", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search History")
                Picker("Show", selection: $filter) {
                    ForEach(HistoryFilter.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Show in History")
                if entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: query.isEmpty ? "tray" : "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                        Text(query.isEmpty ? emptyFilterTitle : "Nothing matches this search").font(.headline)
                        Text("Your selection is kept.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list(entries, transcripts: transcriptIDs, snaps: snapsByID)
                }
            }
            footer(shown: Set(entries.map(\.id)), transcripts: transcriptIDs, snaps: snapsByID)
        }.padding(32)
            .sheet(item: $snap.draft) { draft in SnapEditorView(model: snap, draft: draft) }
            .sheet(isPresented: $showingConnections) {
                HandoffConnectionsSheet(jobs: jobs, backTitle: "Back to History") { showingConnections = false }
            }
            .modifier(TranscriptHistoryDialogs(model: model, original: $original, details: $details, removal: $removal))
            .onAppear { snap.refresh(); applyDoor() }
            .onChange(of: model.historyDoor) { applyDoor() }
            .task { await jobs.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                snap.refresh(); jobs.objectWillChange.send()
            }
    }

    /// Stop stays reachable whatever the filter or search hides.
    @ViewBuilder private var runningTask: some View {
        if jobs.isBusy {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Running · " + (jobs.jobs.first(where: { $0.id == jobs.activeID })?.title ?? "Hand off task"))
                    .font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                Button("Stop task", role: .destructive) { jobs.cancel() }
            }.padding(10).background(Workbench.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder private var notices: some View {
        if let notice = jobs.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        if let error = jobs.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        if let notice = snap.notice { Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        if !snap.problems.isEmpty {
            DisclosureGroup("\(snap.problems.count) Snap record\(snap.problems.count == 1 ? " needs" : "s need") attention") {
                ForEach(snap.problems, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                Button("Reload history") { snap.refresh() }
            }.foregroundStyle(.orange)
        }
    }

    private var emptyFilterTitle: String {
        switch filter {
        case .all: "Nothing here yet"
        case .transcripts: "No transcripts yet"
        case .snaps: "No Snaps yet"
        case .results: "No Hand off results yet"
        case .archived: "Nothing archived"
        }
    }

    private func list(_ entries: [HistoryEntry], transcripts: Set<UUID>, snaps: [UUID: SnapItem]) -> some View {
        // Only captures in the same second can share a spoken time, so each
        // row compares itself with those instead of the whole history.
        let sameSecond = Dictionary(grouping: model.history) { Int($0.date.timeIntervalSince1970.rounded(.down)) }
        let target = revealTarget
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(entries) { entry in
                        switch entry {
                        case .transcript(let item):
                            TranscriptHistoryRow(model: model, library: library, item: item,
                                history: sameSecond[Int(item.date.timeIntervalSince1970.rounded(.down))] ?? [item],
                                showsCheckbox: true, showsKind: true,
                                onDetails: { details = item }, onOriginal: { original = item },
                                onRemove: { removal = TranscriptRemoval(transcript: item, includesRecording: model.meetings.hasRecording(for: item.id)) })
                        case .snap(let item):
                            HistorySnapRow(snap: snap, library: library, item: item)
                        case .result(let job):
                            HandoffJobCard(jobs: jobs, job: job, expanded: $expandedResult, applySuggestedMetadata: applySuggestedMetadata) {
                                HistoryMadeFrom(jobs: jobs, job: job) { HistoryList.availability(of: $0, transcripts: transcripts, snaps: snaps) }
                            }.padding(16).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(target == job.id ? Workbench.accent : .clear, lineWidth: 2))
                        }
                    }
                }.padding(.vertical, 2)
            }
            .task(id: revealRequest) {
                guard revealRequest != nil, let target = revealTarget else { return }
                try? await Task.sleep(nanoseconds: 60_000_000)
                withAnimation { proxy.scrollTo(HistoryEntry.ID.result(target), anchor: .top) }
                if let job = jobs.jobs.first(where: { $0.id == target }) {
                    AccessibilityNotification.Announcement("Result shown in History: \(job.title), \(job.status.title)").post()
                }
            }
        }
    }

    @ViewBuilder private func footer(shown: Set<HistoryEntry.ID>, transcripts: Set<UUID>, snaps: [UUID: SnapItem]) -> some View {
        if !library.selected.isEmpty || !library.savedSelections.isEmpty || library.error != nil {
            let notes = HistoryList.selectionNotes(selected: library.selected, shown: shown, transcripts: transcripts, snaps: snaps)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                if notes.hidden > 0 {
                    Text("\(notes.hidden) selected hidden by this view. Hand off still includes them.").font(.caption).foregroundStyle(.secondary)
                }
                if !notes.missingTranscripts.isEmpty {
                    HStack {
                        Text("\(notes.missingTranscripts.count) selected transcripts are no longer available.").font(.caption).foregroundStyle(.orange)
                        Button("Remove missing references") { library.removeReferences(kind: .transcript, ids: notes.missingTranscripts) }.font(.caption)
                    }
                }
                if !notes.unavailable.isEmpty {
                    Button("Remove \(notes.unavailable.count) unavailable from selection") { library.setSelected(library.selected.subtracting(notes.unavailable)) }.font(.caption)
                }
                if !notes.archivedSnaps.isEmpty {
                    Button("Exclude \(notes.archivedSnaps.count) archived from selection") {
                        library.setSelected(library.selected.subtracting(notes.archivedSnaps.map { WorkbenchItemReference(kind: .snap, id: $0) }))
                    }.font(.caption)
                }
                if !notes.unavailable.isEmpty || !notes.archivedSnaps.isEmpty {
                    Text("Other selected evidence stays selected. Use Update to change a saved selection.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HistorySelectionControls(history: library) { model.onHandOffSelection?(nil) }
        }
    }

    /// The visible card for the task a door asked to reveal. A task grouped
    /// under a review shows through that review's card.
    private var revealTarget: UUID? {
        guard let revealed else { return nil }
        if jobs.visibleJobs.contains(where: { $0.id == revealed }) { return revealed }
        guard let key = jobs.jobs.first(where: { $0.id == revealed })?.reviewKey else { return nil }
        return jobs.visibleJobs.first(where: { $0.reviewKey == key })?.id
    }

    private func applyDoor() {
        guard let door = model.historyDoor else { return }
        model.historyDoor = nil
        filter = door.filter
        query = ""
        revealed = door.job
        if door.job != nil { revealRequest = UUID() }
    }
}

/// A Snap as History lists it, with the actions its card has on the Snap page.
struct HistorySnapRow: View {
    @ObservedObject var snap: SnapModel
    @ObservedObject var library: WorkbenchHistoryModel
    let item: SnapItem
    var body: some View {
        let reference = WorkbenchItemReference(kind: .snap, id: item.id)
        let time = item.createdAt.formatted(date: .abbreviated, time: .shortened)
        let archived = item.archivedAt != nil
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(get: { library.selected.contains(reference) }, set: { include in
                var references = library.selected
                if include { references.insert(reference) } else { references.remove(reference) }
                library.setSelected(references)
            })).toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel("Select Snap, \(item.title), \(item.source.title), \(time)" + (archived ? ", archived" : ""))
            SnapThumbnail(model: snap, item: item).frame(width: 120, height: 76)
                .onTapGesture { if !archived { snap.edit(item.id) } }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "photo").foregroundStyle(Workbench.accent).accessibilityHidden(true)
                    Text(item.title).font(.callout.weight(.semibold)).lineLimit(2)
                    Spacer()
                    if item.edit != SnapEdit() { Image(systemName: "pencil").font(.caption).accessibilityLabel("Edited; original preserved") }
                }
                Text("Snap · \(item.source.title) · \(time)" + (archived ? " · Archived" : "")).font(.caption).foregroundStyle(.secondary)
                if !item.tags.isEmpty { Text(item.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                HStack(spacing: 12) {
                    Button("Copy") { snap.copy(item.id) }.accessibilityLabel("Copy \(item.title)")
                    if !archived { Button("Edit…") { snap.edit(item.id) }.accessibilityLabel("Edit \(item.title)") }
                    Button("Export image…") { snap.export(item.id) }.accessibilityLabel("Export \(item.title)")
                    Spacer()
                    Button(archived ? "Restore" : "Archive") { snap.archive([item.id], archived: !archived) }
                        .accessibilityLabel((archived ? "Restore " : "Archive ") + item.title)
                }.buttonStyle(.borderless).font(.system(size: 11))
            }
        }.padding(14).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// What a task was made from: the frozen copies in its own folder, labelled
/// when the live item was archived, removed or is missing. Each opens the saved
/// copy itself, which keeps working after the live item has gone.
struct HistoryMadeFrom: View {
    @ObservedObject var jobs: HandoffJobsModel
    let job: HandoffJob
    let availability: (WorkbenchItemReference) -> HistoryInputAvailability
    @State private var showingAll = false
    var body: some View {
        let inputs = jobs.inputs(job)
        if let problem = inputs.problem {
            Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        } else if !inputs.items.isEmpty {
            let shown = showingAll ? inputs.items : Array(inputs.items.prefix(6))
            VStack(alignment: .leading, spacing: 6) {
                Text("Made from").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                        HistoryInputChip(jobs: jobs, job: job, item: item, availability: availability(item.reference))
                    }
                }
                if inputs.items.count > 6 {
                    Button(showingAll ? "Show fewer" : "Show all \(inputs.items.count)") { showingAll.toggle() }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
        }
    }
}

private struct HistoryInputChip: View {
    let jobs: HandoffJobsModel
    let job: HandoffJob
    let item: HandoffInputRecord
    let availability: HistoryInputAvailability
    @State private var showingCopy = false

    private var kind: String {
        switch item.reference.kind {
        case .transcript: "Transcript"
        case .snap: "Snap"
        case .snapAndTalk: "Snap & Talk"
        }
    }
    private var symbol: String {
        switch item.reference.kind {
        case .transcript: "mic"
        case .snap: "photo"
        case .snapAndTalk: "rectangle.and.pencil.and.ellipsis"
        }
    }

    var body: some View {
        Button { showingCopy = true } label: {
            HStack(spacing: 8) {
                if let path = item.images.first, let url = jobs.inputImageURL(job, path: path) {
                    FrozenThumbnail(url: url, maximumPixels: 96).frame(width: 34, height: 24)
                } else {
                    Image(systemName: symbol).foregroundStyle(Workbench.accent).frame(width: 34, height: 24)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.caption.weight(.medium)).lineLimit(1)
                    Text(availability.label ?? kind).font(.caption2).lineLimit(1)
                        .foregroundStyle(availability == .inHistory ? Color.secondary : Color.orange)
                }
                Spacer(minLength: 0)
            }.padding(6).background(Workbench.background, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("Made from \(kind), \(item.title)" + (availability.label.map { ", " + $0 } ?? ""))
            .accessibilityHint("Shows the saved copy this task used")
            .help(item.title + " · " + (availability.label ?? kind))
            .popover(isPresented: $showingCopy, arrowEdge: .bottom) { savedCopy }
    }

    private var savedCopy: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title).font(.headline)
            Text("\(kind) · \(item.capturedAt.formatted(date: .abbreviated, time: .shortened)) · \(item.role.title)")
                .font(.caption).foregroundStyle(.secondary)
            Text(availability.label ?? "Still in History. This is the copy the task used.").font(.caption)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !item.text.isEmpty {
                        Text(String(item.text.prefix(4_000))).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(item.images.enumerated()), id: \.offset) { _, path in
                        if let url = jobs.inputImageURL(job, path: path) {
                            FrozenThumbnail(url: url, maximumPixels: 720).frame(maxWidth: 380, maxHeight: 240)
                                .accessibilityLabel("Saved image for " + item.title)
                        } else {
                            Label("This saved image is missing from the task’s folder.", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }.frame(maxHeight: 320)
            HStack {
                Spacer()
                Button("Show in Finder") {
                    let images = item.images.compactMap { jobs.inputImageURL(job, path: $0) }
                    if images.isEmpty { jobs.showInputs(job) } else { NSWorkspace.shared.activateFileViewerSelecting(images) }
                }
            }
        }.padding(16).frame(width: 420)
    }
}

/// A frozen input image, decoded away from the main thread at a small size.
private struct FrozenThumbnail: View {
    let url: URL
    var maximumPixels: Int
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.task(id: url) {
            let url = url, size = maximumPixels
            let decoded = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: size, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
                return NSImage(cgImage: image, size: .zero)
            }.value
            image = decoded
        }
    }
}
