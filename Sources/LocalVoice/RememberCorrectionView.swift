import SwiftUI
import AppKit

struct CorrectionSelectionObserver: ViewModifier {
    let transcript: String
    let active: Bool
    @Binding var selection: String
    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { notice in
            guard active, let textView = notice.object as? NSTextView,
                  textView.isEditable, textView.string == transcript else { return }
            let range = textView.selectedRange()
            guard range.length > 0, let selected = Range(range, in: textView.string) else { selection = ""; return }
            let text = String(textView.string[selected])
            selection = text.count <= CorrectionRule.maximumCharacters && text.rangeOfCharacter(from: .newlines) == nil ? text : ""
        }
        .onChange(of: transcript) { _, _ in selection = "" }
        .onChange(of: active) { _, _ in selection = "" }
    }
}

/// A deliberate local dictionary edit. It never reads another app's selection,
/// learns from typing, invokes a model, or sends text to the clipboard.
struct RememberCorrectionView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var heard: String
    @State private var written = ""
    let draft: String
    @State private var saveError: String?
    @FocusState private var focused: Field?
    private enum Field { case heard, written }

    private var proposal: CorrectionRuleProposal? {
        try? CorrectionRule.propose(heard: heard, written: written, draft: draft, replacements: model.replacements)
    }
    private var validation: String? {
        guard !heard.isEmpty, !written.isEmpty else { return nil }
        do { _ = try CorrectionRule.propose(heard: heard, written: written, draft: draft, replacements: model.replacements); return nil }
        catch { return error.localizedDescription }
    }
    private var saveTitle: String {
        guard let proposal else { return "Remember" }
        if proposal.isAlreadyRemembered { return proposal.changesDraft ? "Correct draft" : "Already remembered" }
        // A different output for a saved phrase is an explicit Update, as in Dictionary.
        if proposal.replacesExisting { return proposal.changesDraft ? "Update & correct draft" : "Update" }
        return proposal.changesDraft ? "Remember & correct draft" : "Remember"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Remember a correction").font(.title2.weight(.semibold))
            Text("A name, a product, a word you use. Set its spelling once for future dictations on this Mac.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Heard").font(.headline)
                    TextField("For example, stage mark", text: $heard).focused($focused, equals: .heard)
                        .accessibilityLabel("Heard")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Write instead").font(.headline)
                    TextField("StageMark", text: $written).focused($focused, equals: .written)
                        .accessibilityLabel("Write instead")
                }
            }.textFieldStyle(.roundedBorder)
            if let proposal {
                VStack(alignment: .leading, spacing: 8) {
                    if let previous = proposal.previousRule, proposal.replacesExisting {
                        Text("Updates the saved correction: “\(previous.heard)” → “\(previous.written)”.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(proposal.changesDraft ? "This draft after correction" : "This draft stays as it is").font(.headline)
                    if proposal.changesDraft {
                        ScrollView {
                            Text(proposal.previewText).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        }.frame(height: 130).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("Draft preview")
                    }
                    Text(proposal.matchCount == 0 ? "No matching phrase in this draft. The correction will apply to future dictations."
                         : "Matches whole words and phrases, ignoring case. Your chosen spelling is kept exactly.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let message = saveError ?? validation {
                Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("The original and earlier captures stay unchanged. This won’t paste into another app.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Dictionary") { model.page = "dictionary"; dismiss() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saveTitle) {
                    do {
                        try model.rememberCorrection(heard: heard, written: written, expectedDraft: draft)
                        dismiss()
                    } catch { saveError = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
                    .disabled(proposal == nil || model.phase != .idle || (proposal?.isAlreadyRemembered == true && proposal?.changesDraft == false))
            }
        }.padding(24).frame(width: 550).workbenchTheme()
            .onAppear { focused = heard.isEmpty ? .heard : .written }
            .onChange(of: heard) { _, _ in saveError = nil }
            .onChange(of: written) { _, _ in saveError = nil }
    }
}
