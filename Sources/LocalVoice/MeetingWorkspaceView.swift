import AppKit
import Combine
import SwiftUI

struct MeetingQuickStatus: View {
    @ObservedObject var model: MeetingModel
    var review: () -> Void
    var body: some View {
        if model.isBusy {
            HStack {
                Button(model.isRecording ? "Meeting · recording" : "Meeting · processing", action: review)
                    .buttonStyle(.plain).font(.caption)
                Spacer()
                if model.isRecording {
                    Button("Stop") { Task { await model.stop() } }.font(.caption).foregroundStyle(.red)
                } else {
                    Button("Cancel") { Task { await model.cancel() } }.font(.caption)
                }
            }.padding(.vertical, 4)
        }
    }
}

struct MeetingDetectionSettings: View {
    @ObservedObject var model: MeetingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Detect Meetings & Calls", isOn: $model.detectionEnabled)
            Text("Offer to transcribe when a supported call uses audio on this Mac. Detection checks activity only; you choose whether to record.")
                .font(.caption).foregroundStyle(.secondary)
            if #unavailable(macOS 14.2) {
                Text("Meeting detection and app audio capture require macOS 14.2 or later. Dictate remains available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct MeetingWorkspaceView: View {
    @ObservedObject var model: MeetingModel
    var engineName: String
    var openHistory: (UUID?) -> Void
    @State private var showingOptions = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                WorkbenchPageHeader("meeting", summary: "Transcribe a meeting or call.") {
                    Button("History") { openHistory(nil) }
                }
                if let offer = model.offer {
                    HStack(spacing: 12) {
                        Label(MeetingDetector.offerTitle(for: offer), systemImage: "phone")
                        Spacer()
                        Button("Use this source") { model.useOffer(offer); model.dismissOffer() }
                        Button("Not now") { model.dismissOffer() }
                        Button("Snooze") { model.snoozeOffers() }
                    }.padding(14).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        Image(systemName: model.isRecording ? "record.circle.fill" : "person.2.wave.2")
                            .font(.system(size: 26)).foregroundStyle(model.isRecording ? .red : Workbench.accent)
                            .frame(width: 48, height: 48).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.isRecording ? "Recording conversation" : model.isProcessing ? "Transcribing your recording" : model.isStarting ? "Starting recording" : "Choose what to record")
                                .font(.title3.weight(.semibold))
                            Text(model.isRecording ? time(model.elapsed) : model.isProcessing ? "You can keep working while this finishes." : "App audio, your microphone, or both.")
                                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer()
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text("Audio source").frame(width: 100, alignment: .leading)
                            Picker("Audio source", selection: Binding(get: { model.selectedAppID }, set: model.selectAudioSource)) {
                                Text("Microphone only").tag(Int32?.none)
                                ForEach(model.apps) { app in Text(app.name).tag(Optional(app.id)) }
                            }.labelsHidden().frame(maxWidth: 360)
                            Button { model.refreshApps() } label: { Image(systemName: "arrow.clockwise") }
                                .help("Refresh audio apps").accessibilityLabel("Refresh audio apps")
                            Spacer(minLength: 0)
                        }
                        if model.selectedAppID != nil {
                            Toggle("Include my microphone", isOn: $model.includeMicrophone)
                                .padding(.leading, 116)
                        }
                        if model.selectedAppID == nil {
                            Text("Microphone only records what this Mac can hear. Choose the call app to include people speaking through headphones.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("A browser source can include audio from its other tabs.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(model.isBusy)
                    HStack(spacing: 12) {
                        transport
                        Spacer()
                        Text("Up to 2 hours").font(.caption).foregroundStyle(.secondary)
                    }.controlSize(.large)
                    Label(engineName, systemImage: "waveform")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(22).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("meeting.recording")

                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                if !model.isBusy, let id = model.completedTranscriptID {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle").foregroundStyle(Workbench.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Transcript saved").font(Workbench.sectionTitle)
                            Text("Review, copy or prepare follow-up notes in History.").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Review transcript") { openHistory(id) }
                    }.padding(18).background(Workbench.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                if model.isStarting || model.isProcessing || model.error != nil || model.hasRecovery || !model.pendingTranscriptNotes.isEmpty {
                    Text(model.notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if model.hasRecovery && !model.isBusy {
                    HStack(spacing: 12) {
                        Label("Unfinished recording", systemImage: "waveform")
                        Spacer()
                        Button("Retry saved recording") { Task { await model.retry() } }
                    }.padding(16).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                DisclosureGroup("Recording options", isExpanded: $showingOptions) {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Save as", selection: $model.purpose) {
                            Text("Meeting").tag("meeting")
                            Text("Call").tag("call")
                        }.pickerStyle(.segmented).fixedSize().disabled(model.isBusy)
                        Button("Open Sound settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!) }
                        Text("Audio is kept on this Mac for recovery. Try a short sample before an important call. Calls that stay on your phone cannot be captured here.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.top, 12)
                }.font(.callout)
            }.padding(Workbench.pagePadding).frame(maxWidth: 960, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }.onAppear { if !model.isBusy { model.refreshApps() } }
    }

    @ViewBuilder private var transport: some View {
        if model.isStarting {
            ProgressView().controlSize(.small)
            Button("Cancel start") { Task { await model.cancel() } }
        } else if model.isRecording {
            Button("Stop & transcribe") { Task { await model.stop() } }.buttonStyle(.borderedProminent)
            Button("Stop & keep for later") { Task { await model.cancel() } }
        } else if model.isProcessing {
            ProgressView().controlSize(.small)
            Button("Stop processing") { Task { await model.cancel() } }
        } else {
            Button { Task { await model.start() } } label: { Label("Start recording", systemImage: "record.circle") }
                .buttonStyle(.borderedProminent).disabled(!model.includeMicrophone && model.selectedAppID == nil)
                .accessibilityIdentifier("meeting.start")
        }
    }
}

/// A passive offer never takes focus or opens a microphone. Its Review action
/// returns to the explicit source/Start controls.
@MainActor
final class MeetingOfferPanelController {
    struct Actions {
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
            Text("Would you like to transcribe? Nothing is recording.").font(.callout)
            HStack {
                Button("Review", action: actions.review)
                Button("Not now", action: actions.dismiss)
                Button("Snooze", action: actions.snooze)
            }
        }.padding(18))
        panel.orderFrontRegardless()
        return { panel.orderOut(nil) }
    }
}
