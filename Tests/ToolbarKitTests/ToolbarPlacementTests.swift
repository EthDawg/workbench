import AppKit
import XCTest
import StageKit
import ToolbarCore
@testable import ToolbarKit

/// Free placement (#163): the drag threshold, the snap zone, clamping and recovery, and a
/// free position that keeps its glyph and its side whichever way the row opens or its
/// resting element changes width.
final class ToolbarPlacementTests: XCTestCase {
    let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)
    let resting = NSSize(width: 162, height: 36)
    let row = NSSize(width: 408, height: 36)

    /// A free position released with its resting element at `origin`, at the fixture's width.
    func released(at origin: CGPoint) -> ToolbarPosition {
        .free(ToolbarFreePosition(released: NSRect(origin: origin, size: resting), on: screen))
    }

    func testAMoveStartsAtFourPointsAndLessIsAClick() {
        XCTAssertEqual(ToolbarDrag.threshold, 4)
        XCTAssertEqual(ToolbarDrag.threshold, FloatingControlPlacement.dragThreshold,
                       "the toolbar and other floating controls share one threshold")
        let start = CGPoint(x: 100, y: 100)
        for (dx, dy, moves) in [(3.9, 0.0, false), (4.0, 0.0, true), (0.0, -4.5, true), (2.8, 2.8, false), (2.9, 2.9, true), (0.0, 0.0, false)] {
            let point = CGPoint(x: start.x + dx, y: start.y + dy)
            XCTAssertEqual(ToolbarDrag.isDrag(from: start, to: point), moves, "\(dx), \(dy)")
            XCTAssertEqual(FloatingControlPlacement.isDrag(from: start, to: point), moves, "\(dx), \(dy)")
        }
    }

    func testAReleaseWithinSixteenPointsOfADockSnapsAndBeyondStaysFree() throws {
        XCTAssertEqual(FloatingControlPlacement.snapDistance, 16)
        for anchor in FloatingControlAnchor.allCases {
            let dock = FloatingControlGeometry.frame(anchor: anchor, size: resting, visibleFrame: screen)
            // The toolbar docks its resting element exactly where the drag guide outlines the dock.
            let toolbarAnchor = try XCTUnwrap(ToolbarAnchor(rawValue: anchor.rawValue))
            XCTAssertEqual(ToolbarGeometry.restingFrame(size: resting, position: .docked(toolbarAnchor), screen: screen), dock, anchor.rawValue)
            for (dx, dy) in [(16.0, 0.0), (-16.0, 0.0), (0.0, 16.0), (0.0, -16.0), (11.3, -11.3)] {
                XCTAssertEqual(FloatingControlPlacement.snapAnchor(for: dock.offsetBy(dx: dx, dy: dy), in: screen), anchor, "\(anchor.rawValue) \(dx), \(dy)")
            }
            for (dx, dy) in [(16.5, 0.0), (-16.5, 0.0), (0.0, 16.5), (12, 12)] {
                XCTAssertNil(FloatingControlPlacement.snapAnchor(for: dock.offsetBy(dx: dx, dy: dy), in: screen), "\(anchor.rawValue) \(dx), \(dy)")
            }
        }
    }

    func testAFreePositionKeepsItsRestingElementAsTheRowOpensAndCloses() {
        // The side is decided on release, by the half of the display the resting element sits
        // in: 620 + 81 is left of the middle at 720, and 640 + 81 is right of it.
        for (origin, leftward) in [(CGPoint(x: 200, y: 300), false), (CGPoint(x: 1100, y: 500), true),
                                   (CGPoint(x: 620, y: 60), false), (CGPoint(x: 640, y: 60), true)] {
            let position = released(at: origin)
            let rest = ToolbarGeometry.frame(size: resting, restingSize: resting, position: position, screen: screen)
            let open = ToolbarGeometry.frame(size: row, restingSize: resting, position: position, screen: screen)
            XCTAssertEqual(rest.origin, origin)
            XCTAssertEqual(ToolbarGeometry.growsLeftward(position), leftward, "\(origin)")
            XCTAssertEqual(ToolbarGeometry.rowAnchor(position), leftward ? .right : .left)
            XCTAssertEqual(leftward ? open.maxX : open.minX, leftward ? rest.maxX : rest.minX, "the resting element keeps its place at \(origin)")
            XCTAssertEqual(open.midY, rest.midY)
            XCTAssertEqual(open.size, row)
            XCTAssertTrue(screen.contains(open))
        }
    }

    /// A live label changes the resting element's width. The side stays the one decided on
    /// release, and the glyph's edge stays where it was let go (#197 review).
    func testAWidthChangeNeverTurnsAFreeRowRoundOrMovesItsGlyph() {
        for origin in [CGPoint(x: 720 - 81 - 5, y: 300), CGPoint(x: 720 - 81 + 5, y: 300), CGPoint(x: 1000, y: 500), CGPoint(x: 300, y: 500)] {
            let position = released(at: origin)
            let before = ToolbarGeometry.restingFrame(size: resting, position: position, screen: screen)
            let leftward = ToolbarGeometry.growsLeftward(position)
            for width in [resting.width - 40, resting.width + 30, resting.width + 120] {
                let after = ToolbarGeometry.restingFrame(size: NSSize(width: width, height: resting.height), position: position, screen: screen)
                XCTAssertEqual(ToolbarGeometry.growsLeftward(position), leftward, "\(origin) at \(width)")
                XCTAssertEqual(leftward ? after.maxX : after.minX, leftward ? before.maxX : before.minX, "the glyph moved at \(origin), width \(width)")
                XCTAssertEqual(after.midY, before.midY)
            }
        }
    }

    /// An earlier save kept only the resting element's frame: its side is decided once, where
    /// it was left, and kept from then on.
    func testAnEarlierSaveDecidesItsSideOnce() {
        let saved = NSRect(x: 1000, y: 400, width: 132, height: 36)
        let position = ToolbarFreePosition(released: saved, on: screen)
        XCTAssertTrue(position.growsLeftward)
        XCTAssertEqual(position.glyphEdge, saved.maxX)
        XCTAssertEqual(position.centreY, saved.midY)
        XCTAssertEqual(position.restingFrame(size: saved.size), saved)
        XCTAssertEqual(position.restingFrame(size: NSSize(width: 300, height: 36)).maxX, saved.maxX,
                       "a wider label later grows toward the middle, from the same glyph edge")
    }

    func testAFreeRowNearAnEdgeGrowsInward() {
        let nearRight = released(at: CGPoint(x: screen.maxX - resting.width - 4, y: 400))
        let right = ToolbarGeometry.frame(size: row, restingSize: resting, position: nearRight, screen: screen)
        XCTAssertEqual(right.maxX, screen.maxX - 4)
        XCTAssertTrue(screen.contains(right))
        let nearLeft = released(at: CGPoint(x: screen.minX + 4, y: 400))
        let left = ToolbarGeometry.frame(size: row, restingSize: resting, position: nearLeft, screen: screen)
        XCTAssertEqual(left.minX, screen.minX + 4)
        XCTAssertTrue(screen.contains(left))
    }

    func testAFreePositionIsKeptWholeOnAVisibleDisplay() {
        let partlyOff = ToolbarPosition.free(ToolbarFreePosition(glyphEdge: screen.maxX + 30, centreY: screen.maxY - 4, growsLeftward: true))
        let clamped = ToolbarGeometry.restingFrame(size: resting, position: partlyOff, screen: screen)
        XCTAssertTrue(screen.contains(clamped))
        XCTAssertEqual(clamped.maxX, screen.maxX); XCTAssertEqual(clamped.maxY, screen.maxY)
        let broken = ToolbarFreePosition(glyphEdge: .nan, centreY: .infinity, growsLeftward: false)
        XCTAssertFalse(broken.isFinite)
        XCTAssertTrue(screen.contains(ToolbarGeometry.restingFrame(size: resting, position: .free(broken), screen: screen)))
        // A position on a display that has gone recovers whole onto the preferred display; one
        // on a display that is still attached stays there.
        let left = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let gone = NSRect(origin: CGPoint(x: -1800, y: 200), size: resting)
        XCTAssertEqual(FloatingControlPlacement.screen(for: gone, screens: [screen], preferred: screen), screen)
        XCTAssertTrue(screen.contains(FloatingControlPlacement.recover(gone, screens: [screen], preferred: screen)))
        XCTAssertEqual(FloatingControlPlacement.screen(for: gone, screens: [screen, left], preferred: screen), left)
        XCTAssertEqual(FloatingControlPlacement.recover(gone, screens: [screen, left], preferred: screen), gone)
    }

    func testADockedPositionIsTheAnchorsOwnGeometry() {
        for anchor in ToolbarAnchor.allCases {
            XCTAssertEqual(ToolbarGeometry.frame(size: row, restingSize: resting, position: .docked(anchor), screen: screen),
                           ToolbarGeometry.frame(size: row, restingWidth: resting.width, anchor: anchor, screen: screen))
            XCTAssertEqual(ToolbarGeometry.rowAnchor(.docked(anchor)), anchor)
            XCTAssertEqual(ToolbarGeometry.growsLeftward(.docked(anchor)), anchor.growsLeftward)
        }
    }
}
