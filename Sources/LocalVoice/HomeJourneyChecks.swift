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
        // Nothing yet: the guide, with Skip for now, then Read and Snap and an empty Recent work.
        let fresh = HomeJourney()
        try check(fresh.showsGuide && fresh.offersSkip && !fresh.offersGuide, "nothing saved shows the guide and offers Skip for now")
        try check(fresh.sections == [.guide, .quickStart, .recentWork], "nothing saved shows the guide, the quick starts and Recent work")

        // The gate: other saved work never ends the guide, and stays listed below it.
        for (name, journey) in [("a loaded Snap & Talk session", HomeJourney(hasSession: true)), ("iPhone photos", HomeJourney(photos: 2)),
                                ("both", HomeJourney(hasSession: true, photos: 1))] {
            try check(journey.showsGuide && journey.offersSkip && !journey.hasDictated, "\(name) without a dictation still gets the guide")
            try check(journey.sections.prefix(3) == [.guide, .quickStart, .recentWork], "\(name) stays below the guide and Recent work")
        }
        try check(HomeJourney(hasSession: true, photos: 1).sections == [.guide, .quickStart, .recentWork, .fromIPhone],
                  "a loaded session uses its workflow card instead of creating a duplicate section")

        // A dictation ends first use, including one saved before this state existed.
        let dictated = HomeJourney(transcripts: 1)
        try check(!dictated.showsGuide && !dictated.offersSkip && !dictated.offersGuide, "after a dictation Home offers neither the guide nor the way back")
        try check(dictated.sections == [.quickStart, .recentWork], "after a dictation Home shows the quick starts and recent work")
        try check(dictated.guideToSave == .completed && HomeJourney(transcripts: 1, guide: .skipped).guideToSave == .completed,
                  "a dictation in History is recorded as completed, even after Skip for now")
        try check(HomeJourney(transcripts: 1, guide: .completed).guideToSave == nil && HomeJourney(hasSession: true, photos: 4).guideToSave == nil,
                  "completion is recorded once, and never from other work")
        let removed = HomeJourney(guide: .completed)
        try check(!removed.showsGuide && !removed.offersGuide && removed.sections == [.quickStart, .recentWork],
                  "removing every transcript later does not bring the guide back")

        // Skip for now: no tour, and one small way back while nothing is dictated.
        let skipped = HomeJourney(guide: .skipped)
        try check(!skipped.showsGuide && skipped.offersGuide && !skipped.offersSkip, "Skip for now hides the guide and keeps Show me a first dictation")
        try check(skipped.sections == [.quickStart, .recentWork], "a skipped guide leaves the ordinary Home")
        // Leaving Home, a cancelled permission request and relaunch keep the saved choice:
        // a new Home (stayInGuide false), a request in flight (current work) and after it.
        for (name, journey) in [("leaving and returning to Home", HomeJourney(guide: .skipped, stayInGuide: false)),
                                ("a microphone request in flight", HomeJourney(guide: .skipped, hasCurrentWork: true))] {
            try check(!journey.showsGuide && journey.offersGuide, "\(name) never forces the guide back or loses the way back")
        }
        try check(HomeJourney(hasCurrentWork: true).sections == [.currentWork, .guide, .quickStart, .recentWork],
                  "a cancelled microphone request leaves the guide as it was, below current work")

        // Show me a first dictation offers the guide again, with its own Skip.
        let resumed = HomeJourney(guide: .offered, photos: 1, stayInGuide: true)
        try check(resumed.showsGuide && resumed.offersSkip && resumed.sections.prefix(2) == [.guide, .quickStart], "the way back shows the guide again")

        // Dictating from the guide: it stays to show where the words went, then Done or leaving Home ends it.
        let landed = HomeJourney(transcripts: 1, guide: .completed, stayInGuide: true)
        try check(landed.sections == [.guide, .firstResult, .quickStart], "the first result shows where the words went, not a second copy in recent work")
        try check(!landed.offersSkip && !landed.offersGuide, "after the first result neither Skip nor the way back remains")
        try check(HomeJourney(transcripts: 1, guide: .completed).sections == [.quickStart, .recentWork], "Done returns to the ordinary Home")

        // Current work comes first in every state, and its operations leave the quick starts.
        try check(HomeJourney(hasCurrentWork: true).sections.first == .currentWork
                  && HomeJourney(transcripts: 1, hasCurrentWork: true).sections == [.currentWork, .quickStart, .recentWork],
                  "current work renders above the guide and the quick starts")
        let order: [HomeJourney.Section] = [.currentWork, .guide, .firstResult, .quickStart, .recentWork, .fromIPhone]
        for journey in [HomeJourney(transcripts: 1, hasCurrentWork: true, hasSession: true, photos: 2),
                        HomeJourney(hasCurrentWork: true, hasSession: true, photos: 2), landed, fresh] {
            let positions = journey.sections.map { order.firstIndex(of: $0)! }
            try check(positions == positions.sorted(), "Home keeps its fixed order: \(journey.sections)")
        }

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
