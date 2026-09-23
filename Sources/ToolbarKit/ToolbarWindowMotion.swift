import AppKit

/// One native window animation. Retargeting invalidates only the old completion,
/// never the reducer state. The immediate path is also used for Reduce Motion.
@MainActor public final class ToolbarWindowMotion {
    public private(set) var target: NSRect?
    public var settled: (() -> Void)?
    private var revision = 0
    public init() {}

    public func move(_ window: NSWindow, to frame: NSRect, animated: Bool) {
        revision += 1
        let current = revision
        guard animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            target = nil
            // Supersede a native animation on this property, then finish now.
            // A drag must not receive a late completion restoring its old origin.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                window.animator().setFrame(frame, display: true)
            }
            window.setFrame(frame, display: true, animate: false)
            settled?()
            return
        }
        target = frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard let self, let window, self.revision == current else { return }
                window.setFrame(frame, display: true, animate: false)
                self.target = nil
                self.settled?()
            }
        }
    }

    public func finish(_ window: NSWindow) {
        guard let target else { return }
        move(window, to: target, animated: false)
    }
}
