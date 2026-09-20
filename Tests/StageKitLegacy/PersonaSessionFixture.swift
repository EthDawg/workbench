import AppKit
import SwiftUI

/// Explicit native QA, never part of the ordinary test run. A disposable
/// persona library and bundled public artwork; no capture, cloud or hotkeys.
@MainActor
final class PersonaSessionFixture: NSObject, NSApplicationDelegate {
    private var library: PersonaLibrary!
    private var window: NSWindow!
    private var root: URL!

    func run() {
        NSApp.delegate = self; NSApp.setActivationPolicy(.regular)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkbenchOverlayFixture-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = PersonaLibrary(root: root)
        let bundled = Bundle.main.resourceURL!.appendingPathComponent("PersonaPortraits")
        let folder = FileManager.default.fileExists(atPath: bundled.path) ? bundled
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/PersonaPortraits")
        do {
            let first = try library.addImage(folder.appendingPathComponent("field-lead.png"), card: PersonaCardStyle(label: "Site manager"))
            let second = try library.addImage(folder.appendingPathComponent("front-desk.png"), card: PersonaCardStyle(label: "Service desk", background: InkColor(0.19, 0.32, 0.49)))
            let one = try library.createGroup(name: "Private walkthrough A", members: [first.id, second.id])
            let two = try library.createGroup(name: "Private walkthrough B", members: [first.id, second.id])
            var right = PersonaOverlayState(); right.width = 0.11; right.locked = true
            var left = right; left.x = 0.02
            try library.saveGroupLayout(one, overlays: [PersonaOverlayItem(personaID: first.id, placement: right), PersonaOverlayItem(personaID: second.id, placement: left)], publicLabel: nil)
            left.y = 0.98
            try library.saveGroupLayout(two, overlays: [PersonaOverlayItem(personaID: second.id, placement: left)], publicLabel: "Manager view")
            try library.savePreparedGroups([one, two]); library.prepareGroup(one)
        } catch { fatalError("Could not prepare isolated fixture: \(error)") }
        library.mayBeginInteraction = { true }
        let content = OverlayFixtureHome(library: library).frame(width: 860, height: 660)
        window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = "Overlay Review · disposable content"
        window.setContentSize(CGSize(width: 860, height: 660)); window.center(); window.isReleasedWhenClosed = false
        library.onShow = { [weak self] in self?.window.orderOut(nil) }
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(title: "Overlay Review")
        appMenu.addItem(withTitle: "Quit Overlay Review", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; main.addItem(appItem)
        let reviewItem = NSMenuItem(); let review = NSMenu(title: "Review")
        for (title, selector) in [("Show preparation", #selector(showPreparation)), ("Start prepared overlays", #selector(start)), ("Focus overlay controls", #selector(focus)), ("Hide all", #selector(pause)), ("Show again", #selector(resume)), ("Next set", #selector(next)), ("End overlays", #selector(end)), ("Save evidence snapshot", #selector(snapshot))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; review.addItem(item)
        }
        reviewItem.submenu = review; main.addItem(reviewItem); NSApp.mainMenu = main
        NSApp.finishLaunching(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        print("Overlay fixture storage: \(root.path)")
        NSApp.run()
    }
    @objc private func showPreparation() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func start() {
        do { try library.startOverlaySession(groupIDs: library.preparedGroupIDs, initialGroupID: library.preparedGroupIDs[0], softReveal: true) }
        catch { library.notice = error.localizedDescription; showPreparation() }
    }
    @objc private func focus() { library.focusOverlayControls() }
    @objc private func pause() { library.pauseOverlaySession() }
    @objc private func resume() { try? library.resumeOverlaySession() }
    @objc private func next() { library.performOverlayAction(.stepGroup(1)) }
    @objc private func end() { library.hideOverlay() }
    @objc private func snapshot() {
        let state = library.sessionState
        let windows = NSApp.windows.filter(\.isVisible).map { ["title": $0.title, "frame": NSStringFromRect($0.frame), "clickThrough": String($0.ignoresMouseEvents)] }
        let record: [String: Any] = ["phase": String(describing: state.phase), "groupCount": state.groups.count,
            "instances": state.instances.map { ["label": $0.label, "visible": String($0.visible), "locked": String($0.locked)] }, "windows": windows]
        try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("native-evidence.json"))
        print("Evidence: \(root.appendingPathComponent("native-evidence.json").path)")
    }
    func applicationWillTerminate(_ notification: Notification) { library.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct OverlayFixtureHome: View {
    @ObservedObject var library: PersonaLibrary
    @State private var showing = false
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Service walkthrough").font(.largeTitle.bold())
            Text("Disposable native review. Two prepared groups, no personal data.").foregroundStyle(.secondary)
            TextField("Click-through test: type here", text: $text).textFieldStyle(.roundedBorder)
            Button("Open Personas") { showing = true }
            Text("Use Review → Start prepared overlays, then change to another app. The cards and one click menu should remain available. Hide all preserves the session; End clears it.").fixedSize(horizontal: false, vertical: true)
            Spacer()
        }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity).workbenchTheme()
            .sheet(isPresented: $showing) { PersonaLibraryView(library: library) }
    }
}
