import AppKit
import StageKit
import SwiftUI
import ToolbarCore
import ToolbarKit

/// Position… (#163): the toolbar's named docks and a reset in one compact control, in place
/// of an eight-item submenu. Dragging is the everyday way to move the toolbar; this is the
/// keyboard and precise way. Arrow keys move between docks, Return or Space moves the toolbar
/// there and Escape closes. Each dock is also a labelled button for the pointer and VoiceOver.
struct ToolbarPositionControl: View {
    let current: FloatingControlAnchor?
    let choose: (FloatingControlAnchor) -> Void
    let reset: () -> Void
    let close: () -> Void
    @State private var selection: FloatingControlAnchor
    @FocusState private var focused: Bool
    private static let pitch = CGSize(width: 42, height: 34)
    private static let cellSize = CGSize(width: 36, height: 28)

    init(current: FloatingControlAnchor?, choose: @escaping (FloatingControlAnchor) -> Void,
         reset: @escaping () -> Void, close: @escaping () -> Void) {
        self.current = current; self.choose = choose; self.reset = reset; self.close = close
        _selection = State(initialValue: current ?? .bottom)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Position").font(.system(size: 13, weight: .semibold))
            ZStack(alignment: .topLeading) {
                ForEach(FloatingControlAnchor.allCases) { anchor in
                    Button { choose(anchor) } label: {
                        Label(anchor.title, systemImage: Self.symbol(anchor)).labelStyle(.iconOnly)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(anchor == current ? Workbench.accent : Color.primary)
                            .frame(width: Self.cellSize.width, height: Self.cellSize.height)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(anchor == current ? Workbench.accent.opacity(0.16) : Color.primary.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(anchor == selection ? Workbench.accent : Color.clear, lineWidth: 2))
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
            Button("Reset position", action: reset).controlSize(.small)
            Text("Or drag the toolbar anywhere.").font(.system(size: 11)).foregroundStyle(.secondary)
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
        .accessibilityLabel("Toolbar position")
        .tint(Workbench.accent).workbenchTheme()
    }

    /// Where each dock sits in the three-by-three grid; the middle is empty.
    static func cell(_ anchor: FloatingControlAnchor) -> (column: Int, row: Int) {
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
    static func neighbour(of anchor: FloatingControlAnchor, column dx: Int, row dy: Int) -> FloatingControlAnchor {
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
private final class ToolbarPositionWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Why Position… closed, which decides where the keyboard goes next.
enum ToolbarPositionClose: Equatable {
    case chose, reset, escape
    /// A click elsewhere, another window taking the keyboard, a drag or a menu on the toolbar,
    /// or the toolbar leaving.
    case dismissed

    /// Opened from the toolbar's keyboard focus, a choice, Reset or Escape gives the keyboard
    /// back to the toolbar, so a second Escape leaves for the field it came from. Opened by
    /// pointer, or dismissed, Position… takes the keyboard nowhere.
    func returnsKeyboard(openedFromKeyboard: Bool) -> Bool { openedFromKeyboard && self != .dismissed }
}

/// Shows Position… beside the toolbar and closes it on a choice, Escape or a click elsewhere.
@MainActor final class ToolbarPositionPanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var closed: ((ToolbarPositionClose) -> Void)?
    var isShown: Bool { panel != nil }

    func show(beside toolbar: NSRect, level: NSWindow.Level, current: FloatingControlAnchor?,
              anchor: ToolbarAnchor = .bottom,
              choose: @escaping (FloatingControlAnchor) -> Void, reset: @escaping () -> Void,
              closed: @escaping (ToolbarPositionClose) -> Void = { _ in }) {
        close()
        let panel = ToolbarPositionWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        panel.title = "Toolbar position"
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: ToolbarPositionControl(current: current,
            choose: { [weak self] anchor in self?.close(.chose); choose(anchor) },
            reset: { [weak self] in self?.close(.reset); reset() },
            close: { [weak self] in self?.close(.escape) }))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setFrame(Self.frame(size: size, beside: toolbar, anchor: anchor), display: true)
        panel.delegate = self
        self.panel = panel; self.closed = closed
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(hosting)
    }

    /// Above a toolbar in the lower half of its display, otherwise below it, kept on screen.
    static func frame(size: NSSize, beside toolbar: NSRect,
                      anchor: ToolbarAnchor = .bottom,
                      screens: [NSRect] = NSScreen.screens.map(\.visibleFrame)) -> NSRect {
        let screen = FloatingControlPlacement.screen(for: toolbar, screens: screens, preferred: screens.first ?? toolbar)
        if anchor.isVertical { return ToolbarGeometry.sidePanelFrame(size: size, toolbar: toolbar, anchor: anchor, visible: screen) }
        let y = toolbar.midY < screen.midY ? toolbar.maxY + 8 : toolbar.minY - 8 - size.height
        return FloatingControlGeometry.clamp(NSRect(origin: NSPoint(x: toolbar.minX, y: y), size: size), to: screen, inset: 0)
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    func close(_ reason: ToolbarPositionClose = .dismissed) {
        guard let panel else { return }
        let closed = self.closed
        self.panel = nil; self.closed = nil
        panel.delegate = nil
        panel.orderOut(nil)
        closed?(reason)
    }
}
