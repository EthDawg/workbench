import AppKit
import StageKit

/// Pure geometry and presentation checks; no windows, microphone or hotkeys.
enum CaptureHUDChecks {
    private struct Failure: LocalizedError {
        let name: String
        var errorDescription: String? { "Capture HUD check failed: \(name)" }
    }

    static func run() throws {
        var count = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw Failure(name: name) }
            count += 1
        }
        let main = NSRect(x: 0, y: 30, width: 1440, height: 870)
        try check(FloatingToolbarSurface.resolve(enabled: true, capturingScreen: false, dictation: false, narration: false) == .tools,
                  "finishing an operation returns to the persistent tools")
        try check(FloatingToolbarSurface.resolve(enabled: false, capturingScreen: false, dictation: false, narration: false) == .hidden,
                  "an explicit idle-toolbar dismissal remains respected")
        for enabled in [true, false] {
            try check(FloatingToolbarSurface.resolve(enabled: enabled, capturingScreen: false, dictation: true, narration: false) == .tools,
                      "dictation keeps the shared host visible even with idle tools hidden (#134 T4)")
            try check(FloatingToolbarSurface.resolve(enabled: enabled, capturingScreen: false, dictation: false, narration: true) == .tools,
                      "narration uses the same host")
            try check(FloatingToolbarSurface.resolve(enabled: enabled, capturingScreen: true, dictation: true, narration: true) == .hidden,
                      "screen acquisition temporarily hides all shared controls")
        }
        // StageKit's named docks and drag destination agree, as its other floating controls use
        // them; the toolbar's own placement is ToolbarPlacementTests' and the gallery's.
        let left = NSRect(x: -1920, y: -400, width: 1920, height: 1080)
        for screen in [main, left] {
            for anchor in FloatingControlAnchor.allCases {
                let frame = FloatingControlGeometry.frame(anchor: anchor, size: CaptureHUDLayout.message, visibleFrame: screen)
                try check(screen.contains(frame) && FloatingControlGeometry.nearestAnchor(to: frame, in: screen) == anchor,
                          "menu and drag destination agree on \(anchor.title)")
            }
        }
        let top = FloatingControlGeometry.frame(anchor: .top, size: CaptureHUDLayout.compact, visibleFrame: main)
        try check(FloatingControlGeometry.nearestAnchor(to: top.offsetBy(dx: 28, dy: 0), in: main) == .top, "snap threshold includes its boundary")
        try check(FloatingControlGeometry.nearestAnchor(to: top.offsetBy(dx: 28.1, dy: 0), in: main) == nil, "drag outside snap threshold remains free")

        // A dictation that heard no speech is routine: its cue goes within two
        // seconds unless the person holds it; a technical failure stays (#156).
        let shown = Date(timeIntervalSinceReferenceDate: 1_000)
        var routine = CaptureCueClock(routine: true, shownAt: shown)
        try check(CaptureCueClock.routineSeconds < 2 && routine.deadline == shown.addingTimeInterval(CaptureCueClock.routineSeconds),
                  "a routine cue is timed to go within two seconds")
        try check(!routine.isExpired(at: shown.addingTimeInterval(1.5)) && routine.isExpired(at: shown.addingTimeInterval(2)),
                  "a routine cue is gone by two seconds without a click")
        routine.hold(true, at: shown.addingTimeInterval(1))
        try check(routine.isHeld && routine.deadline == nil && !routine.isExpired(at: shown.addingTimeInterval(60)),
                  "hovering the cue, or VoiceOver on it, holds it for as long as that lasts")
        routine.hold(true, at: shown.addingTimeInterval(30))
        routine.hold(false, at: shown.addingTimeInterval(60))
        try check(!routine.isHeld && abs((routine.deadline?.timeIntervalSince(shown) ?? 0) - (60 + CaptureCueClock.routineSeconds - 1)) < 0.0001,
                  "letting go resumes the time that was left, once")
        let technical = CaptureCueClock(routine: false, shownAt: shown)
        try check(technical.deadline == nil && !technical.isExpired(at: .distantFuture), "a technical failure never goes by itself")
        try check(FloatingToolbarSurface.resolve(enabled: false, capturingScreen: false, dictation: false, narration: false, reading: true) == .tools,
                  "a stopped reading keeps the shared host, and its controls, even with the toolbar hidden")
        let cues = [CaptureCue(reason: .tooShort), CaptureCue(reason: .tooQuiet),
                    CaptureCue(reason: .nothingRecognised(keptAudio: true)), CaptureCue(reason: .nothingRecognised(keptAudio: false))]
        let words = cues.flatMap { [$0.message, $0.hint, $0.status] }.joined(separator: " ")
        try check(cues.allSatisfy { $0.message == "No speech heard" && $0.hint.count <= 40 } && !words.lowercased().contains("attention")
                  && !words.contains("—") && !words.contains("–") && !words.contains(" - "),
                  "the cue says No speech heard with a short hint, never Needs attention, with no dash punctuation")
        print("CAPTURE_HUD_CHECKS_OK: \(count) checks passed")
    }
}
