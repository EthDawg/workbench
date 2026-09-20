import AppKit
import Combine
import SwiftUI
import SceneSyncKit
import PhotoHandoffKit

/// The native scene remains a rendering/editing value. This adapter owns no
/// second manifest: every successful edit goes through the portable library.
@MainActor final class MacSceneSync: ObservableObject {
    let library: SceneLibraryModel
    let root: URL
    @Published private(set) var scenes: [DemoScene] = []
    @Published private(set) var migrationNotice: String?
    @Published private(set) var isBlocked = false
    private(set) var recoveryIDs = Set<UUID>()
    var onChange: (() -> Void)?
    private var recovery: [DemoScene] = []
    private(set) var unavailableAssetIDs = Set<UUID>()
    private var nativeCache: [UUID: (revision: UUID, scene: DemoScene)] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var importing = false
    private let legacyURL: URL

    init(root: URL, systemIntegrationEnabled: Bool, library: SceneLibraryModel? = nil) {
        self.root = root; legacyURL = root.appendingPathComponent("scenes.json")
        let directory = root.appendingPathComponent("Portable", isDirectory: true)
        let configuration: SceneCloudConfiguration
        if systemIntegrationEnabled {
            let verified = PhotoCloudConfiguration.current()
            configuration = SceneCloudConfiguration(container: verified.container,
                environment: verified.environment, isProvisioned: verified.isConfigured)
        } else { configuration = .unavailable }
        self.library = library ?? SceneLibraryModel(directory: directory, configuration: configuration)
        isBlocked = self.library.isStorageBlocked
        migratePreviousScenes()
        self.library.$records.dropFirst().sink { [weak self] records in
            guard let self, !self.importing else { return }
            self.publish(records)
        }.store(in: &subscriptions)
        self.library.$error.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            self.isBlocked = self.isBlocked || self.library.isStorageBlocked; self.onChange?()
        }.store(in: &subscriptions)
        if systemIntegrationEnabled {
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in Task { @MainActor in await self?.library.refresh() } }
                .store(in: &subscriptions)
        }
    }

    /// Existing filenames are a compatibility cache for the native renderer.
    /// Their bytes remain immutable; the portable Assets directory is authoritative.
    static func materializedName(_ asset: String) -> String {
        "scene-asset-" + asset.dropLast(".image".count) + ".png"
    }
    private func materialize(_ package: ScenePackage) throws {
        _ = try package.validated()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (asset, bytes) in package.assets {
            let target = root.appendingPathComponent(Self.materializedName(asset))
            if let existing = try PersonaStorage.read(target, maximumBytes: SceneAsset.maximumBytes) {
                guard existing == bytes else { throw SceneDocumentError.concurrentChange }
            } else {
                let staged = root.appendingPathComponent(".scene-cache-" + UUID().uuidString)
                try bytes.write(to: staged, options: .atomic)
                defer { try? FileManager.default.removeItem(at: staged) }
                // A hard link installs complete bytes without replacing a file
                // that another process created after the initial existence check.
                do { try FileManager.default.linkItem(at: staged, to: target) }
                catch {
                    guard try PersonaStorage.read(target, maximumBytes: SceneAsset.maximumBytes) == bytes else { throw error }
                }
            }
        }
    }
    func native(_ record: SavedSceneRecord) throws -> DemoScene {
        let package = try library.package(for: record.scene); try materialize(package)
        return try nativeDocument(record)
    }
    private func nativeDocument(_ record: SavedSceneRecord) throws -> DemoScene {
        var object = try Self.object(record.scene)
        Self.rewriteImages(&object) { Self.materializedName($0) }
        var scene = try JSONDecoder().decode(DemoScene.self, from: JSONSerialization.data(withJSONObject: object)).validated()
        scene.libraryRevision = record.revision
        return scene
    }
    /// Preserve fields the older Mac renderer does not edit. A new persona image
    /// clears the old authored card unless the caller supplies its new source.
    func portable(_ scene: DemoScene, preserving previous: PortableScene? = nil,
                  card: SceneCardStyle? = nil, replacingCard: Bool = false) throws -> PortableScene {
        let checked = try scene.validated()
        var object = try Self.object(checked)
        var names: [String: String] = [:]
        for file in Set([checked.background, checked.logo?.image, checked.hand?.image, checked.persona?.image].compactMap { $0 }) {
            if let retained = previous?.assets.first(where: { Self.materializedName($0) == file }) {
                // A rename/layout edit retains the canonical asset. An external
                // change to a renderer cache is never an implicit picture edit.
                names[file] = retained; continue
            }
            guard let bytes = try PersonaStorage.read(root.appendingPathComponent(file), maximumBytes: SceneAsset.maximumBytes)
            else { throw SceneDocumentError.missingAsset }
            names[file] = try library.importAsset(bytes)
        }
        Self.rewriteImages(&object) { names[$0] ?? $0 }
        var portable = try JSONDecoder().decode(PortableScene.self, from: JSONSerialization.data(withJSONObject: object))
        // Rig references stay canonical hashes, unlike the native poster cache
        // filename. A deliberate clear must not resurrect the previous recipe.
        portable.ambience = checked.ambience
        portable.groupID = previous?.groupID; portable.legacyMobileProject = previous?.legacyMobileProject
        portable.retainedAssets = previous?.retainedAssets
        if replacingCard { portable.persona?.card = card }
        else if portable.persona?.image == previous?.persona?.image { portable.persona?.card = previous?.persona?.card }
        return try portable.validated()
    }
    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        else { throw SceneError.invalidScene }; return object
    }
    private static func rewriteImages(_ object: inout [String: Any], transform: (String) -> String) {
        if let file = object["background"] as? String { object["background"] = transform(file) }
        for key in ["logo", "hand", "persona"] {
            if var layer = object[key] as? [String: Any], let file = layer["image"] as? String {
                layer["image"] = transform(file); object[key] = layer
            }
        }
    }

    func migratePreviousScenes() {
        importing = true; defer { importing = false; publish(library.records) }
        recovery = []; recoveryIDs = []; nativeCache = [:]; migrationNotice = nil; isBlocked = library.isStorageBlocked
        do {
            let legacy = try SceneStorage.load(legacyURL)
            for scene in legacy {
                let source = "mac-scenes-v1:" + scene.id.uuidString
                guard !library.hasAdoptedLegacySource(source) else { continue }
                do {
                    // Validate every referenced byte before the source marker and
                    // record are committed together. Failed sources remain retryable.
                    let converted = try portable(scene)
                    _ = try library.migrate(scene: converted, sourceID: source)
                } catch {
                    var preserved = scene
                    if library.records.contains(where: { $0.id == scene.id }) {
                        let hex = SceneAsset.digest(Data(("legacy-recovery:" + scene.id.uuidString).utf8))
                        let value = String(hex.prefix(32))
                        let formatted = "\(value.prefix(8))-\(value.dropFirst(8).prefix(4))-\(value.dropFirst(12).prefix(4))-\(value.dropFirst(16).prefix(4))-\(value.suffix(12))"
                        preserved.id = UUID(uuidString: formatted)!
                    }
                    recovery.append(preserved); recoveryIDs.insert(preserved.id)
                    migrationNotice = "Some previous scenes need attention. Their original files are kept and readable scenes can still be exported. Restore missing pictures in the original folder, then retry import."
                }
            }
        } catch {
            migrationNotice = "The previous scenes file could not be read. It is unchanged. " + error.localizedDescription
            if !FileManager.default.fileExists(atPath: library.directory.appendingPathComponent("scene-library.json").path) { isBlocked = true }
        }
    }
    private func publish(_ records: [SavedSceneRecord]) {
        var next: [DemoScene] = []; unavailableAssetIDs = []; isBlocked = isBlocked || library.isStorageBlocked
        var retainedCache: [UUID: (revision: UUID, scene: DemoScene)] = [:]
        for record in records where !record.isDeleted {
            do {
                // An acknowledgement or an edit to another scene does not need
                // to read every large picture in the library again.
                let value = nativeCache[record.id].flatMap { $0.revision == record.revision ? $0.scene : nil }
                let scene = try value ?? native(record)
                next.append(scene); retainedCache[record.id] = (record.revision, scene)
            }
            catch {
                // Do not discard a record because its local image cache cannot be
                // materialized. Its canonical package remains the recovery source.
                if let retained = try? nativeDocument(record) { next.append(retained); unavailableAssetIDs.insert(record.id) }
                migrationNotice = "A saved scene needs attention. Its portable document is kept. " + error.localizedDescription
            }
        }
        nativeCache = retainedCache
        scenes = next + recovery.filter { item in !next.contains(where: { $0.id == item.id }) }
        onChange?()
    }
    func isReadOnly(_ id: UUID) -> Bool { isBlocked || recoveryIDs.contains(id) || unavailableAssetIDs.contains(id) }
    func save(_ scene: DemoScene, card: SceneCardStyle? = nil, replacingCard: Bool = false) throws {
        guard !isReadOnly(scene.id), let revision = scene.libraryRevision,
              let previous = library.records.first(where: { $0.id == scene.id && !$0.isDeleted }), previous.revision == revision
        else { throw SceneDocumentError.concurrentChange }
        let portable = try portable(scene, preserving: previous.scene, card: card, replacingCard: replacingCard)
        _ = try library.save(portable, expectedRevision: revision)
        publish(library.records)
    }
    func create(_ scene: DemoScene) throws {
        guard !isBlocked else { throw SceneDocumentError.storageBlocked }
        _ = try library.create(portable(scene)); publish(library.records)
    }
    func duplicate(_ scene: DemoScene) throws -> UUID {
        guard !isReadOnly(scene.id), let current = library.records.first(where: { $0.id == scene.id && !$0.isDeleted }),
              current.revision == scene.libraryRevision else { throw SceneDocumentError.concurrentChange }
        let copy = try library.duplicate(id: scene.id); publish(library.records); return copy.id
    }
    func remove(_ scene: DemoScene) throws {
        guard !isReadOnly(scene.id), let revision = scene.libraryRevision else { throw SceneDocumentError.concurrentChange }
        try library.delete(id: scene.id, expectedRevision: revision); publish(library.records)
    }
    func reorder(_ ids: [UUID]) throws { try library.reorder(ids: ids); publish(library.records) }
    func shutdown() { subscriptions.removeAll(); library.cancelRefresh(); onChange = nil }
}

struct MacSceneSyncControls: View {
    @ObservedObject var adapter: MacSceneSync
    @ObservedObject private var library: SceneLibraryModel
    init(adapter: MacSceneSync) { self.adapter = adapter; library = adapter.library }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(library.status, systemImage: library.isEnabled ? "icloud" : "internaldrive")
                    .font(.caption).lineLimit(2)
                Spacer(minLength: 0)
                Menu {
                    if library.isEnabled {
                        Button("Sync now") { Task { await library.refresh() } }.disabled(library.isBusy)
                        Button("Turn off scene sync") { library.disable() }
                    } else {
                        Button("Use private iCloud sync") { Task { await library.enable() } }
                            .disabled(!library.isConfigured || library.isBusy || adapter.isBlocked)
                    }
                    Divider()
                    Button("Retry importing previous scenes") { adapter.migratePreviousScenes() }
                    Button("Show original scene files") { NSWorkspace.shared.open(adapter.root) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Scene sync options")
            }
            if !library.isConfigured { Text("iCloud needs a provisioned build. Local saving works.").font(.caption).foregroundStyle(.secondary) }
            if let error = library.error {
                Text(error + (library.isStorageBlocked ? " Quit and reopen Workbench before editing." : ""))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let notice = adapter.migrationNotice { Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .task { await library.refresh() }
    }
}
