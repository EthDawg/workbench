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
        print("CAPTURE_HUD_CHECKS_OK: \(count) checks passed")
    }
}
