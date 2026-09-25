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
    @Published var notice: String?
    @Published var hasError = false
    @Published var pendingSource: String?
    @Published var preferredTranscriptSkillID: String?
    @Published private(set) var transcriptSkills: [TranscriptHandoffSkill] = []
    @Published private(set) var brandPackID: String?
    @Published var automaticUpdates: Bool {
        didSet { defaults.set(automaticUpdates, forKey: "packs.automaticUpdates.v1") }
    }
    var onSkillsChanged: (([TranscriptHandoffSkill]) -> Void)?
    var brandLabel: String? { brandPackID.flatMap { payloads[$0]?.manifest.branding?.label } }
    var brandLogo: NSImage? { brandPackID.flatMap { id in packs.first(where: { $0.id == id })?.logo } }
    private let store: PackStore
    private let defaults: UserDefaults
    private var records: [String: InstalledPack] = [:]
    private var payloads: [String: PackPayload] = [:]
    private var operation: Task<Void, Never>?
    private var verificationURL: URL?
    private var updateTimer: Timer?
    private var lastUpdateAttempt = Date.distantPast
    private var refreshGeneration = 0
    private let appVersion: PackVersion

    init(defaults: UserDefaults = .standard, root: URL = Workbench.supportDirectory(component: "Packs")) {
        self.defaults = defaults
        self.store = PackStore(root: root)
        self.appVersion = PackVersion.appVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.2.0") ?? PackVersion("2.2.0")!
        self.automaticUpdates = defaults.object(forKey: "packs.automaticUpdates.v1") as? Bool ?? true
        self.brandPackID = defaults.string(forKey: "packs.appearance.v1")
        do { login = try PackCredentialStore.read()?.login }
        catch { notice = error.localizedDescription; hasError = true }
    }
    private func authorization() throws -> GitHubPackAuthorization {
        try GitHubPackAuthorization(clientID: Bundle.main.object(forInfoDictionaryKey: "WorkbenchGitHubClientID") as? String ?? "")
    }
    func connect() {
        run("Waiting for GitHub sign-in…") {
            let authorization = try self.authorization()
            let challenge = try await authorization.begin()
            self.deviceCode = challenge.userCode; self.verificationURL = challenge.verificationURL
            self.openDeviceLogin()
            let token = try await authorization.complete(challenge)
            let login = try await authorization.login(accessToken: token.accessToken)
            try Task.checkCancellation()
            try PackCredentialStore.save(PackGitHubCredential(login: login, accessToken: token.accessToken,
                refreshToken: token.refreshToken, expiresAt: token.expiresAt, refreshExpiresAt: token.refreshExpiresAt))
            self.login = login
            self.notice = "Connected as \(login). Add a repository your team has invited you to."
        }
    }
    func openDeviceLogin() {
        guard let url = verificationURL, url.absoluteString == "https://github.com/login/device" else { return }
        NSWorkspace.shared.open(url)
    }
    func disconnect() {
        guard !isBusy else { return }
        do {
            try PackCredentialStore.remove(); login = nil
            notice = "Disconnected on this Mac. Installed content and personal work remain available."
            hasError = false
        } catch { report(error) }
    }
    func cancel() { operation?.cancel() }
    private func accessToken() async throws -> String {
        guard var saved = try PackCredentialStore.read() else { throw VoiceError.message("Connect GitHub to install or update private packs.") }
        if let expiry = saved.expiresAt, expiry.timeIntervalSinceNow < 300 {
            guard let refresh = saved.refreshToken, saved.refreshExpiresAt.map({ $0 > Date() }) ?? true else {
                throw VoiceError.message("Reconnect GitHub to update your private packs.")
            }
            let token = try await authorization().refresh(refresh)
            saved.accessToken = token.accessToken; saved.refreshToken = token.refreshToken
            saved.expiresAt = token.expiresAt; saved.refreshExpiresAt = token.refreshExpiresAt
            // Save both rotated tokens together before starting a download.
            try PackCredentialStore.save(saved)
        }
        return saved.accessToken
    }
    func install(_ text: String) {
        do {
            let source = try PackSource.parse(text)
            run("Installing pack…") { try await self.install(source) }
        } catch { report(error) }
    }
    private func install(_ source: PackSource) async throws {
        let token = try await accessToken()
        let client = try GitHubPackClient(source: source, client: URLSessionPackClient(), token: token)
        let result = try await store.install(from: client, appVersion: appVersion)
        await loadInstalled()
        notice = "\(result.pack.manifest.name) \(result.pack.manifest.version) ready. \(result.downloadedFiles) files downloaded, \(result.reusedFiles) reused."
    }
    func update(_ id: String) {
        guard let pack = records[id] else { return }
        run("Checking \(pack.manifest.name)…") { try await self.install(pack.source) }
    }
    func remove(_ id: String) {
        guard let pack = records[id] else { return }
        run("Removing pack…") {
            try await self.store.remove(pack)
            if self.brandPackID == id { self.setBrand(nil) }
            await self.loadInstalled()
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
        run("Checking pack updates…", clearNotice: false) {
            await self.loadInstalled()
            for pack in self.records.values.sorted(by: { $0.id < $1.id }) {
                try Task.checkCancellation()
                try await self.install(pack.source)
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
                    entries: valid[pack.id]?.manifest.entries.map { PackShelfEntry(id: $0.id, name: $0.name, kind: $0.kind.rawValue) } ?? [],
                    logo: valid[pack.id]?.brandingLogo.flatMap(NSImage.init(data:)))
            }
            transcriptSkills = skills(for: .transcripts)
            onSkillsChanged?(skills(for: .snapAndTalk))
            if !failures.isEmpty {
                notice = "These packs need repair: \(failures.joined(separator: ", ")). Remove and add them again. Existing sessions are unchanged."
                hasError = true
            }
        } catch { report(error) }
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
                return TranscriptHandoffSkill(id: reference.id, title: entry.name,
                    detail: "\(pack.manifest.name) · \(pack.manifest.version)", load: { selected })
            }
        }
    }
    private static func skillID(pack: InstalledPack, entry: PackEntry) -> String {
        "private-" + String(PackDigest.hex(Data((pack.source.identity + "/" + pack.manifest.id + "/" + entry.id).utf8)).prefix(40))
    }
    func use(_ entry: PackShelfEntry, from pack: PackShelfItem, readback: ReadbackModel, app: AppModel, stage: StageKitController) {
        do {
            guard let record = records[pack.id], let payload = payloads[pack.id],
                  let definition = payload.manifest.entry(id: entry.id) else { throw VoiceError.message("Refresh Packs and try again.") }
            if definition.kind == .skill {
                let id = Self.skillID(pack: record, entry: definition)
                if definition.inputKinds?.contains(.snapAndTalk) == true {
                    readback.selectSkill(id); app.page = "readback"
                } else if definition.inputKinds?.contains(.transcripts) == true {
                    preferredTranscriptSkillID = id; app.page = "history"
                } else { throw VoiceError.message("This skill does not declare a supported input. Ask its contributor to update the pack.") }
                return
            }
            let data = try payload.data(at: definition.path)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench-pack-import-" + UUID().uuidString)
            try ReadbackStore.createPrivateDirectory(temporary)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let file = temporary.appendingPathComponent(URL(fileURLWithPath: definition.path).lastPathComponent)
            try ReadbackStore.writePrivate(data, to: file)
            switch definition.kind {
            case .scene: try stage.importPackScene(at: file); app.page = "present"
            case .personas: try stage.importPackPersona(at: file, name: entry.name); app.page = "present"
            case .resources:
                let panel = NSSavePanel(); panel.nameFieldStringValue = file.lastPathComponent; panel.title = "Save Resource"
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                try ReadbackStore.writePrivate(data, to: destination)
            case .skill: break
            }
            notice = "Added your own copy of \(entry.name). Pack updates will not change it."
            hasError = false
        } catch { report(error) }
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
    private func run(_ label: String, clearNotice: Bool = true, work: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true; activity = label; hasError = false
        if clearNotice { notice = nil }
        operation = Task {
            defer { isBusy = false; activity = ""; deviceCode = nil; verificationURL = nil; operation = nil }
            do { try await work() }
            catch is CancellationError { notice = "Cancelled. Any previously installed pack is unchanged." }
            catch { report(error) }
        }
    }
}
