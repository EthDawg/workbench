import AppKit
import AVFoundation
import CoreMediaIO

struct DemoSource: Identifiable, Equatable {
    let id: String
    let name: String
    /// A muxed-media display hint only; never evidence of phone identity.
    let isScreen: Bool
}

/// Never silently switch to another device after a disconnect.
struct CaptureRecovery {
    var desiredID: String?
    var generation = 0
    mutating func select(_ id: String?) -> Int { desiredID = id; invalidateSession(); return generation }
    mutating func invalidateSession() { generation += 1 }
    func accepts(_ token: Int, source: String) -> Bool { token == generation && source == desiredID }
    func candidate(in sources: [DemoSource]) -> String? {
        if let desiredID { return sources.contains { $0.id == desiredID } ? desiredID : nil }
        // Nothing chosen yet: the one phone or tablet screen on the Mac is shown and
        // remembered, so a plugged-in phone appears without a hunt for a Source menu.
        // A plain video device (a capture card, a camera) still needs a choice, and
        // two screens always do. Losing the remembered device never opens another.
        let screens = sources.filter(\.isScreen)
        return sources.count == 1 && screens.count == 1 ? screens[0].id : nil
    }
}

/// Local, video-only preview. No recording output, microphone, network or
/// third-party window control. All capture work runs off the main thread.
/// The words for each phase live in `PhoneLink.status`; this class publishes
/// only what it knows: the sources, the choice and the session's phase.
final class DemoCapture: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var sources: [DemoSource] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var phase = CapturePhase.idle
    @Published private(set) var live = false
    /// The device this capture currently holds, so another camera owner can keep
    /// clear of it instead of taking it away. nil whenever no session is open.
    @Published private(set) var heldDeviceID: String?
    @Published private(set) var dimensions = CGSize.zero
    /// Every surface showing this session draws through its own layer: the Present
    /// page's preview and the stage. Newest first, so a stage opened later is wired
    /// before the preview behind it; if macOS refuses a second connection, the surface
    /// in front keeps the picture. Touched only on the capture queue.
    private final class LayerSlot { weak var layer: AVCaptureVideoPreviewLayer?; init(_ layer: AVCaptureVideoPreviewLayer) { self.layer = layer } }
    private var layers: [LayerSlot] = []
    private let queue = DispatchQueue(label: "StageMark.device-preview", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var recovery = CaptureRecovery()
    private var activeID: String?
    private var activeToken = 0
    private var devices: [String: AVCaptureDevice] = [:]
    private var discovery: AVCaptureDevice.DiscoverySession?
    private var discoveryObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var wakeObserver: NSObjectProtocol?
    private var timer: DispatchSourceTimer?
    private var lastFrame = Date.distantPast
    private var lastPublish = Date.distantPast
    private var startedAt = Date.distantPast
    private var enabled = false
    private var retryAfter = Date.distantPast
    private var retryDelay: TimeInterval = 2
    private var waitingForPermission = false
    private let preference: URL
    private let deliveryLock = NSLock()
    private var pendingDelivery = false
    private var deliveryToken = -1

    init(root: URL) {
        preference = root.appendingPathComponent("demo-source.json")
        super.init()
        if let data = try? Data(contentsOf: preference), let id = try? JSONDecoder().decode(String.self, from: data) {
            recovery.desiredID = id; selectedID = id
        }
    }
    /// A layer for one surface. It shows the running session at once and every
    /// later one; a surface that goes away releases it.
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer()
        layer.videoGravity = .resizeAspect; layer.masksToBounds = true
        queue.async { [weak self] in
            guard let self else { return }
            layers.removeAll { $0.layer == nil }
            layers.insert(LayerSlot(layer), at: 0)
            guard let session, let port = session.inputs.first?.ports.first(where: { $0.mediaType == .video }) else { return }
            session.beginConfiguration()
            attach(layer, to: session, port: port)
            session.commitConfiguration()
        }
        return layer
    }
    /// On the capture queue. A layer already on this session is left alone.
    private func attach(_ layer: AVCaptureVideoPreviewLayer, to session: AVCaptureSession, port: AVCaptureInput.Port) {
        guard layer.session !== session else { return }
        layer.setSessionWithNoConnection(session)
        let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
        }
        if session.canAddConnection(connection) { session.addConnection(connection) } else { layer.session = nil }
    }
    /// Lets this process see iPhone and iPad screens as capture devices. Process-wide
    /// and idempotent; it requests no permission.
    static func allowScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        _ = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout.size(ofValue: allow)), &allow)
    }
    func start() {
        queue.async { [weak self] in
            guard let self, !enabled else { return }; enabled = true
            Self.allowScreenCaptureDevices()
            discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: nil, position: .unspecified)
            discoveryObservation = discovery?.observe(\.devices, options: [.new]) { [weak self] _, _ in self?.refresh() }
            let center = NotificationCenter.default
            for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.refresh() })
            }
            observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: nil) { [weak self] notification in
                guard let failed = notification.object as? AVCaptureSession else { return }
                self?.queue.async { [weak self] in
                    guard let self, enabled, session === failed else { return }
                    let id = activeID
                    stopSession(); publish(id.map { .interrupted($0) } ?? .idle)
                    discover()
                }
            })
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in self?.reconnect() }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in self?.checkHealth() }
            self.timer = timer; timer.resume()
            discover()
        }
    }
    func refresh() { queue.async { [weak self] in self?.discover() } }
    func select(_ id: String) {
        queue.async { [weak self] in
            guard let self, enabled else { return }
            retryAfter = .distantPast; retryDelay = 2
            remember(id)
            stopSession(); connect(id)
        }
    }
    private func remember(_ id: String) {
        _ = recovery.select(id)
        try? JSONEncoder().encode(id).write(to: preference, options: .atomic)
        DispatchQueue.main.async { [weak self] in self?.selectedID = id }
    }
    func reconnect() {
        queue.async { [weak self] in
            guard let self, enabled else { return }
            retryAfter = .distantPast; retryDelay = 2
            _ = recovery.select(recovery.desiredID); stopSession(); discover()
        }
    }
    /// Completion runs on main only after this capture queue has released its
    /// session and recovery observers. A native fallback must wait for it.
    func stop(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            // The remembered device survives a stop: the page and the stage share one capture
            // that starts again when either needs it.
            enabled = false; recovery.invalidateSession(); stopSession(); publish(.idle)
            devices.removeAll()
            DispatchQueue.main.async { [weak self] in self?.sources = [] }
            timer?.cancel(); timer = nil
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
            if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver); self.wakeObserver = nil }
            discoveryObservation = nil; discovery = nil
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }
    private func publish(_ phase: CapturePhase) {
        lastPublished = phase
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.phase = phase
            if case .live = phase {} else { live = false }
        }
    }
    private func discover() {
        guard enabled else { return }
        let found = (discovery?.devices ?? []).filter { !$0.isContinuityCamera && ($0.hasMediaType(.video) || $0.hasMediaType(.muxed)) }
        devices = Dictionary(found.map { ($0.uniqueID, $0) }, uniquingKeysWith: { first, _ in first })
        let choices = found.map { DemoSource(id: $0.uniqueID, name: $0.localizedName, isScreen: $0.hasMediaType(.muxed)) }.sorted { $0.name < $1.name }
        DispatchQueue.main.async { [weak self] in self?.sources = choices }
        if let activeID, devices[activeID] == nil {
            stopSession(); publish(.interrupted(activeID))
        }
        guard activeID == nil, Date() >= retryAfter else { return }
        if let candidate = recovery.candidate(in: choices) {
            if recovery.desiredID == nil { remember(candidate) }
            connect(candidate)
        } else if case .interrupted = phaseSnapshot, choices.isEmpty {
            // The remembered device is away and nothing else is offered: keep waiting for that exact device.
        } else {
            // Idle lets the words offer the other screens that are here, or say what is missing.
            publish(.idle)
        }
    }
    /// The last phase this queue published, read here without a hop to main.
    private var lastPublished = CapturePhase.idle
    private var phaseSnapshot: CapturePhase { lastPublished }
    private func connect(_ id: String) {
        guard enabled, activeID == nil, let device = devices[id], !waitingForPermission else { return }
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        switch authorization {
        case .notDetermined:
            waitingForPermission = true
            publish(.waitingForAccess)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self else { return }; waitingForPermission = false; discover()
                }
            }
            return
        case .denied, .restricted:
            // PhoneLink reads the permission itself and says what to do.
            publish(.idle)
            return
        default: break
        }
        retryAfter = Date().addingTimeInterval(retryDelay); retryDelay = min(30, retryDelay * 2)
        publish(.connecting(id))
        do {
            let input = try AVCaptureDeviceInput(device: device)
            let newSession = AVCaptureSession()
            newSession.beginConfiguration()
            guard newSession.canAddInput(input) else { throw CaptureError.unavailable }
            for port in input.ports where port.mediaType == .audio { port.isEnabled = false }
            newSession.addInputWithNoConnections(input)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: queue)
            guard newSession.canAddOutput(output) else { throw CaptureError.unavailable }
            newSession.addOutputWithNoConnections(output)
            let ports = input.ports.filter { $0.mediaType == .video }
            guard !ports.isEmpty else { throw CaptureError.unavailable }
            let videoConnection = AVCaptureConnection(inputPorts: ports, output: output)
            guard newSession.canAddConnection(videoConnection) else { throw CaptureError.unavailable }
            newSession.addConnection(videoConnection)
            layers.removeAll { $0.layer == nil }
            for slot in layers { if let layer = slot.layer { attach(layer, to: newSession, port: ports[0]) } }
            newSession.commitConfiguration()
            // Explicit video-only wiring avoids connecting a muxed device
            // microphone as an accidental side effect of auto-connection.
            session = newSession; activeID = id; activeToken = recovery.generation
            DispatchQueue.main.async { [weak self] in self?.heldDeviceID = id }
            deliveryLock.lock(); deliveryToken = activeToken; deliveryLock.unlock()
            lastFrame = .distantPast; startedAt = Date()
            newSession.startRunning()
            if !newSession.isRunning { stopSession(); publish(.failed(id, .couldNotStart)) }
        } catch let error as AVError where error.code == .deviceInUseByAnotherApplication {
            stopSession(); publish(.failed(id, .busy))
        } catch { stopSession(); publish(.failed(id, .couldNotOpen)) }
    }
    private func stopSession() {
        // Automatic error/disconnect recovery can reopen the same device without
        // another selection. Its new session must never reuse an old frame token.
        recovery.invalidateSession()
        deliveryLock.lock(); deliveryToken = -1; deliveryLock.unlock()
        session?.stopRunning(); layers.forEach { $0.layer?.session = nil }; session = nil; activeID = nil
        DispatchQueue.main.async { [weak self] in self?.live = false; self?.dimensions = .zero; self?.heldDeviceID = nil }
    }
    private func checkHealth() {
        guard enabled else { return }
        guard let activeID else { discover(); return }
        if devices[activeID]?.isConnected != true { stopSession(); discover(); return }
        if Date().timeIntervalSince(max(lastFrame, startedAt)) > 5 {
            publish(.stalled(activeID))
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard enabled, let id = activeID, recovery.accepts(activeToken, source: id),
              session?.outputs.contains(where: { $0 === output }) == true else { return }
        lastFrame = Date(); retryDelay = 2
        guard lastFrame.timeIntervalSince(lastPublish) >= 0.2,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let size = CMVideoFormatDescriptionGetDimensions(description)
        deliveryLock.lock()
        if pendingDelivery { deliveryLock.unlock(); return }
        pendingDelivery = true; deliveryLock.unlock()
        lastPublish = lastFrame
        let token = activeToken
        let nextSize = CGSize(width: Int(size.width), height: Int(size.height))
        lastPublished = .live(id, nextSize)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { deliveryLock.lock(); pendingDelivery = false; deliveryLock.unlock() }
            // Stop/selection updates are queued before subsequent frames. The
            // selected identity also gates any already-enqueued old frame.
            deliveryLock.lock(); let valid = deliveryToken == token; deliveryLock.unlock()
            guard valid, selectedID == id else { return }
            if dimensions != nextSize { dimensions = nextSize }
            if !live || phase != .live(id, nextSize) { live = true; phase = .live(id, nextSize) }
        }
    }
    private enum CaptureError: Error { case unavailable }
}
