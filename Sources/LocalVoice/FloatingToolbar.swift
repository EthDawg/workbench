import AppKit
import SwiftUI
import StageKit
import ToolbarCore
import ToolbarKit

/// One window and one host own the tools, dictation, narration and reading (#134 T4).
/// Starting an operation never changes the user's choice to show the toolbar.
enum FloatingToolbarSurface: Equatable {
    /// Nothing to show, or a screen capture that must not include the controls.
    case hidden
    /// The shared host: the compact mark at rest; revealed, the launcher row, or a result's own
    /// controls. Dictation, narration, reading and their results keep it up while Hide toolbar is on.
    case tools
    /// The routine no-speech cue, for under two seconds, at the toolbar's place (#156).
    case cue

    static func resolve(enabled: Bool, capturingScreen: Bool, dictation: Bool, narration: Bool, reading: Bool = false,
                        cue: Bool = false) -> Self {
        if capturingScreen { return .hidden }
        if cue { return .cue }
        return enabled || dictation || narration || reading ? .tools : .hidden
    }

    /// Hide toolbar is authoritative for the tools (#155). Drawing, a presentation and
    /// personas are deliberately not consulted: they carry on without the tools, reachable
    /// by their keys and the menu-bar panel, and Show floating toolbar brings the tools back
    /// with their live state. A prompt insertion keeps the tools until it ends, because its
    /// Stop is there. Recording, processing, narration, reading and their results keep the
    /// same host up, at rest as the compact mark, until they end.
    static func resolve(shown: Bool, drawing: Bool, presenting: Bool, persona: Bool, inserting: Bool,
                        capturingScreen: Bool, dictation: Bool, narration: Bool, reading: Bool, cue: Bool = false) -> Self {
        resolve(enabled: shown || inserting, capturingScreen: capturingScreen,
                dictation: dictation, narration: narration, reading: reading, cue: cue)
    }
}

/// A result that keeps its own controls (#134 T4): a dictation that needs attention, a reading
/// that stopped. Delivery cues have their own brief, button-free presentation.
enum FloatingResult: Equatable {
    case dictationFailure, readingFailure

    /// The result waiting for the person stays reachable in the chooser while other work runs. A new recording or its processing sets it aside until it ends.
    @MainActor static func pending(_ model: AppModel) -> FloatingResult? {
        guard model.phase == .idle, !model.previewingPanel else { return nil }
        if model.captureFailure != nil { return .dictationFailure }
        if model.readingFailure != nil, !model.rendering, !model.playing, !model.paused { return .readingFailure }
        return nil
    }

    /// Which result is pending, for the live work's hold (#222). A failure is known by its kind: the
    /// host lets a held one go when its owner sets that slot again, so a new failure in the same
    /// words is new.
    enum Identity: Hashable { case dictationFailure, readingFailure }
    @MainActor func identity(in model: AppModel) -> Identity? {
        switch self {
        case .dictationFailure: return .dictationFailure
        case .readingFailure: return .readingFailure
        }
    }

    /// The result the pointer's reveal shows in place of the row (#220, #222): the pending one,
    /// unless it was already pending when the input-consuming work now live began. The row of a
    /// reading preparing, playing or paused, a narration, a recording, drawing or an insertion then
    /// stays under the pointer, and the result keeps its recovery with its owner
    /// until the next reveal after that work ends. A result that arrives during the work, or over
    /// the chosen tool's own session, is revealed as any new result is.
    @MainActor static func revealed(_ model: AppModel, hold: ToolbarResultHold<Identity>) -> FloatingResult? {
        guard let result = pending(model), let identity = result.identity(in: model), hold.reveals(identity) else { return nil }
        return result
    }
}

extension ToolbarMode {
    /// The panel row that shares this mode's shortcut, admission and detail.
    var controlTool: WorkbenchControlTool? { WorkbenchControlTool(mode: self) }
}

/// The toolbar's mode follows the journey. This view freezes what is live into
/// one `ToolbarLiveState` per render, asks the core for the next action, and
/// maps each operation back to the owner that already does it.
struct FloatingToolbar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var readback: ReadbackModel
    @ObservedObject var stage: StageKitController
    @ObservedObject var controls: CaptureHUDControls
    @ObservedObject var promptInsertion: PromptInsertion
    @ObservedObject var meetings: MeetingModel
    @ObservedObject var snapModel: SnapModel
    /// The clipboard receipt is its own owner: a new one must redraw the mark's status (#134 T4).
    @ObservedObject var receipts: ClipboardReceiptModel
    let dictate: () -> Void
    let snap: () -> Void
    let snapCapture: () -> Void
    let draw: () -> Void
    let present: () -> Void
    var capture: (ToolbarMode, ToolbarCaptureKind) -> Void = { _, _ in }
    private var context: WorkbenchControlContext { .init(model: model, readback: readback, stage: stage, snap: snapModel) }

    /// The same frozen value the panel's rows read, for the selected mode.
    var live: ToolbarLiveState { context.state.live(model.toolbarMode) }

    /// The assigned key for a mode, or nil when it is off or failed: an
    /// unusable binding is omitted rather than shown as text nobody can use.
    func key(_ mode: ToolbarMode) -> String? {
        guard let tool = mode.controlTool else { return nil }
        switch context.shortcut(tool) {
        case "Shortcut off", "Shortcut unavailable", nil: return nil
        case .some(let keys): return keys
        }
    }

    /// Name the actual shortcut gesture. A held recording ends on release; a
    /// different drawing tool cannot claim that Pen's key will stop it.
    private func actionKey(_ operation: ToolbarOperation) -> String? {
        guard let mode = operation.keyMode, let assigned = key(mode) else { return nil }
        switch mode {
        case .dictate:
            let starting: Bool
            if case .start = operation { starting = true } else { starting = false }
            return ToolbarShortcut.actionHint(key: assigned, holdToStart: starting && model.preferences.capture == .hold,
                                              releaseToFinish: !starting && model.captureUsesHoldShortcut)
        case .draw:
            guard let gesture = stage.penShortcutGesture else { return nil }
            return ToolbarShortcut.actionHint(key: assigned, holdToStart: gesture == .hold, releaseToFinish: gesture == .release)
        case .snapAndTalk:
            // Without a prepared session the key opens its page, while the
            // toolbar starts a capture. Do not imply those are the same action.
            guard readback.sessionURL != nil, readback.permissionsReady,
                  readback.currentSessionProblem == nil || readback.isRecording else { return nil }
            return assigned
        default: return assigned
        }
    }

    /// What the owners say is going on, for the compact rest's indicator (#134).
    var activity: ToolbarActivity { context.activity(snapAndTalkSequence: controls.snapAndTalkSequence) }

    var viewState: ToolbarViewState {
        let live = self.live
        let action = ToolbarNextAction.resolve(live)
        // An unfinished Snap is reopened by every capture door, so the pill offers it instead of
        // sources that would each bring back the draft.
        let draftWaiting = reviewsUnfinishedSnap(live)
        // A start held back only by a dictation still processing says so, rather than a bare grey icon.
        let waitsForDictation: Bool = {
            guard !action.isEnabled, live.dictation != .idle else { return false }
            if case .start = action.operation { return true }
            return action.operation == .captureNext
        }()
        let hint = draftWaiting ? ["Your unfinished Snap · save or discard it to capture again"]
            : waitsForDictation ? ["Available when dictation finishes"]
            : [elapsed(for: action.operation), action.hint(key: actionKey(action.operation))].compactMap { $0 }
        return ToolbarViewState(name: "live", tier: controls.toolbar.state.tier,
            anchor: controls.rowAnchor, isFloating: controls.isFloating,
            mode: live.mode, actionTitle: draftWaiting ? "Review unfinished Snap" : action.title, actionSymbol: draftWaiting ? "photo" : action.symbol,
            isActionEnabled: draftWaiting || action.isEnabled,
            actionHint: hint.isEmpty ? nil : hint.joined(separator: " · "),
            choices: chooserChoices,
            isBusy: live.isLive(live.mode),
            status: .resolve(activity), showsAccessory: controls.accessoryFits,
            accessory: accessory(live), accessoryDescription: accessoryDescription(live),
            captureChoices: draftWaiting ? [] : ToolbarCaptureKind.offered(for: live), quickControl: quickControl)
    }

    /// The chosen tool's one accessory (#134 part B): Snap & Talk's Review once a session is open,
    /// Draw's Tools, Present's Prompts, and Persona's picker, whose choices are the cards and the
    /// live camera, so the camera is one click from the revealed pill.
    func accessory(_ live: ToolbarLiveState) -> ToolbarAccessory? {
        if live.mode == .persona { return stage.personaPicker == nil ? nil : .personaPicker }
        return ToolbarAccessory.offered(for: live, selectedPersonaCopy: live.mode == .persona && stage.selectedPersonaCopy != nil)
    }
    var quickControl: ToolbarQuickControl? {
        if live.mode == .present, stage.isPresenting { return .presentationView }
        if live.mode == .persona, let cycle = stage.personaCycle, cycle.canAdvance {
            return cycle.isSet ? .nextSet : .nextPersona
        }
        return nil
    }
    func pressQuick() -> (() -> Void)? {
        guard let cycle = stage.personaCycle, cycle.canAdvance else { return nil }
        return { stage.stepPersona(expected: cycle) }
    }
    /// The current frozen Persona label or the exact session capture count.
    func accessoryDescription(_ live: ToolbarLiveState) -> String? {
        if live.mode == .persona, let picker = stage.personaPicker {
            if picker.isSet { return "Choose set · " + picker.title }
            return picker.title.isEmpty ? "Choose Persona" : "Choose Persona · " + picker.title
        }
        if accessory(live) == .review, let count = live.captureCount {
            return "Review Snap & Talk · \(count) " + (count == 1 ? "capture" : "captures")
        }
        return nil
    }

    /// A recording's elapsed time against its 5-minute limit, for the Stop that ends it (#134 T4).
    /// It lives in the hint and VoiceOver's help, never the label, whose width would tick.
    private func elapsed(for operation: ToolbarOperation) -> String? {
        let seconds: Double
        switch operation {
        case .stopDictation: seconds = model.elapsed
        case .finishNarration: seconds = readback.recordingElapsed
        default: return nil
        }
        return time(seconds) + " of 5:00"
    }

    var body: some View {
        let state = viewState
        let operation = ToolbarNextAction.resolve(live).operation
        content(state)
            // The host sizes its window from these reports (#152). A preference written
            // from a background GeometryReader never reached onPreferenceChange once the
            // row held conditional content, so every window kept its seed size.
            .onGeometryChange(for: ToolbarMeasurement.self) {
                ToolbarMeasurement(tier: state.tier, anchor: state.anchor, isResult: controls.revealsResult,
                                   accessoryAvailable: state.accessoryCount > 0, accessoryShown: state.showsAccessory,
                                   accessoryCount: state.accessoryCount, size: $0.size)
            } action: { measurement in
                controls.reportSize(measurement.size, tier: measurement.tier, anchor: measurement.anchor, isResult: measurement.isResult,
                                    accessoryAvailable: measurement.accessoryAvailable, accessoryShown: measurement.accessoryShown,
                                    accessoryCount: measurement.accessoryCount)
            }
            // Each change of the next action is a new generation, so a press latched on the
            // old one cannot act on the new one (#134).
            .onChange(of: operation, initial: true) { _, operation in controls.pressGate.shown(operation) }
            .onChange(of: state.choices) { _, choices in controls.chooserChoicesChanged?(choices) }
            .onChange(of: chooserActivities) { _, activities in controls.chooserActivitiesChanged?(activities) }
            .onChange(of: state.status, initial: true) { previous, status in controls.statusChanged(from: previous, to: status) }
            .pinnedToDock(state.anchor, isFloating: state.isFloating)
            .tint(Workbench.accent).workbenchTheme()
    }

    /// The launcher row, or, when the row opened on a result, that result's own controls,
    /// growing inward from the same place (#134 T4). The host decides at the reveal; a result it
    /// showed stays while the pointer or a hold keeps it, even as live work begins (#222).
    @ViewBuilder private func content(_ state: ToolbarViewState) -> some View {
        if state.tier == .revealed, controls.revealsResult, let result = FloatingResult.pending(model) {
            FloatingResultView(result: result, model: model, controls: controls)
        } else {
            ToolbarRow(state: state, accent: Workbench.accent,
                makeAccessoryMenu: { accessoryMenu(state.accessory) }, openAccessory: accessoryPanel(state.accessory),
                makeViewMenu: stage.makePresentationViewMenu, pressQuick: pressQuick,
                press: pressPrimary, pressCapture: pressCapture,
                openChooser: { launcher in
                    controls.chooserActivities = chooserActivities
                    controls.chooserPerform = performChooserAction
                    controls.openChooser?(launcher, chooserChoices)
                },
                makeMenu: toolbarContextMenu, menuBegan: controls.beginMenu, menuEnded: controls.endMenu,
                focusButton: { button in
                    controls.focusFirstControl = { [weak button] in
                        guard let button else { return }
                        button.window?.makeFirstResponder(button)
                    }
                }, escape: controls.endKeyboardInteraction, revealFromRest: { controls.revealFromRest?() }, drag: controls.dragActions)
        }
    }

    /// Latches the next action as the button goes down (#134). The click then acts only if
    /// the same operation, in the same generation, is still the next action when it comes up,
    /// so a Stop that completes while pressed is discarded rather than becoming a Start; and a
    /// press on a label that changed since the last redraw does nothing. Internal so the host
    /// checks can press it through a completion.
    func pressPrimary() -> (() -> Void)? {
        // The unfinished Snap reopens directly, as the chooser's Review unfinished Snap does,
        // whatever else is running; no capture is attempted.
        if reviewsUnfinishedSnap(live) {
            return controls.pressGate.press({
                var action = ToolbarNextAction.resolve(live); action.isEnabled = reviewsUnfinishedSnap(live); return action
            }, perform: { _ in model.onShowEditor?("snap"); snapModel.reviewDraft() })
        }
        let personaIdentity = stage.personaSessionIdentity
        return controls.pressGate.press({ ToolbarNextAction.resolve(live) }, perform: { operation in
            guard operation.mode != .persona || stage.personaSessionIdentity == personaIdentity else { return }
            perform(operation)
        })
    }

    /// Snap's start while an unfinished Snap waits: the pill offers that draft instead.
    func reviewsUnfinishedSnap(_ live: ToolbarLiveState) -> Bool {
        ToolbarNextAction.resolve(live).operation == .start(.snap) && snapModel.draft != nil
    }

    /// The source and selected tool are fixed at mouse-down. The shared operation generation
    /// rejects a click after another job starts, even if it finishes before mouse-up.
    func pressCapture(_ kind: ToolbarCaptureKind) -> (() -> Void)? {
        let mode = live.mode
        let sessionID = readback.manifest?.id
        guard ToolbarCaptureKind.offered(for: live).contains(kind) else { return nil }
        return controls.pressGate.press({
            var action = ToolbarNextAction.resolve(live)
            action.isEnabled = action.isEnabled && live.mode == mode && ToolbarCaptureKind.offered(for: live).contains(kind)
                && (mode != .snapAndTalk || readback.manifest?.id == sessionID)
            return action
        }, perform: { _ in capture(mode, kind) })
    }

    /// The accessory that opens a place or a panel: Review opens the session's review, and Prompts
    /// the one Saved Prompts picker. Tools and Persona selection open their menus instead.
    func accessoryPanel(_ accessory: ToolbarAccessory?) -> ((NSView) -> Void)? {
        switch accessory {
        case .review?: return { _ in model.onShowEditor?("readback") }
        case .prompts?: return { button in openPrompts(anchor: button, destination: controls.promptDestination?()) }
        case .tools?, .personaPicker?, nil: return nil
        }
    }
    /// Existing drawing choices or frozen Persona choices, retained by their live owners.
    func accessoryMenu(_ accessory: ToolbarAccessory?) -> NSMenu {
        switch accessory {
        case .tools?: return stage.makeAnnotationMenu(includeSettings: false)
        case .personaPicker?: return stage.makePersonaPickerMenu()
        case .review?, .prompts?, nil: return NSMenu()
        }
    }

    /// One Saved Prompts picker for the pill and workspace (#159). It
    /// freezes the field that was in front when it was asked for.
    private func openPrompts(anchor: NSView? = nil, frame: NSRect? = nil, destination: TextDelivery.Target?) {
        let context = PromptPickerController.Context(resources: model.library.resources, delivery: promptInsertion,
            receipts: model.clipboardReceipt, destination: destination, trusted: AXIsProcessTrusted(),
            controls: controls, openLibrary: { model.showLibrary() })
        if let anchor { PromptPickerController.shared.show(from: anchor, context: context) }
        else if let frame { PromptPickerController.shared.show(anchor: frame, context: context) }
    }

    /// Each operation goes to the owner that already does it. The toolbar never
    /// ends anything but what its label names.
    private func perform(_ operation: ToolbarOperation) {
        WorkbenchOperationDispatch(model: model, readback: readback, stage: stage, meetings: meetings) { mode in
            switch mode {
            case .dictate: dictate()
            case .read: model.onShowEditor?("speak")
            case .snap: snapCapture()
            case .snapAndTalk: snap()
            case .draw: draw()
            case .present: present()
            case .persona: stage.togglePersona()
            }
        }.perform(operation)
    }

    /// A context click is only a shortcut to the toolbar's own settings.
    func toolbarContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Floating toolbar"); menu.autoenablesItems = false
        // One command in place of the eight-item submenu: the named docks and a reset, for
        // the keyboard and precise placement (#163). Dragging is the everyday way to move.
        menu.addItem(ToolbarMenuAction("Position…") { controls.toolbar.afterMenuTracking { controls.showPosition?() } })
        menu.addItem(ToolbarMenuAction("Keep open", checked: controls.toolbar.state.keepsOpen) {
            controls.toolbar.send(.keepOpenChanged(!controls.toolbar.state.keepsOpen))
        })
        menu.addItem(ToolbarMenuAction("Hide toolbar") { model.floatingToolbarVisible = false })
        menu.addItem(ToolbarMenuAction("Settings…") { model.onShowEditor?("settings") })
        return menu
    }

    static func shortcutLabel(_ shortcut: VoiceShortcut, failure: String?) -> String {
        if !shortcut.enabled { return "Shortcut off" }
        if failure != nil { return "Shortcut unavailable" }
        return shortcut.label
    }
}

private struct ToolbarMeasurement: Equatable {
    var tier: ToolbarTier
    var anchor: ToolbarAnchor
    var isResult: Bool
    var accessoryAvailable: Bool
    var accessoryShown: Bool
    var accessoryCount: Int
    var size: CGSize
}

struct WorkbenchFloatingContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var readback: ReadbackModel
    @ObservedObject var stage: StageKitController
    @ObservedObject var controls: CaptureHUDControls
    @ObservedObject var receipts: ClipboardReceiptModel
    @ObservedObject var meetings: MeetingModel
    let snapModel: SnapModel
    let dictate: () -> Void
    let snap: () -> Void
    let snapCapture: () -> Void
    let draw: () -> Void
    let present: () -> Void
    var capture: (ToolbarMode, ToolbarCaptureKind) -> Void = { _, _ in }

    /// Dictation, narration, reading and their results share the toolbar's host (#134 T4): the
    /// compact mark at rest, the row or a result's controls revealed. Only the routine no-speech
    /// cue keeps its own view, briefly, at the same place.
    var body: some View {
        if let cue = model.captureCue, CapturePanelController.showsCue(model), !readback.isRecording {
            NoSpeechCueHUD(cue: cue, hold: model.holdCaptureCue)
        } else if CapturePanelController.showsDeliveryCue(model), !readback.isRecording {
            ClipboardCueHUD(receipts: receipts)
        } else {
            FloatingToolbar(model: model, readback: readback, stage: stage, controls: controls, promptInsertion: model.promptInsertion,
                            meetings: model.meetings, snapModel: snapModel, receipts: model.clipboardReceipt,
                            dictate: dictate, snap: snap, snapCapture: snapCapture, draw: draw, present: present, capture: capture)
        }
    }
}

/// A result's own controls, revealed from the toolbar's place (#134 T4). A result's message is
/// content, not only commands, so it keeps the view it had: a dictation that needs attention,
/// a reading that stopped. It opens only when the
/// person reveals the toolbar; revealing, collapsing or choosing a tool never dismisses,
/// acknowledges or retries it.
struct FloatingResultView: View {
    let result: FloatingResult
    @ObservedObject var model: AppModel
    @ObservedObject var controls: CaptureHUDControls
    var body: some View {
        switch result {
        case .dictationFailure: DictationResultView(model: model, controls: controls)
        case .readingFailure: ReadingStoppedView(model: model, controls: controls)
        }
    }
}

/// A reading that stopped because its audio could not be read keeps the reason, Retry and
/// Dismiss until the person does one of them. Pausing, resuming and stopping a live reading
/// are the toolbar row's next action and chooser (#134 T4); editing and voices stay in Workbench.
/// It grows from the launcher's centre like the row, so at a right-hand dock it is mirrored:
/// the reason sits over the mark the pointer came from, and Retry and Dismiss away from it
/// (#211 F3).
private struct ReadingStoppedView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controls: CaptureHUDControls
    enum Action: Hashable { case retry, dismiss }
    @FocusState private var focused: Action?
    var body: some View {
        if let failure = model.readingFailure { stopped(failure) }
    }

    private var firstAction: Action { model.canRetryReading ? .retry : .dismiss }

    private func stopped(_ failure: AppModel.ReadingFailure) -> some View {
        let mirrored = controls.rowAnchor.growsLeftward
        let reason = HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reading stopped").font(.system(size: 12, weight: .semibold))
                Text("Its audio could not be read.").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }.accessibilityElement(children: .combine).accessibilityLabel(failure.message).help(failure.message)
        }.accessibilitySortPriority(3)
        // Mirrored or not, VoiceOver reads the reason, then Retry, then Dismiss.
        let retry = Button("Retry") { model.retryReading() }.controlSize(.small).disabled(!model.canRetryReading)
            .accessibilityHint("Makes new audio and reads from the start")
            .focused($focused, equals: .retry).accessibilitySortPriority(2).resultAction("Retry", controls)
        let dismiss = Button { model.dismissReadingFailure() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            .accessibilityLabel("Dismiss reading error")
            .focused($focused, equals: .dismiss).accessibilitySortPriority(1).resultAction("Dismiss", controls)
        return HStack(spacing: 10) {
            if mirrored { dismiss; retry; Spacer(minLength: 4); reason }
            else { reason; Spacer(minLength: 4); retry; dismiss }
        }.padding(14).frame(width: CaptureHUDLayout.compact.width, height: CaptureHUDLayout.compact.height)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain).accessibilityLabel("Reading controls")
            .defaultFocus($focused, firstAction)
            .onAppear { ResultKeyboard.appeared(controls) { focused = firstAction } }
            .onExitCommand(perform: controls.endKeyboardInteraction)
            .workbenchTheme()
    }
}
