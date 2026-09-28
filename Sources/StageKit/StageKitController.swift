import AppKit
import SwiftUI
import Combine
import Carbon
import SceneSyncKit

/// Carbon key codes and modifier masks, shared with macOS global shortcuts.
public struct StageShortcutDescriptor: Identifiable, Equatable {
    public let id: String
    public let label: String
    public let keyCode: UInt32
    public let modifiers: UInt32
    public let enabled: Bool
    public let error: String?
    public let keyLabel: String
}

/// Presentation capabilities hosted by Workbench's single application shell.
/// StageKit never creates a menu-bar item or independently terminates the app.
@MainActor
public final class StageKitController: ObservableObject {
    private let coordinator: AppCoordinator
    private var observations = Set<AnyCancellable>()
    private var started = false

    public var onOpenControls: (() -> Void)? {
        didSet { coordinator.onOpenControls = onOpenControls }
    }
    public var onOpenScenes: (() -> Void)? {
        didSet { coordinator.onOpenScenes = onOpenScenes; coordinator.demoScenes.onOpen = onOpenScenes }
    }
    /// Opens the host’s independent Persona workspace. Scene selection keeps its own sheet.
    public var onOpenPersonas: (() -> Void)?
    public var onOpenShortcuts: (() -> Void)? {
        didSet { coordinator.onOpenShortcuts = onOpenShortcuts }
    }
    public var onEditShortcuts: (() -> Void)? {
        get { onOpenShortcuts }
        set { onOpenShortcuts = newValue }
    }
    public var onShortcutsChanged: (() -> Void)? {
        didSet { coordinator.onShortcutsChanged = onShortcutsChanged }
    }
    public var mayBeginInteraction: (() -> Bool)? {
        didSet {
            coordinator.mayBeginInteraction = mayBeginInteraction; coordinator.demoScenes.mayBeginInteraction = mayBeginInteraction
            coordinator.demoScenes.personas.mayBeginInteraction = mayBeginInteraction
        }
    }
    /// Drawing may coexist with a host recording; other StageKit actions retain
    /// the broader interaction guard. An unset drawing guard uses that guard.
    public var mayBeginDrawing: (() -> Bool)? {
        didSet { coordinator.mayBeginDrawing = mayBeginDrawing }
    }
    /// Called after input ownership changes, once per drawing state transition.
    public var onDrawingChanged: ((Bool) -> Void)? {
        didSet { coordinator.onDrawingChanged = onDrawingChanged }
    }
    /// Hide the shell before drawing, starting a timer or presenting a scene.
    public var onBeginActivity: (() -> Void)? {
        didSet {
            coordinator.onBeginActivity = onBeginActivity
            coordinator.demoScenes.onBeginPresentation = onBeginActivity
            coordinator.demoScenes.personas.onShow = onBeginActivity
        }
    }
    /// Supply the other modules' shortcuts so every entry point checks conflicts.
    /// Return a concise reason when the combination belongs to another module.
    public var validateExternalShortcut: ((UInt32, UInt32) -> String?)? {
        didSet {
            // A host's nil result means available. Only standalone Stage uses fixed reservations.
            coordinator.validateExternalShortcut = validateExternalShortcut ?? Self.reservedVoiceShortcut
            if started { coordinator.setShortcutsSuspended(true); coordinator.setShortcutsSuspended(false) }
        }
    }

    /// `defaults` replaces the edition's presentation preferences only for isolated fixtures.
    public init(onOpenControls: (() -> Void)? = nil, onOpenScenes: (() -> Void)? = nil,
                reserving shortcuts: Set<GlobalShortcutCombination> = [], defaults: UserDefaults? = nil) {
        let defaults = defaults ?? Workbench.stageDefaults
        let migrationNotice = Workbench.prepareStageData(defaults: defaults)
        let settings = SettingsStore(defaults: defaults, reserving: shortcuts)
        let coordinator = AppCoordinator(settings: settings, embedded: true, migrationFailure: migrationNotice)
        self.coordinator = coordinator
        self.onOpenControls = onOpenControls
        self.onOpenScenes = onOpenScenes
        coordinator.onOpenControls = onOpenControls
        coordinator.onOpenScenes = onOpenScenes
        coordinator.demoScenes.onOpen = onOpenScenes
        coordinator.validateExternalShortcut = Self.reservedVoiceShortcut
        if let migrationNotice { coordinator.notice = migrationNotice }
        observe(coordinator)
    }
    /// Checks wrap a coordinator on disposable storage; the app uses the initializer above.
    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        observe(coordinator)
    }
    private func observe(_ coordinator: AppCoordinator) {
        coordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        coordinator.settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        coordinator.demoScenes.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        coordinator.demoScenes.personas.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
    }

    /// Embedded Workbench owns the sole live control surface. Standalone
    /// StageKit fixtures retain their existing controls for compatibility.
    public var onFocusActivityControls: ((String) -> Void)? {
        didSet {
            coordinator.demoScenes.onFocusSharedControls = { [weak self] in self?.onFocusActivityControls?("present") }
            coordinator.demoScenes.personas.onFocusSharedControls = { [weak self] in self?.onFocusActivityControls?("persona") }
        }
    }
    public func useSharedActivityControls() {
        coordinator.demoScenes.usesSharedControls = true
        coordinator.demoScenes.personas.usesSharedControls = true
    }
    public var hasActivePersona: Bool { hasActivePersonaSession || coordinator.demoScenes.personas.overlayVisible }
    public var personaStatus: String {
        let library = coordinator.demoScenes.personas
        if library.sessionState.phase == .paused { return "Hidden" }
        if library.sessionState.phase != .idle { return "\(library.sessionState.instances.filter(\.visible).count) Overlays" }
        if library.overlayVisible { return "Shown" }
        // A hidden card is kept for Show again, like a paused set.
        return library.hasHiddenCard ? "Hidden" : ""
    }
    public func togglePersona() {
        if case .failure = coordinator.demoScenes.personas.togglePersonaVisibility() { showPersonas() }
    }
    public func makePersonaMenu(includePreparation: Bool = false) -> NSMenu {
        let menu = coordinator.demoScenes.personas.makeControlsMenu()
        if includePreparation {
            menu.addItem(.separator())
            menu.addItem(StageMenuAction("Prepare Personas…") { [weak self] in self?.showPersonas() })
        }
        return menu
    }
    public func makePresentationMenu() -> NSMenu { coordinator.demoScenes.makeControlsMenu() }
    /// One live persona copy, named exactly: the one floating card, or one copy of
    /// a prepared set. Capture it when a control is drawn, so a later choice
    /// changes that copy and never another (#169, #134).
    public struct PersonaCopy: Equatable { fileprivate let copy: PersonaLiveCopy }
    /// Circle, Card or Original: Persona's one appearance choice.
    public enum PersonaShape: String, CaseIterable, Sendable {
        case circle, card, original
        public var title: String { PersonaAppearance.Shape(rawValue: rawValue)?.title ?? rawValue }
    }
    /// The live copy Persona's Options act on now: the selected copy of a prepared
    /// set, or else the one floating card. nil when no persona is live.
    public var selectedPersonaCopy: PersonaCopy? { coordinator.demoScenes.personas.selectedLiveCopy.map { PersonaCopy(copy: $0) } }
    /// The look that copy shows now; nil once it is no longer live.
    public func personaShape(of copy: PersonaCopy) -> PersonaShape? {
        coordinator.demoScenes.personas.liveShape(of: copy.copy).flatMap { PersonaShape(rawValue: $0.rawValue) }
    }
    /// Changes exactly that live copy's look, as its Appearance menu does. The
    /// saved persona, other copies and the layout's saved state are unchanged.
    public func setPersonaShape(_ shape: PersonaShape, for copy: PersonaCopy) {
        guard let look = PersonaAppearance.Shape(rawValue: shape.rawValue) else { return }
        coordinator.demoScenes.personas.setLiveShape(look, for: copy.copy)
    }
    /// The panel row starts and stops the timer; the overlay keeps pause and reset.
    public func startTimer() { coordinator.startTimer() }
    public func stopTimer() { coordinator.resetTimer(); coordinator.hideTimer() }
    /// The panel's persona options: the set, the persona, add, hide or show,
    /// the layout and End. Selection-scoped adjustments (size, lock, position, appearance,
    /// replace, order, remove) stay in the HUD and toolbar menus.
    public func makePersonaPanelMenu() -> NSMenu {
        let library = coordinator.demoScenes.personas
        let menu = library.makeControlsMenu()
        // The panel already shows these in its own feedback line.
        let feedback = library.sessionState.feedback ?? library.cardFeedback
        let selectionScoped = ["Lock Artwork · Clicks Pass Through", "Position Artwork", "Appearance", "Replace Selected", "Hide Selected",
                               "Show Selected", "Bring Forward", "Send Backward", "Remove Selected"]
        for item in menu.items {
            let dropped = item.view != nil || (feedback != nil && item.title == feedback)
                || selectionScoped.contains(item.title)
                || (!item.isEnabled && item.submenu == nil && item.title.hasSuffix("first."))
            if dropped { menu.removeItem(item) }
        }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        return menu
    }
    /// `optionsOnly` leaves out the transport (start, pause, stop, reset): the
    /// panel row starts and stops, and the overlay keeps pause and reset.
    public func makeTimerMenu(optionsOnly: Bool = false) -> NSMenu {
        let app = coordinator
        let menu = NSMenu(title: "Timer"); menu.autoenablesItems = false
        if !optionsOnly {
            menu.addItem(StageMenuAction("Start Timer", enabled: mayBeginInteraction?() != false) { [weak app] in app?.startTimer() })
            let transport = app.timerTransport
            menu.addItem(StageMenuAction(app.timerRunning ? "Pause Timer" : "Resume Timer", enabled: transport == .running || transport == .paused) { [weak app] in app?.pauseResumeTimer() })
            menu.addItem(StageMenuAction("Stop Timer", enabled: app.timerSessionStarted) { [weak app] in app?.resetTimer(); app?.hideTimer() })
            menu.addItem(StageMenuAction("Reset Timer") { [weak app] in app?.resetTimer() })
        }
        menu.addSubmenu("Duration", items: [1, 5, 10, 15, 30, 60].map { minutes in
            StageMenuAction("\(minutes) min", checked: app.settings.value.timerMinutes == Double(minutes)) { [weak app] in
                app?.settings.value.timerMinutes = Double(minutes)
                // A duration change applies on the next Start or Reset.
            }
        })
        menu.addSubmenu("Position", items: FloatingControlAnchor.allCases.map { anchor in
            StageMenuAction(anchor.title, checked: app.timerPlacementAnchor == anchor) { [weak app] in app?.setTimerPosition(anchor) }
        })
        menu.addItem(StageMenuAction("Chime When Finished", checked: app.settings.value.timerChime) { [weak app] in
            guard let app else { return }; app.settings.value.timerChime.toggle()
        })
        return menu
    }
    public var controlsView: AnyView { AnyView(ControlCenter(app: coordinator, settings: coordinator.settings)) }
    public var scenesView: AnyView { AnyView(DemoScenesView(model: coordinator.demoScenes)) }
    public var personasView: AnyView { AnyView(PersonaLibraryView(library: coordinator.demoScenes.personas, mode: .workspace)) }

    /// Installing a pack supplies starters; importing explicitly creates a personal copy.
    public func importPackScene(at url: URL) throws {
        guard let library = coordinator.demoScenes.sceneSync?.library else {
            throw SceneDocumentError.invalid("The scene library is unavailable. Reopen Workbench and try again.")
        }
        let record = try library.importPackage(SceneFile.read(url))
        coordinator.demoScenes.query = ""
        coordinator.demoScenes.selectedID = record.id
        coordinator.demoScenes.notice = "Added a personal scene copy. Pack updates will not change it."
    }

    public func importPackPersona(at url: URL, name: String) throws {
        _ = try coordinator.demoScenes.personas.addImage(url, name: name,
                                                        card: PersonaCardStyle(label: name))
    }
    public var quickControlsView: AnyView { AnyView(QuickControlsView(app: coordinator, settings: coordinator.settings)) }
    /// One native menu for the application menu bar or the shell's status menu.
    /// It refreshes tool state and shortcut labels whenever it opens; StageKit
    /// continues to own all drawing actions and their existing global keys.
    public func makeAnnotationMenu(includeSettings: Bool = true) -> NSMenu { AnnotationMenu(coordinator: coordinator, includeSettings: includeSettings) }
    /// Opens an existing-scene choice followed by the ordinary backdrop preview.
    /// The caller presents this as a sheet; no scene changes until Use backdrop.
    public func backdropReplacementView(imageURL: URL, title: String) -> AnyView {
        AnyView(PhotoBackdropChooser(model: coordinator.demoScenes, imageURL: imageURL, title: title))
    }
    public var isDrawing: Bool { coordinator.isDrawing }
    public var drawingActivationTitle: String { coordinator.settings.value.activation.rawValue }
    public var drawingToolTitle: String { coordinator.tool.title }
    public var isPresenting: Bool { coordinator.demoScenes.isPresenting }
    public var hasActivePersonaSession: Bool { coordinator.demoScenes.personas.sessionState.phase != .idle }
    public var isPersonaSessionPaused: Bool { coordinator.demoScenes.personas.sessionState.phase == .paused }
    public var isTakingScreenshot: Bool { coordinator.screenshotHandoffActive }
    public func presentSelectedScene() {
        if coordinator.demoScenes.selected == nil { onOpenScenes?() }
        else {
            coordinator.demoScenes.startDemo(mode: .windowed)
            if !coordinator.demoScenes.isPresenting { onOpenScenes?() }
        }
    }
    public func endDeviceScene() { coordinator.demoScenes.endPresentation() }
    public var hasOverlaySession: Bool { coordinator.demoScenes.personas.sessionState.phase != .idle }
    public var areOverlaysPaused: Bool { coordinator.demoScenes.personas.sessionState.phase == .paused }
    public var canStepOverlays: Bool { coordinator.demoScenes.personas.sessionState.groups.count > 1 }
    public var timerText: String { coordinator.timerText }
    public var isTimerRunning: Bool { coordinator.timerRunning }
    public var hasTimerSession: Bool { coordinator.timerSessionStarted }
    public var hasActiveTimer: Bool { coordinator.hasActiveTimer }
    /// A card that could not show is live, so it comes before an older scene notice.
    public var notice: String? {
        let personas = coordinator.demoScenes.personas
        return coordinator.notice ?? coordinator.settings.notice ?? personas.cardFeedback ?? coordinator.demoScenes.notice ?? personas.notice
    }

    public func start() {
        guard !started else { return }
        started = true
        coordinator.start()
    }
    public func shutdown() {
        guard started else { return }
        started = false
        coordinator.shutdown()
    }
    public func draw() { coordinator.startDrawing(.pen, latched: true) }
    /// Return input without clearing the current ink or removing a board.
    public func finishDrawing() { coordinator.stopDrawing() }
    public func clear() { coordinator.perform(.clear) }
    public func showBoard() { coordinator.toggleBoard(.white) }
    public func showTimer() { coordinator.toggleTimer() }
    public func showScenes() { coordinator.showDemoScenes() }
    public func showPersonas() {
        if let onOpenPersonas { onOpenPersonas() }
        else { coordinator.demoScenes.showPersonas() }
    }
    public func focusOverlayControls() { coordinator.demoScenes.personas.focusOverlayControls() }
    public func stepOverlaySet(_ offset: Int) { coordinator.demoScenes.personas.performOverlayAction(.stepGroup(offset)) }
    public func toggleOverlayVisibility() { coordinator.demoScenes.personas.performOverlayAction(.pauseResume) }
    public func escape() { coordinator.escape() }
    public func performShortcut(id: String) {
        guard let action = Action(rawValue: id) else { return }
        coordinator.perform(action)
    }
    public func setShortcutsSuspended(_ suspended: Bool) { coordinator.setShortcutsSuspended(suspended) }
    public func resetShortcuts() { coordinator.restoreShortcuts() }
    public func refreshShortcutRegistration() { if started { coordinator.refreshShortcutRegistration() } }

    public var shortcutDescriptors: [StageShortcutDescriptor] {
        StageShortcutSettings.descriptors(for: coordinator.settings.value, failures: coordinator.shortcutFailures)
    }

    /// Returns a validation failure without changing the saved shortcut.
    @discardableResult
    public func updateShortcut(id: String, keyCode: UInt32, modifiers: UInt32, enabled: Bool) -> String? {
        guard let action = Action(rawValue: id) else { return "That action is no longer available." }
        let shortcut = Shortcut(keyCode: keyCode, modifiers: modifiers, enabled: enabled)
        if enabled {
            guard modifiers & UInt32(controlKey | optionKey) != 0 else { return "Include Control or Option." }
            if let message = coordinator.validateExternalShortcut?(keyCode, modifiers) { return message }
            if let conflict = Action.allCases.first(where: { $0 != action && coordinator.settings.value.shortcut(for: $0) == shortcut }) {
                return "That shortcut belongs to \(conflict.title). Choose another combination."
            }
        }
        coordinator.settings.value.shortcuts[action.rawValue] = shortcut
        return nil
    }

    private static func reservedVoiceShortcut(_ code: UInt32, _ modifiers: UInt32) -> String? {
        guard modifiers == UInt32(optionKey), [UInt32(kVK_ANSI_Q), UInt32(kVK_ANSI_W), UInt32(kVK_ANSI_C), UInt32(kVK_ANSI_V)].contains(code) else { return nil }
        return "This combination is reserved for Voice. Choose another combination."
    }
}

@MainActor
private struct PhotoBackdropChooser: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DemoScenes
    let imageURL: URL
    let title: String
    @State private var sceneID: UUID?
    @State private var draft: BackdropReplacement?
    @State private var notice: String?
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let draft {
                BackdropReplacementView(model: model, draft: draft)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Use photo as backdrop").font(.title2.weight(.semibold))
                        Spacer()
                        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                    HStack(spacing: 16) {
                        Group {
                            if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                            else { Image(systemName: "photo").foregroundStyle(.secondary) }
                        }.frame(width: 120, height: 90).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title).font(.headline).lineLimit(2)
                            Text("Choose a saved scene. Review the crop next, then apply when it looks right.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if model.storageBlocked {
                        ContentUnavailableView("Saved scenes need attention", systemImage: "exclamationmark.folder",
                            description: Text("The scene library could not be read. Its original files are preserved. You can still save a separate copy of this photo."))
                    } else if model.scenes.isEmpty {
                        ContentUnavailableView("Prepare a scene first", systemImage: "rectangle.on.rectangle",
                            description: Text("Create a scene in Present, then return to this photo. Choosing a backdrop never creates a duplicate scene."))
                    } else {
                        List(selection: $sceneID) {
                            ForEach(model.scenes) { scene in
                                Label(scene.name, systemImage: "rectangle.on.rectangle")
                                    .padding(.vertical, 7).tag(scene.id)
                            }
                        }.accessibilityLabel("Choose a saved scene")
                            .accessibilityIdentifier("handoff.backdrop-scenes")
                    }
                    if let notice { Text(notice).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    Spacer(minLength: 0)
                    Divider()
                    HStack {
                        Text("Only the backdrop changes. Foreground layers and the current presentation stay as they are.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Preview backdrop") {
                            guard let sceneID else { return }
                            do { draft = try model.makeBackdropReplacement(sceneID: sceneID, imageURL: imageURL, title: title) }
                            catch { notice = error.localizedDescription }
                        }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(model.storageBlocked || thumbnail == nil || !model.scenes.contains { $0.id == sceneID })
                            .accessibilityIdentifier("handoff.preview-backdrop")
                    }
                }.padding(20).frame(width: 840, height: 660)
                    .background(Workbench.background).tint(Workbench.accent).workbenchTheme()
            }
        }.onAppear {
            sceneID = model.selected?.id ?? model.scenes.first?.id
            do { thumbnail = try BackdropImage.thumbnail(imageURL) }
            catch { notice = "The photo could not be opened. " + error.localizedDescription }
        }.onDisappear { draft?.cancel() }
    }
}
