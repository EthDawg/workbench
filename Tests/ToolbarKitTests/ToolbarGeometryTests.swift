import AppKit
import XCTest
import StageKit
import ToolbarCore
@testable import ToolbarKit

final class ToolbarGeometryTests: XCTestCase {
    /// The compact rest and the revealed row share one launcher centre at every dock (#134):
    /// nothing under a pointer on that centre moves as the row opens or widens.
    func testEveryAnchorKeepsTheLauncherCentreAcrossBothTiers() {
        for screen in [NSRect(x: 0, y: 0, width: 1440, height: 900),
                       NSRect(x: -1920, y: -300, width: 1920, height: 1080)] {
            for anchor in ToolbarAnchor.allCases {
                let position = ToolbarPosition.docked(anchor)
                let centre = ToolbarGeometry.launcherCentre(position, screen: screen)
                for size in [ToolbarLayout.mark, NSSize(width: ToolbarLayout.standardWidth, height: ToolbarLayout.rowHeight),
                             NSSize(width: ToolbarLayout.accessoryStandardWidth, height: ToolbarLayout.rowHeight)] {
                    let frame = ToolbarGeometry.frame(size: size, position: position, screen: screen)
                    XCTAssertTrue(screen.contains(frame), "\(anchor) \(size)")
                    XCTAssertEqual(ToolbarGeometry.launcherCentre(inWindow: frame, growsLeftward: anchor.growsLeftward), centre, "\(anchor) \(size)")
                }
            }
        }
    }

    /// The compact rest's window is exactly its 48 × 28 target, centred on the launcher.
    func testTheRestingWindowIsTheCompactTarget() {
        let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)
        for anchor in ToolbarAnchor.allCases {
            let frame = ToolbarGeometry.frame(size: ToolbarLayout.mark, position: .docked(anchor), screen: screen)
            XCTAssertEqual(frame.size, ToolbarLayout.mark)
            XCTAssertEqual(NSPoint(x: frame.midX, y: frame.midY), ToolbarGeometry.launcherCentre(.docked(anchor), screen: screen), anchor.rawValue)
        }
        XCTAssertEqual(ToolbarLayout.standardWidth, 160)
        XCTAssertEqual(ToolbarLayout.accessoryStandardWidth, 252)
    }

    /// Each dock's slot is exactly the shared floating-control geometry's frame for that anchor,
    /// so the drag guides, snapping and Position… all agree.
    func testDockSlotsAreTheSharedFloatingControlFrames() throws {
        let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)
        for anchor in ToolbarAnchor.allCases {
            let shared = try XCTUnwrap(FloatingControlAnchor(rawValue: anchor.rawValue))
            XCTAssertEqual(ToolbarGeometry.slot(around: ToolbarGeometry.launcherCentre(.docked(anchor), screen: screen)),
                           FloatingControlGeometry.frame(anchor: shared, size: ToolbarLayout.dockSlot, visibleFrame: screen), anchor.rawValue)
        }
    }

    func testDisconnectedOrSmallDisplayStillContainsToolbar() {
        let screen = NSRect(x: -200, y: 40, width: 220, height: 150)
        for anchor in ToolbarAnchor.allCases {
            for size in [ToolbarLayout.mark, NSSize(width: 340, height: 48)] {
                XCTAssertTrue(screen.contains(ToolbarGeometry.frame(size: size, position: .docked(anchor), screen: screen)), "\(anchor) \(size)")
            }
        }
    }

    func testGeometryCrossingsAtStationaryPointerDoNotReveal() {
        var gate = ToolbarPointerGate(point: NSPoint(x: 20, y: 20))
        gate.settled(at: NSPoint(x: 20, y: 20), inside: false)
        XCTAssertNil(gate.crossing(at: NSPoint(x: 20, y: 20), inside: true))
        XCTAssertEqual(gate.crossing(at: NSPoint(x: 21, y: 20), inside: true), .pointerEntered)
        XCTAssertNil(gate.crossing(at: NSPoint(x: 22, y: 20), inside: true))
        XCTAssertEqual(gate.crossing(at: NSPoint(x: 45, y: 20), inside: false), .pointerLeft)
    }
}
