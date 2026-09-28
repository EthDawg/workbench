import SwiftUI
import AppKit

private let ink = Workbench.background
private let panelColor = Workbench.surface
private let mint = Workbench.accent

struct ContentView: View {
    @ObservedObject var model: AppModel
    /// The Workbench window embeds this view for the dictate, speak, library and
    /// dictionary pages; each page draws its own title, so no shared chrome.
    var embedded = true
    @State private var showOriginal = false
    @State private var showCorrection = false
    @State private var selectedCorrection = ""
    @State private var correctionSeed = ""
    @State private var correctionDraft = ""
    @State private var confirmingRecoveryDiscard = false
    /// On Read, a stopped reading shows beside Listen with Retry, not in the banner as well.
    private var bannerError: String? {
        guard let error = model.error else { return nil }
        if model.page == "speak", let failure = model.readingFailure, error == failure.message { return nil }
        return error
    }
    /// What just happened. On Dictate a copy for ⌘V reads as the finished result it is (#165).
    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle().fill(model.phase == .recording ? .red : mint).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
                if let error = bannerError {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(error).font(.system(size: 12)).textSelection(.enabled)
                        Spacer()
                        Button { model.dismissError() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss error")
                    }.padding(14).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                }
                Group {
                    switch model.page {
                    case "speak": speak
                    case "library": DemoLibraryView(library: model.library, model: model)
                    case "dictionary": DictionaryView(model: model)
                    default: dictate
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Read and the dictionary show the model's status here. Dictate shows it inside its
                // task region with the result it reports, and Library's sections keep their own.
                if ["speak", "dictionary"].contains(model.page) { statusLine }
            }.padding(Workbench.pagePadding).background(ink)
        }
        // Embedded, a page takes the height its window gives it, below Library's switcher too.
        .frame(minWidth: 650, minHeight: embedded ? nil : 680)
        .tint(mint).workbenchTheme()
        .sheet(isPresented: $showOriginal) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Original transcript").font(.title2.weight(.semibold))
                Text("Your unedited words are kept so you can check any cleanup.").foregroundStyle(.secondary)
                ScrollView { Text(model.rawTranscript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 240)
                HStack { Button("Restore original") { model.useOriginal(); showOriginal = false }; Spacer(); Button("Done") { showOriginal = false }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 560, height: 380)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
        .sheet(isPresented: $showCorrection) {
            RememberCorrectionView(model: model, heard: correctionSeed, draft: correctionDraft)
        }
        .confirmationDialog("Discard capture recovery?", isPresented: $confirmingRecoveryDiscard, titleVisibility: .visible) {
            Button("Discard recovery", role: .destructive) { model.discardCaptureRecovery() }
            Button("Keep recovery", role: .cancel) { }
        } message: {
            Text("This removes the kept recording and its pending save. Your current draft stays open. Copy or Save text first if you need another copy.")
        }
        .modifier(CorrectionSelectionObserver(transcript: model.transcript,
            active: model.page == "dictate" && !showCorrection, selection: $selectedCorrection))
    }

    /// One task region (#134): the microphone, where the words go and how they are tidied, and
    /// the result, in one card; then the meeting link, recovery, Dictate's other options and the
    /// Apple Shortcuts caption. The page scrolls only when the window is shorter than that, and
    /// the editor takes any spare height. The microphone is the page's one accent action; Copy
    /// text and the result's other actions stay neutral.
    private var dictate: some View {
        GeometryReader { proxy in ScrollView {
            VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
            WorkbenchPageHeader("dictate", summary: "Turn a thought into text. Record here, or use the shortcut from any app.")
            VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
            HStack(spacing: 22) {
                Button { model.toggleRecording() } label: {
                    Image(systemName: model.phase == .requesting ? "xmark" : model.phase == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 27)).frame(width: 66, height: 66)
                        .foregroundStyle(ink).background(model.phase == .recording ? Color.red.opacity(0.9) : mint, in: Circle())
                }.buttonStyle(.plain).disabled(!model.ready || ![.idle, .requesting, .recording].contains(model.phase) || model.rendering)
                    .accessibilityLabel(model.phase == .requesting ? "Cancel microphone request" : model.phase == .recording ? "Stop recording" : "Start recording")
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.phase == .requesting ? "Waiting for microphone access" : model.phase == .recording ? "Listening to you" : model.phase == .cleaning ? "Tidying your words…" : model.phase == .transcribing ? "Finding your words…" : model.phase == .delivering ? "Delivering text…" : model.phase == .cancelling ? "Cancelling…" : "Ready for your next thought")
                        .font(Workbench.sectionTitle)
                    HStack(spacing: 10) {
                        if model.phase == .recording {
                            WaveBars(level: model.level).frame(width: 100, height: 22)
                            Text(time(model.elapsed)).monospacedDigit()
                            Button("Discard") { model.cancelRecording() }.buttonStyle(.plain).foregroundStyle(.secondary)
                        } else if model.phase == .requesting {
                            Text("Allow access in the macOS prompt, or cancel this attempt.")
                        } else if [.transcribing, .cleaning, .delivering, .cancelling].contains(model.phase) || model.preparing {
                            ProgressView().controlSize(.small)
                            Text(model.preparing ? "Preparing your speech engine" : model.phase == .cancelling ? "Waiting for the speech engine to stop" : model.phase == .delivering ? "Checking the destination" : model.captureProcessingLabel)
                            if model.canCancelCurrentCapture { Button("Cancel") { model.cancelCurrentCapture() } }
                        } else if model.canRecordAgain {
                            Text("Record again with \(model.preferences.dictationShortcut.label). Previous audio will be kept in Saved recordings.")
                        } else { Text("Click the microphone or use \(model.preferences.dictationShortcut.label). Up to 5 minutes per recording.") }
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            dictateChoices
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    WorkbenchSectionTitle("Your words")
                    Spacer()
                    Button("Remember correction…") {
                        correctionSeed = selectedCorrection
                        correctionDraft = model.transcript
                        showCorrection = true
                    }.disabled(model.transcript.isEmpty || model.phase != .idle)
                        .help("Select a mistaken word or phrase, then remember its spelling for future dictations.")
                    Button("Original…") { showOriginal = true }.disabled(model.rawTranscript.isEmpty)
                    Text("\(TextRules.wordCount(model.transcript)) words").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                editor(text: $model.transcript, placeholder: "Your transcript will appear here.\nYou can edit it before copying or saving.", label: "Transcript")
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
            }.frame(maxHeight: .infinity)
            HStack(spacing: 12) {
                Button { model.copyTranscript() } label: { Label("Copy text", systemImage: "doc.on.doc") }.disabled(model.transcript.isEmpty)
                Button("Clean text") { model.cleanCurrentDraft() }.disabled(model.transcript.isEmpty || model.phase != .idle)
                Button("Save text…") { model.exportTranscript() }.disabled(model.transcript.isEmpty)
                Button("Save prompt") { model.savePrompt(model.transcript) }.disabled(model.transcript.isEmpty)
                Spacer()
                if model.canRetry { Button(model.retryCaptureLabel) { model.retryTranscription() }.help(model.retryCaptureHelp) }
                Button { model.importAudio() } label: { Label("Import audio…", systemImage: "arrow.up.doc") }.disabled(!model.ready || model.phase != .idle)
            }.controlSize(.large)
            statusLine
            }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(panelColor, in: RoundedRectangle(cornerRadius: 16))
            Button("Transcribe a meeting or call…") { model.page = "meeting"; model.onShowEditor?("meeting") }
                .buttonStyle(.link).disabled(model.phase != .idle)
            if model.hasCaptureRecovery && model.phase == .idle {
                HStack {
                    Text(model.canRecordAgain ? "Retry this audio, or record again and keep it for later." : "A capture is kept for recovery.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Show recovery files") { model.showCaptureRecoveryFiles() }
                    Button("Discard recovery…", role: .destructive) { confirmingRecoveryDiscard = true }
                        .disabled(!model.canDiscardCaptureRecovery)
                }.font(.caption)
            }
            if model.hasSavedRecordings {
                Button("Saved recordings…") { model.showSavedRecordings() }
                    .font(.caption).help("Previous audio is kept here. Use Import audio to transcribe a recording again.")
            }
            dictateOptions
            appleShortcutsCaption
            }.frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
        } }
    }

    /// Where the words go and how they are tidied, inside the task region. The surface check
    /// scans this as Dictate's options.
    private var dictateChoices: some View { DictateTaskOptions(model: model) }

    /// Dictate's options live with Dictate (Grammar: options live with their
    /// capability). Same controls and labels as before; Settings keeps one
    /// "Dictate options…" door to here.
    private var dictateOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkbenchSectionTitle("Options")
            VoiceOptions(model: model, showShortcut: false)
            HStack(spacing: 12) {
                Button("Your dictionary") { model.page = "dictionary" }
                Button("Position dictation panel…") { model.showPanelPreview() }.disabled(model.phase != .idle)
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(panelColor, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Audio in, text out through Apple Shortcuts: Dictate's job, so it is noted here.
    private var appleShortcutsCaption: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Bundle.main.url(forResource: "Metadata", withExtension: "appintents") != nil ? "Apple Shortcuts: add Record Audio, then Transcribe with Workbench, then Create Note, Copy to Clipboard, or another text action. Shortcuts handles recording; Workbench returns your words." : "Apple Shortcuts: this development build has no Apple Shortcuts metadata. Use the full-Xcode package for the Transcribe with Workbench action.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Apple Shortcuts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
                .buttonStyle(.link).fixedSize()
        }.font(.system(size: 10)).foregroundStyle(.tertiary)
    }

    /// While text waits for Replace reading or Keep current, the page scrolls,
    /// so the incoming text, the choice and the current draft all stay readable
    /// in a small window. Otherwise the draft fills the page as before.
    @ViewBuilder private var speak: some View {
        if model.pendingReadingSelection != nil { ScrollView { speakPage.padding(.trailing, 12) } }
        else { speakPage }
    }

    private var speakPage: some View {
        VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
            WorkbenchPageHeader("speak", summary: "Paste something to hear it aloud, or save a reading to take with you.")
            if let selection = model.pendingReadingSelection {
                ReadingSelectionReviewCard(selection: selection, limitMessage: model.readingLimitMessage(for: selection.text),
                                           replacingDisabled: !model.canReplaceReading,
                                           waitReason: model.canReplaceReading ? nil : AppModel.replaceWaitsForSave,
                                           keep: model.keepCurrentReading, replace: model.replaceReadingWithSelection)
            }
            ReadingProviderView(model: model)
            if model.readingProvider == .mac {
                MacVoicePanel(voices: model.macVoices, choice: model.voiceChoice, hint: model.voiceHint, rate: $model.rate,
                              previewing: model.previewingVoice, choose: model.chooseVoice, preview: model.toggleVoicePreview,
                              openSettings: model.openVoiceSettings)
                    .disabled(model.rendering)
            }
            if let reading = model.followAlongText {
                ReadingFollowAlongView(text: reading, highlight: model.readingHighlight)
                    .background(RoundedRectangle(cornerRadius: 12).fill(panelColor.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.07)))
                    .frame(minHeight: 150, maxHeight: .infinity)
            } else {
                editor(text: $model.speechText, placeholder: "Paste an article, a draft, or a thought.\nLet your Mac do the reading.", label: "Text to read").disabled(model.rendering)
            }
            HStack {
                Text("\(model.speechText.count.formatted()) / \(model.readingLimit.formatted()) characters").font(.system(size: 10))
                    .foregroundStyle(model.speechText.count > model.readingLimit ? Color.orange : Color.secondary.opacity(0.6))
                Spacer()
            }
            if let limit = model.readingLimitMessage(for: model.speechText) {
                Label(limit, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .accessibilityLabel("Reading limit: \(limit)")
            }
            if model.playing || model.paused {
                ReadingPlaybackStrip(elapsed: model.playbackTime, duration: model.audioDuration, renderingAhead: model.renderingAhead,
                                     seek: model.seekReading, skip: model.skipReading)
                    .disabled(!model.canSeekReading)
            } else if let failure = model.readingFailure {
                HStack(spacing: 10) {
                    Label(failure.message, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange)
                    Spacer()
                    Button("Retry") { model.retryReading() }.disabled(!model.canRetryReading)
                        .accessibilityHint("Makes new audio and reads from the start")
                    Button { model.dismissReadingFailure() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        .accessibilityLabel("Dismiss reading error")
                }
            }
            HStack(spacing: 12) {
                Button { model.listen() } label: { Label(model.rendering ? "Making audio…" : model.playing ? "Pause" : model.paused ? "Resume" : "Listen", systemImage: model.playing ? "pause.fill" : "play.fill") }
                    .buttonStyle(PrimaryButton()).disabled(model.speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.rendering || model.phase != .idle || model.speechText.count > model.readingLimit)
                if model.readingGenerationActive { Button("Cancel generation") { model.cancelReading() } }
                if model.playing || model.paused { Button("Stop") { model.stopPlayback() } }
                Spacer()
                Button { model.saveAudio() } label: { Label("Save audio…", systemImage: "square.and.arrow.down") }.disabled(model.speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.rendering || model.renderingAhead || model.speechText.count > model.readingLimit)
            }.controlSize(.large)
            Text("Saved audio is M4A, ready for QuickTime, Music, or sharing.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func editor(text: Binding<String>, placeholder: String, label: String) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12).fill(panelColor.opacity(0.6))
            if text.wrappedValue.isEmpty { Text(placeholder).font(.system(size: 15)).foregroundStyle(.tertiary).lineSpacing(7).padding(20).allowsHitTesting(false) }
            TextEditor(text: text).font(.system(size: 15)).lineSpacing(6).scrollContentBackground(.hidden).padding(14).accessibilityLabel(label)
        }.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.07))).frame(minHeight: 150, maxHeight: .infinity)
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
            WorkbenchPageHeader("dictionary", summary: "Correct names and specialist terms after transcription. Matches whole words and phrases, ignoring case.")
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
