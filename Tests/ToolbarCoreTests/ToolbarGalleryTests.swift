import XCTest
@testable import ToolbarCore

/// The gallery is the review surface for the look. These checks keep it honest:
/// a visual state that is not in here has never been looked at in both themes.
final class ToolbarGalleryTests: XCTestCase {
    func testEveryFixtureHasAUniqueStableName() {
        let names = ToolbarGallery.states.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        // These become snapshot filenames, and the disk is case-insensitive.
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for name in names {
            XCTAssertFalse(name.isEmpty)
            XCTAssertTrue(name.unicodeScalars.allSatisfy(safe.contains), name)
        }
    }

    func testSlugsStayUniqueOnACaseInsensitiveDisk() {
        XCTAssertEqual(Set(ToolbarMode.allCases.map(\.slug)).count, ToolbarMode.allCases.count)
        XCTAssertEqual(Set(ToolbarAnchor.allCases.map(\.slug)).count, ToolbarAnchor.allCases.count)
    }

    func testEveryTierDockAndModeIsRepresented() {
        XCTAssertEqual(Set(ToolbarGallery.states.map(\.tier)), Set(ToolbarTier.allCases))
        XCTAssertEqual(Set(ToolbarGallery.states.map(\.anchor)), Set(ToolbarAnchor.allCases))
        XCTAssertEqual(Set(ToolbarGallery.states.map(\.mode)), Set(ToolbarMode.allCases))
        for mode in ToolbarMode.allCases {
            let tiers = ToolbarGallery.modes.filter { $0.mode == mode }.map(\.tier)
            XCTAssertEqual(Set(tiers), Set(ToolbarTier.allCases), mode.rawValue)
        }
    }

    func testBothTiersAppearAtEveryDock() {
        for anchor in ToolbarAnchor.allCases {
            let tiers = ToolbarGallery.placements.filter { $0.anchor == anchor }.map(\.tier)
            XCTAssertEqual(Set(tiers), Set(ToolbarTier.allCases), anchor.rawValue)
        }
    }

    func testUnusableBindingsNeverBecomeHoverText() {
        let kinds: [ToolbarShortcut] = [.off, .unavailable, .assigned("⌃⌥Space")]
        XCTAssertEqual(Set(kinds.map(\.label)).count, 3, "off, failed and assigned must not read the same")
        XCTAssertNil(ToolbarShortcut.off.hintKey)
        XCTAssertNil(ToolbarShortcut.unavailable.hintKey)
        XCTAssertEqual(ToolbarShortcut.assigned("⌃⌥Space").hintKey, "⌃⌥Space")
        for state in ToolbarGallery.states {
            XCTAssertNotEqual(state.actionHint, ToolbarShortcut.off.label, state.name)
            XCTAssertNotEqual(state.actionHint, ToolbarShortcut.unavailable.label, state.name)
        }
    }

    func testActiveWorkReplacesTheStartActionRatherThanAddingToIt() {
        let drawing = ToolbarGallery.activity.first { $0.name == "activity-drawing" }
        XCTAssertEqual(drawing?.actionTitle, "Stop drawing")
        XCTAssertNotEqual(drawing?.actionTitle, ToolbarMode.draw.title)
        XCTAssertEqual(ToolbarGallery.activity.first { $0.name == "activity-presenting" }?.actionTitle, "End presentation")
        XCTAssertEqual(ToolbarGallery.activity.first { $0.name == "activity-personas" }?.actionTitle, "Hide personas")
    }

    /// Work started from a key while another mode is selected: the label follows
    /// the work, the glyph stays quiet and that mode's chip lights instead.
    func testWorkInAnotherModeLightsItsChipNotTheGlyph() throws {
        let state = try XCTUnwrap(ToolbarGallery.activity.first { $0.name == "activity-drawing-in-dictate" })
        XCTAssertEqual(state.mode, .dictate)
        XCTAssertEqual(state.actionTitle, "Stop drawing")
        XCTAssertFalse(state.isBusy)
        XCTAssertEqual(state.switcher.filter(\.isBusy).map(\.mode), [.draw])
        XCTAssertFalse(state.switcher.contains { $0.mode == state.mode }, "the selected mode is the glyph, not a chip")
    }

    func testTheCountLivesInTheLabelAndTheKeyInTheHint() {
        let between = ToolbarGallery.idle.first { $0.name == "idle-session-open" }
        XCTAssertEqual(between?.actionTitle, "Capture next · 3")
        XCTAssertEqual(between?.actionHint, "⌥C")
        XCTAssertEqual(between?.isBusy, false, "a saved session does not pretend to be recording")
        let saving = ToolbarGallery.activity.first { $0.name == "activity-transcribing" }
        XCTAssertEqual(saving?.actionHint, "saving · ⌥C")
        XCTAssertEqual(saving?.isBusy, true)
        XCTAssertEqual(ToolbarGallery.activity.first { $0.name == "activity-presenting" }?.accessoryTitle, "Prompts")
        XCTAssertNil(ToolbarGallery.modes.first { $0.mode == .dictate }?.accessoryTitle)
    }

    func testRunningWorkIsVisibleWithoutHovering() {
        let resting = ToolbarGallery.activity.filter { $0.tier == .resting && $0.mode != .dictate }
        XCTAssertFalse(resting.isEmpty, "the resting element must be reviewed in its busy state too")
        XCTAssertTrue(resting.allSatisfy(\.isBusy))
    }

    func testNoDeadReadingFixtureRemains() {
        XCTAssertFalse(ToolbarGallery.states.contains { $0.name == "activity-reading" },
                       "reading shows its own compact controls; the row never renders it")
    }

    /// The row is a glance, not a sentence. The label budget is the next action's.
    func testEveryLabelStaysAGlance() {
        for state in ToolbarGallery.states {
            XCTAssertFalse(state.actionTitle.isEmpty, state.name)
            XCTAssertLessThanOrEqual(state.actionTitle.count, ToolbarNextAction.titleBudget, state.name)
            XCTAssertEqual(state.switcher.count, ToolbarMode.allCases.count - 1, state.name)
        }
    }

    func testARowGrowsInwardFromItsDockedEdge() {
        XCTAssertEqual(ToolbarAnchor.allCases.filter(\.growsLeftward), [.topRight, .right, .bottomRight])
    }

    func testEachModeKeepsOneSymbolAndOnePageAcrossEverySurface() {
        let symbols = ToolbarMode.allCases.map(\.symbol)
        XCTAssertEqual(Set(symbols).count, symbols.count)
        XCTAssertEqual(ToolbarMode.draw.page, "annotate")
        XCTAssertEqual(ToolbarMode.read.page, "speak")
        XCTAssertEqual(ToolbarMode.snapAndTalk.page, "readback")
        XCTAssertEqual(ToolbarMode.persona.page, "personas")
    }
}
