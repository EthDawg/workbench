import SwiftUI

enum CaptureHistoryAccessibility {
    static func context(for capture: Transcript, history: [Transcript] = [], locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        let timestamp = formatter.string(from: capture.date)
        let collisions = history.filter { formatter.string(from: $0.date) == timestamp }
        let suffix = collisions.count > 1 && collisions.contains(where: { $0.id == capture.id })
            ? ", capture \(collisions.firstIndex(where: { $0.id == capture.id })! + 1) of \(collisions.count)" : ""
        return "captured \(timestamp)\(suffix)"
    }
    static func label(_ action: String, context: String) -> String { "\(action), \(context)" }
}

struct CaptureHistoryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var library: WorkbenchHistoryModel
    var compact: Bool
    @State private var query = ""
    @State private var original: Transcript?
    @State private var removal: Transcript?
    @State private var details: Transcript?
    @State private var selecting = false

    init(model: AppModel, compact: Bool = false) {
        self.model = model; self.library = model.historyLibrary; self.compact = compact
    }
    private var matches: [Transcript] { library.matching(model.history, query: query) }
    private var selectedIDs: Set<UUID> { Set(library.selected.filter { $0.kind == .transcript }.map(\.id)) }
    private var missingIDs: Set<UUID> { selectedIDs.subtracting(Set(model.history.map(\.id))) }
    private var hiddenCount: Int { selectedIDs.subtracting(Set(matches.map(\.id))).count - missingIDs.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(model.history.count) saved on this Mac").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !compact {
                    Button(selecting ? "Done selecting" : "Select…") { selecting.toggle() }
                        .buttonStyle(.borderless).font(.caption)
                        .accessibilityLabel(selecting ? "Stop selecting transcripts" : "Select transcripts for a handoff")
                }
            }
            TextField("Search words, people, companies or tags", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search transcripts")
            if matches.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock").font(.title2)
                    Text(model.history.isEmpty ? "Your recordings will appear here." : "No matching transcripts.")
                    Text("Search checks your original words and saved details.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { LazyVStack(alignment: .leading, spacing: 10) { ForEach(matches) { row($0) } } }
            }
            if !compact {
                if hiddenCount > 0 { Text("\(hiddenCount) selected transcripts are hidden by this search.").font(.caption).foregroundStyle(.secondary) }
                if !missingIDs.isEmpty {
                    HStack {
                        Text("\(missingIDs.count) selected transcripts are no longer available.").font(.caption).foregroundStyle(.orange)
                        Button("Remove missing references") { library.removeReferences(kind: .transcript, ids: missingIDs) }.font(.caption)
                    }
                }
                HistorySelectionControls(history: library) { model.onHandOffSelection?(nil) }
            } else {
                Button("Open full history…") { model.onShowEditor?("history") }.buttonStyle(.link)
            }
        }
        .sheet(item: $original) { item in
            VStack(alignment: .leading, spacing: 16) {
                Text("Original transcript").font(.title2)
                ScrollView { Text(item.rawText ?? item.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Text(item.date, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary); Spacer(); Button("Done") { original = nil }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 560, height: 380)
        }
        .sheet(item: $details) { item in
            TranscriptMetadataEditor(transcript: item, library: library, suggest: { model.onSuggestTranscriptDetails?(item.id) })
        }
        .confirmationDialog("Remove this saved transcript?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("Remove transcript", role: .destructive) { if let removal { model.removeTranscript(removal) }; removal = nil }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: { Text("Saved selections will show this item as missing. Existing handoff snapshots are kept.") }
    }

    private func row(_ item: Transcript) -> some View {
        let context = CaptureHistoryAccessibility.context(for: item, history: model.history)
        let metadata = library.metadata(for: item.id)
        let ref = WorkbenchItemReference(kind: .transcript, id: item.id)
        return HStack(alignment: .top, spacing: 12) {
            if !compact && (selecting || selectedIDs.contains(item.id)) {
                Toggle("", isOn: Binding(get: { library.selected.contains(ref) }, set: { include in
                    var refs = library.selected
                    if include { refs.insert(ref) } else { refs.remove(ref) }
                    library.setSelected(refs)
                })).toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel(CaptureHistoryAccessibility.label("Include in handoff", context: context))
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(item.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    Text(metadata.purpose.title).fontWeight(.medium)
                    Spacer(); Text("\(TextRules.wordCount(item.text)) words")
                }.font(.system(size: compact ? 10 : 11)).foregroundStyle(.secondary)
                if !compact {
                    let fields = [metadata.person, metadata.company] + metadata.tags.map { "#" + $0 }
                    if fields.contains(where: { !$0.isEmpty }) { Text(fields.filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                }
                Text(item.text).font(.system(size: compact ? 12 : 14)).lineLimit(compact ? 5 : 8)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if !metadata.captureNotes.isEmpty {
                    Label(metadata.captureNotes.joined(separator: " "), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).lineLimit(compact ? 2 : nil)
                }
                HStack(spacing: 12) {
                    Button("Copy") { model.copyCapture(item) }.accessibilityLabel(CaptureHistoryAccessibility.label("Copy", context: context))
                    Button("Open") { model.openTranscript(item); if compact { model.onShowEditor?("dictate") } }
                        .accessibilityLabel(CaptureHistoryAccessibility.label("Open", context: context))
                    if compact {
                        Button("Paste") { model.onPasteTranscript?(item.text) }.disabled(model.phase != .idle)
                            .accessibilityLabel(CaptureHistoryAccessibility.label("Paste", context: context))
                    } else {
                        Button("Details…") { details = item }.accessibilityLabel(CaptureHistoryAccessibility.label("Edit details", context: context))
                        Button("Original") { original = item }.accessibilityLabel(CaptureHistoryAccessibility.label("Show original", context: context))
                        Menu("More…") {
                            Button("Read aloud") { model.speechText = item.text; model.page = "speak" }
                            Button("Save prompt") { model.savePrompt(item.text) }
                            Button("Export cleaned text…") { model.exportCapture(item, version: .cleaned) }
                            Button("Export original wording…") { model.exportCapture(item, version: .original) }
                        }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel(CaptureHistoryAccessibility.label("More transcript actions", context: context))
                    }
                    Spacer()
                    if !compact {
                        Button { removal = item } label: { Image(systemName: "trash") }
                            .accessibilityLabel(CaptureHistoryAccessibility.label("Remove transcript", context: context))
                    }
                }.buttonStyle(.borderless).font(.system(size: 11))
            }
        }.padding(compact ? 12 : 18).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}
