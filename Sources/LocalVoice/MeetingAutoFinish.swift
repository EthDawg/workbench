import Foundation

/// Call activity is process metadata, never an inference from silent samples.
/// Unknown observations and audio-route recovery revoke a pending finish.
struct MeetingAutoFinish {
    enum Activity { case active, inactive, unknown }
    private var observedActive = false
    private var inactiveSince: TimeInterval?
    private var keptOpen = false
    var inactivityDelay: TimeInterval = 20
    var grace: TimeInterval = 10

    mutating func keepRecording() { keptOpen = true; inactiveSince = nil }

    /// A non-nil value is a visible countdown; zero authorizes this session's
    /// normal Finish path. Pause/reconnect require fresh active-call evidence.
    mutating func observe(_ activity: Activity, now: TimeInterval, suspended: Bool) -> Int? {
        guard !keptOpen else { return nil }
        guard !suspended else { observedActive = false; inactiveSince = nil; return nil }
        switch activity {
        case .active: observedActive = true; inactiveSince = nil; return nil
        case .unknown: observedActive = false; inactiveSince = nil; return nil
        case .inactive:
            guard observedActive else { return nil }
            if inactiveSince == nil { inactiveSince = now }
            let quietFor = max(0, now - inactiveSince!)
            guard quietFor >= inactivityDelay else { return nil }
            return max(0, Int(ceil(inactivityDelay + grace - quietFor)))
        }
    }
}

enum MeetingFollowUp {
    /// The existing reviewed handoff interprets the transcript as evidence and
    /// proposes next steps. A keyword guess never becomes a claimed decision.
    static let task = """
    Review this meeting or call and prepare the most useful next step. Start with a short account of its purpose and outcome, grounded in the transcript. Separate agreed decisions, explicit commitments, open questions and optional suggestions. For actions, include an owner and due date only when the speakers actually stated them; otherwise mark them unassigned or unspecified. Quote the brief supporting words for each commitment. Then draft the one most useful follow-up (for example a message, checklist or next-meeting agenda) when the conversation supports it. If the call was social or has no follow-up, say so rather than inventing tasks. Do not infer identities from You/Others. Do not send, schedule or change anything. Return drafts for review.
    """
}
