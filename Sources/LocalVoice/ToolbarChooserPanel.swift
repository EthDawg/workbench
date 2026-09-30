import AppKit
import Combine
import SwiftUI
import ToolbarCore
import ToolbarKit

/// Why the chooser closed, which decides where the keyboard goes next (#134).
enum ToolbarChooserClose: Equatable {
    /// A tool was chosen, by click or Return.
    case chose
    /// Escape.
    case escape
    /// A click elsewhere, Command-Tab, the app leaving the front, a display change, a drag
    /// or the toolbar leaving: the chooser goes and takes the keyboard nowhere.
    case dismissed

    /// A choice or Escape returns the keyboard to the launcher, so a second Escape leaves the
    /// toolbar. Dismissal leaves the keyboard with whatever the person moved to.
    var returnsKeyboardToLauncher: Bool { self != .dismissed }
}

/// Where the chooser opens: beside the launcher, on the side of the toolbar with more room,
/// aligned with the launcher's outer edge and kept inside the display.
enum ToolbarChooserPlacement {
    static let gap: CGFloat = 6
    static let edgeMargin: CGFloat = 8

    /// The room above and below the launcher, inside the margins.
    static func room(launcher: NSRect, visible: NSRect) -> (above: CGFloat, below: CGFloat) {
        (max(0, visible.maxY - edgeMargin - (launcher.maxY + gap)), max(0, launcher.minY - gap - (visible.minY + edgeMargin)))
    }

    static func frame(content: NSSize, launcher: NSRect, visible: NSRect, growsLeftward: Bool,
                      anchor: ToolbarAnchor = .bottom, toolbar: NSRect? = nil) -> NSRect {
        if anchor.isVertical {
            return ToolbarGeometry.sidePanelFrame(size: content, toolbar: toolbar ?? launcher, anchor: anchor, visible: visible)
        }
        let room = room(launcher: launcher, visible: visible)
        let above = content.height <= room.above || room.above >= room.below
        let width = min(content.width, visible.width - 2 * edgeMargin)
        let height = min(content.height, above ? room.above : room.below)
        let x = growsLeftward ? launcher.maxX - width : launcher.minX
        let y = above ? launcher.maxY + gap : launcher.minY - gap - height
        return NSRect(x: min(max(x, visible.minX + edgeMargin), visible.maxX - edgeMargin - width).rounded(),
                      y: y.rounded(), width: width.rounded(), height: height.rounded())
    }
}

/// A key panel that never activates Workbench, so the app in front keeps its place.
private final class ToolbarChooserWindow: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    var escape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { escape?() }
}

/// Takes every key the chooser answers, so a focused SwiftUI view never swallows them.
private final class ToolbarChooserContent<Content: View>: NSHostingView<Content> {
    var keyHandler: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }
}

/// The one tool chooser (#134): opened from the launcher by click, Space or Return, anchored
/// to it, and closed by a choice, Escape or anything else taking the person elsewhere.
@MainActor final class ToolbarChooserPanel: NSObject, NSWindowDelegate {
    private var panel: ToolbarChooserWindow?
    private(set) var model: ToolbarChooserModel?
    private var closed: ((ToolbarChooserClose) -> Void)?
    private var monitors: [Any] = []
    private weak var launcher: NSView?
    /// The surface gallery opens the real panel invisibly to check where it lands: no
    /// keyboard, no pointer and no click monitors, so a local run never takes anyone's input.
    var offscreenForChecks = false
    var isShown: Bool { panel != nil }
    var shownFrame: NSRect? { panel?.frame }

    /// - Parameters:
    ///   - launcher: the launcher's frame on screen; `view` is the launcher itself, whose
    ///     click only closes an open chooser, so the launcher toggles it.
    func show(from launcherFrame: NSRect, view: NSView?, level: NSWindow.Level, growsLeftward: Bool, choices: [ToolbarToolChoice],
              anchor: ToolbarAnchor = .bottom, toolbar: NSRect? = nil,
              textScale: CGFloat = 1, choose: @escaping (ToolbarMode) -> Void, closed: @escaping (ToolbarChooserClose) -> Void) {
        close()
        let centre = NSPoint(x: launcherFrame.midX, y: launcherFrame.midY)
        guard let visible = (NSScreen.screens.first { $0.frame.contains(centre) } ?? NSScreen.main)?.visibleFrame else {
            closed(.dismissed); return
        }
        let model = ToolbarChooserModel(choices: choices)
        model.choose = { [weak self] mode in self?.close(.chose); choose(mode) }
        model.dismiss = { [weak self] in self?.close(.escape) }
        let room = ToolbarChooserPlacement.room(launcher: launcherFrame, visible: visible)
        let natural = NSHostingView(rootView: ToolbarChooserView(model: model, textScale: textScale, accent: Workbench.accent)).fittingSize
        let frame = ToolbarChooserPlacement.frame(content: natural, launcher: launcherFrame, visible: visible, growsLeftward: growsLeftward,
                                                  anchor: anchor, toolbar: toolbar)
        let above = natural.height <= room.above || room.above >= room.below
        let available = anchor.isVertical ? visible.height - 2 * ToolbarChooserPlacement.edgeMargin : above ? room.above : room.below
        let hosting = ToolbarChooserContent(rootView: ToolbarChooserView(model: model, textScale: textScale, accent: Workbench.accent,
                                                                          available: available, availableWidth: frame.width))
        hosting.sizingOptions = []
        let panel = ToolbarChooserWindow(contentRect: NSRect(origin: .zero, size: frame.size),
                                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Choose a tool"
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let keys: (NSEvent) -> Bool = { [weak model] event in
            model?.handle(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, time: event.timestamp) ?? false
        }
        panel.keyHandler = keys; hosting.keyHandler = keys
        panel.escape = { [weak model] in model?.dismiss() }
        panel.contentView = hosting
        panel.setFrame(frame, display: false)
        panel.delegate = self
        self.panel = panel; self.model = model; self.closed = closed; launcher = view
        if offscreenForChecks {
            panel.alphaValue = 0; panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
            return
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(hosting)
        monitors = [
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.consumes(event) ?? false } ? nil : event
            },
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.close(.dismissed) }
            }
        ].compactMap { $0 }
    }

    /// New live facts while open: rows update, the highlight stays on the same tool.
    func refresh(_ choices: [ToolbarToolChoice]) { model?.refresh(choices) }

    /// A click outside closes the chooser. On the launcher the click only closes it.
    private func consumes(_ event: NSEvent) -> Bool {
        guard let panel, event.window !== panel else { return false }
        let onLauncher = launcher.map { view in
            event.window === view.window && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        } ?? false
        close(.dismissed)
        return onLauncher
    }

    func windowDidResignKey(_ notification: Notification) { close(.dismissed) }

    func close(_ reason: ToolbarChooserClose = .dismissed) {
        guard let panel else { return }
        let closed = self.closed
        self.panel = nil; self.closed = nil; model = nil; launcher = nil
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        panel.delegate = nil
        panel.orderOut(nil)
        // A row's own action can close the chooser, so its view outlives that action.
        Task { @MainActor in panel.contentView = nil }
        closed?(reason)
    }
}
