import SwiftUI

struct HistorySelectionControls: View {
    @ObservedObject var history: WorkbenchHistoryModel
    var onHandOff: () -> Void
    @State private var editor: HistorySelectionEditorRequest?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(history.selected.count) selected").font(.callout.weight(.medium))
                Menu("Saved selections") {
                    if history.savedSelections.isEmpty { Text("No saved selections yet") }
                    ForEach(history.savedSelections) { selection in
                        Button("\(selection.name) · \(selection.items.count)") { history.loadSelection(selection.id) }
                    }
                    if !history.savedSelections.isEmpty {
                        Divider()
                        Menu("Remove saved selection") {
                            ForEach(history.savedSelections) { selection in
                                Button(selection.name) { history.removeSelection(selection.id) }
                            }
                        }
                    }
                }.fixedSize()
                Button("Save selection…") { editor = HistorySelectionEditorRequest() }.disabled(history.selected.isEmpty)
                if !history.savedSelections.isEmpty {
                    Menu("Update…") {
                        ForEach(history.savedSelections) { selection in
                            Button(selection.name) { editor = HistorySelectionEditorRequest(selection: selection) }
                        }
                    }.fixedSize().disabled(history.selected.isEmpty)
                }
                Spacer()
                Button("Clear") { history.setSelected([]) }.disabled(history.selected.isEmpty)
                Button("Hand off…", action: onHandOff).disabled(history.selected.isEmpty).buttonStyle(.borderedProminent)
            }
            if let error = history.error { WorkbenchNote(error) }
        }
        .sheet(item: $editor) { request in
            HistorySelectionEditor(history: history, request: request)
        }
    }
}

/// The sheet receives its mode and initial values together. A fresh presentation
/// identity keeps a cancelled draft out of the next create or update operation.
private struct HistorySelectionEditorRequest: Identifiable {
    let id = UUID()
    let selectionID: UUID?
    let name: String

    init(selection: SavedWorkbenchSelection? = nil) {
        selectionID = selection?.id
        name = selection?.name ?? ""
    }
}

private struct HistorySelectionEditor: View {
    @ObservedObject var history: WorkbenchHistoryModel
    let selectionID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(history: WorkbenchHistoryModel, request: HistorySelectionEditorRequest) {
        self.history = history
        selectionID = request.selectionID
        _name = State(initialValue: request.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(selectionID == nil ? "Save this selection" : "Update saved selection").font(.title2)
            Text(selectionID == nil
                 ? "Return to these same items later. New recordings and search filters won’t change it."
                 : "Update the name and replace its saved items with your current selection. Existing handoff tasks keep their own inputs.")
                .foregroundStyle(.secondary)
            TextField("Name", text: $name)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    history.saveSelection(name: name, id: selectionID)
                    if history.error == nil { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = history.error { WorkbenchNote(error) }
        }.padding(24).frame(width: 420)
    }
}

struct TranscriptMetadataEditor: View {
    let transcript: Transcript
    @ObservedObject var library: WorkbenchHistoryModel
    var suggest: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var purpose: TranscriptPurpose = .prompt
    @State private var person = ""
    @State private var company = ""
    @State private var tags = ""
    @State private var suggesting = false
    @State private var localSuggestion: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transcript details").font(.title2)
            Text("Details help you find this later. Your original words stay unchanged.").foregroundStyle(.secondary)
            ForEach(library.metadata(for: transcript.id).captureNotes, id: \.self) { note in
                WorkbenchNote(note, symbol: "exclamationmark.triangle")
            }
            Picker("Purpose", selection: $purpose) {
                ForEach(TranscriptPurpose.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            TextField("Person", text: $person)
            TextField("Company", text: $company)
            TextField("Tags, separated by commas", text: $tags)
            if let receipt = library.metadata(for: transcript.id).reviewedSuggestion {
                Text("Last reviewed suggestion: " + receipt).font(.caption2).foregroundStyle(.secondary)
            }
            // One Suggest action: this Mac first, an assistant as a choice.
            Group {
                if let suggest {
                    Menu(suggesting ? "Suggesting…" : "Suggest details") {
                        Button("Ask an assistant…") { dismiss(); suggest() }
                    } primaryAction: { suggestOnThisMac() }
                } else {
                    Button(suggesting ? "Suggesting…" : "Suggest details") { suggestOnThisMac() }
                }
            }.fixedSize().disabled(suggesting)
                .help((LocalDetailSuggestions.usesAppleIntelligence
                       ? "Fills empty names and adds tags using Apple Intelligence on this Mac. Nothing is sent anywhere."
                       : "Fills empty names on this Mac. Nothing is sent anywhere. Turn on Apple Intelligence to also suggest tags.")
                      + (suggest == nil ? "" : " For a fuller suggestion you review, choose Ask an assistant… from its menu."))
            if let localSuggestion {
                Text("Suggested on this Mac (\(localSuggestion)). Check names before saving.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    let saved = library.metadata(for: transcript.id)
                    library.setMetadata(TranscriptMetadata(purpose: purpose, person: person, company: company,
                        tags: tags.split(separator: ",").map { String($0) },
                        reviewedSuggestion: localSuggestion.map { "On this Mac · " + $0 } ?? saved.reviewedSuggestion,
                        captureNotes: saved.captureNotes), for: transcript.id)
                    if library.error == nil { dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
            if let error = library.error { WorkbenchNote(error) }
        }.padding(24).frame(width: 450)
            .onAppear {
                let metadata = library.metadata(for: transcript.id)
                purpose = metadata.purpose; person = metadata.person; company = metadata.company; tags = metadata.tags.joined(separator: ", ")
            }
    }

    /// Fills only empty details for review. Nothing is saved until Save.
    private func suggestOnThisMac() {
        suggesting = true
        let current = TranscriptMetadata(purpose: purpose, person: person, company: company,
            tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        let text = transcript.text
        Task { @MainActor in
            let suggestion = await LocalDetailSuggestions.suggest(for: text)
            let merged = LocalDetailSuggestions.merged(current, with: suggestion)
            purpose = merged.purpose; person = merged.person; company = merged.company
            tags = merged.tags.joined(separator: ", ")
            localSuggestion = suggestion.source
            suggesting = false
        }
    }
}

struct SubscriptionSettingsView: View {
    @ObservedObject var jobs: HandoffJobsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkbenchSectionTitle("Assistant handoffs")
            Text("Use an installed Codex or Claude Code CLI with its own sign-in. Only the items you review for a task are shared. Copy instructions works without a connection.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(SubscriptionProvider.allCases) { provider in
                VStack(alignment: .leading, spacing: 5) {
                    Toggle("Use installed \(provider.title)", isOn: Binding(get: { jobs.enabled(provider) }, set: { jobs.setEnabled(provider, $0) }))
                    if jobs.enabled(provider) {
                        if let connection = jobs.connections[provider] {
                            Label(connection.detail, systemImage: connection.ready ? "checkmark.circle" : "exclamationmark.circle")
                                .font(.caption).foregroundStyle(connection.ready ? Color.secondary : Color.orange)
                            if !connection.version.isEmpty { Text(connection.version).font(.caption2).foregroundStyle(.secondary) }
                        } else { Text("Checking the installed CLI…").font(.caption).foregroundStyle(.secondary) }
                        Link("Install or sign in with \(provider.title)", destination: URL(string: provider == .claude
                            ? "https://code.claude.com/docs/en/quickstart" : "https://learn.chatgpt.com/docs/codex/cli")!)
                            .font(.caption)
                    }
                }
            }
            Button("Check connections") { Task { await jobs.refresh() } }.disabled(jobs.refreshing || jobs.isBusy)
            Text("Workbench does not store provider credentials. Managed account policies and provider usage limits still apply. Tasks return to History; they don’t continue an existing desktop chat.")
                .font(.caption).foregroundStyle(.secondary)
        }.task { await jobs.refresh() }
    }
}

/// One Connections sheet for every handoff surface, so checking a provider
/// returns to the work in progress instead of leaving it for Settings.
struct HandoffConnectionsSheet: View {
    @ObservedObject var jobs: HandoffJobsModel
    var backTitle: String
    var back: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SubscriptionSettingsView(jobs: jobs)
            HStack { Spacer(); Button(backTitle, action: back).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 530)
    }
}

/// One Hand off task with every control the former Handoffs page gave it: its
/// state and warnings, attempts, Retry, the tasks grouped under one review and
/// its result. History shows each visible task with this card and places what
/// the task was made from in `madeFrom`. `revealed` names the task a door asked
/// to show, which can be this task or one grouped under it.
struct HandoffJobCard<MadeFrom: View>: View {
    @ObservedObject var jobs: HandoffJobsModel
    let job: HandoffJob
    @Binding var expanded: UUID?
    var revealed: UUID?
    var focus: FocusState<UUID?>.Binding
    var voiceOverFocus: AccessibilityFocusState<UUID?>.Binding
    var applySuggestedMetadata: ((HandoffJob, String) -> Void)?
    var query = ""
    var copyResult: (HandoffJob, String) -> Void = { _, _ in }
    @ViewBuilder var madeFrom: MadeFrom
    @State private var showingOthers = false

    var body: some View {
        let files = jobs.files(job)
        let resultReady = job.status == .completed && files?.resultReadable == true
        let context = Self.context(job)
        let others = jobs.otherReviewJobs(job)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.up.forward.app").foregroundStyle(Workbench.accent)
                Text(job.title).font(.headline)
                Spacer()
                Text(job.status.title).font(.caption.weight(.medium))
            }.accessibilityElement(children: .ignore)
                .accessibilityLabel("Result, \(job.title), \(job.status.title)")
                .focusable(revealed == job.id).focused(focus, equals: job.id)
                .accessibilityFocused(voiceOverFocus, equals: job.id)
            Text((job.itemCount == 1 ? "1 item" : "\(job.itemCount) items") + " · " + HistoryDate.text(job.createdAt))
                .font(.subheadline).foregroundStyle(.secondary)
            madeFrom
            Text(job.detail).font(.callout)
            if job.status == .completed && files?.resultReadable == false {
                resultProblem(files)
            }
            if let key = job.reviewKey, jobs.currentReviewDigest?(key) != nil {
                HStack {
                    Button("Open current review") { jobs.onOpenReview?(key) }
                        .accessibilityLabel("Open current review, " + context)
                    if let current = jobs.currentPublishedJob(key: key) {
                        Text("Current result · " + HistoryDate.text(current.updatedAt))
                            .font(.caption).foregroundStyle(.secondary)
                    } else { Text("Current document includes local edits or an overview.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            HStack {
                Button("Copy instructions") { jobs.copy(job) }.accessibilityLabel("Copy instructions, " + context)
                Button("Show selected files") { jobs.showInputs(job) }.accessibilityLabel("Show selected files, " + context)
                if job.status == .completed {
                    Button(expanded == job.id ? "Hide result" : "Review result") { expanded = expanded == job.id ? nil : job.id }
                        .disabled(!resultReady && expanded != job.id)
                        .accessibilityLabel((expanded == job.id ? "Hide result, " : "Review result, ") + context)
                    Button("Open result") { jobs.showResult(job) }.disabled(!resultReady)
                        .accessibilityLabel("Open result, " + context)
                    if job.reviewKey != nil {
                        Button("Use as current review") { jobs.publishReview(job, replacingChanges: true) }.disabled(jobs.isBusy || !resultReady)
                            .accessibilityLabel("Use as current review, " + context)
                    }
                }
                startAction(job)
            }.buttonStyle(.borderless).font(.callout)
            if let session = job.providerSessionID {
                Text("Provider receipt: \(session)").textSelection(.enabled).font(.caption2).foregroundStyle(.secondary)
            }
            if !job.previousAttempts.isEmpty {
                DisclosureGroup("Previous attempts") {
                    ForEach(job.previousAttempts, id: \.number) { attempt in
                        Text("Attempt \(attempt.number) · \(attempt.provider.title) · \(attempt.status.title)\n"
                             + attempt.detail + (attempt.providerSessionID.map { "\nProvider receipt: " + $0 } ?? ""))
                            .font(.caption).textSelection(.enabled)
                    }
                }.font(.caption)
            }
            if !others.isEmpty {
                DisclosureGroup("Other tasks for this review (\(others.count))", isExpanded: $showingOthers) {
                    ForEach(others) { previous in
                        let previousContext = Self.context(previous)
                        let readable = previous.status == .completed && jobs.files(previous)?.resultReadable == true
                        VStack(alignment: .leading, spacing: 6) {
                            Text(HistoryDate.text(previous.createdAt) + " · " + previous.status.title)
                                .accessibilityLabel("Earlier task, \(previous.title), \(previous.status.title), "
                                                    + HistoryDate.text(previous.createdAt))
                                .focusable(revealed == previous.id).focused(focus, equals: previous.id)
                                .accessibilityFocused(voiceOverFocus, equals: previous.id)
                            Text(previous.detail).foregroundStyle(.secondary)
                            if !query.isEmpty && jobs.matchesResult(previous, query: query, includingGrouped: false) {
                                Text("Matches search").foregroundStyle(Workbench.accent)
                            }
                            if previous.status == .completed && jobs.files(previous)?.resultReadable == false {
                                resultProblem(jobs.files(previous))
                            }
                            HStack {
                                Button("Show selected files") { jobs.showInputs(previous) }
                                    .accessibilityLabel("Show selected files, " + previousContext)
                                if previous.status == .completed {
                                    Button(expanded == previous.id ? "Hide result" : "Review result") {
                                        expanded = expanded == previous.id ? nil : previous.id
                                    }.disabled(!readable && expanded != previous.id)
                                        .accessibilityLabel((expanded == previous.id ? "Hide result, " : "Review result, ") + previousContext)
                                    Button("Open saved result") { jobs.showResult(previous) }.disabled(!readable)
                                        .accessibilityLabel("Open saved result, " + previousContext)
                                    Button("Use as current review") { jobs.publishReview(previous, replacingChanges: true) }
                                        .disabled(jobs.isBusy || !readable)
                                        .accessibilityLabel("Use as current review, " + previousContext)
                                }
                                startAction(previous)
                            }
                            if expanded == previous.id && previous.status == .completed { resultPreview(previous) }
                        }.font(.caption).padding(.vertical, 4).padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(revealed == previous.id ? Workbench.accent : .clear, lineWidth: 2))
                            .id(HistoryEntry.ID.result(previous.id))
                    }
                }
            }
            if expanded == job.id && job.status == .completed { resultPreview(job) }
        }
        // A grouped task revealed by a door or matching a search opens its group.
        .onChange(of: revealed, initial: true) {
            if let revealed, revealed != job.id, others.contains(where: { $0.id == revealed }) { showingOthers = true }
        }
        .onChange(of: query, initial: true) { showMatchingGroup(others) }
        .onChange(of: jobs.taskFiles) { showMatchingGroup(others) }
    }

    private func showMatchingGroup(_ others: [HandoffJob]) {
        if !query.isEmpty && others.contains(where: { jobs.matchesResult($0, query: query, includingGrouped: false) }) {
            showingOthers = true
        }
    }

    private func resultProblem(_ files: HandoffTaskFiles?) -> some View {
        WorkbenchNote(files?.resultProblem ?? "The saved result is unavailable. Show selected files opens the task folder.",
                      symbol: "exclamationmark.triangle")
    }

    @ViewBuilder private func resultPreview(_ task: HandoffJob) -> some View {
        // The visible text and action closures take the same immutable cache
        // value. No file read can replace the words between review and reuse.
        if let files = jobs.files(task) {
            if let result = files.resultText {
                HandoffResultPreview(text: result, context: Self.context(task),
                    copyText: { copyResult(task, result) })
                if let applySuggestedMetadata, jobs.isMetadataSuggestion(task) {
                    Button("Review suggested details…") { applySuggestedMetadata(task, result) }
                }
            } else { resultProblem(files) }
        } else { ProgressView().controlSize(.small) }
    }

    /// Names the task an action belongs to, since every card repeats its buttons.
    static func context(_ job: HandoffJob) -> String {
        job.title + ", " + HistoryDate.text(job.createdAt)
    }

    @ViewBuilder private func startAction(_ job: HandoffJob) -> some View {
        if job.status == .ready || [.failed, .cancelled, .interrupted].contains(job.status) {
            Menu {
                ForEach(SubscriptionProvider.allCases) { provider in
                    Button((job.status == .ready ? "Start with " : "Retry with ") + provider.title) {
                        jobs.start(job, provider: provider, retry: job.status != .ready)
                    }.disabled(jobs.isBusy || !jobs.canRun(job, with: provider))
                }
            } label: {
                // A menu's own title ignores the row's font, so it is set here to match the links beside it.
                Text(job.status == .ready ? "Start task…" : "Retry…").font(.callout)
            }.fixedSize().accessibilityLabel((job.status == .ready ? "Start task, " : "Retry, ") + Self.context(job))
        }
    }
}

/// Copies the exact words currently shown by visual result review.
struct HandoffResultPreview: View {
    let text: String
    let context: String
    var copyText: () -> Void

    var body: some View {
        // The words, then Copy below them, as every other Copy in Workbench sits under its text.
        VStack(alignment: .leading, spacing: 8) {
            Text(text.isEmpty ? "The saved result has no text." : text)
                .textSelection(.enabled).font(.body)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(Workbench.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Workbench.border))
            Button("Copy result", action: copyText).accessibilityLabel("Copy result, " + context)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

struct HandoffReviewView: View {
    @ObservedObject var history: WorkbenchHistoryModel
    @ObservedObject var jobs: HandoffJobsModel
    var skills: [TranscriptHandoffSkill]
    var initialTask: String?
    var preferredSkillID: String? = nil
    var selectedSnapTalkSession: URL? = nil
    var initialEvidenceURL: URL? = nil
    /// Why a Snap & Talk session cannot be packaged yet: its owner is still
    /// transcribing it or holds an unsaved narration edit. Checked when evidence
    /// is added and again when the task is prepared.
    var evidenceProblem: (URL) -> String? = { _ in nil }
    var resolveReviewContext: (() throws -> SnapReviewContext?)? = nil
    var resolveSources: () throws -> [HandoffSourceSnapshot]
    /// Receives the task this review actually prepared or reused, so the host
    /// can reveal that task instead of assuming a new one.
    var onPrepared: (UUID) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var task = ""
    @State private var sources: [HandoffSourceSnapshot] = []
    @State private var roles: [WorkbenchItemReference: HandoffInputRole] = [:]
    @State private var skillID = TranscriptHandoffSkill.followUp.id
    @State private var problem: String?
    @State private var evidenceURL: URL?
    @State private var reviewContext: SnapReviewContext?
    @State private var includePreviousReview = true
    @State private var showingConnections = false
    @State private var showingPreviousReview = false
    @State private var initialized = false
    @State private var selectedProvider: SubscriptionProvider = .codex
    @State private var loadedSkill: ReadbackSkillPackSnapshot?
    @State private var skillProblem: String?
    @StateObject private var evidencePicker = TranscriptHandoffRunner()
    private var skill: TranscriptHandoffSkill { skills.first(where: { $0.id == skillID }) ?? .followUp }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hand off selected work").font(.title2.weight(.semibold))
            Text("\(sources.count) \(sources.count == 1 ? "item" : "items"). Each task keeps this selection, even when you pick different items later.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("What should the assistant prepare?", text: $task, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                    Picker("Skill", selection: $skillID) { ForEach(skills) { Text($0.title).tag($0.id) } }
                    if let reviewContext {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Current review: " + reviewContext.title).font(.callout.weight(.medium))
                            Text("A successful result updates this review. Existing task results remain available. Suggested exclusions are never applied automatically.")
                                .font(.caption).foregroundStyle(.secondary)
                            if reviewContext.previousDocument != nil {
                                HStack {
                                    Toggle("Include the previous review as reference", isOn: $includePreviousReview).toggleStyle(.checkbox)
                                    Button("Read…") { showingPreviousReview = true }
                                }.font(.caption)
                            }
                        }
                    }
                    HStack {
                        if let evidenceURL {
                            Label("Snap & Talk: " + evidenceURL.lastPathComponent, systemImage: "photo.on.rectangle").font(.caption)
                            Button("Remove evidence") { self.evidenceURL = nil; refreshSources() }.font(.caption)
                        } else {
                            Menu("Add Snap & Talk evidence…") {
                                if let selectedSnapTalkSession {
                                    Button("Use the open session") { useEvidence(selectedSnapTalkSession) }
                                }
                                Button("Choose a session…") {
                                    if let url = evidencePicker.chooseEvidence() { useEvidence(url) }
                                }
                            }.fixedSize().font(.caption)
                        }
                    }
                    if evidenceURL != nil {
                        Text("Includes live screenshots and the saved narration paired with each one. Original audio stays in the session; its own Hand off action retains the complete portable workflow.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(sources, id: \.reference) { source in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.title).font(.callout.weight(.medium)).lineLimit(2)
                                    Text(source.text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    ForEach(source.captureNotes, id: \.self) { note in
                                        WorkbenchNote(note, symbol: "exclamationmark.triangle")
                                    }
                                    ForEach(Array(source.images.enumerated()), id: \.offset) { _, bytes in
                                        if let image = NSImage(data: bytes) {
                                            // Read what will be shared at full size (#154).
                                            CapturePreviewButton("View image to share for " + source.title, item: { .toShare(title: source.title, png: bytes) }, collection: { sources.flatMap { source in source.images.map { .toShare(title: source.title, png: $0) } } }) {
                                                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 340, maxHeight: 110)
                                            }
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Picker("Use as", selection: Binding(get: { roles[source.reference] ?? source.role }, set: { roles[source.reference] = $0 })) {
                                    ForEach(HandoffInputRole.allCases, id: \.self) { Text($0.title).tag($0) }
                                }.fixedSize().accessibilityLabel("Use \(source.title) as")
                            }.padding(10).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    Text("Meeting speech and images start as reference material. “My instructions” means you adopt that text as your request. Connected tasks send the reviewed material to the chosen provider and return a draft for review.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !skill.repliesInline {
                        Text("This skill uses the manual handoff so your assistant can create its requested files. Copy instructions, then attach the selected work folder.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(sources.contains(where: { !$0.images.isEmpty })
                        ? "Copy instructions includes the complete text and names each image to attach. Edited Snaps share the visible crop and annotations; originals stay in History."
                        : "Copy instructions includes the complete request and selected text. For a text reply, paste these instructions into your assistant; no Workbench connection is needed.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        Picker("Run with", selection: $selectedProvider) {
                            ForEach(SubscriptionProvider.allCases) { Text($0.title).tag($0) }
                        }
                        Button("Check again") { Task { await jobs.refresh() } }.disabled(jobs.refreshing)
                    }
                    Text(readiness.detail).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("handoff.runner-readiness")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let problem { WorkbenchNote(problem) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connections…") { showingConnections = true }
                Spacer()
                Button("Copy instructions") { submit(provider: nil) }.disabled(sources.isEmpty)
                Button("Start task") { submit(provider: selectedProvider) }.disabled(!readiness.canStart)
            }
        }.padding(24)
            .frame(width: 680, height: min(720, max(400, (NSScreen.main?.visibleFrame.height ?? 820) - 100)))
            .onChange(of: skillID) { previous, current in
                loadSkill()
                // The task follows the chosen skill only while it is still the
                // previous skill's suggestion; typed requests are never replaced.
                let before = skills.first(where: { $0.id == previous })?.defaultTask
                guard initialTask == nil, task.isEmpty || task == before,
                      let suggested = skills.first(where: { $0.id == current })?.defaultTask else { return }
                task = suggested
            }
            .onAppear {
                guard !initialized else { return }
                initialized = true
                task = initialTask ?? TranscriptHandoffSkill.followUp.defaultTask ?? ""
                if let preferredSkillID, skills.contains(where: { $0.id == preferredSkillID }) { skillID = preferredSkillID }
                evidenceURL = initialEvidenceURL
                loadSkill()
                refreshSources()
                Task { await jobs.refresh() }
            }
            .sheet(isPresented: $showingConnections) {
                HandoffConnectionsSheet(jobs: jobs, backTitle: "Back to handoff") { showingConnections = false }
            }
            .onChange(of: showingConnections) { _, shown in
                if !shown { Task { await jobs.refresh() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await jobs.refresh() }
            }
            .sheet(isPresented: $showingPreviousReview) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Previous review · reference material").font(.title2)
                    Text("Assistant proposals have not been applied to your Snaps. Current names and archive choices come from History.").font(.caption).foregroundStyle(.secondary)
                    ScrollView { Text(reviewContext?.previousDocument ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack { Spacer(); Button("Back to handoff") { showingPreviousReview = false }.keyboardShortcut(.defaultAction) }
                }.padding(24).frame(width: 660, height: 550)
            }
    }
    private func submit(provider: SubscriptionProvider?) {
        if let evidenceURL, let waiting = evidenceProblem(evidenceURL) { problem = waiting; return }
        do {
            var latest = try currentSources()
            var latestReview = try resolveReviewContext?()
            guard latest == sources, latestReview == reviewContext else {
                sources = latest; reviewContext = latestReview; roles = [:]
                problem = "Selected content changed since this review opened. Check the refreshed items and roles, then try again."
                return
            }
            if !includePreviousReview { latestReview?.previousDocument = nil }
            for index in latest.indices { latest[index].role = roles[latest[index].reference] ?? latest[index].role }
            try jobs.handOff(sources: latest, task: task, skill: skill.load(), review: latestReview, provider: provider) { id in
                onPrepared(id); dismiss()
            }
            if let error = jobs.error { problem = error }
        } catch { problem = error.localizedDescription }
    }
    private var readiness: HandoffRunReadiness {
        var inputProblem = skillProblem
        if sources.isEmpty { inputProblem = "Choose readable saved items before starting a task." }
        else if sources.count > HandoffJobStore.maximumItems { inputProblem = "Select between 1 and 200 items." }
        else if task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || task.count > 20_000 {
            inputProblem = "Describe what you want to prepare, in up to 20,000 characters."
        }
        if let loadedSkill, inputProblem == nil {
            var items = sources
            for index in items.indices { items[index].role = roles[items[index].reference] ?? items[index].role }
            var review = reviewContext
            if !includePreviousReview { review?.previousDocument = nil }
            let id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            let snapshot = HandoffSnapshotRecord(id: id, createdAt: .distantPast,
                task: task.trimmingCharacters(in: .whitespacesAndNewlines), skill: loadedSkill.reference,
                items: HandoffJobStore.inputRecords(items), review: review)
            let text = String(data: loadedSkill.files["SKILL.md"] ?? Data(), encoding: .utf8) ?? ""
            let prompt = HandoffJobStore.prompt(snapshot: snapshot, skill: text,
                folder: jobs.directory.appendingPathComponent(id.uuidString), manual: false)
            inputProblem = HandoffRunReadiness.inputProblem(provider: selectedProvider, prompt: prompt,
                imageBytes: items.flatMap(\.images).map(\.count))
        }
        return HandoffRunReadiness.evaluate(provider: selectedProvider, enabled: jobs.enabled(selectedProvider),
            checking: jobs.refreshing, connection: jobs.connections[selectedProvider], busy: jobs.isBusy,
            compatible: loadedSkill.map { SkillMetadata(snapshot: $0).repliesInline && $0.files.count == 1 } ?? true,
            inputProblem: inputProblem)
    }
    private func loadSkill() {
        do { loadedSkill = try skill.load(); skillProblem = nil }
        catch { loadedSkill = nil; skillProblem = error.localizedDescription }
    }
    private func currentSources() throws -> [HandoffSourceSnapshot] {
        var result = try resolveSources()
        if let evidenceURL { result += try HandoffSessionEvidence.snapshots(at: evidenceURL) }
        return result
    }
    private func refreshSources() {
        do { sources = try currentSources(); reviewContext = try resolveReviewContext?(); roles = [:]; problem = nil }
        catch { problem = error.localizedDescription }
    }
    private func useEvidence(_ url: URL) {
        if let waiting = evidenceProblem(url) { problem = waiting; return }
        do {
            _ = try HandoffSessionEvidence.snapshots(at: url)
            evidenceURL = url; refreshSources()
        } catch { problem = error.localizedDescription }
    }
}
