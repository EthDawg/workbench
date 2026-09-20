import SwiftUI

struct SceneStarterGallery: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DemoScenes
    @State private var organizing = false
    @State private var renaming: String?
    @State private var newName = ""
    let choose: (SceneStarter) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Choose a starting point").font(.title2.weight(.semibold))
                    Text("A picture for your desktop, or the starting point for a presentation.").foregroundStyle(.secondary)
                }
                Spacer()
                Button(organizing ? "Done organising" : "Organise") { organizing.toggle() }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.starters.isEmpty {
                        Text("All starter backdrops are hidden. Restore defaults to bring them back.").foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        ForEach(model.starters) { starter in
                            VStack(spacing: 7) {
                                SceneStarterCard(starter: starter) { choose(starter) }
                                if organizing {
                                    HStack {
                                        Button { model.customizeStarter { $0.move(starter.id, by: -1) } } label: { Image(systemName: "arrow.up") }
                                            .disabled(model.starters.first?.id == starter.id).help("Move earlier")
                                            .accessibilityLabel("Move \(starter.name) earlier")
                                        Button { model.customizeStarter { $0.move(starter.id, by: 1) } } label: { Image(systemName: "arrow.down") }
                                            .disabled(model.starters.last?.id == starter.id).help("Move later")
                                            .accessibilityLabel("Move \(starter.name) later")
                                        Button("Rename") { renaming = starter.id; newName = starter.name }
                                        Spacer()
                                        Button { model.customizeStarter { $0.hidden.insert(starter.id) } } label: { Image(systemName: "eye.slash") }
                                            .help("Hide starter; saved customer scenes are kept")
                                            .accessibilityLabel("Hide \(starter.name)")
                                    }.font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                Text("Fictional settings made with AI · Available offline").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if organizing { Button("Restore defaults") { model.customizeStarter { $0 = StarterPreferences() } }.font(.caption) }
            }
        }.padding(24).frame(width: 680, height: 610)
            .background(Workbench.background).tint(Workbench.accent).workbenchTheme()
            .alert("Rename starter", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if let id = renaming, !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        model.customizeStarter { $0.names[id] = String(newName.prefix(160)) }
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
    }
}

private struct SceneStarterCard: View {
    let starter: SceneStarter
    let choose: () -> Void
    @State private var thumbnail: NSImage?
    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 0) {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary).aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay(Image(systemName: "photo"))
                }
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(starter.name).font(.subheadline.weight(.medium))
                        if starter.ambientPreset != nil { Label("Quiet motion", systemImage: "wind").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "plus.circle.fill").foregroundStyle(Workbench.accent)
                }.padding(12)
            }.background(Workbench.surface, in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.1)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(thumbnail == nil)
            .accessibilityLabel("Use \(starter.name)")
            .onAppear { if thumbnail == nil { thumbnail = starter.thumbnail() } }
    }
}
