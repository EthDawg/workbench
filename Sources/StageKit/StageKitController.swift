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
    private let profileDefaults: UserDefaults
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
    public var onViewImages: (([StageImagePreview], UUID) -> Void)? {
        didSet {
            coordinator.demoScenes.onViewImages = onViewImages
            coordinator.demoScenes.personas.onViewImages = onViewImages
        }
    }
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
        self.profileDefaults = defaults
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
        // Boards and scenes that could not be copied: Draw shows it with its other board notices.
        if let migrationNotice { coordinator.post(migrationNotice, on: .draw) }
        observe(coordinator)
    }
    /// Checks wrap a coordinator on disposable storage; the app uses the initializer above.
    init(coordinator: AppCoordinator, profileDefaults: UserDefaults = .standard) {
        self.coordinator = coordinator
        self.profileDefaults = profileDefaults
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
    /// Persona has something on screen, or is opening a source for it, so its
    /// doors offer that source's ending rather than a new start.
    public var hasActivePersona: Bool {
        hasActivePersonaSession || coordinator.demoScenes.personas.overlayVisible
            || coordinator.demoScenes.personas.camera.isStarting
    }
    /// Anything a live door can hide, show again or end, including a camera visit
    /// that is still starting or has stopped with a reason.
    public var hasLivePersonaSource: Bool {
        let library = coordinator.demoScenes.personas
        return hasActivePersonaSession || library.overlayVisible || library.hasHiddenCard || library.cameraOwnsSlot
    }
    /// A projection of the single camera owner for Home, the panel and toolbar.
    public enum PersonaCameraPhase: Sendable { case off, starting, live, hidden, failed }
    public var personaCameraPhase: PersonaCameraPhase {
        let library = coordinator.demoScenes.personas
        guard library.cameraOwnsSlot else { return .off }
        switch library.camera.state {
        case .off: return .off
        case .permission, .starting: return .starting
        case .live: return .live
        case .hidden: return .hidden
        case .failed: return .failed
        }
    }
    public var personaCameraMayResume: Bool {
        coordinator.demoScenes.personas.camera.failure?.offersRetry != false
    }
    public var personaStatus: String {
        let library = coordinator.demoScenes.personas
        if library.cameraOwnsSlot { return library.camera.status }
        if library.sessionState.phase == .paused { return "Hidden" }
        if library.sessionState.phase != .idle { return "\(library.sessionState.instances.filter(\.visible).count) Overlays" }
        if library.overlayVisible { return "Shown" }
        // A hidden card is kept for Show again, like a paused set.
        return library.hasHiddenCard ? "Hidden" : ""
    }
    /// The live source is kept but off screen: a paused set, a hidden card, or a
    /// camera bubble that is hidden or stopped and waiting to be started again.
    public var isPersonaHidden: Bool {
        let library = coordinator.demoScenes.personas
        if library.cameraOwnsSlot { return library.camera.isHidden || library.camera.failure != nil }
        if library.sessionState.phase == .paused { return true }
        return library.sessionState.phase == .idle && library.hasHiddenCard
    }
    /// Exactly what `togglePersona()` will do to the live source now, for a
    /// control that must name the operation it performs.
    public var personaVisibilityTitle: String {
        let library = coordinator.demoScenes.personas
        if library.cameraOwnsSlot {
            switch library.camera.state {
            case .permission, .starting: return "Cancel"
            case .live: return "Hide camera"
            case .hidden: return "Show camera again"
            case .failed: return "Try again"
            case .off: break
            }
        }
        return isPersonaHidden ? "Show again" : "Hide"
    }
    /// End names the source it releases.
    public var personaEndTitle: String {
        coordinator.demoScenes.personas.cameraOwnsSlot ? "End camera" : "End Persona"
    }
    public func togglePersona() {
        if case .failure = coordinator.demoScenes.personas.togglePersonaVisibility() { showPersonas() }
    }
    public func endPersona() { coordinator.demoScenes.personas.endLivePersona() }
    public var personaSessionIdentity: UUID { coordinator.demoScenes.personas.liveControlsGeneration }
    public func makePersonaMenu(includePreparation: Bool = false) -> NSMenu {
        let menu = coordinator.demoScenes.personas.makeControlsMenu()
        if includePreparation {
            menu.addItem(.separator())
            menu.addItem(StageMenuAction("Prepare Personas…") { [weak self] in self?.showPersonas() })
        }
        return menu
    }
    public func makePresentationMenu() -> NSMenu { coordinator.demoScenes.makeControlsMenu() }
    public func makePresentationViewMenu() -> NSMenu { coordinator.demoScenes.makeViewMenu() }
    public struct PersonaCycle: Equatable {
        let generation: UUID
        let revision: UUID
        let selection: UUID
        public let title: String
        public let isSet: Bool
        public let canAdvance: Bool
    }
    public var personaCycle: PersonaCycle? { coordinator.demoScenes.personas.toolbarCycle }
    public var personaCycleNotice: String? { coordinator.demoScenes.personas.cardFeedback ?? coordinator.demoScenes.personas.sessionState.feedback }
    public func stepPersona(expected: PersonaCycle, offset: Int = 1) {
        coordinator.demoScenes.personas.stepToolbarPersona(expected: expected, offset: offset)
    }
    /// The pill's one Persona picker: a prepared set's current set, or the shown
    /// card, the camera or nothing yet among Persona's choices.
    public struct PersonaPicker: Equatable {
        /// The current choice's public name; empty while nothing is live.
        public let title: String
        public let isSet: Bool
    }
    public var personaPicker: PersonaPicker? { coordinator.demoScenes.personas.toolbarPicker }
    /// The cards Persona can show now, then Camera; a prepared set's sets.
    public func makePersonaPickerMenu() -> NSMenu { coordinator.demoScenes.personas.makeToolbarPickerMenu() }
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
    /// Whether that copy is hidden now: the one floating card kept for Show again,
    /// or a set's copy while the set or the copy is hidden. False once it is gone.
    public func isPersonaCopyHidden(_ copy: PersonaCopy) -> Bool {
        coordinator.demoScenes.personas.liveCopyHidden(copy.copy) == true
    }
    /// Whether this menu holds a live copy's Appearance: an item with that title and a submenu, as
    /// the Persona menu names it for a shown card and for a set's selected copy, never for a hidden
    /// card. Found by its title, so choices added under it or reordered never make the floating
    /// toolbar's More add a second Appearance beside it (#134 part B, #216).
    public static func personaMenuHoldsAppearance(_ menu: NSMenu) -> Bool {
        menu.items.contains { $0.title == "Appearance" && $0.hasSubmenu }
    }
    /// Changes exactly that live copy's look, as its Appearance menu does. The
    /// saved persona, other copies and the layout's saved state are unchanged.
    public func setPersonaShape(_ shape: PersonaShape, for copy: PersonaCopy) {
        guard let look = PersonaAppearance.Shape(rawValue: shape.rawValue) else { return }
        coordinator.demoScenes.personas.setLiveShape(look, for: copy.copy)
    }
    /// The panel row starts and stops the timer; its Options, Home, the chooser and the
    /// timer's own window carry the next step and Show or Hide timer.
    public func startTimer() { coordinator.startTimer() }
    /// Stop timer: the countdown ends and its window closes.
    public func stopTimer() { coordinator.resetTimer(); coordinator.hideTimer() }
    /// Whether the timer's window is on screen; hiding it leaves the countdown running.
    public var isTimerShown: Bool { coordinator.timerShown }
    /// Show timer or Hide timer, for the window alone. Show needs a started countdown.
    public func setTimerShown(_ shown: Bool) { shown ? coordinator.revealTimer() : coordinator.hideTimer() }
    /// One line for a started timer on every surface: its time, then Paused, Time is up
    /// or Hidden when they apply. Empty before it starts.
    public var timerStateDetail: String {
        guard coordinator.timerSessionStarted else { return "" }
        var parts = [coordinator.timerFinished ? "Time is up" : coordinator.timerText]
        if coordinator.timerTransport == .paused { parts.append("Paused") }
        if !coordinator.timerShown { parts.append("Hidden") }
        return parts.joined(separator: " · ")
    }
    /// The panel retains the live-copy adjustments as an alternate home to the Persona
    /// workspace. Feedback already shown by the panel is not repeated in its menu.
    public func makePersonaPanelMenu() -> NSMenu {
        let library = coordinator.demoScenes.personas
        let menu = library.makeControlsMenu()
        // The panel already shows these in its own feedback line.
        let feedback = library.sessionState.feedback ?? library.cardFeedback
        for item in menu.items {
            let dropped = (feedback != nil && item.title == feedback)
                || (!item.isEnabled && item.submenu == nil && item.title.hasSuffix("first."))
            if dropped { menu.removeItem(item) }
        }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        return menu
    }
    /// One word set for the timer (1 October): its next step (Start, Pause, Resume or
    /// Restart Timer), Show or Hide Timer for the window alone, and Stop Timer, which ends
    /// the countdown and closes its window. `optionsOnly` leaves out Start and Stop, which
    /// the panel row does; a started timer's next step and Show or Hide stay in its Options.
    public func makeTimerMenu(optionsOnly: Bool = false) -> NSMenu {
        let app = coordinator
        let menu = NSMenu(title: "Timer"); menu.autoenablesItems = false
        // The one next step as shown now, and only that (#174): a running countdown offers
        // Pause, never a second Start that would silently restart it.
        let transport = TimerTransportAction(app)
        if !optionsOnly || app.timerSessionStarted {
            menu.addItem(StageMenuAction(transport.transport.title + " Timer",
                                         enabled: !transport.transport.starts || mayBeginInteraction?() != false) { transport() })
        }
        if app.timerSessionStarted {
            let shown = app.timerShown
            menu.addItem(StageMenuAction(shown ? "Hide Timer" : "Show Timer") { [weak app] in
                if shown { app?.hideTimer() } else { app?.revealTimer() }
            })
            if !optionsOnly { menu.addItem(StageMenuAction("Stop Timer") { [weak app] in app?.resetTimer(); app?.hideTimer() }) }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addSubmenu("Duration", items: [1, 5, 10, 15, 30, 60].map { minutes in
            StageMenuAction("\(minutes) min", checked: app.settings.value.timerMinutes == Double(minutes)) { [weak app] in
                app?.settings.value.timerMinutes = Double(minutes)
                // A duration change applies on the next Start or Reset.
            }
        })
        // Position…: the floating toolbar's compact eight-dock control, not a submenu of
        // anchors (#134 Fit rule 1). It applies before the window first opens.
        menu.addItem(StageMenuAction("Position…") { [weak app] in app?.showTimerPositionControl() })
        menu.addItem(StageMenuAction("Chime When Finished", checked: app.settings.value.timerChime) { [weak app] in
            guard let app else { return }; app.settings.value.timerChime.toggle()
        })
        return menu
    }
    public var controlsView: AnyView { AnyView(ControlCenter(app: coordinator, settings: coordinator.settings)) }
    /// The timer's window content with its hover controls shown, for renders with synthetic state.
    public var timerWindowPreview: AnyView { AnyView(BreakTimerView(app: coordinator, settings: coordinator.settings, controlsShown: true)) }
    /// Position… as the Timer opens it: the shared eight-dock control, without Reset position.
    public var timerPositionControlPreview: AnyView {
        AnyView(FloatingPositionControl(current: coordinator.timerPlacementAnchor, choose: { _ in }, reset: nil, close: {},
                                        hint: "Or drag the timer window anywhere.", accessibilityLabel: "Timer position"))
    }
    /// Whether the Timer's Position… control is open.
    public var isTimerPositionControlShown: Bool { coordinator.timerPositionPanel.isShown }
    /// For renders: React to my voice turned on against a synthetic refused microphone, so the
    /// Persona page and its live menus show the refusal with Microphone Settings…. Nothing asks
    /// macOS or opens System Settings. The returned closure restores the earlier access.
    public func showSyntheticPersonaVoiceRefusal() -> () -> Void {
        let library = coordinator.demoScenes.personas
        let previous = library.replaceVoiceAccess(PersonaVoiceAccess(
            permission: { .denied }, requestPermission: { $0(false) },
            makeSource: { PersonaSilentVoiceSource() }, savedChoice: { false }, saveChoice: { _ in },
            openMicrophoneSettings: {}))
        library.setVoiceRing(true)
        return { _ = library.replaceVoiceAccess(previous) }
    }
    public var scenesView: AnyView { AnyView(DemoScenesView(model: coordinator.demoScenes)) }
    public func personasView(editProfile: @escaping () -> Void) -> AnyView {
        AnyView(PersonaLibraryView(library: coordinator.demoScenes.personas, mode: .workspace, editProfile: editProfile))
    }
    /// The local profile is a reference to an ordinary saved persona. It has no account,
    /// separate image store or automatic presentation lifecycle.
    public var localProfileImage: NSImage? {
        let library = coordinator.demoScenes.personas
        return LocalPersonaProfile.persona(in: library, defaults: profileDefaults).flatMap { library.renderedImage(for: $0) }
    }
    public var localProfileView: AnyView {
        AnyView(LocalPersonaProfileView(library: coordinator.demoScenes.personas, defaults: profileDefaults,
            changed: { [weak self] in self?.objectWillChange.send() }, openPersona: { [weak self] in self?.showPersonas() }))
    }

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
    /// Without its settings item, a caller may end the menu with its own items, built each time it opens.
    public func makeAnnotationMenu(includeSettings: Bool = true, trailing: (() -> [NSMenuItem])? = nil) -> NSMenu {
        AnnotationMenu(coordinator: coordinator, includeSettings: includeSettings, trailing: trailing)
    }
    /// Opens an existing-scene choice followed by the ordinary backdrop preview.
    /// The caller presents this as a sheet; no scene changes until Use backdrop.
    public func backdropReplacementView(imageURL: URL, title: String) -> AnyView {
        AnyView(PhotoBackdropChooser(model: coordinator.demoScenes, imageURL: imageURL, title: title))
    }
    /// Library holds file access only while reading; these views own immutable
    /// bytes and wait for Use backdrop/Create scene or Add persona before saving.
    public func backdropReplacementView(imageData: Data, title: String) throws -> AnyView {
        let image = try BackdropImage.decode(imageData)
        return AnyView(PhotoBackdropChooser(model: coordinator.demoScenes, image: image, title: title))
    }
    public func personaImportView(imageData: Data, title: String) throws -> AnyView {
        let library = coordinator.demoScenes.personas
        let draft = try library.portraitDraft(imageData: imageData, name: title)
        return AnyView(PersonaImageImportView(library: library, draft: draft))
    }
    public var isDrawing: Bool { coordinator.isDrawing }
    public var drawingIdentity: UUID? { isDrawing ? coordinator.drawingGeneration : nil }
    public enum ShortcutGesture { case press, hold, release }
    /// Only presentation metadata; shortcut execution stays with the coordinator.
    public var penShortcutGesture: ShortcutGesture? { coordinator.penShortcutGesture }
    public var drawingActivationTitle: String { coordinator.settings.value.activation.rawValue }
    public var drawingToolTitle: String { coordinator.tool.title }
    public var isPresenting: Bool { coordinator.demoScenes.isPresenting }
    public var presentationIdentity: UUID? { coordinator.demoScenes.presentationIdentity }
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
    /// The timer's next transport: Start, Pause, Resume or Restart. A finished timer is
    /// `.finished`, never paused, although its session stays started until it is reset.
    public var timerTransport: TimerTransport { coordinator.timerTransport }
    /// The timer's next transport as a control shows it now, tied to its countdown (#174).
    public var timerStep: TimerStep { coordinator.timerStep }
    /// Performs `expected`, a step a control showed, only while it is still the timer's next one
    /// for the same countdown; otherwise nothing. Start and Restart take the normal start path;
    /// Pause and Resume keep the timer's window as it is. A shown Pause or Resume never becomes a
    /// Start or a Restart (#174).
    public func performTimerTransport(expected: TimerStep) { coordinator.performTimerTransport(expected: expected) }
    /// Every current notice with its page, most urgent first. The drawing and settings stores
    /// record their notice's page where it is raised; a persona or scene notice belongs to its own
    /// page. A card that could not show is live, so it comes before an older scene notice.
    private var notices: [StageNotice] {
        let personas = coordinator.demoScenes.personas
        return [coordinator.postedNotice, coordinator.settings.postedNotice,
                personas.cardFeedback.map { StageNotice(text: $0, page: .persona) },
                coordinator.demoScenes.notice.map { StageNotice(text: $0, page: .present) },
                personas.notice.map { StageNotice(text: $0, page: .persona) }].compactMap { $0 }
    }
    /// The notice to show now.
    public var notice: String? { notices.first?.text }
    /// The page that shows `notice` in full, from the same record: a surface with room for one
    /// sentence opens it for the rest (#134).
    public var noticePage: StageNoticePage? { notices.first?.page }
    /// The first notice a page owns, for that page to show in full.
    public func notice(on page: StageNoticePage) -> String? { notices.first { $0.page == page }?.text }

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
    /// Draw starts with the tool Tools shows as chosen. Text and Eraser need a place or ink
    /// first, so a toolbar or panel start uses the Pen for them.
    public func draw() {
        let chosen = coordinator.tool
        coordinator.startDrawing(chosen == .text || chosen == .eraser ? .pen : chosen, latched: true)
    }
    /// Return input without clearing the current ink. A whiteboard closes too, since it would keep
    /// taking clicks; its ink stays with the board for the next time it opens.
    public func finishDrawing() { coordinator.finishDrawing() }
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
            if let message = GlobalShortcutRule.problem(label: shortcut.label, keyCode: keyCode, modifiers: modifiers) { return message }
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
struct PhotoBackdropChooser: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DemoScenes
    private let imageURL: URL?
    private let preparedImage: BackdropImage?
    let title: String
    init(model: DemoScenes, imageURL: URL, title: String) {
        self.model = model; self.imageURL = imageURL; self.preparedImage = nil; self.title = title
    }
    init(model: DemoScenes, image: BackdropImage, title: String) {
        self.model = model; self.imageURL = nil; self.preparedImage = image; self.title = title
    }
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
                        Text(preparedImage == nil ? "Use photo as backdrop" : "Use in Present").font(.title2.weight(.semibold))
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
                            Text(model.scenes.isEmpty && preparedImage != nil
                                 ? "Create your first scene from this image. It will be saved for you to prepare in Present."
                                 : "Choose a saved scene. Review the crop next, then apply when it looks right.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if model.storageBlocked {
                        ContentUnavailableView("Saved scenes need attention", systemImage: "exclamationmark.folder",
                            description: Text("The scene library could not be read. Its original files are preserved. You can still save a separate copy of this photo."))
                    } else if model.scenes.isEmpty && preparedImage != nil {
                        Label("Your image stays unchanged. Creating a scene saves an independent copy.", systemImage: "photo.on.rectangle")
                            .font(.callout).foregroundStyle(.secondary)
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
                        Text(model.scenes.isEmpty && preparedImage != nil
                             ? "Create scene saves your choice. Choose Present when you are ready."
                             : "Only the backdrop changes. Foreground layers and the current presentation stay as they are.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if model.scenes.isEmpty, let preparedImage {
                            Button("Create scene") {
                                guard model.scenes.isEmpty else { notice = "A scene is now available. Choose it before previewing this backdrop."; return }
                                do { try model.addImage(preparedImage, name: title); dismiss() }
                                catch { notice = error.localizedDescription }
                            }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                                .disabled(model.storageBlocked)
                        } else {
                            Button("Preview backdrop") {
                                guard let sceneID else { return }
                                do {
                                    if let preparedImage { draft = try model.makeBackdropReplacement(sceneID: sceneID, image: preparedImage, title: title) }
                                    else if let imageURL { draft = try model.makeBackdropReplacement(sceneID: sceneID, imageURL: imageURL, title: title) }
                                } catch { notice = error.localizedDescription }
                            }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                                .disabled(model.storageBlocked || thumbnail == nil || !model.scenes.contains { $0.id == sceneID })
                                .accessibilityIdentifier("handoff.preview-backdrop")
                        }
                    }
                }.padding(20).frame(width: 840, height: model.scenes.isEmpty && preparedImage != nil ? 320 : 660)
                    .background(Workbench.background).tint(Workbench.accent).workbenchTheme()
            }
        }.onAppear {
            sceneID = model.selected?.id ?? model.scenes.first?.id
            do {
                if let preparedImage { thumbnail = preparedImage.image }
                else if let imageURL { thumbnail = try BackdropImage.thumbnail(imageURL) }
            } catch { notice = "The photo could not be opened. " + error.localizedDescription }
        }.onDisappear { draft?.cancel() }
    }
}

/// Where a StageKit notice is shown in full, or acted on: drawing and boards on Draw, a scene on
/// Present, a card or persona on Persona, recording a shortcut on Settings › Keyboard, and login
/// and saved settings on Settings › General (#134).
public enum StageNoticePage: Sendable, CaseIterable { case draw, present, persona, keyboard, general }

/// A notice and its page, recorded together where the notice is raised (#134).
struct StageNotice: Equatable {
    let text: String
    let page: StageNoticePage
}
