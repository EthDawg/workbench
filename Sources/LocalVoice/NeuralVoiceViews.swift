import SwiftUI

/// The neural voices' one download: what it is, how far it has got, and its removal. Shown
/// wherever Read's voice source is chosen, so the choice never ends at a missing download.
struct NeuralVoiceSetupView: View {
    @ObservedObject var model: AppModel
    @State private var confirmRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Natural-sounding voices made on this Mac. One download (\(NeuralVoiceCatalog.downloadSize)), then readings need no internet and your text stays here.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let progress = model.neuralVoiceProgress {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.callout).monospacedDigit()
                    Button("Stop download") { model.cancelNeuralVoiceDownload() }
                } else if model.neuralVoicesDownloaded {
                    Label("Downloaded · On this Mac", systemImage: "checkmark.circle").font(.callout)
                    Button("Remove download…") { confirmRemoval = true }.disabled(model.rendering || model.playing || model.paused)
                } else {
                    Button("Download neural voices") { model.downloadNeuralVoices() }.buttonStyle(.borderedProminent)
                }
            }
            if !model.neuralVoiceNotice.isEmpty {
                Text(model.neuralVoiceNotice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Follow-along moves a sentence at a time. \(NeuralVoiceCatalog.attribution)")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.refreshNeuralVoices() }
        .confirmationDialog("Remove the neural voices?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove download", role: .destructive) { model.removeNeuralVoices() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("This frees \(NeuralVoiceCatalog.downloadSize) on this Mac. Your readings and other voices stay, and you can download the neural voices again at any time.")
        }
    }
}

/// The neural voice Read uses, with a sample to compare voices by ear.
struct NeuralVoicePanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Voice").font(Workbench.sectionTitle)
            HStack(spacing: 6) {
                Picker("Neural voice", selection: $model.neuralVoice) {
                    ForEach(NeuralVoiceCatalog.voices, id: \.self) { Text(NeuralVoiceCatalog.title($0)).tag($0) }
                }.labelsHidden().frame(width: 270, alignment: .leading)
                Button { model.toggleVoicePreview() } label: { Image(systemName: model.previewingVoice ? "stop.fill" : "speaker.wave.2") }
                    .buttonStyle(.borderless)
                    .help(model.previewingVoice ? "Stop the sample" : "Hear a short sample of this voice")
                    .accessibilityLabel(model.previewingVoice ? "Stop voice sample" : "Hear voice sample")
            }
            Text("Neural voices read at their own pace.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}
