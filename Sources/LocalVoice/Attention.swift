import Foundation

/// A problem Workbench reports, with the page that shows it in full beside its recovery (#134).
/// The page is chosen where the problem is raised and travels with the words, so the menu-bar
/// panel's door opens it without guessing the owner from the message later.
struct Attention: Equatable {
    enum Page: Equatable, CaseIterable {
        /// Dictation, capture and its recovery, delivery, the dictionary and the saved session.
        case dictate
        /// Preparing the speech model, whose Retry model is on Home.
        case home
        /// Removing, exporting or opening a saved transcript.
        case history

        /// The route that opens the page.
        var route: String {
            switch self {
            case .dictate: return "dictate"
            case .home: return "home"
            case .history: return "history"
            }
        }
    }
    let message: String
    let page: Page
}

/// A named door's request to show and focus one section of its page (#134). Each request is
/// new, so it applies even when the page is already showing.
struct PageFocusRequest: Equatable {
    enum Target: Equatable { case dictateOptions }
    var id = UUID()
    var target: Target
}
