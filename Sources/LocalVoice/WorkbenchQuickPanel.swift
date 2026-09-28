import AppKit
import SwiftUI
import StageKit
import ToolbarCore

/// One compact panel, reached from the status item and the Quick Controls key.
/// A row per capability in moment order, each reading the same next action the
/// floating toolbar shows and acting on it. The action rows stay above receipts
/// and inline shortcut editing.
struct WorkbenchQuickPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var stage: StageKitController
    @ObservedObject var readback: ReadbackModel
    @ObservedObject var keyboard: KeyboardCoachModel
    @ObservedObject var receipts: ClipboardReceiptModel
    @ObservedObject var snapModel: SnapModel
    @ObservedObject private var updates = WorkbenchUpdates.shared
    var open: (String) -> Void
    var draw: () -> Void
    var snap: () -> Void
    var snapCapture: (SnapCapture.Mode) -> Void
    var present: () -> Void
    var timer: () -> Void
    var personas: () -> Void
    @State private var editingShortcut = false
    private var context: WorkbenchControlContext { .init(model: model, readback: readback, stage: stage, snap: snapModel) }
    private var hasFeedback: Bool {
        editingShortcut || receipts.receipt?.isClipboardCurrent == true ||
            !context.activitySummary.isEmpty || model.error != nil || stage.notice != nil ||
            readback.notice != nil || (model.phase == .idle && !model.ready)
    }

    var body: some View {
        let state = context.state
        VStack(alignment: .leading, spacing: 10) {
            Text("Workbench").font(.system(size: 13, weight: .semibold))
            Divider()
            VStack(spacing: 2) {
                ForEach(WorkbenchControlTool.allCases) { tool in
                    HStack(spacing: 8) {
                        Button { perform(tool) } label: {
                            Text(state.actionTitle(tool)).font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .disabled(!state.enabled(tool) || keyboard.isInteracting)
                            .help(state.actionTitle(tool) + ". " + context.detail(tool))
                        shortcut(tool)
                        ZStack(alignment: .trailing) { options(tool) }
                            .frame(width: 64, height: 28, alignment: .trailing)
                    }.frame(height: 34)
                }
            }
            Divider()
            MeetingQuickStatus(model: model.meetings) { open("meeting") }
            // Feedback grows below the tools; an idle panel has no empty well.
            if hasFeedback {
                if editingShortcut { shortcutEditor }
                else {
                    VStack(alignment: .leading, spacing: 5) {
                        WorkbenchClipboardShelf(receipts: receipts,
                            review: { receipts.dismissHUD(); model.openHistory(); open("history") },
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
            Text(keyboard.message ?? "Press your combination.")
                .font(.caption).foregroundStyle(keyboard.hasError ? .orange : .secondary).lineLimit(3)
            HStack {
                Button("Change") { keyboard.beginRecording() }
                Button("Turn off") { keyboard.disableSelected() }
                if keyboard.isInteracting { Button("Cancel") { keyboard.stopInteraction() } }
            }.controlSize(.small)
        }
    }

    /// Each row's options hold only that capability's own choices and its one
    /// door to its page. Nothing here is information-only.
    @ViewBuilder private func options(_ tool: WorkbenchControlTool) -> some View {
        switch tool {
        case .dictate:
            Menu("Options") {
                ForEach(DeliveryMode.allCases, id: \.self) { delivery in
                    Button { model.preferences.delivery = delivery } label: {
                        if model.preferences.delivery == delivery { Label(delivery.rawValue, systemImage: "checkmark") }
                        else { Text(delivery.rawValue) }
                    }.disabled(model.phase != .idle)
                }
                // The choice is kept while it waits for approval; say what happens until then.
                if model.preferences.delivery == .paste && !model.accessibilityGranted {
                    Section("Copies for ⌘V until automatic paste is approved") {
                        Button("Set up automatic paste…") { model.onCloseMenu?(); model.requestAccessibility() }
                    }
                }
                Divider()
                ForEach(CleanupStyle.allCases, id: \.self) { style in
                    Button { model.preferences.cleanup = style } label: {
                        if model.preferences.cleanup == style { Label(style.rawValue, systemImage: "checkmark") }
                        else { Text(style.rawValue) }
                    }.disabled(model.phase != .idle)
                }
                Divider()
                // Capture history belongs to Dictate, so its option opens History on Transcripts.
                Button("History…") { model.openHistory(HistoryDoor(filter: .transcripts)); open("history") }
                Button("Transcribe meeting or call…") { open("meeting") }
                Button("Open Dictate…") { open("dictate") }
            }.menuStyle(.borderlessButton).fixedSize()
                // The same 11 pt accent label the native Options controls use on every other row.
                .font(.system(size: 11)).foregroundStyle(Workbench.accent)
        case .read:
            EmptyView()
        case .snap:
            NativeControlMenu(title: "Options") {
                let menu = NSMenu(title: "Snap"); menu.autoenablesItems = false
                for mode in SnapCapture.Mode.allCases {
                    menu.addItem(ToolbarMenuAction(mode.title, enabled: context.state.enabled(.snap)) {
                        model.toolbarMode = .snap; snapCapture(mode)
                    })
                }
                menu.addItem(.separator())
                menu.addItem(ToolbarMenuAction("Open Snap…") { open("snap") })
                return menu
            }
        case .snapAndTalk:
            NativeControlMenu(title: "Options") {
                let menu = NSMenu(title: "Snap & Talk"); menu.autoenablesItems = false
                menu.addItem(ToolbarMenuAction("Review Snap & Talk…") { open("readback") })
                return menu
            }
        case .annotate:
            NativeControlMenu(title: "Options") { nativeOptions(tool) ?? NSMenu() }
        case .present:
            NativeControlMenu(title: "Options") { nativeOptions(tool) ?? NSMenu() }
        case .persona:
            NativeControlMenu(title: "Options") { nativeOptions(tool) ?? NSMenu() }
        case .timer:
            NativeControlMenu(title: "Options") { nativeOptions(tool) ?? NSMenu() }
        }
    }

    /// Native option menus, built when clicked. The surface gallery lists these same menus.
    func nativeOptions(_ tool: WorkbenchControlTool) -> NSMenu? {
        switch tool {
        case .annotate: return stage.makeAnnotationMenu(includeSettings: false)
        case .present:
            let menu = stage.makePresentationMenu()
            // The page is the door when nothing is prepared; a note is not.
            for item in menu.items where !item.isEnabled && item.submenu == nil { menu.removeItem(item) }
            if menu.items.isEmpty == false { menu.addItem(.separator()) }
            menu.addItem(ToolbarMenuAction("Open Present…") { open("present") })
            return menu
        case .persona:
            let menu = stage.makePersonaPanelMenu()
            if menu.items.isEmpty == false { menu.addItem(.separator()) }
            menu.addItem(ToolbarMenuAction("Open Persona…") { open("personas") })
            return menu
        case .timer: return stage.makeTimerMenu(optionsOnly: true)
        case .dictate, .read, .snap, .snapAndTalk: return nil
        }
    }

    /// The row does exactly what its label says: the same operation, through the
    /// same owner switch the floating toolbar uses. Only a start goes through
    /// this surface's own door.
    private func perform(_ tool: WorkbenchControlTool) {
        let dispatch = WorkbenchOperationDispatch(model: model, readback: readback, stage: stage, meetings: model.meetings) { mode in
            switch mode {
            case .dictate: model.onMenuRecording?()
            case .read: open("speak")
            case .snap: snapCapture(.region)
            case .snapAndTalk: snap()
            case .draw: draw()
            case .present: present()
            case .persona: personas()
            }
        }
        switch context.state.rowAction(tool) {
        case .startTimer, .stopTimer: timer()
        case .operation(let operation):
            if case .start = operation {} else { model.onCloseMenu?() }
            dispatch.perform(operation)
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
