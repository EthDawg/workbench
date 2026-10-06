import SwiftUI

/// This view owns only the configuration draft; readiness comes from the engine's snapshot.
struct ModelSettingsView: View {
    let engine: RecognitionEngine
    var isBusy: Bool
    var snapshot: RecognitionSnapshot
    var onNotNow: () -> Void = {}
    var onSnapshot: @MainActor (RecognitionSnapshot) -> Void = { _ in }
    @State private var draft = RecognitionConfiguration()
    @State private var active = RecognitionConfiguration()
    @State private var applying = false
    @State private var failure: String?
    @State private var loaded = false
    private var current: RecognitionSnapshot { snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: "waveform.badge.magnifyingglass").font(.title2).foregroundStyle(Workbench.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Speech model").font(Workbench.sectionTitle).accessibilityAddTraits(.isHeader)
                    Text("Choose what turns your recordings into text.").foregroundStyle(.secondary)
                }
            }
            Label(current.line, systemImage: current.canTranscribe ? "checkmark.circle" : "circle.dotted")
                .font(.callout).foregroundStyle(current.canTranscribe ? .primary : .secondary)
                .accessibilityLabel("Active model: \(current.line)")

            Picker("Transcribe with", selection: $draft.provider) {
                ForEach(RecognitionProvider.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(isBusy || applying || current.isPreparing || !loaded)

            if draft.provider == .parakeet {
                Text("Parakeet v2 turns English speech into text on this Mac. About 450 MB to download; validated saved files work offline. Setup never starts recording. You can keep using saved work without downloading.")
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

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if let details = current.failure?.details {
                DisclosureGroup("Details") { Text(details).font(.callout).textSelection(.enabled) }
            }
            HStack(spacing: 10) {
                if current.isPreparing {
                    ProgressView().controlSize(.small)
                    Button("Cancel setup") { Task { await engine.cancelPreparation(); await refresh() } }
                        .disabled(current.phase == .cancelling)
                } else {
                    Button(actionTitle) { Task { await apply() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy || applying || !loaded || (current.canTranscribe && draft == active))
                    if draft == active && draft.provider == .parakeet && !current.canTranscribe {
                        Button("Retry saved files") { Task { await prepareCached() } }.disabled(isBusy || applying)
                        Button("Not now", action: onNotNow)
                    }
                }
            }
            if isBusy {
                Text("Model changes are available when recording and processing finish.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            draft = await engine.configuration(); active = draft
            await refresh(); loaded = true
        }

    }

    /// What the one button does now: download or retry the model in use, switch to another,
    /// or nothing while the chosen model is ready.
    private var actionTitle: String {
        if draft != active { return draft.provider == .parakeet ? "Use Parakeet" : "Use local server" }
        if current.canTranscribe { return "In use" }
        return draft.provider == .parakeet ? "Download Parakeet" : "Use local server"
    }

    @MainActor private func refresh() async {
        onSnapshot(await engine.snapshot())
    }
    @MainActor private func prepareCached() async {
        guard !isBusy, !applying else { return }
        applying = true; failure = nil
        defer { applying = false }
        do { try await engine.prepareCached() } catch { }
        await refresh()
    }
    @MainActor private func apply() async {
        guard !isBusy, !applying, !current.isPreparing else { return }
        applying = true; failure = nil
        defer { applying = false }
        do {
            let switching = draft != active
            try await engine.configure(draft)
            active = await engine.configuration(); draft = active
            await refresh()
            if active.provider == .parakeet {
                // Selecting Parakeet reviews its cache, never implies download consent.
                if switching { try await engine.prepareCached() }
                else { try await engine.acquireSelectedModel() }
            }
        } catch {
            // Configuration refusals belong to this draft. Current admission is always
            // read back from the engine, preserving a still-ready previous selection.
            if (await engine.snapshot()).failure == nil { failure = error.localizedDescription }
        }
        await refresh()
    }
}
