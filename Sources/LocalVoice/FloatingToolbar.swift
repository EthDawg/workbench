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
    static let size = NSSize(width: 480, height: 88)
    @ObservedObject var model: AppModel
    @ObservedObject var readback: ReadbackModel
    @ObservedObject var stage: StageKitController
    @ObservedObject var controls: CaptureHUDControls
    let dictate: () -> Void
    let snap: () -> Void
    let draw: () -> Void
    let present: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 10) {
            PanelDragHandle(accessibilityLabel: "Drag Workbench toolbar; position choices are in the menu")
                .frame(width: 20, height: 48)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Menu {
                        Button("Open Workbench") { model.onShowEditor?("home") }
                        Button("Read aloud…") { model.onShowEditor?("speak") }
                        Button("Review Snap & Talk…") { model.onShowEditor?("readback") }
                        Button("Choose a scene…") { model.onShowEditor?("present") }
                        Button("Switch to browser tab…") { model.onShowPresenter?() }
                        Button("Break timer") { stage.showTimer() }
                        Button("Overlay cards…") { stage.showPersonas() }
                        Divider()
                        Menu("Position") {
                            ForEach(FloatingControlAnchor.allCases, id: \.self) { anchor in
                                Button(anchor.title) { controls.choosePosition?(anchor) }
                            }
                        }
                        Button("Hide floating toolbar") { model.floatingToolbarVisible = false }
                        Button("Settings…") { model.onShowEditor?("settings") }
                    } label: {
                        Label("Workbench", systemImage: "square.stack.3d.up.fill").font(.caption.weight(.semibold))
                    }.menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("Workbench toolbar menu")
                    Spacer(minLength: 0)
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(readback.notice ?? model.status)
                }
                HStack(spacing: 8) {
                    action("Dictate", "mic", dictate)
                        .disabled(!model.ready || model.rendering || readback.blocksDictation)
                    action("Snap & Talk", "rectangle.and.pencil.and.ellipsis", snap)
                        .disabled(model.rendering || readback.isCapturing)
                    action(stage.isDrawing ? "Done drawing" : "Draw", "pencil.tip", draw)
                    action(stage.isPresenting ? "End scene" : "Present", "iphone", present)
                }.controlSize(.small)
            }
        }.padding(.horizontal, 12)
            .frame(width: Self.size.width, height: Self.size.height)
            .background {
                if reduceTransparency { RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .windowBackgroundColor)) }
                else { RoundedRectangle(cornerRadius: 18).fill(.regularMaterial) }
            }
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.12)))
            .tint(Workbench.accent).workbenchTheme()
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
