import AppKit
import SwiftUI
import XCTest
import ToolbarCore
import StageKit
import VoiceAppearance
@testable import ToolbarKit

final class ToolbarNativeTests: XCTestCase {
    private func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    private func laidOut<V: View>(_ root: V, width: CGFloat? = nil) -> NSHostingView<V> {
        let view = NSHostingView(rootView: root)
        let size = view.fittingSize
        view.frame = NSRect(x: 0, y: 0, width: width ?? size.width, height: size.height)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Every resting fixture is the same 48 × 28 compact target, whatever it shows (#134); every
    /// revealed row fits its content and grows with larger text.
    @MainActor func testProductionRowsFitContentForEveryFixtureAndLargerText() {
        _ = NSApplication.shared
        for scale in [CGFloat(1), 1.35] {
            for state in ToolbarGallery.states {
                let size = NSHostingView(rootView: ToolbarRow(state: state, textScale: scale)).fittingSize
                if state.tier == .resting {
                    XCTAssertEqual(size, ToolbarLayout.mark(for: state.anchor), state.name)
                    continue
                }
                XCTAssertGreaterThanOrEqual(size.height, ToolbarLayout.rowHeight * scale - 1, state.name)
                XCTAssertLessThan(size.width, 700, state.name)
                XCTAssertGreaterThanOrEqual(state.anchor.isVertical ? size.height : size.width, ToolbarLayout.standardWidth - 0.5, state.name)
                let larger = NSHostingView(rootView: ToolbarRow(state: state, textScale: scale * 1.2)).fittingSize
                XCTAssertGreaterThan(larger.width, size.width, state.name)
            }
        }
    }

    /// Ordinary work shares the quiet handle; recording and recovery remain visible.
    /// Drawn bounds prove no live-tool glyph escapes the thin capsule and the hit target
    /// stays generous. Capture badges retain their separate bounds checks below.
    @MainActor func testTheCompactMarkDistinguishesQuietWorkFromSignalsWithoutMovingItsTarget() throws {
        _ = NSApplication.shared
        func drawn(_ status: ToolbarStatus) throws -> (width: Int, height: Int, size: NSSize) {
            let view = NSHostingView(rootView: ToolbarCompactMark(status: status).environment(\.colorScheme, .light))
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let perPoint = CGFloat(bitmap.pixelsHigh) / view.bounds.height
            var rows = Set<Int>(), columns = Set<Int>()
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                    rows.insert(y); columns.insert(x)
                }
            }
            func points(_ pixels: Set<Int>) -> Int { pixels.isEmpty ? 0 : Int((CGFloat(pixels.max()! - pixels.min()! + 1) / perPoint).rounded()) }
            return (points(columns), points(rows), view.fittingSize)
        }
        for status in [ToolbarStatus.idle] + ToolbarActivity.Live.allCases.map({ .resolve(ToolbarActivity(live: [$0])) }) {
            let quiet = try drawn(status)
            XCTAssertEqual(quiet.size, ToolbarLayout.mark, status.description)
            XCTAssertEqual(quiet.height, 8, "a quiet handle, without a tiny tool glyph: \(status.description)")
            XCTAssertEqual(quiet.width, 48)
        }
        for activity in [ToolbarActivity(capture: .dictation, level: 0.6), ToolbarActivity(capture: .narration, level: 0.3, stopsSoon: true),
                         ToolbarActivity(processing: true), ToolbarActivity(paused: true),
                         ToolbarActivity(failure: true), ToolbarActivity(pendingDelivery: true), ToolbarActivity(unsavedCapture: true)] {
            let working = try drawn(.resolve(activity))
            XCTAssertEqual(working.size, ToolbarLayout.mark, "\(activity)")
            XCTAssertEqual(working.height, activity.capture == nil ? 8 : 20, "only recording changes the quiet capsule: \(activity)")
            XCTAssertEqual(working.width, 48, "nothing is drawn beyond the capsule: \(activity)")
        }
    }

    /// A saved warning or copied result cannot change the collapsed appearance, even
    /// during a recording. Inspect rendered pixels at every dock, rather than a flag.
    @MainActor func testRecoveryNeverPaintsWarningsOnThePill() throws {
        _ = NSApplication.shared
        for anchor in ToolbarAnchor.allCases {
            for capture in [false, true] {
                let status = ToolbarStatus.resolve(ToolbarActivity(capture: capture ? .dictation : nil,
                    level: 0.4, failure: true, pendingDelivery: true, unsavedCapture: true, stopsSoon: true))
                let view = laidOut(ToolbarRow(state: ToolbarViewState(name: "quiet recovery", tier: .resting,
                    anchor: anchor, status: status)))
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                var orange = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        if c.alphaComponent > 0.5 && c.redComponent > 0.8 && c.greenComponent > 0.2
                            && c.greenComponent < 0.8 && c.blueComponent < 0.2 { orange += 1 }
                    }
                }
                XCTAssertEqual(orange, 0, "No warning or timer glyph at \(anchor), recording \(capture)")
                XCTAssertEqual(view.fittingSize, ToolbarLayout.mark(for: anchor))
            }
        }
    }

    @MainActor func testSwitchToolKeepsItsNameAndOwnTargetAcrossEveryMode() throws {
        _ = NSApplication.shared
        for mode in ToolbarMode.allCases {
            for activity in [ToolbarActivity.idle, ToolbarActivity(failure: true), ToolbarActivity(pendingDelivery: true),
                             ToolbarActivity(capture: .dictation, level: 0.4, failure: true)] {
                let state = ToolbarViewState(name: "switch", tier: .revealed, mode: mode, status: .resolve(activity))
                let view = laidOut(ToolbarRow(state: state))
                let launcher = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.launcher" })
                XCTAssertEqual(launcher.accessibilityLabel(), "Switch tool")
                XCTAssertEqual(launcher.accessibilityValue() as? String, mode.title)
                XCTAssertEqual((launcher as? ToolbarIconButton)?.hint, "Switch tool · " + mode.title)
                XCTAssertEqual(launcher.bounds.width, 48)
            }
        }
    }

    @MainActor func testSwitchToolRendersTheSameIconForEveryToolAndSavedResult() throws {
        _ = NSApplication.shared
        var reference: [Bool]?
        for mode in ToolbarMode.allCases {
            for activity in [ToolbarActivity.idle, ToolbarActivity(failure: true), ToolbarActivity(pendingDelivery: true),
                             ToolbarActivity(capture: .dictation, level: 0.4, failure: true)] {
                let view = laidOut(ToolbarRow(state: ToolbarViewState(name: "chooser icon", tier: .revealed,
                    mode: mode, status: .resolve(activity))))
                let launcher = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.launcher" })
                let rect = launcher.convert(launcher.bounds, to: view)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rect))
                view.cacheDisplay(in: rect, to: bitmap)
                var glyph: [Bool] = []
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let c = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        glyph.append(min(c.redComponent, c.greenComponent, c.blueComponent) > 0.88)
                    }
                }
                XCTAssertTrue(glyph.contains(true), "the chooser must draw an icon")
                if let reference { XCTAssertEqual(glyph, reference, "the chooser changed for \(mode) with \(activity)") }
                else { reference = glyph }
            }
        }
    }

    /// Short actions keep their target without reserving space for other tools.
    @MainActor func testTheStandardRowWidths() {
        _ = NSApplication.shared
        let plain = NSHostingView(rootView: ToolbarRow(state: ToolbarViewState(name: "plain", tier: .revealed, mode: .draw))).fittingSize
        XCTAssertEqual(plain, NSSize(width: ToolbarLayout.standardWidth, height: ToolbarLayout.rowHeight))
        let accessory = NSHostingView(rootView: ToolbarRow(state: ToolbarViewState(name: "prompts", tier: .revealed, mode: .present, accessory: .prompts))).fittingSize
        var waiting = ToolbarViewState(name: "prompts-in-more", tier: .revealed, mode: .present, accessory: .prompts)
        waiting.showsAccessory = false
        let without = NSHostingView(rootView: ToolbarRow(state: waiting)).fittingSize.width
        XCTAssertEqual(accessory.width - without, ToolbarLayout.accessoryWidth + ToolbarLayout.gap, accuracy: 0.5)
        XCTAssertLessThan(without, 200, "short verbs should not carry a 152-point action floor")
    }

    /// Each accessory takes the one accessory slot beside the content-sized action, and says
    /// what it is: a chevron only on those that open a list, VoiceOver hearing the title without it,
    /// or the description when there is one, which the tooltip shows too (#134 part B).
    @MainActor func testEachAccessoryTakesItsSlotAndSaysWhatItIs() throws {
        _ = NSApplication.shared
        for accessory in ToolbarAccessory.allCases {
            for description in [nil, "Appearance of the selected persona, hidden"] {
                let state = ToolbarViewState(name: "accessory", tier: .revealed, mode: accessory.mode, accessory: accessory, accessoryDescription: description)
                let view = laidOut(ToolbarRow(state: state))
                var without = state; without.accessory = nil
                let plain = laidOut(ToolbarRow(state: without)).fittingSize
                XCTAssertEqual(view.fittingSize.width - plain.width, ToolbarLayout.accessoryWidth + ToolbarLayout.gap,
                               accuracy: 0.5, "one fixed accessory slot: \(accessory)")
                XCTAssertEqual(view.fittingSize.height, ToolbarLayout.rowHeight)
                let found = buttons(view).filter { $0.accessibilityIdentifier() == "toolbar.accessory" }
                let button = try XCTUnwrap(found.first, "\(accessory)")
                XCTAssertEqual(found.count, 1, "one accessory: \(accessory)")
                XCTAssertEqual(button.title, "", "the action is a symbol, with its words in the hint")
                XCTAssertNotNil(button.image)
                XCTAssertEqual(button.accessibilityLabel(), description ?? accessory.title)
                XCTAssertEqual((button as? ToolbarIconButton)?.hint, description ?? accessory.title)
            }
        }
        var none = ToolbarViewState(name: "none", tier: .revealed, mode: .draw)
        XCTAssertTrue(buttons(laidOut(ToolbarRow(state: none))).allSatisfy { $0.accessibilityIdentifier() != "toolbar.accessory" }, "no accessory unless given")
        none.accessory = .tools; none.showsAccessory = false
        XCTAssertTrue(buttons(laidOut(ToolbarRow(state: none))).allSatisfy { $0.accessibilityIdentifier() != "toolbar.accessory" }, "one that waits in More is not drawn")
    }

    /// Review goes straight to the review; an accessory that opens a list pops up its menu only
    /// with admission, as More does.
    @MainActor func testReviewOpensAtOnceAndAListAccessoryAsksFirst() throws {
        _ = NSApplication.shared
        var opened: [NSView] = [], menus = 0, admissions = 0
        let review = laidOut(ToolbarRow(state: ToolbarViewState(name: "review", tier: .revealed, mode: .snapAndTalk, accessory: .review),
                                        makeAccessoryMenu: { menus += 1; return NSMenu() }, openAccessory: { opened.append($0) }))
        let reviewButton = try XCTUnwrap(buttons(review).first { $0.accessibilityIdentifier() == "toolbar.accessory" })
        reviewButton.performClick(nil)
        XCTAssertTrue(opened.count == 1 && opened.first === reviewButton && menus == 0, "Review opens the review from its own button")
        let tools = laidOut(ToolbarRow(state: ToolbarViewState(name: "tools", tier: .revealed, mode: .draw, accessory: .tools),
                                       makeAccessoryMenu: { menus += 1; return NSMenu() }, menuBegan: { _ in admissions += 1; return false }))
        try XCTUnwrap(buttons(tools).first { $0.accessibilityIdentifier() == "toolbar.accessory" }).performClick(nil)
        XCTAssertEqual(menus, 1, "Tools builds its menu as it opens, for what is live then")
        XCTAssertEqual(admissions, 1, "and asks before it pops up")
    }

    /// The accessory answers the keyboard as the launcher and More do (#216): it takes the focus,
    /// Return, Enter and Down open it through the same admission, and Escape leaves keyboard
    /// interaction without opening anything.
    @MainActor func testTheAccessoryOpensFromTheKeyboardAsMoreDoes() throws {
        _ = NSApplication.shared
        func key(_ code: UInt16, _ characters: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        let down = String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!))
        var admissions = 0, endings = 0, escapes = 0, opened = 0
        let tools = laidOut(ToolbarRow(state: ToolbarViewState(name: "tools", tier: .revealed, mode: .draw, accessory: .tools),
                                       menuBegan: { _ in admissions += 1; return false }, menuEnded: { endings += 1 },
                                       escape: { escapes += 1 }))
        let button = try XCTUnwrap(buttons(tools).first { $0.accessibilityIdentifier() == "toolbar.accessory" })
        XCTAssertTrue(button.acceptsFirstResponder, "Tab reaches it, as it reaches More")
        for (code, characters) in [(UInt16(36), "\r"), (76, "\u{3}"), (125, down)] {
            let before = admissions
            button.keyDown(with: key(code, characters))
            XCTAssertEqual(admissions, before + 1, "key \(code) asks to open the accessory's menu")
        }
        XCTAssertEqual(endings, 0, "a refused menu never tracks")
        button.keyDown(with: key(53, "\u{1b}"))
        XCTAssertEqual(escapes, 1, "Escape leaves keyboard interaction")
        XCTAssertEqual(admissions, 3, "and opens nothing")
        // Review goes to the review from the keyboard too.
        let review = laidOut(ToolbarRow(state: ToolbarViewState(name: "review", tier: .revealed, mode: .snapAndTalk, accessory: .review),
                                        openAccessory: { _ in opened += 1 }))
        try XCTUnwrap(buttons(review).first { $0.accessibilityIdentifier() == "toolbar.accessory" }).keyDown(with: key(36, "\r"))
        XCTAssertEqual(opened, 1, "Return opens the session's review")
    }

    /// The launcher sits exactly where the compact mark does: 24 points from the growth edge,
    /// at every anchor and text size, so the two share one centre on screen.
    @MainActor func testTheLauncherSharesTheCompactMarksCentre() throws {
        _ = NSApplication.shared
        for scale in [CGFloat(1), 1.35] {
            for anchor in ToolbarAnchor.allCases {
                let view = laidOut(ToolbarRow(state: ToolbarViewState(name: "launcher", tier: .revealed, anchor: anchor, mode: .present, accessory: .prompts), textScale: scale))
                let launcher = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.launcher" })
                let frame = launcher.convert(launcher.bounds, to: view)
                XCTAssertEqual(anchor.isVertical ? frame.height : frame.width, ToolbarLayout.launcherWidth, "\(anchor) at \(scale)")
                let inset = anchor.isVertical ? frame.midY : anchor.growsLeftward ? view.bounds.maxX - frame.midX : frame.midX
                XCTAssertEqual(inset, ToolbarLayout.launcherInset, accuracy: 0.5, "\(anchor) at \(scale)")
            }
        }
    }

    /// A right-hand row reverses its slots: More, the accessory, the next action, then the
    /// launcher at the docked edge. The reading order of the controls is the same in both.
    @MainActor func testARightHandRowReversesItsSlots() {
        _ = NSApplication.shared
        func order(_ anchor: ToolbarAnchor) -> [String] {
            let view = laidOut(ToolbarRow(state: ToolbarViewState(name: "order", tier: .revealed, anchor: anchor, mode: .present, accessory: .prompts)))
            return buttons(view).filter { $0.accessibilityIdentifier().hasPrefix("toolbar.") }
                .sorted { $0.convert($0.bounds, to: view).minX < $1.convert($1.bounds, to: view).minX }
                .map { $0.accessibilityIdentifier() }
        }
        XCTAssertEqual(order(.bottom), ["toolbar.launcher", "toolbar.primary", "toolbar.accessory"])
        XCTAssertEqual(order(.bottomRight), ["toolbar.accessory", "toolbar.primary", "toolbar.launcher"])
    }

    /// The row holds no mode strip any more: the launcher is the one way to another tool.
    @MainActor func testTheRowHasOneLauncherAndNoModeStrip() throws {
        _ = NSApplication.shared
        var opened: [NSView] = []
        let view = laidOut(ToolbarRow(state: ToolbarViewState(name: "strip", tier: .revealed, mode: .dictate), openChooser: { opened.append($0) }))
        XCTAssertTrue(buttons(view).filter { $0.accessibilityIdentifier().hasPrefix("toolbar.mode.") }.isEmpty)
        let launcher = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.launcher" })
        XCTAssertTrue(launcher.acceptsFirstResponder && launcher.acceptsFirstMouse(for: nil))
        XCTAssertEqual(launcher.accessibilityLabel(), "Switch tool")
        launcher.performClick(nil)
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened.first === launcher, "the chooser is anchored to the launcher")
    }

    /// More opens the tool's options only with admission, as the glyph menu did.
    @MainActor func testMoreOpensTheOptionsWithAdmission() throws {
        _ = NSApplication.shared
        var admissionRequests = 0, endings = 0
        let view = laidOut(ToolbarRow(state: ToolbarViewState(name: "view", tier: .revealed, mode: .present, quickControl: .presentationView),
            menuBegan: { _ in admissionRequests += 1; return false }, menuEnded: { endings += 1 }))
        let more = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.view" })
        XCTAssertTrue(more.acceptsFirstResponder)
        XCTAssertEqual(more.accessibilityLabel(), "View")
        more.performClick(nil)
        XCTAssertEqual(admissionRequests, 1)
        XCTAssertEqual(endings, 0, "rejected native activation never enters menu tracking")
    }

    /// The next action asks its press for what to do, and does nothing when the press says so.
    @MainActor func testThePrimaryActsOnlyThroughItsLatchedPress() throws {
        _ = NSApplication.shared
        var presses = 0, actions = 0, valid = true
        let view = laidOut(ToolbarRow(state: ToolbarViewState(name: "press", tier: .revealed),
            press: { presses += 1; return valid ? { actions += 1 } : nil }))
        let primary = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.primary" })
        primary.performClick(nil)
        XCTAssertEqual(presses, 1); XCTAssertEqual(actions, 1)
        valid = false
        primary.performClick(nil)
        XCTAssertEqual(presses, 2); XCTAssertEqual(actions, 1, "a press whose operation no longer holds does nothing")
    }

    /// Exercise AppKit's actual hit-test tree rather than calling an obscured button directly.
    /// Both a settled row and the production dock wrapper must deliver each visible target.
    @MainActor func testVisibleControlsOwnTheirHitTargets() throws {
        for anchor in ToolbarAnchor.allCases {
            for mode in ToolbarMode.allCases {
                let state = ToolbarViewState(name: "hit-test", tier: .revealed, anchor: anchor, mode: mode,
                    accessory: .offered(for: ToolbarLiveState(mode: mode), selectedPersonaCopy: true))
                let row = ToolbarRow(state: state)
                let size = NSHostingView(rootView: row).fittingSize
                let host = NSHostingView(rootView: row.pinnedToDock(anchor))
                host.frame = NSRect(origin: .zero, size: size)
                let panel = NSPanel(contentRect: NSRect(x: -19900, y: -19900, width: size.width, height: size.height),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.contentView = host
                panel.orderFrontRegardless()
                host.layoutSubtreeIfNeeded()
                for button in buttons(host) {
                    let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: host.superview)
                    let hit = host.hitTest(point)
                    XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true,
                        "\(mode), \(anchor), \(button.accessibilityIdentifier()) intercepted by \(String(describing: hit))")
                }
                panel.close()
            }
        }
    }

    @MainActor func testControlsRemainClickableAfterGrowingFromRest() throws {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for anchor in ToolbarAnchor.allCases {
            for mode in ToolbarMode.allCases {
                var state = ToolbarViewState(name: "hover-hit", tier: .resting, anchor: anchor, mode: mode,
                    accessory: .offered(for: ToolbarLiveState(mode: mode), selectedPersonaCopy: true),
                    captureChoices: mode == .snap || mode == .snapAndTalk ? ToolbarCaptureKind.allCases : [])
                let host = NSHostingView(rootView: ToolbarRow(state: state).pinnedToDock(anchor))
                host.sizingOptions = []
                let tracking = ToolbarTrackingView(content: host)
                tracking.autoresizingMask = [.width, .height]
                let panel = NSPanel(contentRect: NSRect(x: -19900, y: -19900, width: 48, height: 28),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.contentView = tracking
                panel.orderFrontRegardless()
                defer { panel.close() }
                // The AppKit layout/display calls can return before SwiftUI commits
                // native representable frames. Advance its synchronous test renderer
                // once per simulated frame; never poll or retry a failed hit test.
                func renderFrame() {
                    tracking.layoutSubtreeIfNeeded()
                    host._renderForTest(interval: 0)
                }
                for _ in 0..<3 {
                    state.tier = .resting
                    host.rootView = ToolbarRow(state: state).pinnedToDock(anchor)
                    panel.setContentSize(ToolbarLayout.mark(for: anchor))
                    renderFrame()
                    state.tier = .revealed
                    host.rootView = ToolbarRow(state: state).pinnedToDock(anchor)
                    renderFrame()
                    let size = NSHostingView(rootView: ToolbarRow(state: state)).fittingSize
                    for progress in [CGFloat(0.5), 0.9, 1] {
                        panel.setContentSize(NSSize(width: ToolbarLayout.mark(for: anchor).width + (size.width - ToolbarLayout.mark(for: anchor).width) * progress, height: ToolbarLayout.mark(for: anchor).height + (size.height - ToolbarLayout.mark(for: anchor).height) * progress))
                        renderFrame()
                        let controls = buttons(host)
                        XCTAssertEqual(controls.count, 1 + max(1, state.captureChoices.count) + (state.showsAccessory ? state.accessoryCount : 0))
                        for button in controls {
                            XCTAssertEqual(button.isEnabled, progress == 1,
                                "\(mode), \(anchor), \(button.accessibilityIdentifier()) at reveal progress \(progress)")
                        }
                    }
                    let controls = buttons(host)
                    XCTAssertEqual(controls.count, 1 + max(1, state.captureChoices.count) + (state.showsAccessory ? state.accessoryCount : 0))
                    for button in controls {
                        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: tracking.superview)
                        let hit = tracking.hitTest(point)
                        XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true,
                            "\(mode), \(anchor), \(button.accessibilityIdentifier()) after reveal intercepted by \(String(describing: hit))")
                    }
                    state.tier = .resting
                    host.rootView = ToolbarRow(state: state).pinnedToDock(anchor)
                    renderFrame()
                    let closing = buttons(host)
                    // SwiftUI's read-only accessibility setting removes the overlay immediately
                    // under Reduce Motion. Otherwise every fading control remains present but disabled.
                    XCTAssertEqual(closing.count, reduceMotion ? 0 : controls.count,
                        "closing controls follow Reduce Motion (\(reduceMotion))")
                    for button in closing {
                        XCTAssertFalse(button.isEnabled,
                            "\(mode), \(anchor), \(button.accessibilityIdentifier()) cannot act while closing")
                    }
                }
            }
        }
    }

    /// Exercise immediate and timer-driven reveals. Production admits pointer crossings at
    /// completion, so inspect enabled states and hits here without forcing a test render.
    @MainActor func testNativeMotionCompletionDeliversEveryVisibleHitTarget() async throws {
        for animated in [false, true] {
            for anchor in ToolbarAnchor.allCases {
                for mode in ToolbarMode.allCases {
                    var state = ToolbarViewState(name: "motion-hit", tier: .resting, anchor: anchor, mode: mode,
                        accessory: .offered(for: ToolbarLiveState(mode: mode), selectedPersonaCopy: true),
                        captureChoices: mode == .snap || mode == .snapAndTalk ? ToolbarCaptureKind.allCases : [])
                    let host = NSHostingView(rootView: ToolbarRow(state: state).pinnedToDock(anchor))
                    host.sizingOptions = []
                    let tracking = ToolbarTrackingView(content: host)
                    tracking.autoresizingMask = [.width, .height]
                    let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: -19900, y: -19900), size: ToolbarLayout.mark(for: anchor)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    panel.isReleasedWhenClosed = false; panel.contentView = tracking
                    panel.orderFrontRegardless(); tracking.layoutSubtreeIfNeeded()
                    defer { panel.close() }
                    state.tier = .revealed
                    host.rootView = ToolbarRow(state: state).pinnedToDock(anchor)
                    tracking.layoutSubtreeIfNeeded()
                    let size = NSHostingView(rootView: ToolbarRow(state: state)).fittingSize
                    let complete = expectation(description: "\(mode) at \(anchor) settled")
                    let motion = ToolbarWindowMotion()
                    motion.settled = {
                        let controls = self.buttons(host)
                        XCTAssertEqual(controls.count, 1 + max(1, state.captureChoices.count) + (state.showsAccessory ? state.accessoryCount : 0))
                        for button in controls {
                            XCTAssertTrue(button.isEnabled,
                                "\(mode), \(anchor), \(button.accessibilityIdentifier()) is enabled at native completion (animated: \(animated))")
                            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: tracking.superview)
                            let hit = tracking.hitTest(point)
                            XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true,
                                "\(mode), \(anchor), \(button.accessibilityIdentifier()) at native completion (animated: \(animated)) intercepted by \(String(describing: hit))")
                        }
                        complete.fulfill()
                    }
                    motion.move(panel, to: NSRect(origin: panel.frame.origin, size: size), animated: animated, anchor: anchor)
                    await fulfillment(of: [complete], timeout: 2)
                }
            }
        }
    }

    @MainActor func testPanelDispatchReachesEveryVisibleActionAfterReveal() throws {
        for mode in ToolbarMode.allCases {
            var received: [String] = []
            var state = ToolbarViewState(name: "dispatch", tier: .revealed, mode: mode,
                accessory: .offered(for: ToolbarLiveState(mode: mode, captureCount: 2), selectedPersonaCopy: true))
            func row() -> some View {
                ToolbarRow(state: state, openAccessory: { _ in received.append("toolbar.accessory") },
                    action: { received.append("toolbar.primary") }, openChooser: { _ in received.append("toolbar.launcher") },
                    menuBegan: { _ in received.append("toolbar.more"); return false }).pinnedToDock(.bottom)
            }
            let size = NSHostingView(rootView: ToolbarRow(state: state)).fittingSize
            state.tier = .resting
            let host = NSHostingView(rootView: row())
            host.sizingOptions = []
            let tracking = ToolbarTrackingView(content: host)
            let panel = NSPanel(contentRect: NSRect(x: -19900, y: -19900, width: 48, height: 28),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.isFloatingPanel = true
            panel.contentView = tracking
            panel.orderFrontRegardless()
            defer { panel.close() }
            state.tier = .revealed; host.rootView = row()
            tracking.layoutSubtreeIfNeeded()
            panel.setContentSize(size); tracking.layoutSubtreeIfNeeded()
            for control in buttons(host) {
                let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
                func event(_ type: NSEvent.EventType, number: Int) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: number, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                let before = received.count
                NSApp.postEvent(event(.leftMouseUp, number: 0), atStart: false)
                panel.sendEvent(event(.leftMouseDown, number: panel.windowNumber))
                XCTAssertEqual(received.count, before + 1, "\(mode), \(control.accessibilityIdentifier()) receives a panel-dispatched click")
                XCTAssertEqual(received.last, control.accessibilityIdentifier())
                while queuedMouseUp(dequeue: true) {}
            }
        }
    }

    /// The compact rest is one accessible button: pressing it reveals, and nothing else.
    @MainActor func testTheCompactRestOnlyReveals() throws {
        _ = NSApplication.shared
        var reveals = 0, work = 0
        let status = ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, level: 0.5))
        let view = laidOut(ToolbarRow(state: ToolbarViewState(name: "rest", tier: .resting, status: status), action: { work += 1 },
                                      revealFromRest: { reveals += 1 }))
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let target = try XCTUnwrap(all(view).first { $0.accessibilityIdentifier() == "toolbar.rest" })
        XCTAssertTrue(target.isAccessibilityElement())
        XCTAssertEqual(target.accessibilityValue() as? String, status.spokenValue)
        XCTAssertEqual(status.spokenValue, "Recording dictation. Receiving sound", "every state, then the level in words (#211 F7)")
        XCTAssertTrue(target.accessibilityPerformPress())
        XCTAssertEqual(reveals, 1); XCTAssertEqual(work, 0)
        XCTAssertTrue(buttons(view).isEmpty, "no control is reachable at rest but the target")
    }

    @MainActor func testQuietLiveWorkRetainsItsAccessibleStatusAndRevealAction() throws {
        _ = NSApplication.shared
        var reveals = 0
        let status = ToolbarStatus.resolve(ToolbarActivity(live: [.drawing, .presenting, .timer]))
        let view = laidOut(ToolbarRow(state: ToolbarViewState(name: "quiet-live", tier: .resting, mode: .draw, status: status),
                                      revealFromRest: { reveals += 1 }))
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let target = try XCTUnwrap(all(view).first { $0.accessibilityIdentifier() == "toolbar.rest" })
        XCTAssertEqual(target.accessibilityValue() as? String, "Drawing, Presenting, Timer running")
        XCTAssertTrue(target.accessibilityPerformPress())
        XCTAssertEqual(reveals, 1)
        XCTAssertEqual(view.fittingSize, ToolbarLayout.mark)
    }

    /// A real window with the row in it, invisible and taking no pointer, for pressing its
    /// controls through their own mouse handling.
    @MainActor private func shown<V: View>(_ root: V) -> (NSPanel, NSHostingView<V>) {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: root)
        let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: view.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.alphaValue = 0; panel.ignoresMouseEvents = true
        panel.contentView = view
        panel.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        return (panel, view)
    }
    /// Presses `control` through its own `mouseDown`, with the mouse-up already queued behind it,
    /// as a click arrives. Whatever the press leaves in the queue is left there for the caller.
    /// The queued mouse-up names no window: AppKit re-maps a posted event's window location
    /// through global coordinates, and one with no window keeps the point it was given.
    @MainActor private func click(_ control: NSView, in window: NSWindow, clickCount: Int = 1) {
        let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, window number: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: number, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
        }
        NSApp.postEvent(event(.leftMouseUp, window: 0), atStart: false)
        control.mouseDown(with: event(.leftMouseDown, window: window.windowNumber))
    }
    @MainActor private func queuedMouseUp(dequeue: Bool = false) -> Bool {
        NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking, dequeue: dequeue) != nil
    }

    /// The next action is latched as the button goes down, before its mouse-up is read, and the
    /// click then does what was latched (#134).
    @MainActor func testTheNextActionIsLatchedWhileTheButtonIsStillDown() throws {
        var upStillQueued: Bool?, actions = 0
        let (window, view) = shown(ToolbarRow(state: ToolbarViewState(name: "latch", tier: .revealed), press: { [self] in
            upStillQueued = queuedMouseUp()
            return { actions += 1 }
        }))
        defer { window.close() }
        let primary = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.primary" })
        click(primary, in: window)
        XCTAssertEqual(upStillQueued, true, "the operation must be latched on mouse-down, not resolved when the button comes up")
        XCTAssertEqual(actions, 1)
        XCTAssertFalse(queuedMouseUp(), "the click took its own mouse-up")
    }

    /// The second click of a double-click does nothing on the next action or the launcher, so a
    /// double-click that begins on the compact rest never reaches work (#134).
    @MainActor func testTheSecondClickOfADoubleClickDoesNothing() throws {
        var presses = 0, opens = 0
        let (window, view) = shown(ToolbarRow(state: ToolbarViewState(name: "double", tier: .revealed),
                                              press: { presses += 1; return {} }, openChooser: { _ in opens += 1 }))
        defer { window.close() }
        for id in ["toolbar.primary", "toolbar.launcher"] {
            let control = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == id })
            click(control, in: window, clickCount: 2)
            while queuedMouseUp(dequeue: true) {}
        }
        XCTAssertEqual(presses, 0, "a second click latched the next action")
        XCTAssertEqual(opens, 0, "a second click opened the chooser")
    }

    /// A click on the compact rest reveals, never works, and takes the whole click: the row that
    /// appears under the pointer never receives its mouse-up (#134).
    @MainActor func testAClickOnTheCompactRestOnlyRevealsAndTakesTheWholeClick() throws {
        var reveals = 0, work = 0
        let status = ToolbarStatus.resolve(ToolbarActivity(capture: .dictation, level: 0.5))
        let (window, view) = shown(ToolbarRow(state: ToolbarViewState(name: "rest-click", tier: .resting, status: status),
                                              action: { work += 1 }, revealFromRest: { reveals += 1 }))
        defer { window.close() }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let target = try XCTUnwrap(all(view).first { $0.accessibilityIdentifier() == "toolbar.rest" })
        click(target, in: window)
        XCTAssertEqual(reveals, 1); XCTAssertEqual(work, 0)
        XCTAssertFalse(queuedMouseUp(), "the mouse-up was the compact rest's")
    }

    /// The launcher holds its place while the window is briefly the wrong size, at every anchor,
    /// because the content is pinned to the growth edge the launcher sits on.
    @MainActor func testTheLauncherHoldsItsPlaceWhileTheWindowIsTheWrongSize() throws {
        _ = NSApplication.shared
        func inset(_ state: ToolbarViewState, width: CGFloat, pinned: Bool) throws -> CGFloat {
            let row = ToolbarRow(state: state)
            let view = NSHostingView(rootView: pinned ? AnyView(row.pinnedToDock(state.anchor)) : AnyView(row))
            view.frame = NSRect(x: 0, y: 0, width: width, height: NSHostingView(rootView: row).fittingSize.height)
            view.layoutSubtreeIfNeeded()
            let launcher = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.launcher" })
            let frame = launcher.convert(launcher.bounds, to: view)
            return state.anchor == .top || state.anchor == .bottom ? frame.midX - view.bounds.midX
                : state.anchor.growsLeftward ? view.bounds.maxX - frame.maxX : frame.minX
        }
        for anchor in ToolbarAnchor.allCases {
            let state = ToolbarViewState(name: "jump", tier: .revealed, anchor: anchor, mode: .draw)
            let exact = NSHostingView(rootView: ToolbarRow(state: state)).fittingSize.width
            let settled = try inset(state, width: exact, pinned: true)
            for stale in [48, 72, exact - 30, exact + 60, max(400, exact + 1)] {
                XCTAssertEqual(try inset(state, width: stale, pinned: true), settled, accuracy: 0.5,
                               "\(anchor.rawValue): the launcher moved in a \(Int(stale))-point window")
            }
            if !anchor.growsFromCentre { XCTAssertGreaterThan(abs(try inset(state, width: exact + 60, pinned: false) - settled), 20,
                                 "\(anchor.rawValue): an unpinned row no longer moves, so this test no longer reproduces the jump")
            }
        }
    }

    @MainActor func testLongPrimaryWordsRemainInTheHintWithoutMovingTargets() throws {
        let short = ToolbarViewState(name: "short", tier: .revealed, actionTitle: "Dictate")
        var long = short; long.actionTitle = "Finish this much longer action"
        let small = NSHostingView(rootView: ToolbarRow(state: short)).fittingSize
        let large = NSHostingView(rootView: ToolbarRow(state: long)).fittingSize
        XCTAssertEqual(large.width, small.width)
        XCTAssertEqual(large.height, small.height, accuracy: 1)
        let primary = try XCTUnwrap(buttons(laidOut(ToolbarRow(state: long))).first { $0.accessibilityIdentifier() == "toolbar.primary" } as? ToolbarIconButton)
        XCTAssertEqual(primary.accessibilityLabel(), long.actionTitle)
        XCTAssertEqual(primary.hint, long.actionTitle)
    }

    /// A changing count redrew the row. With proportional digits each redraw
    /// changed its width and re-placed the window under the pointer. The count
    /// now lives in the label, so the label keeps one width per digit.
    @MainActor func testAChangingCountKeepsTheRowTheSameWidth() {
        _ = NSApplication.shared
        func width(_ title: String) -> CGFloat {
            NSHostingView(rootView: ToolbarRow(state: ToolbarViewState(name: "count", tier: .revealed, mode: .snapAndTalk,
                actionTitle: title))).fittingSize.width
        }
        XCTAssertEqual(width("Capture next · 1"), width("Capture next · 8"), accuracy: 0.5, "digits of different shapes resized the window")
        XCTAssertEqual(width("Capture next · 10"), width("Capture next · 99"), accuracy: 0.5)
    }

    /// Start, Stop and a long action all keep the same target, including across a collapse.
    @MainActor func testChangingActionKeepsTheTargetsSteady() {
        var state = ToolbarViewState(name: "width", tier: .revealed, mode: .draw, actionTitle: "Draw")
        let view = laidOut(ToolbarRow(state: state))
        let short = view.fittingSize.width
        state.actionTitle = "End presentation"
        view.rootView = ToolbarRow(state: state); view.layoutSubtreeIfNeeded()
        let long = view.fittingSize.width
        XCTAssertEqual(long, short)
        state.actionTitle = "Draw"
        view.rootView = ToolbarRow(state: state); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.fittingSize.width, long, accuracy: 0.5)
        state.tier = .resting
        view.rootView = ToolbarRow(state: state); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.fittingSize, ToolbarLayout.mark)
        state.tier = .revealed
        view.rootView = ToolbarRow(state: state); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.fittingSize.width, short, accuracy: 0.5)
    }

    @MainActor func testActionAndToolsHintsNameTheirActualControl() throws {
        let state = ToolbarViewState(name: "hint", tier: .revealed, mode: .draw, actionTitle: "Draw", actionHint: "Hold ⌥D", accessory: .tools)
        let view = laidOut(ToolbarRow(state: state))
        let primary = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.primary" } as? ToolbarIconButton)
        let more = try XCTUnwrap(buttons(view).first { $0.accessibilityIdentifier() == "toolbar.accessory" } as? ToolbarIconButton)
        XCTAssertEqual(primary.hint, "Draw · Hold ⌥D")
        XCTAssertEqual(primary.accessibilityHelp(), primary.hint)
        XCTAssertEqual(more.hint, "Tools")
        XCTAssertNil(primary.toolTip, "the native floating hint has no competing system tooltip")
        var noKey = state; noKey.actionHint = nil
        view.rootView = ToolbarRow(state: noKey); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(primary.hint, "Draw")
    }

    func testRevealChromeFollowsTheWindowWithNoSecondClock() {
        for scale in [CGFloat(1), 1.35] {
            let row = ToolbarLayout.rowHeight * scale
            XCTAssertEqual(ToolbarRevealVisuals.progress(viewportHeight: 28, rowHeight: row), 0)
            XCTAssertEqual(ToolbarRevealVisuals.progress(viewportHeight: row, rowHeight: row), 1)
            let halfway = ToolbarRevealVisuals.progress(viewportHeight: (28 + row) / 2, rowHeight: row)
            XCTAssertEqual(halfway, 0.5, accuracy: 0.001)
            for (indicator, rest) in [(ToolbarStatus.Indicator.idle, CGFloat(8)), (.live(.presenting), 8), (.capture, 20), (.failure, 8)] {
                XCTAssertEqual(ToolbarRevealVisuals.capsuleHeight(progress: 0, rowHeight: row, indicator: indicator), rest)
                XCTAssertEqual(ToolbarRevealVisuals.capsuleHeight(progress: halfway, rowHeight: row, indicator: indicator), (rest + row) / 2)
                XCTAssertEqual(ToolbarRevealVisuals.capsuleHeight(progress: 1, rowHeight: row, indicator: indicator), row)
            }
        }
    }

    @MainActor func testImmediateRetargetSettlesSynchronouslyAtRequestedDestination() {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 48, height: 28),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let motion = ToolbarWindowMotion()
        let final = NSRect(x: 200, y: 160, width: 48, height: 28)
        var completions = 0
        motion.settled = { completions += 1 }
        motion.move(panel, to: NSRect(x: 100, y: 100, width: 248, height: 40), animated: true)
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
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 48, height: 28),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let motion = ToolbarWindowMotion()
        var completions = 0
        motion.settled = { completions += 1 }
        let expanded = NSRect(x: 100, y: 100, width: 248, height: 40)
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

    /// The black capsule has white glyphs in both appearances. Live work does not decorate Switch tool.
    @MainActor func testSwitchToolStaysWhiteAndUndecoratedInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var expected: NSColor!
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                expected = WorkbenchPalette.nativeAccent.usingColorSpace(.deviceRGB)
            }
            let busy = ToolbarLiveState(mode: .draw, drawing: true)
            let view = NSHostingView(rootView: ToolbarRow(
                state: ToolbarViewState(name: "busy-colour", tier: .revealed, mode: .draw, choices: ToolbarNextAction.choices(for: busy), isBusy: true),
                accent: WorkbenchPalette.accent)
                .environment(\.colorScheme, name == .darkAqua ? .dark : .light))
            view.appearance = appearance
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            // Only the launcher's 48 points: the next action's bezel is accent too.
            let launcherPixels = Int(ToolbarLayout.launcherWidth * CGFloat(bitmap.pixelsWide) / view.bounds.width)
            var upperMatches = 0, lowerMatches = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<launcherPixels {
                    guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let delta = abs(colour.redComponent - expected.redComponent)
                        + abs(colour.greenComponent - expected.greenComponent)
                        + abs(colour.blueComponent - expected.blueComponent)
                    if y < bitmap.pixelsHigh * 3 / 4,
                       min(colour.redComponent, colour.greenComponent, colour.blueComponent) > 0.92 { upperMatches += 1 }
                    if y >= bitmap.pixelsHigh * 3 / 4, delta < 0.04 { lowerMatches += 1 }
                }
            }
            XCTAssertGreaterThan(upperMatches, 0, "the launcher renders a white glyph in \(name)")
            XCTAssertEqual(lowerMatches, 0, "live work must not decorate Switch tool in \(name)")
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

    /// The chooser is 280 points wide with 36-point rows, the seven tools in order, and it scrolls
    /// only when its display leaves it less than its height.
    @MainActor func testTheChooserMeasures() {
        _ = NSApplication.shared
        let choices = ToolbarNextAction.choices(for: ToolbarLiveState(mode: .dictate))
        for scale in [CGFloat(1), 1.35] {
            let size = NSHostingView(rootView: ToolbarChooserView(model: ToolbarChooserModel(choices: choices), textScale: scale)).fittingSize
            XCTAssertEqual(size.width, ToolbarChooserLayout.width * scale, accuracy: 0.5, "at \(scale)")
            // Rows of 48.6 points at larger text land on whole pixels.
            XCTAssertEqual(size.height, ToolbarChooserLayout.height(rows: 6, scale: scale) + 45 * scale, accuracy: 1, "at \(scale)")
        }
        let short = NSHostingView(rootView: ToolbarChooserView(model: ToolbarChooserModel(choices: choices), available: 150)).fittingSize
        XCTAssertEqual(short.height, 150, accuracy: 0.5, "a short display scrolls the list rather than clipping it")
    }

    /// The chooser's keys: Down, Return by identity, Escape without a change, typed names.
    @MainActor func testTheChooserKeys() {
        var chosen: [ToolbarMode] = [], dismissed = 0
        let model = ToolbarChooserModel(choices: ToolbarNextAction.choices(for: ToolbarLiveState(mode: .dictate)),
                                        choose: { chosen.append($0) }, dismiss: { dismissed += 1 })
        XCTAssertTrue(model.handle(keyCode: 125, characters: nil, time: 0))
        XCTAssertEqual(model.state.highlighted, .snap)
        XCTAssertTrue(model.handle(keyCode: 53, characters: nil, time: 0))
        XCTAssertEqual(dismissed, 1); XCTAssertTrue(chosen.isEmpty, "Escape changes nothing")
        XCTAssertTrue(model.handle(keyCode: 35, characters: "p", time: 1))
        XCTAssertEqual(model.state.highlighted, .present)
        XCTAssertTrue(model.handle(keyCode: 36, characters: "\r", time: 1.1))
        XCTAssertEqual(chosen, [.present])
        XCTAssertFalse(model.handle(keyCode: 48, characters: "\t", time: 2), "Tab is not the chooser's")
    }
}
