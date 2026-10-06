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

    @State private var showRecovery = false
    @State private var selectedCorrection = ""
    @State private var correctionSeed = ""
    @State private var correctionDraft = ""
    @State private var confirmingRecoveryDiscard = false
    @State private var dictateResult: String?

    @State private var dictateActionID = UUID()
    /// Measured so the transcript card fills the window above the recovery card at any text size.
    @State private var headerHeight: CGFloat = 52
    @State private var recoveryHeight: CGFloat = 0

    @Environment(\.pageSectionFrames) private var sectionFrames

    /// A problem stays on the workspace that owns it. Read's typed playback failure already
    /// has its own Retry beside the transport, so it is never repeated in the page banner.
    private var bannerError: String? {
        guard let attention = model.attention else { return nil }
        let belongsHere = ["dictate", "dictionary"].contains(model.page) && attention.page == .dictate
        guard belongsHere else { return nil }
        return attention.message
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
            if let error = bannerError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).accessibilityHidden(true)
                    Text(error).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    // The fix is in System Settings, so the page opens it beside the microphone refusal
                    // itself. The Mac's microphone setting says nothing about which problem this is.
                    if model.canOpenMicrophoneSettings {
                        Button("Microphone Settings…") { model.openMicrophoneSettings() }.controlSize(.small)
                            .help("Open Privacy & Security › Microphone in System Settings")
                    }
                    Button { model.dismissError() } label: { Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss error")
                }.padding(14).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            }
            Group {
                switch model.page {
                case _ where WorkbenchHome.destination(model.page).section == "library": DemoLibraryView(library: model.library, model: model,
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
            dictateResult = nil; dictateActionID = UUID()
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
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
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
                        }.voicePageCard()
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
                        }.voicePageCard()
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
                            Text("\(TextRules.wordCount(model.transcript)) words").font(.caption).foregroundStyle(.secondary)
                        }
                        editor(text: $model.transcript, placeholder: transcriptPlaceholder, label: "Transcript")
                        rememberedCorrection
                        HStack(spacing: 12) {
                            // The page's one prominent action once there are words; the microphone stays the hero.
                            Button { dictateResult = nil; model.copyTranscript() } label: { Label("Copy text", systemImage: "doc.on.doc") }
                                .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                                .help("Copy text (⌘↩)").disabled(model.transcript.isEmpty)
                            transcriptActions
                            Spacer()
                        }.controlSize(.large)
                        if let dictateResult { workspaceResult(dictateResult) { self.dictateResult = nil } }
                        else { DictateDeliveryReceipt(receipts: model.clipboardReceipt) }
                        }
                    }
                    .padding(Workbench.tilePadding)
                    .frame(maxWidth: .infinity, minHeight: max(360, proxy.size.height - headerHeight - Workbench.sectionSpacing
                                                                 - (hasRecoverySection ? recoveryHeight + Workbench.sectionSpacing : 0)), alignment: .topLeading)
                    .background(panelColor, in: RoundedRectangle(cornerRadius: Workbench.tileRadius))
                    .overlay(RoundedRectangle(cornerRadius: Workbench.tileRadius).strokeBorder(Workbench.border))
                    if hasRecoverySection {
                        captureRecovery.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { recoveryHeight = $0 }
                    }
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
        WorkbenchPageHeader("dictate", summary: "Speak instead of typing. Your words are ready to paste, or to edit here.") {
            Button("Import audio…") { dictateResult = nil; model.importAudio() }.disabled(!model.ready || model.phase != .idle)
            Button("Settings…") { showDictateSettings = true }.accessibilityLabel("Dictate settings")
        }
    }


    private var captureControls: some View {
        HStack(spacing: 14) {
            Button { dictateResult = nil; model.toggleRecording() } label: {
                Image(systemName: model.phase == .requesting ? "xmark" : model.phase == .recording ? "stop.fill" : "mic.fill")
                    .font(.title).frame(width: 48, height: 48)
                    .foregroundStyle(ink).background(model.phase == .recording ? Color.red.opacity(0.9) : mint, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canToggleRecording)
            .accessibilityLabel(model.phase == .requesting ? "Cancel microphone request" : model.phase == .recording ? "Finish dictation" : "Start recording")
            VStack(alignment: .leading, spacing: 5) {
                Text(captureTitle).font(Workbench.sectionTitle)
                if model.phase == .recording {
                    HStack(spacing: 10) {
                        WaveBars(level: model.voiceSession.phase == .paused || model.voiceSession.phase == .reconnecting ? 0 : model.level).frame(width: 96, height: 28)
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
                        if model.preparing { Button("Cancel setup") { model.cancelSpeechPreparation() }.disabled(model.recognition.phase == .cancelling) }
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
                    Button("Models") { model.page = "models" }.buttonStyle(.link).font(.caption)
                        .help("Choose the speech and writing models in Settings › Models")
                }
                // The writing model's download, or why it stopped, beside the models it concerns (#134).
                if let line = model.writingModelLine {
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if model.phase == .idle {
            Button("Models") { model.page = "models" }.buttonStyle(.link).font(.caption)
        }
    }

    private var captureTitle: String {
        if model.preparing && model.phase == .idle { return "Preparing dictation…" }
        switch model.phase {
        case .idle: return model.idleMicrophoneTitle ?? (model.ready ? "Ready to dictate" : "Dictation unavailable")
        case .requesting: return "Waiting for microphone access"
        // A capture without a live session (file-based dictation) is still recording, never "Ready".
        case .recording: return model.voiceSession.phase == .idle ? "Recording" : model.voiceSession.recordingTitle
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

    /// The empty transcript says how to fill it, with the shortcut as it is saved.
    private var transcriptPlaceholder: String {
        let shortcut = model.preferences.dictationShortcut
        guard shortcut.enabled else { return "Click the microphone. Your words appear here." }
        return (model.preferences.capture == .hold ? "Hold " : "Press ") + shortcut.label + " or click the microphone. Your words appear here."
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
        }.fixedSize().controlSize(.large).accessibilityLabel("More transcript actions")
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
                Button { model.dismissRememberedCorrection() } label: { Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss remembered correction")
            }.font(.callout).padding(12).background(mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
                        Button("Saved recordings") { model.showSavedRecordings() }
                            .help("Use Import audio to transcribe a saved recording again.")
                    }
                }.controlSize(.small)
            }.padding(.top, 10)
        } label: {
            Label(hasCurrentRecovery ? "Capture recovery" : "Saved recordings", systemImage: hasCurrentRecovery ? "arrow.counterclockwise" : "archivebox")
                .font(.callout)
        }.voicePageCard()
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











    private func workspaceResult(_ message: String, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel("Dismiss result")
        }
    }

    private func editor(text: Binding<String>, placeholder: String, label: String) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12).fill(ink.opacity(0.5))
            // 15 pt on a standard Mac, the reading size Meetings' transcript shares; it grows with larger text.
            if text.wrappedValue.isEmpty { Text(placeholder).font(.title3).foregroundStyle(.secondary).lineSpacing(7).padding(20).allowsHitTesting(false) }
            TextEditor(text: text).font(.title3).lineSpacing(6).scrollContentBackground(.hidden).padding(14).accessibilityLabel(label)
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
                content().frame(maxWidth: .infinity, alignment: .leading)
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
                        Button("Models", action: openModels).help("Choose the speech and writing models in Settings › Models")
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







struct DictionaryView: View {
    @ObservedObject var model: AppModel
    @State private var heard = ""
    @State private var written = ""
    @State private var saveError: String?
    @FocusState private var heardFocused: Bool
    /// What saving the fields would do, decided by the same rule as Remember correction.
    private var change: Result<CorrectionRuleChange, Error>? {
        guard !heard.isEmpty, !written.isEmpty else { return nil }
        return Result { try CorrectionRule.change(heard: heard, written: written, replacements: model.replacements) }
    }
    var body: some View {
        let change = self.change
        let pending = try? change?.get()
        VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
            // The title sits where every other page has it; the way back is the header's door.
            WorkbenchPageHeader("dictionary", summary: "Names and spellings for future dictations.") {
                Button { model.page = "dictate" } label: { Label("Back to Dictate", systemImage: "chevron.left") }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Heard").font(Workbench.sectionTitle)
                        TextField("e.g. git hub", text: $heard).accessibilityLabel("Heard").focused($heardFocused)
                            .onSubmit { save(pending) }
                    }
                    Image(systemName: "arrow.right").padding(.bottom, 7).foregroundStyle(mint).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Write instead").font(Workbench.sectionTitle)
                        TextField("e.g. GitHub", text: $written).accessibilityLabel("Write instead").onSubmit { save(pending) }
                    }
                    Button(pending?.updatesExisting == true ? "Update" : "Add") { save(pending) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(pending == nil || pending?.isAlreadySaved == true)
                }
                if let note = note(for: change) {
                    if note.warning { VoiceAttentionNote(text: note.text, font: .callout) }
                    else { Text(note.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }.textFieldStyle(.roundedBorder).controlSize(.large).voicePageCard()
            ForEach(CorrectionRule.conflicts(in: model.replacements), id: \.[0].id) { rules in conflict(rules) }
            if model.replacements.isEmpty {
                Text("No corrections yet. Add a name or phrase above when you need one.").font(.callout).foregroundStyle(.secondary)
            } else {
                // One card holding the list, a row per correction, as a native grouped list reads.
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.replacements.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider() }
                            HStack {
                                Text(item.heard).frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "arrow.right").foregroundStyle(mint).accessibilityHidden(true)
                                Text(item.written).frame(maxWidth: .infinity, alignment: .leading)
                                Button { model.removeReplacement(item) } label: { Image(systemName: "trash").frame(width: 24, height: 24).contentShape(Rectangle()) }
                                    .buttonStyle(.borderless).accessibilityLabel("Remove \(item.heard) to \(item.written)")
                                    .help("Remove this correction")
                            }.font(.body).padding(.vertical, 10)
                        }
                    }.padding(.horizontal, Workbench.tilePadding).padding(.vertical, 6)
                        .background(Workbench.surface, in: RoundedRectangle(cornerRadius: Workbench.tileRadius))
                        .overlay(RoundedRectangle(cornerRadius: Workbench.tileRadius).strokeBorder(Workbench.border))
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
            heard = ""; written = ""; saveError = nil; heardFocused = true
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
            Label {
                Text(spellings.count > 1
                     ? "“\(rules[0].heard)” has \(rules.count) rules. Dictation writes “\(CorrectionRule.currentOutput(for: rules[0].heard, in: model.replacements))”."
                     : "“\(rules[0].heard)” is saved \(rules.count) times.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Workbench.attention).accessibilityHidden(true)
            }.font(.body.weight(.medium))
            Text("Keep one spelling. Only this phrase’s other rules are removed.")
                .font(.callout).foregroundStyle(.secondary)
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
        .padding(Workbench.tilePadding).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: Workbench.tileRadius))
    }
}



/// Home's first-dictation button. Disabled, its label stays readable (secondary on a quaternary
/// fill) rather than fading the accent's dark label into an almost-matching background.
struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return configuration.label.font(.callout.weight(.semibold)).padding(.horizontal, 20).padding(.vertical, 12)
            .foregroundStyle(enabled ? AnyShapeStyle(Workbench.background) : AnyShapeStyle(.secondary))
            .background { if enabled { shape.fill(mint.opacity(configuration.isPressed ? 0.75 : 1)) } else { shape.fill(.quaternary) } }
    }
}
/// The live level, tallest in the middle (voice-waveform decision): sixteen bars on one sine arch.
struct WaveBars: View {
    let level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<16) { index in
                RoundedRectangle(cornerRadius: 2).fill(mint)
                    .frame(width: 3, height: 3 + level * 24 * sin(.pi * (Double(index) + 0.5) / 16))
            }
        }.animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: level)
    }
}

extension View {
    /// The page kit's card (docs/desktop.md § Page kit) for a container that is not a titled
    /// WorkbenchTile: 16 pt inside, 12 pt corners, the control surface and its hairline, which
    /// macOS 26 needs because the window and control backgrounds are the same colour.
    func voicePageCard() -> some View {
        padding(Workbench.tilePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Workbench.surface, in: RoundedRectangle(cornerRadius: Workbench.tileRadius))
            .overlay(RoundedRectangle(cornerRadius: Workbench.tileRadius).strokeBorder(Workbench.border))
    }
}

/// A failure or warning in words: the text in the primary colour so it stays readable, and an
/// orange symbol for attention (orange and red text fail contrast on a light card).
struct VoiceAttentionNote: View {
    let text: String
    var font: Font = .callout
    var body: some View {
        Label {
            Text(text).foregroundStyle(.primary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Workbench.attention).accessibilityHidden(true)
        }.font(font)
    }
}
func time(_ seconds: Double) -> String { String(format: "%d:%02d", max(0, Int(seconds)) / 60, max(0, Int(seconds)) % 60) }
