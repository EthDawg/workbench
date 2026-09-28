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
            Text("Offer to transcribe when a supported Mac app, or a FaceTime or iPhone call answered on this Mac, appears to be using the microphone. Detection reads audio activity only; it never records or sends audio. You choose whether to start. Calls kept on your iPhone are not heard by this Mac.")
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
    var openHistory: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
                WorkbenchPageHeader("meeting", summary: "Choose the audio you want to keep. Recording starts only when you choose Start.")
                if let offer = model.offer {
                    HStack {
                        Label(MeetingDetector.offerTitle(for: offer), systemImage: "phone")
                        Spacer()
                        Button("Use this source") { model.useOffer(offer); model.dismissOffer() }
                        Button("Not now") { model.dismissOffer() }
                        Button("Snooze") { model.snoozeOffers() }
                    }.padding(12).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 10))
                }
                Group {
                    Picker("Purpose", selection: $model.purpose) {
                        Text("Meeting").tag("meeting")
                        Text("Call").tag("call")
                    }.pickerStyle(.segmented).fixedSize()
                    Picker("Mac app audio", selection: $model.selectedAppID) {
                        Text("Microphone only").tag(Int32?.none)
                        ForEach(model.apps) { app in Text(app.name).tag(Optional(app.id)) }
                    }
                    Toggle("Include current Mac microphone", isOn: $model.includeMicrophone)
                    HStack {
                        Button("Refresh audio apps") { model.refreshApps() }
                        Button("Open Sound settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!) }
                    }.font(.caption)
                }.disabled(model.isBusy)
                Text("Select the Mac app producing the call audio. A browser source can include its other tabs. Try a short sample with your headphone or routed phone setup first. Calls remaining on your phone are outside this capture.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Recordings are kept locally for recovery and transcribed with your selected speech engine. Allow up to two hours. Meeting speech stays reference material in handoffs.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if model.isStarting {
                        ProgressView().controlSize(.small)
                        Button("Cancel start") { Task { await model.cancel() } }
                    } else if model.isRecording {
                        Label("Recording · \(Int(model.elapsed) / 60):\(String(format: "%02d", Int(model.elapsed) % 60))", systemImage: "record.circle")
                            .foregroundStyle(.red).monospacedDigit()
                        Button("Stop & transcribe") { Task { await model.stop() } }.buttonStyle(.borderedProminent)
                        Button("Stop & keep for later") { Task { await model.cancel() } }
                    } else if model.isProcessing {
                        ProgressView().controlSize(.small)
                        Text("Transcribing saved audio…")
                        Button("Stop processing") { Task { await model.cancel() } }
                    } else {
                        Button("Start") { Task { await model.start() } }.buttonStyle(.borderedProminent)
                            .disabled(!model.includeMicrophone && model.selectedAppID == nil)
                        if model.hasRecovery { Button("Retry saved recording") { Task { await model.retry() } } }
                        Button("History", action: openHistory)
                    }
                }
                if !model.notice.isEmpty { Text(model.notice).font(.callout).textSelection(.enabled) }
                if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                Divider()
                MeetingDetectionSettings(model: model)
            }.padding(Workbench.pagePadding).frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear { model.refreshApps() }
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
