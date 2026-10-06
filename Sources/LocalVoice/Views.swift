import SwiftUI
import AppKit

private let ink = Workbench.background
private let panelColor = Workbench.surface
private let mint = Workbench.accent

struct ContentView: View {
    @ObservedObject var model: AppModel
    /// Workbench supplies the window and navigation; each workspace owns its content.
    var embedded = true
    var onUseImageInPresent: ((DemoLibraryImageSnapshot) -> Void)? = nil
    var onUseImageInPersona: ((DemoLibraryImageSnapshot) -> Void)? = nil
    @State private var showOriginal = false
    @State private var showCorrection = false
    @State private var showDictateSettings = false
    @State private var showReadingSettings = false
    @State private var showRecovery = false
    @State private var selectedCorrection = ""
    @State private var correctionSeed = ""
    @State private var correctionDraft = ""
    @State private var confirmingRecoveryDiscard = false
    @State private var dictateResult: String?
    @State private var readingResult: String?
    @State private var dictateActionID = UUID()
    @State private var readingActionID = UUID()
    @Environment(\.pageSectionFrames) private var sectionFrames

    /// A problem stays on the workspace that owns it. Read's typed playback failure already
    /// has its own Retry beside the transport, so it is never repeated in the page banner.
    private var bannerError: String? {
        guard let attention = model.attention else { return nil }
        let belongsHere = model.page == "speak" ? attention.page == .read
            : ["dictate", "dictionary"].contains(model.page) && attention.page == .dictate
        guard belongsHere else { return nil }
        if model.page == "speak", attention.message == model.readingFailure?.message { return nil }
        return attention.message
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
            if let error = bannerError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(error).font(.system(size: 12)).textSelection(.enabled)
                    Spacer()
                    // The fix is in System Settings, so the page opens it beside the microphone refusal
                    // itself. The Mac's microphone setting says nothing about which problem this is.
                    if model.page != "speak", error.hasPrefix("Microphone access is off") {
                        Button("Microphone Settings…") { model.openMicrophoneSettings() }.controlSize(.small)
                            .help("Open Privacy & Security › Microphone in System Settings")
                    }
                    Button { model.dismissError() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss error")
                }.padding(14).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            }
            Group {
                switch model.page {
                case "speak": speak
                case "library": DemoLibraryView(library: model.library, model: model,
                    onUseImageInPresent: onUseImageInPresent, onUseImageInPersona: onUseImageInPersona)
                case "dictionary": DictionaryView(model: model)
                default: dictate
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(Workbench.pagePadding).background(ink)
        .frame(minWidth: 650, minHeight: embedded ? nil : 680)
        .tint(mint).workbenchTheme()
        .sheet(isPresented: $showOriginal) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Original transcript").font(.title2.weight(.semibold))
                Text("Your unedited words are kept so you can check any cleanup.").foregroundStyle(.secondary)
                ScrollView { Text(model.rawTranscript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 240)
                HStack {
                    Button("Restore original") { dictateActionID = UUID(); dictateResult = model.useOriginal(); showOriginal = false }
                    Spacer()
                    Button("Done") { showOriginal = false }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 560, height: 380)
        }
        .sheet(isPresented: $showDictateSettings) {
            DictateSettingsView(model: model, openDictionary: {
                showDictateSettings = false
                model.page = "dictionary"
            }, openModels: {
                showDictateSettings = false
                model.page = "models"
            }, done: { showDictateSettings = false })
        }
        .sheet(isPresented: $showReadingSettings) {
            ReadingSettingsView(model: model, done: { showReadingSettings = false })
        }
        .sheet(isPresented: $showCorrection) {
            RememberCorrectionView(model: model, heard: correctionSeed, draft: correctionDraft)
        }
        .confirmationDialog("Discard capture recovery?", isPresented: $confirmingRecoveryDiscard, titleVisibility: .visible) {
            Button("Discard recovery", role: .destructive) { model.discardCaptureRecovery() }
            Button("Keep recovery", role: .cancel) { }
        } message: {
            Text("This removes the kept recording and its pending save. Your current draft stays open. Copy or Save text first if you need another copy.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
        .onChange(of: model.page) { _, _ in
            dictateResult = nil; readingResult = nil; dictateActionID = UUID(); readingActionID = UUID()
        }
        .onChange(of: model.phase) { _, phase in
            if phase != .idle { dictateResult = nil }
        }
        .modifier(CorrectionSelectionObserver(transcript: model.transcript,
            active: model.page == "dictate" && !showCorrection && !showOriginal && !showDictateSettings,
            selection: $selectedCorrection))
    }

    /// The transcript is the workspace. Routine preferences have one named sheet; recoverable
    /// work keeps a separate, visible door and none of these navigation changes retries it.
    private var dictate: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
                    dictateHeader
                    if let delivery = model.unresolvedDelivery {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(delivery.title, systemImage: delivery.symbolName).font(.headline)
                            Text(delivery.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Review text") { model.reviewUnresolvedDelivery() }
                                if delivery.offersCopy { Button("Copy again") { model.copyUnresolvedDelivery() } }
                                Spacer()
                                Button("Dismiss") { model.dismissUnresolvedDelivery() }.accessibilityLabel("Dismiss unfinished delivery")
                            }
                        }.padding(16).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let incoming = model.pendingTranscript {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Open saved transcript?").font(.headline)
                            Text("Your current draft stays here until you choose Replace draft.").font(.callout).foregroundStyle(.secondary)
                            Text(incoming.text).font(.callout).lineLimit(3).textSelection(.enabled)
                            HStack {
                                Button("Keep current") { model.keepCurrentTranscript() }
                                Spacer()
                                Button("Replace draft") { model.replaceDraftWithTranscript() }.disabled(model.phase != .idle)
                            }
                        }.padding(16).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        captureControls
                        dictateEngine
                        Divider()
                        if showsLiveDictation {
                            LiveVoiceTranscriptView(snapshot: model.voiceSession)
                        } else {
                        HStack {
                            WorkbenchSectionTitle("Transcript")
                            Spacer()
                            Text("\(TextRules.wordCount(model.transcript)) words").font(.caption).foregroundStyle(.tertiary)
                        }
                        editor(text: $model.transcript, placeholder: "Your words appear here. Edit, copy or save them.", label: "Transcript")
                        rememberedCorrection
                        HStack(spacing: 12) {
                            Button { dictateResult = nil; model.copyTranscript() } label: { Label("Copy text", systemImage: "doc.on.doc") }
                                .buttonStyle(PrimaryButton()).disabled(model.transcript.isEmpty)
                            transcriptActions
                            Spacer()
                        }
                        if let dictateResult { workspaceResult(dictateResult) { self.dictateResult = nil } }
                        else { DictateDeliveryReceipt(receipts: model.clipboardReceipt) }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, minHeight: max(360, proxy.size.height - (hasRecoverySection ? 102 : 48)), alignment: .topLeading)
                    .background(panelColor, in: RoundedRectangle(cornerRadius: 16))
                    if hasRecoverySection { captureRecovery }
                }.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sectionFrames?("dictate.visible", $0) }
            .onAppear { showRequestedSettings() }
            .onChange(of: model.focusRequest) { _, _ in showRequestedSettings() }
        }
    }

    private var showsLiveDictation: Bool {
        model.voiceSession.sessionID != nil && model.phase != .idle && model.phase != .cancelling
    }

    private var dictateHeader: some View {
        WorkbenchPageHeader("dictate") {
            Button("Import audio…") { dictateResult = nil; model.importAudio() }.disabled(!model.ready || model.phase != .idle)
            Button("Settings…") { showDictateSettings = true }.accessibilityLabel("Dictate settings")
        }
    }

    private var readingHeader: some View {
        WorkbenchPageHeader("speak") {
            Button("Import text…") { model.importReadingFile() }.disabled(model.savingAudio)
            Button("Voice & pace…") { showReadingSettings = true }
        }
    }

    private var captureControls: some View {
        HStack(spacing: 14) {
            Button { dictateResult = nil; model.toggleRecording() } label: {
                Image(systemName: model.phase == .requesting ? "xmark" : model.phase == .recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 21)).frame(width: 48, height: 48)
                    .foregroundStyle(ink).background(model.phase == .recording ? Color.red.opacity(0.9) : mint, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!model.ready || ![.idle, .requesting, .recording].contains(model.phase) || model.rendering)
            .accessibilityLabel(model.phase == .requesting ? "Cancel microphone request" : model.phase == .recording ? "Finish dictation" : "Start recording")
            VStack(alignment: .leading, spacing: 5) {
                Text(captureTitle).font(Workbench.sectionTitle)
                if model.phase == .recording {
                    HStack(spacing: 10) {
                        WaveBars(level: model.voiceSession.phase == .paused || model.voiceSession.phase == .reconnecting ? 0 : model.level).frame(width: 70, height: 20)
                        Text(time(model.elapsed)).monospacedDigit()
                        if model.voiceSession.phase == .paused {
                            Button("Resume") { Task { await model.resume() } }.buttonStyle(.link)
                        } else {
                            Button("Pause") { Task { await model.pause() } }.buttonStyle(.link)
                                .disabled(model.voiceSession.phase == .reconnecting)
                        }
                        Button("Cancel") { model.cancelRecording() }.buttonStyle(.link).help("Stop and discard this recording")
                    }.font(.caption)
                } else if model.phase == .requesting {
                    Text("Allow access in the macOS prompt, or cancel.").font(.caption).foregroundStyle(.secondary)
                } else if model.preparing || [.transcribing, .cleaning, .delivering, .cancelling].contains(model.phase) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.preparing ? "Preparing your speech engine" : model.phase == .cancelling ? "Waiting for the speech engine to stop" : model.phase == .delivering ? "Checking the destination" : model.captureProcessingLabel)
                        if model.canCancelCurrentCapture { Button("Cancel") { model.cancelCurrentCapture() } }
                    }.font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(model.ready ? recordingHint : model.modelMessage)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if model.phase == .idle && !model.preparing {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(deliverySummary).font(.caption).foregroundStyle(.secondary)
                    if model.preferences.delivery == .paste && !model.accessibilityGranted {
                        Button("Set up automatic paste…") { model.requestAccessibility() }.font(.caption).buttonStyle(.link)
                    }
                }
            }
        }
    }

    /// What turns this page's recordings into text, where it runs, and the way to change it
    /// (workbench.md, rule 9). While the model is not ready, the line above already says why.
    @ViewBuilder private var dictateEngine: some View {
        if model.ready {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Label("\(model.modelMessage) · \(model.preferences.cleanup.rawValue) text style", systemImage: "waveform")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Models…") { model.page = "models" }.buttonStyle(.link).font(.caption)
                        .help("Choose the speech and writing models in Settings › Models")
                }
                // The writing model's download, or why it stopped, beside the models it concerns (#134).
                if let line = model.writingModelLine {
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var captureTitle: String {
        if model.preparing { return "Preparing dictation…" }
        switch model.phase {
        case .idle: return model.ready ? "Ready to dictate" : "Dictation unavailable"
        case .requesting: return "Waiting for microphone access"
        case .recording: return model.voiceSession.recordingTitle
        case .transcribing: return "Transcribing…"
        case .cleaning: return "Cleaning text…"
        case .delivering: return "Delivering text…"
        case .cancelling: return "Cancelling…"
        }
    }

    private var recordingHint: String {
        let shortcut = model.preferences.dictationShortcut
        guard shortcut.enabled else { return "Click the microphone · Up to 5 minutes" }
        return (model.preferences.capture == .hold ? "Hold " : "") + shortcut.label + " · Up to 5 minutes"
    }

    private var deliverySummary: String {
        switch model.preferences.delivery {
        case .clipboard: return "Copies text · Paste with ⌘V"
        case .paste where model.accessibilityGranted: return "Automatic paste ready"
        case .paste: return "Copies text · Paste with ⌘V"
        }
    }

    private var transcriptActions: some View {
        Menu("More") {
            Button("Clean text") {
                dictateResult = nil
                let invocation = UUID(); dictateActionID = invocation
                model.cleanCurrentDraft { result in
                    guard dictateActionID == invocation, model.page == "dictate" else { return }
                    dictateResult = result
                }
            }.disabled(model.transcript.isEmpty || model.phase != .idle)
            Button("Save text…") { dictateActionID = UUID(); dictateResult = nil; dictateResult = model.exportTranscript() }.disabled(model.transcript.isEmpty)
            Button("Save prompt") { model.savePrompt(model.transcript) }.disabled(model.transcript.isEmpty)
            Divider()
            Button("Original…") { showOriginal = true }.disabled(model.rawTranscript.isEmpty)
            Button("Remember correction…") {
                correctionSeed = selectedCorrection
                correctionDraft = model.transcript
                showCorrection = true
            }.disabled(model.transcript.isEmpty || model.phase != .idle)
        }.fixedSize().accessibilityLabel("More transcript actions")
    }

    @ViewBuilder private var rememberedCorrection: some View {
        if let correction = model.rememberedCorrection {
            HStack(spacing: 10) {
                Image(systemName: "text.book.closed").foregroundStyle(mint).accessibilityHidden(true)
                Text("Remembered “\(correction.written)”").lineLimit(2)
                Spacer()
                Button("Undo") {
                    do { try model.undoRememberedCorrection() }
                    catch { model.report(error.localizedDescription, on: .dictate) }
                }.disabled(model.phase != .idle)
                Button { model.dismissRememberedCorrection() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss remembered correction")
            }.font(.system(size: 12)).padding(12).background(mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var hasCurrentRecovery: Bool { model.phase == .idle && (model.hasCaptureRecovery || model.canRetry) }
    private var hasRecoverySection: Bool { hasCurrentRecovery || model.hasSavedRecordings }
    private var captureRecovery: some View {
        DisclosureGroup(isExpanded: $showRecovery) {
            VStack(alignment: .leading, spacing: 10) {
                if hasCurrentRecovery, let failure = model.captureFailure, failure != bannerError {
                    Text(failure).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if model.canRecordAgain {
                    Text("Record again to keep this audio in Saved recordings, or retry it here.").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if hasCurrentRecovery && model.canRetry {
                        Button(model.retryCaptureLabel) { model.retryTranscription() }
                            .disabled(model.phase != .idle).help(model.retryCaptureHelp)
                    }
                    if hasCurrentRecovery && model.hasCaptureRecovery {
                        Button("Show recovery files") { model.showCaptureRecoveryFiles() }
                        Button("Discard recovery…", role: .destructive) { confirmingRecoveryDiscard = true }
                            .disabled(!model.canDiscardCaptureRecovery)
                    }
                    if model.hasSavedRecordings {
                        Button("Saved recordings…") { model.showSavedRecordings() }
                            .help("Use Import audio to transcribe a saved recording again.")
                    }
                }.controlSize(.small)
            }.padding(.top, 10)
        } label: {
            Label(hasCurrentRecovery ? "Capture recovery" : "Saved recordings", systemImage: hasCurrentRecovery ? "arrow.counterclockwise" : "archivebox")
                .font(.callout)
        }.padding(12).background(panelColor, in: RoundedRectangle(cornerRadius: 10))
    }

    /// The existing Settings door now opens this workspace's settings sheet, once.
    private func showRequestedSettings() {
        guard let request = model.focusRequest, request.target == .dictateOptions else { return }
        DispatchQueue.main.async {
            guard model.page == "dictate", model.focusRequest?.id == request.id else { return }
            model.focusRequest = nil
            showDictateSettings = true
        }
    }

    private var speak: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
                    readingHeader
                    if let selection = model.pendingReadingSelection {
                        ReadingSelectionReviewCard(selection: selection, limitMessage: model.readingLimitMessage(for: selection.text),
                                                   replacingDisabled: !model.canReplaceReading,
                                                   waitReason: model.canReplaceReading ? nil : AppModel.replaceWaitsForSave,
                                                   keep: { performReadingAction(model.keepCurrentReading) },
                                                   replace: { performReadingAction(model.replaceReadingWithSelection) })
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        readingDestination
                        if let reading = model.followAlongText {
                            ReadingFollowAlongView(text: reading, highlight: model.readingHighlight)
                                .background(RoundedRectangle(cornerRadius: 12).fill(panelColor.opacity(0.6)))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.07)))
                                .frame(minHeight: 200, maxHeight: .infinity)
                        } else {
                            editor(text: $model.speechText, placeholder: "Paste text to hear it read aloud.", label: "Text to read").disabled(model.rendering)
                        }
                        Text("\(model.speechText.count.formatted()) / \(model.readingLimit.formatted()) characters")
                            .font(.caption).foregroundStyle(model.speechText.count > model.readingLimit ? Color.orange : Color.secondary)
                        if let limit = model.readingLimitMessage(for: model.speechText) {
                            Label(limit, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                                .accessibilityLabel("Reading limit: \(limit)")
                        }
                        readingPlayback
                        readingActions
                        if let readingResult { workspaceResult(readingResult) { self.readingResult = nil } }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, minHeight: max(390, proxy.size.height - (model.pendingReadingSelection == nil ? 48 : 250)), alignment: .topLeading)
                    .background(panelColor, in: RoundedRectangle(cornerRadius: 16))
                }.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var readingDestination: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.readingProvider == .mac {
                // The voice's quality and the free better-voices hint stay on the page (workbench.md, Models).
                Label(model.voiceChoice?.voice.map { "\($0.name), \($0.quality.label) · \(Int(model.rate)) words/min · On this Mac" } ?? "On this Mac",
                      systemImage: "desktopcomputer").font(.callout).foregroundStyle(.secondary)
                if model.voiceChoice?.voice != nil, let hint = model.voiceHint {
                    MacVoiceHintRow(hint: hint, open: model.openVoiceSettings)
                }
                if model.voiceChoice?.voice == nil {
                    HStack {
                        Label(model.missingVoiceMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Button("Choose voice…") { showReadingSettings = true }
                    }.font(.caption)
                }
            } else if model.readingProvider == .neural {
                Label("\(NeuralVoiceCatalog.title(model.neuralVoice)) · Neural voice · On this Mac", systemImage: "desktopcomputer")
                    .font(.callout).foregroundStyle(.secondary)
                if !model.neuralVoicesDownloaded {
                    HStack {
                        Text(model.neuralVoiceProgress ?? "Neural voices need one download before they can read.")
                        Button("Set up…") { showReadingSettings = true }.accessibilityLabel("Set up neural voices")
                    }.font(.caption)
                }
            } else {
                Label("\(model.selectedSpekoVoice?.name ?? "Automatic voice") · Online with Speko", systemImage: "cloud")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Listen and Save audio send this text to Speko. Usage may be charged.").font(.caption).foregroundStyle(.secondary)
                if !SpekoKeychain.hasKey {
                    HStack {
                        Text("Add your Speko key to read online.")
                        Button("Set up…") { showReadingSettings = true }.accessibilityLabel("Set up Speko reading")
                    }.font(.caption)
                }
            }
        }
    }

    @ViewBuilder private var readingPlayback: some View {
        if model.playing || model.paused {
            ReadingPlaybackStrip(elapsed: model.playbackTime, duration: model.audioDuration, renderingAhead: model.renderingAhead,
                                 seek: model.seekReading, skip: model.skipReading)
                .disabled(!model.canSeekReading)
        } else if let failure = model.readingFailure {
            HStack(spacing: 10) {
                Label(failure.message, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange)
                Spacer()
                Button("Retry") { readingResult = nil; model.retryReading() }.disabled(!model.canRetryReading)
                    .accessibilityHint("Makes new audio and reads from the start")
                Button { model.dismissReadingFailure() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    .accessibilityLabel("Dismiss reading error")
            }
        }
    }

    private var readingActions: some View {
        HStack(spacing: 12) {
            Button { readingResult = nil; model.listen() } label: {
                Label(model.rendering ? "Making audio…" : model.playing ? "Pause" : model.paused ? "Resume" : "Listen", systemImage: model.playing ? "pause.fill" : "play.fill")
            }.buttonStyle(PrimaryButton())
                .disabled(model.speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.rendering || model.phase != .idle || model.speechText.count > model.readingLimit)
            // One Cancel ends making audio or Save audio's export: the word every other Read door uses.
            if model.canCancelReading { Button("Cancel") { performReadingAction(model.cancelReading) }.help(model.savingAudio ? "Stop saving this audio" : "Stop making this audio") }
            if model.playing || model.paused { Button("Stop") { performReadingAction(model.stopPlayback) } }
            Spacer()
            Button {
                readingResult = nil
                let invocation = UUID(); readingActionID = invocation
                model.saveAudio { result in
                    guard readingActionID == invocation, model.page == "speak" else { return }
                    readingResult = result
                }
            } label: { Label("Save audio…", systemImage: "square.and.arrow.down") }
                .disabled(model.speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.rendering || model.renderingAhead || model.speechText.count > model.readingLimit)
                .help("Save an M4A file for QuickTime, Music or sharing.")
        }.controlSize(.large)
    }

    /// These synchronous transport/import actions complete in this call. File exports and
    /// cleanup report their own outcomes instead of sampling a shared status after a wait.
    private func performReadingAction(_ action: () -> Void) {
        readingResult = nil
        let previous = model.status
        action()
        if model.status != previous, model.attention?.page != .read { readingResult = model.status }
    }

    private func workspaceResult(_ message: String, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss result")
        }
    }

    private func editor(text: Binding<String>, placeholder: String, label: String) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12).fill(ink.opacity(0.5))
            if text.wrappedValue.isEmpty { Text(placeholder).font(.system(size: 15)).foregroundStyle(.tertiary).lineSpacing(7).padding(20).allowsHitTesting(false) }
            TextEditor(text: text).font(.system(size: 15)).lineSpacing(6).scrollContentBackground(.hidden).padding(14).accessibilityLabel(label)
        }.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07))).frame(minHeight: 200, maxHeight: .infinity)
    }
}

/// Delivery feedback follows the existing receipt owner and its lifetime. A reading status
/// cannot appear here, and opening this workspace never restarts or dismisses a receipt.
private struct DictateDeliveryReceipt: View {
    @ObservedObject var receipts: ClipboardReceiptModel
    var body: some View {
        if let receipt = receipts.receipt, receipt.source == .transcript, receipts.isHUDVisible {
            Label(receipt.title + ". " + receipt.detail, systemImage: receipt.symbolName)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

/// One settings sheet per workspace, shared by its header and the existing Settings route.
/// The geometry reports let the gallery verify the actual sheet that received the request.
struct VoiceWorkspaceSettingsSheet<Content: View>: View {
    let title: String
    let identifier: String
    let done: () -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.pageSectionFrames) private var sectionFrames
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(Workbench.pageTitle).accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
            ScrollView {
                content().frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sectionFrames?(identifier + ".visible", $0) }
            Divider()
            HStack { Spacer(); Button("Done", action: done).keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 570, height: 510).workbenchTheme().tint(mint)
        .accessibilityIdentifier(identifier)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sectionFrames?(identifier, $0) }
        .onAppear { titleFocused = true }
        .onExitCommand(perform: done)
    }
}

struct DictateSettingsView: View {
    @ObservedObject var model: AppModel
    let openDictionary: () -> Void
    var openModels: () -> Void = {}
    let done: () -> Void

    var body: some View {
        VoiceWorkspaceSettingsSheet(title: "Dictate settings", identifier: "dictate.settings", done: done) {
            VStack(alignment: .leading, spacing: 16) {
                DictateTaskOptions(model: model)
                SettingsRow("Models") {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.modelMessage)
                            Text("Natural text style uses \(CleanupConfigurationStore().snapshot().naturalSummary).")
                            if let line = model.writingModelLine { Text(line) }
                        }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Models…", action: openModels).help("Choose the speech and writing models in Settings › Models")
                    }
                }
                Divider()
                VoiceOptions(model: model)
                Divider()
                SettingsRow("Dictionary") {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Names and spellings to get right.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Your dictionary", action: openDictionary)
                    }
                }
                SettingsRow("Shortcuts app") {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Bundle.main.url(forResource: "Metadata", withExtension: "appintents") != nil
                             ? "Record Audio, then Transcribe with Workbench, then any text action."
                             : "This development build has no Shortcuts actions.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Open Apple Shortcuts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
                    }
                }
            }
        }
    }
}

struct ReadingSettingsView: View {
    @ObservedObject var model: AppModel
    let done: () -> Void

    var body: some View {
        VoiceWorkspaceSettingsSheet(title: "Voice & pace", identifier: "read.settings", done: done) {
            VStack(alignment: .leading, spacing: 20) {
                ReadingProviderView(model: model)
                if model.readingProvider == .mac {
                    MacVoicePanel(voices: model.macVoices, choice: model.voiceChoice, hint: model.voiceHint, rate: $model.rate,
                                  previewing: model.previewingVoice, choose: model.chooseVoice, preview: model.toggleVoicePreview,
                                  openSettings: model.openVoiceSettings)
                        .disabled(model.rendering)
                }
                if model.readingProvider == .neural, model.neuralVoicesDownloaded {
                    NeuralVoicePanel(model: model).disabled(model.rendering)
                }
            }
        }
    }
}

/// Voice and pace for Mac voices. Voices show their accent and quality, a
/// sample can be heard before choosing, and a hint appears while every voice
/// for the person's language is compact.
struct MacVoicePanel: View {
    let voices: [MacVoice]
    let choice: MacVoiceChoice?
    let hint: MacVoiceHint?
    @Binding var rate: Double
    var previewing = false
    var choose: (String) -> Void
    var preview: () -> Void
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Voice").font(Workbench.sectionTitle)
                    HStack(spacing: 6) {
                        Picker("Voice", selection: Binding(get: { choice?.voice?.id ?? "" }, set: choose)) {
                            if case .missing(let name) = choice { Text("\(name) (not installed)").tag("") }
                            ForEach(voices) { Text($0.label).tag($0.id) }
                        }.labelsHidden().frame(width: 270, alignment: .leading)
                        Button(action: preview) { Image(systemName: previewing ? "stop.fill" : "speaker.wave.2") }
                            .buttonStyle(.borderless)
                            .disabled(choice?.voice == nil || choice?.voice?.sayOnly == true)
                            .help(previewing ? "Stop the sample" : "Hear a short sample of this voice")
                            .accessibilityLabel(previewing ? "Stop voice sample" : "Hear voice sample")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Pace").font(Workbench.sectionTitle)
                        Spacer()
                        Text("\(Int(rate)) words/min").monospacedDigit().font(.caption).foregroundStyle(.secondary)
                    }
                    Slider(value: $rate, in: 100...300, step: 10).accessibilityLabel("Reading pace")
                }
            }
            if case .missing(let name) = choice {
                Label("\(name) is not installed on this Mac. Choose another voice.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let hint { MacVoiceHintRow(hint: hint, open: openSettings) }
        }.padding(20).background(panelColor, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Position, scrubber and 15-second skips for the loaded reading. While a Mac
/// voice is still rendering, the range covers only what exists.
struct ReadingPlaybackStrip: View {
    let elapsed: Double
    let duration: Double
    var renderingAhead = false
    var seek: (TimeInterval) -> Void
    var skip: (TimeInterval) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button { skip(-15) } label: { Image(systemName: "gobackward.15") }
                .help("Back 15 seconds").accessibilityLabel("Back 15 seconds")
            Text(time(elapsed)).monospacedDigit().frame(minWidth: 34, alignment: .trailing)
                .accessibilityLabel("Elapsed time").accessibilityValue(time(elapsed))
            Slider(value: Binding(get: { elapsed }, set: { seek($0) }), in: 0...max(duration, 0.001))
                .accessibilityLabel("Reading position")
                .accessibilityValue("\(time(elapsed)) of \(time(duration))\(renderingAhead ? ", more is being prepared" : "")")
            HStack(spacing: 4) {
                Text(time(duration)).monospacedDigit()
                if renderingAhead { ProgressView().controlSize(.mini).help("Preparing the rest of the reading") }
            }.frame(minWidth: 34, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Reading duration").accessibilityValue(time(duration) + (renderingAhead ? ", still preparing" : ""))
            Button { skip(15) } label: { Image(systemName: "goforward.15") }
                .help("Forward 15 seconds").accessibilityLabel("Forward 15 seconds")
        }
        .font(.system(size: 11))
    }
}

struct DictionaryView: View {
    @ObservedObject var model: AppModel
    @State private var heard = ""
    @State private var written = ""
    @State private var saveError: String?
    /// What saving the fields would do, decided by the same rule as Remember correction.
    private var change: Result<CorrectionRuleChange, Error>? {
        guard !heard.isEmpty, !written.isEmpty else { return nil }
        return Result { try CorrectionRule.change(heard: heard, written: written, replacements: model.replacements) }
    }
    var body: some View {
        let change = self.change
        let pending = try? change?.get()
        VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
            Button { model.page = "dictate" } label: { Label("Back to Dictate", systemImage: "chevron.left") }
                .buttonStyle(.link)
            WorkbenchPageHeader("dictionary", summary: "Names and spellings for future dictations.")
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) { Text("Heard").font(Workbench.sectionTitle); TextField("e.g. git hub", text: $heard).accessibilityLabel("Heard") }
                    Image(systemName: "arrow.right").padding(.bottom, 7).foregroundStyle(mint)
                    VStack(alignment: .leading, spacing: 8) { Text("Write instead").font(Workbench.sectionTitle); TextField("e.g. GitHub", text: $written).accessibilityLabel("Write instead") }
                    Button(pending?.updatesExisting == true ? "Update" : "Add") { save(pending) }
                        .disabled(pending == nil || pending?.isAlreadySaved == true)
                }
                if let note = note(for: change) {
                    Text(note.text).font(.system(size: 12)).foregroundStyle(note.warning ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.textFieldStyle(.roundedBorder).controlSize(.large).padding(20).background(panelColor, in: RoundedRectangle(cornerRadius: 12))
            ForEach(CorrectionRule.conflicts(in: model.replacements), id: \.[0].id) { rules in conflict(rules) }
            if model.replacements.isEmpty {
                Text("No corrections yet. Add a name or phrase above when you need one.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.replacements) { item in
                        HStack { Text(item.heard).frame(maxWidth: .infinity, alignment: .leading); Image(systemName: "arrow.right").foregroundStyle(mint); Text(item.written).frame(maxWidth: .infinity, alignment: .leading); Button { model.removeReplacement(item) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Remove correction") }
                            .font(.system(size: 13)).padding(16).background(panelColor, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .onChange(of: heard) { _, _ in saveError = nil }
        .onChange(of: written) { _, _ in saveError = nil }
    }

    private func save(_ change: CorrectionRuleChange?) {
        guard let change else { return }
        do {
            if change.updatesExisting { try model.updateReplacement(heard: heard, written: written) }
            else { try model.addReplacement(heard: heard, written: written) }
            heard = ""; written = ""; saveError = nil
        } catch { saveError = error.localizedDescription }
    }

    /// The saved value before Update, a validation problem, or nothing for a new phrase.
    private func note(for change: Result<CorrectionRuleChange, Error>?) -> (text: String, warning: Bool)? {
        if let saveError { return (saveError, true) }
        switch change {
        case .none: return nil
        case .failure(CorrectionRuleError.duplicateRules(let heard, let count)):
            return ("“\(heard)” has \(count) rules. Choose the spelling to keep below.", true)
        case .failure(let error): return (error.localizedDescription, true)
        case .success(let change):
            if change.isAlreadySaved { return ("Already in your dictionary.", false) }
            guard let previous = change.previousRule else { return nil }
            return ("“\(previous.heard)” currently writes “\(previous.written)”. Update changes future dictations only.", false)
        }
    }

    /// Rules saved by earlier versions can share a phrase. The card names what
    /// dictation writes for it today, from every rule in order, shows every
    /// value and lets one explicit choice settle it.
    private func conflict(_ rules: [Replacement]) -> some View {
        let spellings = rules.map(\.written).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return VStack(alignment: .leading, spacing: 10) {
            Label(spellings.count > 1
                  ? "“\(rules[0].heard)” has \(rules.count) rules. Dictation writes “\(CorrectionRule.currentOutput(for: rules[0].heard, in: model.replacements))”."
                  : "“\(rules[0].heard)” is saved \(rules.count) times.", systemImage: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .medium))
            Text("Keep one spelling. Only this phrase’s other rules are removed.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(spellings, id: \.self) { spelling in
                    Button(spellings.count > 1 ? "Keep “\(spelling)”" : "Keep one") {
                        guard let chosen = rules.first(where: { $0.written == spelling }) else { return }
                        do { try model.resolveReplacementConflict(keeping: chosen) }
                        catch { model.report(error.localizedDescription, on: .dictate) }
                    }.accessibilityLabel("Keep \(spelling) for \(rules[0].heard)")
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ReadingSelectionReviewCard: View {
    let selection: ReadingSelectionImport
    let limitMessage: String?
    var replacingDisabled = false
    /// Why Replace reading is unavailable for now, shown under the choice.
    var waitReason: String? = nil
    let keep: () -> Void
    let replace: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(selection.origin.name) is ready to review", systemImage: "text.quote")
                .font(.headline).foregroundStyle(mint)
            ScrollView {
                Text(selection.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    .accessibilityLabel("Text to review")
                    .accessibilityValue(selection.text)
            }.frame(minHeight: 56, maxHeight: 120).padding(12).background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            Text("Your current reading stays unchanged until you choose Replace reading. " + selection.origin.keepNote)
                .font(.caption).foregroundStyle(.secondary)
            if let limitMessage {
                Label(limitMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Keep current", action: keep)
                Button("Replace reading", action: replace)
                    .buttonStyle(PrimaryButton()).disabled(replacingDisabled)
                    .accessibilityHint("Replaces the reading draft and stops any reading in progress. It does not start audio or send text online.")
            }
            if let waitReason {
                Label(waitReason, systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).background(mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Review imported selected text")
    }
}

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 20).padding(.vertical, 12)
            .foregroundStyle(Workbench.background).opacity(enabled ? 1 : 0.4).background(mint.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
struct WaveBars: View {
    let level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View { HStack(spacing: 3) { ForEach(0..<16) { index in RoundedRectangle(cornerRadius: 2).fill(mint).frame(width: 3, height: 3 + level * Double([10, 18, 12, 22, 15, 24, 16, 10][index % 8])) } }.animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: level) }
}
func time(_ seconds: Double) -> String { String(format: "%d:%02d", max(0, Int(seconds)) / 60, max(0, Int(seconds)) % 60) }
