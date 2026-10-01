import Foundation

/// A problem Workbench reports, with the page that shows it in full beside its recovery (#134).
/// The page is chosen where the problem is raised and travels with the words, so the menu-bar
/// panel's door opens it without guessing the owner from the message later.
struct Attention: Equatable {
    enum Page: Equatable, CaseIterable {
        /// Dictation, capture and its recovery, delivery, the dictionary and the saved session.
        case dictate
        /// Reading aloud: its text, voice, provider and audio.
        case read
        /// Preparing the speech model, whose Retry model is on Home.
        case home
        /// Removing, exporting or opening a saved transcript.
        case history

        /// The route that opens the page.
        var route: String {
            switch self {
            case .dictate: return "dictate"
            case .read: return "speak"
            case .home: return "home"
            case .history: return "history"
            }
        }
    }
    /// A control that shows its own problem beside itself, as well as on its page (#173).
    enum Origin: Equatable {
        /// Home's Read tile refused copied text its provider cannot read.
        case homeReadTileRefused
        /// Home's Read tile waited for a meeting that was recording or transcribing.
        case homeReadTileMeeting
    }
    let message: String
    let page: Page
    /// Set only by the control that raised the problem. The next problem, or clearing, replaces
    /// the slot and this with it.
    var origin: Origin? = nil

    /// What Home shows under its Read tile: the tile's own problem while it is the one in the
    /// slot, never another door's, and its meeting wait only while a meeting still runs. Read's
    /// banner and the menu-bar panel show every problem.
    static func besideHomeReadTile(_ attention: Attention?, meetingBusy: Bool) -> String? {
        guard let attention, let origin = attention.origin else { return nil }
        switch origin {
        case .homeReadTileRefused: return attention.message
        case .homeReadTileMeeting: return meetingBusy ? attention.message : nil
        }
    }
}

/// A named door's request to show and focus one section of its page (#134). Each request is
/// new, so it applies even when the page is already showing.
struct PageFocusRequest: Equatable {
    enum Target: Equatable { case dictateOptions }
    var id = UUID()
    var target: Target
}
