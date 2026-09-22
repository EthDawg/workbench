/// Every state the toolbar is allowed to be seen in, as fixtures.
///
/// This list is the review surface for the look, and the input to the snapshot
/// renderer. Adding a visual state means adding a case here first, so a state
/// can never ship without somebody having looked at it in light and dark.
public enum ToolbarGallery {
    /// The three tiers at every dock, for one ordinary idle tool.
    public static let placements: [ToolbarViewState] = ToolbarAnchor.allCases.flatMap { anchor in
        ToolbarTier.allCases.map { tier in
            ToolbarViewState(name: "placement-\(anchor.slug)-\(tier.rawValue)", tier: tier, anchor: anchor)
        }
    }

    /// Each tool at each tier, docked at the default position.
    public static let tools: [ToolbarViewState] = ToolbarTool.allCases.flatMap { tool in
        ToolbarTier.allCases.map { tier in
            ToolbarViewState(name: "tool-\(tool.slug)-\(tier.rawValue)", tier: tier, tool: tool,
                             shortcut: tool == .read ? .off : .assigned("⌃⌥Space"),
                             detail: tool.title + " · ready")
        }
    }

    /// Bindings that are not usable must not look usable.
    public static let bindings: [ToolbarViewState] = [
        ToolbarViewState(name: "binding-off", tier: .peeking, shortcut: .off),
        ToolbarViewState(name: "binding-unavailable", tier: .peeking, shortcut: .unavailable),
        ToolbarViewState(name: "binding-off-pinned", tier: .pinned, shortcut: .off),
        ToolbarViewState(name: "binding-unavailable-pinned", tier: .pinned, shortcut: .unavailable)
    ]

    /// Work in progress: the primary button becomes the finish action, and a
    /// tool that cannot start right now says so instead of looking clickable.
    public static let activity: [ToolbarViewState] = [
        ToolbarViewState(name: "activity-drawing", tier: .pinned, tool: .annotate,
                         actionTitle: "Done drawing", status: "Drawing",
                         detail: "Keeps marks and releases input"),
        ToolbarViewState(name: "activity-presenting", tier: .peeking, tool: .present,
                         actionTitle: "End scene", status: "Presenting",
                         detail: "Device scene on the right display"),
        ToolbarViewState(name: "activity-captures", tier: .pinned, tool: .snapAndTalk,
                         actionTitle: "Capture next", shortcut: .assigned("⌃⌥\\"),
                         status: "3 captures", detail: "Adds to today's session"),
        ToolbarViewState(name: "activity-reading", tier: .peeking, tool: .read,
                         actionTitle: "Stop reading", shortcut: .off,
                         status: "Reading", detail: "Mac voice · Ava"),
        ToolbarViewState(name: "activity-unavailable", tier: .pinned, tool: .dictate,
                         actionTitle: "Dictate", isActionEnabled: false,
                         status: "Narration has the microphone",
                         detail: "Finish narration to dictate"),
        ToolbarViewState(name: "activity-long-status", tier: .pinned, tool: .snapAndTalk,
                         actionTitle: "Capture next", shortcut: .assigned("⌃⌥\\"),
                         status: "Transcribing 2 of 3",
                         detail: "Narration is still transcribing in the background")
    ]

    /// Everything, in a stable order.
    public static let states: [ToolbarViewState] = placements + tools + bindings + activity
}
