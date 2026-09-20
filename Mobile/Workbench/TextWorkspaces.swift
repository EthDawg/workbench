import SwiftUI
import UniformTypeIdentifiers

struct MobileDictateView: View {
    @EnvironmentObject private var store: MobileStore
    @EnvironmentObject private var speech: SpeechService
    @EnvironmentObject private var reader: ReadingService
    @Environment(\.openURL) private var openURL
    @State private var draft = ""
    @State private var original = ""
    @State private var savedID: UUID?
    @State private var cleanup = true
    @State private var importing = false
    @State private var notice: String?
    @State private var previousDraft: (before: String, applied: String)?
    @State private var listening = false
    @State private var originalVisible = false
    @State private var discardRecovery = false
    @FocusState private var editing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                captureControls
                if let recovery = speech.recoveryAudioURL, !speech.isRecording, !speech.isWorking {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Recording kept for recovery", systemImage: "arrow.counterclockwise").font(.headline)
                        Text("Retry transcription, or share the audio to keep another copy.").font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            Button("Retry transcription") { guard preserveDraft() else { return }; Task { reader.stop(); accept(await speech.transcribe(url: recovery)) } }.buttonStyle(.bordered).disabled(!speech.isReady)
                            ShareLink(item: recovery) { Image(systemName: "square.and.arrow.up").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("Share recovered audio")
                        }
                        Button("Discard recovery", role: .destructive) { discardRecovery = true }.font(.subheadline).frame(minHeight: 44)
                    }.padding(16).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                }
                if let problem = speech.recoveryProblem {
                    Text(problem).font(.subheadline).foregroundStyle(.secondary)
                    Button("Discard recovery", role: .destructive) { discardRecovery = true }
                }
                if let error = speech.error {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(error, systemImage: "exclamationmark.circle").font(.subheadline)
                        if let detail = speech.diagnosticDetail {
                            DisclosureGroup("Troubleshooting details") {
                                Text(detail).font(.caption.monospaced()).textSelection(.enabled)
                                Button("Copy details", systemImage: "doc.on.doc") { UIPasteboard.general.string = detail; notice = "Copied troubleshooting details. No recording or transcript is included." }.font(.subheadline)
                            }.font(.subheadline)
                        }
                    }.foregroundStyle(.secondary)
                }
                HStack {
                    Text("Your words").font(.title2.bold())
                    Spacer()
                    PasteButton(payloadType: String.self) { values in
                        if let text = values.first {
                            guard text.count <= 50_000 else { notice = "Choose a passage under 50,000 characters. Your draft is unchanged."; return }
                            let keptPrevious = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            guard store.replaceDraftWithPaste(text, preserving: draft, original: original, savedID: savedID) else { return }
                            original = store.document.draftOriginal; draft = store.document.draft
                            savedID = nil; previousDraft = nil
                            notice = keptPrevious ? "Previous draft kept in Saved. Pasted text is ready." : "Pasted text is ready."
                        }
                    }.labelStyle(.iconOnly).disabled(speech.isWorking || speech.isRecording)
                }
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty { Text("Speak, paste or type something you want to keep.").foregroundStyle(.tertiary).padding(.top, 12).padding(.leading, 5).allowsHitTesting(false) }
                    // Let native input commit through its own state binding.
                    // Retire dependent Undo UI after SwiftUI observes the edit,
                    // rather than mutating both states inside the input setter.
                    TextEditor(text: $draft).frame(minHeight: 200).scrollContentBackground(.hidden).focused($editing).accessibilityLabel("Draft text").accessibilityIdentifier("dictate.draft").disabled(speech.isWorking || speech.isRecording)
                }.padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                if !draft.isEmpty {
                    HStack {
                        Button("Clean up", systemImage: "text.badge.checkmark") {
                            let applied = TextRules.apply(DictationCleanup.light(draft), replacements: store.document.replacements)
                            previousDraft = (before: draft, applied: applied)
                            if original.isEmpty { original = draft }
                            draft = applied
                            store.change { $0.draft = draft; $0.draftOriginal = original }
                            notice = "Light cleanup applied. Your original is kept."
                        }.buttonStyle(.bordered).disabled(speech.isWorking || speech.isRecording)
                        if let snapshot = previousDraft {
                            Button("Undo cleanup") {
                                previousDraft = nil
                                // A pending view refresh cannot make stale Undo
                                // overwrite text that has already changed.
                                guard draft == snapshot.applied else { return }
                                draft = snapshot.before
                            }
                        }
                        Spacer()
                    }
                    DisclosureGroup("Original", isExpanded: $originalVisible) {
                        Text(original.isEmpty ? draft : original).font(.body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(.top, 8)
                    }.font(.subheadline)
                    HStack {
                        ShareLink(item: draft) { Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 36) }.buttonStyle(.borderedProminent)
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = draft; notice = "Copied. Paste when you’re ready." }.buttonStyle(.bordered).frame(minHeight: 44)
                    }
                    HStack {
                        Button("Save text", systemImage: "bookmark") {
                            savedID = store.saveText(draft, original: original.isEmpty ? draft : original, id: savedID)
                            if savedID != nil { notice = "Saved on this device." }
                        }.accessibilityIdentifier("dictate.save")
                        Spacer()
                        Button("Read aloud", systemImage: "speaker.wave.2") { if store.change({ $0.readText = draft }) { reader.stop(); listening = true } }
                    }.font(.subheadline).frame(minHeight: 44)
                }
                if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("dictate.notice") }
            }.padding(20).frame(maxWidth: 720)
        }.frame(maxWidth: .infinity).background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Dictate").navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { editing = false } } }
            .onAppear { draft = store.document.draft; original = store.document.draftOriginal }
            .task { await speech.refreshAvailability() }
            .onChange(of: draft) { _, new in
                // Any edit retires the snapshot; returning to its text later
                // must not revive it. Programmatic cleanup matches applied.
                if let snapshot = previousDraft, new != snapshot.applied { previousDraft = nil }
                if new.count > 50_000 { draft = String(new.prefix(50_000)); return }
                store.change { $0.draft = new; $0.draftOriginal = original }
            }
            .onDisappear { if speech.isRecording || speech.isWorking { speech.cancel() } }
            .navigationDestination(isPresented: $listening) { MobileReadingView() }
            .confirmationDialog("Discard this recovery?", isPresented: $discardRecovery, titleVisibility: .visible) {
                Button("Discard recovery", role: .destructive) { speech.discardRecovery() }
            } message: { Text("Share the recording first if you need another copy. This clears the pending recovery so you can record again.") }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task {
                        reader.stop()
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        accept(await speech.transcribe(url: url))
                    }
                } else if case .failure(let error) = result { notice = error.localizedDescription }
            }
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(speech.isRecording ? "Recording" : "On-device dictation", systemImage: speech.isRecording ? "mic.fill" : "iphone")
                    .font(.headline).foregroundStyle(speech.isRecording ? Color.red : Color.primary)
                Spacer()
                if speech.isRecording { Text(Duration.seconds(speech.elapsed), format: .time(pattern: .minuteSecond)).monospacedDigit().accessibilityLabel("Recording duration") }
            }
            Text(speech.phase).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("dictate.phase")
            if !speech.languages.isEmpty, !speech.isRecording {
                Picker("Speech language", selection: Binding(get: { speech.selectedLanguageID }, set: { value in Task { await speech.selectLanguage(value) } })) {
                    if !speech.languages.contains(where: { $0.id == speech.selectedLanguageID }) { Text(speech.languageName).tag(speech.selectedLanguageID) }
                    ForEach(speech.languages) { language in Text(language.name).tag(language.id) }
                }.disabled(speech.isWorking).accessibilityIdentifier("dictate.language")
            }
            if speech.isWorking {
                if let progress = speech.downloadProgress { ProgressView(value: progress).accessibilityLabel("Speech language download") } else { ProgressView().frame(maxWidth: .infinity) }
                Button(speech.hasRecovery ? "Cancel · keep audio" : "Cancel") { speech.cancel() }.buttonStyle(.bordered).frame(minHeight: 44)
            } else if speech.isRecording {
                ProgressView(value: speech.inputLevel).tint(.red).accessibilityLabel("Microphone level")
                Text("Listening. Finish when you’re ready; your original audio is kept.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Finish & transcribe", systemImage: "stop.fill") { Task { accept(await speech.finish()) } }.buttonStyle(.borderedProminent).tint(.red).frame(minHeight: 44)
                    Button("Cancel · keep audio") { speech.cancel() }.frame(minHeight: 44)
                }
            } else if speech.isReady {
                HStack {
                    Button { guard preserveDraft() else { return }; editing = false; reader.stop(); Task { await speech.start() } } label: { Label("Record", systemImage: "mic.fill").frame(maxWidth: .infinity, minHeight: 36) }
                        .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("dictate.record").disabled(speech.hasRecovery)
                    Button("Import audio", systemImage: "waveform") { if preserveDraft() { importing = true } }.buttonStyle(.bordered).frame(minHeight: 44).disabled(speech.hasRecovery)
                }
                Toggle("Light cleanup", isOn: $cleanup).font(.subheadline)
                Text("Removes fillers, resolves clear time corrections and formats explicit lists. Original wording stays available.").font(.caption).foregroundStyle(.secondary)
            } else {
                if speech.canPrepare {
                    Button(speech.readiness == .downloading ? "Continue language download" : speech.readiness == .failed ? "Retry language download" : "Download speech language", systemImage: "arrow.down.circle") { editing = false; Task { reader.stop(); await speech.prepare() } }
                        .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("dictate.prepare")
                    Text("Apple’s \(speech.languageName) model downloads once, using an internet connection. Keep Workbench open until it is ready. Recording starts only when you tap Record.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Check availability again", systemImage: "arrow.clockwise") { Task { await speech.refreshAvailability() } }.frame(minHeight: 44)
                Text("You can also type, paste, or use the microphone on Apple’s keyboard in Your words.").font(.caption).foregroundStyle(.secondary)
            }
            if speech.microphoneDenied {
                Button("Open microphone settings", systemImage: "gearshape") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }.frame(minHeight: 44)
            }
        }.padding(18).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
    }

    private func setDraft(_ text: String, original: String) {
        self.original = String(original.prefix(50_000)); draft = String(text.prefix(50_000)); savedID = nil; previousDraft = nil
        store.change { $0.draft = draft; $0.draftOriginal = self.original }
    }
    private func preserveDraft() -> Bool {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        savedID = store.saveText(draft, original: original.isEmpty ? draft : original, id: savedID)
        return savedID != nil
    }
    private func accept(_ result: MobileSpeechResult?) {
        guard let result else { return }
        setDraft(TextRules.apply(cleanup ? DictationCleanup.light(result.original) : result.original, replacements: store.document.replacements), original: result.original)
        savedID = store.saveText(draft, original: original, audioURL: result.audioURL)
        if savedID != nil { speech.markSaved(audioURL: result.audioURL) }
        notice = savedID == nil ? "Your text is ready. Saving failed; copy or share it before leaving." : "Saved with your original recording."
    }
}

struct MobileReadingView: View {
    @EnvironmentObject private var store: MobileStore
    @EnvironmentObject private var speech: SpeechService
    @EnvironmentObject private var reader: ReadingService
    @State private var text = ""
    @State private var showVoices = false
    @State private var notice: String?
    @FocusState private var editing: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Make room to listen.").font(.title3).foregroundStyle(.secondary); Spacer()
                    PasteButton(payloadType: String.self) { values in
                        if let value = values.first {
                            guard value.count <= 50_000 else { notice = "Choose a passage under 50,000 characters. The current text is unchanged."; return }
                            text = value
                        }
                    }.labelStyle(.iconOnly).disabled(reader.isSpeaking || reader.isPaused)
                }
                TextEditor(text: $text).frame(minHeight: 260).padding(10).scrollContentBackground(.hidden).focused($editing)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityLabel("Text to read").accessibilityIdentifier("reading.text")
                    .disabled(reader.isSpeaking || reader.isPaused)
                HStack(spacing: 14) {
                    Button { editing = false; speech.cancel(); if reader.isSpeaking || reader.isPaused { reader.pauseResume() } else { reader.read(text) } } label: {
                        Label(reader.isPaused ? "Resume" : reader.isSpeaking ? "Pause" : "Read aloud", systemImage: reader.isSpeaking && !reader.isPaused ? "pause.fill" : "play.fill").frame(maxWidth: .infinity, minHeight: 36)
                    }.buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("reading.play")
                    if reader.isSpeaking || reader.isPaused { Button("Stop", systemImage: "stop.fill") { reader.stop() }.buttonStyle(.bordered).frame(minHeight: 44).accessibilityIdentifier("reading.stop") }
                }
                Button { showVoices = true } label: {
                    HStack { Label("Voice", systemImage: "person.wave.2"); Spacer(); Text(reader.voices.first { $0.identifier == reader.selectedVoiceID }?.name ?? "System voice").foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.caption) }
                }.frame(minHeight: 44)
                VStack(alignment: .leading) {
                    HStack { Text("Pace"); Spacer(); Text(reader.rate < 0.45 ? "Slower" : reader.rate > 0.55 ? "Faster" : "Natural").foregroundStyle(.secondary) }
                    Slider(value: $reader.rate, in: 0.3...0.65, step: 0.05).accessibilityLabel("Reading pace")
                    Text("Voice and pace changes apply to the next reading.").font(.caption).foregroundStyle(.secondary)
                }.disabled(reader.isSpeaking || reader.isPaused)
                Button("Save text", systemImage: "bookmark") { if store.saveText(text, original: text) != nil { notice = "Saved on this device." } }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).frame(minHeight: 44)
                if let error = reader.error { Text(error).font(.subheadline).foregroundStyle(.secondary) }
                if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                Text("Apple voices. Your text stays on this device.").font(.footnote).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: 720)
        }.frame(maxWidth: .infinity).background(Color(uiColor: .systemGroupedBackground)).navigationTitle("Read aloud").navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { editing = false } } }
            .onAppear { text = store.document.readText; reader.selectedVoiceID = store.document.voiceID; reader.rate = store.document.readingRate }
            .onChange(of: text) { _, value in if value.count > 50_000 { text = String(value.prefix(50_000)) } else { store.change { $0.readText = value } } }
            .onChange(of: reader.selectedVoiceID) { _, value in store.change { $0.voiceID = value } }
            .onChange(of: reader.rate) { _, value in store.change { $0.readingRate = value } }
            .sheet(isPresented: $showVoices) {
                NavigationStack {
                    List {
                        Button("System voice") { reader.selectedVoiceID = ""; showVoices = false }
                        ForEach(reader.voices, id: \.identifier) { voice in
                            Button { reader.selectedVoiceID = voice.identifier; showVoices = false } label: {
                                HStack { VStack(alignment: .leading) { Text(voice.name); Text(Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language).font(.caption).foregroundStyle(.secondary) }; Spacer(); if reader.selectedVoiceID == voice.identifier { Image(systemName: "checkmark") } }
                            }
                        }
                    }.navigationTitle("Installed voices").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showVoices = false } } }
                }
            }
    }
}
