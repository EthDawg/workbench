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
            Text("Offer to transcribe when a supported Mac app appears to be using its microphone. Detection reads audio activity only; it never records or sends audio. You choose whether to start.")
                .font(.caption).foregroundStyle(.secondary)
            if model.detectionEnabled {
                Toggle("Include calls answered on this Mac", isOn: $model.detectMacCalls)
                    .help("FaceTime, or an iPhone call you take on this Mac. Offered only while the call has two-way audio. Calls that stay on the iPhone are not heard by this Mac.")
                    .padding(.leading, 20)
            }
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
            VStack(alignment: .leading, spacing: 20) {
                Text("Transcribe a meeting or call").font(.largeTitle.weight(.semibold))
                Text("Choose the audio you want to keep. Recording starts only when you choose Start.")
                    .foregroundStyle(.secondary)
                if let offer = model.offer {
                    HStack {
                        Label(MeetingDetector.offerTitle(for: offer), systemImage: "phone")
                        Spacer()
                        Button("Use this app") { model.useOffer(offer); model.dismissOffer() }
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
                        Button("Recent transcripts", action: openHistory)
                    }
                }
                if !model.notice.isEmpty { Text(model.notice).font(.callout).textSelection(.enabled) }
                if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                Divider()
                MeetingDetectionSettings(model: model)
            }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear { model.refreshApps() }
    }
}

/// A passive offer never takes focus or opens a microphone. Its Review action
/// returns to the explicit source/Start controls.
@MainActor
final class MeetingOfferPanelController {
    private var observation: AnyCancellable?
    private var panel: NSPanel?
    private var displayedID: Int32?
    init(model: MeetingModel, review: @escaping () -> Void) {
        observation = model.$offer.sink { [weak self, weak model] offer in
            guard let self else { return }
            self.panel?.orderOut(nil); self.panel = nil
            guard let offer, let model, !model.isBusy, self.displayedID != offer.id else { return }
            self.displayedID = offer.id
            let bounds = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            let panel = NSPanel(contentRect: NSRect(x: bounds.maxX - 365, y: bounds.maxY - 175, width: 340, height: 145),
                styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: false)
            panel.title = "Workbench"; panel.level = .floating; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
                Label(MeetingDetector.offerTitle(for: offer), systemImage: "phone").font(.headline)
                Text("Would you like to transcribe? Nothing is recording.").font(.callout)
                HStack {
                    Button("Review") { model.useOffer(offer); model.dismissOffer(); review() }
                    Button("Not now") { model.dismissOffer() }
                    Button("Snooze") { model.snoozeOffers() }
                }
            }.padding(18))
            self.panel = panel
            panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self, weak panel] in
                panel?.orderOut(nil)
                if self?.displayedID == offer.id { self?.displayedID = nil }
            }
        }
    }
    func close() { observation = nil; panel?.close(); panel = nil }
}
