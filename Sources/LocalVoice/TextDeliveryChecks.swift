import AppKit

/// Delivery through `TextDelivery.System`: an untrusted Mac, an isolated
/// pasteboard and a recorder stand in for the real ones, so these checks never
/// read or change the person's clipboard or Accessibility approval (#165).
@MainActor
enum TextDeliveryChecks {
    private final class AXFixture {
        let app = AccessibilityBridge.application(NSRunningApplication.current.processIdentifier)
        var focused: AXUIElement?
        var focusedWindow: AXUIElement?
        var trusted = true, frontmost: pid_t? = NSRunningApplication.current.processIdentifier
        var manual: Bool? = nil
        var requiresManual = false
        var writes = 0, reads = 0, textReads = 0, rangeReads = 0
        var nodes: [(AXUIElement, [String: CFTypeRef])] = []
        var rangeText: CFTypeRef?

        func node(_ attributes: [String: CFTypeRef]) -> AXUIElement {
            let node = AccessibilityBridge.application(pid_t(100_000 + nodes.count))
            nodes.append((node, attributes)); return node
        }
        var adapter: TextDelivery.Accessibility {
            .init(isTrusted: { self.trusted }, frontmostPID: { self.frontmost }, attribute: { node, key in
                self.reads += 1
                if CFEqual(node, self.app) {
                    if key == "AXManualAccessibility" { return self.manual.map { $0 as CFTypeRef } }
                    if key == kAXFocusedUIElementAttribute { return self.requiresManual && self.manual != true ? nil : self.focused }
                    if key == kAXFocusedWindowAttribute { return self.focusedWindow }
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
        let target = TextDelivery.Target(app: .current, element: AccessibilityBridge.application(getpid()), value: "before ")
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
                     expectedValue: String? = nil, expectedSelection: NSRange? = nil,
                     fit: InsertionBoundary.Context? = nil, system: TextDelivery.System? = nil) async -> TextDelivery.Outcome {
            await TextDelivery.deliver(text, target: target, mode: .paste, restoreClipboard: restore,
                                       expectedValue: expectedValue, expectedSelection: expectedSelection, fit: fit, system: system ?? self.system)
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
        // Only something focused that isn't a usable field counts against automatic paste on Home:
        // nothing focused, or a password field, is not a paste problem.
        var hidden = field; hidden.unusableFocus = true; reset()
        let hiddenOutcome = await TextDelivery.deliver("synthetic dictation", target: hidden, mode: .paste, restoreClipboard: true, system: system)
        try check(!unreadable.unusableFocus && hiddenOutcome.unusableFocus && hiddenOutcome.failure == .fieldUnreadable
                  && AutomaticPasteProblem(unreadable, layout: "us", pasteKey: 9) == nil
                  && AutomaticPasteProblem(hiddenOutcome, layout: "us", pasteKey: 9)?.failure == .fieldUnreadable,
                  "nothing focused is not a paste problem; a focused field the app doesn't show is")
        var subrole: String? = nil, focusedPresent = true
        let focusReader = TextDelivery.Accessibility(isTrusted: { true }, frontmostPID: { nil },
            attribute: { _, key in
                if key == kAXFocusedUIElementAttribute { return focusedPresent ? AccessibilityBridge.application(getpid()) : nil }
                if key == kAXSubroleAttribute { return subrole as CFString? }
                return nil
            }, parameterized: { _, _, _ in nil }, setBoolean: { _, _, _ in false })
        let plainFocus = TextDelivery.unusableFocus(getpid(), accessibility: focusReader)
        subrole = kAXSecureTextFieldSubrole
        let secureFocus = TextDelivery.unusableFocus(getpid(), accessibility: focusReader)
        subrole = nil; focusedPresent = false
        let noFocus = TextDelivery.unusableFocus(getpid(), accessibility: focusReader)
        try check(plainFocus && !secureFocus && !noFocus,
                  "capture marks an unusable focus only when something non-secure is focused")
        let element = TextDelivery.Target(app: .current, element: AccessibilityBridge.application(getpid()), value: "")
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

        // The real Sublime shape is an AXWindow, not a fictional custom text
        // field. Exercise that admission and the production delivery path.
        let opaqueAX = AXFixture()
        let editorWindow = opaqueAX.node([kAXRoleAttribute: kAXWindowRole as CFString,
                                         kAXSubroleAttribute: kAXStandardWindowSubrole as CFString,
                                         kAXTitleAttribute: "Synthetic untitled editor" as CFString])
        opaqueAX.focused = editorWindow; opaqueAX.focusedWindow = editorWindow
        let opaquePID = NSRunningApplication.current.processIdentifier
        func windowAllowed(_ bundle: String = "com.sublimetext.4") -> Bool {
            OpaqueEditorDestination.window(pid: opaquePID, bundleID: bundle, accessibility: opaqueAX.adapter) != nil
        }
        try check(windowAllowed() && TextDelivery.captureField(opaquePID, accessibility: opaqueAX.adapter) == nil,
                  "the observed Sublime window is compatible without pretending it is a readable text field")
        try check(!windowAllowed("other.editor"), "unknown opaque apps remain copy-only")
        let sheet = opaqueAX.node([kAXRoleAttribute: kAXSheetRole as CFString])
        opaqueAX.nodes[0].1[kAXChildrenAttribute] = [sheet] as CFArray
        try check(!windowAllowed(), "an editor window with a sheet is never a paste destination")
        opaqueAX.nodes[0].1.removeValue(forKey: kAXChildrenAttribute)
        let dialog = opaqueAX.node([kAXRoleAttribute: kAXWindowRole as CFString,
                                   kAXSubroleAttribute: kAXDialogSubrole as CFString,
                                   kAXTitleAttribute: "Dialog" as CFString])
        opaqueAX.focused = dialog; opaqueAX.focusedWindow = dialog
        try check(!windowAllowed(), "a native dialog is never an opaque editor destination")
        opaqueAX.focused = editorWindow; opaqueAX.focusedWindow = editorWindow
        opaqueAX.trusted = false
        try check(!windowAllowed(), "opaque capture needs existing Accessibility trust")
        opaqueAX.trusted = true
        var invalidate: (() -> Void)?, opaqueStops = 0, opaquePosts = 0, stillCurrent = true
        func guardedTarget(observation: Bool = true) -> TextDelivery.Target {
            let guardState = OpaqueEditorDestination(current: { stillCurrent && windowAllowed() }, observe: { _, changed in
                guard observation else { return nil }
                invalidate = changed
                return { opaqueStops += 1 }
            })
            guardState.begin(shortcut: VoiceShortcut())
            return TextDelivery.Target(app: .current, element: nil, value: nil, opaqueEditor: guardState)
        }
        let opaqueSystem = TextDelivery.System(pasteboard: board, isTrusted: { true },
            isEligible: { TextDelivery.eligible($0) }, preparePaste: { _ in { opaquePosts += 1 } },
            readField: { _ in .init(value: nil, selection: nil) },
            pause: { _ in throw VoiceError.message("An opaque editor cannot confirm its text") })
        let guarded = guardedTarget()
        _ = TextDelivery.copy("previous clipboard", to: board)
        let opaqueOutcome = await TextDelivery.deliver("opaque synthetic words", target: guarded, mode: .paste, restoreClipboard: true, system: opaqueSystem)
        try check(opaquePosts == 1 && opaqueOutcome.pasteWasAttempted && !opaqueOutcome.wasPasted && opaqueOutcome.failure == nil,
                  "an unchanged opaque destination receives one paste without a false confirmation")
        let sentReceipt = ClipboardReceiptModel(clipboardChangeCount: { board.changeCount }, automaticallySchedules: false)
        sentReceipt.record(outcome: opaqueOutcome, wordCount: 3)
        try check(UnresolvedDelivery.kind(of: opaqueOutcome) == nil && sentReceipt.receipt?.title.hasPrefix("Sent to ") == true
                  && sentReceipt.receipt?.canSuggestPaste == false && opaqueOutcome.message.contains("still copied"),
                  "an expected unobservable paste has a quiet truthful receipt and no unresolved entry or duplicate-paste hint")
        try check(board.string(forType: .string) == "opaque synthetic words" && opaqueStops == 1 && guarded.opaqueEditor?.active == false,
                  "opaque delivery retains recovery text and releases its observation")
        let unarmed = TextDelivery.Target(app: .current, element: nil, value: nil,
            opaqueEditor: OpaqueEditorDestination(current: { true }, observe: { _, _ in {} }))
        let promptOutcome = await TextDelivery.deliver("prompt words", target: unarmed, mode: .paste, restoreClipboard: false, system: opaqueSystem)
        try check(promptOutcome.failure == .fieldUnreadable && !promptOutcome.pasteWasAttempted && opaquePosts == 1,
                  "Saved Prompts explain an unreadable field without claiming it changed")
        try check(!OpaqueEditorDestination.inputEvents.contains(.scrollWheel), "scrolling cannot cancel an unchanged editor target")
        var boundedReads = 0, limits: [Float] = [], clock = 0.0
        let bounded = OpaqueEditorDestination.ReadBudget(now: { clock }, setTimeout: { _, timeout in limits.append(timeout); return .success },
            read: { _, _ in boundedReads += 1; return (.cannotComplete, nil) })
        _ = bounded.attribute(editorWindow, kAXModalAttribute)
        _ = bounded.attribute(editorWindow, kAXTitleAttribute)
        try check(!bounded.valid && boundedReads == 1 && limits.count == 1 && limits[0] <= 0.03,
                  "an AX timeout invalidates the snapshot and stops further IPC even for an optional attribute")
        let elapsedBudget = OpaqueEditorDestination.ReadBudget(now: { clock }, setTimeout: { _, _ in .success },
            read: { _, _ in clock += 0.07; return (.success, "late" as CFString) })
        try check(elapsedBudget.attribute(editorWindow, kAXTitleAttribute) == nil && !elapsedBudget.valid,
                  "a slow successful AX response cannot extend the total snapshot budget")
        try check(OpaqueEditorDestination.observationInterval >= 0.25, "recording observes window changes at a bounded rate")
        let edited = guardedTarget()
        invalidate?() // an edit, click or app departure, even if the target returns
        edited.opaqueEditor?.begin(shortcut: VoiceShortcut())
        let editedOutcome = await TextDelivery.deliver("changed target words", target: edited, mode: .paste, restoreClipboard: true, system: opaqueSystem)
        try check(opaquePosts == 1 && !editedOutcome.pasteWasAttempted && editedOutcome.failure == .focusChanged,
                  "a changed opaque target stays invalid even after focus returns and cannot paste twice")
        let missingObservation = guardedTarget(observation: false)
        let unavailable = await TextDelivery.deliver("unobserved words", target: missingObservation, mode: .paste, restoreClipboard: false, system: opaqueSystem)
        try check(!unavailable.pasteWasAttempted && opaquePosts == 1, "missing observation fails closed to one copy")
        let changedWindow = guardedTarget()
        stillCurrent = false
        let changedWindowOutcome = await TextDelivery.deliver("window changed words", target: changedWindow, mode: .paste, restoreClipboard: false, system: opaqueSystem)
        try check(!changedWindowOutcome.pasteWasAttempted && opaquePosts == 1, "the final exact-window check rejects an unseen window change")
        try check(!TextDelivery.confirms("exact words", before: .init(value: nil, selection: NSRange(location: 0, length: 0)),
                                        after: .init(value: nil, selection: NSRange(location: 11, length: 0))),
                  "caret movement alone cannot confirm exact inserted words")

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
        try check(TextDelivery.confirms("ab", before: .init(value: "aX", selection: nil),
                                       after: .init(value: "abaX", selection: nil)),
                  "an inserted span sharing only part of the old prefix is confirmed")
        try check(TextDelivery.confirms("bca", before: .init(value: "abcabc", selection: nil),
                                       after: .init(value: "abcabcabc", selection: nil)),
                  "repeated text can confirm an insertion between both unchanged boundaries")
        try check(TextDelivery.confirms("🧑‍🚀a", before: .init(value: "🧑‍🚀X", selection: nil),
                                       after: .init(value: "🧑‍🚀a🧑‍🚀X", selection: nil)),
                  "an ambiguous Unicode prefix is matched in UTF-16 without losing a character")
        try check(TextDelivery.confirms("🧑‍🚀e\u{301}", before: .init(value: "e\u{301}🧑‍🚀e\u{301}🧑‍🚀", selection: nil),
                                       after: .init(value: "e\u{301}🧑‍🚀e\u{301}🧑‍🚀e\u{301}🧑‍🚀", selection: nil)),
                  "repeated emoji and combining marks can match an interior insertion position")
        try check(!TextDelivery.confirms("ab", before: .init(value: "ac", selection: nil),
                                        after: .init(value: "abcc", selection: nil)),
                  "matching words outside the unchanged prefix and suffix cannot confirm a paste")
        let repeated = String(repeating: "a", count: 50_000)
        try check(TextDelivery.confirms(repeated + "b", before: .init(value: repeated, selection: nil),
                                       after: .init(value: repeated + "b" + repeated, selection: nil)),
                  "a long repeated prefix confirms without rebuilding the field for each candidate")
        let unchangedText = TextDelivery.FieldState(value: "words", selection: NSRange(location: 0, length: 5))
        try check(!TextDelivery.confirms("words", before: unchangedText, after: unchangedText)
                  && TextDelivery.confirms("words", before: unchangedText, after: .init(value: "words", selection: NSRange(location: 5, length: 0))),
                  "replacing identical selected text needs the resulting caret to confirm")
        // Dictated words fit the field (#14): the fitted words are copied only for the
        // paste itself, from the snapshot taken just before it; the clipboard holds the
        // transcript as dictated before and after, and the saved transcript is the caller's.
        let caretState = TextDelivery.FieldState(value: "Please bringtomorrow", selection: NSRange(location: 12, length: 0))
        let joined = DeliveryFixture(board)
        joined.state = caretState
        var pastedWords: String?
        var recording = joined.system
        recording.preparePaste = { _ in { pastedWords = board.string(forType: .string); joined.posted += 1 } }
        joined.duringConfirmation = { joined.state = .init(value: "Please bring the blue folder tomorrow", selection: NSRange(location: 29, length: 0)) }
        let fittedPaste = await joined.deliver("The blue folder", restore: false, fit: .init(), system: recording)
        try check(fittedPaste.wasPasted && joined.posted == 1 && joined.reads == 2 && pastedWords == " the blue folder ",
                  "a fitted paste fits the pre-paste snapshot without an extra read and pastes the fitted words")
        try check(board.string(forType: .string) == "The blue folder" && fittedPaste.clipboardChangeCount == board.changeCount,
                  "after a confirmed paste the transcript is copied back, as the live span leaves it")
        _ = TextDelivery.copy("earlier clipboard", to: board)
        let restoredFit = DeliveryFixture(board)
        restoredFit.state = caretState
        restoredFit.duringConfirmation = { restoredFit.state = joined.state }
        let restoredPaste = await restoredFit.deliver("The blue folder", fit: .init())
        try check(restoredPaste.wasPasted && board.string(forType: .string) == "earlier clipboard",
                  "a fitted paste restores the previous clipboard like any other")
        let unconfirmedFit = DeliveryFixture(board)
        unconfirmedFit.state = caretState
        let unconfirmedPaste = await unconfirmedFit.deliver("The blue folder", restore: false, fit: .init())
        try check(unconfirmedPaste.failure == .pasteUnconfirmed && unconfirmedFit.posted == 1 && board.string(forType: .string) == "The blue folder",
                  "an unconfirmed fitted paste leaves the transcript copied once polling ends")
        let unfitted = DeliveryFixture(board)
        unfitted.state = joined.state
        _ = await unfitted.deliver("The blue folder")
        try check(board.string(forType: .string) == "The blue folder", "without a boundary context the words are copied as dictated")
        // Every return before the paste leaves the transcript on the clipboard, never
        // words shaped for a caret that is no longer the target.
        let movedFit = DeliveryFixture(board)
        movedFit.state = caretState
        movedFit.beforePosting = { movedFit.eligible = false }
        let movedPaste = await movedFit.deliver("The blue folder", restore: false, fit: .init())
        try check(movedPaste.failure == .focusChanged && movedFit.posted == 0 && movedFit.reads == 1 && board.string(forType: .string) == "The blue folder",
                  "a focus change after the fit leaves the transcript copied")
        let unavailableFit = DeliveryFixture(board)
        unavailableFit.state = caretState
        var noPaste = unavailableFit.system
        noPaste.preparePaste = { _ in nil }
        let unavailablePaste = await unavailableFit.deliver("The blue folder", restore: false, fit: .init(), system: noPaste)
        try check(unavailablePaste.failure == .pasteUnavailable && board.string(forType: .string) == "The blue folder",
                  "unavailable paste after the fit leaves the transcript copied")
        let changedFit = DeliveryFixture(board)
        changedFit.state = caretState
        changedFit.beforePosting = { _ = TextDelivery.copy("newer before paste", to: board) }
        let changedPaste = await changedFit.deliver("The blue folder", restore: false, fit: .init())
        try check(changedPaste.failure == .clipboardChanged && changedFit.posted == 0 && board.string(forType: .string) == "newer before paste",
                  "a clipboard change after the fit is left alone")
        let cancelledFit = DeliveryFixture(board)
        cancelledFit.state = caretState
        var validations = 0
        let cancelledPaste = await TextDelivery.deliver("The blue folder", target: cancelledFit.target, mode: .paste, restoreClipboard: false,
                                                        validateTarget: { validations += 1; return validations < 2 }, fit: .init(), system: cancelledFit.system)
        try check(cancelledPaste.failure == .cancelled && cancelledFit.posted == 0 && cancelledFit.reads == 1 && board.string(forType: .string) == "The blue folder",
                  "cancellation after the fit leaves the transcript copied")
        // Cancellation during the confirmation poll is a post-paste exit like the others:
        // the fitted words were pasted once and the transcript is what stays copied.
        let cancelledPoll = DeliveryFixture(board)
        cancelledPoll.state = caretState
        var cancelledPollSystem = cancelledPoll.system
        cancelledPollSystem.pause = { _ in throw CancellationError() }
        let cancelledPollPaste = await TextDelivery.deliver("The blue folder", target: cancelledPoll.target, mode: .paste, restoreClipboard: false,
                                                            validateTarget: { true }, fit: .init(), system: cancelledPollSystem)
        try check(cancelledPollPaste.failure == .cancelled && cancelledPollPaste.pasteWasAttempted && cancelledPoll.posted == 1
                  && board.string(forType: .string) == "The blue folder" && cancelledPollPaste.clipboardChangeCount == board.changeCount,
                  "cancellation during the confirmation poll leaves the transcript copied and owned, not the fitted words")
        let unreadableFit = DeliveryFixture(board)
        unreadableFit.state = .init(value: nil, selection: nil)
        let unreadablePaste = await unreadableFit.deliver("The blue folder", fit: .init())
        try check(unreadablePaste.failure == .pasteUnconfirmed && board.string(forType: .string) == "The blue folder",
                  "an unreadable field value leaves the dictated words as they are")
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
