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

struct TranscriptRemoval {
    let transcript: Transcript
    let includesRecording: Bool
}

/// A transcript list's page-level sheets: the original wording, the details
/// editor and the removal confirmation that names a saved recording. They sit
/// on the page, not the row, so a row leaving a lazy list cannot close them.
struct TranscriptHistoryDialogs: ViewModifier {
    @ObservedObject var model: AppModel
    @Binding var original: Transcript?
    @Binding var details: Transcript?
    @Binding var removal: TranscriptRemoval?
    private var removalIncludesRecording: Bool { removal?.includesRecording == true }

    func body(content: Content) -> some View {
        content
            .sheet(item: $original) { item in
                VStack(alignment: .leading, spacing: 16) {
                    Text("Original transcript").font(.title2)
                    ScrollView { Text(item.rawText ?? item.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack { Text(item.date, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary); Spacer(); Button("Done") { original = nil }.keyboardShortcut(.defaultAction) }
                }.padding(24).frame(width: 560, height: 380)
            }
            .sheet(item: $details) { item in
                TranscriptMetadataEditor(transcript: item, library: model.historyLibrary, suggest: { model.onSuggestTranscriptDetails?(item.id) })
            }
            .confirmationDialog(removalIncludesRecording ? "Remove this transcript and its recording?" : "Remove this saved transcript?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
                Button(removalIncludesRecording ? "Remove transcript and recording" : "Remove transcript", role: .destructive) {
                    if let removal { model.removeTranscript(removal.transcript, includingRecording: removal.includesRecording) }
                    removal = nil
                }
                Button("Cancel", role: .cancel) { removal = nil }
            } message: {
                Text(removalIncludesRecording
                     ? "Permanently removes this saved transcript and its recording from this Mac. Saved selections will show it as missing. Existing handoff snapshots and exported copies are kept."
                     : "Saved selections will show this item as missing. Existing handoff snapshots are kept.")
            }
    }
}

/// One saved transcript as History lists it, with the actions it has always
/// had. Its sheets belong to the page (see `TranscriptHistoryDialogs`), so the
/// row only names which transcript they show.
struct TranscriptHistoryRow: View {
    @ObservedObject var model: AppModel
    /// Observed here, so a row's checkbox follows the shared selection.
    @ObservedObject var library: WorkbenchHistoryModel
    let item: Transcript
    /// The captures to tell identical times apart among. Passing only those in
    /// the same second keeps a long history from being scanned for every row.
    var history: [Transcript]
    @Binding var original: Transcript?
    @Binding var details: Transcript?
    @Binding var removal: TranscriptRemoval?

    var body: some View {
        let context = CaptureHistoryAccessibility.context(for: item, history: history)
        let metadata = library.metadata(for: item.id)
        let ref = WorkbenchItemReference(kind: .transcript, id: item.id)
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(get: { library.selected.contains(ref) }, set: { include in
                var refs = library.selected
                if include { refs.insert(ref) } else { refs.remove(ref) }
                library.setSelected(refs)
            })).toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel(CaptureHistoryAccessibility.label("Select transcript, " + metadata.purpose.title, context: context))
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "mic").foregroundStyle(Workbench.accent).accessibilityHidden(true)
                    Text(item.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    Text(metadata.purpose.title).fontWeight(.medium)
                    Spacer(); Text("\(TextRules.wordCount(item.text)) words")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                let fields = [metadata.person, metadata.company] + metadata.tags.map { "#" + $0 }
                if fields.contains(where: { !$0.isEmpty }) { Text(fields.filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                Text(item.text).font(.system(size: 14)).lineLimit(8)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if !metadata.captureNotes.isEmpty {
                    Label(metadata.captureNotes.joined(separator: " "), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack(spacing: 12) {
                    Button("Copy") { model.copyCapture(item) }.accessibilityLabel(CaptureHistoryAccessibility.label("Copy", context: context))
                    Button("Open") { model.openTranscript(item) }
                        .accessibilityLabel(CaptureHistoryAccessibility.label("Open", context: context))
                    Button("Details…") { details = item }.accessibilityLabel(CaptureHistoryAccessibility.label("Edit details", context: context))
                    Button("Original") { original = item }.accessibilityLabel(CaptureHistoryAccessibility.label("Show original", context: context))
                    Menu("More…") {
                        Button("Read aloud") { model.importReading(item.text, from: .transcript) }
                        Button("Save prompt") { model.savePrompt(item.text) }
                        Button("Export cleaned text…") { model.exportCapture(item, version: .cleaned) }
                        Button("Export original wording…") { model.exportCapture(item, version: .original) }
                    }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel(CaptureHistoryAccessibility.label("More transcript actions", context: context))
                    Spacer()
                    Button {
                        removal = TranscriptRemoval(transcript: item, includesRecording: model.meetings.hasRecording(for: item.id))
                    } label: { Image(systemName: "trash") }
                        .accessibilityLabel(CaptureHistoryAccessibility.label("Remove transcript", context: context))
                }.buttonStyle(.borderless).font(.system(size: 11))
            }
        }.padding(18).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}
