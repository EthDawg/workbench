import AppKit
import XCTest
import ToolbarCore
@testable import ToolbarKit

final class ToolbarEdgePlacementTests: XCTestCase {
    let screen = NSRect(x: -1440, y: -180, width: 1440, height: 900)

    func testTopBottomAndFreeExpandEvenlyWhileSideDocksKeepTheirEdge() {
        let sizes = [ToolbarLayout.mark, NSSize(width: 252, height: 40), NSSize(width: 336, height: 54)]
        for position in [ToolbarPosition.docked(.top), .docked(.bottom),
                         .free(.init(releasedAt: CGPoint(x: screen.midX + 100, y: screen.midY), on: screen))] {
            let frames = sizes.map { ToolbarGeometry.frame(size: $0, position: position, screen: screen) }
            for frame in frames { XCTAssertEqual(frame.midX, frames[0].midX); XCTAssertEqual(frame.midY, frames[0].midY) }
            XCTAssertEqual(frames[0].minX - frames[1].minX, frames[1].maxX - frames[0].maxX)
        }
        for anchor in [ToolbarAnchor.topLeft, .left, .bottomLeft, .topRight, .right, .bottomRight] {
            let frames = sizes.map { ToolbarGeometry.frame(size: $0, position: .docked(anchor), screen: screen) }
            for frame in frames {
                XCTAssertEqual(anchor.growsLeftward ? frame.maxX : frame.minX,
                               anchor.growsLeftward ? frames[0].maxX : frames[0].minX)
                XCTAssertTrue(screen.contains(frame))
            }
        }
    }

    func testEveryEdgeAcceptsArbitraryFractionsAndOvershoot() throws {
        for edge in ToolbarEdge.allCases {
            for fraction in [CGFloat(0.2), 0.37, 0.7, 0.84] {
                let attachment = ToolbarEdgeAttachment(edge: edge, fraction: fraction)
                let centre = attachment.centre(on: screen)
                for distance in [CGFloat(0), -16, -80] {
                    let shift: CGPoint
                    switch edge {
                    case .left: shift = CGPoint(x: distance, y: 0)
                    case .right: shift = CGPoint(x: -distance, y: 0)
                    case .bottom: shift = CGPoint(x: 0, y: distance)
                    case .top: shift = CGPoint(x: 0, y: -distance)
                    }
                    let dragged = ToolbarGeometry.slot(around: centre).offsetBy(dx: shift.x, dy: shift.y)
                    guard case .free(let saved) = ToolbarGeometry.releasedPosition(frame: dragged, screen: screen) else {
                        return XCTFail("An arbitrary point on \(edge) unexpectedly jumped to a named dock")
                    }
                    XCTAssertEqual(saved.attachment?.edge, edge)
                    XCTAssertEqual(try XCTUnwrap(saved.attachment).fraction, fraction, accuracy: 0.0001)
                    for size in [ToolbarLayout.mark, NSSize(width: 252, height: 40)] {
                        XCTAssertTrue(screen.contains(ToolbarGeometry.frame(size: size, position: .free(saved), screen: screen)))
                    }
                }
            }
        }
    }

    func testEdgeThresholdMidpointsAndCornersUseWindowBounds() {
        let centre = ToolbarEdgeAttachment(edge: .bottom, fraction: 0.3).centre(on: screen)
        let slot = ToolbarGeometry.slot(around: centre)
        XCTAssertTrue(ToolbarGeometry.isAttached(ToolbarGeometry.releasedPosition(frame: slot.offsetBy(dx: 0, dy: 16), screen: screen)))
        XCTAssertFalse(ToolbarGeometry.isAttached(ToolbarGeometry.releasedPosition(frame: slot.offsetBy(dx: 0, dy: 16.1), screen: screen)))
        for anchor in ToolbarAnchor.allCases {
            let centre = ToolbarGeometry.launcherCentre(.docked(anchor), screen: screen)
            XCTAssertEqual(ToolbarGeometry.releasedPosition(frame: ToolbarGeometry.slot(around: centre), screen: screen), .docked(anchor))
        }
        // A wide toolbar docks when its edge reaches the rail; its centre need not be near it.
        let wide = NSRect(x: screen.minX + 20, y: screen.midY - 140, width: 252, height: 40)
        guard case .free(let saved) = ToolbarGeometry.releasedPosition(frame: wide, screen: screen) else { return XCTFail() }
        XCTAssertEqual(saved.attachment?.edge, .left)
        XCTAssertEqual(ToolbarGeometry.rowAnchor(.free(saved)), .left)
    }

    func testAttachedFractionSurvivesDisplayChangeAndSmallScreensRemainReachable() {
        for edge in ToolbarEdge.allCases {
            let attachment = ToolbarEdgeAttachment(edge: edge, fraction: 0.3)
            let saved = ToolbarPosition.free(.init(centre: attachment.centre(on: screen), growsLeftward: edge == .right, attachment: attachment))
            for destination in [NSRect(x: 0, y: 25, width: 2560, height: 1415), NSRect(x: -220, y: 40, width: 220, height: 150)] {
                XCTAssertEqual(ToolbarGeometry.launcherCentre(saved, screen: destination), attachment.centre(on: destination))
                XCTAssertTrue(destination.contains(ToolbarGeometry.frame(size: NSSize(width: 340, height: 54), position: saved, screen: destination)))
            }
        }
    }

    func testAttachmentStaysOnItsDisplayWhenAnotherDisplayTakesItsOldCoordinates() {
        let attached = ToolbarEdgeAttachment(edge: .right, fraction: 0.3, displayID: "A")
        let resizedA = NSRect(x: 0, y: 0, width: 1024, height: 768)
        let shiftedB = NSRect(x: 1024, y: 0, width: 1920, height: 1080)
        XCTAssertTrue(shiftedB.contains(CGPoint(x: 1400, y: 300)), "the old absolute centre now falls on B")
        XCTAssertEqual(attached.screen(in: ["A": resizedA, "B": shiftedB], fallback: shiftedB), resizedA)
        XCTAssertEqual(attached.screen(in: ["B": shiftedB], fallback: shiftedB), shiftedB)
        XCTAssertEqual(attached.screen(in: ["A": resizedA, "B": shiftedB], fallback: shiftedB), resizedA,
                       "temporary recovery does not replace the saved owner")
    }
}
