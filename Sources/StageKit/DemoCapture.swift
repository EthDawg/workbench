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
        // Muxed describes media, not a verified phone screen. Even a single
        // external source needs the user's first selection; reconnects retain it.
        return nil
    }
}

enum CaptureVideoAccess {
    static func unavailableMessage(for status: AVAuthorizationStatus) -> String? {
        switch status {
        case .restricted:
            return "Device video access is restricted on this Mac. Use an approved presentation route or ask your IT administrator for help."
        case .denied:
            return "Device video access is off. Enable Workbench in System Settings → Privacy & Security → Camera, then choose Reconnect."
        default: return nil
        }
    }
}

/// Local, video-only preview. No recording output, microphone, network or
/// third-party window control. All capture work runs off the main thread.
final class DemoCapture: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var sources: [DemoSource] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var message = "Connect and unlock your device."
    @Published private(set) var live = false
    @Published private(set) var dimensions = CGSize.zero
    let previewLayer = AVCaptureVideoPreviewLayer()
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
    func reportNotice(_ text: String) { message = text }
    func start() {
        queue.async { [weak self] in
            guard let self, !enabled else { return }; enabled = true
            var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var allow: UInt32 = 1
            _ = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout.size(ofValue: allow)), &allow)
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
                    stopSession(); publish("The device feed was interrupted. Reconnecting to your selected device…")
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
            _ = recovery.select(id)
            try? JSONEncoder().encode(id).write(to: preference, options: .atomic)
            DispatchQueue.main.async { [weak self] in self?.selectedID = id }
            stopSession(); connect(id)
        }
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
        // Replace the former live label during the short full-screen exit.
        publish("Ending demo…")
        queue.async { [self] in
            enabled = false; _ = recovery.select(nil); stopSession()
            timer?.cancel(); timer = nil
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
            if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver); self.wakeObserver = nil }
            discoveryObservation = nil; discovery = nil
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }
    private func publish(_ text: String, clear: Bool = true) {
        DispatchQueue.main.async { [weak self] in
            self?.message = text
            if clear { self?.live = false }
        }
    }
    private func discover() {
        guard enabled else { return }
        let found = (discovery?.devices ?? []).filter { !$0.isContinuityCamera && ($0.hasMediaType(.video) || $0.hasMediaType(.muxed)) }
        devices = Dictionary(found.map { ($0.uniqueID, $0) }, uniquingKeysWith: { first, _ in first })
        let choices = found.map { DemoSource(id: $0.uniqueID, name: $0.localizedName, isScreen: $0.hasMediaType(.muxed)) }.sorted { $0.name < $1.name }
        DispatchQueue.main.async { [weak self] in self?.sources = choices }
        if let activeID, devices[activeID] == nil {
            stopSession(); publish("Device disconnected. Reconnect and unlock it; this stage will wait here.")
        }
        guard activeID == nil, Date() >= retryAfter else { return }
        if let candidate = recovery.candidate(in: choices) {
            connect(candidate)
        } else {
            publish(recovery.desiredID == nil ? "Choose a connected device screen. For iPhone or iPad, connect by USB, unlock and trust this Mac." : "Waiting for your selected device. Reconnect it, or choose another source.")
        }
    }
    private func connect(_ id: String) {
        guard enabled, activeID == nil, let device = devices[id], !waitingForPermission else { return }
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        switch authorization {
        case .notDetermined:
            waitingForPermission = true
            publish("Allow device video access in the macOS prompt to preview your screen.")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self else { return }; waitingForPermission = false; discover()
                }
            }
            return
        case .denied, .restricted:
            publish(CaptureVideoAccess.unavailableMessage(for: authorization)
                ?? "Device video access is unavailable. Choose another approved presentation route.")
            return
        default: break
        }
        retryAfter = Date().addingTimeInterval(retryDelay); retryDelay = min(30, retryDelay * 2)
        publish("Connecting to \(device.localizedName)…")
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
            previewLayer.setSessionWithNoConnection(newSession)
            let previewConnection = AVCaptureConnection(inputPort: ports[0], videoPreviewLayer: previewLayer)
            if previewConnection.isVideoMirroringSupported {
                previewConnection.automaticallyAdjustsVideoMirroring = false; previewConnection.isVideoMirrored = false
            }
            guard newSession.canAddConnection(previewConnection) else { throw CaptureError.unavailable }
            newSession.addConnection(previewConnection); newSession.commitConfiguration()
            // Explicit video-only wiring avoids connecting a muxed device
            // microphone as an accidental side effect of auto-connection.
            session = newSession; activeID = id; activeToken = recovery.generation
            deliveryLock.lock(); deliveryToken = activeToken; deliveryLock.unlock()
            lastFrame = .distantPast; startedAt = Date()
            newSession.startRunning()
            if !newSession.isRunning { stopSession(); publish("The device could not start. Close other apps using its screen, then Reconnect.") }
        } catch { stopSession(); publish("Cannot open this device. Unlock it, close any other preview using it, then Reconnect.") }
    }
    private func stopSession() {
        // Automatic error/disconnect recovery can reopen the same device without
        // another selection. Its new session must never reuse an old frame token.
        recovery.invalidateSession()
        deliveryLock.lock(); deliveryToken = -1; deliveryLock.unlock()
        session?.stopRunning(); previewLayer.session = nil; session = nil; activeID = nil
        DispatchQueue.main.async { [weak self] in self?.live = false; self?.dimensions = .zero }
    }
    private func checkHealth() {
        guard enabled else { return }
        guard let activeID else { discover(); return }
        if devices[activeID]?.isConnected != true { stopSession(); discover(); return }
        if Date().timeIntervalSince(max(lastFrame, startedAt)) > 5 {
            publish("No new frames. Unlock your device or reconnect its cable, then choose Reconnect.")
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
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { deliveryLock.lock(); pendingDelivery = false; deliveryLock.unlock() }
            // Stop/selection updates are queued before subsequent frames. The
            // selected identity also gates any already-enqueued old frame.
            deliveryLock.lock(); let valid = deliveryToken == token; deliveryLock.unlock()
            guard valid, selectedID == id else { return }
            let nextSize = CGSize(width: Int(size.width), height: Int(size.height))
            if dimensions != nextSize { dimensions = nextSize }
            if !live { live = true; message = "Live device screen" }
        }
    }
    private enum CaptureError: Error { case unavailable }
}
