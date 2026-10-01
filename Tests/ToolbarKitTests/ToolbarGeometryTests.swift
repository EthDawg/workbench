import AppKit
import XCTest
import StageKit
import ToolbarCore
@testable import ToolbarKit

final class ToolbarGeometryTests: XCTestCase {
    /// The compact rest and the revealed row share one launcher centre at every dock (#134):
    /// nothing under a pointer on that centre moves as the row opens or widens.
    func testEveryAnchorKeepsItsCentreOrInwardEdgeAcrossBothTiers() {
        for screen in [NSRect(x: 0, y: 0, width: 1440, height: 900),
                       NSRect(x: -1920, y: -300, width: 1920, height: 1080)] {
            for anchor in ToolbarAnchor.allCases {
                let position = ToolbarPosition.docked(anchor)
                let centre = ToolbarGeometry.launcherCentre(position, screen: screen)
                for size in [ToolbarLayout.mark, NSSize(width: ToolbarLayout.standardWidth, height: ToolbarLayout.rowHeight),
                             NSSize(width: ToolbarLayout.accessoryStandardWidth, height: ToolbarLayout.rowHeight)] {
                    let frame = ToolbarGeometry.frame(size: ToolbarLayout.oriented(size, for: anchor), position: position, screen: screen)
                    XCTAssertTrue(screen.contains(frame), "\(anchor) \(size)")
                    XCTAssertEqual(ToolbarGeometry.restingCentre(inWindow: frame, anchor: anchor), centre, "\(anchor) \(size)")
                }
            }
        }
    }

    /// The compact rest's window is exactly its 48 × 28 target, centred on the launcher.
    func testTheRestingWindowIsTheCompactTarget() {
        let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)
        for anchor in ToolbarAnchor.allCases {
            let frame = ToolbarGeometry.frame(size: ToolbarLayout.mark(for: anchor), position: .docked(anchor), screen: screen)
            XCTAssertEqual(frame.size, ToolbarLayout.mark(for: anchor))
            XCTAssertEqual(NSPoint(x: frame.midX, y: frame.midY), ToolbarGeometry.launcherCentre(.docked(anchor), screen: screen), anchor.rawValue)
        }
        XCTAssertEqual(ToolbarLayout.standardWidth, 96)
        XCTAssertEqual(ToolbarLayout.accessoryStandardWidth, 136)
    }

    /// Named positions use the same eight-point outer inset in either orientation.
    func testDockedFramesStayTuckedAgainstTheirEdges() {
        let screen = NSRect(x: -1440, y: -200, width: 1440, height: 900)
        for anchor in ToolbarAnchor.allCases {
            for horizontal in [ToolbarLayout.mark, NSSize(width: 252, height: 40), NSSize(width: 330, height: 54)] {
                let frame = ToolbarGeometry.frame(size: ToolbarLayout.oriented(horizontal, for: anchor), position: .docked(anchor), screen: screen)
                if anchor != .top && anchor != .bottom {
                    XCTAssertEqual(anchor.growsLeftward ? screen.maxX - frame.maxX : frame.minX - screen.minX, 8)
                }
                if anchor.isVertical { XCTAssertEqual(frame.midY, screen.midY) }
                else {
                    let top = [.topLeft, .top, .topRight].contains(anchor)
                    XCTAssertEqual(top ? screen.maxY - frame.maxY : frame.minY - screen.minY, 8)
                }
            }
        }
    }

    func testFrameReferenceIsAnExactInverseAcrossOrientationChanges() {
        for anchor in ToolbarAnchor.allCases {
            for floating in [false, true] {
                for frame in [NSRect(x: -402.5, y: 51, width: 252, height: 40), NSRect(x: 102, y: -73.5, width: 31, height: 163)] {
                    let reference = ToolbarGeometry.restingCentre(inWindow: frame, anchor: anchor, isFloating: floating)
                    XCTAssertEqual(ToolbarGeometry.frame(size: frame.size, reference: reference, anchor: anchor, isFloating: floating), frame)
                }
            }
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
