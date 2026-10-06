import AppKit
import PrivatePackKit

/// In-memory repository used with the actual atomic PackStore, never a provider.
actor PackLibraryFixtureSource: PackContentSource {
    nonisolated let source: PackSource
    let manifestValue: PackManifest
    let bytes: [String: Data]
    let digest: String
    init(version: String = "1.0.0") throws {
        source = try .parse("example/workbench-fixture")
        let files = ["skills/both/SKILL.md": Data("# Prepare a useful response from the supplied material.\n".utf8),
                     "skills/notes/SKILL.md": Data("# Prepare notes from the selected transcripts.\n".utf8),
                     "skills/screens/SKILL.md": Data("# Prepare a visual walkthrough from the session.\n".utf8),
                     "resources/Workshop.txt": Data("  Synthetic workshop reference.\r\nKeep the original wording.  \n".utf8)]
        bytes = files
        manifestValue = PackManifest(id: "workshop", name: "Workshop starters", version: PackVersion(version)!,
            minimumAppVersion: PackVersion("2.2.0")!, entries: [
                PackEntry(id: "both", kind: .skill, name: "Prepare a follow-up", path: "skills/both/SKILL.md", inputKinds: [.transcripts, .snapAndTalk]),
                PackEntry(id: "notes", kind: .skill, name: "Meeting notes", path: "skills/notes/SKILL.md", inputKinds: [.transcripts]),
                PackEntry(id: "screens", kind: .skill, name: "Visual walkthrough", path: "skills/screens/SKILL.md", inputKinds: [.snapAndTalk]),
                PackEntry(id: "file", kind: .resources, name: "Workshop reference", path: "resources/Workshop.txt")],
            files: files.keys.sorted().map { PackFile(path: $0, sha256: PackDigest.hex(files[$0]!), size: files[$0]!.count) },
            branding: PackBranding(label: "Workshop"))
        digest = PackDigest.hex(try JSONEncoder().encode(manifestValue))
    }
    func currentRevision() async throws -> PackRevision { try PackRevision(sha: String(repeating: "a", count: 40)) }
    func catalog(at revision: PackRevision) async throws -> PackCatalog {
        PackCatalog(id: manifestValue.id, name: manifestValue.name, releases: [PackRelease(version: manifestValue.version,
            minimumAppVersion: manifestValue.minimumAppVersion, manifestPath: "releases/\(manifestValue.version)/pack.json", sha256: digest)])
    }
    func manifest(for release: PackRelease, in catalog: PackCatalog, at revision: PackRevision) async throws -> PackManifestDocument {
        PackManifestDocument(manifest: manifestValue, digest: digest, path: release.manifestPath)
    }
    func file(_ file: PackFile, for release: PackRelease, at revision: PackRevision) async throws -> Data { bytes[file.path]! }
}

actor PackAuthorizationFixture: PackHTTPClient {
    enum Gate { case none, challenge, login }
    var requests = 0
    private let gate: Gate
    private let code: String
    private let declined: Bool
    private let pending: Bool
    private var continuation: CheckedContinuation<PackHTTPResponse, Error>?
    init(_ gate: Gate = .none, code: String = "TEST-CODE", declined: Bool = false, pending: Bool = false) {
        self.gate = gate; self.code = code; self.declined = declined; self.pending = pending
    }
    var waiting: Bool { continuation != nil }
    func send(_ request: PackHTTPRequest) async throws -> PackHTTPResponse {
        requests += 1
        let reply: String
        if request.url.path == "/login/device/code" {
            reply = "{\"device_code\":\"fixture-device\",\"user_code\":\"\(code)\",\"verification_uri\":\"https://github.com/login/device\",\"expires_in\":60,\"interval\":1}"
        } else if request.url.path == "/user" { reply = "{\"login\":\"fixture-account\"}" }
        else { reply = declined ? "{\"error\":\"expired_token\"}" : pending ? "{\"error\":\"authorization_pending\"}" : "{\"access_token\":\"fixture-access\",\"token_type\":\"bearer\"}" }
        let response = PackHTTPResponse(status: 200, body: Data(reply.utf8))
        if (gate == .challenge && request.url.path == "/login/device/code") || (gate == .login && request.url.path == "/user") {
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        return response
    }
    func resume(_ response: PackHTTPResponse) { continuation?.resume(returning: response); continuation = nil }
}

@MainActor enum PackLibraryChecks {
    static func run() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/Workbench-PackChecks-" + UUID().uuidString)
        let domain = root.appendingPathComponent("Preferences").path
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try value() else { throw VoiceError.message("PACK_LIBRARY_CHECK_FAILED: " + name) }; count += 1
        }
        var opened = 0, copied = 0, saves = 0, removals = 0
        var credential: PackGitHubCredential?
        var services = PackLibraryServices()
        services.readCredential = { credential }
        services.saveCredential = { credential = $0; saves += 1 }
        services.removeCredential = { credential = nil; removals += 1 }
        services.openURL = { _ in opened += 1; return true }
        services.copyCode = { _ in copied += 1; return true }
        var beforeLibraryRead: ((DemoLibraryStore) throws -> Void)?
        services.readLibrary = { store in try beforeLibraryRead?(store); return try store.load() }
        services.contentSource = { _, _ in throw VoiceError.message("No network source is admitted by this fixture.") }
        let packsRoot = root.appendingPathComponent("Packs")
        let store = PackStore(root: packsRoot), source = try PackLibraryFixtureSource()
        let installed = try await store.install(from: source, appVersion: PackVersion("2.2.0")!)
        let model = PackLibraryModel(defaults: preferences, root: packsRoot, services: services)
        var captureContinuation: CheckedContinuation<ReadbackScreenshot, Error>?
        let readback = ReadbackModel(engine: RecognitionEngine(store: RecognitionConfigurationStore(defaults: preferences)),
            defaults: preferences, captureDisplay: { try await withCheckedThrowingContinuation { captureContinuation = $0 } },
            skillPacks: ReadbackSkillPackStore(root: root.appendingPathComponent("Legacy packs")),
            screenAccess: .fixed(true), microphoneAccess: { .authorized })
        defer { readback.shutdown(); model.cancel() }
        model.onSkillsChanged = { readback.setPackSkills($0) }
        model.refreshInstalled()
        try await wait { !model.packs.isEmpty }
        try check(model.login == nil && model.packs.count == 1 && model.transcriptSkills.count == 2 && readback.packSkills.count == 2
                  && !model.isBusy && opened == 0 && saves == 0, "verified installed content loads offline without sign-in, launch or download")
        let pack = model.packs[0], both = pack.entries.first { $0.id == "both" }!, notes = pack.entries.first { $0.id == "notes" }!
        let initialChoice = readback.selectedSkillChoice
        var refused = false
        do { try model.prepareSkill(both, from: pack, input: nil, readback: readback) } catch { refused = true }
        try check(refused && readback.selectedSkillChoice == initialChoice && model.preferredTranscriptSkillID == nil,
                  "dual-input skill cannot silently choose or change a tool")
        try check(try model.prepareSkill(notes, from: pack, input: nil, readback: readback) == .transcripts
                  && model.preferredTranscriptSkillID != nil && readback.selectedSkillChoice == initialChoice,
                  "transcript-only skill prepares only the existing History preference")
        refused = false
        do { try model.prepareSkill(notes, from: pack, input: .snapAndTalk, readback: readback) } catch { refused = true }
        try check(refused && readback.selectedSkillChoice == initialChoice, "incompatible explicit destination is refused")
        try check(try model.prepareSkill(both, from: pack, input: .snapAndTalk, readback: readback) == .snapAndTalk
                  && readback.sessionURL == nil && !readback.isRecording && !readback.isCapturing,
                  "explicit Snap and Talk choice prepares its skill without a session or capture")
        let session = root.appendingPathComponent("Personal session")
        _ = try readback.createSession(at: session, title: "Retained synthetic session")
        let frozenSkill = try Data(contentsOf: session.appendingPathComponent("SKILL.md"))
        let frozenReceipt = try Data(contentsOf: session.appendingPathComponent(ReadbackStore.skillPackReceiptName))
        let selectedBefore = readback.selectedSkillChoice
        try check(!readback.selectSkill("unavailable-fixture") && readback.selectedSkillChoice == selectedBefore,
                  "unavailable skill preserves the existing new-session choice")
        let capture = Task { await readback.captureNewSection(fromEditor: false) }
        try await wait { captureContinuation != nil }
        refused = false
        do { try model.prepareSkill(both, from: pack, input: .snapAndTalk, readback: readback) } catch { refused = true }
        try check(refused && readback.isCapturing && readback.selectedSkillChoice == selectedBefore,
                  "actual in-flight capture blocks a pack skill change without replacing its preference")
        captureContinuation?.resume(throwing: VoiceError.message("Synthetic capture ends without any screen or audio."))
        captureContinuation = nil; await capture.value
        var manifest = try ReadbackStore.load(from: session)
        let sectionID = UUID(), directory = "items/" + sectionID.uuidString.lowercased()
        try ReadbackStore.createPrivateDirectory(session.appendingPathComponent(directory))
        try ReadbackStore.writePrivate(Data("Synthetic screen".utf8), to: session.appendingPathComponent(directory + "/screen.png"))
        try ReadbackStore.writePrivate(Data("Saved narration".utf8), to: session.appendingPathComponent(directory + "/narration.txt"))
        manifest.sections.append(ReadbackSection(id: sectionID, capturedAt: Date(), displayName: "Synthetic", directory: directory,
            screenshot: directory + "/screen.png", audio: nil, originalTranscript: nil, transcript: directory + "/narration.txt",
            status: .ready, failure: nil, deletedAt: nil))
        try ReadbackStore.save(manifest, at: session); readback.openRecent(session)
        readback.transcriptWriter = { _, _ in throw VoiceError.message("Synthetic narration write failure") }
        readback.updateTranscript("Unsaved narration stays here", for: sectionID)
        refused = false
        do { try model.prepareSkill(both, from: pack, input: .snapAndTalk, readback: readback) } catch { refused = true }
        try check(refused && readback.hasUnsavedNarration && readback.transcriptDrafts[sectionID] == "Unsaved narration stays here"
                  && readback.selectedSkillChoice == selectedBefore, "failed narration save blocks a pack choice and retains the exact draft")
        try check(model.acceptLink(URL(string: "workbench://packs/add?source=example%2Fanother-pack")!)
                  && model.pendingSource == "https://github.com/example/another-pack" && !model.isBusy && opened == 0,
                  "deep link only prefills Add without connecting, downloading or starting")
        model.automaticUpdates = false; model.setBrand(pack.id)
        model.disconnect()
        try check(removals == 1 && model.packs.count == 1 && model.brandPackID == pack.id
                  && !preferences.bool(forKey: "packs.automaticUpdates.v1"), "disconnect retains installed content, appearance and update preference")
        model.setBrand(nil)
        try check(model.brandPackID == nil && preferences.string(forKey: "packs.appearance.v1") == nil, "Reset clears only workspace appearance")

        let library = DemoLibraryModel(store: DemoLibraryStore(directory: root.appendingPathComponent("Library")), copyText: { _ in 1 }, openURL: { _ in false })
        let file = root.appendingPathComponent("Saved.txt"), data = Data("  exact e\u{301}\r\nPersonal copy.  ".utf8)
        var writes = 0, choices = 0
        try check(!model.saveResource(data, title: "Personal copy", filename: "Saved.txt", library: library,
            chooseDestination: { _ in choices += 1; return nil }, write: { _, _ in writes += 1 }) && writes == 0 && library.resources.isEmpty,
            "Cancel exports nothing and creates no reference")
        try check(model.saveResource(data, title: "Personal copy", filename: "Saved.txt", library: library,
            chooseDestination: { _ in choices += 1; return file }, write: { bytes, url in writes += 1; try bytes.write(to: url) }),
            "successful export verifies bytes and commits its Library reference")
        try check(try Data(contentsOf: file) == data && library.resources.count == 1 && library.selected?.content == file.path
                  && model.savedResource == nil && writes == 1, "Library selects the exact saved original without opening it")
        let conflicting = root.appendingPathComponent("Reference retry.txt")
        let newer = try library.store.save(library.resources + [DemoResource(title: "Newer local record", content: "Preserve me")])
        try check(!model.saveResource(data, title: "Retry copy", filename: conflicting.lastPathComponent, library: library,
            chooseDestination: { _ in choices += 1; return conflicting }, write: { bytes, url in writes += 1; try bytes.write(to: url) })
                  && model.savedResource != nil && library.savingDisabled && Data(contentsOf: library.store.url) == newer,
                  "Library conflict keeps the exported file and newer records with reference-only recovery")
        try check(model.notice?.contains("Choose Add saved file to Library") == true
                  && model.notice?.contains("Resources → Library details") == true && model.notice?.contains("Reopen Workbench") == false
                  && library.storageFailure?.contains("Reopen Workbench") == true && library.savingDisabled,
                  "Packs offers its in-place file-reference retry while Library retains the original persistent diagnostic")
        let pending = model.savedResource!.id, beforeRetryWrites = writes, beforeRetryChoices = choices
        let reloaded = library
        let keptDraft = DemoResource(title: "Unfinished personal edit", content: "Keep this draft exactly")
        library.draft = keptDraft
        try check(!model.addSavedResource(to: library, reviewCurrentStore: true) && library.draft == keptDraft
                  && library.savingDisabled && model.savedResource?.id == pending && library.resources.count == 1
                  && model.notice?.contains("Finish the current Library review") == true,
                  "reference retry cannot discard a pending resource edit to reload the Library")
        library.draft = nil
        let incoming = root.appendingPathComponent("Incoming library.json")
        try DemoLibraryStore.encoded([keptDraft], portable: true).write(to: incoming)
        let reviewing = DemoLibraryModel(store: DemoLibraryStore(directory: root.appendingPathComponent("Import review")))
        reviewing.prepareImport(from: incoming)
        try check(reviewing.importReview != nil && !model.addSavedResource(to: reviewing, reviewCurrentStore: true)
                  && reviewing.importReview != nil && reviewing.resources.isEmpty && model.savedResource?.id == pending
                  && model.notice?.contains("Finish the current Library review") == true,
                  "reference retry cannot dismiss a pending import decision or add into its reviewed Library")
        try FileManager.default.moveItem(at: library.store.url, to: root.appendingPathComponent("Retained Library.json"))
        try check(!model.addSavedResource(to: library, reviewCurrentStore: true) && library.savingDisabled
                  && library.resources.count == 1 && model.savedResource?.id == pending && !FileManager.default.fileExists(atPath: library.store.url.path),
                  "missing saved Library remains missing and held instead of being replaced by one reference")
        try Data("corrupt synthetic Library".utf8).write(to: library.store.url)
        try check(!model.addSavedResource(to: library, reviewCurrentStore: true) && library.savingDisabled
                  && library.resources.count == 1 && model.savedResource?.id == pending,
                  "explicit reference retry preserves readable records and its pending file when current Library cannot decode")
        try newer.write(to: library.store.url)
        try Data(repeating: 120, count: data.count).write(to: conflicting)
        try check(!model.addSavedResource(to: reloaded, reviewCurrentStore: true) && model.savedResource?.id == pending && reloaded.resources.count == 1
                  && model.notice?.contains("contents changed") == true && model.notice?.contains("Choose Add saved file to Library") == false,
                  "same-sized changed export is not silently adopted by retry")
        try data.write(to: conflicting)
        try check(model.addSavedResource(to: reloaded, reviewCurrentStore: true) && reloaded.selected?.id == pending && reloaded.resources.count == 3 && !reloaded.savingDisabled
                  && writes == beforeRetryWrites && choices == beforeRetryChoices && Data(contentsOf: conflicting) == data,
                  "same-owner reference retry reviews current Library and uses the same file and identity without another export or chooser")
        let refusedFile = root.appendingPathComponent("Refused.txt")
        try check(!model.saveResource(data, title: "Refused export", filename: refusedFile.lastPathComponent, library: reloaded,
            chooseDestination: { _ in refusedFile }, write: { _, _ in throw VoiceError.message("Synthetic write refusal") })
                  && model.savedResource == nil && !FileManager.default.fileExists(atPath: refusedFile.path) && reloaded.resources.count == 3,
                  "failed export cannot create a Library reference or a false saved-file retry")
        try check(!model.saveResource(data, title: "Partial export", filename: refusedFile.lastPathComponent, library: reloaded,
            chooseDestination: { _ in refusedFile }, write: { bytes, url in try bytes.write(to: url); throw VoiceError.message("Synthetic post-write failure") })
                  && model.savedResource != nil && reloaded.resources.count == 3,
                  "verified file left by a post-write failure retains reference-only recovery")
        model.keepSavedFileOnly()
        try check(model.savedResource == nil && Data(contentsOf: refusedFile) == data && reloaded.resources.count == 3,
                  "Keep file only dismisses recovery without deleting or adding the exported original")

        // The commit can succeed before its separate readback fails. The cached UUID
        // then exists without a write hold, while disk no longer has that reference.
        // Explicit Retry must review disk even in this initially-unheld state.
        for fault in ["restored", "missing", "corrupt"] {
            let currentStore = DemoLibraryStore(directory: root.appendingPathComponent("Post-commit " + fault))
            let retained = DemoResource(title: "Retained " + fault, content: "Keep the current saved records")
            let baseline = try currentStore.save([retained])
            let currentLibrary = DemoLibraryModel(store: currentStore)
            let export = root.appendingPathComponent("Post-commit " + fault + ".txt")
            var sawCommittedReference = false
            beforeLibraryRead = { store in
                let persisted = try store.load()
                sawCommittedReference = persisted.count == 2 && persisted.contains { $0.kind == .file && $0.content == export.path }
                switch fault {
                case "restored": try baseline.write(to: store.url)
                case "missing": try FileManager.default.removeItem(at: store.url)
                default: try Data("corrupt post-commit fixture".utf8).write(to: store.url)
                }
                throw VoiceError.message("Synthetic final reference readback failure")
            }
            let saved = model.saveResource(data, title: "Post-commit " + fault, filename: export.lastPathComponent, library: currentLibrary,
                chooseDestination: { _ in choices += 1; return export }, write: { bytes, url in writes += 1; try bytes.write(to: url) })
            beforeLibraryRead = nil
            guard let retryID = model.savedResource?.id else { throw VoiceError.message("The post-commit fixture lost its saved export.") }
            let exportCount = writes, chooserCount = choices
            try check(!saved && sawCommittedReference && !currentLibrary.savingDisabled && currentLibrary.resources.count == 2
                      && currentLibrary.resources.contains(where: { $0.id == retryID }) && Data(contentsOf: export) == data
                      && model.notice?.contains("Synthetic final reference readback failure") == true,
                      "post-commit \(fault) readback failure leaves the exact cached UUID initially unheld")
            if fault == "restored" {
                currentLibrary.draft = keptDraft
                try check(!model.addSavedResource(to: currentLibrary, reviewCurrentStore: true) && currentLibrary.draft == keptDraft
                          && currentLibrary.resources.count == 2 && !currentLibrary.savingDisabled && Data(contentsOf: currentStore.url) == baseline,
                          "initially-unheld retry preserves an editor draft and does not reload or write beneath it")
                currentLibrary.draft = nil
                currentLibrary.prepareImport(from: incoming); currentLibrary.importChoices = [keptDraft.id]
                try check(currentLibrary.importReview != nil && !model.addSavedResource(to: currentLibrary, reviewCurrentStore: true)
                          && currentLibrary.importReview != nil && currentLibrary.importChoices == [keptDraft.id]
                          && currentLibrary.resources.count == 2 && Data(contentsOf: currentStore.url) == baseline,
                          "initially-unheld retry preserves the import decision and choices without reloading or writing")
                currentLibrary.cancelImport()
            } else {
                let faultyBytes = try currentStore.currentData()
                try check(!model.addSavedResource(to: currentLibrary, reviewCurrentStore: true) && currentLibrary.savingDisabled
                          && currentLibrary.storageFailure != nil && currentLibrary.resources.count == 2
                          && model.savedResource?.id == retryID && currentStore.currentData() == faultyBytes && Data(contentsOf: export) == data,
                          "initially-unheld \(fault) store establishes a persistent hold while retaining cached records and export")
                try baseline.write(to: currentStore.url)
            }
            try check(model.addSavedResource(to: currentLibrary, reviewCurrentStore: true) && !currentLibrary.savingDisabled
                      && currentLibrary.resources.count == 2 && currentLibrary.resources.contains(retained) && currentLibrary.selected?.id == retryID
                      && currentStore.load().filter { $0.id == retryID }.count == 1 && Data(contentsOf: export) == data
                      && writes == exportCount && choices == chooserCount && model.savedResource == nil,
                      "post-commit \(fault) retry reviews disk and commits one same-ID reference without another export or chooser")
        }
        model.remove(pack.id)
        try await wait { !model.isBusy && model.packs.isEmpty }
        try check(Data(contentsOf: session.appendingPathComponent("SKILL.md")) == frozenSkill
                  && Data(contentsOf: session.appendingPathComponent(ReadbackStore.skillPackReceiptName)) == frozenReceipt
                  && Data(contentsOf: file) == data && reloaded.resources.count == 3,
                  "removing owned downloads preserves immutable session and personal file/reference copies")
        let remaining = try await store.installed()
        try check(remaining.isEmpty, "Remove pack clears only its actual installed store")
        _ = installed

        let late = PackAuthorizationFixture(.challenge, code: "OLD-CODE")
        let current = PackAuthorizationFixture(code: "NEW-CODE")
        var authorizations = 0
        services.authorization = {
            authorizations += 1
            return try GitHubPackAuthorization(clientID: "Iv1.fixture", client: authorizations == 1 ? late : current)
        }
        let auth = PackLibraryModel(defaults: preferences, root: root.appendingPathComponent("Auth"), services: services)
        auth.connect(); try await wait { await late.waiting }
        auth.cancel(); auth.connect(); try await wait { auth.deviceCode == "NEW-CODE" }
        let launches = opened
        await late.resume(PackHTTPResponse(status: 200, body: Data("{\"device_code\":\"fixture-old\",\"user_code\":\"OLD-CODE\",\"verification_uri\":\"https://github.com/login/device\",\"expires_in\":60,\"interval\":1}".utf8)))
        try await Task.sleep(nanoseconds: 50_000_000)
        try check(auth.deviceCode == "NEW-CODE" && auth.connecting && opened == launches && saves == 0,
                  "cancelled late challenge neither opens a browser nor replaces the newer sign-in")
        auth.cancel(); auth.openDeviceLogin(copyCode: true)
        try check(!auth.isBusy && auth.deviceCode == nil && opened == launches && copied == 0,
                  "cancel retires code callbacks and leaves no actionable old challenge")
        let loginGate = PackAuthorizationFixture(.login)
        services.authorization = { try GitHubPackAuthorization(clientID: "Iv1.fixture", client: loginGate) }
        let lateLogin = PackLibraryModel(defaults: preferences, root: root.appendingPathComponent("Late login"), services: services)
        lateLogin.connect(); try await wait { await loginGate.waiting }
        lateLogin.cancel()
        await loginGate.resume(PackHTTPResponse(status: 200, body: Data("{\"login\":\"fixture-account\"}".utf8)))
        try await Task.sleep(nanoseconds: 50_000_000)
        try check(lateLogin.login == nil && saves == 0 && credential == nil, "late account reply cannot restore cancelled credentials or sign-in state")
        let expired = PackAuthorizationFixture(declined: true)
        services.authorization = { try GitHubPackAuthorization(clientID: "Iv1.fixture", client: expired) }
        let expiry = PackLibraryModel(defaults: preferences, root: root.appendingPathComponent("Expiry"), services: services)
        expiry.connect(); try await wait { !expiry.isBusy }
        try check(expiry.hasError && expiry.deviceCode == nil && expiry.login == nil && expiry.notice?.contains("expired") == true,
                  "expired device code ends with truthful retry guidance and no saved account")
        let accepted = PackAuthorizationFixture()
        services.authorization = { try GitHubPackAuthorization(clientID: "Iv1.fixture", client: accepted) }
        let success = PackLibraryModel(defaults: preferences, root: root.appendingPathComponent("Accepted"), services: services)
        success.connect(); try await wait { !success.isBusy }
        try check(success.login == "fixture-account" && credential != nil && saves == 1 && !success.hasError && success.deviceCode == nil,
                  "current completed authorization saves one credential and clears its transient challenge")
        success.disconnect()
        try check(credential == nil && success.login == nil, "explicit Disconnect removes only the authenticated account")
        print("PACK_LIBRARY_CHECKS_OK: \(count) checks; synthetic stores, repository, credentials and browser callbacks only")
    }

    private static func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !(await condition()) {
            guard Date() < deadline else { throw VoiceError.message("PACK_LIBRARY_CHECK_FAILED: synthetic operation timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
