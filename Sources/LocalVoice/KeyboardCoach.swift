import AppKit
import Carbon
import StageKit
import SwiftUI

/// One shortcut catalogue for every Workbench module. The owner persists changes transactionally.
struct ShortcutEntry: Identifiable, Equatable {
    var id: String
    var title: String
    var shortcut: VoiceShortcut
    var error: String?

    init(id: String, title: String, shortcut: VoiceShortcut, error: String? = nil) {
        self.id = id; self.title = title; self.shortcut = shortcut; self.error = error
    }
}

enum ShortcutConflict {
    static let supportedModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    /// Preserve saved choices, but do not let registration order choose which duplicate action runs.
    static func duplicateFailures(in entries: [ShortcutEntry]) -> [String: String] {
        var failures: [String: String] = [:]
        for entry in entries where entry.shortcut.enabled {
            if let other = entries.first(where: { $0.id != entry.id && $0.shortcut.enabled && $0.shortcut.combination == entry.shortcut.combination }) {
                failures[entry.id] = "Also assigned to \(other.title). Both shortcuts are paused; change or turn off one in Keyboard shortcuts."
            }
        }
        return failures
    }

    static func voiceRegistrationPreferences(_ preferences: VoicePreferences, failures: [String: String]) -> VoicePreferences {
        var result = preferences
        for id in UInt32(1)...7 where failures["voice.\(id)"] != nil {
            var shortcut = result.shortcut(id); shortcut.enabled = false
            result.setShortcut(shortcut, for: id)
        }
        return result
    }

    static func message(for candidate: VoiceShortcut, replacing id: String, in entries: [ShortcutEntry]) -> String? {
        guard candidate.enabled else { return nil }
        guard candidate.modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else {
            return "Include Control or Option so ordinary typing stays available."
        }
        guard candidate.modifiers & ~supportedModifiers == 0 else { return "Choose Control, Option, Shift or Command with a key." }
        if let other = entries.first(where: { $0.id != id && $0.shortcut.enabled && $0.shortcut.keyCode == candidate.keyCode && $0.shortcut.modifiers == candidate.modifiers }) {
            return "\(candidate.label) belongs to \(other.title). Choose another combination or turn that shortcut off first."
        }
        if let owner = systemUse(candidate) {
            return "\(candidate.label) is commonly used for \(owner). Choose another combination to keep that Mac control available."
        }
        return GlobalShortcutRule.problem(label: candidate.label, modifiers: candidate.modifiers)
    }

    /// A small, explicit policy for familiar Mac controls. macOS does not expose a complete
    /// inventory of other apps' shortcuts; Carbon registration checks availability separately.
    static func systemUse(_ shortcut: VoiceShortcut) -> String? {
        let key = shortcut.keyCode, mods = shortcut.modifiers
        let command = UInt32(cmdKey), control = UInt32(controlKey), option = UInt32(optionKey), shift = UInt32(shiftKey)
        if key == UInt32(kVK_Space), mods == command { return "Spotlight" }
        if key == UInt32(kVK_Space), mods == command | option { return "Finder search" }
        if key == UInt32(kVK_Space), mods == control { return "switching keyboard input sources" }
        if key == UInt32(kVK_Tab), mods == command || mods == command | shift { return "switching apps" }
        if key == UInt32(kVK_Escape), mods == command | option { return "Force Quit" }
        if key == UInt32(kVK_ANSI_Q), mods == command | control { return "locking the screen" }
        if key == UInt32(kVK_ANSI_Q), mods == command | shift || mods == command | control | shift { return "logging out" }
        if [UInt32(kVK_LeftArrow), UInt32(kVK_RightArrow), UInt32(kVK_UpArrow), UInt32(kVK_DownArrow)].contains(key), mods == control { return "Mission Control and Spaces" }
        if [UInt32(kVK_ANSI_3), UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6)].contains(key), mods == command | shift || mods == command | shift | control { return "screenshots and screen recording" }
        if key == UInt32(kVK_ANSI_F), mods == command | control { return "full screen" }
        if key == UInt32(kVK_ANSI_Grave), mods == command || mods == command | shift { return "switching windows" }
        if mods == command {
            let familiar: [UInt32: String] = [UInt32(kVK_ANSI_Q): "Quit", UInt32(kVK_ANSI_W): "Close", UInt32(kVK_ANSI_H): "Hide", UInt32(kVK_ANSI_M): "Minimize", UInt32(kVK_ANSI_C): "Copy", UInt32(kVK_ANSI_X): "Cut", UInt32(kVK_ANSI_V): "Paste", UInt32(kVK_ANSI_Z): "Undo", UInt32(kVK_ANSI_A): "Select All", UInt32(kVK_ANSI_S): "Save", UInt32(kVK_ANSI_O): "Open", UInt32(kVK_ANSI_P): "Print", UInt32(kVK_ANSI_N): "New", UInt32(kVK_ANSI_F): "Find", UInt32(kVK_ANSI_Comma): "Settings"]
            return familiar[key]
        }
        if key == UInt32(kVK_ANSI_Z), mods == command | shift { return "Redo" }
        if mods == option, [UInt32(kVK_ANSI_E), UInt32(kVK_ANSI_U), UInt32(kVK_ANSI_I), UInt32(kVK_ANSI_N), UInt32(kVK_ANSI_Grave)].contains(key) { return "typing accented letters" }
        return nil
    }
}

/// Counts complete presses, not auto-repeat events or a modifier release by itself.
struct ShortcutPracticeState: Equatable {
    enum Feedback: Equatable { case waiting, release, retry, success, complete }
    let target: VoiceShortcut
    let required: Int
    private(set) var completed = 0
    private(set) var heldKey: UInt32?
    private(set) var feedback: Feedback = .waiting
    var isComplete: Bool { completed >= required }

    init(target: VoiceShortcut, required: Int = 3) { self.target = target; self.required = max(1, required) }

    mutating func keyDown(_ keyCode: UInt32, modifiers: UInt32, isRepeat: Bool) {
        guard target.enabled, !isComplete, !isRepeat else { return }
        guard heldKey == nil else { return }
        guard keyCode == target.keyCode, modifiers == target.modifiers else { feedback = .retry; return }
        heldKey = keyCode; feedback = .release
    }

    mutating func keyUp(_ keyCode: UInt32) {
        guard !isComplete, heldKey == keyCode else { return }
        heldKey = nil; completed += 1
        feedback = isComplete ? .complete : .success
    }
}

@MainActor
final class KeyboardCoachModel: ObservableObject {
    enum Interaction: Equatable { case idle, recording, practicing }
    @Published private(set) var entries: [ShortcutEntry]
    @Published var selectedID: String {
        didSet { if selectedID != oldValue { stopInteraction(); practice = nil; message = nil } }
    }
    @Published private(set) var interaction: Interaction = .idle
    @Published private(set) var message: String?
    @Published private(set) var hasError = false
    @Published private(set) var heldModifiers: UInt32 = 0
    @Published private(set) var heldKey: UInt32?
    @Published private(set) var practice: ShortcutPracticeState?
    var selected: ShortcutEntry? { entries.first { $0.id == selectedID } }
    var isInteracting: Bool { interaction != .idle }

    private let update: (String, VoiceShortcut) -> String?
    private let suspend: (Bool) -> Void
    private let probe: (VoiceShortcut) -> String?
    private var eventMonitor: Any?
    private var suspended = false

    /// update must leave the previous preference intact on error. It must not resume global
    /// hotkeys: suspend(false) owns that operation after editing or practice has stopped.
    init(entries: [ShortcutEntry], update: @escaping (String, VoiceShortcut) -> String?, suspend: @escaping (Bool) -> Void, probe: ((VoiceShortcut) -> String?)? = nil) {
        self.entries = entries; selectedID = entries.first?.id ?? ""
        self.update = update; self.suspend = suspend; self.probe = probe ?? Self.registrationFailure
    }

    func replaceEntries(_ entries: [ShortcutEntry]) {
        if let previous = selected, !entries.contains(where: { $0.id == previous.id && $0.shortcut == previous.shortcut }) { stopInteraction(); practice = nil }
        self.entries = entries
        if !entries.contains(where: { $0.id == selectedID }) { selectedID = entries.first?.id ?? "" }
    }

    func beginRecording() {
        guard selected != nil else { return }
        stopInteraction(); practice = nil; message = "Press your new combination. Escape cancels."; hasError = false
        begin(.recording)
    }

    func beginPractice() {
        guard let shortcut = selected?.shortcut, shortcut.enabled, selected?.error == nil else { return }
        stopInteraction(); practice = ShortcutPracticeState(target: shortcut)
        message = nil; hasError = false; begin(.practicing)
    }

    private func begin(_ interaction: Interaction) {
        suspended = true; suspend(true)
        self.interaction = interaction
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stopInteraction() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        let wasInteracting = isInteracting
        interaction = .idle; heldModifiers = 0; heldKey = nil
        if suspended { suspended = false; suspend(false) }
        if wasInteracting, practice?.isComplete != true { message = "Stopped. Your shortcuts are active again."; hasError = false }
    }

    func disableSelected() {
        guard var candidate = selected?.shortcut else { return }
        stopInteraction(); suspended = true; suspend(true)
        candidate.enabled = false
        _ = save(candidate)
        stopInteraction()
    }

    /// Event handling remains local to the active app. Global Workbench actions are suspended.
    /// Every practice keystroke is consumed, so it cannot edit text or perform a menu command.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard isInteracting else { return event }
        if event.type == .flagsChanged { heldModifiers = VoiceShortcut(event: event).modifiers; return event }
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) { stopInteraction(); return nil }
        let shortcut = VoiceShortcut(event: event)
        heldModifiers = shortcut.modifiers
        if event.type == .keyDown { heldKey = shortcut.keyCode }
        else if heldKey == shortcut.keyCode { heldKey = nil }
        if interaction == .recording {
            guard event.type == .keyDown, !event.isARepeat else { return nil }
            if save(shortcut) { stopInteraction(); message = "Saved. Try it here to build the habit." }
        } else if interaction == .practicing {
            if event.type == .keyDown { practice?.keyDown(shortcut.keyCode, modifiers: shortcut.modifiers, isRepeat: event.isARepeat) }
            else { practice?.keyUp(shortcut.keyCode) }
            if practice?.isComplete == true { stopInteraction(); message = "Three complete presses. Ready to use anywhere." }
        }
        return nil
    }

    @discardableResult
    private func save(_ candidate: VoiceShortcut) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == selectedID }) else { return false }
        if let problem = ShortcutConflict.message(for: candidate, replacing: selectedID, in: entries) ?? (candidate.enabled ? probe(candidate) : nil) {
            message = problem; hasError = true; return false
        }
        if let problem = update(selectedID, candidate) { message = problem; hasError = true; return false }
        entries[index].shortcut = candidate; entries[index].error = nil
        hasError = false; message = candidate.enabled ? "Shortcut saved." : "Shortcut off. The action is still available from its button or menu."
        return true
    }

    static func registrationFailure(_ shortcut: VoiceShortcut) -> String? {
        guard shortcut.enabled else { return nil }
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x57424B43, id: 1), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        if let reference { UnregisterEventHotKey(reference) }
        guard result == noErr else { return "macOS could not register \(shortcut.label) (\(result)). It may be in use by another app or the system. Your previous shortcut is unchanged." }
        return nil
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if suspended { suspend(false) }
    }
}

struct KeyboardCoachView: View {
    @ObservedObject var model: KeyboardCoachModel
    private var selected: ShortcutEntry? { model.selected }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Make it second nature").font(.system(size: 24, weight: .semibold))
                Text("One set of shortcuts for speaking, drawing and presenting.").foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 20) {
                actionList.frame(width: 230, height: 230)
                Divider().frame(height: 230)
                VStack(alignment: .leading, spacing: 12) {
                    if let selected {
                        HStack(alignment: .firstTextBaseline) {
                            Text(selected.title).font(.title3.weight(.semibold))
                            Spacer()
                            Text(model.interaction == .recording ? "Press keys…" : selected.shortcut.label)
                                .font(.system(size: 23, weight: .medium, design: .monospaced)).foregroundStyle(Color.accentColor)
                        }
                        HStack {
                            Button(model.interaction == .recording ? "Cancel recording" : "Record shortcut") {
                                if model.interaction == .recording { model.stopInteraction() } else { model.beginRecording() }
                            }
                            Button("Turn off") { model.disableSelected() }.disabled(!selected.shortcut.enabled || model.isInteracting)
                            Spacer()
                            Button(model.interaction == .practicing ? "Stop practice" : "Practice") {
                                if model.interaction == .practicing { model.stopInteraction() } else { model.beginPractice() }
                            }.buttonStyle(.borderedProminent).disabled(!selected.shortcut.enabled || selected.error != nil)
                        }
                        if let error = selected.error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                        if model.interaction == .practicing || model.practice?.isComplete == true { practiceProgress }
                        if let message = model.message {
                            Text(message).font(.callout).foregroundStyle(model.hasError ? Color.orange : .secondary).fixedSize(horizontal: false, vertical: true)
                        } else if !model.isInteracting {
                            Text("Choose an action, then change its keys or practice three complete presses.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 230)
            VirtualMacKeyboard(shortcut: selected?.shortcut, active: model.isInteracting, heldModifiers: model.heldModifiers, heldKey: model.heldKey)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.isInteracting ? "hand.raised.fill" : "keyboard").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.interaction == .practicing ? "Practice stays here. Nothing records or draws while you try the keys." : model.interaction == .recording ? "Global shortcuts are paused while you choose a combination." : "Every action is still available from its button or menu.")
                    Text("Labels follow your input layout. The picture shows an ANSI keyboard.")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("ISO and JIS keys may sit elsewhere. Workbench checks its own duplicate shortcuts, common Mac controls and global registration. macOS does not expose a complete list of other apps’ shortcuts.")
                }
            }.font(.callout)
        }.padding(24).frame(minWidth: 760, idealWidth: 840, maxWidth: .infinity)
            .background(KeyboardCoachWindowObserver { model.stopInteraction() }.frame(width: 0, height: 0))
            .onDisappear { model.stopInteraction() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in model.stopInteraction() }
    }

    private var actionList: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(model.entries) { entry in
                    Button { model.selectedID = entry.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title).fontWeight(.medium)
                                if entry.error != nil { Text("Needs another combination").font(.caption2).foregroundStyle(.orange) }
                            }
                            Spacer(minLength: 8)
                            Text(entry.shortcut.label).font(.system(.caption, design: .monospaced))
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(model.selectedID == entry.id ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("\(entry.title), \(entry.shortcut.label)")
                        .accessibilityAddTraits(model.selectedID == entry.id ? .isSelected : [])
                }
            }
        }.scrollIndicators(.visible)
    }

    private var practiceProgress: some View {
        HStack(spacing: 8) {
            ForEach(0..<3) { index in
                Image(systemName: index < (model.practice?.completed ?? 0) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(index < (model.practice?.completed ?? 0) ? Color.accentColor : Color.secondary.opacity(0.45))
            }
            Text(practicePrompt).font(.callout).foregroundStyle(.secondary)
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(model.practice?.completed ?? 0) of 3 complete presses. \(practicePrompt)")
    }

    private var practicePrompt: String {
        switch model.practice?.feedback {
        case .release: "Now release the key."
        case .retry: "Try \(selected?.shortcut.label ?? "the highlighted keys")."
        case .success: "Good. Press it again."
        case .complete: "Three out of three."
        default: "Press and release the highlighted keys."
        }
    }
}

private struct VirtualMacKeyboard: View {
    struct Key: Identifiable {
        let id: String
        let keyCode: UInt32?
        let modifier: UInt32
        let label: String?
        let width: CGFloat
        init(_ keyCode: Int, width: CGFloat = 1, label: String? = nil) { id = "key\(keyCode)"; self.keyCode = UInt32(keyCode); modifier = 0; self.label = label; self.width = width }
        init(_ id: String, _ label: String, modifier: Int = 0, width: CGFloat = 1) { self.id = id; self.label = label; self.modifier = UInt32(modifier); keyCode = nil; self.width = width }
    }
    let shortcut: VoiceShortcut?
    let active: Bool
    let heldModifiers: UInt32
    let heldKey: UInt32?
    @State private var layoutRevision = 0
    private static let rows: [[Key]] = [
        [Key(53, label: "esc"), Key(122), Key(120), Key(99), Key(118), Key(96), Key(97), Key(98), Key(100), Key(101), Key(109), Key(103), Key(111)],
        [Key(50), Key(18), Key(19), Key(20), Key(21), Key(23), Key(22), Key(26), Key(28), Key(25), Key(29), Key(27), Key(24), Key(51, width: 1.6, label: "delete")],
        [Key(48, width: 1.45, label: "tab"), Key(12), Key(13), Key(14), Key(15), Key(17), Key(16), Key(32), Key(34), Key(31), Key(35), Key(33), Key(30), Key(42, width: 1.15)],
        [Key("caps", "caps lock", width: 1.75), Key(0), Key(1), Key(2), Key(3), Key(5), Key(4), Key(38), Key(40), Key(37), Key(41), Key(39), Key(36, width: 1.85, label: "return")],
        [Key("shiftL", "⇧ shift", modifier: shiftKey, width: 2.25), Key(6), Key(7), Key(8), Key(9), Key(11), Key(45), Key(46), Key(43), Key(47), Key(44), Key("shiftR", "shift ⇧", modifier: shiftKey, width: 2.35)],
        [Key("fn", "fn"), Key("control", "⌃", modifier: controlKey), Key("optionL", "⌥", modifier: optionKey), Key("commandL", "⌘", modifier: cmdKey, width: 1.25), Key(49, width: 4.6, label: "space"), Key("commandR", "⌘", modifier: cmdKey, width: 1.25), Key("optionR", "⌥", modifier: optionKey), Key(123, label: "←"), Key(126, label: "↑"), Key(125, label: "↓"), Key(124, label: "→")]
    ]

    var body: some View {
        VStack(spacing: 5) {
            ForEach(Self.rows.indices, id: \.self) { row in
                GeometryReader { geometry in
                    let keys = Self.rows[row]
                    let units = keys.reduce(CGFloat(0)) { $0 + $1.width }
                    let unit = max(1, (geometry.size.width - CGFloat(keys.count - 1) * 5) / units)
                    HStack(spacing: 5) {
                        ForEach(keys) { key in
                            keycap(key, width: unit * key.width, functionRow: row == 0)
                        }
                    }
                }.frame(height: row == 0 ? 26 : 34)
            }
        }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
            .accessibilityElement(children: .ignore).accessibilityLabel("Keyboard. \(shortcut?.enabled == true ? "Highlighted shortcut: \(shortcut!.label)" : "No shortcut selected")")
            .onReceive(NotificationCenter.default.publisher(for: NSTextInputContext.keyboardSelectionDidChangeNotification)) { _ in layoutRevision += 1 }
    }

    private func keycap(_ key: Key, width: CGFloat, functionRow: Bool) -> some View {
        let intended = highlighted(key)
        let pressed = isPressed(key)
        let foreground: Color = pressed ? .white : (intended ? .accentColor : .primary.opacity(0.7))
        let background: Color = pressed ? .accentColor : (intended ? .accentColor.opacity(0.13) : Color(NSColor.controlBackgroundColor))
        let border: Color = intended ? .accentColor.opacity(0.55) : .primary.opacity(0.08)
        return Text(label(key))
            .font(.system(size: functionRow ? 10 : 12, weight: intended ? .semibold : .regular))
            .lineLimit(1).minimumScaleFactor(0.6)
            .frame(width: width, height: functionRow ? 26 : 34)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(border, lineWidth: 1))
            .accessibilityHidden(true)
    }

    private func label(_ key: Key) -> String {
        _ = layoutRevision
        if let label = key.label { return label }
        return VoiceShortcut(keyCode: key.keyCode ?? 0, modifiers: 0).label
    }
    private func highlighted(_ key: Key) -> Bool {
        guard let shortcut, shortcut.enabled else { return false }
        return key.modifier != 0 ? shortcut.modifiers & key.modifier != 0 : key.keyCode == shortcut.keyCode
    }
    private func isPressed(_ key: Key) -> Bool {
        guard active else { return false }
        return key.modifier != 0 ? heldModifiers & key.modifier != 0 : key.keyCode != nil && heldKey == key.keyCode
    }
}

/// Restores hotkeys when another window becomes active, even inside the same app.
private struct KeyboardCoachWindowObserver: NSViewRepresentable {
    var onResign: () -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView(onResign: onResign) }
    func updateNSView(_ view: ObserverView, context: Context) { view.onResign = onResign }

    final class ObserverView: NSView {
        var onResign: () -> Void
        private var observer: NSObjectProtocol?
        init(onResign: @escaping () -> Void) { self.onResign = onResign; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            guard let window else { onResign(); return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.onResign() }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
