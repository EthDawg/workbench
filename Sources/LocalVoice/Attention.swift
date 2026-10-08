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
    /// A typed problem code for Report a problem (#296), chosen where the problem is raised. It is
    /// never read from the message; a raise without one names only its page.
    var code: String

    init(message: String, page: Page, code: String? = nil) {
        self.message = message; self.page = page
        // The manifest's error_code pattern; this file is also compiled alone by scripts/test-clean-draft.py.
        let valid = code.flatMap { $0.range(of: "^[a-z][a-z0-9_.]{0,63}$", options: .regularExpression) != nil ? $0 : nil }
        self.code = valid ?? "\(page.route).problem"
    }
}

/// A named door's request to show and focus one section of its page (#134). Each request is
/// new, so it applies even when the page is already showing.
struct PageFocusRequest: Equatable {
    enum Target: Equatable {
        case dictateOptions
        /// My Profile's editor, from Persona's My Profile… where no profile photo is saved yet.
        case profile
    }
    var id = UUID()
    var target: Target
}
