import AppKit
import AVFoundation

final class PhonePresentationTests {
    func testOnePhoneScreenIsAdoptedAndALostDeviceNeverSwitches() {
        let muxed = DemoSource(id: "muxed-source", name: "Ethan’s iPhone", isScreen: true)
        let camera = DemoSource(id: "camera", name: "Camera", isScreen: false)
        var recovery = CaptureRecovery()
        XCTAssertEqual(recovery.candidate(in: [muxed]), muxed.id, "The one phone screen shows and is remembered")
        XCTAssertTrue(recovery.candidate(in: [camera]) == nil, "A plain video device still needs a choice")
        XCTAssertEqual(recovery.candidate(in: [muxed, camera]), muxed.id, "A camera beside the phone does not make it a choice")
        XCTAssertTrue(recovery.candidate(in: [muxed, DemoSource(id: "second", name: "iPad", isScreen: true)]) == nil, "Two screens need a choice")
        _ = recovery.select(muxed.id)
        XCTAssertEqual(recovery.candidate(in: [camera, muxed]), muxed.id)
        recovery.invalidateSession()
        XCTAssertEqual(recovery.candidate(in: [muxed]), muxed.id, "A remembered choice reconnects without choosing again")
        XCTAssertTrue(recovery.candidate(in: [camera]) == nil, "Loss of the remembered source never opens another device")
        XCTAssertTrue(recovery.candidate(in: [DemoSource(id: "other", name: "Other iPhone", isScreen: true)]) == nil, "Not even another phone")
    }

    func testNativeHandoffWaitsForBothCaptureAndWindowInEitherOrder() {
        for captureFirst in [true, false] {
            let operation = PresentationHandoff()
            var openings = 0
            XCTAssertTrue(operation.request { openings += 1 })
            if captureFirst { operation.captureDidStop() } else { operation.presentationDidClose() }
            XCTAssertEqual(openings, 0, "Neither resource alone permits the other app to open")
            XCTAssertFalse(operation.completed)
            if captureFirst { operation.presentationDidClose() } else { operation.captureDidStop() }
            XCTAssertEqual(openings, 1)
            XCTAssertTrue(operation.completed)
            operation.captureDidStop(); operation.presentationDidClose()
            XCTAssertEqual(openings, 1, "Repeated delegate/teardown callbacks do not open twice")
        }
    }

    func testHandoffKeepsFirstRequestAndDoesNotRetryFailedLaunchOrOrdinaryClose() {
        let operation = PresentationHandoff()
        var events: [String] = []
        XCTAssertTrue(operation.request { events.append("attempt failed") })
        XCTAssertFalse(operation.request { events.append("replacement") }, "Repeated clicks cannot change the accepted destination")
        operation.presentationDidClose(); operation.captureDidStop()
        XCTAssertEqual(events, ["attempt failed"])
        XCTAssertFalse(operation.request { events.append("retry") })
        operation.presentationDidClose(); operation.captureDidStop()
        XCTAssertEqual(events, ["attempt failed"], "A launch failure must not retry or reacquire capture automatically")

        let ordinaryClose = PresentationHandoff()
        ordinaryClose.captureDidStop(); ordinaryClose.presentationDidClose()
        XCTAssertFalse(ordinaryClose.request { events.append("late") }, "A closed presentation cannot later initiate a handoff")
        XCTAssertEqual(events, ["attempt failed"])
    }

    func testHandoffWaitsThroughFailedNativeTransitionAndRepeatedEnd() {
        var lifecycle = PresentationLifecycle()
        let operation = PresentationHandoff()
        var openings = 0
        lifecycle.willEnter()
        XCTAssertTrue(operation.request { openings += 1 })
        XCTAssertEqual(lifecycle.requestEnd(), .none)
        XCTAssertEqual(lifecycle.requestEnd(), .none)
        operation.captureDidStop()
        XCTAssertEqual(openings, 0)
        XCTAssertEqual(lifecycle.failedToEnter(), .finish)
        lifecycle.complete(); operation.presentationDidClose()
        XCTAssertEqual(openings, 1)
        XCTAssertEqual(lifecycle.requestEnd(), .none)
        operation.presentationDidClose()
        XCTAssertEqual(openings, 1)
    }

    func testCaptureStopCompletionRetainsHandoffAfterPresenterRelease() {
        // This constructs a stopped capture only: no start, discovery, device,
        // permission prompt, native window, or user preference is accessed.
        let capture = DemoCapture(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var operation: PresentationHandoff? = PresentationHandoff()
        weak let retainedOperation = operation
        var openings = 0
        var callbackOnMain = false
        XCTAssertTrue(operation!.request { openings += 1 })
        operation!.presentationDidClose()
        capture.stop { [pending = operation!] in
            callbackOnMain = Thread.isMainThread
            pending.captureDidStop()
        }
        operation = nil // DemoScenes releases its presenter in onEnd.
        XCTAssertNotNil(retainedOperation)
        XCTAssertEqual(openings, 0, "stop must not claim synchronous completion before its queue drains")
        let deadline = Date().addingTimeInterval(3)
        while openings == 0 && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(openings, 1)
        XCTAssertTrue(callbackOnMain)
    }
}
