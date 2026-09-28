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
        try checkPointerPresence(check)
        try checkHoldLesson(check)
        try checkUnresolvedDelivery(check)
        try checkShortcutConfirmation(check)
        print("FEEDBACK_CHECKS_OK: \(count) checks; one lifetime, the coach's host seam, a resting pointer, the hold lesson, undelivered results that survive quit, and Saved confirmations VoiceOver hears")
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
        var fallbacks = 0
        try check(model.request(lesson, otherwise: { fallbacks += 1 }) && model.card == lesson && !model.isPresented
                  && !tips.isRetired(HoldLesson.tip) && fallbacks == 0,
                  "a lesson the host can show waits for the host, still unspent")
        try check(model.lifetime?.deadline == nil, "its four seconds have not started before the host shows it")
        model.drop(lesson.id)
        try check(model.card == nil && !tips.isRetired(HoldLesson.tip) && fallbacks == 1,
                  "a card the host drops gives the owner's own feedback instead, once, and the lesson stays")
        model.drop(lesson.id)
        try check(fallbacks == 1, "dropping it again changes nothing")

        try check(model.request(lesson, otherwise: { fallbacks += 1 }), "the next qualifying gesture can ask again")
        clock = 1_010
        model.didPresent(lesson.id)
        try check(model.isPresented && model.lifetime?.deadline == 1_014 && tips.isRetired(HoldLesson.tip)
                  && announced == ["Hold ⌥V to dictate. Keep holding while you speak. Release to finish."],
                  "shown by the host: four seconds start, the lesson is spent and VoiceOver hears it once")
        clock = 1_012
        model.didPresent(lesson.id)
        try check(model.lifetime?.deadline == 1_014 && announced.count == 1, "the host reporting again restarts and repeats nothing")
        model.drop(lesson.id)
        try check(model.card == lesson && fallbacks == 1, "a shown card cannot be dropped as if it never appeared, and needs no fallback")
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

        let replacedCard = FeedbackCoachModel.Card(tip: "fixture.replaced", symbol: "keyboard", title: "Replaced.", body: "Never shown.")
        let removedCard = FeedbackCoachModel.Card(tip: "fixture.removed", symbol: "keyboard", title: "Removed.", body: "Never shown.")
        try check(model.request(replacedCard, otherwise: { fallbacks += 10 }) && model.request(removedCard, otherwise: { fallbacks += 100 }),
                  "a newer pending card replaces an older one")
        model.drop(replacedCard.id)
        try check(model.card == removedCard && fallbacks == 1, "the replaced card's fallback never runs, even if the host reports it dropped")
        model.remove()
        try check(model.card == nil && fallbacks == 1, "a new capture or teardown removes a pending card without its fallback")

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

    // MARK: A pointer resting where a notice appears

    /// A window that is never shown, with the pointer and the window's
    /// visibility supplied: nothing moves the real pointer or shows anything.
    private static func checkPointerPresence(_ check: Check) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 320, height: 120), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        window.contentView = host
        var pointer = NSPoint(x: 260, y: 350)
        var shown = true
        func presence(_ reports: @escaping (Bool) -> Void) -> PointerPresenceView {
            let view = PointerPresenceView(changed: reports)
            view.pointer = { pointer }; view.windowShows = { _ in shown }; view.deliver = { $0() }
            view.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
            return view
        }
        func crossing(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                   eventNumber: 0, trackingNumber: 0, userData: nil)!
        }
        var reports: [Bool] = []
        let resting = presence { reports.append($0) }
        host.addSubview(resting)
        try check(reports == [true] && resting.isInside, "a notice that appears under a resting pointer starts held")
        try check(resting.trackingAreas.contains { $0.options.contains(.assumeInside) }, "AppKit then reports when that pointer leaves")
        try check(resting.hitTest(NSPoint(x: 10, y: 10)) == nil, "it never takes a click")
        resting.mouseExited(with: crossing(.mouseExited))
        resting.mouseEntered(with: crossing(.mouseEntered))
        try check(reports == [true, false, true], "leaving lets go and coming back holds again")
        shown = false; resting.refresh()
        try check(reports.last == false, "a window taken off screen lets go")
        shown = true; resting.refresh()
        try check(reports.last == true, "back on screen under the pointer, it holds again")
        resting.removeFromSuperview()
        try check(reports == [true, false, true, false, true, false], "a notice that goes lets go")

        var elsewhere: [Bool] = []
        pointer = NSPoint(x: 900, y: 900)
        let away = presence { elsewhere.append($0) }
        host.addSubview(away)
        try check(elsewhere.isEmpty && !away.isInside && !away.trackingAreas.contains { $0.options.contains(.assumeInside) },
                  "a pointer elsewhere holds nothing, and AppKit reports when it arrives")
        away.removeFromSuperview()
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
        try check(UnresolvedDelivery(kind: .copyFailed, reference: .draft(revision: 1), wordCount: 4).offersCopy
                  && UnresolvedDelivery(kind: .notPasted, reference: .transcript(id), wordCount: 4).offersCopy, "an undelivered copy offers Copy again")
        let words = [UnresolvedDelivery.Kind.copyFailed, .pasteUnconfirmed, .stopped(pasteSent: true), .stopped(pasteSent: false), .notPasted]
            .flatMap { kind in [UnresolvedDelivery(kind: kind, reference: .transcript(id), wordCount: 1),
                                UnresolvedDelivery(kind: kind, reference: .draft(revision: 1), wordCount: 1)] }
            .flatMap { [$0.title, $0.detail] }.joined(separator: " ")
        try check(!words.contains("—") && !words.contains("–") && !words.lowercased().contains("attention") && words.contains("History")
                  && words.contains("Dictate draft"), "each says where the words are, in plain words")
        try checkUnresolvedSlot(check)
        try checkUnresolvedPersistence(check)
    }

    /// The one slot, driven the way its owner drives it: History and the draft
    /// are handed in as they are at each moment (#134 T5 review).
    private static func checkUnresolvedSlot(_ check: Check) throws {
        let dictated = Transcript(text: "Meet at noon by the river.", seconds: 2)
        let earlier = Transcript(text: "An earlier thought.", seconds: 1)
        var history = [dictated, earlier]
        var draft = (text: dictated.text, revision: UInt64(7))
        var records: DeliveryRecords { DeliveryRecords(history: history, draft: draft) }
        func sent(_ failure: TextDelivery.FailureKind? = nil) -> TextDelivery.Outcome {
            .init(message: "Synthetic.", clipboardChangeCount: 1, wasPasted: false, destinationName: nil,
                  failure: failure, pasteWasAttempted: failure == .pasteUnconfirmed)
        }
        var slot = UnresolvedDeliverySlot()
        slot.note(sent(.pasteUnconfirmed), text: dictated.text, from: .transcript(dictated.id), in: records)
        try check(slot.entry?.kind == .pasteUnconfirmed && slot.entry?.reference == .transcript(dictated.id) && slot.entry?.wordCount == 6,
                  "an unconfirmed paste of a dictation is kept with its transcript")
        slot.note(sent(), text: earlier.text, from: .transcript(earlier.id), in: records)
        try check(slot.entry?.kind == .pasteUnconfirmed, "delivering other words resolves nothing")
        slot.note(sent(), text: dictated.text, from: .draft(revision: draft.revision), in: records)
        try check(slot.entry == nil, "copying the same words from the draft resolves it: the words decide, not where they were copied from")

        slot.note(sent(.copyFailed), text: earlier.text, from: .transcript(earlier.id), in: records)
        slot.note(sent(.clipboardChanged), text: dictated.text, from: .transcript(dictated.id), in: records)
        try check(slot.entry?.kind == .notPasted && slot.entry?.reference == .transcript(dictated.id),
                  "one slot: a newer undelivered result takes the place of an older one, whose words stay in History")
        try check(slot.wordsToCopy(in: records) == dictated.text, "Copy again copies the transcript's words as History holds them")
        slot.transcriptRemoved(earlier.id)
        try check(slot.entry != nil, "removing another transcript leaves it")
        history.removeAll { $0.id == dictated.id }
        try check(slot.shown(in: records) == nil && slot.wordsToCopy(in: records) == nil && slot.saved(in: records) == nil,
                  "a transcript no longer in History shows, copies and saves nothing")
        slot.transcriptRemoved(dictated.id)
        try check(slot.entry == nil, "removing its transcript is the person's choice: the entry goes with it")
        history = [dictated, earlier]

        // A draft entry acts, and resolves, only while the draft is still the revision that failed.
        slot.note(sent(.copyFailed), text: draft.text, from: .draft(revision: draft.revision), in: records)
        try check(slot.entry?.reference == .draft(revision: 7) && slot.wordsToCopy(in: records) == draft.text
                  && slot.shown(in: records)?.offersCopy == true && slot.shown(in: records)?.draftChanged == false,
                  "a failed copy of the draft offers Copy again of that draft")
        draft = (text: "A new dictation replaced the draft.", revision: 8)
        let changed = slot.shown(in: records)
        try check(slot.wordsToCopy(in: records) == nil && changed?.offersCopy == false && changed?.draftChanged == true
                  && changed?.detail == "Your Dictate draft has changed since. Review it before copying." && changed?.isDraft == true,
                  "once the draft changes, Copy again never copies whatever the draft became; it says so and offers Review")
        slot.note(sent(), text: draft.text, from: .draft(revision: draft.revision), in: records)
        try check(slot.entry != nil, "copying the new draft does not resolve the old failure")
        draft = (text: dictated.text, revision: 9)
        slot.note(sent(), text: dictated.text, from: .draft(revision: draft.revision), in: records)
        try check(slot.entry != nil, "even the same words typed back later are a new revision: only Dismiss sets it aside")
        slot.dismiss()
        try check(slot.entry == nil, "Dismiss sets it aside")

        draft = (text: dictated.text, revision: 10)
        slot.note(sent(.copyFailed), text: draft.text, from: .draft(revision: draft.revision), in: records)
        slot.note(sent(), text: dictated.text, from: .transcript(dictated.id), in: records)
        try check(slot.entry == nil, "copying those words from History resolves a draft entry while the draft still holds them")
    }

    /// Survives quit (#134 T5 review): saved with the session as a record's
    /// name, never the words, and restored only while that record holds them.
    private static func checkUnresolvedPersistence(_ check: Check) throws {
        let dictated = Transcript(text: "Private words that stay in History.", seconds: 2)
        func sent(_ failure: TextDelivery.FailureKind?) -> TextDelivery.Outcome {
            .init(message: "Synthetic.", clipboardChangeCount: nil, wasPasted: false, destinationName: nil, failure: failure)
        }
        let live = DeliveryRecords(history: [dictated], draft: (text: "Draft words.", revision: 3))
        var transcriptSlot = UnresolvedDeliverySlot()
        transcriptSlot.note(sent(.copyFailed), text: dictated.text, from: .transcript(dictated.id), in: live)
        var draftSlot = UnresolvedDeliverySlot()
        draftSlot.note(sent(.clipboardChanged), text: "Draft words.", from: .draft(revision: 3), in: live)

        let state = SavedState(draft: "Draft words.", history: [dictated], rawDraft: "draft words", undelivered: transcriptSlot.saved(in: live))
        let data = try JSONEncoder().encode(state)
        let json = String(decoding: data, as: UTF8.self)
        let decoded = try JSONDecoder().decode(SavedState.self, from: data)
        try check(decoded.undelivered?.kind == .copyFailed && decoded.undelivered?.reference == .transcript(dictated.id)
                  && decoded.undelivered?.wordCount == 6, "the session keeps the undelivered result across quit")
        try check(json.components(separatedBy: dictated.text).count == 2, "it names the transcript; the words are saved once, in History, never again for it")
        let draftData = try JSONEncoder().encode(SavedState(draft: "Draft words.", undelivered: draftSlot.saved(in: live)))
        try check(String(decoding: draftData, as: UTF8.self).components(separatedBy: "Draft words.").count == 2,
                  "a draft entry names the draft; its words are saved once, as the draft")

        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy.removeValue(forKey: "undelivered")
        let older = try JSONDecoder().decode(SavedState.self, from: JSONSerialization.data(withJSONObject: legacy))
        try check(older.undelivered == nil && older.draft == "Draft words." && older.history.first?.id == dictated.id && older.rawDraft == "draft words",
                  "state saved before this change still decodes, with nothing undelivered")
        var future = legacy
        future["undelivered"] = ["kind": "somethingLater", "words": 3]
        let later = try? JSONDecoder().decode(SavedState.self, from: JSONSerialization.data(withJSONObject: future))
        try check(later != nil && later?.undelivered == nil && later?.draft == "Draft words." && later?.history.count == 1,
                  "a result this build cannot read is left out; the session still opens")
        var missing = legacy
        missing.removeValue(forKey: "draft")
        var refused = false
        do { _ = try JSONDecoder().decode(SavedState.self, from: JSONSerialization.data(withJSONObject: missing)) } catch { refused = true }
        try check(refused, "every other field decodes as strictly as before")

        // A write carries it only while what it writes still holds its words.
        try check(transcriptSlot.saved(in: DeliveryRecords(history: [], draft: nil)) == nil, "a write without its transcript drops it")
        try check(draftSlot.saved(in: DeliveryRecords(history: [], draft: (text: "Draft words.", revision: 4))) == nil
                  && draftSlot.saved(in: DeliveryRecords(history: [], draft: nil)) == nil,
                  "a write of a changed or replaced draft drops a draft entry")
        try check(draftSlot.saved(in: live)?.reference == .draft(revision: 3), "a write of the same draft keeps it")

        // Launch: back only with its words.
        var relaunched = UnresolvedDeliverySlot()
        relaunched.restore(decoded.undelivered, loadedDraftRevision: 1, in: DeliveryRecords(history: [dictated], draft: (text: "Draft words.", revision: 1)))
        try check(relaunched.entry?.reference == .transcript(dictated.id) && relaunched.shown(in: DeliveryRecords(history: [dictated], draft: nil))?.offersCopy == true,
                  "relaunch shows it on the shelf with Copy again")
        relaunched.restore(decoded.undelivered, loadedDraftRevision: 1, in: DeliveryRecords(history: [], draft: (text: "Draft words.", revision: 1)))
        try check(relaunched.entry == nil, "relaunch drops it if its transcript is gone")
        let savedDraft = try JSONDecoder().decode(SavedState.self, from: draftData).undelivered
        relaunched.restore(savedDraft, loadedDraftRevision: 1, in: DeliveryRecords(history: [], draft: (text: "Draft words.", revision: 1)))
        try check(relaunched.entry?.reference == .draft(revision: 1) && relaunched.wordsToCopy(in: DeliveryRecords(history: [], draft: (text: "Draft words.", revision: 1))) == "Draft words.",
                  "a draft entry comes back on the draft launch loaded, with that draft's revision")
        relaunched.restore(savedDraft, loadedDraftRevision: 1, in: DeliveryRecords(history: [], draft: (text: "A recovered capture.", revision: 2)))
        try check(relaunched.entry == nil, "relaunch drops a draft entry if launch replaced the draft")
        relaunched.restore(nil, loadedDraftRevision: 1, in: live)
        try check(relaunched.entry == nil, "nothing saved, nothing shown")
    }

    // MARK: Saved and Practice complete

    /// Every check that says a ✓ is absent starts from one that is showing,
    /// so the absence means something (#134 T5 review).
    private static func checkShortcutConfirmation(_ check: Check) throws {
        var clock: TimeInterval = 2_000
        let start = VoiceShortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey))
        var updates = 0, refuse = false
        var heard: [String] = []
        let keyboard = KeyboardCoachModel(entries: [ShortcutEntry(id: "voice.8", title: "Snap", shortcut: start)],
                                          update: { _, _ in updates += 1; return refuse ? "Registration changed during the save." : nil },
                                          suspend: { _ in }, probe: { _ in nil }, notifications: NotificationCenter(), clock: { clock })
        keyboard.announce = { heard.append($0) }
        let editor = PanelShortcutEditor(keyboard: keyboard)
        func key(_ type: NSEvent.EventType, _ code: Int, option: Bool = true) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: option ? [.option] : [], timestamp: 0, windowNumber: 0,
                             context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code))!
        }
        func press(_ code: Int) { _ = keyboard.handle(key(.keyDown, code)); _ = keyboard.handle(key(.keyUp, code, option: false)) }
        func record(_ code: Int) { keyboard.beginRecording(); _ = keyboard.handle(key(.keyDown, code)) }

        editor.change("voice.8")
        _ = keyboard.handle(key(.keyDown, kVK_ANSI_2))
        let saved = VoiceShortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(optionKey))
        try check(updates == 1 && keyboard.selected?.shortcut == saved && keyboard.confirmation?.kind == .saved,
                  "✓ Saved appears only after the owner kept the new shortcut")
        try check(heard == ["Saved"], "VoiceOver hears Saved once, as the label says it")
        let event = keyboard.confirmation!.lifetime.event
        clock += 3.9; keyboard.expireConfirmation(event)
        try check(keyboard.confirmation?.kind == .saved, "it lasts four seconds")
        clock += 0.1; keyboard.expireConfirmation(event)
        try check(keyboard.confirmation == nil && keyboard.selected?.shortcut == saved && editor.shortcutID == "voice.8"
                  && keyboard.message == "Try it here to build the habit.", "expiry clears only the check: the shortcut, the editor and its words stay")

        record(kVK_ANSI_3)
        try check(keyboard.confirmation?.kind == .saved && updates == 2 && heard.count == 2, "a second save shows, and says, its own check")
        keyboard.beginRecording()
        try check(keyboard.confirmation == nil, "recording another combination starts without the last check")
        _ = keyboard.handle(key(.keyDown, kVK_ANSI_V, option: false))
        try check(keyboard.confirmation == nil && keyboard.hasError && updates == 2 && heard.count == 2,
                  "a refused combination shows its reason; no check is shown or heard")
        keyboard.stopInteraction()

        record(kVK_ANSI_4)
        try check(keyboard.confirmation?.kind == .saved, "a check is showing before the owner refuses a change")
        refuse = true
        keyboard.disableSelected()
        try check(keyboard.confirmation == nil && keyboard.hasError && keyboard.selected?.shortcut.enabled == true && heard.count == 3,
                  "when the owner refuses a change, the showing check goes and the reason stays")
        refuse = false
        keyboard.disableSelected()
        try check(keyboard.selected?.shortcut.enabled == false && keyboard.confirmation?.kind == .saved && heard.count == 4,
                  "turning a shortcut off is a change the owner kept: ✓ Saved")
        let offUpdates = updates, offCheck = keyboard.confirmation?.lifetime.event
        keyboard.disableSelected()
        try check(updates == offUpdates && keyboard.confirmation?.lifetime.event == offCheck && offCheck != nil && heard.count == 4,
                  "Turn off on a shortcut already off saves, confirms and says nothing")

        record(kVK_ANSI_2)
        try check(keyboard.confirmation?.kind == .saved && keyboard.selected?.shortcut.enabled == true, "a check is showing before practice")
        keyboard.beginPractice()
        try check(keyboard.confirmation == nil && keyboard.isInteracting, "practice starts without the last check")
        press(kVK_ANSI_2); press(kVK_ANSI_2)
        try check(keyboard.practice?.completed == 2 && keyboard.confirmation == nil && keyboard.isInteracting && heard.last == "Saved",
                  "no check, and nothing heard, after two of three presses")
        press(kVK_ANSI_2)
        try check(keyboard.practice?.isComplete == true && keyboard.confirmation?.kind == .practiceComplete && heard.last == "Practice complete",
                  "✓ Practice complete appears, and is heard, only after the third complete press")
        let practiced = keyboard.confirmation!.lifetime.event
        let words = keyboard.message
        clock += 4; keyboard.expireConfirmation(practiced)
        try check(keyboard.confirmation == nil && keyboard.practice?.isComplete == true && keyboard.message == words && words != nil
                  && editor.shortcutID == "voice.8", "its expiry clears only the check: the practice result, its words and the editor stay")

        keyboard.beginPractice(); for _ in 0..<3 { press(kVK_ANSI_2) }
        let older = keyboard.confirmation!.lifetime.event
        clock += 3
        keyboard.beginPractice(); for _ in 0..<3 { press(kVK_ANSI_2) }
        let newer = keyboard.confirmation!.lifetime.event
        clock += 1.5; keyboard.expireConfirmation(older)
        try check(keyboard.confirmation?.lifetime.event == newer && newer != older, "an older check's expiry cannot end a newer one")
        editor.end()
        try check(keyboard.confirmation == nil, "closing the editor ends the check it was showing")
        try check(ShortcutConfirmation.texts == ["Saved", "Practice complete"], "the two confirmations, and the space kept for them")

        let refusing = KeyboardCoachModel(entries: [ShortcutEntry(id: "voice.8", title: "Snap", shortcut: start)],
                                          update: { _, _ in "Registration changed during the save." }, suspend: { _ in }, probe: { _ in nil },
                                          notifications: NotificationCenter(), clock: { clock })
        var refusedHeard: [String] = []
        refusing.announce = { refusedHeard.append($0) }
        refusing.beginRecording()
        _ = refusing.handle(key(.keyDown, kVK_ANSI_3))
        try check(refusing.confirmation == nil && refusing.hasError && refusing.selected?.shortcut == start && refusedHeard.isEmpty,
                  "✓ Saved never shows, or is heard, when the owner could not keep the change")
    }
}
