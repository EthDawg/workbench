import SwiftUI

struct HistorySelectionControls: View {
    @ObservedObject var history: WorkbenchHistoryModel
    var onHandOff: () -> Void
    @State private var naming = false
    @State private var name = ""
    @State private var editingID: UUID?
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
                Button("Save selection…") { editingID = nil; name = ""; naming = true }.disabled(history.selected.isEmpty)
                if !history.savedSelections.isEmpty {
                    Menu("Update…") {
                        ForEach(history.savedSelections) { selection in
                            Button(selection.name) { editingID = selection.id; name = selection.name; naming = true }
                        }
                    }.fixedSize().disabled(history.selected.isEmpty)
                }
                Spacer()
                Button("Clear") { history.setSelected([]) }.disabled(history.selected.isEmpty)
                Button("Hand off…", action: onHandOff).disabled(history.selected.isEmpty).buttonStyle(.borderedProminent)
            }
            if let error = history.error { Text(error).foregroundStyle(.red).font(.caption) }
        }
        .sheet(isPresented: $naming) {
            VStack(alignment: .leading, spacing: 16) {
                Text(editingID == nil ? "Save this selection" : "Update saved selection").font(.title2)
                Text(editingID == nil
                     ? "Return to these same items later. New recordings and search filters won’t change it."
                     : "Update the name and replace its saved items with your current selection. Existing handoff tasks keep their own inputs.")
                    .foregroundStyle(.secondary)
                TextField("Name", text: $name)
                HStack {
                    Button("Cancel") { naming = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save") {
                        history.saveSelection(name: name, id: editingID)
                        if history.error == nil { naming = false }
                    }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error = history.error { Text(error).foregroundStyle(.red).font(.caption) }
            }.padding(24).frame(width: 420)
        }
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
            if let suggest {
                Button("Suggest details with an assistant…") { dismiss(); suggest() }.buttonStyle(.link)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    library.setMetadata(TranscriptMetadata(purpose: purpose, person: person, company: company,
                        tags: tags.split(separator: ",").map { String($0) },
                        captureNotes: library.metadata(for: transcript.id).captureNotes), for: transcript.id)
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
    @State private var expanded: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Handoffs").font(.title2.weight(.semibold))
                Spacer()
                if jobs.isBusy { Button("Stop task", role: .destructive) { jobs.cancel() } }
            }
            if let notice = jobs.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if let error = jobs.error { Text(error).font(.caption).foregroundStyle(.red) }
            if jobs.jobs.isEmpty { Text("Your selected work and its results stay here.").foregroundStyle(.secondary) }
            ForEach(jobs.jobs) { job in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(job.title).font(.headline)
                        Spacer()
                        Text(job.status.title).font(.caption.weight(.medium))
                    }
                    Text("\(job.itemCount) items · \(job.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(job.detail).font(.callout)
                    HStack {
                        Button("Copy instructions") { jobs.copy(job) }
                        Button("Show selected files") { jobs.showInputs(job) }
                        if job.status == .completed {
                            Button(expanded == job.id ? "Hide result" : "Read result") { expanded = expanded == job.id ? nil : job.id }
                            Button("Open result") { jobs.showResult(job) }
                        }
                        if [.failed, .cancelled, .interrupted].contains(job.status) {
                            Menu("Retry…") {
                                ForEach(SubscriptionProvider.allCases) { provider in
                                    Button("Retry with \(provider.title)") { jobs.start(job, provider: provider, retry: true) }
                                        .disabled(jobs.isBusy || !jobs.canRun(job, with: provider))
                                }
                            }.fixedSize()
                        }
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
                    if expanded == job.id, let result = jobs.result(job) {
                        Text(result).textSelection(.enabled).font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Workbench.background)
                        if let applySuggestedMetadata, jobs.isMetadataSuggestion(job) {
                            Button("Review suggested details…") { applySuggestedMetadata(job, result) }
                        }
                    }
                }.padding(16).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 10))
            }
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
    var resolveSources: () throws -> [HandoffSourceSnapshot]
    var onConnections: () -> Void
    var onPrepared: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var task = ""
    @State private var sources: [HandoffSourceSnapshot] = []
    @State private var roles: [WorkbenchItemReference: HandoffInputRole] = [:]
    @State private var skillID = TranscriptHandoffSkill.followUp.id
    @State private var problem: String?
    @State private var evidenceURL: URL?
    @StateObject private var evidencePicker = TranscriptHandoffRunner()
    private var skill: TranscriptHandoffSkill { skills.first(where: { $0.id == skillID }) ?? .followUp }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hand off selected work").font(.title2.weight(.semibold))
            Text("\(sources.count) items. Each task keeps this selection, even when you pick different items later.")
                .foregroundStyle(.secondary)
            TextField("What should the assistant prepare?", text: $task, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
            Picker("Skill", selection: $skillID) { ForEach(skills) { Text($0.title).tag($0.id) } }
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
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
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
            }.frame(minHeight: 160, maxHeight: 330)
            Text("Meeting speech and images start as reference material. “My instructions” means you adopt that text as your request. Connected tasks send the reviewed material to the chosen provider and return a draft for review.")
                .font(.caption).foregroundStyle(.secondary)
            if skill.id != TranscriptHandoffSkill.followUp.id {
                Text("This skill uses the manual handoff so your assistant can create its requested files. Copy instructions, then attach the selected work folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if sources.contains(where: { !$0.images.isEmpty }) {
                Text("Image tasks use Codex. Workbench supports up to \(SubscriptionCLILimits.maximumImages) images, at most 10 MB each and 128 MB together. Edited Snaps share the visible crop and annotations; originals stay in Snap History. Claude Code is available for text tasks. Copy instructions keeps the complete selection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connections…") { dismiss(); onConnections() }
                Spacer()
                Button("Copy instructions") { submit(provider: nil) }.disabled(sources.isEmpty)
                Menu("Start task") {
                    ForEach(SubscriptionProvider.allCases) { provider in
                        Button("Start with \(provider.title)") { submit(provider: provider) }
                            .disabled(jobs.connections[provider]?.ready != true || !jobs.enabled(provider) || !supports(provider))
                    }
                }.disabled(sources.isEmpty || jobs.isBusy || skill.id != TranscriptHandoffSkill.followUp.id).menuStyle(.borderlessButton).fixedSize()
            }
        }.padding(24).frame(width: 680)
            .onAppear {
                task = initialTask ?? "Prepare the requested follow-up from my selected instructions and reference material. Identify any essential missing information."
                if let preferredSkillID, skills.contains(where: { $0.id == preferredSkillID }) { skillID = preferredSkillID }
                evidenceURL = initialEvidenceURL
                refreshSources()
                Task { await jobs.refresh() }
            }
    }
    private func submit(provider: SubscriptionProvider?) {
        do {
            var latest = try currentSources()
            guard latest == sources else {
                sources = latest; roles = [:]
                problem = "Selected content changed since this review opened. Check the refreshed items and roles, then try again."
                return
            }
            for index in latest.indices { latest[index].role = roles[latest[index].reference] ?? latest[index].role }
            let job = try jobs.prepare(sources: latest, task: task, skill: skill.load())
            if let provider { jobs.start(job, provider: provider, retry: [.failed, .cancelled, .interrupted].contains(job.status)) } else { jobs.copy(job) }
            if jobs.error == nil { onPrepared(); dismiss() } else { problem = jobs.error }
        } catch { problem = error.localizedDescription }
    }
    private func supports(_ provider: SubscriptionProvider) -> Bool {
        let images = sources.flatMap(\.images)
        if provider == .claude { return images.isEmpty }
        return images.count <= SubscriptionCLILimits.maximumImages
            && images.allSatisfy { $0.count <= SubscriptionCLILimits.maximumImageBytes }
            && images.reduce(0, { $0 + $1.count }) <= SubscriptionCLILimits.maximumTotalImageBytes
    }
    private func currentSources() throws -> [HandoffSourceSnapshot] {
        var result = try resolveSources()
        if let evidenceURL { result += try HandoffSessionEvidence.snapshots(at: evidenceURL) }
        return result
    }
    private func refreshSources() {
        do { sources = try currentSources(); roles = [:]; problem = nil }
        catch { problem = error.localizedDescription }
    }
    private func useEvidence(_ url: URL) {
        do {
            _ = try HandoffSessionEvidence.snapshots(at: url)
            evidenceURL = url; refreshSources()
        } catch { problem = error.localizedDescription }
    }
}
