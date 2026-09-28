import AppKit

/// Delivery through `TextDelivery.System`: an untrusted Mac, an isolated
/// pasteboard and a recorder stand in for the real ones, so these checks never
/// read or change the person's clipboard or Accessibility approval (#165).
@MainActor
enum TextDeliveryChecks {
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
            preparePaste: { prepared += 1; return { posted += 1 } })
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
        print("TEXT_DELIVERY_CHECKS_OK: \(passed) checks; injected trust, recorded paste events and an isolated pasteboard only")
    }
}
