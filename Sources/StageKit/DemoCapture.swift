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
        // remembered, so a plugged-in phone appears without a hunt for a Source menu,
        // whatever plain cameras are also there (a work Mac's display camera, Camo, a
        // capture card). A plain video device is never shown by itself, and two screens
        // always wait for a choice. Losing the remembered device never opens another.
        let screens = sources.filter(\.isScreen)
        return screens.count == 1 ? screens[0].id : nil
    }
}

/// Which surface draws through a preview layer. If macOS refuses a second connection
/// to the phone's screen, the stage, which the audience sees, keeps the picture.
enum PreviewSurface: Equatable {
    case stage, page
    /// Where a new layer goes among the current ones: stages before pages, newest first
    /// within each, which is also the order a new session wires them in.
    static func insertionIndex(for surface: PreviewSurface, among current: [PreviewSurface]) -> Int {
        surface == .stage ? 0 : (current.firstIndex(of: .page) ?? current.count)
    }
}

/// What the capture asks of AVFoundation. `SystemCaptureHardware` is the Mac's own; a check
/// substitutes synthetic devices, permission answers and sessions, so the real owners
/// (`DemoCapture`, `DemoScenes`, `DemoPresentation`) run their own callbacks without a phone.
/// Every method is called on the capture's queue.
protocol CaptureHardware: AnyObject {
    /// Begin watching for devices; `changed` may be called on any thread.
    func startDiscovery(changed: @escaping () -> Void)
    func stopDiscovery()
    /// External video and muxed devices, without Continuity Camera, sorted by name.
    func sources() -> [DemoSource]
    func isConnected(_ id: String) -> Bool
    func authorization() -> AVAuthorizationStatus
    /// Asks macOS once; the answer may arrive on any thread, at any later time.
    func requestAccess(_ completion: @escaping (Bool) -> Void)
    /// A configured, started video-only session for one device that delivers to `output`
    /// and draws through `attach`. nil when it configured but did not run.
    func openSession(_ id: String, output: AVCaptureVideoDataOutput,
                     attach: (AVCaptureSession, AVCaptureInput.Port) -> Void) throws -> AVCaptureSession?
}

/// Why a session could not be configured, as a bounded code for the report.
enum CaptureConfigurationError: Int, Error { case inputRefused = 1, outputRefused, noVideoPort, connectionRefused, deviceGone }

final class SystemCaptureHardware: CaptureHardware {
    private var discovery: AVCaptureDevice.DiscoverySession?
    private var observation: NSKeyValueObservation?
    private var devices: [String: AVCaptureDevice] = [:]
    func startDiscovery(changed: @escaping () -> Void) {
        DemoCapture.allowScreenCaptureDevices()
        discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: nil, position: .unspecified)
        observation = discovery?.observe(\.devices, options: [.new]) { _, _ in changed() }
    }
    func stopDiscovery() { observation = nil; discovery = nil; devices.removeAll() }
    func sources() -> [DemoSource] {
        let found = (discovery?.devices ?? []).filter { !$0.isContinuityCamera && ($0.hasMediaType(.video) || $0.hasMediaType(.muxed)) }
        devices = Dictionary(found.map { ($0.uniqueID, $0) }, uniquingKeysWith: { first, _ in first })
        return found.map { DemoSource(id: $0.uniqueID, name: $0.localizedName, isScreen: $0.hasMediaType(.muxed)) }.sorted { $0.name < $1.name }
    }
    func isConnected(_ id: String) -> Bool { devices[id]?.isConnected == true }
    func authorization() -> AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }
    func requestAccess(_ completion: @escaping (Bool) -> Void) { AVCaptureDevice.requestAccess(for: .video, completionHandler: completion) }
    func openSession(_ id: String, output: AVCaptureVideoDataOutput,
                     attach: (AVCaptureSession, AVCaptureInput.Port) -> Void) throws -> AVCaptureSession? {
        guard let device = devices[id] else { throw CaptureConfigurationError.deviceGone }
        let input = try AVCaptureDeviceInput(device: device)
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input) else { throw CaptureConfigurationError.inputRefused }
        // Explicit video-only wiring avoids connecting a muxed device
        // microphone as an accidental side effect of auto-connection.
        for port in input.ports where port.mediaType == .audio { port.isEnabled = false }
        session.addInputWithNoConnections(input)
        guard session.canAddOutput(output) else { throw CaptureConfigurationError.outputRefused }
        session.addOutputWithNoConnections(output)
        let ports = input.ports.filter { $0.mediaType == .video }
        guard !ports.isEmpty else { throw CaptureConfigurationError.noVideoPort }
        let connection = AVCaptureConnection(inputPorts: ports, output: output)
        guard session.canAddConnection(connection) else { throw CaptureConfigurationError.connectionRefused }
        session.addConnection(connection)
        attach(session, ports[0])
        session.commitConfiguration()
        session.startRunning()
        return session.isRunning ? session : nil
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
    /// Every surface showing this session draws through its own display layer: the
    /// Present page's preview and the stage. Each is fed the frames the session's data
    /// output already receives, so a phone screen that delivers frames is drawn on every
    /// surface at once. Preview-layer connections to the iPhone's muxed screen device
    /// stayed black on hardware (7 October 2026) while the data output had frames.
    /// Stages first, newest first. Touched only on the capture queue.
    private final class LayerSlot {
        weak var layer: AVSampleBufferDisplayLayer?
        let surface: PreviewSurface
        init(_ layer: AVSampleBufferDisplayLayer, surface: PreviewSurface) { self.layer = layer; self.surface = surface }
    }
    private var layers: [LayerSlot] = []
    /// Frames drawn on each surface since the last session started; checks read it.
    private(set) var drawnFrames: [PreviewSurface: Int] = [:]
    /// The running session's latest accepted frame. A phone on a still screen may send nothing
    /// new for a while, so a surface that opens later (Present pressed on a still Home Screen)
    /// draws this at once instead of opening black. Cleared whenever the session stops.
    private var lastDrawn: CMSampleBuffer?
    /// The headless phone receipt reads accepted frames here (on the capture queue); the app never sets it.
    var frameProbe: ((CMSampleBuffer) -> Void)?
    /// Every capture change runs here. Checks reach it to deliver a synthetic frame as AVFoundation would.
    let queue = DispatchQueue(label: "StageMark.device-preview", qos: .userInitiated)
    private let hardware: CaptureHardware
    private var session: AVCaptureSession?
    /// The current session's frame output; a frame from any other output is not this session's.
    private var activeOutput: AVCaptureOutput?
    private var recovery = CaptureRecovery()
    private var activeID: String?
    private var activeToken = 0
    private var sourceIDs = Set<String>()
    /// Bumped by every start and stop, so a permission answer for an earlier run admits nothing.
    private var runToken = 0
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
    /// macOS interrupted the session for another app; it resumes by itself when that app lets go.
    private var sessionInterrupted = false

    init(root: URL, hardware: CaptureHardware = SystemCaptureHardware()) {
        preference = root.appendingPathComponent("demo-source.json")
        self.hardware = hardware
        super.init()
        if let data = try? Data(contentsOf: preference), let id = try? JSONDecoder().decode(String.self, from: data) {
            recovery.desiredID = id; selectedID = id
        }
    }
    /// A layer for one surface. It draws the running session's next frame and every
    /// later one; a surface that goes away releases it.
    func makePreviewLayer(for surface: PreviewSurface) -> AVSampleBufferDisplayLayer {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect; layer.masksToBounds = true
        queue.async { [weak self] in
            guard let self else { return }
            layers.removeAll { $0.layer == nil }
            layers.insert(LayerSlot(layer, surface: surface), at: PreviewSurface.insertionIndex(for: surface, among: layers.map(\.surface)))
            if let lastDrawn { enqueue(lastDrawn, on: layer, surface: surface) }
        }
        return layer
    }
    /// On the capture queue: draws one accepted frame on every live surface at once.
    private func draw(_ sampleBuffer: CMSampleBuffer) {
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        lastDrawn = sampleBuffer
        // Strong copies, so a surface's final release never happens on this queue mid-loop.
        let surfaces = layers.compactMap { slot in slot.layer.map { ($0, slot.surface) } }
        layers.removeAll { $0.layer == nil }
        for (layer, surface) in surfaces { enqueue(sampleBuffer, on: layer, surface: surface) }
    }
    /// A renderer that is busy skips this frame rather than queueing it; the next one follows.
    private func enqueue(_ sampleBuffer: CMSampleBuffer, on layer: AVSampleBufferDisplayLayer, surface: PreviewSurface) {
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
        guard renderer.isReadyForMoreMediaData else { return }
        renderer.enqueue(sampleBuffer)
        drawnFrames[surface, default: 0] += 1
    }
    /// On the capture queue: a stopped session leaves no picture behind on any surface.
    private func clearSurfaces() {
        for slot in layers { slot.layer?.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil) }
        drawnFrames = [:]; lastDrawn = nil
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
            guard let self, !enabled else { return }; enabled = true; runToken += 1
            // A fresh run tries at once: an earlier run's back-off never delays Present or Reconnect.
            retryAfter = .distantPast; retryDelay = 2
            hardware.startDiscovery { [weak self] in self?.refresh() }
            let center = NotificationCenter.default
            for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.refresh() })
            }
            observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: nil) { [weak self] notification in
                guard let failed = notification.object as? AVCaptureSession else { return }
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self?.queue.async { [weak self] in
                    guard let self, enabled, session === failed else { return }
                    let id = activeID
                    stopSession()
                    // Only macOS's own "in use by another application" names another app.
                    if let id, let error, error.domain == AVFoundationErrorDomain, error.code == AVError.Code.deviceInUseByAnotherApplication.rawValue {
                        publish(.failed(id, .busy, CaptureFault(error)))
                    } else {
                        publish(id.map { .interrupted($0, error.map(CaptureFault.init)) } ?? .idle)
                    }
                    discover()
                }
            })
            // Another app (QuickTime Player, iPhone Mirroring) taking the screen interrupts the
            // session; macOS restarts it when the other app lets go, and the words follow.
            observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: nil, queue: nil) { [weak self] notification in
                guard let interrupted = notification.object as? AVCaptureSession else { return }
                self?.queue.async { [weak self] in
                    guard let self, enabled, session === interrupted, let id = activeID else { return }
                    sessionInterrupted = true
                    publish(.failed(id, .busy, CaptureFault(domain: "AVCaptureSession interrupted", code: 0)))
                }
            })
            observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: nil, queue: nil) { [weak self] notification in
                guard let resumed = notification.object as? AVCaptureSession else { return }
                self?.queue.async { [weak self] in
                    guard let self, enabled, session === resumed, sessionInterrupted, let id = activeID else { return }
                    sessionInterrupted = false; lastFrame = .distantPast; startedAt = Date()
                    publish(.connecting(id))
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
    /// Everything the stopped run still has outstanding is invalidated: a permission
    /// answer, a discovery change, a health check or a frame that lands later does nothing.
    func stop(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            // The remembered device survives a stop: the page and the stage share one capture
            // that starts again when either needs it.
            enabled = false; runToken += 1; waitingForPermission = false
            retryAfter = .distantPast; retryDelay = 2
            recovery.invalidateSession(); stopSession(); publish(.idle)
            sourceIDs.removeAll()
            publishSources([])
            timer?.cancel(); timer = nil
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
            if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver); self.wakeObserver = nil }
            hardware.stopDiscovery()
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }
    /// Publishes a change of phase only, so the two-second health check repeating the same
    /// answer never makes the page or the stage lay out again. A stall keeps `live`: the
    /// stage holds the phone's last frame while the words go to the controls and the page.
    private func publish(_ phase: CapturePhase) {
        guard phase != lastPublished else { return }
        lastPublished = phase
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.phase = phase
            switch phase {
            case .live, .stalled: break
            default: live = false
            }
        }
    }
    private var lastSources: [DemoSource] = []
    private func publishSources(_ choices: [DemoSource]) {
        guard choices != lastSources else { return }
        lastSources = choices
        DispatchQueue.main.async { [weak self] in self?.sources = choices }
    }
    private func discover() {
        guard enabled else { return }
        let choices = hardware.sources()
        sourceIDs = Set(choices.map(\.id))
        publishSources(choices)
        if let activeID, !sourceIDs.contains(activeID) {
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
        guard enabled, activeID == nil, sourceIDs.contains(id), !waitingForPermission else { return }
        switch hardware.authorization() {
        case .notDetermined:
            waitingForPermission = true
            publish(.waitingForAccess)
            let run = runToken
            hardware.requestAccess { [weak self] _ in
                self?.queue.async { [weak self] in
                    // An answer for a stopped run admits nothing: End or a release stays final.
                    guard let self, run == runToken else { return }
                    waitingForPermission = false; discover()
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
        // Frames are drawn on the page and the stage by display layers, so ask for 4:2:0 video
        // range, which they render directly; their size is read from the format description.
        let output = AVCaptureVideoDataOutput()
        let videoRange = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if output.availableVideoPixelFormatTypes.contains(videoRange) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: videoRange]
        }
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        // The token and output are set before the session runs, so its first frame is accepted.
        activeID = id; activeToken = recovery.generation; activeOutput = output
        deliveryLock.lock(); deliveryToken = activeToken; deliveryLock.unlock()
        lastFrame = .distantPast; startedAt = Date()
        do {
            // Surfaces draw this output's frames (`draw`), so the session wires no preview connections.
            let opened = try hardware.openSession(id, output: output) { _, _ in }
            guard let opened else { stopSession(); publish(.failed(id, .couldNotStart)); return }
            session = opened
            DispatchQueue.main.async { [weak self] in self?.heldDeviceID = id }
        } catch let error as AVError where error.code == .deviceInUseByAnotherApplication {
            stopSession(); publish(.failed(id, .busy, CaptureFault(error)))
        } catch let error as CaptureConfigurationError {
            stopSession(); publish(.failed(id, .couldNotOpen, CaptureFault(domain: "Workbench capture configuration", code: error.rawValue)))
        } catch { stopSession(); publish(.failed(id, .couldNotOpen, CaptureFault(error))) }
    }
    private func stopSession() {
        // Automatic error/disconnect recovery can reopen the same device without
        // another selection. Its new session must never reuse an old frame token.
        recovery.invalidateSession()
        deliveryLock.lock(); deliveryToken = -1; deliveryLock.unlock()
        session?.stopRunning(); clearSurfaces(); session = nil; activeID = nil; activeOutput = nil
        sessionInterrupted = false
        DispatchQueue.main.async { [weak self] in self?.live = false; self?.dimensions = .zero; self?.heldDeviceID = nil }
    }
    private func checkHealth() {
        guard enabled else { return }
        guard let activeID else { discover(); return }
        // The device went away under a running session: say so before looking again, so a
        // frozen "Showing iPhone" never outlives the phone.
        if !hardware.isConnected(activeID) { stopSession(); publish(.interrupted(activeID)); discover(); return }
        // An interruption for another app is not a stall; macOS resumes the session when it ends.
        if sessionInterrupted { return }
        // A phone screen takes about ten seconds to deliver its first frame while the
        // session negotiates (measured on 6 October 2026: 10.2 s). Only a feed that has
        // flowed and then gone quiet for five seconds is stalled; before the first frame
        // the words stay at connecting for fifteen seconds.
        let grace: TimeInterval = lastFrame == .distantPast ? 15 : 5
        if Date().timeIntervalSince(max(lastFrame, startedAt)) > grace {
            publish(.stalled(activeID))
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        deliver(sampleBuffer, from: output)
    }
    /// One frame from `output`, on the capture queue: the running session's frames are drawn on
    /// every surface; any other is dropped, as `frameArrived` decides.
    func deliver(_ sampleBuffer: CMSampleBuffer, from output: AVCaptureOutput) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let size = CMVideoFormatDescriptionGetDimensions(description)
        if frameArrived(CGSize(width: Int(size.width), height: Int(size.height)), from: output) { frameProbe?(sampleBuffer); draw(sampleBuffer) }
    }
    /// One frame from `output`, on the capture queue, where AVFoundation delivers it. Only the
    /// current session's output, in the current generation, while the capture runs, can make
    /// the phase live; a frame that lands after End or a newer selection is dropped.
    /// Returns whether the frame belongs to the running session, so the caller draws it.
    @discardableResult
    func frameArrived(_ nextSize: CGSize, from output: AVCaptureOutput) -> Bool {
        guard enabled, let id = activeID, recovery.accepts(activeToken, source: id), output === activeOutput else { return false }
        lastFrame = Date(); retryDelay = 2
        guard lastFrame.timeIntervalSince(lastPublish) >= 0.2 else { return true }
        deliveryLock.lock()
        if pendingDelivery { deliveryLock.unlock(); return true }
        pendingDelivery = true; deliveryLock.unlock()
        lastPublish = lastFrame
        let token = activeToken
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
        return true
    }
}
