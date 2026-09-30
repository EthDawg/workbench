import AppKit
import SwiftUI
import XCTest
import ToolbarCore
@testable import ToolbarKit

final class ToolbarOrientationTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor func testNativeMenusUseTheInboardEdgeOfTheWholeColumn() {
        _ = NSApplication.shared
        for anchor in [ToolbarAnchor.left, .right] {
            let panel = NSPanel(contentRect: NSRect(x: -19000, y: -19000, width: 40, height: 252),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            defer { panel.close() }
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 252))
            let button = NSButton(frame: NSRect(x: 4, y: 80, width: 32, height: 36))
            root.addSubview(button); panel.contentView = root
            let menu = NSMenu(); menu.addItem(withTitle: "Options for Snap", action: nil, keyEquivalent: "")
            let point = toolbarMenuLocation(menu, from: button, anchor: anchor)
            let screenPoint = panel.convertPoint(toScreen: button.convert(point, to: nil))
            if anchor == .left { XCTAssertEqual(screenPoint.x, panel.frame.maxX + 8) }
            else { XCTAssertEqual(screenPoint.x + menu.size.width, panel.frame.minX - 8) }
        }
    }

    @MainActor func testNarrowSideChooserMeasuresWithinItsAvailableLane() {
        let model = ToolbarChooserModel(choices: ToolbarNextAction.choices(for: ToolbarLiveState(mode: .snap)))
        for scale in [CGFloat(1), 1.35] {
            let view = NSHostingView(rootView: ToolbarChooserView(model: model, textScale: scale, availableWidth: 230))
            XCTAssertEqual(view.fittingSize.width, 230)
            XCTAssertGreaterThan(view.fittingSize.height, 200)
        }
    }

    @MainActor func testSideColumnsKeepReadingOrderUprightAndEveryTargetReachable() throws {
        _ = NSApplication.shared
        for anchor in [ToolbarAnchor.left, .right] {
            for scale in [CGFloat(1), 1.35] {
                let state = ToolbarViewState(name: "side", tier: .revealed, anchor: anchor, mode: .snapAndTalk,
                    accessory: .review, captureChoices: ToolbarCaptureKind.allCases)
                let row = ToolbarRow(state: state, textScale: scale)
                let size = NSHostingView(rootView: row).fittingSize
                let host = NSHostingView(rootView: row.pinnedToDock(anchor))
                let panel = NSPanel(contentRect: NSRect(origin: CGPoint(x: -19000, y: -19000), size: size),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false; panel.contentView = host
                defer { panel.close() }
                panel.orderFrontRegardless(); host.layoutSubtreeIfNeeded()
                XCTAssertEqual(size.width, 40 * scale, accuracy: 0.5)
                let buttons = descendants(host).compactMap { $0 as? NSButton }.sorted {
                    $0.convert($0.bounds, to: host).minY < $1.convert($1.bounds, to: host).minY
                }
                XCTAssertEqual(buttons.map { $0.accessibilityIdentifier() },
                    ["toolbar.launcher", "toolbar.capture.region", "toolbar.capture.window", "toolbar.capture.screen", "toolbar.accessory", "toolbar.more"])
                for button in buttons {
                    XCTAssertTrue(button.isEnabled)
                    XCTAssertTrue(host.bounds.contains(button.convert(button.bounds, to: host)))
                    let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: host.superview)
                    let hit = host.hitTest(point)
                    XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true)
                    XCTAssertEqual(button.frameRotation, 0)
                }
            }
        }
    }

    @MainActor func testSideHintsStayOnOneInboardRailForEveryAttachmentFraction() {
        let screen = NSRect(x: -1440, y: -180, width: 1440, height: 900)
        for anchor in [ToolbarAnchor.left, .right] {
            for fraction in [CGFloat(0.05), 0.3, 0.5, 0.95] {
                let attachment = ToolbarEdgeAttachment(edge: anchor == .left ? .left : .right, fraction: fraction)
                let position = ToolbarPosition.free(.init(centre: .zero, growsLeftward: anchor == .right, attachment: attachment))
                let target = ToolbarGeometry.frame(size: NSSize(width: 40, height: 252), position: position, screen: screen)
                let short = ToolbarHintController.frame(size: NSSize(width: 72, height: 29), target: target, visible: screen, anchor: anchor)
                let long = ToolbarHintController.frame(size: NSSize(width: 324, height: 65), target: target, visible: screen, anchor: anchor)
                XCTAssertEqual(short.midY, long.midY)
                XCTAssertEqual(anchor == .left ? short.minX : short.maxX, anchor == .left ? long.minX : long.maxX)
                for hint in [short, long] {
                    XCTAssertFalse(target.intersects(hint)); XCTAssertTrue(screen.contains(hint))
                }
                for size in [NSSize(width: 280, height: 340), NSSize(width: 420, height: 1500)] {
                    let popup = ToolbarGeometry.sidePanelFrame(size: size, toolbar: target, anchor: anchor, visible: screen)
                    XCTAssertFalse(target.intersects(popup)); XCTAssertTrue(screen.contains(popup))
                }
            }
        }
    }

    @MainActor func testRecordingSignalLeavesSwitchToolAndStopTheirOwnTargetsAtSideDocks() throws {
        _ = NSApplication.shared
        for anchor in [ToolbarAnchor.left, .right] {
            let state = ToolbarViewState(name: "recording", tier: .revealed, anchor: anchor,
                status: .resolve(ToolbarActivity(capture: .dictation, level: 0.5, failure: true, stopsSoon: true)))
            let host = NSHostingView(rootView: ToolbarRow(state: state))
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let launcher = try XCTUnwrap(descendants(host).first { $0.accessibilityIdentifier() == "toolbar.launcher" })
            let primary = try XCTUnwrap(descendants(host).first { $0.accessibilityIdentifier() == "toolbar.primary" })
            let chooserFrame = launcher.convert(launcher.bounds, to: host)
            let actionFrame = primary.convert(primary.bounds, to: host)
            XCTAssertEqual(chooserFrame.height, 48)
            XCTAssertFalse(chooserFrame.intersects(actionFrame))
            XCTAssertGreaterThan(host.fittingSize.height, ToolbarLayout.standardWidth + ToolbarLayout.captureSignalWidth)
        }
    }
}
