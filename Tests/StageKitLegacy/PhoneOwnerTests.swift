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
    private(set) var sessions: [AVCaptureSession] = []
    private(set) var discovering = false
    /// Listed but no longer connected, as a device that went away under a running session.
    var disconnected = Set<String>()
    /// Kept after discovery stops, so a check can fire a change that lands late.
    private(set) var changed: (() -> Void)?
    init(available: [DemoSource], access: AVAuthorizationStatus) { self.available = available; self.access = access }
    func startDiscovery(changed: @escaping () -> Void) { discovering = true; self.changed = changed }
    func stopDiscovery() { discovering = false }
    func sources() -> [DemoSource] { available }
    func isConnected(_ id: String) -> Bool { available.contains { $0.id == id } && !disconnected.contains(id) }
    func authorization() -> AVAuthorizationStatus { access }
    func requestAccess(_ completion: @escaping (Bool) -> Void) { pendingAnswers.append(completion) }
    func openSession(_ id: String, output: AVCaptureVideoDataOutput,
                     attach: (AVCaptureSession, AVCaptureInput.Port) -> Void) throws -> AVCaptureSession? {
        let session = AVCaptureSession() // Never configured or started: no device is opened.
        opened.append(id); outputs.append(output); sessions.append(session)
        return session
    }
    func read<T>(_ capture: DemoCapture, _ body: (SyntheticCaptureHardware) -> T) -> T { capture.queue.sync { body(self) } }
}

/// The USB bus as the monitor hears it, driven by the check: a look is delivered when the
/// check says so, the way IOKit's callback delivers one.
final class SyntheticUSBWatch: USBWatching {
    var onChange: ((USBProbeResult) -> Void)?
    private(set) var running = false
    func start() { running = true }
    func stop() { running = false }
}

/// The real owners as the app runs them: DemoScenes admits the capture, DemoPresentation
/// runs and ends the stage, DemoCapture runs the session on its queue and PhoneLinkMonitor
/// mirrors it. Only AVFoundation and the USB bus are synthetic. The stage window is built
/// and ended but never ordered on screen. Nothing reads or writes the person's scenes,
/// permissions or devices.
class PhoneOwnerFixture {
    let phone = DemoSource(id: "screen-1", name: "Ethan’s iPhone", isScreen: true)
    let tablet = DemoSource(id: "screen-3", name: "Ethan’s iPad", isScreen: true)
    let card = DemoSource(id: "card-2", name: "Capture card", isScreen: false)
    let frame = CGSize(width: 1320, height: 2868)
    let usbPhone = PhoneLinkSignals.USBDevice(name: "iPhone", kind: .iPhone, productID: 0x12A8)
    private(set) var usb = SyntheticUSBWatch()

    func makeScenes(_ hardware: SyntheticCaptureHardware) throws -> (DemoScenes, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneOwner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let backdrop = root.appendingPathComponent("backdrop.png")
        try png().write(to: backdrop)
        usb = SyntheticUSBWatch()
        let scenes = DemoScenes(root: root.appendingPathComponent("Scenes"), systemIntegrationEnabled: false, captureHardware: hardware, usbWatch: usb)
        // The app's shared live controls: End does not reopen a scenes window.
        scenes.usesSharedControls = true
        try scenes.addImage(backdrop, name: "Customer demo")
        XCTAssertTrue(scenes.selected?.showsPhone == true, "A new scene has the device frame")
        return (scenes, root)
    }
    func png() -> Data {
        let context = CGContext(data: nil, width: 160, height: 100, bitsPerComponent: 8, bytesPerRow: 640,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.82, blue: 0.86, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
        let output = NSMutableData(); let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); CGImageDestinationFinalize(destination)
        return output as Data
    }
    @discardableResult func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        return condition()
    }
    /// Lets every queued capture and main-thread callback run.
    func settle(_ seconds: TimeInterval = 0.4) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
    /// The phone's status as every Present surface reads it, from its one owner (tests run on main).
    func words(_ scenes: DemoScenes) -> PhoneLinkStatus { MainActor.assumeIsolated { scenes.phoneLink.status } }
    func deliverFrame(_ scenes: DemoScenes, from output: AVCaptureOutput) {
        let capture = scenes.capture, size = frame
        capture.queue.async { capture.frameArrived(size, from: output) }
    }
    /// One look at the bus, delivered as IOKit's callback would deliver it.
    func busLook(_ devices: [PhoneLinkSignals.USBDevice]) { usb.onChange?(.success(devices)) }
}

/// End is final: only a deliberate action takes the phone back.
final class PhoneEndTests: PhoneOwnerFixture {

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
        let hardware = SyntheticCaptureHardware(available: [tablet, phone], access: .authorized)
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

    /// "Presentation ended" does not last for the app's lifetime: a fresh visit to the Present
    /// page, or the phone plugged in again, is as deliberate as Reconnect. End's own reopening
    /// of the page, and a bus look that merely finds the phone still there, are not.
    func testEndedResumesOnAFreshVisitOrWhenThePhoneIsPluggedInAgain() throws {
        let hardware = SyntheticCaptureHardware(available: [phone], access: .authorized)
        let (scenes, root) = try makeScenes(hardware)
        defer { scenes.shutdown(); try? FileManager.default.removeItem(at: root) }
        let capture = scenes.capture
        scenes.setPageVisible(true)
        XCTAssertTrue(waitUntil { hardware.read(capture) { $0.opened.count } == 1 })
        busLook([usbPhone])
        scenes.startDemo(mode: .windowed); scenes.endPresentation()
        XCTAssertTrue(waitUntil { self.words(scenes).phase == .ended })
        busLook([usbPhone]) // Still there: not a new connection.
        settle()
        XCTAssertEqual(hardware.read(capture) { $0.opened.count }, 1, "A bus look that finds the same phone takes nothing back")
        scenes.presentPageOpened()
        XCTAssertTrue(waitUntil { hardware.read(capture) { $0.opened.count } == 2 }, "A fresh visit to the Present page shows the phone again")

        scenes.startDemo(mode: .windowed); scenes.endPresentation()
        XCTAssertTrue(waitUntil { self.words(scenes).phase == .ended })
        busLook([]); settle()
        XCTAssertEqual(hardware.read(capture) { $0.opened.count }, 2, "Unplugging takes nothing back")
        busLook([usbPhone])
        XCTAssertTrue(waitUntil { hardware.read(capture) { $0.opened.count } == 3 }, "Plugging the phone in again is deliberate")

        // With the stage's own controls, End reopens the page itself; that opening is End's, not the person's.
        scenes.usesSharedControls = false
        scenes.onOpen = { [weak scenes] in scenes?.presentPageOpened() }
        scenes.startDemo(mode: .windowed); scenes.endPresentation()
        XCTAssertTrue(waitUntil { self.words(scenes).phase == .ended })
        settle()
        XCTAssertEqual(hardware.read(capture) { $0.opened.count }, 3, "End's own reopening of the page does not undo End")
        scenes.presentPageOpened()
        XCTAssertTrue(waitUntil { hardware.read(capture) { $0.opened.count } == 4 }, "The person's next visit does")
    }
}

/// The capture as a phone really behaves on a Mac with other video devices, slow handshakes,
/// stalls, unplugging and other apps, through the same real owners.
final class PhoneCaptureTests: PhoneOwnerFixture {
    /// A work Mac's display camera, Camo or a capture card beside the phone never turns the one
    /// phone screen into a choice; two phone screens still wait for one.
    func testTheOnePhoneScreenIsAdoptedBesideACamera() throws {
        let hardware = SyntheticCaptureHardware(available: [card, phone], access: .authorized)
        let (scenes, root) = try makeScenes(hardware)
        defer { scenes.shutdown(); try? FileManager.default.removeItem(at: root) }
        scenes.setPageVisible(true)
        XCTAssertTrue(waitUntil { hardware.read(scenes.capture) { $0.opened } == [self.phone.id] }, "The phone is shown without a click")
        XCTAssertTrue(waitUntil { scenes.capture.selectedID == self.phone.id }, "and remembered")
        XCTAssertTrue(waitUntil { self.words(scenes).phase == .connecting })
    }

    /// End, then Present at once: the earlier run's back-off never leaves the stage on
    /// "Connecting…" while nothing is tried.
    func testPresentAfterEndTriesAtOnce() throws {
        let hardware = SyntheticCaptureHardware(available: [phone], access: .authorized)
        let (scenes, root) = try makeScenes(hardware)
        defer { scenes.shutdown(); try? FileManager.default.removeItem(at: root) }
        let capture = scenes.capture
        scenes.setPageVisible(true)
        XCTAssertTrue(waitUntil { hardware.read(capture) { $0.opened.count } == 1 })
        scenes.startDemo(mode: .windowed); scenes.endPresentation()
        XCTAssertTrue(waitUntil { !scenes.isPresenting && capture.phase == .idle })
        scenes.startDemo(mode: .windowed)
        XCTAssertTrue(waitUntil(1) { hardware.read(capture) { $0.opened.count } == 2 }, "Present opens the phone within a second, not after the back-off")
        scenes.endPresentation()
        XCTAssertTrue(waitUntil { capture.phase == .idle })
        scenes.reconnectPhone()
        XCTAssertTrue(waitUntil(1) { hardware.read(capture) { $0.opened.count } == 3 }, "and so does Reconnect")
    }

    /// The health check finds the device gone under a running session: the phase says so, so
    /// "Showing iPhone" never stays over an empty frame.
    func testADisconnectFoundByTheHealthCheckIsSaid() throws {
        let hardware = SyntheticCaptureHardware(available: [phone], access: .authorized)
        let (scenes, root) = try makeScenes(hardware)
        defer { scenes.shutdown(); try? FileManager.default.removeItem(at: root) }
        let capture = scenes.capture
        var phases: [CapturePhase] = []
        let watching = capture.$phase.sink { phases.append($0) }
        defer { watching.cancel() }
        scenes.setPageVisible(true)
        XCTAssertTrue(waitUntil { hardware.read(capture) { $0.opened.count } == 1 })
        deliverFrame(scenes, from: hardware.read(capture) { $0.outputs[0] })
        XCTAssertTrue(waitUntil { capture.live })
        hardware.read(capture) { $0.disconnected.insert(self.phone.id) }
        XCTAssertTrue(waitUntil(4) { phases.contains(.interrupted(self.phone.id)) }, "The health check publishes the disconnect")
        XCTAssertFalse(capture.live)
        XCTAssertFalse(words(scenes).phase == .live, "Showing iPhone does not outlive the phone")
    }

    /// A stall keeps the last frame on the stage (live stays true, so neither the stage nor the
    /// page's preview hides the phone or draws words over it); the words and Reconnect go to the
    /// status the controls, the menu, the page row and the toolbar show. The next frame clears it.
    func testAStallKeepsTheLastFrameAndSaysSoBesideIt() throws {
        let hardware = SyntheticCaptureHardware(available: [phone], access: .authorized)
        let (scenes, root) = try makeScenes(hardware)
        defer { scenes.shutdown(); try? FileManager.default.removeItem(at: root) }
        let capture = scenes.capture
        scenes.setPageVisible(true)
        XCTAssertTrue(waitUntil { hardware.read(capture) { $0.opened.count } == 1 })
        let output = hardware.read(capture) { $0.outputs[0] }
        deliverFrame(scenes, from: output)
        XCTAssertTrue(waitUntil { capture.live })
        XCTAssertTrue(waitUntil(10) { capture.phase == .stalled(self.phone.id) }, "Five quiet seconds after frames flowed is a stall")
        XCTAssertTrue(capture.live, "The stage keeps the phone's last frame")
        XCTAssertTrue(waitUntil { self.words(scenes).phase == .stalled })
        XCTAssertEqual(words(scenes).step, .reconnect)
        deliverFrame(scenes, from: output)
        XCTAssertTrue(waitUntil { self.words(scenes).phase == .live }, "The next frame ends the stall")
    }

    /// QuickTime Player or iPhone Mirroring taking the screen interrupts the session: the words
    /// name another app, and the picture comes back by itself when that app lets go.
    func testAnInterruptionByAnotherAppSaysSoAndRecovers() throws {
        let hardware = SyntheticCaptureHardware(available: [phone], access: .authorized)
        let (scenes, root) = try makeScenes(hardware)
        defer { scenes.shutdown(); try? FileManager.default.removeItem(at: root) }
        let capture = scenes.capture
        scenes.setPageVisible(true)
        XCTAssertTrue(waitUntil { hardware.read(capture) { $0.opened.count } == 1 })
        let output = hardware.read(capture) { $0.outputs[0] }, session = hardware.read(capture) { $0.sessions[0] }
        deliverFrame(scenes, from: output)
        XCTAssertTrue(waitUntil { capture.live })
        NotificationCenter.default.post(name: AVCaptureSession.wasInterruptedNotification, object: session)
        XCTAssertTrue(waitUntil { self.words(scenes).phase == .busy })
        XCTAssertEqual(words(scenes).title, "Another app is using the iPhone’s screen")
        NotificationCenter.default.post(name: AVCaptureSession.interruptionEndedNotification, object: session)
        XCTAssertTrue(waitUntil { capture.phase == .connecting(self.phone.id) }, "The end of the interruption is a reconnection, with nothing pressed")
        settle(0.3)
        deliverFrame(scenes, from: output)
        XCTAssertTrue(waitUntil { self.words(scenes).phase == .live })
        XCTAssertEqual(hardware.read(capture) { $0.opened.count }, 1, "macOS resumed the same session")
    }

    /// Covering the page briefly keeps its preview's session, so Present opens already live;
    /// after the grace it lets go. End still lets go at once.
    func testThePagesPreviewOutlivesABriefCover() throws {
        let hardware = SyntheticCaptureHardware(available: [phone], access: .authorized)
        let (scenes, root) = try makeScenes(hardware)
        defer { scenes.shutdown(); try? FileManager.default.removeItem(at: root) }
        let capture = scenes.capture
        scenes.pageHideGrace = 1
        scenes.setPageVisible(true)
        XCTAssertTrue(waitUntil { hardware.read(capture) { $0.opened.count } == 1 })
        scenes.setPageVisible(false)
        settle(0.4)
        XCTAssertTrue(hardware.read(capture) { $0.discovering }, "A covered page keeps its session for the grace")
        scenes.setPageVisible(true); scenes.setPageVisible(false)
        settle(0.4)
        XCTAssertTrue(hardware.read(capture) { $0.discovering })
        XCTAssertTrue(waitUntil(2) { !hardware.read(capture) { $0.discovering } }, "After the grace the preview lets go")
        XCTAssertEqual(hardware.read(capture) { $0.opened.count }, 1, "Uncovering within the grace reopened nothing")

        scenes.setPageVisible(true)
        XCTAssertTrue(waitUntil { hardware.read(capture) { $0.opened.count } == 2 })
        scenes.startDemo(mode: .windowed)
        scenes.setPageVisible(false)
        scenes.endPresentation()
        XCTAssertTrue(waitUntil(0.5) { !hardware.read(capture) { $0.discovering } }, "End lets go at once, grace or not")
    }

    /// A session that answers the same thing every health check publishes nothing new, so the
    /// page's preview is not laid out and redrawn every two seconds.
    func testAnUnchangedAnswerIsNotRepublished() throws {
        let hardware = SyntheticCaptureHardware(available: [], access: .authorized)
        let (scenes, root) = try makeScenes(hardware)
        defer { scenes.shutdown(); try? FileManager.default.removeItem(at: root) }
        let capture = scenes.capture
        var sources = 0, phases = 0
        let a = capture.$sources.dropFirst().sink { _ in sources += 1 }, b = capture.$phase.dropFirst().sink { _ in phases += 1 }
        defer { a.cancel(); b.cancel() }
        scenes.setPageVisible(true)
        settle(4.6) // Two health checks.
        XCTAssertEqual(sources, 0, "An empty list is not published again")
        XCTAssertEqual(phases, 0, "nor an idle phase")
        hardware.read(capture) { $0.available = [self.phone] }
        hardware.read(capture) { $0.changed }?()
        XCTAssertTrue(waitUntil { capture.sources == [self.phone] }, "A real change still is")
    }

    /// If macOS refuses the phone's screen a second connection, the stage, which the audience
    /// sees, is wired first and keeps it: stages come before pages, newest first within each.
    func testTheStageIsWiredBeforeThePagesPreview() {
        XCTAssertEqual(PreviewSurface.insertionIndex(for: .page, among: []), 0)
        XCTAssertEqual(PreviewSurface.insertionIndex(for: .stage, among: [.page]), 0, "A stage goes before an older page")
        XCTAssertEqual(PreviewSurface.insertionIndex(for: .page, among: [.stage]), 1, "A newer page goes after a stage")
        XCTAssertEqual(PreviewSurface.insertionIndex(for: .page, among: [.stage, .page]), 1, "and before older pages")
        XCTAssertEqual(PreviewSurface.insertionIndex(for: .stage, among: [.stage, .page]), 0)
    }
}
