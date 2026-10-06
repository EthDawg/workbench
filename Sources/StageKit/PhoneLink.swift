import AppKit
import AVFoundation
import Combine
import CoreMediaIO
import IOKit

// MARK: - Signals and status

/// What the Mac can see of a phone right now. Two signals need no permission:
/// the USB bus says whether an iPhone or iPad is attached at all, and the screen
/// sources macOS offers for capture say whether its screen is available, which
/// takes an unlocked, trusted phone and an allowed accessory. The camera
/// permission and the capture session's own phase complete the picture.
/// `PhoneLink.status` turns them into one line and one next step, and every
/// Present surface shows those same words.
public struct PhoneLinkSignals: Equatable {
    public struct USBDevice: Equatable {
        public enum Kind: Equatable { case iPhone, iPad, iPod }
        public var name: String
        public var kind: Kind
        public var productID: Int
        public init(name: String, kind: Kind, productID: Int) { self.name = name; self.kind = kind; self.productID = productID }
        var noun: String {
            switch kind { case .iPhone: return "iPhone"; case .iPad: return "iPad"; case .iPod: return "iPod touch" }
        }
    }
    public struct ScreenSource: Equatable, Identifiable {
        public var id: String
        public var name: String
        /// Muxed media is a display hint only; it never establishes a phone's identity.
        public var isScreen: Bool
        public init(id: String, name: String, isScreen: Bool) { self.id = id; self.name = name; self.isScreen = isScreen }
    }
    public enum VideoAccess: Equatable { case notDetermined, authorized, denied, restricted }
    /// The last look at the USB bus. A look that failed is not an empty bus: it is
    /// kept with its IOKit result code, so the words and the report say "couldn't check".
    public enum USBProbe: Equatable { case notChecked, checked, failed(Int32) }
    /// Why Workbench let go of the phone. Either way the capture stays off until the
    /// person asks for it back: Present, Reconnect, or showing a screen.
    public enum Release: Equatable { case ended, forAnotherApp }
    public var usb: [USBDevice] = []
    public var usbProbe = USBProbe.notChecked
    public var sources: [ScreenSource] = []
    /// The exact device a previous choice saved. Reconnects only ever reopen this one.
    public var rememberedID: String?
    public var access: VideoAccess = .notDetermined
    public var phase: CapturePhase = .idle
    /// Workbench let go of the phone (the presentation ended, or an Apple app needed it),
    /// and stays out of the way until the person asks for it back.
    public var released: Release?
    /// A capture session is allowed to run now (the Present page shows a device scene,
    /// or a presentation with a device frame runs), so an available screen is about to
    /// be shown. Off in the headless receipt, where nothing ever connects.
    public var capturing = false
    public init() {}

    /// The same facts with every device's own name replaced by its kind, so a report or the
    /// stage in a call never carries a personal name such as "Ethan’s iPhone", not even inside
    /// the status words. A second source of the same kind is numbered ("iPhone 2").
    /// Identifiers stay for matching and are never printed.
    public var anonymised: PhoneLinkSignals {
        var copy = self
        copy.usb = usb.map { .init(name: $0.noun, kind: $0.kind, productID: $0.productID) }
        var seen: [String: Int] = [:]
        copy.sources = sources.map { source in
            let kind = source.isScreen ? PhoneLink.capitalised(PhoneLink.noun(for: source, usb: usb)) : "Video device"
            seen[kind, default: 0] += 1
            return .init(id: source.id, name: seen[kind] == 1 ? kind : "\(kind) \(seen[kind]!)", isScreen: source.isScreen)
        }
        return copy
    }
}

/// A capture failure's bounded identity for a report: the error's domain and code,
/// never its message or user-info dictionary.
public struct CaptureFault: Equatable {
    public let domain: String
    public let code: Int
    public init(domain: String, code: Int) { self.domain = String(domain.prefix(64)); self.code = code }
    public init(_ error: Error) {
        let error = error as NSError
        self.init(domain: error.domain, code: error.code)
    }
    public var text: String { "\(domain) \(code)" }
}

/// The capture session's own phase, published by `DemoCapture`. Words live in
/// `PhoneLink.status`, not here.
public enum CapturePhase: Equatable {
    /// `busy` only when macOS said another app holds the device; `couldNotStart` is a
    /// session that configured but never ran, for any reason.
    public enum Failure: Equatable { case busy, couldNotOpen, couldNotStart }
    case idle
    case waitingForAccess
    case connecting(String)
    case live(String, CGSize)
    case stalled(String)
    /// The device went away or the session stopped with an error, kept bounded for the report.
    case interrupted(String, CaptureFault? = nil)
    case failed(String, Failure, CaptureFault? = nil)
    var deviceID: String? {
        switch self {
        case .idle, .waitingForAccess: return nil
        case .connecting(let id), .stalled(let id), .interrupted(let id, _): return id
        case .live(let id, _): return id
        case .failed(let id, _, _): return id
        }
    }
    var fault: CaptureFault? {
        switch self {
        case .interrupted(_, let fault), .failed(_, _, let fault): return fault
        default: return nil
        }
    }
}

public struct PhoneLinkStatus: Equatable {
    public enum Phase: Equatable {
        case noPhone, usbUnavailable, phoneOnUSB, screenFound, chooseScreen, waitingForRemembered, available, connecting, live, stalled,
             interrupted, busy, couldNotOpen, couldNotStart, accessPending, accessDenied, accessRestricted, released, ended
    }
    /// The one next action a surface renders beside the words. nil means the words
    /// already say what to do away from the Mac (unlock, trust, a cable).
    public enum Step: Equatable {
        case showSource(id: String, title: String)
        case chooseSource
        case reconnect
        case openCameraSettings
        public var title: String {
            switch self {
            case .showSource(_, let title): return title
            case .chooseSource: return "Choose screen…"
            case .reconnect: return "Reconnect"
            case .openCameraSettings: return "Open Camera settings"
            }
        }
    }
    public var phase: Phase
    public var title: String
    public var detail: String?
    public var step: Step?
    public var isLive: Bool { phase == .live }
    /// Reconnect is worth offering only where looking again can change something and
    /// the next step is not already Reconnect: a phone on the bus, a choice to make.
    public var offersReconnect: Bool {
        switch phase {
        case .phoneOnUSB, .chooseScreen, .waitingForRemembered, .screenFound, .accessDenied: return true
        default: return false
        }
    }
    /// The phone is not on the stage and the reason may be outside Workbench, so
    /// the surface offers "Can't see your phone?".
    public var offersHelp: Bool {
        switch phase {
        case .live, .connecting, .available, .screenFound, .accessPending, .released, .ended: return false
        default: return true
        }
    }
    /// Checking in QuickTime Player is worth suggesting only while the picture is missing for a
    /// reason the Mac itself might explain. Not when another app already holds the screen, the
    /// screen is offered, the permission is Workbench's own, or Workbench let go on purpose.
    /// What QuickTime shows is another observation, never proof of a cause.
    public var suggestsQuickTimeCheck: Bool {
        switch phase {
        case .noPhone, .usbUnavailable, .phoneOnUSB, .waitingForRemembered, .stalled, .interrupted, .couldNotOpen, .couldNotStart: return true
        default: return false
        }
    }
    public var symbol: String {
        switch phase {
        case .live: return "iphone"
        case .connecting, .available, .accessPending: return "iphone.radiowaves.left.and.right"
        case .accessDenied, .accessRestricted: return "video.slash"
        case .noPhone: return "cable.connector.slash"
        default: return "cable.connector"
        }
    }
}

public enum PhoneLink {
    /// One pure decision from the signals. Priority: a running session's own
    /// phase, then permission, then what is available and what was remembered.
    public static func status(_ signals: PhoneLinkSignals) -> PhoneLinkStatus {
        let sources = signals.sources
        // Only phone and tablet screens count as screens; a display camera, Camo or a capture
        // card beside them never turns the one phone into a choice.
        let screens = sources.filter(\.isScreen)
        let remembered = signals.rememberedID.flatMap { id in sources.first { $0.id == id } }
        let active = signals.phase.deviceID.flatMap { id in sources.first { $0.id == id } }
        let lone = screens.count == 1 ? screens[0] : (sources.count == 1 ? sources[0] : nil)
        let noun = Self.noun(for: active ?? remembered ?? lone, usb: signals.usb)
        let Noun = Self.capitalised(noun)
        switch signals.phase {
        case .live:
            return .init(phase: .live, title: "Showing \(noun)", detail: "Use the phone itself for taps, typing and its own voice features.", step: nil)
        case .connecting:
            return .init(phase: .connecting, title: "Connecting to \(noun)…", detail: nil, step: nil)
        case .stalled:
            return .init(phase: .stalled, title: "\(Noun) stopped sending its picture",
                         detail: "Unlock it or reseat the cable, then Reconnect.", step: .reconnect)
        case .interrupted:
            return .init(phase: .interrupted, title: "\(Noun) disconnected",
                         detail: "Reconnect the cable and unlock it. The stage waits here.", step: .reconnect)
        case .failed(_, .busy, _):
            // Only here has macOS said another app holds the device, so only here is QuickTime named.
            return .init(phase: .busy, title: "Another app is using the \(noun)’s screen",
                         detail: "Close QuickTime Player or the other preview, then Reconnect.", step: .reconnect)
        case .failed(_, .couldNotOpen, _):
            return .init(phase: .couldNotOpen, title: "Workbench can’t open the \(noun)",
                         detail: "Unlock it, then Reconnect. Copy connection details records what macOS answered.", step: .reconnect)
        case .failed(_, .couldNotStart, _):
            return .init(phase: .couldNotStart, title: "The \(noun)’s screen didn’t start",
                         detail: "Unlock the phone, then Reconnect.", step: .reconnect)
        case .waitingForAccess:
            return .init(phase: .accessPending, title: "Allow device video in the macOS prompt",
                         detail: "Workbench shows the phone’s picture only. It never opens the phone’s microphone.", step: nil)
        case .idle:
            break
        }
        switch signals.released {
        case .forAnotherApp:
            return .init(phase: .released, title: "Let go for another app",
                         detail: "Workbench released the \(noun) so QuickTime Player or iPhone Mirroring could use it. Reconnect to show it here again.",
                         step: .reconnect)
        case .ended:
            return .init(phase: .ended, title: "Presentation ended",
                         detail: "Workbench let go of the \(noun). Reconnect to show it here again, or press Present.", step: .reconnect)
        case nil:
            break
        }
        switch signals.access {
        case .restricted:
            return .init(phase: .accessRestricted, title: "Device video is restricted on this Mac",
                         detail: "Use a route your organisation allows, or ask IT.", step: nil)
        case .denied:
            return .init(phase: .accessDenied, title: "Workbench can’t use device video",
                         detail: "Allow Workbench under System Settings › Privacy & Security › Camera, then come back to Present.", step: .openCameraSettings)
        case .notDetermined, .authorized:
            break
        }
        if let remembered {
            // The capture reconnects a remembered screen by itself; idle between attempts reads as
            // connecting. With no session allowed, the screen is simply there for Present.
            if signals.capturing { return .init(phase: .connecting, title: "Connecting to \(noun)…", detail: nil, step: nil) }
            return .init(phase: .available, title: "\(Noun) ready", detail: "Present shows \(remembered.name).", step: nil)
        }
        if sources.isEmpty {
            if case .failed = signals.usbProbe {
                // A failed look at the bus says nothing about whether a phone is there.
                return .init(phase: .usbUnavailable, title: "Workbench couldn’t check USB",
                             detail: "macOS didn’t answer the USB check. If the phone is plugged in, unlock it and trust this Mac; its screen can still appear here.", step: nil)
            }
            if let phone = signals.usb.first {
                return .init(phase: .phoneOnUSB, title: "\(phone.noun) connected, screen not available yet",
                             detail: "Unlock it and tap Trust on the phone. If this Mac asked to allow the accessory, allow it.", step: nil)
            }
            return .init(phase: .noPhone, title: "No phone on USB",
                         detail: "Connect with a data cable, unlock the phone and trust this Mac. If this Mac asks to allow the accessory, allow it.", step: nil)
        }
        if signals.rememberedID != nil {
            // The remembered device is away; its kind comes from the bus, never from the other screen.
            let remembered = Self.noun(for: nil, usb: signals.usb)
            let detail = sources.count == 1
                ? "Reconnect it, or show \(sources[0].name) instead."
                : "Reconnect it, or choose another screen."
            return .init(phase: .waitingForRemembered, title: "Waiting for your remembered \(remembered)", detail: detail, step: .chooseSource)
        }
        if screens.count == 1 {
            // The one phone screen is adopted by the capture itself, whatever cameras are also here.
            if signals.capturing { return .init(phase: .connecting, title: "Connecting to \(noun)…", detail: nil, step: nil) }
            return .init(phase: .available, title: "\(Noun) ready", detail: "Present shows \(screens[0].name).", step: nil)
        }
        if screens.isEmpty {
            // Plain video devices only: one is offered with a click, several wait for a choice.
            if sources.count == 1 {
                return .init(phase: .screenFound, title: "\(sources[0].name) found",
                             detail: "Show it, and Workbench remembers it. Only phone and tablet screens appear by themselves.",
                             step: .showSource(id: sources[0].id, title: "Show \(sources[0].name)"))
            }
            return .init(phase: .chooseScreen, title: "\(sources.count) video sources available",
                         detail: "None of them is a phone screen. Choose which one to show.", step: .chooseSource)
        }
        return .init(phase: .chooseScreen, title: "\(screens.count) screens available",
                     detail: "Choose which one to show.", step: .chooseSource)
    }

    /// "iPhone" keeps its case; "phone" and "device" start a title with a capital.
    static func capitalised(_ noun: String) -> String {
        noun.hasPrefix("i") ? noun : noun.prefix(1).uppercased() + noun.dropFirst()
    }
    /// A short noun for the words: the kind of device when it is known, never a serial. For a
    /// screen the USB bus names the model, so it comes first; the person's own device name
    /// ("Ethan’s iPad") is only a fallback when the bus is empty or holds several kinds.
    static func noun(for source: PhoneLinkSignals.ScreenSource?, usb: [PhoneLinkSignals.USBDevice]) -> String {
        if let source {
            if source.isScreen, Set(usb.map(\.kind)).count == 1, let device = usb.first { return device.noun }
            for candidate in ["iPhone", "iPad", "iPod touch"] where source.name.localizedCaseInsensitiveContains(candidate) { return candidate }
            return source.isScreen ? "phone" : "device"
        }
        return usb.first?.noun ?? "phone"
    }

    /// The words for anything another person may see, the stage shared in a call and a
    /// report: the status of the same facts with device names replaced by their kinds
    /// (`PhoneLinkSignals.anonymised`).
    public static func sharedStatus(_ signals: PhoneLinkSignals) -> PhoneLinkStatus { status(signals.anonymised) }

    /// Facts for a report, with no serial number, device identifier or personal device
    /// name. The same text backs Copy connection details and the `--phone-link` receipt.
    public static func diagnostic(_ signals: PhoneLinkSignals, build: String) -> String {
        let signals = signals.anonymised
        let status = Self.status(signals)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines = ["Workbench \(build) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"]
        let usb: String
        switch signals.usbProbe {
        case .notChecked: usb = "not checked"
        case .failed(let code): usb = String(format: "check failed (IOKit 0x%08X)", UInt32(bitPattern: code))
        case .checked:
            usb = signals.usb.isEmpty ? "no iPhone or iPad on the bus"
                : signals.usb.map { String(format: "%@ (product 0x%04X)", $0.noun, $0.productID) }.joined(separator: ", ")
        }
        lines.append("USB: " + usb)
        lines.append("Screen sources: " + (signals.sources.isEmpty ? "none"
            : signals.sources.map { $0.name + ($0.isScreen ? " (screen)" : " (video)") }.joined(separator: ", ")))
        let remembered: String
        if let id = signals.rememberedID { remembered = signals.sources.contains { $0.id == id } ? "present" : "absent" } else { remembered = "none" }
        lines.append("Remembered device: " + remembered)
        let access: String
        switch signals.access {
        case .authorized: access = "authorized"
        case .notDetermined: access = "not asked yet"
        case .denied: access = "denied"
        case .restricted: access = "restricted by policy"
        }
        lines.append("Device video access: " + access)
        var phase: String
        switch signals.phase {
        case .idle:
            switch signals.released {
            case .forAnotherApp: phase = "released for another app"
            case .ended: phase = "released when the presentation ended"
            case nil: phase = "no session"
            }
        case .waitingForAccess: phase = "waiting for the permission prompt"
        case .connecting: phase = "connecting"
        case .live(_, let size): phase = "live \(Int(size.width))×\(Int(size.height))"
        case .stalled: phase = "stalled, no frame for 5 s after frames had flowed (the first frame gets 15 s)"
        case .interrupted: phase = "interrupted"
        case .failed(_, .busy, _): phase = "device in use by another app"
        case .failed(_, .couldNotOpen, _): phase = "could not open the device"
        case .failed(_, .couldNotStart, _): phase = "the session did not start"
        }
        if let fault = signals.phase.fault { phase += " (\(fault.text))" }
        lines.append("Session: " + phase)
        lines.append("Status: " + status.title + (status.detail.map { " — " + $0 } ?? ""))
        return lines.joined(separator: "\n")
    }
}

// MARK: - USB bus

/// One look at the USB bus: the Apple phones and tablets on it, or the IOKit result
/// code of a look that failed. A failure is never reported as an empty bus.
typealias USBProbeResult = Result<[PhoneLinkSignals.USBDevice], USBProbeFailure>
struct USBProbeFailure: Error, Equatable { let code: kern_return_t }

/// What the monitor needs from the bus watch, so a check can drive the monitor's own
/// callback with a failed or late look instead of the Mac's IOKit.
protocol USBWatching: AnyObject {
    /// Called on any queue with each look at the bus.
    var onChange: ((USBProbeResult) -> Void)? { get set }
    func start()
    func stop()
}

/// Apple phones and tablets on the USB bus, from IOKit, with no permission and
/// no pairing. Presence here without a screen source means the phone is attached
/// but not yet unlocked, trusted or allowed as an accessory.
final class USBPhoneWatch: USBWatching {
    private static let appleVendor = 0x05AC
    /// IOKit's generic error, for a step that failed without returning its own code.
    private static let genericFailure = kern_return_t(bitPattern: 0xE00002BC)
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private let queue = DispatchQueue(label: "Workbench.phone-link.usb", qos: .utility)
    /// Called on the watch's own queue with each look at the bus.
    var onChange: ((USBProbeResult) -> Void)?

    func start() {
        guard port == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            queue.async { [weak self] in self?.onChange?(.failure(.init(code: Self.genericFailure))) }
            return
        }
        self.port = port
        // Registered on the queue so an ordinary caller never races a stop in flight.
        IONotificationPortSetDispatchQueue(port, queue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watch = Unmanaged<USBPhoneWatch>.fromOpaque(refcon).takeUnretainedValue()
            watch.drain(iterator)
            watch.publish(nil)
        }
        // A watch that could not register cannot see changes: the look is reported as failed.
        var failure: kern_return_t?
        for kind in [kIOMatchedNotification, kIOTerminatedNotification] {
            guard let matching = Self.matching() else { failure = Self.genericFailure; continue }
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(port, kind, matching, callback, refcon, &iterator)
            if result == KERN_SUCCESS { drain(iterator); iterators.append(iterator) } else { failure = result }
        }
        queue.async { [weak self] in self?.publish(failure) }
    }
    /// Synchronous on the watch's own queue, where its callbacks run, so no callback
    /// can run after this returns and the unretained reference they carry is safe.
    func stop() {
        queue.sync {
            iterators.forEach { IOObjectRelease($0) }; iterators.removeAll()
            if let port { IONotificationPortDestroy(port) }
            port = nil
        }
    }
    deinit { stop() }

    /// Every USB device: the USB family accepts only its own key combinations in a
    /// matching dictionary (a vendor alone matches nothing), so the Apple filter is
    /// applied in `classify`, not here. Found on 6 October 2026 with a real iPhone.
    private static func matching() -> CFMutableDictionary? {
        IOServiceMatching("IOUSBHostDevice")
    }
    private func drain(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 { IOObjectRelease(service); service = IOIteratorNext(iterator) }
    }
    private func publish(_ failure: kern_return_t?) {
        if let failure { onChange?(.failure(.init(code: failure))) } else { onChange?(Self.snapshot()) }
    }

    /// Every Apple phone or tablet currently on the bus, or why the bus could not be read.
    static func snapshot() -> USBProbeResult {
        guard let matching = matching() else { return .failure(.init(code: genericFailure)) }
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else { return .failure(.init(code: result)) }
        defer { IOObjectRelease(iterator) }
        var devices: [PhoneLinkSignals.USBDevice] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            let name = property("USB Product Name") as? String ?? ""
            let vendor = (property("idVendor") as? NSNumber)?.intValue ?? 0
            let product = (property("idProduct") as? NSNumber)?.intValue ?? 0
            if let device = classify(name: name, vendor: vendor, product: product) { devices.append(device) }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return .success(devices)
    }

    /// Apple's own product identifiers first, then the product name. Keyboards,
    /// mice and hubs carry the same vendor and are not phones.
    static func classify(name: String, vendor: Int, product: Int) -> PhoneLinkSignals.USBDevice? {
        guard vendor == appleVendor else { return nil }
        let kind: PhoneLinkSignals.USBDevice.Kind?
        switch product {
        case 0x12A8: kind = .iPhone
        case 0x12AB: kind = .iPad
        case 0x12AA: kind = .iPod
        default:
            if name.hasPrefix("iPhone") { kind = .iPhone }
            else if name.hasPrefix("iPad") { kind = .iPad }
            else if name.hasPrefix("iPod") { kind = .iPod }
            else { kind = nil }
        }
        guard let kind else { return nil }
        return .init(name: name.isEmpty ? kind.noun : name, kind: kind, productID: product)
    }
}

private extension PhoneLinkSignals.USBDevice.Kind {
    var noun: String { PhoneLinkSignals.USBDevice(name: "", kind: self, productID: 0).noun }
}

// MARK: - Monitor

/// The live owner of the phone's state. It mirrors the one capture's sources,
/// choice and phase, watches the USB bus and the permission while Present is in
/// use, and publishes one status for every surface. It starts no capture and
/// never asks for a permission itself.
@MainActor
public final class PhoneLinkMonitor: ObservableObject {
    @Published public private(set) var signals = PhoneLinkSignals()
    @Published public private(set) var status = PhoneLink.status(PhoneLinkSignals())
    /// Fixed signals for an offscreen render; nil follows the Mac.
    public var fixture: PhoneLinkSignals? { didSet { if let fixture { apply(fixture) } else { apply(mirrored); refresh() } } }
    private let usb: USBWatching
    private var captureObservations = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var wakeObserver: NSObjectProtocol?
    private var running = false
    private var mirrored = PhoneLinkSignals()

    public convenience init() { self.init(usb: USBPhoneWatch()) }
    init(usb: USBWatching) {
        self.usb = usb
        usb.onChange = { [weak self] result in
            DispatchQueue.main.async { self?.receiveUSB(result) }
        }
    }
    /// A look at the bus, on main. One that lands after the watch stopped is dropped, so
    /// a stale look cannot bring back devices or a failure while Present is not in use.
    func receiveUSB(_ result: USBProbeResult) {
        guard running else { return }
        // A first look that finds the phone is not a new connection; one after an empty look is.
        let wasEmpty = mirrored.usbProbe == .checked && mirrored.usb.isEmpty
        update {
            switch result {
            case .success(let devices): $0.usb = devices; $0.usbProbe = .checked
            case .failure(let failure): $0.usb = []; $0.usbProbe = .failed(failure.code)
            }
        }
        if wasEmpty, case .success(let devices) = result, !devices.isEmpty { onNewConnection?() }
    }
    /// Mirror the capture's own facts: the sources it sees, the device it remembers
    /// and the phase of its session. The capture may be stopped; its facts still hold.
    func mirror(_ capture: DemoCapture) {
        captureObservations.removeAll()
        capture.$phase.receive(on: RunLoop.main).sink { [weak self] phase in
            // A phase change is the moment the permission may have changed too.
            self?.update { $0.phase = phase; if self?.running == true { $0.access = Self.access() } }
        }.store(in: &captureObservations)
        capture.$selectedID.receive(on: RunLoop.main).sink { [weak self] id in self?.update { $0.rememberedID = id } }.store(in: &captureObservations)
        capture.$sources.receive(on: RunLoop.main).sink { [weak self] sources in
            self?.update { $0.sources = sources.map { .init(id: $0.id, name: $0.name, isScreen: $0.isScreen) } }
        }.store(in: &captureObservations)
    }
    /// Present is in use (its page is on screen or a presentation runs): watch the bus
    /// and the permission so the words stay true while nothing is captured yet.
    public func setActive(_ active: Bool) {
        if active && !running { start() } else if !active && running { stop() }
    }
    public func refresh() {
        guard running, fixture == nil else { return }
        update { $0.access = Self.access() }
    }
    /// The capture was let go (the presentation ended, or an Apple app needed it), or taken back.
    func setReleased(_ released: PhoneLinkSignals.Release?) { update { $0.released = released } }
    /// A session is allowed to run now, so an available screen reads as connecting.
    func setCapturing(_ capturing: Bool) { update { $0.capturing = capturing } }
    private func start() {
        running = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        usb.start()
        refresh()
    }
    private func stop() {
        running = false
        usb.stop()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver); self.wakeObserver = nil }
        update { $0.usb = []; $0.usbProbe = .notChecked }
    }
    private func update(_ change: (inout PhoneLinkSignals) -> Void) {
        change(&mirrored)
        if fixture == nil { apply(mirrored) }
    }
    private func apply(_ next: PhoneLinkSignals) {
        guard next != signals else { return }
        signals = next
        status = PhoneLink.status(next)
    }

    static func access() -> PhoneLinkSignals.VideoAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .notDetermined
        }
    }

    /// Facts for a report, with no identifiers or personal device names.
    public func diagnostic(build: String) -> String { PhoneLink.diagnostic(signals, build: build) }
    /// The words for the stage shared in a call and for a report: device names replaced by their kinds.
    public var sharedStatus: PhoneLinkStatus { PhoneLink.sharedStatus(signals) }
    /// The phone was plugged in again after the bus was seen without it, which counts as a
    /// deliberate action (Present's owner takes the phone back after End).
    var onNewConnection: (() -> Void)?

    /// Like `observe`, but also runs the one capture session headless, so a Mac can
    /// prove that frames arrive, and at what size, without opening a window. The
    /// session uses a temporary root, so what it adopts never reaches the person's
    /// scenes; macOS asks for camera access on first use, as the page would.
    public static func observeLive(seconds: TimeInterval, build: String, onChange: @escaping (String) -> Void) async -> (signals: PhoneLinkSignals, status: PhoneLinkStatus, report: String, firstFrame: TimeInterval?, size: CGSize) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-phone-link-live-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = DemoCapture(root: root)
        let monitor = PhoneLinkMonitor()
        monitor.mirror(capture)
        monitor.setCapturing(true)
        var last: PhoneLinkStatus?
        // The receipt keeps the report's words, so no personal device name reaches it.
        let subscription = monitor.$signals.map(PhoneLink.sharedStatus).sink { status in
            guard status != last else { return }
            last = status; onChange(status.title + (status.detail.map { " — " + $0 } ?? ""))
        }
        monitor.setActive(true)
        let started = Date()
        capture.start()
        let deadline = started.addingTimeInterval(seconds)
        var firstFrame: TimeInterval?
        var size = CGSize.zero
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            monitor.refresh()
            if case .live(_, let dimensions) = capture.phase {
                if firstFrame == nil { firstFrame = Date().timeIntervalSince(started) }
                size = dimensions
            }
        }
        subscription.cancel()
        let frames = firstFrame.map { String(format: "Frames: first after %.1f s, %d×%d", $0, Int(size.width), Int(size.height)) }
            ?? "Frames: none within \(Int(seconds)) s"
        let final = (signals: monitor.signals, status: monitor.sharedStatus, report: monitor.diagnostic(build: build) + "\n" + frames, firstFrame: firstFrame, size: size)
        monitor.setActive(false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in capture.stop { continuation.resume() } }
        return final
    }

    /// Runs the bus watch and the source discovery headless for a while and reports
    /// what the Mac showed, for a receipt from a Mac where the phone never appeared.
    /// It starts no capture session and asks for no permission.
    public static func observe(seconds: TimeInterval, build: String, onChange: @escaping (String) -> Void) async -> (signals: PhoneLinkSignals, status: PhoneLinkStatus, report: String) {
        DemoCapture.allowScreenCaptureDevices()
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: nil, position: .unspecified)
        let monitor = PhoneLinkMonitor()
        // The device this edition's Present remembers, read only, so the receipt says present or absent.
        let preference = Workbench.supportDirectory(component: "StageMark").appendingPathComponent("Scenes/demo-source.json")
        if let data = try? Data(contentsOf: preference), let id = try? JSONDecoder().decode(String.self, from: data) {
            monitor.update { $0.rememberedID = id }
        }
        var last: PhoneLinkStatus?
        let subscription = monitor.$signals.map(PhoneLink.sharedStatus).sink { status in
            guard status != last else { return }
            last = status; onChange(status.title + (status.detail.map { " — " + $0 } ?? ""))
        }
        monitor.setActive(true)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let sources = discovery.devices
                .filter { !$0.isContinuityCamera && ($0.hasMediaType(.video) || $0.hasMediaType(.muxed)) }
                .map { PhoneLinkSignals.ScreenSource(id: $0.uniqueID, name: $0.localizedName, isScreen: $0.hasMediaType(.muxed)) }
                .sorted { $0.name < $1.name }
            monitor.update { $0.sources = sources }
            monitor.refresh()
        }
        subscription.cancel()
        // Read everything before stopping: stopping the bus watch clears its devices.
        let final = (signals: monitor.signals, status: monitor.sharedStatus, report: monitor.diagnostic(build: build))
        monitor.setActive(false)
        return final
    }
}
