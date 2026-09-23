import AppKit
import XCTest
import ToolbarCore
@testable import ToolbarKit

final class ToolbarGeometryTests: XCTestCase {
    func testEveryAnchorKeepsTheGlyphUnderThePointerAcrossBothTiers() {
        for screen in [NSRect(x: 0, y: 0, width: 1440, height: 900),
                       NSRect(x: -1920, y: -300, width: 1920, height: 1080)] {
            for anchor in ToolbarAnchor.allCases {
                let rest = ToolbarGeometry.frame(size: NSSize(width: 36, height: 36), glyphWidth: 36, anchor: anchor, screen: screen)
                let row = ToolbarGeometry.frame(size: NSSize(width: 330, height: 36), glyphWidth: 36, anchor: anchor, screen: screen)
                XCTAssertTrue(screen.contains(rest)); XCTAssertTrue(screen.contains(row))
                XCTAssertEqual(rest.midY, row.midY)
                XCTAssertEqual(rest.midX, anchor.growsLeftward ? row.maxX - 18 : row.minX + 18, "\(anchor)")
            }
        }
    }
    func testDisconnectedOrSmallDisplayStillContainsToolbar() {
        let screen = NSRect(x: -200, y: 40, width: 220, height: 150)
        for anchor in ToolbarAnchor.allCases {
            XCTAssertTrue(screen.contains(ToolbarGeometry.frame(size: NSSize(width: 340, height: 48),
                glyphWidth: 48, anchor: anchor, screen: screen)))
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
