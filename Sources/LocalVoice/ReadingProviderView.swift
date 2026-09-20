import SwiftUI

struct ReadingProviderView: View {
    @ObservedObject var model: AppModel
    @State private var key = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Read with", selection: $model.readingProvider) {
                ForEach(ReadingProvider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if model.readingProvider == .speko {
                Text("Speko sends this reading to its cloud service and selected voice provider. Your Speko account may be charged. Your dictation engine is selected separately in Models.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    SecureField("Personal Speko API key", text: $key).textFieldStyle(.roundedBorder)
                    Button("Save key") { model.saveSpekoKey(key); key = "" }.disabled(key.isEmpty)
                    Button("Remove key") { model.removeSpekoKey(); key = "" }
                }
                HStack {
                    Text(model.keyNotice.isEmpty ? "Saved in this app’s Keychain. Never in your drafts or backups." : model.keyNotice)
                    Spacer()
                    Link("Speko account ↗", destination: URL(string: "https://platform.speko.ai")!)
                }.font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("VOICE").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
                    HStack {
                        Picker("Speko voice", selection: Binding<String?>(
                            get: { model.selectedSpekoVoice?.id },
                            set: { model.selectSpekoVoice(id: $0) }
                        )) {
                            Text("Automatic · balanced route").tag(String?.none)
                            ForEach(model.displayedSpekoVoices) { voice in
                                Text(voice.name).tag(Optional(voice.id))
                            }
                        }
                        .frame(maxWidth: 360)
                        Button { Task { await model.refreshSpekoVoices() } } label: {
                            Label("Refresh voices", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.loadingSpekoVoices || !SpekoKeychain.hasKey)
                        if model.loadingSpekoVoices { ProgressView().controlSize(.small) }
                    }
                    if let voice = model.selectedSpekoVoice {
                        Text("\(voice.name) · \(voice.detail) · explicit \(voice.useWith.provider) / \(voice.useWith.model)")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Automatic voice · balanced routing")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !model.spekoVoiceNotice.isEmpty {
                        Text(model.spekoVoiceNotice).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Up to 5,000 characters per reading. Speko speech-to-text is not selected here; dictation remains configured separately in Models.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(model.rendering)
        .task(id: model.readingProvider) {
            if model.readingProvider == .speko { await model.refreshSpekoVoices() }
        }
        .onDisappear { key = "" }
    }
}
