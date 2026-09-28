import AppKit
import SwiftUI
import StageKit
import ToolbarCore
import ToolbarKit

/// One window owns the tools, dictation, and narration. Starting an operation
/// never changes the user's choice to show the toolbar.
enum FloatingToolbarSurface: Equatable {
    case hidden, tools, dictation, narration, reading

    static func resolve(enabled: Bool, capturingScreen: Bool, dictation: Bool, narration: Bool, reading: Bool = false) -> Self {
        if capturingScreen { return .hidden }
        if narration { return .narration }
        if dictation { return .dictation }
        if reading { return .reading }
        return enabled ? .tools : .hidden
    }

    /// Hide toolbar is authoritative for the tools (#155). Drawing, a presentation and
    /// personas are deliberately not consulted: they carry on without the tools, reachable
    /// by their keys and the menu-bar panel, and Show floating toolbar brings the tools back
    /// with their live state. A prompt insertion keeps the tools until it ends, because its
    /// Stop is there. Recording, processing, narration and reading keep their own surfaces.
    static func resolve(shown: Bool, drawing: Bool, presenting: Bool, persona: Bool, inserting: Bool,
                        capturingScreen: Bool, dictation: Bool, narration: Bool, reading: Bool) -> Self {
        resolve(enabled: shown || inserting, capturingScreen: capturingScreen,
                dictation: dictation, narration: narration, reading: reading)
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
    let dictate: () -> Void
    let snap: () -> Void
    let snapCapture: () -> Void
    let draw: () -> Void
    let present: () -> Void
    private var context: WorkbenchControlContext { .init(model: model, readback: readback, stage: stage, snap: snapModel) }

    /// The same frozen value the panel's rows read, for the selected mode.
    var live: ToolbarLiveState { context.state.live(model.toolbarMode) }

    /// The assigned key for a mode, or nil when it is off or failed: an
    /// unusable binding is omitted rather than shown as text nobody can use.
    private func key(_ mode: ToolbarMode) -> String? {
        guard let tool = mode.controlTool else { return nil }
        switch context.shortcut(tool) {
        case "Shortcut off", "Shortcut unavailable", nil: return nil
        case .some(let keys): return keys
        }
    }

    /// What the owners say is going on, for the compact rest's indicator (#134).
    var activity: ToolbarActivity { context.activity(snapAndTalkSequence: controls.snapAndTalkSequence) }

    var viewState: ToolbarViewState {
        let live = self.live
        let action = ToolbarNextAction.resolve(live)
        return ToolbarViewState(name: "live", tier: controls.toolbar.state.tier,
            anchor: controls.rowAnchor,
            mode: live.mode, actionTitle: action.title, isActionEnabled: action.isEnabled,
            actionHint: action.hint(key: action.operation.keyMode.flatMap(key)),
            choices: ToolbarNextAction.choices(for: live, key: key),
            minimumTitles: ToolbarNextAction.titles(across: live),
            isBusy: live.isLive(live.mode),
            status: .resolve(activity), showsAccessory: controls.accessoryFits)
    }

    private var detail: String {
        if let tool = model.toolbarMode.controlTool { return context.detail(tool) }
        return "Capture a region of the screen into Snap."
    }

    var body: some View {
        let state = viewState
        let operation = ToolbarNextAction.resolve(live).operation
        ToolbarRow(state: state, accent: Workbench.accent,
            openAccessory: { button in openPrompts(anchor: button, destination: controls.promptDestination?()) },
            press: pressPrimary, openChooser: { launcher in controls.openChooser?(launcher, state.choices) },
            makeMenu: moreMenu, menuBegan: controls.beginMenu, menuEnded: controls.endMenu,
            focusButton: { button in
                controls.focusFirstControl = { [weak button] in
                    guard let button else { return }
                    button.window?.makeFirstResponder(button)
                }
            }, escape: controls.endKeyboardInteraction, revealFromRest: { controls.revealFromRest?() }, drag: controls.dragActions)
            // The host sizes its window from these reports (#152). A preference written
            // from a background GeometryReader never reached onPreferenceChange once the
            // row held conditional content, so every window kept its seed size.
            .onGeometryChange(for: ToolbarMeasurement.self) { ToolbarMeasurement(tier: state.tier, size: $0.size) } action: { measurement in
                controls.reportSize(measurement.size, tier: measurement.tier)
            }
            // Each change of the next action is a new generation, so a press latched on the
            // old one cannot act on the new one (#134).
            .onChange(of: operation, initial: true) { _, operation in controls.pressGate.shown(operation) }
            .onChange(of: state.choices) { _, choices in controls.chooserChoicesChanged?(choices) }
            .onChange(of: state.status, initial: true) { previous, status in controls.statusChanged(from: previous, to: status) }
            .pinnedToDock(state.anchor)
            .help(detail)
            .tint(Workbench.accent).workbenchTheme()
    }

    /// Latches the next action as the button goes down (#134). The click then acts only if
    /// the same operation, in the same generation, is still the next action when it comes up,
    /// so a Stop that completes while pressed is discarded rather than becoming a Start; and a
    /// press on a label that changed since the last redraw does nothing. Internal so the host
    /// checks can press it through a completion.
    func pressPrimary() -> (() -> Void)? {
        controls.pressGate.press({ ToolbarNextAction.resolve(live) }, perform: perform)
    }

    /// One Saved Prompts picker for the accessory and More (#159). It
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

    /// More (#134): the tool's own options, then the work running elsewhere, then the
    /// toolbar's own items. The next action is the row's primary, not repeated here. Dictate,
    /// Read and Snap are start and stop on the row: their preparation stays in Workbench, one
    /// door away. A right-click on the launcher or the compact rest opens the same menu.
    private func moreMenu() -> NSMenu {
        let menu = NSMenu(title: "More"); menu.autoenablesItems = false
        let live = self.live
        let action = ToolbarNextAction.resolve(live)
        let mode = live.mode
        switch mode {
        case .dictate:
            menu.addItem(ToolbarMenuAction("Open Dictate…") { model.onShowEditor?("dictate") })
        case .read:
            menu.addItem(ToolbarMenuAction("Open Read…") { model.onShowEditor?("speak") })
        case .snap:
            menu.addItem(ToolbarMenuAction("Open Snap…") { model.onShowEditor?("snap") })
        case .snapAndTalk:
            menu.addItem(ToolbarMenuAction("Review Snap & Talk · \(readback.activeSections.count) Captures…") { model.onShowEditor?("readback") })
        case .draw:
            Self.inline(stage.makeAnnotationMenu(includeSettings: false), into: menu)
        case .present:
            Self.inline(stage.makePresentationMenu(), into: menu)
            // The picker opens once this menu has closed, for the field in front now.
            let destination = controls.promptDestination?(), toolbarFrame = NSApp.currentEvent?.window?.frame
            menu.addItem(ToolbarMenuAction("Saved Prompts…") {
                controls.toolbar.afterMenuTracking { if let toolbarFrame { openPrompts(frame: toolbarFrame, destination: destination) } }
            })
            menu.addItem(ToolbarMenuAction("Switch to Browser Tab…") { model.onShowPresenter?() })
        case .persona:
            Self.inline(stage.makePersonaMenu(), into: menu)
        }
        // Work running in another tool is never a dead end: whatever the compact mark shows has
        // its finish, resume or door under Active work, worded as that tool's own label would be.
        let active: [NSMenuItem] = ToolbarActiveWork.items(activeWorkFacts(action: action)).map { item in
            switch item {
            case .stopDrawing: return ToolbarMenuAction("Stop drawing") { stage.finishDrawing() }
            case .endPresentation: return ToolbarMenuAction("End presentation") { stage.endDeviceScene() }
            case .persona(let title): return ToolbarMenuAction(title) { stage.togglePersona() }
            case .stopTranscribing: return ToolbarMenuAction("Stop transcribing") { Task { await meetings.stop() } }
            case .meetingRecovery:
                return ToolbarMenuAction("Transcribe meeting or call…") { model.page = "meeting"; model.onShowEditor?("meeting") }
            case .snapDraft: return ToolbarMenuAction("Open Snap…") { model.onShowEditor?("snap") }
            case .timer(let transport): return ToolbarMenuAction(transport.title + " timer") { stage.performTimerTransport() }
            }
        }
        if !active.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: "Active work"))
            active.forEach(menu.addItem)
        }
        menu.addItem(.separator())
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

    /// What the owners say for More's Active work section, read when More opens.
    func activeWorkFacts(action: ToolbarNextAction) -> ToolbarActiveWork.Facts {
        let live = self.live
        return ToolbarActiveWork.Facts(mode: live.mode, nextAction: action.operation, drawing: live.drawing, presenting: live.presenting,
            persona: live.persona, meetingRecording: live.meetingRecording,
            meetingRecovery: meetings.hasRecovery && !meetings.isBusy, snapDraft: snapModel.draft != nil, timer: stage.timerTransport)
    }

    /// Move a builder's items into this menu, so the mode's options sit at the
    /// top level instead of behind a wrapper named after the mode.
    private static func inline(_ source: NSMenu, into menu: NSMenu) {
        for item in source.items { source.removeItem(item); menu.addItem(item) }
    }

    static func shortcutLabel(_ shortcut: VoiceShortcut, failure: String?) -> String {
        if !shortcut.enabled { return "Shortcut off" }
        if failure != nil { return "Shortcut unavailable" }
        return shortcut.label
    }
}

private struct ToolbarMeasurement: Equatable {
    var tier: ToolbarTier
    var size: CGSize
}

struct WorkbenchFloatingContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var readback: ReadbackModel
    @ObservedObject var stage: StageKitController
    @ObservedObject var controls: CaptureHUDControls
    let snapModel: SnapModel
    let dictate: () -> Void
    let snap: () -> Void
    let snapCapture: () -> Void
    let draw: () -> Void
    let present: () -> Void

    var body: some View {
        if readback.isRecording {
            ReadbackHUDView(model: readback, controls: controls)
        } else if CapturePanelController.showsDictation(model) {
            RecordingOverlay(model: model, controls: controls,
                finishDrawing: stage.isDrawing ? { stage.finishDrawing() } : nil)
        } else if model.rendering || model.playing || model.paused || model.readingFailure != nil {
            ReadingControls(model: model)
        } else {
            FloatingToolbar(model: model, readback: readback, stage: stage, controls: controls, promptInsertion: model.promptInsertion,
                            meetings: model.meetings, snapModel: snapModel, dictate: dictate, snap: snap, snapCapture: snapCapture, draw: draw, present: present)
        }
    }
}

/// Reading only needs its active transport. Editing and voice choices stay in
/// Workbench; there is no second reading editor hidden behind this surface.
/// A reading that stopped because its audio could not be read stays here with
/// the reason, Retry and Dismiss until the person does one of them.
private struct ReadingControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let failure = model.readingFailure, !model.rendering, !model.playing, !model.paused {
            stopped(failure)
        } else {
            transport
        }
    }

    private func stopped(_ failure: AppModel.ReadingFailure) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reading stopped").font(.system(size: 12, weight: .semibold))
                Text("Its audio could not be read.").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }.accessibilityElement(children: .combine).accessibilityLabel(failure.message).help(failure.message)
            Spacer(minLength: 4)
            Button("Retry") { model.retryReading() }.controlSize(.small).disabled(!model.canRetryReading)
                .accessibilityHint("Makes new audio and reads from the start")
            Button { model.dismissReadingFailure() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                .accessibilityLabel("Dismiss reading error")
        }.padding(14).frame(width: 336, height: 64)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain).accessibilityLabel("Reading controls")
            .workbenchTheme()
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2").foregroundStyle(Workbench.accent)
            Text(model.rendering ? "Preparing Reading" : model.paused ? "Reading Paused" : "Reading")
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 4)
            if !model.rendering {
                Button(model.paused ? "Resume" : "Pause") { model.listen() }.controlSize(.small)
            }
            Button(model.rendering ? "Cancel" : "Stop") {
                if model.rendering { model.cancelReading() } else { model.stopPlayback() }
            }.controlSize(.small)
        }.padding(14).frame(width: 336, height: 64)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain).accessibilityLabel("Reading controls")
            .workbenchTheme()
    }
}
