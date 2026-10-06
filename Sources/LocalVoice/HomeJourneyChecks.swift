import Foundation
import Carbon

/// Home's first-dictation gate, its way back, its section order, its permission rows and its
/// last meeting, without rendering SwiftUI. The guide is gated on dictation, not on any saved
/// work (#15).
enum HomeJourneyChecks {
    static func run() throws {
        var passed = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("HOME_JOURNEY_CHECK_FAILED: \(name)") }
            passed += 1
        }
        // Every Home shows your meetings and decks, this Mac's permissions and your keys; the
        // guide and current work come first only while they apply (docs/desktop.md § Home).
        let results: [HomeJourney.Section] = [.permissions, .meetings, .decks, .keys]
        // Nothing yet: the guide, with Skip for now, above the results.
        let fresh = HomeJourney()
        try check(fresh.showsGuide && fresh.offersSkip && !fresh.offersGuide, "nothing saved shows the guide and offers Skip for now")
        try check(fresh.sections == [.guide] + results, "nothing saved shows the guide, then meetings, decks, permissions and keys")
        try check(!fresh.sections.contains(.currentWork), "nothing running shows no current work")

        // A dictation ends first use, including one saved before this state existed.
        let dictated = HomeJourney(transcripts: 1)
        try check(!dictated.showsGuide && !dictated.offersSkip && !dictated.offersGuide, "after a dictation Home offers neither the guide nor the way back")
        try check(dictated.sections == results, "after a dictation Home shows meetings, decks, permissions and keys")
        try check(dictated.guideToSave == .completed && HomeJourney(transcripts: 1, guide: .skipped).guideToSave == .completed,
                  "a dictation in History is recorded as completed, even after Skip for now")
        try check(HomeJourney(transcripts: 1, guide: .completed).guideToSave == nil && HomeJourney(hasCurrentWork: true).guideToSave == nil,
                  "completion is recorded once, and never from other work")
        let removed = HomeJourney(guide: .completed)
        try check(!removed.showsGuide && !removed.offersGuide && removed.sections == results,
                  "removing every transcript later does not bring the guide back")

        // Skip for now: no tour, and one small way back while nothing is dictated.
        let skipped = HomeJourney(guide: .skipped)
        try check(!skipped.showsGuide && skipped.offersGuide && !skipped.offersSkip, "Skip for now hides the guide and keeps Show me a first dictation")
        try check(skipped.sections == results, "a skipped guide leaves the ordinary Home")
        // Leaving Home, a cancelled permission request and relaunch keep the saved choice:
        // a new Home (stayInGuide false), a request in flight (current work) and after it.
        for (name, journey) in [("leaving and returning to Home", HomeJourney(guide: .skipped, stayInGuide: false)),
                                ("a microphone request in flight", HomeJourney(guide: .skipped, hasCurrentWork: true))] {
            try check(!journey.showsGuide && journey.offersGuide, "\(name) never forces the guide back or loses the way back")
        }
        try check(HomeJourney(hasCurrentWork: true).sections == [.currentWork, .guide] + results,
                  "a cancelled microphone request leaves the guide as it was, below current work")

        // Show me a first dictation offers the guide again, with its own Skip.
        let resumed = HomeJourney(guide: .offered, stayInGuide: true)
        try check(resumed.showsGuide && resumed.offersSkip && resumed.sections.first == .guide, "the way back shows the guide again")

        // Dictating from the guide: it stays to show where the words went, then Done or leaving Home ends it.
        let landed = HomeJourney(transcripts: 1, guide: .completed, stayInGuide: true)
        try check(landed.sections == [.guide, .firstResult] + results, "the first result shows where the words went, above the results")
        try check(!landed.offersSkip && !landed.offersGuide, "after the first result neither Skip nor the way back remains")
        try check(HomeJourney(transcripts: 1, guide: .completed).sections == results, "Done returns to the ordinary Home")

        // Current work comes first in every state; the columns hold every result section once.
        try check(HomeJourney(transcripts: 1, hasCurrentWork: true).sections == [.currentWork] + results,
                  "current work renders above the results")
        for folded in [false, true] {
            let journey = HomeJourney(transcripts: 1, permissionsFolded: folded)
            let laidOut = journey.above + journey.leading + journey.trailing + journey.below
            try check(laidOut.count == Set(laidOut).count && Set(laidOut) == Set(journey.sections),
                      "the two-column layout shows each section exactly once (permissions folded: \(folded))")
        }
        try check(HomeJourney(transcripts: 1).trailing == [.permissions] && HomeJourney(transcripts: 1).below == [.keys],
                  "while Permissions is open it has the right half and your keys run the full width below")
        try check(HomeJourney(transcripts: 1, permissionsFolded: true).trailing == [.keys, .permissions]
                  && HomeJourney(transcripts: 1, permissionsFolded: true).below.isEmpty,
                  "once Permissions is one line, your keys and the folded panel share the right half")
        try check(!HomeJourney().sections.contains(where: { "\($0)".lowercased().contains("recent") }),
                  "Home holds no copy of History's recent list")
        let order: [HomeJourney.Section] = [.currentWork, .guide, .firstResult, .permissions, .meetings, .decks, .keys]
        try check(HomeJourney(permissionsFolded: true).sections == [.guide, .meetings, .decks, .keys, .permissions],
                  "a folded Permissions panel follows the results in one column")
        for journey in [HomeJourney(transcripts: 1, hasCurrentWork: true), HomeJourney(hasCurrentWork: true), landed, fresh] {
            let positions = journey.sections.map { order.firstIndex(of: $0)! }
            try check(positions == positions.sorted(), "Home keeps its fixed order: \(journey.sections)")
        }

        // Permissions: each row says only what macOS reports, asks only from its own Set up…,
        // is orange only when something a tool needs is off, and never claims All allowed falsely.
        func row(_ permission: MacPermission, _ state: MacPermissionState) -> MacPermissionRow { .init(permission: permission, state: state) }
        try check(row(.microphone, .notAsked).action == .request && row(.microphone, .notAsked).action?.title == "Set up…",
                  "an approval macOS has not asked about offers Set up…, never a custom Allow, and macOS asks")
        try check(row(.microphone, .notAsked).tone == .neutral && row(.camera, .notAllowed).tone == .attention,
                  "not asked yet is information; only an approval that is off asks for attention")
        try check(row(.camera, .notAllowed).action == .openSettings && row(.camera, .managed).action == .openSettings,
                  "an approval that is off or managed opens Settings rather than promising a grant")
        try check(row(.microphone, .allowed).action == nil && row(.microphone, .allowed).detail == nil,
                  "an allowed approval has nothing to press and nothing to explain")
        try check(row(.callAudio, .checkedOnUse).action == nil && row(.callAudio, .checkedOnUse).detail?.contains("first time") == true,
                  "call audio, which macOS lists only after Meetings asks, offers no empty Settings list")
        try check(row(.accessibility, .notAllowed).detail?.contains("⌘V") == true,
                  "automatic paste that is off says the words are still copied for ⌘V")
        try check(row(.screenRecording, .notAllowed).afterAllowing == MacPermissionRow.reopenAfterAllowing && row(.camera, .notAllowed).afterAllowing == nil,
                  "Screen Recording that is off says to reopen Workbench once allowed")
        try check(row(.camera, .managed).status == "Managed" && row(.camera, .managed).tone == .neutral,
                  "a restricted approval is managed, never called a refusal")
        for permission in MacPermission.allCases {
            try check(permission.withoutIt.hasPrefix("Without it:"), "\(permission.name) says what still works without it")
            try check(permission.settingsURL.absoluteString.hasPrefix("x-apple.systempreferences:"), "\(permission.name) opens its own Settings list")
        }
        let newMac = MacPermissionSnapshot([.microphone: .allowed, .accessibility: .notAsked, .screenRecording: .notAsked,
                                           .camera: .notAsked, .callAudio: .checkedOnUse])
        try check(newMac.summary == "3 not asked yet" && newMac.tone == .neutral && !newMac.needsAttention,
                  "a new Mac reads as not asked yet, never as a row of warnings")
        try check(newMac.expanded(dismissed: false) && !newMac.expanded(dismissed: true),
                  "the panel opens to encourage setup and folds for good with Done for now")
        let off = MacPermissionSnapshot([.microphone: .allowed, .accessibility: .notAsked, .screenRecording: .notAllowed,
                                         .camera: .notAsked, .callAudio: .checkedOnUse])
        try check(off.summary == "1 off" && off.tone == .attention && off.expanded(dismissed: true),
                  "an approval that is off opens the panel, even after Done for now")
        let twoOff = MacPermissionSnapshot([.microphone: .notAllowed, .accessibility: .allowed, .screenRecording: .notAllowed,
                                            .camera: .allowed, .callAudio: .checkedOnUse])
        try check(twoOff.summary == "2 off", "two approvals off read as 2 off")
        let allowed = MacPermissionSnapshot([.microphone: .allowed, .accessibility: .allowed, .screenRecording: .allowed,
                                             .camera: .allowed, .callAudio: .checkedOnUse])
        try check(allowed.summary == "All allowed" && allowed.isComplete && allowed.tone == .done && !allowed.expanded(dismissed: false),
                  "every checkable approval allowed reads All allowed and folds")
        let managed = MacPermissionSnapshot([.microphone: .allowed, .accessibility: .allowed, .screenRecording: .allowed,
                                             .camera: .managed, .callAudio: .checkedOnUse])
        try check(!managed.isComplete && !managed.needsAttention && managed.summary == "1 managed" && managed.tone == .neutral,
                  "a managed camera keeps the panel from claiming All allowed without asking for attention")
        try check(MacPermissionReader.state(.notDetermined) == .notAsked && MacPermissionReader.state(.restricted) == .managed
                  && MacPermissionReader.state(.denied) == .notAllowed && MacPermissionReader.state(.authorized) == .allowed,
                  "the camera and microphone keep the four answers macOS gives")

        // Your meetings: meetings and calls only, newest first, named by their saved details.
        let earlierCall = Transcript(date: Date(timeIntervalSince1970: 100), text: "Older call words here", seconds: 30)
        let latestMeeting = Transcript(date: Date(timeIntervalSince1970: 200), text: "Newest meeting words", seconds: 3_900)
        let dictation = Transcript(date: Date(timeIntervalSince1970: 300), text: "A later dictation", seconds: 5)
        let details: [UUID: TranscriptMetadata] = [earlierCall.id: .init(purpose: .call), latestMeeting.id: .init(purpose: .meeting, person: "Sam", company: " ")]
        let meetings = HomeMeetings.newest([earlierCall, latestMeeting, dictation]) { details[$0] ?? TranscriptMetadata() }
        try check(meetings.map(\.id) == [latestMeeting.id, earlierCall.id] && meetings.first?.heading == "Meeting · Sam" && meetings.first?.excerpt == "Newest meeting words",
                  "meetings and calls, newest first, named by their saved details, never a dictation")
        try check(meetings.last?.heading == "Call", "a call with no details reads as Call")
        try check(HomeMeetings.newest([dictation]) { _ in TranscriptMetadata() }.isEmpty, "no meeting shows the empty tile")
        let noted = HomeMeetings.newest([latestMeeting]) { _ in .init(purpose: .meeting, captureNotes: ["No audio was received from Zoom."]) }
        try check(noted.first?.note == "No audio was received from Zoom.", "a recording's first note, such as missing audio, travels with the meeting")
        try check(HomeMeetings.recap("# Follow-up for Sam\n\n- Maya sends the agenda.\n**Decision:** launch Friday.") == "Follow-up for Sam · Maya sends the agenda. · Decision: launch Friday.",
                  "a follow-up's opening lines read as plain sentences")
        let many = (0..<6).map { Transcript(date: Date(timeIntervalSince1970: Double($0)), text: "m", seconds: 60) }
        try check(HomeMeetings.newest(many) { _ in .init(purpose: .meeting) }.count == 3, "the tile shows at most three meetings")
        try check(HomeMeetings.duration(20) == "Under a minute" && HomeMeetings.duration(2_520) == "42 min"
                  && HomeMeetings.duration(3_900) == "1 h 5 min" && HomeMeetings.duration(7_200) == "2 h",
                  "a meeting's length reads in minutes and hours")
        try check(HomeMeetings.review(latestMeeting.id).transcript == latestMeeting.id, "Review opens that exact transcript in History")
        func job(_ seconds: Double) -> HandoffJob {
            HandoffJob(id: UUID(), createdAt: Date(timeIntervalSince1970: seconds), updatedAt: Date(timeIntervalSince1970: seconds), title: "Follow-up",
                       fingerprint: "", status: .completed, detail: "", attempts: 1, itemCount: 1, inputFiles: [], inputDigest: "", supportsConnectedText: true)
        }
        let unrelated = job(400), olderFollowUp = job(500), newerFollowUp = job(600)
        let inputs: [UUID: [WorkbenchItemReference]] = [unrelated.id: [.init(kind: .transcript, id: dictation.id)],
            olderFollowUp.id: [.init(kind: .transcript, id: latestMeeting.id)], newerFollowUp.id: [.init(kind: .transcript, id: latestMeeting.id), .init(kind: .snap, id: UUID())]]
        try check(HomeMeetings.followUp(for: latestMeeting.id, in: [unrelated, olderFollowUp, newerFollowUp]) { inputs[$0.id] ?? [] }?.id == newerFollowUp.id,
                  "the follow-up shown is the newest task made from that meeting")
        try check(HomeMeetings.followUp(for: earlierCall.id, in: [unrelated, olderFollowUp, newerFollowUp]) { inputs[$0.id] ?? [] } == nil,
                  "a meeting nothing was made from offers Prepare follow-up…")

        // Your decks: the newest presentable file in outputs/, never a note or an image.
        let now = Date(timeIntervalSince1970: 1_000)
        let deck = HomeDeck.newestDeck([(URL(fileURLWithPath: "/s/outputs/notes.md"), now.addingTimeInterval(60)),
                                        (URL(fileURLWithPath: "/s/outputs/Launch-1.pptx"), now),
                                        (URL(fileURLWithPath: "/s/outputs/Launch-2.PPTX"), now.addingTimeInterval(30)),
                                        (URL(fileURLWithPath: "/s/outputs/screen.png"), now.addingTimeInterval(90))])
        try check(deck?.lastPathComponent == "Launch-2.PPTX", "the newest deck file wins, whatever the case of its extension")
        try check(HomeDeck.newestDeck([(URL(fileURLWithPath: "/s/outputs/follow-up.md"), now)]) == nil, "outputs without a deck read as No deck yet")

        // Your keys: the next three working shortcuts not yet learned, killer features first,
        // learned for the keys they were learned on, and only Option keys on the left-hand map.
        func entry(_ id: String, _ key: UInt32, modifiers: UInt32 = UInt32(optionKey), enabled: Bool = true, error: String? = nil) -> ShortcutEntry {
            ShortcutEntry(id: id, title: id, shortcut: VoiceShortcut(keyCode: key, modifiers: modifiers, enabled: enabled), error: error)
        }
        func learned(_ ids: [String], in entries: [ShortcutEntry]) -> Set<String> {
            Set(ids.compactMap { id in entries.first { $0.id == id }.map { KeyboardCoachModel.practiceRecord($0.id, $0.shortcut) } })
        }
        let keys = [entry("voice.1", 9), entry("stage.pen", 2), entry("voice.5", 8), entry("stage.clear", 7), entry("stage.arrow", 0),
                    entry("voice.7", 12, error: "Also assigned to Something. Both shortcuts are paused."), entry("stage.undo", 6, enabled: false),
                    entry("voice.8", 1, modifiers: UInt32(optionKey | shiftKey))]
        try check(HomeKeys.next(keys, learned: []).map(\.id) == ["voice.1", "stage.pen", "voice.5"], "first come Dictate, Draw and Snap & Talk")
        let firstThree = learned(["voice.1", "stage.pen", "voice.5"], in: keys)
        try check(HomeKeys.next(keys, learned: firstThree).map(\.id) == ["stage.clear", "stage.arrow", "voice.8"],
                  "learned keys make way for the next, skipping one in conflict and one turned off")
        try check(HomeKeys.progress(keys, learned: learned(["voice.1", "stage.clear"], in: keys)) == (2, 6), "progress counts only shortcuts that work")
        var rebound = keys; rebound[0] = entry("voice.1", 12)
        try check(!HomeKeys.isLearned(rebound[0], in: firstThree) && HomeKeys.next(rebound, learned: firstThree).first?.id == "voice.1",
                  "a shortcut moved to new keys is a new habit to learn")
        try check(HomeKeys.entry(on: 9, in: keys)?.id == "voice.1" && HomeKeys.entry(on: 12, in: keys) == nil && HomeKeys.entry(on: 1, in: keys) == nil,
                  "the map shows working Option shortcuts only, never a conflict or a Shift combination")
        let snapOff = [entry("voice.1", 9), entry("voice.8", 5, enabled: false)]
        try check(HomeKeys.suggestion(snapOff)?.entry.id == "voice.8" && HomeKeys.suggestion(snapOff)?.key == 5, "Snap without a key is offered ⌥G")
        try check(HomeKeys.suggestion(snapOff + [entry("stage.foo", 5)])?.key == 17, "a taken G moves the offer to the next free key, never E")
        try check(HomeKeys.suggestion([entry("voice.8", 1)]) == nil, "a Snap that has a key needs no offer")
        try check(!HomeKeys.suggestions.contains { $0.keys.contains(14) }, "Option-E, an accent key, is never offered")
        try check(Set(HomeKeys.rows.joined()).count == 15 && HomeKeys.priority.allSatisfy { HomeKeys.shortNames[$0] != nil },
                  "the map has fifteen left-hand keys and every priority shortcut has a keycap name")

        let frames = HomeGreetingSequence.frames
        try check(frames.contains { $0.text == HomeGreetingSequence.welcome && $0.milliseconds >= 600 },
                  "the greeting types Welcome back and holds it briefly")
        try check(HomeGreetingSequence.frames(returning: false).contains { $0.text == HomeGreetingSequence.firstWelcome && $0.milliseconds >= 600 }
                  && !HomeGreetingSequence.frames(returning: false).contains { $0.text == HomeGreetingSequence.welcome },
                  "someone who has never dictated is welcomed, not welcomed back")
        try check(frames.contains { $0.text.isEmpty } && frames.last?.text == HomeGreetingSequence.settled,
                  "the greeting erases before settling on one action-oriented line")
        try check(frames.reduce(0) { $0 + $1.milliseconds } < 3_000, "the one-time greeting finishes within three seconds")

        // Persisted with the Dictate preferences: survives relaunch, keeps older files and reads a newer value safely.
        var preferences = VoicePreferences()
        preferences.firstDictationGuide = .skipped; preferences.cleanup = .natural
        let saved = try JSONEncoder().encode(preferences)
        try check(try JSONDecoder().decode(VoicePreferences.self, from: saved).firstDictationGuide == .skipped, "Skip for now survives relaunch")
        var older = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        older.removeValue(forKey: "firstDictationGuide")
        let olderPreferences = try JSONDecoder().decode(VoicePreferences.self, from: JSONSerialization.data(withJSONObject: older))
        try check(olderPreferences.firstDictationGuide == nil && olderPreferences.cleanup == .natural, "preferences saved before the guide keep every other choice")
        older["firstDictationGuide"] = "later"
        let newer = try JSONDecoder().decode(VoicePreferences.self, from: JSONSerialization.data(withJSONObject: older))
        try check(newer.firstDictationGuide == .offered && newer.cleanup == .natural, "an unknown guide value reads as offered without resetting other choices")
        print("HOME_JOURNEY_CHECKS_OK: \(passed) checks")
    }
}
