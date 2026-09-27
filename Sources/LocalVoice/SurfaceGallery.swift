import AppKit
import ObjectiveC
import SwiftUI
import StageKit

/// `LocalVoice --render-surfaces DIR` draws the menu-bar quick panel in fixed states and the top
/// of every Home page at the default and minimum window sizes, then writes `index.html` listing
/// each entry and where it leads. It uses synthetic fixtures only: nothing is launched, and no
/// shortcut, microphone, screen capture, Keychain item or network request is used.
///
/// Each appearance renders in a child process whose home is a new temporary folder, so every
/// file store resolves there (`CFFIXED_USER_HOME`). cfprefsd ignores that variable, so the child
/// also keeps every preference in plist files beside that home; see `isolatePreferences`.
enum SurfaceGallery {
    static let passFlag = "--render-surfaces-pass"
    static let workPrefix = ".surface-pass-"
    /// Set only inside an isolated pass. Keychain readers then report that nothing is saved.
    nonisolated(unsafe) static var isRendering = false
    /// AppDelegate opens Home at 1180 × 800. Its 1050 × 730 minimum grows by the title bar.
    static let sizes: [(name: String, size: NSSize)] = [("default", NSSize(width: 1180, height: 800)), ("narrow", NSSize(width: 1050, height: 730))]
    /// Pages with no sidebar item. Settings → Your dictionary opens this one.
    static let extraPages = [("dictionary", "Your dictionary")]
    static let unknownRoute = "surface-gallery-unknown-route"

    struct Shot: Codable { var id: String; var title: String; var detail: String; var file: String; var width: Int; var height: Int }
    struct Page: Codable { var route: String; var title: String; var fallsThrough: Bool; var shots: [Shot] }
    /// `ran` marks a destination learned from the app's own code rather than the catalogue.
    struct Entry: Codable { var surface: String; var label: String; var leads: String; var route: String?; var ran = false }
    struct Listing: Codable { var title: String; var lines: [String] }
    struct Pass: Codable { var theme: String; var panels: [Shot]; var pages: [Page]; var entries: [Entry]; var menus: [Listing] }

    /// Parent process: the two appearances render at once in isolated passes, then the contact sheet.
    static func run(output: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        // The temporary homes sit in the output folder, named without symbolic links: Packs refuses
        // a storage path through one, such as /tmp or the /var of the system temporary folder.
        guard let executable = Bundle.main.executableURL, let real = realpath(output.path, nil) else {
            throw VoiceError.message("LocalVoice could not prepare \(output.path).")
        }
        let output = URL(fileURLWithPath: String(cString: real), isDirectory: true); free(real)
        var running: [(theme: String, process: Process, root: URL)] = []
        defer { for pass in running { if pass.process.isRunning { pass.process.terminate() }; try? fm.removeItem(at: pass.root) } }
        for theme in ["light", "dark"] {
            let root = output.appendingPathComponent(workPrefix + UUID().uuidString, isDirectory: true)
            let home = root.appendingPathComponent("home", isDirectory: true), temporary = root.appendingPathComponent("tmp", isDirectory: true)
            for folder in [home, preferences(home: home), temporary] {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let pass = Process()
            pass.executableURL = executable
            // A fixed language, region and time zone keep text and dates identical between runs.
            pass.arguments = [passFlag, output.path, theme, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            var environment = ProcessInfo.processInfo.environment
            environment["CFFIXED_USER_HOME"] = home.path; environment["HOME"] = home.path
            environment["TMPDIR"] = temporary.path + "/"; environment["TZ"] = "UTC"
            pass.environment = environment
            running.append((theme, pass, root))
            try pass.run()
        }
        var passes: [Pass] = []
        for (theme, pass, _) in running {
            pass.waitUntilExit()
            let result = output.appendingPathComponent("pass-\(theme).json")
            defer { try? fm.removeItem(at: result) }
            guard pass.terminationStatus == 0, let data = try? Data(contentsOf: result) else {
                throw VoiceError.message("The \(theme) surface pass failed with status \(pass.terminationStatus).")
            }
            passes.append(try JSONDecoder().decode(Pass.self, from: data))
        }
        let flags = try SurfaceIndex(passes: passes).write(to: output)
        let renders = passes.reduce(0) { $0 + $1.panels.count + $1.pages.reduce(0) { $0 + $1.shots.count } }
        print("SURFACE_GALLERY_OK: \(renders) renders, \(passes[0].entries.count) entries, \(flags) flags in \(output.path)")
    }

    /// Child process. It runs on the main thread outside any dispatch job, so SwiftUI tasks can
    /// finish while a render settles.
    @MainActor static func runPass(_ arguments: [String]) -> Int32 {
        do {
            guard arguments.count >= 2, ["light", "dark"].contains(arguments[1]) else {
                throw VoiceError.message("Run --render-surfaces OUTPUT_DIRECTORY; it starts the isolated passes itself.")
            }
            let output = URL(fileURLWithPath: arguments[0], isDirectory: true)
            let pass = try SurfacePass(theme: arguments[1], output: output)
            let result = try pass.render(to: output)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: output.appendingPathComponent("pass-\(arguments[1]).json"))
            return 0
        } catch { fputs("Surface gallery: \(error.localizedDescription)\n", stderr); return 1 }
    }

    /// Refuses to build any model unless the home and Application Support resolve inside the
    /// temporary folder the parent created for this pass.
    static func verifiedHome(output: URL) throws -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let root = home.resolvingSymlinksInPath().deletingLastPathComponent()
        guard let fixed = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              URL(fileURLWithPath: fixed).resolvingSymlinksInPath().path == home.resolvingSymlinksInPath().path, home.lastPathComponent == "home",
              root.lastPathComponent.hasPrefix(workPrefix), root.deletingLastPathComponent().path == output.resolvingSymlinksInPath().path,
              Workbench.supportDirectory(component: "LocalVoice").path.hasPrefix(home.path + "/") else {
            throw VoiceError.message("Surface passes run only inside the temporary home that --render-surfaces creates.")
        }
        return home
    }

    /// Plist files for this pass. They sit beside the temporary home, not in its
    /// Library/Preferences: cfprefsd maps a path there to the person's real domain of that name.
    static func preferences(home: URL) -> URL { home.deletingLastPathComponent().appendingPathComponent("preferences", isDirectory: true) }

    /// A preferences suite backed by a plist file in this pass's folder. It fails unless a write
    /// actually lands there.
    static func isolatedDefaults(_ name: String, home: URL) throws -> UserDefaults {
        let file = preferences(home: home).appendingPathComponent(name)
        guard let defaults = UserDefaults(suiteName: file.path) else { throw VoiceError.message("Could not isolate \(name) preferences.") }
        defaults.set(true, forKey: "surfaceGallery.isolated"); defaults.synchronize()
        guard FileManager.default.fileExists(atPath: file.path + ".plist") else { throw VoiceError.message("Could not isolate \(name) preferences.") }
        return defaults
    }

    /// An unbundled LocalVoice keeps `UserDefaults.standard` in the person's real
    /// ~/Library/Preferences/LocalVoice.plist whatever the home directory says. Answer every
    /// request for it with this pass's own plist, which cannot see that real domain.
    static func isolatePreferences(home: URL, appearance: String) throws {
        let isolated = try isolatedDefaults("standard", home: home)
        guard let method = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults")) else {
            throw VoiceError.message("Could not isolate preferences.")
        }
        let replacement: @convention(block) (AnyObject) -> UserDefaults = { _ in isolated }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["appearance"] = appearance
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        guard UserDefaults.standard === isolated, UserDefaults.standard.string(forKey: "appearance") == appearance else {
            throw VoiceError.message("Could not isolate preferences.")
        }
    }
}

/// One appearance: fixtures, renders and the entry catalogue.
@MainActor private final class SurfacePass {
    let theme: String
    let home: URL
    let model: AppModel
    let stage: StageKitController
    let readback: ReadbackModel
    let sessionReadback: ReadbackModel
    let keyboard: KeyboardCoachModel
    /// Supplies the app's own shortcut catalogue. It registers nothing unless launched.
    private let shell = AppDelegate()
    /// Routes passed to the panel's `open`, and other actions, while a menu item runs.
    private var opened: [String] = []
    private var actions: [String] = []
    private var menuEntries: [SurfaceGallery.Entry] = []

    init(theme: String, output: URL) throws {
        self.theme = theme
        home = try SurfaceGallery.verifiedHome(output: output)
        try SurfaceGallery.isolatePreferences(home: home, appearance: theme == "dark" ? "Dark" : "Light")
        SurfaceGallery.isRendering = true
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        let stageDefaults = try SurfaceGallery.isolatedDefaults("StageKit", home: home)
        // Never look for a legacy StageMark preferences domain.
        stageDefaults.set(true, forKey: "legacyStagePreferencesSeeded.v1")
        let preferences = VoicePreferences.load(reserving: StageShortcutSettings.migrationReservations(defaults: stageDefaults))
        model = AppModel(preferences: preferences)
        // Set before the initialiser's prepare() task runs, so no speech model is loaded or downloaded.
        model.ready = true
        model.accessibilityGranted = false
        model.history = SurfacePass.history
        model.transcript = SurfacePass.history[0].text; model.rawTranscript = model.transcript
        let noCapture: @MainActor () async throws -> ReadbackScreenshot = { throw ReadbackError.message("The surface gallery never captures the screen.") }
        let noSpeech: @MainActor (URL) async throws -> String = { _ in throw ReadbackError.message("The surface gallery never transcribes audio.") }
        readback = ReadbackModel(engine: model.engine, captureDisplay: noCapture, transcribeAudio: noSpeech)
        let session = try SurfacePass.makeSession(in: home)
        let sessionDefaults = try SurfaceGallery.isolatedDefaults("SnapSession", home: home)
        sessionDefaults.set([session.path], forKey: "readback.recentSessionPaths.v1")
        sessionReadback = ReadbackModel(engine: model.engine, defaults: sessionDefaults, captureDisplay: noCapture, transcribeAudio: noSpeech)
        stage = StageKitController(reserving: preferences.enabledCombinations, defaults: stageDefaults)
        stage.useSharedActivityControls()
        let model = model
        stage.mayBeginInteraction = { model.phase == .idle && !model.rendering }
        stage.mayBeginDrawing = { WorkbenchDrawingAdmission.allows(phase: model.phase, suspended: false, capturingScreen: false, terminating: false) }
        shell.model = model; shell.stage = stage
        keyboard = KeyboardCoachModel(entries: shell.shortcutEntries(), update: { _, _ in "The surface gallery does not save shortcuts." },
                                      suspend: { _ in }, probe: { _ in nil })
        model.onShowPresenter = { [weak self] in self?.actions.append("Opens the Switch to panel") }
    }

    func render(to output: URL) throws -> SurfaceGallery.Pass {
        var panels: [SurfaceGallery.Shot] = []
        for state in panelStates() {
            state.apply()
            let rep = try renderPanel(state.readback)
            panels.append(try save(rep, id: state.id, title: state.title, detail: state.detail, file: "panel-\(state.id)-\(theme).png", to: output))
            state.reset()
        }
        var pages = SurfacePass.pages.map { SurfaceGallery.Page(route: $0.0, title: $0.1, fallsThrough: false, shots: []) }
        for (name, size) in SurfaceGallery.sizes {
            let window = homeWindow(size: size)
            defer { window.contentViewController = nil; window.close() }
            let fallback = name == "default" ? SurfacePass.contentPixels(try renderPage(SurfaceGallery.unknownRoute, in: window).0) : nil
            for index in pages.indices {
                let (rep, drawn) = try renderPage(pages[index].route, in: window)
                if let fallback { pages[index].fallsThrough = SurfacePass.contentPixels(rep) == fallback }
                pages[index].shots.append(try save(rep, id: name, title: "\(name == "default" ? "Default" : "Minimum") window, \(Int(drawn.width)) × \(Int(drawn.height)) pt",
                                                   detail: "", file: "page-\(pages[index].route)-\(name)-\(theme).png", to: output))
            }
        }
        let listings = menus()
        return SurfaceGallery.Pass(theme: theme, panels: panels, pages: pages, entries: entries() + menuEntries, menus: listings)
    }

    // MARK: Fixtures

    static let history: [Transcript] = [
        Transcript(id: UUID(uuidString: "5D1C0A1E-0000-4000-8000-000000000001")!, date: Date(timeIntervalSince1970: 1_789_546_320),
                   text: "Send Sam the revised agenda before the Thursday review and ask which slides need the new numbers.", seconds: 9, cleanupMethod: "Light cleanup"),
        Transcript(id: UUID(uuidString: "5D1C0A1E-0000-4000-8000-000000000002")!, date: Date(timeIntervalSince1970: 1_789_488_300),
                   text: "Book the quiet room for the design critique.", seconds: 4, cleanupMethod: "Light cleanup"),
        Transcript(id: UUID(uuidString: "5D1C0A1E-0000-4000-8000-000000000003")!, date: Date(timeIntervalSince1970: 1_789_378_200),
                   text: "The demo starts with the overview, then the workspace, then the finished deck.", seconds: 7, cleanupMethod: "Original")]

    /// A three-section Snap & Talk session in the temporary home, opened only as a recent session.
    static func makeSession(in home: URL) throws -> URL {
        let root = home.appendingPathComponent("Snap & Talk/Synthetic walkthrough", isDirectory: true)
        var manifest = try ReadbackStore.create(at: root, title: "Synthetic walkthrough")
        for (index, title) in ["Start with the overview", "Choose the right workspace", "Share the finished work"].enumerated() {
            let id = UUID(uuidString: "5D1C0A1E-0000-4000-8000-00000000010\(index)")!
            let directory = "items/\(id.uuidString.lowercased())"
            try ReadbackStore.createPrivateDirectory(root.appendingPathComponent(directory))
            let section = ReadbackSection(id: id, capturedAt: Date(timeIntervalSince1970: 1_789_546_320 + Double(index * 60)), displayName: "Synthetic display",
                directory: directory, screenshot: directory + "/screen.png", audio: directory + "/narration.wav",
                originalTranscript: directory + "/narration-original.txt", transcript: directory + "/narration.txt", status: .ready, failure: nil, deletedAt: nil)
            for path in [section.screenshot, section.audio!, section.originalTranscript!, section.transcript!] {
                try ReadbackStore.writePrivate(Data(title.utf8), to: root.appendingPathComponent(path))
            }
            manifest.sections.append(section)
        }
        try ReadbackStore.save(manifest, at: root)
        return root
    }

    struct PanelState { var id, title, detail: String; var readback: ReadbackModel; var apply: () -> Void = {}; var reset: () -> Void = {} }

    /// Only the voice-owned states. Drawing, presenting, personas and the timer need live StageKit
    /// windows or device capture, so the index lists them as not rendered.
    func panelStates() -> [PanelState] {
        let model = model
        return [
            PanelState(id: "idle", title: "Idle", detail: "Speech ready, no session, nothing running.", readback: readback),
            PanelState(id: "speech-not-ready", title: "Speech not ready", detail: "First run while the on-device model prepares.", readback: readback,
                       apply: { model.ready = false; model.preparing = true; model.modelMessage = "Preparing speech · first setup may take a few minutes" },
                       reset: { model.ready = true; model.preparing = false; model.modelMessage = "Preparing local speech…" }),
            PanelState(id: "dictating", title: "Dictating", detail: "Recording for 14 seconds.", readback: readback,
                       apply: { model.phase = .recording; model.elapsed = 14 }, reset: { model.phase = .idle; model.elapsed = 0 }),
            PanelState(id: "snap-session", title: "Snap & Talk session", detail: "A session with three captures.", readback: sessionReadback),
            PanelState(id: "reading", title: "Reading", detail: "Read aloud playing.", readback: readback,
                       apply: { model.playing = true }, reset: { model.playing = false }),
            PanelState(id: "clipboard", title: "Clipboard receipt", detail: "A 42-word transcript copied and still on the clipboard.", readback: readback,
                       apply: { model.clipboardReceipt.record(outcome: .init(message: "Copied to the clipboard.", clipboardChangeCount: NSPasteboard.general.changeCount,
                                                                             wasPasted: false, destinationName: nil), wordCount: 42) },
                       reset: { model.clipboardReceipt.clear() }),
            PanelState(id: "microphone-denied", title: "Microphone denied", detail: "The error a denied microphone leaves in the panel.", readback: readback,
                       apply: { model.error = "Microphone access is off. Open System Settings → Privacy & Security → Microphone and allow Workbench." },
                       reset: { model.error = nil })]
    }

    // MARK: Rendering

    func quickPanel(_ readback: ReadbackModel) -> WorkbenchQuickPanel {
        WorkbenchQuickPanel(model: model, stage: stage, readback: readback, keyboard: keyboard, receipts: model.clipboardReceipt,
                            open: { [weak self] route in self?.opened.append(route) }, draw: {}, snap: {}, present: {}, timer: {}, personas: {})
    }

    /// The popover's own material is not drawn; the panel sits on the window background.
    func renderPanel(_ readback: ReadbackModel) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: quickPanel(readback).background(Color(nsColor: .windowBackgroundColor)))
        let window = offscreenWindow(size: host.fittingSize, styleMask: [.borderless])
        window.contentView = host
        settle(host)
        window.setContentSize(host.fittingSize)
        settle(host, seconds: 0.05)
        defer { window.contentView = nil; window.close() }
        return try snapshot(host)
    }

    /// One Home window per size, set up like AppDelegate's. As in the app, pages change inside it
    /// (Home asks macOS for the login item status each time it is created, which can be slow).
    func homeWindow(size: NSSize) -> NSWindow {
        let window = offscreenWindow(size: size, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.contentViewController = NSHostingController(rootView: WorkbenchHome(model: model, stage: stage, keyboard: keyboard, readback: readback))
        window.setContentSize(size)
        return window
    }

    /// The page for `route`, captured with the window buttons.
    func renderPage(_ route: String, in window: NSWindow) throws -> (NSBitmapImageRep, NSSize) {
        model.page = route
        let frame = window.contentView?.superview ?? window.contentView!
        settle(frame)
        return (try snapshot(frame), frame.bounds.size)
    }

    func offscreenWindow(size: NSSize, styleMask: NSWindow.StyleMask) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: styleMask, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
        return window
    }

    /// Lets layout, `onAppear` and SwiftUI tasks finish. The window is never ordered on screen.
    func settle(_ view: NSView, seconds: TimeInterval = 0.3) {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.02)))
        } while Date() < deadline
        view.layoutSubtreeIfNeeded()
    }

    /// Draws the window's layer tree, as the screen would. `cacheDisplay` misses SwiftUI content
    /// inside scroll views. A layer render gets it, except where a scroll view shows its document
    /// through a portal (its source layer is transparent), so those documents are drawn again.
    func snapshot(_ root: NSView) throws -> NSBitmapImageRep {
        root.window?.display()
        let scale = root.window?.backingScaleFactor ?? 2, bounds = root.bounds
        guard root.layer != nil, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw VoiceError.message("Could not allocate a render.")
        }
        context.scaleBy(x: scale, y: scale)
        func draw(_ view: NSView, in rect: NSRect) {
            guard let layer = view.layer else { return }
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY)
            if view.isFlipped { context.translateBy(x: 0, y: rect.height); context.scaleBy(x: 1, y: -1) }
            layer.render(in: context)
            context.restoreGState()
        }
        func clipViews(_ view: NSView) -> [NSClipView] { ((view as? NSClipView).map { [$0] } ?? []) + view.subviews.flatMap(clipViews) }
        func transparent(_ view: NSView) -> Bool {
            var layer = view.layer
            while let current = layer, current !== root.layer {
                if current.isHidden || current.opacity == 0 { return true }
                layer = current.superlayer
            }
            return false
        }
        draw(root, in: SurfacePass.unflipped(root.bounds, of: root, in: root))
        for clip in clipViews(root) where !clip.isHiddenOrHasHiddenAncestor {
            guard let document = clip.documentView, transparent(document) else { continue }
            context.saveGState()
            context.clip(to: SurfacePass.unflipped(clip.bounds, of: clip, in: root))
            draw(document, in: SurfacePass.unflipped(document.bounds, of: document, in: root))
            context.restoreGState()
        }
        guard let image = context.makeImage() else { throw VoiceError.message("Could not finish a render.") }
        return NSBitmapImageRep(cgImage: image)
    }

    /// A view's rectangle in the root's bottom-left coordinates, which the bitmap context uses.
    static func unflipped(_ rect: NSRect, of view: NSView, in root: NSView) -> NSRect {
        var converted = view.convert(rect, to: root)
        if root.isFlipped { converted.origin.y = root.bounds.height - converted.maxY }
        return converted
    }

    func save(_ rep: NSBitmapImageRep, id: String, title: String, detail: String, file: String, to output: URL) throws -> SurfaceGallery.Shot {
        guard let png = rep.representation(using: .png, properties: [:]) else { throw VoiceError.message("Could not encode \(file).") }
        try png.write(to: output.appendingPathComponent(file), options: .atomic)
        return .init(id: id, title: title, detail: detail, file: file, width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    /// Pixels right of the 215-point sidebar and its divider. A route whose page matches the
    /// unknown route's page has no content of its own.
    static func contentPixels(_ rep: NSBitmapImageRep) -> Data {
        let bytes = rep.bitsPerPixel / 8, start = Int((216 * CGFloat(rep.pixelsWide) / SurfaceGallery.sizes[0].size.width).rounded()) * bytes
        var data = Data()
        guard let base = rep.bitmapData, !rep.isPlanar else { return data }
        for row in 0..<rep.pixelsHigh { data.append(base + row * rep.bytesPerRow + start, count: rep.pixelsWide * bytes - start) }
        return data
    }

    // MARK: Entries

    static let pages: [(String, String)] = WorkbenchHome.navItems.map { ($0.0, $0.1) } + SurfaceGallery.extraPages

    /// StageKit menu items that open a page, as AppDelegate wires StageKit's callbacks.
    static let stageLinks = ["Drawing Controls…": "annotate", "Keyboard Shortcuts…": "shortcuts", "Prepare Personas…": "present"]

    /// Native option menus as the panel builds them. Items the panel adds itself are run with
    /// recording closures to learn their destination; StageKit items are listed, never run.
    func menus() -> [SurfaceGallery.Listing] {
        let panel = quickPanel(readback)
        var listings = [SurfaceGallery.Listing(title: "Dictate · Options (SwiftUI menu, listed from its source)", lines:
            ["Destination"] + DeliveryMode.allCases.map { "  " + $0.rawValue } + ["Text Style"] + CleanupStyle.allCases.map { "  " + $0.rawValue }
            + ["---", "Recent Transcripts… → history", "Dictation Settings… → dictate"])]
        for tool in WorkbenchControlTool.allCases {
            guard let menu = panel.nativeOptions(tool) else { continue }
            let title = "\(tool.title) · \(tool == .annotate ? "Tools" : "Options")"
            listings.append(.init(title: title, lines: lines(menu, depth: 0, path: title)))
        }
        return listings
    }

    func lines(_ menu: NSMenu, depth: Int, path: String) -> [String] {
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu.items.flatMap { item -> [String] in
            let indent = String(repeating: "  ", count: depth)
            if item.isSeparatorItem { return [indent + "---"] }
            var line = indent + (item.state == .on ? "✓ " : "") + item.title
            if let key = SurfacePass.keyLabel(item) { line += "  \(key)" }
            if !item.isEnabled { line += "  (disabled)" }
            let label = "\(path) · \(item.title)"
            if item is ToolbarMenuAction, let action = item.action {
                opened.removeAll(); actions.removeAll()
                NSApp.sendAction(action, to: item.target, from: item)
                let route = opened.first, leads = route.map { "Page: \($0)" } ?? actions.first ?? "No effect"
                line += "  → " + (route ?? leads)
                menuEntries.append(.init(surface: "Menu-bar panel", label: label, leads: leads, route: route, ran: true))
            } else if let route = SurfacePass.stageLinks[item.title] {
                line += "  → \(route)"
                menuEntries.append(.init(surface: "Menu-bar panel", label: label, leads: "Page: \(route)", route: route))
            }
            return [line] + (item.submenu.map { lines($0, depth: depth + 1, path: label) } ?? [])
        }
    }

    static func keyLabel(_ item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        let mask = item.keyEquivalentModifierMask
        return [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { mask.contains($0.0) }.map(\.1).joined() + item.keyEquivalent.uppercased()
    }

    func entries() -> [SurfaceGallery.Entry] {
        typealias E = SurfaceGallery.Entry
        func page(_ surface: String, _ label: String, _ route: String) -> E { E(surface: surface, label: label, leads: "Page: \(route)", route: route) }
        func action(_ surface: String, _ label: String, _ text: String) -> E { E(surface: surface, label: label, leads: text, route: nil) }
        let panel = "Menu-bar panel", home = "Home page", menu = "App menus", other = "Keys and handoffs"
        var list: [E] = [action(panel, "Floating Toolbar switch", "Shows or hides the floating toolbar")]
        for tool in WorkbenchControlTool.allCases {
            switch tool {
            case .dictate:
                list += [action(panel, "Dictate", "Starts or finishes dictation into the app that was in front"),
                         page(panel, "Dictate · Options · Recent Transcripts…", "history"), page(panel, "Dictate · Options · Dictation Settings…", "dictate"),
                         action(panel, "Dictate · Options · Destination and Text Style", "Changes the saved dictation settings")]
            case .read:
                list += [page(panel, "Read, when nothing is playing", "speak"), action(panel, "Read, while reading · Stop or Cancel", "Pauses, resumes, stops or cancels the reading")]
            case .snap:
                list += [action(panel, "Snap & Talk, with a ready session", "Captures the display under the pointer and starts narration"),
                         page(panel, "Snap & Talk, without a session or access", "readback"), page(panel, "Snap & Talk · Set Up or N · Review", "readback")]
            case .annotate:
                list += [action(panel, "Draw", "Starts drawing on screen"), action(panel, "Draw · Tools", "Native menu, listed below")]
            case .present:
                list += [action(panel, "Present, with a scene selected", "Starts the scene, or shows its live controls"),
                         page(panel, "Present, without a scene", "present"), action(panel, "Present · Options", "Native menu, listed below")]
            case .persona:
                list += [action(panel, "Persona Overlay", "Shows the prepared persona, or its live controls"),
                         page(panel, "Persona Overlay, with nothing prepared", "present"), action(panel, "Persona Overlay · Options", "Native menu, listed below")]
            case .timer:
                list += [action(panel, "Timer", "Starts the saved timer, or shows the running one"), action(panel, "Timer · Options", "Native menu, listed below")]
            }
        }
        list += [action(panel, "Shortcut label on each row", "Edits that shortcut inside the panel"),
                 page(panel, "Open Workbench", "home"), page(panel, "Settings", "settings"), page(panel, "Shortcuts", "shortcuts"),
                 action(panel, WorkbenchUpdates.shared.panelTitle, "Checks for updates"), action(panel, "Quit", "Quits Workbench"),
                 page(panel, "Clipboard receipt · Review text", "history"), action(panel, "Clipboard receipt · Show cue", "Shows the clipboard cue")]
        list += WorkbenchHome.navItems.map { E(surface: "Home sidebar", label: $0.1, leads: "Page: \($0.0)", route: $0.0, ran: true) }
        list += [page("Home sidebar", "Update button, when an update is waiting", "settings"), action("Home sidebar", "Suite appearance", "Changes the appearance")]
        list += [page(home, "Dictate card", "dictate"), page(home, "Read aloud card", "speak"), page(home, "Snap & Talk card", "readback"),
                 page(home, "Annotate card", "annotate"), page(home, "Present a device card", "present"), page(home, "Try the keyboard", "shortcuts"),
                 page(home, "Speech settings, while speech is not ready", "models"), page(home, "Phone photo arrival", "library"),
                 page("Settings page", "Your dictionary", "dictionary"), page("Settings page", "Models and local server", "models"),
                 page("Settings page", "Keyboard and practice", "shortcuts"), action("Settings page", "Position dictation panel…", "Shows the dictation panel preview"),
                 page("Snap & Talk page", "Manage packs…", "packs")]
        list += [action(menu, "Workbench › About Workbench", "Shows the About panel"), page(menu, "Workbench › Check for Updates…", "settings"),
                 action(menu, "Workbench › Copy build details", "Copies build details"), page(menu, "Workbench › Settings…", "settings"),
                 page(menu, "Workbench › Keyboard shortcuts…", "shortcuts"), action(menu, "Window › Open Workbench", "Opens Home on its current page"),
                 action(menu, "Window › Quick controls", "Opens this panel"), action(menu, "Window › Show floating toolbar", "Shows the toolbar"),
                 action(menu, "Window › Focus floating toolbar", "Moves keyboard focus to the toolbar"), action(menu, "Window › Restore menu-bar icon", "Shows the icon and the toolbar"),
                 page(menu, "Window › Saved resources", "library"), action(menu, "Window › Switch to…", "Opens the Switch to panel"),
                 page(menu, "Window › Snap & Talk sessions", "readback"), page(menu, "Window › Save clipboard as prompt…", "library"),
                 action(menu, "Help › Workbench Guide", "Opens the web guide")]
        list += [page(other, "Saved resources shortcut", "library"), page(other, "Read shortcut, when nothing is playing", "speak"),
                 page(other, "Snap & Talk shortcut, without a session or access", "readback"), page(other, "Present shortcut, without a scene", "present"),
                 action(other, "Quick controls shortcut", "Opens this panel"), action(other, "Switch to shortcut", "Opens the Switch to panel"),
                 page(other, "Read aloud Service (selected text)", "speak"), page(other, "Private pack link", "packs"),
                 page(other, "Switch to panel · Set up", "library"), page(other, "StageKit controls and drawing settings", "annotate"),
                 page(other, "StageKit shortcut editing", "shortcuts")]
        return list
    }
}

/// The contact sheet. Flags come from the entry catalogue and the rendered pages.
private struct SurfaceIndex {
    let passes: [SurfaceGallery.Pass]

    /// Returns the number of flags.
    func write(to output: URL) throws -> Int {
        let light = passes[0], dark = passes.count > 1 ? passes[1] : passes[0]
        let routes = Set(light.pages.map(\.route))
        var flags: [String] = []
        for entry in light.entries where entry.route.map({ !routes.contains($0) }) == true {
            flags.append("\(entry.surface) · \(entry.label) leads to “\(entry.route!)”, which has no page. Home shows the Dictate page instead.")
        }
        for page in light.pages {
            let reached = light.entries.filter { $0.route == page.route && $0.surface != "Home sidebar" }
            if reached.isEmpty && !WorkbenchHome.navItems.contains(where: { $0.0 == page.route }) { flags.append("No entry opens \(page.title) (\(page.route)).") }
            if page.fallsThrough && page.route != "dictate" { flags.append("\(page.title) (\(page.route)) renders the Dictate page: the route has no page of its own.") }
        }
        var html = """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Workbench surfaces</title><style>
        :root{color-scheme:light dark;--ink:#1d1f21;--muted:#5f6368;--line:#d9dde1;--flag:#b3261e;--ok:#1f7a5a;--card:#f6f7f8}
        @media (prefers-color-scheme:dark){:root{--ink:#e8eaed;--muted:#a0a4a8;--line:#3a3d41;--flag:#f28b82;--ok:#7fd1ae;--card:#202124}}
        body{font:14px/1.45 -apple-system,system-ui,sans-serif;color:var(--ink);background:Canvas;margin:0 auto;max-width:1500px;padding:24px 16px}
        h1{font-size:24px;margin:0 0 4px}h2{font-size:18px;margin:32px 0 8px;border-bottom:1px solid var(--line);padding-bottom:6px}h3{font-size:15px;margin:22px 0 4px}
        p,li{color:var(--muted)}.flag{color:var(--flag)}.ok{color:var(--ok)}code{font:12px ui-monospace,monospace}
        .row{display:flex;flex-wrap:wrap;gap:14px;align-items:flex-start}figure{margin:0}figcaption{font-size:12px;color:var(--muted)}
        img{display:block;max-width:100%;height:auto;border:1px solid var(--line);border-radius:6px}.panel img{width:328px}.page img{width:560px}
        pre{background:var(--card);border:1px solid var(--line);border-radius:6px;padding:10px 12px;overflow-x:auto;font-size:12px}
        table{border-collapse:collapse;width:100%}td,th{text-align:left;border-bottom:1px solid var(--line);padding:5px 8px;vertical-align:top}th{font-weight:600}
        .menus{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:12px}
        </style></head><body>
        <h1>Workbench surfaces</h1>
        <p>\(esc(WorkbenchBuild().label)). Synthetic fixtures only. Each appearance rendered in its own process with a temporary home, which was removed afterwards. Nothing was launched, recorded, captured or sent.</p>
        <h2>Checks</h2>
        """
        html += flags.isEmpty ? "<p class=\"ok\">Every entry leads to an existing page or an action, and every page has an entry.</p>"
            : "<ul>" + flags.map { "<li class=\"flag\">\(esc($0))</li>" }.joined() + "</ul>"
        html += "<p>An unknown route falls through to the Dictate page with no error, so a mistyped route looks like a working entry. Pages are compared with that fallback to catch it.</p>"
        html += "<h2>Menu-bar panel</h2><p>Rendered on the window background; the popover's material is not drawn.</p>"
        for (index, shot) in light.panels.enumerated() {
            html += "<h3>\(esc(shot.title))</h3><p>\(esc(shot.detail))</p><div class=\"row panel\">" + figure(shot, "Light") + figure(dark.panels[index], "Dark") + "</div>"
        }
        html += "<h3>Not rendered</h3><ul>" + ["Drawing", "Presenting a device scene", "Persona Overlay showing", "Timer running"].map {
            "<li>\($0): needs a live StageKit session (overlay windows or device capture). The options menus below show these rows' idle menus.</li>" }.joined() + "</ul>"
        html += "<h2>Options menus</h2><div class=\"menus\">" + light.menus.map { "<div><h3>\(esc($0.title))</h3><pre>\(esc($0.lines.joined(separator: "\n")))</pre></div>" }.joined() + "</div>"
        html += "<h2>Pages</h2><p>The top of each page, with the window at its default size and at its minimum size.</p>"
        for (index, page) in light.pages.enumerated() {
            let reached = light.entries.filter { $0.route == page.route }.map { "\($0.surface) · \($0.label)" }
            html += "<h3>\(esc(page.title)) <code>\(esc(page.route))</code></h3><p>Opened from: \(esc(reached.joined(separator: "; ")))</p><div class=\"row page\">"
            for (shotIndex, shot) in page.shots.enumerated() {
                html += figure(shot, "Light") + figure(dark.pages[index].shots[shotIndex], "Dark")
            }
            html += "</div>"
        }
        html += "<h2>Entries</h2><p>Source: <em>app code</em> means the destination was read from the app's own navigation data or found by running the item with recording callbacks; <em>catalogue</em> means it is declared in SurfaceGallery.swift.</p>"
        html += "<table><tr><th>Surface</th><th>Entry</th><th>Leads to</th><th>Source</th><th>Check</th></tr>"
        for entry in light.entries {
            let missing = entry.route.map { !routes.contains($0) } ?? false
            html += "<tr><td>\(esc(entry.surface))</td><td>\(esc(entry.label))</td><td>\(esc(entry.leads))</td><td>\(entry.ran ? "App code" : "Catalogue")</td>"
                + (missing ? "<td class=\"flag\">No page</td>" : "<td class=\"ok\">\(entry.route == nil ? "Action" : "Page exists")</td>") + "</tr>"
        }
        html += "</table><h2>Limitations</h2><ul>" + [
            "Drawing, presenting, persona and timer states need live StageKit windows or device capture and are not rendered.",
            "StageKit is never started, so Annotate reports Ready on 0 displays.",
            "Workbench is never the active app, so controls draw in their inactive style (the Floating Toolbar switch is grey).",
            "Menu contents are listed as text. The Dictate options menu is SwiftUI and is listed from its source; the others are the panel's own native menus.",
            "Buttons, app menus and keys come from a catalogue in SurfaceGallery.swift. Add a row there when adding an entry.",
            "Snap & Talk shows its first-run page. An open session shows its folder path and this Mac's Screen Recording and Microphone access.",
            "The speech engine is never loaded, so Models shows a fresh install. Mac voices, Apple Intelligence availability and keyboard labels come from the rendering Mac.",
            "Pixel sizes follow the rendering display's scale."].map { "<li>\(esc($0))</li>" }.joined() + "</ul></body></html>\n"
        try Data(html.utf8).write(to: output.appendingPathComponent("index.html"), options: .atomic)
        let shots = passes.flatMap { pass in pass.panels + pass.pages.flatMap(\.shots) }.map { ["file": $0.file, "width": $0.width, "height": $0.height] as [String: Any] }
        let manifest: [String: Any] = ["renders": shots, "flags": flags, "entries": light.entries.map { ["surface": $0.surface, "label": $0.label, "leads": $0.leads] }]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("manifest.json"))
        return flags.count
    }

    func figure(_ shot: SurfaceGallery.Shot, _ theme: String) -> String {
        "<figure><a href=\"\(esc(shot.file))\"><img src=\"\(esc(shot.file))\" alt=\"\(esc(shot.title)), \(theme)\" loading=\"lazy\"></a>"
            + "<figcaption>\(theme) · \(esc(shot.title)) · \(shot.width) × \(shot.height) px</figcaption></figure>"
    }

    func esc(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
