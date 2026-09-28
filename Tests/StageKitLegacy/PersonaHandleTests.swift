import AppKit

/// A pointer the checks move by hand, so the real pointer never decides a result.
final class PersonaTestPointer: PersonaPointerTracking {
    var location = CGPoint(x: -20_000, y: -20_000)
    private(set) var clients: [PersonaPointerClient] = []
    func add(_ client: PersonaPointerClient) { if !clients.contains(where: { $0 === client }) { clients.append(client) } }
    func remove(_ client: PersonaPointerClient) { clients.removeAll { $0 === client } }
    func move(to point: CGPoint) { location = point; clients.forEach { $0.pointerMoved(to: point) } }
}

/// Direct movement and resizing (#157): handles are small windows of their
/// own, locked artwork keeps passing clicks through, the voice outline's room
/// never blocks the app beneath, a click is not a drag, and a resize keeps the
/// artwork's shape within its limits and changes only that copy.
final class PersonaHandleTests {
    /// A round badge on transparency, like a presenter's headshot.
    static func badge() -> NSImage {
        NSImage(size: CGSize(width: 240, height: 240), flipped: false) { _ in
            NSColor(srgbRed: 0.93, green: 0.76, blue: 0.35, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 20, y: 20, width: 200, height: 200)).fill()
            NSColor(srgbRed: 0.1, green: 0.2, blue: 0.2, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 80, y: 40, width: 80, height: 110)).fill()
            return true
        }
    }
    /// An opaque card.
    static func card() -> NSImage {
        NSImage(size: CGSize(width: 200, height: 250), flipped: false) { rect in
            NSColor(srgbRed: 0.1, green: 0.4, blue: 0.35, alpha: 1).setFill(); rect.fill(); return true
        }
    }
    private func screen() -> NSScreen? { NSScreen.main ?? NSScreen.screens.first }
    private func displayID(_ screen: NSScreen) -> UInt32? { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }

    /// Delivers a mouse event straight to one of our own views. Nothing is
    /// posted to the system, so other apps never receive it.
    private func send(_ type: NSEvent.EventType, at point: CGPoint, to view: NSView) {
        guard let window = view.window,
              let event = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseUp(with: event)
        }
    }
    private func drag(_ view: NSView, from start: CGPoint, by steps: [CGVector]) {
        send(.leftMouseDown, at: start, to: view)
        for step in steps { send(.leftMouseDragged, at: CGPoint(x: start.x + step.dx, y: start.y + step.dy), to: view) }
        let last = steps.last ?? .zero
        send(.leftMouseUp, at: CGPoint(x: start.x + last.dx, y: start.y + last.dy), to: view)
    }

    // MARK: Geometry

    func testHandlesSitOnTheVisibleArtworkNotItsTransparentRoom() {
        let screen = CGRect(x: 0, y: 25, width: 1512, height: 920)
        // A 240-point badge circle inside a larger window: the voice outline's room around it.
        let visible = CGRect(x: 600, y: 400, width: 240, height: 240)
        let frames = PersonaManipulation.frames(around: visible, within: screen)
        XCTAssertEqual(Set(frames.keys), Set(PersonaHandle.allCases), "A large card has all eight handles")
        let reach = visible.insetBy(dx: -PersonaManipulation.revealDistance, dy: -PersonaManipulation.revealDistance)
        for (handle, frame) in frames {
            XCTAssertTrue(reach.contains(frame), "\(handle) sits within reach of the visible artwork (\(frame))")
            XCTAssertTrue(frame.width * frame.height <= 44 * 18, "\(handle) is small (\(frame.size))")
            XCTAssertFalse(frame.intersects(visible.insetBy(dx: 12, dy: 12)), "\(handle) leaves the artwork's middle to click through")
        }
        // Everything a handle can take is a small share of the room around the artwork.
        let room = 24.0 * 2 * (240 + 240 + 48)
        let taken = frames.values.reduce(0) { $0 + Double($1.width * $1.height) }
        XCTAssertTrue(taken < room * 0.25, "Handles take \(Int(taken)) of \(Int(room)) square points around the artwork")
        XCTAssertTrue(frames[.move].map { $0.midX == visible.midX && $0.minY >= visible.maxY - 2 } ?? false, "The grab handle sits on the top edge")

        // A small card keeps its corners and grab handle; edges too short for handles have none.
        let small = PersonaManipulation.frames(around: CGRect(x: 100, y: 100, width: 60, height: 60), within: screen)
        XCTAssertEqual(Set(small.keys), [.move, .topLeft, .topRight, .bottomLeft, .bottomRight])
        // At the top of the screen the grab handle stays reachable.
        let top = PersonaManipulation.frames(around: CGRect(x: 100, y: screen.maxY - 120, width: 120, height: 120), within: screen)
        XCTAssertTrue(top.values.allSatisfy { screen.contains($0) }, "Handles stay on the visible display")
        XCTAssertTrue(PersonaManipulation.reveals(CGPoint(x: visible.maxX + 20, y: visible.midY), around: visible))
        XCTAssertFalse(PersonaManipulation.reveals(CGPoint(x: visible.maxX + 30, y: visible.midY), around: visible))
    }

    func testResizeFollowsThePointerKeepsTheShapeAndStaysWithinLimits() {
        let artwork = CGRect(x: 500, y: 300, width: 200, height: 250)
        let visible = artwork
        let widths: ClosedRange<CGFloat> = 90...600
        func expectShape(_ rect: CGRect, _ message: String) {
            XCTAssertEqual(Double(rect.width / rect.height), 0.8, accuracy: 0.0001)
        }
        // Dragging the bottom-right corner out along its diagonal grows it; the top-left stays put.
        let grown = PersonaManipulation.resized(artwork, visible: visible, handle: .bottomRight, by: CGVector(dx: 40, dy: -50), widths: widths)
        expectShape(grown, "corner")
        XCTAssertEqual(Double(grown.width), 240, accuracy: 0.5)
        XCTAssertEqual(Double(grown.minX), 500, accuracy: 0.001); XCTAssertEqual(Double(grown.maxY), 550, accuracy: 0.001)
        // The top-left corner pulled inward shrinks it toward the bottom-right.
        let shrunk = PersonaManipulation.resized(artwork, visible: visible, handle: .topLeft, by: CGVector(dx: 40, dy: -50), widths: widths)
        expectShape(shrunk, "corner")
        XCTAssertEqual(Double(shrunk.width), 160, accuracy: 0.5)
        XCTAssertEqual(Double(shrunk.maxX), 700, accuracy: 0.001); XCTAssertEqual(Double(shrunk.minY), 300, accuracy: 0.001)
        // Edges: across, with the middle of the opposite side fixed.
        let wider = PersonaManipulation.resized(artwork, visible: visible, handle: .right, by: CGVector(dx: 50, dy: 30), widths: widths)
        expectShape(wider, "edge")
        XCTAssertEqual(Double(wider.width), 250, accuracy: 0.001); XCTAssertEqual(Double(wider.midY), Double(artwork.midY), accuracy: 0.001)
        let taller = PersonaManipulation.resized(artwork, visible: visible, handle: .bottom, by: CGVector(dx: 0, dy: -125), widths: widths)
        expectShape(taller, "edge")
        XCTAssertEqual(Double(taller.height), 375, accuracy: 0.001); XCTAssertEqual(Double(taller.maxY), 550, accuracy: 0.001)
        let narrower = PersonaManipulation.resized(artwork, visible: visible, handle: .left, by: CGVector(dx: 60, dy: 0), widths: widths)
        XCTAssertEqual(Double(narrower.width), 140, accuracy: 0.001); XCTAssertEqual(Double(narrower.maxX), 700, accuracy: 0.001)
        // Limits hold however far the pointer goes.
        XCTAssertEqual(PersonaManipulation.resized(artwork, visible: visible, handle: .bottomRight, by: CGVector(dx: 2_000, dy: -2_000), widths: widths).width, 600)
        XCTAssertEqual(PersonaManipulation.resized(artwork, visible: visible, handle: .bottomRight, by: CGVector(dx: -2_000, dy: 2_000), widths: widths).width, 90)
        // A round badge inside transparent padding resizes about its visible circle.
        let badgeArtwork = CGRect(x: 0, y: 0, width: 240, height: 240), circle = CGRect(x: 20, y: 20, width: 200, height: 200)
        let badge = PersonaManipulation.resized(badgeArtwork, visible: circle, handle: .topRight, by: CGVector(dx: 50, dy: 50), widths: 10...1_000)
        XCTAssertEqual(Double(badge.width), 300, accuracy: 0.5)
        XCTAssertEqual(Double(badge.minX + 20 * badge.width / 240), 20, accuracy: 0.01, file: #filePath, line: #line)
        XCTAssertEqual(PersonaManipulation.resized(artwork, visible: visible, handle: .move, by: CGVector(dx: 50, dy: 50), widths: widths), artwork)
        XCTAssertEqual(PersonaManipulation.dragThreshold, 4, "The same four points as the floating toolbar")
    }

    // MARK: Native windows

    /// Locked artwork moves and resizes from its handles while clicks keep
    /// passing through its body and the voice outline's room; the lock stays.
    func testLockedArtworkMovesAndResizesFromItsHandlesAndStaysLocked() throws {
        guard let screen = screen() else { XCTAssertTrue(false, "The native handle test needs a display"); return }
        let pointer = PersonaTestPointer()
        let controller = PersonaOverlayController(pointer: pointer, revealDelay: 0)
        defer { controller.shutdown() }
        guard let window = controller.window else { return }
        var placements: [PersonaOverlayState] = []
        controller.onPlacementChange = { placements.append($0) }
        var selections = 0
        controller.onSelection = { selections += 1 }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier, previousKey = NSApp.keyWindow
        let state = PersonaOverlayState(x: 0.5, y: 0.5, width: 0.16, screenID: displayID(screen), locked: true)
        controller.setVoiceRing(true)
        _ = controller.show(image: Self.badge(), name: "Synthetic persona", state: state)
        guard let visible = controller.visibleFrame else { XCTAssertTrue(false, "The artwork's visible edge is known"); return }
        XCTAssertTrue(window.frame.width > visible.width + 10, "The voice outline's room surrounds the badge")

        // Far away: no handles, and the locked artwork ignores the pointer.
        XCTAssertTrue(controller.handleWindows.isEmpty, "Handles stay hidden until the pointer comes near")
        XCTAssertTrue(window.ignoresMouseEvents)
        for point in [CGPoint(x: visible.midX, y: visible.midY), CGPoint(x: window.frame.minX + 3, y: window.frame.minY + 3)] {
            pointer.move(to: point)
            XCTAssertTrue(window.ignoresMouseEvents && !controller.acceptsClick(at: point), "Locked artwork and its room pass clicks through")
        }
        // Near: small handle windows appear, above the artwork, that never take focus.
        pointer.move(to: CGPoint(x: visible.maxX + 10, y: visible.midY))
        let shown = controller.handleWindows
        XCTAssertEqual(Set(shown.keys), Set(PersonaHandle.allCases))
        for (handle, panel) in shown {
            XCTAssertTrue(panel.isVisible && !panel.ignoresMouseEvents, "\(handle) takes the pointer")
            XCTAssertFalse(panel.canBecomeKey || panel.canBecomeMain)
            XCTAssertEqual(panel.level, window.level)
            XCTAssertTrue(panel.frame.width <= 44 && panel.frame.height <= 30)
        }
        XCTAssertTrue(window.ignoresMouseEvents, "Showing handles does not unlock the artwork")

        // The grab handle: a small wobble is a click; a drag moves the copy once.
        guard let grab = shown[.move]?.contentView else { return }
        let before = window.frame
        drag(grab, from: CGPoint(x: shown[.move]!.frame.midX, y: shown[.move]!.frame.midY), by: [CGVector(dx: 2, dy: 1), CGVector(dx: -1, dy: 2)])
        XCTAssertEqual(window.frame, before, "A click on the grab handle moves nothing")
        XCTAssertTrue(placements.isEmpty)
        drag(grab, from: CGPoint(x: shown[.move]!.frame.midX, y: shown[.move]!.frame.midY), by: [CGVector(dx: 3, dy: 0), CGVector(dx: 40, dy: -30), CGVector(dx: 60, dy: -40)])
        XCTAssertEqual(Double(window.frame.minX), Double(before.minX + 60), accuracy: 1)
        XCTAssertEqual(Double(window.frame.minY), Double(before.minY - 40), accuracy: 1)
        XCTAssertEqual(placements.count, 1)
        XCTAssertTrue(placements.last?.locked == true, "Moving from the handle keeps the lock")
        XCTAssertTrue(controller.handleWindows[.move].map { abs($0.frame.midX - controller.visibleFrame!.midX) < 1 } ?? false, "Handles follow the artwork")
        pointer.move(to: CGPoint(x: controller.visibleFrame!.maxX + 10, y: controller.visibleFrame!.midY))

        // Dragged off the display, the copy comes back fully on screen when released.
        if let grabHandle = controller.handleWindows[.move] {
            let parked = placements.count
            drag(grabHandle.contentView!, from: CGPoint(x: grabHandle.frame.midX, y: grabHandle.frame.midY), by: [CGVector(dx: 5_000, dy: 5_000)])
            XCTAssertEqual(placements.count, parked + 1)
            XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(window.frame) }, "Released off screen, the copy returns to a visible display")
            // Back to the middle of the display from the same handle.
            pointer.move(to: CGPoint(x: controller.visibleFrame!.midX, y: controller.visibleFrame!.maxY + 6))
            if let back = controller.handleWindows[.move] {
                drag(back.contentView!, from: CGPoint(x: back.frame.midX, y: back.frame.midY),
                     by: [CGVector(dx: before.midX + 60 - window.frame.midX, dy: before.midY - 40 - window.frame.midY)])
            } else { XCTAssertTrue(false, "The grab handle shows again beside the recovered copy") }
            XCTAssertEqual(Double(window.frame.midX), Double(before.midX + 60), accuracy: 1)
        }
        // A corner handle resizes, keeping the badge round and the opposite corner still.
        pointer.move(to: CGPoint(x: controller.visibleFrame!.maxX + 10, y: controller.visibleFrame!.midY))
        guard let corner = controller.handleWindows[.bottomRight], let movedVisible = controller.visibleFrame else { return }
        let width = placements.last?.width ?? 0, resizes = placements.count
        drag(corner.contentView!, from: CGPoint(x: corner.frame.midX, y: corner.frame.midY), by: [CGVector(dx: 30, dy: -30), CGVector(dx: 50, dy: -50)])
        guard let resized = controller.visibleFrame else { return }
        XCTAssertEqual(placements.count, resizes + 1)
        XCTAssertTrue((placements.last?.width ?? 0) > width, "Dragging a corner outward enlarges the copy")
        XCTAssertEqual(Double(resized.width / resized.height), 1, accuracy: 0.02)
        XCTAssertEqual(Double(resized.minX), Double(movedVisible.minX), accuracy: 2)
        XCTAssertEqual(Double(resized.maxY), Double(movedVisible.maxY), accuracy: 2)
        XCTAssertTrue(placements.last?.locked == true, "Resizing from a handle keeps the lock")
        XCTAssertTrue(window.ignoresMouseEvents, "The body still passes clicks through")
        XCTAssertEqual(selections, 0, "Handles never change which copy is selected")
        XCTAssertTrue(NSApp.keyWindow === previousKey, "Handles never take keyboard focus")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost)

        // Hide removes the handles and keeps the copy's size, position and lock.
        let kept = placements.last!
        controller.hide()
        XCTAssertTrue(controller.handleWindows.isEmpty)
        XCTAssertTrue(pointer.clients.isEmpty, "A hidden persona stops following the pointer")
        _ = controller.show(image: Self.badge(), name: "Synthetic persona", state: kept)
        XCTAssertEqual(controller.visibleFrame.map { Double($0.width) } ?? 0, Double(resized.width), accuracy: 1)
        XCTAssertTrue(window.ignoresMouseEvents)
    }

    /// A pointer passing by does not flash the handles; one that pauses near
    /// the artwork shows them, and leaving hides them at once.
    func testHandlesAppearAfterABriefPauseNearTheArtwork() throws {
        guard let screen = screen() else { XCTAssertTrue(false, "The native handle test needs a display"); return }
        let pointer = PersonaTestPointer()
        let controller = PersonaOverlayController(pointer: pointer)
        defer { controller.shutdown() }
        _ = controller.show(image: Self.card(), name: "Synthetic persona", state: PersonaOverlayState(x: 0.5, y: 0.5, width: 0.14, screenID: displayID(screen), locked: true))
        guard let visible = controller.visibleFrame else { return }
        let near = CGPoint(x: visible.maxX + 10, y: visible.midY), away = CGPoint(x: visible.maxX + 200, y: visible.midY)
        pointer.move(to: near)
        XCTAssertTrue(controller.handleWindows.isEmpty, "Not at once")
        pointer.move(to: away)
        RunLoop.current.run(until: Date().addingTimeInterval(PersonaManipulation.revealDelay + 0.1))
        XCTAssertTrue(controller.handleWindows.isEmpty, "A pointer that passed by leaves no handles")
        pointer.move(to: near)
        let paused = Date()
        // Wait for the reveal timer rather than a fixed slice past it: a busy CI runner can fire it late.
        let deadline = Date().addingTimeInterval(PersonaManipulation.revealDelay + 2)
        while controller.handleWindows.isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(controller.handleWindows.count, PersonaHandle.allCases.count, "A pause near the artwork shows its handles")
        // They wait for the pause: a zero delay would show them straight away.
        XCTAssertTrue(Date().timeIntervalSince(paused) >= PersonaManipulation.revealDelay - 0.03,
                      "The handles appear only after the pointer has paused for the reveal delay")
        pointer.move(to: away)
        XCTAssertTrue(controller.handleWindows.isEmpty, "Leaving hides them at once")
    }

    /// Unlocked artwork drags by its body without treating a click as a drag,
    /// and the outline's room and a badge's transparent corners never block.
    func testUnlockedArtworkTakesClicksOnlyOnItsBody() throws {
        guard let screen = screen() else { XCTAssertTrue(false, "The native handle test needs a display"); return }
        let pointer = PersonaTestPointer()
        let controller = PersonaOverlayController(pointer: pointer, revealDelay: 0)
        defer { controller.shutdown() }
        guard let window = controller.window, let artwork = window.contentView else { return }
        var placements: [PersonaOverlayState] = []
        controller.onPlacementChange = { placements.append($0) }
        var selections = 0
        controller.onSelection = { selections += 1 }
        controller.setVoiceRing(true)
        _ = controller.show(image: Self.badge(), name: "Synthetic persona", state: PersonaOverlayState(x: 0.3, y: 0.4, width: 0.16, screenID: displayID(screen)))
        guard let visible = controller.visibleFrame else { return }
        let middle = CGPoint(x: visible.midX, y: visible.midY)
        let room = CGPoint(x: window.frame.minX + 2, y: window.frame.midY)
        let corner = CGPoint(x: visible.minX + 4, y: visible.minY + 4)
        pointer.move(to: middle)
        XCTAssertFalse(window.ignoresMouseEvents, "The body takes the pointer")
        XCTAssertTrue(controller.acceptsClick(at: middle))
        pointer.move(to: room)
        XCTAssertTrue(window.ignoresMouseEvents, "The voice outline's room passes clicks through")
        pointer.move(to: corner)
        XCTAssertTrue(window.ignoresMouseEvents, "A round badge's transparent corner passes clicks through")
        pointer.move(to: CGPoint(x: -20_000, y: -20_000))
        XCTAssertFalse(window.ignoresMouseEvents)

        pointer.move(to: middle)
        let start = window.frame
        drag(artwork, from: middle, by: [])
        XCTAssertEqual(window.frame, start); XCTAssertTrue(placements.isEmpty, "A click is not a drag")
        XCTAssertEqual(selections, 1, "A click selects the copy")
        drag(artwork, from: middle, by: [CGVector(dx: 2, dy: 2), CGVector(dx: 3, dy: -1)])
        XCTAssertEqual(window.frame, start); XCTAssertTrue(placements.isEmpty, "A wobble under four points is still a click")
        drag(artwork, from: middle, by: [CGVector(dx: 3, dy: 3), CGVector(dx: 30, dy: 20)])
        XCTAssertEqual(Double(window.frame.minX), Double(start.minX + 30), accuracy: 1)
        XCTAssertEqual(placements.count, 1)
        XCTAssertTrue(placements.last?.locked == false)
    }

    /// A controller released while its persona shows still removes the shared
    /// pointer monitors, so nothing keeps following the pointer.
    func testReleasedControllerStopsFollowingThePointer() throws {
        guard let screen = screen() else { XCTAssertTrue(false, "The native handle test needs a display"); return }
        let tracker = PersonaPointerTracker()
        var controller: PersonaOverlayController?
        weak var released: PersonaOverlayController?
        var window: NSWindow?
        defer { window?.orderOut(nil) }
        // Autorelease pools stand in for the run loop's, so the release happens here.
        autoreleasepool {
            controller = PersonaOverlayController(pointer: tracker, revealDelay: 0)
            released = controller; window = controller?.window
            _ = controller?.show(image: Self.card(), name: "Synthetic persona", state: PersonaOverlayState(x: 0.5, y: 0.5, width: 0.1, screenID: displayID(screen), locked: true))
        }
        XCTAssertTrue(tracker.isFollowing, "A shown persona follows the pointer")
        autoreleasepool { controller = nil }
        XCTAssertTrue(released == nil, "The controller was released")
        XCTAssertFalse(tracker.isFollowing, "Released while shown, it stops following the pointer")
    }

    /// A card moved under a still pointer, as a layout restore does, takes
    /// clicks by where the pointer is now, even if no pointer event arrived.
    func testCardMovedUnderAStillPointerTakesClicksByWhereItIs() throws {
        guard let screen = screen() else { XCTAssertTrue(false, "The native handle test needs a display"); return }
        let pointer = PersonaTestPointer()
        let controller = PersonaOverlayController(pointer: pointer, revealDelay: 0)
        defer { controller.shutdown() }
        guard let window = controller.window else { return }
        controller.setVoiceRing(true)
        let first = PersonaOverlayState(x: 0.3, y: 0.5, width: 0.16, screenID: displayID(screen))
        _ = controller.show(image: Self.badge(), name: "Synthetic persona", state: first)
        guard let visible = controller.visibleFrame else { return }
        // The pointer rests on the badge's body; its clicks go to the artwork.
        pointer.move(to: CGPoint(x: visible.midX, y: visible.midY))
        XCTAssertFalse(window.ignoresMouseEvents)
        // The card moves by a layout restore, and the pointer, still, is now in
        // the outline's room beside it; no pointer event reports that.
        var second = first; second.x = 0.6
        controller.configure(image: Self.badge(), name: "Synthetic persona", state: second)
        guard let moved = controller.visibleFrame else { return }
        pointer.location = CGPoint(x: moved.minX - 2, y: moved.midY)
        controller.configure(image: Self.badge(), name: "Synthetic persona", state: second)
        XCTAssertTrue(window.frame.contains(pointer.location), "The still pointer is inside the moved window")
        XCTAssertTrue(window.ignoresMouseEvents, "The outline's room passes the click through after the move")
    }

    /// Tall artwork is limited by the display's height, so a wider Size shows at
    /// the same width. A resize that cannot grow it keeps its Size, instead of
    /// the Size slider jumping lower; one that shrinks it round-trips.
    func testTallArtworkKeepsItsSizeThroughAResize() throws {
        guard let screen = screen() else { XCTAssertTrue(false, "The native handle test needs a display"); return }
        for (width, height) in [(180, 600), (60, 600)] {
            let tall = NSImage(size: CGSize(width: width, height: height), flipped: false) { rect in
                NSColor(srgbRed: 0.2, green: 0.4, blue: 0.5, alpha: 1).setFill(); rect.fill(); return true
            }
            let requested = PersonaGeometry.rect(PersonaPlacement(image: "persona.png", width: 0.16), imageSize: tall.size, in: screen.visibleFrame.size)
            guard requested.width < screen.visibleFrame.width * 0.16 - 1 else { continue } // A display tall enough never limits it.
            let pointer = PersonaTestPointer()
            let controller = PersonaOverlayController(pointer: pointer, revealDelay: 0)
            defer { controller.shutdown() }
            var placements: [PersonaOverlayState] = []
            controller.onPlacementChange = { placements.append($0) }
            _ = controller.show(image: tall, name: "Synthetic persona", state: PersonaOverlayState(x: 0.5, y: 0.5, width: 0.16, screenID: displayID(screen), locked: true))
            guard let before = controller.visibleFrame else { continue }
            pointer.move(to: CGPoint(x: before.maxX + 8, y: before.midY))
            guard let grow = controller.handleWindows[.bottomRight] else { XCTAssertTrue(false, "Handles show"); continue }
            drag(grow.contentView!, from: CGPoint(x: grow.frame.midX, y: grow.frame.midY), by: [CGVector(dx: 20, dy: -20), CGVector(dx: 80, dy: -80)])
            XCTAssertEqual(placements.last?.width ?? 0, 0.16, accuracy: 0.0001, file: #filePath, line: #line)
            XCTAssertEqual(Double(controller.visibleFrame?.width ?? 0), Double(before.width), accuracy: 1)
            // Shrinking, where the artwork allows it, stores the smaller Size, which shows at the same width again.
            let smallest = PersonaGeometry.rect(PersonaPlacement(image: "persona.png", width: 0.06), imageSize: tall.size, in: screen.visibleFrame.size)
            guard smallest.width < before.width - 4 else { continue }
            pointer.move(to: CGPoint(x: before.maxX + 8, y: before.midY))
            guard let shrink = controller.handleWindows[.bottomRight] else { continue }
            drag(shrink.contentView!, from: CGPoint(x: shrink.frame.midX, y: shrink.frame.midY), by: [CGVector(dx: -10, dy: 10), CGVector(dx: -30, dy: 90)])
            guard let smaller = controller.visibleFrame, let stored = placements.last else { continue }
            XCTAssertTrue(smaller.width < before.width - 2, "The card shrank")
            XCTAssertTrue(stored.width < 0.16)
            _ = controller.show(image: tall, name: "Synthetic persona", state: stored)
            XCTAssertEqual(Double(controller.visibleFrame?.width ?? 0), Double(smaller.width), accuracy: 1)
        }
    }

    /// Set WORKBENCH_LAYOUT_EVIDENCE to write renders of the handles around
    /// small and large, round and rectangular artwork, locked, with the voice
    /// outline on, over half a light slide and half a dark editor.
    func testOffscreenHandleRenders() throws {
        guard let output = ProcessInfo.processInfo.environment["WORKBENCH_LAYOUT_EVIDENCE"], let screen = screen() else { return }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, image) in [("badge", Self.badge()), ("card", Self.card())] {
            for (size, width) in [("small", 0.07), ("large", 0.2)] {
                let pointer = PersonaTestPointer()
                let controller = PersonaOverlayController(pointer: pointer, revealDelay: 0)
                defer { controller.shutdown() }
                controller.setVoiceRing(true)
                _ = controller.show(image: image, name: "Synthetic persona", state: PersonaOverlayState(x: 0.5, y: 0.5, width: width, screenID: displayID(screen), locked: true))
                guard let window = controller.window, let visible = controller.visibleFrame else { continue }
                pointer.move(to: CGPoint(x: visible.maxX + 8, y: visible.midY))
                let handles = controller.handleWindows
                let area = handles.values.reduce(window.frame) { $0.union($1.frame) }.insetBy(dx: -24, dy: -24)
                let scale: CGFloat = 2
                guard let context = CGContext(data: nil, width: Int(area.width * scale), height: Int(area.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                context.scaleBy(x: scale, y: scale)
                context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: area.width / 2, height: area.height))
                context.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor); context.fill(CGRect(x: area.width / 2, y: 0, width: area.width / 2, height: area.height))
                for drawn in [window] + PersonaHandle.allCases.compactMap({ handles[$0] }) {
                    guard let layer = drawn.contentView?.layer else { continue }
                    drawn.contentView?.layoutSubtreeIfNeeded()
                    context.saveGState()
                    context.translateBy(x: drawn.frame.minX - area.minX, y: drawn.frame.minY - area.minY)
                    layer.render(in: context)
                    context.restoreGState()
                }
                guard let rendered = context.makeImage(), let data = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else { continue }
                let url = directory.appendingPathComponent("persona-handles-\(name)-\(size).png")
                try data.write(to: url)
                print("Offscreen persona handles: " + url.path)
            }
        }
    }

    /// In a prepared set, a handle changes only its own copy, and saving stays explicit.
    func testHandlesChangeOnlyTheirOwnCopy() throws {
        guard let screen = screen() else { XCTAssertTrue(false, "The native handle test needs a display"); return }
        let pointer = PersonaTestPointer()
        var made: [PersonaOverlayController] = []
        let candidate = PersonaSessionCandidate(id: UUID(), label: "Presenter", image: Self.card())
        let first = PersonaOverlayItem(personaID: candidate.id, placement: PersonaOverlayState(x: 0.2, y: 0.3, width: 0.14, screenID: displayID(screen), locked: true))
        let second = PersonaOverlayItem(personaID: candidate.id, placement: PersonaOverlayState(x: 0.7, y: 0.3, width: 0.14, screenID: displayID(screen), locked: false))
        let group = PersonaGroup(name: "Private group", personaIDs: [candidate.id], overlays: [first, second])
        let session = try PersonaSessionController(groups: [PersonaPreparedSessionGroup(source: group, label: "Set 1", candidates: [candidate], overlays: [first, second])],
                                                   initialGroupID: group.id, canSave: true,
                                                   makePanel: { let controller = PersonaOverlayController(pointer: pointer, revealDelay: 0); made.append(controller); return controller })
        defer { session.end() }
        session.start()
        XCTAssertEqual(made.count, 2)
        guard let target = made.last, let visible = target.visibleFrame else { return }
        pointer.move(to: CGPoint(x: visible.minX - 8, y: visible.midY))
        XCTAssertTrue(made.first?.handleWindows.isEmpty == true, "Only the copy under the pointer shows handles")
        guard let edge = target.handleWindows[.left] else { XCTAssertTrue(false, "The copy near the pointer shows its handles"); return }
        drag(edge.contentView!, from: CGPoint(x: edge.frame.midX, y: edge.frame.midY), by: [CGVector(dx: -40, dy: 0)])
        let layout = session.currentLayout
        XCTAssertEqual(layout[0].placement, first.placement, "The other copy is unchanged")
        XCTAssertTrue(layout[1].placement.width > second.placement.width, "The dragged copy grew")
        XCTAssertEqual(layout[1].placement.locked, false); XCTAssertEqual(layout[0].placement.locked, true)
        XCTAssertTrue(session.state.hasUnsavedLayout, "Saving the layout stays explicit")
        // Hide all and show again keep both copies as they were.
        session.pause(); session.resume()
        XCTAssertEqual(session.currentLayout.map(\.placement.width), layout.map(\.placement.width))
        XCTAssertEqual(session.currentLayout.map(\.placement.locked), [true, false])
    }
}
