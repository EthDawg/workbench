import AppKit
import QuartzCore
import ToolbarCore

/// One frame clock updates origin and size together. Retargeting begins at the actual
/// visible frame, so an interrupted resize cannot leave two AppKit animations competing.
@MainActor public final class ToolbarWindowMotion {
    public private(set) var target: NSRect?
    public var settled: (() -> Void)?
    private var timer: Timer?
    private var revision = 0
    public init() {}

    public func move(_ window: NSWindow, to frame: NSRect, animated: Bool, anchor: ToolbarAnchor = .bottom, isFloating: Bool = false) {
        timer?.invalidate(); timer = nil
        revision += 1
        let current = revision
        guard animated, window.frame != frame, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            target = nil
            window.setFrame(frame, display: true, animate: false)
            settled?()
            return
        }
        let start = window.frame, began = CACurrentMediaTime()
        let destination = ToolbarGeometry.restingCentre(inWindow: frame, anchor: anchor, isFloating: isFloating)
        var origin = ToolbarGeometry.restingCentre(inWindow: start, anchor: anchor, isFloating: isFloating)
        // AppKit rounds native frames. Do not feed that half-point error back into the
        // next resize: an unchanged reference stays exact through repeated reversals.
        if abs(origin.x - destination.x) <= 1 { origin.x = destination.x }
        if abs(origin.y - destination.y) <= 1 { origin.y = destination.y }
        target = frame
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self, weak window] tick in
            MainActor.assumeIsolated {
                guard let self, let window, self.revision == current else { tick.invalidate(); return }
                let progress = min(1, max(0, (CACurrentMediaTime() - began) / 0.16))
                let eased = 1 - pow(1 - progress, 3)
                func blend(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
                let width = blend(start.width, frame.width).rounded(), height = blend(start.height, frame.height).rounded()
                let reference = CGPoint(x: blend(origin.x, destination.x), y: blend(origin.y, destination.y))
                var next = ToolbarGeometry.frame(size: NSSize(width: width, height: height), reference: reference, anchor: anchor, isFloating: isFloating)
                next.origin = NSPoint(x: next.minX.rounded(), y: next.minY.rounded())
                window.setFrame(progress == 1 ? frame : next, display: true, animate: false)
                guard self.revision == current else { tick.invalidate(); return }
                if progress == 1 {
                    tick.invalidate(); self.timer = nil; self.target = nil
                    self.settled?()
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    public func finish(_ window: NSWindow) {
        guard let target else { return }
        move(window, to: target, animated: false)
    }

    deinit { timer?.invalidate() }
}
