import AppKit

/// What the floating surface says for a moment after a dictation ends without
/// words: silence, a tap too short to hold speech, a sound that was not speech,
/// or speech that came back as no words. That is routine, not a fault, so it is
/// a brief cue in place of the recording controls rather than the recovery
/// panel, which failures keep (#156).
struct CaptureCue: Identifiable, Equatable {
    enum Reason: Equatable {
        /// Shorter than a syllable, like an accidental tap. Nothing is kept.
        case tooShort
        /// Nothing above the microphone's quiet floor. Nothing is kept.
        case tooQuiet
        /// The engine returned no words. A recording of our own is kept for Retry.
        case nothingRecognised(keptAudio: Bool)
    }
    let id = UUID()
    let reason: Reason
    /// A recording shorter than this cannot hold a word, so it is too short.
    static let shortestSpeech: TimeInterval = 0.35
    /// The cue's words, on the surface and for VoiceOver alike.
    static let message = "No speech heard"
    var message: String { Self.message }
    /// One short line under the words, only where it helps.
    var hint: String {
        switch reason {
        case .tooShort, .nothingRecognised(keptAudio: false): return "Nothing was added."
        case .tooQuiet: return "Check the microphone if you spoke."
        case .nothingRecognised(keptAudio: true): return "Recording kept on the Dictate page."
        }
    }
    /// The window's status line, which has room to say a little more.
    var status: String {
        switch reason {
        case .tooShort: return "No speech heard. Nothing was added."
        case .tooQuiet: return "No speech heard. Nothing was added. If you spoke, check Sound → Input; on a MacBook, open the lid."
        case .nothingRecognised(keptAudio: false): return "No speech heard. Nothing was added."
        case .nothingRecognised(keptAudio: true): return "No speech heard. The recording is kept here if you want to retry it."
        }
    }
}

/// How long a cue on the floating surface lasts. A routine cue goes after
/// `routineSeconds` of time the person is not holding it: hovering it or
/// focusing it with VoiceOver pauses the count, and letting go resumes it.
/// A technical cue never expires; the person acts on it or dismisses it.
/// Pure, so a check can walk it without a clock or a window.
struct CaptureCueClock: Equatable {
    static let routineSeconds: TimeInterval = 1.6
    let routine: Bool
    private(set) var remaining: TimeInterval
    /// When the current unheld stretch began; nil while held or technical.
    private(set) var runningSince: Date?

    init(routine: Bool, shownAt now: Date) {
        self.routine = routine
        remaining = routine ? Self.routineSeconds : .infinity
        runningSince = routine ? now : nil
    }

    var isHeld: Bool { routine && runningSince == nil }

    mutating func hold(_ held: Bool, at now: Date) {
        guard routine else { return }
        if held, let started = runningSince {
            remaining = max(0, remaining - now.timeIntervalSince(started))
            runningSince = nil
        } else if !held, runningSince == nil {
            runningSince = now
        }
    }

    /// When the cue goes, or nil while it is held or technical.
    var deadline: Date? { runningSince.map { $0.addingTimeInterval(remaining) } }

    func isExpired(at now: Date) -> Bool { deadline.map { now >= $0 } ?? false }
}

enum CaptureCueAnnouncement {
    /// VoiceOver says the words once, whatever has focus.
    @MainActor static func post(_ text: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
