import Foundation
import ToolbarCore
import StageKit

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
        try check(WorkbenchHome.navItems.map(\.title) == ["Home", "Dictate", "Meetings", "Read", "Snap", "Snap & Talk", "Draw", "Present", "Persona", "History", "Library", "Settings"],
                  "the sidebar includes Meetings beside Dictate under the shared page names")
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
        for route in ["dictionary"] {
            let landing = WorkbenchHome.destination(route)
            try check(landing.page == "dictate" && landing.section == nil, "\(route) keeps its page with Dictate highlighted")
        }
        try check(WorkbenchHome.destination("surface-gallery-unknown-route").page == "dictate",
                  "an unknown route shows Dictate with Dictate highlighted, as the page switch does")
        for route in pages + WorkbenchHome.sections.map(\.id) + WorkbenchHome.subpages.map(\.id) {
            try check(pages.contains(WorkbenchHome.destination(route).page), "\(route) lands on a sidebar page")
        }

        // From iPhone left Library with the iPhone photo sync's other doors (#276). Its route is
        // retired, not forgotten: it opens Library on Resources, as every Library door (the Library
        // shortcut, Window › Library, the sidebar item and Switch to › Set up, all "library") does,
        // rather than falling through to Dictate.
        try check(!WorkbenchHome.sections.contains { $0.id == "photos" || $0.title == "From iPhone" }, "Library has no From iPhone section")
        let retired = WorkbenchHome.destination("photos")
        try check(retired.page == "library" && retired.section == "library", "the retired From iPhone route opens Library on Resources")
        for (route, replacement) in WorkbenchHome.retiredRoutes {
            try check(!(pages + WorkbenchHome.sections.map(\.id) + WorkbenchHome.subpages.map(\.id)).contains(route),
                      "the retired route \(route) is not also a live page, section or subpage")
            try check(WorkbenchHome.destination(route) == WorkbenchHome.destination(replacement), "the retired route \(route) lands where \(replacement) does")
        }
        for route in [WorkbenchHome.navItems.first { $0.title == "Library" }?.id ?? "", "library"] {
            let landing = WorkbenchHome.destination(route)
            try check(landing.page == "library" && landing.section == "library", "a Library door (\(route)) opens Resources")
        }

        try check(WorkbenchHome.name(of: "settings") == "Settings" && WorkbenchHome.name(of: "library") == "Library",
                  "a page's own name wins over its first section's")
        try check(WorkbenchHome.name(of: "shortcuts") == "Keyboard" && WorkbenchHome.name(of: "models") == "Models" && WorkbenchHome.name(of: "packs") == "Packs",
                  "sections are named by the record")
        try check(WorkbenchHome.name(of: "meeting") == "Meetings" && WorkbenchHome.destination("meeting").page == "meeting", "meeting doors open a visible Meetings page with its own sidebar item")
        // One identity on all three surfaces (#134 C10): each capability's page in the sidebar, its
        // toolbar mode and its menu-bar panel row carry the same name and symbol, and the mode's
        // page door opens that page. Timer is a panel row and a Present option, never a page.
        for mode in ToolbarMode.allCases {
            let item = WorkbenchHome.navItems.first { $0.id == mode.page }
            try check(item?.title == mode.title && item?.symbol == mode.symbol, "\(mode.title)'s sidebar page has the toolbar's name and symbol")
            let row = WorkbenchControlTool(mode: mode)
            try check(row?.title == mode.title && row?.symbol == mode.symbol, "\(mode.title)'s panel row has the toolbar's name and symbol")
            try check(WorkbenchHome.destination(mode.page).page == mode.page, "\(mode.title)'s page door opens its highlighted page")
            try check(WorkbenchHome.symbol(of: mode.page) == mode.symbol, "\(mode.title)'s page shows the toolbar's symbol wherever the record is read")
        }
        try check(WorkbenchHome.symbol(of: "dictionary") == WorkbenchHome.symbol(of: "dictate") && WorkbenchHome.symbol(of: "packs") == WorkbenchHome.symbol(of: "library"),
                  "a subpage or section shows its page's symbol")
        // The panel's door opens the page recorded with the problem where it was raised, never one
        // read from its words (#134 review): each page lands where that problem is shown and fixed.
        for (page, route, section) in [(Attention.Page.dictate, "dictate", nil), (.read, "speak", nil), (.home, "home", nil), (.history, "history", nil)] as [(Attention.Page, String, String?)] {
            let landing = WorkbenchHome.destination(page.route)
            try check(page.route == route && landing.page == route && landing.section == section, "a Voice problem owned by \(page) opens \(route)")
        }
        try check(Set(Attention.Page.allCases.map(\.route)).count == Attention.Page.allCases.count, "each Voice owner has its own page")
        for (page, route, section) in [(StageNoticePage.draw, "annotate", nil), (.present, "present", nil), (.persona, "personas", nil),
                                       (.keyboard, "settings", "shortcuts"), (.general, "settings", "settings")] as [(StageNoticePage, String, String?)] {
            let landing = WorkbenchHome.destination(page.route)
            try check(landing.page == route && landing.section == section, "a StageKit notice owned by \(page) opens \(route)\(section.map { " on " + $0 } ?? "")")
        }
        try check(Set(StageNoticePage.allCases.map(\.route)).count == StageNoticePage.allCases.count, "each StageKit owner has its own page or section")
        // Groups remain shallow: every capability and saved place occurs once, in sidebar order.
        let listed = pages.filter { $0 != WorkbenchHome.pinnedPage && $0 != "home" }
        try check(pages.last == WorkbenchHome.pinnedPage && WorkbenchHome.pinnedPage == "settings",
                  "Settings stays pinned below navigation")
        try check(WorkbenchHome.sidebarGroups.map(\.title) == ["Voice", "Screen", "Saved"], "the desktop groups explain voice, screen and saved work")
        let grouped = WorkbenchHome.sidebarGroups.flatMap(\.routes)
        try check(grouped == listed && Set(grouped).count == grouped.count, "groups cover each workspace once in navigation order")
        try check(WorkbenchHome.sidebarGroups.first?.routes == ["dictate", "meeting", "speak"], "Meetings is visible next to Dictate and Read")
        // The floating toolbar's one switch reads the same everywhere (#134 H3).
        try check(WorkbenchHome.floatingToolbarHelp == "Show between actions. Recording and recovery controls still appear when needed.",
                  "the switch explains itself in the contract's words")
        try check(AppDelegate.floatingToolbarTitle(visible: true) == "Hide floating toolbar" && AppDelegate.floatingToolbarTitle(visible: false) == "Show floating toolbar",
                  "the Window menu names what its item will do")
        // Named doors land on their section (#134 H2): Keyboard… on Settings › Keyboard.
        let keyboard = WorkbenchHome.destination("shortcuts")
        try check(keyboard.page == "settings" && keyboard.section == "shortcuts", "Keyboard… opens Settings on Keyboard")
        // The menu-bar panel's recovery says one sentence and opens the page that says the rest.
        try check(PanelRecoveryRow.headline("Microphone access is off. Open System Settings › Privacy & Security › Microphone and allow Workbench.") == "Microphone access is off.",
                  "a recovery row keeps only the first sentence")
        try check(PanelRecoveryRow.headline("Preparing speech · first setup may take a few minutes") == "Preparing speech · first setup may take a few minutes",
                  "a one-sentence message is shown whole")
        try check(WorkbenchControlTool.allCases.compactMap(\.mode) == ToolbarMode.allCases, "the panel's rows follow the toolbar's modes in moment order")
        try check(WorkbenchControlTool.timer.mode == nil && !WorkbenchHome.navItems.contains { $0.title == WorkbenchControlTool.timer.title },
                  "Timer is a panel row, not a page")
        print("WORKBENCH_PAGE_CHECKS_OK: \(passed) checks; \(pages.count) sidebar pages, \(WorkbenchHome.sections.count) sections, every older route and one name and symbol per capability")
    }
}
