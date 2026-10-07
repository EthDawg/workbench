import AppKit
import AVFoundation

/// Every row of the PhoneLink table, from synthetic signals only: no device,
/// permission prompt, capture session or IOKit notification is touched.
final class PhoneLinkTests {
    private let phone = PhoneLinkSignals.USBDevice(name: "iPhone", kind: .iPhone, productID: 0x12A8)
    private let screen = PhoneLinkSignals.ScreenSource(id: "udid-1", name: "Ethan’s iPhone", isScreen: true)
    private let card = PhoneLinkSignals.ScreenSource(id: "cap-2", name: "Capture card", isScreen: false)

    /// Signals after the bus has been looked at once, as on any Mac after the first second.
    private func signals(_ change: (inout PhoneLinkSignals) -> Void = { _ in }) -> PhoneLinkSignals {
        var value = PhoneLinkSignals(); value.usbProbe = .checked; change(&value); return value
    }

    /// A cold start never alarms the room: before the first look at the bus, and for the first
    /// seconds of a capture, Present says it is looking, with no "No phone" words, no Trust advice
    /// and no help link on the stage. After that the real answer shows.
    func testAColdStartLooksBeforeItSaysAnythingIsWrong() {
        let unchecked = PhoneLink.status(signals { $0.usbProbe = .notChecked; $0.capturing = true })
        XCTAssertEqual(unchecked.phase, .looking)
        XCTAssertEqual(unchecked.title, "Looking for your phone…")
        XCTAssertTrue(unchecked.detail == nil && unchecked.step == nil)
        XCTAssertFalse(unchecked.offersHelp, "No help link while nothing is known yet")
        XCTAssertFalse(unchecked.suggestsQuickTimeCheck)
        XCTAssertEqual(unchecked.tone, .neutral)

        let searchingWithPhone = PhoneLink.status(signals { $0.usb = [phone]; $0.capturing = true; $0.searching = true })
        XCTAssertEqual(searchingWithPhone.phase, .looking, "The screen list gets a moment before the Trust advice")
        XCTAssertEqual(searchingWithPhone.title, "Looking for your iPhone…")

        let settled = PhoneLink.status(signals { $0.usb = [phone]; $0.capturing = true; $0.searching = false })
        XCTAssertEqual(settled.phase, .phoneOnUSB, "After the grace, the real advice shows")
        let empty = PhoneLink.status(signals { $0.capturing = true; $0.searching = false })
        XCTAssertEqual(empty.phase, .noPhone)
        let failed = PhoneLink.status(signals { $0.usbProbe = .failed(-536870212); $0.capturing = true; $0.searching = true })
        XCTAssertEqual(failed.phase, .usbUnavailable, "A failed look is said at once, never hidden as looking")
    }

    func testNothingAttachedNamesTheCableAndTheAccessoryPrompt() {
        let status = PhoneLink.status(signals())
        XCTAssertEqual(status.phase, .noPhone)
        XCTAssertEqual(status.title, "No phone on USB")
        XCTAssertTrue(status.detail?.contains("data cable") == true)
        XCTAssertTrue(status.detail?.contains("allow the accessory") == true)
        XCTAssertTrue(status.step == nil)
        XCTAssertTrue(status.offersHelp)
        XCTAssertFalse(status.offersReconnect, "Nothing on the bus: looking again changes nothing")
        XCTAssertFalse(status.isLive)
    }

    func testPhoneOnTheBusWithoutAScreenAsksForUnlockAndTrust() {
        let status = PhoneLink.status(signals { $0.usb = [phone] })
        XCTAssertEqual(status.phase, .phoneOnUSB)
        XCTAssertEqual(status.title, "iPhone connected, screen not available yet")
        XCTAssertTrue(status.detail?.contains("Trust") == true)
        XCTAssertTrue(status.detail?.contains("allow the accessory") == true)
        XCTAssertTrue(status.step == nil, "Unlocking and trusting happen on the phone, not in Workbench")
        XCTAssertTrue(status.offersHelp)
        XCTAssertTrue(status.offersReconnect, "A nudge after Trust is worth offering")
        let tablet = PhoneLink.status(signals { $0.usb = [.init(name: "iPad", kind: .iPad, productID: 0x12AB)] })
        XCTAssertEqual(tablet.title, "iPad connected, screen not available yet")
    }

    func testOnePhoneScreenIsAdoptedAndAPlainVideoDeviceWaitsForAClick() {
        // The one phone screen: with a session allowed, the capture adopts it, so the words say
        // connecting and offer no click; with none allowed (the receipt), it is simply ready.
        let adopted = PhoneLink.status(signals { $0.usb = [phone]; $0.sources = [screen]; $0.capturing = true })
        XCTAssertEqual(adopted.phase, .connecting)
        XCTAssertEqual(adopted.title, "Connecting to iPhone…")
        XCTAssertTrue(adopted.step == nil)
        XCTAssertFalse(adopted.offersHelp)
        let ready = PhoneLink.status(signals { $0.usb = [phone]; $0.sources = [screen] })
        XCTAssertEqual(ready.phase, .available)
        XCTAssertEqual(ready.title, "iPhone ready")
        XCTAssertTrue(ready.detail?.contains("Ethan’s iPhone") == true)
        // A plain video device is never shown by itself.
        let found = PhoneLink.status(signals { $0.sources = [card] })
        XCTAssertEqual(found.phase, .screenFound)
        XCTAssertEqual(found.title, "Capture card found")
        XCTAssertEqual(found.step, .showSource(id: "cap-2", title: "Show Capture card"))
        XCTAssertTrue(found.detail?.contains("remembers") == true)
        // A display camera, Camo or a capture card beside the phone does not make it a choice.
        let besideCamera = PhoneLink.status(signals { $0.usb = [phone]; $0.sources = [card, screen]; $0.capturing = true })
        XCTAssertEqual(besideCamera.phase, .connecting)
        XCTAssertEqual(besideCamera.title, "Connecting to iPhone…")
        XCTAssertEqual(PhoneLink.status(signals { $0.usb = [phone]; $0.sources = [card, screen] }).title, "iPhone ready")
        // A ready screen whose kind is unknown still starts its title with a capital.
        XCTAssertEqual(PhoneLink.status(signals { $0.sources = [.init(id: "s", name: "Screen 00008030", isScreen: true)] }).title, "Phone ready")
        // The capture's own rule behind the words.
        var recovery = CaptureRecovery()
        XCTAssertEqual(recovery.candidate(in: [DemoSource(id: screen.id, name: screen.name, isScreen: true)]), screen.id, "One phone screen is adopted")
        XCTAssertTrue(recovery.candidate(in: [DemoSource(id: card.id, name: card.name, isScreen: false)]) == nil, "One plain video device is not")
        XCTAssertEqual(recovery.candidate(in: [DemoSource(id: screen.id, name: screen.name, isScreen: true), DemoSource(id: card.id, name: card.name, isScreen: false)]), screen.id, "A camera beside the phone is no choice")
        XCTAssertTrue(recovery.candidate(in: [DemoSource(id: screen.id, name: screen.name, isScreen: true), DemoSource(id: "udid-2", name: "iPad", isScreen: true)]) == nil, "Two screens need a choice")
        _ = recovery.select(screen.id)
        XCTAssertEqual(recovery.candidate(in: [DemoSource(id: card.id, name: card.name, isScreen: false), DemoSource(id: screen.id, name: screen.name, isScreen: true)]), screen.id)
        recovery.invalidateSession()
        XCTAssertTrue(recovery.candidate(in: [DemoSource(id: card.id, name: card.name, isScreen: false)]) == nil, "Loss of the remembered device never opens another")
        XCTAssertTrue(recovery.candidate(in: [DemoSource(id: "udid-9", name: "Someone’s iPhone", isScreen: true)]) == nil, "Not even another phone")
    }

    func testSeveralScreensAskForAChoiceAndARememberedAbsentPhoneWaits() {
        let several = PhoneLink.status(signals { $0.sources = [screen, .init(id: "udid-2", name: "Test iPad", isScreen: true), card] })
        XCTAssertEqual(several.phase, .chooseScreen)
        XCTAssertEqual(several.title, "2 screens available", "Only screens are counted")
        XCTAssertEqual(several.step, .chooseSource)
        let cameras = PhoneLink.status(signals { $0.sources = [card, .init(id: "cam", name: "Display camera", isScreen: false)] })
        XCTAssertEqual(cameras.phase, .chooseScreen)
        XCTAssertEqual(cameras.title, "2 video sources available", "Cameras are never called screens")
        let waiting = PhoneLink.status(signals { $0.sources = [card]; $0.rememberedID = screen.id; $0.usb = [phone] })
        XCTAssertEqual(waiting.phase, .waitingForRemembered)
        XCTAssertEqual(waiting.title, "Waiting for your remembered iPhone")
        XCTAssertTrue(waiting.detail?.contains("Capture card") == true, "The one other screen is named so it can be chosen")
        XCTAssertEqual(waiting.step, .chooseSource)
        let waitingAlone = PhoneLink.status(signals { $0.rememberedID = screen.id })
        XCTAssertEqual(waitingAlone.phase, .noPhone, "A remembered phone that is not even on USB reads as no phone")
        let waitingOnBus = PhoneLink.status(signals { $0.rememberedID = screen.id; $0.usb = [phone] })
        XCTAssertEqual(waitingOnBus.phase, .phoneOnUSB)
    }

    func testRememberedPhonePresentReadsAsConnectingUntilTheSessionSpeaks() {
        let status = PhoneLink.status(signals { $0.sources = [screen]; $0.rememberedID = screen.id; $0.capturing = true })
        XCTAssertEqual(status.phase, .connecting)
        XCTAssertEqual(status.title, "Connecting to iPhone…")
        XCTAssertTrue(status.step == nil)
        XCTAssertFalse(status.offersHelp)
        let ready = PhoneLink.status(signals { $0.sources = [screen]; $0.rememberedID = screen.id })
        XCTAssertEqual(ready.phase, .available, "With no session allowed, as in the headless receipt, the screen is ready for Present")
        XCTAssertEqual(ready.title, "iPhone ready")
    }

    func testSessionPhasesOutrankAvailability() {
        let base: (inout PhoneLinkSignals) -> Void = { $0.sources = [self.screen]; $0.rememberedID = self.screen.id; $0.access = .authorized; $0.capturing = true }
        let live = PhoneLink.status(signals { base(&$0); $0.phase = .live(self.screen.id, CGSize(width: 1179, height: 2556)) })
        XCTAssertEqual(live.phase, .live)
        XCTAssertEqual(live.title, "Showing iPhone")
        XCTAssertTrue(live.isLive)
        XCTAssertTrue(live.step == nil)
        XCTAssertFalse(live.offersHelp)
        let stalled = PhoneLink.status(signals { base(&$0); $0.phase = .stalled(self.screen.id) })
        XCTAssertEqual(stalled.phase, .stalled)
        XCTAssertEqual(stalled.step, .reconnect)
        XCTAssertFalse(stalled.offersReconnect, "Reconnect is already the step")
        XCTAssertTrue(stalled.offersHelp)
        XCTAssertFalse(live.offersReconnect)
        let interrupted = PhoneLink.status(signals { base(&$0); $0.phase = .interrupted(self.screen.id); $0.sources = [] })
        XCTAssertEqual(interrupted.phase, .interrupted)
        XCTAssertEqual(interrupted.title, "Phone disconnected", "With the source gone and nothing on the bus, only the kind is unknown")
        let unplugged = PhoneLink.status(signals { base(&$0); $0.phase = .interrupted(self.screen.id); $0.sources = []; $0.usb = [self.phone] })
        XCTAssertEqual(unplugged.title, "iPhone disconnected", "The bus still names the kind while the screen is away")
        XCTAssertEqual(interrupted.step, .reconnect)
        let busy = PhoneLink.status(signals { base(&$0); $0.phase = .failed(self.screen.id, .busy) })
        XCTAssertEqual(busy.phase, .busy)
        XCTAssertTrue(busy.title.contains("Another app"))
        XCTAssertTrue(busy.detail?.contains("QuickTime") == true)
        let unopenable = PhoneLink.status(signals { base(&$0); $0.phase = .failed(self.screen.id, .couldNotOpen) })
        XCTAssertEqual(unopenable.phase, .couldNotOpen)
        XCTAssertEqual(unopenable.step, .reconnect)
        let unstarted = PhoneLink.status(signals { base(&$0); $0.phase = .failed(self.screen.id, .couldNotStart) })
        XCTAssertEqual(unstarted.phase, .couldNotStart)
        XCTAssertEqual(unstarted.title, "The iPhone’s screen didn’t start")
        XCTAssertFalse(unstarted.title.contains("Another app"), "A generic start failure never blames another app")
        XCTAssertEqual(unstarted.step, .reconnect)
        let connecting = PhoneLink.status(signals { base(&$0); $0.phase = .connecting(self.screen.id) })
        XCTAssertEqual(connecting.title, "Connecting to iPhone…")
        let prompt = PhoneLink.status(signals { base(&$0); $0.phase = .waitingForAccess })
        XCTAssertEqual(prompt.phase, .accessPending)
        XCTAssertTrue(prompt.detail?.contains("never opens the phone’s microphone") == true)
    }

    func testPermissionOutranksAvailabilityAndRestrictedOffersNoToggle() {
        let denied = PhoneLink.status(signals { $0.sources = [screen]; $0.access = .denied })
        XCTAssertEqual(denied.phase, .accessDenied)
        XCTAssertEqual(denied.step, .openCameraSettings)
        XCTAssertTrue(denied.detail?.contains("System Settings") == true)
        XCTAssertFalse(denied.offersReconnect, "While access is off, looking again changes nothing; returning from System Settings re-reads it by itself")
        let restricted = PhoneLink.status(signals { $0.sources = [screen]; $0.access = .restricted })
        XCTAssertEqual(restricted.phase, .accessRestricted)
        XCTAssertTrue(restricted.step == nil, "A policy restriction cannot be removed by the person's Camera toggle")
        XCTAssertFalse(restricted.detail?.contains("System Settings") == true)
        XCTAssertTrue(restricted.detail?.contains("IT") == true)
        XCTAssertTrue(restricted.offersHelp)
        let live = PhoneLink.status(signals { $0.access = .denied; $0.phase = .live(screen.id, CGSize(width: 10, height: 20)); $0.sources = [screen] })
        XCTAssertEqual(live.phase, .live, "A session that is already live is the truth, whatever the cached permission says")
    }

    func testReleasedForAnAppleAppSaysSoUntilReconnect() {
        let released = PhoneLink.status(signals { $0.sources = [screen]; $0.rememberedID = screen.id; $0.usb = [phone]; $0.released = .forAnotherApp })
        XCTAssertEqual(released.phase, .released)
        XCTAssertEqual(released.title, "Let go for another app")
        XCTAssertTrue(released.detail?.contains("QuickTime Player") == true)
        XCTAssertEqual(released.step, .reconnect)
        XCTAssertFalse(released.offersHelp)
        XCTAssertFalse(released.offersReconnect, "Reconnect is already the step")
        let live = PhoneLink.status(signals { $0.released = .forAnotherApp; $0.phase = .live(screen.id, CGSize(width: 1, height: 2)); $0.sources = [screen] })
        XCTAssertEqual(live.phase, .live, "A session that is running was never released")
        let unplugged = PhoneLink.status(signals { $0.released = .forAnotherApp; $0.capturing = true })
        XCTAssertEqual(unplugged.phase, .released, "The release outranks what is on the bus and whether a session is allowed")
        XCTAssertTrue(PhoneLink.diagnostic(signals { $0.released = .forAnotherApp }, build: "b").contains("Session: released for another app"))
    }

    func testEndedSaysSoAndOffersOnlyADeliberateWayBack() {
        let ended = PhoneLink.status(signals { $0.sources = [screen]; $0.rememberedID = screen.id; $0.usb = [phone]; $0.released = .ended; $0.access = .authorized })
        XCTAssertEqual(ended.phase, .ended)
        XCTAssertEqual(ended.title, "Presentation ended")
        XCTAssertTrue(ended.detail?.contains("Reconnect") == true)
        XCTAssertEqual(ended.step, .reconnect, "The page's preview comes back only when asked")
        XCTAssertFalse(ended.offersHelp, "Nothing is wrong: Workbench let go on purpose")
        XCTAssertFalse(ended.suggestsQuickTimeCheck)
        XCTAssertEqual(PhoneLink.status(signals { $0.released = .ended; $0.sources = [screen]; $0.capturing = true }).phase, .ended,
                       "A visible page does not turn End into connecting")
        XCTAssertTrue(PhoneLink.diagnostic(signals { $0.released = .ended }, build: "b").contains("Session: released when the presentation ended"))
    }

    func testAFailedUSBCheckIsNotAnEmptyBus() {
        let code = Int32(bitPattern: 0xE00002C7)
        let failed = PhoneLink.status(signals { $0.usbProbe = .failed(code) })
        XCTAssertEqual(failed.phase, .usbUnavailable)
        XCTAssertEqual(failed.title, "Workbench couldn’t check USB")
        XCTAssertFalse(failed.title.contains("No phone"), "A failed look never reads as nothing attached")
        XCTAssertTrue(failed.offersHelp)
        let report = PhoneLink.diagnostic(signals { $0.usbProbe = .failed(code) }, build: "b")
        XCTAssertTrue(report.contains("USB: check failed (IOKit 0xE00002C7)"))
        XCTAssertFalse(report.contains("no iPhone or iPad on the bus"))
        XCTAssertTrue(PhoneLink.diagnostic(signals { $0.usbProbe = .checked }, build: "b").contains("USB: no iPhone or iPad on the bus"))
        XCTAssertTrue(PhoneLink.diagnostic(signals { $0.usbProbe = .notChecked }, build: "b").contains("USB: not checked"), "Never looked is not an empty bus either")
        // A screen macOS offers is still there to show, whatever the USB check said.
        XCTAssertEqual(PhoneLink.status(signals { $0.usbProbe = .failed(code); $0.sources = [screen] }).phase, .available)
    }

    /// The monitor's own USB callback, from a synthetic watch: a failure is kept as a failure,
    /// a later look replaces it, and a look that lands after Present stopped watching is dropped.
    @MainActor func testTheMonitorKeepsAFailedLookAndDropsALateOne() {
        final class Watch: USBWatching {
            var onChange: ((USBProbeResult) -> Void)?
            var running = false
            func start() { running = true }
            func stop() { running = false }
        }
        func settle() { let end = Date().addingTimeInterval(0.2); while Date() < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) } }
        let watch = Watch()
        let monitor = PhoneLinkMonitor(usb: watch)
        monitor.setActive(true)
        XCTAssertTrue(watch.running)
        watch.onChange?(.failure(.init(code: Int32(bitPattern: 0xE00002BC))))
        settle()
        XCTAssertEqual(monitor.signals.usbProbe, .failed(Int32(bitPattern: 0xE00002BC)))
        XCTAssertEqual(monitor.status.phase, .usbUnavailable)
        var connections = 0
        monitor.onNewConnection = { connections += 1 }
        watch.onChange?(.success([phone]))
        settle()
        XCTAssertEqual(monitor.status.phase, .phoneOnUSB)
        XCTAssertEqual(connections, 0, "Finding the phone after a failed look is not a new connection")
        watch.onChange?(.success([phone])); settle()
        XCTAssertEqual(connections, 0, "nor is finding it still there")
        watch.onChange?(.success([])); settle()
        watch.onChange?(.success([phone])); settle()
        XCTAssertEqual(connections, 1, "Plugged in again after the bus was seen without it is")
        monitor.setActive(false)
        XCTAssertFalse(watch.running)
        watch.onChange?(.success([phone]))
        settle()
        XCTAssertEqual(monitor.signals.usb, [], "A look after the watch stopped brings nothing back")
        XCTAssertEqual(monitor.signals.usbProbe, .notChecked)
    }

    func testCaptureFaultsStayBoundedAndOnlyABusyDeviceNamesQuickTime() {
        let base: (inout PhoneLinkSignals) -> Void = { $0.sources = [self.screen]; $0.rememberedID = self.screen.id; $0.access = .authorized; $0.usbProbe = .checked }
        let fault = CaptureFault(NSError(domain: AVFoundationErrorDomain, code: -11814,
                                         userInfo: [NSLocalizedDescriptionKey: "Ethan’s iPhone could not be opened", "device": "udid-1"]))
        XCTAssertEqual(fault.text, "\(AVFoundationErrorDomain) -11814")
        let unopenable = signals { base(&$0); $0.phase = .failed(self.screen.id, .couldNotOpen, fault) }
        let report = PhoneLink.diagnostic(unopenable, build: "b")
        XCTAssertTrue(report.contains("Session: could not open the device (\(AVFoundationErrorDomain) -11814)"), "The underlying code is kept for the report")
        XCTAssertFalse(report.contains("could not be opened"), "The error's message and user info stay out of the report")
        XCTAssertFalse(report.contains("udid-1"))
        XCTAssertEqual(CaptureFault(domain: String(repeating: "x", count: 500), code: 1).domain.count, 64)
        let interrupted = signals { base(&$0); $0.phase = .interrupted(self.screen.id, CaptureFault(domain: AVFoundationErrorDomain, code: -11819)) }
        XCTAssertTrue(PhoneLink.diagnostic(interrupted, build: "b").contains("Session: interrupted (\(AVFoundationErrorDomain) -11819)"))
        for failure in [CapturePhase.Failure.couldNotOpen, .couldNotStart] {
            let status = PhoneLink.status(signals { base(&$0); $0.phase = .failed(self.screen.id, failure) })
            XCTAssertFalse(status.detail?.contains("QuickTime") == true, "A generic failure never blames QuickTime")
            XCTAssertFalse(status.detail?.contains("other") == true, "or any other app")
            XCTAssertTrue(status.suggestsQuickTimeCheck, "QuickTime is offered as a check, not a cause")
        }
        let busy = PhoneLink.status(signals { base(&$0); $0.phase = .failed(self.screen.id, .busy) })
        XCTAssertTrue(busy.detail?.contains("QuickTime") == true, "Only macOS's own in-use answer names QuickTime")
        XCTAssertFalse(busy.suggestsQuickTimeCheck, "Another app already holds the screen: opening QuickTime is no check")
        for phase in [PhoneLinkStatus.Phase.live, .connecting, .available, .accessDenied, .accessRestricted, .released, .ended, .chooseScreen] {
            XCTAssertFalse(PhoneLinkStatus(phase: phase, title: "", detail: nil, step: nil).suggestsQuickTimeCheck, "No QuickTime check while \(phase)")
        }
    }

    /// The report replaces every device's own name with its kind, including where the status
    /// words would carry it. The page itself still names the screen for the person at the Mac.
    func testReportsCarryKindsNeverPersonalNames() {
        let personalCard = PhoneLinkSignals.ScreenSource(id: "cap-9", name: "Ethan’s Capture Card", isScreen: false)
        let personalBus = PhoneLinkSignals.USBDevice(name: "Ethan’s iPhone", kind: .iPhone, productID: 0x12A8)
        // Each state whose page words name a device: ready, found, and waiting with one other screen.
        let named: [PhoneLinkSignals] = [
            signals { $0.usb = [personalBus]; $0.usbProbe = .checked; $0.sources = [screen] },
            signals { $0.sources = [personalCard] },
            signals { $0.sources = [personalCard]; $0.rememberedID = screen.id; $0.usb = [personalBus]; $0.usbProbe = .checked }]
        let cases = named + [signals { $0.sources = [screen, personalCard] }]
        for value in cases {
            let words = PhoneLink.status(value)
            if named.contains(value) {
                let shown = words.title + " " + (words.detail ?? "") + " " + (words.step?.title ?? "")
                XCTAssertTrue(shown.contains("Ethan"), "The page's own words still name the screen: \(shown)")
            }
            let report = PhoneLink.diagnostic(value, build: "b")
            XCTAssertFalse(report.contains("Ethan"), "No personal name reaches a report: \(report)")
            let reported = PhoneLink.sharedStatus(value)
            XCTAssertFalse((reported.title + (reported.detail ?? "") + (reported.step?.title ?? "")).contains("Ethan"), "nor the receipt's status words")
            XCTAssertEqual(reported.phase, words.phase, "The report's words describe the same state")
        }
        let report = PhoneLink.diagnostic(cases[3], build: "b")
        XCTAssertTrue(report.contains("Screen sources: iPhone (screen), Video device (video)"))
        // Two phones of one kind stay apart without their names, on the stage as in a report.
        let two = signals { $0.sources = [screen, .init(id: "udid-7", name: "Ethan’s other iPhone", isScreen: true)] }.anonymised
        XCTAssertEqual(two.sources.map(\.name), ["iPhone", "iPhone 2"])
        XCTAssertTrue(PhoneLink.diagnostic(cases[0], build: "b").contains("USB: iPhone (product 0x12A8)"))
    }

    /// Copy connection details claims success only when the pasteboard took the text.
    func testCopySuccessDependsOnThePasteboardsAnswer() {
        let board = NSPasteboard(name: NSPasteboard.Name("Workbench.PhoneLinkTests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        XCTAssertTrue(PhoneConnectionSupport.copy("Workbench b · facts", to: board))
        XCTAssertEqual(board.string(forType: .string), "Workbench b · facts")
        let copied = PhoneConnectionSupport.copyOutcome(true)
        XCTAssertEqual(copied.label, "Copied")
        XCTAssertEqual(copied.announcement, "Connection details copied")
        let failed = PhoneConnectionSupport.copyOutcome(false)
        XCTAssertEqual(failed.label, "Couldn’t copy")
        XCTAssertFalse(failed.announcement == copied.announcement, "VoiceOver never hears success for a failed write")
        XCTAssertTrue(failed.announcement.contains("not copied"))
    }

    func testNounsFollowTheDeviceNotTheSerial() {
        XCTAssertEqual(PhoneLink.noun(for: .init(id: "x", name: "Ethan’s iPad", isScreen: true), usb: []), "iPad")
        XCTAssertEqual(PhoneLink.noun(for: .init(id: "x", name: "Ethan’s iPad", isScreen: true), usb: [phone]), "iPhone", "The bus names the model before the person's own device name")
        XCTAssertEqual(PhoneLink.noun(for: .init(id: "x", name: "Screen 00008030", isScreen: true), usb: [phone]), "iPhone")
        XCTAssertEqual(PhoneLink.noun(for: .init(id: "x", name: "Capture card", isScreen: false), usb: []), "device")
        XCTAssertEqual(PhoneLink.noun(for: nil, usb: []), "phone")
        XCTAssertEqual(PhoneLink.noun(for: nil, usb: [.init(name: "iPod touch", kind: .iPod, productID: 0x12AA)]), "iPod touch")
    }

    func testUSBClassificationKeepsPhonesAndDropsOtherAppleDevices() {
        XCTAssertEqual(USBPhoneWatch.classify(name: "iPhone", vendor: 0x05AC, product: 0x12A8)?.kind, .iPhone)
        XCTAssertEqual(USBPhoneWatch.classify(name: "iPad", vendor: 0x05AC, product: 0x12AB)?.kind, .iPad)
        XCTAssertEqual(USBPhoneWatch.classify(name: "", vendor: 0x05AC, product: 0x12AA)?.name, "iPod touch")
        XCTAssertEqual(USBPhoneWatch.classify(name: "iPhone", vendor: 0x05AC, product: 0x1234)?.kind, .iPhone, "An unknown product identifier still counts by name")
        XCTAssertTrue(USBPhoneWatch.classify(name: "Magic Keyboard", vendor: 0x05AC, product: 0x029C) == nil)
        XCTAssertTrue(USBPhoneWatch.classify(name: "USB3.0 Hub", vendor: 0x05AC, product: 0x1000) == nil)
        XCTAssertTrue(USBPhoneWatch.classify(name: "iPhone", vendor: 0x1234, product: 0x12A8) == nil, "Only Apple's vendor identifier counts")
        // Enumerating the bus is read-only and needs no device; it must not fail on a Mac with nothing attached.
        _ = USBPhoneWatch.snapshot()
    }

    func testDiagnosticNamesFactsWithoutIdentifiers() {
        let value = signals {
            $0.usb = [phone]; $0.usbProbe = .checked; $0.sources = [screen]; $0.rememberedID = screen.id; $0.access = .authorized; $0.capturing = true
            $0.phase = .live(screen.id, CGSize(width: 1179, height: 2556))
        }
        let text = PhoneLink.diagnostic(value, build: "2.5.0 (test)")
        XCTAssertTrue(text.contains("Workbench 2.5.0 (test) · macOS"))
        XCTAssertTrue(text.contains("USB: iPhone (product 0x12A8)"))
        XCTAssertTrue(text.contains("Screen sources: iPhone (screen)"))
        XCTAssertFalse(text.contains("Ethan"), "The screen's personal name stays on this Mac")
        XCTAssertTrue(text.contains("Remembered device: present"))
        XCTAssertTrue(text.contains("Device video access: authorized"))
        XCTAssertTrue(text.contains("Session: live 1179×2556"))
        XCTAssertTrue(text.contains("Status: Showing iPhone"))
        XCTAssertFalse(text.contains("udid-1"), "No device identifier leaves the Mac in a report")
        let empty = PhoneLink.diagnostic(signals { $0.usbProbe = .checked }, build: "b")
        XCTAssertTrue(empty.contains("USB: no iPhone or iPad on the bus"))
        XCTAssertTrue(empty.contains("Remembered device: none"))
        XCTAssertTrue(empty.contains("Status: No phone on USB — Connect"))
    }

    /// A fixture pins the words for an offscreen render; clearing it returns to the Mac's facts.
    @MainActor func testMonitorFixtureAndMirrorAreIndependent() {
        let monitor = PhoneLinkMonitor()
        XCTAssertEqual(monitor.status.phase, .looking, "A monitor that has not looked at the bus yet is looking, not reporting no phone")
        monitor.fixture = signals { $0.usb = [phone] }
        XCTAssertEqual(monitor.status.phase, .phoneOnUSB)
        monitor.fixture = nil
        XCTAssertEqual(monitor.status.phase, .looking, "Nothing was mirrored, so the facts are empty again")
        XCTAssertEqual(monitor.diagnostic(build: "t").split(separator: "\n").count, 7)
    }
}
