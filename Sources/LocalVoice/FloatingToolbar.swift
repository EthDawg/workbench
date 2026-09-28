import AppKit
import SwiftUI
import StageKit
import ToolbarCore
import ToolbarKit

/// One window owns idle tools, dictation, and narration. Starting an operation
/// never changes the user's choice to keep the idle toolbar visible.
enum FloatingToolbarSurface: Equatable {
    case hidden, tools, dictation, narration, reading

    static func resolve(enabled: Bool, capturingScreen: Bool, dictation: Bool, narration: Bool, reading: Bool = false) -> Self {
        if capturingScreen { return .hidden }
        if narration { return .narration }
        if dictation { return .dictation }
        if reading { return .reading }
        return enabled ? .tools : .hidden
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

    var viewState: ToolbarViewState {
        let live = self.live
        let action = ToolbarNextAction.resolve(live)
        return ToolbarViewState(name: "live", tier: controls.toolbar.state.tier,
            anchor: (controls.anchor ?? .bottom).toolbarAnchor,
            mode: live.mode, actionTitle: action.title, isActionEnabled: action.isEnabled,
            actionHint: action.hint(key: action.operation.keyMode.flatMap(key)),
            switcher: ToolbarNextAction.switcher(for: live, key: key),
            minimumTitles: ToolbarNextAction.titles(across: live),
            isBusy: live.isLive(live.mode))
    }

    private var detail: String {
        if let tool = model.toolbarMode.controlTool { return context.detail(tool) }
        return "Capture a region of the screen into Snap."
    }

    var body: some View {
        let state = viewState
        ToolbarRow(state: state, accent: Workbench.accent,
            openAccessory: { button in openPrompts(anchor: button, destination: controls.promptDestination?()) },
            action: performSelected, selectMode: { model.toolbarMode = $0 }, makeMenu: toolsMenu,
            menuBegan: controls.beginMenu, menuEnded: controls.endMenu,
            focusButton: { button in
                controls.focusFirstControl = { [weak button] in
                    guard let button else { return }
                    button.window?.makeFirstResponder(button)
                }
            }, escape: controls.endKeyboardInteraction, drag: controls.dragActions)
            // The host sizes its window from these reports (#152). A preference written
            // from a background GeometryReader never reached onPreferenceChange once the
            // row held conditional content, so every window kept its seed size.
            .onGeometryChange(for: ToolbarMeasurement.self) { ToolbarMeasurement(tier: state.tier, size: $0.size) } action: { measurement in
                // A row that opens revealed (Keep open at launch) has not drawn its resting
                // element yet. Measure it once, unseen, so a top or bottom dock centres on it.
                if measurement.tier == .revealed && !controls.hasMeasured(.resting) {
                    controls.reportRestingSize(NSHostingView(rootView: ToolbarRow(state: Self.resting(state))).fittingSize)
                }
                controls.reportSize(measurement.size, tier: measurement.tier)
            }
            .pinnedToDock(state.anchor)
            .help(detail)
            .tint(Workbench.accent).workbenchTheme()
    }

    private static func resting(_ state: ToolbarViewState) -> ToolbarViewState {
        var resting = state; resting.tier = .resting
        return resting
    }

    /// One Saved Prompts picker for the accessory and the glyph menu (#159). It
    /// freezes the field that was in front when it was asked for.
    private func openPrompts(anchor: NSView? = nil, frame: NSRect? = nil, destination: TextDelivery.Target?) {
        let context = PromptPickerController.Context(library: model.library, delivery: promptInsertion,
            receipts: model.clipboardReceipt, destination: destination, trusted: AXIsProcessTrusted(),
            controls: controls, openLibrary: { model.showLibrary() })
        if let anchor { PromptPickerController.shared.show(from: anchor, context: context) }
        else if let frame { PromptPickerController.shared.show(anchor: frame, context: context) }
    }

    /// Each operation goes to the owner that already does it. The toolbar never
    /// ends anything but what its label names.
    private func performSelected() {
        perform(ToolbarNextAction.resolve(live).operation)
    }

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

    /// The mode's own options, then the constant tail. Dictate, Read and Snap
    /// are start and stop here: their preparation stays in Workbench, one door
    /// away. Cross-mode finish items stay so nothing is a dead end.
    private func toolsMenu() -> NSMenu {
        let menu = NSMenu(title: "Workbench"); menu.autoenablesItems = false
        let live = self.live
        let action = ToolbarNextAction.resolve(live)
        let mode = live.mode
        let next = ToolbarMenuAction(action.title, enabled: action.isEnabled) { perform(action.operation) }
        Self.showKey(action.operation.keyMode.flatMap(key), on: next)
        menu.addItem(next)
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
        // Work running in another mode is never a dead end: its finish item
        // sits here, worded exactly as that mode's own label would be.
        if live.drawing && mode != .draw && action.operation != .finishDrawing {
            menu.addItem(ToolbarMenuAction("Stop drawing") { stage.finishDrawing() })
        }
        if live.presenting && mode != .present {
            menu.addItem(ToolbarMenuAction("End presentation") { stage.endDeviceScene() })
        }
        if live.persona != .none && mode != .persona {
            let personaFinish = live.persona == .session ? "Hide personas" : live.persona == .sessionHidden ? "Show personas" : "Hide persona"
            menu.addItem(ToolbarMenuAction(personaFinish) { stage.togglePersona() })
        }
        if live.meetingRecording && mode != .dictate {
            menu.addItem(ToolbarMenuAction("Stop transcribing") { Task { await meetings.stop() } })
        }
        menu.addItem(.separator())
        let position = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        let positions = NSMenu(); positions.autoenablesItems = false
        for anchor in FloatingControlAnchor.allCases {
            positions.addItem(ToolbarMenuAction(anchor.title, checked: controls.anchor == anchor) { controls.choosePosition?(anchor) })
        }
        position.submenu = positions; menu.addItem(position)
        menu.addItem(ToolbarMenuAction("Keep open", checked: controls.toolbar.state.keepsOpen) {
            controls.toolbar.send(.keepOpenChanged(!controls.toolbar.state.keepsOpen))
        })
        menu.addItem(ToolbarMenuAction("Hide toolbar") { model.floatingToolbarVisible = false })
        menu.addItem(ToolbarMenuAction("Settings…") { model.onShowEditor?("settings") })
        return menu
    }

    /// Move a builder's items into this menu, so the mode's options sit at the
    /// top level instead of behind a wrapper named after the mode.
    private static func inline(_ source: NSMenu, into menu: NSMenu) {
        for item in source.items { source.removeItem(item); menu.addItem(item) }
    }

    /// Show an assigned key beside the item, from the same label the hint uses.
    /// Keys the menu cannot spell (function and arrow keys) are left off.
    static func showKey(_ label: String?, on item: NSMenuItem) {
        guard var keys = label else { return }
        var mask: NSEvent.ModifierFlags = []
        let modifiers: [(Character, NSEvent.ModifierFlags)] = [("⌃", .control), ("⌥", .option), ("⇧", .shift), ("⌘", .command)]
        for (symbol, flag) in modifiers where keys.first == symbol {
            mask.insert(flag); keys.removeFirst()
        }
        for (symbol, flag) in modifiers where keys.first == symbol {
            mask.insert(flag); keys.removeFirst()
        }
        let equivalent = keys == "Space" ? " " : keys.count == 1 ? keys.lowercased() : nil
        guard let equivalent else { return }
        item.keyEquivalent = equivalent
        item.keyEquivalentModifierMask = mask
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
        } else if model.rendering || model.playing || model.paused {
            ReadingControls(model: model)
        } else {
            FloatingToolbar(model: model, readback: readback, stage: stage, controls: controls, promptInsertion: model.promptInsertion,
                            meetings: model.meetings, snapModel: snapModel, dictate: dictate, snap: snap, snapCapture: snapCapture, draw: draw, present: present)
        }
    }
}

/// Reading only needs its active transport. Editing and voice choices stay in
/// Workbench; there is no second reading editor hidden behind this surface.
private struct ReadingControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
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
