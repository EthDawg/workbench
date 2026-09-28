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
    /// The page record: every surface that names or opens a window page reads it here, so a
    /// page has one name wherever it appears (#134). The sidebar lists `navItems`, Library and
    /// Settings switch between their `sections`, and `subpages` have no sidebar item of their
    /// own. A capability page's name and symbol are the toolbar's (`ToolbarMode`) and the panel's
    /// (`WorkbenchControlTool`), checked by --check-core. The surface gallery renders each route.
    static let navItems: [(id: String, title: String, symbol: String)] = [
        ("home", "Home", "square.grid.2x2"), ("dictate", "Dictate", "mic"),
        ("speak", "Read", "speaker.wave.2"), ("snap", "Snap", "viewfinder"), ("readback", "Snap & Talk", "rectangle.dashed.badge.record"), ("annotate", "Draw", "pencil.tip"),
        ("present", "Present", "iphone"), ("personas", "Persona", "person.crop.rectangle"),
        ("history", "History", "clock"), ("library", "Library", "square.stack"), ("settings", "Settings", "slider.horizontal.3")]
    /// A page's sections, in switcher order. Each opens from its own route, and the page's own
    /// route opens the first; Keyboard, Models and Packs keep the routes their sidebar items had.
    static let sections: [(id: String, page: String, title: String)] = [
        ("library", "library", "Resources"), ("packs", "library", "Packs"), ("photos", "library", "From iPhone"),
        ("settings", "settings", "General"), ("shortcuts", "settings", "Keyboard"),
        ("models", "settings", "Models"), ("connections", "settings", "Connections")]
    /// Pages reached from another page. A door to one keeps that page highlighted, so the
    /// sidebar is always the way back.
    static let subpages: [(id: String, page: String, title: String)] = [
        ("dictionary", "dictate", "Your dictionary"), ("meeting", "dictate", "Transcribe meeting or call")]
    /// Home's photo arrival cue opens Library on From iPhone by this route. Nothing else holds
    /// the section, so a later Library door returns to Resources.
    static let photoArrivals = "photos"

    /// Where a route lands: the sidebar page it highlights and, on a page with sections, the
    /// section it shows. Every door resolves here, so a route that was once a page of its own
    /// still works and nothing lands without a highlighted item. A route nothing knows shows
    /// Dictate, as the page switch always has.
    static func destination(_ route: String) -> (page: String, section: String?) {
        if let section = sections.first(where: { $0.id == route }) { return (section.page, section.id) }
        if navItems.contains(where: { $0.id == route }) { return (route, nil) }
        return (subpages.first { $0.id == route }?.page ?? "dictate", nil)
    }
    /// A route's one name: its page's, else its section's or subpage's. "settings" is Settings,
    /// not General.
    static func name(of route: String) -> String {
        navItems.first { $0.id == route }?.title ?? sections.first { $0.id == route }?.title
            ?? subpages.first { $0.id == route }?.title ?? route
    }
    /// The symbol of the page a route lands on, as its sidebar item shows it.
    static func symbol(of route: String) -> String {
        let page = destination(route).page
        return navItems.first { $0.id == page }?.symbol ?? "questionmark"
    }
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
                // A section or subpage keeps its page's item highlighted.
                let current = Self.destination(model.page).page
                VStack(spacing: 4) { ForEach(Self.navItems, id: \.id) { page, title, symbol in
                    Button {
                        keyboard.stopInteraction()
                        // Every door opens History on All, even from History itself.
                        if page == "history" { model.openHistory() } else { model.page = page }
                    } label: {
                        Label(title, systemImage: symbol).font(.system(size: 13, weight: current == page ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
                            .foregroundStyle(current == page ? Workbench.accent : .primary)
                            .background(current == page ? Workbench.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityAddTraits(current == page ? .isSelected : [])
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
                case "readback": titled("readback", summary: "Explain screens aloud and get a deck in seconds.", divided: true) {
                    ReadbackView(model: readback, onOpenPacks: { model.page = "packs" },
                    onChooseSnaps: { model.page = "snap" }, onReviewHandoff: {
                        guard let session = readback.sessionURL else { return }
                        handoffReview = HandoffReviewRequest(task: "Prepare a clear summary and follow-up from these screenshots and their paired narration.", evidenceURL: session)
                    })
                }
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
                case "history": HistoryView(model: model, snap: snap, applySuggestedMetadata: { job, result in
                    do { suggestionReview = try MetadataSuggestionReview(job: job, result: result, jobs: model.handoffJobs, transcripts: model.history) }
                    catch { model.handoffJobs.error = error.localizedDescription }
                })
                case "meeting": MeetingWorkspaceView(model: model.meetings, openHistory: { model.openHistory() })
                case "annotate": titled("annotate", summary: "Draw attention to what matters, right over your live demo.") { stage.controlsView }
                case "present": titled("present", summary: "Show a device in a saved scene, with your backdrop and branding.", divided: true) { stage.scenesView }
                case "personas": stage.personasView
                case _ where Self.destination(model.page).page == "library": library
                case _ where Self.destination(model.page).page == "settings": settings
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
    /// Library holds Resources, Packs and From iPhone as sections of one page, with its switcher
    /// at the top (#134). The route alone chooses the section, so every Library door opens
    /// Resources and Home's arrival cue opens From iPhone by its own route.
    private var library: some View {
        let section = Self.destination(model.page).section ?? "library"
        return VStack(alignment: .leading, spacing: 0) {
            sectionedHeader("library", selection: section)
            switch section {
            case "packs": PackLibraryView(model: packs) { pack, entry in packs.use(entry, from: pack, readback: readback, app: model, stage: stage) }
            case "photos":
                PhotoHandoffView(handoff: model.photoHandoff, onUseAsBackdrop: model.onUsePhotoAsBackdrop)
                    .padding(Workbench.pagePadding).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            default: ContentView(model: model, embedded: true)
            }
        }
    }

    /// Settings holds General, Keyboard, Models and Connections as sections of one page, with
    /// its switcher at the top (#134). Each section shows what its old page or place showed.
    private var settings: some View {
        let section = Self.destination(model.page).section ?? "settings"
        return VStack(alignment: .leading, spacing: 0) {
            sectionedHeader("settings", selection: section)
            switch section {
            case "shortcuts":
                // Recording and practice pause global actions only while they run. Leaving this
                // section ends them and restores the actions, as leaving the Keyboard page did.
                ScrollView { KeyboardCoachView(model: keyboard) }
            case "models":
                ScrollView { VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
                    ModelSettingsView(engine: model.engine, isBusy: model.phase != .idle || model.preparing || model.rendering || model.meetings.isBusy || readback.isRecording || readback.isCapturing || readback.hasPendingTranscriptions) { ready, message in
                        model.ready = ready; model.modelMessage = message
                    }
                    Divider()
                    CleanupModelSettingsView(isBusy: model.phase != .idle || model.preparing || model.rendering)
                }.padding(Workbench.pagePadding) }
            case "connections":
                ScrollView { VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
                    SubscriptionSettingsView(jobs: model.handoffJobs)
                    if model.photoHandoff.isConfigured {
                        Divider()
                        PhotoHandoffSettings(handoff: model.photoHandoff)
                    }
                }.padding(Workbench.pagePadding).frame(maxWidth: .infinity, alignment: .leading) }
            default:
                ScrollView { VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
                    Text("Only turn on the access you need. Closing this window leaves the menu-bar tools available; Quit stops Workbench.").foregroundStyle(.secondary)
                    // Saved drawing settings that could not be read or saved, and login, belong to
                    // General: the menu-bar panel's Open Settings… leads to these words (#134).
                    if let notice = stage.notice(on: .general) {
                        Text(notice).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
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
                    HStack(spacing: 12) {
                        Button("Dictate options…") { model.page = "dictate" }
                        // Until the first dictation, Home's guide can be asked for here too (#15).
                        if !HomeJourney(transcripts: model.history.count, guide: model.preferences.firstDictationGuide).hasDictated {
                            Button("Show me a first dictation") { model.preferences.firstDictationGuide = .offered; model.page = "home" }
                        }
                    }
                    Text("Delivery, text style, activation, your dictionary and the dictation panel are on the Dictate page.").font(.caption).foregroundStyle(.secondary)
                    Text("Workbench and Workbench Preview keep separate libraries. Your previous Voice and StageMark data remains in place.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    FounderIntroductionCard(model: introduction, canDismiss: false)
                }.padding(Workbench.pagePadding).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
    }

    /// A page with sections: its name from the page record, then its switcher, where every
    /// other page has its title (#134). Each section keeps its own summary below.
    private func sectionedHeader(_ page: String, selection: String) -> some View {
        VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
            WorkbenchPageHeader(page)
            sectionSwitcher(page, selection: selection) { model.page = $0 }
        }.padding([.horizontal, .top], Workbench.pagePadding)
    }

    /// A page whose own view draws no page title takes its name from the page record here, in
    /// the same place and type as every other page (#134). A page of two columns is divided
    /// from its title, so both columns start below it.
    private func titled<Page: View>(_ route: String, summary: String, divided: Bool = false, @ViewBuilder page: () -> Page) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkbenchPageHeader(route, summary: summary)
                .padding([.horizontal, .top], Workbench.pagePadding).padding(.bottom, divided ? Workbench.sectionSpacing : 0)
            if divided { Divider() }
            page()
        }
    }

    /// A page's section switcher, named for its page, with one segment per section in the page
    /// record. Choosing a segment opens that section's route, so the switcher, the sidebar and
    /// every door agree on where you are. The page's title above it says the name, so the
    /// switcher's label is for VoiceOver only.
    private func sectionSwitcher(_ page: String, selection: String, choose: @escaping (String) -> Void) -> some View {
        Picker(Self.name(of: page), selection: Binding(get: { selection }, set: { section in
            keyboard.stopInteraction(); choose(section)
        })) {
            ForEach(Self.sections.filter { $0.page == page }, id: \.id) { section in Text(section.title).tag(section.id) }
        }.pickerStyle(.segmented).labelsHidden().fixedSize()
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
                    // One ⌘V: the key only when the receipt's words do not already say it.
                    if receipt.canSuggestPaste && !receipt.detail.contains("⌘V") {
                        Text("⌘V").font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
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
            VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        // Home's title is its welcome, in the page title's type (#134).
                        Text(journey.showsGuide ? "Say something." : "Make room for the work.").font(Workbench.pageTitle)
                            .accessibilityAddTraits(.isHeader)
                        Text(journey.showsGuide ? "One click, and your words are ready to paste anywhere." : "Speak a thought. Explain a screen. Give your demo a stage.")
                            .font(Workbench.bodyText).foregroundStyle(.secondary)
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
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 34)).foregroundStyle(Workbench.accent)
                        .accessibilityHidden(true)
                }
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
            }.padding(Workbench.pagePadding)
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
                        review: {
                            let prompt = model.clipboardReceipt.receipt?.source == .prompt
                            model.clipboardReceipt.dismissHUD(); model.page = prompt ? "library" : "history"
                        },
                        showCue: { model.clipboardReceipt.revealHUD() })
                }
            }
        }
    }
    private var engineBanner: some View {
        HStack {
            if model.preparing { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.modelMessage).font(.callout)
                // A failed preparation belongs here, beside Retry model: the menu-bar panel's
                // Open Home… leads to these words (#134).
                if let attention = model.attention, attention.page == .home {
                    Text(attention.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
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
                WorkbenchSectionTitle("Live")
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
            WorkbenchSectionTitle("Recent work")
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
                        CapturePreviewButton("View latest Snap", item: { .snap(item, store: snap.store) }) { HomeSnapThumbnail(model: snap, item: item) }
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
                        model.page = WorkbenchHome.photoArrivals
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
        VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
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
            VStack(alignment: .leading, spacing: 2) {
                WorkbenchSectionTitle(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
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
