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
    public var usb: [USBDevice] = []
    public var sources: [ScreenSource] = []
    /// The exact device a previous choice saved. Reconnects only ever reopen this one.
    public var rememberedID: String?
    public var access: VideoAccess = .notDetermined
    public var phase: CapturePhase = .idle
    /// Workbench let go of the phone so an Apple app could use it, and stays out of
    /// the way until the person asks for it back.
    public var released = false
    public init() {}
}

/// The capture session's own phase, published by `DemoCapture`. Words live in
/// `PhoneLink.status`, not here.
public enum CapturePhase: Equatable {
    public enum Failure: Equatable { case busy, couldNotOpen }
    case idle
    case waitingForAccess
    case connecting(String)
    case live(String, CGSize)
    case stalled(String)
    case interrupted(String)
    case failed(String, Failure)
    var deviceID: String? {
        switch self {
        case .idle, .waitingForAccess: return nil
        case .connecting(let id), .stalled(let id), .interrupted(let id): return id
        case .live(let id, _): return id
        case .failed(let id, _): return id
        }
    }
}

public struct PhoneLinkStatus: Equatable {
    public enum Phase: Equatable {
        case noPhone, phoneOnUSB, screenFound, chooseScreen, waitingForRemembered, connecting, live, stalled,
             interrupted, busy, couldNotOpen, accessPending, accessDenied, accessRestricted, released
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
        case .phoneOnUSB, .chooseScreen, .waitingForRemembered, .screenFound: return true
        default: return false
        }
    }
    /// The phone is not on the stage and the reason may be outside Workbench, so
    /// the surface offers "Can't see your phone?".
    public var offersHelp: Bool {
        switch phase {
        case .live, .connecting, .screenFound, .accessPending, .released: return false
        default: return true
        }
    }
    public var symbol: String {
        switch phase {
        case .live: return "iphone"
        case .connecting, .accessPending: return "iphone.radiowaves.left.and.right"
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
        let remembered = signals.rememberedID.flatMap { id in sources.first { $0.id == id } }
        let active = signals.phase.deviceID.flatMap { id in sources.first { $0.id == id } }
        let noun = Self.noun(for: active ?? remembered ?? (sources.count == 1 ? sources[0] : nil), usb: signals.usb)
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
        case .failed(_, .busy):
            return .init(phase: .busy, title: "Another app is using the \(noun)’s screen",
                         detail: "Close QuickTime Player or the other preview, then Reconnect.", step: .reconnect)
        case .failed(_, .couldNotOpen):
            return .init(phase: .couldNotOpen, title: "Workbench can’t open the \(noun)",
                         detail: "Unlock it and close any other preview using it, then Reconnect.", step: .reconnect)
        case .waitingForAccess:
            return .init(phase: .accessPending, title: "Allow device video in the macOS prompt",
                         detail: "Workbench shows the phone’s picture only. It never opens the phone’s microphone.", step: nil)
        case .idle:
            break
        }
        if signals.released {
            return .init(phase: .released, title: "Let go for another app",
                         detail: "Workbench released the \(noun) so QuickTime Player or iPhone Mirroring could use it. Reconnect to show it here again.",
                         step: .reconnect)
        }
        switch signals.access {
        case .restricted:
            return .init(phase: .accessRestricted, title: "Device video is restricted on this Mac",
                         detail: "Use a route your organisation allows, or ask IT.", step: nil)
        case .denied:
            return .init(phase: .accessDenied, title: "Workbench can’t use device video",
                         detail: "Allow Workbench under System Settings › Privacy & Security › Camera, then Reconnect.", step: .openCameraSettings)
        case .notDetermined, .authorized:
            break
        }
        if remembered != nil {
            // The capture reconnects a remembered screen by itself; idle between attempts reads as connecting.
            return .init(phase: .connecting, title: "Connecting to \(noun)…", detail: nil, step: nil)
        }
        if sources.isEmpty {
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
        if sources.count == 1 {
            // The one phone screen is adopted by the capture itself; a plain video device waits for a choice.
            if sources[0].isScreen { return .init(phase: .connecting, title: "Connecting to \(noun)…", detail: nil, step: nil) }
            return .init(phase: .screenFound, title: "\(sources[0].name) found",
                         detail: "Show it, and Workbench remembers it. Only phone and tablet screens appear by themselves.",
                         step: .showSource(id: sources[0].id, title: "Show \(sources[0].name)"))
        }
        return .init(phase: .chooseScreen, title: "\(sources.count) screens available",
                     detail: "Choose which one to show.", step: .chooseSource)
    }

    /// "iPhone" keeps its case; "phone" and "device" start a title with a capital.
    static func capitalised(_ noun: String) -> String {
        noun.hasPrefix("i") ? noun : noun.prefix(1).uppercased() + noun.dropFirst()
    }
    /// A short noun for the words: the kind of device when it is known, never a serial.
    static func noun(for source: PhoneLinkSignals.ScreenSource?, usb: [PhoneLinkSignals.USBDevice]) -> String {
        if let source {
            for candidate in ["iPhone", "iPad", "iPod touch"] where source.name.localizedCaseInsensitiveContains(candidate) { return candidate }
            if source.isScreen, let device = usb.first { return device.noun }
            return source.isScreen ? "phone" : "device"
        }
        return usb.first?.noun ?? "phone"
    }

    /// Facts for a report, with no serial number or device identifier. The same text
    /// backs Copy connection details and the `--phone-link` receipt.
    public static func diagnostic(_ signals: PhoneLinkSignals, status: PhoneLinkStatus, build: String) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines = ["Workbench \(build) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"]
        lines.append("USB: " + (signals.usb.isEmpty ? "no iPhone or iPad on the bus"
            : signals.usb.map { String(format: "%@ (product 0x%04X)", $0.name, $0.productID) }.joined(separator: ", ")))
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
        let phase: String
        switch signals.phase {
        case .idle: phase = signals.released ? "released for another app" : "no session"
        case .waitingForAccess: phase = "waiting for the permission prompt"
        case .connecting: phase = "connecting"
        case .live(_, let size): phase = "live \(Int(size.width))×\(Int(size.height))"
        case .stalled: phase = "stalled, no frames for 5 s"
        case .interrupted: phase = "interrupted"
        case .failed(_, .busy): phase = "could not start, device busy"
        case .failed(_, .couldNotOpen): phase = "could not open the device"
        }
        lines.append("Session: " + phase)
        lines.append("Status: " + status.title + (status.detail.map { " — " + $0 } ?? ""))
        return lines.joined(separator: "\n")
    }
}

// MARK: - USB bus

/// Apple phones and tablets on the USB bus, from IOKit, with no permission and
/// no pairing. Presence here without a screen source means the phone is attached
/// but not yet unlocked, trusted or allowed as an accessory.
final class USBPhoneWatch {
    private static let appleVendor = 0x05AC
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private let queue = DispatchQueue(label: "Workbench.phone-link.usb", qos: .utility)
    /// Called on the watch's own queue with the whole current list.
    var onChange: (([PhoneLinkSignals.USBDevice]) -> Void)?

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        // Registered on the queue so an ordinary caller never races a stop in flight.
        IONotificationPortSetDispatchQueue(port, queue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watch = Unmanaged<USBPhoneWatch>.fromOpaque(refcon).takeUnretainedValue()
            watch.drain(iterator)
            watch.publish()
        }
        for kind in [kIOMatchedNotification, kIOTerminatedNotification] {
            guard let matching = Self.matching() else { continue }
            var iterator: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, kind, matching, callback, refcon, &iterator) == KERN_SUCCESS {
                drain(iterator); iterators.append(iterator)
            }
        }
        queue.async { [weak self] in self?.publish() }
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

    private static func matching() -> CFMutableDictionary? {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return nil }
        (matching as NSMutableDictionary)["idVendor"] = NSNumber(value: appleVendor)
        return matching
    }
    private func drain(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 { IOObjectRelease(service); service = IOIteratorNext(iterator) }
    }
    private func publish() { onChange?(Self.snapshot()) }

    /// Every Apple phone or tablet currently on the bus.
    static func snapshot() -> [PhoneLinkSignals.USBDevice] {
        guard let matching = matching() else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
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
        return devices
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
    private let usb = USBPhoneWatch()
    private var captureObservations = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var running = false
    private var mirrored = PhoneLinkSignals()

    public init() {
        usb.onChange = { [weak self] devices in
            DispatchQueue.main.async { self?.update { $0.usb = devices } }
        }
    }
    /// Mirror the capture's own facts: the sources it sees, the device it remembers
    /// and the phase of its session. The capture may be stopped; its facts still hold.
    func mirror(_ capture: DemoCapture) {
        captureObservations.removeAll()
        capture.$phase.receive(on: RunLoop.main).sink { [weak self] phase in self?.update { $0.phase = phase } }.store(in: &captureObservations)
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
    /// The capture was let go for an Apple app, or taken back.
    func setReleased(_ released: Bool) { update { $0.released = released } }
    private func start() {
        running = true
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        usb.start()
        refresh()
    }
    private func stop() {
        running = false
        usb.stop()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        update { $0.usb = [] }
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

    /// Facts for a report, with no identifiers.
    public func diagnostic(build: String) -> String { PhoneLink.diagnostic(signals, status: status, build: build) }

    /// Runs the bus watch and the source discovery headless for a while and reports
    /// what the Mac showed, for a receipt from a Mac where the phone never appeared.
    /// It starts no capture session and asks for no permission.
    public static func observe(seconds: TimeInterval, build: String, onChange: @escaping (String) -> Void) async -> (signals: PhoneLinkSignals, status: PhoneLinkStatus, report: String) {
        DemoCapture.allowScreenCaptureDevices()
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: nil, position: .unspecified)
        let monitor = PhoneLinkMonitor()
        var last: PhoneLinkStatus?
        let subscription = monitor.$status.sink { status in
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
        let report = monitor.diagnostic(build: build)
        monitor.setActive(false)
        return (monitor.signals, monitor.status, report)
    }
}
