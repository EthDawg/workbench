import AppKit
import SwiftUI

struct PackShelfEntry: Identifiable {
    let id: String
    let name: String
    let kind: String
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
}

struct PackLibraryView: View {
    @ObservedObject var model: PackLibraryModel
    var onUseEntry: (PackShelfItem, PackShelfEntry) -> Void
    @State private var source = ""
    @State private var removal: PackShelfItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Packs").font(.system(size: 32, weight: .semibold))
                    Text("Your team’s skills, scenes and personas, ready to use.")
                        .foregroundStyle(.secondary)
                }
                connection
                addSource
                if let message = model.notice {
                    Label(message, systemImage: model.hasError ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.callout).foregroundStyle(model.hasError ? Color.orange : Color.secondary)
                        .textSelection(.enabled)
                        .accessibilityLabel(message)
                }
                if model.isBusy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.activity).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { model.cancel() }.buttonStyle(.borderless)
                    }
                }
                if model.packs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "shippingbox").font(.system(size: 34)).foregroundStyle(Workbench.accent)
                        Text("Start with a pack link").font(.title3.weight(.semibold))
                        Text("Paste the private repository link your team shared. Sign in with a GitHub account that has access, then add the pack.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 450)
                        Text("Your ordinary Workbench tools are ready to use without a pack.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 38)
                } else {
                    ForEach(model.packs) { pack in packCard(pack) }
                    Toggle("Keep packs up to date automatically", isOn: $model.automaticUpdates)
                    Text("Updates apply to shared starters. Existing sessions and personal copies keep their own content.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(32).frame(maxWidth: 920, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            if let pending = model.pendingSource { source = pending; model.pendingSource = nil }
            model.refreshInstalled()
        }
        .onChange(of: model.pendingSource) { _, value in
            if let value { source = value; model.pendingSource = nil }
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
            Text("Add a pack").font(.headline)
            HStack(spacing: 10) {
                TextField("https://github.com/team/pack", text: $source)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Pack repository link")
                    .onSubmit { addPack() }
                Button("Add pack") { addPack() }
                    .disabled(model.isBusy || model.login == nil || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if model.login == nil {
                Text("Connect GitHub first to add your team’s pack.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Your account and Workbench Packs both need access to the repository.")
                    .foregroundStyle(.secondary)
                Link("Pack owner setup", destination: URL(string: "https://github.com/apps/workbench-packs")!)
            }.font(.caption)
        }
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
            ForEach(pack.entries) { entry in
                HStack(spacing: 12) {
                    Image(systemName: entry.symbol).frame(width: 22).foregroundStyle(Workbench.accent)
                    Text(entry.name)
                    Spacer()
                    Button(entry.actionTitle) { onUseEntry(pack, entry) }.disabled(model.isBusy)
                }
            }
            HStack {
                if model.brandPackID == pack.id {
                    Label("Workspace appearance", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    Button("Reset") { model.setBrand(nil) }.buttonStyle(.link).font(.caption)
                } else {
                    Button("Use workspace appearance") { model.setBrand(pack.id) }.buttonStyle(.link).font(.caption)
                }
            }
        }.padding(22).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}
