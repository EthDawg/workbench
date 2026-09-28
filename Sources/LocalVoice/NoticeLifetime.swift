import AppKit

// Brief feedback that teaches once and leaves work intact (#134 T5): the one
// lifetime every timed notice uses.

/// Seconds since this Mac started: the timebase of NSEvent and Carbon event
/// timestamps. It never jumps when the wall clock changes, so it cannot stretch
/// or cut short anything timed with it.
typealias MonotonicClock = () -> TimeInterval
enum Monotonic {
    static let now: MonotonicClock = { ProcessInfo.processInfo.systemUptime }
}

/// How long one notice stays: `duration` seconds of visible, unheld time on
/// one monotonic clock, tied to one event. Its owner keeps it. A view reads it
/// to draw a countdown and reports holds; one guarded expiry ends it. Drawing,
/// layout or looking at it again never restarts it.
struct NoticeLifetime: Equatable {
    /// Each pauses the count on its own; time resumes only when all let go.
    enum Hold: String, CaseIterable, Hashable {
        /// The pointer is over it.
        case pointer
        /// Keyboard focus is inside it.
        case focus
        /// Its own menu is open.
        case menu
        /// Kept on screen until unpinned, like a pinned receipt.
        case pinned
    }
    let event: UUID
    let duration: TimeInterval
    /// With VoiceOver on, a lesson waits for its dismissal or the next right action.
    let waitsForDismissal: Bool
    private(set) var isPresented = false
    private(set) var holds: Set<Hold> = []
    /// Unheld time left, as of `runningSince` while running.
    private(set) var remaining: TimeInterval
    /// When the current visible, unheld stretch began; nil while held or waiting.
    private(set) var runningSince: TimeInterval?

    init(event: UUID = UUID(), duration: TimeInterval, waitsForDismissal: Bool = false) {
        self.event = event
        self.duration = max(0, duration)
        self.waitsForDismissal = waitsForDismissal
        remaining = max(0, duration)
    }

    /// The host has it on screen: counting starts now, once. Later calls,
    /// such as a rerender, change nothing.
    mutating func present(at now: TimeInterval) {
        guard !isPresented else { return }
        isPresented = true
        resumeIfFree(at: now)
    }

    mutating func hold(_ hold: Hold, _ held: Bool, at now: TimeInterval) {
        if held {
            guard holds.insert(hold).inserted else { return }
            if let started = runningSince {
                remaining = max(0, remaining - max(0, now - started))
                runningSince = nil
            }
        } else {
            guard holds.remove(hold) != nil else { return }
            resumeIfFree(at: now)
        }
    }

    private mutating func resumeIfFree(at now: TimeInterval) {
        guard isPresented, holds.isEmpty, !waitsForDismissal, runningSince == nil else { return }
        runningSince = now
    }

    var isRunning: Bool { runningSince != nil }

    func remaining(at now: TimeInterval) -> TimeInterval {
        guard let started = runningSince else { return remaining }
        return max(0, remaining - max(0, now - started))
    }

    /// 1 when it appears, 0 when it is due: the countdown ring's value.
    func fraction(at now: TimeInterval) -> Double {
        duration > 0 ? min(1, max(0, remaining(at: now) / duration)) : 0
    }

    /// When it goes, or nil while it is held, waiting or not yet shown.
    var deadline: TimeInterval? { runningSince.map { $0 + remaining } }

    func isDue(at now: TimeInterval) -> Bool { deadline.map { now >= $0 } ?? false }
}

/// The one pending expiry for an owner's notice. It sleeps until the
/// lifetime's deadline, then hands back that event's ID; the owner checks the
/// ID and the clock before ending anything, so a stale sleep can never end a
/// newer notice. Owners reschedule after every hold change.
@MainActor
final class NoticeExpiry {
    private var task: Task<Void, Never>?
    private let clock: MonotonicClock
    /// The event and deadline it is waiting for, if any; checks read it.
    private(set) var pending: (event: UUID, deadline: TimeInterval)?

    init(clock: @escaping MonotonicClock = Monotonic.now) { self.clock = clock }
    deinit { task?.cancel() }

    func schedule(_ lifetime: NoticeLifetime?, fire: @escaping @MainActor (UUID) -> Void) {
        cancel()
        guard let lifetime, let deadline = lifetime.deadline else { return }
        let event = lifetime.event, wait = max(0, deadline - clock())
        pending = (event, deadline)
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.pending = nil
            fire(event)
        }
    }

    func cancel() { task?.cancel(); task = nil; pending = nil }
}

/// A quiet, four-second confirmation of something that actually succeeded,
/// beside the control that did it. It needs no close button or ring: it is an
/// inline label. Its owner clears only the confirmation when it is due.
struct LocalConfirmation<Kind: Equatable>: Equatable {
    static var seconds: TimeInterval { 4 }
    let kind: Kind
    private(set) var lifetime: NoticeLifetime

    init(_ kind: Kind, at now: TimeInterval) {
        self.kind = kind
        var lifetime = NoticeLifetime(duration: Self.seconds)
        lifetime.present(at: now)
        self.lifetime = lifetime
    }
}

/// What brief feedback says to VoiceOver: once, waiting for current speech
/// rather than interrupting it, so a notice that goes after a few seconds is
/// still heard.
enum FeedbackAnnouncement {
    @MainActor static func post(_ text: String) {
        // Only the running app speaks; a check or render process never does.
        guard let app = NSApp, app.isRunning else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
