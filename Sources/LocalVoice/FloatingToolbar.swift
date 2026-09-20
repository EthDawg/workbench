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
    private var canDictate: Bool { model.ready && !model.rendering && !readback.blocksDictation }

    var body: some View {
        Group {
            switch disclosure {
            case .collapsed: resting
            case .hovered: revealed
            case .expanded: expanded
            }
        }
        .frame(width: disclosure.size.width, height: disclosure.size.height)
        .background {
            if reduceTransparency { RoundedRectangle(cornerRadius: radius).fill(Color(nsColor: .windowBackgroundColor)) }
            else { RoundedRectangle(cornerRadius: radius).fill(.regularMaterial) }
        }
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.primary.opacity(0.12)))
        .contentShape(RoundedRectangle(cornerRadius: radius))
        .onHover { controls.hover($0) }
        .onExitCommand { controls.collapseToolbar() }
        .transaction { $0.animation = nil }
        .tint(Workbench.accent).workbenchTheme()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workbench floating toolbar")
    }

    private var radius: CGFloat { disclosure == .collapsed ? 14 : 18 }

    private var resting: some View {
        Button { controls.expandToolbar() } label: {
            HStack(spacing: 9) {
                Image(systemName: stage.isPresenting ? "iphone" : stage.isDrawing ? "pencil.tip" : "waveform")
                    .font(.system(size: 12, weight: .medium))
                Capsule().fill(.secondary.opacity(0.55)).frame(width: 22, height: 3)
            }.foregroundStyle(.secondary).frame(width: 76, height: 28).contentShape(Capsule())
        }.buttonStyle(.plain)
            .accessibilityLabel("Expand Workbench toolbar")
            .help("Workbench · " + status + ". Hover for quick actions, or click to keep all tools open.")
    }

    private var revealed: some View {
        HStack(spacing: 8) {
            PanelDragHandle(accessibilityLabel: "Drag Workbench toolbar").frame(width: 16, height: 34)
            Button(action: dictate) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Dictate", systemImage: "mic.fill").font(.system(size: 12, weight: .semibold))
                    Text(shortcutLabel(1)).font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(minWidth: 72, minHeight: 34)
            }.buttonStyle(.plain).disabled(!canDictate)
                .help(dictationHelp).accessibilityLabel("Dictate. " + shortcutLabel(1))
            Divider().frame(height: 25)
            modeMenu.frame(width: 91, height: 30)
            Button(action: snap) {
                Image(systemName: "rectangle.and.pencil.and.ellipsis").frame(width: 32, height: 32)
            }.buttonStyle(.plain).disabled(model.rendering || readback.isCapturing)
                .help("Snap & Talk · " + shortcutLabel(5)).accessibilityLabel("Snap & Talk. " + shortcutLabel(5))
            Spacer(minLength: 0)
            expandButton
        }.padding(.horizontal, 12)
    }

    private var expanded: some View {
        HStack(spacing: 10) {
            PanelDragHandle(accessibilityLabel: "Drag Workbench toolbar; position choices are in the menu")
                .frame(width: 20, height: 60)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    FloatingToolbarMenu(title: "Workbench", symbol: "square.stack.3d.up.fill",
                        help: "Workbench toolbar menu", controls: controls, focusOnReveal: true, makeMenu: toolsMenu)
                        .frame(width: 116, height: 24)
                    Spacer(minLength: 0)
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button { controls.collapseToolbar() } label: {
                        Image(systemName: "minus").frame(width: 26, height: 24)
                    }.buttonStyle(.plain).help("Collapse to the quiet indicator")
                        .accessibilityLabel("Collapse Workbench toolbar")
                }
                HStack(spacing: 8) {
                    action("Dictate", "mic", dictate).disabled(!canDictate).help(dictationHelp)
                    action("Snap & Talk", "rectangle.and.pencil.and.ellipsis", snap)
                        .disabled(model.rendering || readback.isCapturing).help("Snap & Talk · " + shortcutLabel(5))
                    action(stage.isDrawing ? "Done drawing" : "Draw", "pencil.tip", draw)
                    action(stage.isPresenting ? "End scene" : "Present", "iphone", present)
                }.controlSize(.small)
                HStack(spacing: 5) {
                    Text("Dictation mode").foregroundStyle(.secondary)
                    modeMenu.frame(width: 91, height: 22)
                    Spacer(minLength: 0)
                    Text(shortcutLabel(1)).foregroundStyle(.secondary)
                }.font(.system(size: 11))
            }
        }.padding(.horizontal, 12)
    }

    private var expandButton: some View {
        Button { controls.expandToolbar() } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 28, height: 32)
        }.buttonStyle(.plain).help("Expand and keep all tools open")
            .accessibilityLabel("Expand Workbench toolbar")
    }

    private var modeMenu: some View {
        FloatingToolbarMenu(title: model.preferences.cleanup.rawValue, symbol: "slider.horizontal.3",
            help: "Change mode. Dictation cleanup: " + model.preferences.cleanup.rawValue,
            controls: controls, enabled: model.phase == .idle && !readback.isRecording,
            makeMenu: makeModeMenu)
    }

    private func makeModeMenu() -> NSMenu {
        let menu = NSMenu(title: "Change mode"); menu.autoenablesItems = false
        menu.addItem(ToolbarMenuAction("Dictation cleanup", enabled: false) {})
        for style in CleanupStyle.allCases {
            let item = ToolbarMenuAction(style.rawValue, checked: model.preferences.cleanup == style) {
                guard model.phase == .idle, !readback.isRecording else { return }
                model.preferences.cleanup = style
            }
            item.toolTip = style.detail; menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ToolbarMenuAction("Dictation settings…") { model.onShowEditor?("dictate") })
        return menu
    }

    private func toolsMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(ToolbarMenuAction("Dictate · " + shortcutLabel(1), enabled: canDictate, run: dictate))
        menu.addItem(ToolbarMenuAction("Snap & Talk · " + shortcutLabel(5),
            enabled: !model.rendering && !readback.isCapturing, run: snap))
        menu.addItem(ToolbarMenuAction(stage.isDrawing ? "Done drawing" : "Draw", run: draw))
        menu.addItem(ToolbarMenuAction(stage.isPresenting ? "End scene" : "Present", run: present))
        let mode = NSMenuItem(title: "Change mode · " + model.preferences.cleanup.rawValue, action: nil, keyEquivalent: "")
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
    private var dictationHelp: String {
        canDictate ? "Dictate · " + shortcutLabel(1) : readback.blocksDictation ? "Finish Snap & Talk before dictating" : "Open Workbench to prepare dictation"
    }
    private var status: String {
        if readback.hasPendingTranscriptions { return "Transcribing narration…" }
        if stage.isPresenting { return "Presenting" }
        if stage.isDrawing { return "Drawing" }
        if !model.ready { return "Speech needs setup" }
        return "Ready"
    }
    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Label(title, systemImage: symbol).fixedSize() }
            .buttonStyle(.bordered).accessibilityLabel(title)
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
            RecordingOverlay(model: model, controls: controls)
        } else {
            FloatingToolbar(model: model, readback: readback, stage: stage, controls: controls,
                            dictate: dictate, snap: snap, draw: draw, present: present)
        }
    }
}
