import SwiftUI

/// Integrate with ModelSettingsView(engine: model.engine,
///   isBusy: model.phase != .idle || model.preparing || model.rendering) { ready, message in ... }
/// The caller updates its recording readiness from onChange; this view owns only the draft.
struct ModelSettingsView: View {
    let engine: RecognitionEngine
    var isBusy: Bool
    /// The app's one readiness line, which carries a model setup's progress (checking files,
    /// Downloading Parakeet · 42%, preparing for this Mac) from whichever door started it.
    var progress: String? = nil
    /// The app is preparing the model itself, as it does at launch or from Home's Retry model.
    var hostPreparing = false
    /// Why the app's own preparation failed, shown here beside Try download again.
    var hostFailure: String? = nil
    /// Why this page's own Use or Download stopped, or nil as it starts, so the host's readiness
    /// line shows one failure wherever it shows (Snap & Talk's Retry model reads it).
    var onFailure: @MainActor (String?) -> Void = { _ in }
    var onChange: @MainActor (Bool, String) -> Void = { _, _ in }
    @State private var draft = RecognitionConfiguration()
    @State private var active = RecognitionConfiguration()
    @State private var applying = false
    @State private var ready = false
    @State private var status = "Checking model settings…"
    @State private var failure: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: "waveform.badge.magnifyingglass").font(.title2).foregroundStyle(Workbench.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Speech model").font(Workbench.sectionTitle).accessibilityAddTraits(.isHeader)
                    Text("Choose what turns your recordings into text.").foregroundStyle(.secondary)
                }
            }
            Label((applying || hostPreparing) ? (progress ?? status) : status, systemImage: ready ? "checkmark.circle" : "circle.dotted")
                .font(.callout).foregroundStyle(ready ? .primary : .secondary)
                .accessibilityLabel("Active model: \(status)")

            Picker("Transcribe with", selection: $draft.provider) {
                ForEach(RecognitionProvider.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)

            if draft.provider == .parakeet {
                Text("English recognition on this Mac. First setup downloads Parakeet v2; later recordings work offline. Audio is processed inside Workbench.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Use a transcription model served by software running on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transcription endpoint").font(.caption).foregroundStyle(.secondary)
                        TextField("http://127.0.0.1:8080/v1/audio/transcriptions", text: $draft.endpoint)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Local transcription endpoint")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Model name from your server").font(.caption).foregroundStyle(.secondary)
                        TextField("whisper-1", text: $draft.model)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Local transcription model name")
                    }
                    Text("OpenAI-compatible audio transcription · WAV, M4A, MP3 or FLAC · up to 64 MB · 3-minute timeout")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Some servers, including whisper.cpp, load their model when they start. For those servers, change the model in the server itself; this name alone does not switch it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Workbench connects only to loopback addresses and never follows redirects. Your server controls whether it forwards audio elsewhere. Start it before recording; applying settings does not test its model.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let failure = failure ?? (hostPreparing || ready ? nil : hostFailure) {
                Label(failure, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Button {
                    Task { await apply() }
                } label: {
                    Text(actionTitle)
                }.buttonStyle(.borderedProminent).disabled(ready && draft == active)
                if applying || hostPreparing { ProgressView().controlSize(.small) }
                else if draft != active { Text("Changes apply to the next recording.").font(.caption).foregroundStyle(.secondary) }
            }
            if isBusy && !applying {
                Text("Model changes are available when recording and processing finish.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(isBusy || applying || !loaded)
        .task {
            draft = await engine.configuration(); active = draft
            ready = await engine.isReady; status = await engine.statusDescription(); loaded = true
        }
        .onChange(of: isBusy) { _, busy in
            guard !busy, !applying else { return }
            Task { ready = await engine.isReady; status = await engine.statusDescription() }
        }
    }

    /// What the one button does now: download or retry the model in use, switch to another,
    /// or nothing while the chosen model is ready.
    private var actionTitle: String {
        if applying || hostPreparing { return "Preparing…" }
        if draft != active { return draft.provider == .parakeet ? "Use Parakeet" : "Use local server" }
        if ready { return "In use" }
        guard draft.provider == .parakeet else { return "Use local server" }
        return (failure ?? hostFailure) == nil ? "Download Parakeet" : "Try download again"
    }

    @MainActor private func apply() async {
        guard !isBusy, !applying else { return }
        applying = true; failure = nil; onFailure(nil)
        defer { applying = false }
        // Close the recording gate on the main actor before the first suspension:
        // another window or hotkey must not begin capture while selection changes.
        ready = false
        status = "Changing speech model…"
        onChange(false, status)
        do {
            try await engine.configure(draft)
            active = await engine.configuration(); draft = active
            ready = false
            status = draft.provider == .parakeet ? "Preparing Parakeet · first setup may take a few minutes" : "Applying local server settings…"
            onChange(false, status)
            try await engine.prepare()
            ready = await engine.isReady; status = await engine.statusDescription()
            onChange(ready, status)
        } catch {
            failure = error.localizedDescription; onFailure(failure)
            ready = await engine.isReady; status = await engine.statusDescription()
            onChange(ready, status)
        }
    }
}
