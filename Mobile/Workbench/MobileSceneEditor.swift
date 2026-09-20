import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

enum MobileSceneImageLayer { case background, logo, persona }

/// Root navigation can keep a quick action pending while any active editor has
/// unsaved work. Session IDs avoid one window clearing another window's guard.
@MainActor final class SceneEditingActivity: ObservableObject {
    static let shared = SceneEditingActivity()
    @Published private(set) var hasUnsavedEdits = false
    private var dirtySessions = Set<UUID>()
    func update(sessionID: UUID, isDirty: Bool) {
        if isDirty { dirtySessions.insert(sessionID) } else { dirtySessions.remove(sessionID) }
        let dirty = !dirtySessions.isEmpty
        if hasUnsavedEdits != dirty { hasUnsavedEdits = dirty }
    }
}

/// The editor owns its draft. Receipts can refresh its sync state, but another
/// device's authored revision cannot replace pending local edits.
@MainActor final class MobileSceneEditingSession: ObservableObject {
    @Published private(set) var record: SavedSceneRecord? { didSet { refreshActivity() } }
    @Published private(set) var draft: PortableScene? { didSet { refreshActivity() } }
    @Published private(set) var changedElsewhere = false
    @Published var notice: String?
    var activeID: UUID? { record?.id }
    var hasUnsavedChanges: Bool { draft != nil && draft != record?.scene }
    private var library: SceneLibraryModel?
    private var pending: Task<Void, Never>?
    private var generation = UUID()
    private var committing = false
    private let activityID = UUID()
    private var isActive = false
    private let waitToSave: @MainActor () async throws -> Void

    init(waitToSave: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(450)) }) {
        self.waitToSave = waitToSave
    }
    func connect(library: SceneLibraryModel, sceneID: UUID) {
        isActive = true; refreshActivity()
        guard self.library == nil else { observe(library.records); return }
        self.library = library
        guard let record = library.records.first(where: { $0.id == sceneID && !$0.isDeleted }) else {
            notice = "This scene is no longer available. Original pictures are kept."; return
        }
        adopt(record)
    }
    private func adopt(_ value: SavedSceneRecord) {
        cancelPending(); record = value; draft = value.scene; changedElsewhere = false; notice = nil
    }
    func observe(_ values: [SavedSceneRecord]) {
        guard !committing, let current = record else { return }
        guard let latest = values.first(where: { $0.id == current.id && !$0.isDeleted }) else {
            cancelPending(); changedElsewhere = true
            notice = "This scene was deleted elsewhere. You can keep your version as a copy."; return
        }
        if latest.revision == current.revision {
            record = latest // Acknowledgement-only fields; preserve a pending draft.
        } else if !hasUnsavedChanges {
            adopt(latest)
        } else {
            cancelPending(); changedElsewhere = true
            notice = "This scene changed elsewhere. Your edits are kept here until you choose which version to use."
        }
    }
    func edit(_ change: (inout PortableScene) -> Void) {
        guard var next = draft else { return }
        change(&next); next.name = String(next.name.prefix(160)); draft = next
        cancelPending()
        guard hasUnsavedChanges, !changedElsewhere else { return }
        let token = generation
        pending = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await waitToSave(); try Task.checkCancellation() }
            catch { return }
            guard token == generation else { return }
            _ = flush()
        }
    }
    func replaceImage(asset: String, layer: MobileSceneImageLayer) {
        edit { scene in
            switch layer {
            case .background:
                scene.background = asset; scene.backgroundX = 0.5; scene.backgroundY = 0.5; scene.zoom = 1
                scene.ambience = nil; scene.gentleMotion = nil
            case .logo:
                var layer = scene.logo ?? SceneLogoLayer(image: asset); layer.image = asset; scene.logo = layer
            case .persona:
                var layer = scene.persona ?? ScenePersonaLayer(image: asset)
                layer.image = asset; layer.card = nil // The replacement no longer depicts the old authored portrait/card.
                scene.persona = layer
            }
        }
    }
    @discardableResult func flush() -> Bool {
        cancelPending()
        guard let draft, let record, let library, hasUnsavedChanges else { return true }
        guard !changedElsewhere else { return false }
        committing = true; defer { committing = false }
        do {
            self.record = try library.save(draft, expectedRevision: record.revision)
            changedElsewhere = false; notice = nil; return true
        } catch {
            notice = error.localizedDescription
            if error as? SceneDocumentError == .concurrentChange { changedElsewhere = true }
            return false
        }
    }
    @discardableResult func keepCopy() -> Bool {
        cancelPending(); guard var draft, let library else { return false }
        draft.id = UUID(); draft.name = String(draft.name.prefix(140)) + " · kept copy"
        committing = true; defer { committing = false }
        do {
            let saved = try library.create(draft); adopt(saved)
            notice = "Your version is saved as a separate scene."; return true
        } catch { notice = error.localizedDescription; return false }
    }
    /// Called only after the user explicitly chooses to discard pending edits.
    func reloadDiscardingEdits() {
        guard let id = activeID, let latest = library?.records.first(where: { $0.id == id && !$0.isDeleted }) else {
            notice = "This scene is no longer available. Keep your version as a copy to continue."; return
        }
        adopt(latest)
    }
    /// An external navigation/quick action may remove the editor. Preserve a
    /// conflicted pending draft as a copy rather than silently dropping it.
    func finishForDisappearance() {
        defer { isActive = false; refreshActivity() }
        guard hasUnsavedChanges else { cancelPending(); return }
        if !flush() { _ = keepCopy() }
    }
    private func refreshActivity() { SceneEditingActivity.shared.update(sessionID: activityID, isDirty: isActive && hasUnsavedChanges) }
    deinit {
        let id = activityID
        Task { @MainActor in SceneEditingActivity.shared.update(sessionID: id, isDirty: false) }
    }
    func cancelPending() { generation = UUID(); pending?.cancel(); pending = nil }
    func waitForPendingSave() async { await pending?.value }
}

struct MobileSceneEditor: View {
    let sceneID: UUID
    @EnvironmentObject private var scenes: SceneLibraryModel
    @EnvironmentObject private var store: MobileStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPlayAnimatedImages) private var animatedImagesEnabled
    @StateObject private var editor = MobileSceneEditingSession()
    @State private var selection: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var target = MobileSceneImageLayer.background
    @State private var photoTask: Task<Void, Never>?
    @State private var share: SceneFileShare?
    @State private var exportedURL: URL?
    @State private var photoGeneration = UUID()
    @State private var cloudSettings = false
    @State private var busy = false
    @State private var deleting = false
    @State private var reloading = false
    @State private var recovered: MobileImageProject?
    @State private var recovering = false
    @State private var personaCard: ScenePersonaCardRequest?
    @State private var previewPaused = false
    @State private var previewVisible = false
    @State private var editingCrop = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var thermalState = ProcessInfo.processInfo.thermalState

    var body: some View {
        ScrollView { editorContent.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity) }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Edit scene").navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true).toolbar(.hidden, for: .tabBar)
            .toolbar { editorToolbar }
            .onAppear { editor.connect(library: scenes, sceneID: sceneID); refreshMotionConditions() }
            .onReceive(scenes.$records) { editor.observe($0) }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in refreshMotionConditions() }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification).receive(on: RunLoop.main)) { _ in refreshMotionConditions() }
            .onDisappear { photoGeneration = UUID(); photoTask?.cancel(); busy = false; editor.finishForDisappearance() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { _ = editor.flush() } else { refreshMotionConditions() }
            }
            .photosPicker(isPresented: $choosingPhoto, selection: $selection, matching: .images, preferredItemEncoding: .current)
            .onChange(of: selection) { _, item in if let item { openPhoto(item) } }
            .sheet(item: $share, onDismiss: removeExport) { item in MobileImageShareSheet(url: item.url) }
            .sheet(isPresented: $cloudSettings) { MobileSceneSyncSettings() }
            .sheet(item: $personaCard) { request in
                MobilePersonaCardSheet(existing: request.existing, choosingStarter: request.choosingStarter) { layer in
                    guard editor.activeID == request.sceneID, editor.record?.revision == request.revision else {
                        throw SceneDocumentError.invalid("This scene changed while the card was open. Your card is still here; cancel and reopen the editor before applying it to the new version.")
                    }
                    editor.edit { $0.persona = layer }
                    guard editor.flush() else { throw SceneDocumentError.invalid(editor.notice ?? "The card could not be saved. Your edits are kept here.") }
                }
            }
            .navigationDestination(isPresented: $recovering) {
                if let recovered { MobileImageWorkspace(kind: recovered.kind, projectID: recovered.id) }
            }
            .confirmationDialog("Delete this saved scene?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete scene", role: .destructive) { delete() }
            } message: { Text("The deletion will sync if enabled. Original picture files are retained.") }
            .confirmationDialog("Discard your unsaved edits?", isPresented: $reloading, titleVisibility: .visible) {
                Button("Reload saved scene", role: .destructive) { editor.reloadDiscardingEdits() }
            } message: { Text("You can keep your version as a copy instead.") }
    }
    @ViewBuilder private var editorContent: some View {
        if let draft = editor.draft {
            VStack(alignment: .leading, spacing: 22) {
                SceneThumbnail(scene: draft, store: scenes, motionPlaying: motionPlayback.isPlaying).aspectRatio(16.0 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .onScrollVisibilityChange(threshold: 0.05) { previewVisible = $0 }
                    .onDisappear { previewVisible = false }
                Text(draft.showsPhone ? "The device frame marks the live screen on your Mac."
                     : "Turn on Device frame to prepare a device presentation.").font(.footnote).foregroundStyle(.secondary)
                nameSection
                Button("Replace backdrop", systemImage: "photo") { choose(.background) }.buttonStyle(.bordered).disabled(busy)
                motionSection
                deviceSection
                cropSection
                layerSection
                if draft.legacyMobileProject != nil { recoverySection }
                editorStatus
            }
        } else {
            ContentUnavailableView("Scene unavailable", systemImage: "photo", description: Text(editor.notice ?? "Return to Scenes to choose another."))
        }
    }
    private func refreshMotionConditions() {
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled; thermalState = ProcessInfo.processInfo.thermalState
    }
    private var motionPlayback: SceneMotionPlayback {
        SceneMotionPlayback(requested: editor.draft?.gentleMotion == true, paused: previewPaused,
            editingCrop: editingCrop, visible: previewVisible && !busy && !choosingPhoto && share == nil && !cloudSettings && personaCard == nil && !recovering,
            active: scenePhase == .active, reduceMotion: reduceMotion, animatedImagesEnabled: animatedImagesEnabled, lowPower: lowPower, thermalState: thermalState)
    }
    private var motionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Gentle motion", isOn: Binding(get: { editor.draft?.gentleMotion == true }, set: { enabled in
                editor.edit { $0.gentleMotion = enabled ? true : nil }; previewPaused = false
            })).accessibilityIdentifier("scene.gentleMotion")
            if editor.draft?.gentleMotion == true {
                Button(previewPaused ? "Play preview" : "Pause preview", systemImage: previewPaused ? "play.fill" : "pause.fill") {
                    previewPaused.toggle()
                }.buttonStyle(.bordered).frame(minHeight: 44).accessibilityIdentifier("scene.motionPlayback")
                Text(motionPlayback.isPlaying && editor.draft?.ambience != nil
                     ? "Clouds or leaves move gently. Your device, logo and persona stay still."
                     : motionPlayback.explanation).font(.footnote).foregroundStyle(.secondary)
            } else {
                Text(editor.draft?.ambience == nil ? "A slow, subtle zoom when you present this scene."
                     : "Clouds or leaves move gently. The rest of your scene stays still.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 16))
    }
    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scene name").font(.caption).foregroundStyle(.secondary)
            TextField("Scene name", text: field(\.name, fallback: "Untitled scene"))
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("scene.name")
                .submitLabel(.done).onSubmit { _ = editor.flush() }
        }
    }
    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Device frame", isOn: field(\.showsPhone, fallback: true))
            if editor.draft?.showsPhone == true {
                Text("Device position").font(.subheadline)
                HStack { position("Left", value: 0.08); position("Centre", value: 0.5); position("Right", value: 0.92) }
                devicePicker
                LabeledContent("Size") {
                    Slider(value: field(\.phoneHeight, fallback: 0.88), in: 0.3...1)
                        .accessibilityLabel("Device size").accessibilityValue("\(Int((editor.draft?.phoneHeight ?? 0.88) * 100)) percent")
                }
            }
        }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 16))
    }
    private var devicePicker: some View {
        Picker("Device", selection: Binding(get: { editor.draft?.viewport?.aspect ?? 9.0 / 19.5 }, set: { value in
            editor.edit { $0.viewport = SceneDevice(aspect: value, border: value < 0.6 ? 0.009 : 0.012, corners: value < 0.6 ? 0.1 : 0.035) }
        })) {
            Text("Phone").tag(9.0 / 19.5); Text("Tablet").tag(0.75); Text("Landscape").tag(4.0 / 3.0)
            if let aspect = editor.draft?.viewport?.aspect, ![9.0 / 19.5, 0.75, 4.0 / 3.0].contains(aspect) { Text("Saved proportions").tag(aspect) }
        }
    }
    private var cropSection: some View {
        DisclosureGroup("Crop backdrop", isExpanded: $editingCrop) {
            VStack(spacing: 14) {
                LabeledContent("Horizontal") { Slider(value: field(\.backgroundX, fallback: 0.5), in: 0...1).accessibilityLabel("Backdrop horizontal position") }
                LabeledContent("Vertical") { Slider(value: field(\.backgroundY, fallback: 0.5), in: 0...1).accessibilityLabel("Backdrop vertical position") }
                LabeledContent("Zoom") { Slider(value: field(\.zoom, fallback: 1), in: 1...3).accessibilityLabel("Backdrop zoom") }
            }.padding(.top, 12)
        }
    }
    private var layerSection: some View {
        HStack {
            Menu {
                Button(editor.draft?.logo == nil ? "Choose logo" : "Replace logo") { choose(.logo) }
                if editor.draft?.logo != nil { Button("Remove from this scene", role: .destructive) { editor.edit { $0.logo = nil } } }
            } label: { Label(editor.draft?.logo == nil ? "Add logo" : "Logo", systemImage: "seal") }
            Spacer()
            Menu {
                Button("Choose a starter portrait…") { openPersonaCard(choosingStarter: true) }
                if editor.draft?.persona?.card != nil { Button("Edit label and colour…") { openPersonaCard(choosingStarter: false) } }
                Button(editor.draft?.persona == nil ? "Choose persona image" : "Replace persona image") { choose(.persona) }
                if editor.draft?.persona != nil { Button("Remove from this scene", role: .destructive) { editor.edit { $0.persona = nil } } }
            } label: { Label(editor.draft?.persona == nil ? "Add persona" : "Persona", systemImage: "person.crop.circle") }
        }.buttonStyle(.bordered).disabled(busy)
    }
    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Recover mobile original", systemImage: "arrow.uturn.backward") { recoverOriginal() }.buttonStyle(.bordered).disabled(busy)
            Text("The original picture, caption and drawing are kept in a separate editable copy. Your scene may look different.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func recoverOriginal() {
        guard editor.flush(), let draft = editor.draft else { return }
        do { recovered = try MobileSceneImport.recover(scene: draft, store: store, scenes: scenes); recovering = true }
        catch { editor.notice = error.localizedDescription }
    }
    private var editorStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editor.draft?.hand != nil {
                Text("This scene includes a hand cutout. Its saved placement is kept; preview the full composition on Mac.").font(.footnote).foregroundStyle(.secondary)
            }
            if editor.hasUnsavedChanges { Text("Unsaved edits").font(.footnote).foregroundStyle(.secondary) }
            else if let record = editor.record { Text(sceneStatus(record)).font(.footnote).foregroundStyle(.secondary) }
            if busy { ProgressView("Opening picture…") }
            if let notice = editor.notice { Text(notice).foregroundStyle(.secondary).accessibilityIdentifier("scene.editorNotice") }
            if editor.changedElsewhere || (editor.hasUnsavedChanges && editor.notice != nil) {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Keep my version as a copy") { _ = editor.keepCopy() }
                    Button("Reload saved scene") { reloading = true }
                }.buttonStyle(.bordered)
            }
        }
    }
    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { Button("Done") { if editor.flush() { dismiss() } }.disabled(busy) }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Sync settings", systemImage: "icloud") { if editor.flush() { cloudSettings = true } }
                Button("Share editable scene", systemImage: "square.and.arrow.up") { export() }.disabled(editor.draft == nil || busy)
                Button("Delete scene", systemImage: "trash", role: .destructive) { if editor.flush() { deleting = true } }.disabled(editor.record == nil || busy)
            } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Scene actions")
        }
    }
    private func field<Value>(_ key: WritableKeyPath<PortableScene, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { editor.draft?[keyPath: key] ?? fallback }, set: { value in editor.edit { $0[keyPath: key] = value } })
    }
    private func position(_ title: String, value: Double) -> some View {
        let selected = abs((editor.draft?.phoneX ?? 0.5) - value) < 0.02
        return Button { editor.edit { $0.phoneX = value } } label: { Text(title).frame(maxWidth: .infinity).fontWeight(selected ? .semibold : .regular) }
            .buttonStyle(.bordered).tint(selected ? Color.accentColor : .secondary)
            .accessibilityLabel("Device position: \(title)").accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func openPersonaCard(choosingStarter: Bool) {
        guard editor.flush(), let record = editor.record else { return }
        personaCard = ScenePersonaCardRequest(sceneID: record.id, revision: record.revision,
            existing: editor.draft?.persona, choosingStarter: choosingStarter)
    }
    private func choose(_ value: MobileSceneImageLayer) {
        guard editor.flush() else { return }; target = value; choosingPhoto = true
    }
    private func openPhoto(_ item: PhotosPickerItem) {
        photoTask?.cancel(); busy = true
        let token = UUID(); photoGeneration = token
        let destination = target, revision = editor.record?.revision
        photoTask = Task { @MainActor in
            defer { if photoGeneration == token { busy = false; selection = nil } }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw PhotoHandoffInputError.unreadable }
                try Task.checkCancellation()
                guard photoGeneration == token else { return }
                guard editor.record?.revision == revision else { editor.notice = "This scene changed while the picture was opening. Choose the picture again to apply it to this version."; return }
                let name = try scenes.importAsset(data); editor.replaceImage(asset: name, layer: destination); _ = editor.flush()
            } catch is CancellationError { }
            catch { editor.notice = error.localizedDescription }
        }
    }
    private func delete() {
        guard let record = editor.record else { return }
        do { try scenes.delete(id: record.id, expectedRevision: record.revision); dismiss() }
        catch { editor.notice = error.localizedDescription }
    }
    private func export() {
        guard editor.flush(), let draft = editor.draft else { return }
        do {
            let bytes = try scenes.package(for: draft).encoded()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Scene-\(UUID().uuidString).workbenchscene")
            try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            removeExport(); exportedURL = url; share = SceneFileShare(url: url)
        } catch { editor.notice = error.localizedDescription }
    }
    private func removeExport() { if let exportedURL { try? FileManager.default.removeItem(at: exportedURL) }; exportedURL = nil; share = nil }
}
private struct SceneFileShare: Identifiable { let id = UUID(); let url: URL }

private struct ScenePersonaCardRequest: Identifiable {
    let id = UUID()
    let sceneID: UUID
    let revision: UUID
    let existing: ScenePersonaLayer?
    let choosingStarter: Bool
}
