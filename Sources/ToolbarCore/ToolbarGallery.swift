/// Every state the toolbar is allowed to be seen in, as fixtures.
///
/// This list is the review surface for the look, and the input to the snapshot
/// renderer. Adding a visual state means adding a case here first, so a state
/// can never ship without somebody having looked at it in light and dark.
public enum ToolbarGallery {
    /// Both tiers at every dock. At rest the toolbar is the compact mark wherever it is
    /// docked; revealed, the row grows inward from the dock, reversed on a right-hand one.
    public static let placements: [ToolbarViewState] = ToolbarAnchor.allCases.flatMap { anchor in
        ToolbarTier.allCases.map { tier in
            ToolbarViewState(name: "placement-\(anchor.slug)-\(tier.rawValue)", tier: tier, anchor: anchor, actionHint: "⌥V")
        }
    }

    /// Each mode at each tier, idle, docked at the default position. The label is the
    /// mode's start verb and the hint carries its key. At rest every idle mode is the same
    /// small mark: nothing is running, so there is nothing else to say.
    public static let modes: [ToolbarViewState] = ToolbarMode.allCases.flatMap { mode in
        ToolbarTier.allCases.map { tier in
            let action = ToolbarNextAction.resolve(ToolbarLiveState(mode: mode))
            return ToolbarViewState(name: "mode-\(mode.slug)-\(tier.rawValue)", tier: tier, mode: mode,
                                    actionTitle: action.title, actionHint: action.hint(key: exampleKey(mode)),
                                    choices: ToolbarNextAction.choices(for: ToolbarLiveState(mode: mode), key: exampleKey))
        }
    }

    static func exampleKey(_ mode: ToolbarMode) -> String? {
        switch mode {
        case .dictate: return "⌥V"
        case .snapAndTalk: return "⌥C"
        case .draw: return "⌥D"
        case .present, .persona, .read, .snap: return nil
        }
    }

    /// What the owners would report for a live state, for fixtures. The host adds what the
    /// live state cannot say: failures, pending results, unsaved captures and a Snap & Talk
    /// sequence started in this session.
    static func activity(_ live: ToolbarLiveState) -> ToolbarActivity {
        var captures: ToolbarActivity.Capture?
        if live.dictation == .recording { captures = .dictation }
        else if live.narrating { captures = .narration }
        else if live.meetingRecording { captures = .meeting }
        var running: [ToolbarActivity.Live] = []
        if live.drawing { running.append(.drawing) }
        if live.presenting { running.append(.presenting) }
        if live.persona == .shown || live.persona == .session { running.append(.persona) }
        if live.timer == .running { running.append(.timer) }
        if live.insertingPrompt { running.append(.inserting) }
        return ToolbarActivity(capture: captures, playback: live.reading == .playing,
            processing: live.dictation == .processing || live.dictation == .cancelling || live.dictation == .requesting
                || live.pendingNarration || live.reading == .preparing,
            paused: live.reading == .paused || live.timer == .paused || live.persona == .sessionHidden, live: running)
    }

    private static func live(_ live: ToolbarLiveState, name: String, tier: ToolbarTier = .revealed,
                             activity: ToolbarActivity? = nil) -> ToolbarViewState {
        let action = ToolbarNextAction.resolve(live)
        return ToolbarViewState(name: name, tier: tier, mode: live.mode, actionTitle: action.title,
                                isActionEnabled: action.isEnabled,
                                actionHint: action.hint(key: action.operation.keyMode.flatMap(exampleKey)),
                                choices: ToolbarNextAction.choices(for: live, key: exampleKey),
                                minimumTitles: ToolbarNextAction.titles(across: live),
                                isBusy: live.isLive(live.mode),
                                status: .resolve(activity ?? Self.activity(live)))
    }

    /// Work in progress. Input-consuming work takes the button whatever the
    /// mode; a mode's own ending takes it only in that mode, and elsewhere its
    /// chooser row says it is live while the start verb stays. At rest each is the
    /// compact mark, whose indicator says what is running.
    public static let activity: [ToolbarViewState] = [
        live(ToolbarLiveState(mode: .draw, drawing: true), name: "activity-drawing"),
        live(ToolbarLiveState(mode: .draw, drawing: true), name: "activity-drawing-resting", tier: .resting),
        live(ToolbarLiveState(mode: .present, presenting: true), name: "activity-presenting"),
        live(ToolbarLiveState(mode: .present, presenting: true), name: "activity-presenting-resting", tier: .resting),
        live(ToolbarLiveState(mode: .persona, persona: .session), name: "activity-personas"),
        live(ToolbarLiveState(mode: .present, presenting: true, insertingPrompt: true), name: "activity-inserting"),
        live(ToolbarLiveState(mode: .snapAndTalk, pendingNarration: true, captureCount: 3), name: "activity-transcribing"),
        // Drawing started from its key while Dictate is the mode: the label
        // follows the work, and the chooser's Draw row is lit instead.
        live(ToolbarLiveState(mode: .dictate, drawing: true), name: "activity-drawing-in-dictate"),
        live(ToolbarLiveState(mode: .dictate, drawing: true), name: "activity-drawing-in-dictate-resting", tier: .resting),
        // Switched to Draw after a presentation started: ending is Present's own, so the
        // label stays Draw and the chooser's Present row is lit instead.
        live(ToolbarLiveState(mode: .draw, presenting: true), name: "activity-presenting-in-draw"),
        live(ToolbarLiveState(mode: .draw, presenting: true), name: "activity-presenting-in-draw-resting", tier: .resting)
    ]

    /// Between steps: the count sits in the label and the key in the hint.
    public static let idle: [ToolbarViewState] = [
        live(ToolbarLiveState(mode: .snapAndTalk, captureCount: 3), name: "idle-session-open",
             activity: ToolbarActivity(live: [.snapAndTalk])),
        live(ToolbarLiveState(mode: .snapAndTalk, captureCount: 3), name: "idle-session-open-resting", tier: .resting,
             activity: ToolbarActivity(live: [.snapAndTalk])),
        live(ToolbarLiveState(mode: .dictate, mayStart: false), name: "idle-speech-preparing"),
        // A break timer whose countdown finished ("Time is up") is neither running nor paused.
        live(ToolbarLiveState(mode: .dictate, timer: .finished), name: "idle-timer-finished-resting", tier: .resting),
        live(ToolbarLiveState(mode: .dictate, canRecordAgain: true), name: "idle-record-again")
    ]

    /// Dictation, narration and reading in the same host as the tools (#134 T4). At rest each is
    /// the compact mark with its status; revealed, the row's next action is its Stop, Pause or
    /// Resume, the launcher carries the capture signal, and the rest of its commands are in More.
    public static let recording: [ToolbarViewState] = [
        live(ToolbarLiveState(mode: .dictate, dictation: .recording), name: "recording-dictation",
             activity: ToolbarActivity(capture: .dictation, level: 0.55)),
        live(ToolbarLiveState(mode: .dictate, dictation: .recording), name: "recording-dictation-resting", tier: .resting,
             activity: ToolbarActivity(capture: .dictation, level: 0.55)),
        // The last seconds before the 5-minute limit: a timer badge beside the signal.
        live(ToolbarLiveState(mode: .dictate, dictation: .recording), name: "recording-dictation-stops-soon",
             activity: ToolbarActivity(capture: .dictation, level: 0.4, stopsSoon: true)),
        live(ToolbarLiveState(mode: .dictate, dictation: .recording), name: "recording-dictation-stops-soon-resting", tier: .resting,
             activity: ToolbarActivity(capture: .dictation, level: 0.4, stopsSoon: true)),
        // Both at once: the timer beside the trace and the warning on the corner, in the launcher too (#211 F4).
        live(ToolbarLiveState(mode: .dictate, dictation: .recording), name: "recording-dictation-stops-soon-attention",
             activity: ToolbarActivity(capture: .dictation, level: 0.4, failure: true, stopsSoon: true)),
        // Dictating while Present is the tool: the recording claims the button, as everywhere.
        live(ToolbarLiveState(mode: .present, dictation: .recording, presenting: true), name: "recording-dictation-in-present",
             activity: ToolbarActivity(capture: .dictation, level: 0.3, live: [.presenting])),
        live(ToolbarLiveState(mode: .dictate, dictation: .processing), name: "recording-processing"),
        live(ToolbarLiveState(mode: .dictate, dictation: .processing), name: "recording-processing-resting", tier: .resting),
        live(ToolbarLiveState(mode: .snapAndTalk, narrating: true, captureCount: 2), name: "recording-narration",
             activity: ToolbarActivity(capture: .narration, level: 0.4, live: [.snapAndTalk])),
        live(ToolbarLiveState(mode: .read, reading: .playing), name: "reading-playing"),
        live(ToolbarLiveState(mode: .read, reading: .playing), name: "reading-playing-resting", tier: .resting),
        live(ToolbarLiveState(mode: .dictate, reading: .paused), name: "reading-paused-in-dictate")
    ]

    /// The compact rest in each indicator (#134), in priority order: capture with its level,
    /// capture in silence, capture with a job that needs attention, playback, processing,
    /// failure, a pending result, an unsaved capture, paused work and other live work.
    public static let statuses: [ToolbarViewState] = [
        ("capture", ToolbarActivity(capture: .dictation, level: 0.62)),
        ("capture-silent", ToolbarActivity(capture: .meeting)),
        ("capture-attention", ToolbarActivity(capture: .narration, level: 0.35, failure: true)),
        ("capture-stops-soon", ToolbarActivity(capture: .dictation, level: 0.5, failure: true, stopsSoon: true)),
        ("playback", ToolbarActivity(playback: true)),
        ("processing", ToolbarActivity(processing: true)),
        ("failure", ToolbarActivity(failure: true)),
        ("pending-delivery", ToolbarActivity(pendingDelivery: true)),
        ("unsaved-capture", ToolbarActivity(unsavedCapture: true)),
        ("paused", ToolbarActivity(paused: true)),
        ("live-timer", ToolbarActivity(live: [.timer])),
        ("live-persona", ToolbarActivity(live: [.persona]))
    ].map { name, activity in
        ToolbarViewState(name: "status-\(name)", tier: .resting, status: .resolve(activity))
    }

    /// The chooser, as the launcher opens it: nothing running, and Draw chosen while a
    /// presentation and personas run.
    public static let choosers: [(name: String, choices: [ToolbarToolChoice])] = [
        ("chooser-idle", ToolbarNextAction.choices(for: ToolbarLiveState(mode: .dictate), key: exampleKey)),
        ("chooser-live", ToolbarNextAction.choices(for: ToolbarLiveState(mode: .draw, presenting: true, persona: .session), key: exampleKey))
    ]

    /// Everything, in a stable order.
    public static let states: [ToolbarViewState] = placements + modes + activity + idle + recording + statuses
}
