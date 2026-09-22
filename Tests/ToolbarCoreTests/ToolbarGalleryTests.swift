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
        XCTAssertEqual(Set(ToolbarTier.allCases.map { $0.rawValue.lowercased() }).count, ToolbarTier.allCases.count)
    }

    func testEveryTierDockAndToolIsRepresented() {
        XCTAssertEqual(Set(ToolbarGallery.states.map(\.tier)), Set(ToolbarTier.allCases))
        XCTAssertEqual(Set(ToolbarGallery.states.map(\.anchor)), Set(ToolbarAnchor.allCases))
        XCTAssertEqual(Set(ToolbarGallery.states.map(\.tool)), Set(ToolbarTool.allCases))
    }

    func testEveryTierAppearsAtEveryDock() {
        for anchor in ToolbarAnchor.allCases {
            let tiers = ToolbarGallery.placements.filter { $0.anchor == anchor }.map(\.tier)
            XCTAssertEqual(Set(tiers), Set(ToolbarTier.allCases), anchor.rawValue)
        }
    }

    func testUnusableBindingsAreCoveredAndLabelledDifferently() {
        let labels = Set(ToolbarGallery.states.map(\.shortcut.label))
        XCTAssertTrue(labels.contains(ToolbarShortcut.off.label))
        XCTAssertTrue(labels.contains(ToolbarShortcut.unavailable.label))
        XCTAssertFalse(ToolbarShortcut.off.isUsable)
        XCTAssertFalse(ToolbarShortcut.unavailable.isUsable)
        XCTAssertTrue(ToolbarShortcut.assigned("⌃⌥Space").isUsable)
        let kinds: [ToolbarShortcut] = [.off, .unavailable, .assigned("⌃⌥Space")]
        XCTAssertEqual(Set(kinds.map(\.label)).count, 3, "off, failed and assigned must not read the same")
    }

    func testActiveWorkReplacesTheStartActionRatherThanAddingToIt() {
        let drawing = ToolbarGallery.activity.first { $0.name == "activity-drawing" }
        XCTAssertEqual(drawing?.actionTitle, "Done drawing")
        XCTAssertNotEqual(drawing?.actionTitle, ToolbarTool.annotate.title)
    }

    func testNoFixtureShipsEmptyText() {
        for state in ToolbarGallery.states {
            XCTAssertFalse(state.actionTitle.isEmpty, state.name)
            XCTAssertFalse(state.status.isEmpty, state.name)
            XCTAssertFalse(state.detail.isEmpty, state.name)
        }
    }

    func testSideDocksStandTheRestingIndicatorOnEnd() {
        XCTAssertEqual(ToolbarAnchor.allCases.filter(\.isVertical), [.left, .right])
    }

    func testEachToolKeepsOneSymbolAcrossEverySurface() {
        let symbols = ToolbarTool.allCases.map(\.symbol)
        XCTAssertEqual(Set(symbols).count, symbols.count)
    }
}
