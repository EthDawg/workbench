import SwiftUI
import AppKit
import StageKit
import PhotoHandoffKit
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

    /// The page pinned below the sidebar's scrolling list, and the items a small unnamed break
    /// follows: Home, then the tools, then History and Library (#134).
    static let pinnedPage = "settings"
    /// What the floating toolbar's one switch does, wherever it appears (#134).
    static let floatingToolbarHelp = "Show between actions. Recording and recovery controls still appear when needed."
    static let sidebarBreaks: Set<String> = ["home", "personas"]

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
            VStack(alignment: .leading, spacing: 0) {
                if let logo = packs.brandLogo {
                    Image(nsImage: logo).resizable().scaledToFit().frame(maxWidth: 150, maxHeight: 36)
                        .padding(8).background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(packs.brandLabel ?? "Workspace").padding(.bottom, 8)
                }
                // The compact name and mark with the Preview identity; a pack's workspace keeps its name (#134).
                WorkbenchHeader(title: packs.brandLabel ?? "Workbench", subtitle: packs.brandLabel == nil ? "" : "Your workspace in Workbench", symbol: "square.stack.3d.up.fill")
                    .padding(.horizontal, 4).padding(.bottom, 12)
                // A section or subpage keeps its page's item highlighted.
                let current = Self.destination(model.page).page
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Self.navItems.filter { $0.id != Self.pinnedPage }, id: \.id) { item in
                            navItem(item, current: current)
                            // Small unnamed breaks after Home and after the tools.
                            if Self.sidebarBreaks.contains(item.id) { Spacer().frame(height: 10) }
                        }
                    }
                }
                if updates.availableVersion != nil || updates.restartWaiting {
                    Button(updates.buttonTitle) { model.page = "settings"; updates.checkForUpdates() }
                        .font(.caption).buttonStyle(.bordered).padding(.vertical, 6)
                }
                // Settings stays reachable below the list, whatever it scrolls to (#134).
                if let settings = Self.navItems.first(where: { $0.id == Self.pinnedPage }) {
                    Divider().padding(.vertical, 6)
                    navItem(settings, current: current)
                }
                Text(updates.build.label).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 8)
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
        WorkbenchHomePage(model: model, stage: stage, readback: readback, snap: snap, introduction: introduction,
                          jobs: model.handoffJobs, photos: model.photoHandoff, meetings: model.meetings)
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
                    // Appearance first: the suite's look, and the one floating-toolbar switch the panel,
                    // the Window menu and the toolbar's own Hide toolbar share (#134).
                    VStack(alignment: .leading, spacing: 8) {
                        WorkbenchSectionTitle("Appearance")
                        WorkbenchAppearancePicker().fixedSize()
                        Toggle("Floating toolbar", isOn: $model.floatingToolbarVisible).toggleStyle(.switch)
                            .help(WorkbenchHome.floatingToolbarHelp)
                        Text(WorkbenchHome.floatingToolbarHelp).font(.caption).foregroundStyle(.secondary)
                    }
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
                        // Opens Dictate on its options and focuses them (#134).
                        Button("Dictate options…") { model.focusRequest = PageFocusRequest(target: .dictateOptions); model.page = "dictate" }
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

    /// A sidebar item: the record's symbol and name, at least 36 points tall. Choosing it opens
    /// its page and starts nothing; every door opens History on All, even from History itself.
    private func navItem(_ item: (id: String, title: String, symbol: String), current: String) -> some View {
        Button {
            keyboard.stopInteraction()
            if item.id == "history" { model.openHistory() } else { model.page = item.id }
        } label: {
            Label(item.title, systemImage: item.symbol).font(.system(size: 13, weight: current == item.id ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).padding(.horizontal, 12)
                .foregroundStyle(current == item.id ? Workbench.accent : .primary)
                .background(current == item.id ? Workbench.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityAddTraits(current == item.id ? .isSelected : [])
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

/// Home follows the journey (#134): what is running or needs recovering, the first-dictation
/// guide while it is offered (#15), three quick starts, the newest History entries, a loaded
/// Snap & Talk session, photos saved from iPhone and the founder card. It is not another tool
/// menu: every tool keeps its sidebar page, where it is prepared.
struct WorkbenchHomePage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var stage: StageKitController
    @ObservedObject var readback: ReadbackModel
    @ObservedObject var snap: SnapModel
    @ObservedObject var introduction: FounderIntroductionModel
    @ObservedObject var jobs: HandoffJobsModel
    @ObservedObject var photos: PhotoHandoffModel
    @ObservedObject var meetings: MeetingModel
    /// Keeps the guide up after the first dictation lands, so where the words
    /// went is seen once; Done or leaving Home ends it.
    @State private var stayInGuide = false
    /// Recent work, merged and sorted again only when a store's rows change: never on a level,
    /// status or selection redraw (#150). History's own filter, search and selection are not read.
    @State private var recentRows = HistoryRowsCache()
    @State private var storesRevision = 0

    var body: some View {
        // The page's own background fills the scrolled content to at least the window's height,
        // so it is drawn with the content, as Dictate's is.
        GeometryReader { proxy in ScrollView {
            VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
                WorkbenchPageHeader("home") {
                    // The way back to the guide after Skip for now, until the first dictation (#15).
                    if journey.offersGuide {
                        Button("Show me a first dictation") { showGuide() }.buttonStyle(.link)
                            .help("Bring back the short guide to your first dictation.")
                    }
                }
                ForEach(journey.sections, id: \.self) { section in
                    switch section {
                    case .currentWork: currentWork
                    case .guide: firstDictation
                    case .firstResult: firstResult
                    case .quickStart: quickStart
                    case .recentWork: recentWork
                    case .continueSession: continueSession
                    case .fromIPhone: fromIPhone
                    }
                }
                if !introduction.isDismissed { FounderIntroductionCard(model: introduction) }
            }.padding(Workbench.pagePadding)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                .background(Workbench.background)
        } }
        .background(Workbench.background)
        .onAppear { if journey.offersSkip { stayInGuide = true } }
        .onReceive(model.$history.dropFirst()) { _ in storesRevision &+= 1 }
        .onReceive(snap.$items.dropFirst()) { _ in storesRevision &+= 1 }
        .onReceive(jobs.$jobs.dropFirst()) { _ in storesRevision &+= 1 }
    }
    /// What Home shows, from its owners. Dictation alone ends the guide (#15).
    private var journey: HomeJourney {
        HomeJourney(transcripts: model.history.count, guide: model.preferences.firstDictationGuide,
                    hasCurrentWork: hasCurrentWork, hasSession: hasSession, photos: photos.photos.count, stayInGuide: stayInGuide)
    }
    /// Skip for now and Show me a first dictation, saved with the Dictate preferences.
    private func skipGuide() { stayInGuide = false; model.preferences.firstDictationGuide = .skipped }
    private func showGuide() { model.preferences.firstDictationGuide = .offered; stayInGuide = true }

    // MARK: Current work

    /// Dictation, reading and their recovery, each read from its owner.
    private var dictationLive: Bool { model.phase != .idle || model.waitingForDrawing }
    private var readingLive: Bool { model.rendering || model.playing || model.paused }
    private var captureRecovery: Bool { model.hasCaptureRecovery && model.phase == .idle }
    /// Anything running, paused or waiting for recovery. A saved transcript or session alone is not.
    private var hasCurrentWork: Bool {
        dictationLive || readingLive || captureRecovery || model.readingFailure != nil || !model.ready
            || readback.isRecording || readback.hasPendingTranscriptions || stage.isDrawing || stage.isPresenting
            || stage.hasActivePersona || stage.hasActiveTimer || meetings.isBusy || jobs.isBusy
    }
    /// Active input first, then recovery, then other running or resumable work, each with its
    /// own truthful action. Leaving Home collapses, acknowledges or discards none of it.
    private var currentWork: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkbenchSectionTitle("Current work")
            // Active input. Stop only stops: a click that lands after the recording ended starts nothing.
            if model.phase == .recording {
                liveRow("Dictating", "mic.fill") { Button("Stop") { model.stopRecording() } }
            }
            if readback.isRecording {
                liveRow("Narrating", WorkbenchHome.symbol(of: "readback")) { Button("Stop") { readback.stopNarration() } }
            }
            if meetings.isRecording { MeetingQuickStatus(model: meetings) { model.page = "meeting" } }
            // Recovery.
            if captureRecovery {
                liveRow("A capture is kept for recovery", "exclamationmark.arrow.circlepath") {
                    if model.canRetry { Button(model.retryCaptureLabel) { model.retryTranscription() }.help(model.retryCaptureHelp) }
                    else { Button("Open Dictate") { model.page = "dictate" } }
                }
            }
            if model.readingFailure != nil {
                liveRow("A reading stopped", "exclamationmark.triangle") {
                    Button("Retry") { model.retryReading() }.disabled(!model.canRetryReading)
                        .help("Makes new audio and reads from the start")
                }
            }
            // The guide shows the speech engine itself while it is offered.
            if !model.ready && !journey.showsGuide { engineBanner }
            // Other running or resumable work.
            if model.waitingForDrawing {
                liveRow("Text ready", "doc.on.clipboard") { Button("Copy") { model.copyWaitingDelivery() } }
            } else if model.phase != .idle && model.phase != .recording {
                liveRow("Processing speech", "waveform") { ProgressView().controlSize(.small) }
            }
            if model.rendering {
                liveRow("Making audio to read", "speaker.wave.2") { Button("Cancel") { model.cancelReading() } }
            } else if model.playing || model.paused {
                liveRow(model.paused ? "Reading paused" : "Reading", "speaker.wave.2") { Button("Stop reading") { model.stopPlayback() } }
            }
            if !readback.isRecording && readback.hasPendingTranscriptions {
                liveRow("Transcribing narration", WorkbenchHome.symbol(of: "readback")) { ProgressView().controlSize(.small) }
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
            if jobs.isBusy {
                liveRow("Running · " + (jobs.jobs.first { $0.id == jobs.activeID }?.title ?? "Hand off task"), "arrow.up.forward.app") {
                    Button("Stop task") { jobs.cancel() }
                }
            }
            if meetings.isBusy && !meetings.isRecording { MeetingQuickStatus(model: meetings) { model.page = "meeting" } }
        }.padding(16).background(Workbench.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
    /// Persona's label, tooltip and click, from the action the panel and toolbar share (#134).
    private var personaControl: HomePersonaControl {
        HomePersonaControl(WorkbenchControlContext(model: model, readback: readback, stage: stage, snap: snap).state)
    }
    /// Does exactly what the Persona label names, through the switch the panel and toolbar use.
    private func perform(_ persona: HomePersonaControl) {
        WorkbenchOperationDispatch(model: model, readback: readback, stage: stage, meetings: meetings) { _ in stage.togglePersona() }
            .perform(persona.operation)
    }
    private func liveRow<Action: View>(_ title: String, _ symbol: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Workbench.accent).frame(width: 20).accessibilityHidden(true)
            Text(title).font(.callout.weight(.medium))
            Spacer()
            action()
        }.controlSize(.small).frame(minHeight: 28)
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

    // MARK: First dictation

    // One guided first dictation: the engine banner until speech is ready, then
    // one accent button whose label follows the phase as the Dictate page does.
    private var firstDictation: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                WorkbenchSectionTitle("First dictation")
                Spacer()
                // One small switch for the guide until the first dictation (#15).
                if journey.offersSkip {
                    Button("Skip for now") { skipGuide() }.buttonStyle(.link)
                        .help("Hide this guide. Show me a first dictation brings it back.")
                }
            }
            Text("One click, and your words are ready to paste anywhere.").foregroundStyle(.secondary)
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

    // MARK: Quick start

    /// Dictate, Read and Snap as three neutral tiles, each doing only what it says. The guide's
    /// own Start dictating replaces the Dictate tile while it shows, and a tile whose operation
    /// is already listed in Current work steps aside.
    private var quickStart: some View {
        let tools = HomeJourney.quickStarts(showsGuide: journey.showsGuide, dictationLive: dictationLive, readingLive: readingLive)
        return VStack(alignment: .leading, spacing: 8) {
            WorkbenchSectionTitle("Quick start")
            // Equal tiles: a label that wraps grows its row, never one tile alone.
            HStack(alignment: .top, spacing: 12) {
                ForEach(tools) { tool in
                    switch tool {
                    case .dictate:
                        // Only ever a start: the toggle would stop a recording begun since this was drawn.
                        card("Dictate", "Start dictating", disabled: !model.ready || model.phase != .idle || readback.blocksDictation) {
                            if model.phase == .idle { model.toggleRecording() }
                        }
                    case .read:
                        card("Read", "Read the clipboard aloud", disabled: model.phase != .idle) { readClipboard() }
                    default:
                        card("Snap", "Capture a region", disabled: snap.disablesCaptureDoors) { Task { await snap.capture(.region) } }
                    }
                }
            }.fixedSize(horizontal: false, vertical: true)
            if tools.contains(.snap) && !snap.screenAccessGranted {
                Text("Screen Recording is off for Workbench. Snap shows how to allow it, or add an image you already have.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    /// A quick-start tile: the capability's registry symbol and name with the exact action it
    /// takes. The whole tile is that one action; its page is the sidebar item.
    private func card(_ title: String, _ verb: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: WorkbenchControlTool.allCases.first { $0.title == title }?.symbol ?? "questionmark")
                    .font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Workbench.sectionTitle)
                    Text(verb).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(12).frame(maxWidth: .infinity, minHeight: 64, maxHeight: .infinity, alignment: .leading)
                .background(Workbench.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Workbench.border))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).disabled(disabled).accessibilityLabel(title + ". " + verb)
    }
    private func readClipboard() {
        if let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.listen(to: text)
        } else { model.status = "Copy some text first."; model.page = "speak" }
    }

    // MARK: Recent work

    /// History All's five newest entries, from History's own merge and order (#134).
    private var recent: [HistoryEntry] {
        HomeRecentWork.newest(recentRows, revision: storesRevision, transcripts: model.history, snaps: snap.items, results: jobs.visibleJobs)
    }
    private var recentWork: some View {
        let entries = recent
        return VStack(alignment: .leading, spacing: 8) {
            WorkbenchSectionTitle("Recent work")
            if entries.isEmpty {
                Text("Your dictations, Snaps and results will appear here.").foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in recentRow(entry) }
            }
            Button("Open History") { model.openHistory() }.buttonStyle(.link)
        }
    }
    /// One entry: its title opens a review of that exact item, and Copy sits beside it where
    /// the owner copies truthfully. Nothing here selects, edits or opens it in Dictate.
    @ViewBuilder private func recentRow(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            switch entry {
            case .transcript(let item):
                Button { if let door = HomeRecentWork.review(for: entry) { model.openHistory(door) } } label: {
                    recentLabel(symbol: "text.quote", title: item.text, detail: "Transcript · " + stamp(item.date))
                }.buttonStyle(.plain).help("Show it in History")
                Button("Copy") { model.copyCapture(item) }
            case .snap(let item):
                CapturePreviewButton("View Snap", item: { .snap(item, store: snap.store) }) {
                    HStack(spacing: 12) {
                        HomeSnapThumbnail(model: snap, item: item)
                        recentText(title: item.title, detail: "Snap · " + stamp(item.createdAt))
                    }.contentShape(Rectangle())
                }
                Button("Copy") { snap.copy(item.id) }
            case .result(let job):
                Button { if let door = HomeRecentWork.review(for: entry) { model.openHistory(door) } } label: {
                    recentLabel(symbol: "arrow.up.forward.app", title: job.title, detail: "Hand off · \(job.status.title) · " + stamp(job.createdAt))
                }.buttonStyle(.plain).help("Show it in History")
            }
        }.controlSize(.small).padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 56)
            .background(Workbench.surface, in: RoundedRectangle(cornerRadius: 10))
    }
    private func recentLabel(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Workbench.accent).frame(width: 24).accessibilityHidden(true)
            recentText(title: title, detail: detail)
        }.contentShape(Rectangle())
    }
    private func recentText(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).lineLimit(2).multilineTextAlignment(.leading)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func stamp(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }

    // MARK: Snap & Talk and iPhone

    /// The loaded session with captures, not already listed as current work.
    private var hasSession: Bool {
        readback.sessionURL != nil && readback.currentSessionProblem == nil && !readback.activeSections.isEmpty
            && !readback.isRecording && !readback.hasPendingTranscriptions
    }
    /// Opens the loaded session's review. It changes the page only: nothing is reloaded, queued or reset.
    private var continueSession: some View {
        let count = readback.activeSections.count
        let updated = readback.manifest.map { " · updated " + stamp($0.updatedAt) } ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            WorkbenchSectionTitle("Continue Snap & Talk")
            HStack(spacing: 12) {
                Image(systemName: WorkbenchHome.symbol(of: "readback")).font(.title3).foregroundStyle(Workbench.accent).frame(width: 24)
                    .accessibilityHidden(true)
                recentText(title: readback.manifest?.title ?? "Snap & Talk session", detail: "\(count) " + (count == 1 ? "capture" : "captures") + updated)
                Button("Open session") { model.page = "readback" }
            }.controlSize(.small).padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 56)
                .background(Workbench.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }
    /// Photos saved from iPhone live in Library; Home links to them with their count and the
    /// newest one's stored date. It never calls them new.
    @ViewBuilder private var fromIPhone: some View {
        if let saved = HomeRecentWork.savedFromIPhone(photos.photos.map(\.created)) {
            Button(saved) { model.page = WorkbenchHome.photoArrivals }
                .buttonStyle(.link).accessibilityIdentifier("home.phone-photos")
        }
    }
}

/// History All's newest entries for Home (#134): History's own merge, order and exclusions
/// with an empty search, the grouped results History shows, then the first five. The cache is
/// History's: it merges and sorts again only when `revision` changes, so a redraw costs nothing
/// (#150). History's filter, search and selection are neither read nor changed.
@MainActor
enum HomeRecentWork {
    static let limit = 5
    static func newest(_ cache: HistoryRowsCache, revision: Int, transcripts: @autoclosure () -> [Transcript],
                       snaps: @autoclosure () -> [SnapItem], results: @autoclosure () -> [HandoffJob]) -> [HistoryEntry] {
        let stores = cache.stores(revision: revision) {
            HistoryRowsCache.Stores(merged: HistoryList.merged(transcripts: transcripts(), snaps: snaps(), results: results()))
        }
        return cache.shown(.init(stores: revision, search: 0, filter: .all, query: "")) {
            Array(HistoryList.shown(stores.merged, filter: .all, query: "", matchTranscripts: { list, _ in list },
                                    matchSnap: { _, _ in true }, resultText: { _ in "" }).prefix(limit))
        }
    }
    /// Where a row's title leads: History on All, showing that transcript or that task. A Snap
    /// opens its own preview instead. Nothing is selected, and a transcript never replaces
    /// Dictate's text (`AppModel.openTranscript` would).
    static func review(for entry: HistoryEntry) -> HistoryDoor? {
        switch entry {
        case .transcript(let item): return HistoryDoor(transcript: item.id)
        case .result(let job): return HistoryDoor(job: job.id)
        case .snap: return nil
        }
    }
    /// Home's link to photos saved from iPhone: how many, and the newest one's stored date. They
    /// are Library's, so they never join Recent work, and the clock never dates them.
    static func savedFromIPhone(_ created: [Date]) -> String? {
        guard let newest = created.max() else { return nil }
        return "Saved from iPhone · \(created.count) \(created.count == 1 ? "photo" : "photos") · newest "
            + newest.formatted(date: .abbreviated, time: .shortened)
    }
}

/// What Home shows, and in what order. Counting is what LocalVoice can reach; live state comes
/// from every module. The first-dictation guide is gated on dictation alone (#15): Snaps,
/// sessions, results and photos never stop offering it. Skip for now keeps one small way back
/// until someone dictates.
struct HomeJourney: Equatable {
    var transcripts = 0
    /// Saved with the Dictate preferences; nil reads as offered.
    var guide: FirstDictationGuide? = nil
    /// Something is running, paused or waiting for recovery.
    var hasCurrentWork = false
    /// A loaded Snap & Talk session with captures, not already current work.
    var hasSession = false
    /// Photos saved from iPhone, in Library.
    var photos = 0
    var stayInGuide = false
    enum Section: Hashable { case currentWork, guide, firstResult, quickStart, recentWork, continueSession, fromIPhone }
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
    /// Current work first, so what is running can be ended from Home; the guide while it is
    /// offered; the quick starts; recent work, except right after the first dictation, when the
    /// guide's own result would repeat it; then a loaded session and photos saved from iPhone.
    var sections: [Section] {
        let result = showsGuide && hasDictated
        return (hasCurrentWork ? [.currentWork] : []) + (showsGuide ? [.guide] : []) + (result ? [.firstResult] : [])
            + [.quickStart] + (result ? [] : [.recentWork]) + (hasSession ? [.continueSession] : []) + (photos > 0 ? [.fromIPhone] : [])
    }
    /// Dictate, Read and Snap, in that order. The guide's own Start dictating replaces the
    /// Dictate tile while it shows; a tile whose operation Current work already lists steps aside.
    static func quickStarts(showsGuide: Bool, dictationLive: Bool, readingLive: Bool) -> [WorkbenchControlTool] {
        [WorkbenchControlTool.dictate, .read, .snap].filter { tool in
            switch tool {
            case .dictate: return !showsGuide && !dictationLive
            case .read: return !readingLive
            default: return true
            }
        }
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
