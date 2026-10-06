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

/// A transcript list's page-level sheets: read-only transcript review, the details
/// editor and the removal confirmation that names a saved recording. They sit
/// on the page, not the row, so a row leaving a lazy list cannot close them.
struct TranscriptHistoryDialogs: ViewModifier {
    @ObservedObject var model: AppModel
    @Binding var review: TranscriptReview?
    @Binding var details: Transcript?
    @Binding var removal: TranscriptRemoval?
    @Binding var recording: Transcript?
    private var removalIncludesRecording: Bool { removal?.includesRecording == true }

    func body(content: Content) -> some View {
        content
            .sheet(item: $review) { item in
                TranscriptReviewView(model: model, review: item) { review = nil }
            }
            .sheet(item: $recording) { item in
                MeetingRecordingReviewView(meetings: model.meetings, playback: model.meetings.recordingPlayback,
                                           transcript: item) { recording = nil }
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
    @Binding var review: TranscriptReview?
    @Binding var details: Transcript?
    @Binding var removal: TranscriptRemoval?
    @Binding var recording: Transcript?
    /// A door asked History to show this transcript (#134): its heading line is then a focus stop
    /// that takes keyboard and VoiceOver focus, as a revealed task's heading does. Focus is not
    /// selection; the checkbox and the shared selection are untouched.
    var shown = false
    var focus: FocusState<UUID?>.Binding
    var voiceOverFocus: AccessibilityFocusState<UUID?>.Binding

    var body: some View {
        let context = CaptureHistoryAccessibility.context(for: item, history: history)
        let metadata = library.metadata(for: item.id)
        let ref = WorkbenchItemReference(kind: .transcript, id: item.id)
        let words = TextRules.wordCount(item.text)
        let hasRecording = metadata.purpose == .meeting || metadata.purpose == .call || model.meetings.hasRecording(for: item.id)
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(get: { library.selected.contains(ref) }, set: { include in
                var refs = library.selected
                if include { refs.insert(ref) } else { refs.remove(ref) }
                library.setSelected(refs)
            })).toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel(CaptureHistoryAccessibility.label("Select transcript, " + metadata.purpose.title, context: context))
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    // Meetings and calls carry the Meetings symbol, so a recording reads as one at a glance.
                    Image(systemName: metadata.purpose == .meeting || metadata.purpose == .call ? WorkbenchHome.symbol(of: "meeting") : "mic")
                        .foregroundStyle(Workbench.accent).accessibilityHidden(true)
                    Text(HistoryDate.text(item.date))
                    Text(metadata.purpose.title).fontWeight(.medium)
                    Spacer(); Text("\(words) words")
                }.font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(CaptureHistoryAccessibility.label("Transcript, " + metadata.purpose.title, context: context) + ", \(words) words")
                    .focusable(shown).focused(focus, equals: item.id)
                    .accessibilityFocused(voiceOverFocus, equals: item.id)
                let fields = [metadata.person, metadata.company] + metadata.tags.map { "#" + $0 }
                if fields.contains(where: { !$0.isEmpty }) { Text(fields.filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                Text(item.text).font(Workbench.bodyText).lineLimit(8)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if !metadata.captureNotes.isEmpty {
                    WorkbenchNote(metadata.captureNotes.joined(separator: " "), symbol: "exclamationmark.triangle")
                }
                if hasRecording {
                    HStack {
                        Label("Original recording", systemImage: "waveform").foregroundStyle(.secondary)
                        Spacer()
                        Button("Review recording") { recording = item }
                            .accessibilityLabel(CaptureHistoryAccessibility.label("Review original recording", context: context))
                    }.font(.callout).buttonStyle(.borderless)
                }
                // One row font for links and the More menu, so a menu title cannot render larger
                // than the links beside it. Review transcript's Wording switch shows the original
                // words, so the row needs no separate Original link.
                HStack(spacing: 12) {
                    Button("Copy") { model.copyCapture(item) }.accessibilityLabel(CaptureHistoryAccessibility.label("Copy", context: context))
                    Button("Review transcript") { review = TranscriptReview(transcript: item) }
                        .accessibilityLabel(CaptureHistoryAccessibility.label("Review transcript", context: context))
                    Button("Details…") { details = item }.accessibilityLabel(CaptureHistoryAccessibility.label("Details", context: context))
                    Menu {
                        moreActions
                    } label: { Text("More").font(.callout) }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(CaptureHistoryAccessibility.label("More transcript actions", context: context))
                    Spacer()
                    Button {
                        removal = TranscriptRemoval(transcript: item, includesRecording: model.meetings.hasRecording(for: item.id))
                    } label: { Image(systemName: "trash") }
                        .accessibilityLabel(CaptureHistoryAccessibility.label("Remove transcript", context: context))
                        .help("Remove transcript…")
                }.buttonStyle(.borderless).font(.callout)
            }
        }.workbenchCard(outlined: shown)
            // The row's whole action set, where a Mac person looks for it first.
            .contextMenu {
                Button("Copy") { model.copyCapture(item) }
                Button("Review transcript") { review = TranscriptReview(transcript: item) }
                Button("Details…") { details = item }
                if hasRecording { Button("Review recording") { recording = item } }
                Divider()
                moreActions
                Divider()
                Button("Remove transcript…", role: .destructive) {
                    removal = TranscriptRemoval(transcript: item, includesRecording: model.meetings.hasRecording(for: item.id))
                }
            }
    }

    @ViewBuilder private var moreActions: some View {
        Button("Open in Dictate") { model.openTranscript(item) }
        Button("Save prompt") { model.savePrompt(item.text) }
        Button("Export cleaned text…") { model.exportCapture(item, version: .cleaned) }
        Button("Export original wording…") { model.exportCapture(item, version: .original) }
    }
}
