import AppKit
import StageKit

/// Presentation only: changing the HUD size never changes the capture itself.
enum CaptureHUDLayout {
    /// The routine no-speech cue and a stopped reading (#156, #134 T4).
    static let compact = NSSize(width: 336, height: 64)
    /// A dictation's result: a failure that needs a decision, or the clipboard receipt.
    static let message = NSSize(width: 480, height: 128)
}

enum CaptureHUDGeometry {
    static func screen(for frame: NSRect?, screens: [NSRect], preferred: NSRect) -> NSRect {
        guard let frame, valid(frame) else { return preferred }
        let overlaps = screens.map { screen -> (NSRect, CGFloat) in
            let intersection = screen.intersection(frame)
            return (screen, intersection.isNull ? 0 : intersection.width * intersection.height)
        }
        guard let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return preferred }
        return best.0
    }

    private static func valid(_ frame: NSRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) && frame.width > 0 && frame.height > 0
    }
}

