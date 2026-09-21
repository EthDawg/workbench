import AppKit
import SwiftUI
import StageKit

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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var disclosure: FloatingToolbarDisclosure { controls.toolbarDisclosure }
    private var context: WorkbenchControlContext { .init(model: model, readback: readback, stage: stage) }
    private var canDictate: Bool { context.state.enabled(.dictate) }
    private var selectedActionTitle: String {
        if model.controlTool == .dictate && model.phase == .idle { return model.canRecordAgain ? "Record again" : "Dictate" }
        return context.state.actionTitle(model.controlTool)
    }

    var body: some View {
        ZStack {
            Group {
                switch disclosure {
                case .collapsed: resting
                case .hovered: revealed
                case .expanded: expanded
                }
            }
            .frame(width: controls.preferredToolbarSize.width, height: controls.preferredToolbarSize.height)
            .id(disclosure)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
        .frame(width: controls.toolbarSize.width, height: controls.toolbarSize.height)
        .background {
            if reduceTransparency { RoundedRectangle(cornerRadius: radius).fill(Color(nsColor: .windowBackgroundColor)) }
            else { RoundedRectangle(cornerRadius: radius).fill(.regularMaterial) }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.primary.opacity(0.12)))
        .contentShape(RoundedRectangle(cornerRadius: radius))
        .onExitCommand { controls.collapseToolbar() }
        .tint(Workbench.accent).workbenchTheme()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workbench floating toolbar")
    }

    private var radius: CGFloat { min(18, controls.toolbarSize.width / 2, controls.toolbarSize.height / 2) }

    private var resting: some View {
        Button { controls.expandToolbar() } label: {
            let layout = controls.isSideDocked ? AnyLayout(VStackLayout(spacing: 9)) : AnyLayout(HStackLayout(spacing: 9))
            layout {
                Image(systemName: stage.isDrawing ? "pencil.tip" : stage.isPresenting ? "iphone" : model.controlTool.symbol)
                    .font(.system(size: 12, weight: .medium))
                Capsule().fill(.secondary.opacity(0.55))
                    .frame(width: controls.isSideDocked ? 3 : 22, height: controls.isSideDocked ? 22 : 3)
            }.foregroundStyle(.secondary)
                .frame(width: controls.preferredToolbarSize.width, height: controls.preferredToolbarSize.height)
                .contentShape(Capsule())
        }.buttonStyle(.plain)
            .accessibilityLabel("Expand Workbench toolbar")
            .help("Workbench · " + status + ". Hover for quick actions, or click to keep all tools open.")
    }

    private var revealed: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                toolMenu.frame(width: 70, height: 24)
                Text(model.controlTool == .snap ? "\(readback.activeSections.count) captures" : status == "Ready when you are" ? "Ready" : status)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85).help(status)
                    .frame(width: 70, alignment: .leading)
            }.frame(width: 70)
            Divider().frame(height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Button(selectedActionTitle, action: performSelected)
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                    .disabled(!context.state.enabled(model.controlTool))
                Button(context.shortcut(model.controlTool) ?? "Options…") {
                    model.onShowEditor?(context.shortcut(model.controlTool) == nil ? model.controlTool.page : "shortcuts")
                }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("View controls and change keyboard shortcuts")
            }.frame(maxWidth: .infinity, alignment: .leading)
            expandButton
        }.padding(.horizontal, 8)
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    FloatingToolbarMenu(title: "Workbench", symbol: "square.stack.3d.up.fill",
                        help: "Workbench toolbar menu", controls: controls, focusOnReveal: true, makeMenu: toolsMenu)
                        .frame(width: 104, height: 22)
                    PanelDragHandle(accessibilityLabel: "Move toolbar by dragging this empty space; positions are also in the menu", showsGrip: false)
                        .frame(maxWidth: .infinity).frame(height: 24)
                    Text(status == "Ready when you are" ? "Ready" : status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).help(status)
                    Button { controls.collapseToolbar() } label: {
                        Image(systemName: "minus").frame(width: 26, height: 24)
                    }.buttonStyle(.plain).help("Collapse to the quiet indicator")
                        .accessibilityLabel("Collapse Workbench toolbar")
                }
                HStack(spacing: 7) {
                    Button(selectedActionTitle, action: performSelected)
                        .buttonStyle(.borderedProminent).disabled(!context.state.enabled(model.controlTool))
                    Spacer(minLength: 0)
                    if model.controlTool == .dictate { modeMenu.frame(width: 86, height: 24) }
                    else if model.controlTool == .annotate {
                        FloatingToolbarMenu(title: "Tools", symbol: "", help: "Drawing tools, ink and shortcuts",
                            controls: controls, makeMenu: { stage.makeAnnotationMenu() }).frame(width: 52, height: 24)
                    }
                    else {
                        Button(model.controlTool == .snap ? "Review" : "Options") { model.onShowEditor?(model.controlTool.page) }
                            .buttonStyle(.borderless)
                    }
                }.controlSize(.small).font(.system(size: 11))
                HStack(spacing: 5) {
                    Text(context.detail(model.controlTool)).lineLimit(1).help(context.detail(model.controlTool))
                    Spacer(minLength: 0)
                    if let shortcut = context.shortcut(model.controlTool) {
                        Button(shortcut) { model.onShowEditor?("shortcuts") }.buttonStyle(.plain).fixedSize()
                            .help("View or change keyboard shortcuts")
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.horizontal, 10)
    }

    private var expandButton: some View {
        Button { controls.expandToolbar() } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 28, height: 32)
        }.buttonStyle(.plain).help("Expand and keep all tools open")
            .accessibilityLabel("Expand Workbench toolbar")
    }

    private var modeMenu: some View {
        FloatingToolbarMenu(title: model.preferences.cleanup.rawValue, symbol: "slider.horizontal.3",
            help: "Text style for the next dictation: " + model.preferences.cleanup.rawValue,
            controls: controls, enabled: model.phase == .idle && !readback.isRecording,
            makeMenu: makeModeMenu)
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

    private var toolMenu: some View {
        FloatingToolbarMenu(title: "Change", symbol: "chevron.down",
            help: "Change tool. Running activities continue.", controls: controls, makeMenu: makeToolMenu)
    }
    private func makeToolMenu() -> NSMenu {
        let menu = NSMenu(title: "Change tool"); menu.autoenablesItems = false
        for tool in WorkbenchControlTool.allCases {
            menu.addItem(ToolbarMenuAction(tool.title, checked: model.controlTool == tool) { model.controlTool = tool })
        }
        addActiveActions(to: menu)
        menu.addItem(.separator())
        menu.addItem(ToolbarMenuAction("Keyboard shortcuts…") { model.onShowEditor?("shortcuts") })
        return menu
    }
    private func addActiveActions(to menu: NSMenu) {
        guard stage.isPresenting || stage.isDrawing || model.playing else { return }
        menu.addItem(.separator())
        if stage.isDrawing { menu.addItem(ToolbarMenuAction("Done drawing · keep marks") { stage.finishDrawing() }) }
        if stage.isPresenting { menu.addItem(ToolbarMenuAction("End device scene") { stage.endDeviceScene() }) }
        if model.playing { menu.addItem(ToolbarMenuAction("Stop reading") { model.stopPlayback() }) }
    }
    private func performSelected() {
        switch model.controlTool {
        case .dictate: dictate()
        case .snap: snap()
        case .annotate: draw()
        case .present: present()
        case .read:
            if model.rendering { model.cancelReading() }
            else if model.playing || model.paused { model.listen() }
            else { model.onShowEditor?("speak") }
        }
    }

    private func toolsMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(ToolbarMenuAction("Dictate · " + shortcutLabel(1), enabled: canDictate, run: dictate))
        menu.addItem(ToolbarMenuAction("Snap & Talk · " + shortcutLabel(5), enabled: context.state.enabled(.snap), run: snap))
        menu.addItem(ToolbarMenuAction(stage.isDrawing ? "Done drawing" : "Draw", enabled: context.state.enabled(.annotate), run: draw))
        menu.addItem(ToolbarMenuAction(stage.isPresenting ? "End scene" : "Present", enabled: context.state.enabled(.present), run: present))
        let tools = NSMenuItem(title: "Change tool", action: nil, keyEquivalent: "")
        tools.submenu = makeToolMenu(); menu.addItem(tools)
        let mode = NSMenuItem(title: "Text style · " + model.preferences.cleanup.rawValue, action: nil, keyEquivalent: "")
        mode.submenu = makeModeMenu(); menu.addItem(mode)
        menu.addItem(.separator())
        for (title, page) in [("Open Workbench", "home"), ("Read aloud…", "speak"),
                              ("Review Snap & Talk…", "readback"), ("Choose a scene…", "present")] {
            menu.addItem(ToolbarMenuAction(title) { model.onShowEditor?(page) })
        }
        menu.addItem(ToolbarMenuAction("Switch to browser tab…") { model.onShowPresenter?() })
        menu.addItem(ToolbarMenuAction("Break timer") { stage.showTimer() })
        menu.addItem(ToolbarMenuAction("Overlay cards…") { stage.showPersonas() })
        menu.addItem(.separator())
        let position = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        let positions = NSMenu(); positions.autoenablesItems = false
        for anchor in FloatingControlAnchor.allCases {
            positions.addItem(ToolbarMenuAction(anchor.title, checked: controls.anchor == anchor) { controls.choosePosition?(anchor) })
        }
        position.submenu = positions; menu.addItem(position)
        menu.addItem(ToolbarMenuAction("Collapse toolbar") { controls.collapseToolbar() })
        menu.addItem(ToolbarMenuAction("Hide floating toolbar") { model.floatingToolbarVisible = false })
        menu.addItem(ToolbarMenuAction("Keyboard shortcuts…") { model.onShowEditor?("shortcuts") })
        menu.addItem(ToolbarMenuAction("Settings…") { model.onShowEditor?("settings") })
        return menu
    }

    private func shortcutLabel(_ id: UInt32) -> String {
        Self.shortcutLabel(model.preferences.shortcut(id), failure: model.shortcutFailures[id])
    }
    static func shortcutLabel(_ shortcut: VoiceShortcut, failure: String?) -> String {
        if !shortcut.enabled { return "Shortcut off" }
        if failure != nil { return "Shortcut unavailable" }
        return shortcut.label
    }
    private var status: String {
        context.activitySummary
    }

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
