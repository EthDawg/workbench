import AppKit
import SwiftUI
import StageKit
import ToolbarCore

/// One compact panel, reached from the status item and the Quick Controls key.
/// A row per capability in moment order, each showing and acting on its own
/// state while the floating toolbar keeps one contextual next action. The action
/// rows stay above receipts and inline shortcut editing. Its measures are #134's: 320 points wide with a
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
    /// The gallery renders the same rows with frozen synthetic StageKit facts.
    var controlState: WorkbenchControlState? = nil
    private var context: WorkbenchControlContext { .init(model: model, readback: readback, stage: stage, snap: snapModel) }
    private var hasFeedback: Bool {
        editor.shortcutID != nil || receipts.receipt?.isClipboardCurrent == true || model.unresolvedDelivery != nil ||
            !context.activitySummary.isEmpty || model.error != nil || stage.notice != nil ||
            readback.notice != nil || (model.phase == .idle && !model.ready) || model.writingModelLine != nil
    }

    /// The panel's width and inset (#134).
    static let width: CGFloat = 320, inset: CGFloat = 12

    /// One header: the name, and the floating toolbar's one switch at top right (#134). The
    /// switch is the same preference as Settings, the Window menu and the toolbar's Hide toolbar.
    /// The header's text takes one scale, the panel's text size: its labels are fixed point sizes
    /// today, so it is 1, and at a larger scale the switch row grows with its words while staying
    /// at least 32 points high.
    static func header(toolbarVisible: Binding<Bool>, textScale: CGFloat = 1) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Workbench").font(.system(size: 13 * textScale, weight: .semibold))
            Spacer(minLength: 8)
            PanelSwitch(title: "Floating toolbar", isOn: toolbarVisible, help: WorkbenchHome.floatingToolbarHelp, textScale: textScale)
                .fixedSize()
        }
    }

    var body: some View {
        let state = controlState ?? context.state
        VStack(alignment: .leading, spacing: 10) {
            Self.header(toolbarVisible: $model.floatingToolbarVisible)
            Divider()
            VStack(spacing: 2) {
                ForEach(WorkbenchControlTool.allCases) { tool in
                    let renderedAction = state.rowAction(tool)
                    HStack(spacing: 8) {
                        // Each capability retains its own symbol, action and live accent.
                        Button { perform(tool, renderedAction: renderedAction, personaIdentity: state.personaIdentity) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: tool.symbol).font(.system(size: 13))
                                    .foregroundStyle(state.active(tool) ? Workbench.accent : .secondary)
                                    .frame(width: 18).accessibilityHidden(true)
                                Text(state.actionTitle(tool)).font(.system(size: 13, weight: .medium))
                            }.frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            // Give each rendered operation a distinct button identity;
                            // perform also rejects an obsolete action at commit.
                            .id(renderedAction)
                            .disabled(!state.enabled(tool) || keyboard.isInteracting)
                            .help(state.actionTitle(tool) + ". " + context.detail(tool, state: state))
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
                        WorkbenchClipboardShelf(receipts: receipts, unresolved: model.unresolvedDelivery,
                            review: {
                                let source = receipts.receipt?.source
                                receipts.dismissHUD()
                                switch source {
                                case .prompt: open("library")
                                case .result(let id): model.openHistory(HistoryDoor(job: id)); open("history")
                                default: model.openHistory(); open("history")
                                }
                            },
                            showCue: { model.onCloseMenu?(); receipts.revealHUD() },
                            reviewUnresolved: { entry in
                                open(entry.isDraft ? "dictate" : "history")
                                model.reviewUnresolvedDelivery()
                            },
                            copyAgain: { model.copyUnresolvedDelivery() }, dismissUnresolved: { model.dismissUnresolvedDelivery() })
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
        }.padding(Self.inset).frame(width: Self.width).fixedSize(horizontal: false, vertical: true)
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
        // The writing model's download or its failure, the same line Home and Dictate show (#134).
        if let line = model.writingModelLine { return (line, "models", model.cleanupModels.failure != nil) }
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
                // ✓ Saved for four seconds, in space kept for it (#134 T5). Practice
                // happens on the Keyboard page, so this editor never shows its check.
                ConfirmationLabel(text: keyboard.confirmation?.kind == .saved ? ShortcutConfirmation.saved.rawValue : nil,
                                  reserving: [ShortcutConfirmation.saved.rawValue])
                Button("Done") { editor.end() }
                    .buttonStyle(.plain).foregroundStyle(Workbench.accent)
            }
            Text(keyboard.message ?? "Press your combination.")
                .font(.caption).foregroundStyle(keyboard.hasError ? .orange : .secondary).lineLimit(3)
            HStack {
                Button("Change") { keyboard.beginRecording() }
                // Off already: nothing to turn off, so nothing to confirm. It stays
                // usable while recording, which this editor starts on opening.
                Button("Turn off") { keyboard.disableSelected() }
                    .disabled(keyboard.selected?.shortcut.enabled != true)
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
                Button("Meetings…") { open("meeting") }
                Button("Open Dictate…") { open("dictate") }
            }.menuStyle(.borderlessButton).fixedSize()
                // A small control draws the 11 pt label the native Options controls use on every
                // other row; a font on a borderless menu is ignored.
                .controlSize(.small).foregroundStyle(Workbench.accent)
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
                menu.addItem(ToolbarMenuAction("Open Snap & Talk…") { open("readback") })
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
        case .dictate, .snap, .snapAndTalk: return nil
        }
    }

    /// The row does exactly what its label says: the same operation, through the
    /// same owner switch the floating toolbar uses. Only a start goes through
    /// this surface's own door.
    private func perform(_ tool: WorkbenchControlTool, renderedAction: WorkbenchRowAction, personaIdentity: UUID?) {
        guard !keyboard.isInteracting, context.state.admits(renderedAction, for: tool, personaIdentity: personaIdentity) else { return }
        let dispatch = WorkbenchOperationDispatch(model: model, readback: readback, stage: stage, meetings: model.meetings) { mode in
            switch mode {
            case .dictate: model.onMenuRecording?()
            case .snap: snapCapture(.region)
            case .snapAndTalk: snap()
            case .draw: draw()
            case .present: present()
            case .persona: personas()
            }
        }
        switch renderedAction {
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
/// The panel header's Floating toolbar switch (#134 H3): the 11 point label, the space beside it
/// and the row's full 32 point height are one control, so a click anywhere in it toggles, while
/// the switch keeps its own clicks and drags. VoiceOver finds one element, the switch, named by
/// the label with its On or Off value, and Space toggles it when it has focus. AppKit, so the
/// surface gallery can click every part of the row.
struct PanelSwitch: NSViewRepresentable {
    var title: String
    @Binding var isOn: Bool
    var help: String
    /// The words' scale: the panel's text size, 1 at 11 points.
    var textScale: CGFloat = 1
    func makeNSView(context: Context) -> Row {
        let row = Row(title: title, help: help)
        row.control.target = context.coordinator
        row.control.action = #selector(Coordinator.changed(_:))
        return row
    }
    func updateNSView(_ row: Row, context: Context) {
        context.coordinator.isOn = $isOn
        row.update(title: title, help: help, textScale: textScale)
        row.control.state = isOn ? .on : .off
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView row: Row, context: Context) -> CGSize? { row.fittingSize }
    func makeCoordinator() -> Coordinator { Coordinator(isOn: $isOn) }

    final class Coordinator: NSObject {
        var isOn: Binding<Bool>
        init(isOn: Binding<Bool>) { self.isOn = isOn }
        @objc func changed(_ sender: NSSwitch) { isOn.wrappedValue = sender.state == .on }
    }

    final class Row: NSView {
        static let minimumHeight: CGFloat = 32
        let label = Words()
        let control = NSSwitch()
        init(title: String, help: String) {
            super.init(frame: .zero)
            control.controlSize = .mini
            for view in [label, control] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                control.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
                control.trailingAnchor.constraint(equalTo: trailingAnchor),
                control.centerYAnchor.constraint(equalTo: centerYAnchor),
                heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumHeight),
                heightAnchor.constraint(greaterThanOrEqualTo: label.heightAnchor),
                heightAnchor.constraint(greaterThanOrEqualTo: control.heightAnchor),
            ])
            update(title: title, help: help)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func update(title: String, help: String, textScale: CGFloat = 1) {
            label.text = title
            label.scale = textScale
            control.setAccessibilityLabel(title)
            control.setAccessibilityHelp(help)
            toolTip = help
        }
        /// The switch takes its own clicks; every other point of the row is the row's.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let hit = super.hitTest(point) else { return nil }
            return hit.isDescendant(of: control) ? hit : self
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {}
        /// A click released inside the row toggles, as a click on the switch does.
        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { control.performClick(nil) }
        }
    }

    /// The row's words in 11 point secondary text at the panel's text scale, drawn by the view so
    /// a layer render shows them as the screen does (it draws an NSTextField's text twice). Not an
    /// accessibility element: the switch carries the name.
    final class Words: NSView {
        var text = "" { didSet { if text != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
        var scale: CGFloat = 1 { didSet { if scale != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
        private var attributes: [NSAttributedString.Key: Any] {
            [.font: NSFont.systemFont(ofSize: 11 * scale), .foregroundColor: NSColor.secondaryLabelColor]
        }
        override var intrinsicContentSize: NSSize {
            let size = (text as NSString).size(withAttributes: attributes)
            return NSSize(width: ceil(size.width), height: ceil(size.height))
        }
        override func draw(_ dirtyRect: NSRect) { (text as NSString).draw(at: .zero, withAttributes: attributes) }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    }
}

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
