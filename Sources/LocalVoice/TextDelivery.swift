import AppKit

@MainActor
final class TextDelivery {
    enum FailureKind: String, Equatable {
        case copyFailed, accessibilityUnavailable, focusChanged, fieldUnreadable, pasteUnavailable
        case pasteUnconfirmed, clipboardChanged, clipboardRestoreFailed, cancelled
    }
    /// Everything delivery touches outside Workbench. `live` is this Mac; checks
    /// pass an untrusted Mac, an isolated pasteboard and a recorder, so they never
    /// read or change the person's clipboard or Accessibility approval.
    @MainActor struct System {
        var pasteboard: NSPasteboard
        /// Accessibility approval, which automatic paste needs.
        var isTrusted: () -> Bool
        /// The captured field is still frontmost, focused and not secure.
        var isEligible: (Target) -> Bool
        /// The ⌘V poster, or nil when its key events cannot be made.
        var preparePaste: (Target) -> (() -> Void)?
        var readField: (Target) -> FieldState = { TextDelivery.fieldState($0.element) }
        var pause: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }

        static var live: System {
            System(pasteboard: .general, isTrusted: { AXIsProcessTrusted() }, isEligible: { TextDelivery.eligible($0) },
                   preparePaste: { target in
                       guard let source = CGEventSource(stateID: .privateState),
                             let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                             let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return nil }
                       down.flags = .maskCommand; up.flags = .maskCommand
                       // Eligibility is checked immediately before posting. Addressing
                       // that process also prevents an intervening app switch from
                       // redirecting these events to the newly frontmost application.
                       return { down.postToPid(target.app.processIdentifier); up.postToPid(target.app.processIdentifier) }
                   })
        }
    }
    /// One wording for text that was copied and not pasted, shared by dictation
    /// and Saved Prompts. Missing approval is not a fault: it reads as plain copying.
    static let copiedMessage = "Copied. Paste with ⌘V."
    static func copiedDetail(_ failure: FailureKind?) -> String {
        switch failure {
        case .focusChanged: return "The field changed, so nothing was pasted. Paste with ⌘V when ready."
        case .fieldUnreadable: return "The field could not be read, so nothing was pasted. Paste with ⌘V when ready."
        case .pasteUnavailable: return "Paste could not start. Paste with ⌘V when ready."
        default: return "Paste with ⌘V."
        }
    }
    struct Outcome: Equatable {
        var message: String
        var clipboardChangeCount: Int?
        /// True only when the destination value confirms insertion, not merely
        /// when Command-V events were posted.
        var wasPasted: Bool
        var destinationName: String?
        var failure: FailureKind? = nil
        var pasteWasAttempted: Bool = false
    }
    enum ClipboardRestoration { case notAttempted, restored, failed }
    struct Target {
        var app: NSRunningApplication
        var element: AXUIElement?
        var value: String?
        var selection: NSRange? = nil
        var opaqueEditor: OpaqueEditorDestination? = nil
    }
    struct FieldState: Equatable {
        var value: String?
        var selection: NSRange?
    }
    /// The AX adapter is separate from delivery so checks can represent a lazy
    /// Electron tree and rich-text descendants without inspecting another app.
    /// The live one reads through `AccessibilityBridge`, like every AX call.
    struct Accessibility {
        var isTrusted: () -> Bool
        var frontmostPID: () -> pid_t?
        var attribute: (AXUIElement, String) -> CFTypeRef?
        var parameterized: (AXUIElement, String, CFTypeRef) -> CFTypeRef?
        var setBoolean: (AXUIElement, String, Bool) -> Bool

        static var live: Self {
            .init(isTrusted: { AXIsProcessTrusted() }, frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                  attribute: { element, key in
                      let (error, value) = AccessibilityBridge.attribute(element, key)
                      return error == .success ? value : nil
                  }, parameterized: { element, key, parameter in
                      let (error, value) = AccessibilityBridge.parameterizedAttribute(element, key, parameter)
                      return error == .success ? value : nil
                  }, setBoolean: { element, key, value in
                      AccessibilityBridge.setAttribute(element, key, value as CFBoolean) == .success
                  })
        }
    }

    static func capture(app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) -> Target? {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        // Sublime's known window-only editor uses a bounded AX snapshot from
        // the first read; never run the generic unbounded field walk first.
        if OpaqueEditorDestination.supports(app.bundleIdentifier) {
            return Target(app: app, element: nil, value: nil, opaqueEditor: OpaqueEditorDestination.capture(app: app))
        }
        let element = captureField(app.processIdentifier)
        let state = fieldState(element)
        return Target(app: app, element: element, value: state.value, selection: state.selection,
                      opaqueEditor: element == nil ? OpaqueEditorDestination.capture(app: app) : nil)
    }
    static func captureField(_ pid: pid_t, accessibility: Accessibility? = nil) -> AXUIElement? {
        let ax = accessibility ?? .live
        guard ax.isTrusted() else { return nil }
        let app = AccessibilityBridge.application(pid)
        // Electron explicitly exposes this opt-in to assistive clients. Only
        // enable a supported, currently disabled tree; never change OS approval
        // or guess a new destination later if this capture is still unreadable.
        if (ax.attribute(app, "AXManualAccessibility") as? Bool) == false {
            _ = ax.setBoolean(app, "AXManualAccessibility", true)
        }
        return focusedField(pid, accessibility: ax)
    }
    private static func element(_ value: CFTypeRef?) -> AXUIElement? { AccessibilityBridge.element(value) }
    static func focusedField(_ pid: pid_t, accessibility: Accessibility) -> AXUIElement? {
        guard accessibility.isTrusted() else { return nil }
        var current = element(accessibility.attribute(AccessibilityBridge.application(pid), kAXFocusedUIElementAttribute))
        var visited: [AXUIElement] = []
        // Rich editors can focus a paragraph or static-text child. Resolve only
        // its nearest text-field ancestor, never siblings or the window's page.
        while let node = current, visited.count < 8, !visited.contains(where: { CFEqual($0, node) }) {
            visited.append(node)
            guard accessibility.attribute(node, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
                  accessibility.attribute(node, kAXEnabledAttribute) as? Bool != false else { return nil }
            let role = accessibility.attribute(node, kAXRoleAttribute) as? String
            if role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole { return node }
            guard [kAXStaticTextRole, kAXGroupRole, kAXUnknownRole, "AXParagraph"].contains(role ?? "") else { return nil }
            current = element(accessibility.attribute(node, kAXParentAttribute))
        }
        return nil
    }
    static func string(_ element: AXUIElement, _ key: String) -> String? {
        if key == kAXValueAttribute { return textValue(element, accessibility: .live) }
        return Accessibility.live.attribute(element, key) as? String
    }
    static func eligible(_ target: Target, accessibility: Accessibility? = nil) -> Bool {
        if let opaque = target.opaqueEditor { return opaque.isEligible }
        let ax = accessibility ?? .live
        guard ax.frontmostPID() == target.app.processIdentifier,
              let captured = target.element, let current = focusedField(target.app.processIdentifier, accessibility: ax),
              CFEqual(captured, current) else { return false }
        return true
    }
    static func fieldState(_ element: AXUIElement?, accessibility: Accessibility? = nil) -> FieldState {
        let ax = accessibility ?? .live
        guard let element, ax.attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else {
            return .init(value: nil, selection: nil)
        }
        let selection = AccessibilityBridge.range(ax.attribute(element, kAXSelectedTextRangeAttribute))
        return .init(value: textValue(element, accessibility: ax), selection: selection)
    }
    private static func textValue(_ element: AXUIElement, accessibility ax: Accessibility) -> String? {
        guard ax.attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return nil }
        func plain(_ value: CFTypeRef?) -> String? { (value as? String) ?? (value as? NSAttributedString)?.string }
        let value = plain(ax.attribute(element, kAXValueAttribute))
        if let value, !value.isEmpty { return value }
        // Some rich-text controls expose the document through a text range,
        // rather than AXValue. Read this field only, with a bounded UTF-16 range.
        guard let count = ax.attribute(element, kAXNumberOfCharactersAttribute) as? Int,
              (0...1_000_000).contains(count) else { return value }
        if count == 0 { return value ?? "" }
        guard let parameter = AccessibilityBridge.value(NSRange(location: 0, length: count)) else { return nil }
        return plain(ax.parameterized(element, kAXStringForRangeParameterizedAttribute, parameter))
            ?? plain(ax.parameterized(element, kAXAttributedStringForRangeParameterizedAttribute, parameter))
            ?? value
    }

    static func confirms(_ text: String, before: FieldState, after: FieldState,
                         expectedValue: String? = nil, expectedSelection: NSRange? = nil) -> Bool {
        guard let old = before.value, let new = after.value,
              expectedSelection.map({ after.selection == $0 }) ?? true else { return false }
        if let expectedValue { return new == expectedValue && (new != old || before.selection != after.selection) }
        if let selection = before.selection, let range = Range(selection, in: old) {
            var expected = old; expected.replaceSubrange(range, with: text)
            // Replacing selected text with itself is confirmed by the collapsed
            // caret, not by finding words that were already in the field.
            return new == expected && (new != old || after.selection == NSRange(location: selection.location + text.utf16.count, length: 0))
        }
        // Without a readable selection, require exactly one inserted text span.
        // Merely containing the words can mistake an unrelated edit for a paste.
        let oldUnits = Array(old.utf16), newUnits = Array(new.utf16), inserted = Array(text.utf16)
        guard !inserted.isEmpty, newUnits.count == oldUnits.count + inserted.count else { return false }
        var prefix = 0
        while prefix < oldUnits.count, oldUnits[prefix] == newUnits[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < oldUnits.count,
              oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] { suffix += 1 }
        let first = oldUnits.count - suffix, last = prefix
        guard first <= last else { return false }
        // Removing a span of this length anywhere within these bounds leaves
        // the original prefix and suffix intact. Shared/repeated text means the
        // real insertion need not be at the longest common prefix's end.
        // KMP's prefix table searches those positions in linear time, without
        // rebuilding the whole field for each possible insertion position.
        var fallback = [Int](repeating: 0, count: inserted.count)
        for index in 1..<inserted.count {
            var matched = fallback[index - 1]
            while matched > 0, inserted[index] != inserted[matched] { matched = fallback[matched - 1] }
            if inserted[index] == inserted[matched] { matched += 1 }
            fallback[index] = matched
        }
        var matched = 0
        for index in first..<(last + inserted.count) {
            while matched > 0, newUnits[index] != inserted[matched] { matched = fallback[matched - 1] }
            if newUnits[index] == inserted[matched] { matched += 1 }
            if matched == inserted.count { return true }
        }
        return false
    }
    @discardableResult
    static func copy(_ text: String) -> Int? {
        copy(text, to: NSPasteboard.general)
    }

    /// The explicit pasteboard overload permits isolated checks without touching
    /// the user's clipboard. A receipt owns a successful write's change count only.
    @discardableResult
    static func copy(_ text: String, to pasteboard: NSPasteboard) -> Int? {
        guard !text.isEmpty else { return nil }
        let cleared = pasteboard.clearContents()
        guard pasteboard.changeCount == cleared, pasteboard.setString(text, forType: .string),
              pasteboard.changeCount == cleared else { return nil }
        // setString writes within clearContents' ownership generation. Do not
        // accidentally return a later generation copied by another process.
        return cleared
    }

    static func restoreClipboardSnapshot(_ previous: [NSPasteboardItem], on pasteboard: NSPasteboard,
                                         ownedChange: Int, snapshotIsStable: Bool) -> ClipboardRestoration {
        guard snapshotIsStable, pasteboard.changeCount == ownedChange else { return .notAttempted }
        let cleared = pasteboard.clearContents()
        guard pasteboard.changeCount == cleared else { return .failed }
        return previous.isEmpty || pasteboard.writeObjects(previous) ? .restored : .failed
    }

    static func deliver(_ text: String, target: Target?, mode: DeliveryMode, restoreClipboard: Bool,
                        validateTarget: (() -> Bool)? = nil, expectedValue: String? = nil, expectedSelection: NSRange? = nil,
                        fit: InsertionBoundary.Context? = nil, system: System? = nil) async -> Outcome {
        let system = system ?? .live
        defer { target?.opaqueEditor?.end() }
        let pasteboard = system.pasteboard
        let destinationName = target?.app.localizedName
        guard !Task.isCancelled, validateTarget?() != false else {
            return Outcome(message: "Delivery stopped before copying or pasting.", clipboardChangeCount: nil,
                           wasPasted: false, destinationName: destinationName, failure: .cancelled)
        }
        // Without approval nothing can be pasted, so copying is the whole delivery.
        let mayPaste = mode == .paste && target != nil && system.isTrusted()
        // Only inspect old clipboard contents when a paste may need restoring.
        let priorCount = pasteboard.changeCount
        let previous: [NSPasteboardItem]
        if restoreClipboard, mayPaste, target?.opaqueEditor == nil {
            previous = pasteboard.pasteboardItems?.map { item in
                let saved = NSPasteboardItem()
                for type in item.types { if let data = item.data(forType: type) { saved.setData(data, forType: type) } }
                return saved
            } ?? []
        } else { previous = [] }
        let priorSnapshotIsStable = pasteboard.changeCount == priorCount
        // The clipboard holds the transcript as dictated; words fitted to the field
        // (#14) are copied only for the paste itself, so every earlier return
        // leaves the person pasting what they said.
        var delivered = text
        guard var ownedChange = copy(text, to: pasteboard) else {
            return Outcome(message: "Could not copy the transcript. It is still available in Workbench.",
                           clipboardChangeCount: nil, wasPasted: false, destinationName: destinationName, failure: .copyFailed)
        }
        var pasteWasAttempted = false
        func outcome(_ message: String, wasPasted: Bool = false, failure: FailureKind? = nil) -> Outcome {
            Outcome(message: message, clipboardChangeCount: pasteboard.changeCount == ownedChange ? ownedChange : nil,
                    wasPasted: wasPasted, destinationName: destinationName, failure: failure, pasteWasAttempted: pasteWasAttempted)
        }
        guard mode == .paste, let target else { return outcome(copiedMessage) }
        // Automatic paste waits for approval. The copy is the supported result,
        // so it says what to do next rather than where to change a setting.
        guard mayPaste else { return outcome(copiedMessage, failure: .accessibilityUnavailable) }
        guard target.element != nil || target.opaqueEditor != nil else {
            return outcome("Copied. " + copiedDetail(.fieldUnreadable), failure: .fieldUnreadable)
        }
        if let opaque = target.opaqueEditor, !opaque.active, !opaque.invalidated {
            // Saved Prompts never arm opaque dictation. Explain the actual
            // limitation instead of claiming the person changed the field.
            return outcome("Copied. " + copiedDetail(.fieldUnreadable), failure: .fieldUnreadable)
        }
        guard system.isEligible(target) else {
            return outcome("Copied. " + copiedDetail(.focusChanged), failure: .focusChanged)
        }
        // Snapshot immediately before insertion so an unrelated user edit is not mistaken for our paste.
        let before = system.readField(target)
        // Dictated words fit this snapshot (#14); an unreadable value or range changes nothing.
        if let fit, target.opaqueEditor == nil,
           let adjusted = InsertionBoundary.fit(dictated: text, value: before.value, selection: before.selection, context: fit) {
            delivered = adjusted.text
        }
        guard let paste = system.preparePaste(target) else {
            return outcome("Copied. " + copiedDetail(.pasteUnavailable), failure: .pasteUnavailable)
        }
        guard pasteboard.changeCount == ownedChange else {
            return outcome("Clipboard changed before insertion, so nothing was pasted. The transcript is available in Workbench.", failure: .clipboardChanged)
        }
        guard !Task.isCancelled, validateTarget?() != false else {
            return outcome("Delivery stopped before pasting. The transcript remains copied.", failure: .cancelled)
        }
        guard system.isEligible(target) else {
            return outcome("Copied. " + copiedDetail(.focusChanged), failure: .focusChanged)
        }
        if delivered != text {
            guard let fitted = copy(delivered, to: pasteboard) else {
                return outcome("Could not copy the transcript. It is still available in Workbench.", failure: .copyFailed)
            }
            ownedChange = fitted
        }
        pasteWasAttempted = true
        // The captured opaque editor was rechecked above. Stop observing before
        // our own paste; it is sent once and cannot be confirmed from AX text.
        target.opaqueEditor?.end()
        paste()
        if target.opaqueEditor != nil {
            // One command was sent to the guarded editor. Its AX API cannot
            // confirm insertion; this expected limitation is not a failure.
            // Keep the words copied and never suggest sending a second paste.
            return outcome("Sent to \(destinationName ?? "your app") · " + (pasteboard.changeCount == ownedChange
                ? "still copied." : "the clipboard has since changed."))
        }
        var confirmed = false
        // The fitted words served one caret; what stays copied after the paste is the
        // transcript. Every post-paste exit, cancellation included, leaves it so when
        // Workbench still owns the clipboard, and the recopy becomes the owned change.
        func recopyTranscript() {
            if delivered != text, pasteboard.changeCount == ownedChange, let recopied = copy(text, to: pasteboard) { ownedChange = recopied }
        }
        // Web/Electron accessibility updates can arrive after the paste itself.
        // Poll for at most 1.2 seconds; never retry the paste or retarget a field.
        for _ in 0..<(before.value == nil ? 0 : 15) {
            do { try await system.pause(80_000_000); try Task.checkCancellation() }
            catch {
                recopyTranscript()
                return outcome("Paste was sent before cancellation. Check the destination; insertion was not confirmed or undone.", failure: .cancelled)
            }
            guard system.isEligible(target) else { break }
            if confirms(delivered, before: before, after: system.readField(target),
                        expectedValue: expectedValue, expectedSelection: expectedSelection) {
                confirmed = true; break
            }
        }
        if confirmed, restoreClipboard {
            // Never overwrite a copy made while paste confirmation was pending.
            let restoration = restoreClipboardSnapshot(previous, on: pasteboard, ownedChange: ownedChange,
                                                       snapshotIsStable: priorSnapshotIsStable)
            if restoration != .notAttempted {
                let restored = restoration == .restored
                return Outcome(message: restored
                               ? "Pasted into \(destinationName ?? "your app"). Previous clipboard restored."
                               : "Pasted into \(destinationName ?? "your app"), but the previous clipboard could not be restored.",
                               clipboardChangeCount: nil, wasPasted: true, destinationName: destinationName,
                               failure: restored ? nil : .clipboardRestoreFailed, pasteWasAttempted: true)
            }
        }
        recopyTranscript()
        if confirmed { return outcome("Pasted into \(destinationName ?? "your app").", wasPasted: true) }
        return outcome(pasteboard.changeCount == ownedChange
                       ? "Paste sent · insertion could not be confirmed. The transcript remains copied."
                       : "Paste sent · insertion could not be confirmed, and the clipboard has since changed.", failure: .pasteUnconfirmed)
    }
}
