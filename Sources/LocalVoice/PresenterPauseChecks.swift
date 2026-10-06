import AppKit
import Carbon
import Darwin
import PresenterKit

/// Production admission with old preferences and links, plus deterministic late transport work.
/// Every store/socket is disposable; clipboard, URL opening and host installation are spies.
enum PresenterPauseChecks {
    @MainActor static func run() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { throw VoiceError.message("Browser pause: \(label)") }
            checks += 1
        }
        let root = URL(fileURLWithPath: "/tmp/wb-presenter-pause-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let suite = root.appendingPathComponent("preferences").path
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let machine = UUID(), profile = UUID()
        defaults.set(true, forKey: "browser.enabled")
        defaults.set(machine.uuidString, forKey: "browser.machineID")
        var preferences = VoicePreferences()
        for id in VoicePreferences.shortcutIDs { var key = preferences.shortcut(id); key.enabled = false; preferences.setShortcut(key, for: id) }
        let chosen = VoiceShortcut(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(optionKey))
        preferences.presenterShortcut = chosen
        preferences.save(to: defaults); defaults.set(1, forKey: VoicePreferences.shortcutRevisionKey)
        var rawPreferences = try JSONSerialization.jsonObject(with: defaults.data(forKey: VoicePreferences.key)!) as! [String: Any]
        var rawShortcut = rawPreferences["presenterShortcut"] as! [String: Any]
        rawShortcut["futureAssignment"] = "Preserve this unknown saved field"
        rawPreferences["presenterShortcut"] = rawShortcut
        defaults.set(try JSONSerialization.data(withJSONObject: rawPreferences), forKey: VoicePreferences.key)
        let savedPreferences = defaults.persistentDomain(forName: suite)!
        let store = DemoLibraryStore(directory: root)
        var link = DemoResource(kind: .link, title: "Synthetic destination", content: "https://example.com/saved")
        link.browserTarget = BrowserTarget(profileID: profile, profileName: "Synthetic profile", machineID: machine)
        try store.save([link])
        let savedLibrary = try Data(contentsOf: store.url)
        let path = root.appendingPathComponent("paused.socket").path

        for launch in 1...2 {
            var copied: [String] = [], opened: [URL] = [], switches = 0, installs = 0
            let library = DemoLibraryModel(store: store, copyText: { copied.append($0); return copied.count },
                openURL: { opened.append($0); return true })
            library.switchBrowser = { _ in switches += 1 }
            let model = PresenterModel(library: library, defaults: defaults, socketPath: path, hostInstaller: { installs += 1 })
            model.onSwitch = { switches += 1 }
            model.refresh(); model.start(); model.enable()
            var replies: [PresenterMessage] = []
            model.activate(link.id) { replies.append($0) }
            try check(!model.enabled && !model.busy && installs == 0, "launch \(launch): old enabled preference and explicit setup cannot start")
            try check(!FileManager.default.fileExists(atPath: path) && !FileManager.default.fileExists(atPath: path + ".lock"), "launch \(launch): no listener or lock is created")
            for _ in 0..<2 {
                do { let fd = try PresenterSocket.connect(to: path); close(fd); throw VoiceError.message("Paused listener accepted a retry") }
                catch PresenterError.unavailable { }
            }
            try check(replies.count == 1 && replies[0].ok == false && replies[0].error == "unavailable", "direct activation ends once as unavailable")
            try check(model.message == BrowserIntegration.pausedMessage && model.destinations.first?.profileID == profile
                && model.destinations.first?.connected == false, "paused status keeps the saved destination inspectable")
            let loaded = VoicePreferences.load(from: defaults)
            try check(loaded.presenterShortcut == chosen && !loaded.enabledCombinations.contains(chosen.combination), "stored shortcut survives without reserving its key")
            try check(!AppDelegate.voiceShortcutCatalogue.contains { $0.0 == 4 } && VoicePreferences.shortcutIDs.contains(6), "catalogue excludes browser only; Read stays with H")
            let hotkeys = VoiceHotkeys()
            hotkeys.onKey = { _, _, _ in switches += 1 }
            hotkeys.register(loaded) // Only the saved, inactive browser key is enabled.
            hotkeys.dispatch(4, down: true, at: 1); hotkeys.dispatch(4, down: false, at: 2)
            hotkeys.unregister()
            library.selection = link.id
            library.copy(link)
            try check(link.primaryActionTitle == "Open in default browser" && library.performPrimaryAction(), "bound link has an explicit ordinary-open primary action")
            try check(copied == [link.content] && opened == [link.webURL!] && switches == 0, "Copy and Return/open never dispatch browser switching")
            try check(library.resources.first?.browserTarget == link.browserTarget && Data(contentsOf: store.url) == savedLibrary, "Copy/open leave exact saved metadata intact")
            model.stop()
            try check(NSDictionary(dictionary: savedPreferences).isEqual(to: defaults.persistentDomain(forName: suite)!), "launch \(launch): connection and shortcut preferences are unchanged")
        }
        let failedOpen = DemoLibraryModel(store: store, openURL: { _ in false })
        failedOpen.open(link)
        try check(failedOpen.error == "No application could open this link." && Data(contentsOf: store.url) == savedLibrary, "ordinary open failure is truthful and non-destructive")
        let portable = try DemoLibraryStore.decode(DemoLibraryStore.encoded(failedOpen.resources, portable: true))
        try check(portable.first?.content == link.content && portable.first?.browserTarget == nil, "portable export still includes URL without a foreign machine binding")
        let snapshot = SavedBrowserSettings(resources: failedOpen.resources + [
            DemoResource(title: "Unrelated prompt", content: "Never include this prompt"),
            DemoResource(kind: .link, title: "Ordinary link", content: "https://example.com/unbound")], defaults: defaults)
        try check(snapshot.hasSavedSettings && snapshot.shortcutSummary?.contains("inactive") == true,
            "old browser state exposes recovery with an inactive shortcut explanation")
        let exportURL = root.appendingPathComponent("saved-browser.json")
        failedOpen.exportSavedBrowserSettings(snapshot, chooseDestination: { nil })
        try check(!FileManager.default.fileExists(atPath: exportURL.path), "cancelled export writes no snapshot")
        failedOpen.exportSavedBrowserSettings(snapshot, chooseDestination: { root.appendingPathComponent("missing/settings.json") })
        try check(failedOpen.error?.contains("Could not export") == true && failedOpen.notice == nil, "failed export reports failure without success")
        failedOpen.exportSavedBrowserSettings(snapshot, chooseDestination: { exportURL })
        let exported = try JSONSerialization.jsonObject(with: Data(contentsOf: exportURL)) as! [String: Any]
        let exportedLinks = exported["boundLinks"] as! [[String: Any]]
        let exportedConnection = exported["connection"] as! [String: Any]
        try check(exported["format"] as? String == "workbench-saved-browser-settings"
            && exported["shortcutID"] as? Int == 4
            && NSDictionary(dictionary: exported["presenterShortcut"] as! [String: Any]).isEqual(to: rawShortcut),
            "recovery exports the exact raw id4 assignment, including unknown fields")
        try check(exportedConnection["browser.enabled"] as? Bool == true
            && exportedConnection["browser.machineID"] as? String == machine.uuidString
            && exportedLinks.count == 1 && exportedLinks[0]["id"] as? String == link.id.uuidString
            && exportedLinks[0]["content"] as? String == link.content
            && (exportedLinks[0]["browserTarget"] as? [String: String])?["profileID"] == profile.uuidString,
            "recovery keeps exact connection, bound URL, resource and profile IDs")
        try check(Set(exported.keys) == Set(["format", "version", "connection", "boundLinks", "shortcutID", "presenterShortcut"])
            && !String(decoding: Data(contentsOf: exportURL), as: UTF8.self).contains("Never include this prompt")
            && failedOpen.error == nil && failedOpen.notice?.contains("stays paused") == true,
            "recovery excludes unrelated content/preferences and reports successful retry")
        try check(try Data(contentsOf: store.url) == savedLibrary
            && NSDictionary(dictionary: savedPreferences).isEqual(to: defaults.persistentDomain(forName: suite)!),
            "cancelled, failed and successful exports leave exact saved preferences and Library bytes intact")
        for key in [chosen, VoicePreferences.legacyDefaults[4]!] {
            var old = preferences; old.presenterShortcut = key
            try check(VoicePreferences.movingUntouchedShortcuts(old).presenterShortcut == key, "even an unmigrated browser assignment stays exact")
        }
        let freshSuite = root.appendingPathComponent("fresh-preferences").path
        let freshDefaults = UserDefaults(suiteName: freshSuite)!
        defer { freshDefaults.removePersistentDomain(forName: freshSuite) }
        let freshLibrary = DemoLibraryModel(store: DemoLibraryStore(directory: root.appendingPathComponent("fresh")))
        let fresh = PresenterModel(library: freshLibrary, defaults: freshDefaults, socketPath: path)
        try check(!fresh.enabled && freshLibrary.resources.isEmpty && freshDefaults.object(forKey: "browser.enabled") == nil,
            "fresh launch creates no enabled connection or synthetic saved destination")
        fresh.stop()
        VoicePreferences().save(to: freshDefaults)
        try check(!SavedBrowserSettings(resources: [], defaults: freshDefaults).hasSavedSettings,
            "fresh preferences and a generated machine ID expose no browser recovery action")
        var shortcutOnly = VoicePreferences(); shortcutOnly.presenterShortcut = chosen
        shortcutOnly.save(to: freshDefaults)
        try check(SavedBrowserSettings(resources: [], defaults: freshDefaults).hasSavedSettings,
            "an old custom shortcut alone remains inspectable and exportable")
        freshDefaults.set(Data("{unreadable".utf8), forKey: VoicePreferences.key)
        let unreadable = SavedBrowserSettings(resources: [link], defaults: freshDefaults)
        let priorExport = try Data(contentsOf: exportURL)
        failedOpen.exportSavedBrowserSettings(unreadable, chooseDestination: { exportURL })
        try check(try Data(contentsOf: exportURL) == priorExport && failedOpen.error?.contains("could not be read") == true,
            "unreadable preference data cannot silently produce an incomplete recovery or overwrite a good export")

        // Retained protocol checks can use an isolated socket, never a production socket or installer.
        let active = PresenterModel(library: failedOpen, defaults: defaults,
            socketPath: root.appendingPathComponent("compat.socket").path, isolatedCompatibilityCheck: true)
        defer { active.stop() }
        active.start()
        var sockets: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw PresenterError.unavailable }
        defer { close(sockets[1]) }
        let peer = PresenterPeer(fd: sockets[0]); active.accept(peer)
        var hello = PresenterMessage(type: "hello"); hello.profileID = profile; hello.profileName = "Synthetic profile"
        active.receive(hello, from: peer)
        var switches = 0, completions: [PresenterMessage] = []
        active.onSwitch = { switches += 1 }
        active.activate(link.id) { completions.append($0) }
        try check(active.busy && switches == 1, "compatibility fixture has a real pending activation")
        active.stop()
        var late = PresenterMessage(type: "save"); late.title = "Late destination"; late.url = "https://example.com/late"
        active.receive(late, from: peer)
        let focusID = completions.first?.id ?? UUID()
        var focused = PresenterMessage(id: focusID, type: "focused"); focused.ok = true; focused.status = "focused"
        active.receive(focused, from: peer)
        active.activate(link.id) { completions.append($0) }
        active.start() // A new isolated generation cannot replay the previous connection's work.
        active.receive(late, from: peer); active.receive(focused, from: peer)
        try check(completions.count == 2 && completions.allSatisfy { $0.error == "unavailable" } && switches == 1 && !active.busy,
            "stop resolves once; late acknowledgement/save and activation cannot revive old work")
        try check(try Data(contentsOf: store.url) == savedLibrary, "late and replayed commands never write Library")
        active.stop()
        var rejected: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &rejected) == 0 else { throw PresenterError.unavailable }
        defer { close(rejected[1]) }
        let rejectedPeer = PresenterPeer(fd: rejected[0]); active.accept(rejectedPeer)
        try check(fcntl(rejected[0], F_GETFD) == -1 && errno == EBADF, "late accept closes the unstarted peer descriptor")
        rejectedPeer.stop()
        // A writer can fail before start() gives a reader responsibility for closing the fd.
        var failed: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &failed) == 0 else { throw PresenterError.unavailable }
        var unstarted: PresenterPeer? = PresenterPeer(fd: failed[0])
        close(failed[1])
        weak var released = unstarted
        unstarted?.send(PresenterMessage(type: "list")); unstarted = nil
        for _ in 0..<100 where released != nil { try await Task.sleep(nanoseconds: 5_000_000) }
        try check(released == nil, "failed writer releases its unstarted peer")
        try check(fcntl(failed[0], F_GETFD) == -1 && errno == EBADF, "writer failure followed by stop/deinit closes an unowned descriptor")
        print("BROWSER_PAUSE_CHECKS_OK: \(checks) checks; isolated stores, sockets and effect spies")
    }
}
