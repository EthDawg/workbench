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
        var preparePaste: () -> (() -> Void)?

        static var live: System {
            System(pasteboard: .general, isTrusted: { AXIsProcessTrusted() }, isEligible: { TextDelivery.eligible($0) },
                   preparePaste: {
                       guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
                             let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { return nil }
                       down.flags = .maskCommand; up.flags = .maskCommand
                       return { down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap) }
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
    }
    static func capture(app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) -> Target? {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let element = focusedElement(app.processIdentifier)
        return Target(app: app, element: element, value: element.flatMap {
            string($0, kAXSubroleAttribute) == kAXSecureTextFieldSubrole ? nil : string($0, kAXValueAttribute)
        }, selection: element.flatMap { PromptInsertion.selection($0) })
    }
    static func focusedElement(_ pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    static func string(_ element: AXUIElement, _ key: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? String
    }
    static func eligible(_ target: Target) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.app.processIdentifier,
              let captured = target.element, let current = focusedElement(target.app.processIdentifier), CFEqual(captured, current),
              string(current, kAXSubroleAttribute) != kAXSecureTextFieldSubrole else { return false }
        return true
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
                        system: System? = nil) async -> Outcome {
        let system = system ?? .live
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
        if restoreClipboard, mayPaste {
            previous = pasteboard.pasteboardItems?.map { item in
                let saved = NSPasteboardItem()
                for type in item.types { if let data = item.data(forType: type) { saved.setData(data, forType: type) } }
                return saved
            } ?? []
        } else { previous = [] }
        let priorSnapshotIsStable = pasteboard.changeCount == priorCount
        guard let ownedChange = copy(text, to: pasteboard) else {
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
        guard target.element != nil else {
            return outcome("Copied. " + copiedDetail(.fieldUnreadable), failure: .fieldUnreadable)
        }
        guard system.isEligible(target) else {
            return outcome("Copied. " + copiedDetail(.focusChanged), failure: .focusChanged)
        }
        // Snapshot immediately before insertion so an unrelated user edit is not mistaken for our paste.
        let before = target.element.flatMap { string($0, kAXValueAttribute) }
        guard let paste = system.preparePaste() else {
            return outcome("Copied. " + copiedDetail(.pasteUnavailable), failure: .pasteUnavailable)
        }
        guard pasteboard.changeCount == ownedChange else {
            return outcome("Clipboard changed before insertion, so nothing was pasted. The transcript is available in Workbench.", failure: .clipboardChanged)
        }
        guard !Task.isCancelled, validateTarget?() != false else {
            return outcome("Delivery stopped before pasting. The transcript remains copied.", failure: .cancelled)
        }
        pasteWasAttempted = true
        paste()
        do { try await Task.sleep(nanoseconds: 450_000_000) }
        catch {
            return outcome("Paste was sent before cancellation. Check the destination; insertion was not confirmed or undone.", failure: .cancelled)
        }
        let stillEligible = system.isEligible(target)
        let after = stillEligible ? target.element.flatMap { string($0, kAXValueAttribute) } : nil
        let selectionConfirmed = expectedSelection.map { expected in target.element.flatMap { PromptInsertion.selection($0) } == expected } ?? true
        let confirmed = stillEligible && selectionConfirmed && (expectedValue.map { after == $0 } ?? (after != before && after?.contains(text) == true))
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
        if confirmed { return outcome("Pasted into \(destinationName ?? "your app").", wasPasted: true) }
        return outcome(pasteboard.changeCount == ownedChange
                       ? "Paste sent · insertion could not be confirmed. The transcript remains copied."
                       : "Paste sent · insertion could not be confirmed, and the clipboard has since changed.", failure: .pasteUnconfirmed)
    }
}
