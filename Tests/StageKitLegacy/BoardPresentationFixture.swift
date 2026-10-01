import AppKit
import SwiftUI

/// Opt-in native QA only. No camera, global shortcuts, standard defaults or
/// application-support data are used. The normal test run never opens this UI.
@MainActor
final class BoardPresentationFixture: NSObject, NSApplicationDelegate {
    private let root: URL
    private let defaultsName = FileManager.default.temporaryDirectory.appendingPathComponent("WorkbenchFixture." + UUID().uuidString).path
    private let defaults: UserDefaults
    private let app: AppCoordinator
    private var window: NSWindow?
    private var presenter: DemoPresentation?

    override init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkbenchBoardPresentationFixture-" + UUID().uuidString)
        defaults = UserDefaults(suiteName: defaultsName)!
        let settings = SettingsStore(defaults: defaults)
        settings.value.onboardingComplete = true
        for action in Action.allCases {
            var shortcut = action.defaultShortcut; shortcut.enabled = false
            settings.value.shortcuts[action.rawValue] = shortcut
        }
        app = AppCoordinator(settings: settings, archiveURL: root.appendingPathComponent("boards.json"), embedded: true)
        app.demoScenes = DemoScenes(root: root.appendingPathComponent("Scenes"))
        super.init()
    }

    func run() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("Synthetic QA data: \(root.path)")
        NSApp.delegate = self
        NSApp.setActivationPolicy(.regular); NSApp.finishLaunching()
        let menu = NSMenu()
        let applicationItem = NSMenuItem(); menu.addItem(applicationItem)
        let applicationMenu = NSMenu(title: "Fixture")
        let quitItem = NSMenuItem(title: "Quit Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp; applicationMenu.addItem(quitItem); applicationItem.submenu = applicationMenu
        let viewItem = NSMenuItem(); menu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let fullScreenItem = NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(fullScreenItem); viewItem.submenu = viewMenu
        NSApp.mainMenu = menu
        app.start(); app.setShortcutsSuspended(true)
        let panel = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 660, height: 380),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Workbench · Synthetic board and presentation QA"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: BoardPresentationFixtureView(app: app,
            openBoard: { [weak self] in self?.openBoard() },
            present: { [weak self] mode in self?.present(mode) }))
        window = panel
        app.onOpenControls = { [weak self] in self?.window?.makeKeyAndOrderFront(nil) }
        panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        NSApp.run()
    }

    private func openBoard() {
        presenter?.end(); presenter = nil
        app.escape(); app.toggleBoard(.white)
        guard let canvas = app.canvases[app.currentID] else { return }
        let ink = [
            Annotation(tool: .text, color: .black, width: 1, points: [InkPoint(CGPoint(x: 90, y: 90))], text: "Synthetic board — top left", fontSize: 34),
            Annotation(tool: .arrow, color: .coral, width: 6, points: [InkPoint(CGPoint(x: 100, y: 180)), InkPoint(CGPoint(x: 420, y: 240))]),
            Annotation(tool: .highlighter, color: .amber, width: 24, points: [InkPoint(CGPoint(x: 100, y: 300)), InkPoint(CGPoint(x: 470, y: 300))]),
            Annotation(tool: .text, color: .blue, width: 1, points: [InkPoint(CGPoint(x: 90, y: canvas.bounds.height - 130))], text: "Bottom left · PNG must keep this orientation", fontSize: 24)
        ]
        app.history(for: app.currentID)?.clear()
        for annotation in ink { app.history(for: app.currentID)?.append(annotation) }
        app.canvasChanged()
    }

    private func present(_ mode: PresentationMode) {
        app.escape()
        if let presenter { presenter.bringForward(); return }
        var scene = DemoScene(background: "synthetic.png")
        scene.name = "Synthetic presentation"; scene.showsPhone = false
        let image = NSImage(size: CGSize(width: 1920, height: 1080), flipped: false) { rect in
            NSColor(srgbRed: 0.08, green: 0.15, blue: 0.24, alpha: 1).setFill(); rect.fill()
            ("Synthetic presentation" as NSString).draw(at: CGPoint(x: 300, y: 720), withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.white])
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping; paragraph.lineSpacing = 8
            ("Control–Command–F switches between window and fullscreen.\nThe scene and phone tile remain until End or Escape." as NSString)
                .draw(in: CGRect(x: 300, y: 350, width: 1320, height: 270), withAttributes: [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
            return true
        }
        let value = DemoPresentation(scene: scene, image: image, logo: nil, hand: nil, screen: NSScreen.main, root: root, mode: mode)
        value.onEnd = { [weak self] in self?.presenter = nil; self?.window?.makeKeyAndOrderFront(nil) }
        presenter = value; window?.orderOut(nil); value.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        presenter?.onEnd = nil; presenter?.end(); app.shutdown()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}

private struct BoardPresentationFixtureView: View {
    @ObservedObject var app: AppCoordinator
    let openBoard: () -> Void
    let present: (PresentationMode) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Synthetic native QA").font(.title2)
            Text("These samples use temporary data. No phone capture or global shortcuts are started.")
            Button("Open sample board", action: openBoard)
            BoardExportButtons(app: app)
            Text("Use the board palette’s share button to copy or save. Test Save → Cancel, then draw again. Done returns to these controls.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Present in window") { present(.windowed) }
                Button("Present full screen") { present(.fullScreen) }
            }
            if let notice = app.notice { Text(notice).font(.caption) }
            Button("Quit fixture") { NSApp.terminate(nil) }
        }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
    }
}
