import AppKit
import SwiftUI
import PrivatePackKit

struct PackShelfEntry: Identifiable {
    let id: String
    let name: String
    let kind: String
    var inputKinds: [PackInputKind] = []
    var symbol: String {
        switch kind {
        case "skill": return "sparkles"
        case "scene": return "rectangle.on.rectangle"
        case "personas": return "person.crop.rectangle"
        default: return "square.stack"
        }
    }
    var actionTitle: String {
        switch kind {
        case "skill": return "Use skill"
        case "scene": return "Add scene"
        case "personas": return "Add persona"
        default: return "Save resource…"
        }
    }
}

struct PackShelfItem: Identifiable {
    let id: String
    let name: String
    let version: String
    let repository: String
    let sourceURL: URL
    let entries: [PackShelfEntry]
    let logo: NSImage?
    var problem: String? = nil
}

struct PackLibraryView: View {
    @ObservedObject var model: PackLibraryModel
    var onUseEntry: (PackShelfItem, PackShelfEntry, PackInputKind?) -> Void
    var onRetrySavedResource: () -> Void
    @State private var source = ""
    @State private var removal: PackShelfItem?
    @State private var showingAdd = false
    @State private var showingAccount = false
    @State private var skillChoice: SkillChoice?
    private struct SkillChoice: Identifiable {
        let id = UUID()
        let pack: PackShelfItem
        let entry: PackShelfEntry
    }

    init(model: PackLibraryModel, showingAdd: Bool = false,
         onUseEntry: @escaping (PackShelfItem, PackShelfEntry, PackInputKind?) -> Void,
         onRetrySavedResource: @escaping () -> Void) {
        self.model = model; self.onUseEntry = onUseEntry; self.onRetrySavedResource = onRetrySavedResource
        self._showingAdd = State(initialValue: showingAdd)
    }

    var body: some View {
        Group {
            if model.packs.isEmpty && !showingAdd {
                // An empty Packs centres its one empty state in the page, as Resources does, so
                // switching between the two tabs moves neither the summary nor the empty state.
                // It scrolls only when open Pack settings no longer fit.
                ViewThatFits(in: .vertical) {
                    page(centred: true)
                    ScrollView { page(centred: false) }
                }
            } else {
                ScrollView { page(centred: false) }
            }
        }
        .onAppear {
            acceptPendingSource()
            model.refreshInstalled()
        }
        .onChange(of: model.pendingSource) { _, value in
            if value != nil { acceptPendingSource() }
        }
        .onChange(of: model.connecting) { _, value in
            if value && !showingAdd { showingAccount = true }
        }
        .confirmationDialog("Use \(skillChoice?.entry.name ?? "this skill") with…", isPresented: Binding(
            get: { skillChoice != nil }, set: { if !$0 { skillChoice = nil } }), titleVisibility: .visible) {
            Button("Use with transcripts") { chooseSkill(.transcripts) }
            Button("Use with Snap & Talk") { chooseSkill(.snapAndTalk) }
            Button("Cancel", role: .cancel) { skillChoice = nil }
        } message: {
            Text("Prepare the chosen tool. Nothing is captured, submitted or started automatically.")
        }
        .confirmationDialog("Remove \(removal?.name ?? "this pack") from Workbench?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("Remove pack", role: .destructive) {
                if let removal { model.remove(removal.id) }
                removal = nil
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text("Its updates stop. Sessions, imported scenes and personas remain in your own work.")
        }
    }

    /// The action row, then the packs or the one empty state, then Pack settings, at the page's full
    /// width as Resources has it.
    private func page(centred: Bool) -> some View {
        VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
            // Library's header carries this section's summary (WorkbenchHome.sectionSummaries),
            // so its one action sits at the trailing edge.
            HStack(alignment: .firstTextBaseline) {
                Spacer()
                if !model.packs.isEmpty && !showingAdd {
                    Button("Add a pack…") { showingAdd = true }
                }
            // Resources' action row is 26 points high (its Saved Prompts… and Add), so this one is
            // too: the content keeps its place when the tab changes.
            }.frame(minHeight: 26)
            if model.noticePackID == nil || !model.packs.contains(where: { $0.id == model.noticePackID }) { feedback }
            if let saved = model.savedResource {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Saved file: \(saved.url.lastPathComponent)").fontWeight(.medium)
                    Text("The file is kept. Retry reviews the current Library and adds only this file's verified reference; it does not export another copy.")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Saved file details") { Text(saved.url.path).font(.caption).textSelection(.enabled) }
                    HStack {
                        Button("Add saved file to Library") { onRetrySavedResource() }
                        Button("Show saved file") { NSWorkspace.shared.activateFileViewerSelecting([saved.url]) }
                        Button("Keep file only") { model.keepSavedFileOnly() }
                    }
                }.workbenchCard()
            }
            if model.packs.isEmpty {
                if !showingAdd {
                    WorkbenchEmptyState(symbol: "shippingbox", title: "Add reusable content when you need it",
                        detail: "Packs bring shared skills, scenes, personas and resources. Your ordinary Workbench tools are ready to use without one.") {
                        Button("Add a pack…") { showingAdd = true }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: 520, alignment: .leading).frame(maxWidth: .infinity, maxHeight: centred ? .infinity : nil)
                        // Centred, it starts below the space Resources gives its search row (a
                        // 22-point field and 16 points), so both empty states sit at one height.
                        .padding(.top, 38).padding(.bottom, centred ? 0 : 38)
                }
            } else {
                ForEach(model.packs) { pack in packCard(pack) }
            }
            if showingAdd { addSource }
            if model.isBusy && (model.operationPackID == nil || !model.packs.contains(where: { $0.id == model.operationPackID })) { progress }
            DisclosureGroup("Pack settings", isExpanded: $showingAccount) {
                if !showingAdd || model.login != nil { connection }
                Toggle("Keep packs up to date automatically", isOn: $model.automaticUpdates)
                Text("Updates apply to shared starters. Existing sessions and personal copies keep their own content.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(Workbench.pagePadding).frame(maxWidth: .infinity, maxHeight: centred ? .infinity : nil, alignment: .topLeading)
    }

    private func acceptPendingSource() {
        guard let pending = model.pendingSource else { return }
        source = pending; showingAdd = true; model.pendingSource = nil
    }
    private func chooseSkill(_ input: PackInputKind) {
        guard let choice = skillChoice else { return }
        skillChoice = nil; onUseEntry(choice.pack, choice.entry, input)
    }
    @ViewBuilder private var feedback: some View {
        if let message = model.notice {
            WorkbenchNote(message, tone: model.hasError ? .attention : .neutral,
                          symbol: model.hasError ? nil : "checkmark.circle").accessibilityLabel(message)
        }
    }
    private var progress: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(model.activity).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { model.cancel() }.buttonStyle(.borderless)
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield").font(.title2).foregroundStyle(Workbench.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.login.map { "Connected as \($0)" } ?? "Connect GitHub").font(.headline)
                    Text("Read access to the repositories you and Workbench are both allowed to use.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.login != nil {
                    Button("Reconnect") { model.connect() }.disabled(model.isBusy)
                    Button("Disconnect") { model.disconnect() }.disabled(model.isBusy)
                } else {
                    Button("Connect GitHub") { model.connect() }.buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                }
            }
            if let code = model.deviceCode {
                Divider()
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Enter this code on GitHub").font(.callout)
                        Text(code).font(.system(size: 25, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled).accessibilityLabel("GitHub verification code: \(code)")
                    }
                    Spacer()
                    Button("Copy code and open GitHub") { model.openDeviceLogin(copyCode: true) }
                    Button("Cancel") { model.cancel() }
                }
            }
        }.workbenchCard()
    }

    private var addSource: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Add a pack").font(.headline)
                Spacer()
                Button("Done") { showingAdd = false }.disabled(model.connecting)
            }
            HStack(spacing: 10) {
                TextField("https://github.com/team/pack", text: $source)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Pack repository link")
                    .onSubmit { addPack() }
                Button("Add pack") { addPack() }
                    .disabled(model.isBusy || model.login == nil || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if model.login == nil {
                Text("Connect GitHub to add this repository. Installed content works without a connection.")
                    .font(.caption).foregroundStyle(.secondary)
                connection
            }
            HStack {
                Text("Your account and Workbench Packs both need access to the repository.")
                    .foregroundStyle(.secondary)
                Button("Pack owner setup") { NSWorkspace.shared.open(URL(string: "https://github.com/apps/workbench-packs")!) }
                    .buttonStyle(.workbenchLink)
            }.font(.caption)
        }.workbenchCard()
    }

    private func addPack() {
        guard !model.isBusy, model.login != nil else { return }
        model.install(source)
    }

    private func packCard(_ pack: PackShelfItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                if let logo = pack.logo {
                    Image(nsImage: logo).resizable().scaledToFit().frame(width: 72, height: 36)
                        .padding(10).background(Color(red: 0.02, green: 0.14, blue: 0.19), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(pack.name).font(.title3.weight(.semibold))
                    HStack(spacing: 8) {
                        Text("Version \(pack.version)")
                        Button(pack.repository) { NSWorkspace.shared.open(pack.sourceURL) }.buttonStyle(.workbenchLink)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Check for updates") { model.update(pack.id) }.disabled(model.isBusy)
                    Button("Open source and contribute") { NSWorkspace.shared.open(pack.sourceURL) }
                    Button("Remove pack…", role: .destructive) { removal = pack }.disabled(model.isBusy)
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(pack.name)")
            }
            Divider()
            if let problem = pack.problem { WorkbenchNote(problem) }
            if model.operationPackID == pack.id { progress }
            if model.noticePackID == pack.id { feedback }
            ForEach(pack.entries) { entry in entryRow(entry, pack: pack) }
            DisclosureGroup("Workspace appearance") { HStack {
                if model.brandPackID == pack.id {
                    Label("Workspace appearance", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    Button("Reset") { model.setBrand(nil) }.buttonStyle(.workbenchLink).font(.caption)
                } else {
                    Button("Use workspace appearance") { model.setBrand(pack.id) }.buttonStyle(.workbenchLink).font(.caption)
                }
            } }
        }.workbenchCard()
    }

    private func entryRow(_ entry: PackShelfEntry, pack: PackShelfItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.symbol).frame(width: 22).foregroundStyle(Workbench.accent)
            Text(entry.name)
            Spacer()
            Button(entry.actionTitle) {
                if entry.kind == "skill", entry.inputKinds.count > 1 { skillChoice = SkillChoice(pack: pack, entry: entry) }
                else { onUseEntry(pack, entry, entry.inputKinds.first) }
            }
        }
    }
}
