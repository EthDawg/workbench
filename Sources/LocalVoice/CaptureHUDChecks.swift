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
            try check(FloatingToolbarSurface.resolve(enabled: enabled, capturingScreen: false, dictation: true, narration: false) == .dictation,
                      "dictation controls remain visible even with idle tools hidden")
            try check(FloatingToolbarSurface.resolve(enabled: enabled, capturingScreen: false, dictation: false, narration: true) == .narration,
                      "narration reuses the same operation surface")
            try check(FloatingToolbarSurface.resolve(enabled: enabled, capturingScreen: true, dictation: true, narration: true) == .hidden,
                      "screen acquisition temporarily hides all shared controls")
        }
        let left = NSRect(x: -1920, y: -400, width: 1920, height: 1080)
        let screens = [main, left]
        for screen in screens {
            for anchor in FloatingControlAnchor.allCases {
                let compact = CaptureHUDGeometry.frame(size: CaptureHUDLayout.compact, anchor: anchor, previous: nil, screens: [screen], preferred: screen)
                let expanded = CaptureHUDGeometry.frame(size: CaptureHUDLayout.expanded, anchor: anchor, previous: compact, screens: screens, preferred: main)
                let collapsed = CaptureHUDGeometry.frame(size: CaptureHUDLayout.compact, anchor: anchor, previous: expanded, screens: screens, preferred: main)
                try check(collapsed == compact && screen.contains(expanded), "anchor survives expansion and collapse on \(anchor.title)")
                try check(FloatingControlGeometry.nearestAnchor(to: expanded, in: screen) == anchor, "menu and drag destination agree")
            }
        }
        let defaultFrame = CaptureHUDGeometry.frame(size: CaptureHUDLayout.compact, anchor: nil, previous: nil, screens: screens, preferred: main)
        try check(defaultFrame.midX == main.midX && defaultFrame.minY == main.minY + 16, "first recording sits above Dock at bottom centre")
        let free = NSRect(x: 400, y: 350, width: 336, height: 64)
        let enlarged = CaptureHUDGeometry.frame(size: CaptureHUDLayout.expanded, anchor: nil, previous: free, screens: screens, preferred: left)
        try check(enlarged.midX == free.midX && enlarged.midY == free.midY, "free placement expands around its centre without changing display")
        let oldDisplay = NSRect(x: -1800, y: -200, width: 336, height: 64)
        let recovered = CaptureHUDGeometry.frame(size: CaptureHUDLayout.expanded, anchor: .right, previous: oldDisplay, screens: [main], preferred: main)
        try check(main.contains(recovered) && recovered.maxX == main.maxX - 16, "removed display recovers the chosen right anchor")
        let partlyOff = NSRect(x: 1300, y: 850, width: 336, height: 64)
        let clamped = CaptureHUDGeometry.frame(size: CaptureHUDLayout.expanded, anchor: nil, previous: partlyOff, screens: [main], preferred: main)
        try check(main.contains(clamped), "free expansion near the edge remains visible")
        let tiny = NSRect(x: -300, y: -400, width: 200, height: 80)
        let tinyFrame = CaptureHUDGeometry.frame(size: CaptureHUDLayout.expanded, anchor: .bottom, previous: nil, screens: [tiny], preferred: tiny)
        try check(tiny.contains(tinyFrame), "small visible display keeps the frame recoverable")
        let invalid = NSRect(x: CGFloat.infinity, y: CGFloat.nan, width: 336, height: 64)
        let restored = CaptureHUDGeometry.frame(size: CaptureHUDLayout.compact, anchor: nil, previous: invalid, screens: screens, preferred: main)
        try check(restored == defaultFrame, "invalid saved coordinates recover at the default")
        let top = FloatingControlGeometry.frame(anchor: .top, size: CaptureHUDLayout.compact, visibleFrame: main)
        try check(FloatingControlGeometry.nearestAnchor(to: top.offsetBy(dx: 28, dy: 0), in: main) == .top, "snap threshold includes its boundary")
        try check(FloatingControlGeometry.nearestAnchor(to: top.offsetBy(dx: 28.1, dy: 0), in: main) == nil, "drag outside snap threshold remains free")
        try check(CaptureHUDLayout.size(recording: false, preview: false, expanded: true) == CaptureHUDLayout.message, "recording expansion cannot make a processing or receipt state permanent")
        try check(CaptureHUDLayout.size(recording: false, preview: true, expanded: false) == CaptureHUDLayout.compact, "microphone-off preview uses the actual compact layout")
        let legacy = NSPoint(x: 100, y: 320)
        try check(CapturePanelPlacement.origin(saved: legacy, screens: [main], preferred: main) == legacy, "legacy free placement remains unchanged")

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
        try check(CaptureHUDLayout.size(recording: false, preview: false, expanded: true, cue: true) == CaptureHUDLayout.compact
                  && CaptureHUDLayout.size(recording: false, preview: false, expanded: false) == CaptureHUDLayout.message,
                  "the cue keeps the compact size of the recording controls; the message layout stays for the explicit panel")
        try check(CaptureHUDLayout.size(recording: true, preview: false, expanded: true, cue: true) == CaptureHUDLayout.expanded,
                  "a cue never changes live recording controls")
        try check(FloatingToolbarSurface.resolve(enabled: false, capturingScreen: false, dictation: false, narration: false, reading: true) == .reading,
                  "a stopped reading keeps its controls even with the toolbar hidden")
        let cues = [CaptureCue(reason: .tooShort), CaptureCue(reason: .tooQuiet),
                    CaptureCue(reason: .nothingRecognised(keptAudio: true)), CaptureCue(reason: .nothingRecognised(keptAudio: false))]
        let words = cues.flatMap { [$0.message, $0.hint, $0.status] }.joined(separator: " ")
        try check(cues.allSatisfy { $0.message == "No speech heard" && $0.hint.count <= 40 } && !words.lowercased().contains("attention")
                  && !words.contains("—") && !words.contains("–") && !words.contains(" - "),
                  "the cue says No speech heard with a short hint, never Needs attention, with no dash punctuation")
        print("CAPTURE_HUD_CHECKS_OK: \(count) checks passed")
    }
}
