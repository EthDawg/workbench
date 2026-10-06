import AppKit
import ApplicationServices
import AVFoundation

/// The one door to the Accessibility framework's synchronous calls: element
/// IPC (`AXUIElement*`), observers (`AXObserver*`) and the Mac voice
/// catalogue, which the speech stack serves through the same framework.
///
/// On macOS 26 a call that waits on another process from a Swift task's
/// thread, main actor or not, logs an AXCommon fault ("unsafeForcedSync called
/// from Swift Concurrent context"). Listing the voices alone logged about 741
/// of them each time Workbench came to the front. The bridge runs each call on
/// its own serial queue when the caller is inside a task and inline from a
/// plain frame (a timer, an event monitor, an observer callback), so ordering,
/// timeouts and results are those of a direct call. Reads without a timeout of
/// their own wait at most `defaultTimeout` per message instead of Apple's six
/// seconds. `scripts/check-accessibility-bridge.py` keeps every such call here.
enum AccessibilityBridge {
    /// The process-wide messaging timeout, in seconds, for elements without their own.
    static let defaultTimeout: Float = 1
    private static let queue = DispatchQueue(label: "Workbench.AccessibilityBridge", qos: .userInitiated)
    private static let queueKey = DispatchSpecificKey<Bool>()
    private static let prepared: Bool = {
        queue.setSpecific(key: queueKey, value: true)
        // The system-wide element carries the default for every element that
        // has not set its own; a budgeted read's shorter timeout still wins.
        _ = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), defaultTimeout)
        return true
    }()
    private final class Box<T>: @unchecked Sendable { var value: T? }
    /// True while the current frame runs on the bridge's queue; checks read it.
    static var isOnQueue: Bool { DispatchQueue.getSpecific(key: queueKey) == true }

    /// Runs `body` where macOS counts it as plain code and returns its result.
    /// Inside a task the call hops to the bridge's queue and waits; from a
    /// plain frame, or from the queue itself, it runs in place.
    static func perform<T>(_ body: () -> T) -> T {
        _ = prepared
        if isOnQueue || withUnsafeCurrentTask(body: { $0 == nil }) { return body() }
        let box = Box<T>(), done = DispatchSemaphore(value: 0)
        withoutActuallyEscaping(body) { body in
            queue.async { box.value = body(); done.signal() }
            done.wait()
        }
        return box.value!
    }

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
    static func performAction(_ element: AXUIElement, _ action: String) -> AXError {
        perform { AXUIElementPerformAction(element, action as CFString) }
    }
    /// Bounds every later message to this exact element object; equal
    /// elements read later do not inherit it, the process default applies.
    static func setMessagingTimeout(_ element: AXUIElement, _ seconds: Float) -> AXError {
        perform { AXUIElementSetMessagingTimeout(element, seconds) }
    }
    /// The element an application reports as focused, or nil.
    static func focusedElement(of pid: pid_t) -> AXUIElement? {
        element(attribute(application(pid), kAXFocusedUIElementAttribute).1)
    }
    /// An application's focus, read in one hop.
    struct ApplicationSnapshot {
        var application: AXUIElement
        var focusedElement: AXUIElement?
        var focusedWindow: AXUIElement?
    }
    static func snapshot(of pid: pid_t) -> ApplicationSnapshot {
        let app = application(pid)
        return perform {
            var focused: CFTypeRef?, window: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
            _ = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window)
            return ApplicationSnapshot(application: app, focusedElement: element(focused), focusedWindow: element(window))
        }
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
    /// plain frames. `end` removes every registration and the run loop source.
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

    // MARK: Voices

    /// What the catalogue reads of an installed voice, read in the same hop as the listing.
    struct SpeechVoice {
        var identifier: String
        var name: String
        var language: String
        var quality: AVSpeechSynthesisVoiceQuality
        var traits: AVSpeechSynthesisVoice.Traits
    }
    static func speechVoices() -> [SpeechVoice] {
        perform {
            AVSpeechSynthesisVoice.speechVoices().map {
                SpeechVoice(identifier: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality, traits: $0.voiceTraits)
            }
        }
    }
    static func speechVoice(identifier: String) -> AVSpeechSynthesisVoice? {
        perform { AVSpeechSynthesisVoice(identifier: identifier) }
    }
    /// The voices `say` lists, each with its attributes.
    static func sayVoices() -> [(identifier: NSSpeechSynthesizer.VoiceName, attributes: [NSSpeechSynthesizer.VoiceAttributeKey: Any])] {
        perform { NSSpeechSynthesizer.availableVoices.map { ($0, NSSpeechSynthesizer.attributes(forVoice: $0)) } }
    }
}
