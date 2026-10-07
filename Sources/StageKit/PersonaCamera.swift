import AppKit
import AVFoundation
import SwiftUI

/// A camera Persona could open, as listed without opening it.
struct PersonaCameraDevice: Equatable {
    let id: String
    let name: String
    /// Another application already has it. Workbench does not take it away.
    let inUseByAnotherApp: Bool
}

/// The cameras this Mac offers, and which one a start would open. Listing is
/// read-only: it creates no session, no input and no recording light, so
/// pressing Start camera is the first thing that reaches the hardware.
struct PersonaCameraList: Equatable {
    var devices: [PersonaCameraDevice] = []
    /// The system's default video device, which a start without a chosen camera uses.
    var preferredID: String?

    /// The camera a start with `selection` would open, chosen exactly as the
    /// shared capture session chooses it, so a conflict is reported about the
    /// camera that would actually be opened.
    func chosen(_ selection: String?) -> PersonaCameraDevice? {
        if let selection { return devices.first { $0.id == selection } }
        return devices.first { $0.id == preferredID } ?? devices.first
    }

    static func system() -> PersonaCameraList {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified).devices.filter { !$0.hasMediaType(.muxed) }
        return PersonaCameraList(devices: devices.map {
            PersonaCameraDevice(id: $0.uniqueID, name: $0.localizedName, inUseByAnotherApp: $0.isInUseByAnotherApplication)
        }, preferredID: AVCaptureDevice.default(for: .video)?.uniqueID)
    }
}

/// Why Persona's camera bubble is not on screen, in Persona's own words: the
/// shared capture session's reasons, plus a camera another owner already has.
/// Every message names the next useful action and never offers to save a photo,
/// because this source shows a live picture and keeps none.
enum PersonaCameraFailure: Equatable {
    case access(ProfileCameraIssue)
    case inUse(camera: String, owner: String)
    /// The chosen camera has gone while others remain. None of them is opened in its place.
    case missing(camera: String?)

    var message: String {
        switch self {
        case .inUse(let camera, let owner):
            return "“\(camera)” is already in use by \(owner). End that use or choose another camera, then start Live Camera again."
        case .missing(let camera):
            return "The selected camera" + (camera.map { ", “\($0)”," } ?? "") + " isn’t connected. Choose another camera, or reconnect it, then start Live Camera again."
        case .access(let issue):
            switch issue {
            case .denied: return "Camera access is off. Allow Workbench in Camera settings, then start Live Camera again."
            case .restricted: return "Camera access is restricted on this Mac. Show saved artwork instead."
            case .unavailable: return "No camera is available. Open your Mac’s lid or connect a camera, then try again."
            case .failedToStart: return "The camera couldn’t start. Close any other app using it, then try again."
            case .interrupted: return "The camera was disconnected or interrupted. Check the connection, then try again."
            case .timedOut: return "The camera isn’t sending a picture. Check the camera, then try again."
            case .unreadable: return "The camera’s picture couldn’t be read. Try again, or show saved artwork."
            }
        }
    }
    /// Only a refused permission has a settings route; everything else is retried in place.
    var offersCameraSettings: Bool { self == .access(.denied) }
    /// Restricted access cannot be retried by trying again.
    var offersRetry: Bool { self != .access(.restricted) }
}

/// Why a Start camera was refused before anything was opened. A prepared
/// overlay set owns the slot, and its device, until it is ended.
enum PersonaCameraRefusal: LocalizedError, Equatable {
    case preparedSession
    var errorDescription: String? {
        switch self {
        case .preparedSession: return "End the prepared overlay set before starting Live Camera."
        }
    }
}

/// Why My Profile could not show: no profile photo is set, or a prepared set has the slot.
enum PersonaProfileRefusal: LocalizedError, Equatable {
    case noProfile, preparedSession
    var errorDescription: String? {
        switch self {
        case .noProfile: return "Set a photo in My Profile first."
        case .preparedSession: return "End the prepared overlay set before showing My Profile."
        }
    }
}

/// Why the bubble is off screen while its visit is kept: the presenter hid it,
/// or the Mac slept and Workbench let go of the camera at once.
enum PersonaCameraPause: Equatable {
    case chosen, asleep
    var message: String {
        switch self {
        case .chosen: return "Live Camera hidden · the camera is released. Show Live Camera again when you’re ready."
        case .asleep: return "The camera was released when this Mac slept. Show Live Camera again when you’re ready."
        }
    }
}

/// One explicit camera visit, with nothing on screen until a real frame arrives.
enum PersonaCameraState: Equatable {
    case off, permission, starting, live
    case hidden(PersonaCameraPause)
    case failed(PersonaCameraFailure)
}

/// The camera bubble's window. `PersonaOverlayController` is the one
/// implementation, so the bubble drags, resizes, stays on screen and passes
/// clicks through exactly as saved artwork does; checks pass their own so no
/// display is needed.
protocol PersonaCameraDisplaying: AnyObject {
    var onPlacementChange: ((PersonaOverlayState) -> Void)? { get set }
    var frame: CGRect? { get }
    /// `animated` fades the bubble in over the card it replaces in the same place.
    func showLive(layer: CALayer, aspect: CGSize, outline: PersonaArtworkOutline?,
                  name: String, help: String, state: PersonaOverlayState, animated: Bool) -> PersonaOverlayState
    func configureLive(name: String, help: String, state: PersonaOverlayState)
    func hide()
    func releaseLive()
    func shutdown()
    /// React to my voice around the bubble, exactly as around a card.
    func setVoiceRing(_ on: Bool)
    func setVoiceColor(_ color: InkColor)
    func showVoice(_ frames: [PersonaVoiceFrame])
    /// Fades the bubble out while a card fades in over it, then `completion` releases it.
    func fadeOut(then completion: @escaping () -> Void)
}

extension PersonaCameraDisplaying {
    func setVoiceRing(_ on: Bool) {}
    func setVoiceColor(_ color: InkColor) {}
    func showVoice(_ frames: [PersonaVoiceFrame]) {}
    func fadeOut(then completion: @escaping () -> Void) { completion() }
}

extension PersonaOverlayController: PersonaCameraDisplaying {}

/// macOS's own camera effects for the app: Center Stage's per-app switch, which the menu
/// bar's Video menu also changes, and that Video menu itself. Checks pass their own so no
/// system state changes and nothing opens.
struct PersonaCameraEffects {
    /// `AVCaptureDevice.isCenterStageEnabled`: one switch per app, not per camera.
    var centerStageEnabled: () -> Bool
    /// Sets it in cooperative control, so the Video menu can still change it.
    var setCenterStage: (Bool) -> Void
    /// Calls back on the main thread when the switch changes anywhere; keep the token.
    var observeCenterStage: (@escaping () -> Void) -> AnyObject?
    /// `AVCaptureDevice.showSystemUserInterface(.videoEffects)`.
    var showVideoEffects: () -> Void

    static var system: PersonaCameraEffects {
        PersonaCameraEffects(
            centerStageEnabled: { AVCaptureDevice.isCenterStageEnabled },
            setCenterStage: { on in
                // User control, the default, throws on a set. Cooperative control lets
                // Workbench set it while the Video menu keeps changing it too.
                if AVCaptureDevice.centerStageControlMode != .cooperative { AVCaptureDevice.centerStageControlMode = .cooperative }
                AVCaptureDevice.isCenterStageEnabled = on
            },
            observeCenterStage: { PersonaCenterStageObserver($0) },
            showVideoEffects: { AVCaptureDevice.showSystemUserInterface(.videoEffects) })
    }
    /// Changes and opens nothing: renders and the window read-back check.
    static let inert = PersonaCameraEffects(centerStageEnabled: { false }, setCenterStage: { _ in },
                                            observeCenterStage: { _ in nil }, showVideoEffects: {})
}

/// Key-value observes the class-level Center Stage switch, as cooperative control asks.
private final class PersonaCenterStageObserver: NSObject {
    private let changed: () -> Void
    init(_ changed: @escaping () -> Void) {
        self.changed = changed
        super.init()
        AVCaptureDevice.self.addObserver(self, forKeyPath: "centerStageEnabled", options: [.new], context: nil)
    }
    deinit { AVCaptureDevice.self.removeObserver(self, forKeyPath: "centerStageEnabled") }
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        let changed = changed
        DispatchQueue.main.async { changed() }
    }
}

/// Persona's local live camera: a mirrored circle of this Mac's own camera,
/// floating over the apps beside the windows the presenter is demonstrating.
///
/// It owns one camera session, the bubble's window and the bubble's temporary
/// placement, and nothing else: no saved artwork, no library file and no photo.
/// Starting is always explicit. Visiting Persona, choosing Camera as the source
/// or picking a camera in the list never opens the hardware by itself.
///
/// One visit at a time, identified by `visit`, and one request token behind it:
/// a permission answer, a frame or a deadline from an earlier visit is dropped
/// rather than reopening it. The shared `ProfileCameraSession` configures,
/// starts and stops video-only capture on its own serial queue, so the
/// microphone is never connected and no movie output exists. Hide, End, Quit
/// and the Mac going to sleep release the camera at once, and nothing restarts
/// it without the person asking again.
final class PersonaLiveCamera: ObservableObject {
    /// A camera that has sent no picture within this long has not started.
    static let startupSeconds: TimeInterval = 10
    /// A live bubble whose frames stop for this long has stalled.
    static let frameSeconds: TimeInterval = 5
    typealias Authorize = (@escaping (AVAuthorizationStatus) -> Void) -> Void
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> (() -> Void)

    @Published private(set) var state: PersonaCameraState = .off
    /// The cameras offered in the list: seeded when a start lists them, then
    /// kept up to date by the session itself.
    @Published private(set) var sources: [ProfileCameraSource] = []
    @Published private(set) var selectedID: String?
    /// A prepared source choice starts no device until Start, Show again,
    /// Try again or Switch camera is explicitly chosen.
    @Published private(set) var preparedID: String?
    var hasPreparedSwitch: Bool { isLive && preparedID != nil && preparedID != selectedID }
    var preparedSourceAvailable: Bool { sources.contains { $0.id == (preparedID ?? selectedID) } }
    var offersSourceChoice: Bool { sources.count > 1 || (!sources.isEmpty && !preparedSourceAvailable) }
    func prepareDevice(_ id: String) {
        guard sources.contains(where: { $0.id == id }) else { return }
        preparedID = id
    }
    /// Where the bubble sits, how wide it is and whether it passes clicks
    /// through. It belongs to this owner for this app session only: no file,
    /// preference or database records it, and saved artwork keeps its own.
    @Published private(set) var placement = PersonaOverlayState(x: 0.98, y: 0.06, width: 0.14)
    /// This visit's identity. A control drawn for an earlier visit revalidates
    /// it and does nothing, so a stale Hide or Retry cannot touch a newer one.
    @Published private(set) var visit = UUID()
    /// Told after every change, so the one live Persona slot can follow it.
    var onChange: (() -> Void)?
    /// The camera the app's own device capture holds, so Present keeps it.
    var deviceInUse: (() -> String?)?
    /// What the camera now showing offers, read when it starts.
    @Published private(set) var features = ProfileCameraFeatures()
    /// Center Stage's per-app switch, as macOS keeps it.
    @Published private(set) var centerStageOn = false
    /// Center Stage is offered only while the bubble shows a camera that can frame you.
    var offersCenterStage: Bool { isLive && features.centerStage }
    /// React to my voice around the bubble. The library decides it and opens the microphone;
    /// the bubble only draws it.
    private(set) var voiceRing = false
    private(set) var voiceColor = PersonaVoiceRingLayer.usualColor

    private let makeCapture: () -> ProfileCameraCapturing
    private let makePanel: () -> PersonaCameraDisplaying
    private let authorize: Authorize
    private let schedule: Schedule
    private let list: () -> PersonaCameraList
    private let effects: PersonaCameraEffects
    private var centerStageWatch: AnyObject?
    /// The next bubble fades in over a card it replaces.
    private var fadesIn = false
    private var capture: ProfileCameraCapturing?
    private var panel: PersonaCameraDisplaying?
    private var request = UUID()
    private var deadline = UUID()
    private var cancelDeadline: (() -> Void)?
    private var sleepWatch: NSObjectProtocol?

    /// Checks pass their own capture, window, permission, clock and camera list,
    /// so no hardware, display or privacy prompt is involved.
    init(capture: @escaping () -> ProfileCameraCapturing = { ProfileCameraSession() },
         panel: @escaping () -> PersonaCameraDisplaying = { PersonaOverlayController(persistentLockedHandle: true) },
         authorize: @escaping Authorize = PersonaLiveCamera.authorize,
         schedule: @escaping Schedule = PersonaLiveCamera.schedule,
         list: @escaping () -> PersonaCameraList = PersonaCameraList.system,
         effects: PersonaCameraEffects = .system) {
        self.makeCapture = capture; self.makePanel = panel
        self.authorize = authorize; self.schedule = schedule; self.list = list; self.effects = effects
    }

    var isLive: Bool { state == .live }
    /// Asking for access or waiting for the first frame: nothing is on screen yet.
    var isStarting: Bool { state == .permission || state == .starting }
    /// A visit Persona's doors must speak for, whether or not it is on screen.
    var isActive: Bool { state != .off }
    var isHidden: Bool { if case .hidden = state { return true }; return false }
    var failure: PersonaCameraFailure? { if case .failed(let failure) = state { return failure } else { return nil } }
    /// The camera named in the list, for the panel's own line.
    var selectedName: String? { sources.first { $0.id == selectedID }?.name }
    /// A compact truthful status for Persona's shared controls.
    var status: String {
        switch state {
        case .off: return ""
        case .permission: return "Waiting for camera access"
        case .starting: return "Starting Live Camera"
        case .live: return "Live Camera"
        case .hidden: return "Live Camera hidden"
        case .failed: return "Live Camera stopped"
        }
    }
    /// The panel's own line under its Live Camera heading, which names the source already.
    var phase: String {
        switch state {
        case .off: return "Not started"
        case .permission: return "Waiting for camera access"
        case .starting: return "Starting"
        case .live: return "Showing"
        case .hidden: return "Hidden"
        case .failed: return "Stopped"
        }
    }
    /// One sentence about where the visit is, shown where the visit is managed.
    var explanation: String {
        switch state {
        case .off: return "A mirrored circle of this Mac’s camera floats over your apps. Nothing is recorded, sent or saved."
        case .permission: return "Allow Camera access in the macOS prompt. You can cancel at any time."
        case .starting: return "Starting the camera. Nothing shows until a real picture arrives, so your artwork stays as it is."
        case .live:
            return placement.locked
                ? "Your camera is showing. Drag the handle above it to move it, or drag a corner to resize it."
                : "Your camera is showing. Drag the bubble to move it, or drag a corner to resize it."
        case .hidden(let reason): return reason.message
        case .failed(.access(.unavailable)) where !sources.isEmpty && !sources.contains(where: { $0.id == selectedID }):
            return "The selected camera isn’t available. Choose another camera above, then try again."
        case .failed(let failure): return failure.message
        }
    }
    /// For checks: the bubble's window frame while it shows.
    var bubbleFrame: CGRect? { isLive ? panel?.frame : nil }

    // MARK: One explicit visit

    /// Start camera, the one door to the hardware. `deviceID` is an explicit
    /// choice from the list; without it the system's usual camera is used. A
    /// camera another owner holds is reported instead of taken.
    /// `replacing` is the placement of a card on screen now: the bubble takes its place and
    /// size, keeps its own lock, and fades in over it when the first frame arrives.
    func start(deviceID: String? = nil, replacing card: PersonaOverlayState? = nil) {
        release()
        if let card, !isLive {
            var next = placement
            next.x = card.x; next.y = card.y; next.width = card.width; next.screenID = card.screenID
            if let valid = try? next.validated() { placement = valid }
        }
        fadesIn = card != nil
        features = ProfileCameraFeatures()
        let token = request
        visit = UUID()
        let cameras = list()
        let target = deviceID ?? preparedID ?? selectedID
        let targetName = sources.first { $0.id == target }?.name
        sources = cameras.devices.map { ProfileCameraSource(id: $0.id, name: $0.name) }
        // With no camera at all, the session reports that none is available with
        // the same words as every other start.
        if let chosen = cameras.chosen(target) {
            selectedID = chosen.id; preparedID = chosen.id
            if let owner = owner(of: chosen) {
                fail(.inUse(camera: chosen.name, owner: owner)); return
            }
        } else if target != nil, !cameras.devices.isEmpty {
            // The chosen camera has gone, but others remain. Say which one is
            // missing and let the person choose; never open another in its place.
            fail(.missing(camera: targetName)); return
        } else if let deviceID {
            selectedID = deviceID
        }
        let requested = target ?? selectedID
        move(to: .permission)
        authorize { [weak self] status in
            guard let self, self.request == token, self.state == .permission else { return }
            switch status {
            case .authorized:
                // Permission can outlive another device owner's start. Recheck
                // the same camera immediately before opening it.
                if let chosen = self.list().chosen(requested), let owner = self.owner(of: chosen) {
                    self.fail(.inUse(camera: chosen.name, owner: owner)); return
                }
                self.move(to: .starting)
                self.armDeadline(Self.startupSeconds, token: token)
                let capture = self.capture ?? self.makeCapture()
                self.capture = capture
                capture.start(sourceID: requested) { [weak self] event in self?.receive(event, token: token) }
            case .restricted: self.fail(.access(.restricted))
            default: self.fail(.access(.denied))
            }
        }
    }
    /// Explicit recovery after a failure: the same camera, never a silent fallback.
    func retry() { start(deviceID: preparedID ?? selectedID) }
    /// Hide: the bubble leaves and the camera is released at once. Its place,
    /// size and lock are kept, so Show camera again returns it exactly there.
    func hide(_ reason: PersonaCameraPause = .chosen) {
        guard isLive || (reason == .asleep && isStarting) else { return }
        release()
        move(to: .hidden(reason))
    }
    /// End camera, and Cancel while it is starting: the device goes, the bubble's
    /// window goes, and this visit is over. Saved artwork is untouched.
    /// `fading` lets the bubble fade out while a card fades in over it; the camera is
    /// released at once either way.
    func end(fading: Bool = false) {
        guard isActive else { return }
        release()
        visit = UUID()
        if fading, isLive, let leaving = panel {
            panel = nil
            leaving.fadeOut { leaving.releaseLive(); leaving.shutdown() }
        }
        move(to: .off)
    }
    func shutdown() {
        end()
        centerStageWatch = nil
        disarmSleepWatch()
        panel?.shutdown(); panel = nil
        capture?.stop(); capture = nil
    }

    /// Workspace actions retain the visit they were rendered for. End and
    /// source departure invalidate them before any later click can restart it.
    func perform(ifCurrent expected: UUID, _ action: () -> Void) {
        guard visit == expected else { return }
        action()
    }

    // MARK: React to my voice and camera effects

    /// The ring follows the switch whether or not the bubble shows, so a bubble is placed
    /// with the ring's room at once.
    func setVoiceRing(_ on: Bool) {
        guard voiceRing != on else { return }
        voiceRing = on; panel?.setVoiceRing(on)
    }
    func setVoiceColor(_ color: InkColor) { voiceColor = color; panel?.setVoiceColor(color) }
    func showVoice(_ frames: [PersonaVoiceFrame]) { if isLive { panel?.showVoice(frames) } }
    /// Center Stage on or off for this app, while a camera that can frame you shows. A running
    /// camera moves to a format that supports it.
    func setCenterStage(_ on: Bool) {
        guard offersCenterStage else { return }
        effects.setCenterStage(on)
        centerStageOn = effects.centerStageEnabled()
        if on { capture?.conformToCenterStage() }
        onChange?()
    }
    /// The menu bar's Video menu: Portrait, Studio Light, Reactions, Background and the rest.
    func showVideoEffects() { if isLive { effects.showVideoEffects() } }
    private func watchCenterStage() {
        centerStageOn = effects.centerStageEnabled()
        guard centerStageWatch == nil else { return }
        centerStageWatch = effects.observeCenterStage { [weak self] in
            guard let self else { return }
            self.centerStageOn = self.effects.centerStageEnabled()
            self.onChange?()
        }
    }

    // MARK: The bubble's own placement

    func setWidth(_ width: Double) {
        guard width.isFinite else { return }
        var next = placement; next.width = min(0.40, max(0.06, width)); apply(next)
    }
    func setLocked(_ locked: Bool) {
        var next = placement; next.locked = locked; apply(next)
    }
    func setPosition(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        var next = placement; next.x = min(1, max(0, x)); next.y = min(1, max(0, y)); apply(next)
    }

    // MARK: Inside one visit

    private func receive(_ event: ProfileCameraEvent, token: UUID) {
        guard token == request else { return }
        switch event {
        case .sources(let sources, let selected):
            self.sources = sources
            if let selected { selectedID = selected }
            onChange?()
        case .frame:
            guard state == .starting || state == .live else { return }
            armDeadline(Self.frameSeconds, token: token)
            move(to: .live)
        case .failed(let issue):
            fail(.access(issue))
        case .features(let features):
            self.features = features
            if features.centerStage { watchCenterStage() }
            onChange?()
        }
    }
    private func fail(_ failure: PersonaCameraFailure) {
        release()
        move(to: .failed(failure))
    }
    /// Drops this visit's late events and lets go of the camera. The bubble's
    /// window and placement are left to `move(to:)`.
    private func release() {
        request = UUID()
        disarmDeadline()
        capture?.stop()
    }
    private func move(to next: PersonaCameraState) {
        guard state != next else { return }
        state = next
        switch next {
        case .live: showBubble(); armSleepWatch()
        case .off:
            disarmSleepWatch(); panel?.releaseLive(); panel?.shutdown(); panel = nil
        case .hidden, .failed:
            disarmSleepWatch(); panel?.hide()
        case .permission, .starting:
            panel?.hide(); armSleepWatch()
        }
        onChange?()
    }
    private func showBubble() {
        guard let capture else { return }
        if panel == nil {
            let created = makePanel()
            created.onPlacementChange = { [weak self] state in self?.placementChanged(state) }
            panel = created
        }
        // The ring before the bubble shows, so it is placed with the ring's room at once.
        panel?.setVoiceColor(voiceColor)
        panel?.setVoiceRing(voiceRing)
        // The preview is cropped to the bubble's circle, not letterboxed, and
        // keeps the session's mirroring, so the presenter sees themselves as in
        // a mirror. The session owns the frames; this layer only draws them.
        // The circle is the edge the ring and the handles follow.
        let preview = capture.previewLayer
        preview.videoGravity = .resizeAspectFill
        let fade = fadesIn
        fadesIn = false
        guard let kept = panel?.showLive(layer: preview, aspect: CGSize(width: 1, height: 1),
                                        outline: PersonaCircleRenderer.outline, name: Self.bubbleName,
                                        help: Self.bubbleHelp(locked: placement.locked), state: placement, animated: fade) else { return }
        placement = (try? kept.validated()) ?? kept
    }
    private func apply(_ next: PersonaOverlayState) {
        guard let valid = try? next.validated(), valid != placement else { return }
        placement = valid
        panel?.configureLive(name: Self.bubbleName, help: Self.bubbleHelp(locked: valid.locked), state: valid)
        onChange?()
    }
    /// A drag or a resize of the bubble itself, or a display change moving it back on screen.
    private func placementChanged(_ state: PersonaOverlayState) {
        guard let valid = try? state.validated() else { return }
        placement = valid
        onChange?()
    }

    private static let bubbleName = "Live Camera"
    private static func bubbleHelp(locked: Bool) -> String {
        locked ? "Your live camera. Clicks pass through it. Drag its top handle to move it, or a corner or edge to resize it."
               : "Drag to move your live camera, or drag a corner or edge to resize it. Lock it in Workbench to let clicks pass through."
    }
    /// Who already holds this camera: the app's own device presentation, or
    /// another application. Workbench reports it instead of taking the device.
    private func owner(of camera: PersonaCameraDevice) -> String? {
        if deviceInUse?() == camera.id { return "Present" }
        return camera.inUseByAnotherApp ? "another app" : nil
    }
    private func armDeadline(_ seconds: TimeInterval, token: UUID) {
        disarmDeadline()
        let ticket = deadline
        cancelDeadline = schedule(seconds) { [weak self] in
            guard let self, self.request == token, self.deadline == ticket else { return }
            self.fail(.access(.timedOut))
        }
    }
    private func disarmDeadline() {
        deadline = UUID(); cancelDeadline?(); cancelDeadline = nil
    }
    /// Sleep releases the camera at once and keeps the bubble's place. Waking
    /// shows nothing again by itself; Show camera again is the person's choice.
    private func armSleepWatch() {
        guard sleepWatch == nil else { return }
        sleepWatch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.hide(.asleep)
            }
    }
    private func disarmSleepWatch() {
        guard let sleepWatch else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(sleepWatch)
        self.sleepWatch = nil
    }
    private static func authorize(_ completion: @escaping (AVAuthorizationStatus) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .notDetermined else { completion(status); return }
        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async { completion(AVCaptureDevice.authorizationStatus(for: .video)) }
        }
    }
    private static func schedule(_ seconds: TimeInterval, action: @escaping () -> Void) -> () -> Void {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        return { work.cancel() }
    }
}

/// Camera, the other source for Persona's one floating slot. It prepares and
/// runs the live camera bubble beside the artwork controls, using the same Size,
/// Position and Lock owners, so one place explains what is on screen.
struct PersonaCameraPanel: View {
    @ObservedObject var library: PersonaLibrary
    @ObservedObject var camera: PersonaLiveCamera

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "video.circle").font(.title3).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live Camera").font(.headline)
                    Text(camera.phase).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if camera.isStarting { ProgressView().controlSize(.small) }
            }
            Text(camera.explanation).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if camera.offersSourceChoice {
                Picker("Camera", selection: Binding(get: { camera.preparedSourceAvailable ? (camera.preparedID ?? camera.selectedID ?? "") : "" },
                                                    set: { camera.prepareDevice($0) })) {
                    if !camera.preparedSourceAvailable { Text("Choose a camera").tag("") }
                    ForEach(camera.sources) { Text($0.name).tag($0.id) }
                }.disabled(camera.isStarting)
                    .help("Choose a camera, then start or switch when ready.")
            } else if let name = camera.selectedName {
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading) { actions }
            }
            if camera.isLive || camera.isHidden { placement }
            if camera.isLive { effects }
            Text("Your saved personas stay unchanged. The bubble’s position resets when Workbench quits.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Workbench.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live Camera · " + (camera.status.isEmpty ? "not started" : camera.status))
    }

    /// One row that always keeps the next useful action reachable: Start, Cancel
    /// while it opens, Hide or Show camera again, Try again after a failure, and
    /// End camera whenever a visit exists.
    @ViewBuilder private var actions: some View {
        let visit = camera.visit
        switch camera.state {
        case .off:
            Button("Start Live Camera") { camera.perform(ifCurrent: visit) { library.startCamera() } }
                .buttonStyle(.borderedProminent).disabled(library.hasPreparedSession)
                .help("Opens this Mac’s camera and shows it in a floating bubble, in the shown card’s place. Your card stays up until the picture arrives.")
            if library.hasPreparedSession {
                Text("End the prepared overlay set first.").font(.caption).foregroundStyle(.secondary)
            }
        case .permission, .starting:
            Button("Cancel") { camera.perform(ifCurrent: visit) { library.endCamera() } }.keyboardShortcut(.cancelAction)
                .help("Stops opening the camera and leaves everything as it is")
        case .live:
            if camera.hasPreparedSwitch {
                Button("Switch camera") {
                    camera.perform(ifCurrent: visit) { library.startCamera(deviceID: camera.preparedID) }
                }.buttonStyle(.borderedProminent)
            }
            Button("Hide Live Camera") { camera.perform(ifCurrent: visit) { library.hideCamera() } }.buttonStyle(.borderedProminent)
                .help("Releases the camera and keeps the bubble’s place for Show Live Camera again")
        case .hidden:
            Button("Show Live Camera again") { camera.perform(ifCurrent: visit) { library.showCameraAgain() } }.buttonStyle(.borderedProminent)
                .help("Starts the same camera again and returns the bubble to its place")
        case .failed(let failure):
            if failure.offersRetry {
                Button("Try again") { camera.perform(ifCurrent: visit) { library.retryCamera() } }.buttonStyle(.borderedProminent)
            }
            if failure.offersCameraSettings {
                Button("Camera Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        if camera.isLive || camera.isHidden || camera.failure != nil {
            Button("End Live Camera") { camera.perform(ifCurrent: visit) { library.endCamera() } }
                .help("Releases the camera and this visit. Saved personas and layouts are untouched.")
        }
    }

    /// What this camera offers a presenter: Center Stage where it can frame you, and the
    /// system's Video menu for Portrait, Studio Light, Reactions and Background.
    @ViewBuilder private var effects: some View {
        let visit = camera.visit
        HStack(spacing: 12) {
            if camera.offersCenterStage {
                Toggle("Center Stage", isOn: Binding(get: { camera.centerStageOn },
                                                     set: { on in camera.perform(ifCurrent: visit) { camera.setCenterStage(on) } }))
                    .help("Keeps you framed as you move. macOS remembers it for Workbench, and the Video menu in the menu bar changes it too.")
            }
            Button("Video Effects…") { camera.perform(ifCurrent: visit) { camera.showVideoEffects() } }
                .help("Opens macOS’s Video menu: Portrait, Studio Light, Reactions, Background and more, for this camera")
        }
    }

    /// The same Size, Position and Lock owners the shown card uses, acting on
    /// the bubble while it is the live source.
    private var placement: some View {
        let visit = camera.visit
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Size \(Int((library.overlayWidth * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).frame(width: 58, alignment: .leading)
                Slider(value: Binding(get: { library.overlayWidth }, set: { if camera.visit == visit && library.cameraOwnsSlot { library.setOverlayWidth($0) } }), in: 0.06...0.40)
                    .accessibilityLabel("Size of Live Camera")
                Menu("Position") {
                    ForEach(FloatingControlAnchor.allCases, id: \.self) { anchor in
                        Button(anchor.title) { if camera.visit == visit && library.cameraOwnsSlot { library.setOverlayPosition(x: anchor.unitPoint.x, y: anchor.unitPoint.y) } }
                    }
                }.fixedSize().accessibilityLabel("Position of Live Camera")
            }
            Toggle("Lock Live Camera · clicks pass through", isOn: Binding(
                get: { library.overlayLocked }, set: { if camera.visit == visit && library.cameraOwnsSlot { library.setOverlayLocked($0) } }))
                .accessibilityLabel("Lock Live Camera so clicks pass through")
        }
    }
}
