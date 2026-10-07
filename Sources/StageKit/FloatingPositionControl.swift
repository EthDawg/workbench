import AppKit
import SwiftUI

/// Position… (#163, #134 Fit rule 1): the eight named docks in one compact control, in place
/// of a submenu of anchors. The floating toolbar and the Timer window share it. Dragging is
/// the everyday way to move either; this is the keyboard and precise way. Arrow keys move
/// between docks, Return or Space applies and Escape closes. Each dock is also a labelled
/// button for the pointer and VoiceOver. `reset` is offered only by a surface that has a
/// Reset position command; `hint` names what else can be dragged.
public struct FloatingPositionControl: View {
    public let current: FloatingControlAnchor?
    public let choose: (FloatingControlAnchor) -> Void
    public let reset: (() -> Void)?
    public let close: () -> Void
    public let hint: String
    public let accessibilityLabel: String
    @State private var selection: FloatingControlAnchor
    @FocusState private var focused: Bool
    private static let pitch = CGSize(width: 42, height: 34)
    private static let cellSize = CGSize(width: 36, height: 28)

    public init(current: FloatingControlAnchor?, choose: @escaping (FloatingControlAnchor) -> Void,
                reset: (() -> Void)?, close: @escaping () -> Void,
                hint: String, accessibilityLabel: String) {
        self.current = current; self.choose = choose; self.reset = reset; self.close = close
        self.hint = hint; self.accessibilityLabel = accessibilityLabel
        _selection = State(initialValue: current ?? .bottom)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Position").font(.system(size: 13, weight: .semibold))
            ZStack(alignment: .topLeading) {
                ForEach(FloatingControlAnchor.allCases) { anchor in
                    Button { choose(anchor) } label: {
                        Label(anchor.title, systemImage: Self.symbol(anchor)).labelStyle(.iconOnly)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(anchor == current ? WorkbenchPalette.accent : Color.primary)
                            .frame(width: Self.cellSize.width, height: Self.cellSize.height)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(anchor == current ? WorkbenchPalette.accent.opacity(0.16) : Color.primary.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(anchor == selection ? WorkbenchPalette.accent : Color.clear, lineWidth: 2))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(anchor.title)
                    .accessibilityAddTraits(anchor == current ? .isSelected : [])
                    .offset(x: CGFloat(Self.cell(anchor).column) * Self.pitch.width,
                            y: CGFloat(Self.cell(anchor).row) * Self.pitch.height)
                }
            }
            .frame(width: Self.pitch.width * 2 + Self.cellSize.width, height: Self.pitch.height * 2 + Self.cellSize.height,
                   alignment: .topLeading)
            if let reset { Button("Reset position", action: reset).controlSize(.small) }
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12)))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            switch press.key {
            case .upArrow: move(column: 0, row: -1)
            case .downArrow: move(column: 0, row: 1)
            case .leftArrow: move(column: -1, row: 0)
            default: move(column: 1, row: 0)
            }
            return .handled
        }
        .onKeyPress(keys: [.return, .space]) { _ in choose(selection); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .tint(WorkbenchPalette.accent)
    }

    /// Where each dock sits in the three-by-three grid; the middle is empty.
    public static func cell(_ anchor: FloatingControlAnchor) -> (column: Int, row: Int) {
        switch anchor {
        case .topLeft: return (0, 0)
        case .top: return (1, 0)
        case .topRight: return (2, 0)
        case .left: return (0, 1)
        case .right: return (2, 1)
        case .bottomLeft: return (0, 2)
        case .bottom: return (1, 2)
        case .bottomRight: return (2, 2)
        }
    }

    /// The dock an arrow key reaches from `anchor`, stepping over the empty middle.
    public static func neighbour(of anchor: FloatingControlAnchor, column dx: Int, row dy: Int) -> FloatingControlAnchor {
        var (column, row) = cell(anchor)
        repeat {
            column += dx; row += dy
            guard (0..<3).contains(column), (0..<3).contains(row) else { return anchor }
        } while !FloatingControlAnchor.allCases.contains { cell($0) == (column, row) }
        return FloatingControlAnchor.allCases.first { cell($0) == (column, row) } ?? anchor
    }

    private func move(column dx: Int, row dy: Int) { selection = Self.neighbour(of: selection, column: dx, row: dy) }

    private static func symbol(_ anchor: FloatingControlAnchor) -> String {
        switch anchor {
        case .topLeft: return "arrow.up.left"
        case .top: return "arrow.up"
        case .topRight: return "arrow.up.right"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .bottomLeft: return "arrow.down.left"
        case .bottom: return "arrow.down"
        case .bottomRight: return "arrow.down.right"
        }
    }
}

/// A key panel that does not activate Workbench, so the app in front keeps its place while
/// the control takes the keyboard.
private final class FloatingPositionWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Why Position… closed, which decides where the keyboard goes next.
public enum FloatingPositionClose: Equatable {
    case chose, reset, escape
    /// A click elsewhere, another window taking the keyboard, a drag or a menu on the owner,
    /// or the owner leaving.
    case dismissed

    /// Opened from the owner's keyboard focus, a choice, Reset or Escape gives the keyboard
    /// back to the owner, so a second Escape leaves for the field it came from. Opened by
    /// pointer, or dismissed, Position… takes the keyboard nowhere.
    public func returnsKeyboard(openedFromKeyboard: Bool) -> Bool { openedFromKeyboard && self != .dismissed }
}

/// Shows Position… where its owner asks and closes it on a choice, Escape or a click elsewhere.
/// The owner supplies the frame for the control's fitted size, so the toolbar keeps its own
/// placement beside a horizontal or vertical row and the Timer sits by its window.
public final class FloatingPositionPanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var closed: ((FloatingPositionClose) -> Void)?
    public var isShown: Bool { panel != nil }
    /// The window on screen, for checks that read its title or frame.
    public var window: NSWindow? { panel }

    public override init() { super.init() }

    public func show(title: String, level: NSWindow.Level, current: FloatingControlAnchor?,
                     hint: String, accessibilityLabel: String,
                     choose: @escaping (FloatingControlAnchor) -> Void, reset: (() -> Void)?,
                     closed: @escaping (FloatingPositionClose) -> Void = { _ in },
                     theme: (AnyView) -> AnyView = { $0 },
                     frame: (NSSize) -> NSRect) {
        close()
        let panel = FloatingPositionWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                           backing: .buffered, defer: false)
        panel.title = title
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let control = FloatingPositionControl(current: current,
            choose: { [weak self] anchor in self?.close(.chose); choose(anchor) },
            reset: reset.map { reset in { [weak self] in self?.close(.reset); reset() } },
            close: { [weak self] in self?.close(.escape) },
            hint: hint, accessibilityLabel: accessibilityLabel)
        let hosting = NSHostingView(rootView: theme(AnyView(control)))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setFrame(frame(size), display: true)
        panel.delegate = self
        self.panel = panel; self.closed = closed
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(hosting)
    }

    public func windowDidResignKey(_ notification: Notification) { close() }

    public func close(_ reason: FloatingPositionClose = .dismissed) {
        guard let panel else { return }
        let closed = self.closed
        self.panel = nil; self.closed = nil
        panel.delegate = nil
        panel.orderOut(nil)
        closed?(reason)
    }
}
