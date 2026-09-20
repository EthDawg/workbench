import AppKit
import SwiftUI
import PresenterKit
import Darwin

enum PresenterChecks {
    @MainActor static func renderBrowserSetup(to output: URL) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wb-browser-render-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let suite = "workbench.browser-setup.render." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = PresenterModel(library: DemoLibraryModel(store: DemoLibraryStore(directory: root)), defaults: defaults)
        let setup = BrowserSetupModel(presenter: model, defaults: defaults)
        let file = root.appendingPathComponent("browser-setup.json"); try BrowserSetupPack.compound().data().write(to: file); setup.load(file)
        let view = NSHostingView(rootView: BrowserSetupView(setup: setup, presenter: model).background(Color(nsColor: .windowBackgroundColor)))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 720); view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw VoiceError.message("Browser setup bitmap unavailable") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw VoiceError.message("Browser setup PNG unavailable") }
        try png.write(to: output, options: .atomic)
        print("BROWSER_SETUP_UI_RENDER_OK")
    }

    @MainActor static func run() async throws {
        var passed = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw VoiceError.message("Presenter check failed: \(label)") }
            passed += 1; print("PASS: \(label)")
        }
        let root = URL(fileURLWithPath: "/tmp/wb-presenter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let suite = "workbench.presenter.check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let library = DemoLibraryModel(store: DemoLibraryStore(directory: root))
        let path = root.appendingPathComponent("socket").path
        let model = PresenterModel(library: library, defaults: defaults, socketPath: path)
        model.start()
        defer { model.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try check(model.enabled, "isolated native listener starts")
        let first = try PresenterSocket.connect(to: path), second = try PresenterSocket.connect(to: path)
        defer { close(first); close(second) }
        for fd in [first, second] { var timeout = timeval(tv_sec: 3, tv_usec: 0); setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) }
        func receive(_ fd: Int32) async throws -> PresenterMessage { try await Task.detached { try PresenterSocket.readMessage(fd) }.value }
        func exchange(_ message: PresenterMessage, _ fd: Int32) async throws -> PresenterMessage {
            try PresenterSocket.write(PresenterWire.encode(message), to: fd); return try await receive(fd)
        }
        let profileA = UUID(), profileB = UUID()
        let beforeHello = try await exchange(PresenterMessage(type: "list"), first)
        try check(beforeHello.ok == false, "unpaired connection cannot read saved destinations")
        var hello = PresenterMessage(type: "hello"); hello.profileID = profileA; hello.profileName = "Employee"
        let helloReply = try await exchange(hello, first)
        try check(helloReply.ok == true, "first profile pairs")
        var duplicate = PresenterMessage(type: "hello"); duplicate.profileID = profileA; duplicate.profileName = "Wrong copy"
        let duplicateReply = try await exchange(duplicate, second)
        try check(duplicateReply.error == "duplicateProfile", "duplicate active profile identity rejected")
        hello.id = UUID(); hello.profileID = profileB; hello.profileName = "Manager"; hello.capabilities = ["browserSetup1"]
        try check(try await exchange(hello, second).ok == true, "second profile independently pairs")
        var save = PresenterMessage(type: "save"); save.title = "Manager"; save.url = "https://demo.example/manager"
        let saved = try await exchange(save, second)
        guard let destinationID = saved.destinationID else { throw VoiceError.message("Missing saved destination") }
        try check(saved.ok == true && library.resources.count == 1, "browser saves into canonical resource library")
        try check(try await exchange(save, second).ok == false && library.resources.count == 1, "replay cannot duplicate a saved destination")
        var wrong = save; wrong.id = UUID(); wrong.destinationID = destinationID
        try check(try await exchange(wrong, first).error == "wrongProfile", "another profile cannot rebind the destination")
        var unsafe = save; unsafe.id = UUID(); unsafe.url = "https://user:password@demo.example/"
        try check(try await exchange(unsafe, second).error == "invalid", "embedded credentials rejected before persistence")
        unsafe.id = UUID(); unsafe.url = "https://demo.example/?token=secret"
        try check(try await exchange(unsafe, second).error == "invalid", "ephemeral query rejected before persistence")
        let portable = try DemoLibraryStore.decode(DemoLibraryStore.encoded(library.resources, portable: true))
        try check(portable[0].id == destinationID && portable[0].browserTarget == nil, "export keeps resource ID and strips machine binding")
        let merged = try DemoLibraryStore.merging(library.resources, into: [])
        try check(merged[0].browserTarget == nil, "import never accepts a foreign machine binding")
        let reloaded = DemoLibraryModel(store: library.store)
        try check(reloaded.resources.first?.browserTarget?.profileID == profileB, "local resource restart retains profile binding")
        let otherSuite = "workbench.presenter.other.\(UUID().uuidString)", otherDefaults: UserDefaults
        otherDefaults = UserDefaults(suiteName: otherSuite)!
        let other = PresenterModel(library: reloaded, defaults: otherDefaults); other.refresh()
        try check(other.destinations.isEmpty, "copied resource cannot silently route on another Mac")
        otherDefaults.removePersistentDomain(forName: otherSuite)
        var activation = PresenterMessage(type: "activate"); activation.destinationID = destinationID
        model.mayActivate = { false }
        try check(try await exchange(activation, first).error == "busy" && !model.busy, "shared lifecycle guard blocks browser activation during another interaction")
        model.mayActivate = { true }; activation.id = UUID()
        try PresenterSocket.write(PresenterWire.encode(activation), to: first)
        let focus = try await receive(second)
        try check(focus.type == "focus" && focus.destinationID == destinationID, "cross-profile request goes only to destination owner")
        try check((focus.expiresAt ?? 0) > Date().timeIntervalSince1970 * 1000, "focus command expires across sleep or queued work")
        var forged = PresenterMessage(id: focus.id, type: "focused"); forged.ok = true; forged.status = "focused"
        try PresenterSocket.write(PresenterWire.encode(forged), to: first)
        await Task.yield()
        try check(model.busy, "wrong profile cannot acknowledge another profile's focus")
        try PresenterSocket.write(PresenterWire.encode(forged), to: second)
        try check(try await receive(first).ok == true, "only confirmed target focus resolves activation")
        wrong.id = UUID(); wrong.url = "https://new-demo.example/manager"
        let updated = try await exchange(wrong, second)
        try check(updated.destinationID == destinationID && library.resources[0].content == wrong.url, "changed tenant update preserves stable destination identity")
        library.draft = library.resources.first
        save.id = UUID()
        try check(try await exchange(save, second).error == "busy", "open resource edit prevents conflicting browser writes")
        library.draft = nil
        let setupPack = BrowserSetupPack.compound(), setupPayload = try BrowserSetupPack.compound().payload(for: "manager")
        try check(model.connectedProfiles.count == 2 && model.connectedProfiles.filter(\.supportsSetup).map(\.id) == [profileB], "setup capability is scoped to the announcing profile")
        try check(await model.browserSetup(profileID: profileA, command: "setupPreview", payload: setupPayload).error == "setupUnsupported", "older extensions fail setup promptly without a browser command")
        let setupTask = Task { await model.browserSetup(profileID: profileB, command: "setupPreview", payload: setupPayload) }
        let preview = try await receive(second)
        try check(preview.type == "setupPreview" && preview.setup == setupPayload, "setup preview routes the exact chosen role only to its selected profile")
        try check((preview.expiresAt ?? 0) > Date().timeIntervalSince1970 * 1000, "setup commands have a bounded deadline")
        try check(await model.browserSetup(profileID: profileB, command: "setupLaunch", payload: setupPayload).error == "busy", "setup cannot interleave another native operation")
        var setupReply = PresenterMessage(id: preview.id, type: "setupResult"); setupReply.ok = true
        setupReply.setupResult = try JSONDecoder().decode(BrowserSetupResult.self, from: Data("{\"reviewToken\":\"f2360301-d342-474d-b52e-a011c2b8ec22\",\"create\":5,\"update\":0,\"unchanged\":0,\"conflicts\":0,\"root\":\"Local bar\",\"notes\":[]}".utf8))
        try PresenterSocket.write(PresenterWire.encode(setupReply), to: first)
        await Task.yield()
        try check(model.busy, "wrong profile cannot acknowledge setup review")
        try PresenterSocket.write(PresenterWire.encode(setupReply), to: second)
        let reviewed = await setupTask.value
        try check(reviewed.ok == true && reviewed.setupResult?.create == 5 && !model.busy, "correlated setup results release the busy state")
        let setupDefaults = UserDefaults(suiteName: suite)!
        let setupModel = BrowserSetupModel(presenter: model, defaults: setupDefaults)
        let packFile = root.appendingPathComponent("browser-setup.json"); try setupPack.data().write(to: packFile)
        setupModel.load(packFile); setupModel.assign("manager", to: profileB)
        let reopenedSetup = BrowserSetupModel(presenter: model, defaults: setupDefaults); reopenedSetup.load(packFile)
        try check(reopenedSetup.roles[profileB] == "manager" && reopenedSetup.selectedProfiles.count == 1, "profile-role assignment persists locally without exporting it")
        try check(!reopenedSetup.canApply, "reopening a pack never retains browser apply authority")
        let stoppedTask = Task { await model.browserSetup(profileID: profileB, command: "setupApply", payload: setupPayload, reviewToken: setupReply.setupResult?.reviewToken) }
        _ = try await receive(second)
        model.stop()
        try check(await stoppedTask.value.ok == false && !model.busy, "stopping resolves pending setup without replay or a stranded continuation")
        try check(!model.enabled && model.destinations.allSatisfy { !$0.connected }, "stop drops session connections while retaining resources")
        model.start()
        let restarted = try PresenterSocket.connect(to: path)
        hello.id = UUID()
        try check(try await exchange(hello, restarted).ok == true, "listener restarts and accepts a fresh profile connection")
        close(restarted); model.stop()
        var outside = library.resources[0]; outside.title = "Updated elsewhere"
        try library.store.save([outside])
        let newer = try Data(contentsOf: library.store.url)
        try check(!library.save(library.resources[0]) && library.error?.contains("changed outside") == true, "observed external edit blocks a stale in-memory save")
        try check(try Data(contentsOf: library.store.url) == newer, "conflicting save preserves the newer file exactly")
        let preserved = try Data(contentsOf: library.store.url)
        try Data("future-or-broken-library".utf8).write(to: library.store.url)
        let broken = DemoLibraryModel(store: library.store)
        try check(broken.savingDisabled && !broken.save(library.resources[0]), "unsupported library pauses writes")
        try check(try Data(contentsOf: library.store.url) == Data("future-or-broken-library".utf8), "invalid original library remains byte-for-byte intact")
        try preserved.write(to: library.store.url)
        print("PRESENTER_CHECKS_OK: \(passed) checks passed")
    }
}

/// Native dogfood with the actual bridge and picker but disposable data. Never
/// constructs AppModel or migrates user data. Registers only the Switch to key.
@MainActor final class PresenterFixtureDelegate: NSObject, NSApplicationDelegate {
    let root: URL
    var presenter: PresenterModel!
    var panel: PresenterPanelController!
    var window: NSWindow!
    let hotkeys = VoiceHotkeys()
    init(root: URL) { self.root = root }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let library = DemoLibraryModel(store: DemoLibraryStore(directory: root))
        let defaults = UserDefaults(suiteName: "workbench.presenter.fixture.\(root.lastPathComponent)")!
        presenter = PresenterModel(library: library, defaults: defaults)
        presenter.start()
        panel = PresenterPanelController(model: presenter, setup: { [weak self] in self?.window.makeKeyAndOrderFront(nil) })
        var keys = VoicePreferences()
        for id: UInt32 in [1, 2, 3] { var key = keys.shortcut(id); key.enabled = false; keys.setShortcut(key, for: id) }
        hotkeys.onKey = { [weak self] id, down in
            if id == 4 && down { self?.presenter.message = "Switch to shortcut received."; self?.panel.show() }
        }
        hotkeys.register(keys)
        if let failure = hotkeys.failures[4] { presenter.message = failure }
        presenter.onSwitch = { [weak self] in self?.panel.hide(); self?.window.orderOut(nil) }
        window = NSWindow(contentViewController: NSHostingController(rootView: PresenterFixtureView(model: presenter, show: { [weak self] in self?.panel.show() })))
        window.title = "Workbench · Synthetic presenter fixture"; window.setContentSize(NSSize(width: 580, height: 420))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]; window.isReleasedWhenClosed = false
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { panel.show(); return true }
    func applicationWillTerminate(_ notification: Notification) { hotkeys.unregister(); presenter.stop() }
}
private struct PresenterFixtureView: View {
    @ObservedObject var model: PresenterModel
    var show: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Presenter destinations").font(.largeTitle.weight(.semibold))
            Text("Synthetic acceptance fixture · isolated saved resources").foregroundStyle(.secondary)
            Button("Switch to…", action: show).buttonStyle(.borderedProminent)
            List(model.destinations, id: \.id) { item in Text(item.title + " · " + item.profileName) }
            if let message = model.message { Text(message).font(.caption) }
        }.padding(28).frame(minWidth: 520, minHeight: 350)
    }
}

/// Layout dogfood uses a private socket and synthetic profiles; it never registers
/// Chrome's native host or touches the installed Preview's preference suite.
@MainActor final class BrowserSetupFixtureDelegate: NSObject, NSApplicationDelegate {
    let root: URL
    private var presenter: PresenterModel!
    private var setup: BrowserSetupModel!
    private var window: NSWindow!
    private var descriptors: [Int32] = []
    init(root: URL) { self.root = root }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let defaults = UserDefaults(suiteName: "workbench.browser-setup.fixture.\(root.lastPathComponent)")!
            let library = DemoLibraryModel(store: DemoLibraryStore(directory: root))
            let socket = root.appendingPathComponent("socket").path
            presenter = PresenterModel(library: library, defaults: defaults, socketPath: socket); presenter.start()
            guard presenter.enabled else { throw VoiceError.message(presenter.message ?? "Fixture socket unavailable") }
            setup = BrowserSetupModel(presenter: presenter, defaults: defaults)
            let pack = BrowserSetupPack.compound(), file = root.appendingPathComponent("browser-setup.json")
            try pack.data().write(to: file); setup.load(file)
            for (name, role) in [("Demo · Manager", "manager"), ("Demo · Employee", "mobile")] {
                let fd = try PresenterSocket.connect(to: socket); descriptors.append(fd)
                var hello = PresenterMessage(type: "hello"); let id = UUID(); hello.profileID = id; hello.profileName = name; hello.capabilities = ["browserSetup1"]
                try PresenterSocket.write(PresenterWire.encode(hello), to: fd); setup.assign(role, to: id)
                // These are display-only peers; never claim browser application.
            }
            setup.notice = "Synthetic UI fixture. These are disposable display profiles, not real Chrome connections."
            window = NSWindow(contentViewController: NSHostingController(rootView: BrowserSetupView(setup: setup, presenter: presenter)))
            window.title = "Browser setup · Synthetic fixture"
            window.styleMask = [.titled, .closable, .miniaturizable]; window.isReleasedWhenClosed = false
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        } catch { fputs("Browser setup fixture: \(error.localizedDescription)\n", stderr); NSApp.terminate(nil) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        for fd in descriptors { close(fd) }; presenter?.stop()
        UserDefaults.standard.removePersistentDomain(forName: "workbench.browser-setup.fixture.\(root.lastPathComponent)")
    }
}
