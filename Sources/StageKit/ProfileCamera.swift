import AppKit
import AVFoundation
import CoreImage
import SwiftUI

struct ProfileCameraSource: Identifiable, Equatable {
    let id: String
    let name: String
}

enum ProfileCameraIssue: Error, Equatable {
    case denied, restricted, unavailable, failedToStart, interrupted, timedOut, unreadable
    var message: String {
        switch self {
        case .denied: return "Camera access is off. Allow Workbench in Camera settings, or choose a photo."
        case .restricted: return "Camera access is restricted on this Mac. You can choose a photo instead."
        case .unavailable: return "No camera is available. Open your Mac’s lid or connect a camera, then try again."
        case .failedToStart: return "The camera couldn’t start. Close any other app using it, then try again."
        case .interrupted: return "The camera was disconnected or interrupted. Check the connection, then try again."
        case .timedOut: return "The camera isn’t sending a picture. Open your Mac’s lid or check the camera, then try again."
        case .unreadable: return "That photo couldn’t be read. Try taking it again, or choose a photo."
        }
    }
}

enum ProfileCameraEvent {
    case sources([ProfileCameraSource], selected: String?)
    case frame
    case failed(ProfileCameraIssue)
    /// What the camera now running can do, read once it has started.
    case features(ProfileCameraFeatures)
}

/// What one running camera offers beyond its picture.
struct ProfileCameraFeatures: Equatable {
    /// Some format of this camera keeps people framed with Center Stage
    /// (`AVCaptureDevice.Format.isCenterStageSupported`).
    var centerStage = false
}

protocol ProfileCameraCapturing: AnyObject {
    var previewLayer: AVCaptureVideoPreviewLayer { get }
    func start(sourceID: String?, receive: @escaping @MainActor (ProfileCameraEvent) -> Void)
    func takePhoto(completion: @escaping @MainActor (Result<NSImage, ProfileCameraIssue>) -> Void)
    func stop()
    /// Center Stage was turned on: a running camera whose format cannot frame people
    /// moves to one that can. No default: every capture says what it does.
    func conformToCenterStage()
}

/// Owns one explicit camera visit. Late permissions, frames, photos and deadlines cannot
/// reopen a cancelled visit or replace a newer one. No profile/library writes happen here.
@MainActor
final class ProfileCamera: ObservableObject {
    enum State: Equatable { case idle, permission, starting, live, takingPhoto, failed(ProfileCameraIssue) }
    typealias Authorize = @MainActor (@escaping @MainActor (AVAuthorizationStatus) -> Void) -> Void
    typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> (() -> Void)
    @Published private(set) var state: State = .idle
    @Published private(set) var sources: [ProfileCameraSource] = []
    @Published private(set) var selectedID: String?
    var isPresented: Bool { state != .idle }
    var canTakePhoto: Bool { state == .live }
    var previewLayer: AVCaptureVideoPreviewLayer { capture.previewLayer }
    private let capture: ProfileCameraCapturing
    private let authorize: Authorize
    private let schedule: Schedule
    private var request = UUID()
    private var deadline = UUID()
    private var cancelDeadline: (() -> Void)?

    init(capture: ProfileCameraCapturing = ProfileCameraSession(),
         authorize: @escaping Authorize = ProfileCamera.authorize,
         schedule: @escaping Schedule = ProfileCamera.schedule) {
        self.capture = capture; self.authorize = authorize; self.schedule = schedule
    }
    func start(sourceID: String? = nil) {
        cancel()
        let token = request
        selectedID = sourceID; state = .permission
        authorize { [weak self] status in
            guard let self, self.request == token, self.state == .permission else { return }
            switch status {
            case .authorized:
                self.state = .starting
                self.armDeadline(10, token: token)
                self.capture.start(sourceID: sourceID) { [weak self] event in self?.receive(event, token: token) }
            case .restricted: self.fail(.restricted)
            default: self.fail(.denied)
            }
        }
    }
    func retry() { start(sourceID: selectedID) }
    func takePhoto(completion: @escaping (NSImage) -> Void) {
        guard canTakePhoto else { return }
        state = .takingPhoto
        let token = request
        armDeadline(5, token: token)
        capture.takePhoto { [weak self] result in
            guard let self, self.request == token, self.state == .takingPhoto else { return }
            switch result {
            case .success(let image): self.cancel(); completion(image)
            case .failure(let issue): self.fail(issue)
            }
        }
    }
    func cancel() {
        request = UUID(); disarmDeadline(); capture.stop(); state = .idle
    }
    private func receive(_ event: ProfileCameraEvent, token: UUID) {
        guard token == request else { return }
        switch event {
        case .sources(let sources, let selected):
            self.sources = sources; selectedID = selected
        case .frame:
            guard state == .starting || state == .live else { return }
            state = .live; armDeadline(5, token: token)
        case .failed(let issue): fail(issue)
        case .features: break
        }
    }
    private func fail(_ issue: ProfileCameraIssue) {
        request = UUID(); disarmDeadline(); capture.stop(); state = .failed(issue)
    }
    private func armDeadline(_ seconds: TimeInterval, token: UUID) {
        disarmDeadline()
        let ticket = deadline
        cancelDeadline = schedule(seconds) { [weak self] in
            guard let self, self.request == token, self.deadline == ticket else { return }
            self.fail(.timedOut)
        }
    }
    private func disarmDeadline() {
        deadline = UUID(); cancelDeadline?(); cancelDeadline = nil
    }
    private static func authorize(_ completion: @escaping @MainActor (AVAuthorizationStatus) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .notDetermined else { completion(status); return }
        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async { completion(AVCaptureDevice.authorizationStatus(for: .video)) }
        }
    }
    private static func schedule(_ seconds: TimeInterval, action: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            action()
        }
        return { task.cancel() }
    }
}

/// AVFoundation runs on one serial queue. Explicit video-only connections keep the
/// microphone untouched. Only the newest frame is retained, in memory, until the shutter.
final class ProfileCameraSession: NSObject, ProfileCameraCapturing, AVCaptureVideoDataOutputSampleBufferDelegate {
    let previewLayer = AVCaptureVideoPreviewLayer()
    private let queue = DispatchQueue(label: "Workbench.profile-camera", qos: .userInitiated)
    private let context = CIContext()
    private let requestLock = NSLock()
    private var request = UUID()
    private var session: AVCaptureSession?
    private var device: AVCaptureDevice?
    private var output: AVCaptureVideoDataOutput?
    private var frame: CVPixelBuffer?
    private var frameTime: TimeInterval = 0
    private var lastEvent: TimeInterval = 0
    private var receive: (@MainActor (ProfileCameraEvent) -> Void)?
    private var observers: [NSObjectProtocol] = []

    func start(sourceID: String?, receive: @escaping @MainActor (ProfileCameraEvent) -> Void) {
        let token = replaceRequest()
        queue.async { [self] in
            guard accepts(token) else { return }
            stopSession(); self.receive = receive
            let devices = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                mediaType: .video, position: .unspecified).devices.filter { !$0.hasMediaType(.muxed) }
            let preferred = AVCaptureDevice.default(for: .video)?.uniqueID
            let device = sourceID.flatMap { id in devices.first { $0.uniqueID == id } }
                ?? (sourceID == nil ? devices.first { $0.uniqueID == preferred } ?? devices.first : nil)
            emit(.sources(devices.map { ProfileCameraSource(id: $0.uniqueID, name: $0.localizedName) }, selected: device?.uniqueID ?? sourceID))
            guard let device else { fail(.unavailable); return }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                let session = AVCaptureSession()
                session.beginConfiguration()
                if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                guard session.canAddInput(input) else { throw ProfileCameraIssue.failedToStart }
                for port in input.ports where port.mediaType == .audio { port.isEnabled = false }
                session.addInputWithNoConnections(input)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.setSampleBufferDelegate(self, queue: queue)
                guard session.canAddOutput(output) else { throw ProfileCameraIssue.failedToStart }
                session.addOutputWithNoConnections(output)
                let ports = input.ports.filter { $0.mediaType == .video }
                guard let port = ports.first else { throw ProfileCameraIssue.failedToStart }
                let video = AVCaptureConnection(inputPorts: ports, output: output)
                guard session.canAddConnection(video) else { throw ProfileCameraIssue.failedToStart }
                session.addConnection(video)
                // Preview and saved frame use the same mirror, like looking in a mirror.
                previewLayer.setSessionWithNoConnection(session)
                let preview = AVCaptureConnection(inputPort: port, videoPreviewLayer: previewLayer)
                guard session.canAddConnection(preview) else { throw ProfileCameraIssue.failedToStart }
                session.addConnection(preview)
                let mirrored = video.isVideoMirroringSupported && preview.isVideoMirroringSupported
                for connection in [video, preview] where connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = mirrored
                }
                session.commitConfiguration()
                self.session = session; self.output = output
                for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self, weak session] _ in
                        self?.queue.async { [weak self, weak session] in
                            guard let self, let session, self.session === session else { return }
                            self.fail(.interrupted)
                        }
                    })
                }
                observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self, weak session] _ in
                    self?.queue.async { [weak self, weak session] in
                        guard let self, let session, self.session === session else { return }
                        self.fail(.interrupted)
                    }
                })
                guard accepts(token) else { stopSession(); return }
                self.device = device
                Self.conform(device)
                session.startRunning()
                guard accepts(token) else { stopSession(); return }
                if !session.isRunning { fail(.failedToStart); return }
                emit(.features(ProfileCameraFeatures(centerStage: device.formats.contains { $0.isCenterStageSupported })))
            } catch { fail(.failedToStart) }
        }
    }
    func takePhoto(completion: @escaping @MainActor (Result<NSImage, ProfileCameraIssue>) -> Void) {
        queue.async { [self] in
            let result: Result<NSImage, ProfileCameraIssue>
            if let frame, ProcessInfo.processInfo.systemUptime - frameTime < 2 {
                result = Self.photo(from: frame, context: context)
            } else { result = .failure(.timedOut) }
            stopSession()
            DispatchQueue.main.async { completion(result) }
        }
    }
    static func photo(from frame: CVPixelBuffer, context: CIContext) -> Result<NSImage, ProfileCameraIssue> {
        let image = CIImage(cvPixelBuffer: frame)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return .failure(.unreadable) }
        return .success(NSImage(cgImage: cgImage, size: .zero))
    }
    func stop() {
        _ = replaceRequest()
        queue.async { [self] in stopSession() }
    }
    func conformToCenterStage() {
        queue.async { [self] in if let device { Self.conform(device) } }
    }
    /// With Center Stage on, the app keeps a format that can frame people, as
    /// `AVCaptureDevice.centerStageActive` asks of an app sharing control: the smallest
    /// supporting format at least 1280 wide, else the largest. Nothing changes while it
    /// is off or the current format already supports it.
    private static func conform(_ device: AVCaptureDevice) {
        guard AVCaptureDevice.isCenterStageEnabled, !device.activeFormat.isCenterStageSupported else { return }
        func width(_ format: AVCaptureDevice.Format) -> Int32 { CMVideoFormatDescriptionGetDimensions(format.formatDescription).width }
        let supported = device.formats.filter(\.isCenterStageSupported)
        guard let chosen = supported.filter({ width($0) >= 1280 }).min(by: { width($0) < width($1) })
                ?? supported.max(by: { width($0) < width($1) }) else { return }
        do { try device.lockForConfiguration(); device.activeFormat = chosen; device.unlockForConfiguration() } catch {}
    }
    private func replaceRequest() -> UUID {
        requestLock.lock(); defer { requestLock.unlock() }
        request = UUID(); return request
    }
    private func accepts(_ token: UUID) -> Bool {
        requestLock.lock(); defer { requestLock.unlock() }
        return request == token
    }
    private func stopSession() {
        receive = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning(); previewLayer.session = nil
        session = nil; device = nil; output = nil; frame = nil; frameTime = 0; lastEvent = 0
    }
    private func fail(_ issue: ProfileCameraIssue) {
        emit(.failed(issue)); stopSession()
    }
    private func emit(_ event: ProfileCameraEvent) {
        guard let receive else { return }
        DispatchQueue.main.async { receive(event) }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard self.output === output, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frame = buffer; frameTime = ProcessInfo.processInfo.systemUptime
        if frameTime - lastEvent >= 0.5 { lastEvent = frameTime; emit(.frame) }
    }
}

struct ProfileCameraPreview: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer
    func makeNSView(context: Context) -> ProfileCameraPreviewHost { ProfileCameraPreviewHost(previewLayer) }
    func updateNSView(_ view: ProfileCameraPreviewHost, context: Context) {}
}
final class ProfileCameraPreviewHost: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    init(_ preview: AVCaptureVideoPreviewLayer) {
        self.preview = preview
        super.init(frame: .zero)
        wantsLayer = true; preview.videoGravity = .resizeAspect
        layer?.addSublayer(preview)
        setAccessibilityElement(true); setAccessibilityLabel("Live camera preview")
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.frame = bounds
        CATransaction.commit()
    }
}

struct ProfileCameraView: View {
    @ObservedObject var camera: ProfileCamera
    var captured: (NSImage) -> Void
    var choosePhoto: () -> Void
    private var hasSelectedSource: Bool { camera.sources.contains { $0.id == camera.selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Take photo").font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel") { camera.cancel() }.keyboardShortcut(.cancelAction)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.black)
                ProfileCameraPreview(previewLayer: camera.previewLayer)
                    .opacity(camera.state == .live ? 1 : 0)
                    .accessibilityHidden(camera.state != .live)
                if case .failed = camera.state {
                    Image(systemName: "camera.fill").font(.system(size: 36)).foregroundStyle(.white.opacity(0.6)).accessibilityHidden(true)
                } else if camera.state != .live {
                    ProgressView().controlSize(.small).tint(.white)
                }
            }.frame(height: 238).clipShape(RoundedRectangle(cornerRadius: 12))
            if camera.sources.count > 1 || (!camera.sources.isEmpty && !hasSelectedSource) {
                Picker("Camera", selection: Binding(get: { hasSelectedSource ? camera.selectedID ?? "" : "" }, set: { camera.start(sourceID: $0) })) {
                    if !hasSelectedSource { Text("Choose a camera").tag("") }
                    ForEach(camera.sources) { Text($0.name).tag($0.id) }
                }.disabled(camera.state == .takingPhoto)
            } else if let source = camera.sources.first {
                Text(source.name).font(.caption).foregroundStyle(.secondary)
            }
            Group {
                switch camera.state {
                case .permission: Text("Allow Camera access in the macOS prompt. You can cancel at any time.")
                case .starting: Text("Opening camera…")
                case .takingPhoto: Text("Preparing your photo…")
                case .failed(let issue): Text(issue.message)
                default: Text("Frame yourself, then take a photo. You’ll review it before saving.")
                }
            }.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choose photo…", action: choosePhoto)
                Spacer()
                if case .failed(let issue) = camera.state {
                    if issue == .denied {
                        Button("Camera Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") { NSWorkspace.shared.open(url) }
                        }
                    }
                    if issue != .restricted {
                        Button("Try again") { camera.retry() }
                    }
                } else {
                    Button("Take photo") { camera.takePhoto(completion: captured) }
                        .buttonStyle(.borderedProminent).disabled(!camera.canTakePhoto).keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}
