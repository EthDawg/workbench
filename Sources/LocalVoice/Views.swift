import SwiftUI
import AppKit

private let ink = Workbench.background
private let panelColor = Workbench.surface
private let mint = Workbench.accent

struct ContentView: View {
    @ObservedObject var model: AppModel
    var embedded = false
    @State private var showOriginal = false
    @State private var showCorrection = false
    @State private var selectedCorrection = ""
    @State private var correctionSeed = ""
    @State private var correctionDraft = ""
    var body: some View {
        HStack(spacing: 0) {
            if !embedded { sidebar }
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Label(model.page == "speak" && model.readingProvider == .speko ? "SPEKO · ONLINE READING" : "SPEECH & TEXT", systemImage: model.page == "speak" && model.readingProvider == .speko ? "network" : "waveform").font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(mint)
                    Spacer()
                    ShortcutControl(model: model, id: 1, title: "Dictation").frame(width: 300)
                }
                if let error = model.error {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(error).font(.system(size: 12)).textSelection(.enabled)
                        Spacer()
                        Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss error")
                    }.padding(14).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                }
                Group {
                    switch model.page {
                    case "speak": speak
                    case "history": history
                    case "library": DemoLibraryView(library: model.library, model: model)
                    case "dictionary": DictionaryView(model: model)
                    case "settings": settings
                    case "shortcuts": shortcuts
                    default: dictate
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                HStack(spacing: 8) {
                    Circle().fill(model.phase == .recording ? .red : mint).frame(width: 6, height: 6)
                    Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Text("WORKBENCH  /  \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")\(Workbench.isPreview ? " PREVIEW" : "")").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(.tertiary)
                }
            }.padding(32).background(ink)
        }
        .frame(minWidth: embedded ? 650 : 900, minHeight: 680)
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
        .modifier(CorrectionSelectionObserver(transcript: model.transcript,
            active: model.page == "dictate" && !showCorrection, selection: $selectedCorrection))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkbenchHeader(title: "Voice", subtitle: "A little less typing.", symbol: "waveform")
                .padding(.bottom, 24).padding(.top, 12)
            nav("dictate", "Dictate", "mic")
            nav("speak", "Read aloud", "speaker.wave.2")
            Divider().padding(.vertical, 14)
            nav("history", "Recent transcripts", "clock")
            nav("library", "Demo library", "square.stack.3d.up")
            nav("dictionary", "Your dictionary", "text.book.closed")
            nav("shortcuts", "Shortcuts", "command")
            nav("settings", "Settings", "slider.horizontal.3")
            Spacer()
            WorkbenchSwitcher { model.stopPlayback() }.disabled(model.phase != .idle)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Circle().fill(model.ready ? mint : .orange).frame(width: 6, height: 6)
                    Text(model.ready ? "Local engine ready" : "Preparing engine").font(.system(size: 11, weight: .medium))
                }
                Text(model.ready ? (model.readingProvider == .speko ? "Local dictation.\nSpeko reading sends text online." : "No account. No usage meter.\nYour words stay here.") : model.modelMessage).font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4)
                if !model.ready && !model.preparing { Button("Retry model") { Task { await model.prepare() } }.font(.system(size: 11)) }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(panelColor, in: RoundedRectangle(cornerRadius: 12))
        }.padding(20).frame(width: 210).background(Workbench.surface.opacity(0.65))
    }
    private func nav(_ page: String, _ title: String, _ icon: String) -> some View {
        Button { model.page = page } label: {
            HStack(spacing: 10) { Image(systemName: icon).frame(width: 18); Text(title); Spacer() }
                .font(.system(size: 12, weight: model.page == page ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 12)
                .foregroundStyle(model.page == page ? mint : .secondary)
                .background(model.page == page ? mint.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 34, weight: .semibold)).tracking(-1)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3)
        }
    }

    private var dictate: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Speak your mind.", "Turn a thought into text. Record here, or use the shortcut from any app.")
            HStack(spacing: 22) {
                Button { model.toggleRecording() } label: {
                    Image(systemName: model.phase == .requesting ? "xmark" : model.phase == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 27)).frame(width: 66, height: 66)
                        .foregroundStyle(ink).background(model.phase == .recording ? Color.red.opacity(0.9) : mint, in: Circle())
                }.buttonStyle(.plain).disabled(!model.ready || ![.idle, .requesting, .recording].contains(model.phase) || model.rendering)
                    .accessibilityLabel(model.phase == .requesting ? "Cancel microphone request" : model.phase == .recording ? "Stop recording" : "Start recording")
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.phase == .requesting ? "Waiting for microphone access" : model.phase == .recording ? "Listening to you" : model.phase == .cleaning ? "Tidying your words…" : model.phase == .transcribing ? "Finding your words…" : model.phase == .delivering ? "Delivering text…" : model.phase == .cancelling ? "Cancelling…" : "Ready for your next thought")
                        .font(.system(size: 16, weight: .medium))
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
                        } else { Text("Click the microphone or use \(model.preferences.dictationShortcut.label)") }
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(panelColor, in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("YOUR WORDS").font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary)
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
                            catch { model.error = error.localizedDescription }
                        }.disabled(model.phase != .idle)
                        Button { model.dismissRememberedCorrection() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss remembered correction")
                    }.font(.system(size: 12)).padding(12).background(mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }.frame(maxHeight: .infinity)
            HStack(spacing: 12) {
                Button { model.copyTranscript() } label: { Label("Copy text", systemImage: "doc.on.doc") }.buttonStyle(PrimaryButton()).disabled(model.transcript.isEmpty)
                Button("Clean text") { model.cleanCurrentDraft() }.disabled(model.transcript.isEmpty || model.phase != .idle)
                Button("Save text…") { model.exportTranscript() }.disabled(model.transcript.isEmpty)
                Button("Save prompt") { model.savePrompt(model.transcript) }.disabled(model.transcript.isEmpty)
                Spacer()
                if model.canRetry { Button("Retry transcription") { model.retryTranscription() } }
                Button { model.importAudio() } label: { Label("Import audio…", systemImage: "arrow.up.doc") }.disabled(!model.ready || model.phase != .idle)
            }.controlSize(.large)
            Text(model.preferences.delivery == .paste ? "Automatic paste returns to your starting text field. Up to 5 minutes per recording." : "Finished transcripts are copied. Paste with ⌘V. Up to 5 minutes per recording.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private var speak: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Give your words a voice.", "Paste something to hear it aloud, or save a reading to take with you.")
            if let selection = model.pendingReadingSelection {
                ReadingSelectionReviewCard(selection: selection, limitMessage: model.readingLimitMessage(for: selection.text),
                                           replacingDisabled: model.rendering,
                                           keep: model.keepCurrentReading, replace: model.replaceReadingWithSelection)
            }
            ReadingProviderView(model: model)
            if model.readingProvider == .mac { HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("VOICE").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
                    Picker("Voice", selection: $model.voice) { ForEach(model.voices, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 220)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("PACE").tracking(1.4); Spacer(); Text("\(Int(model.rate)) words/min").monospacedDigit() }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Slider(value: $model.rate, in: 100...300, step: 10).accessibilityLabel("Reading pace")
                }
            }.padding(20).background(panelColor, in: RoundedRectangle(cornerRadius: 14)).disabled(model.rendering) }
            editor(text: $model.speechText, placeholder: "Paste an article, a draft, or a thought.\nLet your Mac do the reading.", label: "Text to read").disabled(model.rendering)
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
                HStack(spacing: 12) {
                    Button { model.skipReading(by: -15) } label: { Image(systemName: "gobackward.15") }
                        .help("Back 15 seconds").accessibilityLabel("Back 15 seconds")
                    Text(time(model.playbackTime)).monospacedDigit().frame(minWidth: 34, alignment: .trailing)
                        .accessibilityLabel("Elapsed time").accessibilityValue(time(model.playbackTime))
                    Slider(value: Binding(get: { model.playbackTime }, set: { model.seekReading(to: $0) }),
                           in: 0...max(model.audioDuration, 0.001))
                        .accessibilityLabel("Reading position")
                        .accessibilityValue("\(time(model.playbackTime)) of \(time(model.audioDuration))")
                    Text(time(model.audioDuration)).monospacedDigit().frame(minWidth: 34, alignment: .leading)
                        .accessibilityLabel("Reading duration").accessibilityValue(time(model.audioDuration))
                    Button { model.skipReading(by: 15) } label: { Image(systemName: "goforward.15") }
                        .help("Forward 15 seconds").accessibilityLabel("Forward 15 seconds")
                }
                .font(.system(size: 11)).disabled(!model.canSeekReading)
            }
            HStack(spacing: 12) {
                Button { model.listen() } label: { Label(model.rendering ? "Making audio…" : model.playing ? "Pause" : model.paused ? "Resume" : "Listen", systemImage: model.playing ? "pause.fill" : "play.fill") }
                    .buttonStyle(PrimaryButton()).disabled(model.speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.rendering || model.phase != .idle || model.speechText.count > model.readingLimit)
                if model.cloudRequestActive { Button("Cancel request") { model.cancelReading() } }
                if model.playing || model.paused { Button("Stop") { model.stopPlayback() } }
                Spacer()
                Button { model.saveAudio() } label: { Label("Save audio…", systemImage: "square.and.arrow.down") }.disabled(model.speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.rendering || model.speechText.count > model.readingLimit)
            }.controlSize(.large)
            Text("Saved audio is M4A, ready for QuickTime, Music, or sharing.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("Pick up a thought.", "Every completed capture is saved here, with its original words.")
            CaptureHistoryView(model: model)
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Make it your shortcut.", "Change keys here or directly in quick controls, just like StageMark.")
            VoiceShortcutSettings(model: model).padding(22).background(panelColor, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 10) {
                Text("Apple Shortcuts").font(.headline)
                Text(Bundle.main.url(forResource: "Metadata", withExtension: "appintents") != nil ? "Add Record Audio, then Transcribe with Workbench, then Create Note, Copy to Clipboard, or another text action. Shortcuts handles recording; Workbench returns your words." : "This development build has no Apple Shortcuts metadata. Use the full-Xcode package for the Transcribe with Workbench action.").foregroundStyle(.secondary)
                Button("Open Apple Shortcuts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
            }
            Spacer()
        }
    }

    private var settings: some View {
        ScrollView { VStack(alignment: .leading, spacing: 24) {
            heading("Ready, set, speak.", "A few simple controls. Everything else is taken care of.")
            VStack(alignment: .leading, spacing: 22) {
                settingRow("Speech model", model.modelMessage, "cpu") {
                    if model.preparing { ProgressView().controlSize(.small) }
                    else if model.ready { Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(mint) }
                    else { Button("Retry model") { Task { await model.prepare() } } }
                }
                Divider()
                settingRow("Microphone", "Workbench records only when you start a recording.", "mic") { Button("Open settings") { model.openMicrophoneSettings() } }
                Divider()
                VoiceOptions(model: model, showShortcut: false)
                Divider()
                VoiceShortcutSettings(model: model)
                Divider()
                Button("Position dictation panel…") { model.showPanelPreview() }.disabled(model.phase != .idle)
                Text("Drag the grip on the panel. Its position is remembered between recordings and app launches.").font(.caption).foregroundStyle(.secondary)
                Divider()
                WorkbenchAppearancePicker()
            }.padding(22).background(panelColor, in: RoundedRectangle(cornerRadius: 14))
            Text("Local by design").font(.system(size: 16, weight: .medium))
            Text("Built-in Parakeet dictation and Mac voices work on your Mac without an account after the initial model download. A local transcription server receives your audio and may forward it, depending on how you configure that server. Optional Speko reading sends the text you choose to its cloud service and selected provider; usage may be billed. Drafts, your dictionary and history remain local. Apple Shortcuts controls any downstream destinations. No analytics are included.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5).textSelection(.enabled)
            Spacer()
        } }
    }
    private func settingRow<Accessory: View>(_ title: String, _ subtitle: String, _ icon: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundStyle(mint).frame(width: 20)
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 13, weight: .medium)); Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
            Spacer(); accessory().font(.system(size: 11))
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

struct DictionaryView: View {
    @ObservedObject var model: AppModel
    @State private var heard = ""
    @State private var written = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Your words, your way.").font(.system(size: 34, weight: .semibold)).tracking(-1)
            Text("Correct names and specialist terms after transcription. Matches whole words and phrases, ignoring case.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) { Text("WHEN IT HEARS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary); TextField("e.g. git hub", text: $heard) }
                Image(systemName: "arrow.right").padding(.bottom, 7).foregroundStyle(mint)
                VStack(alignment: .leading, spacing: 8) { Text("WRITE THIS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary); TextField("e.g. GitHub", text: $written) }
                Button("Add") { model.addReplacement(heard: heard, written: written); heard = ""; written = "" }.disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty || written.trimmingCharacters(in: .whitespaces).isEmpty)
            }.textFieldStyle(.roundedBorder).controlSize(.large).padding(20).background(panelColor, in: RoundedRectangle(cornerRadius: 12))
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
    }
}

struct ReadingSelectionReviewCard: View {
    let selection: ReadingSelectionImport
    let limitMessage: String?
    var replacingDisabled = false
    let keep: () -> Void
    let replace: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Selected text is ready to review", systemImage: "text.quote")
                .font(.headline).foregroundStyle(mint)
            ScrollView {
                Text(selection.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    .accessibilityLabel("Imported selected text")
                    .accessibilityValue(selection.text)
            }.frame(maxHeight: 120).padding(12).background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            Text("Your current reading stays unchanged until you choose Replace reading. Keep current discards only this imported selection.")
                .font(.caption).foregroundStyle(.secondary)
            if let limitMessage {
                Label(limitMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Keep current", action: keep)
                Button("Replace reading", action: replace)
                    .buttonStyle(PrimaryButton()).disabled(replacingDisabled)
                    .accessibilityHint("Replaces the current reading draft. It does not start audio or send text online.")
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
