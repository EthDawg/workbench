import AppKit

/// Every row of the PhoneLink table, from synthetic signals only: no device,
/// permission prompt, capture session or IOKit notification is touched.
final class PhoneLinkTests {
    private let phone = PhoneLinkSignals.USBDevice(name: "iPhone", kind: .iPhone, productID: 0x12A8)
    private let screen = PhoneLinkSignals.ScreenSource(id: "udid-1", name: "Ethan’s iPhone", isScreen: true)
    private let card = PhoneLinkSignals.ScreenSource(id: "cap-2", name: "Capture card", isScreen: false)

    private func signals(_ change: (inout PhoneLinkSignals) -> Void = { _ in }) -> PhoneLinkSignals {
        var value = PhoneLinkSignals(); change(&value); return value
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
        // The capture's own rule behind the words.
        var recovery = CaptureRecovery()
        XCTAssertEqual(recovery.candidate(in: [DemoSource(id: screen.id, name: screen.name, isScreen: true)]), screen.id, "One phone screen is adopted")
        XCTAssertTrue(recovery.candidate(in: [DemoSource(id: card.id, name: card.name, isScreen: false)]) == nil, "One plain video device is not")
        XCTAssertTrue(recovery.candidate(in: [DemoSource(id: screen.id, name: screen.name, isScreen: true), DemoSource(id: card.id, name: card.name, isScreen: false)]) == nil, "Two sources need a choice")
        _ = recovery.select(screen.id)
        XCTAssertEqual(recovery.candidate(in: [DemoSource(id: card.id, name: card.name, isScreen: false), DemoSource(id: screen.id, name: screen.name, isScreen: true)]), screen.id)
        recovery.invalidateSession()
        XCTAssertTrue(recovery.candidate(in: [DemoSource(id: card.id, name: card.name, isScreen: false)]) == nil, "Loss of the remembered device never opens another")
        XCTAssertTrue(recovery.candidate(in: [DemoSource(id: "udid-9", name: "Someone’s iPhone", isScreen: true)]) == nil, "Not even another phone")
    }

    func testSeveralScreensAskForAChoiceAndARememberedAbsentPhoneWaits() {
        let several = PhoneLink.status(signals { $0.sources = [screen, card] })
        XCTAssertEqual(several.phase, .chooseScreen)
        XCTAssertEqual(several.title, "2 screens available")
        XCTAssertEqual(several.step, .chooseSource)
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
        XCTAssertTrue(denied.offersReconnect, "Coming back from System Settings, Reconnect is the way to try again")
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
        XCTAssertEqual(PhoneLink.status(signals { $0.released = .ended; $0.sources = [screen]; $0.capturing = true }).phase, .ended,
                       "A visible page does not turn End into connecting")
        XCTAssertTrue(PhoneLink.diagnostic(signals { $0.released = .ended }, build: "b").contains("Session: released when the presentation ended"))
    }

    /// The report replaces every device's own name with its kind, including where the status
    /// words would carry it. The page itself still names the screen for the person at the Mac.
    func testReportsCarryKindsNeverPersonalNames() {
        let personalCard = PhoneLinkSignals.ScreenSource(id: "cap-9", name: "Ethan’s Capture Card", isScreen: false)
        let personalBus = PhoneLinkSignals.USBDevice(name: "Ethan’s iPhone", kind: .iPhone, productID: 0x12A8)
        // Each state whose page words name a device: ready, found, and waiting with one other screen.
        let named: [PhoneLinkSignals] = [
            signals { $0.usb = [personalBus]; $0.sources = [screen] },
            signals { $0.sources = [personalCard] },
            signals { $0.sources = [personalCard]; $0.rememberedID = screen.id; $0.usb = [personalBus] }]
        let cases = named + [signals { $0.sources = [screen, personalCard] }]
        for value in cases {
            let words = PhoneLink.status(value)
            if named.contains(value) {
                let shown = words.title + " " + (words.detail ?? "") + " " + (words.step?.title ?? "")
                XCTAssertTrue(shown.contains("Ethan"), "The page's own words still name the screen: \(shown)")
            }
            let report = PhoneLink.diagnostic(value, build: "b")
            XCTAssertFalse(report.contains("Ethan"), "No personal name reaches a report: \(report)")
            let reported = PhoneLink.reportStatus(value)
            XCTAssertFalse((reported.title + (reported.detail ?? "") + (reported.step?.title ?? "")).contains("Ethan"), "nor the receipt's status words")
            XCTAssertEqual(reported.phase, words.phase, "The report's words describe the same state")
        }
        let report = PhoneLink.diagnostic(cases[3], build: "b")
        XCTAssertTrue(report.contains("Screen sources: iPhone (screen), Video device (video)"))
        XCTAssertTrue(PhoneLink.diagnostic(cases[0], build: "b").contains("USB: iPhone (product 0x12A8)"))
    }

    func testNounsFollowTheDeviceNotTheSerial() {
        XCTAssertEqual(PhoneLink.noun(for: .init(id: "x", name: "Ethan’s iPad", isScreen: true), usb: []), "iPad")
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
            $0.usb = [phone]; $0.sources = [screen]; $0.rememberedID = screen.id; $0.access = .authorized; $0.capturing = true
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
        let empty = PhoneLink.diagnostic(PhoneLinkSignals(), build: "b")
        XCTAssertTrue(empty.contains("USB: no iPhone or iPad on the bus"))
        XCTAssertTrue(empty.contains("Remembered device: none"))
        XCTAssertTrue(empty.contains("Status: No phone on USB — Connect"))
    }

    /// A fixture pins the words for an offscreen render; clearing it returns to the Mac's facts.
    @MainActor func testMonitorFixtureAndMirrorAreIndependent() {
        let monitor = PhoneLinkMonitor()
        XCTAssertEqual(monitor.status.phase, .noPhone)
        monitor.fixture = signals { $0.usb = [phone] }
        XCTAssertEqual(monitor.status.phase, .phoneOnUSB)
        monitor.fixture = nil
        XCTAssertEqual(monitor.status.phase, .noPhone, "Nothing was mirrored, so the facts are empty again")
        XCTAssertEqual(monitor.diagnostic(build: "t").split(separator: "\n").count, 7)
    }
}
