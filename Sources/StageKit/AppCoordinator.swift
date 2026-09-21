import AppKit
import SwiftUI
import Combine
import Carbon
import ServiceManagement

final class AppCoordinator: NSObject, ObservableObject, NSWindowDelegate, NSPopoverDelegate {
    // The unified app owns the application lifetime, status item and navigation.
    let embedded: Bool
    var onOpenControls: (() -> Void)?
    var onOpenScenes: (() -> Void)?
    var onOpenShortcuts: (() -> Void)?
    var onBeginActivity: (() -> Void)?
    var mayBeginInteraction: (() -> Bool)?
    var mayBeginDrawing: (() -> Bool)?
    var onDrawingChanged: ((Bool) -> Void)?
    var validateExternalShortcut: ((UInt32, UInt32) -> String?)?
    private var shortcutsSuspended = false
    let settings: SettingsStore
    let hotkeys = HotkeyManager()
    lazy var demoScenes = DemoScenes(readOnlyReason: migrationFailure)
    private let migrationFailure: String?
    @Published var tool = DrawingTool.pen
    @Published var isDrawing = false
    @Published var pointerEnabled = false
    @Published var boards: [String: BoardStyle] = [:]
    @Published var timerText = "05:00"
    @Published var timerRunning = false
    @Published var timerProgress: Double = 1
    @Published var timerFinished = false
    @Published private(set) var timerPlacementAnchor: FloatingControlAnchor?
    @Published private(set) var timerPlacementNotice: String?
    @Published var shortcutFailures: [Action: String] = [:]
    @Published var recordingAction: Action?
    @Published var selectedTab = "Present"
    @Published var quickTab = QuickTab.draw
    @Published private(set) var quickControlsVisible = false
    @Published private(set) var screenshotHandoffActive = false
    @Published var notice: String?
    @Published var launchAtLogin = false
    var activeDisplayID: String?
    private(set) var panels: [String: OverlayPanel] = [:]
    private(set) var canvases: [String: AnnotationView] = [:]
    private var overlayHistory: [String: CanvasHistory] = [:]
    private var boardHistory: [String: CanvasHistory] = [:]
    private var heldAction: Action?
    private var latched = false
    private var effectTimer: Timer?
    private var countdownTimer: Timer?
    private var lastMouse = NSEvent.mouseLocation
    private var lastMovement = Date.timeIntervalSinceReferenceDate
    private var lastClick: TimeInterval = 0
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var statusItem: NSStatusItem!
    private var quickPopover: NSPopover?
    private var mainWindow: NSWindow?
    private var previousApplication: NSRunningApplication?
    private var palette: NSPanel?
    private var timerWindow: NSPanel?
    private var adjustingTimerFrame = false
    private var timerLiveResizing = false
    private var timerMoveSettlement: Timer?
    private var timerFrameRevision = 0
    private var boardSavePanel: NSSavePanel?
    private var screenshotHandoff = ScreenshotHandoffState()
    var screenshotLauncher: ScreenshotLauncher = SystemScreenshot.launch
    @Published private(set) var boardExportInProgress = false
    private var shuttingDown = false
    private var recorderMonitor: Any?
    private var saveWork: DispatchWorkItem?
    private var registeredShortcuts: [String: Shortcut] = [:]
    private var countdown = Countdown()
    @Published private(set) var timerSessionStarted = false
    private var storageBlocked = false
    private let archiveURL: URL
    private let availableTimerDisplays: () -> [BreakTimerDisplay]
    private let fallbackTimerDisplayID: () -> String?
    private lazy var timerPlacement = BreakTimerPlacementStore(
        url: archiveURL.deletingLastPathComponent().appendingPathComponent("break-timer-placement.json")
    )
    var displayCount: Int { panels.count }
    var hasPersistentMenuItem: Bool { statusItem?.isVisible == true && statusItem?.button != nil }
    var currentScreen: NSScreen { NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.screens.first! }
    var currentID: String { Self.displayID(currentScreen) }
    static func displayID(_ screen: NSScreen) -> String {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() { return CFUUIDCreateString(nil, uuid) as String }
        return String(id)
    }
    init(settings: SettingsStore = SettingsStore(), archiveURL: URL? = nil, embedded: Bool = false,
         migrationFailure: String? = nil, timerDisplays: (() -> [BreakTimerDisplay])? = nil,
         timerFallbackID: (() -> String?)? = nil) {
        self.settings = settings
        self.embedded = embedded
        self.migrationFailure = migrationFailure
        self.storageBlocked = migrationFailure != nil
        self.availableTimerDisplays = timerDisplays ?? {
            NSScreen.screens.map { BreakTimerDisplay(id: AppCoordinator.displayID($0), visibleFrame: $0.visibleFrame) }
        }
        self.fallbackTimerDisplayID = timerFallbackID ?? {
            let screens = NSScreen.screens
            let screen = screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? screens.first
            return screen.map(AppCoordinator.displayID)
        }
        let testRoot = ProcessInfo.processInfo.environment["WORKBENCH_STAGE_DATA_DIR"] ?? ProcessInfo.processInfo.environment["STAGEMARK_DATA_DIR"]
        self.archiveURL = archiveURL ?? testRoot.map { URL(fileURLWithPath: $0).appendingPathComponent("boards.json") }
            ?? Workbench.supportDirectory(component: "StageMark").appendingPathComponent("boards.json")
        super.init()
    }
    func start() {
        shuttingDown = false
        timerPlacementAnchor = timerPlacement.value.position.anchor
        timerPlacementNotice = timerPlacement.notice
        do {
            let archive = try BoardStorage.load(from: archiveURL)
            boardHistory = archive.displays.mapValues(CanvasHistory.init)
        } catch {
            storageBlocked = true
            notice = "Your saved board could not be read. It has been kept safely at \(archiveURL.path). New boards will not replace it."
        }
        hotkeys.onAction = { [weak self] action, down in self?.handleHotkey(action, down: down) }
        hotkeys.onEscape = { [weak self] in self?.escape() }
        settings.onChange = { [weak self] in self?.settingsChanged() }
        if !embedded { createStatusItem() }
        rebuildScreens(); settingsChanged()
        countdown.reset(seconds: settings.value.timerMinutes * 60)
        updateCountdown()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardLayoutChanged), name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in self?.registerClick() }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in self?.registerClick(); return event }
        if !embedded && !settings.value.onboardingComplete { showQuickControls() }
    }
    func shutdown() {
        shuttingDown = true
        timerMoveSettlement?.invalidate(); timerMoveSettlement = nil
        boardSavePanel?.cancel(nil); boardSavePanel = nil
        demoScenes.shutdown()
        hideQuickControls()
        stopDrawing(); saveWork?.cancel(); saveBoards()
        hotkeys.unregister(); effectTimer?.invalidate(); countdownTimer?.invalidate()
        hotkeys.setEscapeEnabled(false)
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let recorderMonitor { NSEvent.removeMonitor(recorderMonitor) }
        panels.values.forEach { $0.orderOut(nil) }
        palette?.orderOut(nil); timerWindow?.orderOut(nil); mainWindow?.orderOut(nil)
        quickPopover?.contentViewController = nil; quickPopover = nil
        palette?.contentView = nil; palette = nil
        timerWindow?.contentView = nil; timerWindow = nil
        mainWindow?.contentView = nil; mainWindow = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    @objc private func screensChanged() {
        rebuildScreens()
        if timerWindow?.isVisible == true { restoreTimerPosition() }
    }
    @objc private func keyboardLayoutChanged() { objectWillChange.send() }
    @objc private func willSleep() { escape(); effectTimer?.invalidate(); effectTimer = nil; saveBoards() }
    @objc private func didWake() { rebuildScreens(); updateCountdown(); refreshEffects() }
    private func rebuildScreens() {
        guard !NSScreen.screens.isEmpty else { return }
        stopDrawing()
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll(); canvases.removeAll(); boards.removeAll(); palette?.orderOut(nil)
        for screen in NSScreen.screens {
            let id = Self.displayID(screen)
            let panel = OverlayPanel(screen: screen)
            let canvas = AnnotationView(frame: CGRect(origin: .zero, size: screen.frame.size), displayID: id, screenFrame: screen.frame)
            canvas.coordinator = self; panel.contentView = canvas
            panels[id] = panel; canvases[id] = canvas
            if overlayHistory[id] == nil { overlayHistory[id] = CanvasHistory() }
            if boardHistory[id] == nil { boardHistory[id] = CanvasHistory() }
        }
        activeDisplayID = currentID
        refreshWindows(); objectWillChange.send()
    }
    func history(for display: String) -> CanvasHistory? {
        boards[display] != nil && settings.value.separateBoards ? boardHistory[display] : overlayHistory[display]
    }
    private var activeHistory: CanvasHistory? { history(for: activeDisplayID ?? currentID) }
    var canBeginDrawing: Bool {
        !boardExportInProgress && !screenshotHandoffActive && !shortcutsSuspended && recordingAction == nil
            && (mayBeginDrawing ?? mayBeginInteraction)?() != false
    }
    /// Menu validation reads the same admission rules as action dispatch. It
    /// also keeps menu clicks out of shortcut practice/recording.
    func canUseAnnotationMenuAction(_ action: Action) -> Bool {
        if action.tool != nil { return canBeginDrawing }
        guard !boardExportInProgress, !screenshotHandoffActive, !shortcutsSuspended, recordingAction == nil else { return false }
        return action == .clear || action == .controls || mayBeginInteraction?() != false
    }
    @discardableResult
    func startDrawing(_ selected: DrawingTool, latched: Bool) -> Bool {
        guard !boardExportInProgress, !screenshotHandoffActive, !shortcutsSuspended, recordingAction == nil else { return false }
        guard (mayBeginDrawing ?? mayBeginInteraction)?() != false else {
            notice = "Finish the current capture or keyboard practice before drawing."
            return false
        }
        let wasDrawing = isDrawing
        onBeginActivity?()
        for canvas in canvases.values { canvas.finishStroke(); canvas.commitText() }
        tool = selected; isDrawing = true; self.latched = latched
        activeDisplayID = currentID
        let leavingControls = mainWindow?.isVisible == true || quickControlsVisible
        hideQuickControls()
        mainWindow?.orderOut(nil)
        if leavingControls { previousApplication?.activate() }
        refreshWindows(); refreshPalette(); refreshEffects(); updateStatus()
        if selected == .text, let canvas = canvases[currentID] {
            canvas.startText(at: canvas.localPoint(NSEvent.mouseLocation))
        }
        if !wasDrawing { onDrawingChanged?(true) }
        return true
    }
    func stopDrawing() {
        let wasDrawing = isDrawing
        for canvas in canvases.values { canvas.finishStroke(); canvas.commitText() }
        isDrawing = false; latched = false; heldAction = nil
        for panel in panels.values { panel.resignKey() }
        NSCursor.arrow.set()
        refreshWindows(); refreshPalette(); refreshEffects(); updateStatus()
        if wasDrawing { onDrawingChanged?(false) }
    }
    func escape() {
        if screenshotHandoffActive { return }
        if boardExportInProgress { boardSavePanel?.cancel(nil); return }
        if recordingAction != nil { finishRecording(); return }
        if quickControlsVisible { hideQuickControls(); return }
        stopDrawing(); boards.removeAll(); palette?.orderOut(nil)
        refreshWindows(); refreshEffects(); updateStatus()
    }
    func handleHotkey(_ action: Action, down: Bool) {
        guard !screenshotHandoffActive else { return }
        if action.isOverlayAction { if down { perform(action) }; return }
        guard recordingAction == nil, !boardExportInProgress else { return }
        if let selected = action.tool {
            if down {
                let toggle = settings.value.activation == .toggle || selected == .text || !boards.isEmpty
                if toggle && isDrawing && tool == selected { stopDrawing() }
                else if startDrawing(selected, latched: toggle) { heldAction = toggle ? nil : action }
            } else if heldAction == action && !latched { stopDrawing() }
        } else if down { perform(action) }
    }
    func perform(_ action: Action) {
        guard !screenshotHandoffActive else { return }
        if action.isOverlayAction {
            switch action {
            case .personaToggle: demoScenes.personas.toggleQuickPersona()
            case .personaNext: demoScenes.personas.stepQuickPersona(1)
            case .personaPrevious: demoScenes.personas.stepQuickPersona(-1)
            case .overlayControls: demoScenes.personas.focusOverlayControls()
            case .overlayNext: demoScenes.personas.performOverlayAction(.stepGroup(1))
            case .overlayPrevious: demoScenes.personas.performOverlayAction(.stepGroup(-1))
            case .overlayVisibility: demoScenes.personas.performOverlayAction(.pauseResume)
            case .overlayEnd: demoScenes.personas.hideOverlay()
            default: break
            }
            return
        }
        guard !boardExportInProgress else { return }
        if let selected = action.tool { startDrawing(selected, latched: true); return }
        if action != .clear && action != .controls && mayBeginInteraction?() == false { return }
        switch action {
        case .clear:
            hideQuickControls()
            for canvas in canvases.values { canvas.finishStroke(); canvas.commitText() }
            if boards.isEmpty { overlayHistory.values.forEach { $0.clear() } }
            else { for id in boards.keys { history(for: id)?.clear() } }
            canvasChanged(); escape()
        case .undo: activeDisplayID = currentID; activeHistory?.undo(); canvasChanged()
        case .redo: activeDisplayID = currentID; activeHistory?.redo(); canvasChanged()
        case .whiteboard: toggleBoard(.white)
        case .blackboard: toggleBoard(.black)
        case .pointer: pointerEnabled.toggle(); refreshWindows(); refreshEffects(); updateStatus()
        case .fade: settings.value.autoFade.toggle()
        case .timer: toggleTimer()
        case .controls: toggleQuickControls()
        case .scenes: showDemoScenes()
        case .color1, .color2, .color3, .color4, .color5, .color6:
            if let number = action.rawValue.last.flatMap({ Int(String($0)) }) { settings.value.color = InkColor.presets[number - 1] }
        default: break
        }
    }
    func clearCanvas() {
        guard !screenshotHandoffActive else { return }
        for canvas in canvases.values { canvas.finishStroke(); canvas.commitText() }
        activeHistory?.clear(); canvasChanged()
    }
    func toggleBoard(_ style: BoardStyle) {
        guard !boardExportInProgress, !screenshotHandoffActive, mayBeginInteraction?() != false else { return }
        hideQuickControls()
        let id = currentID
        for canvas in canvases.values { canvas.finishStroke(); canvas.commitText() }
        if boards[id] == style {
            boards.removeValue(forKey: id); stopDrawing()
        } else {
            boards[id] = style
            if style == .white && settings.value.color == .white { settings.value.color = .black }
            if style == .black && settings.value.color == .black { settings.value.color = .white }
            startDrawing(.pen, latched: true)
        }
        refreshWindows(); refreshPalette(); refreshEffects(); updateStatus()
    }
    func canvasChanged() {
        for (id, canvas) in canvases {
            canvas.needsDisplay = true
            canvas.setAccessibilityValue("\(history(for: id)?.annotations.count ?? 0) annotations")
        }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveBoards() }
        saveWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        refreshEffects()
    }
    private func saveBoards() {
        guard !storageBlocked else { return }
        do { try BoardStorage.save(BoardArchive(displays: boardHistory.mapValues(\.annotations)), to: archiveURL) }
        catch { notice = "Board saving failed: \(error.localizedDescription)" }
    }
    private var exportableBoardID: String? {
        if let activeDisplayID, boards[activeDisplayID] != nil { return activeDisplayID }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
           boards[Self.displayID(screen)] != nil { return Self.displayID(screen) }
        return boards.count == 1 ? boards.keys.first : nil
    }
    var canExportBoard: Bool { exportableBoardID != nil && !boardExportInProgress }
    func boardImageExport() throws -> BoardImageExport {
        guard let id = exportableBoardID, let style = boards[id], let canvas = canvases[id],
              let history = history(for: id) else { throw BoardExportError.noBoard }
        // Capture the committed text/stroke and the selected display before a
        // save panel can change focus, pointer location or canvas state.
        canvas.finishStroke(); canvas.commitText()
        return BoardImageExport(style: style, size: canvas.bounds.size, annotations: history.annotations,
                                scale: panels[id]?.screen?.backingScaleFactor ?? 1)
    }
    func copyBoard() {
        guard !boardExportInProgress else { return }
        do { try boardImageExport().copy(); notice = "Board copied as an image." }
        catch { notice = error.localizedDescription }
    }
    func saveBoardPNG() {
        guard !boardExportInProgress else { return }
        let data: Data
        do { data = try boardImageExport().png() }
        catch { notice = error.localizedDescription; return }
        hideQuickControls()
        boardExportInProgress = true
        refreshWindows(); refreshPalette()
        let panel = NSSavePanel()
        panel.title = "Save board image"; panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Workbench board.png"
        panel.message = "Saves the board background and drawings. Other apps and drawing controls are excluded."
        boardSavePanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] result in
            guard let self else { return }
            boardSavePanel = nil; boardExportInProgress = false
            guard !shuttingDown else { return }
            if result == .OK, let url = panel.url {
                do { try data.write(to: url, options: .atomic); notice = "Saved \(url.lastPathComponent)." }
                catch { notice = "Board image could not be saved: \(error.localizedDescription)" }
            }
            refreshWindows(); refreshPalette(); refreshEffects()
        }
    }
    func openScreenshot() {
        guard !screenshotHandoffActive, !boardExportInProgress, mayBeginInteraction?() != false,
              screenshotHandoff.begin(at: Date.timeIntervalSinceReferenceDate, autoFade: settings.value.autoFade) else { return }
        let wasDrawing = isDrawing
        onBeginActivity?()
        for canvas in canvases.values {
            canvas.finishStroke(); canvas.commitText()
            canvas.pointerVisible = false; canvas.ripples.removeAll(); canvas.laserTrail.removeAll()
            canvas.needsDisplay = true
        }
        screenshotHandoffActive = true
        isDrawing = false; latched = false; heldAction = nil
        for panel in panels.values { panel.resignKey() }
        hideQuickControls(); mainWindow?.orderOut(nil); palette?.orderOut(nil)
        refreshWindows(); refreshPalette(); refreshEffects(); updateStatus()
        if wasDrawing { onDrawingChanged?(false) }
        screenshotLauncher { [weak self] error in
            DispatchQueue.main.async { self?.finishScreenshotHandoff(error: error) }
        }
    }
    private func finishScreenshotHandoff(error: Error?) {
        guard screenshotHandoffActive else { return }
        if let duration = screenshotHandoff.finish(at: Date.timeIntervalSinceReferenceDate) {
            overlayHistory.values.forEach { $0.pauseFade(by: duration) }
        }
        screenshotHandoffActive = false
        notice = error.map { "Screenshot could not open: \($0.localizedDescription)" }
            ?? "Screenshot closed. Your annotations are still available; choose a drawing tool to continue."
        for canvas in canvases.values { canvas.needsDisplay = true }
        refreshWindows(); refreshPalette(); refreshEffects(); updateStatus()
        if error != nil { showControls(tab: "Drawing", preservingCanvas: true) }
    }
    func settingsChanged() {
        if !shortcutsSuspended && recordingAction == nil && registeredShortcuts != settings.value.shortcuts {
            registerShortcuts()
        }
        refreshWindows(); refreshPalette(); refreshEffects()
        for canvas in canvases.values { canvas.needsDisplay = true }
        timerWindow?.alphaValue = settings.value.timerOpacity
        if !timerSessionStarted { countdown.reset(seconds: settings.value.timerMinutes * 60); updateCountdown() }
    }
    private func refreshWindows() {
        if boardExportInProgress {
            panels.values.forEach { $0.orderOut(nil) }
            hotkeys.setEscapeEnabled(false)
            return
        }
        for (id, panel) in panels {
            let intercept = !screenshotHandoffActive && (isDrawing || boards[id] != nil)
            panel.ignoresMouseEvents = !intercept
            panel.invalidateCursorRects(for: canvases[id]!)
            let hasInk = !(history(for: id)?.annotations.isEmpty ?? true)
            if intercept || hasInk || pointerEnabled { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        }
        hotkeys.setEscapeEnabled(!shortcutsSuspended && !screenshotHandoffActive && (isDrawing || !boards.isEmpty))
    }
    private func refreshEffects() {
        let fadeActive = !screenshotHandoffActive && settings.value.autoFade && overlayHistory.values.contains { !$0.annotations.isEmpty }
        let needsTimer = !screenshotHandoffActive && (pointerEnabled || isDrawing || fadeActive || (!boards.isEmpty && settings.value.boardPalette == .autoHide))
        if needsTimer && effectTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tickEffects() }
            timer.tolerance = 0.003; RunLoop.main.add(timer, forMode: .common); effectTimer = timer
        } else if !needsTimer { effectTimer?.invalidate(); effectTimer = nil }
    }
    private func registerClick() {
        guard !screenshotHandoffActive, pointerEnabled && !isDrawing else { return }
        lastClick = Date.timeIntervalSinceReferenceDate
        guard settings.value.clickRipple, let canvas = canvases[currentID] else { return }
        canvas.ripples.append(ClickRipple(location: canvas.localPoint(NSEvent.mouseLocation), began: lastClick))
    }
    private func tickEffects() {
        let now = Date.timeIntervalSinceReferenceDate, mouse = NSEvent.mouseLocation
        let moved = mouse != lastMouse
        if moved { lastMovement = now; lastMouse = mouse }
        let clicking = CGEventSource.buttonState(.combinedSessionState, button: .left) || CGEventSource.buttonState(.combinedSessionState, button: .right)
        let prefs = settings.value
        let visible = prefs.pointerVisibility == .always || (prefs.pointerVisibility == .moving ? now - lastMovement < prefs.idleDelay : clicking || now - lastClick < 0.25)
        var hasFadingInk = false
        for (id, canvas) in canvases {
            let inside = canvas.screenFrame.contains(mouse)
            let show = !screenshotHandoffActive && visible && inside && pointerEnabled && !isDrawing
            let visibilityChanged = canvas.pointerVisible != show
            canvas.pointerVisible = show
            let hadEffects = !canvas.ripples.isEmpty || !canvas.laserTrail.isEmpty
            canvas.ripples.removeAll { now - $0.began >= 0.55 }
            canvas.laserTrail.removeAll { now - $0.1 >= 0.35 }
            if prefs.pointerStyle == .laser && inside && moved && show { canvas.laserTrail.append((canvas.localPoint(mouse), now)) }
            if moved || visibilityChanged || hadEffects { canvas.movePointer(canvas.localPoint(mouse)) }
            if tool == .text && isDrawing && inside { canvas.updateFloatingText() }
            if !screenshotHandoffActive, prefs.autoFade, boards[id] == nil, let history = overlayHistory[id], !history.annotations.isEmpty {
                hasFadingInk = true
                let fading = history.annotations.filter { now - $0.created >= prefs.fadeDelay }
                for annotation in fading { canvas.setNeedsDisplay(annotation.bounds) }
                history.expire(at: now, delay: prefs.fadeDelay)
                if history.annotations.isEmpty && !isDrawing && !pointerEnabled { panels[id]?.orderOut(nil) }
            }
        }
        if let palette, !boards.isEmpty && prefs.boardPalette == .autoHide {
            let frame = palette.frame.insetBy(dx: -60, dy: -40)
            let alpha: CGFloat = frame.contains(mouse) || now - lastMovement < 2.3 ? 1 : 0
            if palette.alphaValue != alpha { palette.alphaValue = alpha; palette.ignoresMouseEvents = alpha == 0 }
        }
        if !hasFadingInk && !pointerEnabled && !isDrawing && boards.isEmpty { refreshEffects() }
    }
    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = NSStatusItem.AutosaveName("StageMark.MenuBar")
        statusItem.behavior = []
        statusItem.isVisible = true
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.setAccessibilityLabel("Workbench")
        updateStatus()
    }
    private func updateStatus() {
        let image = NSImage(systemSymbolName: isDrawing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle", accessibilityDescription: "Workbench")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.imagePosition = .imageLeading
        statusItem?.button?.title = timerRunning || timerFinished ? " " + timerText : ""
        statusItem?.button?.toolTip = "Workbench · \(isDrawing ? tool.title : "Ready") · \(settings.value.shortcut(for: .controls).label)"
    }
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showStatusMenu(); return }
        toggleQuickControls()
    }
    func toggleQuickControls() {
        if quickControlsVisible { hideQuickControls() } else { showQuickControls() }
    }
    func showQuickControls() {
        if embedded { onOpenControls?(); return }
        guard let button = statusItem?.button else { return }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = frontmost
        }
        // Finish a partial stroke before adjusting it, without clearing or exiting the canvas.
        for canvas in canvases.values { canvas.finishStroke(); canvas.commitText() }
        if quickPopover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.delegate = self
            let controller = NSHostingController(rootView: QuickControlsView(app: self, settings: settings))
            controller.title = "Workbench quick controls"
            popover.contentViewController = controller
            popover.contentSize = QuickControlsView.size
            quickPopover = popover
        }
        mainWindow?.orderOut(nil)
        statusItem.isVisible = true
        quickPopover?.appearance = nil
        NSApp.activate(ignoringOtherApps: true)
        quickPopover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        quickControlsVisible = quickPopover?.isShown == true
        quickPopover?.contentViewController?.view.window?.makeKey()
        quickPopover?.contentViewController?.view.window?.makeFirstResponder(nil)
        updateStatus()
    }
    func hideQuickControls() {
        quickPopover?.close()
        quickControlsVisible = false
    }
    func popoverDidClose(_ notification: Notification) {
        quickControlsVisible = false
        finishRecording()
    }
    private func showStatusMenu() {
        hideQuickControls()
        let menu = NSMenu()
        for action in [Action.pen, .arrow, .highlighter, .clear, .pointer, .whiteboard, .blackboard, .timer, .scenes, .controls] {
            let item = NSMenuItem(title: action.title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.representedObject = action.rawValue; item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "All Settings…", action: #selector(openAllSettings), keyEquivalent: ",")
        settingsItem.target = self; menu.addItem(settingsItem)
        let quit = NSMenuItem(title: "Quit Workbench", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
    }
    @objc private func menuAction(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? String, let action = Action(rawValue: value) { perform(action) }
    }
    @objc func quitApp() { NSApp.terminate(nil) }
    @objc private func openAllSettings() { showControls(tab: "Drawing") }
    func showDemoScenes() {
        hideQuickControls(); escape(); mainWindow?.orderOut(nil)
        if embedded { onOpenScenes?(); return }
        demoScenes.show()
    }
    func showControls(tab: String? = nil, preservingCanvas: Bool = false) {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = frontmost
        }
        hideQuickControls()
        if !preservingCanvas { escape() }
        if let tab { selectedTab = tab }
        if embedded {
            if tab == "Shortcuts", let onOpenShortcuts { onOpenShortcuts() }
            else { onOpenControls?() }
            return
        }
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Workbench"; window.titlebarAppearsTransparent = true
            window.minSize = NSSize(width: 850, height: 620); window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ControlCenter(app: self, settings: settings))
            window.center(); window.delegate = self; mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); mainWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === mainWindow { finishRecording() }
    }
    private func refreshPalette() {
        let shouldShow = !boardExportInProgress && isDrawing && (!boards.isEmpty ? settings.value.boardPalette != .hide : settings.value.showDrawingPalette)
        guard shouldShow else { palette?.orderOut(nil); return }
        if palette == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 670, height: 66), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true; panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: DrawingPalette(app: self, settings: settings))
            panel.isMovableByWindowBackground = true; palette = panel
        }
        let frame = currentScreen.visibleFrame
        palette?.setFrameOrigin(NSPoint(x: frame.midX - 335, y: frame.minY + 28))
        palette?.alphaValue = 1; palette?.ignoresMouseEvents = false; palette?.orderFrontRegardless()
    }
    func toggleTimer() {
        guard mayBeginInteraction?() != false else { return }
        hideQuickControls()
        if timerWindow?.isVisible == true { timerWindow?.orderOut(nil); return }
        if !timerSessionStarted { startTimer() } else { showTimer() }
    }
    func startTimer() {
        guard mayBeginInteraction?() != false else { return }
        onBeginActivity?()
        timerSessionStarted = true
        countdown.start(seconds: settings.value.timerMinutes * 60); timerFinished = false
        ensureCountdownTimer(); updateCountdown(); showTimer()
    }
    func pauseResumeTimer() {
        timerSessionStarted = true
        if countdown.isRunning {
            countdown.pause(); countdownTimer?.invalidate(); countdownTimer = nil
        } else {
            countdown.resume(); ensureCountdownTimer()
        }
        updateCountdown()
    }
    func resetTimer() {
        timerSessionStarted = false
        countdown.reset(seconds: settings.value.timerMinutes * 60); timerFinished = false
        countdownTimer?.invalidate(); countdownTimer = nil; updateCountdown()
    }
    func hideTimer() { timerWindow?.orderOut(nil) }
    func setTimerPosition(_ anchor: FloatingControlAnchor) {
        guard let timerWindow, let display = timerDisplay(containing: timerWindow.frame) else { return }
        timerPlacement.setAnchor(anchor, on: display)
        timerPlacementAnchor = timerPlacement.value.position.anchor
        timerPlacementNotice = timerPlacement.notice
        restoreTimerPosition(fallbackID: display.id)
    }
    private func ensureCountdownTimer() {
        guard countdownTimer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.updateCountdown() }
        timer.tolerance = 0.05; RunLoop.main.add(timer, forMode: .common); countdownTimer = timer
    }
    private func updateCountdown() {
        let remaining = countdown.remaining()
        let text = Countdown.formatted(remaining)
        if text != timerText { timerText = text }
        timerRunning = countdown.isRunning
        timerProgress = min(1, remaining / max(1, countdown.duration))
        if countdown.isRunning && remaining <= 0 {
            countdown.pause(); timerRunning = false; timerFinished = true
            countdownTimer?.invalidate(); countdownTimer = nil
            if settings.value.timerChime { NSSound(named: "Glass")?.play() }
        }
        updateStatus()
    }
    private func showTimer() {
        if timerWindow == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 570, height: 330), styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Workbench · Break timer"; panel.titlebarAppearsTransparent = true
            panel.level = .floating; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.minSize = NSSize(width: 360, height: 240); panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = true; panel.delegate = self
            panel.contentView = NSHostingView(rootView: BreakTimerView(app: self, settings: settings)); timerWindow = panel
        }
        restoreTimerPosition()
        timerWindow?.alphaValue = settings.value.timerOpacity; timerWindow?.orderFrontRegardless()
    }
    private func timerDisplay(containing frame: NSRect) -> BreakTimerDisplay? {
        let displays = availableTimerDisplays()
        let overlapping = displays.max { overlap(frame, $0.visibleFrame) < overlap(frame, $1.visibleFrame) }
        if let overlapping, overlap(frame, overlapping.visibleFrame) > 0 { return overlapping }
        let fallbackID = fallbackTimerDisplayID()
        return displays.first(where: { $0.id == fallbackID }) ?? displays.first
    }
    private func overlap(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
    private func restoreTimerPosition(fallbackID: String? = nil) {
        guard let timerWindow else { return }
        guard let destination = timerPlacement.value.destination(
            size: timerWindow.frame.size, displays: availableTimerDisplays(), fallbackID: fallbackID ?? fallbackTimerDisplayID()
        ) else { return }
        timerMoveSettlement?.invalidate(); timerMoveSettlement = nil
        timerFrameRevision += 1
        let revision = timerFrameRevision
        adjustingTimerFrame = true
        timerWindow.setFrame(destination.frame, display: true)
        // AppKit may apply its own screen constraint when the panel is ordered
        // front and deliver that move after setFrame returns. Keep restoration
        // moves out of the persisted user-drag path through the next run-loop turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.timerFrameRevision == revision else { return }
            self.adjustingTimerFrame = false
        }
    }
    private func recordTimerPosition() {
        guard let timerWindow, !adjustingTimerFrame, !timerLiveResizing,
              let display = timerDisplay(containing: timerWindow.frame) else { return }
        timerPlacement.move(to: timerWindow.frame, on: display)
        timerPlacementAnchor = timerPlacement.value.position.anchor
        timerPlacementNotice = timerPlacement.notice
    }
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === timerWindow else { return }
        guard !adjustingTimerFrame, !timerLiveResizing, timerMoveSettlement == nil else { return }
        // didMove also arrives during a drag. Wait for release before persisting
        // and snapping, so the panel does not fight the user's pointer.
        let settlement = Timer(timeInterval: 0.03, repeats: true) { [weak self] timer in
            guard let self, !self.shuttingDown else { timer.invalidate(); return }
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate(); self.timerMoveSettlement = nil
            guard !self.adjustingTimerFrame, !self.timerLiveResizing else { return }
            self.recordTimerPosition()
            self.restoreTimerPosition()
        }
        timerMoveSettlement = settlement
        RunLoop.main.add(settlement, forMode: .common)
    }
    func windowWillStartLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === timerWindow else { return }
        timerLiveResizing = true
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === timerWindow else { return }
        timerLiveResizing = false
        if timerPlacement.value.position.anchor == nil { recordTimerPosition() }
        restoreTimerPosition(fallbackID: timerDisplay(containing: window.frame)?.id)
    }
    func beginRecording(_ action: Action) {
        if embedded, let onOpenShortcuts { onOpenShortcuts(); return }
        finishRecording()
        if quickControlsVisible { stopDrawing() } else { escape() }
        recordingAction = action; hotkeys.unregister()
        recorderMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.finishRecording(); return nil }
            if event.keyCode == 51 { var shortcut = self.settings.value.shortcut(for: action); shortcut.enabled = false; self.settings.value.shortcuts[action.rawValue] = shortcut; self.finishRecording(); return nil }
            let shortcut = Shortcut(event: event)
            guard shortcut.modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else {
                self.notice = "Include Control, Option or Command with your shortcut."; return nil
            }
            if let conflict = Action.allCases.first(where: { $0 != action && self.settings.value.shortcut(for: $0) == shortcut }) {
                self.notice = "That shortcut belongs to \(conflict.title). Choose another combination."; return nil
            }
            if let message = self.validateExternalShortcut?(shortcut.keyCode, shortcut.modifiers) {
                self.notice = message; return nil
            }
            self.settings.value.shortcuts[action.rawValue] = shortcut
            self.notice = nil; self.finishRecording(); return nil
        }
    }
    func finishRecording() {
        guard recordingAction != nil else { return }
        if let recorderMonitor { NSEvent.removeMonitor(recorderMonitor); self.recorderMonitor = nil }
        recordingAction = nil
        if !shortcutsSuspended { registerShortcuts() }
    }
    func restoreShortcuts() {
        finishRecording()
        settings.value.shortcuts = Dictionary(uniqueKeysWithValues: Action.allCases.map { ($0.rawValue, $0.defaultShortcut) })
    }
    func setShortcutsSuspended(_ suspended: Bool) {
        guard shortcutsSuspended != suspended else { return }
        shortcutsSuspended = suspended
        if suspended {
            finishRecording(); stopDrawing(); hotkeys.unregister(); hotkeys.setEscapeEnabled(false)
        } else { registerShortcuts(); refreshWindows() }
    }
    private func registerShortcuts() {
        // Re-registration discards the pressed-key record. Finish only a held
        // drawing session before its key-up can be lost; latched tools stay on.
        if heldAction != nil && !latched { stopDrawing() }
        var preferences = settings.value
        var conflicts: [Action: String] = [:]
        for action in Action.allCases {
            var shortcut = preferences.shortcut(for: action)
            if shortcut.enabled, let message = validateExternalShortcut?(shortcut.keyCode, shortcut.modifiers) {
                conflicts[action] = message
                shortcut.enabled = false
                preferences.shortcuts[action.rawValue] = shortcut
            }
        }
        hotkeys.register(preferences)
        registeredShortcuts = settings.value.shortcuts
        shortcutFailures = hotkeys.failures.merging(conflicts) { _, conflict in conflict }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { notice = "Approve Workbench in System Settings → General → Login Items."; SMAppService.openSystemSettingsLoginItems() }
        } catch { notice = "Login setting could not be changed: \(error.localizedDescription)" }
    }
    func openZoomSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?Zoom")!)
    }
}
