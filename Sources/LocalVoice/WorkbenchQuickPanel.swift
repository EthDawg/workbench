import AppKit
import SwiftUI
import StageKit
import ToolbarCore

/// One compact panel, reached from the status item and the Quick Controls key.
/// A row per capability in moment order, each reading the same next action the
/// floating toolbar shows and acting on it. The action rows stay above receipts
/// and inline shortcut editing. Its measures are #134's: 320 points wide with a
/// 12 point inset, 36 point rows with 13 point labels, and 11 point shortcut and
/// Options controls, so larger text grows a row rather than clipping it.
struct WorkbenchQuickPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var stage: StageKitController
    @ObservedObject var readback: ReadbackModel
    @ObservedObject var keyboard: KeyboardCoachModel
    /// The inline shortcut editor. The host ends it on every open and close.
    @ObservedObject var editor: PanelShortcutEditor
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
    private var context: WorkbenchControlContext { .init(model: model, readback: readback, stage: stage, snap: snapModel) }
    private var hasFeedback: Bool {
        editor.shortcutID != nil || receipts.receipt?.isClipboardCurrent == true ||
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
                        // The capability's symbol and next action, as the toolbar and its page show them.
                        Button { perform(tool) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: tool.symbol).font(.system(size: 13)).foregroundStyle(.secondary)
                                    .frame(width: 18).accessibilityHidden(true)
                                Text(state.actionTitle(tool)).font(.system(size: 13, weight: .medium))
                            }.frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .disabled(!state.enabled(tool) || keyboard.isInteracting)
                            .help(state.actionTitle(tool) + ". " + context.detail(tool))
                        shortcut(tool)
                        ZStack(alignment: .trailing) { options(tool) }
                            .frame(width: 64, height: 28, alignment: .trailing)
                    }.frame(minHeight: 36)
                }
            }
            Divider()
            MeetingQuickStatus(model: model.meetings) { open("meeting") }
            // Feedback grows below the tools; an idle panel has no empty well.
            if hasFeedback {
                if editor.shortcutID != nil { shortcutEditor }
                else {
                    VStack(alignment: .leading, spacing: 5) {
                        WorkbenchClipboardShelf(receipts: receipts,
                            review: {
                                let prompt = receipts.receipt?.source == .prompt
                                receipts.dismissHUD()
                                if prompt { open("library") } else { model.openHistory(); open("history") }
                            },
                            showCue: { model.onCloseMenu?(); receipts.revealHUD() })
                        if receipts.receipt?.isClipboardCurrent != true {
                            if !context.activitySummary.isEmpty {
                                Text(context.activitySummary).font(.caption).foregroundStyle(.secondary)
                            }
                            if let recovery {
                                PanelRecoveryRow(message: recovery.message, page: recovery.page, warning: recovery.warning, open: open)
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
        }.padding(12).frame(width: 320).fixedSize(horizontal: false, vertical: true)
            .tint(Workbench.accent).workbenchTheme()
    }

    /// What needs attention, and the page that shows it in full with its recovery (#134). The page
    /// is the one recorded where the problem was raised, never read from its words: a Voice
    /// problem's `Attention`, a StageKit notice's page, a Snap & Talk notice, or speech that is not
    /// ready yet.
    private var recovery: (message: String, page: String, warning: Bool)? {
        if let attention = model.attention { return (attention.message, attention.page.route, true) }
        if let notice = stage.notice, let page = stage.noticePage { return (notice, page.route, true) }
        if let notice = readback.notice { return (notice, "readback", false) }
        if model.phase == .idle && !model.ready { return (model.modelMessage, "models", false) }
        return nil
    }


    private func shortcut(_ tool: WorkbenchControlTool) -> some View {
        let id = context.shortcutID(tool)
        let entry = keyboard.entries.first { $0.id == id }
        return Button {
            editor.change(id)
        } label: {
            Text(entry?.shortcut.enabled == true ? (entry?.shortcut.label ?? "Set") : "Set")
                .font(.system(size: 11, design: .monospaced))
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
                Button("Done") { editor.end() }
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
                // The same two choices, under the same names, as the Dictate page's task region.
                Section("Delivery") {
                    ForEach(DeliveryMode.allCases, id: \.self) { delivery in
                        Button { model.preferences.delivery = delivery } label: {
                            if model.preferences.delivery == delivery { Label(delivery.rawValue, systemImage: "checkmark") }
                            else { Text(delivery.rawValue) }
                        }.disabled(model.phase != .idle)
                    }
                }
                // The choice is kept while it waits for approval; say what happens until then.
                if model.preferences.delivery == .paste && !model.accessibilityGranted {
                    Section("Copies for ⌘V until automatic paste is approved") {
                        Button("Set up automatic paste…") { model.onCloseMenu?(); model.requestAccessibility() }
                    }
                }
                Section("Text style") {
                    ForEach(CleanupStyle.allCases, id: \.self) { style in
                        Button { model.preferences.cleanup = style } label: {
                            if model.preferences.cleanup == style { Label(style.rawValue, systemImage: "checkmark") }
                            else { Text(style.rawValue) }
                        }.disabled(model.phase != .idle)
                    }
                }
                Divider()
                // Capture history belongs to Dictate, so its option opens History on Transcripts.
                Button("History…") { model.openHistory(HistoryDoor(filter: .transcripts)); open("history") }
                Button("Transcribe meeting or call…") { open("meeting") }
                Button("Open Dictate…") { open("dictate") }
            }.menuStyle(.borderlessButton).fixedSize()
                // A small control draws the 11 pt label the native Options controls use on every
                // other row; a font on a borderless menu is ignored.
                .controlSize(.small).foregroundStyle(Workbench.accent)
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
        case .annotate:
            // Draw's own tools, then its one door, as Present and Persona end.
            return stage.makeAnnotationMenu(includeSettings: false) { [ToolbarMenuAction("Open Draw…") { open("annotate") }] }
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

extension StageNoticePage {
    /// The route that opens the page a StageKit notice belongs to.
    var route: String {
        switch self {
        case .draw: return "annotate"
        case .present: return "present"
        case .persona: return "personas"
        case .keyboard: return "shortcuts"
        case .general: return "settings"
        }
    }
}

/// One sentence and a door in the panel's status rows: the panel says what happened, and the
/// page that owns it says the rest with its recovery (#134).
struct PanelRecoveryRow: View {
    let message: String
    let page: String
    var warning = true
    let open: (String) -> Void
    var body: some View {
        let name = WorkbenchHome.name(of: page)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.headline(message)).font(.caption)
                .foregroundStyle(warning ? Color.orange : Color.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(message)
            Spacer(minLength: 4)
            Button("Open \(name)…") { open(page) }
                .buttonStyle(.plain).font(.caption).foregroundStyle(Workbench.accent).fixedSize()
        }
    }

    /// A message's first sentence.
    static func headline(_ message: String) -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var first: String?
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { sentence, _, _, stop in
            first = sentence?.trimmingCharacters(in: .whitespacesAndNewlines); stop = true
        }
        return first.flatMap { $0.isEmpty ? nil : $0 } ?? text
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
