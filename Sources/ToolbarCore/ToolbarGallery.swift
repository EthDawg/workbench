/// Every state the toolbar is allowed to be seen in, as fixtures.
///
/// This list is the review surface for the look, and the input to the snapshot
/// renderer. Adding a visual state means adding a case here first, so a state
/// can never ship without somebody having looked at it in light and dark.
public enum ToolbarGallery {
    /// Both tiers at every dock. Resting is a glyph, so the docks differ only in
    /// which way the revealed row grows.
    public static let placements: [ToolbarViewState] = ToolbarAnchor.allCases.flatMap { anchor in
        ToolbarTier.allCases.map { tier in
            ToolbarViewState(name: "placement-\(anchor.slug)-\(tier.rawValue)", tier: tier, anchor: anchor)
        }
    }

    /// Each tool at each tier, docked at the default position.
    public static let tools: [ToolbarViewState] = ToolbarTool.allCases.flatMap { tool in
        ToolbarTier.allCases.map { tier in
            ToolbarViewState(name: "tool-\(tool.slug)-\(tier.rawValue)", tier: tier, tool: tool,
                             trailing: .shortcut(exampleShortcut(tool)))
        }
    }

    private static func exampleShortcut(_ tool: ToolbarTool) -> ToolbarShortcut {
        switch tool {
        case .dictate: return .assigned("⌃⌥Space")
        case .snapAndTalk: return .assigned("⌃⌥\\")
        case .annotate: return .assigned("⌃⌥D")
        case .present, .read: return .off
        }
    }

    /// A binding that is not usable must not look usable.
    public static let bindings: [ToolbarViewState] = [
        ToolbarViewState(name: "binding-off", tier: .revealed, trailing: .shortcut(.off)),
        ToolbarViewState(name: "binding-unavailable", tier: .revealed, trailing: .shortcut(.unavailable))
    ]

    /// Work in progress. The one button becomes the finish action, the trailing
    /// slot carries the status instead of a key, and the resting glyph lights.
    public static let activity: [ToolbarViewState] = [
        ToolbarViewState(name: "activity-drawing", tier: .revealed, tool: .annotate,
                         actionTitle: "Done drawing", trailing: .status("Drawing"), isBusy: true),
        ToolbarViewState(name: "activity-drawing-resting", tier: .resting, tool: .annotate, isBusy: true),
        ToolbarViewState(name: "activity-presenting", tier: .revealed, tool: .present,
                         actionTitle: "End scene", trailing: .status("Right display"), isBusy: true),
        ToolbarViewState(name: "activity-transcribing", tier: .revealed, tool: .snapAndTalk,
                         actionTitle: "Capture next", trailing: .status("Transcribing 2 of 3"), isBusy: true),
        ToolbarViewState(name: "activity-reading", tier: .revealed, tool: .read,
                         actionTitle: "Stop reading", trailing: .status("Ava"), isBusy: true)
    ]

    /// Waiting between captures and preparing speech are idle. Keep the key
    /// discoverable; session counts and availability explanations live in help/menu.
    public static let idle: [ToolbarViewState] = [
        ToolbarViewState(name: "idle-session-open", tier: .revealed, tool: .snapAndTalk,
                         actionTitle: "Capture next", trailing: .shortcut(.assigned("⌃⌥\\"))),
        ToolbarViewState(name: "idle-speech-preparing", tier: .revealed, tool: .dictate,
                         isActionEnabled: false, trailing: .shortcut(.assigned("⌃⌥Space")))
    ]

    /// Everything, in a stable order.
    public static let states: [ToolbarViewState] = placements + tools + bindings + activity + idle
}
