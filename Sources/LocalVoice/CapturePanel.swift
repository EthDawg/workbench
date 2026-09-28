import AppKit
import AVFoundation
import Combine
import StageKit
import SwiftUI
import ToolbarCore
import ToolbarKit

/// Mouse controls preserve the original application's focus and paste target.
final class CapturePanel: NSPanel {
    var allowsKeyboardFocus = false
    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override var canBecomeMain: Bool { false }
    /// Escape that nothing inside handled leaves keyboard interaction, whatever the toolbar shows,
    /// the launcher row or a result's own controls (#211 F1).
    var escape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) {
        if let escape { escape() } else { super.cancelOperation(sender) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let escape { escape() } else { super.keyDown(with: event) }
    }
}

final class CaptureHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class CaptureHUDControls: ObservableObject {
    let toolbar: ToolbarSession
    @Published var toolbarSize = ToolbarLayout.mark
    private var measuredRowSize = NSSize(width: ToolbarLayout.standardWidth, height: ToolbarLayout.rowHeight)
    /// The compact rest, the same 48 × 28 in every state (#134); measured once it has drawn.
    private(set) var restingSize = ToolbarLayout.mark
    private var restingMeasured = false
    private var rowMeasured = false
    private var observation: AnyCancellable?
    var releaseKeyboardFocus: (() -> Void)?
    var promptDestination: (() -> TextDelivery.Target?)?
    var cancelDrag: (() -> Void)?
    var focusFirstControl: (() -> Void)?
    var dragActions = ToolbarDragActions()
    var menuDidClose: (() -> Void)?
    var preferredToolbarSize: NSSize { toolbar.state.tier == .resting ? restingSize : measuredRowSize }
    var restingWidth: CGFloat { restingSize.width }
    /// Whether the row has reported its size for `tier`. Until it has, the seed size above is what
    /// the window gets, which is how a host can sit under a row that draws wider than it.
    func hasMeasured(_ tier: ToolbarTier) -> Bool { tier == .resting ? restingMeasured : rowMeasured }

    init(defaults: UserDefaults = .standard) {
        toolbar = ToolbarSession(defaults: defaults)
        observation = toolbar.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        toolbar.show = { [weak self] tier in self?.tierWillShow(tier); self?.resize?() }
        toolbar.releaseHolds = { [weak self] in self?.cancelDrag?(); self?.releaseKeyboardFocus?() }
    }
    func reportSize(_ size: NSSize, tier: ToolbarTier) {
        guard tier == toolbar.state.tier, size.width > 0, size.height > 0 else { return }
        let size = NSSize(width: ceil(size.width), height: ceil(size.height))
        let previous = preferredToolbarSize
        if tier == .resting { restingSize = size; restingMeasured = true }
        else { measuredRowSize = size; rowMeasured = true }
        if previous != preferredToolbarSize { resize?() }
    }
    /// The revealed row's last measured size, for deciding whether its accessory fits.
    var rowSize: NSSize { measuredRowSize }
    func focusToolbar() { toolbar.send(.holdBegan(.keyboard)) }
    func unfocusToolbar() { toolbar.send(.holdEnded(.keyboard)) }
    func endKeyboardInteraction() { unfocusToolbar(); releaseKeyboardFocus?() }
    func beginMenu(_ menu: NSMenu) -> Bool { menuWillBegin?(); return toolbar.beginMenu(menu) }
    func endMenu() { menuDidClose?() }
    /// A toolbar menu is about to track: Position…, if open, gives way to it.
    var menuWillBegin: (() -> Void)?
    func setDragging(_ value: Bool) { toolbar.send(value ? .holdBegan(.drag) : .holdEnded(.drag)) }
    func suspendToolbar() { toolbar.suspend() }

    // MARK: Results (#134 T4)

    /// The open row shows a result's own controls instead of the launcher row. It is decided as
    /// the row opens, and only for the pointer's own reveal, a dwell or a click on the mark: a
    /// failure or receipt that arrives while the row is open never replaces it under the pointer,
    /// and waits as the mark's status until the person reveals it. Keyboard entry keeps the
    /// launcher row, with the result's own commands first in More (#211 F1), and a row that Keep
    /// open brings back waits for the checks the kept-open swap makes (#211 F8).
    @Published private(set) var revealsResult = false
    /// A result is waiting for the person; the host answers from its owners.
    var resultPending: () -> Bool = { false }
    private func tierWillShow(_ tier: ToolbarTier) {
        let state = toolbar.state
        let reveals = tier == .revealed && state.pointerInside && !state.holds.contains(.keyboard) && resultPending()
        if revealsResult != reveals { revealsResult = reveals }
    }
    /// The result was resolved, dismissed or expired: the open row goes back to the launcher row.
    func resultEnded() { if revealsResult { revealsResult = false } }
    /// The tools came back, after a capture, Hide toolbar or a cue, and the host has not yet found
    /// the pointer: a kept-open row keeps its launcher until it has (#211 F8). The host's own
    /// update runs again from inside the return, before it has looked.
    private(set) var awaitingPointer = false
    /// Brings the tools back. A kept-open row reveals at once; a waiting result waits for the pointer.
    func activateToolbar() {
        if !toolbar.isActive { awaitingPointer = true }
        toolbar.activate()
    }
    /// The host has found the pointer again since the tools came back.
    func pointerSettled() { awaitingPointer = false }
    /// Where each action of a shown result is, by name, in its window's content with the origin
    /// at the top left: the gallery checks that none sits over the mark at a right-hand dock
    /// (#211 F3). SwiftUI keeps no accessibility tree to read while no assistive app asks for one.
    var resultActionFrames: [String: CGRect] = [:]
    /// A row kept open by Keep open alone shows a new result in its place, as the dictation
    /// panel did: Keep open is the person's choice of persistent controls, and there is no rest to
    /// show the status on. Only while no pointer is on it and nothing holds it, a menu, the chooser
    /// or the keyboard included; the host also waits for Position… to close, and for the pointer
    /// to be found again when the row comes back. It never activates Workbench, takes the keyboard
    /// or moves the anchor: the host sizes the window from the same centre.
    func showResultIfKeptOpen() {
        let state = toolbar.state
        guard !revealsResult, !awaitingPointer, toolbar.isActive, state.tier == .revealed, state.keepsOpen, !state.pointerInside,
              state.holds.isEmpty, resultPending() else { return }
        revealsResult = true
    }

    @Published var anchor: FloatingControlAnchor? = .bottom
    /// The anchor the row is drawn for: its dock, or the side a free row grows from (#163).
    @Published var rowAnchor: ToolbarAnchor = .bottom
    var resize: (() -> Void)?
    var choosePosition: ((FloatingControlAnchor) -> Void)?
    /// Opens Position…, the toolbar's compact placement control.
    var showPosition: (() -> Void)?

    // MARK: Compact controls (#134)

    /// The next action's presses: each latched on what the button showed, acting only if it holds.
    let pressGate = ToolbarPressGate()
    /// Opens the tool chooser from the launcher.
    var openChooser: ((NSView, [ToolbarToolChoice]) -> Void)?
    /// The chooser's rows changed while it may be open.
    var chooserChoicesChanged: (([ToolbarToolChoice]) -> Void)?
    /// A click on the compact rest: reveal and take the keyboard, never work.
    var revealFromRest: (() -> Void)?
    /// The Snap & Talk session whose sequence was started in this launch. A session restored
    /// at launch is idle until it is used; closing or switching sessions ends the sequence.
    @Published var snapAndTalkSequence: URL?
    /// The accessory fits the row on this display; when it does not, it waits in More.
    @Published var accessoryFits = true

    /// What the compact rest shows now, as the row last rendered it.
    private(set) var status = ToolbarStatus.idle
    /// VoiceOver hears each meaningful change of the compact status once: a new indicator
    /// or badge, never a level, and never any transcript or result content.
    func statusChanged(from previous: ToolbarStatus, to status: ToolbarStatus) {
        self.status = status
        guard status.announces(after: previous) else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: status.description, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

@MainActor
final class CapturePanelController: NSWindowController, NSWindowDelegate, FloatingHUDDragController {
    var independentScreenCapture: () -> Bool = { false }
    private let positionKey = "capturePanelOrigin.v1"
    private let anchorKey = "capturePanelAnchor.v2"
    private let sizeKey = "capturePanelSize.v1"
    /// A free position with its side, decided when it was released (#163), as a glyph edge.
    /// Still written for the build before #134, which reads it; read here only to migrate.
    private let freeKey = "capturePanelFreePosition.v1"
    /// A free position as the launcher's centre and side (#134): the compact mark's centre,
    /// and the revealed launcher's. It records the glyph-edge copy written beside it, so a
    /// later move by an earlier build is noticed and migrated rather than overwritten.
    private let launcherKey = "capturePanelLauncher.v1"
    private let controls: CaptureHUDControls
    private weak var model: AppModel?
    private weak var readback: ReadbackModel?
    private weak var stage: StageKitController?
    private var positioning = false
    private var dragging = false
    private let snapGuide = FloatingControlGuideController()
    private var observations = Set<AnyCancellable>()
    private var surface: FloatingToolbarSurface = .hidden
    private var keyboardTarget: TextDelivery.Target?
    private var tracking: ToolbarTrackingView?
    private let motion = ToolbarWindowMotion()
    private var measuringToolbar = false
    /// Position… is open for the Dictate page's Position floating toolbar….
    private var previewShowsPosition = false
    /// Where the tools rest while they are not docked (#163); nil while they are docked at
    /// `controls.anchor`. Only a person's placement changes it: a frame recovered onto
    /// another display, or a dictation panel dragged to a dock, is shown but never saved over it.
    private var freePosition: ToolbarFreePosition?
    private let positionControl = ToolbarPositionPanel()
    private let chooser = ToolbarChooserPanel()
    /// The one-time coaching card, above the toolbar's place (#134 T5).
    let coachPanel = ToolbarCoachPanel()
    var isAnimatingToolbar: Bool { motion.target != nil }
    /// The gallery reads where the chooser opened and opens it invisibly (#134).
    var chooserFrame: NSRect? { chooser.shownFrame }
    var chooserOffscreenForChecks: Bool {
        get { chooser.offscreenForChecks }
        set { chooser.offscreenForChecks = newValue }
    }
    /// Where the tools rest: a named dock, or a free position with its side.
    var toolsPosition: ToolbarPosition {
        if controls.anchor == nil, let freePosition { return .free(freePosition) }
        return .docked((controls.anchor ?? .bottom).toolbarAnchor)
    }

    init(model: AppModel, readback: ReadbackModel, stage: StageKitController, snapModel: SnapModel,
         dictate: @escaping () -> Void, snap: @escaping () -> Void,
         snapCapture: @escaping () -> Void = {},
         draw: @escaping () -> Void, present: @escaping () -> Void,
         controls suppliedControls: CaptureHUDControls? = nil) {
        let controls = suppliedControls ?? CaptureHUDControls()
        self.controls = controls
        let panel = CapturePanel(contentRect: NSRect(origin: .zero, size: CaptureHUDLayout.message),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(window: panel)
        self.model = model
        self.readback = readback; self.stage = stage
        let saved = Self.savedPosition(UserDefaults.standard, screens: NSScreen.screens.map(\.visibleFrame),
                                       preferred: NSScreen.main?.visibleFrame)
        switch saved.position {
        case .docked(let anchor): controls.anchor = FloatingControlAnchor(rawValue: anchor.rawValue) ?? .bottom
        case .free(let free): controls.anchor = nil; freePosition = free
        }
        // A position read from an earlier build's keys is saved in this build's terms at once.
        if saved.migrated, case .free(let free) = saved.position {
            UserDefaults.standard.set(Self.launcherRecord(free), forKey: launcherKey)
            UserDefaults.standard.set(Self.record(free), forKey: freeKey)
        }
        controls.rowAnchor = ToolbarGeometry.rowAnchor(toolsPosition)
        controls.toolbarSize = controls.preferredToolbarSize
        controls.resize = { [weak self, weak model] in if let model { self?.update(model: model) } }
        controls.choosePosition = { [weak self] in self?.choosePosition($0) }
        controls.showPosition = { [weak self] in self?.showPositionControl() }
        controls.menuWillBegin = { [weak self] in self?.positionControl.close(); self?.chooser.close() }
        controls.openChooser = { [weak self] launcher, choices in self?.openChooser(from: launcher, choices: choices) }
        controls.chooserChoicesChanged = { [weak self] choices in self?.chooser.refresh(choices) }
        controls.revealFromRest = { [weak self] in self?.revealFromRest() }
        controls.releaseKeyboardFocus = { [weak self] in self?.releaseKeyboardFocus() }
        panel.escape = { [weak controls] in controls?.endKeyboardInteraction() }
        controls.resultPending = { [weak model] in model.map { FloatingResult.pending($0) != nil } ?? false }
        controls.promptDestination = { [weak self] in
            guard let self else { return nil }
            return self.window?.isKeyWindow == true ? self.keyboardTarget : TextDelivery.capture()
        }
        controls.dragActions = ToolbarDragActions(begin: { [weak self] in self?.beginDragging() },
            move: { [weak self] in self?.previewDragging() }, end: { [weak self] in self?.finishDragging() },
            cancel: { [weak self] in self?.cancelDragging() }, isCancelled: { [weak self] in self?.dragging != true })
        controls.cancelDrag = { [weak self] in self?.cancelDragging() }
        controls.menuDidClose = { [weak self] in
            guard let self else { return }
            self.tracking?.settle()
            self.controls.toolbar.endMenu(pointerInside: self.tracking?.pointerInside == true)
        }
        panel.title = "Workbench floating toolbar"
        panel.isFloatingPanel = true
        // Stay above the annotation canvas so drawing cannot intercept live controls.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = CaptureHostingView(rootView: WorkbenchFloatingContent(model: model, readback: readback,
            stage: stage, controls: controls, snapModel: snapModel, dictate: dictate, snap: snap, snapCapture: snapCapture, draw: draw, present: present))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        let tracking = ToolbarTrackingView(content: hosting)
        tracking.autoresizingMask = [.width, .height]
        tracking.event = { [weak controls] in controls?.toolbar.send($0) }
        // A pass-through never springs the row: entry is debounced while the
        // window shows only the compact rest.
        tracking.isRestingSized = { [weak self, weak controls] in
            guard let self, let controls, let window = self.window else { return false }
            return window.frame.width <= controls.restingWidth + 0.5
        }
        self.tracking = tracking
        panel.contentView = tracking
        motion.settled = { [weak self] in
            guard let self else { return }
            self.positioning = false
            self.savePosition()
            self.tracking?.acceptsCrossings = self.surface == .tools && !self.dragging
            if self.surface == .tools { self.tracking?.settle() }
            self.updateCoach()
        }
        panel.delegate = self
        panel.acceptsMouseMovedEvents = true
        // Published emits before assignment; read committed state on the next loop.
        model.clipboardReceipt.$isHUDVisible.combineLatest(model.clipboardReceipt.$receipt)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak model] _ in if let model { self?.update(model: model) } }
            .store(in: &observations)
        model.$floatingToolbarVisible.receive(on: RunLoop.main)
            .sink { [weak self, weak model] _ in if let model { self?.update(model: model) } }
            .store(in: &observations)
        stage.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self, weak model] _ in if let model { self?.update(model: model) } }
            .store(in: &observations)
        model.$rendering.combineLatest(model.$playing, model.$paused)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak model] _ in if let model { self?.update(model: model) } }
            .store(in: &observations)
        model.$phase.combineLatest(model.$captureFailure, model.$previewingPanel)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak model] _ in if let model { self?.update(model: model) } }
            .store(in: &observations)
        // A routine cue and a stopped reading keep their surfaces until they go.
        model.$captureCue.combineLatest(model.$readingFailure)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak model] _ in if let model { self?.update(model: model) } }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.cancelDragging(); self?.chooser.close(); self?.controls.unfocusToolbar() }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.cancelDragging(); self?.chooser.close(); self?.position() }
            .store(in: &observations)
        // A result waiting on a kept-open row shows once its pointer, holds and popovers let go.
        controls.toolbar.$state.receive(on: RunLoop.main)
            .sink { [weak self, weak model] _ in
                guard let self, let model, !self.controls.revealsResult, FloatingResult.pending(model) != nil else { return }
                self.update(model: model)
            }
            .store(in: &observations)
        // The coaching card (#134 T5): this host says when one may show, shows a pending one above
        // its place and reports it presented, and takes it down when it goes. A narration
        // starting takes it down too; a new dictation already does, through its owner.
        model.coach.canPresent = { [weak self] in self?.coachMayShow ?? false }
        model.coach.$card.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateCoach() }
            .store(in: &observations)
        readback.$isRecording.removeDuplicates().filter { $0 }.receive(on: RunLoop.main)
            .sink { [weak model] _ in model?.coach.remove() }
            .store(in: &observations)
        // A Snap & Talk sequence is attention only once it is used in this launch: a capture or
        // narration marks its session, and closing or switching sessions ends it (#134).
        readback.$isCapturing.combineLatest(readback.$isRecording, readback.$sessionURL)
            .receive(on: RunLoop.main)
            .sink { [weak controls] capturing, recording, session in
                guard let controls else { return }
                if capturing || recording { controls.snapAndTalkSequence = session }
                else if controls.snapAndTalkSequence?.standardizedFileURL != session?.standardizedFileURL { controls.snapAndTalkSequence = nil }
            }
            .store(in: &observations)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(model: AppModel) {
        // A size report delivered while the row is being measured below is read
        // by that same call once the measurement returns.
        guard let window, !measuringToolbar else { return }
        let previousSurface = self.surface
        let narrating = readback?.isRecording == true
        let capturingScreen = readback?.isCapturing == true || stage?.isTakingScreenshot == true || independentScreenCapture()
        // A screen capture must not include the coaching card either (#134 T5).
        if capturingScreen { model.coach.remove() }
        let surface = FloatingToolbarSurface.resolve(shown: model.floatingToolbarVisible, drawing: stage?.isDrawing == true,
            presenting: stage?.isPresenting == true, persona: stage?.hasActivePersona == true, inserting: model.promptInsertion.running,
            capturingScreen: capturingScreen,
            dictation: Self.showsDictation(model), narration: narrating,
            reading: model.rendering || model.playing || model.paused || model.readingFailure != nil,
            cue: Self.showsCue(model) && !narrating)
        if surface != self.surface {
            self.surface = surface
            tracking?.acceptsCrossings = false
            motion.finish(window)
            if surface == .tools { controls.activateToolbar() }
            else { chooser.close(); controls.suspendToolbar(); releaseKeyboardFocus(); positionControl.close() }
        }
        // A result that went leaves the open row; a new one waits as the mark's status (#134 T4).
        if FloatingResult.pending(model) == nil { controls.resultEnded() }
        guard surface != .hidden else {
            window.orderOut(nil); cancelDragging(); updateCoach()
            return
        }
        if surface == .tools { measureToolbar() }
        let size = surface == .tools ? controls.preferredToolbarSize : CaptureHUDLayout.compact
        // The frame follows the content's size around the launcher's fixed centre, at a dock or a
        // free position alike, for the tools, recording, results and the cue. A drag keeps its
        // window until release, which places it.
        let moved = !dragging && toolbarFrame(size: size).map({ Self.differs($0, motion.target ?? window.frame) }) == true
        if !window.isVisible { place(size: size, restoreSaved: true) }
        else if moved {
            place(size: size, restoreSaved: false, animated: surface == .tools && previousSurface == .tools && !dragging)
        }
        window.orderFrontRegardless()
        tracking?.acceptsCrossings = surface == .tools && !dragging && motion.target == nil
        if previousSurface != surface && surface == .tools { tracking?.settle(); controls.pointerSettled() }
        // In a row kept open by Keep open alone, a waiting result takes the row's place once nothing
        // is using it: after the pointer is found again above, so a row that comes back under the
        // pointer keeps its launcher until the pointer leaves (#211 F8).
        if FloatingResult.pending(model) != nil, !chooser.isShown, !positionControl.isShown { controls.showResultIfKeptOpen() }
        showPositionForPreview(model)
        updateCoach()
    }

    /// Whether a coaching card may show now: the toolbar is on screen, and the card would cover
    /// neither permission UI, Workbench's own window in front, another of the toolbar's popovers,
    /// nor a result's controls open in its place. A capture hides the toolbar, so none shows then.
    private var coachMayShow: Bool {
        guard let model, let window, window.isVisible, surface != .hidden else { return false }
        if model.phase == .requesting || chooser.isShown || positionControl.isShown { return false }
        if controls.revealsResult && controls.toolbar.state.tier == .revealed { return false }
        if NSApp.isActive, let key = NSApp.keyWindow, key !== window { return false }
        return true
    }

    /// Shows a pending card above the toolbar's place, follows the toolbar if it moves, drops a
    /// card that cannot show now without spending its lesson, and takes a gone card down.
    private func updateCoach() {
        guard let model else { coachPanel.hide(); return }
        let coach = model.coach
        guard let card = coach.card else { coachPanel.hide(); return }
        guard let window, window.isVisible, surface != .hidden, coach.isPresented || coachMayShow else {
            if coach.isPresented { coach.remove() } else { coach.drop(card.id) }
            coachPanel.hide()
            return
        }
        let host = motion.target ?? window.frame
        let launcher = ToolbarGeometry.launcherCentre(inWindow: host, growsLeftward: controls.rowAnchor.growsLeftward)
        if !coachPanel.show(coach, host: host, launcherX: launcher.x, level: window.level), !coach.isPresented {
            coach.drop(card.id)
        }
    }

    /// Position floating toolbar… on the Dictate page opens Position… at the toolbar, which is
    /// where dictation shows now (#134 T4); closing it ends the preview.
    private func showPositionForPreview(_ model: AppModel) {
        guard model.previewingPanel else { previewShowsPosition = false; return }
        guard !previewShowsPosition, surface == .tools else { return }
        previewShowsPosition = true
        DispatchQueue.main.async { [weak self, weak model] in
            self?.showPositionControl(onClose: { model?.closePanelPreview() })
        }
    }

    /// A routine no-speech cue, unless a failure or a new capture has since taken the surface.
    static func showsCue(_ model: AppModel) -> Bool { model.captureCue != nil && model.captureFailure == nil && model.phase == .idle }

    static func showsDictation(_ model: AppModel) -> Bool {
        model.previewingPanel || model.phase != .idle || model.captureFailure != nil || model.captureCue != nil ||
            (model.clipboardReceipt.isHUDVisible && model.clipboardReceipt.receipt != nil)
    }

    func focusToolbar() {
        guard let model, let panel = window as? CapturePanel else { return }
        let target = panel.allowsKeyboardFocus && panel.isKeyWindow ? keyboardTarget : TextDelivery.capture()
        model.floatingToolbarVisible = true
        update(model: model)
        guard surface == .tools else { return }
        keyboardTarget = target
        controls.focusToolbar()
        panel.allowsKeyboardFocus = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, panel?.allowsKeyboardFocus == true, self.surface == .tools else { return }
            self.controls.focusFirstControl?()
        }
    }

    /// A click on the compact rest (#134): it reveals the row and gives the launcher the
    /// keyboard, and nothing else. The field in front is kept first, as the target a later
    /// action from the toolbar will use, and Workbench is not made the active app.
    func revealFromRest() {
        guard surface == .tools, let panel = window as? CapturePanel else { return }
        // The click is the pointer's: it reveals as a dwell would, a waiting result's own controls
        // included (#211 F1), and only then takes the keyboard. A panel that cannot take it holds
        // nothing, so no keyboard hold is left that nothing can release.
        controls.toolbar.send(.pointerEntered)
        let target = panel.allowsKeyboardFocus && panel.isKeyWindow ? keyboardTarget : TextDelivery.capture()
        takeKeyboard(panel, target: target)
    }

    /// Gives the toolbar the keyboard, with `target` as the field it came from, and focuses the
    /// launcher. False, with nothing held, if the panel could not become key.
    @discardableResult
    private func takeKeyboard(_ panel: CapturePanel, target: TextDelivery.Target?) -> Bool {
        keyboardTarget = target
        panel.allowsKeyboardFocus = true
        panel.makeKeyAndOrderFront(nil)
        guard panel.isKeyWindow else { panel.allowsKeyboardFocus = false; keyboardTarget = nil; return false }
        controls.focusToolbar()
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, panel?.allowsKeyboardFocus == true, self.surface == .tools else { return }
            self.controls.focusFirstControl?()
        }
        return true
    }

    func targetForDictation() -> TextDelivery.Target? {
        let target = window?.isKeyWindow == true ? keyboardTarget : TextDelivery.capture()
        releaseKeyboardFocus()
        return target
    }

    /// Leaves keyboard interaction. The field the toolbar was focused from gets the keyboard
    /// back only while the toolbar still owns it and that app is still running; otherwise the
    /// keyboard stays wherever the person has since put it (#134).
    private func releaseKeyboardFocus() {
        guard let panel = window as? CapturePanel, panel.allowsKeyboardFocus else { return }
        let target = keyboardTarget, ownedKey = panel.isKeyWindow
        panel.allowsKeyboardFocus = false
        panel.resignKey()
        if ownedKey, let app = target?.app, !app.isTerminated { app.activate(options: []) }
        keyboardTarget = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        (window as? CapturePanel)?.allowsKeyboardFocus = false
        keyboardTarget = nil; controls.unfocusToolbar()
    }

    func position(reset: Bool = false) {
        if reset { choosePosition(.bottom); return }
        guard let window else { return }
        place(size: motion.target?.size ?? window.frame.size, restoreSaved: !window.isVisible)
    }

    private var preferredScreen: NSRect? {
        (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame
    }

    private func place(size: NSSize, restoreSaved: Bool, animated: Bool = false) {
        guard let window, let preferred = preferredScreen else { return }
        let saved = UserDefaults.standard.string(forKey: positionKey).map(NSPointFromString)
        let savedSize = UserDefaults.standard.string(forKey: sizeKey).map(NSSizeFromString) ?? size
        let previous = restoreSaved ? saved.map { NSRect(origin: $0, size: savedSize) } : window.frame
        if surface == .tools { placeTools(previous: previous, preferred: preferred, animated: animated); return }
        // The cue shows at the toolbar's own place, growing inward from the launcher's centre.
        setFrame(toolbarFrame(size: size, screen: toolsScreen(previous: previous, preferred: preferred)))
    }

    /// Puts the tools where they rest: the row is drawn for the side it grows from and
    /// measured, then the window goes around it, its launcher on the launcher's centre
    /// (#152, #163, #134). The accessory waits in More when the row with it would not fit.
    private func placeTools(previous: NSRect?, preferred: NSRect, animated: Bool) {
        let screen = toolsScreen(previous: previous, preferred: preferred)
        let rowAnchor = ToolbarGeometry.rowAnchor(toolsPosition)
        var remeasure = false
        if controls.rowAnchor != rowAnchor { controls.rowAnchor = rowAnchor; remeasure = true }
        let fits = accessoryFits(on: screen)
        if controls.accessoryFits != fits { controls.accessoryFits = fits; remeasure = true }
        if remeasure { measureToolbar() }
        setFrame(toolbarFrame(size: controls.preferredToolbarSize, screen: screen), animated: animated)
    }

    /// The row with its accessory, measured when it showed one and otherwise its measured width
    /// plus the accessory's, fits the display less its margin.
    private func accessoryFits(on screen: NSRect) -> Bool {
        let row = controls.rowSize.width + (controls.accessoryFits ? 0 : ToolbarLayout.accessoryWidth + ToolbarLayout.gap)
        return row <= screen.width - ToolbarLayout.accessoryScreenMargin
    }

    /// The display the tools belong on: a free position's own display, which is the preferred
    /// one after its display was removed, or the one the docked window covers most.
    private func toolsScreen(previous: NSRect?, preferred: NSRect) -> NSRect {
        let screens = NSScreen.screens.map(\.visibleFrame)
        if case .free(let free) = toolsPosition {
            return FloatingControlPlacement.screen(for: ToolbarGeometry.slot(around: free.centre), screens: screens, preferred: preferred)
        }
        return CaptureHUDGeometry.screen(for: previous ?? NSRect(origin: preferred.origin, size: controls.restingSize),
            screens: screens, preferred: preferred)
    }

    private func toolbarFrame(size: NSSize, screen: NSRect) -> NSRect {
        ToolbarGeometry.frame(size: size, position: toolsPosition, screen: screen)
    }

    /// Where `place` puts the tools at `size`: at their dock or their free position, never
    /// pulled from a free position back to a dock.
    private func toolbarFrame(size: NSSize) -> NSRect? {
        guard let window, let preferred = preferredScreen else { return nil }
        return toolbarFrame(size: size, screen: toolsScreen(previous: motion.target ?? window.frame, preferred: preferred))
    }

    private static func differs(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) > 0.5 || abs(a.minY - b.minY) > 0.5 || abs(a.width - b.width) > 0.5 || abs(a.height - b.height) > 0.5
    }

    /// Brings the row's size reports up to date before the tools are placed. SwiftUI
    /// lays the row out now, for the tier and labels about to show, so the window is
    /// sized around the row as it will draw rather than the last one it reported.
    private func measureToolbar() {
        measuringToolbar = true
        defer { measuringToolbar = false }
        tracking?.layoutSubtreeIfNeeded()
    }

    private func choosePosition(_ anchor: FloatingControlAnchor) {
        controls.anchor = anchor; freePosition = nil
        guard let window else { return }
        place(size: surface == .tools ? controls.preferredToolbarSize : (motion.target?.size ?? window.frame.size),
              restoreSaved: false, animated: surface == .tools)
    }

    private func setFrame(_ frame: NSRect, animated: Bool = false) {
        guard let window, motion.target != frame else { return }
        positioning = true
        tracking?.acceptsCrossings = false
        controls.toolbarSize = frame.size
        savePosition(frame)
        motion.move(window, to: frame, animated: animated)
    }

    private func savePosition(_ destination: NSRect? = nil) {
        guard var frame = destination ?? window?.frame else { return }
        // A free position saves the launcher's centre where the person put it, whatever the
        // window shows: a row, a dictation panel, or a frame recovered onto another display. An
        // earlier build's copy is written beside it, as its glyph edge and resting element.
        if controls.anchor == nil, let freePosition {
            frame = NSRect(x: freePosition.centre.x - ToolbarLayout.launcherInset, y: freePosition.centre.y - ToolbarLayout.mark.height / 2,
                           width: ToolbarLayout.mark.width, height: ToolbarLayout.mark.height)
            UserDefaults.standard.set(Self.launcherRecord(freePosition), forKey: launcherKey)
            UserDefaults.standard.set(Self.record(freePosition), forKey: freeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: launcherKey)
            UserDefaults.standard.removeObject(forKey: freeKey)
        }
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: positionKey)
        UserDefaults.standard.set(NSStringFromSize(frame.size), forKey: sizeKey)
        if let anchor = controls.anchor { UserDefaults.standard.set(anchor.rawValue, forKey: anchorKey) }
        else { UserDefaults.standard.removeObject(forKey: anchorKey) }
    }

    /// The saved position, in the order the builds wrote it: a dock by name; this build's
    /// launcher centre, unless an earlier build has since moved the toolbar; the #163 glyph
    /// edge; the resting element's origin alone, whose side is decided once, where it was left;
    /// otherwise bottom centre. `migrated` says it came from an earlier build's keys (#134).
    static func savedPosition(_ defaults: UserDefaults, screens: [NSRect], preferred: NSRect?) -> (position: ToolbarPosition, migrated: Bool) {
        if let anchor = defaults.string(forKey: "capturePanelAnchor.v2").flatMap(ToolbarAnchor.init(rawValue:)) { return (.docked(anchor), false) }
        let glyph = freePosition(defaults.dictionary(forKey: "capturePanelFreePosition.v1"))
        let launcher = defaults.dictionary(forKey: "capturePanelLauncher.v1")
        if let current = launcherPosition(launcher) {
            // The glyph edge written beside it is unchanged, so no earlier build moved it since.
            guard let glyph, !samePlace(glyph, current) else { return (.free(current), false) }
            return (.free(glyph), true)
        }
        if let glyph { return (.free(glyph), true) }
        if let origin = defaults.string(forKey: "capturePanelOrigin.v1").map(NSPointFromString), origin.x.isFinite, origin.y.isFinite {
            let size = defaults.string(forKey: "capturePanelSize.v1").map(NSSizeFromString)
                .flatMap { $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 ? $0 : nil } ?? NSSize(width: 132, height: 36)
            let resting = NSRect(origin: origin, size: size)
            let screen = FloatingControlPlacement.screen(for: resting, screens: screens, preferred: preferred ?? screens.first ?? resting)
            return (.free(ToolbarFreePosition(earlierResting: resting, on: screen)), true)
        }
        return (.docked(.bottom), false)
    }

    /// The same place and side, to within half a point: a glyph edge converted back to a centre
    /// is not always bit-exact, and an earlier build's move is always a real distance.
    static func samePlace(_ a: ToolbarFreePosition, _ b: ToolbarFreePosition) -> Bool {
        a.growsLeftward == b.growsLeftward && abs(a.centre.x - b.centre.x) < 0.5 && abs(a.centre.y - b.centre.y) < 0.5
    }

    /// The #163 record: the glyph edge of a 36-point glyph, its centre and side.
    static func record(_ position: ToolbarFreePosition) -> [String: Any] {
        ["glyphEdge": Double(position.glyphEdge), "centreY": Double(position.centre.y), "growsLeftward": position.growsLeftward]
    }
    static func freePosition(_ record: [String: Any]?) -> ToolbarFreePosition? {
        guard let record, let edge = (record["glyphEdge"] as? NSNumber)?.doubleValue, let centre = (record["centreY"] as? NSNumber)?.doubleValue,
              let leftward = record["growsLeftward"] as? Bool else { return nil }
        let position = ToolbarFreePosition(glyphEdge: edge, centreY: centre, growsLeftward: leftward)
        return position.isFinite ? position : nil
    }
    /// The #134 record: the launcher's centre and side.
    static func launcherRecord(_ position: ToolbarFreePosition) -> [String: Any] {
        ["x": Double(position.centre.x), "y": Double(position.centre.y), "growsLeftward": position.growsLeftward]
    }
    static func launcherPosition(_ record: [String: Any]?) -> ToolbarFreePosition? {
        guard let record, let x = (record["x"] as? NSNumber)?.doubleValue, let y = (record["y"] as? NSNumber)?.doubleValue,
              let leftward = record["growsLeftward"] as? Bool else { return nil }
        let position = ToolbarFreePosition(centre: CGPoint(x: x, y: y), growsLeftward: leftward)
        return position.isFinite ? position : nil
    }

    func windowDidMove(_ notification: Notification) {
        guard !positioning, !dragging, window?.isVisible == true else { return }
        savePosition()
    }

    func beginDragging() {
        dragging = true; tracking?.acceptsCrossings = false
        // A pointer drag never takes the keyboard, so Position… would otherwise stay open.
        positionControl.close(); chooser.close()
        if let window { motion.finish(window) }
        controls.setDragging(true); previewDragging()
    }

    func cancelDragging() {
        let wasDragging = dragging
        dragging = false; snapGuide.hide()
        if wasDragging {
            tracking?.settle()
            controls.setDragging(false)
            tracking?.acceptsCrossings = surface == .tools && motion.target == nil
        }
    }

    func windowWillClose(_ notification: Notification) { cancelDragging() }

    override func close() {
        observations.removeAll()
        if let model { model.coach.canPresent = nil; model.coach.remove() }
        coachPanel.hide()
        controls.resize = nil; controls.choosePosition = nil; controls.showPosition = nil
        controls.openChooser = nil; controls.chooserChoicesChanged = nil; controls.revealFromRest = nil
        positionControl.close(); chooser.close()
        controls.suspendToolbar(); cancelDragging(); releaseKeyboardFocus()
        motion.settled = nil
        if let window { motion.finish(window) }
        tracking?.acceptsCrossings = false; tracking?.event = nil
        super.close()
    }

    /// The launcher's end is what docks, whatever the host shows: its slot is outlined, and a
    /// dock's guide is active only within the snap distance. Recording and results move the one
    /// shared position, as the tools do (#134 T4).
    func previewDragging() {
        guard dragging, let window, let preferred = preferredScreen else { snapGuide.hide(); return }
        let slot = ToolbarGeometry.slot(around: ToolbarGeometry.launcherCentre(inWindow: window.frame, growsLeftward: controls.rowAnchor.growsLeftward))
        let screen = FloatingControlPlacement.screen(for: slot, screens: NSScreen.screens.map(\.visibleFrame), preferred: preferred)
        snapGuide.show(controlFrame: slot, visibleFrame: screen,
                       activeAnchor: FloatingControlPlacement.snapAnchor(for: slot, in: screen), below: window)
    }

    func finishDragging() {
        defer { cancelDragging() }
        guard dragging, let window else { return }
        releaseTools(atLauncher: ToolbarGeometry.launcherCentre(inWindow: window.frame, growsLeftward: controls.rowAnchor.growsLeftward))
    }

    /// The tools released with their launcher at `centre` (#163, #134): within the snap
    /// distance of a named dock they dock there; anywhere else they rest right there, kept
    /// whole on the display they cover most, growing toward its middle from then on. The
    /// drag's release and the gallery's check use it.
    func releaseTools(atLauncher centre: CGPoint) {
        guard let preferred = preferredScreen else { return }
        let slot = ToolbarGeometry.slot(around: centre)
        let screen = FloatingControlPlacement.screen(for: slot, screens: NSScreen.screens.map(\.visibleFrame), preferred: preferred)
        if let anchor = FloatingControlPlacement.snapAnchor(for: slot, in: screen) {
            controls.anchor = anchor; freePosition = nil
        } else {
            // The side is decided here, once, and kept: a later change of width never turns it round.
            let kept = FloatingControlGeometry.clamp(slot, to: screen, inset: 0)
            controls.anchor = nil
            freePosition = ToolbarFreePosition(releasedAt: CGPoint(x: kept.midX, y: kept.midY), on: screen)
        }
        if surface == .tools { placeTools(previous: slot, preferred: preferred, animated: true) } else { savePosition() }
    }

    /// Position…: the named docks and a reset, beside the toolbar, from the keyboard or pointer.
    /// Opened from the toolbar's keyboard focus, it hands the keyboard back when it closes.
    private func showPositionControl(onClose: (() -> Void)? = nil) {
        guard let window, window.isVisible else { return }
        chooser.close()
        // Position… takes the keyboard, and the toolbar forgets its target when it resigns: keep both now.
        let fromKeyboard = (window as? CapturePanel)?.allowsKeyboardFocus == true, target = keyboardTarget
        positionControl.show(beside: window.frame, level: window.level, current: controls.anchor,
            choose: { [weak self] in self?.choosePosition($0) },
            reset: { [weak self] in self?.choosePosition(.bottom) },
            closed: { [weak self] reason in
                onClose?()
                self?.positionClosed(returnsKeyboard: reason.returnsKeyboard(openedFromKeyboard: fromKeyboard)) {
                    self?.returnKeyboardToToolbar(target: target)
                }
            })
    }

    /// After Position… closes (#211 F2): the keyboard goes back first, when it should, and only then
    /// does the host update, so a result waiting on a kept-open row finds the keyboard's hold and
    /// stays behind the launcher row instead of taking the keyboard's place. The gallery passes
    /// the keyboard's hold alone as `returnKeyboard`, so it never takes the person's keyboard.
    func positionClosed(returnsKeyboard: Bool, returnKeyboard: () -> Void) {
        if returnsKeyboard { returnKeyboard() }
        if let model { update(model: model) }
    }

    /// The tool chooser (#134), from a click, Space or Return on the launcher. It holds the row
    /// open, as a menu does. Before it takes the keyboard, the field in front is kept: the one
    /// the toolbar was focused from, or the one in front now. A choice or Escape returns the
    /// keyboard to the launcher with that field; anything else leaves the keyboard where the
    /// person put it. Choosing changes only the remembered tool.
    private func openChooser(from launcher: NSView, choices: [ToolbarToolChoice]) {
        if chooser.isShown { chooser.close(); return }
        guard surface == .tools, controls.toolbar.isActive, let window, let launcherWindow = launcher.window else { return }
        positionControl.close()
        let panel = window as? CapturePanel
        let target = panel?.allowsKeyboardFocus == true && panel?.isKeyWindow == true ? keyboardTarget : TextDelivery.capture()
        controls.toolbar.send(.holdBegan(.menu))
        let frame = launcherWindow.convertToScreen(launcher.convert(launcher.bounds, to: nil))
        chooser.show(from: frame, view: launcher, level: window.level, growsLeftward: controls.rowAnchor.growsLeftward, choices: choices,
            choose: { [weak self] mode in self?.model?.toolbarMode = mode },
            closed: { [weak self] reason in
                guard let self else { return }
                self.controls.menuDidClose?()
                if reason.returnsKeyboardToLauncher { self.returnKeyboardToToolbar(target: target) }
            })
    }

    /// After Position… or the chooser closes from a choice or Escape, the toolbar takes the
    /// keyboard back with the field it kept. A second Escape then leaves through
    /// `releaseKeyboardFocus`, returning to that field while it is still valid.
    private func returnKeyboardToToolbar(target: TextDelivery.Target?) {
        guard surface == .tools, let panel = window as? CapturePanel else { return }
        takeKeyboard(panel, target: target)
    }
}

@MainActor
protocol FloatingHUDDragController: AnyObject {
    func beginDragging()
    func cancelDragging()
    func previewDragging()
    func finishDragging()
}

struct PanelDragHandle: NSViewRepresentable {
    var accessibilityLabel = "Drag toolbar; named positions are also in Toolbar position"
    var showsGrip = false
    func makeNSView(context: Context) -> DragHandleView { DragHandleView(accessibilityLabel: accessibilityLabel, showsGrip: showsGrip) }
    func updateNSView(_ nsView: DragHandleView, context: Context) {}
}

final class DragHandleView: NSView {
    private var anchor: NSPoint?
    private var startingOrigin: NSPoint?
    private let showsGrip: Bool
    init(accessibilityLabel: String, showsGrip: Bool = false) {
        self.showsGrip = showsGrip
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel(accessibilityLabel)
        toolTip = "Drag to move. Release near an edge guide to snap."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        anchor = window.convertPoint(toScreen: event.locationInWindow)
        (window.windowController as? FloatingHUDDragController)?.beginDragging()
        startingOrigin = window.frame.origin
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let anchor, let startingOrigin else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(x: startingOrigin.x + point.x - anchor.x, y: startingOrigin.y + point.y - anchor.y))
        (window.windowController as? FloatingHUDDragController)?.previewDragging()
    }
    override func mouseUp(with event: NSEvent) {
        (window?.windowController as? FloatingHUDDragController)?.finishDragging()
        anchor = nil; startingOrigin = nil
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            (window?.windowController as? FloatingHUDDragController)?.cancelDragging()
            anchor = nil; startingOrigin = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func draw(_ dirtyRect: NSRect) {
        guard showsGrip else { return }
        NSColor.secondaryLabelColor.setFill()
        for x in [-3.0, 3.0] { for y in [-6.0, 0.0, 6.0] {
            NSBezierPath(ovalIn: NSRect(x: bounds.midX + x - 1.4, y: bounds.midY + y - 1.4, width: 2.8, height: 2.8)).fill()
        } }
    }
}

/// A dictation's result, revealed from the toolbar's place (#134 T4): the failure that needs
/// attention, with Retry, Record again or Open Workbench and Dismiss, or the clipboard receipt
/// with Review, its pin and its dismiss. Each keeps the message and commands it had in the
/// dictation panel; recording and processing are the toolbar row's own now.
struct DictationResultView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controls: CaptureHUDControls
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// The failure's commands, the first of which takes the keyboard's focus (#211 F1).
    enum Action: Hashable { case retry, recordAgain, openWorkbench, dismiss }
    @FocusState private var focused: Action?

    private var firstAction: Action {
        if model.canRetry { return .retry }
        return model.canRecordAgain ? .recordAgain : .openWorkbench
    }

    var body: some View {
        // It grows from the launcher's centre like the row, so at a right-hand dock it is mirrored:
        // the drag handle and the words sit over the mark the pointer came from, and the commands
        // and Position at the far end (#211 F3). VoiceOver reads it in the same order either way.
        let mirrored = controls.rowAnchor.growsLeftward
        HStack(spacing: 8) {
            if !mirrored { PanelDragHandle().frame(width: 8, height: 40) }
            if let failure = model.captureFailure {
                failureState(failure, mirrored: mirrored)
                    .defaultFocus($focused, firstAction)
                    .onAppear { ResultKeyboard.appeared(controls) { focused = firstAction } }
            } else {
                CaptureReceiptView(receipts: model.clipboardReceipt, review: { Self.review($0, model: model) }, controls: controls,
                                   mirrored: mirrored)
            }
            if mirrored { PanelDragHandle().frame(width: 8, height: 40) }
        }.padding(.horizontal, 12)
            .frame(width: CaptureHUDLayout.message.width, height: CaptureHUDLayout.message.height)
            .background {
                if reduceTransparency { RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .windowBackgroundColor)) }
                else { RoundedRectangle(cornerRadius: 18).fill(.regularMaterial) }
            }
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.12)))
            .transaction { $0.animation = nil }
            .onExitCommand(perform: controls.endKeyboardInteraction)
            .tint(Workbench.accent).workbenchTheme()
    }

    /// Review opens where the words are kept: Library for a copied prompt, History for a transcript.
    static func review(_ receipt: ClipboardReceipt, model: AppModel) {
        if receipt.source == .prompt { model.showLibrary() }
        else { model.openHistory(); model.onShowEditor?("history") }
    }

    private func failureState(_ failure: String, mirrored: Bool) -> some View {
        let message = VStack(alignment: .leading, spacing: 7) {
            Label("Dictation needs attention", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
            Text(failure).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true).help(failure)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilitySortPriority(3)
        let commands = VStack(spacing: 4) {
            if model.canRetry {
                Button { model.retryTranscription() } label: { Text(model.retryCaptureLabel).frame(minWidth: 44, minHeight: 28) }
                    .buttonStyle(.borderedProminent).help(model.retryCaptureHelp)
                    .focused($focused, equals: .retry).resultAction("Retry", controls)
            }
            if model.canRecordAgain {
                Button("Record again") { model.toggleRecording() }
                    .buttonStyle(.bordered).help("Keep this audio in Saved recordings and start a new capture")
                    .focused($focused, equals: .recordAgain).resultAction("Record again", controls)
            } else if !model.canRetry || model.hasCaptureRecovery {
                Button { model.dismissCaptureFailure(); model.onShowEditor?("dictate") } label: {
                    Text("Open Workbench").font(.system(size: 12)).frame(minHeight: 28)
                }.buttonStyle(.bordered)
                    .focused($focused, equals: .openWorkbench).resultAction("Open Workbench", controls)
            }
            Button { model.dismissCaptureFailure() } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                .buttonStyle(.plain).accessibilityLabel("Dismiss dictation error")
                .focused($focused, equals: .dismiss).resultAction("Dismiss", controls)
        }.controlSize(.small).accessibilityElement(children: .contain).accessibilitySortPriority(2)
        let position = CapturePositionMenu(controls: controls).accessibilitySortPriority(1)
        return HStack(spacing: 9) {
            if mirrored { position; commands; message } else { message; commands; position }
        }
    }

}

/// The routine no-speech cue at the toolbar's place, for under two seconds, then the compact
/// mark again (#156, #134 T4). It keeps the size of the recording controls it used to replace.
struct NoSpeechCueHUD: View {
    let cue: CaptureCue
    let hold: (Bool) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        NoSpeechCueView(cue: cue, hold: hold)
            .padding(.horizontal, 20)
            .frame(width: CaptureHUDLayout.compact.width, height: CaptureHUDLayout.compact.height)
            .background {
                if reduceTransparency { RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .windowBackgroundColor)) }
                else { RoundedRectangle(cornerRadius: 18).fill(.regularMaterial) }
            }
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.12)))
            .transaction { $0.animation = nil }
            .tint(Workbench.accent).workbenchTheme()
    }
}

/// The routine cue after a dictation that heard no speech: two short lines in
/// place of the recording controls, gone by itself. Hovering it, or VoiceOver
/// on it, holds it. It has no buttons because nothing needs a decision; a kept
/// recording waits on the Dictate page (#156).
struct NoSpeechCueView: View {
    let cue: CaptureCue
    let hold: (Bool) -> Void
    @State private var hovering = false
    @AccessibilityFocusState private var voiceOverFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.slash").font(.system(size: 17)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(cue.message).font(.system(size: 13, weight: .semibold))
                Text(cue.hint).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0; hold($0 || voiceOverFocused) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cue.message + ". " + cue.hint)
        .accessibilityFocused($voiceOverFocused)
        .onChange(of: voiceOverFocused) { _, focused in hold(focused || hovering) }
    }
}

private struct CaptureReceiptView: View {
    @ObservedObject var receipts: ClipboardReceiptModel
    /// Opens where the words are kept, for the receipt as it was when Review was pressed:
    /// dismissing a receipt whose words have left the clipboard clears it.
    let review: (ClipboardReceipt) -> Void
    @ObservedObject var controls: CaptureHUDControls
    /// At a right-hand dock the commands and Position sit at the far end (#211 F3).
    var mirrored = false
    /// Review, the receipt's first command, takes the keyboard's focus (#211 F1).
    @FocusState private var reviewFocused: Bool
    var body: some View {
        if let receipt = receipts.receipt {
            let words = VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: receipt.symbolName).foregroundStyle(Workbench.accent)
                    Text(receipt.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if receipt.wordCount > 0 { Text("\(receipt.wordCount) \(receipt.wordCount == 1 ? "word" : "words")").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                Text(receipt.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).accessibilitySortPriority(3)
            let commands = VStack(spacing: 3) {
                Button { receipts.dismissHUD(); review(receipt) } label: { Text("Review").frame(minWidth: 44, minHeight: 28) }
                    .buttonStyle(.bordered).controlSize(.small).help(receipt.source == .prompt ? "Open Library" : "Open History")
                    .focused($reviewFocused).resultAction("Review", controls)
                HStack(spacing: 2) {
                    if receipt.isClipboardCurrent {
                        Button { receipts.keepVisible.toggle() } label: {
                            Image(systemName: receipts.keepVisible ? "pin.fill" : "pin").frame(width: 28, height: 28)
                        }.buttonStyle(.plain)
                            .accessibilityLabel(receipts.keepVisible ? "Unpin receipt" : "Keep receipt visible")
                            .help("Keep visible while this text is on the clipboard").resultAction("Pin", controls)
                    }
                    // The ring reads the receipt's own lifetime: eight seconds for a copy, four for a paste (#134 T5).
                    Button { receipts.dismissHUD() } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss dictation receipt").resultAction("Dismiss", controls)
                        .overlay { LiveCountdownRing(lifetime: receipts.lifetime, clock: receipts.now).allowsHitTesting(false) }
                }
            }.accessibilityElement(children: .contain).accessibilitySortPriority(2)
            let position = CapturePositionMenu(controls: controls).accessibilitySortPriority(1)
            HStack(spacing: 9) {
                if mirrored { position; commands; words } else { words; commands; position }
            }
            // The pointer holds its time, including one resting where it appears (#134 T5).
            .background(PointerPresence { receipts.holdHUD($0) })
            .defaultFocus($reviewFocused, true)
            .onAppear { ResultKeyboard.appeared(controls) { reviewFocused = true } }
        }
    }
}

/// Keyboard for a result's own controls (#211 F1). Keyboard entry keeps the launcher row, so a
/// result shows only for the pointer's reveal; a person who then takes the keyboard, by the
/// click on the mark or Window › Focus floating toolbar, lands on the result's first command,
/// and Escape leaves as it does from the launcher row (`.onExitCommand` on each result, and
/// `CapturePanel.escape` for a key nothing inside handled).
extension View {
    /// Reports this result action's frame for the gallery's right-hand dock check (#211 F3).
    func resultAction(_ name: String, _ controls: CaptureHUDControls) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { controls.resultActionFrames[name] = $0 }
    }
}

@MainActor enum ResultKeyboard {
    static func appeared(_ controls: CaptureHUDControls, focusFirst: @escaping () -> Void) {
        controls.focusFirstControl = focusFirst
        if controls.toolbar.state.holds.contains(.keyboard) { focusFirst() }
    }
}

/// A result's own placement menu: the named docks and Reset position. It sits at the result's
/// far end from the mark, with its other commands, when the result is mirrored (#211 F3).
struct CapturePositionMenu: View {
    @ObservedObject var controls: CaptureHUDControls
    var body: some View {
        Menu {
            Section("Position") {
                ForEach(FloatingControlAnchor.allCases) { anchor in
                    Button { controls.choosePosition?(anchor) } label: {
                        if controls.anchor == anchor { Label(anchor.title, systemImage: "checkmark") }
                        else { Text(anchor.title) }
                    }
                }
                Button("Reset position") { controls.choosePosition?(.bottom) }
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 32)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Toolbar position").help("Position")
    }
}
