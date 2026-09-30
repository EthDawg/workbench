import AppKit

/// Delivery through `TextDelivery.System`: an untrusted Mac, an isolated
/// pasteboard and a recorder stand in for the real ones, so these checks never
/// read or change the person's clipboard or Accessibility approval (#165).
@MainActor
enum TextDeliveryChecks {
    private final class AXFixture {
        let app = AXUIElementCreateApplication(NSRunningApplication.current.processIdentifier)
        var focused: AXUIElement?
        var trusted = true, frontmost: pid_t? = NSRunningApplication.current.processIdentifier
        var manual: Bool? = nil
        var requiresManual = false
        var writes = 0, reads = 0, textReads = 0, rangeReads = 0
        var nodes: [(AXUIElement, [String: CFTypeRef])] = []
        var rangeText: CFTypeRef?

        func node(_ attributes: [String: CFTypeRef]) -> AXUIElement {
            let node = AXUIElementCreateApplication(pid_t(100_000 + nodes.count))
            nodes.append((node, attributes)); return node
        }
        var adapter: TextDelivery.Accessibility {
            .init(isTrusted: { self.trusted }, frontmostPID: { self.frontmost }, attribute: { node, key in
                self.reads += 1
                if CFEqual(node, self.app) {
                    if key == "AXManualAccessibility" { return self.manual.map { $0 as CFTypeRef } }
                    if key == kAXFocusedUIElementAttribute { return self.requiresManual && self.manual != true ? nil : self.focused }
                }
                if key == kAXValueAttribute { self.textReads += 1 }
                return self.nodes.first(where: { CFEqual($0.0, node) })?.1[key]
            }, parameterized: { _, _, _ in self.rangeReads += 1; return self.rangeText },
            setBoolean: { _, key, value in
                guard key == "AXManualAccessibility", self.manual != nil else { return false }
                self.writes += 1; self.manual = value; return true
            })
        }
    }

    private final class DeliveryFixture {
        let board: NSPasteboard
        let target = TextDelivery.Target(app: .current, element: AXUIElementCreateApplication(getpid()), value: "before ")
        var state = TextDelivery.FieldState(value: "before ", selection: NSRange(location: 7, length: 0))
        var eligible = true, posted = 0, pauses = 0, reads = 0
        var beforePosting: (() -> Void)?
        var duringConfirmation: (() -> Void)?
        var system: TextDelivery.System {
            .init(pasteboard: board, isTrusted: { true }, isEligible: { _ in self.eligible },
                  preparePaste: { target in
                      self.beforePosting?()
                      return { if target.app.processIdentifier == self.target.app.processIdentifier { self.posted += 1 } }
                  }, readField: { _ in self.reads += 1; return self.state },
                  pause: { _ in self.pauses += 1; self.duringConfirmation?(); try Task.checkCancellation() })
        }
        init(_ board: NSPasteboard) { self.board = board }
        func deliver(_ text: String = "spoken words", restore: Bool = true,
                     expectedValue: String? = nil, expectedSelection: NSRange? = nil) async -> TextDelivery.Outcome {
            await TextDelivery.deliver(text, target: target, mode: .paste, restoreClipboard: restore,
                                       expectedValue: expectedValue, expectedSelection: expectedSelection, system: system)
        }
    }

    static func run() async throws {
        var passed = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("TEXT DELIVERY CHECK FAILED: " + name) }
            passed += 1
        }
        let board = NSPasteboard(name: .init("Workbench.DeliveryChecks." + UUID().uuidString))
        defer { board.releaseGlobally() }
        guard TextDelivery.copy("earlier synthetic content", to: board) != nil else {
            throw VoiceError.message("TEXT DELIVERY CHECK FAILED: isolated pasteboard unavailable")
        }
        var trusted = false, eligible = true
        var trustReads = 0, eligibilityReads = 0, prepared = 0, posted = 0
        let system = TextDelivery.System(pasteboard: board,
            isTrusted: { trustReads += 1; return trusted },
            isEligible: { _ in eligibilityReads += 1; return eligible },
            preparePaste: { _ in prepared += 1; return { posted += 1 } })
        func reset() { trustReads = 0; eligibilityReads = 0; prepared = 0; posted = 0 }
        let field = TextDelivery.Target(app: .current, element: nil, value: nil)
        let receipts = ClipboardReceiptModel(clipboardChangeCount: { board.changeCount }, automaticallySchedules: false)

        // Paste automatically is chosen, and Accessibility is not approved.
        var before = board.changeCount
        let untrusted = await TextDelivery.deliver("synthetic dictation", target: field, mode: .paste, restoreClipboard: true, system: system)
        try check(untrusted.failure == .accessibilityUnavailable && !untrusted.wasPasted && !untrusted.pasteWasAttempted,
                  "without approval, delivery reports a copy, never a paste")
        try check(prepared == 0 && posted == 0 && eligibilityReads == 0,
                  "without approval, no paste events are made or posted and the field is not read through Accessibility")
        try check(board.changeCount == before + 1 && board.string(forType: .string) == "synthetic dictation"
                  && untrusted.clipboardChangeCount == board.changeCount,
                  "without approval, exactly one copy lands on the isolated pasteboard")
        try check(untrusted.message == "Copied. Paste with ⌘V." && !untrusted.message.contains("Settings")
                  && !untrusted.message.contains("Accessibility"),
                  "without approval, the result says copied and ⌘V, with no instruction to enable a permission")
        receipts.record(outcome: untrusted, wordCount: 2)
        try check(receipts.receipt?.title == "Copied" && receipts.receipt?.detail == "Paste with ⌘V."
                  && receipts.receipt?.isClipboardCurrent == true && receipts.receipt?.canSuggestPaste == true,
                  "without approval, the receipt reads Copied and Paste with ⌘V.")

        // The same result as choosing Copy to clipboard: no reminder after each capture.
        reset(); before = board.changeCount
        let chosen = await TextDelivery.deliver("synthetic dictation", target: field, mode: .clipboard, restoreClipboard: true, system: system)
        receipts.record(outcome: chosen, wordCount: 2)
        try check(chosen.failure == nil && chosen.message == untrusted.message && prepared == 0 && posted == 0
                  && board.changeCount == before + 1 && receipts.receipt?.title == "Copied" && receipts.receipt?.detail == "Paste with ⌘V.",
                  "a chosen copy and a copy waiting for approval read the same")

        // Approved, but the field cannot be read or has changed: distinct reasons, still no paste.
        trusted = true; reset()
        let unreadable = await TextDelivery.deliver("synthetic dictation", target: field, mode: .paste, restoreClipboard: true, system: system)
        receipts.record(outcome: unreadable, wordCount: 2)
        try check(unreadable.failure == .fieldUnreadable && prepared == 0 && posted == 0
                  && receipts.receipt?.detail.contains("could not be read") == true && receipts.receipt?.title == "Copied",
                  "an unreadable field is its own reason, distinct from missing approval")
        let element = TextDelivery.Target(app: .current, element: AXUIElementCreateApplication(getpid()), value: "")
        eligible = false; reset()
        let changed = await TextDelivery.deliver("synthetic dictation", target: element, mode: .paste, restoreClipboard: true, system: system)
        receipts.record(outcome: changed, wordCount: 2)
        try check(changed.failure == .focusChanged && eligibilityReads == 1 && prepared == 0 && posted == 0
                  && receipts.receipt?.detail.hasPrefix("The field changed, so nothing was pasted.") == true,
                  "a changed field says so and posts nothing")
        try check(Set([untrusted, unreadable, changed].map { TextDelivery.copiedDetail($0.failure) }).count == 3,
                  "missing approval, an unreadable field and a changed field never share one reason")

        // A stale clipboard never claims readiness.
        _ = TextDelivery.copy("unrelated newer copy", to: board)
        receipts.refreshClipboardOwnership()
        try check(receipts.receipt == nil, "a later copy ends the copied receipt")
        receipts.record(outcome: untrusted, wordCount: 2)
        try check(receipts.receipt?.isClipboardCurrent == false && receipts.receipt?.canSuggestPaste == false
                  && receipts.receipt?.title != "Copied",
                  "an outcome whose copy was replaced cannot read as ready to paste")
        try check(trustReads > 0 && board.string(forType: .string) == "unrelated newer copy",
                  "checks used only the injected trust and the isolated pasteboard")

        // Cold Electron trees opt in through their documented attribute only.
        let pid = NSRunningApplication.current.processIdentifier
        let ax = AXFixture()
        let fieldNode = ax.node([kAXRoleAttribute: kAXTextAreaRole as CFString,
                                 kAXValueAttribute: NSAttributedString(string: "before ")])
        ax.focused = fieldNode; ax.manual = false; ax.requiresManual = true
        let captured = TextDelivery.captureField(pid, accessibility: ax.adapter)
        try check(captured.map { CFEqual($0, fieldNode) } == true && ax.writes == 1,
                  "a cold Electron tree is enabled before capturing the field")
        _ = TextDelivery.captureField(pid, accessibility: ax.adapter)
        try check(ax.writes == 1, "an already enabled Electron tree is left alone")
        ax.manual = nil; ax.requiresManual = false
        _ = TextDelivery.captureField(pid, accessibility: ax.adapter)
        try check(ax.writes == 1, "an application without the explicit opt-in attribute receives no AX write")
        let reads = ax.reads; ax.trusted = false
        try check(TextDelivery.captureField(pid, accessibility: ax.adapter) == nil && ax.reads == reads && ax.writes == 1,
                  "unapproved capture neither queries another app nor requests accessibility or enables a tree")
        ax.trusted = true
        try check(TextDelivery.fieldState(fieldNode, accessibility: ax.adapter).value == "before ",
                  "attributed AX values are read as text")

        let child = ax.node([kAXRoleAttribute: kAXStaticTextRole as CFString, kAXParentAttribute: fieldNode])
        let nextChild = ax.node([kAXRoleAttribute: "AXParagraph" as CFString, kAXParentAttribute: fieldNode])
        ax.focused = child
        let resolved = TextDelivery.captureField(pid, accessibility: ax.adapter)
        let stableTarget = TextDelivery.Target(app: .current, element: resolved, value: "before ")
        ax.focused = nextChild
        try check(resolved.map { CFEqual($0, fieldNode) } == true && TextDelivery.eligible(stableTarget, accessibility: ax.adapter),
                  "a new rich-text child inside the captured field preserves that exact destination")
        let otherField = ax.node([kAXRoleAttribute: kAXTextAreaRole as CFString, kAXValueAttribute: "before " as CFString])
        ax.focused = otherField
        try check(!TextDelivery.eligible(stableTarget, accessibility: ax.adapter), "an identically worded sibling field is never substituted")
        ax.focused = fieldNode; ax.frontmost = pid + 1
        try check(!TextDelivery.eligible(stableTarget, accessibility: ax.adapter), "switching applications blocks paste without reactivation")
        ax.frontmost = pid
        let secure = ax.node([kAXRoleAttribute: kAXTextFieldRole as CFString, kAXSubroleAttribute: kAXSecureTextFieldSubrole as CFString,
                              kAXValueAttribute: "not for delivery" as CFString])
        ax.focused = secure
        let textReads = ax.textReads
        try check(TextDelivery.captureField(pid, accessibility: ax.adapter) == nil
                  && TextDelivery.fieldState(secure, accessibility: ax.adapter).value == nil && ax.textReads == textReads,
                  "secure fields are rejected before reading their value")
        let button = ax.node([kAXRoleAttribute: kAXButtonRole as CFString, kAXParentAttribute: fieldNode])
        ax.focused = button
        try check(TextDelivery.captureField(pid, accessibility: ax.adapter) == nil,
                  "a focused button cannot borrow an enclosing field as its destination")
        let disabled = ax.node([kAXRoleAttribute: kAXTextAreaRole as CFString, kAXEnabledAttribute: kCFBooleanFalse!])
        ax.focused = disabled
        try check(TextDelivery.captureField(pid, accessibility: ax.adapter) == nil, "disabled fields cannot receive a paste")
        let document = ax.node([kAXRoleAttribute: "AXWebArea" as CFString])
        ax.focused = document
        try check(TextDelivery.captureField(pid, accessibility: ax.adapter) == nil,
                  "a page without a captured field remains a copy; no field is guessed later")
        let ranged = ax.node([kAXRoleAttribute: kAXTextAreaRole as CFString, kAXNumberOfCharactersAttribute: 7 as CFNumber])
        ax.rangeText = NSAttributedString(string: "before ")
        try check(TextDelivery.fieldState(ranged, accessibility: ax.adapter).value == "before " && ax.rangeReads == 1,
                  "range-backed rich editors can provide their text without AXValue")
        let empty = ax.node([kAXRoleAttribute: kAXTextAreaRole as CFString, kAXNumberOfCharactersAttribute: 0 as CFNumber])
        ax.rangeText = nil
        try check(TextDelivery.fieldState(empty, accessibility: ax.adapter).value == "" && ax.rangeReads == 1,
                  "a zero-character field is readable even when its empty range returns no AX value")
        let placeholder = ax.node([kAXRoleAttribute: kAXTextAreaRole as CFString, kAXValueAttribute: "" as CFString,
                                   kAXNumberOfCharactersAttribute: 7 as CFNumber])
        ax.rangeText = "before " as CFString
        try check(TextDelivery.fieldState(placeholder, accessibility: ax.adapter).value == "before " && ax.rangeReads == 2,
                  "an empty AXValue does not mask the rich editor's nonempty text range")
        let oversized = ax.node([kAXRoleAttribute: kAXTextAreaRole as CFString, kAXNumberOfCharactersAttribute: 1_000_001 as CFNumber])
        try check(TextDelivery.fieldState(oversized, accessibility: ax.adapter).value == nil && ax.rangeReads == 2,
                  "a range read is bounded and never scans an entire unbounded document")

        // Confirmation owns one paste and waits for the same field's AX update.
        let originalClipboard = "earlier synthetic clipboard"
        _ = TextDelivery.copy(originalClipboard, to: board)
        let slow = DeliveryFixture(board)
        slow.duringConfirmation = {
            if slow.pauses == 10 { slow.state = .init(value: "before spoken words", selection: NSRange(location: 19, length: 0)) }
        }
        let confirmed = await slow.deliver()
        try check(confirmed.wasPasted && confirmed.failure == nil && slow.posted == 1 && slow.pauses == 10,
                  "an AX update after 800 ms confirms one paste without replay")
        try check(board.string(forType: .string) == originalClipboard && confirmed.clipboardChangeCount == nil,
                  "only confirmed insertion restores the previous clipboard")
        let timeout = DeliveryFixture(board)
        let unconfirmed = await timeout.deliver()
        try check(!unconfirmed.wasPasted && unconfirmed.failure == .pasteUnconfirmed && unconfirmed.pasteWasAttempted
                  && timeout.posted == 1 && timeout.pauses == 15 && board.string(forType: .string) == "spoken words",
                  "an unchanged field times out with one attempted paste and keeps the copied words")
        let interrupted = DeliveryFixture(board)
        interrupted.duringConfirmation = { interrupted.eligible = false }
        let interruptedResult = await interrupted.deliver()
        try check(interruptedResult.failure == .pasteUnconfirmed && interrupted.posted == 1 && interrupted.pauses == 1 && interrupted.reads == 1,
                  "focus loss stops confirmation without reading the new destination or pasting twice")
        let moved = DeliveryFixture(board)
        moved.beforePosting = { moved.eligible = false }
        let movedResult = await moved.deliver()
        try check(movedResult.failure == .focusChanged && !movedResult.pasteWasAttempted && moved.posted == 0,
                  "focus changes while preparing key events are checked again before any post")
        let clipboardRace = DeliveryFixture(board)
        clipboardRace.duringConfirmation = {
            _ = TextDelivery.copy("person's newer copy", to: board)
            clipboardRace.state = .init(value: "before spoken words", selection: nil)
        }
        let raced = await clipboardRace.deliver()
        try check(raced.wasPasted && raced.clipboardChangeCount == nil && board.string(forType: .string) == "person's newer copy",
                  "confirmed insertion never restores over a newer copy")
        let beforePasteCopy = DeliveryFixture(board)
        beforePasteCopy.beforePosting = { _ = TextDelivery.copy("newer before paste", to: board) }
        let copyChanged = await beforePasteCopy.deliver()
        try check(copyChanged.failure == .clipboardChanged && beforePasteCopy.posted == 0,
                  "a clipboard change before posting prevents pasting unrelated contents")
        let cancelled = DeliveryFixture(board)
        var cancellationSystem = cancelled.system
        cancellationSystem.pause = { _ in throw CancellationError() }
        let stopped = await TextDelivery.deliver("spoken words", target: cancelled.target, mode: .paste, restoreClipboard: true, system: cancellationSystem)
        try check(stopped.failure == .cancelled && stopped.pasteWasAttempted && cancelled.posted == 1
                  && board.string(forType: .string) == "spoken words", "cancellation after posting neither replays nor restores an unconfirmed paste")

        let selected = TextDelivery.FieldState(value: "before TARGET after", selection: NSRange(location: 7, length: 6))
        let unicode = "👨‍👩‍👧‍👦 café\n第二行"
        try check(TextDelivery.confirms(unicode, before: selected, after: .init(value: "before \(unicode) after", selection: nil)),
                  "confirmation preserves Unicode and replaces the selected range exactly")
        try check(!TextDelivery.confirms("spoken words", before: .init(value: "spoken words", selection: nil),
                                        after: .init(value: "spoken words unrelated edit", selection: nil)),
                  "words already present plus an unrelated edit do not confirm a paste")
        try check(TextDelivery.confirms("words", before: .init(value: "before  after", selection: nil),
                                       after: .init(value: "before words after", selection: nil)),
                  "a missing AX selection still confirms exactly one inserted text span")
        let unchangedText = TextDelivery.FieldState(value: "words", selection: NSRange(location: 0, length: 5))
        try check(!TextDelivery.confirms("words", before: unchangedText, after: unchangedText)
                  && TextDelivery.confirms("words", before: unchangedText, after: .init(value: "words", selection: NSRange(location: 5, length: 0))),
                  "replacing identical selected text needs the resulting caret to confirm")
        let prompt = DeliveryFixture(board)
        prompt.duringConfirmation = {
            prompt.state.value = "before spoken words"
            if prompt.pauses == 3 { prompt.state.selection = NSRange(location: 19, length: 0) }
        }
        let promptResult = await prompt.deliver(expectedValue: "before spoken words", expectedSelection: NSRange(location: 19, length: 0))
        try check(promptResult.wasPasted && prompt.pauses == 3 && prompt.posted == 1,
                  "Saved Prompts fallback keeps its exact value and selection confirmation")
        print("TEXT_DELIVERY_CHECKS_OK: \(passed) checks; synthetic AX, recorded paste events and an isolated pasteboard only")
    }
}
