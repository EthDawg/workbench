import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Persona's local live camera: one explicit visit, one session, and a bubble
/// that keeps the presenter's saved artwork, groups and prepared layouts intact.
/// Everything here uses a fake capture, window, permission, clock and camera
/// list, so no hardware, display, permission prompt or file is involved.
final class PersonaCameraTests {
    // MARK: Fakes

    /// Stands in for `ProfileCameraSession`: it records what the owner asked for
    /// and never touches AVFoundation.
    private final class Capture: ProfileCameraCapturing {
        let previewLayer = AVCaptureVideoPreviewLayer()
        var starts: [(String?, @MainActor (ProfileCameraEvent) -> Void)] = []
        var stops = 0
        var photos = 0
        func start(sourceID: String?, receive: @escaping @MainActor (ProfileCameraEvent) -> Void) { starts.append((sourceID, receive)) }
        func takePhoto(completion: @escaping @MainActor (Result<NSImage, ProfileCameraIssue>) -> Void) { photos += 1 }
        func stop() { stops += 1 }
    }
    /// The bubble's window, without a window.
    private final class Bubble: PersonaCameraDisplaying {
        var onPlacementChange: ((PersonaOverlayState) -> Void)?
        var frame: CGRect? = CGRect(x: 0, y: 0, width: 120, height: 120)
        var shown = false
        var released = 0
        var layer: CALayer?
        var aspect: CGSize?
        var outline: PersonaArtworkOutline?
        var state = PersonaOverlayState()
        var names: [String] = []
        func showLive(layer: CALayer, aspect: CGSize, outline: PersonaArtworkOutline?,
                      name: String, help: String, state: PersonaOverlayState) -> PersonaOverlayState {
            self.layer = layer; self.aspect = aspect; self.outline = outline
            self.state = state; names.append(name); shown = true
            return state
        }
        func configureLive(name: String, help: String, state: PersonaOverlayState) { self.state = state }
        func hide() { shown = false }
        func releaseLive() { shown = false; released += 1; layer = nil }
        func shutdown() { shown = false }
    }
    /// A disposable persona library with a fake camera behind it. Permission,
    /// the clock and the camera list are all supplied, so a check decides every
    /// answer and no prompt, timer or device is real.
    private final class Fixture {
        let root: URL
        let capture = Capture()
        let bubble = Bubble()
        var permissionRequests: [(AVAuthorizationStatus) -> Void] = []
        var pendingDeadlines: [(TimeInterval, () -> Void)] = []
        var cancelledDeadlines = 0
        var listCount = 0
        var cameras = PersonaCameraList(devices: [PersonaCameraDevice(id: "built-in", name: "Built-in camera", inUseByAnotherApp: false)],
                                        preferredID: "built-in")
        var saved: SavedPersona?
        lazy var camera = PersonaLiveCamera(
            capture: { [unowned self] in capture }, panel: { [unowned self] in bubble },
            authorize: { [unowned self] answer in permissionRequests.append(answer) },
            schedule: { [unowned self] seconds, action in
                pendingDeadlines.append((seconds, action))
                return { [weak self] in self?.cancelledDeadlines += 1 }
            },
            list: { [unowned self] in listCount += 1; return cameras })
        lazy var library: PersonaLibrary = {
            let library = PersonaLibrary(root: root.appendingPathComponent("library"), sessionHUDEnabled: false, camera: camera)
            library.usesSharedControls = true
            return library
        }()

        init(withArtwork: Bool = false) {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("PersonaCamera-" + UUID().uuidString)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            guard withArtwork else { return }
            let url = root.appendingPathComponent("synthetic.png")
            try? Self.png().write(to: url)
            saved = try? library.addImage(url, name: "Private Alpha", card: PersonaCardStyle(label: "Site lead"))
            library.selectedID = saved?.id
        }
        func offer(_ list: PersonaCameraList) { cameras = list }

        /// Start camera, allow access and deliver the first real frame. The
        /// session's own events arrive on the main thread, as they do in the app.
        @MainActor func live() {
            library.startCamera()
            permissionRequests.last?(.authorized)
            capture.starts.last?.1(.sources([ProfileCameraSource(id: "built-in", name: "Built-in camera")], selected: "built-in"))
            capture.starts.last?.1(.frame)
        }
        func cleanup() {
            library.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        static func png() -> Data {
            let context = CGContext(data: nil, width: 240, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.4, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 320))
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            _ = CGImageDestinationFinalize(destination)
            return data as Data
        }
    }
    private func titles(_ menu: NSMenu) -> [String] { menu.items.flatMap { [$0.title] + ($0.submenu.map(titles) ?? []) } }
    private func invoke(_ menu: NSMenu, _ title: String) {
        guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else {
            XCTAssertTrue(false, "Expected \(title)"); return
        }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    // MARK: Explicit start

    /// Off at launch: opening Persona, creating the owner and choosing Camera as
    /// the source never list, open or authorise a camera. Only Start camera does,
    /// and nothing is on screen until a real frame arrives.
    func testCameraIsOffUntilAnExplicitStartAndShowsNothingBeforeAFrame() {
        MainActor.assumeIsolated {
            let f = Fixture(); defer { f.cleanup() }
            XCTAssertEqual(f.camera.state, .off)
            XCTAssertEqual(f.library.liveSource, .artwork)
            XCTAssertFalse(f.library.overlayVisible)
            XCTAssertEqual(f.listCount, 0, "No camera is listed before Start camera")
            XCTAssertEqual(f.permissionRequests.count, 0)
            XCTAssertEqual(f.capture.starts.count, 0)
            // Preparing the page and picking a camera in the list are not starts.
            XCTAssertEqual(f.capture.stops, 0)

            f.library.startCamera()
            XCTAssertEqual(f.camera.state, .permission)
            XCTAssertEqual(f.library.liveSource, .camera)
            XCTAssertEqual(f.capture.starts.count, 0, "Access comes before the hardware")
            XCTAssertFalse(f.library.overlayVisible, "Nothing shows while access is pending")
            f.permissionRequests.last?(.authorized)
            XCTAssertEqual(f.camera.state, .starting)
            XCTAssertEqual(f.capture.starts.count, 1)
            XCTAssertEqual(f.pendingDeadlines.last?.0, PersonaLiveCamera.startupSeconds)
            XCTAssertFalse(f.library.overlayVisible, "Starting is not showing")
            XCTAssertFalse(f.bubble.shown)
            f.capture.starts.last?.1(.frame)
            XCTAssertEqual(f.camera.state, .live)
            XCTAssertTrue(f.bubble.shown)
            XCTAssertTrue(f.library.overlayVisible)
            XCTAssertEqual(f.pendingDeadlines.last?.0, PersonaLiveCamera.frameSeconds)
            // The bubble is a mirrored circle of the session's own preview layer.
            XCTAssertTrue(f.bubble.layer === f.capture.previewLayer)
            XCTAssertEqual(f.bubble.aspect, CGSize(width: 1, height: 1))
            XCTAssertEqual(f.bubble.outline, PersonaCircleRenderer.outline)
            XCTAssertEqual(f.capture.photos, 0, "A live source never takes a photo")
        }
    }

    /// A cancelled start, a refused permission and a camera that never sends a
    /// picture all leave a shown card exactly as it was, and no automatic restart
    /// follows any of them.
    func testFailuresBeforeReadinessLeaveTheShownArtworkAndNeedAnExplicitRetry() throws {
        try MainActor.assumeIsolated {
            let f = Fixture(withArtwork: true); defer { f.cleanup() }
            try f.library.showOverlay().get()
            XCTAssertTrue(f.library.artworkVisible)
            let card = f.library.shownCard

            // Cancel while access is pending.
            f.library.startCamera()
            f.library.endCamera()
            XCTAssertEqual(f.camera.state, .off)
            XCTAssertEqual(f.library.liveSource, .artwork)
            XCTAssertTrue(f.library.artworkVisible, "The card never moved")
            XCTAssertEqual(f.library.shownCard, card)
            f.permissionRequests.last?(.authorized)
            XCTAssertEqual(f.capture.starts.count, 0, "A cancelled visit never opens the camera")

            // A refused permission.
            f.library.startCamera()
            f.permissionRequests.last?(.denied)
            XCTAssertEqual(f.camera.state, .failed(.access(.denied)))
            XCTAssertTrue(f.library.artworkVisible)
            XCTAssertEqual(f.library.shownCard, card)
            XCTAssertEqual(f.camera.failure?.offersCameraSettings, true)

            // A camera that sends no picture within its startup deadline.
            f.library.retryCamera()
            f.permissionRequests.last?(.authorized)
            XCTAssertEqual(f.camera.state, .starting)
            let stopsBefore = f.capture.stops
            f.pendingDeadlines.last?.1()
            XCTAssertEqual(f.camera.state, .failed(.access(.timedOut)))
            XCTAssertGreaterThan(f.capture.stops, stopsBefore)
            XCTAssertTrue(f.library.artworkVisible, "A failed start leaves the artwork alone")
            XCTAssertFalse(f.bubble.shown)
            // A late frame from that visit cannot open the bubble by itself.
            f.capture.starts.last?.1(.frame)
            XCTAssertEqual(f.camera.state, .failed(.access(.timedOut)))
            XCTAssertFalse(f.bubble.shown)
            XCTAssertEqual(f.library.notice, PersonaCameraFailure.access(.timedOut).message)
        }
    }

    /// A stalled or disconnected camera stops with its own reason and waits for
    /// Try again; an old deadline cannot end a newer live bubble.
    func testStalledAndDisconnectedFeedsRecoverOnlyOnExplicitRetry() {
        MainActor.assumeIsolated {
            let f = Fixture(); defer { f.cleanup() }
            f.live()
            XCTAssertEqual(f.camera.state, .live)
            let stale = f.pendingDeadlines.count - 1
            f.capture.starts.last?.1(.frame)
            f.pendingDeadlines[stale].1()
            XCTAssertEqual(f.camera.state, .live, "An earlier frame's deadline cannot end a refreshed bubble")
            f.pendingDeadlines.last?.1()
            XCTAssertEqual(f.camera.state, .failed(.access(.timedOut)))
            XCTAssertFalse(f.library.overlayVisible)
            XCTAssertFalse(f.bubble.shown)

            f.library.retryCamera(); f.permissionRequests.last?(.authorized)
            f.capture.starts.last?.1(.frame)
            XCTAssertEqual(f.camera.state, .live)
            let starts = f.capture.starts.count
            f.capture.starts.last?.1(.failed(.interrupted))
            XCTAssertEqual(f.camera.state, .failed(.access(.interrupted)))
            XCTAssertEqual(f.capture.starts.count, starts, "A disconnection never silently restarts another camera")
            XCTAssertFalse(f.library.overlayVisible)
            f.library.retryCamera(); f.permissionRequests.last?(.authorized)
            XCTAssertEqual(f.capture.starts.last?.0, "built-in", "Try again uses the same camera")
        }
    }

    // MARK: Conflicts and device choice

    /// A camera another owner already holds is reported, not taken: the app's own
    /// device presentation and another application are both named, and neither
    /// start reaches the hardware.
    func testABusyCameraIsReportedInsteadOfTaken() {
        MainActor.assumeIsolated {
            let f = Fixture(); defer { f.cleanup() }
            f.camera.deviceInUse = { "built-in" }
            f.library.startCamera()
            XCTAssertEqual(f.camera.state, .failed(.inUse(camera: "Built-in camera", owner: "Present")))
            XCTAssertEqual(f.permissionRequests.count, 0, "A conflict is reported before asking for access")
            XCTAssertEqual(f.capture.starts.count, 0)
            XCTAssertTrue(f.library.notice?.contains("Built-in camera") == true)
            XCTAssertTrue(f.library.notice?.contains("Present") == true)

            f.camera.deviceInUse = { nil }
            f.offer(PersonaCameraList(devices: [PersonaCameraDevice(id: "studio", name: "Studio Cam", inUseByAnotherApp: true)],
                                      preferredID: "studio"))
            f.library.startCamera(deviceID: "studio")
            XCTAssertEqual(f.camera.state, .failed(.inUse(camera: "Studio Cam", owner: "another app")))
            XCTAssertEqual(f.capture.starts.count, 0)
        }
    }

    /// Several cameras can be chosen, and choosing one starts that one only:
    /// the previous session is stopped and its late frames are dropped.
    func testChoosingAnotherCameraStartsOnlyThatOneAndDropsTheOldFeed() {
        MainActor.assumeIsolated {
            let f = Fixture(); defer { f.cleanup() }
            f.offer(PersonaCameraList(devices: [PersonaCameraDevice(id: "built-in", name: "Built-in camera", inUseByAnotherApp: false),
                                                PersonaCameraDevice(id: "studio", name: "Studio Cam", inUseByAnotherApp: false)],
                                      preferredID: "built-in"))
            f.live()
            XCTAssertEqual(f.camera.selectedID, "built-in")
            let earlier = f.capture.starts.count - 1
            f.capture.starts.last?.1(.sources([ProfileCameraSource(id: "built-in", name: "Built-in camera"),
                                              ProfileCameraSource(id: "studio", name: "Studio Cam")], selected: "built-in"))
            let permissions = f.permissionRequests.count, starts = f.capture.starts.count
            f.camera.prepareDevice("studio")
            XCTAssertEqual(f.camera.state, .live, "Preparing a source keeps the existing camera live")
            XCTAssertEqual(f.camera.selectedID, "built-in")
            XCTAssertEqual(f.capture.starts.count, starts, "A source choice opens no device")
            XCTAssertEqual(f.permissionRequests.count, permissions)
            XCTAssertTrue(f.camera.hasPreparedSwitch)
            f.library.setOverlayLocked(true)
            XCTAssertTrue(f.camera.explanation.contains("handle above"), "Locked camera movement uses the visible handle")
            f.library.setOverlayLocked(false)
            XCTAssertTrue(f.camera.explanation.contains("Drag the bubble"), "Unlocked camera movement uses its body")
            f.library.startCamera() // explicit Switch camera consumes the prepared choice
            XCTAssertEqual(f.camera.selectedID, "studio")
            XCTAssertEqual(f.camera.state, .permission)
            f.permissionRequests.last?(.authorized)
            XCTAssertEqual(f.capture.starts.last?.0, "studio")
            f.capture.starts[earlier].1(.frame)
            XCTAssertEqual(f.camera.state, .starting, "A frame from the old camera cannot make the new one live")
            f.capture.starts.last?.1(.frame)
            XCTAssertEqual(f.camera.state, .live)
            XCTAssertEqual(f.camera.sources.count, 2)

            // The chosen external camera disappears, leaving one built-in
            // camera. Keep the failed choice until the person chooses A.
            f.capture.starts.last?.1(.failed(.interrupted))
            f.offer(PersonaCameraList(devices: [PersonaCameraDevice(id: "built-in", name: "Built-in camera", inUseByAnotherApp: false)], preferredID: "built-in"))
            let asked = f.permissionRequests.count, opened = f.capture.starts.count
            f.library.retryCamera()
            XCTAssertEqual(f.camera.state, .failed(.missing(camera: "Studio Cam")), "Retry names the camera that has gone")
            XCTAssertEqual(f.capture.starts.count, opened, "Retry never silently substitutes another camera")
            XCTAssertEqual(f.permissionRequests.count, asked, "A camera that is not there asks for nothing")
            XCTAssertEqual(f.camera.sources.count, 1)
            XCTAssertTrue(f.camera.offersSourceChoice, "The remaining camera is reachable even though only one is available")
            XCTAssertFalse(f.camera.preparedSourceAvailable)
            XCTAssertTrue(f.camera.explanation.contains("selected camera") && f.camera.explanation.contains("Choose another camera"),
                          "A missing selected camera must not claim that the available replacement is absent")
            f.camera.prepareDevice("built-in")
            XCTAssertTrue(f.camera.preparedSourceAvailable)
            f.library.retryCamera(); f.permissionRequests.last?(.authorized)
            XCTAssertEqual(f.capture.starts.last?.0, "built-in", "The explicit replacement choice is the one opened")
        }
    }

    func testSleepCancelsPermissionAndStartup() {
        MainActor.assumeIsolated {
            for hasPermission in [false, true] {
                let f = Fixture(); defer { f.cleanup() }
                f.library.startCamera()
                if hasPermission { f.permissionRequests.last?(.authorized) }
                let starts = f.capture.starts.count
                f.camera.hide(.asleep)
                XCTAssertEqual(f.camera.state, .hidden(.asleep))
                XCTAssertFalse(f.bubble.shown)
                f.permissionRequests.last?(.authorized)
                f.capture.starts.last?.1(.frame)
                XCTAssertEqual(f.capture.starts.count, starts, "Late permission cannot start a camera after sleep")
                XCTAssertEqual(f.camera.state, .hidden(.asleep), "Late frames cannot reopen a sleeping visit")
            }
            let f = Fixture(); defer { f.cleanup() }
            f.library.startCamera()
            f.offer(PersonaCameraList(devices: [PersonaCameraDevice(id: "built-in", name: "Built-in camera", inUseByAnotherApp: true)], preferredID: "built-in"))
            f.permissionRequests.last?(.authorized)
            XCTAssertEqual(f.capture.starts.count, 0, "A camera taken while permission was pending remains with that owner")
            XCTAssertEqual(f.camera.failure, .inUse(camera: "Built-in camera", owner: "another app"))
        }
    }

    // MARK: One live slot

    /// Start camera keeps the card it replaces, and End camera keeps saved
    /// artwork, its group and its selection; Show again brings the same card back.
    func testTheCameraTakesTheSlotWithoutLosingSavedOrPreparedArtwork() throws {
        try MainActor.assumeIsolated {
            let f = Fixture(withArtwork: true); defer { f.cleanup() }
            let group = try f.library.createGroup(name: "Private group", members: [f.saved!.id])
            f.library.prepareGroup(group)
            try f.library.showOverlay().get()
            let card = f.library.shownCard
            let savedWidth = f.library.overlayWidth
            f.library.setOverlayLocked(true)

            f.live()
            XCTAssertEqual(f.library.liveSource, .camera)
            XCTAssertFalse(f.library.artworkVisible, "The card stepped aside for the bubble")
            XCTAssertTrue(f.library.overlayVisible)
            XCTAssertTrue(f.library.hasHiddenCard, "It is kept for Show again")
            XCTAssertEqual(f.library.shownCard, card)
            // The bubble's own placement never becomes the artwork's.
            f.library.setOverlayWidth(0.3)
            XCTAssertEqual(f.camera.placement.width, 0.3, accuracy: 0.0001)
            XCTAssertEqual(f.library.overlayWidth, 0.3, accuracy: 0.0001)
            f.library.setOverlayLocked(false)
            XCTAssertFalse(f.camera.placement.locked)

            f.library.endCamera()
            XCTAssertEqual(f.camera.state, .off)
            XCTAssertEqual(f.library.liveSource, .artwork)
            XCTAssertFalse(f.library.overlayVisible)
            XCTAssertEqual(f.bubble.released, 1)
            XCTAssertTrue(f.library.overlayLocked, "Saved artwork keeps the lock it had")
            XCTAssertEqual(f.library.overlayWidth, savedWidth, accuracy: 0.0001)
            XCTAssertEqual(f.library.items.count, 1, "Saved personas are untouched")
            XCTAssertEqual(f.library.activeGroupID, group)
            XCTAssertEqual(f.library.selectedID, f.saved?.id)

            try f.library.showAgain().get()
            XCTAssertTrue(f.library.artworkVisible)
            XCTAssertEqual(f.library.shownCard, card)

            // The pill's End camera goes through StageKitController.endPersona
            // to this shared owner method. It must preserve the same frozen
            // card and placement as the workspace's direct End camera.
            let selection = f.library.liveSelection
            f.live()
            f.library.endLivePersona()
            XCTAssertEqual(f.camera.state, .off)
            XCTAssertTrue(f.library.hasHiddenCard)
            XCTAssertEqual(f.library.shownCard, card)
            XCTAssertEqual(f.library.liveSelection, selection)
            XCTAssertEqual(f.library.overlayWidth, savedWidth, accuracy: 0.0001)
            XCTAssertTrue(f.library.overlayLocked)
            try f.library.showAgain().get()
            XCTAssertTrue(f.library.artworkVisible)
            XCTAssertEqual(f.library.shownCard, card)

            // A failed or pending camera leaves artwork visible; its separate
            // Hide command must still hide that artwork and keep camera state.
            f.library.startCamera()
            let pending = f.camera.state
            f.library.hideArtwork()
            XCTAssertFalse(f.library.artworkVisible)
            XCTAssertEqual(f.camera.state, pending)
            f.permissionRequests.last?(.denied)
            f.library.endCamera()
            try f.library.showAgain().get()
            f.library.startCamera(); f.permissionRequests.last?(.denied)
            let failure = f.camera.state
            f.library.hideArtwork()
            XCTAssertFalse(f.library.artworkVisible)
            XCTAssertEqual(f.camera.state, failure)
            XCTAssertEqual(f.library.shownCard, card)

            // Explicitly showing artwork also invalidates an old camera Retry.
            let visit = f.camera.visit
            let pendingRetry = { f.camera.perform(ifCurrent: visit) { f.library.retryCamera() } }
            try f.library.showAgain().get()
            let requests = f.permissionRequests.count
            pendingRetry()
            XCTAssertEqual(f.camera.state, .off)
            XCTAssertEqual(f.permissionRequests.count, requests)
            XCTAssertTrue(f.library.artworkVisible)
        }
    }

    /// Hide releases the camera at once and keeps the bubble's place; Show camera
    /// again starts the same camera and returns it there. Quit releases it too.
    func testHideReleasesTheCameraAndKeepsItsPlaceForShowAgain() {
        MainActor.assumeIsolated {
            let f = Fixture(); defer { f.cleanup() }
            f.live()
            f.library.setOverlayPosition(x: 0.1, y: 0.9)
            f.library.setOverlayWidth(0.24)
            let place = f.camera.placement

            let stops = f.capture.stops, cancellations = f.cancelledDeadlines
            let staleDeadline = f.pendingDeadlines.last?.1
            f.library.hideCamera()
            XCTAssertEqual(f.camera.state, .hidden(.chosen))
            XCTAssertGreaterThan(f.capture.stops, stops, "Hide releases the camera at once")
            XCTAssertFalse(f.bubble.shown)
            XCTAssertFalse(f.library.overlayVisible)
            XCTAssertTrue(f.library.cameraOwnsSlot, "The visit is kept, so the doors still name the camera")
            XCTAssertEqual(f.camera.placement, place)
            XCTAssertGreaterThan(f.cancelledDeadlines, cancellations, "Hide cancels the active deadline")
            staleDeadline?()
            XCTAssertEqual(f.camera.state, .hidden(.chosen), "A cancelled deadline cannot change the hidden visit")

            f.library.showCameraAgain()
            f.permissionRequests.last?(.authorized)
            f.capture.starts.last?.1(.frame)
            XCTAssertEqual(f.camera.state, .live)
            XCTAssertEqual(f.camera.placement, place, "It returns to the same place and size")
            XCTAssertTrue(f.bubble.shown)

            // Retain the same production dispatch used by a rendered workspace
            // action, then end the visit. It cannot reopen camera hardware.
            f.library.hideCamera()
            let visit = f.camera.visit
            let pendingShow = { f.camera.perform(ifCurrent: visit) { f.library.showCameraAgain() } }
            f.library.endCamera()
            let requests = f.permissionRequests.count
            pendingShow()
            XCTAssertEqual(f.camera.state, .off)
            XCTAssertEqual(f.permissionRequests.count, requests)

            let beforeQuit = f.capture.stops
            f.live()
            f.library.shutdown()
            XCTAssertEqual(f.camera.state, .off)
            XCTAssertGreaterThan(f.capture.stops, beforeQuit, "Quit releases the camera")
        }
    }

    /// Every live Persona door names and acts on the camera while it is the live
    /// source, and cycling never replaces it.
    func testLiveDoorsFollowTheCameraAndCyclingNeverReplacesIt() throws {
        try MainActor.assumeIsolated {
            let f = Fixture(withArtwork: true); defer { f.cleanup() }
            f.live()
            // The Persona visibility shortcut hides the camera, not the artwork.
            f.library.toggleQuickPersona()
            XCTAssertEqual(f.camera.state, .hidden(.chosen))
            f.library.toggleQuickPersona()
            f.permissionRequests.last?(.authorized)
            f.capture.starts.last?.1(.frame)
            XCTAssertEqual(f.camera.state, .live)
            try f.library.togglePersonaVisibility().get()
            XCTAssertEqual(f.camera.state, .hidden(.chosen))
            try f.library.togglePersonaVisibility().get()
            f.permissionRequests.last?(.authorized)
            f.capture.starts.last?.1(.frame)
            XCTAssertEqual(f.camera.state, .live)

            // Next persona refuses rather than replacing a live camera.
            f.library.stepQuickPersona(1)
            XCTAssertEqual(f.camera.state, .live)
            XCTAssertTrue(f.library.notice?.contains("camera") == true)
            XCTAssertTrue(f.library.toolbarCycle == nil, "The camera is not a persona to cycle")

            // The live menu names the camera and nothing else.
            let menu = f.library.makeControlsMenu()
            let names = titles(menu)
            XCTAssertTrue(names.contains("Hide camera"))
            XCTAssertTrue(names.contains("End camera"))
            XCTAssertFalse(names.contains("Choose Persona"))
            XCTAssertFalse(names.contains("End Overlay"))
            XCTAssertTrue(f.library.selectedLiveCopy == nil, "A hidden card is not offered as the live copy")

            // A control from an earlier visit does nothing to a newer one.
            let stale = f.library.makeControlsMenu()
            let oldIdentity = f.library.liveControlsGeneration
            XCTAssertEqual(oldIdentity, f.camera.visit, "Every live door identifies the camera visit")
            f.library.endCamera()
            f.live()
            XCTAssertFalse(f.library.liveControlsGeneration == oldIdentity, "A replacement camera invalidates every live door")
            invoke(stale, "End camera")
            XCTAssertEqual(f.camera.state, .live, "A stale End cannot end a newer visit")
            invoke(stale, "Hide camera")
            XCTAssertEqual(f.camera.state, .live)
        }
    }

    /// A prepared overlay set keeps the slot and its device, and Start overlays
    /// takes the slot back from a live camera without losing the layout.
    func testPreparedSetsAndTheCameraNeverShareTheSlot() throws {
        try MainActor.assumeIsolated {
            let f = Fixture(withArtwork: true); defer { f.cleanup() }
            let group = try f.library.createGroup(name: "Private set", members: [f.saved!.id])
            var placement = PersonaOverlayState(); placement.width = 0.12
            try f.library.saveGroupLayout(group, overlays: [PersonaOverlayItem(personaID: f.saved!.id, placement: placement)], publicLabel: nil)
            try f.library.savePreparedGroups([group])
            try f.library.startOverlaySession(groupIDs: [group], initialGroupID: group)
            XCTAssertTrue(f.library.hasPreparedSession)

            XCTAssertThrowsError(try f.library.startCamera().get())
            XCTAssertEqual(f.camera.state, .off)
            XCTAssertEqual(f.permissionRequests.count, 0, "A refused start never reaches the camera")
            XCTAssertTrue(f.library.hasPreparedSession, "The set keeps running")

            f.library.endOverlaySession()
            f.live()
            XCTAssertEqual(f.camera.state, .live)
            // Starting the prepared set again is explicit, so it releases the camera.
            let stops = f.capture.stops
            try f.library.startOverlaySession(groupIDs: [group], initialGroupID: group)
            XCTAssertEqual(f.camera.state, .off)
            XCTAssertGreaterThan(f.capture.stops, stops)
            XCTAssertEqual(f.library.liveSource, .artwork)
            XCTAssertTrue(f.library.hasPreparedSession)
        }
    }

    /// The camera implies no microphone: React to my voice never listens for a
    /// bubble, and no photo or file is written by a whole visit.
    func testCameraNeitherListensNorWritesAnything() {
        MainActor.assumeIsolated {
            let microphones = Box()
            let access = PersonaVoiceAccess(permission: { .allowed }, requestPermission: { $0(true) },
                                            makeSource: { let source = Microphone(); microphones.made.append(source); return source },
                                            savedChoice: { true }, saveChoice: { _ in })
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("PersonaCameraVoice-" + UUID().uuidString)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let capture = Capture(), bubble = Bubble()
            var permissions: [(AVAuthorizationStatus) -> Void] = []
            let camera = PersonaLiveCamera(capture: { capture }, panel: { bubble },
                                           authorize: { permissions.append($0) }, schedule: { _, _ in {} },
                                           list: { PersonaCameraList(devices: [PersonaCameraDevice(id: "built-in", name: "Built-in camera", inUseByAnotherApp: false)], preferredID: "built-in") })
            let library = PersonaLibrary(root: root.appendingPathComponent("library"), sessionHUDEnabled: false,
                                         voice: access, camera: camera)
            library.usesSharedControls = true
            defer { library.shutdown(); try? FileManager.default.removeItem(at: root) }
            XCTAssertTrue(library.voiceRing, "The remembered voice choice is on")
            library.startCamera()
            permissions.last?(.authorized)
            capture.starts.last?.1(.frame)
            XCTAssertEqual(camera.state, .live)
            XCTAssertFalse(microphones.running, "A camera bubble never opens the microphone")
            library.hideCamera()
            XCTAssertFalse(microphones.running)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("library").path)) ?? []
            XCTAssertFalse(files.contains { $0.hasSuffix(".png") }, "No photo is saved by a live visit")
            XCTAssertFalse(files.contains("persona-overlay.json"), "The bubble's place is never written to the artwork's record")
        }
    }
    private final class Box { var made: [Microphone] = []; var running: Bool { made.contains(where: \.running) } }
    private final class Microphone: PersonaVoiceSource {
        var onFrames: (([PersonaVoiceFrame]) -> Void)?
        var onUnavailable: ((String) -> Void)?
        var onDevice: ((String?) -> Void)?
        private(set) var running = false
        var deviceName: String? { running ? "Synthetic microphone" : nil }
        func start() throws { running = true }
        func stop() { running = false }
    }

    // MARK: The bubble's own window

    /// The real overlay window draws a live layer in the artwork's place: it is
    /// circular to the pointer, drags and resizes inside the display, and keeps
    /// its position through Hide and Show.
    func testTheBubbleWindowMovesResizesAndCropsLikeArtwork() {
        MainActor.assumeIsolated {
            guard let screen = NSScreen.main else { return }
            let pointer = PersonaTestPointer()
            let controller = PersonaOverlayController(pointer: pointer, revealDelay: 0)
            defer { controller.shutdown() }
            let source = CALayer()
            var state = PersonaOverlayState(); state.width = 0.12; state.x = 0.5; state.y = 0.5
            let placed = controller.showLive(layer: source, aspect: CGSize(width: 1, height: 1),
                                             outline: PersonaCircleRenderer.outline, name: "Live camera",
                                             help: "Drag to move your live camera.", state: state)
            guard let window = controller.window else { XCTAssertTrue(false, "A window"); return }
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(placed.width, 0.12, accuracy: 0.0001)
            let frame = window.frame
            XCTAssertEqual(frame.width, frame.height, accuracy: 2)
            XCTAssertTrue(screen.visibleFrame.insetBy(dx: -1, dy: -1).contains(frame))
            // A click in the transparent corner passes through; the circle takes it.
            XCTAssertTrue(controller.acceptsClick(at: CGPoint(x: frame.midX, y: frame.midY)))
            XCTAssertFalse(controller.acceptsClick(at: CGPoint(x: frame.minX + 2, y: frame.minY + 2)))
            // Resizing keeps its shape and stays within the Size range.
            controller.pointerMoved(to: CGPoint(x: frame.midX, y: frame.maxY + 2))
            controller.handleBegan(.topRight)
            controller.handleMoved(.topRight, by: CGVector(dx: 200, dy: 200))
            controller.handleEnded(.topRight)
            guard let grown = controller.frame else { XCTAssertTrue(false, "A frame"); return }
            XCTAssertEqual(grown.width, grown.height, accuracy: 2)
            XCTAssertGreaterThan(grown.width, frame.width)
            XCTAssertTrue(grown.width / screen.visibleFrame.width <= 0.41)
            controller.hide()
            XCTAssertFalse(window.isVisible)
            let again = controller.showLive(layer: source, aspect: CGSize(width: 1, height: 1),
                                            outline: PersonaCircleRenderer.outline, name: "Live camera",
                                            help: "Drag to move your live camera.", state: placed)
            XCTAssertEqual(again.width, placed.width, accuracy: 0.0001)
            XCTAssertTrue(window.isVisible)
            controller.releaseLive()
            XCTAssertFalse(window.isVisible)
        }
    }

    // MARK: Optional synthetic renders

    /// Offscreen renders of the camera panel's states, with synthetic content
    /// only. They are evidence of layout, not of camera access.
    func testOffscreenCameraPanelRenders() throws {
        guard let directory = ProcessInfo.processInfo.environment["WORKBENCH_LAYOUT_EVIDENCE"].map({ URL(fileURLWithPath: $0) }) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try MainActor.assumeIsolated {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for name in ["off", "starting", "live", "switch", "missing-source", "hidden", "denied", "busy"] {
                    let f = Fixture(); defer { f.cleanup() }
                    switch name {
                    case "starting": f.library.startCamera(); f.permissionRequests.last?(.authorized)
                    case "live", "switch":
                        f.offer(PersonaCameraList(devices: [PersonaCameraDevice(id: "built-in", name: "Built-in camera", inUseByAnotherApp: false),
                                                            PersonaCameraDevice(id: "studio", name: "Studio Cam", inUseByAnotherApp: false)],
                                                  preferredID: "built-in"))
                        f.live()
                        f.capture.starts.last?.1(.sources(f.cameras.devices.map { ProfileCameraSource(id: $0.id, name: $0.name) }, selected: "built-in"))
                        if name == "switch" {
                            f.camera.prepareDevice("studio")
                            XCTAssertTrue(f.camera.hasPreparedSwitch, "The switch layout must actually offer Switch camera")
                        }
                    case "missing-source":
                        f.library.startCamera(deviceID: "disconnected"); f.permissionRequests.last?(.authorized)
                        f.capture.starts.last?.1(.failed(.unavailable))
                        XCTAssertTrue(f.camera.offersSourceChoice)
                    case "hidden": f.live(); f.library.hideCamera()
                    case "denied": f.library.startCamera(); f.permissionRequests.last?(.denied)
                    case "busy": f.camera.deviceInUse = { "built-in" }; f.library.startCamera()
                    default: break
                    }
                    let content = PersonaCameraPanel(library: f.library, camera: f.camera)
                        .padding(24).frame(width: 520)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, appearance == .aqua ? .light : .dark)
                    let hosting = NSHostingView(rootView: content)
                    hosting.appearance = NSAppearance(named: appearance)
                    let size = hosting.fittingSize
                    XCTAssertEqual(size.width, 520)
                    XCTAssertTrue(size.height < 420, "The camera panel fits inside the Persona page")
                    let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.appearance = hosting.appearance; window.contentView = hosting
                    defer { window.close() }
                    hosting.frame = CGRect(origin: .zero, size: size)
                    for _ in 0..<5 { hosting.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
                    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds),
                          let data = { hosting.cacheDisplay(in: hosting.bounds, to: bitmap); return bitmap.representation(using: .png, properties: [:]) }()
                    else { throw PersonaError.unreadableImage }
                    try data.write(to: directory.appendingPathComponent("persona-camera-\(name)-\(appearance == .aqua ? "light" : "dark").png"))
                }
            }
        }
    }
    /// A hidden bubble whose camera has gone while another remains says which
    /// camera is missing, next to the list that offers the one that is there.
    /// Show camera again opens nothing in its place and asks for no access; only
    /// an explicit choice starts the remaining camera.
    func testShowAgainAfterTheChosenCameraHasGoneNamesItAndOpensNoOther() {
        MainActor.assumeIsolated {
            let f = Fixture(); defer { f.cleanup() }
            f.offer(PersonaCameraList(devices: [PersonaCameraDevice(id: "built-in", name: "Built-in camera", inUseByAnotherApp: false),
                                                PersonaCameraDevice(id: "desk", name: "Desk camera", inUseByAnotherApp: false)],
                                      preferredID: "built-in"))
            f.live()
            f.library.hideCamera()
            XCTAssertEqual(f.camera.state, .hidden(.chosen))
            // The lid closes or the camera is unplugged while hidden; another remains.
            f.offer(PersonaCameraList(devices: [PersonaCameraDevice(id: "desk", name: "Desk camera", inUseByAnotherApp: false)],
                                      preferredID: "desk"))
            let asked = f.permissionRequests.count, opened = f.capture.starts.count
            f.library.showCameraAgain()
            XCTAssertEqual(f.camera.state, .failed(.missing(camera: "Built-in camera")))
            XCTAssertEqual(f.permissionRequests.count, asked, "Nothing is asked for a camera that is not there")
            XCTAssertEqual(f.capture.starts.count, opened, "The desk camera is not opened in its place")
            XCTAssertFalse(f.bubble.shown)
            XCTAssertTrue(f.camera.explanation.contains("Built-in camera"))
            XCTAssertFalse(f.camera.explanation.contains("No camera is available"), "Another camera is listed, so none-available is untrue")
            XCTAssertTrue(f.library.notice == f.camera.explanation, "The notice gives the same reason")
            XCTAssertTrue(f.camera.offersSourceChoice && !f.camera.preparedSourceAvailable, "The list offers the camera that is there")
            XCTAssertTrue(f.camera.failure?.offersRetry == true)

            // With no camera at all, the words stay the session's own.
            f.offer(PersonaCameraList(devices: [], preferredID: nil))
            f.library.retryCamera(); f.permissionRequests.last?(.authorized)
            f.capture.starts.last?.1(.failed(.unavailable))
            XCTAssertEqual(f.camera.state, .failed(.access(.unavailable)))

            // Choosing the remaining camera, then Try again, opens exactly that one.
            f.offer(PersonaCameraList(devices: [PersonaCameraDevice(id: "desk", name: "Desk camera", inUseByAnotherApp: false)],
                                      preferredID: "desk"))
            f.capture.starts.last?.1(.sources([ProfileCameraSource(id: "desk", name: "Desk camera")], selected: nil))
            f.library.retryCamera()
            f.camera.prepareDevice("desk")
            f.library.retryCamera(); f.permissionRequests.last?(.authorized)
            XCTAssertEqual(f.capture.starts.last?.0, "desk")
            f.capture.starts.last?.1(.frame)
            XCTAssertEqual(f.camera.state, .live)
        }
    }

    /// The End presentation overlays shortcut, through the app's own hotkey
    /// route, ends whichever source is live, as the shared End door does. With
    /// the camera live it ends the camera and keeps the card the camera replaced
    /// for Show again, instead of discarding that hidden card and leaving the
    /// camera running.
    func testEndOverlaysShortcutEndsTheLiveCameraAndKeepsTheReplacedCard() throws {
        try MainActor.assumeIsolated {
            let f = Fixture(); defer { f.cleanup() }
            // A suite named by a path keeps its plist in this folder, not in ~/Library/Preferences.
            let settings = SettingsStore(defaults: UserDefaults(suiteName: f.root.appendingPathComponent("settings").path)!)
            for action in Action.allCases {
                var shortcut = action.defaultShortcut; shortcut.enabled = false
                settings.value.shortcuts[action.rawValue] = shortcut
            }
            let app = AppCoordinator(settings: settings, archiveURL: f.root.appendingPathComponent("boards.json"), embedded: true)
            let scenes = DemoScenes(root: f.root.appendingPathComponent("scenes"), systemIntegrationEnabled: false, personaCamera: f.camera)
            app.demoScenes = scenes
            defer { scenes.shutdown() }
            let library = scenes.personas
            library.usesSharedControls = true
            let url = f.root.appendingPathComponent("synthetic.png")
            try Fixture.png().write(to: url)
            let card = try library.addImage(url, name: "Private Alpha", card: PersonaCardStyle(label: "Site lead"))
            library.selectedID = card.id
            app.handleHotkey(.personaToggle, down: true)
            let copy = library.shownCard?.copyID
            XCTAssertTrue(copy != nil && library.artworkVisible)

            library.startCamera(); f.permissionRequests.last?(.authorized); f.capture.starts.last?.1(.frame)
            XCTAssertEqual(f.camera.state, .live)
            XCTAssertTrue(library.hasHiddenCard, "The camera keeps the card it replaced")
            let stops = f.capture.stops
            app.handleHotkey(.overlayEnd, down: true)
            XCTAssertEqual(f.camera.state, .off, "End ends the source that is live")
            XCTAssertTrue(f.capture.stops > stops, "The camera is released")
            XCTAssertFalse(f.bubble.shown)
            XCTAssertEqual(library.liveSource, .artwork)
            XCTAssertTrue(library.hasHiddenCard && library.shownCard?.copyID == copy, "The replaced card is kept for Show again")
            app.handleHotkey(.personaToggle, down: true)
            XCTAssertTrue(library.artworkVisible && library.shownCard?.copyID == copy, "Show again brings back that exact card")
            // With artwork live, the shortcut still releases the card, as before.
            app.handleHotkey(.overlayEnd, down: true)
            XCTAssertTrue(library.shownCard == nil && !library.overlayVisible)
        }
    }
}
