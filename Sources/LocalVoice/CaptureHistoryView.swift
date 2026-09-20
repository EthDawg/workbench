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
    var compact = false
    @State private var query = ""
    @State private var original: Transcript?
    @State private var removal: Transcript?
    private var matches: [Transcript] { TranscriptHistory.matching(model.history, query: query) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(model.history.count) saved · last \(TranscriptHistory.limit) kept on this Mac")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            TextField("Search transcripts", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search transcripts")
            if matches.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock").font(.title2)
                    Text(model.history.isEmpty ? "Your recordings will appear here." : "No matching transcripts.")
                    Text(model.history.isEmpty ? "Each completed recording or audio import is saved automatically." : "Search also checks your original words.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(matches) { item in
                            let accessibilityContext = CaptureHistoryAccessibility.context(for: item, history: model.history)
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(item.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    Spacer(); Text("\(TextRules.wordCount(item.text)) words")
                                }.font(.system(size: compact ? 10 : 11)).foregroundStyle(.secondary)
                                Text(item.text).font(.system(size: compact ? 12 : 14)).lineLimit(compact ? 5 : 8)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                HStack(spacing: 12) {
                                    Button("Copy") { model.copyCapture(item) }
                                        .accessibilityLabel(CaptureHistoryAccessibility.label("Copy", context: accessibilityContext))
                                    Button("Open") { model.openTranscript(item); if compact { model.onShowEditor?("dictate") } }
                                        .accessibilityLabel(CaptureHistoryAccessibility.label("Open", context: accessibilityContext))
                                    if compact {
                                        Button("Paste") { model.onPasteTranscript?(item.text) }
                                            .accessibilityLabel(CaptureHistoryAccessibility.label("Paste", context: accessibilityContext))
                                            .disabled(model.phase != .idle)
                                    } else {
                                        Button("Original") { original = item }
                                            .accessibilityLabel(CaptureHistoryAccessibility.label("Show original", context: accessibilityContext))
                                        Button("Read aloud") { model.speechText = item.text; model.page = "speak" }
                                            .accessibilityLabel(CaptureHistoryAccessibility.label("Read aloud", context: accessibilityContext))
                                        Button("Save prompt") { model.savePrompt(item.text) }
                                            .accessibilityLabel(CaptureHistoryAccessibility.label("Save prompt", context: accessibilityContext))
                                        Menu("Export…") {
                                            Button("Cleaned text…") { model.exportCapture(item, version: .cleaned) }
                                            Button("Original wording…") { model.exportCapture(item, version: .original) }
                                        }.menuStyle(.borderlessButton).fixedSize()
                                            .accessibilityLabel(CaptureHistoryAccessibility.label("Export transcript", context: accessibilityContext))
                                            .accessibilityHint("Choose cleaned text or original wording")
                                            .help("Export cleaned text or original wording")
                                    }
                                    Spacer()
                                    if !compact {
                                        Button { removal = item } label: { Image(systemName: "trash") }
                                            .accessibilityLabel(CaptureHistoryAccessibility.label("Remove transcript", context: accessibilityContext))
                                    }
                                }.buttonStyle(.borderless).font(.system(size: 11))
                            }.padding(compact ? 12 : 18)
                                .background(Workbench.surface, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            if compact { Button("Open full history…") { model.onShowEditor?("history") }.buttonStyle(.link) }
        }
        .sheet(item: $original) { item in
            VStack(alignment: .leading, spacing: 16) {
                Text("Original transcript").font(.title2)
                ScrollView { Text(item.rawText ?? item.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Text(item.date, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary); Spacer(); Button("Done") { original = nil }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 560, height: 380)
        }
        .confirmationDialog("Remove this saved transcript?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("Remove transcript", role: .destructive) { if let removal { model.removeTranscript(removal) }; removal = nil }
            Button("Cancel", role: .cancel) { removal = nil }
        }
    }
}
