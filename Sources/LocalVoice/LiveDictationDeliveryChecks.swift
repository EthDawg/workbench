import AppKit

/// No personal field, clipboard, input monitor or AX permission is touched. The real
/// owner runs against an adversarial adapter and an owned native NSTextView receiver.
@MainActor
enum LiveDictationDeliveryChecks {
    @MainActor private final class Field {
        var state: TextDelivery.FieldState
        var eligible = true, settable = true, readable = true
        var failSelection = false, failReplacement = false, mutateThenFail = false
        var mutateBeforeReplacement = false
        var inputOnSelect = false
        var selectCalls = 0, replaceCalls = 0, reads = 0, copies: [String] = [], stops = 0
        var now = 0.0
        var onInput: (() -> Void)?, onCheck: (() -> Void)?
        init(_ text: String = "prefix OLD suffix", _ range: NSRange = NSRange(location: 7, length: 3)) {
            state = .init(value: text, selection: range)
        }
        var system: LiveDictationDelivery.System {
            .init(read: { self.reads += 1; return self.eligible && self.readable ? self.state : nil }, canReplaceSelection: { self.settable },
                  select: { range in
                      self.selectCalls += 1
                      if self.failSelection { return false }
                      self.state.selection = range
                      if self.inputOnSelect { self.onInput?() }
                      if self.mutateBeforeReplacement { self.state.value! += "user" }
                      return true
                  }, replaceSelection: { text in
                      self.replaceCalls += 1
                      if self.failReplacement { return false }
                      guard var value = self.state.value, let selection = self.state.selection,
                            let range = Range(selection, in: value) else { return false }
                      value.replaceSubrange(range, with: text)
                      self.state = .init(value: value, selection: .init(location: selection.location + text.utf16.count, length: 0))
                      return !self.mutateThenFail
                  }, observe: { input, check in
                      self.onInput = input; self.onCheck = check
                      return { self.stops += 1; self.onInput = nil; self.onCheck = nil }
                  }, copy: { self.copies.append($0); return self.copies.count }, now: { self.now })
        }
        func owner() -> LiveDictationDelivery? { .init(initial: state, destinationName: "Fixture", system: system) }
        func next() { now += 1 }
    }
    private struct Failure: Error { let message: String }
    static func run() throws {
        var count = 0
        func expect(_ result: Bool, _ message: String) throws {
            guard result else { throw Failure(message: "Live field check failed: " + message) }
            count += 1
        }
        let field = Field("🙂 prefix OLD suffix 👩🏽‍💻", NSRange(location: 10, length: 3))
        let original = field.state
        let live = field.owner()!
        live.preview("hello")
        try expect(field.state.value == "🙂 prefix hello suffix 👩🏽‍💻", "only the selected UTF16 span changes")
        field.next(); live.preview("hello world 🌍")
        try expect(field.state.value == "🙂 prefix hello world 🌍 suffix 👩🏽‍💻", "provisional replacement does not append duplicate words")
        try expect(field.copies.isEmpty, "preview leaves clipboard alone")
        let finished = live.finish("Hello, world! 🌍", restoreClipboard: true)
        try expect(finished.wasPasted && field.state.value == "🙂 prefix hello, world! 🌍 suffix 👩🏽‍💻", "final cleanup replaces owned span and fits mid-sentence (#14)")
        try expect(field.copies.isEmpty && field.stops == 1, "preserved clipboard and observer teardown")
        live.preview("late")
        try expect(field.replaceCalls == 3, "late previews cannot mutate a finished field")

        let cancelField = Field(original.value!, original.selection!)
        let cancel = cancelField.owner()!
        cancel.preview("replacement 🦜")
        try expect(cancel.cancel() == nil && cancelField.state == original, "cancel restores selected original text and exact selection")
        let cancelledWrites = cancelField.replaceCalls
        cancel.preview("later")
        try expect(cancelField.replaceCalls == cancelledWrites, "cancel ends insertion ownership")

        let copied = Field(); let copyOwner = copied.owner()!
        copyOwner.preview("one"); _ = copyOwner.finish("One.", restoreClipboard: false)
        try expect(copied.copies == ["One."], "copy preference applies only to final result")

        let moved = Field(); let movedOwner = moved.owner()!
        movedOwner.preview("one"); moved.eligible = false; moved.onCheck?(); moved.eligible = true; moved.next()
        movedOwner.preview("two")
        let stopped = movedOwner.finish("Two.", restoreClipboard: true)
        try expect(movedOwner.invalidated && moved.replaceCalls == 1 && !stopped.wasPasted && stopped.pasteWasAttempted,
                   "focus changes permanently stop writes and final paste")
        try expect(movedOwner.cancel() != nil && moved.state.value == "prefix one suffix", "invalidated cancel never rewrites destination")

        let typed = Field(); let typedOwner = typed.owner()!
        typedOwner.preview("spoken"); let spokenState = typed.state
        typed.state.value! += "typed"; typed.onInput?(); typed.state = spokenState; typed.next()
        typedOwner.preview("more")
        try expect(typed.replaceCalls == 1 && typedOwner.invalidated, "typing then undoing never resumes ownership")

        let caret = Field(); let caretOwner = caret.owner()!
        caretOwner.preview("spoken"); caret.state.selection = .init(location: 0, length: 0); caret.onCheck?(); caret.next()
        caretOwner.preview("more")
        try expect(caret.replaceCalls == 1 && caretOwner.invalidated, "caret movement invalidates even unchanged text")

        let outside = Field(); let outsideOwner = outside.owner()!
        outsideOwner.preview("spoken"); outside.state.value = "PREFIX spoken suffix"; outside.next()
        outsideOwner.preview("more")
        try expect(outside.replaceCalls == 1 && outsideOwner.invalidated, "full field is verified before every edit")

        let uncertain = Field(); let uncertainOwner = uncertain.owner()!
        uncertain.mutateThenFail = true; uncertainOwner.preview("maybe inserted"); uncertain.next()
        uncertainOwner.preview("must not retry")
        let uncertainResult = uncertainOwner.finish("Final words", restoreClipboard: true)
        try expect(uncertain.replaceCalls == 1 && uncertain.state.value == "prefix maybe inserted suffix" && uncertainResult.failure == .pasteUnconfirmed,
                   "mutation followed by timeout is never retried")
        try expect(uncertainOwner.cancel() != nil, "unknown write cannot roll back")

        let failedSelect = Field(); let selectionOwner = failedSelect.owner()!
        failedSelect.failSelection = true; selectionOwner.preview("hello")
        try expect(selectionOwner.attempted && selectionOwner.invalidated && failedSelect.replaceCalls == 0,
                   "selection failure counts as uncertain mutation without text write")
        let changedBetween = Field(); let changedOwner = changedBetween.owner()!
        changedBetween.mutateBeforeReplacement = true; changedOwner.preview("hello")
        try expect(changedOwner.invalidated && changedBetween.replaceCalls == 0, "selection is rechecked before replacing text")
        let inputBetween = Field(); let inputOwner = inputBetween.owner()!
        inputBetween.inputOnSelect = true; inputOwner.preview("hello")
        try expect(inputOwner.invalidated && inputBetween.replaceCalls == 0, "input arriving during selection prevents subsequent text write")

        let unsupported = Field(); unsupported.settable = false
        try expect(unsupported.owner() == nil && unsupported.selectCalls == 0, "unsupported field is ordinary final-delivery fallback")
        let unreadable = Field(); let unreadableOwner = unreadable.owner()!; unreadable.readable = false; unreadable.next()
        unreadableOwner.preview("hello")
        try expect(unreadableOwner.invalidated && unreadable.selectCalls == 0, "unreadable established field cannot become fallback paste")
        let initialChanged = Field(); let captured = initialChanged.state; initialChanged.state.value! += "changed"
        let changedInitialOwner = LiveDictationDelivery(initial: captured, destinationName: "Fixture", system: initialChanged.system)
        try expect(changedInitialOwner?.invalidated == true, "changed captured value remains a stopped owner rather than falling back")
        let badRange = Field("😀", NSRange(location: 1, length: 0))
        try expect(badRange.owner() == nil, "split-surrogate selection is refused")

        let limited = Field(); let rateOwner = limited.owner()!
        rateOwner.preview("one"); rateOwner.preview("two")
        try expect(limited.replaceCalls == 1, "provisional writes are rate limited")
        _ = rateOwner.finish("two", restoreClipboard: true)
        try expect(limited.replaceCalls == 2 && limited.state.value == "prefix two suffix", "final text bypasses rate limit")

        // Dictated words fit the owned span's boundary (#14): the first partial sets
        // the prefix, every later write keeps it, and cancel restores the original.
        let joined = Field("Please bringtomorrow", NSRange(location: 12, length: 0)); let joinedOwner = joined.owner()!
        joinedOwner.preview("the")
        try expect(joined.state.value == "Please bring the tomorrow", "the first partial gains the spaces the boundary needs")
        joined.next(); joinedOwner.preview("The blue")
        try expect(joined.state.value == "Please bring the blue tomorrow", "later partials keep the prefix and lose the spurious capital")
        let fitted = joinedOwner.finish("The blue folder.", restoreClipboard: true)
        try expect(fitted.wasPasted && joined.state.value == "Please bring the blue folder tomorrow", "final cleanup fits the same span, dropping a mid-sentence full stop")
        joined.next()
        let settledReads = joined.reads, settledReplacements = joined.replaceCalls
        joinedOwner.preview("The blue")
        try expect(joined.reads == settledReads && joined.replaceCalls == settledReplacements,
                   "a repeated partial that fits to the inserted text neither reads nor writes the field")
        let fittedCancel = Field("Please bringtomorrow", NSRange(location: 12, length: 0)); let fittedCancelOwner = fittedCancel.owner()!
        fittedCancelOwner.preview("the blue")
        try expect(fittedCancel.state.value == "Please bring the blue tomorrow" && fittedCancelOwner.cancel() == nil
                   && fittedCancel.state == .init(value: "Please bringtomorrow", selection: NSRange(location: 12, length: 0)),
                   "cancel restores the field without the fitted spaces")
        let sentence = Field("Done.", NSRange(location: 5, length: 0)); let sentenceOwner = sentence.owner()!
        sentenceOwner.preview("next"); sentence.next()
        try expect(sentence.state.value == "Done. Next", "a sentence start after a full stop gains a space and a capital")
        _ = sentenceOwner.finish("Next step.", restoreClipboard: true)
        try expect(sentence.state.value == "Done. Next step.", "the final text keeps the established prefix")
        let named = Field("I spoke to  yesterday", NSRange(location: 11, length: 0))
        let namedOwner = LiveDictationDelivery(initial: named.state, destinationName: "Fixture", system: named.system,
                                               context: .init(dictionaryTerms: ["Mark"]))!
        namedOwner.preview("Mark")
        try expect(named.state.value == "I spoke to Mark yesterday", "a dictionary name keeps its capital mid-sentence")

        // Native receiver semantics with a synthetic, unshown view. This exercises
        // actual NSTextView selection/replacement, not remote AX IPC acceptance.
        let native = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        native.string = "Before 🦜 After"; native.setSelectedRange(NSRange(location: 7, length: 2))
        let nativeState: () -> TextDelivery.FieldState = { .init(value: native.string, selection: native.selectedRange()) }
        let nativeOriginal = nativeState()
        let nativeOwner = LiveDictationDelivery(initial: nativeOriginal, destinationName: "Synthetic NSTextView", system: .init(
            read: nativeState, canReplaceSelection: { true }, select: { native.setSelectedRange($0); return true },
            replaceSelection: { native.insertText($0, replacementRange: native.selectedRange()); return true },
            observe: { _, _ in {} }, copy: { _ in nil }))!
        nativeOwner.preview("two words")
        try expect(native.string == "Before two words After", "native text view receives only the owned span")
        try expect(nativeOwner.cancel() == nil && nativeState() == nativeOriginal, "native receiver restores emoji and selection")
        print("Live dictation field checks passed (\(count)): owned spans, UTF16, cleanup, boundary fit, cancellation, focus/input invalidation, uncertain writes, clipboard and native NSTextView. No external fields or personal clipboard used.")
    }
}
