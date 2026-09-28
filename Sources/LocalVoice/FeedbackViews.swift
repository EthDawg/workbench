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
            .onHover { coach.hold(.pointer, $0, for: card.id) }
            .onChange(of: focused) { _, isFocused in coach.hold(.focus, isFocused, for: card.id) }
            .onExitCommand { if focused { coach.dismiss(card.id) } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Hint")
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
