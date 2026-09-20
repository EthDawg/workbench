import Foundation
import Combine

public struct SceneCloudConfiguration: Equatable, Sendable {
    public let container: String
    public let environment: String
    /// Supplied by the app's verified signing gate. This module never infers entitlement from a container name.
    public let isProvisioned: Bool
    public init(container: String, environment: String, isProvisioned: Bool) {
        self.container = container; self.environment = environment; self.isProvisioned = isProvisioned
    }
    public static let unavailable = Self(container: "", environment: "", isProvisioned: false)
    public var isConfigured: Bool {
        isProvisioned && container.hasPrefix("iCloud.") && container.count <= 200 &&
        container.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-".unicodeScalars.contains($0)) } &&
        ["Production", "Development"].contains(environment)
    }
}

public struct SceneSyncUpload: Sendable {
    public let record: SavedSceneRecord
    public let package: ScenePackage
    public init(record: SavedSceneRecord, package: ScenePackage) { self.record = record; self.package = package }
}
public enum SceneSyncEvent: Sendable {
    case received(SavedSceneRecord, ScenePackage)
    case acknowledged(SavedSceneRecord)
    case checkpoint(Data)
}
public enum SceneSyncError: LocalizedError, Equatable {
    case unavailable, accountChanged, cancelled, invalidEnvelope, removedRemotely
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Scene sync needs a provisioned Workbench build and an available iCloud account. Your scenes remain on this device."
        case .accountChanged: "Scene sync paused because the iCloud account changed. Sign back into the original account to resume. All local scenes are kept."
        case .cancelled: "Scene sync stopped. Your local changes are kept."
        case .invalidEnvelope: "An iCloud scene could not be validated. Its checkpoint was not advanced; local scenes are kept."
        case .removedRemotely: "The scene zone or a record was removed outside Workbench. Sync is paused and local scenes are kept."
        }
    }
}
@MainActor public protocol SceneSyncTransport: AnyObject {
    var onAccountChange: (@MainActor @Sendable () -> Void)? { get set }
    func currentAccount() async throws -> SceneSyncAccount
    /// The sink must finish its durable local commit before returning. A thrown error halts the cycle.
    func synchronize(account: SceneSyncAccount, state: Data?, uploads: [SceneSyncUpload],
                     onEvent: @escaping @MainActor @Sendable (SceneSyncEvent) throws -> Void) async throws
    func cancel()
}

/// Local edits commit synchronously before any cloud work. A cloud receipt can
/// acknowledge its captured revision, but cannot replace an edit made while it was in flight.
@MainActor public final class SceneLibraryModel: ObservableObject {
    @Published public private(set) var records: [SavedSceneRecord] = []
    @Published public private(set) var error: String?
    @Published public private(set) var isBusy = false
    @Published public private(set) var isEnabled = false
    @Published public private(set) var status = "Saved on this device"
    public let isConfigured: Bool
    public let directory: URL
    public var isStorageBlocked: Bool { storageBlocked }
    private let store: SceneLibraryStore
    private var archive = SceneLibraryArchive()
    private let transport: (any SceneSyncTransport)?
    private var generation = UUID()
    private var storageBlocked = false
    private let automaticSyncDelay: @MainActor @Sendable () async throws -> Void
    private(set) var scheduledSync: Task<Void, Never>?
    private var scheduleToken = UUID()
    private var authoredMutation = UUID()
    private var automaticSyncSuspended = false
    private var automaticSyncNeedsExplicitRetry = false

    public init(directory: URL, configuration: SceneCloudConfiguration = .unavailable,
                transport: (any SceneSyncTransport)? = nil,
                automaticSyncDelay: @escaping @MainActor @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(800)) }) {
        self.automaticSyncDelay = automaticSyncDelay
        self.directory = directory; self.store = SceneLibraryStore(directory: directory)
        self.isConfigured = transport != nil || configuration.isConfigured
        self.transport = transport ?? (configuration.isConfigured ? CloudSceneSync(configuration: configuration) : nil)
        do { archive = try store.load(); publish() }
        catch { storageBlocked = true; self.error = error.localizedDescription; status = "Local library needs attention" }
        self.transport?.onAccountChange = { [weak self] in self?.pauseForAccountChange() }
    }
    private func publish() {
        records = archive.records; isEnabled = archive.syncEnabled && isConfigured && !storageBlocked
        if !isBusy { status = isEnabled ? (archive.records.contains(where: { $0.isDirty }) ? "Waiting to sync" : "In iCloud") : "Saved on this device" }
    }
    private func commit(_ next: SceneLibraryArchive) throws {
        guard !storageBlocked else { throw SceneDocumentError.storageBlocked }
        let next = try next.preparedForSaving() // Unsupported input is not a broken local store.
        do { archive = try store.save(next); publish() }
        catch {
            storageBlocked = true; cancelScheduledSync(); automaticSyncSuspended = true
            generation = UUID(); transport?.cancel(); isBusy = false; isEnabled = false
            self.error = error.localizedDescription; status = "Local library needs attention"
            throw error
        }
    }
    private func ensureWritable() throws { if storageBlocked { throw SceneDocumentError.storageBlocked } }
    @discardableResult public func importAsset(_ data: Data) throws -> String {
        try ensureWritable(); return try store.importAsset(data)
    }
    public func assetURL(_ name: String) throws -> URL { try store.assetURL(name) }
    public func package(for scene: PortableScene) throws -> ScenePackage { try store.package(for: scene) }
    private func newRecord(_ input: PortableScene, in next: SceneLibraryArchive) throws -> SavedSceneRecord {
        guard next.records.count < 1000 else { throw SceneDocumentError.invalid("The scene library is full. Existing scenes can still be edited or exported.") }
        var scene = try input.validated()
        _ = try store.package(for: scene) // All immutable bytes must exist before the manifest references them.
        if next.records.contains(where: { $0.id == scene.id }) { scene.id = UUID() }
        var record = SavedSceneRecord(scene: scene)
        // Edits while paused stay with the account that owns this library, never a replacement account.
        record.account = next.account
        return record
    }
    @discardableResult public func create(_ scene: PortableScene) throws -> SavedSceneRecord {
        try ensureWritable(); var next = archive
        let record = try newRecord(scene, in: next); next.records.append(record); try commit(next); authoredChangeCommitted(); return record
    }
    @discardableResult public func save(_ scene: PortableScene, expectedRevision: UUID) throws -> SavedSceneRecord {
        try ensureWritable(); _ = try scene.validated()
        guard let i = archive.records.firstIndex(where: { $0.id == scene.id }), !archive.records[i].isDeleted,
              archive.records[i].revision == expectedRevision else { throw SceneDocumentError.concurrentChange }
        guard archive.records[i].scene != scene else { return archive.records[i] }
        _ = try store.package(for: scene)
        var next = archive; next.records[i].scene = scene; next.records[i].revision = UUID(); next.records[i].modified = Date()
        try commit(next); authoredChangeCommitted(); return next.records[i]
    }
    public func delete(id: UUID, expectedRevision: UUID) throws {
        try ensureWritable()
        guard let i = archive.records.firstIndex(where: { $0.id == id }), archive.records[i].revision == expectedRevision else { throw SceneDocumentError.concurrentChange }
        guard !archive.records[i].isDeleted else { return }
        var next = archive; next.records[i].isDeleted = true; next.records[i].revision = UUID(); next.records[i].modified = Date(); try commit(next); authoredChangeCommitted()
    }
    @discardableResult public func duplicate(id: UUID) throws -> SavedSceneRecord {
        guard let record = archive.records.first(where: { $0.id == id }) else { throw SceneDocumentError.invalid("This scene is no longer available.") }
        var scene = record.scene; scene.id = UUID(); scene.name = String(scene.name.prefix(150)) + " · copy"
        return try create(scene)
    }
    @discardableResult public func importPackage(_ data: Data) throws -> SavedSceneRecord {
        try ensureWritable(); let package = try ScenePackage.decode(data); try store.installAssets(from: package)
        var scene = package.scene; scene.id = UUID(); return try create(scene)
    }
    @discardableResult public func migrate(scene: PortableScene, sourceID: String) throws -> SavedSceneRecord? {
        try ensureWritable()
        guard !sourceID.isEmpty, sourceID.count <= 240 else { throw SceneDocumentError.invalid("The scene import source is invalid.") }
        guard !archive.adoptedLegacyIDs.contains(sourceID) else { return nil }
        var next = archive; let record = try newRecord(scene, in: next)
        next.records.append(record); next.adoptedLegacyIDs.append(sourceID); try commit(next); authoredChangeCommitted(); return record
    }
    public func hasAdoptedLegacySource(_ sourceID: String) -> Bool { archive.adoptedLegacyIDs.contains(sourceID) }
    /// Order is a local library preference; it does not create authored scene revisions.
    public func reorder(ids: [UUID]) throws {
        try ensureWritable()
        let live = archive.records.filter { !$0.isDeleted }
        guard ids.count == live.count, Set(ids).count == ids.count, Set(ids) == Set(live.map(\.id)) else { throw SceneDocumentError.concurrentChange }
        let indexed = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        var next = archive; next.records = ids.compactMap { indexed[$0] } + archive.records.filter(\.isDeleted)
        try commit(next)
    }
    public func statusLabel(for record: SavedSceneRecord) -> String {
        guard record.account != nil else { return "Saved on this device" }
        return record.isDirty ? "Waiting to sync" : "In iCloud"
    }
    /// Backgrounding suspends both queued timers and in-flight work. The next
    /// explicit foreground refresh/enable resumes automatic local-edit sends.
    public func cancelRefresh() {
        cancelScheduledSync(); automaticSyncSuspended = true
        generation = UUID(); transport?.cancel(); isBusy = false; publish()
    }
    public func disable() {
        cancelScheduledSync(); automaticSyncSuspended = true
        generation = UUID(); transport?.cancel(); isBusy = false
        var next = archive; next.syncEnabled = false
        do { try commit(next) } catch { self.error = error.localizedDescription }
    }
    private func pauseForAccountChange() {
        cancelScheduledSync(); automaticSyncSuspended = true; automaticSyncNeedsExplicitRetry = true
        generation = UUID(); transport?.cancel(); isBusy = false
        var next = archive; next.syncEnabled = false
        do { try commit(next); error = SceneSyncError.accountChanged.localizedDescription; status = "iCloud account changed" }
        catch { self.error = error.localizedDescription }
    }
    public func enable() async {
        cancelScheduledSync(); automaticSyncSuspended = false; automaticSyncNeedsExplicitRetry = false
        await run(enabling: true)
    }
    public func refresh() async {
        guard isEnabled else { return }
        cancelScheduledSync(); automaticSyncSuspended = false; automaticSyncNeedsExplicitRetry = false
        await run(enabling: false)
    }
    private var hasDirtyAccountRecords: Bool {
        guard let account = archive.account else { return false }
        return archive.records.contains { $0.account == account && $0.isDirty }
    }
    private func authoredChangeCommitted() {
        authoredMutation = UUID()
        // A running cycle takes one follow-on snapshot after success instead of
        // allowing a timer to race its current upload/acknowledgements.
        guard !isBusy else { return }
        scheduleAutomaticSync()
    }
    private func cancelScheduledSync() {
        scheduleToken = UUID(); scheduledSync?.cancel(); scheduledSync = nil
    }
    private func scheduleAutomaticSync() {
        cancelScheduledSync()
        guard isEnabled, !storageBlocked, !automaticSyncSuspended, !automaticSyncNeedsExplicitRetry,
              !isBusy, hasDirtyAccountRecords else { return }
        let token = scheduleToken, delay = automaticSyncDelay
        scheduledSync = Task { @MainActor [weak self] in
            do { try await delay(); try Task.checkCancellation() }
            catch {
                if let self, token == self.scheduleToken { self.scheduledSync = nil }
                return
            }
            guard let self, token == self.scheduleToken else { return }
            self.scheduledSync = nil
            guard self.isEnabled, !self.automaticSyncSuspended, !self.automaticSyncNeedsExplicitRetry,
                  !self.isBusy, self.hasDirtyAccountRecords else { return }
            await self.run(enabling: false)
        }
    }
    private func run(enabling: Bool) async {
        guard !isBusy, !storageBlocked else { return }
        guard let transport else { error = SceneSyncError.unavailable.localizedDescription; return }
        let token = UUID(), mutationAtStart = authoredMutation
        generation = token; isBusy = true; error = nil; status = "Checking iCloud"
        var completed = false
        defer {
            if token == generation {
                isBusy = false; publish()
                if completed, authoredMutation != mutationAtStart, hasDirtyAccountRecords { scheduleAutomaticSync() }
            }
        }
        do {
            let account = try await transport.currentAccount(); try account.validate(); try check(token)
            guard archive.account == nil || archive.account == account else { throw SceneSyncError.accountChanged }
            var next = archive
            if enabling {
                next.account = account; next.syncEnabled = true
                for i in next.records.indices where next.records[i].account == nil { next.records[i].account = account }
                try commit(next)
            }
            guard archive.syncEnabled, archive.account == account else { throw SceneSyncError.accountChanged }
            // Bound memory and work per foreground cycle. Remaining dirty scenes stay queued durably.
            var uploads: [SceneSyncUpload] = []; var total = 0
            for record in archive.records where record.account == account && record.isDirty {
                let package = try store.package(for: record.scene)
                let bytes = try package.encoded().count
                if uploads.count >= 12 || (!uploads.isEmpty && total + bytes > 120_000_000) { break }
                total += bytes; uploads.append(SceneSyncUpload(record: record, package: package))
            }
            let sent = Dictionary(uniqueKeysWithValues: uploads.map { ($0.record.id, $0.record) })
            status = "Syncing scenes"
            try await transport.synchronize(account: account, state: archive.engineState, uploads: uploads) { [weak self] event in
                guard let self else { throw SceneSyncError.cancelled }; try self.check(token)
                guard self.archive.account == account, self.archive.syncEnabled else { throw SceneSyncError.accountChanged }
                try self.accept(event, account: account, sent: sent)
            }
            try check(token)
            guard try await transport.currentAccount() == account else { throw SceneSyncError.accountChanged }
            try check(token); completed = true
        } catch {
            guard token == generation else { return }
            // No retry loop: even later local edits wait for explicit foreground
            // or manual refresh after a failed operation.
            automaticSyncNeedsExplicitRetry = true; cancelScheduledSync()
            if error as? SceneSyncError == .accountChanged { pauseForAccountChange() }
            else { self.error = error.localizedDescription }
        }
    }
    private func check(_ token: UUID) throws {
        guard token == generation, !Task.isCancelled else { throw SceneSyncError.cancelled }
    }
    private func accept(_ event: SceneSyncEvent, account: SceneSyncAccount, sent: [UUID: SavedSceneRecord]) throws {
        var next = archive
        switch event {
        case .checkpoint(let data):
            guard data.count <= 8_000_000 else { throw SceneSyncError.invalidEnvelope }; next.engineState = data
        case .received(let record, let package):
            guard record.account == account, record.scene == package.scene else { throw SceneSyncError.invalidEnvelope }
            try store.installAssets(from: package)
            try SceneRevisionMerge.receive(record, into: &next, account: account)
        case .acknowledged(let remote):
            guard let snapshot = sent[remote.id], remote.account == account, snapshot.revision == remote.revision,
                  snapshot.scene == remote.scene, snapshot.isDeleted == remote.isDeleted,
                  let i = next.records.firstIndex(where: { $0.id == remote.id }), next.records[i].account == account else { throw SceneSyncError.invalidEnvelope }
            let local = next.records[i]
            if local.revision == snapshot.revision {
                guard local.scene == snapshot.scene, local.isDeleted == snapshot.isDeleted else { throw SceneSyncError.invalidEnvelope }
                next.records[i].baseRevision = snapshot.revision; next.records[i].remoteSystemFields = remote.remoteSystemFields
            } else if local.baseRevision == snapshot.baseRevision {
                // A newer local edit is still pending; only advance its known server base.
                next.records[i].baseRevision = snapshot.revision; next.records[i].remoteSystemFields = remote.remoteSystemFields
            }
            // A fetched conflict may already have replaced this ID. Its newer server base wins over this stale receipt.
        }
        try commit(next)
    }
}
