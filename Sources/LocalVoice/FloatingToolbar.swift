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

struct FloatingToolbar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var readback: ReadbackModel
    @ObservedObject var stage: StageKitController
    @ObservedObject var controls: CaptureHUDControls
    @ObservedObject var promptInsertion: PromptInsertion
    let dictate: () -> Void
    let snap: () -> Void
    let draw: () -> Void
    let present: () -> Void
    private var context: WorkbenchControlContext { .init(model: model, readback: readback, stage: stage) }

    var viewState: ToolbarViewState {
        let tool = model.controlTool
        let coreTool: ToolbarTool
        switch tool {
        case .dictate: coreTool = .dictate
        case .snap: coreTool = .snapAndTalk
        case .annotate: coreTool = .annotate
        case .present: coreTool = .present
        case .read: coreTool = .read
        case .persona: coreTool = .persona
        case .timer: coreTool = .timer
        }
        let shortcut: ToolbarShortcut
        switch context.shortcut(tool) {
        case "Shortcut off", nil: shortcut = .off
        case "Shortcut unavailable": shortcut = .unavailable
        case .some(let keys): shortcut = .assigned(keys)
        }
        var trailing: ToolbarTrailing = shortcut.isUsable ? .shortcut(shortcut) : .status("")
        var busy = false
        var title = context.state.actionTitle(tool)
        switch tool {
        case .dictate:
            title = model.canRecordAgain ? "Record again" : "Dictate"
        case .snap:
            if readback.hasPendingTranscriptions { trailing = .status("\(readback.activeSections.count) · Saving"); busy = true }
            else if readback.sessionURL != nil { trailing = .status("\(readback.activeSections.count) Captures" + (shortcut.isUsable ? " · " + shortcut.label : "")) }
        case .annotate:
            if stage.isDrawing { trailing = .status("Drawing"); busy = true }
            else { title = "Draw" }
        case .present:
            if stage.isPresenting { trailing = .status("Presenting"); busy = true }
            else { title = "Present" }
        case .persona:
            trailing = .status(stage.personaStatus); busy = stage.hasActivePersona
        case .timer:
            trailing = .status(stage.hasTimerSession ? stage.timerText : ""); busy = stage.hasActiveTimer
        case .read:
            if model.rendering { trailing = .status("Preparing audio"); busy = true }
            else if model.playing || model.paused {
                title = "Stop reading"; trailing = .status(model.paused ? "Paused" : "Reading"); busy = true
            } else { title = "Read aloud" }
        }
        if promptInsertion.running { title = "Stop Inserting"; trailing = .status("Inserting Prompt"); busy = true }
        return ToolbarViewState(name: "live", tier: controls.toolbar.state.tier,
            anchor: (controls.anchor ?? .bottom).toolbarAnchor,
            tool: coreTool, actionTitle: title, isActionEnabled: promptInsertion.running || context.state.enabled(tool),
            trailing: trailing, isBusy: busy)
    }

    var body: some View {
        let state = viewState
        ToolbarRow(state: state, accent: Workbench.accent,
            makeAccessoryMenu: { SavedPromptMenu.make(library: model.library, delivery: promptInsertion, target: controls.promptDestination?(), prepare: controls.endKeyboardInteraction) },
            action: performSelected, makeMenu: toolsMenu,
            menuBegan: controls.beginMenu, menuEnded: controls.endMenu,
            focusButton: { button in
                controls.focusFirstControl = { [weak button] in
                    guard let button else { return }
                    button.window?.makeFirstResponder(button)
                }
            }, escape: controls.endKeyboardInteraction, drag: controls.dragActions)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: ToolbarMeasuredSize.self, value: ToolbarMeasurement(tier: state.tier, size: geometry.size))
            })
            .onPreferenceChange(ToolbarMeasuredSize.self) { measurement in controls.reportSize(measurement.size, tier: measurement.tier) }
            .pinnedToDock(state.anchor)
            .help(context.detail(model.controlTool))
            .tint(Workbench.accent).workbenchTheme()
    }

    private func performSelected() {
        if promptInsertion.running { promptInsertion.cancel(); return }
        switch model.controlTool {
        case .dictate: dictate()
        case .snap: snap()
        case .annotate: draw()
        case .present: present()
        case .persona: stage.togglePersona()
        case .timer: stage.showTimer()
        case .read:
            if model.rendering { model.cancelReading() }
            else if model.playing || model.paused { model.stopPlayback() }
            else { model.onShowEditor?("speak") }
        }
    }

    private func toolsMenu() -> NSMenu {
        let menu = NSMenu(title: "Workbench"); menu.autoenablesItems = false
        menu.addItem(ToolbarMenuAction(viewState.actionTitle, enabled: viewState.isActionEnabled, run: performSelected))
        let tools = NSMenuItem(title: "Change tool", action: nil, keyEquivalent: "")
        let choices = NSMenu(); choices.autoenablesItems = false
        for tool in [WorkbenchControlTool.snap, .annotate, .present, .persona] {
            choices.addItem(ToolbarMenuAction(tool.title, checked: model.controlTool == tool) { model.controlTool = tool })
        }
        tools.submenu = choices; menu.addItem(tools)
        // Independent jobs stay available in a fixed order. Opening these
        // controls neither selects another tool nor resets its active state.
        if model.controlTool == .snap {
            menu.addItem(ToolbarMenuAction("Review Snap & Talk · \(readback.activeSections.count) Captures…") { model.onShowEditor?("readback") })
        }
        let presentation = NSMenuItem(title: "Present", action: nil, keyEquivalent: "")
        presentation.submenu = stage.makePresentationMenu(); menu.addItem(presentation)
        let personas = NSMenuItem(title: "Persona Overlay", action: nil, keyEquivalent: "")
        personas.submenu = stage.makePersonaMenu(); menu.addItem(personas)
        let drawing = NSMenuItem(title: "Draw", action: nil, keyEquivalent: "")
        drawing.submenu = stage.makeAnnotationMenu(includeSettings: false); menu.addItem(drawing)
        let prompts = NSMenuItem(title: "Saved Prompts", action: nil, keyEquivalent: "")
        prompts.submenu = SavedPromptMenu.make(library: model.library, delivery: promptInsertion, target: controls.promptDestination?(), prepare: controls.endKeyboardInteraction)
        menu.addItem(prompts)
        menu.addItem(ToolbarMenuAction("Switch to Browser Tab…") { model.onShowPresenter?() })
        if stage.isDrawing && model.controlTool != .annotate {
            menu.addItem(ToolbarMenuAction("Done drawing · keep marks") { stage.finishDrawing() })
        }
        if stage.isPresenting && model.controlTool != .present {
            menu.addItem(ToolbarMenuAction("End device scene") { stage.endDeviceScene() })
        }
        if (model.playing || model.paused) && model.controlTool != .read {
            menu.addItem(ToolbarMenuAction("Stop reading") { model.stopPlayback() })
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
private struct ToolbarMeasuredSize: PreferenceKey {
    static var defaultValue = ToolbarMeasurement(tier: .resting, size: .zero)
    static func reduce(value: inout ToolbarMeasurement, nextValue: () -> ToolbarMeasurement) { value = nextValue() }
}

struct WorkbenchFloatingContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var readback: ReadbackModel
    @ObservedObject var stage: StageKitController
    @ObservedObject var controls: CaptureHUDControls
    let dictate: () -> Void
    let snap: () -> Void
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
                            dictate: dictate, snap: snap, draw: draw, present: present)
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
