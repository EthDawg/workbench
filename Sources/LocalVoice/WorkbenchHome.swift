import SwiftUI
import AppKit
import StageKit
import ServiceManagement
import ImageIO

struct WorkbenchHome: View {
    @ObservedObject var model: AppModel
    @ObservedObject var stage: StageKitController
    @ObservedObject var keyboard: KeyboardCoachModel
    @ObservedObject var readback: ReadbackModel
    @ObservedObject var snap: SnapModel
    @ObservedObject var history: WorkbenchHistoryModel
    @ObservedObject private var packs = PackLibraryModel.shared
    @ObservedObject private var updates = WorkbenchUpdates.shared
    @StateObject private var introduction = FounderIntroductionModel()
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var photoBackdrop: PhotoBackdropRequest?
    @State private var handoffReview: HandoffReviewRequest?
    @State private var suggestionReview: MetadataSuggestionReview?
    /// Every sidebar destination. The surface gallery renders each one.
    static let navItems: [(String, String, String)] = [
        ("home", "Home", "square.grid.2x2"), ("dictate", "Dictate", "mic"),
        ("speak", "Read aloud", "speaker.wave.2"), ("snap", "Snap", "viewfinder"), ("readback", "Snap & Talk", "rectangle.and.pencil.and.ellipsis"), ("annotate", "Annotate", "pencil.tip"),
        ("present", "Present a device", "iphone"), ("personas", "Persona", "person.crop.circle"),
        ("history", "History", "clock"),
        ("library", "Saved resources", "square.stack"), ("shortcuts", "Keyboard", "keyboard"),
        ("packs", "Packs", "shippingbox"), ("models", "Models", "cpu"), ("settings", "Settings", "slider.horizontal.3")]
    init(model: AppModel, stage: StageKitController, keyboard: KeyboardCoachModel, readback: ReadbackModel, snap: SnapModel) {
        self.model = model; self.stage = stage; self.keyboard = keyboard; self.readback = readback
        self.snap = snap; self.history = model.historyLibrary
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                if let logo = packs.brandLogo {
                    Image(nsImage: logo).resizable().scaledToFit().frame(maxWidth: 150, maxHeight: 36)
                        .padding(8).background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(packs.brandLabel ?? "Workspace")
                }
                WorkbenchHeader(title: packs.brandLabel ?? "Workbench", subtitle: packs.brandLabel == nil ? "Everyday tools. A little less friction." : "Your workspace in Workbench", symbol: "square.stack.3d.up.fill")
                    .padding(.vertical, 20)
                ScrollView {
                VStack(spacing: 4) { ForEach(Self.navItems, id: \.0) { page, title, symbol in
                    Button {
                        keyboard.stopInteraction()
                        // Every door opens History on All, even from History itself.
                        if page == "history" { model.openHistory() } else { model.page = page }
                    } label: {
                        Label(title, systemImage: symbol).font(.system(size: 13, weight: model.page == page ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
                            .foregroundStyle(model.page == page ? Workbench.accent : .primary)
                            .background(model.page == page ? Workbench.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                } }
                }
                if updates.availableVersion != nil || updates.restartWaiting {
                    Button(updates.buttonTitle) { model.page = "settings"; updates.checkForUpdates() }
                        .font(.caption).buttonStyle(.bordered)
                }
                WorkbenchAppearancePicker().controlSize(.small)
                Text(updates.build.label).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 10)
            }.padding(16).frame(width: 215).background(Workbench.surface.opacity(0.6))
            Divider()
            Group {
                switch model.page {
                case "home": welcome
                case "readback": ReadbackView(model: readback, onOpenPacks: { model.page = "packs" },
                    onChooseSnaps: { model.page = "snap" }, onReviewHandoff: {
                        guard let session = readback.sessionURL else { return }
                        handoffReview = HandoffReviewRequest(task: "Prepare a clear summary and follow-up from these screenshots and their paired narration.", evidenceURL: session)
                    })
                case "snap": SnapWorkspaceView(model: snap, selectedIDs: Binding(get: {
                    Set(history.selected.filter { $0.kind == .snap }.map(\.id))
                }, set: { ids in
                    history.setSelected(Set(history.selected.filter { $0.kind != .snap }).union(ids.map { .init(kind: .snap, id: $0) }))
                }), savedSelectionID: history.activeSelectionID, selectionProblem: history.error,
                    onAddToNarratedSession: { ids in
                        do {
                            let snapshots = try snap.handoffSnapshots(ids: Set(ids))
                            readback.importSnapSnapshots(snapshots); model.page = "readback"
                        } catch { snap.notice = error.localizedDescription }
                    }, onOrganiseHandOff: { task in
                        handoffReview = HandoffReviewRequest(task: task, snapReview: true, savedSelectionID: history.activeSelectionID)
                    })
                case "packs": PackLibraryView(model: packs) { pack, entry in packs.use(entry, from: pack, readback: readback, app: model, stage: stage) }
                case "history": HistoryView(model: model, snap: snap, applySuggestedMetadata: { job, result in
                    do { suggestionReview = try MetadataSuggestionReview(job: job, result: result, jobs: model.handoffJobs, transcripts: model.history) }
                    catch { model.handoffJobs.error = error.localizedDescription }
                })
                case "meeting": MeetingWorkspaceView(model: model.meetings, openHistory: { model.openHistory() })
                case "annotate": stage.controlsView
                case "present": stage.scenesView
                case "personas": stage.personasView
                case "shortcuts": KeyboardCoachView(model: keyboard)
                case "models": ScrollView { VStack(alignment: .leading, spacing: 28) {
                    ModelSettingsView(engine: model.engine, isBusy: model.phase != .idle || model.preparing || model.rendering || model.meetings.isBusy || readback.isRecording || readback.isCapturing || readback.hasPendingTranscriptions) { ready, message in
                        model.ready = ready; model.modelMessage = message
                    }
                    Divider()
                    CleanupModelSettingsView(isBusy: model.phase != .idle || model.preparing || model.rendering)
                }.padding(32) }
                case "settings": settings
                default: ContentView(model: model, embedded: true)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 1050, minHeight: 730).tint(Workbench.accent).workbenchTheme()
            .onAppear {
                model.onHandOffSelection = { task in handoffReview = HandoffReviewRequest(task: task) }
                model.onSuggestTranscriptDetails = { id in
                    handoffReview = HandoffReviewRequest(task: MetadataSuggestionReview.task, transcriptID: id)
                }
                model.onUsePhotoAsBackdrop = { url, title in
                    keyboard.stopInteraction()
                    photoBackdrop = PhotoBackdropRequest(url: url, title: title)
                }
                model.refreshPhotoHandoffIfEnabled()
            }
            .sheet(item: $photoBackdrop) { request in
                stage.backdropReplacementView(imageURL: request.url, title: request.title)
            }
            .sheet(item: $handoffReview) { request in
                HandoffReviewView(history: model.historyLibrary, jobs: model.handoffJobs,
                    skills: request.transcriptID == nil ? TranscriptHandoffSkill.builtIns + packs.transcriptSkills : [.followUp],
                    initialTask: request.task,
                    preferredSkillID: request.transcriptID == nil ? packs.preferredTranscriptSkillID : nil,
                    selectedSnapTalkSession: request.transcriptID == nil ? readback.sessionURL : nil,
                    initialEvidenceURL: request.evidenceURL,
                    resolveReviewContext: {
                        guard request.snapReview else { return nil }
                        guard history.activeSelectionID == request.savedSelectionID else {
                            throw VoiceError.message("The named selection changed. Close this review, deliberately update the saved selection if needed, and open the handoff again.")
                        }
                        let name = history.savedSelections.first(where: { $0.id == request.savedSelectionID })?.name ?? "Selected Snap review"
                        return try SnapOrganization.context(store: snap.store,
                            ids: Set(history.selected.filter { $0.kind == .snap }.map(\.id)),
                            selectionID: request.savedSelectionID, title: name)
                    },
                    resolveSources: {
                        if request.evidenceURL != nil { return [] }
                        var sources = try model.selectedHandoffSources(references: request.transcriptID.map { Set([WorkbenchItemReference(kind: .transcript, id: $0)]) })
                        if request.transcriptID != nil {
                            for index in sources.indices { sources[index].role = .reference }
                        }
                        return sources
                    }, onPrepared: { id in model.openHistory(HistoryDoor(job: id)) })
            }
            .sheet(item: $suggestionReview) { suggestion in
                MetadataSuggestionView(review: suggestion, library: model.historyLibrary)
            }
    }
    private var welcome: some View {
        WorkbenchHomePage(model: model, stage: stage, keyboard: keyboard, readback: readback, snap: snap,
                          introduction: introduction, handoffReview: $handoffReview)
    }
    private var settings: some View {
        ScrollView { VStack(alignment: .leading, spacing: 22) {
            Text("Make yourself at home.").font(.largeTitle.weight(.semibold))
            Text("Only turn on the access you need. Closing this window leaves the menu-bar tools available; Quit stops Workbench.").foregroundStyle(.secondary)
            WorkbenchAppearancePicker()
            Toggle("Show floating toolbar", isOn: $model.floatingToolbarVisible)
            Text("Start another action from the same place. Recording controls appear here while you speak.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Open Workbench at login", isOn: Binding(get: { loginEnabled }, set: { value in
                do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginEnabled = SMAppService.mainApp.status == .enabled }
                catch { loginError = error.localizedDescription }
            }))
            if let loginError { Text(loginError).foregroundStyle(.orange) }
            Divider()
            WorkbenchUpdateSettings()
            Divider()
            MeetingDetectionSettings(model: model.meetings)
            Divider()
            SubscriptionSettingsView(jobs: model.handoffJobs)
            if model.photoHandoff.isConfigured {
                Divider()
                PhotoHandoffSettings(handoff: model.photoHandoff)
            }
            Divider()
            Button("Dictate options…") { model.page = "dictate" }
            Text("Activation, cleanup, delivery, your dictionary and the dictation panel are on the Dictate page.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("Models and local server") { model.page = "models" }
            Button("Keyboard and practice") { model.page = "shortcuts" }
            Text("Workbench and Workbench Preview keep separate libraries. Your previous Voice and StageMark data remains in place.").font(.caption).foregroundStyle(.secondary)
            Divider()
            FounderIntroductionCard(model: introduction, canDismiss: false)
        }.padding(32).frame(maxWidth: .infinity, alignment: .leading) }
    }
}

struct WorkbenchClipboardShelf: View {
    @ObservedObject var receipts: ClipboardReceiptModel
    let review: () -> Void
    let showCue: () -> Void
    var body: some View {
        if let receipt = receipts.receipt, receipt.isClipboardCurrent {
            // The same words as the floating receipt, so the panel, Home and Dictate agree.
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(receipt.title, systemImage: receipt.symbolName)
                        .font(.callout.weight(.semibold)).lineLimit(1)
                    if receipt.wordCount > 0 {
                        Text("\(receipt.wordCount) \(receipt.wordCount == 1 ? "word" : "words")").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if receipt.canSuggestPaste { Text("⌘V").font(.callout.monospaced()).foregroundStyle(.secondary) }
                }
                Text(receipt.detail)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                HStack {
                    Button("Review text", action: review)
                    Spacer()
                    Button("Show cue", action: showCue)
                }.controlSize(.small)
            }.padding(12)
                .background(Workbench.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Home follows the journey (#134). Until the first dictation it guides one,
/// whatever else has been captured (#15). Afterwards it shows what is live,
/// what was done last, and the three moments as one-click tiles; Prepare… is
/// each tile's small link to its page. WorkbenchHome embeds it as the "home" page.
struct WorkbenchHomePage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var stage: StageKitController
    @ObservedObject var keyboard: KeyboardCoachModel
    @ObservedObject var readback: ReadbackModel
    @ObservedObject var snap: SnapModel
    @ObservedObject var introduction: FounderIntroductionModel
    @Binding var handoffReview: HandoffReviewRequest?
    /// Keeps the guide up after the first dictation lands, so where the words
    /// went is seen once; Done or leaving Home ends it.
    @State private var stayInGuide = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(journey.showsGuide ? "Say something." : "Make room for the work.").font(.system(size: 34, weight: .semibold)).tracking(-0.7)
                        Text(journey.showsGuide ? "One click, and your words are ready to paste anywhere." : "Speak a thought. Explain a screen. Give your demo a stage.")
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                        // One small switch for the guide until the first dictation (#15).
                        if journey.offersSkip {
                            Button("Skip for now") { skipGuide() }.buttonStyle(.link).font(.callout)
                                .help("Hide this guide. Show me a first dictation brings it back.")
                        } else if journey.offersGuide {
                            Button("Show me a first dictation") { showGuide() }.buttonStyle(.link).font(.callout)
                                .help("Bring back the short guide to your first dictation.")
                        }
                    }
                    Spacer()
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 42)).foregroundStyle(Workbench.accent)
                }.padding(.top, 16)
                ForEach(journey.sections, id: \.self) { section in
                    switch section {
                    case .liveStrip: liveStrip
                    case .guide: firstDictation
                    case .firstResult: firstResult
                    case .recentWork: recentWork
                    case .moments: moments
                    }
                }
                if !introduction.isDismissed { FounderIntroductionCard(model: introduction) }
                if !journey.showsGuide && !model.ready { engineBanner }
            }.padding(32)
        }.onAppear { if journey.offersSkip { stayInGuide = true } }
    }
    /// What Home can count. The stage exposes no saved-scene or persona count, so
    /// someone who has only prepared scenes still sees the guide; presenting,
    /// drawing and personas still surface through the live strip.
    private var journey: HomeJourney {
        HomeJourney(transcripts: model.history.count, snaps: snap.items.count,
                    sessions: (readback.sessionURL == nil ? 0 : 1) + readback.recentSessionURLs.count,
                    handoffJobs: model.handoffJobs.jobs.count, photos: model.photoHandoff.photos.count,
                    guide: model.preferences.firstDictationGuide, isLive: isLive, stayInGuide: stayInGuide)
    }
    /// Skip for now and Show me a first dictation, saved with the Dictate preferences.
    private func skipGuide() { stayInGuide = false; model.preferences.firstDictationGuide = .skipped }
    private func showGuide() { model.preferences.firstDictationGuide = .offered; stayInGuide = true }

    // One guided first dictation: the engine banner until speech is ready, then
    // one accent button whose label follows the phase as the Dictate page does.
    private var firstDictation: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.ready { engineBanner } else {
                HStack(spacing: 16) {
                    Button { model.toggleRecording() } label: {
                        Label(model.phase == .requesting ? "Cancel" : model.phase == .recording ? "Stop" : "Start dictating",
                              systemImage: model.phase == .requesting ? "xmark" : model.phase == .recording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 16, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 4)
                    }.buttonStyle(PrimaryButton())
                        .disabled(![.idle, .requesting, .recording].contains(model.phase) || model.rendering || readback.blocksDictation)
                        .accessibilityLabel(model.phase == .requesting ? "Cancel microphone request" : model.phase == .recording ? "Stop recording" : "Start recording")
                    if model.phase == .recording {
                        WaveBars(level: model.level).frame(width: 100, height: 22)
                        Text(time(model.elapsed)).monospacedDigit()
                    } else if model.phase == .requesting {
                        Text("Allow access in the macOS prompt.").font(.callout).foregroundStyle(.secondary)
                    } else if model.phase != .idle {
                        ProgressView().controlSize(.small)
                        Text(model.captureProcessingLabel).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Text("or press \(model.preferences.dictationShortcut.label) in any text field").font(.callout).foregroundStyle(.secondary)
                if !model.transcript.isEmpty {
                    Text(model.transcript).lineLimit(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Your words")
                    HStack(spacing: 12) {
                        Button { model.copyTranscript() } label: { Label("Copy text", systemImage: "doc.on.doc") }
                        if model.preferences.delivery == .paste && !model.accessibilityGranted {
                            Button("Set up automatic paste…") { model.requestAccessibility() }.buttonStyle(.link)
                        }
                        Spacer()
                        Button("Done") { stayInGuide = false }.buttonStyle(.link)
                    }.controlSize(.large)
                    if model.preferences.delivery == .paste && !model.accessibilityGranted {
                        Text("Automatic paste needs Accessibility approval. Until then, transcripts are copied for ⌘V. Your organisation may need to approve this.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    WorkbenchClipboardShelf(receipts: model.clipboardReceipt,
                        review: { model.clipboardReceipt.dismissHUD(); model.page = "history" },
                        showCue: { model.clipboardReceipt.revealHUD() })
                }
            }
        }
    }
    private var engineBanner: some View {
        HStack {
            if model.preparing { ProgressView().controlSize(.small) }
            Text(model.modelMessage).font(.callout)
            Spacer()
            if !model.preparing { Button("Retry model") { Task { await model.prepare() } } }
            Button("Speech settings") { model.page = "models" }
        }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
    // Once, after the first dictation: where the words were kept and the way back
    // to them. It reads the transcript History already holds (#15).
    private var firstResult: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock").foregroundStyle(Workbench.accent).frame(width: 20)
            Text("Also saved in History, newest first. You can copy it again from there.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Open in History") { model.openHistory(HistoryDoor(filter: .transcripts)) }
                .help("Opens History on your transcripts; this one is at the top.")
        }.padding(14).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    // What is live, each with its one action; shown only while something runs.
    private var isLive: Bool {
        model.phase != .idle || model.playing || model.paused || readback.isRecording || readback.hasPendingTranscriptions
            || stage.isDrawing || stage.isPresenting || stage.hasActivePersona || stage.hasActiveTimer || model.meetings.isBusy
    }
    private var liveStrip: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("LIVE").font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary)
                if model.phase == .recording {
                    liveRow("Recording…", "mic.fill") { Button("Stop") { model.toggleRecording() } }
                } else if model.waitingForDrawing {
                    liveRow("Text ready", "doc.on.clipboard") { Button("Copy") { model.copyWaitingDelivery() } }
                } else if model.phase != .idle {
                    liveRow("Processing speech", "waveform") { ProgressView().controlSize(.small) }
                }
                if model.playing || model.paused {
                    liveRow(model.paused ? "Reading paused" : "Reading", "speaker.wave.2") { Button("Stop reading") { model.stopPlayback() } }
                }
                if readback.isRecording {
                    liveRow("Narrating", "rectangle.dashed.badge.record") { Button("Stop") { readback.stopNarration() } }
                } else if readback.hasPendingTranscriptions {
                    liveRow("Transcribing narration", "rectangle.dashed.badge.record") { ProgressView().controlSize(.small) }
                }
                if stage.isDrawing { liveRow("Drawing", "pencil.tip") { Button("Stop drawing") { stage.finishDrawing() } } }
                if stage.isPresenting { liveRow("Presenting", "iphone") { Button("End presentation") { stage.endDeviceScene() } } }
                if stage.hasActivePersona {
                    let persona = personaControl
                    liveRow("Persona · " + stage.personaStatus, "person.crop.rectangle") {
                        Button(persona.rowTitle) { perform(persona) }.help(persona.help)
                    }
                }
                if stage.hasActiveTimer {
                    // Pause, Stop and Reset live in the Timer menu the panel already uses.
                    liveRow("Timer · " + stage.timerText, "timer") { NativeControlMenu(title: "Timer") { stage.makeTimerMenu() }.frame(width: 64, height: 24) }
                }
                MeetingQuickStatus(model: model.meetings) { model.page = "meeting" }
            }.padding(16).background(Workbench.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
    /// Persona's label, tooltip and click, from the action the panel and toolbar share (#134).
    private var personaControl: HomePersonaControl {
        HomePersonaControl(WorkbenchControlContext(model: model, readback: readback, stage: stage, snap: snap).state)
    }
    /// Does exactly what the Persona label names, through the switch the panel and toolbar use.
    private func perform(_ persona: HomePersonaControl) {
        WorkbenchOperationDispatch(model: model, readback: readback, stage: stage, meetings: model.meetings) { _ in stage.togglePersona() }
            .perform(persona.operation)
    }
    private func liveRow<Action: View>(_ title: String, _ symbol: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Workbench.accent).frame(width: 20)
            Text(title).font(.callout.weight(.medium))
            Spacer()
            action()
        }.controlSize(.small)
    }

    // The newest thing of each kind, with the action you would take next.
    private enum RecentKind: Hashable { case transcript, snap, session, handoff, photos }
    private var latestSnap: SnapItem? { snap.items.filter { $0.archivedAt == nil }.max { $0.createdAt < $1.createdAt } }
    private var latestJob: HandoffJob? { model.handoffJobs.jobs.max { $0.updatedAt < $1.updatedAt } }
    private var recentOrder: [RecentKind] {
        var rows: [(Date, RecentKind)] = []
        if let transcript = model.history.first { rows.append((transcript.date, .transcript)) }
        if let item = latestSnap { rows.append((item.createdAt, .snap)) }
        if readback.sessionURL != nil { rows.append((readback.manifest?.updatedAt ?? .distantPast, .session)) }
        if let job = latestJob { rows.append((job.updatedAt, .handoff)) }
        if !model.photoHandoff.photos.isEmpty { rows.append((Date(), .photos)) }
        return rows.sorted { $0.0 > $1.0 }.prefix(5).map(\.1)
    }
    private var recentWork: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECENT WORK").font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary)
            ForEach(recentOrder, id: \.self) { kind in
                switch kind {
                case .transcript: if let transcript = model.history.first {
                    recentRow("text.quote", transcript.text, "\(TextRules.wordCount(transcript.text)) words · \(transcript.date.formatted(date: .abbreviated, time: .shortened))") {
                        Button("Copy") { model.copyCapture(transcript) }
                        Button("Open in Dictate") { model.openTranscript(transcript); model.page = "dictate" }
                    }
                }
                case .snap: if let item = latestSnap {
                    HStack(spacing: 12) {
                        HomeSnapThumbnail(model: snap, item: item)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).lineLimit(1)
                            Text("Snap · " + item.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Copy") { snap.copy(item.id) }
                        Button("Edit…") { snap.edit(item.id); model.page = "snap" }.disabled(snap.disablesCaptureDoors)
                    }.padding(14).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                case .session: if let session = readback.sessionURL {
                    let count = readback.activeSections.count
                    recentRow("rectangle.dashed.badge.record", readback.manifest?.title ?? "Snap & Talk session",
                              "\(count) " + (count == 1 ? "capture" : "captures") + (readback.hasPendingTranscriptions ? " · transcribing narration…" : "")) {
                        if count >= 1 && !readback.hasPendingTranscriptions && !readback.isRecording {
                            Button("Hand off…") {
                                handoffReview = HandoffReviewRequest(task: "Prepare a clear summary and follow-up from these screenshots and their paired narration.", evidenceURL: session)
                            }
                        } else {
                            Button(readback.isCapturing ? "Capturing…" : "Capture & narrate") { Task { await readback.captureNewSection(fromEditor: true) } }
                                .disabled(!readback.permissionsReady || readback.isCapturing || readback.isRecording)
                        }
                    }
                }
                case .handoff: if let job = latestJob {
                    recentRow("arrow.up.forward.app", job.title, "Hand off · " + job.status.title + " · " + job.updatedAt.formatted(date: .abbreviated, time: .shortened)) {
                        switch job.status {
                        case .completed: Button("Open result") { model.handoffJobs.showResult(job) }
                        case .running: Button("Stop task", role: .destructive) { model.handoffJobs.cancel() }
                        default: Button("Copy instructions") { model.handoffJobs.copy(job) }
                        }
                    }
                }
                case .photos:
                    PhotoHandoffArrivalCue(handoff: model.photoHandoff) {
                        model.showingPhonePhotos = true
                        model.page = "library"
                    }
                }
            }
            Button("All history") { model.page = "history" }.buttonStyle(.link)
        }
    }
    private func recentRow<Actions: View>(_ symbol: String, _ title: String, _ detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Workbench.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            actions()
        }.controlSize(.small).padding(14).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    // The moments. Each tile is one click into the action; Prepare… opens its page.
    private var moments: some View {
        VStack(alignment: .leading, spacing: 18) {
            moment("Working", "A utility for seconds, then back to work.") {
                card("Dictate", model.phase == .recording ? "Stop" : "Start dictating", "mic", model.preferences.dictationShortcut.label, prepare: "dictate",
                     disabled: !model.ready || ![.idle, .recording].contains(model.phase) || readback.blocksDictation) { model.toggleRecording() }
                card("Read", model.rendering ? "Cancel" : model.playing || model.paused ? "Stop reading" : "Read the clipboard aloud",
                     "speaker.wave.2", "Mac voices included", prepare: "speak",
                     disabled: !(model.rendering || model.playing || model.paused) && model.phase != .idle) {
                    if model.rendering { model.cancelReading() }
                    else if model.playing || model.paused { model.stopPlayback() }
                    else { readClipboard() }
                }
                card("Snap", "Capture a region", "viewfinder", "Window or screen on the Snap page", prepare: "snap",
                     disabled: snap.disablesCaptureDoors,
                     note: snap.screenAccessGranted ? nil : "Screen Recording is off for Workbench. Snap shows how to allow it, or add an image you already have.") {
                    Task { await snap.capture(.region) }
                }
            }
            moment("Capturing", "Explain screens aloud and get a deck in seconds.") {
                card("Snap & Talk", readback.sessionURL == nil ? "New session…" : readback.isCapturing ? "Capturing…" : "Capture & narrate",
                     "rectangle.dashed.badge.record", model.preferences.shortcut(5).label, prepare: "readback",
                     disabled: readback.isCapturing || readback.isRecording, note: readback.notice) { snapAndTalk() }
            }
            moment("Presenting", "Demonstrate with a device, your persona and live marks.") {
                card("Present", stage.isPresenting ? "End presentation" : "Present the selected scene", "iphone", "Saved scenes and branding", prepare: "present") {
                    if stage.isPresenting { stage.endDeviceScene() } else { stage.presentSelectedScene() }
                }
                let persona = personaControl
                card("Persona", persona.tileVerb, "person.crop.rectangle", "Independent of a scene", prepare: "personas",
                     disabled: !persona.isEnabled) { perform(persona) }
                card("Draw", stage.isDrawing ? "Stop drawing" : "Draw on screen", "pencil.tip", stage.drawingActivationTitle + " to draw", prepare: "annotate") {
                    if stage.isDrawing { stage.finishDrawing() } else { stage.draw() }
                }
                // showTimer toggles the timer window; the stage does not expose whether it is visible.
                card("Timer", stage.hasTimerSession ? "Show or hide timer" : "Start a break", "timer", stage.hasTimerSession ? stage.timerText : "Saved duration", prepare: "annotate") {
                    // The label is the action: after Reset the window may still show, and Start a break starts one.
                    if stage.hasTimerSession { stage.showTimer() } else { stage.startTimer() }
                }
            }
        }
    }
    private func moment<Tiles: View>(_ title: String, _ detail: String, @ViewBuilder tiles: () -> Tiles) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary)
            Text(detail).font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) { tiles() }
        }
    }
    private func card(_ title: String, _ verb: String, _ symbol: String, _ footnote: String, prepare page: String, disabled: Bool = false, note: String? = nil, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(Workbench.accent); Spacer(); Image(systemName: "play.circle").foregroundStyle(.tertiary) }
                    Text(title).font(.system(size: 18, weight: .semibold))
                    Text(verb).foregroundStyle(.secondary).font(.system(size: 13))
                    Text(footnote).font(.system(size: 11, design: .monospaced)).foregroundStyle(Workbench.accent)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(disabled).accessibilityLabel(title + ". " + verb)
            Button("Prepare…") { keyboard.stopInteraction(); model.page = page }.buttonStyle(.link).font(.caption)
            if let note { Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }.padding(18).frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(Workbench.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Workbench.border))
    }
    private func readClipboard() {
        if let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.listen(to: text)
        } else { model.status = "Copy some text first."; model.page = "speak" }
    }
    private func snapAndTalk() {
        if readback.sessionURL == nil { readback.createSession() }
        else { Task { await readback.captureNewSection(fromEditor: true) } }
    }
}

/// What Home knows about the journey and the sections it shows, in order.
/// Counting is what LocalVoice can reach; live state comes from every module.
/// The first-dictation guide is gated on dictation alone (#15): Snaps, Snap &
/// Talk sessions, Hand off jobs and photos are recent work, never a reason to
/// stop offering it. Skip for now keeps one small way back until someone dictates.
struct HomeJourney: Equatable {
    var transcripts = 0, snaps = 0, sessions = 0, handoffJobs = 0, photos = 0
    /// Saved with the Dictate preferences; nil reads as offered.
    var guide: FirstDictationGuide? = nil
    var isLive = false
    var stayInGuide = false
    enum Section: Hashable { case liveStrip, guide, firstResult, recentWork, moments }
    /// Any transcript in History ends first use: a dictation, or a meeting or call
    /// transcribed from Dictate. A recorded completion outlasts removing them.
    var hasDictated: Bool { transcripts > 0 || guide == .completed }
    var showsGuide: Bool { (!hasDictated && guide != .skipped) || stayInGuide }
    /// Skip for now, while the guide shows and nothing has been dictated.
    var offersSkip: Bool { showsGuide && !hasDictated }
    /// Show me a first dictation, while the guide is skipped and nothing has been dictated.
    var offersGuide: Bool { !showsGuide && !hasDictated }
    /// What to save once History holds a dictation.
    var guideToSave: FirstDictationGuide? { transcripts > 0 && guide != .completed ? .completed : nil }
    private var hasRecentWork: Bool { transcripts + snaps + sessions + handoffJobs + photos > 0 }
    /// The live strip comes first, so what is running can be ended from Home.
    /// Recent work stays below the guide, except right after the first dictation,
    /// when the guide's own result would only repeat it.
    var sections: [Section] {
        let result = showsGuide && hasDictated
        return (isLive ? [.liveStrip] : []) + (showsGuide ? [.guide] : []) + (result ? [.firstResult] : [])
            + (hasRecentWork && !result ? [.recentWork] : []) + [.moments]
    }
}

/// A small thumbnail for Home's Recent work row; the Snap page keeps its own.
private struct HomeSnapThumbnail: View {
    let model: SnapModel
    let item: SnapItem
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.frame(width: 56, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: item.revision) {
                guard let url = try? model.store.imageURL(item.id),
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 160, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { image = nil; return }
                image = NSImage(cgImage: cgImage, size: .zero)
            }
    }
}
