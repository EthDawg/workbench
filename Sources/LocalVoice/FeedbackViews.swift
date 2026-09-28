import AppKit
import SwiftUI

// The views for brief feedback (#134 T5). They read lifetimes from their
// owners and report holds; they never start, restart or end a countdown.

/// A dismissible notice's remaining time: a ring that starts full at twelve
/// o'clock and empties clockwise. It is decorative; the control it surrounds
/// carries the meaning for assistive technologies.
struct CountdownRing: View {
    /// 1 when the notice appears, 0 when it is due.
    let fraction: Double
    var diameter: CGFloat = 24
    var lineWidth: CGFloat = 1.5

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.18), lineWidth: lineWidth)
            Circle().trim(from: 1 - min(1, max(0, fraction)), to: 1)
                .stroke(Color.secondary.opacity(0.75), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// The ring for a live lifetime, redrawn from its owner's clock while it runs.
/// Held, waiting or under Reduce Motion it is still; with Reduce Motion or a
/// wait for dismissal it is not drawn, so the close control stays static.
struct LiveCountdownRing: View {
    let lifetime: NoticeLifetime?
    let clock: MonotonicClock
    var diameter: CGFloat = 24
    /// A fixed value instead of the live clock, for renders.
    var fixedFraction: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let lifetime, !reduceMotion, !lifetime.waitsForDismissal, lifetime.isPresented, !lifetime.holds.contains(.pinned) {
            if let fixedFraction {
                CountdownRing(fraction: fixedFraction, diameter: diameter)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !lifetime.isRunning)) { _ in
                    CountdownRing(fraction: lifetime.fraction(at: clock()), diameter: diameter)
                }
            }
        }
    }
}

/// × inside a 32 × 32 target, with the notice's countdown ring around it.
struct CountdownDismissButton: View {
    let lifetime: NoticeLifetime?
    let clock: MonotonicClock
    let label: String
    var fixedFraction: Double? = nil
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay { LiveCountdownRing(lifetime: lifetime, clock: clock, fixedFraction: fixedFraction).allowsHitTesting(false) }
        .accessibilityLabel(label)
    }
}

/// Whether the pointer is over a notice, including a pointer already resting
/// where the notice appears, which SwiftUI's hover reports only once the
/// pointer moves. A notice uses it to hold its time. It takes no clicks.
struct PointerPresence: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> PointerPresenceView { PointerPresenceView(changed: changed) }
    func updateNSView(_ view: PointerPresenceView, context: Context) { view.changed = changed }
    static func dismantleNSView(_ view: PointerPresenceView, coordinator: ()) { view.stop() }
}

final class PointerPresenceView: NSView {
    var changed: (Bool) -> Void
    /// The pointer in screen coordinates; checks supply their own.
    var pointer: () -> NSPoint = { NSEvent.mouseLocation }
    /// Whether the window is on screen; checks supply their own.
    var windowShows: (NSWindow) -> Bool = { $0.isVisible }
    /// Reports wait until the current layout pass ends; checks deliver at once.
    var deliver: (@escaping () -> Void) -> Void = { work in DispatchQueue.main.async(execute: work) }
    private(set) var isInside = false
    private var area: NSTrackingArea?
    private var windowObserver: NSObjectProtocol?

    init(changed: @escaping (Bool) -> Void) {
        self.changed = changed
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver); self.windowObserver = nil }
        if let window {
            // Ordered in or out without moving: judge the pointer again.
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                    object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refresh()
    }

    /// Where the pointer is now decides the start; AppKit then reports the
    /// exit, or the entry, from that state.
    func refresh() {
        if let area { removeTrackingArea(area); self.area = nil }
        let inside = pointerIsInside
        if window != nil {
            var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
            if inside { options.insert(.assumeInside) }
            let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
            addTrackingArea(area)
            self.area = area
        }
        report(inside)
    }

    var pointerIsInside: Bool {
        guard let window, windowShows(window), !isHiddenOrHasHiddenAncestor else { return false }
        return visibleRect.contains(convert(window.convertPoint(fromScreen: pointer()), from: nil))
    }

    override func mouseEntered(with event: NSEvent) { report(true) }
    override func mouseExited(with event: NSEvent) { report(false) }

    /// The notice is gone: whatever held it lets go.
    func stop() {
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver); self.windowObserver = nil }
        report(false)
    }

    deinit { if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) } }

    private func report(_ inside: Bool) {
        guard inside != isInside else { return }
        isInside = inside
        let changed = changed
        deliver { changed(inside) }
    }
}

/// The one-time coaching card: a neutral symbol, a 13 pt title, a 12 pt line
/// and a close control whose ring shows its four seconds. At most 320 pt wide
/// at standard text sizes; larger text wraps and grows. The host places it,
/// above the compact control with a 12 pt gap, and reports when it is shown.
/// Pointer and keyboard focus hold its time; Escape dismisses it only while
/// it has keyboard focus.
struct CoachCardView: View {
    @ObservedObject var coach: FeedbackCoachModel
    /// A fixed ring value, for renders only.
    var fixedFraction: Double? = nil
    @FocusState private var focused: Bool

    var body: some View {
        if let card = coach.card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: card.symbol).font(.system(size: 15)).foregroundStyle(.secondary)
                    .padding(.top, 1).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.title).font(.system(size: 13, weight: .medium))
                    Text(card.body).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                CountdownDismissButton(lifetime: coach.lifetime, clock: coach.clock, label: "Dismiss hint",
                                       fixedFraction: fixedFraction) { coach.dismiss(card.id) }
                    .focused($focused)
                    .padding(.top, -6).padding(.trailing, -6)
            }
            .padding(12)
            .frame(maxWidth: 320, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            // A pointer already resting where the card appears holds it too.
            .background(PointerPresence { coach.hold(.pointer, $0, for: card.id) })
            .onChange(of: focused) { _, isFocused in coach.hold(.focus, isFocused, for: card.id) }
            .onExitCommand { if focused { coach.dismiss(card.id) } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Hint")
            // Each card is its own view, so a newer card judges the pointer afresh.
            .id(card.id)
        }
    }
}

/// A quiet ✓ confirmation beside the control that succeeded. Its width and
/// height are kept for the longest text it can show, so nothing moves when it
/// appears or goes.
struct ConfirmationLabel: View {
    let text: String?
    /// Every text this place can show; the widest one sets the reserved size.
    let reserving: [String]

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(reserving, id: \.self) { candidate in content(candidate).hidden() }
            if let text { content(text).transition(.identity) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text ?? "")
        .accessibilityHidden(text == nil)
    }

    private func content(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Workbench.accent)
            Text(text).foregroundStyle(.secondary)
        }.font(.caption).lineLimit(1).fixedSize()
    }
}
