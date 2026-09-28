import Foundation

/// Home's first-run gate and section order, without rendering SwiftUI.
enum HomeJourneyChecks {
    static func run() throws {
        var passed = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("HOME_JOURNEY_CHECK_FAILED: \(name)") }
            passed += 1
        }
        try check(HomeJourney().isFirstRun, "nothing captured is first run")
        try check(HomeJourney().sections == [.guide, .moments], "first run shows the guide, then the moments")
        for (name, journey) in [("a transcript", HomeJourney(transcripts: 1)), ("a Snap", HomeJourney(snaps: 1)),
                                ("a Snap & Talk session", HomeJourney(sessions: 1)), ("a hand-off job", HomeJourney(handoffJobs: 1)),
                                ("iPhone photos", HomeJourney(photos: 2))] {
            try check(!journey.isFirstRun, "\(name) alone is not first run")
            try check(journey.sections == [.recentWork, .moments], "\(name) alone shows recent work")
        }
        // The stage exposes no saved-scene or persona count, so a scene-only Mac still counts as
        // first run; what it can do about a live scene is the live strip, which comes first.
        try check(HomeJourney(isLive: true).sections == [.liveStrip, .guide, .moments], "the live strip renders above the guide in the first-run state")
        try check(HomeJourney(transcripts: 1, isLive: true).sections == [.liveStrip, .recentWork, .moments], "the live strip renders above recent work")
        try check(HomeJourney(transcripts: 1, stayInGuide: true).sections == [.guide, .moments], "the guide stays after the first transcript until Done")
        try check(!HomeJourney(transcripts: 1, stayInGuide: true).isFirstRun, "staying in the guide does not make it first run again")
        print("HOME_JOURNEY_CHECKS_OK: \(passed) checks")
    }
}
