import SwiftUI

/// Embeddable next to speech recognition settings. Model management never opts a
/// user into Natural cleanup; the existing Original/Light/Natural choice owns that.
/// The manager is the app's: a download started here outlives this view (#134, 1 October).
struct CleanupModelSettingsView: View {
    @ObservedObject var manager: CleanupModelManager
    var isBusy: Bool
    var onChange: (CleanupConfiguration) -> Void = { _ in }
    @State private var draft = CleanupConfiguration()
    @State private var saved = CleanupConfiguration()
    @State private var notice: String?
    @State private var confirmDownload = false
    private var locked: Bool { isBusy || manager.isWorking }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Text refinement", systemImage: "text.badge.checkmark").font(Workbench.sectionTitle).accessibilityAddTraits(.isHeader)
            Text("Speech recognition hears your words. Refinement adjusts punctuation and layout after transcription. Light cleanup works without a text model; Natural uses the choice below.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Natural cleanup model", selection: $draft.naturalProvider) {
                ForEach(NaturalCleanupProvider.allCases, id: \.self) { provider in Text(provider.title).tag(provider) }
            }.disabled(locked)
            if draft.naturalProvider == .apple {
                Text(CleanupEngine.availability).font(.callout).foregroundStyle(.secondary)
            } else {
                TextField("Ollama address", text: $draft.endpoint).textFieldStyle(.roundedBorder).disabled(locked)
                    .help("The base address of Ollama running on this Mac; no /api path.")
                HStack {
                    TextField("Model name", text: $draft.model).textFieldStyle(.roundedBorder).disabled(locked)
                    if !manager.models.isEmpty {
                        Menu("Installed models") {
                            ForEach(manager.models) { model in
                                Button("\(model.name) · \(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file))") {
                                    draft.model = model.name
                                }
                            }
                        }.disabled(locked)
                    }
                }
                HStack {
                    Button("Check installed") { manager.refresh(operationConfiguration) }.disabled(locked)
                    Button("Load model") { manager.load(operationConfiguration) }.disabled(locked)
                    Button("Download model…") { confirmDownload = true }.disabled(locked)
                }
                Text("Ollama must already be installed and running. Downloads use the internet and disk space, and keep going if you leave this page; Cancel stops one. Load checks the draft model; Save applies it to future Natural captures. A failed or meaning-changing edit falls back to Light, and the original is retained.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Link("Get Ollama", destination: URL(string: "https://ollama.com/download/mac")!)
                    Link("Browse models", destination: URL(string: "https://ollama.com/library")!)
                    Link("Disable Ollama Cloud", destination: URL(string: "https://docs.ollama.com/faq#how-do-i-disable-ollama-cloud-features")!)
                }.font(.caption)
                Text("Workbench connects only to loopback and refuses cloud model metadata. You control the local server; enable Ollama’s local-only mode for a stronger boundary.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // A running or failed download shows whichever model is drafted above: the request is
            // the app's, so it is never hidden by a draft change, and Cancel is the explicit stop.
            if draft.naturalProvider == .ollama || manager.isWorking || manager.failure != nil {
                if manager.isWorking {
                    HStack(spacing: 10) {
                        if let progress = manager.progress { ProgressView(value: progress) }
                        else { ProgressView().controlSize(.small) }
                        Button("Cancel") { manager.cancel() }
                    }
                }
                if let failure = manager.failure {
                    Label(failure, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(manager.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Save refinement choice") { save() }.disabled(locked || (draft == saved && saved.settingsIssue == nil))
                if isBusy { Text("Available after the current operation.").font(.caption).foregroundStyle(.secondary) }
            }
            if let notice { Text(notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            Text("Applied to Natural: \(saved.naturalProvider.title)\(saved.naturalProvider == .ollama ? " · " + saved.model : ""). Original and Light do not call a text model.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            let loaded = CleanupConfigurationStore().snapshot()
            saved = loaded; draft = loaded; draft.settingsIssue = nil
            notice = loaded.settingsIssue
        }
        .onChange(of: draft.endpoint) { _, _ in manager.resetStatus() }
        .onChange(of: draft.model) { _, _ in manager.resetStatus() }
        .confirmationDialog("Download \(draft.model)?", isPresented: $confirmDownload, titleVisibility: .visible) {
            Button("Download model") { if !locked { manager.download(operationConfiguration) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Ollama at \(draft.endpoint) will fetch this model from its library. Model sizes vary and may use several gigabytes. This does not change your cleanup selection. Cancelling stops Workbench’s request; Ollama may keep downloaded layers.")
        }
    }
    private var operationConfiguration: CleanupConfiguration {
        var copy = draft; copy.settingsIssue = nil; copy.naturalProvider = .ollama; return copy
    }
    private func save() {
        do {
            var configuration = draft; configuration.settingsIssue = nil
            configuration = try configuration.validated()
            try CleanupConfigurationStore().save(configuration)
            saved = configuration; draft = configuration; manager.clearFailure()
            notice = "Saved for future Natural captures. Select Natural in dictation to use it."
            onChange(configuration)
        } catch { notice = error.localizedDescription }
    }
}
