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
            if let error = history.error { Text(error).foregroundStyle(.red).font(.caption) }
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
            if let error = history.error { Text(error).foregroundStyle(.red).font(.caption) }
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
                Label(note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
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
            if let error = library.error { Text(error).foregroundStyle(.red).font(.caption) }
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
            Text("Assistant handoffs").font(.headline)
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
            Text("Workbench does not store provider credentials. Managed account policies and provider usage limits still apply. Tasks return here; they don’t continue an existing desktop chat.")
                .font(.caption).foregroundStyle(.secondary)
        }.task { await jobs.refresh() }
    }
}

struct HandoffJobsView: View {
    @ObservedObject var jobs: HandoffJobsModel
    var applySuggestedMetadata: ((HandoffJob, String) -> Void)?
    var onConnections: (() -> Void)? = nil
    @State private var expanded: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Handoffs").font(.title2.weight(.semibold))
                Spacer()
                if let onConnections { Button("Connections…", action: onConnections) }
                if jobs.isBusy { Button("Stop task", role: .destructive) { jobs.cancel() } }
            }
            if let notice = jobs.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if let error = jobs.error { Text(error).font(.caption).foregroundStyle(.red) }
            if jobs.jobs.isEmpty { Text("Your selected work and its results stay here.").foregroundStyle(.secondary) }
            ForEach(jobs.visibleJobs) { job in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(job.title).font(.headline)
                        Spacer()
                        Text(job.status.title).font(.caption.weight(.medium))
                    }
                    Text("\(job.itemCount) items · \(job.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(job.detail).font(.callout)
                    if let key = job.reviewKey, jobs.currentReviewDigest?(key) != nil {
                        HStack {
                            Button("Open current review") { jobs.onOpenReview?(key) }
                            if let current = jobs.currentPublishedJob(key: key) {
                                Text("Current result · " + current.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            } else { Text("Current document includes local edits or an overview.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    HStack {
                        Button("Copy instructions") { jobs.copy(job) }
                        Button("Show selected files") { jobs.showInputs(job) }
                        if job.status == .completed {
                            Button(expanded == job.id ? "Hide result" : "Read result") { expanded = expanded == job.id ? nil : job.id }
                            Button("Open result") { jobs.showResult(job) }
                            if job.reviewKey != nil {
                                Button("Use as current review") { jobs.publishReview(job, replacingChanges: true) }.disabled(jobs.isBusy)
                            }
                        }
                        startAction(job)
                    }.buttonStyle(.borderless).font(.caption)
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
                    let others = jobs.otherReviewJobs(job)
                    if !others.isEmpty {
                        DisclosureGroup("Other tasks for this review (\(others.count))") {
                            ForEach(others) { previous in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(previous.createdAt.formatted(date: .abbreviated, time: .shortened) + " · " + previous.status.title)
                                    Text(previous.detail).foregroundStyle(.secondary)
                                    HStack {
                                        Button("Show selected files") { jobs.showInputs(previous) }
                                        if previous.status == .completed {
                                            Button("Open saved result") { jobs.showResult(previous) }
                                            Button("Use as current review") { jobs.publishReview(previous, replacingChanges: true) }.disabled(jobs.isBusy)
                                        }
                                        startAction(previous)
                                    }
                                }.font(.caption).padding(.vertical, 4)
                            }
                        }
                    }
                    if expanded == job.id, let result = jobs.result(job) {
                        Text(result).textSelection(.enabled).font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Workbench.background)
                        if let applySuggestedMetadata, jobs.isMetadataSuggestion(job) {
                            Button("Review suggested details…") { applySuggestedMetadata(job, result) }
                        }
                    }
                }.padding(16).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 10))
            }
        }.task { await jobs.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in jobs.objectWillChange.send() }
    }
    @ViewBuilder private func startAction(_ job: HandoffJob) -> some View {
        if job.status == .ready || [.failed, .cancelled, .interrupted].contains(job.status) {
            Menu(job.status == .ready ? "Start task…" : "Retry…") {
                ForEach(SubscriptionProvider.allCases) { provider in
                    Button((job.status == .ready ? "Start with " : "Retry with ") + provider.title) {
                        jobs.start(job, provider: provider, retry: job.status != .ready)
                    }.disabled(jobs.isBusy || !jobs.canRun(job, with: provider))
                }
            }.fixedSize()
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
    var resolveReviewContext: (() throws -> SnapReviewContext?)? = nil
    var resolveSources: () throws -> [HandoffSourceSnapshot]
    var onPrepared: () -> Void = {}
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
    @StateObject private var evidencePicker = TranscriptHandoffRunner()
    private var skill: TranscriptHandoffSkill { skills.first(where: { $0.id == skillID }) ?? .followUp }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hand off selected work").font(.title2.weight(.semibold))
            Text("\(sources.count) items. Each task keeps this selection, even when you pick different items later.")
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
                                        Label(note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                                    }
                                    ForEach(Array(source.images.enumerated()), id: \.offset) { _, bytes in
                                        if let image = NSImage(data: bytes) {
                                            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 340, maxHeight: 110)
                                                .accessibilityLabel("Image to share for " + source.title)
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
                    if skill.id != TranscriptHandoffSkill.followUp.id {
                        Text("This skill uses the manual handoff so your assistant can create its requested files. Copy instructions, then attach the selected work folder.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if sources.contains(where: { !$0.images.isEmpty }) {
                        Text("Codex: up to 64 images, 10 MiB each and 128 MiB together. Claude Code: up to 20 images, 3.75 MiB each and 16 MiB together, with a 24 MiB encoded request limit. Edited Snaps share the visible crop and annotations; originals stay in Snap History. Copy instructions keeps the complete selection.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connections…") { showingConnections = true }
                Spacer()
                Button("Copy instructions") { submit(provider: nil) }.disabled(sources.isEmpty)
                Menu("Start task") {
                    ForEach(SubscriptionProvider.allCases) { provider in
                        Button("Start with \(provider.title)") { submit(provider: provider) }
                            .disabled(jobs.connections[provider]?.ready != true || !jobs.enabled(provider) || !supports(provider))
                    }
                }.disabled(sources.isEmpty || jobs.isBusy || skill.id != TranscriptHandoffSkill.followUp.id).menuStyle(.borderlessButton).fixedSize()
            }
        }.padding(24)
            .frame(width: 680, height: min(720, max(400, (NSScreen.main?.visibleFrame.height ?? 820) - 100)))
            .onAppear {
                guard !initialized else { return }
                initialized = true
                task = initialTask ?? "Prepare the requested follow-up from my selected instructions and reference material. Identify any essential missing information."
                if let preferredSkillID, skills.contains(where: { $0.id == preferredSkillID }) { skillID = preferredSkillID }
                evidenceURL = initialEvidenceURL
                refreshSources()
                Task { await jobs.refresh() }
            }
            .sheet(isPresented: $showingConnections) {
                VStack(alignment: .leading, spacing: 16) {
                    SubscriptionSettingsView(jobs: jobs)
                    HStack { Spacer(); Button("Back to handoff") { showingConnections = false }.keyboardShortcut(.defaultAction) }
                }.padding(24).frame(width: 530)
            }
            .sheet(isPresented: $showingPreviousReview) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Previous review · reference material").font(.title2)
                    Text("Assistant proposals have not been applied to your Snaps. Current names and archive choices come from Snap History.").font(.caption).foregroundStyle(.secondary)
                    ScrollView { Text(reviewContext?.previousDocument ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack { Spacer(); Button("Back to handoff") { showingPreviousReview = false }.keyboardShortcut(.defaultAction) }
                }.padding(24).frame(width: 660, height: 550)
            }
    }
    private func submit(provider: SubscriptionProvider?) {
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
            let job = try jobs.prepare(sources: latest, task: task, skill: skill.load(), review: latestReview)
            if let provider { jobs.start(job, provider: provider, retry: [.failed, .cancelled, .interrupted].contains(job.status)) } else { jobs.copy(job) }
            if jobs.error == nil { onPrepared(); dismiss() } else { problem = jobs.error }
        } catch { problem = error.localizedDescription }
    }
    private func supports(_ provider: SubscriptionProvider) -> Bool {
        let images = sources.flatMap(\.images)
        return images.count <= SubscriptionCLILimits.maximumImages(for: provider)
            && images.allSatisfy { $0.count <= SubscriptionCLILimits.maximumImageBytes(for: provider) }
            && images.reduce(0, { $0 + $1.count }) <= SubscriptionCLILimits.maximumTotalImageBytes(for: provider)
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
        do {
            _ = try HandoffSessionEvidence.snapshots(at: url)
            evidenceURL = url; refreshSources()
        } catch { problem = error.localizedDescription }
    }
}
