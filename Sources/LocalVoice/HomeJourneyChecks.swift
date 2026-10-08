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
        // is orange only when something the person can turn on is off, and never claims All allowed falsely.
        func row(_ permission: MacPermission, _ state: MacPermissionState, administrator: Bool? = true) -> MacPermissionRow {
            .init(permission: permission, state: state, administrator: administrator)
        }
        func rowIn(_ snapshot: MacPermissionSnapshot, _ permission: MacPermission) -> MacPermissionRow? { snapshot.rows.first { $0.permission == permission } }
        try check(row(.microphone, .notAsked).action == .request && row(.microphone, .notAsked).action?.title == "Set up…",
                  "an approval macOS has not asked about offers Set up…, never a custom Allow, and macOS asks")
        try check(row(.microphone, .notAsked).tone == .neutral && row(.camera, .notAllowed).tone == .attention,
                  "not asked yet is information; only an approval that is off asks for attention")
        try check(row(.camera, .notAllowed).action == .openSettings && row(.camera, .managed).action == .openSettings,
                  "an approval that is off or managed opens Settings rather than promising a grant")
        try check(row(.microphone, .allowed).action == .change && row(.microphone, .allowed).action?.title == "Change…"
                  && row(.microphone, .allowed).details.isEmpty && row(.microphone, .allowed).tone == .done && row(.microphone, .allowed).actionIsQuiet,
                  "an allowed approval has nothing to explain, and a quiet Change… opens its switch")
        try check(MacPermissionStep.of(.change, for: .accessibility) == .openSettings(MacPermission.accessibility.settingsURL)
                  && MacPermissionStep.of(.change, for: .screenRecording) == .openSettings(MacPermission.screenRecording.settingsURL),
                  "Change… only opens the list: nothing is asked of macOS when someone wants to turn something off")
        try check(row(.microphone, .allowed).actionHelp?.contains("until it quits") == true
                  && row(.screenRecording, .allowed).actionHelp?.contains("reopens") == true
                  && row(.accessibility, .allowed).actionHelp?.contains("organisation") == true
                  && row(.microphone, .allowed).actionHelp?.contains("organisation") == false
                  && row(.accessibility, .allowed, administrator: false).actionHelp?.contains("also needs an administrator") == true,
                  "Change… says when macOS applies a change, that an organisation's approval may not be listed, and who can switch it off")
        try check(row(.accessibility, .notAllowed).details.contains { $0.contains("⌘V") },
                  "automatic paste that is off says the words are still copied for ⌘V")
        try check(MacPermission.accessibility.purpose.hasPrefix("Automatic paste"),
                  "the Accessibility row names automatic paste, so someone looking for it finds the permission")
        try check(row(.accessibility, .notAllowed).details.contains { $0.contains("click +") }
                  && row(.accessibility, .notAllowed).details.contains { $0.contains("already on there") }
                  && !row(.camera, .notAllowed).details.contains { $0.contains("click +") || $0.contains("administrator") },
                  "an Off Accessibility says how to bring back a removed entry or reopen after switching it on; Camera's list has no +")
        try check(row(.screenRecording, .notAllowed).afterAllowing == MacPermissionRow.reopenAfterAllowing && row(.camera, .notAllowed).afterAllowing == nil
                  && row(.screenRecording, .allowed).afterAllowing == nil,
                  "Screen Recording that is off says to reopen Workbench once allowed")
        try check(row(.camera, .managed).status == "Managed" && row(.camera, .managed).tone == .neutral,
                  "a restricted approval is managed, never called a refusal")

        // Call audio: unknown until Meetings records a call; then what that call showed.
        let unknownCall = row(.callAudio, .checkedOnUse)
        try check(unknownCall.status == "Checked on your next call" && unknownCall.tone == .neutral && unknownCall.action == .openSettings
                  && unknownCall.actionIsQuiet && unknownCall.details.first?.contains("Meetings learns") == true,
                  "unknown call audio promises no prompt, and keeps its switch one quiet click away for someone already asked")
        try check(row(.callAudio, .lastCall(allowed: true)).status == "Allowed on your last call" && row(.callAudio, .lastCall(allowed: true)).tone == .neutral
                  && row(.callAudio, .lastCall(allowed: true)).action == .change
                  && row(.callAudio, .lastCall(allowed: false)).status == "Off on your last call" && row(.callAudio, .lastCall(allowed: false)).tone == .attention
                  && row(.callAudio, .lastCall(allowed: false)).action == .openSettings
                  && row(.callAudio, .lastCall(allowed: false)).details.contains { $0.contains("Meetings checks again") },
                  "a call's answer reads as evidence from that call, never green as if read now")
        try check(unknownCall.actionHelp?.contains("Privacy & Security") == true && !(unknownCall.actionHelp?.contains("› Call audio") ?? true),
                  "call audio's help names where macOS keeps it, never a list called Call audio")

        // A yes/no approval reads from Workbench's own record of asking, and from whether this
        // account can switch on an approval macOS keeps for the whole Mac.
        try check(MacPermissionReader.state(granted: false, asked: false, administrator: true) == .notSetUp
                  && row(.screenRecording, .notSetUp).status == "Not set up" && row(.screenRecording, .notSetUp).action == .request,
                  "with no record of asking, a yes/no approval reads Not set up, never Not asked yet, and Set up… still leads somewhere")
        try check(MacPermissionReader.state(granted: false, asked: true, administrator: true) == .notAllowed
                  && MacPermissionReader.state(granted: true, asked: false, administrator: false) == .allowed
                  && MacPermissionReader.state(granted: false, asked: false, administrator: nil) == .notSetUp,
                  "an approval asked for and not on is Off; one that is on is Allowed whoever the account is")
        try check(MacPermissionReader.state(granted: false, asked: true, administrator: false) == .needsAdministrator(listed: true)
                  && MacPermissionReader.state(granted: false, asked: false, administrator: false) == .needsAdministrator(listed: false),
                  "on a standard account, a Mac-wide approval that isn't on needs an administrator")
        let needsAdmin = row(.accessibility, .needsAdministrator(listed: true), administrator: false)
        try check(needsAdmin.status == "Needs an administrator" && needsAdmin.tone == .neutral && needsAdmin.action == .openSettings
                  && needsAdmin.details.first?.contains("administrator’s name and password") == true
                  && needsAdmin.details.first?.contains("Copy permission details") == true
                  && needsAdmin.details.contains { $0.contains("already on there") }
                  && !row(.accessibility, .needsAdministrator(listed: false), administrator: false).details.contains { $0.contains("already on there") },
                  "Accessibility on a standard account says an administrator must switch it on and how to ask IT, without orange")
        try check(row(.screenRecording, .needsAdministrator(listed: false), administrator: false).status == "May need an administrator"
                  && row(.screenRecording, .needsAdministrator(listed: false), administrator: false).action == .request
                  && row(.screenRecording, .needsAdministrator(listed: false), administrator: false).details.first?.contains("may need") == true,
                  "Screen Recording hedges, because IT can let standard users switch it on, and a first press asks macOS so the list shows Workbench")
        try check(MacPermissionStep.of(.request, for: .microphone) == .requestMicrophone && MacPermissionStep.of(.request, for: .camera) == .requestCamera
                  && MacPermissionStep.of(.request, for: .accessibility) == .setUpAccessibility && MacPermissionStep.of(.openSettings, for: .accessibility) == .setUpAccessibility
                  && MacPermissionStep.of(.request, for: .screenRecording) == .setUpScreenRecording && MacPermissionStep.of(.openSettings, for: .screenRecording) == .setUpScreenRecording
                  && MacPermissionStep.of(.openSettings, for: .camera) == .openSettings(MacPermission.camera.settingsURL)
                  && MacPermissionStep.of(.openSettings, for: .callAudio) == .openSettings(MacPermission.callAudio.settingsURL),
                  "each button reaches the owner its tool uses, and Off for Accessibility or Screen Recording asks again so a cleared list shows Workbench")

        // Automatic paste that fails while Accessibility is allowed.
        let pasteFails = MacPermissionSnapshot([.microphone: .allowed, .accessibility: .allowed, .screenRecording: .allowed, .camera: .allowed,
                                                .callAudio: .checkedOnUse], pasteProblem: "Your last dictation into Chrome was copied, not pasted.",
                                               pasteNote: "Last paste only copied")
        try check(rowIn(pasteFails, .accessibility)?.details == ["Your last dictation into Chrome was copied, not pasted."]
                  && rowIn(pasteFails, .accessibility)?.status == "Allowed" && rowIn(pasteFails, .accessibility)?.tone == .done,
                  "Accessibility can be allowed while automatic paste still fails; the row keeps its check and says why")
        try check(pasteFails.summary == "Last paste only copied" && pasteFails.tone == .neutral && pasteFails.foldedLine.contains("Last paste only copied")
                  && !pasteFails.expanded(dismissed: false) == pasteFails.isComplete,
                  "a paste problem shows on the summary and the folded line, so a folded panel never says all is well")
        try check(rowIn(MacPermissionSnapshot([.accessibility: .notAllowed], pasteProblem: "x"), .accessibility)?.pasteProblem == nil
                  && MacPermissionSnapshot([.accessibility: .notAllowed], pasteProblem: "x").pasteNote == nil,
                  "a paste problem shows only while Accessibility reads Allowed")
        let untrusted = TextDelivery.Outcome(message: TextDelivery.copiedMessage, clipboardChangeCount: 1, wasPasted: false,
                                             destinationName: "Notes", failure: .accessibilityUnavailable)
        try check(AutomaticPasteProblem.approvalReason(for: untrusted, alreadyExplained: false)?.contains("needs Accessibility") == true
                  && AutomaticPasteProblem.approvalReason(for: untrusted, alreadyExplained: true) == nil
                  && AutomaticPasteProblem(untrusted, layout: "us", pasteKey: 9) == nil,
                  "a result only copied for want of Accessibility says why once per run, then never again, and is not a paste problem")
        var unreadable = untrusted; unreadable.failure = .fieldUnreadable; unreadable.destinationName = "Finder"
        var unconfirmed = unreadable; unconfirmed.failure = .pasteUnconfirmed; unconfirmed.destinationName = "Chrome"
        var noKey = unreadable; noKey.failure = .pasteUnavailable
        var changed = untrusted; changed.failure = .focusChanged
        var pasted = untrusted; pasted.failure = nil; pasted.wasPasted = true
        unreadable.unusableFocus = true
        let noField = AutomaticPasteProblem(unreadable, layout: "us", pasteKey: 9)
        try check(noField?.line.contains("couldn’t find a text field") == true && noField?.line.contains("Finder") == true
                  && noField?.line.contains("web app") == false && noField?.summary.hasPrefix("copied, no text field found, in Finder") == true,
                  "an unreadable field says no text field was found there, without blaming a kind of app")
        try check(AutomaticPasteProblem(unconfirmed, layout: "us", pasteKey: 9)?.line.contains("couldn’t see it arrive") == true
                  && AutomaticPasteProblem(unconfirmed, layout: "us", pasteKey: 9)?.line.contains("Post Event") == false
                  && AutomaticPasteProblem(unconfirmed, layout: "us", pasteKey: 9)?.note == "Last paste unconfirmed",
                  "an unconfirmed paste says only what Workbench saw, never a cause it can't prove")
        try check(AutomaticPasteProblem(noKey, layout: "com.apple.keylayout.Turkmen", pasteKey: nil)?.line.contains(AutomaticPasteProblem.noPasteKey) == true
                  && AutomaticPasteProblem(noKey, layout: "us", pasteKey: 9)?.line.contains("⌘V key") == false,
                  "a layout with no ⌘V key is named as the reason, not macOS")
        try check(AutomaticPasteProblem(changed) == nil && AutomaticPasteProblem(pasted) == nil
                  && AutomaticPasteProblem.approvalReason(for: unreadable, alreadyExplained: false) == nil,
                  "only failures outside the person's control count against automatic paste")

        for permission in MacPermission.allCases {
            try check(permission.withoutIt.hasPrefix("Without it:"), "\(permission.name) says what still works without it")
            try check(permission.settingsURL.absoluteString.hasPrefix("x-apple.systempreferences:"), "\(permission.name) opens its own Settings list")
        }

        // The summary and folding.
        let newMac = MacPermissionSnapshot([.microphone: .allowed, .accessibility: .notSetUp, .screenRecording: .notSetUp,
                                           .camera: .notAsked, .callAudio: .checkedOnUse])
        try check(newMac.summary == "3 to set up" && newMac.tone == .neutral && !newMac.needsAttention,
                  "a new Mac reads as things to set up, never as a row of warnings")
        try check(newMac.expanded(dismissed: false) && !newMac.expanded(dismissed: true),
                  "the panel opens to encourage setup and folds for good with Done for now")
        try check(newMac.foldedLine.hasPrefix("Allowed: Microphone.") && newMac.foldedLine.contains("Not set up: Accessibility and")
                  && newMac.foldedLine.contains("Not asked yet: Camera.") && !newMac.foldedLine.contains("Each tool asks"),
                  "folded, the line names every row by its own status, so Accessibility is never hidden")
        let off = MacPermissionSnapshot([.microphone: .allowed, .accessibility: .notSetUp, .screenRecording: .notAllowed,
                                         .camera: .notAsked, .callAudio: .checkedOnUse])
        try check(off.summary == "1 off" && off.tone == .attention && off.expanded(dismissed: false),
                  "an approval that is off opens the panel")
        try check(!off.expanded(dismissed: true, offWhenDismissed: [.screenRecording]) && off.expanded(dismissed: true, offWhenDismissed: []),
                  "Done for now folds the panel even with something off; only something newly off opens it again")
        let twoOff = MacPermissionSnapshot([.microphone: .notAllowed, .accessibility: .allowed, .screenRecording: .notAllowed,
                                            .camera: .allowed, .callAudio: .checkedOnUse])
        try check(twoOff.summary == "2 off" && twoOff.expanded(dismissed: true, offWhenDismissed: [.screenRecording])
                  && twoOff.foldedLine.contains("Off: Microphone and"),
                  "a second approval turning off after Done for now opens the panel again, and folded it is named")
        let allSet = MacPermissionSnapshot([.microphone: .allowed, .accessibility: .allowed, .screenRecording: .allowed,
                                            .camera: .allowed, .callAudio: .checkedOnUse])
        try check(allSet.summary == "All set" && allSet.isComplete && allSet.tone == .done && !allSet.expanded(dismissed: false)
                  && allSet.foldedLine.contains("call audio"),
                  "every approval checkable now allowed, with call audio known only from a call, reads All set and folds")
        let heardCall = MacPermissionSnapshot([.microphone: .allowed, .accessibility: .allowed, .screenRecording: .allowed,
                                               .camera: .allowed, .callAudio: .lastCall(allowed: true)])
        try check(heardCall.summary == "All set" && heardCall.isComplete,
                  "call audio heard on the last call still reads All set, never All allowed, because nothing can check it now")
        let oldMac = MacPermissionSnapshot([.microphone: .allowed, .accessibility: .allowed, .screenRecording: .allowed,
                                            .camera: .allowed, .callAudio: .unsupported("Needs macOS 14.2 or later")])
        try check(oldMac.summary == "All allowed" && !oldMac.foldedLine.contains("call audio"),
                  "on macOS 14.0–14.1 the folded line never mentions call audio macOS can't record")
        let refused = MacPermissionSnapshot([.microphone: .allowed, .accessibility: .allowed, .screenRecording: .allowed,
                                             .camera: .allowed, .callAudio: .lastCall(allowed: false)])
        try check(refused.summary == "1 off" && rowIn(refused, .callAudio)?.action == .openSettings && refused.offPermissions == [.callAudio],
                  "a call-audio refusal Meetings recorded reads Off on your last call with its Settings list")
        let workMac = MacPermissionSnapshot([.microphone: .allowed, .accessibility: .needsAdministrator(listed: true),
                                             .screenRecording: .needsAdministrator(listed: false), .camera: .allowed, .callAudio: .checkedOnUse],
                                            administrator: false)
        try check(workMac.summary == "Needs an administrator" && workMac.tone == .neutral && !workMac.needsAttention
                  && workMac.expanded(dismissed: false) && !workMac.expanded(dismissed: true)
                  && workMac.foldedLine.contains("Needs an administrator: Accessibility.")
                  && workMac.foldedLine.contains("May need an administrator: Screen"),
                  "a standard account's work Mac says what needs an administrator and what only may, never as warnings, and folds for good")
        let screenOnly = MacPermissionSnapshot([.accessibility: .allowed, .screenRecording: .needsAdministrator(listed: false)], administrator: false)
        try check(screenOnly.summary == "May need an administrator", "the summary hedges when only Screen Recording may need an administrator")
        let managed = MacPermissionSnapshot([.microphone: .allowed, .accessibility: .allowed, .screenRecording: .allowed,
                                             .camera: .managed, .callAudio: .checkedOnUse])
        try check(!managed.isComplete && !managed.needsAttention && managed.summary == "1 managed" && managed.tone == .neutral,
                  "a managed camera keeps the panel from claiming All set without asking for attention")
        try check(MacPermissionReader.state(.notDetermined) == .notAsked && MacPermissionReader.state(.restricted) == .managed
                  && MacPermissionReader.state(.denied) == .notAllowed && MacPermissionReader.state(.authorized) == .allowed,
                  "the camera and microphone keep the four answers macOS gives")
        try check(MacPermissionReader.state(callAudio: nil, supported: true) == .checkedOnUse
                  && MacPermissionReader.state(callAudio: .allowed, supported: true) == .lastCall(allowed: true)
                  && MacPermissionReader.state(callAudio: .refused, supported: true) == .lastCall(allowed: false)
                  && MacPermissionReader.state(callAudio: .allowed, supported: false) == .unsupported("Needs macOS 14.2 or later"),
                  "call audio reads from Meetings' record, and below macOS 14.2 from nothing")

        // Copy permission details: what IT should allow by macOS version, this edition, this Mac.
        let facts = MacPermissionDetails.Facts(appName: "Workbench Preview", bundleID: "com.ethdawg.workbench.preview", version: "2.5.0", build: "1",
                                               codeRequirement: "identifier \"com.ethdawg.workbench.preview\"", macOS: "macOS 26.5.1",
                                               installedIn: "/Applications", administrator: false, enrolled: true, postEvent: false,
                                               callAudio: .refused, keyboardLayout: "com.apple.keylayout.Dvorak", pasteKeyCode: 47,
                                               lastPasteProblem: "copied, no text field found, in Chrome at 14:02")
        let copied = MacPermissionDetails.text(workMac, facts)
        try check(copied.contains("PostEvent = Allow") && copied.contains("AllowStandardUserToSetSystemService") && copied.contains("macOS 27: keep that PPPC profile")
                  && copied.contains("supervised") && copied.contains("Identifier: com.ethdawg.workbench.preview") && copied.contains("Code requirement: identifier")
                  && copied.contains("administrator: no") && copied.contains("Accessibility: Needs an administrator")
                  && copied.contains("Post Event: no") && copied.contains("quit and reopen Workbench, then copy again")
                  && copied.contains("System Audio Recording Only. No profile key") && copied.contains("user channel")
                  && copied.contains("call audio: refused on the last call")
                  && copied.contains("⌘V key 47") && copied.contains("no text field found, in Chrome")
                  && !copied.contains("pasteUnconfirmed") && !copied.contains("fieldUnreadable")
                  && copied.contains(MacPermissionDetails.itPage) && copied.count < 2_048,
                  "Copy permission details names what IT should allow on each macOS, this edition's identity and what this Mac reports, in plain words")

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

        // Settings › Keyboard lists what is on first, in the order Your keys teaches it, then what is off.
        let catalogue = [entry("voice.2", 13), entry("stage.undo", 6, enabled: false), entry("stage.pen", 2), entry("custom.one", 40),
                         entry("voice.1", 9), entry("voice.8", 5, enabled: false)]
        let listed = KeyboardCoachView.ordered(catalogue)
        try check(listed.on.map(\.id) == ["voice.1", "stage.pen", "voice.2", "custom.one"] && listed.off.map(\.id) == ["stage.undo", "voice.8"],
                  "Keyboard leads with Dictate and Draw, keeps unknown shortcuts after the taught ones, and gathers what is off below")

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

    /// Text Input Sources must be read on the main thread, so the paste key's layouts are checked here.
    @MainActor static func runPasteKey() throws {
        var passed = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("PASTE KEY CHECK FAILED: " + name) }
            passed += 1
        }
        // ⌘V is the key that types “v” with ⌘ in the layout, read passively from installed layouts.
        var read = 0
        func source(_ id: String) -> TISInputSource? {
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first
        }
        for (layout, key) in [("com.apple.keylayout.US", 9), ("com.apple.keylayout.Dvorak", 47), ("com.apple.keylayout.DVORAK-QWERTYCMD", 9),
                              ("com.apple.keylayout.Dvorak-Right", 43), ("com.apple.keylayout.Turkish", 8), ("com.apple.keylayout.Russian", 9)] {
            guard let installed = source(layout) else { continue }
            read += 1
            try check(PasteKey.keyCode(in: installed) == CGKeyCode(key), "⌘V in \(layout) is key \(key), not always the US position")
        }
        let turkmenFilter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.Turkmen"] as CFDictionary
        if let turkmen = (TISCreateInputSourceList(turkmenFilter, true)?.takeRetainedValue() as? [TISInputSource])?.first {
            try check(PasteKey.keyCode(in: turkmen) == nil, "a layout with no ⌘V key copies instead of sending some other shortcut")
        }
        try check(read >= 4, "the installed layouts were read, so the layout checks above ran")
        print("PASTE_KEY_CHECKS_OK: \(passed) checks; installed layouts read, none selected")
    }

    /// The live reader's mapping, with fixed answers: the record, macOS 14.0–14.1, an account
    /// macOS can't place, and an approval switched off after Home saw it on.
    @MainActor static func runReader() throws {
        var passed = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("PERMISSION READER CHECK FAILED: " + name) }
            passed += 1
        }
        var accessibility = false, record: CallAudioRecord? = .refused, supported = true, administrator: Bool? = nil
        var earlier: Set<MacPermission> = []
        let reader = MacPermissionReader(microphone: { .authorized }, camera: { .denied }, accessibility: { accessibility },
                                         screenRecording: { false }, callAudioSupported: { supported }, screenRecordingAsked: { false },
                                         callAudio: { record }, administrator: { administrator }, allowedEarlier: { earlier })
        func state(_ snapshot: MacPermissionSnapshot, _ permission: MacPermission) -> MacPermissionState? { snapshot.rows.first { $0.permission == permission }?.state }
        var snapshot = reader.snapshot(accessibilityAsked: false)
        try check(state(snapshot, .accessibility) == .notSetUp && state(snapshot, .screenRecording) == .notSetUp && state(snapshot, .camera) == .notAllowed
                  && state(snapshot, .callAudio) == .lastCall(allowed: false),
                  "an account macOS can't place reads as able to switch things on, and Meetings' refusal reaches the row")
        earlier = [.accessibility]
        snapshot = reader.snapshot(accessibilityAsked: false)
        try check(state(snapshot, .accessibility) == .notAllowed && state(snapshot, .screenRecording) == .notSetUp,
                  "Accessibility switched off after Home saw it on reads Off, even without Workbench's record of asking")
        administrator = false; accessibility = true; record = nil; supported = false
        snapshot = reader.snapshot(accessibilityAsked: true)
        try check(state(snapshot, .accessibility) == .allowed && state(snapshot, .screenRecording) == .needsAdministrator(listed: false)
                  && state(snapshot, .callAudio) == .unsupported("Needs macOS 14.2 or later"),
                  "a standard account's allowed Accessibility stays Allowed; below macOS 14.2 call audio reads unsupported")
        let paste = AutomaticPasteProblem(.init(message: "", clipboardChangeCount: nil, wasPasted: false, destinationName: "Chrome",
                                                failure: .pasteUnconfirmed), layout: "us", pasteKey: 9)
        snapshot = reader.snapshot(accessibilityAsked: true, paste: paste)
        try check(snapshot.pasteNote == "Last paste unconfirmed" && snapshot.rows.first { $0.permission == .accessibility }?.pasteProblem == paste?.line,
                  "the last paste problem reaches the Accessibility row and the summary")
        try check(AccessibilitySetup.screenRecording.settings == ScreenCaptureAccess.settingsURL && AccessibilitySetup.live.settings == AccessibilitySetup.settingsURL,
                  "Screen Recording's setup route opens its own list, and Accessibility's its own")
        print("PERMISSION_READER_CHECKS_OK: \(passed) checks; fixed answers only, nothing asked of macOS")
    }
}
