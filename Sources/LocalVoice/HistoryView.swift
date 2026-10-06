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
/// to reveal, or a transcript to show from Home's recent work (#134). Each door
/// makes a new one, so it applies even when History is already showing. Showing
/// a transcript reveals its row and opens its full read-only review; it never
/// selects it or replaces the draft in Dictate.
struct HistoryDoor: Equatable {
    var id = UUID()
    var filter = HistoryFilter.all
    var job: UUID? = nil
    var transcript: UUID? = nil
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
    /// Every row once, newest first. Sorting happens here, when a store's rows
    /// change, and never while a search is typed.
    static func merged(transcripts: [Transcript], snaps: [SnapItem], results: [HandoffJob]) -> [HistoryEntry] {
        (transcripts.map(HistoryEntry.transcript) + snaps.map(HistoryEntry.snap) + results.map(HistoryEntry.result))
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.tieBreak < $1.tieBreak }
    }

    /// The rows a filter and search show, in merged order, in one pass.
    /// Transcripts use their existing matcher, Snaps SnapModel's search (which
    /// includes the text read from each image) and results their title and
    /// request. Every term must match.
    static func shown(_ merged: [HistoryEntry], filter: HistoryFilter, query: String,
                      matchTranscripts: ([Transcript], String) -> [Transcript],
                      matchSnap: (SnapItem, String) -> Bool,
                      resultText: (HandoffJob) -> String,
                      matchResult: ((HandoffJob, String) -> Bool)? = nil) -> [HistoryEntry] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let showsTranscripts = filter == .all || filter == .transcripts
        var matchingTranscripts: Set<UUID>?
        if showsTranscripts && !terms.isEmpty {
            let transcripts = merged.compactMap { entry -> Transcript? in
                if case .transcript(let item) = entry { return item }
                return nil
            }
            matchingTranscripts = Set(matchTranscripts(transcripts, query).map(\.id))
        }
        return merged.filter { entry in
            switch entry {
            case .transcript(let item):
                return showsTranscripts && matchingTranscripts?.contains(item.id) != false
            case .snap(let item):
                guard filter == .all || filter == .snaps || filter == .archived,
                      (item.archivedAt != nil) == (filter == .archived) else { return false }
                return terms.isEmpty || matchSnap(item, query)
            case .result(let job):
                guard filter == .all || filter == .results else { return false }
                guard !terms.isEmpty else { return true }
                if let matchResult { return matchResult(job, query) }
                let text = job.title + "\n" + resultText(job)
                return terms.allSatisfy { text.localizedCaseInsensitiveContains($0) }
            }
        }
    }

    /// Both steps together, for callers without a cache.
    static func entries(transcripts: [Transcript], snaps: [SnapItem], results: [HandoffJob],
                        filter: HistoryFilter, query: String,
                        matchTranscripts: ([Transcript], String) -> [Transcript],
                        matchSnap: (SnapItem, String) -> Bool,
                        resultText: (HandoffJob) -> String,
                        matchResult: ((HandoffJob, String) -> Bool)? = nil) -> [HistoryEntry] {
        shown(merged(transcripts: transcripts, snaps: snaps, results: results), filter: filter, query: query,
              matchTranscripts: matchTranscripts, matchSnap: matchSnap, resultText: resultText, matchResult: matchResult)
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

    /// The card a revealed task shows in, and the task itself: a task grouped
    /// under a newer task for the same review is shown inside that task's card.
    static func revealTarget(_ task: UUID, jobs: [HandoffJob], visible: [HandoffJob]) -> (card: UUID, task: UUID)? {
        if visible.contains(where: { $0.id == task }) { return (task, task) }
        guard let key = jobs.first(where: { $0.id == task })?.reviewKey,
              let card = visible.first(where: { $0.reviewKey == key }) else { return nil }
        return (card.id, task)
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

/// History's rows kept between redraws, so an unrelated change (a level meter,
/// a status line) costs nothing. The merged, sorted list and its lookups are
/// rebuilt when a store's rows change; a filter or search then keeps that
/// order in one pass.
@MainActor
final class HistoryRowsCache {
    struct Stores {
        var merged: [HistoryEntry] = []
        var transcripts: Set<UUID> = []
        var snaps: [UUID: SnapItem] = [:]
        /// Transcripts by whole second, to tell identical spoken times apart.
        var sameSecond: [Int: [Transcript]] = [:]
    }
    struct ShownKey: Equatable {
        var stores: Int
        var search: Int
        var metadata = 0
        var filter: HistoryFilter
        var query: String
    }
    private var storesRevision: Int?
    private var cachedStores = Stores()
    private var shownKey: ShownKey?
    private var cachedShown: [HistoryEntry] = []

    func stores(revision: Int, build: () -> Stores) -> Stores {
        if storesRevision != revision { cachedStores = build(); storesRevision = revision }
        return cachedStores
    }
    func shown(_ key: ShownKey, build: () -> [HistoryEntry]) -> [HistoryEntry] {
        if shownKey != key { cachedShown = build(); shownKey = key }
        return cachedShown
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
    var openSnapTalkSessions: (() -> Void)?
    @State private var filter: HistoryFilter
    @State private var query = ""
    /// The search the list shows, applied once typing pauses.
    @State private var appliedQuery = ""
    /// Bumped when a store's rows change, so the list is merged and sorted again.
    @State private var storesRevision = 0
    /// Bumped when image text or task files change. Capture details have their
    /// own revision; selecting a row does not change any searchable content.
    @State private var searchRevision = 0
    @State private var rows = HistoryRowsCache()
    @State private var expandedResult: UUID?
    @State private var revealed: UUID?
    @State private var revealRequest: UUID?
    /// A transcript a door asked to show, and the request that scrolls to it and focuses it once.
    @State private var shownTranscript: UUID?
    @State private var transcriptRequest: UUID?
    @FocusState private var focusedTranscript: UUID?
    @AccessibilityFocusState private var voiceOverTranscript: UUID?
    @FocusState private var focusedTask: UUID?
    @AccessibilityFocusState private var voiceOverTask: UUID?
    @State private var showingConnections = false
    @State private var transcriptReview: TranscriptReview?
    @State private var details: Transcript?
    @State private var removal: TranscriptRemoval?
    @State private var recording: Transcript?

    init(model: AppModel, snap: SnapModel, openSnapTalkSessions: (() -> Void)? = nil, applySuggestedMetadata: @escaping (HandoffJob, String) -> Void) {
        self.model = model; self.snap = snap
        self.library = model.historyLibrary; self.jobs = model.handoffJobs
        self.applySuggestedMetadata = applySuggestedMetadata
        self.openSnapTalkSessions = openSnapTalkSessions
        _filter = State(initialValue: model.historyDoor?.filter ?? .all)
    }

    private struct JobStamp: Equatable { var id: UUID; var updated: Date }

    var body: some View {
        let stores = rows.stores(revision: storesRevision) {
            HistoryRowsCache.Stores(merged: HistoryList.merged(transcripts: model.history, snaps: snap.items, results: jobs.visibleJobs),
                transcripts: Set(model.history.map(\.id)),
                snaps: Dictionary(snap.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                sameSecond: Dictionary(grouping: model.history) { Int($0.date.timeIntervalSince1970.rounded(.down)) })
        }
        let entries = rows.shown(.init(stores: storesRevision, search: searchRevision, metadata: library.metadataRevision,
                                      filter: filter, query: appliedQuery)) {
            HistoryList.shown(stores.merged, filter: filter, query: appliedQuery,
                matchTranscripts: { library.matching($0, query: $1) }, matchSnap: { snap.matches($0, query: $1) },
                resultText: { jobs.files($0)?.inputs.task ?? "" },
                matchResult: { jobs.matchesResult($0, query: $1) })
        }
        VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
            header
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
                        Image(systemName: appliedQuery.isEmpty ? "tray" : "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                        Text(appliedQuery.isEmpty ? emptyFilterTitle : "Nothing matches this search").font(.headline)
                        Text("Your selection is kept.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list(entries, stores: stores)
                }
            }
            footer(shown: Set(entries.map(\.id)), stores: stores)
        }.padding(Workbench.pagePadding)
            .sheet(isPresented: $showingConnections) {
                HandoffConnectionsSheet(jobs: jobs, backTitle: "Back to History") { showingConnections = false }
            }
            .modifier(TranscriptHistoryDialogs(model: model, review: $transcriptReview, details: $details, removal: $removal, recording: $recording))
            .onAppear { snap.requestRefresh(); applyDoor() }
            .onChange(of: model.historyDoor) { applyDoor() }
            .task(id: query) {
                // Search runs once typing pauses; clearing it applies at once.
                guard !query.isEmpty else { appliedQuery = ""; return }
                try? await Task.sleep(nanoseconds: 200_000_000)
                if !Task.isCancelled { appliedQuery = query }
            }
            .task(id: jobs.jobs.map { JobStamp(id: $0.id, updated: $0.updatedAt) }) { await jobs.loadTaskFiles(jobs.jobs) }
            .task { await jobs.refresh() }
            .onReceive(model.$history.dropFirst()) { _ in storesRevision &+= 1 }
            .onReceive(snap.$items.dropFirst()) { _ in storesRevision &+= 1 }
            .onReceive(jobs.$jobs.dropFirst()) { _ in storesRevision &+= 1 }
            .onReceive(snap.$recognizedText.dropFirst()) { _ in searchRevision &+= 1 }
            .onReceive(jobs.$taskFiles.dropFirst()) { _ in searchRevision &+= 1 }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                snap.requestRefresh()
                Task { await jobs.loadTaskFiles(jobs.jobs) }
            }
    }

    /// The title and Connections, which opens the provider settings over
    /// History so a Ready or failed task can be started without leaving it.
    private var header: some View {
        WorkbenchPageHeader("history", summary: "What you dictated, snapped and handed off, newest first.") {
            ConfirmationLabel(text: snap.confirmation?.kind.rawValue, reserving: SnapConfirmation.texts)
            if let openSnapTalkSessions {
                Button("Snap & Talk sessions…", action: openSnapTalkSessions)
            }
            Button("Connections…") { showingConnections = true }
        }
    }

    /// Stop stays reachable whatever the filter or search hides.
    @ViewBuilder private var runningTask: some View {
        if jobs.isBusy {
            HStack(spacing: 10) {
                // The surface gallery's isolated pass draws a still symbol, so its renders repeat
                // byte for byte; the app shows the live indicator.
                if CommandLine.arguments.dropFirst().first == "--render-surfaces-pass" {
                    Image(systemName: "hourglass").foregroundStyle(Workbench.accent).accessibilityHidden(true)
                } else { ProgressView().controlSize(.small) }
                Text("Running · " + (jobs.jobs.first(where: { $0.id == jobs.activeID })?.title ?? "Hand off task"))
                    .font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                Button("Stop task", role: .destructive) { jobs.cancel() }
            }.padding(10).background(Workbench.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder private var notices: some View {
        // Removing or exporting a transcript that went wrong: the menu-bar panel's Open History…
        // leads to these words (#134).
        if let attention = model.attention, attention.page == .history {
            Text(attention.message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
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

    private func list(_ entries: [HistoryEntry], stores: HistoryRowsCache.Stores) -> some View {
        let target = revealed.flatMap { HistoryList.revealTarget($0, jobs: jobs.jobs, visible: jobs.visibleJobs) }
        let images: [CaptureImagePreviewItem] = entries.compactMap {
            if case .snap(let item) = $0 { return .snap(item, store: snap.store) }; return nil
        }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(entries) { entry in
                        switch entry {
                        case .transcript(let item):
                            TranscriptHistoryRow(model: model, library: library, item: item,
                                history: stores.sameSecond[Int(item.date.timeIntervalSince1970.rounded(.down))] ?? [item],
                                review: $transcriptReview, details: $details, removal: $removal, recording: $recording,
                                shown: shownTranscript == item.id, focus: $focusedTranscript, voiceOverFocus: $voiceOverTranscript)
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(shownTranscript == item.id ? Workbench.accent : .clear, lineWidth: 2))
                        case .snap(let item):
                            HistorySnapRow(snap: snap, library: library, item: item, images: images,
                                saveImageToLibrary: { chosen in
                                    if let message = model.library.saveCapturedImageToLibrary(.snap(chosen, store: snap.store)) {
                                        snap.notice = message
                                    }
                                })
                        case .result(let job):
                            HandoffJobCard(jobs: jobs, job: job, expanded: $expandedResult, revealed: target?.task,
                                           focus: $focusedTask, voiceOverFocus: $voiceOverTask,
                                           applySuggestedMetadata: applySuggestedMetadata, query: appliedQuery,
                                           copyResult: { model.copySavedResult($1, jobID: $0.id) },
                                           readAloud: { model.importReading($0, from: .result) }) {
                                HistoryMadeFrom(jobs: jobs, job: job) {
                                    HistoryList.availability(of: $0, transcripts: stores.transcripts, snaps: stores.snaps)
                                }
                            }.padding(16).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(target?.card == job.id && target?.task == job.id ? Workbench.accent : .clear, lineWidth: 2))
                        }
                    }
                }.padding(.vertical, 2)
            }
            .task(id: revealRequest) {
                // Scroll to the card, then to a grouped task once its group has
                // opened, and move keyboard and VoiceOver focus to that task.
                guard revealRequest != nil, let target else { return }
                try? await Task.sleep(nanoseconds: 80_000_000)
                withAnimation { proxy.scrollTo(HistoryEntry.ID.result(target.card), anchor: .top) }
                if target.task != target.card {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    withAnimation { proxy.scrollTo(HistoryEntry.ID.result(target.task), anchor: .center) }
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
                focusedTask = target.task
                voiceOverTask = target.task
            }
            .task(id: transcriptRequest) {
                // A transcript Home showed: scroll to it and move keyboard and VoiceOver focus to its
                // heading, as a revealed task's. The list has no selection of its own to move, so
                // nothing is selected: the shared selection is only its checkboxes.
                guard transcriptRequest != nil, let id = shownTranscript else { return }
                try? await Task.sleep(nanoseconds: 80_000_000)
                withAnimation { proxy.scrollTo(HistoryEntry.ID.transcript(id), anchor: .center) }
                try? await Task.sleep(nanoseconds: 120_000_000)
                // The review sheet owns focus while open. Returning to the
                // list leaves this exact row outlined without moving selection.
                if transcriptReview == nil {
                    focusedTranscript = id
                    voiceOverTranscript = id
                }
            }
        }
    }

    @ViewBuilder private func footer(shown: Set<HistoryEntry.ID>, stores: HistoryRowsCache.Stores) -> some View {
        if !library.selected.isEmpty || !library.savedSelections.isEmpty || library.error != nil {
            let notes = HistoryList.selectionNotes(selected: library.selected, shown: shown, transcripts: stores.transcripts, snaps: stores.snaps)
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

    private func applyDoor() {
        guard let door = model.historyDoor else { return }
        model.historyDoor = nil
        filter = door.filter
        query = ""; appliedQuery = ""
        revealed = door.job
        if door.job != nil { revealRequest = UUID() }
        shownTranscript = door.transcript
        if let id = door.transcript {
            transcriptRequest = UUID()
            // A saved result opens as a result. This page-owned sheet never
            // changes Dictate's draft, the shared selection or playback.
            transcriptReview = TranscriptReview.find(id, in: model.history)
        }
    }
}

/// A Snap as History lists it, with the actions its card has on the Snap page.
struct HistorySnapRow: View {
    @ObservedObject var snap: SnapModel
    @ObservedObject var library: WorkbenchHistoryModel
    let item: SnapItem
    var images: [CaptureImagePreviewItem] = []
    var saveImageToLibrary: ((SnapItem) -> Void)? = nil
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
            // The image opens read-only, archived or not; Edit… is its own action.
            CapturePreviewButton("View \(item.title)", item: { .snap(item, store: snap.store) }, collection: { images }) {
                SnapThumbnail(model: snap, item: item).frame(width: 120, height: 76)
            }
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
                    if let saveImageToLibrary {
                        Button("Save image to Library…") { saveImageToLibrary(item) }
                            .accessibilityLabel("Save \(item.title) to Library")
                    }
                    Spacer()
                    Button(archived ? "Restore" : "Archive") { snap.archive([item.id], archived: !archived) }
                        .accessibilityLabel((archived ? "Restore " : "Archive ") + item.title)
                }.buttonStyle(.borderless).font(.system(size: 11))
            }
        }.padding(14).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 10))
            .contextMenu { Button("View image") { CaptureImagePreview.shared.show(.snap(item, store: snap.store), collection: images) } }
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
        if let inputs = jobs.files(job)?.inputs {
            madeFrom(inputs)
        } else {
            Text("Reading what this task was made from…").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func madeFrom(_ inputs: HandoffJobInputs) -> some View {
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
        case .snapAndTalk: WorkbenchHome.symbol(of: "readback")
        }
    }

    var body: some View {
        Button { showingCopy = true } label: {
            HStack(spacing: 8) {
                if let path = item.images.first, let url = jobs.files(job)?.imageURLs[path] {
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
                        if let url = jobs.files(job)?.imageURLs[path] {
                            CapturePreviewButton("View saved image for " + item.title, item: { .savedCopy(title: item.title, url: url) }, collection: { item.images.map { .savedCopy(title: item.title, url: jobs.files(job)?.imageURLs[$0]) } }) {
                                FrozenThumbnail(url: url, maximumPixels: 720).frame(maxWidth: 380, maxHeight: 240)
                            }
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
