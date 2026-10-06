import AppKit
import ApplicationServices

/// The one door to the Accessibility framework's element IPC (`AXUIElement*`)
/// and observers (`AXObserver*`): every such call in the app is made here, and
/// `scripts/check-accessibility-bridge.py` fails when one appears anywhere else.
///
/// On macOS 26 the speech-voice side of the framework logs an AXCommon fault
/// ("unsafeForcedSync called from Swift Concurrent context") when it runs on a
/// Swift task's thread; `AXUIElement` IPC does not, in any context
/// (`docs/verification/2026-10-06-ax-bridge/`). So `perform` runs its body in
/// place, on the calling thread, with no queue, no wait and no change to a
/// call's messaging timeout: an element keeps the budget its caller set, and
/// one without a budget keeps Apple's default. The voice catalogue is not
/// here; `MacVoiceCatalog` lists it under its own rule (#269).
enum AccessibilityBridge {
    /// Runs `body` on the calling thread and returns its result: the one place
    /// the framework is called, kept as a function so a check or a later
    /// measurement can see every call go through it.
    @inline(__always)
    static func perform<T>(_ body: () -> T) -> T { body() }

    // MARK: Elements

    static func application(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }
    /// The value as an element, or nil for any other type.
    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    static func attribute(_ element: AXUIElement, _ key: String) -> (AXError, CFTypeRef?) {
        perform {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
            return (error, value)
        }
    }
    static func parameterizedAttribute(_ element: AXUIElement, _ key: String, _ parameter: CFTypeRef) -> (AXError, CFTypeRef?) {
        perform {
            var value: CFTypeRef?
            let error = AXUIElementCopyParameterizedAttributeValue(element, key as CFString, parameter, &value)
            return (error, value)
        }
    }
    static func setAttribute(_ element: AXUIElement, _ key: String, _ value: CFTypeRef) -> AXError {
        perform { AXUIElementSetAttributeValue(element, key as CFString, value) }
    }
    /// True only when the application answered and said the attribute is settable.
    static func isAttributeSettable(_ element: AXUIElement, _ key: String) -> Bool {
        perform {
            var settable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(element, key as CFString, &settable) == .success && settable.boolValue
        }
    }
    /// Bounds every later message to this exact element object; equal
    /// elements read later do not inherit it, the process default applies.
    static func setMessagingTimeout(_ element: AXUIElement, _ seconds: Float) -> AXError {
        perform { AXUIElementSetMessagingTimeout(element, seconds) }
    }
    /// A text range attribute's value as an NSRange, when it is one.
    static func range(_ value: CFTypeRef?) -> NSRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(ax) == .cfRange, AXValueGetValue(ax, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
    static func value(_ range: NSRange) -> AXValue? {
        var range = CFRange(location: range.location, length: range.length)
        return AXValueCreate(.cfRange, &range)
    }

    // MARK: Observers

    /// One application's notifications, delivered on the main run loop as
    /// plain frames. The observer's run-loop source is attached to the main
    /// run loop at creation, before any notification is registered; `main`
    /// attached it after its three registrations, a benign difference, since
    /// the source carries nothing until a registration succeeds. `end`
    /// removes every registration and the run loop source.
    final class Observation {
        private var observer: AXObserver?
        private var registrations: [(AXUIElement, String)] = []
        init?(pid: pid_t, callback: AXObserverCallback) {
            var observer: AXObserver?
            guard perform({ AXObserverCreate(pid, callback, &observer) }) == .success, let observer else { return nil }
            self.observer = observer
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        /// Registers one notification; false leaves earlier registrations in place.
        func add(_ element: AXUIElement, _ notification: String, context: UnsafeMutableRawPointer?) -> Bool {
            guard let observer, perform({ AXObserverAddNotification(observer, element, notification as CFString, context) }) == .success else { return false }
            registrations.append((element, notification))
            return true
        }
        func end() {
            guard let observer else { return }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            for (element, notification) in registrations {
                _ = perform { AXObserverRemoveNotification(observer, element, notification as CFString) }
            }
            registrations.removeAll()
            self.observer = nil
        }
    }
}
