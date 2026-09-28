import AppKit
import Foundation

// Brief feedback that teaches once and leaves work intact (#134 T5).

/// Lessons Workbench has taught, by semantic ID, in this edition's own
/// preferences. An ID names the lesson, never a key, so relaunch, upgrade and
/// rebinding keep it. There is no setting to change this, and nothing is sent.
final class CoachTips {
    static let key = "workbench.coachTips.retired.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func isRetired(_ id: String) -> Bool { (defaults.stringArray(forKey: Self.key) ?? []).contains(id) }

    func retire(_ id: String) {
        var retired = defaults.stringArray(forKey: Self.key) ?? []
        guard !retired.contains(id) else { return }
        retired.append(id)
        defaults.set(retired, forKey: Self.key)
    }
}

/// One press of the global Dictate shortcut in Hold, timed by the native key
/// events' own timestamps (NSEvent and Carbon both count seconds since the Mac
/// started), tied to the attempt it began. A repeat never moves the press.
struct HoldGesture: Equatable {
    let attempt: UUID
    let pressedAt: TimeInterval
    private(set) var releasedAt: TimeInterval?

    init(attempt: UUID, pressedAt: TimeInterval) { self.attempt = attempt; self.pressedAt = pressedAt }

    mutating func release(at time: TimeInterval) { if releasedAt == nil { releasedAt = max(pressedAt, time) } }

    /// Key-down to key-up, or nil while the key is still down.
    var interval: TimeInterval? { releasedAt.map { $0 - pressedAt } }
}

/// The first automatic lesson: a press of the Dictate shortcut in Hold that
/// was let go too soon.
enum HoldLesson {
    static let tip = "dictate.holdGesture"
    static let body = "Keep holding while you speak. Release to finish."

    /// Only a press of the global shortcut in Hold whose recorder started, let
    /// go before the shortest speech a capture keeps, and ending too short.
    /// The gesture exists only for a shortcut press in Hold that began this
    /// attempt, so Toggle, a click, a failed start or a cancel never teach; a
    /// slow start is judged by the key, not the audio.
    static func teaches(_ gesture: HoldGesture?, outcome: CaptureCue.Reason) -> Bool {
        guard case .tooShort = outcome, let interval = gesture?.interval else { return false }
        return interval < CaptureCue.shortestSpeech
    }

    /// The saved binding, as the person set it; never a hardcoded key.
    static func title(shortcut: String) -> String { "Hold \(shortcut) to dictate." }

    static func card(shortcut: String) -> FeedbackCoachModel.Card {
        .init(tip: tip, symbol: "keyboard", title: title(shortcut: shortcut), body: body)
    }
}

/// The one coaching card. At most one exists. It is requested by the owner of
/// the gesture it corrects, shown by the host that owns the floating control,
/// and timed here, on one lifetime, for both its ring and its expiry.
///
/// The host seam: set `canPresent`; when `card` is set and not yet presented,
/// show `CoachCardView` and then call `didPresent(_:)` once it is really on
/// screen, or `drop(_:)` if it cannot be shown, which gives the owner's own
/// feedback instead. Call `remove()` on screen capture and when another
/// capture starts. The owner itself removes it on sleep, lock and a new
/// dictation.
@MainActor
final class FeedbackCoachModel: ObservableObject {
    struct Card: Identifiable, Equatable {
        let id = UUID()
        /// The semantic lesson it teaches, retired once it is seen.
        let tip: String
        let symbol: String
        let title: String
        let body: String
    }
    static let seconds: TimeInterval = 4

    @Published private(set) var card: Card?
    @Published private(set) var lifetime: NoticeLifetime?
    var isPresented: Bool { lifetime?.isPresented == true }

    /// The host's answer to "may a card show now?". Nil until a host renders
    /// coaches, so a lesson is never spent while nobody can see it.
    var canPresent: (() -> Bool)?
    let tips: CoachTips
    let clock: MonotonicClock
    var voiceOverEnabled: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }
    var announce: (String) -> Void = { FeedbackAnnouncement.post($0) }
    private let expiry: NoticeExpiry
    /// What the owner shows if the host drops the pending card.
    private var fallback: (() -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(tips: CoachTips = CoachTips(), clock: @escaping MonotonicClock = Monotonic.now,
         workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         distributed: NotificationCenter = DistributedNotificationCenter.default()) {
        self.tips = tips
        self.clock = clock
        expiry = NoticeExpiry(clock: clock)
        // Sleep, a locked or switched-away session, or screens going dark take it down.
        for (center, name) in [(workspace, NSWorkspace.willSleepNotification), (workspace, NSWorkspace.screensDidSleepNotification),
                               (workspace, NSWorkspace.sessionDidResignActiveNotification),
                               (distributed, Notification.Name("com.apple.screenIsLocked"))] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.remove() }
            }
            observers.append((center, token))
        }
    }

    deinit { for (center, token) in observers { center.removeObserver(token) } }

    /// Offers a lesson that has not been taught. False when it cannot show
    /// now: already learned, or no host can show it. Nothing is queued, and a
    /// lesson that was not shown is not spent. `otherwise` runs if the host
    /// then drops it, so the owner can give the feedback it replaced.
    @discardableResult
    func request(_ card: Card, otherwise: (() -> Void)? = nil) -> Bool {
        guard !tips.isRetired(card.tip), canPresent?() == true else { return false }
        remove()
        self.card = card
        fallback = otherwise
        lifetime = NoticeLifetime(event: card.id, duration: Self.seconds, waitsForDismissal: voiceOverEnabled())
        return true
    }

    /// The host has the card on screen. Its four seconds start now, the lesson
    /// is spent, and VoiceOver hears it once. Calling again changes nothing.
    func didPresent(_ id: UUID) {
        guard let card, card.id == id, var lifetime, !lifetime.isPresented else { return }
        fallback = nil
        lifetime.present(at: clock())
        self.lifetime = lifetime
        tips.retire(card.tip)
        announce(card.title + " " + card.body)
        scheduleExpiry()
    }

    /// The host could not show it. It is dropped, never queued, and the
    /// lesson stays for the next gesture that qualifies. The owner's own
    /// feedback for that gesture shows instead.
    func drop(_ id: UUID) {
        guard card?.id == id, lifetime?.isPresented != true else { return }
        let fallback = fallback
        clear()
        fallback?()
    }

    func hold(_ hold: NoticeLifetime.Hold, _ held: Bool, for id: UUID) {
        guard card?.id == id, var lifetime else { return }
        lifetime.hold(hold, held, at: clock())
        guard lifetime != self.lifetime else { return }
        self.lifetime = lifetime
        scheduleExpiry()
    }

    /// × or Escape: only this card goes.
    func dismiss(_ id: UUID) {
        guard card?.id == id else { return }
        clear()
    }

    /// Another capture, screen capture, sleep, lock or teardown.
    func remove() { clear() }

    /// Ends the card only if it is still this event and it is due.
    func expire(_ event: UUID) {
        guard let lifetime, lifetime.event == event else { return }
        if lifetime.isDue(at: clock()) { clear() } else { scheduleExpiry() }
    }

    private func scheduleExpiry() {
        expiry.schedule(lifetime) { [weak self] event in self?.expire(event) }
    }

    private func clear() {
        expiry.cancel()
        fallback = nil
        if card != nil { card = nil }
        if lifetime != nil { lifetime = nil }
    }
}
