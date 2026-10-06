import AppKit
import AVFoundation
import SwiftUI
import StageKit

// Report a problem (#296): the modeless composer window, its door beside Dictate and Snap
// problems, and AppDelegate's wiring of the shared owners it borrows.

/// Asks AppDelegate to open the composer with this origin. Views raise it without knowing the host.
enum BugReportRequest {
    static let name = Notification.Name("com.ethdawg.workbench.report-problem")
    @MainActor static func post(_ origin: BugReportOrigin) { NotificationCenter.default.post(name: name, object: Box(origin)) }
    final class Box { let origin: BugReportOrigin; init(_ origin: BugReportOrigin) { self.origin = origin } }
}

/// The same door as Help › Report a problem…, beside a recoverable Dictate or Snap problem. It
/// carries the problem's typed code, never its words.
struct ReportProblemButton: View {
    let origin: BugReportOrigin
    var body: some View {
        Button("Report a problem…") { BugReportRequest.post(origin) }
            .controlSize(.small)
            .help("Send this problem to the Workbench team, with a screenshot or voice note if you like")
    }
}

struct BugReportView: View {
    @ObservedObject var model: BugReportModel
    /// The gallery draws the whole composer at once; the window scrolls.
    var scrolls = true
    @State private var showDetails: Bool
    @State private var removing: BugReportReceipt?

    init(model: BugReportModel, scrolls: Bool = true, expandDetails: Bool = false) {
        self.model = model; self.scrolls = scrolls
        _showDetails = State(initialValue: expandDetails)
    }

    var body: some View {
        Group {
            if scrolls { ScrollView { content } } else { content }
        }
        .frame(minWidth: 420)
        .background(Workbench.background)
        .tint(Workbench.accent)
        .workbenchTheme()
        .confirmationDialog(removing.map { removalTitle($0) } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { receipt in
            Button("Remove from this Mac", role: .destructive) { model.perform(.remove, on: receipt.id); removing = nil }
            Button("Keep", role: .cancel) { removing = nil }
        } message: { receipt in Text(removalMessage(receipt)) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tell the Workbench team what went wrong. A screenshot or a short voice note can help.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(model.receipts) { receipt in receiptRow(receipt) }
            explanation
            evidence
            email
            inclusion
            if let problem = model.problem, !model.problemNearEvidence { problemRow(problem) }
            if let note = model.note {
                Label(note, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
            }
            footer
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Words

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What went wrong?").font(Workbench.sectionTitle)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.explanation)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .accessibilityLabel("What went wrong?")
                    .accessibilityHint("What were you trying to do, and what happened instead?")
                if model.explanation.isEmpty {
                    Text("What were you trying to do, and what happened instead?")
                        .foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .frame(height: 132)
            .background(Workbench.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.explanationProblem == nil ? Workbench.border : Color.red.opacity(0.7)))
            HStack(alignment: .firstTextBaseline) {
                if let problem = model.explanationProblem {
                    Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let counter = model.counter {
                    Text(counter).font(.caption.monospacedDigit())
                        .foregroundStyle(model.explanationProblem == nil ? Color.secondary : Color.red)
                        .accessibilityLabel("\(model.explanation.unicodeScalars.count) of 2,048 characters")
                }
            }
        }
    }

    // MARK: Screenshot and voice note

    private var evidence: some View {
        VStack(alignment: .leading, spacing: 10) {
            screenshotRow
            Divider()
            voiceRow
            if let problem = model.problem, model.problemNearEvidence { problemRow(problem) }
        }
        .reportCard(padding: 12)
    }

    @ViewBuilder private var screenshotRow: some View {
        if let info = model.screenshot {
            HStack(alignment: .center, spacing: 12) {
                if let preview = model.screenshotPreview {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 120, maxHeight: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Workbench.border))
                        .accessibilityLabel("Screenshot to send, \(info.width) by \(info.height) pixels")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Screenshot").font(.callout.weight(.medium))
                    Text("\(info.width) × \(info.height) pixels").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Replace") { Task { await model.addScreenshot() } }.disabled(model.isBusy)
                        Button("Remove") { model.removeScreenshot() }.disabled(model.capturing)
                    }.controlSize(.small)
                }
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 10) {
                Button { Task { await model.addScreenshot() } } label: { Label("Add screenshot", systemImage: "camera.viewfinder") }
                    .disabled(model.isBusy)
                    .help("Drag across the part of the screen to show. Only this window hides while you choose.")
                if model.capturing { Text("Choose an area. Escape cancels.").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private var voiceRow: some View {
        if model.recording {
            HStack(spacing: 10) {
                Circle().fill(Color.red).frame(width: 9, height: 9).accessibilityHidden(true)
                Text("Recording \(Self.time(model.recordingElapsed)) of 1:00").font(.callout.monospacedDigit())
                Spacer(minLength: 8)
                Button("Stop recording") { model.stopRecording() }.keyboardShortcut(.cancelAction)
            }
        } else if let seconds = model.voiceSeconds {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").foregroundStyle(Workbench.accent).accessibilityHidden(true)
                    Text("Voice note · \(Self.time(seconds))").font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    Button(model.playing ? "Pause" : "Play") { model.togglePlayback() }
                    Button("Remove") { model.removeVoice() }
                    if model.canTranscribe { Button("Transcribe") { Task { await model.transcribeVoice() } } }
                }.controlSize(.small)
                if model.transcribing {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Transcribing on this Mac…").font(.caption).foregroundStyle(.secondary) }
                }
                if let transcript = model.transcript {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(transcript).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Button("Add to description") { model.addTranscript() }.controlSize(.small)
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Workbench.background, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        } else {
            HStack(spacing: 10) {
                Button { Task { await model.toggleRecording() } } label: { Label("Record voice note", systemImage: "mic") }
                    .disabled(model.capturing)
                    .help("Up to one minute. The recording is sent as it is, so the team can listen to it.")
                Text("Up to 1 minute").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Email and what is sent

    private var email: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Email me about this (optional)").font(.callout.weight(.medium))
            TextField("Your email address", text: $model.replyEmail)
                .textFieldStyle(.roundedBorder).textContentType(.emailAddress)
                .accessibilityLabel("Email me about this (optional)")
            if let problem = model.emailProblem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
    }

    private var inclusion: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.available ? "This report goes privately to the Workbench team." : "Nothing is sent from this build.", systemImage: "lock")
                .font(.callout.weight(.medium))
            Text(model.inclusionSummary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Details", isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView {
                        Text(model.detailsJSON).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .frame(height: 160)
                    .reportCard(padding: 0)
                    Text(detailsNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 4)
            }.font(.caption)
        }
    }

    private var detailsNote: String {
        guard model.available else {
            return "This is context.json. Save a copy puts it in a new folder with your screenshot and voice note. No other files, titles, names or history from this Mac are included."
        }
        var text = "This is context.json, sent with your words, screenshot and voice note to the team's private Sentry inbox, where reports are kept for 30 days. No other files, titles, names or history from this Mac are included. The report number is replaced when you send."
        if model.destination?.isOverride == true { text += " Test build: reports go to the preview environment." }
        return text
    }

    // MARK: Problems and actions

    private func problemRow(_ problem: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(problem).font(.callout).fixedSize(horizontal: false, vertical: true)
                switch model.problemAction {
                case .chooseImage: Button("Choose image…") { model.chooseImage() }.controlSize(.small)
                case .microphoneSettings: Button("Microphone Settings…") { model.services.openMicrophoneSettings() }.controlSize(.small)
                case .saveCopy, nil: EmptyView()
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.available {
                Text("Sending reports isn't available in this build. Save a copy to keep your words, screenshot and voice note together for the Workbench team.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.available && model.problemAction == .saveCopy {
                    Button("Save a copy…") { model.saveDraftCopy() }.disabled(!model.canSubmit)
                }
                Spacer()
                if model.available {
                    Button("Send report") { model.send() }
                        .keyboardShortcut(.defaultAction).disabled(!model.canSend)
                } else {
                    Button("Save a copy…") { model.saveDraftCopy() }
                        .keyboardShortcut(.defaultAction).disabled(!model.canSubmit)
                }
            }
        }
    }

    // MARK: Receipts

    private func receiptRow(_ receipt: BugReportReceipt) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                switch receipt.tone {
                case .progress: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .problem: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }.frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(receipt.title).font(.callout.weight(.semibold))
                Text(receipt.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ForEach(receipt.actions, id: \.self) { action in
                        switch action {
                        case .retry: Button("Retry") { model.perform(.retry, on: receipt.id) }
                        case .sendAgain: Button("Send again") { model.perform(.sendAgain, on: receipt.id) }
                        case .saveCopy: Button("Save a copy…") { model.perform(.saveCopy, on: receipt.id) }
                        case .remove: Button("Remove…") { removing = receipt }
                        }
                    }
                }.controlSize(.small).padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .reportCard(padding: 10)
        .accessibilityElement(children: .contain)
    }

    private func removalTitle(_ receipt: BugReportReceipt) -> String {
        receipt.tone == .done ? "Remove this receipt from this Mac?" : "Remove this report from this Mac?"
    }
    private func removalMessage(_ receipt: BugReportReceipt) -> String {
        receipt.tone == .done
            ? "The Workbench team's copy stays for 30 days. To have it deleted sooner, send a report that asks and quotes \(BugReportText.shortID(receipt.id))."
            : "Its words, screenshot and voice note are deleted from this Mac. If Workbench was already sending it, the team may still receive it."
    }

    static func time(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}

extension BugReportReceipt.Action: Hashable {}

private extension View {
    /// A grouped area that reads in light and dark, whatever the window background is.
    func reportCard(padding: CGFloat) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Workbench.border))
    }
}

/// The composer's window: titled, modeless and kept while hidden, so the draft and receipts stay put.
@MainActor
final class BugReportWindowController: NSWindowController, NSWindowDelegate {
    let model: BugReportModel

    init(model: BugReportModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Report a problem"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 460)
        window.contentViewController = NSHostingController(rootView: BugReportView(model: model))
        window.setContentSize(NSSize(width: 480, height: 680))
        window.center()
        window.setFrameAutosaveName("Workbench.ReportProblem")
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { nil }

    func present() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing keeps the draft. A recording in progress is stopped and kept.
    func windowWillClose(_ notification: Notification) {
        if model.recording { model.stopRecording() }
        model.stopPlayback()
        model.persist()
    }
}

// MARK: Host wiring

extension AppDelegate {
    /// The one report owner: the edition's report folder, delivery and the shared admissions.
    func makeBugReports() -> BugReportModel {
        let build = WorkbenchBuild()
        let store = BugReportStore(root: Workbench.supportDirectory(component: "Reports"))
        let transport = BugReportTransport(store: store, client: "workbench-mac/" + BugReportText.safe(build.info["CFBundleShortVersionString"] as? String, limit: 32))
        var services = BugReportModel.Services()
        services.context = { [weak self] origin in self?.bugReportContext(origin) ?? BugReportContext(surface: origin.surface, errorCode: origin.errorCode) }
        services.screenshotAdmission = { [weak self] in
            guard let self, !self.isTerminatingForReports else { return "Workbench is closing." }
            if self.shortcutsSuspended { return "Finish changing the shortcut first." }
            return self.snap.isCapturing || self.readback.isCapturing || self.stage.isTakingScreenshot
                ? "Finish the current screen capture first." : nil
        }
        services.captureScreenshot = { [weak self] in
            guard let self else { return nil }
            let source = SnapCapture()
            self.bugReportCapture = source
            // Only the report window hides; the Workbench window and controls stay where they are.
            self.bugReportWindow?.window?.orderOut(nil)
            defer { self.bugReportCapture = nil; self.bugReportWindow?.present() }
            try await Task.sleep(nanoseconds: source.settleDelay)
            guard let data = try await source.capture(.region) else { return nil }
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            return try BugReportMedia.image(data, scale: Double(screen?.backingScaleFactor ?? 2), sourceLimit: SnapStore.maximumImageBytes)
        }
        services.cancelScreenshot = { [weak self] in self?.bugReportCapture?.cancel() }
        services.chooseImage = {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.png, .jpeg]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
            panel.message = "Choose a PNG or JPEG to send with the report."
            return panel.runModal() == .OK ? panel.url : nil
        }
        services.chooseFolder = {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false; panel.prompt = "Save Copy Here"
            panel.message = "Workbench saves the report in a new folder here."
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            return panel.runModal() == .OK ? panel.url : nil
        }
        services.reveal = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        services.microphoneAdmission = { [weak self] in
            guard let self, !self.isTerminatingForReports else { return "Workbench is closing." }
            if self.model.phase != .idle { return "Finish dictation before recording a voice note." }
            if self.model.meetings.isRecording || self.model.meetings.isStarting { return "Finish the meeting recording before recording a voice note." }
            if self.readback.isRecording || self.readback.isCapturing { return "Finish the Snap & Talk capture before recording a voice note." }
            if self.shortcutsSuspended { return "Finish changing the shortcut first." }
            return nil
        }
        services.openMicrophoneSettings = {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
        services.transcriptionReady = { [weak self] in
            guard let self else { return false }
            return self.model.recognition.canTranscribe && self.model.phase == .idle && !self.model.meetings.isBusy
                && !self.readback.isRecording && !self.readback.hasPendingTranscriptions
        }
        services.transcribe = { [weak self] url in
            guard let self else { throw BugReportError.message("Workbench is closing.") }
            return try await self.model.engine.transcribe(url)
        }
        services.onBusyChange = { [weak self] in self?.updateRecordingUI() }
        services.currentDestination = { BugReportConfiguration.destination(build: build) }
        let reports = BugReportModel(store: store, transport: transport, destination: BugReportConfiguration.destination(build: build),
                                     recorder: BugReportRecorder(), services: services)
        transport.start()
        return reports
    }

    /// Opens the composer, recording its context first, before the window takes focus.
    func openBugReport(_ origin: BugReportOrigin) {
        guard let bugReports else { return }
        bugReports.open(origin: origin)
        if bugReportWindow == nil { bugReportWindow = BugReportWindowController(model: bugReports) }
        bugReportWindow?.present()
    }

    /// The allowlisted facts the brief names, from the owners' current state. Nothing is
    /// requested: permission states are read passively, and a plain false stays unknown.
    func bugReportContext(_ origin: BugReportOrigin) -> BugReportContext {
        var context = BugReportContext(surface: origin.surface, errorCode: origin.errorCode)
        var tools: [BugReportTool] = []
        if model.phase != .idle { tools.append(.dictate) }
        if model.meetings.isBusy { tools.append(.meetings) }
        if snap.isBusy { tools.append(.snap) }
        if readback.isRecording || readback.isCapturing || readback.hasPendingTranscriptions { tools.append(.readback) }
        if stage.isDrawing { tools.append(.draw) }
        if stage.isPresenting { tools.append(.present) }
        if stage.hasActivePersona { tools.append(.persona) }
        if stage.hasActiveTimer { tools.append(.timer) }
        context.activeTools = tools
        context.microphone = BugReportPermission(AVCaptureDevice.authorizationStatus(for: .audio))
        context.screenCapture = BugReportPermission(granted: CGPreflightScreenCaptureAccess())
        context.accessibility = BugReportPermission(granted: model.accessibilityGranted)
        context.recognitionProvider = model.recognition.configuration.provider == .parakeet ? .parakeet : .localServer
        context.recognitionReady = model.recognition.canTranscribe
        return context
    }
}
