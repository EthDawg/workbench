import Foundation

/// Home's first-dictation gate, its way back and its section order, without
/// rendering SwiftUI. The guide is gated on dictation, not on any saved work (#15).
enum HomeJourneyChecks {
    static func run() throws {
        var passed = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("HOME_JOURNEY_CHECK_FAILED: \(name)") }
            passed += 1
        }
        // Nothing yet: the guide, with Skip for now, then the moments.
        let fresh = HomeJourney()
        try check(fresh.showsGuide && fresh.offersSkip && !fresh.offersGuide, "nothing saved shows the guide and offers Skip for now")
        try check(fresh.sections == [.guide, .moments], "nothing saved shows the guide, then the moments")

        // The gate: other saved work never ends the guide, and stays listed below it.
        for (name, journey) in [("a Snap", HomeJourney(snaps: 1)), ("a Snap & Talk session", HomeJourney(sessions: 1)),
                                ("a hand-off job", HomeJourney(handoffJobs: 1)), ("iPhone photos", HomeJourney(photos: 2)),
                                ("all four", HomeJourney(snaps: 3, sessions: 1, handoffJobs: 2, photos: 1))] {
            try check(journey.showsGuide && journey.offersSkip && !journey.hasDictated, "\(name) without a dictation still gets the guide")
            try check(journey.sections == [.guide, .recentWork, .moments], "\(name) keeps its recent work below the guide")
        }

        // A dictation ends first use, including one saved before this state existed.
        let dictated = HomeJourney(transcripts: 1, snaps: 1)
        try check(!dictated.showsGuide && !dictated.offersSkip && !dictated.offersGuide, "after a dictation Home offers neither the guide nor the way back")
        try check(dictated.sections == [.recentWork, .moments], "after a dictation Home shows recent work")
        try check(dictated.guideToSave == .completed && HomeJourney(transcripts: 1, guide: .skipped).guideToSave == .completed,
                  "a dictation in History is recorded as completed, even after Skip for now")
        try check(HomeJourney(transcripts: 1, guide: .completed).guideToSave == nil && HomeJourney(snaps: 4).guideToSave == nil,
                  "completion is recorded once, and never from other work")
        let removed = HomeJourney(snaps: 1, guide: .completed)
        try check(!removed.showsGuide && !removed.offersGuide && removed.sections == [.recentWork, .moments],
                  "removing every transcript later does not bring the guide back")

        // Skip for now: no tour, and one small way back while nothing is dictated.
        let skipped = HomeJourney(snaps: 1, guide: .skipped)
        try check(!skipped.showsGuide && skipped.offersGuide && !skipped.offersSkip, "Skip for now hides the guide and keeps Show me a first dictation")
        try check(skipped.sections == [.recentWork, .moments], "a skipped guide leaves the ordinary Home")
        try check(HomeJourney(guide: .skipped).sections == [.moments] && HomeJourney(guide: .skipped).offersGuide, "with nothing saved the skipped guide keeps its way back")
        // Leaving Home, a cancelled permission request and relaunch keep the saved choice:
        // a new Home (stayInGuide false), a request in flight (live) and after it.
        for (name, journey) in [("leaving and returning to Home", HomeJourney(snaps: 1, guide: .skipped, stayInGuide: false)),
                                ("a microphone request in flight", HomeJourney(snaps: 1, guide: .skipped, isLive: true))] {
            try check(!journey.showsGuide && journey.offersGuide, "\(name) never forces the guide back or loses the way back")
        }
        try check(HomeJourney(isLive: true).sections == [.liveStrip, .guide, .moments] && HomeJourney().sections == [.guide, .moments],
                  "a cancelled microphone request leaves the guide as it was")

        // Show me a first dictation offers the guide again, with its own Skip.
        let resumed = HomeJourney(snaps: 1, guide: .offered, stayInGuide: true)
        try check(resumed.showsGuide && resumed.offersSkip && resumed.sections == [.guide, .recentWork, .moments], "the way back shows the guide again")

        // Dictating from the guide: it stays to show where the words went, then Done or leaving Home ends it.
        let landed = HomeJourney(transcripts: 1, snaps: 2, guide: .completed, stayInGuide: true)
        try check(landed.sections == [.guide, .firstResult, .moments], "the first result shows where the words went, not a second copy in recent work")
        try check(!landed.offersSkip && !landed.offersGuide, "after the first result neither Skip nor the way back remains")
        try check(HomeJourney(transcripts: 1, snaps: 2, guide: .completed).sections == [.recentWork, .moments], "Done returns to the ordinary Home")

        // The live strip comes first in every state.
        try check(HomeJourney(isLive: true).sections.first == .liveStrip && HomeJourney(transcripts: 1, isLive: true).sections == [.liveStrip, .recentWork, .moments],
                  "the live strip renders above the guide and above recent work")

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
