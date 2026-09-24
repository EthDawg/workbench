import AppKit
import SwiftUI
import XCTest
import ToolbarCore
import StageKit
@testable import ToolbarKit

final class ToolbarNativeTests: XCTestCase {
    @MainActor func testProductionRowsFitContentForEveryFixtureAndLargerText() {
        _ = NSApplication.shared
        for scale in [CGFloat(1), 1.35] {
            for state in ToolbarGallery.states {
                let view = NSHostingView(rootView: ToolbarRow(state: state, textScale: scale))
                let size = view.fittingSize
                XCTAssertGreaterThanOrEqual(size.height, 36 * scale - 1, state.name)
                XCTAssertLessThan(size.width, 580, state.name)
                XCTAssertGreaterThan(size.width, 30, state.name)
                if state.tier == .resting { XCTAssertEqual(size.width, size.height, accuracy: 1, state.name) }
                let larger = NSHostingView(rootView: ToolbarRow(state: state, textScale: scale * 1.2)).fittingSize
                XCTAssertGreaterThan(larger.width, size.width, state.name)
            }
        }
    }

    @MainActor func testGlyphExposesANativeTargetActionForAccessibilityPress() {
        var admissionRequests = 0
        var endings = 0
        let view = NSHostingView(rootView: ToolbarRow(state: ToolbarViewState(name: "rest", tier: .resting),
            menuBegan: { _ in admissionRequests += 1; return false }, menuEnded: { endings += 1 }))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let glyph = buttons(view).first { $0.accessibilityIdentifier() == "toolbar.menu" }
        XCTAssertNotNil(glyph)
        XCTAssertNotNil(glyph?.target)
        XCTAssertNotNil(glyph?.action)
        XCTAssertTrue(glyph?.acceptsFirstResponder == true)
        glyph?.performClick(nil)
        XCTAssertEqual(admissionRequests, 1)
        XCTAssertEqual(endings, 0, "rejected native activation never enters menu tracking")
    }

    @MainActor func testMenuGlyphDoesNotShiftWhenTheChevronAppears() throws {
        func glyph(_ tier: ToolbarTier) throws -> NSRect {
            let view = NSHostingView(rootView: ToolbarRow(state: ToolbarViewState(name: "glyph", tier: tier)))
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            func buttons(_ view: NSView) -> [NSButton] {
                (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
            }
            let button = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.menu" })
            return try XCTUnwrap(button.cell as? NSButtonCell).imageRect(forBounds: button.bounds)
        }
        XCTAssertEqual(try glyph(.resting), try glyph(.revealed))
    }

    @MainActor func testLongPrimaryActionGrowsInsteadOfShrinkingText() {
        let short = ToolbarViewState(name: "short", tier: .revealed, actionTitle: "Dictate")
        var long = short; long.actionTitle = "Finish this longer action"
        let small = NSHostingView(rootView: ToolbarRow(state: short)).fittingSize
        let large = NSHostingView(rootView: ToolbarRow(state: long)).fittingSize
        XCTAssertGreaterThan(large.width, small.width + 40)
        XCTAssertEqual(large.height, small.height, accuracy: 1)
    }

    @MainActor func testImmediateRetargetSettlesSynchronouslyAtRequestedDestination() {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 36, height: 36),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let motion = ToolbarWindowMotion()
        let final = NSRect(x: 200, y: 160, width: 36, height: 36)
        var completions = 0
        motion.settled = { completions += 1 }
        motion.move(panel, to: NSRect(x: 100, y: 100, width: 300, height: 36), animated: true)
        // AppKit can finish the first animation before move returns (including
        // with Reduce Motion). A completion before retargeting is legitimate.
        let beforeRetarget = completions
        XCTAssertLessThanOrEqual(beforeRetarget, 1)
        motion.move(panel, to: final, animated: false)
        // Assert immediately: a nonanimated replacement must settle before the
        // caller continues, not at some later point in an asynchronous wait.
        XCTAssertEqual(completions, beforeRetarget + 1)
        XCTAssertEqual(panel.frame, final)
        XCTAssertNil(motion.target)
    }

    @MainActor func testFinishingBeforeDragCannotRestoreTheOldOriginLater() async {
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 36, height: 36),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let motion = ToolbarWindowMotion()
        var completions = 0
        motion.settled = { completions += 1 }
        let expanded = NSRect(x: 100, y: 100, width: 300, height: 36)
        motion.move(panel, to: expanded, animated: true)
        motion.finish(panel)
        XCTAssertNil(motion.target)
        XCTAssertEqual(panel.frame, expanded)
        XCTAssertEqual(completions, 1, "finish must be synchronous before a drag records its origin")
        panel.setFrameOrigin(NSPoint(x: 350, y: 250))
        let unexpected = expectation(description: "stale animation completion")
        unexpected.isInverted = true
        motion.settled = { unexpected.fulfill() }
        await fulfillment(of: [unexpected], timeout: 0.25)
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 350, y: 250))
    }

    @MainActor func testBusyGlyphAndDotUseTheSameBrandColourInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var expected: NSColor!
            appearance.performAsCurrentDrawingAppearance {
                expected = WorkbenchPalette.nativeAccent.usingColorSpace(.deviceRGB)
            }
            let view = NSHostingView(rootView: ToolbarRow(
                state: ToolbarViewState(name: "busy-colour", tier: .resting, isBusy: true),
                accent: WorkbenchPalette.accent)
                .environment(\.colorScheme, name == .darkAqua ? .dark : .light))
            view.appearance = appearance
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            var upperMatches = 0, lowerMatches = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let delta = abs(colour.redComponent - expected.redComponent)
                        + abs(colour.greenComponent - expected.greenComponent)
                        + abs(colour.blueComponent - expected.blueComponent)
                    if delta < 0.04 {
                        if y < bitmap.pixelsHigh * 3 / 4 { upperMatches += 1 }
                        else { lowerMatches += 1 }
                    }
                }
            }
            XCTAssertGreaterThan(upperMatches, 0, "glyph must render the brand accent in \(name)")
            XCTAssertGreaterThan(lowerMatches, 0, "busy dot must render the same accent in \(name)")
        }
    }

    func testBrandPaletteResolvesTheSpecifiedLightAndDarkColours() throws {
        let cases: [(NSAppearance.Name, CGFloat, CGFloat, CGFloat)] = [
            (.aqua, 0.04, 0.43, 0.32), (.darkAqua, 0.43, 0.89, 0.73)
        ]
        for (name, red, green, blue) in cases {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var colour: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                colour = WorkbenchPalette.nativeAccent.usingColorSpace(.sRGB)
            }
            let resolved = try XCTUnwrap(colour)
            XCTAssertEqual(resolved.redComponent, red, accuracy: 0.001, name.rawValue)
            XCTAssertEqual(resolved.greenComponent, green, accuracy: 0.001, name.rawValue)
            XCTAssertEqual(resolved.blueComponent, blue, accuracy: 0.001, name.rawValue)
        }
    }
}
