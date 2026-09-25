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
    /// Skills offered beside the built-in neutral follow-up skill. The closure
    /// runs when selection starts, so a host can supply installed pack entries
    /// without this view owning a pack store or knowing where packs come from.
    var handoffSkills: () -> [TranscriptHandoffSkill] = { [] }
    /// Preselects one of those skills by `TranscriptHandoffSkill.id`. Nil keeps
    /// the neutral follow-up skill selected.
    var preferredHandoffSkillID: String? = nil
    /// A Snap & Talk session the host has already selected, offered as optional
    /// evidence. Nil leaves the explicit folder chooser as the only route.
    var selectedSnapTalkSession: URL? = nil

    @StateObject private var handoff = TranscriptHandoffRunner()
    @State private var query = ""
    @State private var original: Transcript?
    @State private var removal: Transcript?
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var skills: [TranscriptHandoffSkill] = [.followUp]
    @State private var skillID = TranscriptHandoffSkill.followUp.id
    @State private var transcriptRole: TranscriptHandoffRole = .instructions
    @State private var evidence: URL?

    private var matches: [Transcript] { TranscriptHistory.matching(model.history, query: query) }
    /// Selection lives as transcript UUIDs and is always resolved against the
    /// saved history: a removed transcript simply stops being selected, and a
    /// search never adds an item the person did not choose.
    private var selected: [Transcript] { TranscriptHandoffSelection.resolve(selection, in: model.history) }
    private var hiddenSelectionCount: Int {
        let visible = Set(matches.map(\.id))
        return selected.filter { !visible.contains($0.id) }.count
    }
    private var chosenSkill: TranscriptHandoffSkill { skills.first { $0.id == skillID } ?? .followUp }
    private var selectionSummary: String {
        guard !selected.isEmpty else { return "No transcripts selected" }
        let hidden = hiddenSelectionCount
        return "\(selected.count) selected" + (hidden > 0 ? " · \(hidden) hidden by this search" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(model.history.count) saved · last \(TranscriptHistory.limit) kept on this Mac")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !compact && !model.history.isEmpty {
                    Button(selecting ? "Done selecting" : "Select…") { toggleSelecting() }
                        .buttonStyle(.borderless).font(.system(size: 11))
                        .accessibilityLabel(selecting ? "Stop selecting transcripts" : "Select transcripts for a handoff")
                        .accessibilityHint(selecting ? "Clears the current selection" : "Shows a checkbox on each transcript")
                        .help("Choose several transcripts and hand them to Claude, ChatGPT or Codex")
                }
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
                        ForEach(matches) { item in row(item) }
                    }
                }
            }
            if selecting && !compact { handoffPanel }
            if compact { Button("Open full history…") { model.onShowEditor?("history") }.buttonStyle(.link) }
        }
        .onChange(of: model.history.map(\.id)) { _, ids in
            // A transcript removed here or elsewhere leaves the selection with it.
            selection = selection.intersection(Set(ids))
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

    private func row(_ item: Transcript) -> some View {
        let accessibilityContext = CaptureHistoryAccessibility.context(for: item, history: model.history)
        return HStack(alignment: .top, spacing: 12) {
            if selecting && !compact {
                Toggle("", isOn: selectionBinding(for: item))
                    .toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel(CaptureHistoryAccessibility.label("Include in handoff", context: accessibilityContext))
                    .accessibilityValue(selection.contains(item.id) ? "Selected" : "Not selected")
            }
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
            }
        }.padding(compact ? 12 : 18)
            .background(Workbench.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    /// Selection, the chosen skill, optional screen evidence and the same
    /// Hand off targets Snap & Talk uses. Nothing here sends anything: it
    /// creates one local folder and copies a prompt.
    private var handoffPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(selectionSummary).font(.system(size: 12, weight: .medium))
                    .accessibilityLabel("\(selected.count) transcripts selected for a handoff")
                    .accessibilityValue(hiddenSelectionCount > 0 ? "\(hiddenSelectionCount) of them are hidden by the current search" : "All of them are shown")
                Spacer()
                Button("Clear selection") { selection = []; handoff.reset() }
                    .disabled(selected.isEmpty)
                Menu {
                    ForEach(ReadbackHandoffTarget.allCases) { target in
                        Button { handOff(to: target) } label: {
                            Label(target.title, systemImage: target == .claude ? "sparkles" : "bubble.left.and.text.bubble.right")
                        }
                    }
                } label: {
                    Label("Hand off…", systemImage: "arrow.up.forward.app")
                }.fixedSize()
                    .disabled(selected.isEmpty || handoff.isPreparing)
                    .help("Create one folder with the selected transcripts and chosen skill, copy its prompt and open the chosen app")
                    .accessibilityHint("Creates a local folder and copies a prompt. Workbench does not send or upload anything")
            }
            HStack(spacing: 12) {
                Picker("Skill:", selection: $skillID) {
                    ForEach(skills) { skill in Text(skill.title).tag(skill.id) }
                }.fixedSize()
                    .accessibilityLabel("Handoff skill")
                    .accessibilityHint(chosenSkill.detail)
                Spacer()
                evidenceControls
            }
            Picker("Use selected dictation as", selection: $transcriptRole) {
                ForEach(TranscriptHandoffRole.allCases, id: \.self) { role in Text(role.title).tag(role) }
            }.pickerStyle(.segmented).fixedSize()
            Text(chosenSkill.detail).font(.caption).foregroundStyle(.secondary)
            if let failure = handoff.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Handoff problem. \(failure)")
            }
            if let status = handoff.status {
                Label(status, systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Handoff status. \(status)")
            }
        }.padding(14)
            .background(Workbench.surface, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Hand off selected transcripts")
    }

    @ViewBuilder private var evidenceControls: some View {
        if let evidence {
            HStack(spacing: 8) {
                Label("Screen evidence: \(evidence.lastPathComponent)", systemImage: "photo.on.rectangle")
                    .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                Button("Remove") { self.evidence = nil; handoff.reset() }
                    .buttonStyle(.borderless).font(.system(size: 11))
                    .accessibilityLabel("Do not include that Snap & Talk session")
            }.accessibilityElement(children: .contain)
                .accessibilityLabel("Including the whole Snap & Talk session \(evidence.lastPathComponent)")
        } else {
            Menu("Add screen evidence…") {
                if let session = selectedSnapTalkSession {
                    Button("Use the whole session “\(session.lastPathComponent)”") { evidence = handoff.useEvidence(session) }
                }
                Button("Choose a Snap & Talk session folder…") { evidence = handoff.chooseEvidence() }
            }.fixedSize()
                .help("Optional: copy one whole Snap & Talk session — every current screenshot with the narration recorded for it")
                .accessibilityLabel("Add screen evidence")
                .accessibilityHint("Optional. Copies one session you choose. Items in its Recently Deleted are never copied and the original session is not changed")
        }
    }

    private func selectionBinding(for item: Transcript) -> Binding<Bool> {
        Binding(get: { selection.contains(item.id) },
                set: { include in
                    if include { selection.insert(item.id) } else { selection.remove(item.id) }
                    handoff.reset()
                })
    }

    /// Selection starts empty every time, and leaving selection clears it, so no
    /// hidden earlier choice can travel into a later handoff.
    private func toggleSelecting() {
        selecting.toggle()
        handoff.reset()
        guard selecting else { selection = []; evidence = nil; return }
        // The built-in skill is always offered first; a host entry reusing its
        // id would break the picker, so the first entry for an id wins.
        var offered = [TranscriptHandoffSkill.followUp]
        for skill in handoffSkills() where !offered.contains(where: { $0.id == skill.id }) { offered.append(skill) }
        skills = offered
        if let preferred = preferredHandoffSkillID, skills.contains(where: { $0.id == preferred }) {
            skillID = preferred
        } else if !skills.contains(where: { $0.id == skillID }) {
            skillID = TranscriptHandoffSkill.followUp.id
        }
    }

    private func handOff(to target: ReadbackHandoffTarget) {
        handoff.handOff(to: target, transcripts: selected, skill: chosenSkill, evidence: evidence, role: transcriptRole)
    }
}
