import AppKit
import ObjectiveC
import PhotoHandoffKit
import SwiftUI
import StageKit
import ToolbarCore
import ToolbarKit

/// `LocalVoice --render-surfaces DIR` draws the menu-bar quick panel in fixed states, the production
/// floating toolbar host in every mode at rest and revealed, and the top of every Home page at the
/// default and minimum window sizes, then writes `index.html` listing each entry and where it leads.
/// A toolbar window that is not the size of its row fails the run; other flags are reported only.
/// It uses synthetic fixtures only: nothing is launched, and no
/// shortcut, microphone, screen capture, Keychain item or network request is used.
///
/// Each appearance renders in a child process whose home is a new temporary folder, so every
/// file store resolves there (`CFFIXED_USER_HOME`). cfprefsd ignores that variable, so the child
/// also keeps every preference in plist files beside that home; see `isolatePreferences`.
enum SurfaceGallery {
    /// Speko.swift and PackCredentials.swift check this same argument and never query Keychain in a pass.
    static let passFlag = "--render-surfaces-pass"
    static let workPrefix = ".surface-pass-"
    /// AppDelegate opens Home at 1180 × 800. Its 1050 × 730 minimum grows by the title bar.
    static let sizes: [(name: String, size: NSSize)] = [("default", NSSize(width: 1180, height: 800)), ("narrow", NSSize(width: 1050, height: 730))]
    /// Routes with no sidebar item, all from the page record: every section but a page's first,
    /// which is the page itself, then the pages Dictate opens (Your dictionary, Transcribe meeting
    /// or call).
    static var extraPages: [(String, String)] {
        WorkbenchHome.sections.filter { section in !WorkbenchHome.navItems.contains { $0.id == section.id } }
            .map { ($0.id, WorkbenchHome.name(of: $0.page) + " › " + $0.title) }
            + WorkbenchHome.subpages.map { ($0.id, $0.title) }
    }
    static let unknownRoute = "surface-gallery-unknown-route"

    struct Shot: Codable { var id: String; var title: String; var detail: String; var file: String; var width: Int; var height: Int }
    struct Page: Codable { var route: String; var title: String; var fallsThrough: Bool; var blank = false; var shots: [Shot] }
    /// `ran` marks a destination learned from the app's own code rather than the catalogue.
    struct Entry: Codable { var surface: String; var label: String; var leads: String; var route: String?; var ran = false }
    struct Listing: Codable { var title: String; var lines: [String] }
    /// One state of the production toolbar host: the size its window got and the size its row wanted.
    struct HostCheck: Codable { var id, title, mode, tier: String; var window, wants, preferred: [Double]; var measured, twinMeasured: Bool; var problems: [String]; var file: String
        /// The toolbar reached the tier this state asked for; its sizes are only compared if so.
        var settled = true }
    /// One step of the toolbar's placement through the production host (#163).
    struct PlacementCheck: Codable { var title: String; var problems: [String] }
    /// One state of the production Saved Prompts panel: the size it got and the size its content wanted.
    struct PickerHostCheck: Codable { var id, title: String; var window, wants: [Double]; var heard: Bool; var problems: [String]; var file: String
        /// The picker was still open when measured; its sizes are only compared if so.
        var settled = true }
    struct Pass: Codable { var theme: String; var panels: [Shot]; var toolbar: [Shot]; var host: [HostCheck]; var pickers: [Shot]; var pickerHost: [PickerHostCheck]
        var pages: [Page]; var entries: [Entry]; var menus: [Listing]; var placement: [PlacementCheck] = []
        /// Home's review and the floating toolbar's switch, checked with the pass's own models (#134).
        var checks: [String] = [] }

    /// Parent process: the two appearances render at once in isolated passes, then the contact sheet.
    static func run(output: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        // The temporary homes sit in the output folder, named without symbolic links: Packs refuses
        // a storage path through one, such as /tmp or the /var of the system temporary folder.
        guard let executable = Bundle.main.executableURL, let real = realpath(output.path, nil) else {
            throw VoiceError.message("LocalVoice could not prepare \(output.path).")
        }
        // Foundation reports a home under /private/tmp or /private/var as /tmp or /var, which are
        // symbolic links that meeting and pack storage refuse. The Data volume names the same folder
        // without one.
        let canonical = String(cString: real); free(real)
        let output = URL(fileURLWithPath: canonical.hasPrefix("/private/") ? "/System/Volumes/Data" + canonical : canonical, isDirectory: true)
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
        // A toolbar window that is not the size of its row fails the run (#152), after the index
        // has recorded it. Every other flag stays report-only.
        let wrongSize = passes.flatMap { pass in pass.host.filter(\.hasSizeProblem).map { "\($0.title), \(pass.theme)" } }
        if !wrongSize.isEmpty {
            throw VoiceError.message("The floating toolbar's window is not the size of its row in \(wrongSize.count) states (\(wrongSize.joined(separator: "; "))). See \(output.appendingPathComponent("index.html").path).")
        }
        // So does a toolbar that does not rest where it was put (#163).
        let misplaced = passes.flatMap { pass in pass.placement.filter { !$0.problems.isEmpty }.map { "\($0.title), \(pass.theme)" } }
        if !misplaced.isEmpty {
            // Each failing step's own words, so a runner's log says what it saw once the passes' files are gone.
            let details = passes.flatMap { pass in pass.placement.filter { !$0.problems.isEmpty }.map {
                "\($0.title), \(pass.theme): \($0.problems.joined(separator: "; "))" } }
            throw VoiceError.message("The floating toolbar did not rest where it was put in \(misplaced.count) steps (\(misplaced.joined(separator: "; "))). See \(output.appendingPathComponent("index.html").path).\n"
                + details.joined(separator: "\n"))
        }
        // The same for the Saved Prompts panel: a panel that is not the size of its content
        // leaves blank space or clips its status line (#159, the pattern #152 found).
        let wrongPicker = passes.flatMap { pass in pass.pickerHost.filter(\.hasSizeProblem).map { "\($0.title), \(pass.theme)" } }
        if !wrongPicker.isEmpty {
            throw VoiceError.message("The Saved Prompts picker's panel is not the size of its content in \(wrongPicker.count) states (\(wrongPicker.joined(separator: "; "))). See \(output.appendingPathComponent("index.html").path).")
        }
        let renders = passes.reduce(0) { $0 + $1.panels.count + $1.toolbar.count + $1.pickers.count + $1.pages.reduce(0) { $0 + $1.shots.count } }
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
        var part = URL(fileURLWithPath: "/", isDirectory: true)
        for component in home.pathComponents.dropFirst() {
            part.appendPathComponent(component)
            if (try? part.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw VoiceError.message("The temporary home \(home.path) passes through a symbolic link, which Snap, meeting and pack storage refuse.")
            }
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
    /// The preferences that name the synthetic session as recent.
    let sessionDefaults: UserDefaults
    let snap: SnapModel
    /// Meeting owners with a fixed audio-app list and a capture that records nothing.
    let meetings: MeetingModel
    let recordingMeetings: MeetingModel
    let keyboard: KeyboardCoachModel
    let panelEditor: PanelShortcutEditor
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
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        let stageDefaults = try SurfaceGallery.isolatedDefaults("StageKit", home: home)
        // Never look for a legacy StageMark preferences domain.
        stageDefaults.set(true, forKey: "legacyStagePreferencesSeeded.v1")
        let preferences = VoicePreferences.load(reserving: StageShortcutSettings.migrationReservations(defaults: stageDefaults))
        model = AppModel(preferences: preferences)
        // Before anything reads the app's lazy meeting owner, which would list live audio processes.
        let support = Workbench.supportDirectory(component: "Meetings")
        meetings = SurfacePass.syntheticMeetings(support)
        recordingMeetings = SurfacePass.syntheticMeetings(support.deletingLastPathComponent().appendingPathComponent("Meetings (panel state)"))
        model.meetings = meetings
        // Set before the initialiser's prepare() task runs, so no speech model is loaded or downloaded.
        model.ready = true
        model.accessibilityGranted = false
        model.history = SurfacePass.history
        model.transcript = SurfacePass.history[0].text; model.rawTranscript = model.transcript
        let noCapture: @MainActor () async throws -> ReadbackScreenshot = { throw ReadbackError.message("The surface gallery never captures the screen.") }
        let noSpeech: @MainActor (URL) async throws -> String = { _ in throw ReadbackError.message("The surface gallery never transcribes audio.") }
        // Screen Recording reads as allowed, so pages render alike on every Mac; a separate state shows it off.
        readback = ReadbackModel(engine: model.engine, captureDisplay: noCapture, transcribeAudio: noSpeech, screenAccess: .fixed(true))
        let session = try SurfacePass.makeSession(in: home)
        let sessionDefaults = try SurfaceGallery.isolatedDefaults("SnapSession", home: home)
        sessionDefaults.set([session.path], forKey: "readback.recentSessionPaths.v1")
        sessionReadback = ReadbackModel(engine: model.engine, defaults: sessionDefaults, captureDisplay: noCapture, transcribeAudio: noSpeech,
                                        screenAccess: .fixed(true))
        self.sessionDefaults = sessionDefaults
        // Snap storage wants the resolved spelling of its folder, which may name /private as /tmp.
        let snaps = Workbench.supportDirectory(component: "Snaps")
        try FileManager.default.createDirectory(at: snaps, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // An empty Desktop in the temporary home, and a trash that refuses: Desktop import never runs here.
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        snap = SnapModel(store: try SurfacePass.makeSnaps(SnapStore(root: snaps.resolvingSymlinksInPath())), desktop: desktop,
                         trash: { _ in throw SnapError.message("The surface gallery never moves files to the Trash.") }, screenAccess: .fixed(true))
        stage = StageKitController(reserving: preferences.enabledCombinations, defaults: stageDefaults)
        stage.useSharedActivityControls()
        let model = model
        stage.mayBeginInteraction = { model.phase == .idle && !model.rendering }
        stage.mayBeginDrawing = { WorkbenchDrawingAdmission.allows(phase: model.phase, suspended: false, capturingScreen: false, terminating: false) }
        shell.model = model; shell.stage = stage
        keyboard = KeyboardCoachModel(entries: shell.shortcutEntries(), update: { _, _ in "The surface gallery does not save shortcuts." },
                                      suspend: { _ in }, probe: { _ in nil })
        panelEditor = PanelShortcutEditor(keyboard: keyboard)
        model.onShowPresenter = { [weak self] in self?.actions.append("Opens the Switch to panel") }
        // StageKit's page callbacks, wired to the routes AppDelegate gives them.
        stage.onOpenControls = { [weak self] in self?.opened.append("annotate") }
        stage.onOpenScenes = { [weak self] in self?.opened.append("present") }
        stage.onOpenPersonas = { [weak self] in self?.opened.append("personas") }
        stage.onEditShortcuts = { [weak self] in self?.opened.append("shortcuts") }
    }

    func render(to output: URL) throws -> SurfaceGallery.Pass {
        var panels: [SurfaceGallery.Shot] = []
        for state in panelStates() {
            try state.apply()
            let rep = try renderPanel(state.readback, controlState: state.controlState)
            panels.append(try save(rep, id: state.id, title: state.title, detail: state.detail, file: "panel-\(state.id)-\(theme).png", to: output))
            try state.reset()
        }
        let header = try renderPanelHeaderLargerText(to: output)
        panels.append(header.shot)
        panels += try renderFloatingStates(to: output)
        let (hostShots, host) = try renderToolbarHost(to: output)
        let toolbar = hostShots + [try renderChooser(to: output), try renderPositionControl(to: output)]
        let placement = try checkToolbarPlacement()
        let pickers = try renderPickerStates(to: output)
        let (pickerShots, pickerHost) = try checkPickerHost(to: output)
        var pages = SurfacePass.pages.map { SurfaceGallery.Page(route: $0.0, title: $0.1, fallsThrough: false, shots: []) }
        for (name, size) in SurfaceGallery.sizes {
            let window = homeWindow(size: size)
            defer { window.contentViewController = nil; window.close() }
            let fallback = name == "default" ? SurfacePass.contentPixels(try renderPage(SurfaceGallery.unknownRoute, in: window).0) : nil
            for index in pages.indices {
                let (rep, drawn) = try renderPage(pages[index].route, in: window)
                if let fallback { pages[index].fallsThrough = SurfacePass.contentPixels(rep) == fallback }
                if SurfacePass.isBlank(rep, size: size) { pages[index].blank = true }
                pages[index].shots.append(try save(rep, id: name, title: "\(name == "default" ? "Default" : "Minimum") window, \(Int(drawn.width)) × \(Int(drawn.height)) pt",
                                                   detail: "", file: "page-\(pages[index].route)-\(name)-\(theme).png", to: output))
            }
        }
        for (route, shots) in try renderFoldedStates(to: output) {
            if let index = pages.firstIndex(where: { $0.route == route }) { pages[index].shots += shots }
        }
        if let read = pages.firstIndex(where: { $0.route == "speak" }) { pages[read].shots += try renderReadStates(to: output) }
        if let dictate = pages.firstIndex(where: { $0.route == "dictate" }) { pages[dictate].shots += try renderDictateStates(to: output) }
        // Home's first-dictation states come before History's, which add Hand off tasks to recent work.
        if let home = pages.firstIndex(where: { $0.route == "home" }) { pages[home].shots += try renderHomeStates(to: output) + [try renderHomeLargerText(to: output), try renderHomeSavedPhotos(to: output)] }
        let review = try checkHomeReview(to: output)
        if let history = pages.firstIndex(where: { $0.route == "history" }) { pages[history].shots.append(review.shot) }
        let checks = try review.checks + checkToolbarVisibility() + header.checks
        // History's states render last, so the pages above show no Hand off task.
        if let history = pages.firstIndex(where: { $0.route == "history" }) { pages[history].shots += try renderHistoryStates(to: output) }
        // The read-only image preview that capture thumbnails open (#154), shown with the Snap page.
        if let snapPage = pages.firstIndex(where: { $0.route == "snap" }) { pages[snapPage].shots += try renderImagePreview(to: output) }
        let listings = menus()
        // Screen Recording off (#112): Snap, Home's quick starts and a Snap & Talk session explain it.
        for (route, shot) in try renderScreenAccessOff(to: output) {
            if let index = pages.firstIndex(where: { $0.route == route }) { pages[index].shots.append(shot) }
        }
        return SurfaceGallery.Pass(theme: theme, panels: panels, toolbar: toolbar, host: host, pickers: pickers + pickerShots, pickerHost: pickerHost,
                                   pages: pages, entries: entries() + menuEntries, menus: listings, placement: placement, checks: checks)
    }

    // MARK: Saved Prompts picker

    /// Present's Saved Prompts picker, from synthetic prompts, at its 420-point width and at
    /// standard and larger text. The panel's placement and focus are covered by --check-core and
    /// need a pointer on the installed app; nothing here opens a window on screen.
    func renderPickerStates(to output: URL) throws -> [SurfaceGallery.Shot] {
        let now = Date(timeIntervalSince1970: 1_789_546_320)
        func prompt(_ title: String, favourite: Bool = false, product: String = "", persona: String = "", age: Double = 0) -> DemoResource {
            DemoResource(kind: .prompt, title: title, product: product, persona: persona,
                         content: "Synthetic prompt for \(title).", favorite: favourite, modified: now.addingTimeInterval(-age * 3_600))
        }
        let library = [prompt("Open with the customer's goal", favourite: true, product: "Acme CRM", age: 1),
                       prompt("Show the approval flow", favourite: true, product: "Acme CRM", persona: "Manager", age: 2),
                       prompt("Summarise the pricing change", product: "Acme CRM", age: 3),
                       prompt("Walk through onboarding", persona: "Manager", age: 4),
                       prompt("Explain the security review", persona: "HR Admin", age: 5),
                       prompt("Close with next steps", age: 6)]
        let long = [prompt("Explain how the quarterly planning review connects the regional forecasts to the hiring plan and the budget", favourite: true,
                           product: "A product name long enough to need truncating in one line", persona: "Regional operations manager"),
                    prompt("Supercalifragilisticexpialidocious-configuration-walkthrough-for-the-enterprise-tenant-administrators", age: 1),
                    prompt("Short one", age: 2)]
        let large = (1...60).map { prompt("Demo prompt \($0)", favourite: $0 % 12 == 1, product: "Product \($0 % 4 + 1)", age: Double($0)) }
        let notes = PromptPickerMode.insert(into: "Notes")
        let stopped = PromptAttempt(prompt: "Show the approval flow", destination: "Mail",
                                    result: "Insertion stopped. 12 characters confirmed; nothing was replayed.")
        struct State {
            var id, title, detail: String; var resources: [DemoResource]; var mode: PromptPickerMode; var scale: CGFloat = 1
            var query = ""; var filter = PromptPickerList.Filter.all; var running = false; var attempt: PromptAttempt?; var details = false
        }
        let states = [
            State(id: "empty", title: "No saved prompts", detail: "An empty picker leads to Library.", resources: [], mode: notes),
            State(id: "one", title: "One prompt", detail: "Inserting into Notes, the field in front when the picker opened.", resources: [library[0]], mode: notes),
            State(id: "grouped", title: "Favourites, then the rest", detail: "Product and Persona tags filter the one list. The last delivery went to Mail and says so.",
                  resources: library, mode: notes, attempt: stopped),
            State(id: "details", title: "Last delivery details", detail: "Details shows the full reason, wrapped inside the picker.",
                  resources: library, mode: notes, attempt: stopped, details: true),
            State(id: "copy", title: "Copy prompt", detail: "Without Accessibility approval the action is Copy prompt, with no reminder to approve.",
                  resources: library, mode: .copy(noField: false),
                  attempt: PromptAttempt(prompt: "Close with next steps", destination: "Clipboard", result: TextDelivery.copiedMessage)),
            State(id: "no-field", title: "No readable field", detail: "With approval but no readable field in front, choosing a prompt copies it.",
                  resources: library, mode: .copy(noField: true)),
            State(id: "long-names", title: "Long names", detail: "Long names wrap to two lines or truncate; the picker keeps its width.",
                  resources: long, mode: notes),
            State(id: "filtered", title: "One category", detail: "Persona: Manager narrows the same list.", resources: library, mode: notes,
                  filter: .persona("Manager")),
            State(id: "no-match", title: "No match", detail: "A search with no match offers to show every prompt.", resources: library, mode: notes, query: "zebra"),
            State(id: "inserting", title: "Inserting", detail: "While a prompt is typed in, the picker offers Stop inserting.", resources: library, mode: notes,
                  running: true, attempt: PromptAttempt(prompt: "Show the approval flow", destination: "Notes", result: "Inserting…", finished: false)),
            State(id: "large", title: "Sixty prompts", detail: "A large library scrolls at the picker's maximum height; search finds any prompt.",
                  resources: large, mode: notes),
            State(id: "grouped-larger", title: "Favourites, larger text", detail: "At 1.35 times the text size the picker keeps its width and wraps.",
                  resources: library, mode: notes, scale: 1.35, attempt: stopped),
            State(id: "long-names-larger", title: "Long names, larger text", detail: "Long names at 1.35 times the text size.",
                  resources: long, mode: .copy(noField: false), scale: 1.35)]
        var shots: [SurfaceGallery.Shot] = []
        for state in states {
            let model = PromptPickerModel(list: PromptPickerList(resources: state.resources), mode: state.mode, width: PromptPickerLayout.maxWidth,
                                          available: 640, textScale: state.scale, perform: { _ in }, dismiss: {})
            model.list.query = state.query; model.list.filter = state.filter
            model.show(running: state.running, attempt: state.attempt); model.showsDetails = state.details
            let host = NSHostingView(rootView: PromptPickerView(model: model).padding(16).background(Color(nsColor: .windowBackgroundColor)))
            let window = offscreenWindow(size: host.fittingSize, styleMask: [.borderless])
            window.contentView = host
            settle(host); window.setContentSize(host.fittingSize); settle(host, seconds: 0.1)
            window.setContentSize(host.fittingSize); settle(host, seconds: 0.05)
            defer { window.contentView = nil; window.close() }
            shots.append(try save(try snapshot(host), id: state.id, title: state.title, detail: state.detail,
                                  file: "picker-\(state.id)-\(theme).png", to: output))
        }
        return shots
    }

    // MARK: Saved Prompts picker host

    /// The production picker, `PromptPickerController`, opened as the toolbar host check drives
    /// the toolbar: its panel is invisible, ignores the pointer, takes no keyboard focus and
    /// watches no clicks. It opens over a bottom-docked Prompts button with synthetic prompts,
    /// narrows to one row, gains a status line, shows that line's Details, then lists every prompt
    /// again. Each time its panel must be the size its content wants, within the display, as
    /// measured by a twin view that sizes its own window. The picker's renders above size their
    /// own windows, so only this check can see a panel its content never resized (#152).
    func checkPickerHost(to output: URL) throws -> (shots: [SurfaceGallery.Shot], checks: [SurfaceGallery.PickerHostCheck]) {
        guard let screen = NSScreen.main else { return ([], []) }
        let now = Date(timeIntervalSince1970: 1_789_546_320)
        let prompts = [("Open with the customer's goal", true, "Acme CRM", ""), ("Show the approval flow", true, "Acme CRM", "Manager"),
                       ("Summarise the pricing change", false, "Acme CRM", ""), ("Walk through onboarding", false, "", "Manager"),
                       ("Explain the security review", false, "", "HR Admin"), ("Close with next steps", false, "", "")]
            .enumerated().map { index, item in
                DemoResource(kind: .prompt, title: item.0, product: item.2, persona: item.3, content: "Synthetic prompt for \(item.0).",
                             favorite: item.1, modified: now.addingTimeInterval(-Double(index) * 3_600))
            }
        // Copy prompt writes only to this pasteboard; nothing is pasted or typed anywhere.
        let board = NSPasteboard(name: .init("Workbench.PickerHostCheck." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let isolated = TextDelivery.System(pasteboard: board, isTrusted: { false }, isEligible: { _ in false }, preparePaste: { nil })
        let receipts = ClipboardReceiptModel(clipboardChangeCount: { board.changeCount }, automaticallySchedules: false)
        let delivery = PromptInsertion()
        let controller = PromptPickerController()
        controller.offscreenForChecks = true
        let visible = screen.visibleFrame
        let anchor = NSRect(x: visible.midX - 32, y: visible.minY + 40, width: 64, height: 30)
        controller.show(anchor: anchor, context: .init(resources: prompts, delivery: delivery, receipts: receipts, destination: nil,
                                                       trusted: false, controls: nil, openLibrary: {}))
        defer { controller.close() }
        guard let panel = controller.shownPanel, let content = panel.contentView else { throw VoiceError.message("The Saved Prompts picker did not open.") }
        panel.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
        let steps: [(id: String, title: String, apply: () -> Void)] = [
            ("open", "Opened", {}),
            ("one-row", "Narrowed to one row", { controller.shownModel?.list.query = "pricing" }),
            ("status", "With a status line", {
                delivery.copy("Synthetic prompt for Summarise the pricing change.", title: "Summarise the pricing change", receipts: receipts, system: isolated)
            }),
            // A result too long for one line gets Details. With no field, nothing is typed.
            ("details", "With the status line's Details", {
                delivery.insert("Synthetic prompt.", title: "Walk through onboarding", into: nil); controller.shownModel?.showsDetails = true
            }),
            ("all", "Every prompt again", { controller.shownModel?.list.query = "" })]
        var shots: [SurfaceGallery.Shot] = [], checks: [SurfaceGallery.PickerHostCheck] = []
        for step in steps {
            step.apply()
            waitForPicker(controller, panel)
            let title = "Saved Prompts panel, \(step.title.lowercased())", file = "picker-host-\(step.id)-\(theme).png"
            guard let model = controller.shownModel else {
                checks.append(.init(id: step.id, title: title, window: [], wants: [], heard: false,
                                    problems: ["the picker closed during the check"], file: "", settled: false))
                break
            }
            let natural = pickerWants(model)
            let wants = PromptPickerLayout.frame(content: natural, anchor: anchor, visible: visible, above: controller.opensAbove).size
            let window = panel.frame.size
            var problems: [String] = []
            let heard = controller.reportedSize.map { abs($0.width - natural.width) <= 0.5 && abs($0.height - natural.height) <= 0.5 } ?? false
            if !heard {
                problems.append("the panel never heard its content's current size" + (controller.reportedSize.map { "; the last report was \(Self.points($0))" } ?? ""))
            }
            if abs(window.width - wants.width) > 0.5 || abs(window.height - wants.height) > 0.5 {
                problems.append("the panel is \(Self.points(window)) but its content wants \(Self.points(wants))"
                    + (window.height > wants.height + 0.5 ? ", so it shows blank space" : window.height + 0.5 < wants.height ? ", so its content is clipped" : ""))
            }
            if !visible.insetBy(dx: PromptPickerLayout.edgeMargin - 0.5, dy: PromptPickerLayout.edgeMargin - 0.5).contains(panel.frame) {
                problems.append("the panel is not inside the display with its margins")
            }
            // An empty panel has nothing to draw; its size is the finding.
            if content.bounds.width >= 1 && content.bounds.height >= 1 {
                shots.append(try save(try snapshot(content), id: "host-\(step.id)", title: title,
                                      detail: "The production panel, invisible: \(Self.points(window)); its content wants \(Self.points(wants)).", file: file, to: output))
            }
            checks.append(.init(id: step.id, title: title, window: [window.width, window.height], wants: [wants.width, wants.height],
                                heard: heard, problems: problems, file: file))
        }
        return (shots, checks)
    }

    /// Spins the main run loop until the picker's panel has held its frame for six turns of about
    /// 50 ms, the picker closes, or three seconds pass.
    func waitForPicker(_ controller: PromptPickerController, _ panel: NSPanel) {
        let deadline = Date().addingTimeInterval(3)
        var still = 0, last = panel.frame
        while Date() < deadline && still < 6 && controller.isShown {
            panel.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            still = panel.frame == last ? still + 1 : 0
            last = panel.frame
        }
    }

    /// What the picker's content wants: the same state in a twin view that sizes its own window.
    func pickerWants(_ model: PromptPickerModel) -> NSSize {
        let twinModel = PromptPickerModel(list: model.list, mode: model.mode, width: model.width, available: model.available,
                                          textScale: model.textScale, perform: { _ in }, dismiss: {})
        twinModel.show(running: model.running, attempt: model.attempt); twinModel.showsDetails = model.showsDetails
        let twin = NSHostingView(rootView: PromptPickerView(model: twinModel))
        let window = offscreenWindow(size: NSSize(width: model.width, height: 200), styleMask: [.borderless])
        window.contentView = twin
        defer { window.contentView = nil; window.close() }
        var size = twin.fittingSize
        for _ in 0..<20 {
            window.setContentSize(size); settle(twin, seconds: 0.05)
            let next = twin.fittingSize
            if abs(next.width - size.width) <= 0.5 && abs(next.height - size.height) <= 0.5 { break }
            size = next
        }
        return size
    }

    // MARK: Floating surface states

    /// The floating surface's own moments, which no page shows: the routine cue at the toolbar's
    /// place after a dictation that heard no speech, and the results the toolbar reveals in place
    /// of its row (#134 T4): a reading that stopped because its audio could not be read, and the
    /// clipboard receipt with its ring. Each at the size it uses.
    func renderFloatingStates(to output: URL) throws -> [SurfaceGallery.Shot] {
        let controls = CaptureHUDControls(defaults: .standard)
        model.announceForAccessibility = { _ in }
        var shots: [SurfaceGallery.Shot] = []
        func shot(_ id: String, _ title: String, _ detail: String, result: FloatingResult? = nil) throws {
            let size = CaptureHUDLayout.compact
            let content = Group {
                if let result { FloatingResultView(result: result, model: model, controls: controls) }
                else { WorkbenchFloatingContent(model: model, readback: readback, stage: stage, controls: controls, snapModel: snap,
                                                dictate: {}, snap: {}, snapCapture: {}, draw: {}, present: {}) }
            }
            let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = offscreenWindow(size: size, styleMask: [.borderless])
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            settle(host)
            shots.append(try save(try snapshot(host), id: id, title: title, detail: detail, file: "panel-\(id)-\(theme).png", to: output))
        }
        model.endWithoutSpeech(.tooQuiet)
        try shot("floating-no-speech", "Floating: no speech heard",
                 "At the toolbar's place for under two seconds, then the compact mark again. Hover holds it.")
        model.dismissCaptureCue()
        model.reportReadingFailure(.audioUnreadable)
        try shot("floating-reading-stopped", "Floating: reading stopped",
                 "Revealed from the compact mark's warning: a reading whose audio could not be read keeps Retry and dismiss.",
                 result: .readingFailure)
        /// A result as it shows at a right-hand dock: mirrored, its words over the mark the pointer
        /// came from and its commands at the far end (#211 F3).
        func mirrored(_ id: String, _ title: String, _ result: FloatingResult, size: NSSize) throws {
            controls.rowAnchor = .right
            defer { controls.rowAnchor = .bottom }
            let host = NSHostingView(rootView: FloatingResultView(result: result, model: model, controls: controls)
                .frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
            let window = offscreenWindow(size: size, styleMask: [.borderless])
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            settle(host)
            shots.append(try save(try snapshot(host), id: id, title: title,
                                  detail: "At a right-hand dock it grows leftward from the mark, so it is mirrored: the words sit over the mark the pointer came from, the commands at the far end.",
                                  file: "panel-\(id)-\(theme).png", to: output))
        }
        try mirrored("floating-reading-stopped-right", "Floating: reading stopped, right-hand dock", .readingFailure, size: CaptureHUDLayout.compact)
        model.dismissReadingFailure()
        model.captureFailure = "The speech engine stopped before it finished."
        try mirrored("floating-dictation-failure-right", "Floating: dictation failure, right-hand dock", .dictationFailure, size: CaptureHUDLayout.message)
        model.dismissCaptureFailure()

        // The receipt's own countdown ring (#134 T5), frozen by a pointer hold so the render repeats.
        model.clipboardReceipt.record(outcome: .init(message: TextDelivery.copiedMessage, clipboardChangeCount: NSPasteboard.general.changeCount,
                                                     wasPasted: false, destinationName: nil), wordCount: 42)
        model.clipboardReceipt.holdHUD(true)
        do {
            // The receipt as the toolbar reveals it from the mark's clipboard status (#134 T4).
            let size = CaptureHUDLayout.message
            let content = FloatingResultView(result: .receipt, model: model, controls: controls)
            let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = offscreenWindow(size: size, styleMask: [.borderless])
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            settle(host)
            shots.append(try save(try snapshot(host), id: "floating-receipt", title: "Floating: copied receipt",
                                  detail: "Its ring counts the receipt's own eight seconds; the pointer or a pin holds it.",
                                  file: "panel-floating-receipt-\(theme).png", to: output))
        }
        try mirrored("floating-receipt-right", "Floating: copied receipt, right-hand dock", .receipt, size: CaptureHUDLayout.message)
        model.clipboardReceipt.holdHUD(false)
        model.clipboardReceipt.clear()

        // The one-time coaching card, shown by a host, with its ring half spent and, for VoiceOver, still.
        for (id, title, detail, fraction, voiceOver) in [
            ("floating-coach", "Floating: hold lesson", "After a too-short press of the Dictate shortcut in Hold, once. Its ring is half spent at two of four seconds.", 0.5, false),
            ("floating-coach-voiceover", "Floating: hold lesson with VoiceOver", "With VoiceOver on it waits for Dismiss hint, with a still close control.", 1.0, true)] {
            let tips = CoachTips(defaults: try SurfaceGallery.isolatedDefaults("Coach-" + id, home: home))
            let coach = FeedbackCoachModel(tips: tips, clock: { 100 }, workspace: NotificationCenter(), distributed: NotificationCenter())
            coach.voiceOverEnabled = { voiceOver }; coach.announce = { _ in }; coach.canPresent = { true }
            let card = HoldLesson.card(shortcut: VoicePreferences.defaultDictationShortcut.label)
            guard coach.request(card) else { throw VoiceError.message("The gallery's coach did not accept its card.") }
            coach.didPresent(card.id)
            // The host proposes the card's standard width; its text wraps and it grows downward.
            let view = CoachCardView(coach: coach, fixedFraction: fraction).frame(width: 320)
                .fixedSize(horizontal: false, vertical: true).padding(12)
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            let window = offscreenWindow(size: host.fittingSize, styleMask: [.borderless])
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            settle(host)
            window.setContentSize(host.fittingSize)
            settle(host, seconds: 0.05)
            shots.append(try save(try snapshot(host), id: id, title: title, detail: detail, file: "panel-\(id)-\(theme).png", to: output))
        }

        // The menu-bar panel's shelf for a delivery that did not finish (#134 T5): once
        // with its transcript in History, and once for a draft that has changed since.
        let words = SurfacePass.history[0]
        let failed = TextDelivery.Outcome(message: "Could not copy the transcript.", clipboardChangeCount: nil, wasPasted: false,
                                          destinationName: nil, failure: .copyFailed)
        let then = DeliveryRecords(history: [words], draft: (text: words.text, revision: 1))
        let now = DeliveryRecords(history: [words], draft: (text: "A newer draft replaced it.", revision: 2))
        var fromHistory = UnresolvedDeliverySlot(), fromDraft = UnresolvedDeliverySlot()
        fromHistory.note(failed, text: words.text, from: .transcript(words.id), in: then)
        fromDraft.note(failed, text: words.text, from: .draft(revision: 1), in: then)
        for (id, title, detail, entry) in [
            ("shelf-undelivered", "Panel shelf: copy failed", "Kept after the receipt goes and across quit, with where the words are, Review text, Copy again and Dismiss.",
             fromHistory.shown(in: now)),
            ("shelf-draft-changed", "Panel shelf: the draft changed", "A failed copy of the draft once the draft has changed: Review text opens Dictate, and there is no Copy again.",
             fromDraft.shown(in: now))] {
            let receipts = ClipboardReceiptModel(clipboardChangeCount: { 0 }, automaticallySchedules: false)
            let view = WorkbenchClipboardShelf(receipts: receipts, unresolved: entry, review: {}, showCue: {})
                .frame(width: 304).fixedSize(horizontal: false, vertical: true).padding(12)
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            let window = offscreenWindow(size: host.fittingSize, styleMask: [.borderless])
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            settle(host)
            window.setContentSize(host.fittingSize)
            settle(host, seconds: 0.05)
            shots.append(try save(try snapshot(host), id: id, title: title, detail: detail, file: "panel-\(id)-\(theme).png", to: output))
        }
        return shots
    }

    // MARK: Folded page states

    /// Library's Resources with long names and one selected, and Settings' Models while a
    /// dictation records, at the minimum window size: the folded pages with long labels and an
    /// active job (#134). Between the two, every page and section opens in turn; the draft, the
    /// selections and the recording must come through unchanged, or the pass fails.
    func renderFoldedStates(to output: URL) throws -> [(String, [SurfaceGallery.Shot])] {
        let size = SurfaceGallery.sizes[1].size, library = model.library
        let window = homeWindow(size: size)
        defer { window.contentViewController = nil; window.close(); model.phase = .idle; model.elapsed = 0 }
        var added: [DemoResource] = []
        defer { for item in added { library.remove(item) }; library.notice = nil }
        for title in ["Quarterly pricing walkthrough for the regional partner review, with the revised numbers",
                      "Onboarding checklist for presenters joining the Thursday demo rotation",
                      "Follow-up prompt: summarise the objections from the procurement call and propose next steps"] {
            let item = DemoResource(title: title, product: "Synthetic product with a longer name", persona: "Operations lead", content: "Synthetic text for \(title).")
            guard library.save(item) else { throw VoiceError.message("The gallery could not save a synthetic resource: \(library.error ?? "unknown").") }
            added.append(item)
        }
        library.selection = added[0].id; library.notice = nil
        let (resources, resourcesSize) = try renderPage("library", in: window)
        let libraryShot = try save(resources, id: "state-long-names", title: "Resources with long names, one selected, minimum window, \(Int(resourcesSize.width)) × \(Int(resourcesSize.height)) pt",
                                   detail: "Three synthetic resources with long titles; the first is selected and its detail shows.", file: "page-library-state-long-names-\(theme).png", to: output)
        model.phase = .recording; model.elapsed = 14
        let kept = (draft: model.transcript, selection: model.historyLibrary.selected, resource: library.selection)
        for route in SurfacePass.pages.map(\.0) + ["library"] { model.page = route; settle(window.contentView?.superview ?? window.contentView!, seconds: 0.05) }
        guard model.transcript == kept.draft, model.historyLibrary.selected == kept.selection, library.selection == kept.resource, model.phase == .recording else {
            throw VoiceError.message("Opening every page and section changed the Dictate draft, a selection or the recording.")
        }
        let (models, modelsSize) = try renderPage("models", in: window)
        let modelsShot = try save(models, id: "state-dictating", title: "Models while a dictation records, minimum window, \(Int(modelsSize.width)) × \(Int(modelsSize.height)) pt",
                                  detail: "A recording holds the speech model: the controls wait until it finishes.", file: "page-models-state-dictating-\(theme).png", to: output)
        model.phase = .idle; model.elapsed = 0
        // General before any dictation: Show me a first dictation sits beside Dictate options… (#15).
        let before = (history: model.history, guide: model.preferences.firstDictationGuide)
        model.history = []; model.preferences.firstDictationGuide = nil
        defer { model.history = before.history; model.preferences.firstDictationGuide = before.guide }
        let (general, generalSize) = try renderPage("settings", in: window)
        let generalShot = try save(general, id: "state-before-first-dictation", title: "General before the first dictation, minimum window, \(Int(generalSize.width)) × \(Int(generalSize.height)) pt",
                                   detail: "Nothing dictated yet: Show me a first dictation sits beside Dictate options… and opens Home on the guide.",
                                   file: "page-settings-state-before-first-dictation-\(theme).png", to: output)
        return [("library", [libraryShot]), ("models", [modelsShot]), ("settings", [generalShot])]
    }

    // MARK: Read states

    /// Read after a reading stopped because its audio could not be read (one error with Retry,
    /// and the text back in the editor), and with a History transcript waiting for Replace
    /// reading or Keep current over a different draft.
    func renderReadStates(to output: URL) throws -> [SurfaceGallery.Shot] {
        let size = SurfaceGallery.sizes[0].size
        let window = homeWindow(size: size)
        defer { window.contentViewController = nil; window.close(); model.dismissReadingFailure() }
        model.importReading("The workshop starts at nine with a short review of last week's notes. Maya walks through the revised budget.", from: .savedText)
        model.reportReadingFailure(.audioUnreadable)
        var (rep, drawn) = try renderPage("speak", in: window)
        var shots = [try save(rep, id: "state-audio-unreadable", title: "Read, audio could not be read, \(Int(drawn.width)) × \(Int(drawn.height)) pt",
                              detail: "The reading stopped; the text is editable again and Retry makes new audio.",
                              file: "page-speak-state-audio-unreadable-\(theme).png", to: output)]
        model.dismissReadingFailure()
        model.importReading(SurfacePass.history[0].text, from: .transcript)
        defer { model.keepCurrentReading() }
        for (name, size) in SurfaceGallery.sizes {
            let sized = name == "default" ? window : homeWindow(size: size)
            defer { if sized !== window { sized.contentViewController = nil; sized.close() } }
            (rep, drawn) = try renderPage("speak", in: sized)
            shots.append(try save(rep, id: "state-import-review-\(name)", title: "Read, a transcript to review, \(Int(drawn.width)) × \(Int(drawn.height)) pt",
                                  detail: "Read aloud on a History transcript while a different draft is in Read: nothing changes until Replace reading or Keep current.",
                                  file: "page-speak-state-import-review-\(name)-\(theme).png", to: output))
        }
        return shots
    }

    // MARK: Home checks

    /// Home's Recent work reviews its exact item (#134 H1). Opening a transcript from Home shows it
    /// in History and changes nothing else: Dictate's draft stays byte for byte, the shared
    /// selection stays, and redrawing Home asks History for nothing. Throws if any of that moved.
    func checkHomeReview(to output: URL) throws -> (checks: [String], shot: SurfaceGallery.Shot) {
        let window = homeWindow(size: SurfaceGallery.sizes[1].size)
        defer { window.contentViewController = nil; window.close() }
        let draft = "An edited Dictate draft that must survive: " + model.transcript
        let keptDraft = model.transcript, keptSelection = model.historyLibrary.selected
        defer { model.transcript = keptDraft; model.historyLibrary.setSelected(keptSelection) }
        model.transcript = draft
        let selection: Set<WorkbenchItemReference> = [.init(kind: .transcript, id: SurfacePass.history[0].id)]
        model.historyLibrary.setSelected(selection)
        model.historyDoor = nil
        _ = try renderPage("home", in: window)
        _ = try renderPage("home", in: window)
        guard model.historyDoor == nil, model.transcript == draft, model.historyLibrary.selected == selection else {
            throw VoiceError.message("Drawing Home changed History's door, the Dictate draft or the selection.")
        }
        // The same door the row's title uses, for an older transcript.
        let older = SurfacePass.history[2]
        guard let door = HomeRecentWork.review(for: .transcript(older)) else { throw VoiceError.message("A recent transcript had no review.") }
        model.openHistory(door)
        guard model.page == "history", model.historyDoor?.transcript == older.id, model.historyDoor?.filter == .all else {
            throw VoiceError.message("A recent transcript did not open History on it.")
        }
        let (history, size) = try renderPage("history", in: window)
        guard model.transcript == draft, model.historyLibrary.selected == selection, model.historyDoor == nil else {
            throw VoiceError.message("Opening a recent transcript changed the Dictate draft or the selection, or History kept the door.")
        }
        let shot = try save(history, id: "state-from-home", title: "History, showing a transcript Home opened, \(Int(size.width)) × \(Int(size.height)) pt",
                            detail: "Home's Recent work opened the oldest synthetic transcript: History shows All, scrolled to it and outlined; the selected transcript stays selected.",
                            file: "page-history-state-from-home-\(theme).png", to: output)
        return (["Drawing Home twice leaves History's door unset, the Dictate draft and the shared selection as they were.",
                 "An older transcript's title opens History on All, showing it; the edited Dictate draft is unchanged byte for byte and the selection is kept."], shot)
    }

    /// Home at 1.35 times its text in the minimum window's content column. SwiftUI's text styles do
    /// not follow a larger text size on macOS, so the page is laid out in a column 1.35 times
    /// narrower and drawn 1.35 times larger: every title, tile and row must wrap rather than clip.
    func renderHomeLargerText(to output: URL) throws -> SurfaceGallery.Shot {
        let scale: CGFloat = 1.35, size = NSSize(width: SurfaceGallery.sizes[1].size.width - 216, height: SurfaceGallery.sizes[1].size.height)
        model.page = "home"
        let page = WorkbenchHomePage(model: model, stage: stage, readback: readback, snap: snap, introduction: FounderIntroductionModel(),
                                     jobs: model.handoffJobs, photos: model.photoHandoff, meetings: model.meetings)
            .frame(width: size.width / scale, height: size.height / scale).scaleEffect(scale, anchor: .topLeading)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Workbench.background).tint(Workbench.accent).workbenchTheme()
        let host = NSHostingView(rootView: page)
        let window = offscreenWindow(size: size, styleMask: [.borderless])
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host, seconds: 1)
        return try save(try snapshot(host), id: "state-larger-text", title: "Home at 1.35 times the text size, minimum window's content column",
                        detail: "The page drawn 1.35 times larger in the same column: the title, tiles and recent rows wrap and grow, and nothing clips.",
                        file: "page-home-state-larger-text-\(theme).png", to: output)
    }

    /// Home with photos saved from iPhone days before the newest capture (#134 H1). They are
    /// Library's, so Recent work stays History's five newest, and the quiet link under it gives
    /// their count and the newest photo's stored date. The photos are a synthetic local library
    /// in the pass's own folder, with no image files and no iCloud.
    func renderHomeSavedPhotos(to output: URL) throws -> SurfaceGallery.Shot {
        let folder = home.appendingPathComponent("Gallery Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let newestCapture = SurfacePass.history.map(\.date).max()!
        func photo(daysBefore days: Double, _ title: String) -> [String: Any] {
            ["id": UUID().uuidString, "title": title, "created": newestCapture.addingTimeInterval(-days * 86_400).timeIntervalSinceReferenceDate,
             "sourceDevice": "iPhone", "disposition": "local", "digest": String(repeating: "a", count: 64), "byteCount": 1_000,
             "width": 10, "height": 10, "hasOriginal": false]
        }
        let library: [String: Any] = ["version": 1, "photos": [photo(daysBefore: 5, "Whiteboard"), photo(daysBefore: 9, "Receipt")],
                                      "enabled": false, "accounts": [Any](), "suppressed": [Any]()]
        try JSONSerialization.data(withJSONObject: library).write(to: folder.appendingPathComponent("photos.json"))
        let photos = PhotoHandoffModel(directory: folder, platform: "Mac", allowsCloudAccess: false)
        guard photos.photos.count == 2 else { throw VoiceError.message("The synthetic iPhone photos did not load: \(photos.error ?? "none listed").") }
        let size = NSSize(width: SurfaceGallery.sizes[1].size.width - 216, height: SurfaceGallery.sizes[1].size.height)
        model.page = "home"
        let page = WorkbenchHomePage(model: model, stage: stage, readback: readback, snap: snap, introduction: FounderIntroductionModel(),
                                     jobs: model.handoffJobs, photos: photos, meetings: model.meetings)
            .frame(width: size.width, height: size.height).tint(Workbench.accent).workbenchTheme()
        let host = NSHostingView(rootView: page)
        let window = offscreenWindow(size: size, styleMask: [.borderless])
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host, seconds: 1)
        return try save(try snapshot(host), id: "state-saved-photos", title: "Home with photos saved from iPhone, minimum window's content column",
                        detail: "Two synthetic photos saved 5 and 9 days before the newest capture: Recent work is still History's five newest, and the quiet link under it reads Saved from iPhone with the count and the newest photo's stored date.",
                        file: "page-home-state-saved-photos-\(theme).png", to: output)
    }

    // MARK: Floating toolbar visibility

    /// The floating toolbar's one switch from its doors (#134 H3): the panel's header switch,
    /// Settings › General's switch, the Window menu and the toolbar's own More › Hide toolbar
    /// read and change the one saved preference, and each shows what the others did. More's item
    /// is read from the menu the toolbar builds when More opens, and chosen as a menu chooses it.
    /// The panel header's whole 32 point row is the switch's target, and the switch is its one
    /// accessibility element. Which surface shows over live work is CaptureHUDChecks' (#155).
    func checkToolbarVisibility() throws -> [String] {
        let kept = model.floatingToolbarVisible
        defer { model.floatingToolbarVisible = kept }
        func switches(in view: NSView) -> [NSSwitch] { (view as? NSSwitch).map { [$0] } ?? view.subviews.flatMap(switches) }
        let panelHost = NSHostingView(rootView: quickPanel(readback).background(Color(nsColor: .windowBackgroundColor)))
        let panelWindow = offscreenWindow(size: panelHost.fittingSize, styleMask: [.borderless])
        panelWindow.contentView = panelHost
        defer { panelWindow.contentView = nil; panelWindow.close() }
        let settingsWindow = homeWindow(size: SurfaceGallery.sizes[0].size)
        defer { settingsWindow.contentViewController = nil; settingsWindow.close() }
        model.page = "settings"
        let settingsFrame = settingsWindow.contentView?.superview ?? settingsWindow.contentView!
        let windowMenu = shell.makeMainMenu().main.items.compactMap(\.submenu).first { $0.title == "Window" }
        guard let item = windowMenu?.items.first(where: { $0.action == #selector(AppDelegate.toggleFloatingToolbar) }) else {
            throw VoiceError.message("The Window menu has no floating toolbar item.")
        }
        func agree(_ visible: Bool, after door: String) throws {
            settle(panelHost, seconds: 0.15); settle(settingsFrame, seconds: 0.15)
            _ = shell.validateMenuItem(item)
            let panel = switches(in: panelHost), settings = switches(in: settingsFrame)
            guard model.floatingToolbarVisible == visible, panel.count == 1, settings.count == 1,
                  (panel[0].state == .on) == visible, (settings[0].state == .on) == visible,
                  item.title == AppDelegate.floatingToolbarTitle(visible: visible) else {
                throw VoiceError.message("After \(door), the floating toolbar's doors disagree: saved \(model.floatingToolbarVisible), "
                    + "panel \(panel.map(\.state.rawValue)), Settings \(settings.map(\.state.rawValue)), Window \(item.title).")
            }
        }
        model.floatingToolbarVisible = true
        try agree(true, after: "turning it on")
        switches(in: panelHost).first?.performClick(nil)
        try agree(false, after: "the panel's switch")
        switches(in: settingsFrame).first?.performClick(nil)
        try agree(true, after: "Settings' switch")
        NSApp.sendAction(item.action!, to: shell, from: item)
        try agree(false, after: "the Window menu")
        NSApp.sendAction(item.action!, to: shell, from: item)
        try agree(true, after: "the Window menu again")
        // The fourth door, the toolbar's own More › Hide toolbar (#134 T4, H3): the item as More
        // builds it for a toolbar that is showing, chosen as a menu chooses it.
        let controls = CaptureHUDControls(defaults: try SurfaceGallery.isolatedDefaults("ToolbarVisibility", home: home))
        let toolbar = FloatingToolbar(model: model, readback: readback, stage: stage, controls: controls, promptInsertion: model.promptInsertion,
                                      meetings: model.meetings, snapModel: snap, receipts: model.clipboardReceipt,
                                      dictate: {}, snap: {}, snapCapture: {}, draw: {}, present: {})
        guard let hide = toolbar.moreMenu().items.first(where: { $0.title == "Hide toolbar" }), let action = hide.action else {
            throw VoiceError.message("The toolbar's More has no Hide toolbar.")
        }
        NSApp.sendAction(action, to: hide.target, from: hide)
        try agree(false, after: "the toolbar's More › Hide toolbar")
        switches(in: panelHost).first?.performClick(nil)
        try agree(true, after: "the panel's switch, after More › Hide toolbar")

        // The header's whole switch row is one control (#134 review): a click on the words, beside
        // them, above or below them or on the switch toggles once, and a click just outside the
        // 32 point row lands elsewhere. Each click goes to the view AppKit's hit test picks.
        guard let row = Self.panelSwitchRows(in: panelHost).first, row.bounds.height >= PanelSwitch.Row.minimumHeight else {
            throw VoiceError.message("The panel header's Floating toolbar row is missing or shorter than \(Int(PanelSwitch.Row.minimumHeight)) points.")
        }
        let root = panelHost.superview ?? panelHost, control = row.control
        let area = row.convert(row.bounds, to: nil), knob = control.convert(control.bounds, to: nil), words = row.label.convert(row.label.bounds, to: nil)
        let points: [(String, NSPoint)] = [
            ("the words", NSPoint(x: words.midX, y: words.midY)), ("the gap beside the switch", NSPoint(x: knob.minX - 3, y: knob.midY)),
            ("the row above the words", NSPoint(x: words.midX, y: area.maxY - 1)), ("the row below the words", NSPoint(x: words.midX, y: area.minY + 1)),
            ("the row above the switch", NSPoint(x: knob.midX, y: area.maxY - 1)), ("the switch", NSPoint(x: knob.midX, y: knob.midY))]
        for (place, point) in points {
            guard let hit = root.hitTest(root.convert(point, from: nil)), hit === row || hit.isDescendant(of: control) else {
                throw VoiceError.message("A click on \(place) in the panel header does not reach the Floating toolbar switch.")
            }
            let before = model.floatingToolbarVisible
            click(hit, at: point, in: panelWindow)
            try agree(!before, after: "a click on \(place)")
        }
        let outside = NSPoint(x: words.midX, y: area.maxY + 3)
        if let hit = root.hitTest(root.convert(outside, from: nil)), hit === row || hit.isDescendant(of: row) {
            throw VoiceError.message("The Floating toolbar row takes clicks beyond its own height.")
        }
        // One accessibility element, the switch, whose value follows the preference; VoiceOver's
        // press and Space on the focused switch each toggle it once.
        let value = { ((control as NSObject).value(forKey: "accessibilityValue") as? NSNumber)?.boolValue }
        guard !row.isAccessibilityElement(), !row.label.isAccessibilityElement(), control.isAccessibilityElement(),
              control.accessibilityLabel() == "Floating toolbar", control.accessibilitySubrole() == .switch,
              value() == model.floatingToolbarVisible else {
            throw VoiceError.message("The panel header's switch is not one accessibility element named Floating toolbar with its On or Off value.")
        }
        var before = model.floatingToolbarVisible
        _ = control.accessibilityPerformPress()
        try agree(!before, after: "VoiceOver's press")
        guard value() == model.floatingToolbarVisible else { throw VoiceError.message("The switch's accessibility value did not follow VoiceOver's press.") }
        guard panelWindow.makeFirstResponder(control) else { throw VoiceError.message("The panel header's switch cannot take keyboard focus.") }
        before = model.floatingToolbarVisible
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            panelWindow.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: panelWindow.windowNumber, context: nil, characters: " ",
                                                   charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!)
        }
        try agree(!before, after: "Space on the focused switch")
        return ["The panel's switch, Settings › General's switch and the Window menu each turned the floating toolbar off or on, and every other door then showed the same: the switches' states and Show or Hide floating toolbar.",
                "In the panel header, a click on the words Floating toolbar, the gap beside the switch, the row above and below the words, the row above the switch and the switch itself each toggled it once; a click 3 points above the 32 point row missed it.",
                "The header switch is the one accessibility element, named Floating toolbar with its On or Off value; VoiceOver's press and Space on the focused switch each toggled it once.",
                "The toolbar's own More › Hide toolbar, as More builds it, turned it off, and every other door then showed the same; the panel's switch turned it back on. Which surface shows during drawing, presenting, personas, recording, reading and insertion is checked by CaptureHUDChecks (#155)."]
    }

    /// The panel header's switch rows under `view`.
    static func panelSwitchRows(in view: NSView) -> [PanelSwitch.Row] {
        (view as? PanelSwitch.Row).map { [$0] } ?? view.subviews.flatMap(panelSwitchRows)
    }

    /// The panel header at 1.35 times the text size (#134 H3): the name and the Floating toolbar
    /// row take one scale, and the row grows with its words while staying at least 32 points high
    /// and inside the panel's width. The row's height is also checked at 1 and 3 times, where
    /// its words are taller than 32 points.
    func renderPanelHeaderLargerText(to output: URL) throws -> (shot: SurfaceGallery.Shot, checks: [String]) {
        func hosted<Content: View>(_ content: Content) -> (NSHostingView<AnyView>, NSWindow) {
            let host = NSHostingView(rootView: AnyView(content.background(Color(nsColor: .windowBackgroundColor))))
            let window = offscreenWindow(size: host.fittingSize, styleMask: [.borderless])
            window.contentView = host
            window.setContentSize(host.fittingSize)
            settle(host, seconds: 0.1)
            return (host, window)
        }
        var widths: [CGFloat] = []
        for scale: CGFloat in [1, 1.35, 3] {
            let (host, window) = hosted(PanelSwitch(title: "Floating toolbar", isOn: .constant(true), help: WorkbenchHome.floatingToolbarHelp,
                                                    textScale: scale).fixedSize())
            defer { window.contentView = nil; window.close() }
            guard let row = Self.panelSwitchRows(in: host).first else { throw VoiceError.message("The Floating toolbar row did not draw.") }
            let words = row.label.intrinsicContentSize.height, tallest = max(PanelSwitch.Row.minimumHeight, words, row.control.fittingSize.height)
            guard abs(row.bounds.height - tallest) < 0.5, row.label.frame.minY >= -0.5, row.label.frame.maxY <= row.bounds.height + 0.5 else {
                throw VoiceError.message("At \(scale) times the text size the Floating toolbar row is \(row.bounds.height) points high for words \(words) high.")
            }
            widths.append(row.bounds.width)
        }
        guard widths[0] < widths[1], widths[1] < widths[2] else { throw VoiceError.message("The Floating toolbar row did not widen with its words: \(widths).") }
        let scale: CGFloat = 1.35
        let (host, window) = hosted(WorkbenchQuickPanel.header(toolbarVisible: .constant(true), textScale: scale)
            .padding(WorkbenchQuickPanel.inset).frame(width: WorkbenchQuickPanel.width))
        defer { window.contentView = nil; window.close() }
        guard let row = Self.panelSwitchRows(in: host).first else { throw VoiceError.message("The panel header did not draw its switch row.") }
        let frame = row.convert(row.bounds, to: host)
        guard frame.height >= PanelSwitch.Row.minimumHeight, frame.minX >= WorkbenchQuickPanel.inset - 0.5,
              frame.maxX <= WorkbenchQuickPanel.width - WorkbenchQuickPanel.inset + 0.5 else {
            throw VoiceError.message("At \(scale) times the text size the Floating toolbar row leaves the panel's width: \(frame).")
        }
        let shot = try save(try snapshot(host), id: "header-larger-text", title: "Panel header, 1.35 times the text size",
                            detail: "The name and the Floating toolbar row take the panel's one text scale: the row widens with its words, stays 32 points high and fits the panel's 320 points.",
                            file: "panel-header-larger-text-\(theme).png", to: output)
        return (shot, ["The panel header's Floating toolbar row is exactly as tall as the taller of 32 points and its words at 1, 1.35 and 3 times the text size (\(widths.map { String(Int($0.rounded())) }.joined(separator: ", ")) points wide), and at 1.35 times it fits inside the panel's 320 points."])
    }

    /// A click delivered straight to the view AppKit's hit test picked: the gallery's windows are
    /// never on screen, so the window server routes nothing to them. The release is queued first
    /// for a control that tracks the mouse itself, as NSSwitch does, and handed over otherwise.
    func click(_ view: NSView, at point: NSPoint, in window: NSWindow) {
        let time = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, after delay: TimeInterval) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time + delay, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        NSApp.postEvent(event(.leftMouseUp, after: 0.05), atStart: false)
        view.mouseDown(with: event(.leftMouseDown, after: 0))
        if let release = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { view.mouseUp(with: release) }
    }

    // MARK: Dictate states

    /// The newcomer's manual copy (#134 C10, #165): Paste automatically waits for an Accessibility
    /// approval an organisation may have to give, so the finished transcript was copied. The task
    /// region shows the words with the copy as the result, and Set up automatic paste… beside
    /// Delivery as an option; nothing waits on the approval. Only the model's status is set, as a
    /// dictation leaves it; the clipboard is not touched. The pass's draft, status, delivery and
    /// approval are restored afterwards.
    func renderDictateStates(to output: URL) throws -> [SurfaceGallery.Shot] {
        let kept = (draft: model.transcript, raw: model.rawTranscript, status: model.status,
                    delivery: model.preferences.delivery, granted: model.accessibilityGranted)
        let window = homeWindow(size: SurfaceGallery.sizes[0].size)
        defer {
            window.contentViewController = nil; window.close()
            model.transcript = kept.draft; model.rawTranscript = kept.raw; model.status = kept.status
            model.preferences.delivery = kept.delivery; model.accessibilityGranted = kept.granted
        }
        let words = SurfacePass.history[1].text
        model.preferences.delivery = .paste; model.accessibilityGranted = false
        model.rawTranscript = words; model.transcript = words; model.status = TextDelivery.copiedMessage
        let (rep, drawn) = try renderPage("dictate", in: window)
        var shots = [try save(rep, id: "state-manual-copy", title: "Dictate, copied for ⌘V, \(Int(drawn.width)) × \(Int(drawn.height)) pt",
                         detail: "Paste automatically is chosen and waits for Accessibility approval, so the transcript was copied: the result reads Copied. Paste with ⌘V., and Set up automatic paste… sits beside Delivery.",
                         file: "page-dictate-state-manual-copy-\(theme).png", to: output)]
        // Settings' Dictate options… lands on the options, not the top of the page (#134 H2).
        let narrow = homeWindow(size: SurfaceGallery.sizes[1].size)
        defer { narrow.contentViewController = nil; narrow.close() }
        model.page = "settings"; settle(narrow.contentView?.superview ?? narrow.contentView!)
        model.focusRequest = PageFocusRequest(target: .dictateOptions)
        model.page = "dictate"
        let optionsFrame = narrow.contentView?.superview ?? narrow.contentView!
        // The page takes the request asynchronously. Wait for it rather than one fixed settle, which
        // a busy runner can outlast; the check still fails if the request is never taken.
        let taken = Date().addingTimeInterval(3)
        repeat { settle(optionsFrame, seconds: 0.1) } while model.focusRequest != nil && Date() < taken
        guard model.focusRequest == nil else { throw VoiceError.message("Dictate did not take Settings' request to show its options.") }
        settle(optionsFrame)
        let (options, optionsSize) = (try snapshot(optionsFrame), optionsFrame.bounds.size)
        shots.append(try save(options, id: "state-options-focused", title: "Dictate, from Settings › Dictate options…, \(Int(optionsSize.width)) × \(Int(optionsSize.height)) pt",
                              detail: "The page opens scrolled to its Options, where VoiceOver starts.", file: "page-dictate-state-options-focused-\(theme).png", to: output))
        return shots
    }

    // MARK: Home states

    /// The first-dictation journey (#15): the guide beside earlier Snaps, the
    /// ordinary Home after Skip for now with its way back, and the guide's result
    /// right after a first dictation. Synthetic history only; the pass's own
    /// history, draft and guide choice are restored afterwards.
    func renderHomeStates(to output: URL) throws -> [SurfaceGallery.Shot] {
        let size = NSSize(width: 1180, height: 1_000)
        let kept = (history: model.history, draft: model.transcript, raw: model.rawTranscript, guide: model.preferences.firstDictationGuide)
        defer {
            model.history = kept.history; model.transcript = kept.draft; model.rawTranscript = kept.raw
            model.preferences.firstDictationGuide = kept.guide
        }
        var shots: [SurfaceGallery.Shot] = []
        func shot(_ id: String, _ title: String, _ detail: String, then change: (() -> Void)? = nil) throws {
            let window = offscreenWindow(size: size, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
            window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            defer { window.contentViewController = nil; window.close() }
            model.page = "home"
            window.contentViewController = NSHostingController(rootView: WorkbenchHome(model: model, stage: stage, keyboard: keyboard, readback: readback, snap: snap))
            window.setContentSize(size)
            let frame = window.contentView?.superview ?? window.contentView!
            settle(frame, seconds: 1)
            if let change { change(); settle(frame, seconds: 1) }
            shots.append(try save(try snapshot(frame), id: "state-\(id)", title: title, detail: detail, file: "page-home-state-\(id)-\(theme).png", to: output))
        }
        model.history = []; model.transcript = ""; model.rawTranscript = ""
        model.preferences.firstDictationGuide = nil
        try shot("first-dictation", "First dictation, beside earlier Snaps", "Nothing dictated yet but Snaps saved: the guide stays, with Skip for now, and recent work below it.")
        model.preferences.firstDictationGuide = .skipped
        try shot("guide-skipped", "Guide skipped", "After Skip for now: the ordinary Home, with Show me a first dictation until someone dictates.")
        model.preferences.firstDictationGuide = .offered
        let first = SurfacePass.history[1]
        try shot("first-result", "First result", "Right after the first dictation: the words, their delivery controls and where they were saved.") { [self] in
            model.rawTranscript = first.text; model.transcript = first.text; model.history = [first]
        }
        // Current work, above everything: a dictation recording, then a paused reading (#134 H1).
        model.history = kept.history; model.transcript = kept.draft; model.rawTranscript = kept.raw
        model.preferences.firstDictationGuide = .completed
        let phase = model.phase
        try shot("current-work", "Current work", "A dictation recording, then a paused reading, each with its own action; the Dictate and Read tiles step aside.") { [self] in
            model.phase = .recording; model.elapsed = 12; model.paused = true
        }
        model.phase = phase; model.elapsed = 0; model.paused = false
        return shots
    }

    // MARK: History states

    /// A provider that never starts a process: it accepts each task, then finishes it, fails it or
    /// keeps it running until cancelled, by the task's request.
    static let syntheticProvider = HandoffRunner(
        discover: { SubscriptionConnection(provider: $0, executable: URL(fileURLWithPath: "/usr/bin/false"), version: "synthetic",
                                           ready: true, detail: "Synthetic connection; nothing is sent.") },
        run: { _, prompt, _, _, onSession in
            onSession("synthetic-session")
            if prompt.contains("Task: Plan the walkthrough.") { try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000) }
            if prompt.contains("Task: Summarize the pricing change.") { throw SubscriptionCLIError.failed("The synthetic provider stopped before it finished.") }
            return SubscriptionCLIResult(providerSessionID: "synthetic-session", text: "# Follow-up for Sam\n\nA synthetic result.")
        })

    /// Spins the main run loop, where the model's tasks finish, until `done` or a deadline.
    func wait(_ what: String, seconds: TimeInterval = 10, until done: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        guard done() else { throw VoiceError.message("History state not reached: \(what).") }
    }

    /// History at the default width and a taller height: empty; transcripts, Snaps and tasks
    /// together with two items selected; Results with running, completed, failed and Ready tasks;
    /// and Transcripts, as Dictate's History… opens it. Tasks are prepared through the app's own
    /// handoff model with a fixed clock and the synthetic provider above.
    func renderHistoryStates(to output: URL) throws -> [SurfaceGallery.Shot] {
        let size = NSSize(width: 1180, height: 1_180), jobs = model.handoffJobs, library = model.historyLibrary
        // A Snap folder that does not exist yet reads as an empty history.
        let emptySnaps = SnapModel(store: SnapStore(root: home.appendingPathComponent("Empty Snaps", isDirectory: true)), desktop: home.appendingPathComponent("Desktop"),
                                   trash: { _ in throw SnapError.message("The surface gallery never moves files to the Trash.") }, screenAccess: .fixed(true))
        var shots: [SurfaceGallery.Shot] = []
        func shot(_ id: String, _ title: String, _ detail: String, snaps: SnapModel, door: HistoryDoor? = nil) throws {
            let window = offscreenWindow(size: size, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
            window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            defer { window.contentViewController = nil; window.close() }
            model.historyDoor = door; model.page = "history"
            window.contentViewController = NSHostingController(rootView: WorkbenchHome(model: model, stage: stage, keyboard: keyboard, readback: readback, snap: snaps))
            window.setContentSize(size)
            let frame = window.contentView?.superview ?? window.contentView!
            settle(frame, seconds: 1)
            let rep = try snapshot(frame)
            shots.append(try save(rep, id: "state-\(id)", title: title, detail: detail, file: "page-history-state-\(id)-\(theme).png", to: output))
        }

        model.history = []
        try shot("empty", "History, empty", "Nothing dictated, snapped or handed off yet.", snaps: emptySnaps)
        model.history = SurfacePass.history

        // Four tasks between the synthetic captures, each through the real handoff model.
        var now = Date(timeIntervalSince1970: 1_789_300_000)
        jobs.clock = { now }; jobs.runner = SurfacePass.syntheticProvider
        jobs.setEnabled(.claude, true)
        try wait("a synthetic connection") { jobs.connections[.claude]?.ready == true }
        let resolve: (Set<WorkbenchItemReference>) throws -> [HandoffSourceSnapshot] = { [snap] references in
            try snap.handoffSnapshots(ids: Set(references.map(\.id))).map(\.reviewedHandoffSource)
        }
        func sources(_ references: [WorkbenchItemReference]) throws -> [HandoffSourceSnapshot] {
            try AppModel.handoffSources(selected: Set(references), history: model.history, library: library, additional: resolve)
        }
        let transcripts = SurfacePass.history.map { WorkbenchItemReference(kind: .transcript, id: $0.id) }
        let snaps = snap.items.map { WorkbenchItemReference(kind: .snap, id: $0.id) }
        let skill = try TranscriptHandoffSkill.followUp.load()
        _ = try jobs.prepare(sources: sources([transcripts[0], snaps[0]]), task: "Prepare the follow-up for Sam.", skill: skill)
        for (time, references, request, status) in [(1_789_400_000.0, [snaps[1]], "Summarize the pricing change.", HandoffJobStatus.failed),
                                                   (1_789_500_000.0, [transcripts[1]], "Draft the booking note.", .completed),
                                                   (1_789_546_900.0, [transcripts[2], snaps[2]], "Plan the walkthrough.", .running)] {
            now = Date(timeIntervalSince1970: time)
            let job = try jobs.prepare(sources: sources(references), task: request, skill: skill)
            jobs.start(job, provider: .claude)
            try wait("a \(status.rawValue) task") {
                let current = jobs.jobs.first { $0.id == job.id }
                return current?.status == status && (status != .running || current?.providerSessionID != nil)
            }
        }
        let loading = Task { await jobs.loadTaskFiles(jobs.jobs) }
        try wait("the tasks' saved inputs") { jobs.jobs.allSatisfy { jobs.files($0) != nil } }
        _ = loading
        library.setSelected([transcripts[0], snaps[0]])

        try shot("mixed", "History, All", "Transcripts, Snaps and Hand off tasks newest first, a task running above them and two items selected.", snaps: snap)
        try shot("results", "History, Results", "A running task with Stop above the list, then completed, failed and Ready tasks, each with what it was made from.",
                 snaps: snap, door: HistoryDoor(filter: .results))
        try shot("transcripts", "History, Transcripts", "As Dictate's History… opens it.", snaps: snap, door: HistoryDoor(filter: .transcripts))

        jobs.cancel()
        try wait("the running task to stop") { !jobs.isBusy }
        library.setSelected([])
        return shots
    }

    // MARK: Image preview

    /// The preview window at Home's default size: a full-display synthetic capture fitted to the
    /// window, the same at actual size, and a missing file. Its Snap lives in a store of its own, so
    /// the pages above are unchanged.
    func renderImagePreview(to output: URL) throws -> [SurfaceGallery.Shot] {
        // Snap storage wants the resolved spelling of its folder, as for the pages' Snaps.
        let folder = home.appendingPathComponent("Preview Snaps", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = SnapStore(root: folder.resolvingSymlinksInPath())
        let item = try store.insert(originalPNG: try CaptureImagePreviewChecks.screenPNG(width: 2_880, height: 1_800, heading: "Synthetic release notes"),
                                    width: 2_880, height: 1_800, title: "Release notes", source: .screen,
                                    id: UUID(uuidString: "5D1C0A1E-0000-4000-8000-000000000300")!, createdAt: Date(timeIntervalSince1970: 1_789_546_320))
        let owner = offscreenWindow(size: SurfaceGallery.sizes[0].size, styleMask: [.titled])
        let preview = CaptureImagePreview()
        preview.present = { _ in }
        defer { preview.close(); owner.close() }
        var shots: [SurfaceGallery.Shot] = []
        func shot(_ id: String, _ title: String, _ detail: String, _ item: CaptureImagePreviewItem, command: CaptureImagePreviewModel.Command? = nil) throws {
            preview.show(item, over: owner)
            guard let panel = preview.panel, let model = preview.model else { throw VoiceError.message("The image preview did not open.") }
            panel.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
            panel.setFrame(NSRect(origin: .zero, size: SurfaceGallery.sizes[0].size), display: false)
            let frame = panel.contentView?.superview ?? panel.contentView!
            try wait("the preview to load") { if case .loading = model.state { return false }; return true }
            settle(frame)
            if let command { model.perform(command); settle(frame, seconds: 0.1) }
            let rep = try snapshot(frame)
            shots.append(try save(rep, id: "preview-\(id)", title: title, detail: detail, file: "page-snap-preview-\(id)-\(theme).png", to: output))
        }
        try shot("fit", "Image preview, fitted", "A full-display synthetic capture opened from its thumbnail, fitted to the window.", .snap(item, store: store))
        try shot("actual", "Image preview, actual size", "The same capture after Actual size (⌘0): one image pixel per screen pixel.", .snap(item, store: store), command: .actualSize)
        let gone = ReadbackSection(id: UUID(uuidString: "5D1C0A1E-0000-4000-8000-000000000301")!, capturedAt: Date(timeIntervalSince1970: 1_789_546_320),
            displayName: "Synthetic display", directory: "items/gone", screenshot: "items/gone/screen.png", audio: nil, originalTranscript: nil,
            transcript: nil, status: .ready, failure: nil, deletedAt: nil)
        try shot("missing", "Image preview, missing file", "A Snap & Talk screenshot whose file is gone from its session folder.",
                 .section(gone, number: 3, session: home.appendingPathComponent("Snap & Talk/Moved session", isDirectory: true)))
        return shots
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

    /// Three Snaps with fixed dates, added through the store.
    static func makeSnaps(_ store: SnapStore) throws -> SnapStore {
        let titles = ["Pricing table before the change", "Onboarding checklist", "Error shown after saving"]
        for (index, title) in titles.enumerated() {
            let image = NSImage(size: NSSize(width: 640, height: 400))
            image.lockFocus()
            NSColor(calibratedHue: 0.12 + CGFloat(index) * 0.22, saturation: 0.22, brightness: 0.95, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 640, height: 400).fill()
            (title as NSString).draw(in: NSRect(x: 40, y: 170, width: 560, height: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.black])
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                throw VoiceError.message("Could not draw a synthetic Snap.")
            }
            let id = UUID(uuidString: "5D1C0A1E-0000-4000-8000-00000000020\(index)")!
            try store.insert(originalPNG: png, width: 640, height: 400, title: title, source: [SnapSource.region, .window, .screen][index],
                             tags: index == 0 ? ["pricing"] : [], id: id, createdAt: Date(timeIntervalSince1970: 1_789_546_320 - Double(index) * 86_400))
        }
        return store
    }

    // MARK: Screen Recording off

    /// The pages that capture the screen, with Screen Recording off: the Snap page, Home (its
    /// quick starts) and a Snap & Talk session. The Snaps and session are the same synthetic ones.
    func renderScreenAccessOff(to output: URL) throws -> [(String, SurfaceGallery.Shot)] {
        let noCapture: @MainActor () async throws -> ReadbackScreenshot = { throw ReadbackError.message("The surface gallery never captures the screen.") }
        let noSpeech: @MainActor (URL) async throws -> String = { _ in throw ReadbackError.message("The surface gallery never transcribes audio.") }
        let snapOff = SnapModel(store: SnapStore(root: snap.store.root), desktop: home.appendingPathComponent("Desktop"),
                                trash: { _ in throw SnapError.message("The surface gallery never moves files to the Trash.") }, screenAccess: .fixed(false))
        let sessionOff = ReadbackModel(engine: model.engine, defaults: sessionDefaults, captureDisplay: noCapture, transcribeAudio: noSpeech,
                                       screenAccess: .fixed(false))
        var shots: [(String, SurfaceGallery.Shot)] = []
        for (route, size, detail, readback) in [
            ("snap", SurfaceGallery.sizes[0].size, "Region, Window and Screen explain the missing access and offer Paste image, Import image and System Settings.", readback),
            ("home", SurfaceGallery.sizes[0].size, "Under the quick starts, a note says Screen Recording is off before Snap is chosen.", readback),
            ("readback", SurfaceGallery.sizes[0].size, "An open session explains the missing access; its screenshots and narration stay available.", sessionOff)] {
            let window = offscreenWindow(size: size, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
            window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            defer { window.contentViewController = nil; window.close() }
            model.page = route
            window.contentViewController = NSHostingController(rootView: WorkbenchHome(model: model, stage: stage, keyboard: keyboard, readback: readback, snap: snapOff))
            window.setContentSize(size)
            let frame = window.contentView?.superview ?? window.contentView!
            settle(frame, seconds: 1)
            let rep = try snapshot(frame)
            shots.append((route, try save(rep, id: "screen-access-off", title: "Screen Recording off", detail: detail,
                                         file: "page-\(route)-screen-access-off-\(theme).png", to: output)))
        }
        return shots
    }

    static func syntheticMeetings(_ directory: URL) -> MeetingModel {
        MeetingModel(directory: directory, defaults: .standard, processSource: SyntheticAudioApps(),
                     transcribe: { _ in throw MeetingError.message("The surface gallery never transcribes audio.") },
                     microphonePermission: { false }, captureFactory: { SilentMeetingCapture() })
    }

    /// Starts or cancels the synthetic meeting and waits on the main run loop, where its tasks run.
    /// A state that is not reached fails the pass rather than rendering the wrong panel.
    func drive(_ meetings: MeetingModel, start: Bool) throws {
        if start {
            meetings.includeMicrophone = false
            meetings.refreshApps(); meetings.selectedAppID = meetings.apps.first?.id
            Task { await meetings.start() }
        } else { Task { await meetings.cancel() } }
        let deadline = Date().addingTimeInterval(5)
        while (start ? !meetings.isRecording : meetings.isBusy) && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        guard start ? meetings.isRecording : !meetings.isBusy else {
            throw VoiceError.message("The synthetic meeting did not \(start ? "start" : "stop"): \(meetings.error ?? meetings.notice)")
        }
    }

    struct PanelState { var id, title, detail: String; var readback: ReadbackModel; var controlState: WorkbenchControlState? = nil; var apply: () throws -> Void = {}; var reset: () throws -> Void = {} }

    /// Voice fixtures use their isolated owners. Combined StageKit states use a frozen
    /// row projection, so the real panel draws them without opening overlays or capture.
    func panelStates() -> [PanelState] {
        let model = model
        var combined = WorkbenchControlState()
        combined.drawing = true; combined.presenting = true; combined.overlays = true
        combined.timerStarted = true; combined.timerRunning = true
        var recording = combined
        recording.phase = .recording; recording.mayPresent = false
        var hidden = recording
        hidden.overlaySession = true; hidden.overlaysPaused = true
        return [
            PanelState(id: "idle", title: "Idle", detail: "Speech ready, no session, nothing running.", readback: readback),
            PanelState(id: "toolbar-off", title: "Floating toolbar off", detail: "The header's switch is off: the toolbar stays hidden between actions.", readback: readback,
                       apply: { model.floatingToolbarVisible = false }, reset: { model.floatingToolbarVisible = true }),
            PanelState(id: "speech-not-ready", title: "Speech not ready", detail: "First run while the on-device model prepares.", readback: readback,
                       apply: { model.ready = false; model.preparing = true; model.modelMessage = "Preparing speech · first setup may take a few minutes" },
                       reset: { model.ready = true; model.preparing = false; model.modelMessage = "Preparing local speech…" }),
            PanelState(id: "dictating", title: "Dictating", detail: "Recording for 14 seconds.", readback: readback,
                       apply: { model.phase = .recording; model.elapsed = 14 }, reset: { model.phase = .idle; model.elapsed = 0 }),
            PanelState(id: "combined-live", title: "Drawing, presenting, Persona and timer",
                       detail: "Synthetic StageKit facts: each live row keeps its own Stop, End or Hide; Dictate, Read and Snap remain distinct.",
                       readback: readback, controlState: combined),
            PanelState(id: "dictating-live", title: "Dictating alongside live work",
                       detail: "Only Dictate says Stop. Draw, Present, Persona and Timer keep their own endings; incompatible new captures are disabled.",
                       readback: readback, controlState: recording,
                       apply: { model.phase = .recording; model.elapsed = 14 }, reset: { model.phase = .idle; model.elapsed = 0 }),
            PanelState(id: "persona-hidden-busy", title: "Hidden Persona set during dictation",
                       detail: "Show personas waits for its owner's resume admission. Present, Draw and Timer remain independently usable.",
                       readback: readback, controlState: hidden,
                       apply: { model.phase = .recording; model.elapsed = 14 }, reset: { model.phase = .idle; model.elapsed = 0 }),
            PanelState(id: "snap-session", title: "Snap & Talk session", detail: "A session with three captures.", readback: sessionReadback),
            PanelState(id: "reading", title: "Reading", detail: "Read aloud playing.", readback: readback,
                       apply: { model.playing = true }, reset: { model.playing = false }),
            PanelState(id: "clipboard", title: "Clipboard receipt", detail: "A 42-word transcript copied and still on the clipboard.", readback: readback,
                       apply: { model.clipboardReceipt.record(outcome: .init(message: "Copied to the clipboard.", clipboardChangeCount: NSPasteboard.general.changeCount,
                                                                             wasPasted: false, destinationName: nil), wordCount: 42) },
                       reset: { model.clipboardReceipt.clear() }),
            PanelState(id: "microphone-denied", title: "Microphone denied", detail: "The error a denied microphone leaves in the panel.", readback: readback,
                       apply: { model.report("Microphone access is off. Open System Settings → Privacy & Security → Microphone and allow Workbench.", on: .dictate) },
                       reset: { model.dismissError() }),
            PanelState(id: "reading-audio-unreadable", title: "Reading audio unreadable", detail: "The error a reading leaves when its audio cannot be read.", readback: readback,
                       apply: { model.reportReadingFailure(.audioUnreadable) }, reset: { model.dismissReadingFailure() }),
            PanelState(id: "meeting-recording", title: "Meeting recording", detail: "A meeting recording app audio, which shows the meeting status row.", readback: readback,
                       apply: { [self] in model.meetings = recordingMeetings; try drive(recordingMeetings, start: true) },
                       reset: { [self] in try drive(recordingMeetings, start: false); model.meetings = meetings }),
            PanelState(id: "shortcut-editor", title: "Shortcut editor", detail: "Snap's shortcut label clicked: the inline editor waits for keys. Closing the panel ends it.", readback: readback,
                       apply: { [self] in panelEditor.change("voice.8") }, reset: { [self] in panelEditor.end() })]
    }

    // MARK: Rendering

    func quickPanel(_ readback: ReadbackModel, controlState: WorkbenchControlState? = nil) -> WorkbenchQuickPanel {
        WorkbenchQuickPanel(model: model, stage: stage, readback: readback, keyboard: keyboard, editor: panelEditor, receipts: model.clipboardReceipt, snapModel: snap,
                            open: { [weak self] route in self?.opened.append(route) }, draw: {}, snap: {}, snapCapture: { _ in }, present: {}, timer: {}, personas: {}, controlState: controlState)
    }

    /// The popover's own material is not drawn; the panel sits on the window background.
    func renderPanel(_ readback: ReadbackModel, controlState: WorkbenchControlState? = nil) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: quickPanel(readback, controlState: controlState).background(Color(nsColor: .windowBackgroundColor)))
        let window = offscreenWindow(size: host.fittingSize, styleMask: [.borderless])
        window.contentView = host
        settle(host)
        window.setContentSize(host.fittingSize)
        settle(host, seconds: 0.05)
        defer { window.contentView = nil; window.close() }
        return try snapshot(host)
    }

    // MARK: Floating toolbar host

    /// The production toolbar host, `CapturePanelController`, with this pass's models. Its panel is
    /// ordered in with alpha zero and mouse events ignored, so it sizes exactly as the app's does
    /// without appearing. Each mode is driven at rest and revealed through the toolbar's own events,
    /// and the window's size is compared with what the same content wants, measured by a twin
    /// hosting view that sizes itself and reports to its own controls. The host pins seed sizes
    /// until the row reports (`CaptureHUDControls.reportSize`), so a row the host never heard from
    /// draws wider than its window; the view gallery cannot see that, because it sizes its own
    /// window to the content (#152).
    func renderToolbarHost(to output: URL) throws -> (shots: [SurfaceGallery.Shot], checks: [SurfaceGallery.HostCheck]) {
        // The host places its window on a screen; a Mac with none renders nothing rather than a false flag.
        guard NSScreen.main != nil else { return ([], []) }
        let defaults = try SurfaceGallery.isolatedDefaults("Toolbar", home: home)
        let controls = CaptureHUDControls(defaults: defaults)
        let host = CapturePanelController(model: model, readback: readback, stage: stage, snapModel: snap,
                                          dictate: {}, snap: {}, snapCapture: {}, draw: {}, present: {}, controls: controls)
        guard let panel = host.window, let content = panel.contentView else { throw VoiceError.message("The toolbar host has no window.") }
        panel.alphaValue = 0; panel.ignoresMouseEvents = true
        panel.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
        // The twin has its own controls, so its size reports never reach the host under test.
        let twinControls = CaptureHUDControls(defaults: defaults)
        twinControls.toolbar.activate()
        let twin = NSHostingView(rootView: WorkbenchFloatingContent(model: model, readback: readback, stage: stage, controls: twinControls, snapModel: snap,
                                                                     dictate: {}, snap: {}, snapCapture: {}, draw: {}, present: {}))
        let twinWindow = offscreenWindow(size: NSSize(width: 600, height: 60), styleMask: [.borderless])
        twinWindow.contentView = twin
        let previousMode = model.toolbarMode, previousVisible = model.floatingToolbarVisible
        defer {
            host.close(); twinControls.suspendToolbar(); twinWindow.contentView = nil; twinWindow.close()
            model.floatingToolbarVisible = previousVisible; model.toolbarMode = previousMode
        }
        // Publishing the switch is what makes the host resolve its surface and show the tools.
        model.floatingToolbarVisible = true
        settle(content, seconds: 0.5)
        guard controls.toolbar.isActive else { throw VoiceError.message("The toolbar host did not show its tools.") }
        var shots: [SurfaceGallery.Shot] = [], checks: [SurfaceGallery.HostCheck] = []
        for mode in ToolbarMode.allCases {
            model.toolbarMode = mode
            for tier in ToolbarTier.allCases {
                // A keyboard hold reveals the row and keeps it up whatever the real pointer does;
                // releasing it lets the grace timer bring the row back to rest.
                let event: ToolbarEvent = tier == .revealed ? .holdBegan(.keyboard) : .holdEnded(.keyboard)
                controls.toolbar.send(event); twinControls.toolbar.send(event)
                waitForToolbar(host, controls, tier: tier, content: content)
                settle(twin, seconds: 0.2)
                let window = panel.frame.size, wants = twin.fittingSize, preferred = controls.preferredToolbarSize
                var problems: [String] = []
                if controls.toolbar.state.tier != tier {
                    problems.append("the toolbar did not settle \(tier == .resting ? "at rest" : "revealed") (in a local run, a pointer inside the invisible panel can hold it)")
                }
                if !controls.hasMeasured(tier) {
                    problems.append("the host never received the row's size for this tier, so its window is the seed size"
                        + (twinControls.hasMeasured(tier) ? "" : " (a self-sizing twin of the same content received no report either, so the report path itself is silent)"))
                }
                if window.width + 0.5 < wants.width || window.height + 0.5 < wants.height {
                    problems.append("the window is \(Self.points(window)) but the row wants \(Self.points(wants)), so the row is clipped")
                }
                if abs(window.width - preferred.width) > 0.5 || abs(window.height - preferred.height) > 0.5 {
                    problems.append("the window is \(Self.points(window)) while the host prefers \(Self.points(preferred))")
                }
                let id = "\(mode.rawValue)-\(tier.rawValue)", title = "\(mode.title), \(tier == .resting ? "at rest" : "revealed")"
                let file = "toolbar-\(id)-\(theme).png"
                shots.append(try save(try snapshot(content), id: id, title: title, detail: "Window \(Self.points(window)); the row wants \(Self.points(wants)).", file: file, to: output))
                checks.append(.init(id: id, title: title, mode: mode.title, tier: tier.rawValue, window: [window.width, window.height], wants: [wants.width, wants.height],
                                    preferred: [preferred.width, preferred.height], measured: controls.hasMeasured(tier), twinMeasured: twinControls.hasMeasured(tier),
                                    problems: problems, file: file, settled: controls.toolbar.state.tier == tier))
            }
        }
        // A mode switch while the row is open changes its width with no reveal or collapse, so
        // the host hears of it only through the row's own report: Present's Prompts widen the row.
        controls.toolbar.send(.holdBegan(.keyboard)); twinControls.toolbar.send(.holdBegan(.keyboard))
        for (from, to) in [(ToolbarMode.dictate, ToolbarMode.present), (.present, .dictate)] {
            model.toolbarMode = from
            waitForToolbar(host, controls, tier: .revealed, content: content)
            model.toolbarMode = to
            // The new width arrives by the row's own report, a turn or more later; a slow runner
            // gets a full second of stillness before the window is read.
            waitForToolbar(host, controls, tier: .revealed, content: content, stillFor: 1)
            settle(twin, seconds: 0.2)
            let window = panel.frame.size, wants = twin.fittingSize, preferred = controls.preferredToolbarSize
            var problems: [String] = []
            if controls.toolbar.state.tier != .revealed { problems.append("the toolbar did not stay revealed") }
            if window.width + 0.5 < wants.width || window.height + 0.5 < wants.height {
                problems.append("the window is \(Self.points(window)) but the row wants \(Self.points(wants)), so the row is clipped")
            }
            if abs(window.width - preferred.width) > 0.5 || abs(window.height - preferred.height) > 0.5 {
                problems.append("the window is \(Self.points(window)) while the host prefers \(Self.points(preferred))")
            }
            let id = "\(from.rawValue)-to-\(to.rawValue)-revealed", title = "\(from.title) to \(to.title), revealed"
            let file = "toolbar-\(id)-\(theme).png"
            shots.append(try save(try snapshot(content), id: id, title: title, detail: "Window \(Self.points(window)); the row wants \(Self.points(wants)).", file: file, to: output))
            checks.append(.init(id: id, title: title, mode: to.title, tier: ToolbarTier.revealed.rawValue, window: [window.width, window.height], wants: [wants.width, wants.height],
                                preferred: [preferred.width, preferred.height], measured: controls.hasMeasured(.revealed), twinMeasured: twinControls.hasMeasured(.revealed),
                                problems: problems, file: file, settled: controls.toolbar.state.tier == .revealed))
        }
        /// One more state, read after the host and the twin have settled into `tier`.
        func record(_ id: String, _ title: String, tier: ToolbarTier) throws {
            waitForToolbar(host, controls, tier: tier, content: content, stillFor: 0.5)
            settle(twin, seconds: 0.2)
            let window = panel.frame.size, wants = twin.fittingSize, preferred = controls.preferredToolbarSize
            var problems: [String] = []
            if controls.toolbar.state.tier != tier { problems.append("the toolbar did not settle \(tier == .resting ? "at rest" : "revealed")") }
            if window.width + 0.5 < wants.width || window.height + 0.5 < wants.height {
                problems.append("the window is \(Self.points(window)) but the row wants \(Self.points(wants)), so the row is clipped")
            }
            if abs(window.width - preferred.width) > 0.5 || abs(window.height - preferred.height) > 0.5 {
                problems.append("the window is \(Self.points(window)) while the host prefers \(Self.points(preferred))")
            }
            let file = "toolbar-\(id)-\(theme).png"
            shots.append(try save(try snapshot(content), id: id, title: title, detail: "Window \(Self.points(window)); the content wants \(Self.points(wants)).", file: file, to: output))
            checks.append(.init(id: id, title: title, mode: model.toolbarMode.title, tier: tier.rawValue, window: [window.width, window.height], wants: [wants.width, wants.height],
                                preferred: [preferred.width, preferred.height], measured: controls.hasMeasured(tier), twinMeasured: twinControls.hasMeasured(tier),
                                problems: problems, file: file, settled: controls.toolbar.state.tier == tier))
        }
        // A right-hand dock reverses the row around the same launcher centre (#134).
        model.toolbarMode = .present
        controls.choosePosition?(.right); twinControls.rowAnchor = .right
        try record("present-right-dock-revealed", "Present, revealed at the right-hand dock", tier: .revealed)
        controls.toolbar.send(.holdEnded(.keyboard)); twinControls.toolbar.send(.holdEnded(.keyboard))
        try record("present-right-dock-resting", "Present, at rest at the right-hand dock", tier: .resting)
        controls.choosePosition?(.bottom); twinControls.rowAnchor = .bottom
        // The compact rest while a synthetic meeting records: the same 48 × 28, now with the
        // capture signal. The meeting owner has no level sample, so its outline stays still.
        let previousMeetings = model.meetings
        model.meetings = recordingMeetings; model.objectWillChange.send()
        try drive(recordingMeetings, start: true)
        model.toolbarMode = .dictate
        try record("meeting-recording-resting", "At rest while a meeting records", tier: .resting)
        try drive(recordingMeetings, start: false)
        model.meetings = previousMeetings; model.objectWillChange.send()
        return (shots, checks)
    }

    /// The tool chooser as the launcher opens it, at standard text: Dictate chosen, nothing running.
    func renderChooser(to output: URL) throws -> SurfaceGallery.Shot {
        let model = ToolbarChooserModel(choices: ToolbarNextAction.choices(for: ToolbarLiveState(mode: .dictate)))
        let view = NSHostingView(rootView: ToolbarChooserView(model: model, accent: Workbench.accent))
        let window = offscreenWindow(size: view.fittingSize, styleMask: [.borderless])
        window.isOpaque = false; window.backgroundColor = .clear
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        settle(view)
        return try save(try snapshot(view), id: "chooser", title: "The tool chooser",
                        detail: "The seven tools, Dictate chosen and highlighted, 280 pt wide with 36 pt rows.", file: "toolbar-chooser-\(theme).png", to: output)
    }

    /// Spins the main run loop until the toolbar reports `tier`, its frame animation has finished
    /// and the window's size has held still for a moment (six turns of about 50 ms, or `stillFor`
    /// seconds when given), or three seconds have passed.
    func waitForToolbar(_ host: CapturePanelController, _ controls: CaptureHUDControls, tier: ToolbarTier, content: NSView,
                        stillFor: TimeInterval? = nil) {
        let deadline = Date().addingTimeInterval(3)
        var still = 0, last = host.window?.frame ?? .zero, since = Date()
        while Date() < deadline && (stillFor.map { Date().timeIntervalSince(since) < $0 } ?? (still < 6)) {
            content.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            let frame = host.window?.frame ?? .zero
            // Any change of size or place restarts the stillness clock before the loop condition reads it again.
            if controls.toolbar.state.tier == tier && !host.isAnimatingToolbar && frame == last { still += 1 }
            else { still = 0; since = Date() }
            last = frame
        }
    }

    static func points(_ size: NSSize) -> String { "\(Int(ceil(size.width))) × \(Int(ceil(size.height))) pt" }
    /// A frame as x, y, width × height in points, to a tenth of a point.
    static func rect(_ rect: NSRect) -> String {
        func n(_ value: CGFloat) -> String { String(format: "%.1f", value) }
        return "\(n(rect.minX)), \(n(rect.minY)), \(n(rect.width)) × \(n(rect.height))"
    }

    // MARK: Floating toolbar placement

    /// Position…, the toolbar's placement control, as the glyph menu opens it with the toolbar
    /// docked at bottom centre and the keyboard on that dock.
    func renderPositionControl(to output: URL) throws -> SurfaceGallery.Shot {
        let view = NSHostingView(rootView: ToolbarPositionControl(current: .bottom, choose: { _ in }, reset: {}, close: {}))
        let window = offscreenWindow(size: view.fittingSize, styleMask: [.borderless])
        window.isOpaque = false; window.backgroundColor = .clear
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        settle(view)
        return try save(try snapshot(view), id: "position-control", title: "Position…",
                        detail: "The eight docks with bottom centre current and selected, and Reset position.", file: "toolbar-position-control-\(theme).png", to: output)
    }

    /// Free placement through the production host (#163, #134), with its panel invisible. Every
    /// position is compared at the launcher's centre, which the compact rest and the revealed row
    /// share. A release away from every dock rests right there through an update, a reveal and a
    /// collapse, on either half of the display; a row that widens moves neither its launcher nor
    /// its side; a release within the snap distance of a dock docks and one just beyond stays
    /// free; a new host, as after a relaunch, restores the free position, and earlier builds'
    /// saves come back where they were left; Reset position docks at bottom centre. The chooser
    /// opens inside the display at larger text from a bottom-right and a top-left dock.
    func checkToolbarPlacement() throws -> [SurfaceGallery.PlacementCheck] {
        guard let screen = NSScreen.main?.visibleFrame else { return [] }
        let defaults = try SurfaceGallery.isolatedDefaults("ToolbarPlacement", home: home)
        func makeHost() -> (CapturePanelController, CaptureHUDControls) {
            let controls = CaptureHUDControls(defaults: defaults)
            let host = CapturePanelController(model: model, readback: readback, stage: stage, snapModel: snap,
                                              dictate: {}, snap: {}, snapCapture: {}, draw: {}, present: {}, controls: controls)
            host.window?.alphaValue = 0; host.window?.ignoresMouseEvents = true
            return (host, controls)
        }
        let previousMode = model.toolbarMode, previousVisible = model.floatingToolbarVisible
        var (host, controls) = makeHost()
        defer { host.close(); model.floatingToolbarVisible = previousVisible; model.toolbarMode = previousMode }
        model.toolbarMode = .dictate; model.floatingToolbarVisible = true
        host.update(model: model)
        waitForToolbar(host, controls, tier: .resting, content: host.window?.contentView ?? NSView())
        var checks: [SurfaceGallery.PlacementCheck] = []
        func settle(_ tier: ToolbarTier) {
            waitForToolbar(host, controls, tier: tier, content: host.window?.contentView ?? NSView(), stillFor: 0.5)
        }
        func launcher() -> CGPoint {
            ToolbarGeometry.launcherCentre(inWindow: host.window?.frame ?? .zero, growsLeftward: controls.rowAnchor.growsLeftward)
        }
        func expect(_ title: String, _ problems: [String?]) { checks.append(.init(title: title, problems: problems.compactMap { $0 })) }
        /// What a failing step saw, so a failure on a runner can be read from its log alone: the
        /// window, where the host wants it, the display, the tier and the saved position.
        func context() -> String {
            let window = host.window?.frame ?? .zero
            let wants = host.window.map { _ in ToolbarGeometry.frame(size: window.size, position: host.toolsPosition, screen: screen) } ?? .zero
            let saved = ["capturePanelAnchor.v2", "capturePanelLauncher.v1", "capturePanelFreePosition.v1", "capturePanelOrigin.v1"].map { key in
                "\(key)=\(UserDefaults.standard.object(forKey: key).map { "\($0)".replacingOccurrences(of: "\n", with: " ") } ?? "none")"
            }.joined(separator: ", ")
            return "window \(Self.rect(window)), the host would place it at \(Self.rect(wants)), display \(Self.rect(screen)), "
                + "\(controls.toolbar.state.tier.rawValue), \(host.window?.isVisible == true ? "visible" : "not visible"), saved \(saved)"
        }
        func at(_ centre: CGPoint, _ what: String) -> String? {
            let found = launcher()
            return abs(found.x - centre.x) > 0.5 || abs(found.y - centre.y) > 0.5
                ? "\(what): the launcher is at \(Int(found.x)), \(Int(found.y)), not \(Int(centre.x)), \(Int(centre.y)) (\(context()))" : nil
        }
        func free(_ centre: CGPoint) -> String? {
            guard case .free(let free) = host.toolsPosition, controls.anchor == nil else { return "the toolbar is docked, not free (\(context()))" }
            return abs(free.centre.x - centre.x) > 0.5 || abs(free.centre.y - centre.y) > 0.5
                ? "the toolbar is free at \(Int(free.centre.x)), \(Int(free.centre.y)), not \(Int(centre.x)), \(Int(centre.y)) (\(context()))" : nil
        }
        func compact(_ what: String) -> String? {
            guard controls.toolbar.state.tier == .resting, let size = host.window?.frame.size else { return nil }
            return abs(size.width - ToolbarLayout.mark.width) > 0.5 || abs(size.height - ToolbarLayout.mark.height) > 0.5
                ? "\(what): the resting window is \(Self.points(size)), not the compact rest's 48 × 28 pt" : nil
        }
        for (side, centre) in [("left", CGPoint(x: screen.minX + screen.width * 0.3, y: screen.minY + screen.height * 0.4)),
                               ("right", CGPoint(x: screen.minX + screen.width * 0.7, y: screen.minY + screen.height * 0.6))] {
            let centre = CGPoint(x: centre.x.rounded(), y: centre.y.rounded())
            host.releaseTools(atLauncher: centre); settle(.resting)
            let leftward = side == "right"
            expect("Released free on the \(side), at rest", [free(centre), at(centre, "at rest"), compact("at rest"),
                controls.rowAnchor.growsLeftward == leftward ? nil : "the row would grow \(leftward ? "rightward, off" : "leftward, away from") the near edge"])
            // An update while free must not pull the toolbar back to a dock.
            model.floatingToolbarVisible = true; host.update(model: model); settle(.resting)
            expect("Free on the \(side), after an update", [free(centre), at(centre, "after an update")])
            controls.toolbar.send(.holdBegan(.keyboard)); settle(.revealed)
            let window = host.window?.frame ?? .zero
            expect("Free on the \(side), revealed", [at(centre, "revealed"), screen.contains(window) ? nil : "the revealed row leaves the display",
                abs(window.width - controls.preferredToolbarSize.width) > 0.5 ? "the window is \(Self.points(window.size)), not the row's \(Self.points(controls.preferredToolbarSize))" : nil])
            controls.toolbar.send(.holdEnded(.keyboard)); settle(.resting)
            expect("Free on the \(side), collapsed again", [at(centre, "collapsed again"), compact("collapsed again")])
        }
        // A row that widens, here by Present's accessory, must neither move its launcher nor turn
        // round: released just left of the middle, and on the right half, then Present is chosen.
        for (place, x) in [("just left of the middle", screen.midX - 5), ("on the right half", screen.minX + screen.width * 0.7)] {
            let centre = CGPoint(x: x.rounded(), y: (screen.minY + screen.height * 0.45).rounded())
            model.toolbarMode = .dictate
            host.releaseTools(atLauncher: centre); controls.toolbar.send(.holdBegan(.keyboard)); settle(.revealed)
            let leftward = controls.rowAnchor.growsLeftward, width = host.window?.frame.width ?? 0
            for mode in [ToolbarMode.present, .dictate] {
                model.toolbarMode = mode; settle(.revealed)
                let grown = (host.window?.frame.width ?? 0) - width
                expect("Released \(place), revealed, then \(mode.title) is chosen", [
                    mode == .present && abs(grown) < 0.5 ? "the row stayed \(Int(width)) pt wide, so this step shows nothing" : nil,
                    controls.rowAnchor.growsLeftward != leftward ? "the row turned round, from growing \(leftward ? "leftward" : "rightward")" : nil,
                    at(centre, "after the width changed")])
            }
            controls.toolbar.send(.holdEnded(.keyboard)); settle(.resting)
        }
        let dock = ToolbarGeometry.launcherCentre(.docked(.bottomRight), screen: screen)
        host.releaseTools(atLauncher: CGPoint(x: dock.x - (FloatingControlPlacement.snapDistance - 2), y: dock.y)); settle(.resting)
        expect("Released \(Int(FloatingControlPlacement.snapDistance - 2)) pt from the bottom-right dock",
               [controls.anchor == .bottomRight ? nil : "the toolbar did not dock bottom right", at(dock, "docked")])
        let beyond = CGPoint(x: dock.x - (FloatingControlPlacement.snapDistance + 4), y: dock.y)
        host.releaseTools(atLauncher: beyond); settle(.resting)
        expect("Released \(Int(FloatingControlPlacement.snapDistance + 4)) pt from the bottom-right dock", [free(beyond), at(beyond, "beyond the snap distance")])
        // A new host reads the saved position, as Workbench does after a relaunch.
        let kept = CGPoint(x: (screen.minX + screen.width * 0.4).rounded(), y: (screen.minY + screen.height * 0.5).rounded())
        host.releaseTools(atLauncher: kept); settle(.resting)
        /// A new host places its window as it is first updated. Wait until the window is on screen,
        /// at rest where the host's position puts it, and has held still there for half a second, as a
        /// relaunch settles, rather than compare at once: a slow runner can reach the check before a
        /// new window is placed (#205, batch 4). A host that never gets there fails with what it saw.
        func settleNewHost() {
            let deadline = Date().addingTimeInterval(5)
            var since = Date(), last = NSRect.zero
            while Date() < deadline {
                host.window?.contentView?.layoutSubtreeIfNeeded()
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
                let frame = host.window?.frame ?? .zero
                let wants = ToolbarGeometry.frame(size: frame.size, position: host.toolsPosition, screen: screen)
                let placed = host.window?.isVisible == true && controls.toolbar.state.tier == .resting && !host.isAnimatingToolbar
                    && abs(frame.minX - wants.minX) <= 0.5 && abs(frame.minY - wants.minY) <= 0.5
                if !placed || frame != last { since = Date() }
                last = frame
                if Date().timeIntervalSince(since) >= 0.5 { return }
            }
        }
        func relaunch(_ prepare: (UserDefaults) -> Void) {
            host.close()
            prepare(UserDefaults.standard)
            (host, controls) = makeHost()
            host.update(model: model); settleNewHost()
        }
        relaunch { _ in }
        expect("A new host, as after a relaunch", [free(kept), at(kept, "after a relaunch")])
        // Earlier builds' saves: #163's glyph edge, and before that the resting element alone. Each
        // comes back with its launcher where its glyph was, and is saved in this build's terms.
        let edge = (screen.minX + screen.width * 0.66).rounded(), edgeY = (screen.minY + screen.height * 0.35).rounded()
        relaunch { defaults in
            for key in ["capturePanelLauncher.v1", "capturePanelAnchor.v2"] { defaults.removeObject(forKey: key) }
            defaults.set(["glyphEdge": Double(edge), "centreY": Double(edgeY), "growsLeftward": true], forKey: "capturePanelFreePosition.v1")
        }
        expect("A new host reading #163's glyph-edge save", [free(CGPoint(x: edge - 18, y: edgeY)), at(CGPoint(x: edge - 18, y: edgeY), "migrated"),
            controls.rowAnchor.growsLeftward ? nil : "the save's side, leftward, was lost",
            UserDefaults.standard.dictionary(forKey: "capturePanelLauncher.v1") == nil ? "the migrated position was not saved in this build's terms" : nil])
        let earlier = NSRect(x: (screen.minX + screen.width * 0.65).rounded(), y: (screen.minY + screen.height * 0.3).rounded(), width: 132, height: 36)
        relaunch { defaults in
            for key in ["capturePanelLauncher.v1", "capturePanelFreePosition.v1", "capturePanelAnchor.v2"] { defaults.removeObject(forKey: key) }
            defaults.set(NSStringFromPoint(earlier.origin), forKey: "capturePanelOrigin.v1")
            defaults.set(NSStringFromSize(earlier.size), forKey: "capturePanelSize.v1")
        }
        expect("A new host reading an earlier resting-element save", [free(CGPoint(x: earlier.maxX - 18, y: earlier.midY)),
            controls.rowAnchor.growsLeftward ? nil : "the earlier save on the right half grows rightward",
            UserDefaults.standard.dictionary(forKey: "capturePanelLauncher.v1") == nil ? "the side decided for the earlier save was not saved with it" : nil])
        // An earlier build moved the toolbar after this one saved it: that later move wins.
        let moved = CGPoint(x: (screen.minX + screen.width * 0.25).rounded(), y: (screen.minY + screen.height * 0.55).rounded())
        relaunch { defaults in
            defaults.set(["glyphEdge": Double(moved.x - 18), "centreY": Double(moved.y), "growsLeftward": false], forKey: "capturePanelFreePosition.v1")
        }
        expect("A new host after an earlier build moved the toolbar", [free(moved), at(moved, "after the earlier build's move")])
        // A right-hand dock: the launcher stays on the dock's centre at rest and revealed, and the
        // row grows leftward from it, its slots reversed.
        controls.choosePosition?(.right); settle(.resting)
        let right = ToolbarGeometry.launcherCentre(.docked(.right), screen: screen)
        expect("Docked right, at rest", [at(right, "at rest"), compact("at rest")])
        controls.toolbar.send(.holdBegan(.keyboard)); settle(.revealed)
        expect("Docked right, revealed", [at(right, "revealed"),
            controls.rowAnchor == .right ? nil : "the row does not grow leftward from a right-hand dock"])
        controls.toolbar.send(.holdEnded(.keyboard)); settle(.resting)
        controls.choosePosition?(.bottom); settle(.resting)
        let bottom = ToolbarGeometry.launcherCentre(.docked(.bottom), screen: screen)
        expect("Reset position", [controls.anchor == .bottom ? nil : "Reset position did not dock at bottom centre", at(bottom, "reset")])
        // Work never holds the row open (#134): at rest while a meeting records, the toolbar is the
        // same 48 × 28 compact rest on the same launcher centre, now showing the capture signal.
        let previousMeetings = model.meetings
        model.meetings = recordingMeetings; model.objectWillChange.send()
        try drive(recordingMeetings, start: true)
        settle(.resting)
        expect("At rest while a meeting records", [
            controls.toolbar.state.tier == .resting ? nil : "the row stayed open while a meeting records",
            compact("while a meeting records"), at(bottom, "while a meeting records"),
            controls.status.indicator == .capture ? nil : "the compact rest shows \"\(controls.status.description)\", not the recording"])
        try drive(recordingMeetings, start: false)
        model.meetings = previousMeetings; model.objectWillChange.send()
        settle(.resting)
        try checkRecordingInTheHost(host: host, controls: controls, bottom: bottom, expect: expect, settle: settle, at: at, compact: compact)
        checkResultsInTheHost(host: host, controls: controls, expect: expect, settle: settle)
        // The chooser opens beside the launcher and inside the display, at larger text too.
        for (anchor, scale) in [(ToolbarAnchor.bottomRight, CGFloat(1.35)), (.topLeft, 1.35), (.bottom, 1)] {
            let centre = ToolbarGeometry.launcherCentre(.docked(anchor), screen: screen)
            let chooser = ToolbarChooserPanel(); chooser.offscreenForChecks = true
            chooser.show(from: ToolbarGeometry.slot(around: centre), view: nil, level: .statusBar, growsLeftward: anchor.growsLeftward,
                         choices: ToolbarNextAction.choices(for: ToolbarLiveState(mode: .dictate)), textScale: scale, choose: { _ in }, closed: { _ in })
            let frame = chooser.shownFrame ?? .zero
            let natural = ToolbarChooserLayout.height(rows: ToolbarMode.allCases.count, scale: scale)
            expect("Chooser from the \(anchor.title.lowercased()) dock\(scale > 1 ? ", larger text" : "")", [
                screen.contains(frame) ? nil : "the chooser at \(Int(frame.minX)), \(Int(frame.minY)), \(Self.points(frame.size)) leaves the display",
                abs(frame.width - ToolbarChooserLayout.width * scale) > 1 && frame.width < screen.width - 16 ? "the chooser is \(Int(frame.width)) pt wide, not \(Int(ToolbarChooserLayout.width * scale))" : nil,
                frame.height + 1 < natural && screen.height > natural + 200 ? "the chooser scrolls although all seven tools fit" : nil,
                ToolbarGeometry.slot(around: centre).intersects(frame) ? "the chooser covers the launcher" : nil])
            chooser.close()
        }
        return checks
    }

    /// Dictation, its processing and its results in the toolbar's host (#134 T4), and the coaching
    /// card beside it (#134 T5), docked at bottom centre. At rest each is the same 48 × 28 mark on
    /// the same centre; a new failure or receipt changes only the mark's status until the person
    /// reveals it, and a result that arrives while the row is open waits rather than replacing it;
    /// revealing shows the result's own controls from the same centre, and collapsing never
    /// dismisses it; the no-speech cue shows at the same place; a Stop pressed through the
    /// recording's completion does nothing; and the card sits 12 points above the mark, or below
    /// it at a top dock, with nothing of the toolbar's in the gap and the mark where it was.
    func checkRecordingInTheHost(host: CapturePanelController, controls: CaptureHUDControls, bottom: CGPoint,
                                 expect: (String, [String?]) -> Void, settle: (ToolbarTier) -> Void,
                                 at: (CGPoint, String) -> String?, compact: (String) -> String?) throws {
        let failure = "The speech engine stopped before it finished."
        func rests(_ what: String, _ indicator: ToolbarStatus.Indicator) -> [String?] {
            settle(.resting)
            return [controls.toolbar.state.tier == .resting ? nil : "\(what): the row opened by itself", compact(what), at(bottom, what),
                    controls.status.indicator == indicator ? nil : "\(what): the mark shows \"\(controls.status.description)\""]
        }
        // The pointer's reveal, which alone shows a waiting result's own controls (#211 F1), held by
        // a menu's hold: the real pointer is elsewhere, and the host would find it gone and collapse.
        func reveal() { controls.toolbar.send(.pointerEntered); controls.toolbar.send(.holdBegan(.menu)); settle(.revealed) }
        func collapse() { controls.toolbar.send(.holdEnded(.menu)); controls.toolbar.send(.pointerLeft) }
        /// A result's controls grow inward from the launcher's centre; a display edge may lift them.
        func grewFromTheCentre(_ what: String) -> String? {
            let frame = host.window?.frame ?? .zero
            let x = ToolbarGeometry.launcherCentre(inWindow: frame, growsLeftward: controls.rowAnchor.growsLeftward).x
            return abs(x - bottom.x) > 0.5 ? "\(what): the controls grew from \(Int(x)), not the launcher's centre at \(Int(bottom.x))" : nil
        }
        model.toolbarMode = .dictate
        model.phase = .recording; model.elapsed = 12
        expect("At rest while dictating", rests("while dictating", .capture))
        reveal()
        expect("Revealed while dictating", [at(bottom, "revealed while dictating"),
            controls.revealsResult ? "the row showed a result while dictating" : nil])
        collapse()
        model.phase = .transcribing
        expect("At rest while transcribing", rests("while transcribing", .processing))
        model.phase = .idle; model.elapsed = 0
        model.captureFailure = failure
        expect("A new failure, at rest", rests("with a new failure", .failure))
        reveal()
        expect("The failure, revealed", [controls.revealsResult ? nil : "revealing did not show the failure's own controls",
            abs((host.window?.frame.width ?? 0) - CaptureHUDLayout.message.width) > 0.5 ? "the failure's controls are not their own size" : nil,
            grewFromTheCentre("the failure")])
        collapse()
        expect("The failure, collapsed again", rests("after the failure was revealed", .failure)
            + [model.captureFailure == nil ? "collapsing dismissed the failure" : nil])
        model.dismissCaptureFailure(); settle(.resting)
        // A result that arrives while the row is open never replaces the row under the pointer.
        reveal()
        let row = host.window?.frame.size ?? .zero
        model.captureFailure = failure
        settle(.revealed)
        expect("A failure arriving while the row is open", [controls.revealsResult ? "the failure replaced the open row" : nil,
            host.window?.frame.size == row ? nil : "the open row changed size for the failure"])
        collapse()
        model.dismissCaptureFailure(); settle(.resting)
        // A row kept open by Keep open alone shows a new result in its place, but never while a
        // hold is on it: the result waits until the hold lets go, then grows from the same centre.
        controls.toolbar.send(.keepOpenChanged(true)); settle(.revealed)
        reveal()
        let keptRow = host.window?.frame.size ?? .zero
        model.captureFailure = failure
        settle(.revealed)
        expect("A failure arriving while a kept-open row is held", [controls.revealsResult ? "the kept-open row swapped while a hold was on it" : nil,
            host.window?.frame.size == keptRow ? nil : "the held row changed size for the failure"])
        collapse(); settle(.revealed)
        expect("The kept-open row once the hold lets go", [controls.revealsResult ? nil : "the kept-open row never showed the waiting failure",
            grewFromTheCentre("the kept-open failure")])
        model.dismissCaptureFailure()
        controls.toolbar.send(.keepOpenChanged(false)); settle(.resting)
        model.clipboardReceipt.record(outcome: .init(message: TextDelivery.copiedMessage, clipboardChangeCount: NSPasteboard.general.changeCount,
                                                     wasPasted: false, destinationName: nil), wordCount: 12)
        expect("A new receipt, at rest", rests("with a new receipt", .pendingDelivery))
        reveal()
        expect("The receipt, revealed", [controls.revealsResult ? nil : "revealing did not show the receipt", grewFromTheCentre("the receipt")])
        collapse()
        expect("The receipt, collapsed again", rests("after the receipt was revealed", .pendingDelivery)
            + [model.clipboardReceipt.receipt == nil ? "collapsing dismissed the receipt" : nil])
        model.clipboardReceipt.clear(); settle(.resting)
        // The no-speech cue shows at the toolbar's own place, then the mark again. Too short, not
        // too quiet: a second quiet capture in a row is a failure, and the floating shots had one.
        model.endWithoutSpeech(.tooShort)
        settle(.resting)
        let cue = host.window?.frame ?? .zero
        expect("The no-speech cue", [cue.size == CaptureHUDLayout.compact ? nil : "the cue is \(Self.points(cue.size))", grewFromTheCentre("the cue")])
        model.dismissCaptureCue()
        expect("After the no-speech cue", rests("after the cue", .idle) + [model.captureFailure.map { "a failure took the cue's place: \($0)" }])
        // A Stop pressed as the recording completes: the press latched Stop, and the click must not
        // become a new dictation (#134, #205 review).
        var starts = 0
        let toolbar = FloatingToolbar(model: model, readback: readback, stage: stage, controls: controls, promptInsertion: model.promptInsertion,
                                      meetings: model.meetings, snapModel: snap, receipts: model.clipboardReceipt,
                                      dictate: { starts += 1 }, snap: {}, snapCapture: {}, draw: {}, present: {})
        model.phase = .recording; settle(.resting)
        controls.pressGate.shown(ToolbarNextAction.resolve(toolbar.live).operation)
        let click = toolbar.pressPrimary()
        model.phase = .idle
        click?()
        expect("Stop pressed through the recording's completion", [click == nil ? "the press on Stop latched nothing" : nil,
            starts > 0 ? "the click started a new dictation" : nil, model.phase != .idle ? "the click acted after the recording ended" : nil])
        settle(.resting)
        // Record again only ever starts (#211): chosen from More or a failure's controls drawn before
        // a recording began, by the shortcut say, it leaves that recording alone. A recording begins
        // with its microphone request, which the plain toggle would cancel, then records, which it
        // would stop; the gallery's recording has no recorder, so the request is the telling case.
        for phase in [AppModel.Phase.requesting, .recording] {
            model.phase = phase
            model.recordAgain()
            expect("Record again chosen once a recording has begun, \(phase.rawValue)", [
                model.phase == phase ? nil : "Record again turned the \(phase.rawValue) into \(model.phase.rawValue)"])
            model.phase = .idle
        }
        settle(.resting)
        // The coaching card beside the compact mark (#134 T5).
        let coach = model.coach
        coach.announce = { _ in }; coach.voiceOverEnabled = { false }
        host.coachPanel.offscreenForChecks = true
        for anchor in [FloatingControlAnchor.bottom, .top] {
            controls.choosePosition?(anchor); settle(.resting)
            let mark = host.window?.frame ?? .zero
            let card = FeedbackCoachModel.Card(tip: "gallery.placement.\(anchor.rawValue)", symbol: "keyboard",
                                               title: "Hold ⌥V to dictate.", body: HoldLesson.body)
            let requested = coach.request(card)
            settle(.resting)
            let frame = host.coachPanel.shownFrame ?? .zero
            let above = anchor != .top
            let gap = above ? NSRect(x: frame.minX, y: mark.maxY, width: frame.width, height: frame.minY - mark.maxY)
                            : NSRect(x: frame.minX, y: frame.maxY, width: frame.width, height: mark.minY - frame.maxY)
            let launcherX = ToolbarGeometry.launcherCentre(inWindow: mark, growsLeftward: controls.rowAnchor.growsLeftward).x
            expect("The coaching card at the \(anchor.title.lowercased()) dock", [
                requested ? nil : "the host would not let the card show",
                coach.isPresented ? nil : "the card was never reported presented",
                abs(gap.height - 12) > 0.5 ? "the card is \(Int(gap.height)) pt \(above ? "above" : "below") the mark, not 12" : nil,
                abs(frame.midX - launcherX) > 1 ? "the card is not centred on the launcher" : nil,
                (host.window?.frame ?? .zero).intersects(gap.insetBy(dx: 0, dy: 0.5)) || frame.intersects(gap.insetBy(dx: 0, dy: 0.5))
                    ? "something of the toolbar's covers the gap" : nil,
                host.window?.frame == mark ? nil : "the mark moved for the card"])
            coach.remove(); settle(.resting)
            if host.coachPanel.shownFrame != nil { expect("The coaching card goes", ["the card stayed after it was removed"]) }
        }
        controls.choosePosition?(.bottom); settle(.resting)
    }

    /// A waiting result from the keyboard and at a right-hand dock (#211), in the same host. The
    /// gallery never takes the person's keyboard: the toolbar's keyboard hold stands in for it.
    /// Keyboard entry onto a waiting receipt must keep the launcher row, whose launcher takes the
    /// focus, and Escape must leave without dismissing the receipt; Escape must leave a result's
    /// own controls too (F1). Position… closing onto a receipt waiting on a kept-open row must
    /// hand the keyboard back before the host updates, so the launcher row stays (F2). And at the
    /// right-hand dock each result's actions must sit clear of the mark the pointer came from (F3).
    func checkResultsInTheHost(host: CapturePanelController, controls: CaptureHUDControls,
                               expect: (String, [String?]) -> Void, settle: (ToolbarTier) -> Void) {
        func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        /// A receipt pinned, so its own eight seconds never end it while the steps run.
        func receipt() {
            model.clipboardReceipt.record(outcome: .init(message: TextDelivery.copiedMessage, clipboardChangeCount: NSPasteboard.general.changeCount,
                                                         wasPasted: false, destinationName: nil), wordCount: 12)
            model.clipboardReceipt.keepVisible = true
        }
        /// The pointer's reveal, held by a menu's hold, as the real pointer is elsewhere and the host
        /// would otherwise find it gone and collapse the row.
        func reveal() { controls.toolbar.send(.pointerEntered); controls.toolbar.send(.holdBegan(.menu)) }
        func collapse() { controls.toolbar.send(.holdEnded(.menu)); controls.toolbar.send(.pointerLeft) }
        func escape() {
            guard let window = host.window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53) else { return }
            window.sendEvent(event)
        }
        model.toolbarMode = .dictate
        receipt(); settle(.resting)
        controls.focusToolbar(); settle(.revealed)
        let launcher = host.window?.contentView.map(buttons)?.first { $0.accessibilityIdentifier() == "toolbar.launcher" }
        controls.focusFirstControl?()
        let focused = launcher != nil && host.window?.firstResponder === launcher
        let showedResult = controls.revealsResult
        escape(); settle(.resting)
        expect("Keyboard entry onto a waiting receipt", [
            showedResult ? "the receipt's controls took the launcher row's place" : nil,
            launcher == nil ? "the row has no launcher" : focused ? nil : "the launcher did not take the keyboard's focus",
            controls.toolbar.state.holds.contains(.keyboard) ? "Escape left the keyboard's hold in place" : nil,
            controls.toolbar.state.tier == .resting ? nil : "the row stayed open after Escape",
            model.clipboardReceipt.receipt == nil ? "Escape dismissed the receipt" : nil])
        // The pointer's reveal shows the receipt's own controls; the keyboard taken after it, and
        // Escape from them, leave as from the launcher row.
        reveal(); settle(.revealed)
        let pointerShowed = controls.revealsResult
        controls.focusToolbar(); escape()
        let released = !controls.toolbar.state.holds.contains(.keyboard)
        collapse(); settle(.resting)
        expect("Escape from a waiting receipt's own controls", [pointerShowed ? nil : "the pointer's reveal did not show the receipt",
            released ? nil : "Escape left the keyboard's hold in place", model.clipboardReceipt.receipt == nil ? "Escape dismissed the receipt" : nil])
        model.clipboardReceipt.clear(); settle(.resting)
        // Position… holds a kept-open row's result back while it is open (a menu's hold stands in
        // for it here); closing it hands the keyboard back first, and only then does the host update.
        controls.toolbar.send(.keepOpenChanged(true)); settle(.revealed)
        controls.toolbar.send(.holdBegan(.menu))
        receipt(); settle(.revealed)
        let waited = !controls.revealsResult
        controls.toolbar.send(.holdEnded(.menu))
        host.positionClosed(returnsKeyboard: true) { controls.focusToolbar() }
        let keptRow = !controls.revealsResult, keyboard = controls.toolbar.state.holds.contains(.keyboard)
        settle(.revealed)
        expect("Position… closing onto a receipt waiting on a kept-open row", [
            waited ? nil : "the receipt took the row while Position… was open",
            keptRow && !controls.revealsResult ? nil : "the receipt took the place of the row the keyboard came back to",
            keyboard ? nil : "the keyboard did not come back"])
        model.clipboardReceipt.clear(); controls.endKeyboardInteraction()
        controls.toolbar.send(.keepOpenChanged(false)); settle(.resting)
        // At the right-hand dock each result grows leftward from the launcher's centre: its actions
        // must sit clear of the mark the pointer came from, never Retry, Dismiss or the like there.
        controls.choosePosition?(.right); settle(.resting)
        let mark = host.window?.frame ?? .zero
        let failure = "The speech engine stopped before it finished."
        let results: [(String, () -> Void, () -> Void)] = [
            ("A dictation failure", { self.model.captureFailure = failure }, { self.model.dismissCaptureFailure() }),
            ("The clipboard receipt", receipt, { self.model.clipboardReceipt.clear() }),
            ("A stopped reading", { self.model.reportReadingFailure(.audioUnreadable) }, { self.model.dismissReadingFailure() })]
        for (name, show, clear) in results {
            show(); settle(.resting)
            let pending = FloatingResult.pending(model)
            controls.resultActionFrames = [:]
            reveal(); settle(.revealed)
            let window = host.window?.frame ?? .zero
            let actions = controls.resultActionFrames.map { name, frame in
                (name, NSRect(x: window.minX + frame.minX, y: window.maxY - frame.maxY, width: frame.width, height: frame.height))
            }
            let over = actions.filter { $0.1.intersects(mark.insetBy(dx: 0.5, dy: 0.5)) }.map { "\($0.0) at \(Self.rect($0.1))" }.sorted()
            expect("\(name) at the right-hand dock", [
                controls.revealsResult ? nil : "the pointer's reveal did not show it (waiting: \(pending.map { "\($0)" } ?? "nothing"), \(controls.toolbar.state.tier.rawValue))",
                actions.isEmpty ? "no action was found to measure" : nil,
                over.isEmpty ? nil : "\(over.joined(separator: "; ")) sit over the mark the pointer came from at \(Self.rect(mark)), in a window at \(Self.rect(window))"])
            collapse(); clear(); settle(.resting)
        }
        controls.choosePosition?(.bottom); settle(.resting)
    }

    /// One Home window per size, set up like AppDelegate's. As in the app, pages change inside it
    /// (Home asks macOS for the login item status each time it is created, which can be slow).
    func homeWindow(size: NSSize) -> NSWindow {
        let window = offscreenWindow(size: size, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.contentViewController = NSHostingController(rootView: WorkbenchHome(model: model, stage: stage, keyboard: keyboard, readback: readback, snap: snap))
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

    /// Draws the window's layer tree, as the screen would. Neither `cacheDisplay` nor a layer render
    /// of the window reliably includes a scroll view's document (macOS may show it through the
    /// scroll edge portal), so each visible document is hidden for the window pass and then drawn
    /// on its own, outer ones first, clipped to its scroll view.
    func snapshot(_ root: NSView) throws -> NSBitmapImageRep {
        root.window?.display()
        let scale = root.window?.backingScaleFactor ?? 2, bounds = root.bounds
        guard root.layer != nil, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw VoiceError.message("Could not allocate a render.")
        }
        context.scaleBy(x: scale, y: scale)
        // The window background is not in the layer tree, so paint it first, in the window's appearance.
        var background = NSColor.windowBackgroundColor.cgColor
        (root.window?.effectiveAppearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.cgColor
        }
        context.setFillColor(background); context.fill(bounds)
        func draw(_ view: NSView, in rect: NSRect) {
            guard let layer = view.layer else { return }
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY)
            // A magnified scroll view shows its document scaled, as the image preview does.
            let scale = CGSize(width: view.bounds.width > 0 ? rect.width / view.bounds.width : 1,
                               height: view.bounds.height > 0 ? rect.height / view.bounds.height : 1)
            let magnified = abs(scale.width - 1) > 0.001 || abs(scale.height - 1) > 0.001
            if magnified { context.scaleBy(x: scale.width, y: scale.height) }
            if view.isFlipped { context.translateBy(x: 0, y: magnified ? view.bounds.height : rect.height); context.scaleBy(x: 1, y: -1) }
            layer.render(in: context)
            context.restoreGState()
        }
        func clipViews(_ view: NSView) -> [NSClipView] { ((view as? NSClipView).map { [$0] } ?? []) + view.subviews.flatMap(clipViews) }
        let scrolled = clipViews(root).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { clip in clip.documentView.map { (clip, $0) } }
        let documents = scrolled.compactMap { $0.1.layer }.filter { !$0.isHidden }
        let opacities = documents.map(\.opacity)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { for (layer, opacity) in zip(documents, opacities) { layer.isHidden = false; layer.opacity = opacity }; CATransaction.commit() }
        documents.forEach { $0.isHidden = true }
        draw(root, in: SurfacePass.unflipped(root.bounds, of: root, in: root))
        for (clip, document) in scrolled {
            document.layer?.isHidden = false; document.layer?.opacity = 1
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

    /// True when nothing is drawn in the page area (right of the sidebar, below the title bar and
    /// inside the window edge): a capture failure, not a design.
    static func isBlank(_ rep: NSBitmapImageRep, size: NSSize) -> Bool {
        let scale = CGFloat(rep.pixelsWide) / size.width, bytes = rep.bitsPerPixel / 8
        guard let base = rep.bitmapData, !rep.isPlanar, bytes >= 3 else { return false }
        let left = Int(232 * scale), right = rep.pixelsWide - Int(12 * scale), top = Int(40 * scale), bottom = rep.pixelsHigh - Int(12 * scale)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { (0..<bytes).map { base[y * rep.bytesPerRow + x * bytes + $0] } }
        let background = pixel(right - 1, rep.pixelsHigh / 2)
        var drawn = 0, total = 0
        for y in stride(from: top, to: bottom, by: 4) { for x in stride(from: left, to: right, by: 4) { total += 1; if pixel(x, y) != background { drawn += 1 } } }
        return total > 0 && Double(drawn) / Double(total) < 0.002
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

    static let pages: [(String, String)] = WorkbenchHome.navItems.map { ($0.id, $0.title) } + SurfaceGallery.extraPages

    /// StageKit items that only open a page. They are run with StageKit's page callbacks recording.
    static let stageLinks: Set<String> = ["Drawing Controls…", "Keyboard Shortcuts…", "Prepare Personas…"]

    /// Native option menus as the panel builds them. The panel's own items and StageKit's page links
    /// are run with recording callbacks to learn their destination; other StageKit items are listed only.
    func menus() -> [SurfaceGallery.Listing] {
        let panel = quickPanel(readback)
        var listings = [SurfaceGallery.Listing(title: "Dictate · Options (SwiftUI menu, listed from its source)", lines:
            ["Delivery"] + DeliveryMode.allCases.map { "  " + $0.rawValue }
            + ["Copies for ⌘V until automatic paste is approved (while Paste automatically waits for Accessibility approval)", "  Set up automatic paste…"]
            + ["Text style"] + CleanupStyle.allCases.map { "  " + $0.rawValue }
            + ["---", "History… → history, on Transcripts", "Transcribe meeting or call… → meeting", "Open Dictate… → dictate"])]
        for tool in WorkbenchControlTool.allCases {
            guard let menu = panel.nativeOptions(tool) else { continue }
            let title = "\(tool.title) · Options"
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
            if item is ToolbarMenuAction || SurfacePass.stageLinks.contains(item.title), let action = item.action {
                opened.removeAll(); actions.removeAll()
                NSApp.sendAction(action, to: item.target, from: item)
                let route = opened.first, leads = route.map { "Page: \($0)" } ?? actions.first ?? "No effect"
                line += "  → " + (route ?? leads)
                menuEntries.append(.init(surface: "Menu-bar panel", label: label, leads: leads, route: route, ran: true))
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
        // Rows and their Options are named by the panel's own tools, as the toolbar and sidebar are (#134).
        var list: [E] = [action(panel, "Floating toolbar switch", "Shows or hides the floating toolbar between actions, as Settings and the Window menu do")]
        for tool in WorkbenchControlTool.allCases {
            let options = "\(tool.title) · Options"
            switch tool {
            case .dictate:
                list += [action(panel, "Dictate", "Starts or finishes dictation into the app that was in front"),
                         E(surface: panel, label: "Dictate · Options · History…", leads: "Page: history, on Transcripts", route: "history"), page(panel, "Dictate · Options · Transcribe meeting or call…", "meeting"),
                         page(panel, "Dictate · Options · Open Dictate…", "dictate"),
                         action(panel, "Dictate · Options · Delivery and Text style", "Changes the saved dictation settings"),
                         action(panel, "Dictate · Options · Set up automatic paste…", "Asks macOS for Accessibility approval; shown while Paste automatically waits for it")]
            case .read:
                list += [page(panel, "Read, when nothing is playing", "speak"), action(panel, "Read, while reading", "Pauses, resumes or cancels the reading from the row itself")]
            case .snap:
                list += [action(panel, "Snap", "Captures a region, saved in History"),
                         action(panel, "Snap · Options · Region, Window or Screen", "Captures that area, saved in History"),
                         page(panel, "Snap · Options · Open Snap…", "snap")]
            case .snapAndTalk:
                list += [action(panel, "Snap & Talk, with a ready session", "Captures the display under the pointer and starts narration"),
                         page(panel, "Snap & Talk, without a session or access", "readback"), page(panel, "Snap & Talk · Options · Review Snap & Talk…", "readback")]
            case .annotate:
                list += [action(panel, tool.title, "Starts drawing on screen"), action(panel, options, "Native menu, listed below")]
            case .present:
                list += [action(panel, "Present, with a scene selected", "Starts the scene, or shows its live controls"),
                         page(panel, "Present, without a scene", "present"), action(panel, options, "Native menu, listed below")]
            case .persona:
                list += [action(panel, tool.title, "Shows the prepared persona, or its live controls"),
                         page(panel, "\(tool.title), with nothing prepared", "personas"), action(panel, options, "Native menu, listed below")]
            case .timer:
                list += [action(panel, tool.title, "Starts the saved timer, or shows the running one"), action(panel, options, "Native menu, listed below")]
            }
        }
        list += [action(panel, "Shortcut label on each row", "Edits that shortcut inside the panel"),
                 page(panel, "Open Workbench", "home"), page(panel, "Settings", "settings"), page(panel, "Shortcuts", "shortcuts"),
                 action(panel, WorkbenchUpdates.shared.panelTitle, "Checks for updates"), action(panel, "Quit", "Quits Workbench"),
                 page(panel, "Clipboard receipt · Review text", "history"), action(panel, "Clipboard receipt · Show cue", "Shows the clipboard cue"),
                 page(panel, "Recovery · Open Dictate…, for a dictation error", "dictate"), page(panel, "Recovery · Open Read…, for a reading error", "speak"),
                 page(panel, "Recovery · Open History…, for a transcript removal or export", "history"),
                 page(panel, "Recovery · Open Home…, when the speech model could not be prepared", "home"),
                 page(panel, "Recovery · Open Models…, while speech is still preparing", "models"), page(panel, "Recovery · Open Snap & Talk…, for its notice", "readback"),
                 page(panel, "Recovery · Open Draw…, for a drawing notice", "annotate"), page(panel, "Recovery · Open Present…, for a scene notice", "present"),
                 page(panel, "Recovery · Open Persona…, for a persona notice", "personas"),
                 page(panel, "Recovery · Open Keyboard…, for recording a shortcut", "shortcuts"),
                 page(panel, "Recovery · Open Settings…, for login or saved drawing settings", "settings"),
                 page(panel, "Meeting status row, while a meeting is busy", "meeting"), action(panel, "Meeting status row · Stop or Cancel", "Stops or cancels the meeting")]
        list += WorkbenchHome.navItems.map { E(surface: "Home sidebar", label: $0.title, leads: "Page: \($0.id)", route: $0.id, ran: true) }
        // Each page's switcher, from the same page record: a section opens its own route.
        list += WorkbenchHome.sections.map {
            E(surface: "Section switcher", label: WorkbenchHome.name(of: $0.page) + " › " + $0.title, leads: "Page: \($0.id)", route: $0.id, ran: true)
        }
        list += [page("Home sidebar", "Update button, when an update is waiting", "settings")]
        // Home (#134 H1): three quick starts that act, Recent work's reviews, a loaded session and saved photos.
        list += [action(home, "Quick start · Dictate", "Starts dictating"), action(home, "Quick start · Read", "Reads the clipboard aloud"),
                 action(home, "Quick start · Snap", "Captures a region, saved in History"),
                 E(surface: home, label: "Recent work · a transcript's title", leads: "Page: history, showing that transcript", route: "history"),
                 E(surface: home, label: "Recent work · a result's title", leads: "Page: history, revealing that task", route: "history"),
                 action(home, "Recent work · a Snap's thumbnail and title", "Opens its read-only preview"),
                 page(home, "Open History", "history"), page(home, "Continue Snap & Talk · Open session", "readback"),
                 page(home, "Saved from iPhone, when photos are in Library", "photos"),
                 page(home, "Current work · Open Dictate, for a kept capture without a retry", "dictate"),
                 action(home, "Show me a first dictation, after Skip for now", "Shows the first-dictation guide again"),
                 page(home, "Speech settings, while speech is not ready", "models"),
                 E(surface: "Settings page", label: "Dictate options…", leads: "Page: dictate, scrolled to and focused on its options", route: "dictate"),
                 page("Settings page", "Show me a first dictation, until the first dictation", "home"),
                 action("Settings page", "Appearance · Floating toolbar switch", "Shows or hides the floating toolbar between actions"),
                 page("Dictate page", "Your dictionary", "dictionary"), action("Dictate page", "Position floating toolbar…", "Opens Position… at the floating toolbar"),
                 page("Snap & Talk page", "Manage packs…", "packs"), page("Snap & Talk page", "Choose Snaps", "snap"),
                 page("Snap page", "Add to narrated session", "readback"),
                 action("Snap page", "Use selected · Organise… · Hand off for synthesis…", "Opens the handoff review for a Snap review"),
                 action("Snap page", "Add image · Paste image or Import image…", "Opens a Snap draft from the clipboard or a chosen file"),
                 action("Snap page", "Add image · Import Desktop screenshots…", "Lists screenshots on the Desktop, then asks before importing them and moving the originals to the Trash"),
                 action("Transcript details", "Suggest details · Ask an assistant…", "Opens the handoff review to suggest names and tags"),
                 action("Read page", "Open Read & Speak", "Opens System Settings to add a Mac voice"),
                 page("Dictate page", "Transcribe a meeting or call…", "meeting"), page("Meeting page", "History", "history"),
                 E(surface: "Handoff review", label: "Copy instructions or Start task", leads: "Page: history, revealing the task it prepared", route: "history"),
                 page("Remember correction", "Open Dictionary", "dictionary"),
                 page(home, "Clipboard receipt · Review text", "history"),
                 page("History page", "Transcript · Open", "dictate"), page("History page", "Transcript · More… · Read aloud", "speak"),
                 action("History page", "Connections…", "Shows provider connections over History"),
                 action("History page", "Hand off…", "Opens the handoff review for the selected items"),
                 action("History page", "Result · Review suggested details…", "Reviews an assistant's suggested details for the task's transcript"),
                 action("History page", "Stop task", "Stops the running task, whatever the filter shows")]
        list += appMenuEntries(surface: menu)
        list += [action("Library page", "Resources · Add · Save clipboard as prompt…, or ⇧⌘S while Resources shows", "Opens a new prompt with the clipboard's text")]
        list += [page(other, "Library shortcut", "library"), page(other, "Read shortcut, when nothing is playing", "speak"),
                 page(other, "Snap & Talk shortcut, without a session or access", "readback"), page(other, "Present shortcut, without a scene", "present"),
                 action(other, "Quick controls shortcut", "Opens this panel"), action(other, "Switch to shortcut", "Opens the Switch to panel"),
                 page(other, "Read Selection service (selected text)", "speak"), page(other, "Private pack link", "packs"),
                 page(other, "Meeting offer panel", "meeting"), page(other, "Pack persona import", "personas"),
                 page(other, "Switch to panel · Set up", "library"), page(other, "StageKit controls and drawing settings", "annotate"),
                 page(other, "StageKit shortcut editing", "shortcuts"), page(other, "StageKit persona preparation", "personas")]
        return list
    }
}

extension SurfacePass {
    /// The Workbench, Window and Help menus as AppDelegate builds them, so the index lists the
    /// names and destinations the menus really have. A page item carries its route; Check for
    /// Updates… opens Settings as it checks. Edit, Services and the Draw menu are listed elsewhere
    /// or belong to macOS.
    func appMenuEntries(surface: String) -> [SurfaceGallery.Entry] {
        let actions = ["About Workbench": "Shows the About panel", "Check for Updates…": "Page: settings, and checks for updates",
                       "Copy build details": "Copies build details", "Hide Workbench": "Hides Workbench", "Quit Workbench": "Quits Workbench",
                       "Close Window": "Closes the front window", "Open Workbench": "Opens Home on its current page",
                       "Show floating toolbar": "Shows the toolbar between actions", "Hide floating toolbar": "Hides the toolbar between actions", "Focus floating toolbar": "Moves keyboard focus to the toolbar",
                       "Restore menu-bar icon": "Shows the icon and the toolbar", "Switch to…": "Opens the Switch to panel", "Workbench Guide": "Opens the web guide"]
        return shell.makeMainMenu().main.items.compactMap(\.submenu).filter { ["Workbench", "Window", "Help"].contains($0.title) }.flatMap { menu in
            menu.items.filter { !$0.isSeparatorItem && $0.submenu == nil }.map { item in
                let label = "\(menu.title) › \(item.title)"
                if let route = item.representedObject as? String {
                    return SurfaceGallery.Entry(surface: surface, label: label, leads: "Page: \(route)", route: route, ran: true)
                }
                let opensSettings = item.action == #selector(AppDelegate.showUpdates)
                return SurfaceGallery.Entry(surface: surface, label: label, leads: actions[item.title] ?? "An action", route: opensSettings ? "settings" : nil, ran: true)
            }
        }
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
            if passes.contains(where: { $0.pages.first { $0.route == page.route }?.blank == true }) {
                flags.append("\(page.title) (\(page.route)) rendered blank: the gallery could not capture it.")
            }
        }
        for check in light.host { for problem in check.problems { flags.append("Floating toolbar host · \(check.title): \(problem).") } }
        for check in light.placement { for problem in check.problems { flags.append("Floating toolbar placement · \(check.title): \(problem).") } }
        for check in dark.placement { for problem in check.problems { flags.append("Floating toolbar placement, dark · \(check.title): \(problem).") } }
        for check in light.pickerHost { for problem in check.problems { flags.append("Saved Prompts picker host · \(check.title): \(problem).") } }
        // A menu door that carries a page's sidebar name plus other words is the same door under
        // another name; the Grammar's Names rule gives a place one name on every surface.
        for entry in light.entries where entry.surface == "App menus" {
            guard let route = entry.route, let title = WorkbenchHome.navItems.first(where: { $0.0 == route })?.1,
                  let label = entry.label.components(separatedBy: " › ").last?.replacingOccurrences(of: "…", with: "") else { continue }
            if label != title && label.hasPrefix(title) { flags.append("\(entry.surface) · \(entry.label) opens \(title) under another name.") }
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
        img{display:block;max-width:100%;height:auto;border:1px solid var(--line);border-radius:6px}.panel img{width:328px}.picker img{width:452px}.page img{width:560px}.toolbar img{width:auto;max-height:72px}
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
        html += "<h3>Not rendered</h3><ul>" + ["Drawing", "Presenting a device scene", "Persona showing", "Timer running"].map {
            "<li>\($0): needs a live StageKit session (overlay windows or device capture). The options menus below show these rows' idle menus.</li>" }.joined() + "</ul>"
        html += "<h2>Home and the floating toolbar's switch</h2><p>Checked with the pass's own models; the pass fails if any of these does not hold (#134).</p><ul>"
            + light.checks.map { "<li class=\"ok\">\(esc($0))</li>" }.joined() + "</ul>"
        html += "<h2>Floating toolbar host</h2><p>The production host (<code>CapturePanelController</code>) driven offscreen for every mode, at rest and revealed, then switched between Dictate and Present while revealed, with its panel invisible. Each window is compared with what its row wants; a smaller window clips the row and its corners.</p>"
        if light.host.isEmpty { html += "<p>Not run: this Mac reported no display.</p>" }
        html += "<table><tr><th>State</th><th>Window</th><th>Row wants</th><th>Host heard the row</th><th>Twin heard its row</th><th>Check</th></tr>"
        for check in light.host {
            html += "<tr><td>\(esc(check.title))</td><td>\(points(check.window))</td><td>\(points(check.wants))</td><td>\(check.measured ? "Yes" : "No")</td><td>\(check.twinMeasured ? "Yes" : "No")</td>"
                + (check.problems.isEmpty ? "<td class=\"ok\">Fits</td>" : "<td class=\"flag\">\(esc(check.problems.joined(separator: "; ")))</td>") + "</tr>"
        }
        html += "</table>"
        html += "<h3>Placement</h3><p>The same host released away from every dock, near one, after an update, revealed and collapsed, and read again by a new host as after a relaunch (#163); every position is read at the launcher's centre, which the compact rest shares, and the chooser opens from three docks (#134).</p>"
        if light.placement.isEmpty { html += "<p>Not run: this Mac reported no display.</p>" }
        // Both passes' tables: they run at once, so a step can fail in one theme only.
        html += "<table><tr><th>Step</th><th>Light</th><th>Dark</th></tr>" + light.placement.enumerated().map { index, check in
            func cell(_ check: SurfaceGallery.PlacementCheck?) -> String {
                guard let check else { return "<td>Not run</td>" }
                return check.problems.isEmpty ? "<td class=\"ok\">Rests where it was put</td>" : "<td class=\"flag\">\(esc(check.problems.joined(separator: "; ")))</td>"
            }
            return "<tr><td>\(esc(check.title))</td>" + cell(check) + cell(index < dark.placement.count ? dark.placement[index] : nil) + "</tr>"
        }.joined() + "</table>"
        for (index, shot) in light.toolbar.enumerated() {
            html += "<h3>\(esc(shot.title))</h3><p>\(esc(shot.detail))</p><div class=\"row toolbar\">" + figure(shot, "Light")
                + (index < dark.toolbar.count ? figure(dark.toolbar[index], "Dark") : "") + "</div>"
        }
        html += "<h2>Saved Prompts picker</h2><p>Present's Prompts accessory and the glyph menu's Saved Prompts… open this picker. Its states are drawn at its 420-point width on the window background from synthetic prompts; its keyboard and choices are covered by --check-core. The production panel (<code>PromptPickerController</code>) is then opened invisibly over a bottom-docked Prompts button, narrowed to one row, given a status line and its Details, and widened to every prompt again. Each time its panel is compared with what its content wants.</p>"
        if light.pickerHost.isEmpty { html += "<p>The production panel was not opened: this Mac reported no display.</p>" }
        else {
            html += "<table><tr><th>State</th><th>Panel</th><th>Content wants</th><th>Panel heard its content</th><th>Check</th></tr>"
            for check in light.pickerHost {
                html += "<tr><td>\(esc(check.title))</td><td>\(points(check.window))</td><td>\(points(check.wants))</td><td>\(check.heard ? "Yes" : "No")</td>"
                    + (check.problems.isEmpty ? "<td class=\"ok\">Fits</td>" : "<td class=\"flag\">\(esc(check.problems.joined(separator: "; ")))</td>") + "</tr>"
            }
            html += "</table>"
        }
        for (index, shot) in light.pickers.enumerated() {
            html += "<h3>\(esc(shot.title))</h3><p>\(esc(shot.detail))</p><div class=\"row picker\">" + figure(shot, "Light")
                + (index < dark.pickers.count ? figure(dark.pickers[index], "Dark") : "") + "</div>"
        }
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
            "Combined drawing, presenting, Persona and timer rows use frozen synthetic state in the production panel. This proves labels and layout only; live StageKit windows, device capture and mouse interaction still need installed acceptance.",
            "The floating toolbar host is driven with its panel at alpha zero and mouse events ignored, in every mode but with no live work; in a local run a pointer inside that invisible frame can hold the row revealed, which the check reports as not settling.",
            "The Saved Prompts panel is opened the same way, with no keyboard focus and no click monitors; its placement, focus return and dismissal need a pointer on the installed app.",
            "StageKit is never started, so Draw reports Ready on 0 displays.",
            "Workbench is never the active app, so controls draw in their inactive style.",
            "Menu contents are listed as text. The Dictate options menu is SwiftUI and is listed from its source; the others are the panel's own native menus.",
            "Buttons and keys come from a catalogue in SurfaceGallery.swift; add a row there when adding an entry. The app menus are read from the menu bar AppDelegate builds, so their names and pages are the app's own.",
            "Snap & Talk shows its first-run page. An open session shows its folder path and this Mac's Microphone access. Screen Recording reads as allowed, except in the Screen Recording off states.",
            "History shows the synthetic transcripts and Snaps, then its states: empty; All with Hand off tasks and two items selected; Results with running, completed, failed and Ready tasks; and Transcripts. Tasks run through a synthetic provider with a fixed clock; no process starts. The running strip draws a still symbol in place of its live indicator. Snap shows three synthetic Snaps with fixed dates.",
            "The meeting page lists two synthetic audio apps instead of this Mac's; the meeting status row comes from a synthetic capture that records nothing.",
            "The speech engine is never loaded, so Models shows a fresh install. Mac voices, Apple Intelligence availability and keyboard labels come from the rendering Mac.",
            "Pixel sizes follow the rendering display's scale."].map { "<li>\(esc($0))</li>" }.joined() + "</ul></body></html>\n"
        try Data(html.utf8).write(to: output.appendingPathComponent("index.html"), options: .atomic)
        let shots = passes.flatMap { pass in pass.panels + pass.toolbar + pass.pickers + pass.pages.flatMap(\.shots) }.map { ["file": $0.file, "width": $0.width, "height": $0.height] as [String: Any] }
        let manifest: [String: Any] = ["renders": shots, "flags": flags, "entries": light.entries.map { ["surface": $0.surface, "label": $0.label, "leads": $0.leads] }]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("manifest.json"))
        return flags.count
    }

    func points(_ size: [Double]) -> String { size.count == 2 ? "\(Int(ceil(size[0]))) × \(Int(ceil(size[1]))) pt" : "?" }

    func figure(_ shot: SurfaceGallery.Shot, _ theme: String) -> String {
        "<figure><a href=\"\(esc(shot.file))\"><img src=\"\(esc(shot.file))\" alt=\"\(esc(shot.title)), \(theme)\" loading=\"lazy\"></a>"
            + "<figcaption>\(theme) · \(esc(shot.title)) · \(shot.width) × \(shot.height) px</figcaption></figure>"
    }

    func esc(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

extension SurfaceGallery.PickerHostCheck {
    /// The panel never heard its content, or is not the size its content wants within the
    /// display. A picker that closed during the check (a click in a local run) is only reported.
    var hasSizeProblem: Bool { settled && !problems.isEmpty }
}

extension SurfaceGallery.HostCheck {
    /// The host never heard the row, the window is smaller than the row wants, or the window is
    /// not the size the host prefers. A state that did not reach its tier is not compared: in a
    /// local run a real pointer inside the invisible panel can hold the row revealed, and that
    /// window is not the resting size its twin wants. Not settling is itself reported only.
    var hasSizeProblem: Bool {
        guard settled else { return false }
        guard window.count == 2, wants.count == 2, preferred.count == 2 else { return true }
        return !measured || window[0] + 0.5 < wants[0] || window[1] + 0.5 < wants[1]
            || abs(window[0] - preferred[0]) > 0.5 || abs(window[1] - preferred[1]) > 0.5
    }
}

/// Two known meeting apps with audio, so the meeting page lists choices without reading CoreAudio.
private final class SyntheticAudioApps: MeetingProcessSource {
    var isAvailable: Bool { true }
    var unavailableReason: String { "" }
    func snapshot() throws -> [MeetingProcessSnapshot] {
        [.init(pid: 41_001, bundleID: "us.zoom.xos", isRunningInput: true, isRunningOutput: true, name: "Zoom"),
         .init(pid: 41_002, bundleID: "com.microsoft.teams2", isRunningInput: false, isRunningOutput: true, name: "Microsoft Teams")]
    }
}

/// Reports a started capture and records nothing: no device, tap or permission is touched.
private final class SilentMeetingCapture: MeetingCapture {
    func start(_ request: MeetingCaptureRequest) async throws {}
    func finish() async -> MeetingCaptureReport { MeetingCaptureReport() }
    func requestStop() {}
    var elapsedSeconds: Double { 0 }
    var stopReason: String? { nil }
}
