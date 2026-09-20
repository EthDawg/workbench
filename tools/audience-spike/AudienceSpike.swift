import AppKit
import ScreenCaptureKit
import CoreImage
import CoreMedia

@main
struct AudienceSpike {
    @MainActor static func main() {
        let app = NSApplication.shared
        let controller = AudienceController()
        app.delegate = controller
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(controller) {}
    }
}

@MainActor
private final class AudienceController: NSObject, NSApplicationDelegate, NSWindowDelegate, SCContentSharingPickerObserver {
    private let audienceView = AudienceView()
    private var audienceWindow: NSWindow!
    private var controlWindow: NSWindow!
    private var chooseButton: NSButton!
    private var status: NSTextField!
    private var source: NSTextField!
    private var state = AudienceSessionState()
    private var pickerGeneration: UInt64?
    private var stream: SCStream?
    private var receiver: FrameReceiver?
    private var operation: Task<Void, Never>?
    private var sourceOwnerPIDs = Set<pid_t>()
    private var sourceDisplayID: CGDirectDisplayID?
    private var notifications: [NSObjectProtocol] = []
    private var quitting = false
    private var terminationReplied = false
    // SCStreamConfiguration's CGColor property is unowned; retain it for the
    // entire stream lifetime instead of assigning a temporary color object.
    private let captureBackground = CGColor(gray: 0.06, alpha: 1)

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeWindows()
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Audience Spike", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem); NSApp.mainMenu = menu
        SCContentSharingPicker.shared.add(self)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            notifications.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stop(message: "Stopped for sleep or session change. Choose demo windows again when ready.")
                }
            })
        }
        notifications.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      self.sourceOwnerPIDs.contains(app.processIdentifier) else { return }
                self.stop(message: "A selected demo application closed. Choose demo windows again.")
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.phase == .starting || self.state.phase == .live else { return }
                self.stop(message: "Display configuration changed. The output is blank; choose the intended demo display/windows again.")
            }
        })
        controlWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindows() {
        audienceWindow = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 960, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        audienceWindow.title = "Workbench Audience"
        audienceWindow.contentView = audienceView
        audienceWindow.isReleasedWhenClosed = false; audienceWindow.delegate = self
        audienceWindow.tabbingMode = .disallowed
        audienceWindow.minSize = CGSize(width: 480, height: 270)
        audienceWindow.backgroundColor = .black

        controlWindow = NSWindow(contentRect: CGRect(x: 170, y: 170, width: 570, height: 460),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        controlWindow.title = "Audience Spike · private controls"
        controlWindow.isReleasedWhenClosed = false; controlWindow.delegate = self
        controlWindow.tabbingMode = .disallowed
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let title = NSTextField(labelWithString: "Share one audience window")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        stack.addArrangedSubview(title)
        let explanation = label("Developer experiment. Choose exact demo windows using macOS, then select only ‘Workbench Audience’ in your meeting app. These controls stay separate. Whole-display or Workbench-application sharing is not private.")
        stack.addArrangedSubview(explanation)
        source = label("No source selected. Nothing is being captured.")
        source.font = .systemFont(ofSize: 12, weight: .medium); stack.addArrangedSubview(source)
        status = label("Ready. Capture begins only after you choose windows in the system picker.")
        stack.addArrangedSubview(status)
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 10
        chooseButton = NSButton(title: "Choose demo windows…", target: self, action: #selector(choose))
        buttons.addArrangedSubview(chooseButton)
        buttons.addArrangedSubview(NSButton(title: "Stop / blank", target: self, action: #selector(stopButton)))
        buttons.addArrangedSubview(NSButton(title: "Show audience", target: self, action: #selector(showAudience)))
        stack.addArrangedSubview(buttons)
        let limits = label("No sound, microphone, saved frames or network connection. Persona overlays are not included in this standalone spike. A selected window includes every tab and dialog inside that window. Use synthetic content first.")
        limits.font = .systemFont(ofSize: 11); limits.textColor = .secondaryLabelColor
        stack.addArrangedSubview(limits)
        controlWindow.contentView = stack
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.preferredMaxLayoutWidth = 522
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    @objc private func showAudience() { audienceWindow.makeKeyAndOrderFront(nil) }
    @objc private func stopButton() { stop(message: "Stopped. Audience output is blank.") }

    @objc private func choose() {
        guard !quitting, pickerGeneration == nil else { return }
        let token = state.choose()
        audienceView.clear(); source.stringValue = "No source selected."
        status.stringValue = "Choose one to eight demo windows on one display."
        chooseButton.isEnabled = false
        let stopped = stopCurrentStream()
        Task { [weak self] in
            await stopped.value
            guard let self, self.state.generation == token, self.state.phase == .choosing, !self.quitting else { return }
            let picker = SCContentSharingPicker.shared
            var configuration = SCContentSharingPickerConfiguration()
            configuration.allowedPickerModes = .multipleWindows
            configuration.allowsChangingSelectedContent = false
            configuration.excludedWindowIDs = NSApp.windows.filter { $0.windowNumber > 0 }.map { Int($0.windowNumber) }
            if let bundle = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [bundle] }
            picker.defaultConfiguration = configuration
            picker.maximumStreamCount = 1
            self.pickerGeneration = token
            picker.isActive = true
            picker.present(using: .window)
        }
    }

    private func accept(_ filter: SCContentFilter, for callbackStream: SCStream?) {
        guard let choice = pickerGeneration else { return }
        pickerGeneration = nil; chooseButton.isEnabled = true
        guard callbackStream == nil, state.generation == choice, state.phase == .choosing, !quitting else {
            status.stringValue = "Selection discarded. Audience output remains blank."; return
        }
        do {
            guard filter.style == .window || filter.style == .display else { throw AudienceSelectionError.broadScope }
            let windows = filter.includedWindows
            let selection = AudienceSelection(windows: windows.map { .init(id: $0.windowID, ownerPID: $0.owningApplication?.processID) },
                displayIDs: filter.includedDisplays.map(\.displayID), applicationCount: filter.includedApplications.count,
                isIndependentWindow: filter.style == .window)
            try selection.validate(ownPID: getpid())
            let size = filter.contentRect.size
            guard [size.width, size.height].allSatisfy({ $0.isFinite && $0 > 0 && $0 < 100_000 }) else {
                throw AudienceSelectionError.display
            }
            guard let token = state.start(selectionGeneration: choice) else { return }
            filter.includeMenuBar = false
            let configuration = SCStreamConfiguration()
            let scale = min(1, min(1920 / size.width, 1080 / size.height))
            configuration.width = max(2, Int(size.width * scale))
            configuration.height = max(2, Int(size.height * scale))
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 3
            configuration.backgroundColor = captureBackground
            configuration.preservesAspectRatio = true
            configuration.capturesAudio = false; configuration.captureMicrophone = false
            configuration.includeChildWindows = false
            configuration.showsCursor = true; configuration.showMouseClicks = false
            configuration.captureDynamicRange = .SDR
            configuration.streamName = "Workbench audience spike"
            sourceOwnerPIDs = Set(windows.compactMap { $0.owningApplication?.processID })
            sourceDisplayID = selection.displayIDs.first
            if let displayID = sourceDisplayID {
                source.stringValue = "Display \(displayID) · \(windows.count) explicitly selected window(s)"
            } else {
                source.stringValue = "One explicitly selected independent window · window \(windows[0].windowID)"
            }
            status.stringValue = "Starting. Output stays blank until a complete frame arrives."
            audienceWindow.orderFront(nil)
            let listener = FrameReceiver(onFrame: { [weak self] image in
                guard let self, self.state.completeFrame(token) else { return }
                self.audienceView.show(image)
                self.status.stringValue = "Live locally. Share only the ‘Workbench Audience’ window in Zoom/Teams. Receiver privacy has not been verified by this spike."
            }, onUnavailable: { [weak self] message in
                guard let self, self.state.acceptsFrames(token) else { return }
                self.stop(message: message)
            })
            let candidate = SCStream(filter: filter, configuration: configuration, delegate: listener)
            try candidate.addStreamOutput(listener, type: .screen, sampleHandlerQueue: listener.queue)
            stream = candidate; receiver = listener
            let previous = operation
            operation = Task { [weak self] in
                await previous?.value
                guard let self, self.state.acceptsFrames(token), !self.quitting else { return }
                do { try await candidate.startCapture() }
                catch {
                    guard self.state.acceptsFrames(token) else { return }
                    self.stop(message: "Capture could not start. \(error.localizedDescription) Nothing is shown; check macOS or organisation policy, then choose again.")
                }
            }
        } catch {
            stop(message: error.localizedDescription)
        }
    }

    /// The content view is cleared before awaiting ScreenCaptureKit teardown.
    private func stop(message: String) {
        state.stop(); audienceView.clear()
        status.stringValue = pickerGeneration == nil ? message : message + " Cancel or finish the system picker before choosing again; its result will be discarded."
        chooseButton.isEnabled = pickerGeneration == nil && !quitting
        _ = stopCurrentStream()
    }

    @discardableResult private func stopCurrentStream() -> Task<Void, Never> {
        let previous = operation, old = stream, oldReceiver = receiver
        stream = nil; receiver = nil; sourceOwnerPIDs.removeAll(); sourceDisplayID = nil
        oldReceiver?.invalidate()
        let task = Task {
            await previous?.value
            if let old {
                try? await old.stopCapture()
                if let oldReceiver { try? old.removeStreamOutput(oldReceiver, type: .screen) }
            }
        }
        operation = task
        return task
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in self?.accept(filter, for: stream) }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self, self.pickerGeneration != nil else { return }
            self.pickerGeneration = nil
            self.stop(message: "Selection cancelled. Nothing is being captured.")
        }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pickerGeneration = nil
            self.stop(message: "System picker unavailable: \(error.localizedDescription)")
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === controlWindow { NSApp.terminate(nil); return false }
        stop(message: "Audience window closed. Output stopped."); return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        quitting = true; stop(message: "Stopping…")
        SCContentSharingPicker.shared.remove(self); SCContentSharingPicker.shared.isActive = false
        let work = operation
        Task { [weak self] in
            await work?.value
            self?.finishTermination()
        }
        // A system teardown failure must not trap Quit. No output can survive
        // process exit; already queued callbacks were invalidated above.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finishTermination() }
        return .terminateLater
    }
    private func finishTermination() {
        guard !terminationReplied else { return }
        terminationReplied = true; NSApp.reply(toApplicationShouldTerminate: true)
    }
}

/// At most one rendered image waits for the main queue. No frame archive, audio
/// output, network transport or arbitrary shareable-content enumeration exists.
private final class FrameReceiver: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "workbench.audience-spike.frames")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var invalidated = false
    private var pendingFrame = false
    private let onFrame: @MainActor (CGImage) -> Void
    private let onUnavailable: @MainActor (String) -> Void
    init(onFrame: @escaping @MainActor (CGImage) -> Void, onUnavailable: @escaping @MainActor (String) -> Void) {
        self.onFrame = onFrame; self.onUnavailable = onUnavailable
    }
    func invalidate() { lock.lock(); invalidated = true; lock.unlock() }
    private var isInvalidated: Bool { lock.lock(); defer { lock.unlock() }; return invalidated }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !isInvalidated else { return }
        guard sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else {
            unavailable("Invalid frame metadata. Output stopped and blanked."); return
        }
        switch status {
        case .idle, .started: return
        case .blank, .suspended, .stopped:
            unavailable("Source is blank, suspended or stopped. Choose demo windows again."); return
        case .complete: break
        @unknown default: unavailable("Unsupported capture state. Output stopped."); return
        }
        lock.lock()
        guard !invalidated, !pendingFrame else { lock.unlock(); return }
        pendingFrame = true; lock.unlock()
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            lock.lock(); pendingFrame = false; lock.unlock()
            unavailable("Missing frame pixels. Output stopped."); return
        }
        let picture = CIImage(cvPixelBuffer: buffer)
        guard let image = context.createCGImage(picture, from: picture.extent) else {
            lock.lock(); pendingFrame = false; lock.unlock()
            unavailable("Could not render the selected source. Output stopped."); return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.isInvalidated { self.onFrame(image) }
            self.lock.lock(); self.pendingFrame = false; self.lock.unlock()
        }
    }
    private func unavailable(_ message: String) {
        invalidate()
        DispatchQueue.main.async { [weak self] in self?.onUnavailable(message) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        unavailable("Capture stopped: \(error.localizedDescription)")
    }
    func streamDidBecomeInactive(_ stream: SCStream) {
        unavailable("The selected windows are no longer available. Choose demo windows again.")
    }
}

private final class AudienceView: NSView {
    private var image: CGImage?
    override var isOpaque: Bool { true }
    func show(_ image: CGImage) { self.image = image; needsDisplay = true }
    func clear() { image = nil; needsDisplay = true; displayIfNeeded() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.06, alpha: 1).setFill(); bounds.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                      width: size.width, height: size.height))
    }
}
