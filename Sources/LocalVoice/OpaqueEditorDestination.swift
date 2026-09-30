import AppKit

/// Sublime exposes its editor as a window, without a readable AX text field.
/// A dictation may send one paste to that captured window while it remains
/// untouched. It never claims confirmed insertion or restores the clipboard.
/// Other unreadable applications still copy; Saved Prompts do not arm this path.
@MainActor
final class OpaqueEditorDestination {
    struct Window {
        var element: AXUIElement
        var title: String
    }
    private let current: () -> Bool
    private let observe: (VoiceShortcut, @escaping () -> Void) -> (() -> Void)?
    private var stop: (() -> Void)?
    private(set) var active = false
    private(set) var invalidated = false

    init(current: @escaping () -> Bool,
         observe: @escaping (VoiceShortcut, @escaping () -> Void) -> (() -> Void)?) {
        self.current = current; self.observe = observe
    }
    deinit { stop?() }

    static let observationInterval: TimeInterval = 0.35
    static let inputEvents: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    static func supports(_ bundleID: String?) -> Bool { bundleID == "com.sublimetext.4" || bundleID == "com.sublimetext.3" }

    /// Bounds the whole snapshot as well as each IPC. Set the timeout on each
    /// exact AX object; Apple's setting is not inherited by equal objects.
    final class ReadBudget {
        static let maximum: TimeInterval = 0.06
        private let now: () -> TimeInterval
        private let deadline: TimeInterval
        private let setTimeout: (AXUIElement, Float) -> AXError
        private let read: (AXUIElement, String) -> (AXError, CFTypeRef?)
        private(set) var valid = true
        init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
             setTimeout: @escaping (AXUIElement, Float) -> AXError = { AXUIElementSetMessagingTimeout($0, $1) },
             read: @escaping (AXUIElement, String) -> (AXError, CFTypeRef?) = { element, key in
                 var value: CFTypeRef?
                 let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
                 return (result, value)
             }) {
            self.now = now; deadline = now() + Self.maximum; self.setTimeout = setTimeout; self.read = read
        }
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            let remaining = deadline - now()
            guard valid, remaining > 0,
                  setTimeout(element, Float(min(0.03, remaining))) == .success else { valid = false; return nil }
            let (result, value) = read(element, key)
            guard now() < deadline else { valid = false; return nil }
            switch result {
            case .success: return value
            case .attributeUnsupported, .noValue: return nil
            default: valid = false; return nil
            }
        }
    }
    private static func liveWindow(app: NSRunningApplication) -> Window? {
        let budget = ReadBudget()
        var ax = TextDelivery.Accessibility.live
        ax.attribute = budget.attribute
        let result = window(pid: app.processIdentifier, bundleID: app.bundleIdentifier, accessibility: ax)
        return budget.valid ? result : nil
    }
    static func capture(app: NSRunningApplication) -> OpaqueEditorDestination? {
        guard let captured = liveWindow(app: app) else { return nil }
        let current = {
            guard !app.isTerminated,
                  let now = liveWindow(app: app) else { return false }
            return CFEqual(captured.element, now.element) && captured.title == now.title
        }
        return OpaqueEditorDestination(current: current, observe: { shortcut, invalidate in
            // Apple's global monitor observes events delivered outside Workbench.
            // The nonactivating Stop button is ours and does not edit Sublime.
            guard let input = NSEvent.addGlobalMonitorForEvents(matching: inputEvents, handler: { event in
                if event.type == .keyDown, shortcut.enabled, VoiceShortcut(event: event) == shortcut { return }
                invalidate()
            }) else { return nil }
            let center = NSWorkspace.shared.notificationCenter
            let activation = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
                let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if activated?.processIdentifier != app.processIdentifier { invalidate() }
            }
            let sleep = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in invalidate() }
            // Also notice a programmatically changed window, title, sheet or AX
            // focus; no text or keystroke content is retained by the observation.
            let timer = Timer(timeInterval: observationInterval, repeats: true) { _ in if !current() { invalidate() } }
            RunLoop.main.add(timer, forMode: .common)
            return { NSEvent.removeMonitor(input); center.removeObserver(activation); center.removeObserver(sleep); timer.invalidate() }
        })
    }

    /// Exact observed shape: a standard window is both the focused window and
    /// focused element. A dialog, sheet, secure field or unknown tree is refused.
    static func window(pid: pid_t, bundleID: String?, accessibility ax: TextDelivery.Accessibility) -> Window? {
        guard supports(bundleID),
              ax.isTrusted(), ax.frontmostPID() == pid else { return nil }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        let app = AXUIElementCreateApplication(pid)
        guard let focused = element(ax.attribute(app, kAXFocusedUIElementAttribute)),
              let window = element(ax.attribute(app, kAXFocusedWindowAttribute)), CFEqual(focused, window),
              ax.attribute(window, kAXRoleAttribute) as? String == kAXWindowRole,
              ax.attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              ax.attribute(window, kAXModalAttribute) as? Bool != true,
              ax.attribute(window, kAXMinimizedAttribute) as? Bool != true,
              let title = ax.attribute(window, kAXTitleAttribute) as? String, !title.isEmpty else { return nil }
        let children = ax.attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
        guard !children.contains(where: { ax.attribute($0, kAXRoleAttribute) as? String == kAXSheetRole }) else { return nil }
        return Window(element: window, title: title)
    }

    func begin(shortcut: VoiceShortcut) {
        guard !active, !invalidated, current() else { invalidate(); return }
        active = true
        stop = observe(shortcut, { [weak self] in self?.invalidate() })
        if stop == nil || !current() { invalidate() }
    }
    var isEligible: Bool {
        guard active, !invalidated else { return false }
        if !current() { invalidate(); return false }
        return true
    }
    private func invalidate() { invalidated = true; end() }
    func end() { active = false; let cleanup = stop; stop = nil; cleanup?() }
}
