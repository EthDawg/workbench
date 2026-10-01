import AppKit
import SwiftUI
import ToolbarCore

/// The chooser's measures (#134): 320 points wide with 36-point rows at standard text.
public enum ToolbarChooserLayout {
    public static let width: CGFloat = 320
    public static let rowHeight: CGFloat = 36
    public static let verticalPadding: CGFloat = 6
    /// The natural height of a list of `rows`, before any display limit.
    public static func height(rows: Int, scale: CGFloat = 1) -> CGFloat {
        (CGFloat(rows) * rowHeight + 2 * verticalPadding) * scale
    }
}

/// The chooser as its view and its panel see it: the frozen list with its keyboard
/// highlight. Choosing reports a tool by identity; closing reports nothing.
@MainActor public final class ToolbarChooserModel: ObservableObject {
    @Published public private(set) var state: ToolbarChooserState
    @Published public private(set) var activities = ToolbarChooserActivities()
    private var generations: [String: Int] = [:]
    public var choose: (ToolbarMode) -> Void
    public var dismiss: () -> Void
    public var perform: (ToolbarChooserAction) -> Void = { _ in }
    public var openTool: (ToolbarMode) -> Void = { _ in }

    public init(choices: [ToolbarToolChoice], choose: @escaping (ToolbarMode) -> Void = { _ in }, dismiss: @escaping () -> Void = {}) {
        state = ToolbarChooserState(choices: choices)
        self.choose = choose; self.dismiss = dismiss
    }

    /// Live facts changed while the chooser is open; the rows update, the highlight stays put.
    public func refresh(_ choices: [ToolbarToolChoice]) {
        let previous = actions
        state.refresh(choices)
        observe(previous)
    }
    public func refreshActivities(_ activities: ToolbarChooserActivities) {
        let previous = actions
        self.activities = activities
        observe(previous)
    }
    private var actions: [ToolbarChooserAction] { state.choices.flatMap(\.actions) + activities.rows.flatMap(\.actions) }
    private func observe(_ previous: [ToolbarChooserAction]) {
        let before = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
        for id in Set(before.keys).union(after.keys) where before[id] != after[id] { generations[id, default: 0] += 1 }
    }
    /// Latch the visible command. Changing a row while the button is held cancels the press.
    public func press(_ action: ToolbarChooserAction) -> (() -> Void)? {
        guard actions.contains(action) else { return nil }
        let version = generations[action.id, default: 0]
        return { [weak self] in
            guard let self, self.generations[action.id, default: 0] == version, self.actions.contains(action) else { return }
            self.perform(action)
        }
    }
    public func highlight(_ mode: ToolbarMode) { state.highlight(mode) }
    public var selected: ToolbarMode { state.choices.first(where: \.isSelected)?.mode ?? state.highlighted }

    /// Up and Down move, Return commits, Escape closes without a change, and typing jumps to
    /// a tool by name, as a native menu does. Returns whether the key was the chooser's.
    @discardableResult
    public func handle(keyCode: UInt16, characters: String?, time: Double) -> Bool {
        switch keyCode {
        case 126: state.move(-1); return true
        case 125: state.move(1); return true
        case 36, 76: choose(state.committed); return true
        case 53: dismiss(); return true
        default:
            guard let characters, !characters.isEmpty,
                  characters.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "&" }) else { return false }
            state.type(characters, at: time)
            return true
        }
    }
}

/// The flat chooser: the seven tools, each with its symbol, exact name, a checkmark on the
/// chosen one, a labelled dot when its work is running and its key. Live commands
/// sit under their owner, with independent activities after the seven tools. Hovering highlights a row, as a menu does; only a click chooses.
public struct ToolbarChooserView: View {
    @ObservedObject var model: ToolbarChooserModel
    let textScale: CGFloat
    let accent: Color
    /// The height the display leaves; the list scrolls only when it is shorter than the list.
    let available: CGFloat?
    let availableWidth: CGFloat?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .body) private var systemScale: CGFloat = 1
    /// VoiceOver's cursor follows the keyboard highlight, so Up, Down and typing are heard.
    @AccessibilityFocusState private var voiceOverRow: ToolbarMode?

    public init(model: ToolbarChooserModel, textScale: CGFloat = 1, accent: Color = .accentColor, available: CGFloat? = nil, availableWidth: CGFloat? = nil) {
        self.model = model; self.textScale = textScale; self.accent = accent; self.available = available
        self.availableWidth = availableWidth
    }
    private var scale: CGFloat { textScale * systemScale }
    private var commandColumns: Int { (availableWidth ?? .infinity) < ToolbarChooserLayout.width * scale ? 1 : 2 }

    public var body: some View {
        let natural = ToolbarChooserLayout.height(rows: model.state.choices.count, scale: scale)
            + CGFloat(model.state.choices.reduce(0) { $0 + actionHeight($1.actions, detail: $1.detail) }
                + model.activities.rows.reduce(0) { $0 + 36 + actionHeight($1.actions, detail: $1.detail) }
                + (model.activities.rows.isEmpty ? 0 : 9) + 45) * scale
        let list = VStack(spacing: 0) {
            ForEach(model.state.choices) { choice in
                VStack(alignment: .leading, spacing: 0) {
                    row(choice)
                    commands(choice.actions, detail: choice.detail)
                }.id(choice.mode)
            }
            if !model.activities.rows.isEmpty { Divider().padding(.vertical, 4 * scale) }
            ForEach(model.activities.rows) { activity in
                VStack(alignment: .leading, spacing: 0) {
                    Label(activity.title, systemImage: activity.symbol)
                        .font(.system(size: 13 * scale, weight: .medium)).frame(height: 36 * scale)
                        .padding(.horizontal, 14 * scale)
                    commands(activity.actions, detail: activity.detail)
                }
            }
            Divider().padding(.vertical, 4 * scale)
            ToolbarChooserCommandButton(action: .init("open-tool", "Open " + model.selected.title + "…"),
                model: model, scale: scale, opensTool: model.selected)
                .frame(maxWidth: .infinity, minHeight: 36 * scale)
                .padding(.horizontal, 14 * scale)
        }
            .padding(.vertical, ToolbarChooserLayout.verticalPadding * scale)
        Group {
            if let available, available < natural {
                // On a short display the list scrolls to keep the keyboard highlight in view.
                ScrollViewReader { proxy in
                    ScrollView { list }.frame(height: available)
                        .onChange(of: model.state.highlighted) { _, mode in proxy.scrollTo(mode) }
                }
            } else { list }
        }
        .frame(width: min(ToolbarChooserLayout.width * scale, availableWidth ?? .infinity))
        .background {
            let shape = RoundedRectangle(cornerRadius: 12)
            if reduceTransparency { shape.fill(Color(nsColor: .windowBackgroundColor)) } else { shape.fill(.regularMaterial) }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.14), lineWidth: 1))
        .tint(accent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose a tool")
        .onChange(of: model.state.highlighted) { _, mode in voiceOverRow = mode }
    }

    private func actionHeight(_ actions: [ToolbarChooserAction], detail: String?) -> Int {
        (detail == nil ? 0 : 20) + ((actions.count + commandColumns - 1) / commandColumns) * 28
    }

    @ViewBuilder private func commands(_ actions: [ToolbarChooserAction], detail: String?) -> some View {
        if let detail {
            Text(detail).font(.system(size: 11 * scale)).foregroundStyle(.secondary)
                .lineLimit(1).help(detail).frame(height: 20 * scale).padding(.horizontal, 14 * scale)
        }
        ForEach(Array(stride(from: 0, to: actions.count, by: commandColumns)), id: \.self) { index in
            HStack(spacing: 6 * scale) {
                ForEach(Array(actions[index..<min(index + commandColumns, actions.count)])) { action in
                    ToolbarChooserCommandButton(action: action, model: model, scale: scale)
                        .frame(maxWidth: .infinity)
                }
            }.frame(height: 28 * scale).padding(.horizontal, 12 * scale)
        }
    }

    private func row(_ choice: ToolbarToolChoice) -> some View {
        let highlighted = model.state.highlighted == choice.mode
        return HStack(spacing: 10 * scale) {
            Image(systemName: choice.mode.symbol).font(.system(size: 15 * scale, weight: .medium))
                .foregroundStyle(choice.isLive ? accent : Color.primary).frame(width: 22 * scale)
            Text(choice.mode.title).font(.system(size: 13 * scale)).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 8 * scale)
            if choice.isLive {
                Circle().fill(accent).frame(width: 6 * scale, height: 6 * scale).help(choice.mode.title + " is running")
            }
            if let key = choice.key {
                Text(key).font(.system(size: 11 * scale, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Image(systemName: "checkmark").font(.system(size: 11 * scale, weight: .semibold))
                .foregroundStyle(accent).opacity(choice.isSelected ? 1 : 0).frame(width: 14 * scale)
        }
        .padding(.horizontal, 12 * scale)
        .frame(height: ToolbarChooserLayout.rowHeight * scale)
        .background {
            RoundedRectangle(cornerRadius: 6).fill(highlighted ? accent.opacity(0.2) : Color.clear).padding(.horizontal, 5 * scale)
        }
        .contentShape(Rectangle())
        .id(choice.mode)
        .onTapGesture { model.choose(choice.mode) }
        .onHover { inside in if inside { model.highlight(choice.mode) } }
        .accessibilityElement(children: .ignore)
        // The keyboard highlight is the selected row; the checkmark is the current tool.
        .accessibilityLabel(choice.mode.title + (choice.isSelected ? ", current tool" : "") + (choice.isLive ? ", running" : "")
                            + (choice.key.map { ", \($0)" } ?? ""))
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityFocused($voiceOverRow, equals: choice.mode)
        .accessibilityAction { model.choose(choice.mode) }
    }
}

/// Native controls keep the command shown at mouse-down, including when an owner completes
/// during AppKit's tracking loop. VoiceOver sees each command separately from tool selection.
private struct ToolbarChooserCommandButton: NSViewRepresentable {
    let action: ToolbarChooserAction
    let model: ToolbarChooserModel
    let scale: CGFloat
    var opensTool: ToolbarMode? = nil
    func makeNSView(context: Context) -> CommandButton { CommandButton() }
    func updateNSView(_ view: CommandButton, context: Context) {
        view.title = action.title; view.font = .systemFont(ofSize: 11 * scale)
        view.setAccessibilityLabel(action.title)
        view.setAccessibilityIdentifier("chooser.action." + action.id)
        view.press = {
            if let mode = opensTool {
                return { if model.selected == mode { model.openTool(mode) } }
            }
            return model.press(action)
        }
        view.escape = model.dismiss
        view.navigate = { event in model.handle(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, time: event.timestamp) }
    }
    final class CommandButton: NSButton {
        var press: (() -> (() -> Void)?)?
        var escape: (() -> Void)?
        var navigate: ((NSEvent) -> Bool)?
        private var commit: (() -> Void)?
        private var trackingPress = false
        override init(frame: NSRect) {
            super.init(frame: frame)
            bezelStyle = .rounded; controlSize = .small
            target = self; action = #selector(run)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            trackingPress = true; commit = press?()
            defer { commit = nil; trackingPress = false }
            super.mouseDown(with: event)
        }
        override func performClick(_ sender: Any?) { press?()?() }
        override func accessibilityPerformPress() -> Bool {
            guard isEnabled, let commit = press?() else { return false }
            commit(); return true
        }
        @objc private func run() { if trackingPress { commit?() } else { press?()?() } }
        override func keyDown(with event: NSEvent) {
            if let window, ToolbarChooserKeyboard.tab(event, in: window, from: self) { return }
            if event.keyCode == 53 { escape?() }
            else if [36, 49, 76].contains(event.keyCode) { performClick(nil) }
            else if !event.modifierFlags.contains(.command), navigate?(event) == true { window?.makeFirstResponder(window?.contentView) }
            else { super.keyDown(with: event) }
        }
    }
}

/// An explicit cycle includes every activity command with Full Keyboard Access on or off.
public enum ToolbarChooserKeyboard {
    @MainActor public static func tab(_ event: NSEvent, in window: NSWindow, from button: NSButton? = nil) -> Bool {
        guard event.keyCode == 48, !event.modifierFlags.contains(.command), let root = window.contentView else { return false }
        func buttons(_ view: NSView) -> [NSButton] {
            let own = (view as? NSButton).map { [$0] } ?? []
            return own + view.subviews.flatMap(buttons)
        }
        let controls = buttons(root).filter { $0.accessibilityIdentifier().hasPrefix("chooser.action.") && $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor }
            .sorted {
                let a = $0.convert($0.bounds, to: nil), b = $1.convert($1.bounds, to: nil)
                return abs(a.midY - b.midY) > 2 ? a.midY > b.midY : a.minX < b.minX
            }
        guard !controls.isEmpty else { return true }
        let backwards = event.modifierFlags.contains(.shift)
        if let button, let index = controls.firstIndex(where: { $0 === button }) {
            let next = index + (backwards ? -1 : 1)
            if controls.indices.contains(next) { window.makeFirstResponder(controls[next]); controls[next].scrollToVisible(controls[next].bounds) }
            else { window.makeFirstResponder(root) }
        } else {
            let control = backwards ? controls.last! : controls.first!
            window.makeFirstResponder(control); control.scrollToVisible(control.bounds)
        }
        return true
    }
}
