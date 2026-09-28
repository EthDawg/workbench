import AppKit
import StageKit

/// Presentation only: changing the HUD size never changes the capture itself.
enum CaptureHUDLayout {
    static let compact = NSSize(width: 336, height: 64)
    static let expanded = NSSize(width: 480, height: 192)
    static let message = NSSize(width: 480, height: 128)

    /// The message layout is for receipts, processing and the explicit
    /// recovery panel. A routine cue after a dictation that heard no speech
    /// keeps the compact size of the recording controls it replaces (#156).
    static func size(recording: Bool, preview: Bool, expanded: Bool, cue: Bool = false) -> NSSize {
        if cue && !recording && !preview { return compact }
        return recording || preview ? (expanded ? Self.expanded : compact) : message
    }
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

    static func frame(size: NSSize, anchor: FloatingControlAnchor?, previous: NSRect?, screens: [NSRect], preferred: NSRect) -> NSRect {
        let previous = previous.flatMap { valid($0) ? $0 : nil }
        let screen = screen(for: previous, screens: screens, preferred: preferred)
        if let anchor { return FloatingControlGeometry.frame(anchor: anchor, size: size, visibleFrame: screen) }
        guard let previous else { return FloatingControlGeometry.frame(anchor: .bottom, size: size, visibleFrame: screen) }
        let resized = NSRect(x: previous.midX - size.width / 2, y: previous.midY - size.height / 2,
                             width: size.width, height: size.height)
        return FloatingControlGeometry.clamp(resized, to: screen)
    }

    private static func valid(_ frame: NSRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) && frame.width > 0 && frame.height > 0
    }
}

/// Retained for the existing core checks and saved free-position migration.
enum CapturePanelPlacement {
    static let size = CaptureHUDLayout.message
    static func origin(saved: NSPoint?, screens: [NSRect], preferred: NSRect) -> NSPoint {
        CaptureHUDGeometry.frame(size: size, anchor: nil, previous: saved.map { NSRect(origin: $0, size: size) },
                                 screens: screens, preferred: preferred).origin
    }
}
