import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Synthetic AVFoundation for the real capture owner: the screens it offers, a camera
/// permission whose answer the check releases when it chooses, sessions that never touch a
/// device, and the frame outputs the capture created, so a check can deliver a frame the way
/// AVFoundation does. DemoCapture calls it on its own queue; the check reads it through that
/// queue (`SyntheticCaptureHardware.read`).
final class SyntheticCaptureHardware: CaptureHardware {
    var available: [DemoSource]
    var access: AVAuthorizationStatus
    private(set) var pendingAnswers: [(Bool) -> Void] = []
    private(set) var opened: [String] = []
    private(set) var outputs: [AVCaptureVideoDataOutput] = []
    private(set) var discovering = false
    /// Kept after discovery stops, so a check can fire a change that lands late.
    private(set) var changed: (() -> Void)?
    init(available: [DemoSource], access: AVAuthorizationStatus) { self.available = available; self.access = access }
    func startDiscovery(changed: @escaping () -> Void) { discovering = true; self.changed = changed }
    func stopDiscovery() { discovering = false }
    func sources() -> [DemoSource] { available }
    func isConnected(_ id: String) -> Bool { available.contains { $0.id == id } }
    func authorization() -> AVAuthorizationStatus { access }
    func requestAccess(_ completion: @escaping (Bool) -> Void) { pendingAnswers.append(completion) }
    func openSession(_ id: String, output: AVCaptureVideoDataOutput,
                     attach: (AVCaptureSession, AVCaptureInput.Port) -> Void) throws -> AVCaptureSession? {
        opened.append(id); outputs.append(output)
        return AVCaptureSession() // Never configured or started: no device is opened.
    }
    func read<T>(_ capture: DemoCapture, _ body: (SyntheticCaptureHardware) -> T) -> T { capture.queue.sync { body(self) } }
}

/// End through the real owners as the app runs them: DemoScenes admits the capture,
/// DemoPresentation ends the stage, DemoCapture runs the session on its queue and
/// PhoneLinkMonitor mirrors it. Only AVFoundation is synthetic. The stage window is a
/// real window, shown briefly and closed by End. Nothing reads or writes the person's
/// scenes, permissions or devices.
final class PhoneEndTests {
    private let phone = DemoSource(id: "screen-1", name: "Ethan’s iPhone", isScreen: true)
    private let card = DemoSource(id: "card-2", name: "Capture card", isScreen: false)
    private let frame = CGSize(width: 1320, height: 2868)

    private func makeScenes(_ hardware: SyntheticCaptureHardware) throws -> (DemoScenes, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneEnd-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let backdrop = root.appendingPathComponent("backdrop.png")
        try png().write(to: backdrop)
        let scenes = DemoScenes(root: root.appendingPathComponent("Scenes"), systemIntegrationEnabled: false, captureHardware: hardware)
        // The app's shared live controls: End does not reopen a scenes window.
        scenes.usesSharedControls = true
        try scenes.addImage(backdrop, name: "Customer demo")
        XCTAssertTrue(scenes.selected?.showsPhone == true, "A new scene has the device frame")
        return (scenes, root)
    }
    private func png() -> Data {
        let context = CGContext(data: nil, width: 160, height: 100, bitsPerComponent: 8, bytesPerRow: 640,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.82, blue: 0.86, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
        let output = NSMutableData(); let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); CGImageDestinationFinalize(destination)
        return output as Data
    }
    @discardableResult private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        return condition()
    }
    /// Lets every queued capture and main-thread callback run.
    private func settle(_ seconds: TimeInterval = 0.4) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
    /// The phone's status as every Present surface reads it, from its one owner (tests run on main).
    private func words(_ scenes: DemoScenes) -> PhoneLinkStatus { MainActor.assumeIsolated { scenes.phoneLink.status } }
    private func deliverFrame(_ scenes: DemoScenes, from output: AVCaptureOutput) {
        let capture = scenes.capture, size = frame
        capture.queue.async { capture.frameArrived(size, from: output) }
    }

    /// Ethan's flow with a first-use permission: the page shows the one phone screen, the
    /// macOS prompt is up, Present, End. The answer arrives after End and opens nothing; the
    /// page staying visible, being covered and uncovered, a new selection and a late discovery
    /// change do not either. Only Reconnect takes the phone back.
    func testEndWithAPendingPermissionStaysEndedWhenTheAnswerArrivesLate() throws {
        let hardware = SyntheticCaptureHardware(available: [phone], access: .notDetermined)
        let (scenes, root) = try makeScenes(hardware)
        defer { scenes.shutdown(); try? FileManager.default.removeItem(at: root) }
        let capture = scenes.capture
        scenes.setPageVisible(true)
        XCTAssertTrue(waitUntil { capture.phase == .waitingForAccess }, "The page's preview asks macOS once for the one phone screen")
        XCTAssertEqual(hardware.read(capture) { $0.pendingAnswers.count }, 1)
        scenes.startDemo(mode: .windowed)
        XCTAssertTrue(scenes.isPresenting)
        scenes.endPresentation()
        XCTAssertTrue(waitUntil { !scenes.isPresenting })
        XCTAssertTrue(waitUntil { hardware.read(capture) { !$0.discovering } }, "End stops the capture although the page is still on screen")
        XCTAssertTrue(waitUntil { capture.phase == .idle }, "The permission wait ends with the capture")
        XCTAssertTrue(waitUntil { self.words(scenes).phase == .ended })
        XCTAssertEqual(words(scenes).step, .reconnect)

        // The person answers the prompt after End, on AVFoundation's own thread.
        let answers = hardware.read(capture) { hardware in hardware.access = .authorized; return hardware.pendingAnswers }
        DispatchQueue.global().async { answers.forEach { $0(true) } }
        settle()
        XCTAssertEqual(hardware.read(capture) { $0.opened }, [], "Permission granted after End opens nothing")
        XCTAssertEqual(capture.phase, .idle)
        XCTAssertTrue(capture.heldDeviceID == nil)
        // A discovery change that lands late, and the page living on, do not take it back either.
        hardware.read(capture) { $0.changed }?()
        scenes.setPageVisible(false); scenes.setPageVisible(true)
        scenes.selectedID = scenes.selectedID
        settle()
        XCTAssertEqual(hardware.read(capture) { $0.opened }, [], "Covering, uncovering and reselecting are not a deliberate action")
        XCTAssertFalse(hardware.read(capture) { $0.discovering })
        XCTAssertEqual(words(scenes).phase, .ended)

        scenes.reconnectPhone()
        XCTAssertTrue(waitUntil { hardware.read(capture) { $0.opened } == [self.phone.id] }, "Reconnect is deliberate: the phone shows again, once")
        XCTAssertTrue(waitUntil { words(scenes).phase != .ended })
    }

    /// A frame already on its way when End is pressed, and one that lands after, never make the
    /// phase live again and never reopen the device. Present is the other way back.
    func testALateFrameAfterEndNeitherGoesLiveNorReopens() throws {
        let hardware = SyntheticCaptureHardware(available: [phone], access: .authorized)
        let (scenes, root) = try makeScenes(hardware)
        defer { scenes.shutdown(); try? FileManager.default.removeItem(at: root) }
        let capture = scenes.capture
        scenes.setPageVisible(true)
        XCTAssertTrue(waitUntil { hardware.read(capture) { $0.opened } == [self.phone.id] }, "The page adopts the one phone screen without a click")
        guard let output = hardware.read(capture, { $0.outputs.first }) else { return }
        deliverFrame(scenes, from: output)
        XCTAssertTrue(waitUntil { capture.live })
        XCTAssertEqual(words(scenes).phase, .live)
        scenes.startDemo(mode: .windowed)
        XCTAssertTrue(scenes.isPresenting)
        XCTAssertEqual(hardware.read(capture) { $0.opened.count }, 1, "Present shows the page's session; it does not open another")

        settle(0.3) // Past the capture's five-a-second publishing, so the next frame is not merely throttled.
        deliverFrame(scenes, from: output) // On its way when End is pressed.
        scenes.endPresentation()
        XCTAssertTrue(waitUntil { !scenes.isPresenting })
        settle(0.3)
        deliverFrame(scenes, from: output) // Lands after End.
        settle()
        XCTAssertFalse(capture.live, "No frame after End shows the phone")
        XCTAssertEqual(capture.phase, .idle)
        XCTAssertTrue(capture.heldDeviceID == nil)
        XCTAssertEqual(words(scenes).phase, .ended)
        hardware.read(capture) { $0.changed }?()
        settle()
        XCTAssertEqual(hardware.read(capture) { $0.opened.count }, 1, "Nothing reopened the phone after End")

        scenes.startDemo(mode: .windowed)
        XCTAssertTrue(waitUntil { hardware.read(capture) { $0.opened.count } == 2 }, "Present takes the phone back")
        // A failed check above stops here rather than crashing the runner.
        guard let fresh = hardware.read(capture, { $0.outputs.count == 2 ? $0.outputs[1] : nil }) else { return }
        deliverFrame(scenes, from: output) // The ended session's output is not this session's.
        settle()
        XCTAssertFalse(capture.live)
        deliverFrame(scenes, from: fresh)
        XCTAssertTrue(waitUntil { capture.live })
        scenes.endPresentation()
        XCTAssertTrue(waitUntil { !scenes.isPresenting && capture.phase == .idle })
    }

    /// The stage's own steps, still in a menu someone opened before End, do nothing once End
    /// has begun: a late Choose screen cannot select a device and restart the capture.
    func testTheStagesStepsAfterEndCannotTakeThePhoneBack() throws {
        let hardware = SyntheticCaptureHardware(available: [card, phone], access: .authorized)
        let (scenes, root) = try makeScenes(hardware)
        defer { scenes.shutdown(); try? FileManager.default.removeItem(at: root) }
        let capture = scenes.capture
        scenes.setPageVisible(true)
        XCTAssertTrue(waitUntil { capture.sources.count == 2 })
        XCTAssertEqual(hardware.read(capture) { $0.opened }, [], "Two screens always wait for a choice")
        scenes.startDemo(mode: .windowed)
        XCTAssertTrue(waitUntil { words(scenes).phase == .chooseScreen })
        let stale = scenes.makeControlsMenu()
        guard let choose = stale.items.first(where: { $0.title == "Choose screen" })?.submenu else {
            XCTAssertTrue(false, "The stage offers Choose screen with two screens"); return
        }
        scenes.endPresentation()
        XCTAssertTrue(waitUntil { !scenes.isPresenting })
        choose.performActionForItem(at: 0)
        settle()
        XCTAssertEqual(hardware.read(capture) { $0.opened }, [], "A stale stage step after End starts nothing")
        XCTAssertFalse(hardware.read(capture) { $0.discovering })
        XCTAssertEqual(words(scenes).phase, .ended)
    }
}
