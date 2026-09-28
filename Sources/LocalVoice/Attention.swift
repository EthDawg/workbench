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
        /// Removing or exporting a saved transcript.
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
    let message: String
    let page: Page
}
