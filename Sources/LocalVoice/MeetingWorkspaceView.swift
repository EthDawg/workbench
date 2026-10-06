import AppKit
import Combine
import SwiftUI

struct MeetingQuickStatus: View {
    @ObservedObject var model: MeetingModel
    var review: () -> Void
    var body: some View {
        if model.isBusy {
            HStack {
                Button(model.isRecording ? "Meetings · " + model.voiceSession.recordingTitle.lowercased() : "Meetings · finishing", action: review)
                    .buttonStyle(.plain).font(.caption)
                Spacer()
                if model.isRecording {
                    Button("Finish meeting") { Task { await model.stop() } }.font(.caption).foregroundStyle(.red)
                } else {
                    Button("Stop processing") { Task { await model.cancel() } }.font(.caption)
                }
            }.padding(.vertical, 4)
        }
    }
}

struct MeetingDetectionSettings: View {
    @ObservedObject var model: MeetingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Detect Meetings & Calls", isOn: $model.detectionEnabled).toggleStyle(.switch)
            Text("Offer to transcribe when a supported call uses audio on this Mac. Detection checks activity only; you choose whether to record.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if #unavailable(macOS 14.2) {
                Text("Meeting detection and app audio capture require macOS 14.2 or later. Dictate remains available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct MeetingFinishSettings: View {
    @ObservedObject var model: MeetingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Finish when call audio ends", isOn: $model.automaticallyFinishCalls).toggleStyle(.switch)
            Text("After the selected call app stops using audio, a short countdown lets you keep recording. Silence, Pause and reconnecting audio never finish a session. Microphone-only recordings finish manually.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Meetings owns everything about recording a conversation: its sources, its offer to start
/// when a call begins, and the recordings it kept. A recording kept for later or left without
/// text is listed once with its own actions, so nothing waits behind an unexplained message.
struct MeetingWorkspaceView: View {
    @ObservedObject var model: MeetingModel
    var engineName: String
    var openHistory: (UUID?) -> Void
    /// The host resolves the committed UUID in History and returns any failure.
    var copyTranscript: (UUID) -> String? = { _ in "The transcript library is unavailable. Nothing was copied." }
    /// Where the speech engine is chosen and downloaded: Settings › Models.
    var openModels: () -> Void = {}
    var prepareFollowUp: (UUID) -> Void = { _ in }
    @State private var showingOptions = false
    @State private var showingSources = false
    @State private var showingNewRecording = false
    @StateObject private var copyFeedback = TranscriptReviewFeedback()

    private var showsCompletedResult: Bool { !model.isBusy && model.completedTranscriptID != nil && !showingNewRecording }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
                WorkbenchPageHeader("meeting", summary: "Follow the conversation. Keep the words and what comes next.") {
                    Button("History") { openHistory(nil) }
                }
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        Image(systemName: showsCompletedResult ? "checkmark.circle" : model.voiceSession.phase == .paused ? "pause.circle" : model.isRecording ? "record.circle.fill" : "person.2.wave.2")
                            .font(.system(size: 26)).foregroundStyle(model.isRecording && model.voiceSession.phase != .paused ? .red : Workbench.accent)
                            .frame(width: 48, height: 48).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(showsCompletedResult ? "Transcript saved" : model.isRecording ? model.voiceSession.recordingTitle : model.isProcessing ? "Finishing transcript" : model.isStarting ? "Starting recording" : model.admission.title)
                                .font(.title3.weight(.semibold))
                            Text(showsCompletedResult ? "Copy the complete transcript to use it in your next task." : model.isRecording ? time(model.elapsed) : model.isProcessing ? "Finishing your transcript." : "Start once. Follow the words as the conversation happens.")
                                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer()
                    }
                    if showsCompletedResult, let id = model.completedTranscriptID {
                        HStack(spacing: 12) {
                            Button("Copy transcript") {
                                if let problem = copyTranscript(id) { copyFeedback.finish(nil, problem: problem) }
                                else { copyFeedback.finish("Copied transcript") }
                            }.buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("meeting.copy-transcript")
                            Button("Review transcript") { openHistory(id) }
                            Button("Prepare follow-up…") { prepareFollowUp(id) }
                            Spacer()
                            Button("New recording…") { showingNewRecording = true }
                        }
                        if let problem = copyFeedback.problem {
                            Text(problem).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ConfirmationLabel(text: copyFeedback.confirmation?.kind, reserving: ["Copied transcript"])
                        }
                        ForEach(model.pendingTranscriptNotes, id: \.self) { note in
                            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Divider()
                        if model.isBusy {
                            LiveVoiceSourcesView(sources: model.voiceSession.sources)
                        } else if let offer = model.offer, !showingSources {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Label(MeetingDetector.offerTitle(for: offer), systemImage: "phone")
                                    Text(offer.name + (model.includeMicrophone ? " + your microphone" : " · app audio only"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Change source") {
                                    model.useOffer(offer); model.dismissOffer(); showingSources = true
                                }
                            }
                        } else { sources }
                        HStack(spacing: 12) {
                            transport
                            Spacer()
                            Text("Up to 2 hours").font(.caption).foregroundStyle(.secondary)
                        }.controlSize(.large)
                    }
                    if let seconds = model.autoFinishSeconds {
                        HStack {
                            Label("Call audio ended · finishing in \(seconds)s", systemImage: "clock")
                                .font(.callout).monospacedDigit()
                            Spacer()
                            Button("Keep recording") { model.keepRecording() }
                        }.padding(12).background(Workbench.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityIdentifier("meeting.auto-finish")
                    }
                    if (model.isBusy && (!model.isProcessing || !model.voiceSession.segments.isEmpty)) || model.completedTranscriptID != nil {
                        Divider()
                        LiveVoiceTranscriptView(snapshot: transcriptSnapshot, conversation: true,
                                                completedText: model.completedTranscriptID != nil ? model.completedTranscriptText : nil)
                    }
                    // Progress belongs beside the control that started it.
                    if model.isStarting || model.isProcessing {
                        Text(model.notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Label(engineName, systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
                        Button("Models…", action: openModels).buttonStyle(.link).font(.caption)
                    }
                }.padding(22).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("meeting.recording")

                if let problem = model.problem ?? (model.isBusy ? nil : model.admission.captureProblem) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                        Text(problem.message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            if problem.opensMicrophoneSettings {
                                Button("Microphone Settings…", action: model.openMicrophoneSettings).controlSize(.small)
                                    .help("Open Privacy & Security › Microphone in System Settings")
                            }
                            if problem.opensAudioSettings {
                                Button("Audio Recording Settings…", action: model.openAudioRecordingSettings).controlSize(.small)
                            }
                            if [.microphoneDenied, .microphoneRestricted, .microphoneUnconfirmed].contains(problem), model.canUseAppAudioOnly {
                                Button("Use app audio only", action: model.useAppAudioOnly).controlSize(.small).disabled(model.isBusy)
                            }
                            if model.selectedAppID != nil {
                                switch problem {
                                case .appAudioUnavailable, .appAudioPermission, .appAudioUnknown, .sourceProbe, .sourceDisappeared:
                                    Button("Use microphone only", action: model.useMicrophoneOnly).controlSize(.small).disabled(model.isBusy)
                                default: EmptyView()
                                }
                            }
                        }
                        if model.problem != nil {
                            Button { model.dismissError() } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).accessibilityLabel("Dismiss meeting problem")
                        }
                    }.padding(14).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                }
                if !model.isBusy, let kept = model.keptWithoutSpeech {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "waveform.slash").foregroundStyle(.secondary).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No speech heard").font(Workbench.sectionTitle)
                            Text(kept.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 12) {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([kept.session]) }
                                Button("Move to Trash") { Task { await model.moveRecordingToTrash(kept.session) } }
                            }.controlSize(.small).padding(.top, 4)
                        }
                        Spacer()
                        Button { model.dismissKeptWithoutSpeech() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss")
                    }.padding(16).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                if !model.recoveries.isEmpty {
                    keptForLater
                }
                if !model.isBusy, let receipt = model.receipt {
                    Label(receipt, systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Recording options", isExpanded: $showingOptions) {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Save as", selection: $model.purpose) {
                            Text("Meeting").tag("meeting")
                            Text("Call").tag("call")
                        }.pickerStyle(.segmented).fixedSize().disabled(model.isBusy)
                        MeetingDetectionSettings(model: model)
                        MeetingFinishSettings(model: model)
                        Button("Open Sound settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!) }
                        Text("Audio is kept on this Mac for recovery. Try a short sample before an important call. Calls that stay on your phone cannot be captured here.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.top, 12)
                }.font(.callout)
            }.padding(Workbench.pagePadding).frame(maxWidth: 960, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }.onAppear { if !model.isBusy { model.refreshApps() } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshAdmission() }
            .onChange(of: model.completedTranscriptID) { value in
                copyFeedback.finish(nil)
                if value != nil { showingNewRecording = false }
            }
    }

    private var transcriptSnapshot: LiveVoiceSnapshot {
        var value = model.voiceSession
        if model.completedTranscriptID != nil { value.phase = .completed; value.message = "Saved in History." }
        else if model.isProcessing { value.message = "Finishing your transcript." }
        return value
    }

    /// One label column, so the source, its microphone choice and their note line up.
    private var sources: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                Text("Audio source")
                HStack(spacing: 8) {
                    Picker("Audio source", selection: Binding(get: { model.selectedAppID }, set: model.selectAudioSource)) {
                        Text("Microphone only").tag(Int32?.none)
                        ForEach(model.apps) { app in Text(app.name).tag(Optional(app.id)) }
                    }.labelsHidden().fixedSize()
                    Button { model.refreshApps() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh audio apps").accessibilityLabel("Refresh audio apps")
                }
            }
            if model.selectedAppID != nil {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Toggle("Include my microphone", isOn: $model.includeMicrophone)
                }
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Text(model.selectedAppID == nil
                     ? "Microphone only records what this Mac can hear. Choose the call app to include people speaking through headphones."
                     : model.apps.first(where: { $0.id == model.selectedAppID }).map { MeetingAppCatalogue.known($0.bundleID)?.kind == .browser } == true
                        ? "A browser source can include audio from its other tabs."
                        : "Records this app’s audio, including voices heard through headphones.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Every recording that still holds audio without text, newest first, each with its own
    /// actions. Transcribe works on that row's recording, never on whichever sorts first.
    private var keptForLater: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkbenchSectionTitle("Kept for later")
            ForEach(model.recoveries) { entry in
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: entry.isReadable ? "waveform" : "exclamationmark.triangle").foregroundStyle(entry.isReadable ? Workbench.accent : .orange)
                        .frame(width: 20).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.title(entry)).font(.callout.weight(.medium))
                        Text(entry.manifest.map(Self.detail) ?? entry.problem ?? "This recording could not be read.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if entry.canSaveTranscript {
                            Text("Complete text is ready to save; no model or microphone is needed.").font(.caption).foregroundStyle(.secondary)
                        }
                        if entry.checkpoint?.originalsAvailable == false {
                            Text(entry.canSaveTranscript ? "Original audio is missing; playback and retranscription are unavailable." : "Original audio is missing. The incomplete checkpoint is kept for review.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if entry.isReadable {
                        Button(entry.canSaveTranscript ? "Save transcript" : "Transcribe") { Task { await model.retry(entry) } }
                            .disabled(model.isBusy || (!entry.canSaveTranscript && (model.admission.recognitionProblem != nil || entry.checkpoint?.originalsAvailable == false)))
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.session]) }
                    Button("Move to Trash") { Task { await model.moveRecordingToTrash(entry.session) } }.disabled(model.isBusy)
                }.controlSize(.small).padding(12).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityElement(children: .contain).accessibilityLabel(Self.title(entry))
            }
        }
    }

    private static func title(_ entry: MeetingRecoveryEntry) -> String {
        guard let manifest = entry.manifest else { return "Unreadable recording" }
        let kind = manifest.purpose == "call" ? "Call" : "Meeting"
        return manifest.appName.map { "\(kind) · \($0)" } ?? kind
    }

    private static func detail(_ manifest: MeetingManifest) -> String {
        manifest.createdAt.formatted(date: .abbreviated, time: .shortened) + " · " + time(manifest.seconds)
    }

    @ViewBuilder private var transport: some View {
        if model.isStarting {
            ProgressView().controlSize(.small)
            Button("Cancel start") { Task { await model.cancel() } }
        } else if model.isRecording {
            Button("Finish meeting") { Task { await model.stop() } }.buttonStyle(.borderedProminent)
            if model.voiceSession.phase == .paused {
                Button("Resume") { Task { await model.resume() } }
            } else {
                Button("Pause") { Task { await model.pause() } }.disabled(model.voiceSession.phase == .reconnecting)
            }
            Menu("More") { Button("Stop & keep for later") { Task { await model.cancel() } } }
        } else if model.isProcessing {
            ProgressView().controlSize(.small)
            Button("Stop processing") { Task { await model.cancel() } }
        } else {
            Button {
                let offered = showingSources ? nil : model.offer
                Task {
                    if let offered { await model.startOffered(offered) }
                    else { await model.start() }
                }
            } label: { Label("Start recording", systemImage: "record.circle") }
                .buttonStyle(.borderedProminent).disabled(!model.admission.canStart)
                .accessibilityIdentifier("meeting.start")
        }
    }
}

/// A passive offer never takes focus or opens a microphone. Start is explicit
/// and bound to the exact displayed source; Review still allows source changes.
@MainActor
final class MeetingOfferPanelController {
    struct Actions {
        var start: () -> Void
        var review: () -> Void
        var dismiss: () -> Void
        var snooze: () -> Void
    }
    typealias Present = (MeetingAudioApp, Actions) -> () -> Void
    typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> Void

    private var observation: AnyCancellable?
    private var closePanel: (() -> Void)?
    private var displayedOffer: MeetingAudioApp?
    private var generation = UUID()

    /// Rendering and time are injectable so checks exercise the actual published
    /// offer lifecycle without opening windows, audio or device metadata.
    init(model: MeetingModel, present: Present? = nil, schedule: Schedule? = nil,
         review: @escaping () -> Void) {
        let present: Present = present ?? Self.presentPanel
        let schedule: Schedule = schedule ?? { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() }
        }
        observation = model.$offer.sink { [weak self, weak model] offer in
            guard let self else { return }
            guard let offer, let model, !model.isBusy else {
                self.hidePanel(); self.displayedOffer = nil
                return
            }
            // Repeated polls must preserve both a visible offer and an offer
            // already timed out. A changed/absent offer starts a new lifetime.
            guard self.displayedOffer != offer else { return }
            self.hidePanel()
            self.displayedOffer = offer
            let token = self.generation
            self.closePanel = present(offer, Actions(
                start: { [weak model] in
                    Task { [weak model] in
                        guard let model else { return }
                        await model.startOffered(offer)
                        review()
                    }
                },
                review: { [weak model] in
                    guard let model else { return }
                    model.useOffer(offer); model.dismissOffer(); review()
                },
                dismiss: { [weak model] in model?.dismissOffer() },
                snooze: { [weak model] in model?.snoozeOffers() }
            ))
            schedule(20) { [weak self] in
                guard let self, self.generation == token else { return }
                self.hidePanel()
            }
        }
    }

    private func hidePanel() {
        generation = UUID()
        closePanel?(); closePanel = nil
    }

    func close() {
        observation = nil
        hidePanel(); displayedOffer = nil
    }

    private static func presentPanel(offer: MeetingAudioApp, actions: Actions) -> () -> Void {
        let bounds = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let panel = NSPanel(contentRect: NSRect(x: bounds.maxX - 365, y: bounds.minY + 25, width: 340, height: 145),
            styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: false)
        panel.title = "Workbench"; panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
            Label(MeetingDetector.offerTitle(for: offer), systemImage: "phone").font(.headline)
            Text(offer.name + " · Review to adjust the microphone before starting.").font(.callout)
            HStack {
                Button("Start recording", action: actions.start).buttonStyle(.borderedProminent)
                Button("Review", action: actions.review)
                Button("Not now", action: actions.dismiss)
                Button("Snooze", action: actions.snooze)
            }
        }.padding(18))
        panel.orderFrontRegardless()
        return { panel.orderOut(nil) }
    }
}
