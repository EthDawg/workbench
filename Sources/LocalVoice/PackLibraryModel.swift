import AppKit
import Combine
import PrivatePackKit
import StageKit

@MainActor
final class PackLibraryModel: ObservableObject {
    static let shared = PackLibraryModel()
    @Published private(set) var packs: [PackShelfItem] = []
    @Published private(set) var login: String?
    @Published private(set) var deviceCode: String?
    @Published private(set) var isBusy = false
    @Published private(set) var activity = ""
    @Published private(set) var operationPackID: String?
    @Published private(set) var connecting = false
    @Published private(set) var noticePackID: String?
    @Published var notice: String?
    @Published var hasError = false
    @Published var pendingSource: String?
    @Published var preferredTranscriptSkillID: String?
    @Published private(set) var transcriptSkills: [TranscriptHandoffSkill] = []
    @Published private(set) var brandPackID: String?
    @Published private(set) var savedResource: PackSavedResource?
    @Published var automaticUpdates: Bool {
        didSet { defaults.set(automaticUpdates, forKey: "packs.automaticUpdates.v1") }
    }
    var onSkillsChanged: (([TranscriptHandoffSkill]) -> Void)?
    var brandLabel: String? { brandPackID.flatMap { payloads[$0]?.manifest.branding?.label } }
    var brandLogo: NSImage? { brandPackID.flatMap { id in packs.first(where: { $0.id == id })?.logo } }
    private let store: PackStore
    private let defaults: UserDefaults
    private let services: PackLibraryServices
    private var records: [String: InstalledPack] = [:]
    private var payloads: [String: PackPayload] = [:]
    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private var verificationURL: URL?
    private var updateTimer: Timer?
    private var lastUpdateAttempt = Date.distantPast
    private var refreshGeneration = 0
    private let appVersion: PackVersion

    init(defaults: UserDefaults = .standard, root: URL = Workbench.supportDirectory(component: "Packs"),
         services: PackLibraryServices? = nil) {
        self.defaults = defaults
        self.services = services ?? PackLibraryServices()
        self.store = PackStore(root: root)
        self.appVersion = PackVersion.appVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.2.0") ?? PackVersion("2.2.0")!
        self.automaticUpdates = defaults.object(forKey: "packs.automaticUpdates.v1") as? Bool ?? true
        self.brandPackID = defaults.string(forKey: "packs.appearance.v1")
        do { login = try self.services.readCredential()?.login }
        catch { notice = error.localizedDescription; hasError = true }
    }
    func connect() {
        run("Waiting for GitHub sign-in…", connecting: true) { attempt in
            let authorization = try self.services.authorization()
            let challenge = try await authorization.begin()
            try self.requireCurrent(attempt)
            self.deviceCode = challenge.userCode; self.verificationURL = challenge.verificationURL
            self.openDeviceLogin()
            let token = try await authorization.complete(challenge)
            try self.requireCurrent(attempt)
            let login = try await authorization.login(accessToken: token.accessToken)
            try self.requireCurrent(attempt)
            try self.services.saveCredential(PackGitHubCredential(login: login, accessToken: token.accessToken,
                refreshToken: token.refreshToken, expiresAt: token.expiresAt, refreshExpiresAt: token.refreshExpiresAt))
            self.login = login
            self.notice = "Connected as \(login). Add a repository your team has invited you to."
            self.hasError = false
        }
    }
    func openDeviceLogin(copyCode: Bool = false) {
        guard connecting, operationID != nil, let url = verificationURL,
              url.absoluteString == "https://github.com/login/device" else { return }
        if copyCode, let code = deviceCode, !services.copyCode(code) {
            report(VoiceError.message("The sign-in code could not be copied. Select the code to copy it, or try again.")); return
        }
        if !services.openURL(url) { report(VoiceError.message("GitHub could not be opened. Open github.com/login/device in your browser and enter this code.")) }
    }
    func disconnect() {
        guard !isBusy else { return }
        do {
            try services.removeCredential(); login = nil; noticePackID = nil
            notice = "Disconnected on this Mac. Installed content and personal work remain available."
            hasError = false
        } catch { report(error) }
    }
    func cancel() {
        guard operationID != nil else { return }
        let wasConnecting = connecting
        operation?.cancel(); finishOperation()
        notice = wasConnecting ? "Sign-in cancelled. Installed content remains available."
            : "Cancelled. Any changes already completed remain available; personal work is unchanged."
        hasError = false
        refreshInstalled()
    }
    private func accessToken(for attempt: UUID) async throws -> String {
        try requireCurrent(attempt)
        guard var saved = try services.readCredential() else { throw VoiceError.message("Connect GitHub to install or update private packs. Installed content remains available.") }
        if let expiry = saved.expiresAt, expiry.timeIntervalSinceNow < 300 {
            guard let refresh = saved.refreshToken, saved.refreshExpiresAt.map({ $0 > Date() }) ?? true else {
                throw VoiceError.message("Reconnect GitHub to update your private packs.")
            }
            let token = try await services.authorization().refresh(refresh)
            try requireCurrent(attempt)
            saved.accessToken = token.accessToken; saved.refreshToken = token.refreshToken
            saved.expiresAt = token.expiresAt; saved.refreshExpiresAt = token.refreshExpiresAt
            // Save both rotated tokens together before starting a download.
            try services.saveCredential(saved)
        }
        return saved.accessToken
    }
    func install(_ text: String) {
        do {
            let source = try PackSource.parse(text)
            run("Installing pack…", packID: source.storageKey) { try await self.install(source, attempt: $0) }
        } catch { report(error) }
    }
    private func install(_ source: PackSource, attempt: UUID) async throws {
        let token = try await accessToken(for: attempt)
        try requireCurrent(attempt)
        let client = try services.contentSource(source, token)
        let previousVersion = records[source.storageKey]?.manifest.version
        let result = try await store.install(from: client, appVersion: appVersion)
        try requireCurrent(attempt)
        await loadInstalled()
        try requireCurrent(attempt)
        notice = previousVersion == result.pack.manifest.version
            ? "\(result.pack.manifest.name) is up to date (\(result.pack.manifest.version))."
            : "\(result.pack.manifest.name) \(result.pack.manifest.version) is ready to use."
    }
    func update(_ id: String) {
        guard let pack = records[id] else { return }
        run("Checking \(pack.manifest.name)…", packID: id) { try await self.install(pack.source, attempt: $0) }
    }
    func remove(_ id: String) {
        guard let pack = records[id] else { return }
        run("Removing pack…", packID: id) { attempt in
            try self.requireCurrent(attempt)
            try await self.store.remove(pack)
            if self.brandPackID == id { self.setBrand(nil) }
            try self.requireCurrent(attempt)
            await self.loadInstalled()
            try self.requireCurrent(attempt)
            self.noticePackID = nil
            self.notice = "Pack removed. Existing sessions, scenes and personas are unchanged."
        }
    }
    func setBrand(_ id: String?) {
        brandPackID = id
        defaults.set(id, forKey: "packs.appearance.v1")
    }
    func refreshInstalled() {
        Task { await loadInstalled() }
    }
    func start() {
        refreshInstalled()
        checkAutomatically()
        guard updateTimer == nil else { return }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 21_600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAutomatically() }
        }
    }
    func checkAutomatically() {
        guard automaticUpdates, login != nil, !isBusy, Date().timeIntervalSince(lastUpdateAttempt) >= 21_600 else { return }
        lastUpdateAttempt = Date()
        run("Checking pack updates…", clearNotice: false) { attempt in
            await self.loadInstalled()
            try self.requireCurrent(attempt)
            var failures: [String] = []
            for pack in self.records.values.sorted(by: { $0.id < $1.id }) {
                try self.requireCurrent(attempt)
                self.operationPackID = pack.id; self.noticePackID = pack.id
                self.activity = "Checking \(pack.manifest.name)…"
                do { try await self.install(pack.source, attempt: attempt) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    try Task.checkCancellation()
                    failures.append("\(pack.manifest.name): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                self.noticePackID = nil
                self.hasError = true
                self.notice = "Some packs could not update. Their installed content remains available.\n" + failures.joined(separator: "\n")
            }
        }
    }
    private func loadInstalled() async {
        refreshGeneration += 1; let generation = refreshGeneration
        do {
            let installed = try await store.installed()
            var valid: [String: PackPayload] = [:]
            var failures: [String] = []
            for pack in installed {
                do { valid[pack.id] = try await store.payload(for: pack) }
                catch { failures.append(pack.manifest.name) }
            }
            guard generation == refreshGeneration else { return }
            records = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0) }); payloads = valid
            packs = installed.map { pack in
                PackShelfItem(id: pack.id, name: pack.manifest.name, version: pack.manifest.version.description,
                    repository: pack.source.owner + "/" + pack.source.repository, sourceURL: pack.source.webURL!,
                    entries: valid[pack.id]?.manifest.entries.map { PackShelfEntry(id: $0.id, name: $0.name, kind: $0.kind.rawValue,
                        inputKinds: $0.inputKinds ?? []) } ?? [],
                    logo: valid[pack.id]?.brandingLogo.flatMap(NSImage.init(data:)),
                    problem: valid[pack.id] == nil ? "Installed files could not be verified. Remove this pack and add it again. Personal copies and sessions are unchanged." : nil)
            }
            transcriptSkills = skills(for: .transcripts)
            onSkillsChanged?(skills(for: .snapAndTalk))
            if !failures.isEmpty {
                notice = "These packs need repair: \(failures.joined(separator: ", ")). Remove and add them again. Existing sessions are unchanged."
                hasError = true
            }
        } catch { if generation == refreshGeneration { report(error) } }
    }
    private func skills(for input: PackInputKind) -> [TranscriptHandoffSkill] {
        records.values.sorted { $0.manifest.name < $1.manifest.name }.flatMap { pack -> [TranscriptHandoffSkill] in
            guard let payload = payloads[pack.id] else { return [] }
            return pack.manifest.entries.compactMap { entry in
                guard entry.kind == .skill, entry.inputKinds?.contains(input) == true,
                      let snapshot = try? payload.snapshot(entryID: entry.id) else { return nil }
                let reference = ReadbackSkillPackReference(id: Self.skillID(pack: pack, entry: entry),
                    version: pack.manifest.version.description, name: entry.name,
                    origin: ReadbackSkillOrigin(repository: pack.source.description, revision: pack.revision.sha,
                                               packID: pack.manifest.id, entryID: entry.id))
                let selected = ReadbackSkillPackSnapshot(reference: reference, files: snapshot.files)
                guard (try? selected.validate()) != nil else { return nil }
                let title = entry.name.localizedCaseInsensitiveContains(pack.manifest.name)
                    ? entry.name : "\(entry.name) (\(pack.manifest.name))"
                return TranscriptHandoffSkill(selected, title: title, detail: "\(pack.manifest.name) · \(pack.manifest.version)")
            }
        }
    }
    private static func skillID(pack: InstalledPack, entry: PackEntry) -> String {
        "private-" + String(PackDigest.hex(Data((pack.source.identity + "/" + pack.manifest.id + "/" + entry.id).utf8)).prefix(40))
    }
    @discardableResult func prepareSkill(_ entry: PackShelfEntry, from pack: PackShelfItem, input: PackInputKind?,
                                        readback: ReadbackModel) throws -> PackInputKind {
        guard let record = records[pack.id], record.manifest.version.description == pack.version,
              let definition = payloads[pack.id]?.manifest.entry(id: entry.id), definition.kind == .skill else {
            throw VoiceError.message("This skill changed or is unavailable. Review the installed pack and choose again.")
        }
        let supported = definition.inputKinds ?? []
        guard let chosen = input ?? (supported.count == 1 ? supported.first : nil), supported.contains(chosen) else {
            throw VoiceError.message("Choose Use with transcripts or Use with Snap & Talk for this skill.")
        }
        let id = Self.skillID(pack: record, entry: definition)
        if chosen == .snapAndTalk {
            guard readback.selectSkill(id) else { throw VoiceError.message(readback.notice ?? "Finish the current Snap & Talk work before choosing a skill.") }
            readback.notice = "Selected \(entry.name) for your next session. Existing sessions keep their own skill; choose New session when ready."
        } else { preferredTranscriptSkillID = id }
        return chosen
    }
    func use(_ entry: PackShelfEntry, from pack: PackShelfItem, input: PackInputKind? = nil,
             readback: ReadbackModel, app: AppModel, stage: StageKitController) {
        do {
            guard let record = records[pack.id], let payload = payloads[pack.id],
                  record.manifest.version.description == pack.version,
                  let definition = payload.manifest.entry(id: entry.id) else { throw VoiceError.message("This pack changed. Review its current content and choose again.") }
            noticePackID = pack.id
            if definition.kind == .skill {
                if try prepareSkill(entry, from: pack, input: input, readback: readback) == .snapAndTalk { app.page = "readback" }
                else { app.openHistory() }
                return
            }
            let data = try payload.data(at: definition.path)
            if definition.kind == .resources {
                if saveResource(data, title: entry.name, filename: URL(fileURLWithPath: definition.path).lastPathComponent, library: app.library) {
                    app.page = "library"
                }
                return
            }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench-pack-import-" + UUID().uuidString)
            try ReadbackStore.createPrivateDirectory(temporary)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let file = temporary.appendingPathComponent(URL(fileURLWithPath: definition.path).lastPathComponent)
            try ReadbackStore.writePrivate(data, to: file)
            switch definition.kind {
            case .scene: try stage.importPackScene(at: file); app.page = "present"
            case .personas: try stage.importPackPersona(at: file, name: entry.name); app.page = "personas"
            case .resources, .skill: break
            }
            notice = "Added your own copy of \(entry.name). Pack updates will not change it."
            hasError = false
        } catch { report(error) }
    }

    @discardableResult func saveResource(_ data: Data, title: String, filename: String, library: DemoLibraryModel,
        chooseDestination: ((String) -> URL?)? = nil, write: ((Data, URL) throws -> Void)? = nil) -> Bool {
        guard savedResource == nil else {
            report(VoiceError.message("Finish adding the saved file to Library, or choose Keep file only before exporting another resource.")); return false
        }
        guard library.draft == nil, library.importReview == nil else {
            report(VoiceError.message("Save or cancel the current Library review before saving a pack resource.")); return false
        }
        let destination: URL?
        if let chooseDestination { destination = chooseDestination(filename) }
        else {
            let panel = NSSavePanel(); panel.nameFieldStringValue = filename; panel.title = "Save Resource"
            panel.message = "Save your own file. Workbench will verify it and add its reference to Library; pack updates will not change it."
            destination = panel.runModal() == .OK ? panel.url : nil
        }
        guard let destination else { return false }
        let access = destination.startAccessingSecurityScopedResource()
        defer { if access { destination.stopAccessingSecurityScopedResource() } }
        let exported = PackSavedResource(title: title, url: destination, byteCount: data.count, digest: PackDigest.hex(data))
        do {
            guard destination.isFileURL else { throw VoiceError.message("Choose a local destination for this resource.") }
            try (write ?? { try ReadbackStore.writePrivate($0, to: $1) })(data, destination)
            savedResource = exported
            return addSavedResource(to: library)
        } catch {
            if destination.isFileURL, (try? exported.verify()) != nil { savedResource = exported }
            report(VoiceError.message("Saving could not finish at \(destination.path). No Library reference was confirmed. \(error.localizedDescription)"))
            return false
        }
    }

    @discardableResult func addSavedResource(to library: DemoLibraryModel, reviewCurrentStore: Bool = false) -> Bool {
        guard let saved = savedResource else { return false }
        let access = saved.url.startAccessingSecurityScopedResource()
        defer { if access { saved.url.stopAccessingSecurityScopedResource() } }
        do {
            try saved.verify()
            if reviewCurrentStore, library.savingDisabled {
                guard library.reviewForSavedFileReference() else {
                    throw VoiceError.message(library.storageFailure ?? "Finish the current Library review before adding this file's reference.")
                }
            }
            guard library.draft == nil, library.importReview == nil, !library.savingDisabled else {
                throw VoiceError.message(library.storageFailure ?? "Finish the current Library review before adding this file's reference.")
            }
            if let existing = library.resources.first(where: { $0.id == saved.id }) {
                guard existing.kind == .file, existing.content == saved.url.path else {
                    throw VoiceError.message("That Library record changed. The saved file remains where you put it; no record was replaced.")
                }
            } else {
                #if APP_STORE
                let options: URL.BookmarkCreationOptions = [.withSecurityScope]
                #else
                let options: URL.BookmarkCreationOptions = [.minimalBookmark]
                #endif
                let bookmark = try saved.url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
                let resource = DemoResource(id: saved.id, kind: .file, title: saved.title, content: saved.url.path, bookmark: bookmark)
                guard library.save(resource) else { throw VoiceError.message(library.storageFailure ?? library.error ?? "Library could not be saved.") }
            }
            guard try library.store.load().contains(where: { $0.id == saved.id && $0.kind == .file && $0.content == saved.url.path }) else {
                throw VoiceError.message("The Library reference could not be verified.")
            }
            try saved.verify()
            library.query = ""; library.favoritesOnly = false; library.selection = saved.id
            library.notice = "Saved file added to Library. Open file when you are ready."
            savedResource = nil; notice = nil; hasError = false
            return true
        } catch {
            report(VoiceError.message("The file was saved, but its Library reference could not be confirmed. \(error.localizedDescription)"))
            return false
        }
    }

    func keepSavedFileOnly() {
        guard let savedResource else { return }
        notice = "Kept \(savedResource.url.lastPathComponent) in its chosen folder. No further Library change was made."
        hasError = false; self.savedResource = nil
    }
    func acceptLink(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["workbench", "workbench-preview"].contains(components.scheme ?? ""),
              components.host == "packs", components.path == "/add", components.user == nil,
              components.password == nil, components.port == nil, components.fragment == nil,
              let items = components.queryItems, items.count == 1, items[0].name == "source",
              let value = items[0].value, let source = try? PackSource.parse(value) else { return false }
        pendingSource = source.webURL?.absoluteString
        return true
    }
    private func report(_ error: Error) { notice = error.localizedDescription; hasError = true }
    private func requireCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard operationID == id else { throw CancellationError() }
    }
    private func finishOperation() {
        operationID = nil; operation = nil; isBusy = false; activity = ""
        operationPackID = nil; connecting = false; deviceCode = nil; verificationURL = nil
    }
    private func run(_ label: String, packID: String? = nil, connecting: Bool = false, clearNotice: Bool = true,
                     work: @escaping @MainActor (UUID) async throws -> Void) {
        guard !isBusy else { return }
        let id = UUID(); operationID = id; operationPackID = packID; noticePackID = packID; self.connecting = connecting
        isBusy = true; activity = label; hasError = false
        if clearNotice { notice = nil }
        operation = Task {
            defer { if operationID == id { finishOperation() } }
            do { try await work(id) }
            catch is CancellationError {
                if operationID == id { notice = "Cancelled. Installed content remains available." }
            }
            catch { if operationID == id { report(error) } }
        }
    }
}
