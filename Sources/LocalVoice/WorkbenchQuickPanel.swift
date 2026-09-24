import AppKit
import SwiftUI
import StageKit

/// One compact panel, reached from the status item and the Quick Controls key.
/// The action rows stay above receipts and inline shortcut editing.
struct WorkbenchQuickPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var stage: StageKitController
    @ObservedObject var readback: ReadbackModel
    @ObservedObject var keyboard: KeyboardCoachModel
    @ObservedObject var receipts: ClipboardReceiptModel
    @ObservedObject private var updates = WorkbenchUpdates.shared
    var open: (String) -> Void
    var draw: () -> Void
    var snap: () -> Void
    var present: () -> Void
    var timer: () -> Void
    var personas: () -> Void
    @State private var editingShortcut = false
    private var context: WorkbenchControlContext { .init(model: model, readback: readback, stage: stage) }
    private var hasFeedback: Bool {
        editingShortcut || receipts.receipt?.isClipboardCurrent == true ||
            !context.activitySummary.isEmpty || model.error != nil || stage.notice != nil ||
            readback.notice != nil || (model.phase == .idle && !model.ready)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Workbench").font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("Floating Toolbar", isOn: $model.floatingToolbarVisible)
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
            }
            Divider()
            VStack(spacing: 2) {
                ForEach(WorkbenchControlTool.allCases) { tool in
                    HStack(spacing: 8) {
                        Button { perform(tool) } label: {
                            Text(tool.title).font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .disabled(!context.state.enabled(tool) || keyboard.isInteracting)
                            .help((tool == .present && stage.isPresenting || tool == .persona && stage.hasActivePersona ? "Show live controls" : context.state.actionTitle(tool)) + ". " + context.detail(tool))
                        shortcut(tool)
                        ZStack(alignment: .trailing) { options(tool) }
                            .frame(width: 64, height: 28, alignment: .trailing)
                    }.frame(height: 34)
                }
            }
            Divider()
            // Feedback grows below the tools; an idle panel has no empty well.
            if hasFeedback {
                if editingShortcut { shortcutEditor }
                else {
                    VStack(alignment: .leading, spacing: 5) {
                        WorkbenchClipboardShelf(receipts: receipts,
                            review: { receipts.dismissHUD(); open("history") },
                            showCue: { model.onCloseMenu?(); receipts.revealHUD() })
                        if receipts.receipt?.isClipboardCurrent != true {
                            if !context.activitySummary.isEmpty {
                                Text(context.activitySummary).font(.caption).foregroundStyle(.secondary)
                            }
                            if let error = model.error ?? stage.notice {
                                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3).help(error)
                            } else if let notice = readback.notice {
                                Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            } else if model.phase == .idle && !model.ready {
                                Text(model.modelMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
                Divider()
            }
            HStack {
                Button("Open Workbench") { open("home") }
                Spacer(minLength: 8)
                Button("Settings") { open("settings") }
                Button("Shortcuts") { open("shortcuts") }
            }.buttonStyle(.plain).foregroundStyle(Workbench.accent).font(.system(size: 11))
            HStack {
                Button(updates.panelTitle) { updates.checkForUpdates() }
                    .disabled(!updates.canCheck).help(updates.status)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(12).frame(width: 328).fixedSize(horizontal: false, vertical: true)
            .tint(Workbench.accent).workbenchTheme()
            .onDisappear { keyboard.stopInteraction(); editingShortcut = false }
    }

    private func shortcut(_ tool: WorkbenchControlTool) -> some View {
        let id = context.shortcutID(tool)
        let entry = keyboard.entries.first { $0.id == id }
        return Button {
            keyboard.selectedID = id; editingShortcut = true; keyboard.beginRecording()
        } label: {
            Text(entry?.shortcut.enabled == true ? (entry?.shortcut.label ?? "Set") : "Set")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(entry?.error == nil ? Workbench.accent : .orange)
                .frame(width: 46, height: 28)
        }.buttonStyle(.plain).disabled(model.phase != .idle || readback.isRecording)
            .accessibilityLabel("Change \(tool.title) Shortcut")
            .help(entry?.error ?? "Set or change the shortcut here")
    }

    private var shortcutEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(keyboard.selected?.title ?? "Shortcut").font(.callout.weight(.semibold))
                Spacer()
                Button("Done") { keyboard.stopInteraction(); editingShortcut = false }
                    .buttonStyle(.plain).foregroundStyle(Workbench.accent)
            }
            Text(keyboard.message ?? "Choose Change to record a shortcut.")
                .font(.caption).foregroundStyle(keyboard.hasError ? .orange : .secondary).lineLimit(3)
            HStack {
                Button("Change") { keyboard.beginRecording() }
                Button("Turn Off") { keyboard.disableSelected() }
                if keyboard.isInteracting { Button("Cancel") { keyboard.stopInteraction() } }
            }.controlSize(.small)
        }
    }

    @ViewBuilder private func options(_ tool: WorkbenchControlTool) -> some View {
        switch tool {
        case .dictate:
            Menu("Options") {
                Text("Destination")
                ForEach(DeliveryMode.allCases, id: \.self) { delivery in
                    Button { model.preferences.delivery = delivery } label: {
                        if model.preferences.delivery == delivery { Label(delivery.rawValue, systemImage: "checkmark") }
                        else { Text(delivery.rawValue) }
                    }.disabled(model.phase != .idle)
                }
                Divider(); Text("Text Style")
                ForEach(CleanupStyle.allCases, id: \.self) { style in
                    Button { model.preferences.cleanup = style } label: {
                        if model.preferences.cleanup == style { Label(style.rawValue, systemImage: "checkmark") }
                        else { Text(style.rawValue) }
                    }.disabled(model.phase != .idle)
                }
                Divider()
                Button("Recent Transcripts…") { open("history") }
                Button("Dictation Settings…") { open("dictate") }
            }.menuStyle(.borderlessButton).fixedSize()
        case .read:
            if model.rendering { Button("Cancel") { model.cancelReading() }.buttonStyle(.plain).foregroundStyle(Workbench.accent) }
            else if model.playing || model.paused { Button("Stop") { model.stopPlayback() }.buttonStyle(.plain).foregroundStyle(Workbench.accent) }
        case .snap:
            Button(readback.sessionURL == nil ? "Set Up" : "\(readback.activeSections.count) · Review") { open("readback") }
                .font(.system(size: 10)).lineLimit(1).fixedSize()
                .buttonStyle(.plain).foregroundStyle(Workbench.accent)
                .help("Review captures and prepare the explicit deck handoff")
        case .annotate:
            NativeControlMenu(title: "Tools") { stage.makeAnnotationMenu() }
        case .present:
            NativeControlMenu(title: "Options") {
                let menu = stage.makePresentationMenu()
                menu.addItem(.separator())
                menu.addItem(ToolbarMenuAction("Switch to Browser Tab…") { model.onShowPresenter?() })
                menu.addItem(ToolbarMenuAction("Saved Resources…") { open("library") })
                menu.addItem(ToolbarMenuAction("Prepare Scenes…") { open("present") })
                return menu
            }
        case .persona:
            NativeControlMenu(title: "Options") { stage.makePersonaMenu(includePreparation: true) }
        case .timer:
            NativeControlMenu(title: "Options") { stage.makeTimerMenu() }
        }
    }

    private func perform(_ tool: WorkbenchControlTool) {
        switch tool {
        case .dictate:
            if model.waitingForDrawing { model.copyWaitingDelivery() }
            else { model.onMenuRecording?() }
        case .read:
            if model.rendering { model.cancelReading() }
            else if model.playing || model.paused { model.listen() }
            else { open("speak") }
        case .snap: model.controlTool = .snap; snap()
        case .annotate: model.controlTool = .annotate; draw()
        case .present: model.controlTool = .present; present()
        case .persona: model.controlTool = .persona; personas()
        case .timer: timer()
        }
    }
}

/// Snapshot the menu at click time. Tracking a native menu must not rebuild it
/// under the pointer when an independent operation publishes a new status.
struct NativeControlMenu: NSViewRepresentable {
    var title: String
    var makeMenu: () -> NSMenu
    func makeNSView(context: Context) -> Button { Button() }
    func updateNSView(_ view: Button, context: Context) {
        view.title = title + " ⌄"; view.font = .systemFont(ofSize: 11)
        view.contentTintColor = NSColor(Workbench.accent); view.isBordered = false
        view.makeMenu = makeMenu; view.setAccessibilityLabel(title)
    }
    final class Button: NSButton {
        var makeMenu: (() -> NSMenu)?
        override init(frame: NSRect) { super.init(frame: frame); target = self; action = #selector(showMenu) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        @objc private func showMenu() {
            makeMenu?().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
        }
    }
}
