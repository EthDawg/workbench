import AppKit
import Combine
import SwiftUI

/// One read-only visit to an exact saved transcript. It is page-owned, so a
/// History row leaving the lazy list cannot dismiss it or select another item.
/// No draft, selection, recording or persistent store belongs to this value.
struct TranscriptReview: Identifiable {
    let transcript: Transcript
    var version: TranscriptExportVersion = .cleaned
    var id: UUID { transcript.id }

    static func find(_ id: UUID, in history: [Transcript]) -> Self? {
        history.first { $0.id == id }.map { Self(transcript: $0) }
    }

    var text: String { TranscriptExport.text(for: transcript, version: version) }
}

/// Feedback belongs to this review visit. Success is brief; a failed copy or
/// export remains here until another explicit attempt succeeds or review ends.
@MainActor
final class TranscriptReviewFeedback: ObservableObject {
    @Published private(set) var confirmation: LocalConfirmation<String>?
    @Published private(set) var problem: String?
    private let expiry = NoticeExpiry()

    func finish(_ success: String?, problem: String? = nil) {
        expiry.cancel()
        self.problem = problem
        guard let success else { confirmation = nil; return }
        let confirmation = LocalConfirmation(success, at: Monotonic.now())
        self.confirmation = confirmation
        expiry.schedule(confirmation.lifetime) { [weak self] event in
            guard self?.confirmation?.lifetime.event == event else { return }
            self?.confirmation = nil
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: success, .priority: NSAccessibilityPriorityLevel.low.rawValue])
    }
}

struct TranscriptReviewView: View {
    @Environment(\.pageSectionFrames) private var sectionFrames
    @ObservedObject var model: AppModel
    let review: TranscriptReview
    let done: () -> Void
    @State private var version: TranscriptExportVersion
    @State private var recording: Transcript?
    @StateObject private var feedback = TranscriptReviewFeedback()

    init(model: AppModel, review: TranscriptReview, done: @escaping () -> Void) {
        self.model = model; self.review = review; self.done = done
        _version = State(initialValue: review.version)
    }

    private var item: Transcript { review.transcript }
    private var text: String { TranscriptExport.text(for: item, version: version) }
    private var recordingAvailable: Bool {
        let purpose = model.historyLibrary.metadata(for: item.id).purpose
        return purpose == .meeting || purpose == .call || model.meetings.hasRecording(for: item.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Transcript").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            HStack {
                Text(HistoryDate.text(item.date))
                Text(model.historyLibrary.metadata(for: item.id).purpose.title)
                Spacer()
                Text("\(TextRules.wordCount(text)) words").monospacedDigit()
            }.font(.subheadline).foregroundStyle(.secondary)
            Picker("Wording", selection: $version) {
                Text("Current text").tag(TranscriptExportVersion.cleaned)
                Text("Original wording").tag(TranscriptExportVersion.original)
            }.pickerStyle(.segmented).accessibilityLabel("Transcript wording")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let notes = model.historyLibrary.metadata(for: item.id).captureNotes
                    if !notes.isEmpty {
                        WorkbenchNote(notes.joined(separator: "\n"))
                    }
                    // A reading measure: long lines are hard to follow, so the words stop near
                    // 600 points with a little air between lines, however wide the sheet grows.
                    Text(text).font(.body).lineSpacing(3).textSelection(.enabled)
                        .frame(maxWidth: 600, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(Workbench.tilePadding)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sectionFrames?("history.transcript-review.document", $0) }
            }.id(version).background(Workbench.surface, in: RoundedRectangle(cornerRadius: Workbench.tileRadius))
                // The hairline Dictate's transcript has, so the text box reads as one on macOS 26.
                .overlay(RoundedRectangle(cornerRadius: Workbench.tileRadius).strokeBorder(Workbench.border))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sectionFrames?("history.transcript-review.text", $0) }
                .accessibilityIdentifier("history.transcript-review.text")
            HStack(spacing: 12) {
                // The current-wording copy owner also retains its exact failure
                // recovery. Original wording can be selected or exported without
                // pretending that recovery points at those different words.
                Button("Copy current text") {
                    model.copyCapture(item)
                    if model.status == TextDelivery.copiedMessage { feedback.finish("Copied current text") }
                    else { feedback.finish(nil, problem: model.status) }
                }.disabled(item.text.isEmpty)
                Button(version == .original ? "Export original…" : "Export current text…") {
                    if let saved = model.exportCapture(item, version: version) {
                        if saved { feedback.finish("Saved") }
                        else { feedback.finish(nil, problem: model.attention?.message ?? "The transcript could not be saved.") }
                    }
                }
                Spacer()
                if recordingAvailable {
                    Button("Review recording") { recording = item }
                }
            }.controlSize(.regular)
            if let problem = feedback.problem {
                ScrollView {
                    WorkbenchNote(problem).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 60)
            } else {
                ConfirmationLabel(text: feedback.confirmation?.kind, reserving: ["Copied current text", "Saved"])
            }
        }.padding(Workbench.pagePadding)
            // A sheet the person can make bigger for a long meeting. macOS opens a sheet at its
            // minimum, so the minimum is the size it has always opened at.
            .frame(minWidth: 640, idealWidth: 640, maxWidth: 1000, minHeight: 560, idealHeight: 560, maxHeight: .infinity)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sectionFrames?("history.transcript-review", $0) }
            .accessibilityIdentifier("history.transcript-review")
            .onExitCommand(perform: done)
            // Escape is Done even when no control has keyboard focus; the visible Done is Return.
            .background { Button("Done", action: done).keyboardShortcut(.cancelAction).hidden() }
            .sheet(item: $recording) { item in
                MeetingRecordingReviewView(meetings: model.meetings, playback: model.meetings.recordingPlayback,
                                           transcript: item) { recording = nil }
            }
    }
}
