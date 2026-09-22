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
        XCTAssertEqual(Set(ToolbarTool.allCases.map(\.slug)).count, ToolbarTool.allCases.count)
        XCTAssertEqual(Set(ToolbarAnchor.allCases.map(\.slug)).count, ToolbarAnchor.allCases.count)
    }

    func testEveryTierDockAndToolIsRepresented() {
        XCTAssertEqual(Set(ToolbarGallery.states.map(\.tier)), Set(ToolbarTier.allCases))
        XCTAssertEqual(Set(ToolbarGallery.states.map(\.anchor)), Set(ToolbarAnchor.allCases))
        XCTAssertEqual(Set(ToolbarGallery.states.map(\.tool)), Set(ToolbarTool.allCases))
    }

    func testBothTiersAppearAtEveryDock() {
        for anchor in ToolbarAnchor.allCases {
            let tiers = ToolbarGallery.placements.filter { $0.anchor == anchor }.map(\.tier)
            XCTAssertEqual(Set(tiers), Set(ToolbarTier.allCases), anchor.rawValue)
        }
    }

    func testUnusableBindingsAreCoveredAndReadDifferently() {
        let kinds: [ToolbarShortcut] = [.off, .unavailable, .assigned("⌃⌥Space")]
        XCTAssertEqual(Set(kinds.map(\.label)).count, 3, "off, failed and assigned must not read the same")
        XCTAssertTrue(ToolbarTrailing.shortcut(.off).readsAsUnavailable)
        XCTAssertTrue(ToolbarTrailing.shortcut(.unavailable).readsAsUnavailable)
        XCTAssertFalse(ToolbarTrailing.shortcut(.assigned("⌃⌥Space")).readsAsUnavailable)
        XCTAssertFalse(ToolbarTrailing.status("3 captures").readsAsUnavailable, "a status is not a broken binding")
        let covered = Set(ToolbarGallery.states.map(\.trailing.text))
        XCTAssertTrue(covered.contains(ToolbarShortcut.off.label))
        XCTAssertTrue(covered.contains(ToolbarShortcut.unavailable.label))
    }

    func testActiveWorkReplacesTheStartActionRatherThanAddingToIt() {
        let drawing = ToolbarGallery.activity.first { $0.name == "activity-drawing" }
        XCTAssertEqual(drawing?.actionTitle, "Done drawing")
        XCTAssertNotEqual(drawing?.actionTitle, ToolbarTool.annotate.title)
    }

    func testTheTrailingSlotCarriesStatusWhileWorkingAndAKeyWhenIdle() {
        for state in ToolbarGallery.activity where state.isBusy && state.tier == .revealed {
            guard case .status = state.trailing else {
                return XCTFail("\(state.name) shows a key while work is running")
            }
        }
        for state in ToolbarGallery.tools where !state.isBusy {
            guard case .shortcut = state.trailing else {
                return XCTFail("\(state.name) shows a status while idle")
            }
        }
    }

    func testRunningWorkIsVisibleWithoutHovering() {
        let resting = ToolbarGallery.activity.filter { $0.tier == .resting }
        XCTAssertFalse(resting.isEmpty, "the resting glyph must be reviewed in its busy state too")
        XCTAssertTrue(resting.allSatisfy(\.isBusy))
    }

    /// Found by looking at the gallery: a long status pushed the row past the
    /// artboard. The row is a glance, not a sentence, and the longest thing it is
    /// ever allowed to say is "Shortcut unavailable".
    func testTheTrailingSlotStaysAGlance() {
        let budget = ToolbarShortcut.unavailable.label.count
        for state in ToolbarGallery.states {
            XCTAssertLessThanOrEqual(state.trailing.text.count, budget,
                                     "\(state.name): \u{201c}\(state.trailing.text)\u{201d}")
        }
    }

    func testNoFixtureShipsEmptyText() {
        for state in ToolbarGallery.states {
            XCTAssertFalse(state.actionTitle.isEmpty, state.name)
            XCTAssertFalse(state.trailing.text.isEmpty, state.name)
        }
    }

    func testARowGrowsInwardFromItsDockedEdge() {
        XCTAssertEqual(ToolbarAnchor.allCases.filter(\.growsLeftward), [.topRight, .right, .bottomRight])
    }

    func testEachToolKeepsOneSymbolAcrossEverySurface() {
        let symbols = ToolbarTool.allCases.map(\.symbol)
        XCTAssertEqual(Set(symbols).count, symbols.count)
    }
}
