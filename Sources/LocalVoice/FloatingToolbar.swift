import AppKit
import SwiftUI
import StageKit
import ToolbarCore
import ToolbarKit

/// One window owns idle tools, dictation, and narration. Starting an operation
/// never changes the user's choice to keep the idle toolbar visible.
enum FloatingToolbarSurface: Equatable {
    case hidden, tools, dictation, narration

    static func resolve(enabled: Bool, capturingScreen: Bool, dictation: Bool, narration: Bool) -> Self {
        if capturingScreen { return .hidden }
        if narration { return .narration }
        if dictation { return .dictation }
        return enabled ? .tools : .hidden
    }
}

struct FloatingToolbar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var readback: ReadbackModel
    @ObservedObject var stage: StageKitController
    @ObservedObject var controls: CaptureHUDControls
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
        }
        let shortcut: ToolbarShortcut
        switch context.shortcut(tool) {
        case "Shortcut off", nil: shortcut = .off
        case "Shortcut unavailable": shortcut = .unavailable
        case .some(let keys): shortcut = .assigned(keys)
        }
        var trailing = ToolbarTrailing.shortcut(shortcut)
        var busy = false
        var title = context.state.actionTitle(tool)
        switch tool {
        case .dictate:
            title = model.canRecordAgain ? "Record again" : "Dictate"
        case .snap:
            if readback.hasPendingTranscriptions { trailing = .status("Transcribing"); busy = true }
        case .annotate:
            if stage.isDrawing { trailing = .status("Drawing"); busy = true }
            else { title = "Draw" }
        case .present:
            if stage.isPresenting { trailing = .status("Presenting"); busy = true }
            else { title = "Present" }
        case .read:
            if model.rendering { trailing = .status("Preparing audio"); busy = true }
            else if model.playing || model.paused {
                title = "Stop reading"; trailing = .status(model.paused ? "Paused" : "Reading"); busy = true
            } else { title = "Read aloud" }
        }
        return ToolbarViewState(name: "live", tier: controls.toolbar.state.tier,
            anchor: (controls.anchor ?? .bottom).toolbarAnchor,
            tool: coreTool, actionTitle: title, isActionEnabled: context.state.enabled(tool),
            trailing: trailing, isBusy: busy)
    }

    var body: some View {
        let state = viewState
        ToolbarRow(state: state, accent: Workbench.accent, action: performSelected, makeMenu: toolsMenu,
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
            .help(context.detail(model.controlTool))
            .tint(Workbench.accent).workbenchTheme()
    }

    private func makeModeMenu() -> NSMenu {
        let menu = NSMenu(title: "Text style"); menu.autoenablesItems = false
        menu.addItem(ToolbarMenuAction("Text style for the next dictation", enabled: false) {})
        for style in CleanupStyle.allCases {
            let item = ToolbarMenuAction(style.rawValue, checked: model.preferences.cleanup == style) {
                guard model.phase == .idle, !readback.isRecording else { return }
                model.preferences.cleanup = style
            }
            item.toolTip = style.detail; menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ToolbarMenuAction("Destination for the next dictation", enabled: false) {})
        for delivery in DeliveryMode.allCases {
            menu.addItem(ToolbarMenuAction(delivery.rawValue, checked: model.preferences.delivery == delivery) {
                guard model.phase == .idle, !readback.isRecording else { return }
                model.preferences.delivery = delivery
            })
        }
        menu.addItem(.separator())
        menu.addItem(ToolbarMenuAction("Dictation settings…") { model.onShowEditor?("dictate") })
        return menu
    }

    private func performSelected() {
        switch model.controlTool {
        case .dictate: dictate()
        case .snap: snap()
        case .annotate: draw()
        case .present: present()
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
        for tool in WorkbenchControlTool.allCases {
            choices.addItem(ToolbarMenuAction(tool.title, checked: model.controlTool == tool) { model.controlTool = tool })
        }
        tools.submenu = choices; menu.addItem(tools)
        switch model.controlTool {
        case .dictate:
            let item = NSMenuItem(title: "Dictation options", action: nil, keyEquivalent: "")
            item.submenu = makeModeMenu(); menu.addItem(item)
        case .annotate:
            let item = NSMenuItem(title: "Drawing tools", action: nil, keyEquivalent: "")
            item.submenu = stage.makeAnnotationMenu(); menu.addItem(item)
        case .snap:
            let count = readback.activeSections.count
            let title = readback.sessionURL == nil ? "Review Snap & Talk…"
                : "Review Snap & Talk · \(count) " + (count == 1 ? "capture…" : "captures…")
            menu.addItem(ToolbarMenuAction(title) { model.onShowEditor?("readback") })
        case .present: menu.addItem(ToolbarMenuAction("Choose a scene…") { model.onShowEditor?("present") })
        case .read: menu.addItem(ToolbarMenuAction("Reading options…") { model.onShowEditor?("speak") })
        }
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
        menu.addItem(ToolbarMenuAction("Keyboard shortcuts…") { model.onShowEditor?("shortcuts") })
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
        } else {
            FloatingToolbar(model: model, readback: readback, stage: stage, controls: controls,
                            dictate: dictate, snap: snap, draw: draw, present: present)
        }
    }
}
