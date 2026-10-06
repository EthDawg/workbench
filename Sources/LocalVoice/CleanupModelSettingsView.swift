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
            VStack(alignment: .leading, spacing: 4) {
                ModelSectionHeader(title: "Text style", symbol: "text.badge.checkmark")
                Text("Speech recognition hears your words; the text style tidies punctuation and layout afterwards. Original and Light need no text model. Natural uses the model below.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker("Natural style model", selection: $draft.naturalProvider) {
                ForEach(NaturalCleanupProvider.allCases, id: \.self) { provider in Text(provider.title).tag(provider) }
            }.disabled(locked)
            if draft.naturalProvider == .apple {
                Text(CleanupEngine.availability).font(.callout).foregroundStyle(.secondary)
                if manager.isWorking || manager.failure != nil { downloadProgress }
            } else {
                // Caption labels above each field, as the speech server's fields have.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ollama address").font(.caption).foregroundStyle(.secondary)
                    TextField("Ollama address", text: $draft.endpoint, prompt: Text(verbatim: "http://127.0.0.1:11434")).textFieldStyle(.roundedBorder).disabled(locked)
                        .accessibilityLabel("Ollama address")
                        .help("The base address of Ollama running on this Mac; no /api path.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model name").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("Model name", text: $draft.model, prompt: Text(verbatim: "gemma3:1b")).textFieldStyle(.roundedBorder).disabled(locked)
                            .accessibilityLabel("Model name")
                        if !manager.models.isEmpty {
                            Menu("Installed models") {
                                ForEach(manager.models) { model in
                                    Button("\(model.name) · \(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file))") {
                                        draft.model = model.name
                                    }
                                }
                            }.disabled(locked).fixedSize()
                        }
                    }
                }
                HStack {
                    Button("Check installed") { manager.refresh(operationConfiguration) }.disabled(locked)
                    Button("Load model") { manager.load(operationConfiguration) }.disabled(locked)
                    Button("Download model…") { confirmDownload = true }.disabled(locked)
                }
                // Progress and its reason sit directly under the buttons that started them.
                downloadProgress
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
            HStack {
                Button("Save") { save() }.disabled(locked || (draft == saved && saved.settingsIssue == nil))
                if isBusy { Text("Available after the current operation.").font(.caption).foregroundStyle(.secondary) }
            }
            if let notice { Text(notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            // The same sentence Dictate settings shows for the saved choice.
            Text("Natural text style uses \(saved.naturalSummary).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 720, alignment: .leading)
        .onAppear {
            let loaded = manager.store.snapshot()
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
    /// A running or failed download, whichever model is drafted: the request is the app's, so a
    /// draft change never hides it, and Cancel is the explicit stop.
    @ViewBuilder private var downloadProgress: some View {
        if manager.isWorking {
            HStack(spacing: 10) {
                if let progress = manager.progress { ProgressView(value: progress) }
                else { ProgressView().controlSize(.small) }
                Button("Cancel") { manager.cancel() }
            }
        }
        if let failure = manager.failure { WorkbenchNote(failure) }
        if draft.naturalProvider == .ollama || manager.isWorking || manager.failure != nil {
            Text(manager.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var operationConfiguration: CleanupConfiguration {
        var copy = draft; copy.settingsIssue = nil; copy.naturalProvider = .ollama; return copy
    }
    private func save() {
        do {
            var configuration = draft; configuration.settingsIssue = nil
            configuration = try configuration.validated()
            try manager.store.save(configuration)
            saved = configuration; draft = configuration; manager.clearFailure()
            notice = "Saved for future Natural captures. Select Natural in dictation to use it."
            onChange(configuration)
        } catch { notice = error.localizedDescription }
    }
}
