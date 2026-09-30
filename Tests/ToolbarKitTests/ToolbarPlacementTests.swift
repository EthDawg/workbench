import AppKit
import XCTest
import StageKit
import ToolbarCore
@testable import ToolbarKit

/// Free placement (#163, #134): the drag threshold, the snap zone, clamping and recovery, and a
/// free position that keeps its launcher and its side whichever way the row opens or however
/// wide its content becomes.
final class ToolbarPlacementTests: XCTestCase {
    let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)
    let row = NSSize(width: ToolbarLayout.accessoryStandardWidth, height: ToolbarLayout.rowHeight)

    /// A free position released with its launcher at `centre`.
    func released(at centre: CGPoint) -> ToolbarPosition {
        .free(ToolbarFreePosition(releasedAt: centre, on: screen))
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
        for anchor in ToolbarAnchor.allCases {
            let shared = try XCTUnwrap(FloatingControlAnchor(rawValue: anchor.rawValue))
            let dock = ToolbarGeometry.slot(around: ToolbarGeometry.launcherCentre(.docked(anchor), screen: screen))
            for (dx, dy) in [(16.0, 0.0), (-16.0, 0.0), (0.0, 16.0), (0.0, -16.0), (11.3, -11.3)] {
                XCTAssertEqual(FloatingControlPlacement.snapAnchor(for: dock.offsetBy(dx: dx, dy: dy), in: screen), shared, "\(anchor.rawValue) \(dx), \(dy)")
            }
            for (dx, dy) in [(16.5, 0.0), (-16.5, 0.0), (0.0, 16.5), (12, 12)] {
                XCTAssertNil(FloatingControlPlacement.snapAnchor(for: dock.offsetBy(dx: dx, dy: dy), in: screen), "\(anchor.rawValue) \(dx), \(dy)")
            }
        }
    }

    func testAFreePositionKeepsItsLauncherAsTheRowOpensAndCloses() {
        // The side is decided on release, by the half of the display the launcher sits in.
        for centre in [CGPoint(x: 200, y: 300), CGPoint(x: 1100, y: 500), CGPoint(x: 719, y: 60), CGPoint(x: 721, y: 60)] {
            let position = released(at: centre)
            XCTAssertFalse(ToolbarGeometry.growsLeftward(position), "\(centre)")
            XCTAssertTrue(ToolbarGeometry.rowAnchor(position).growsFromCentre)
            for size in [ToolbarLayout.mark, row] {
                let frame = ToolbarGeometry.frame(size: size, position: position, screen: screen)
                XCTAssertEqual(ToolbarGeometry.restingCentre(inWindow: frame, anchor: .bottom), centre, "\(centre) \(size)")
                XCTAssertTrue(screen.contains(frame))
            }
        }
    }

    /// Content of any width keeps the launcher and the side decided on release (#197 review).
    func testAWidthChangeNeverTurnsAFreeRowRoundOrMovesItsLauncher() {
        for centre in [CGPoint(x: 715, y: 300), CGPoint(x: 725, y: 300), CGPoint(x: 1000, y: 500), CGPoint(x: 300, y: 500)] {
            let position = released(at: centre)
            let leftward = ToolbarGeometry.growsLeftward(position)
            for width in [ToolbarLayout.mark.width, 248, 340, 500] {
                let frame = ToolbarGeometry.frame(size: NSSize(width: width, height: ToolbarLayout.rowHeight), position: position, screen: screen)
                XCTAssertEqual(ToolbarGeometry.growsLeftward(position), leftward)
                XCTAssertEqual(ToolbarGeometry.restingCentre(inWindow: frame, anchor: .bottom), centre, "\(centre) at \(width)")
            }
        }
    }

    /// Earlier saves: #163's glyph edge, and before it the resting element alone. The launcher
    /// takes the old glyph's centre, and an earlier save's side is decided once, where it was left.
    func testEarlierSavesKeepTheirPlace() {
        let edge = ToolbarFreePosition(glyphEdge: 1100, centreY: 400, growsLeftward: true)
        XCTAssertEqual(edge.centre, CGPoint(x: 1082, y: 400))
        XCTAssertEqual(edge.glyphEdge, 1100, "and back again, for an earlier build")
        XCTAssertEqual(ToolbarFreePosition(glyphEdge: 200, centreY: 400, growsLeftward: false).centre, CGPoint(x: 218, y: 400))
        let saved = NSRect(x: 1000, y: 400, width: 132, height: 36)
        let earlier = ToolbarFreePosition(earlierResting: saved, on: screen)
        XCTAssertTrue(earlier.growsLeftward)
        XCTAssertEqual(earlier.centre, CGPoint(x: saved.maxX - 18, y: saved.midY))
        let left = ToolbarFreePosition(earlierResting: NSRect(x: 100, y: 200, width: 132, height: 36), on: screen)
        XCTAssertFalse(left.growsLeftward)
        XCTAssertEqual(left.centre, CGPoint(x: 118, y: 218))
    }

    func testAFreeRowNearAnEdgeGrowsInward() {
        let nearRight = released(at: CGPoint(x: screen.maxX - 28, y: 400))
        let right = ToolbarGeometry.frame(size: row, position: nearRight, screen: screen)
        XCTAssertEqual(right.maxX, screen.maxX)
        XCTAssertTrue(screen.contains(right))
        let nearLeft = released(at: CGPoint(x: screen.minX + 28, y: 400))
        let left = ToolbarGeometry.frame(size: row, position: nearLeft, screen: screen)
        XCTAssertEqual(left.minX, screen.minX)
        XCTAssertTrue(screen.contains(left))
    }

    func testAFreePositionIsKeptWholeOnAVisibleDisplay() {
        let partlyOff = ToolbarPosition.free(ToolbarFreePosition(centre: CGPoint(x: screen.maxX + 30, y: screen.maxY + 4), growsLeftward: true))
        let centre = ToolbarGeometry.launcherCentre(partlyOff, screen: screen)
        XCTAssertTrue(screen.contains(ToolbarGeometry.slot(around: centre)))
        XCTAssertEqual(centre, CGPoint(x: screen.maxX - 24, y: screen.maxY - 20))
        let broken = ToolbarFreePosition(centre: CGPoint(x: CGFloat.nan, y: CGFloat.infinity), growsLeftward: false)
        XCTAssertFalse(broken.isFinite)
        XCTAssertTrue(screen.contains(ToolbarGeometry.frame(size: row, position: .free(broken), screen: screen)))
        // A position on a display that has gone recovers whole onto the preferred display; one
        // on a display that is still attached stays there.
        let left = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let gone = ToolbarGeometry.slot(around: CGPoint(x: -1800, y: 200))
        XCTAssertEqual(FloatingControlPlacement.screen(for: gone, screens: [screen], preferred: screen), screen)
        XCTAssertTrue(screen.contains(FloatingControlPlacement.recover(gone, screens: [screen], preferred: screen)))
        XCTAssertEqual(FloatingControlPlacement.screen(for: gone, screens: [screen, left], preferred: screen), left)
        XCTAssertEqual(FloatingControlPlacement.recover(gone, screens: [screen, left], preferred: screen), gone)
    }

    func testADockedPositionGrowsInwardFromItsAnchor() {
        for anchor in ToolbarAnchor.allCases {
            XCTAssertEqual(ToolbarGeometry.rowAnchor(.docked(anchor)), anchor)
            XCTAssertEqual(ToolbarGeometry.growsLeftward(.docked(anchor)), anchor.growsLeftward)
        }
    }
}
