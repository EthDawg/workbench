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
        ScrollView {
            VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
                // Library's title and switcher name this section, so it opens on its summary (#134).
                HStack(alignment: .firstTextBaseline) {
                    Text("Reusable skills, scenes, personas and resources.").foregroundStyle(.secondary)
                    Spacer()
                    if !model.packs.isEmpty && !showingAdd {
                        Button("Add a pack…") { showingAdd = true }
                    }
                }
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
                    }.padding(16).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                if model.packs.isEmpty {
                    if !showingAdd { VStack(spacing: 12) {
                        Image(systemName: "shippingbox").font(.system(size: 34)).foregroundStyle(Workbench.accent)
                        Text("Add reusable content when you need it.").font(.title3.weight(.semibold))
                        Text("Your ordinary Workbench tools are ready to use without a pack.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Add a pack…") { showingAdd = true }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity).padding(.vertical, 38) }
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
            }.padding(Workbench.pagePadding).frame(maxWidth: 920, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
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
            Label(message, systemImage: model.hasError ? "exclamationmark.circle" : "checkmark.circle")
                .font(.callout).foregroundStyle(model.hasError ? Color.orange : Color.secondary)
                .textSelection(.enabled).accessibilityLabel(message)
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
        }.padding(20).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 14))
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
                Link("Pack owner setup", destination: URL(string: "https://github.com/apps/workbench-packs")!)
            }.font(.caption)
        }.padding(18).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 12))
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
                        Link(pack.repository, destination: pack.sourceURL)
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
            if let problem = pack.problem { Text(problem).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if model.operationPackID == pack.id { progress }
            if model.noticePackID == pack.id { feedback }
            ForEach(pack.entries) { entry in entryRow(entry, pack: pack) }
            DisclosureGroup("Workspace appearance") { HStack {
                if model.brandPackID == pack.id {
                    Label("Workspace appearance", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    Button("Reset") { model.setBrand(nil) }.buttonStyle(.link).font(.caption)
                } else {
                    Button("Use workspace appearance") { model.setBrand(pack.id) }.buttonStyle(.link).font(.caption)
                }
            } }
        }.padding(22).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 14))
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
