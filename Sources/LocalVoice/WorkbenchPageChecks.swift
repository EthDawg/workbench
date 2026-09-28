import Foundation

/// The page record and its one route normaliser (#134): the sidebar is the eleven pages under
/// their Grammar names, every route that ever opened a page still lands on a highlighted sidebar
/// item, and a section opens its page on that section. Pure data; nothing is drawn.
enum WorkbenchPageChecks {
    @MainActor static func run() throws {
        var passed = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("WORKBENCH_PAGE_CHECK_FAILED: \(name)") }
            passed += 1
        }
        let pages = WorkbenchHome.navItems.map(\.id)
        try check(WorkbenchHome.navItems.map(\.title) == ["Home", "Dictate", "Read", "Snap", "Snap & Talk", "Draw", "Present", "Persona", "History", "Library", "Settings"],
                  "the sidebar is the eleven pages, in order, under their Grammar names")
        try check(Set(pages).count == pages.count, "each sidebar page has its own route")
        for page in pages { try check(WorkbenchHome.destination(page).page == page, "\(page) highlights its own item") }

        let sectioned = Set(WorkbenchHome.sections.map(\.page))
        try check(sectioned == ["library", "settings"], "Library and Settings are the pages with sections")
        for page in sectioned {
            let sections = WorkbenchHome.sections.filter { $0.page == page }
            try check(sections.first?.id == page, "\(page)'s own route opens its first section")
            try check(Set(sections.map(\.title)).count == sections.count, "\(page)'s sections have one name each")
        }
        for section in WorkbenchHome.sections {
            let landing = WorkbenchHome.destination(section.id)
            try check(landing.page == section.page && landing.section == section.id, "\(section.id) opens \(section.page) on \(section.title)")
        }

        // Routes that were pages of their own before the folds, as doors and menus still use them.
        for (route, page) in [("shortcuts", "settings"), ("models", "settings"), ("packs", "library")] {
            let landing = WorkbenchHome.destination(route)
            try check(landing.page == page && landing.section == route, "the \(route) route opens \(page) on that section")
        }
        for route in ["speak", "annotate", "present", "library"] {
            try check(WorkbenchHome.destination(route).page == route, "\(route) still opens its renamed page")
        }
        for route in ["dictionary", "meeting"] {
            let landing = WorkbenchHome.destination(route)
            try check(landing.page == "dictate" && landing.section == nil, "\(route) keeps its page with Dictate highlighted")
        }
        try check(WorkbenchHome.destination("surface-gallery-unknown-route").page == "dictate",
                  "an unknown route shows Dictate with Dictate highlighted, as the page switch does")
        for route in pages + WorkbenchHome.sections.map(\.id) + WorkbenchHome.subpages.map(\.id) {
            try check(pages.contains(WorkbenchHome.destination(route).page), "\(route) lands on a sidebar page")
        }

        // Home's photo arrival cue opens From iPhone by its own route, and nothing else holds the
        // section, so the Library doors that follow it (the Library shortcut, Window › Library, the
        // sidebar item and Switch to › Set up, all "library") open Resources. The cue used to open
        // "library" with a separate flag those doors never cleared (#198 review).
        let cue = WorkbenchHome.destination(WorkbenchHome.photoArrivals)
        try check(cue.page == "library" && cue.section == "photos", "Home's photo cue opens Library on From iPhone by its own route")
        try check(WorkbenchHome.photoArrivals != "library", "the photo cue does not share the Library doors' route")
        for route in [WorkbenchHome.navItems.first { $0.title == "Library" }?.id ?? "", "library"] {
            let landing = WorkbenchHome.destination(route)
            try check(landing.page == "library" && landing.section == "library", "after the photo cue, a Library door (\(route)) opens Resources")
        }

        try check(WorkbenchHome.name(of: "settings") == "Settings" && WorkbenchHome.name(of: "library") == "Library",
                  "a page's own name wins over its first section's")
        try check(WorkbenchHome.name(of: "shortcuts") == "Keyboard" && WorkbenchHome.name(of: "models") == "Models" && WorkbenchHome.name(of: "packs") == "Packs",
                  "sections are named by the record")
        try check(WorkbenchHome.name(of: "meeting") == "Transcribe meeting or call", "the meeting page keeps its Grammar workflow name")
        // The menu-bar panel's recovery says one sentence and opens the page that says the rest.
        try check(PanelRecoveryRow.headline("Microphone access is off. Open System Settings → Privacy & Security → Microphone and allow Workbench.") == "Microphone access is off.",
                  "a recovery row keeps only the first sentence")
        try check(PanelRecoveryRow.headline("Preparing speech · first setup may take a few minutes") == "Preparing speech · first setup may take a few minutes",
                  "a one-sentence message is shown whole")
        print("WORKBENCH_PAGE_CHECKS_OK: \(passed) checks; \(pages.count) sidebar pages, \(WorkbenchHome.sections.count) sections and every older route")
    }
}
