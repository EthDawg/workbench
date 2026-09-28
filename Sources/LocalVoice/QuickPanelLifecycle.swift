import AppKit

/// The menu-bar panel's inline shortcut editor, for one visit. NSPopover keeps
/// the panel's SwiftUI content alive between visits and never tells it that it
/// closed: no onDisappear, and onAppear only once. So the editor cannot own its
/// own teardown. The panel's host ends it whenever the popover opens or closes,
/// whatever closed it (#153).
@MainActor
final class PanelShortcutEditor: ObservableObject {
    /// The catalogue entry being changed, or nil while the editor is closed.
    @Published private(set) var shortcutID: String?
    let keyboard: KeyboardCoachModel

    init(keyboard: KeyboardCoachModel) { self.keyboard = keyboard }

    /// Opens the editor on one shortcut and starts recording. Another row's
    /// label replaces this editor; it never keeps the first one's recording.
    func change(_ id: String) {
        keyboard.selectedID = id
        shortcutID = id
        keyboard.beginRecording()
    }

    /// Done, the panel closing and the panel opening all end here: recording
    /// stops, global actions resume and the next visit starts without the well.
    /// Feedback is cleared only when this editor was open, so the Keyboard
    /// page keeps its own last message.
    func end() {
        let wasOpen = shortcutID != nil
        keyboard.stopInteraction()
        shortcutID = nil
        if wasOpen { keyboard.clearFeedback() }
    }
}

/// The panel leaves when you do. NSPopover's transient behaviour reacts only
/// to events Workbench itself receives, and AppKit leaves its exact triggers
/// unspecified, so a click in another app that did not deactivate Workbench
/// left the panel open.
/// While the panel shows, a click in any other app or Workbench giving up
/// focus closes it. The monitor sees mouse presses only, needs no permission
/// and stops when the panel closes.
@MainActor
final class PanelLeaveWatch {
    private let notifications: NotificationCenter
    private let addMonitor: (@escaping () -> Void) -> Any?
    private let removeMonitor: (Any) -> Void
    private var monitor: Any?
    private var observer: NSObjectProtocol?

    init(notifications: NotificationCenter = .default,
         addMonitor: @escaping (@escaping () -> Void) -> Any? = { leave in
             NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in leave() }
         },
         removeMonitor: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) }) {
        self.notifications = notifications; self.addMonitor = addMonitor; self.removeMonitor = removeMonitor
    }

    var isWatching: Bool { monitor != nil || observer != nil }

    func watch(_ leave: @escaping @MainActor () -> Void) {
        stop()
        monitor = addMonitor { MainActor.assumeIsolated { leave() } }
        observer = notifications.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { leave() }
        }
    }

    func stop() {
        if let monitor { removeMonitor(monitor); self.monitor = nil }
        if let observer { notifications.removeObserver(observer); self.observer = nil }
    }
}
