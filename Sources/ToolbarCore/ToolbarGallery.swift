/// Every state the toolbar is allowed to be seen in, as fixtures.
///
/// This list is the review surface for the look, and the input to the snapshot
/// renderer. Adding a visual state means adding a case here first, so a state
/// can never ship without somebody having looked at it in light and dark.
public enum ToolbarGallery {
    /// Both tiers at every dock. Resting is one element, so the docks differ
    /// only in which way the revealed row grows.
    public static let placements: [ToolbarViewState] = ToolbarAnchor.allCases.flatMap { anchor in
        ToolbarTier.allCases.map { tier in
            ToolbarViewState(name: "placement-\(anchor.slug)-\(tier.rawValue)", tier: tier, anchor: anchor, actionHint: "⌥V")
        }
    }

    /// Each mode at each tier, idle, docked at the default position. The label
    /// is the mode's start verb and the hint carries its key.
    public static let modes: [ToolbarViewState] = ToolbarMode.allCases.flatMap { mode in
        ToolbarTier.allCases.map { tier in
            let action = ToolbarNextAction.resolve(ToolbarLiveState(mode: mode))
            return ToolbarViewState(name: "mode-\(mode.slug)-\(tier.rawValue)", tier: tier, mode: mode,
                                    actionTitle: action.title, actionHint: action.hint(key: exampleKey(mode)),
                                    switcher: ToolbarNextAction.switcher(for: ToolbarLiveState(mode: mode), key: exampleKey))
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

    private static func live(_ live: ToolbarLiveState, name: String, tier: ToolbarTier = .revealed) -> ToolbarViewState {
        let action = ToolbarNextAction.resolve(live)
        return ToolbarViewState(name: name, tier: tier, mode: live.mode, actionTitle: action.title,
                                isActionEnabled: action.isEnabled,
                                actionHint: action.hint(key: exampleKey(action.operation.mode ?? live.mode)),
                                switcher: ToolbarNextAction.switcher(for: live, key: exampleKey),
                                isBusy: live.isLive(live.mode))
    }

    /// Work in progress. The one button becomes the finish action and the glyph
    /// of the mode whose work it is lights, wherever it sits.
    public static let activity: [ToolbarViewState] = [
        live(ToolbarLiveState(mode: .draw, drawing: true), name: "activity-drawing"),
        live(ToolbarLiveState(mode: .draw, drawing: true), name: "activity-drawing-resting", tier: .resting),
        live(ToolbarLiveState(mode: .present, presenting: true), name: "activity-presenting"),
        live(ToolbarLiveState(mode: .present, presenting: true), name: "activity-presenting-resting", tier: .resting),
        live(ToolbarLiveState(mode: .persona, persona: .session), name: "activity-personas"),
        live(ToolbarLiveState(mode: .present, presenting: true, insertingPrompt: true), name: "activity-inserting"),
        live(ToolbarLiveState(mode: .snapAndTalk, pendingNarration: true, captureCount: 3), name: "activity-transcribing"),
        // Drawing started from its key while Dictate is the mode: the label
        // follows the work, and the Draw chip lights instead of the glyph.
        live(ToolbarLiveState(mode: .dictate, drawing: true), name: "activity-drawing-in-dictate"),
        live(ToolbarLiveState(mode: .dictate, drawing: true), name: "activity-drawing-in-dictate-resting", tier: .resting)
    ]

    /// Between steps: the count sits in the label and the key in the hint.
    public static let idle: [ToolbarViewState] = [
        live(ToolbarLiveState(mode: .snapAndTalk, captureCount: 3), name: "idle-session-open"),
        live(ToolbarLiveState(mode: .snapAndTalk, captureCount: 3), name: "idle-session-open-resting", tier: .resting),
        live(ToolbarLiveState(mode: .dictate, mayStart: false), name: "idle-speech-preparing"),
        live(ToolbarLiveState(mode: .dictate, canRecordAgain: true), name: "idle-record-again")
    ]

    /// Everything, in a stable order.
    public static let states: [ToolbarViewState] = placements + modes + activity + idle
}
