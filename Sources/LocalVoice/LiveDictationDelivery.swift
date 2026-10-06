import AppKit

/// Owns only the span selected when Dictate began. Every mutation uses AXSelectedText,
/// never AXValue or a paste event. An uncertain mutation permanently closes this owner.
@MainActor
final class LiveDictationDelivery {
    @MainActor struct System {
        /// Returns nil unless the exact captured, non-secure field is still focused.
        var read: () -> TextDelivery.FieldState?
        var canReplaceSelection: () -> Bool
        var select: (NSRange) -> Bool
        var replaceSelection: (String) -> Bool
        var observe: (@escaping () -> Void, @escaping () -> Void) -> (() -> Void)?
        var copy: (String) -> Int? = { TextDelivery.copy($0) }
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    }

    static let maximumUTF16Length = 1_000_000
    static let updateInterval: TimeInterval = 0.35
    private let system: System
    private let original: TextDelivery.FieldState
    private let originalText: String
    private let name: String
    private var expected: TextDelivery.FieldState
    private var owned: NSRange
    private var stopObservation: (() -> Void)?
    private var lastUpdate = -Double.infinity
    private var writing = false
    private var ended = false
    private(set) var attempted = false
    private(set) var invalidated = false
    private(set) var insertedText = ""
    /// The text either side of the owned span and the boundary context (#14). The first
    /// partial establishes the prefix; later partials and the final cleanup keep it.
    private let boundary: (before: String, after: String, context: InsertionBoundary.Context)
    private var fitPrefix: String?

    /// Nil means unsupported from the outset: the ordinary final-delivery path remains.
    init?(initial: TextDelivery.FieldState, destinationName: String, system: System, context: InsertionBoundary.Context = .init()) {
        guard let value = initial.value, value.utf16.count <= Self.maximumUTF16Length,
              let selection = initial.selection, let range = Self.range(selection, in: value),
              system.canReplaceSelection() else { return nil }
        self.system = system; original = initial; expected = initial; owned = selection
        originalText = String(value[range]); name = destinationName
        boundary = (String(value[..<range.lowerBound]), String(value[range.upperBound...]), context)
        guard system.read() == initial else { invalidated = true; return }
        stopObservation = system.observe({ [weak self] in self?.invalidate() }, { [weak self] in self?.check() })
        guard stopObservation != nil else { return nil }
        check()
    }

    deinit { stopObservation?() }

    static func range(_ range: NSRange, in value: String) -> Range<String.Index>? {
        let units = value as NSString
        guard range.location >= 0, range.length >= 0, range.location <= units.length,
              range.length <= units.length - range.location else { return nil }
        func splitsSurrogate(_ offset: Int) -> Bool {
            offset > 0 && offset < units.length && (0xD800...0xDBFF).contains(units.character(at: offset - 1))
                && (0xDC00...0xDFFF).contains(units.character(at: offset))
        }
        guard !splitsSurrogate(range.location), !splitsSurrogate(range.location + range.length) else { return nil }
        return Range(range, in: value)
    }

    static func begin(target: TextDelivery.Target?, shortcut: VoiceShortcut, context: InsertionBoundary.Context = .init()) -> LiveDictationDelivery? {
        guard let target, target.opaqueEditor == nil, target.element != nil else { return nil }
        return LiveDictationDelivery(initial: .init(value: target.value, selection: target.selection),
            destinationName: target.app.localizedName ?? "your app", system: .live(target: target, shortcut: shortcut), context: context)
    }
    /// Dictated words fitted to the text around the owned span; cancel never uses it.
    private func fitted(_ text: String) -> String {
        var fit = InsertionBoundary.fit(before: boundary.before, after: boundary.after, dictated: text, context: boundary.context)
        if let fitPrefix { fit.prefix = fitPrefix } else { fitPrefix = fit.prefix }
        return fit.text
    }

    func invalidate() {
        invalidated = true
        let stop = stopObservation; stopObservation = nil; stop?()
    }
    func check() {
        guard !ended, !invalidated, !writing else { return }
        if system.read() != expected { invalidate() }
    }
    func end() {
        ended = true
        let stop = stopObservation; stopObservation = nil; stop?()
    }

    func preview(_ text: String) {
        guard !text.isEmpty, system.now() - lastUpdate >= Self.updateInterval else { return }
        let fitted = fitted(text)
        guard fitted != insertedText else { return }
        lastUpdate = system.now()
        _ = replace(fitted)
    }

    /// The caller commits History first. This result replaces final paste even if the
    /// field changed: a partial live insertion must never cause a duplicate full paste.
    func finish(_ text: String, restoreClipboard: Bool) -> TextDelivery.Outcome {
        let success = replace(fitted(text))
        end()
        // Live AX writes never use the clipboard. Preserve it by doing nothing when
        // requested; otherwise keep the final words copied, as ordinary paste does.
        let copied = restoreClipboard ? nil : system.copy(text)
        if success {
            return .init(message: "Inserted into \(name)." + (!restoreClipboard && copied == nil ? " The transcript could not be copied; it is saved in History." : ""),
                         clipboardChangeCount: copied, wasPasted: true, destinationName: name,
                         pasteWasAttempted: attempted)
        }
        return .init(message: "Live insertion stopped. Review the text in \(name); the complete transcript is saved in History. Nothing was pasted again.",
                     clipboardChangeCount: copied, wasPasted: false, destinationName: name,
                     failure: .pasteUnconfirmed, pasteWasAttempted: attempted)
    }

    /// Nil confirms either no mutation or exact rollback. A message means leave the
    /// destination untouched and retain recovery audio for the person's review.
    func cancel() -> String? {
        defer { end() }
        guard attempted else { return nil }
        guard replace(originalText, restoring: original.selection), system.read() == original else {
            return "Recording cancelled. The field in \(name) was left as it is because its original state could not be restored safely. Recording audio is kept for review."
        }
        return nil
    }

    @discardableResult
    private func replace(_ text: String, restoring selection: NSRange? = nil) -> Bool {
        guard !ended, !invalidated, !writing, text.utf16.count <= Self.maximumUTF16Length,
              let before = expected.value, let range = Self.range(owned, in: before),
              system.canReplaceSelection(), system.read() == expected, !invalidated else { invalidate(); return false }
        var after = before; after.replaceSubrange(range, with: text)
        guard after.utf16.count <= Self.maximumUTF16Length else { invalidate(); return false }
        let caret = NSRange(location: owned.location + text.utf16.count, length: 0)
        let desired = selection ?? caret
        guard Self.range(desired, in: after) != nil else { invalidate(); return false }
        if after == before, expected.selection == desired {
            insertedText = text
            return true
        }
        writing = true
        defer { writing = false }
        // Setting the selection is already a mutation: even a timeout cannot safely
        // fall back to a paste or assume that nothing happened in the other app.
        attempted = true
        guard system.select(owned), !invalidated,
              system.read() == .init(value: before, selection: owned), !invalidated,
              system.replaceSelection(text), !invalidated,
              system.read() == .init(value: after, selection: caret), !invalidated else { invalidate(); return false }
        if desired != caret {
            guard system.select(desired), !invalidated, system.read() == .init(value: after, selection: desired), !invalidated else { invalidate(); return false }
        }
        owned.length = text.utf16.count
        expected = .init(value: after, selection: desired)
        insertedText = text
        return true
    }
}

extension LiveDictationDelivery.System {
    static func live(target: TextDelivery.Target, shortcut: VoiceShortcut) -> Self {
        let read: () -> TextDelivery.FieldState? = {
            let budget = LiveDictationAXBudget()
            let ax = budget.accessibility
            guard TextDelivery.eligible(target, accessibility: ax) else { return nil }
            let state = TextDelivery.fieldState(target.element, accessibility: ax)
            guard budget.valid, let value = state.value, value.utf16.count <= LiveDictationDelivery.maximumUTF16Length,
                  let selection = state.selection, LiveDictationDelivery.range(selection, in: value) != nil else { return nil }
            return state
        }
        return .init(read: read, canReplaceSelection: {
            guard let element = target.element,
                  AXUIElementSetMessagingTimeout(element, 0.03) == .success else { return false }
            var range = DarwinBoolean(false), text = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success && range.boolValue
                && AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &text) == .success && text.boolValue
        }, select: { selection in
            guard let element = target.element, AXUIElementSetMessagingTimeout(element, 0.03) == .success else { return false }
            var range = CFRange(location: selection.location, length: selection.length)
            guard let value = AXValueCreate(.cfRange, &range) else { return false }
            return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
        }, replaceSelection: { text in
            guard let element = target.element, AXUIElementSetMessagingTimeout(element, 0.03) == .success else { return false }
            return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        }, observe: { invalidate, check in
            guard let input = NSEvent.addGlobalMonitorForEvents(matching: OpaqueEditorDestination.inputEvents, handler: { event in
                if event.type == .keyDown, shortcut.enabled, VoiceShortcut(event: event) == shortcut { return }
                invalidate()
            }) else { return nil }
            let center = NSWorkspace.shared.notificationCenter
            let activation = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.processIdentifier != target.app.processIdentifier { invalidate() }
            }
            let sleep = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in invalidate() }
            let observer = LiveDictationAXObserver(target: target, invalidate: invalidate, check: check)
            guard let observer else { NSEvent.removeMonitor(input); center.removeObserver(activation); center.removeObserver(sleep); return nil }
            let timer = Timer(timeInterval: 0.2, repeats: true) { _ in check() }
            RunLoop.main.add(timer, forMode: .common)
            return { NSEvent.removeMonitor(input); center.removeObserver(activation); center.removeObserver(sleep); timer.invalidate(); observer.end() }
        })
    }
}

/// At most 60 ms per exact-field snapshot; every AX object receives its own IPC timeout.
@MainActor
private final class LiveDictationAXBudget {
    private let deadline = ProcessInfo.processInfo.systemUptime + 0.06
    private(set) var valid = true
    private func read(_ element: AXUIElement, _ body: () -> (AXError, CFTypeRef?)) -> CFTypeRef? {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard valid, remaining > 0, AXUIElementSetMessagingTimeout(element, Float(min(0.02, remaining))) == .success else { valid = false; return nil }
        let (error, result) = body()
        guard ProcessInfo.processInfo.systemUptime < deadline else { valid = false; return nil }
        if error == .success { return result }
        if error != .attributeUnsupported && error != .noValue { valid = false }
        return nil
    }
    var accessibility: TextDelivery.Accessibility {
        var ax = TextDelivery.Accessibility.live
        ax.attribute = { element, key in self.read(element) {
            var value: CFTypeRef?; let error = AXUIElementCopyAttributeValue(element, key as CFString, &value); return (error, value)
        } }
        ax.parameterized = { element, key, parameter in self.read(element) {
            var value: CFTypeRef?; let error = AXUIElementCopyParameterizedAttributeValue(element, key as CFString, parameter, &value); return (error, value)
        } }
        return ax
    }
}

/// Focus notifications invalidate permanently; own value/selection notifications only
/// verify expected state. Global input monitoring catches even an away-and-back user edit.
@MainActor
private final class LiveDictationAXObserver {
    private var observer: AXObserver?
    private let app: AXUIElement
    private let element: AXUIElement
    private let invalidate: () -> Void
    private let check: () -> Void
    init?(target: TextDelivery.Target, invalidate: @escaping () -> Void, check: @escaping () -> Void) {
        guard let element = target.element else { return nil }
        self.app = AXUIElementCreateApplication(target.app.processIdentifier); self.element = element
        self.invalidate = invalidate; self.check = check
        var observer: AXObserver?
        guard AXObserverCreate(target.app.processIdentifier, { _, _, notification, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let owner = Unmanaged<LiveDictationAXObserver>.fromOpaque(context).takeUnretainedValue()
                if notification as String == kAXFocusedUIElementChangedNotification { owner.invalidate() }
                else { owner.check() }
            }
        }, &observer) == .success, let observer else { return nil }
        self.observer = observer
        let context = Unmanaged.passUnretained(self).toOpaque()
        AXUIElementSetMessagingTimeout(app, 0.03); AXUIElementSetMessagingTimeout(element, 0.03)
        guard AXObserverAddNotification(observer, app, kAXFocusedUIElementChangedNotification as CFString, context) == .success,
              AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, context) == .success,
              AXObserverAddNotification(observer, element, kAXSelectedTextChangedNotification as CFString, context) == .success else { end(); return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
    func end() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        AXObserverRemoveNotification(observer, app, kAXFocusedUIElementChangedNotification as CFString)
        AXObserverRemoveNotification(observer, element, kAXValueChangedNotification as CFString)
        AXObserverRemoveNotification(observer, element, kAXSelectedTextChangedNotification as CFString)
        self.observer = nil
    }
}
