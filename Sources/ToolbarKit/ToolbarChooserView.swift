import AppKit
import SwiftUI
import ToolbarCore

/// The chooser's measures (#134): 280 points wide with 36-point rows at standard text.
public enum ToolbarChooserLayout {
    public static let width: CGFloat = 280
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
    public var choose: (ToolbarMode) -> Void
    public var dismiss: () -> Void

    public init(choices: [ToolbarToolChoice], choose: @escaping (ToolbarMode) -> Void = { _ in }, dismiss: @escaping () -> Void = {}) {
        state = ToolbarChooserState(choices: choices)
        self.choose = choose; self.dismiss = dismiss
    }

    /// Live facts changed while the chooser is open; the rows update, the highlight stays put.
    public func refresh(_ choices: [ToolbarToolChoice]) { state.refresh(choices) }
    public func highlight(_ mode: ToolbarMode) { state.highlight(mode) }

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
/// chosen one, a labelled dot when its work is running and its key. Nothing is nested,
/// searched or grouped. Hovering highlights a row, as a menu does; only a click chooses.
public struct ToolbarChooserView: View {
    @ObservedObject var model: ToolbarChooserModel
    let textScale: CGFloat
    let accent: Color
    /// The height the display leaves; the list scrolls only when it is shorter than the list.
    let available: CGFloat?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .body) private var systemScale: CGFloat = 1
    /// VoiceOver's cursor follows the keyboard highlight, so Up, Down and typing are heard.
    @AccessibilityFocusState private var voiceOverRow: ToolbarMode?

    public init(model: ToolbarChooserModel, textScale: CGFloat = 1, accent: Color = .accentColor, available: CGFloat? = nil) {
        self.model = model; self.textScale = textScale; self.accent = accent; self.available = available
    }
    private var scale: CGFloat { textScale * systemScale }

    public var body: some View {
        let natural = ToolbarChooserLayout.height(rows: model.state.choices.count, scale: scale)
        let list = VStack(spacing: 0) { ForEach(model.state.choices) { row($0) } }
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
        .frame(width: ToolbarChooserLayout.width * scale)
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
