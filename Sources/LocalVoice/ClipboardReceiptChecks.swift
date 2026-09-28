import AppKit

@MainActor
enum ClipboardReceiptChecks {
    static func run() throws {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
            guard condition() else { throw VoiceError.message("CLIPBOARD RECEIPT CHECK FAILED: " + name) }
            passed += 1
        }
        var clipboardCount = 10
        var clock: TimeInterval = 1_000
        let model = ClipboardReceiptModel(clipboardChangeCount: { clipboardCount }, now: { clock }, automaticallySchedules: false)
        func copied(_ count: Int) -> TextDelivery.Outcome {
            TextDelivery.Outcome(message: TextDelivery.copiedMessage, clipboardChangeCount: count, wasPasted: false, destinationName: nil)
        }
        model.record(outcome: copied(10), wordCount: 6)
        try check(model.isHUDVisible && model.receipt?.isClipboardCurrent == true && model.receipt?.wordCount == 6,
                  "own copy creates visible metadata receipt")
        try check(model.receipt?.title == "Copied" && model.receipt?.detail == "Paste with ⌘V.",
                  "a copy's receipt reads Copied and Paste with ⌘V.")
        clock += 8; model.refreshClipboardOwnership()
        try check(!model.isHUDVisible && model.receipt?.isClipboardCurrent == true,
                  "copied HUD expires but current clipboard shelf remains")
        let retainedID = model.receipt?.id
        model.revealHUD()
        try check(model.isHUDVisible && model.receipt?.id == retainedID && model.receipt?.canSuggestPaste == true
                  && clipboardCount == 10, "reveal reopens the same safe-to-paste receipt without recopying")
        clipboardCount = 11; model.refreshClipboardOwnership()
        try check(model.receipt == nil && !model.isHUDVisible, "unrelated copy clears the stale shelf")
        model.revealHUD()
        try check(model.receipt == nil && !model.isHUDVisible, "reveal cannot resurrect a stale clipboard receipt")

        model.record(outcome: copied(11), wordCount: 3)
        model.keepVisible = true
        clock += 80; model.refreshClipboardOwnership()
        try check(model.isHUDVisible && model.keepVisible, "pin survives the normal HUD deadline")
        clipboardCount = 12; model.refreshClipboardOwnership()
        try check(model.receipt == nil && !model.isHUDVisible && !model.keepVisible, "new clipboard ends a pinned receipt")

        model.record(outcome: copied(12), wordCount: 4)
        let oldID = model.receipt?.id
        clock += 7
        model.record(outcome: copied(12), wordCount: 8)
        let newID = model.receipt?.id
        clock += 2; model.refreshClipboardOwnership()
        try check(model.isHUDVisible && model.receipt?.id == newID && newID != oldID,
                  "an older receipt deadline cannot hide a newer receipt")
        clock += 6; model.refreshClipboardOwnership()
        try check(!model.isHUDVisible && model.receipt?.id == newID, "new receipt uses its own full deadline")

        let restored = TextDelivery.Outcome(message: "Pasted into Notes. Previous clipboard restored.",
                                           clipboardChangeCount: nil, wasPasted: true, destinationName: "Notes")
        model.record(outcome: restored, wordCount: 9)
        try check(model.receipt?.title == "Pasted into Notes" && model.receipt?.isClipboardCurrent == false
                  && model.receipt?.clipboardChangeCount == nil && model.receipt?.canSuggestPaste == false,
                  "restored clipboard never advertises copied transcript or duplicate paste")
        clock += 4; model.refreshClipboardOwnership()
        try check(model.receipt == nil && !model.isHUDVisible, "pasted-and-restored receipt ends after four seconds")

        model.record(outcome: copied(11), wordCount: 1)
        try check(model.receipt?.isClipboardCurrent == false && model.receipt?.title == "Transcript ready",
                  "already-stale outcome cannot create clipboard readiness")
        model.dismissHUD()
        try check(model.receipt == nil, "dismissing a receipt without ownership leaves no shelf")
        model.record(outcome: copied(12), wordCount: 1); model.keepVisible = true; model.dismissHUD()
        try check(!model.isHUDVisible && !model.keepVisible && model.receipt?.isClipboardCurrent == true,
                  "dismiss hides and unpins while preserving owned clipboard shelf")
        model.clear()
        try check(model.receipt == nil && !model.isHUDVisible && !model.keepVisible, "new recording clear removes all receipt state")

        // The HUD's countdown is its own lifetime (#134 T5): the pointer and a pin hold it,
        // the ring reads the same value, and only the HUD ends when it is due.
        model.record(outcome: copied(12), wordCount: 2)
        let receiptEvent = model.lifetime?.event
        clock += 2
        try check(abs((model.lifetime?.fraction(at: clock) ?? 0) - 0.75) < 0.0001, "a copy's ring shows six of eight seconds left")
        model.holdHUD(true); clock += 30; model.refreshClipboardOwnership()
        try check(model.isHUDVisible && abs((model.lifetime?.remaining(at: clock) ?? 0) - 6) < 0.0001,
                  "the pointer over the HUD pauses its time")
        model.holdHUD(false); clock += 5.9; model.refreshClipboardOwnership()
        try check(model.isHUDVisible, "letting go resumes the time that was left")
        model.keepVisible = true; clock += 60; model.refreshClipboardOwnership()
        try check(model.isHUDVisible && model.lifetime?.event == receiptEvent, "a pin holds the same lifetime")
        model.keepVisible = false; clock += 0.2; model.refreshClipboardOwnership()
        try check(!model.isHUDVisible && model.receipt?.isClipboardCurrent == true, "unpinned, the HUD goes when its time is spent; the shelf stays")
        model.clear()

        model.record(outcome: TextDelivery.Outcome(message: "Copy was unavailable.", clipboardChangeCount: nil,
                                                 wasPasted: false, destinationName: nil, failure: .copyFailed), wordCount: 5)
        try check(model.receipt?.title == "Copy failed" && model.receipt?.isClipboardCurrent == false && model.isHUDVisible,
                  "copy failure remains a dismissible error, never a success receipt")
        model.dismissHUD()
        try check(model.receipt == nil, "copy failure can be dismissed")
        model.record(outcome: TextDelivery.Outcome(message: "Paste sent.", clipboardChangeCount: 12,
                                                 wasPasted: false, destinationName: "Notes", failure: .pasteUnconfirmed), wordCount: 2)
        try check(model.receipt?.title == "Paste unconfirmed" && model.receipt?.wasPasted == false && model.receipt?.canSuggestPaste == false,
                  "unconfirmed paste remains distinct from confirmed insertion")
        model.record(outcome: TextDelivery.Outcome(message: "Paste sent before cancellation.", clipboardChangeCount: 12,
                                                 wasPasted: false, destinationName: "Notes", failure: .cancelled,
                                                 pasteWasAttempted: true), wordCount: 2)
        try check(model.receipt?.isClipboardCurrent == true && model.receipt?.canSuggestPaste == false,
                  "cancelled attempted paste does not suggest a duplicate Command-V")
        model.record(outcome: TextDelivery.Outcome(message: "Pasted into Notes.", clipboardChangeCount: 12,
                                                 wasPasted: true, destinationName: "Notes", pasteWasAttempted: true), wordCount: 2)
        try check(model.receipt?.isClipboardCurrent == true && model.receipt?.canSuggestPaste == false,
                  "confirmed paste without restoration does not suggest pasting twice")
        model.clear()

        // Use a unique pasteboard: these checks never touch the user's clipboard.
        let board = NSPasteboard(name: .init("Workbench.ClipboardChecks." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let snapshot = NSPasteboardItem(); snapshot.setString("earlier synthetic content", forType: .string)
        guard let owned = TextDelivery.copy("synthetic transcript", to: board) else {
            throw VoiceError.message("CLIPBOARD RECEIPT CHECK FAILED: isolated copy failed")
        }
        try check(board.changeCount == owned && board.string(forType: .string) == "synthetic transcript",
                  "successful copy returns its actual pasteboard change count")
        let restoredState = TextDelivery.restoreClipboardSnapshot([snapshot], on: board, ownedChange: owned, snapshotIsStable: true)
        try check(restoredState == .restored && board.changeCount != owned && board.string(forType: .string) == "earlier synthetic content",
                  "restoration ends ownership and restores the prior value")
        guard let nextOwned = TextDelivery.copy("another synthetic transcript", to: board),
              let laterCopy = TextDelivery.copy("unrelated newer copy", to: board) else {
            throw VoiceError.message("CLIPBOARD RECEIPT CHECK FAILED: isolated later copy failed")
        }
        let refused = TextDelivery.restoreClipboardSnapshot([snapshot], on: board, ownedChange: nextOwned, snapshotIsStable: true)
        try check(refused == .notAttempted && board.changeCount == laterCopy && board.string(forType: .string) == "unrelated newer copy",
                  "restoration never overwrites a newer copy")
        let unstable = TextDelivery.restoreClipboardSnapshot([snapshot], on: board, ownedChange: laterCopy, snapshotIsStable: false)
        try check(unstable == .notAttempted && board.changeCount == laterCopy, "an unstable prior snapshot is not restored")
        try check(TextDelivery.copy("", to: board) == nil && board.changeCount == laterCopy,
                  "failed empty copy does not clear a clipboard or issue a success token")
        print("CLIPBOARD_RECEIPT_CHECKS_OK: \(passed) checks; synthetic metadata and isolated pasteboard only")
    }
}
