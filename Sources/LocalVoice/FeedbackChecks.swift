import AppKit
import Carbon

/// Brief feedback that teaches once and leaves work intact (#134 T5): the one
/// lifetime, the coach's host seam, the hold lesson, undelivered results and
/// the local Saved confirmations. Synthetic clocks and a preferences file in a
/// temporary folder; nothing is shown, recorded, posted or saved for real.
@MainActor
enum FeedbackChecks {
    private struct Failure: LocalizedError {
        let label: String
        var errorDescription: String? { "FEEDBACK CHECK FAILED: \(label)" }
    }

    static func run() throws {
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw Failure(label: label) }
            count += 1
        }
        try checkLifetime(check)
        try checkCoach(check)
        try checkHoldLesson(check)
        try checkUnresolvedDelivery(check)
        try checkShortcutConfirmation(check)
        print("FEEDBACK_CHECKS_OK: \(count) checks; one lifetime, the coach's host seam, the hold lesson, undelivered results and Saved confirmations")
    }

    typealias Check = (@autoclosure () throws -> Bool, String) throws -> Void

    // MARK: The one lifetime

    private static func checkLifetime(_ check: Check) throws {
        var lifetime = NoticeLifetime(duration: 4)
        try check(!lifetime.isRunning && lifetime.deadline == nil && !lifetime.isDue(at: 1_000_000), "a lifetime does not count before it is shown")
        lifetime.present(at: 100)
        try check(lifetime.deadline == 104 && lifetime.fraction(at: 100) == 1, "shown, it has four seconds and a full ring")
        try check(abs(lifetime.fraction(at: 102) - 0.5) < 0.0001, "the ring is half spent at two seconds")
        lifetime.present(at: 103)
        try check(lifetime.deadline == 104, "showing it again, as a rerender does, never restarts it")
        lifetime.hold(.pointer, true, at: 101)
        lifetime.hold(.focus, true, at: 101.5)
        try check(!lifetime.isRunning && lifetime.deadline == nil && lifetime.remaining(at: 500) == 3,
                  "overlapping pointer and focus holds pause the same remaining value")
        lifetime.hold(.pointer, false, at: 200)
        try check(!lifetime.isRunning && lifetime.remaining(at: 300) == 3, "time stays paused until every hold lets go")
        lifetime.hold(.pointer, false, at: 250)
        try check(!lifetime.isRunning, "releasing a hold twice resumes nothing")
        lifetime.hold(.focus, false, at: 300)
        try check(lifetime.deadline == 303 && !lifetime.isDue(at: 302.99) && lifetime.isDue(at: 303), "when all let go, only what was left runs")
        lifetime.hold(.menu, true, at: 302)
        lifetime.hold(.menu, false, at: 400)
        try check(lifetime.deadline == 401, "its own menu holds it the same way")
        var waiting = NoticeLifetime(duration: 4, waitsForDismissal: true)
        waiting.present(at: 10)
        try check(waiting.deadline == nil && !waiting.isDue(at: 1_000_000) && waiting.fraction(at: 1_000_000) == 1,
                  "with VoiceOver it waits for dismissal")
        var confirmation = LocalConfirmation("Saved", at: 50)
        try check(confirmation.lifetime.deadline == 54, "a local confirmation lasts four seconds from its success")
        confirmation = LocalConfirmation("Saved", at: 60)
        try check(confirmation.lifetime.deadline == 64, "each success gets its own four seconds")
    }

    // MARK: The coach and its host seam

    private static func isolatedDefaults() throws -> (UserDefaults, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorkbenchFeedbackChecks-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("preferences").path
        guard let defaults = UserDefaults(suiteName: path) else { throw Failure(label: "isolated preferences") }
        return (defaults, { defaults.removePersistentDomain(forName: path); try? FileManager.default.removeItem(at: folder) })
    }

    private static func checkCoach(_ check: Check) throws {
        let (defaults, cleanUp) = try isolatedDefaults()
        defer { cleanUp() }
        var clock: TimeInterval = 1_000
        let workspace = NotificationCenter(), distributed = NotificationCenter()
        var announced: [String] = []
        func coach(_ tips: CoachTips) -> FeedbackCoachModel {
            let model = FeedbackCoachModel(tips: tips, clock: { clock }, workspace: workspace, distributed: distributed)
            model.voiceOverEnabled = { false }
            model.announce = { announced.append($0) }
            return model
        }
        let tips = CoachTips(defaults: defaults)
        let model = coach(tips)
        let lesson = HoldLesson.card(shortcut: "⌥V")
        try check(!model.request(lesson) && model.card == nil && !tips.isRetired(HoldLesson.tip),
                  "with no host to show it, a lesson is not requested and not spent")
        var hostAllows = false
        model.canPresent = { hostAllows }
        try check(!model.request(lesson) && model.card == nil, "a blocked presentation is dropped, not queued")
        hostAllows = true
        try check(model.request(lesson) && model.card == lesson && !model.isPresented && !tips.isRetired(HoldLesson.tip),
                  "a lesson the host can show waits for the host, still unspent")
        try check(model.lifetime?.deadline == nil, "its four seconds have not started before the host shows it")
        model.drop(lesson.id)
        try check(model.card == nil && !tips.isRetired(HoldLesson.tip), "a card the host could not show is dropped and the lesson stays")

        try check(model.request(lesson), "the next qualifying gesture can ask again")
        clock = 1_010
        model.didPresent(lesson.id)
        try check(model.isPresented && model.lifetime?.deadline == 1_014 && tips.isRetired(HoldLesson.tip)
                  && announced == ["Hold ⌥V to dictate. Keep holding while you speak. Release to finish."],
                  "shown by the host: four seconds start, the lesson is spent and VoiceOver hears it once")
        clock = 1_012
        model.didPresent(lesson.id)
        try check(model.lifetime?.deadline == 1_014 && announced.count == 1, "the host reporting again restarts and repeats nothing")
        model.drop(lesson.id)
        try check(model.card == lesson, "a shown card cannot be dropped as if it never appeared")
        model.hold(.pointer, true, for: lesson.id)
        clock = 1_030; model.expire(lesson.id)
        try check(model.card == lesson && model.lifetime?.remaining(at: clock) == 2, "the pointer holds it; its old deadline cannot end it")
        model.hold(.pointer, false, for: lesson.id)
        clock = 1_031.9; model.expire(lesson.id)
        try check(model.card == lesson, "released, it keeps the two seconds it had left")
        clock = 1_032; model.expire(lesson.id)
        try check(model.card == nil && model.lifetime == nil, "unheld, it goes at its deadline")

        let other = FeedbackCoachModel.Card(tip: "fixture.other", symbol: "keyboard", title: "Another lesson.", body: "A second tip.")
        let third = FeedbackCoachModel.Card(tip: "fixture.third", symbol: "keyboard", title: "A third lesson.", body: "A third tip.")
        try check(model.request(other), "another lesson can ask")
        model.didPresent(other.id)
        try check(model.request(third) && model.card == third && model.lifetime?.event == third.id, "at most one card: a newer one replaces it")
        model.didPresent(third.id)
        clock += 10; model.expire(other.id)
        try check(model.card == third, "a stale expiry from the replaced card cannot end the newer one")
        model.dismiss(other.id)
        try check(model.card == third, "dismissing a card that is gone changes nothing")
        model.dismiss(third.id)
        try check(model.card == nil, "× dismisses it at once")
        try check(!model.request(lesson), "a lesson already taught is not asked again")

        let fourth = FeedbackCoachModel.Card(tip: "fixture.fourth", symbol: "keyboard", title: "Lock.", body: "Taken down.")
        try check(model.request(fourth), "a lesson before a lock")
        model.didPresent(fourth.id)
        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        try check(model.card == nil, "locking the screen takes it down")
        let fifth = FeedbackCoachModel.Card(tip: "fixture.fifth", symbol: "keyboard", title: "Sleep.", body: "Taken down.")
        try check(model.request(fifth), "a lesson before sleep")
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        try check(model.card == nil && !CoachTips(defaults: defaults).isRetired(fifth.tip), "sleep takes down a card never shown, without spending it")

        let spoken = coach(tips)
        spoken.voiceOverEnabled = { true }
        spoken.canPresent = { true }
        let sixth = FeedbackCoachModel.Card(tip: "fixture.sixth", symbol: "keyboard", title: "VoiceOver.", body: "Waits.")
        try check(spoken.request(sixth), "with VoiceOver a lesson can still show")
        spoken.didPresent(sixth.id)
        clock += 3_600; spoken.expire(sixth.id)
        try check(spoken.card == sixth && spoken.lifetime?.waitsForDismissal == true, "with VoiceOver it waits for dismissal")
        spoken.remove()
        try check(spoken.card == nil, "a new capture or teardown still removes it")

        let relaunched = CoachTips(defaults: defaults)
        try check(relaunched.isRetired(HoldLesson.tip) && relaunched.isRetired(other.tip), "relaunch keeps every lesson taught")
        try check(HoldLesson.card(shortcut: "⌃⌥Space").tip == HoldLesson.tip && !coach(relaunched).request(HoldLesson.card(shortcut: "⌃⌥Space")),
                  "rebinding the shortcut does not bring the lesson back")
    }

    // MARK: The hold lesson

    private static func checkHoldLesson(_ check: Check) throws {
        let attempt = UUID()
        func gesture(_ down: TimeInterval, _ up: TimeInterval?) -> HoldGesture {
            var gesture = HoldGesture(attempt: attempt, pressedAt: down)
            if let up { gesture.release(at: up) }
            return gesture
        }
        try check(HoldLesson.teaches(gesture(10, 10.2), outcome: .tooShort), "a press of the shortcut in Hold let go too soon teaches")
        try check(!HoldLesson.teaches(nil, outcome: .tooShort), "without a timed press (Toggle, a click, a failed start) nothing teaches")
        try check(!HoldLesson.teaches(gesture(10, nil), outcome: .tooShort), "a press still down, or ended by a cancel, never teaches")
        try check(!HoldLesson.teaches(gesture(10, 11), outcome: .tooShort), "a long hold with a slow recorder is not called a tap")
        try check(!HoldLesson.teaches(gesture(0, CaptureCue.shortestSpeech), outcome: .tooShort), "a press as long as the shortest speech does not teach")
        try check(!HoldLesson.teaches(gesture(10, 10.2), outcome: .tooQuiet), "a genuine hold that heard only silence does not teach")
        try check(!HoldLesson.teaches(gesture(10, 10.2), outcome: .nothingRecognised(keptAudio: true)), "no words recognised does not teach")
        var repeated = gesture(10, nil)
        repeated.release(at: 10.1); repeated.release(at: 12)
        try check(repeated.interval.map { abs($0 - 0.1) < 0.0001 } == true, "the first release is the release; a later one cannot stretch it")
        try check(HoldLesson.title(shortcut: "⌥V") == "Hold ⌥V to dictate." && HoldLesson.title(shortcut: "⌃⌥Space") == "Hold ⌃⌥Space to dictate.",
                  "the lesson names the shortcut as it is saved")
        try check(HoldLesson.body == "Keep holding while you speak. Release to finish.", "the lesson's second line")
        let words = [HoldLesson.title(shortcut: "⌥V"), HoldLesson.body].joined(separator: " ")
        try check(!words.contains("—") && !words.contains("–") && !words.lowercased().contains("fn"), "plain words, no dashes and no assumed fn key")
    }

    // MARK: Undelivered results

    private static func checkUnresolvedDelivery(_ check: Check) throws {
        func outcome(_ failure: TextDelivery.FailureKind?, pasted: Bool = false, attempted: Bool = false) -> TextDelivery.Outcome {
            .init(message: "Synthetic.", clipboardChangeCount: 1, wasPasted: pasted, destinationName: "Notes", failure: failure, pasteWasAttempted: attempted)
        }
        try check(UnresolvedDelivery.kind(of: outcome(.copyFailed)) == .copyFailed, "a failed copy is undelivered")
        try check(UnresolvedDelivery.kind(of: outcome(.pasteUnconfirmed, attempted: true)) == .pasteUnconfirmed, "an unconfirmed paste is uncertain")
        try check(UnresolvedDelivery.kind(of: outcome(.cancelled, attempted: true)) == .stopped(pasteSent: true)
                  && UnresolvedDelivery.kind(of: outcome(.cancelled)) == .stopped(pasteSent: false), "a stopped delivery says whether ⌘V went")
        try check(UnresolvedDelivery.kind(of: outcome(.clipboardChanged)) == .notPasted, "a clipboard change before insertion pasted nothing")
        for delivered in [outcome(nil), outcome(nil, pasted: true, attempted: true), outcome(.clipboardRestoreFailed, pasted: true, attempted: true),
                          outcome(.accessibilityUnavailable), outcome(.focusChanged), outcome(.fieldUnreadable), outcome(.pasteUnavailable)] {
            try check(UnresolvedDelivery.kind(of: delivered) == nil, "a copy waiting for ⌘V or a confirmed paste is delivered: \(String(describing: delivered.failure))")
        }
        let id = UUID()
        let uncertain = UnresolvedDelivery(kind: .pasteUnconfirmed, reference: .transcript(id), wordCount: 4)
        let stoppedAfterPaste = UnresolvedDelivery(kind: .stopped(pasteSent: true), reference: .transcript(id), wordCount: 4)
        try check(!uncertain.offersCopy && !stoppedAfterPaste.offersCopy, "an uncertain paste never offers another copy to paste")
        try check(UnresolvedDelivery(kind: .copyFailed, reference: .draft, wordCount: 4).offersCopy
                  && UnresolvedDelivery(kind: .notPasted, reference: .transcript(id), wordCount: 4).offersCopy, "an undelivered copy offers Copy again")
        let words = [UnresolvedDelivery.Kind.copyFailed, .pasteUnconfirmed, .stopped(pasteSent: true), .stopped(pasteSent: false), .notPasted]
            .flatMap { kind in [UnresolvedDelivery(kind: kind, reference: .transcript(id), wordCount: 1),
                                UnresolvedDelivery(kind: kind, reference: .draft, wordCount: 1)] }
            .flatMap { [$0.title, $0.detail] }.joined(separator: " ")
        try check(!words.contains("—") && !words.contains("–") && !words.lowercased().contains("attention") && words.contains("History")
                  && words.contains("Dictate draft"), "each says where the words are, in plain words")
    }

    // MARK: Saved and Practice complete

    private static func checkShortcutConfirmation(_ check: Check) throws {
        var clock: TimeInterval = 2_000
        let start = VoiceShortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey))
        var updates = 0
        let keyboard = KeyboardCoachModel(entries: [ShortcutEntry(id: "voice.8", title: "Snap", shortcut: start)],
                                          update: { _, _ in updates += 1; return nil }, suspend: { _ in }, probe: { _ in nil },
                                          notifications: NotificationCenter(), clock: { clock })
        let editor = PanelShortcutEditor(keyboard: keyboard)
        func key(_ type: NSEvent.EventType, _ code: Int, option: Bool = true) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: option ? [.option] : [], timestamp: 0, windowNumber: 0,
                             context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code))!
        }
        editor.change("voice.8")
        _ = keyboard.handle(key(.keyDown, kVK_ANSI_2))
        let saved = VoiceShortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(optionKey))
        try check(updates == 1 && keyboard.selected?.shortcut == saved && keyboard.confirmation?.kind == .saved,
                  "✓ Saved appears only after the owner kept the new shortcut")
        let event = keyboard.confirmation!.lifetime.event
        clock += 3.9; keyboard.expireConfirmation(event)
        try check(keyboard.confirmation?.kind == .saved, "it lasts four seconds")
        clock += 0.1; keyboard.expireConfirmation(event)
        try check(keyboard.confirmation == nil && keyboard.selected?.shortcut == saved && editor.shortcutID == "voice.8"
                  && keyboard.message == "Try it here to build the habit.", "expiry clears only the check: the shortcut, the editor and its words stay")
        keyboard.beginRecording()
        _ = keyboard.handle(key(.keyDown, kVK_ANSI_V, option: false))
        try check(keyboard.confirmation == nil && keyboard.hasError, "a refused combination shows its reason and no check")
        keyboard.stopInteraction()

        keyboard.beginPractice()
        for _ in 0..<3 { _ = keyboard.handle(key(.keyDown, kVK_ANSI_2)); _ = keyboard.handle(key(.keyUp, kVK_ANSI_2, option: false)) }
        try check(keyboard.practice?.isComplete == true && keyboard.confirmation?.kind == .practiceComplete,
                  "✓ Practice complete appears only after three complete presses")
        let practiced = keyboard.confirmation!.lifetime.event
        keyboard.beginPractice()
        try check(keyboard.confirmation == nil && keyboard.isInteracting, "starting practice again starts without the old check")
        clock += 10; keyboard.expireConfirmation(practiced)
        try check(keyboard.isInteracting && keyboard.interaction == .practicing, "an old check's expiry never stops practice in progress")
        keyboard.stopInteraction()
        editor.end()
        try check(keyboard.confirmation == nil, "closing the editor ends its check")
        try check(ShortcutConfirmation.texts == ["Saved", "Practice complete"], "the two confirmations, and the space kept for them")

        let refusing = KeyboardCoachModel(entries: [ShortcutEntry(id: "voice.8", title: "Snap", shortcut: start)],
                                          update: { _, _ in "Registration changed during the save." }, suspend: { _ in }, probe: { _ in nil },
                                          notifications: NotificationCenter(), clock: { clock })
        refusing.beginRecording()
        _ = refusing.handle(key(.keyDown, kVK_ANSI_3))
        try check(refusing.confirmation == nil && refusing.hasError && refusing.selected?.shortcut == start,
                  "✓ Saved never shows when the owner could not keep the change")
    }
}
