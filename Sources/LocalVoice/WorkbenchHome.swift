import SwiftUI
import AppKit
import StageKit
import ServiceManagement
import ImageIO

struct WorkbenchHome: View {
    @Environment(\.pageSectionFrames) private var sectionFrames
    @ObservedObject var model: AppModel
    @ObservedObject var stage: StageKitController
    @ObservedObject var keyboard: KeyboardCoachModel
    @ObservedObject var readback: ReadbackModel
    @ObservedObject var snap: SnapModel
    @ObservedObject var history: WorkbenchHistoryModel
    @ObservedObject private var packs: PackLibraryModel
    @ObservedObject private var updates = WorkbenchUpdates.shared
    @StateObject private var introduction = FounderIntroductionModel()
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    @State private var libraryPreparation: LibraryPreparation?
    @State private var openSnapTalkSessions = false
    private struct LibraryPreparation: Identifiable {
        let id = UUID()
        let view: AnyView
    }
    @State private var handoffReview: HandoffReviewRequest?
    @State private var suggestionReview: MetadataSuggestionReview?
    @AppStorage("workbench.sidebarCollapsed.v1") private var sidebarCollapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var greetingPlayed = false
    @State private var showingProfile = false
    @State private var hoveredSidebarItem: String?
    /// Only the offscreen gallery supplies an override; the app keeps the person's choice.
    private var sidebarOverride: Bool?
    private var collapsed: Bool { sidebarOverride ?? sidebarCollapsed }
    /// The page record: every surface that names or opens a window page reads it here, so a
    /// page has one name wherever it appears (#134). The sidebar lists `navItems`, Library and
    /// Settings switch between their `sections`, and `subpages` have no sidebar item of their
    /// own. A capability page's name and symbol are the toolbar's (`ToolbarMode`) and the panel's
    /// (`WorkbenchControlTool`), checked by --check-core. The surface gallery renders each route.
    static let navItems: [(id: String, title: String, symbol: String)] = [
        ("home", "Home", "square.grid.2x2"), ("dictate", "Dictate", "mic"),
        ("meeting", "Meetings", "person.2.wave.2"),
        ("snap", "Snap", "viewfinder"), ("readback", "Snap & Talk", "rectangle.dashed.badge.record"), ("annotate", "Draw", "pencil.tip"),
        ("present", "Present", "iphone"), ("personas", "Persona", "person.crop.rectangle"),
        ("history", "History", "clock"), ("library", "Library", "square.stack"), ("settings", "Settings", "slider.horizontal.3")]
    /// A page's sections, in switcher order. Each opens from its own route, and the page's own
    /// route opens the first; Keyboard, Models and Packs keep the routes their sidebar items had.
    static let sections: [(id: String, page: String, title: String)] = [
        ("library", "library", "Resources"), ("packs", "library", "Packs"),
        ("settings", "settings", "General"), ("shortcuts", "settings", "Keyboard"),
        ("models", "settings", "Models"), ("connections", "settings", "Connections")]
    /// Pages reached from another page. A door to one keeps that page highlighted, so the
    /// sidebar is always the way back.
    static let subpages: [(id: String, page: String, title: String)] = [
        ("dictionary", "dictate", "Your dictionary")]
    /// Routes whose page or section has gone, and the route each now opens. Read's route left
    /// with Read; Library's From iPhone section left with the iPhone photo sync's other doors
    /// (#276). Both open Library on Resources rather than falling through to Dictate.
    static let retiredRoutes: [String: String] = ["speak": "library", "photos": "library"]

    /// The sidebar's footer: "Stable 2.4.1", "Preview 2.4.1 · local" for a build from source, or
    /// "Local build" when there is no version at all.
    static func footer(_ build: WorkbenchBuild) -> String {
        guard build.info["CFBundleShortVersionString"] is String else { return "Local build" }
        return "\(build.edition) \(build.version)" + (build.released ? "" : " · local")
    }

    /// App-wide settings stay reachable below the sidebar's scrolling groups.
    static let pinnedPage = "settings"
    /// What the floating toolbar's one switch does, wherever it appears (#134).
    static let floatingToolbarHelp = "Show between actions. Recording and recovery controls still appear when needed."
    /// Stable, visible groups explain what belongs together without adding a navigation level.
    static let sidebarGroups: [(title: String, routes: [String])] = [
        ("Voice", ["dictate", "meeting"]),
        ("Screen", ["snap", "readback", "annotate", "present", "personas"]),
        ("Saved", ["history", "library"])
    ]

    /// Where a route lands: the sidebar page it highlights and, on a page with sections, the
    /// section it shows. Every door resolves here, so a route that was once a page of its own
    /// still works and nothing lands without a highlighted item. A retired route opens the
    /// route that replaced it. A route nothing knows shows Dictate, as the page switch always has.
    static func destination(_ route: String) -> (page: String, section: String?) {
        let route = retiredRoutes[route] ?? route
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
    // Optional sidebar values are only supplied by the isolated surface gallery.
    init(model: AppModel, stage: StageKitController, keyboard: KeyboardCoachModel, readback: ReadbackModel, snap: SnapModel, sidebarCollapsed: Bool? = nil, sidebarHint: String? = nil, packs: PackLibraryModel? = nil) {
        self.model = model; self.stage = stage; self.keyboard = keyboard; self.readback = readback
        self.snap = snap; self.history = model.historyLibrary
        self._packs = ObservedObject(wrappedValue: packs ?? .shared)
        self.sidebarOverride = sidebarCollapsed
        self._hoveredSidebarItem = State(initialValue: sidebarHint)
    }
    var body: some View {
        HStack(spacing: 0) {
            // Both widths share one icon column, so collapsing or expanding moves only the
            // trailing edge: the toggle, every icon and every row keep their place while the
            // names fade. Collapsing inserts and removes nothing, so nothing below can jump.
            VStack(alignment: .leading, spacing: 0) {
                if let logo = packs.brandLogo {
                    // A fixed height keeps the rows below in place as the logo narrows.
                    Image(nsImage: logo).resizable().scaledToFit().frame(maxWidth: 150).frame(height: 36)
                        .padding(8).background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(packs.brandLabel ?? "Workspace").padding(.bottom, 8)
                }
                // The window already carries the product name. Keep one mark and the edition,
                // with a pack's own name only when it supplies one. The toggle leads, so it
                // stays under the pointer that used it.
                HStack(spacing: 0) {
                    Button { sidebarCollapsed.toggle() } label: {
                        Image(systemName: "sidebar.left").font(.system(size: 16)).frame(width: SidebarMetrics.toggleSize, height: SidebarMetrics.toggleSize)
                    }.buttonStyle(WorkbenchNavigationStyle())
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sectionFrames?("sidebar.toggle", $0) }
                        .modifier(SidebarHintTarget(id: "toggle", title: collapsed ? "Expand sidebar" : "Collapse sidebar",
                            enabled: collapsed, hovered: $hoveredSidebarItem))
                        .accessibilityLabel(collapsed ? "Expand sidebar" : "Collapse sidebar")
                        .keyboardShortcut("s", modifiers: [.command, .control])
                        .accessibilityIdentifier("sidebar.toggle")
                    HStack(spacing: 9) {
                        Image(systemName: "square.stack.3d.up.fill").font(.system(size: 21)).foregroundStyle(Workbench.accent)
                            .accessibilityHidden(true)
                        if let label = packs.brandLabel { Text(label).font(.callout.weight(.semibold)).lineLimit(1) }
                        else if Workbench.isPreview { Text("Preview").font(.caption.weight(.medium)).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                    }.padding(.leading, 9).sidebarName(hidden: collapsed, width: SidebarMetrics.headerNameWidth)
                }.padding(.leading, SidebarMetrics.toggleInset).frame(height: 42).padding(.bottom, 12)
                // A section or subpage keeps its page's item highlighted.
                let current = Self.destination(model.page).page
                ScrollView {
                    VStack(spacing: 2) {
                        if let home = Self.navItems.first(where: { $0.id == "home" }) { navItem(home, current: current) }
                        ForEach(Self.sidebarGroups, id: \.title) { group in
                            // The group's name and the collapsed rule share one slot of one height.
                            Text(group.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                .sidebarName(hidden: collapsed)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.leading, SidebarMetrics.rowInset).padding(.top, 14).padding(.bottom, 4)
                                .overlay { Divider().padding(.horizontal, 8).opacity(collapsed ? 1 : 0) }
                            ForEach(Self.navItems.filter { group.routes.contains($0.id) }, id: \.id) { item in
                                navItem(item, current: current)
                            }
                        }
                    }
                }
                WorkbenchUpdateSidebar(updates: updates, collapsed: collapsed, hovered: $hoveredSidebarItem)
                // Settings stays reachable below the list, whatever it scrolls to (#134).
                if let settings = Self.navItems.first(where: { $0.id == Self.pinnedPage }) {
                    Divider().padding(.vertical, 6)
                    navItem(settings, current: current)
                }
                // One line: the edition and version, or Local build for an unpackaged build.
                Text(Self.footer(updates.build)).font(.caption2).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    .help(updates.build.label)
                    .sidebarName(hidden: collapsed, width: SidebarMetrics.buildLabelWidth)
                    .padding(.leading, SidebarMetrics.rowInset).padding(.top, 8)
            }.padding(.horizontal, SidebarMetrics.inset).padding(.vertical, 14)
                .frame(width: collapsed ? SidebarMetrics.collapsedWidth : SidebarMetrics.expandedWidth, alignment: .leading)
                .clipped().background(Workbench.surface.opacity(0.6))
            Divider()
            Group {
                switch model.page {
                case "home": welcome
                case "readback":
                    ReadbackView(model: readback, onOpenPacks: { model.page = "packs" },
                    onChooseSnaps: { model.page = "snap" }, onReviewHandoff: {
                        guard let session = readback.sessionURL else { return }
                        handoffReview = HandoffReviewRequest(task: "Prepare a clear summary and follow-up from these screenshots and their paired narration.", evidenceURL: session)
                    }, onSaveImageToLibrary: { model.library.saveCapturedImageToLibrary($0) },
                    initialSheet: openSnapTalkSessions ? .sessions : nil,
                             engine: .init(name: model.modelMessage, ready: model.ready, failure: model.modelFailure, preparing: model.preparing),
                    onOpenModels: { model.page = "models" }, onRetryModel: { Task { await model.prepare() } })
                        .onAppear { openSnapTalkSessions = false }
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
                case "history": HistoryView(model: model, snap: snap, openSnapTalkSessions: {
                    openSnapTalkSessions = true; model.page = "readback"
                }, applySuggestedMetadata: { job, result in
                    do { suggestionReview = try MetadataSuggestionReview(job: job, result: result, jobs: model.handoffJobs, transcripts: model.history) }
                    catch { model.handoffJobs.error = error.localizedDescription }
                })
                case "meeting": MeetingWorkspaceView(model: model.meetings, engineName: model.modelMessage,
                    openHistory: { id in model.openHistory(id.map { HistoryDoor(transcript: $0) } ?? HistoryDoor(filter: .transcripts)) },
                    copyTranscript: model.copyMeetingTranscript,
                    openModels: { model.page = "models" },
                    prepareFollowUp: { id in handoffReview = HandoffReviewRequest(task: MeetingFollowUp.task, transcriptID: id) })
                case "annotate": titled("annotate", summary: "Draw attention to what matters, right over your live demo.") { stage.controlsView }
                case "present": titled("present", summary: "Your phone on a clean stage, for calls and demos.") { PresentWorkspaceView(model: model, stage: stage) }
                case "personas": stage.personasView(editProfile: { keyboard.stopInteraction(); showingProfile = true })
                case _ where Self.destination(model.page).page == "library": library
                case _ where Self.destination(model.page).page == "settings": settings
                default: ContentView(model: model, embedded: true)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The sidebar and the page move together as one change. Reduce Motion changes the
        // width at once; the names still fade.
        .animation(reduceMotion ? nil : SidebarMetrics.motion, value: collapsed)
        .overlayPreferenceValue(SidebarHintAnchors.self) { anchors in
            GeometryReader { geometry in
                if collapsed, let id = hoveredSidebarItem, let hint = anchors[id] {
                    let rect = geometry[hint.bounds]
                    SidebarHintLabel(title: hint.title)
                        .frame(width: 0, height: rect.height, alignment: .leading)
                        .offset(x: rect.maxX + 8, y: rect.minY)
                }
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
            .frame(minWidth: 1050, minHeight: 730).tint(Workbench.accent).workbenchTheme()
            .onChange(of: collapsed) { _ in hoveredSidebarItem = nil }
            .onChange(of: model.page) { _ in hoveredSidebarItem = nil }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in hoveredSidebarItem = nil }
            .onDisappear { hoveredSidebarItem = nil }
            .onAppear {
                model.onHandOffSelection = { task in handoffReview = HandoffReviewRequest(task: task) }
                model.onSuggestTranscriptDetails = { id in
                    handoffReview = HandoffReviewRequest(task: MetadataSuggestionReview.task, transcriptID: id)
                }
            }
            .sheet(item: $libraryPreparation) { $0.view }
            .sheet(item: $handoffReview) { request in
                HandoffReviewView(history: model.historyLibrary, jobs: model.handoffJobs,
                    skills: request.transcriptID == nil ? TranscriptHandoffSkill.builtIns + packs.transcriptSkills : [.followUp],
                    initialTask: request.task,
                    preferredSkillID: request.transcriptID == nil ? packs.preferredTranscriptSkillID : nil,
                    selectedSnapTalkSession: request.transcriptID == nil ? readback.sessionURL : nil,
                    initialEvidenceURL: request.evidenceURL,
                    evidenceProblem: { readback.handOffProblem(forEvidence: $0) },
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
            .sheet(isPresented: $showingProfile) { stage.localProfileView }
            // Persona's My Profile… in a live menu, with no profile photo saved yet: the same editor.
            .onChange(of: model.focusRequest) { _, _ in openRequestedProfile() }
            .onAppear { openRequestedProfile() }
    }
    private func openRequestedProfile() {
        guard model.focusRequest?.target == .profile else { return }
        model.focusRequest = nil
        keyboard.stopInteraction(); showingProfile = true
    }
    private var welcome: some View {
        WorkbenchHomePage(model: model, stage: stage, readback: readback, snap: snap, introduction: introduction,
                          jobs: model.handoffJobs, meetings: model.meetings, keyboard: keyboard,
                          greetingPlayed: $greetingPlayed, openProfile: { keyboard.stopInteraction(); showingProfile = true },
                          prepareFollowUp: { id in handoffReview = HandoffReviewRequest(task: MeetingFollowUp.task, transcriptID: id) })
    }
    /// Library holds Resources and Packs as sections of one page, with its switcher at the top
    /// (#134). The route alone chooses the section, so every Library door opens Resources.
    private var library: some View {
        let section = Self.destination(model.page).section ?? "library"
        return VStack(alignment: .leading, spacing: 0) {
            sectionedHeader("library", selection: section)
            switch section {
            case "packs": PackLibraryView(model: packs, onUseEntry: { pack, entry, input in
                packs.use(entry, from: pack, input: input, readback: readback, app: model, stage: stage)
            }, onRetrySavedResource: {
                if packs.addSavedResource(to: model.library, reviewCurrentStore: true) { model.page = "library" }
            })
            default: ContentView(model: model, embedded: true,
                onUseImageInPresent: { prepareLibraryImage($0, for: .present) },
                onUseImageInPersona: { prepareLibraryImage($0, for: .persona) })
            }
        }
    }

    private func prepareLibraryImage(_ image: DemoLibraryImageSnapshot, for destination: DemoLibraryImageUse) {
        keyboard.stopInteraction()
        do {
            let view: AnyView
            switch destination {
            case .present: view = try stage.backdropReplacementView(imageData: image.data, title: image.title)
            case .persona: view = try stage.personaImportView(imageData: image.data, title: image.title)
            }
            libraryPreparation = LibraryPreparation(view: view)
        } catch { model.library.error = error.localizedDescription }
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
                settingsStack {
                    // Each model view names its own job, so its card carries no second title.
                    ModelSettingsView(engine: model.engine, isBusy: model.phase != .idle || model.meetings.isBusy || readback.isRecording || readback.isCapturing || readback.hasPendingTranscriptions,
                                      snapshot: model.recognition, onSnapshot: model.acceptRecognition).workbenchCard()
                    CleanupModelSettingsView(manager: model.cleanupModels, isBusy: model.phase != .idle || model.preparing).workbenchCard()
                }
            case "connections":
                settingsStack {
                    SubscriptionSettingsView(jobs: model.handoffJobs).workbenchCard()
                }
            default:
                // The same cards as every other page, one per subject, with what each setting does
                // beside it rather than only on hover.
                settingsStack {
                    // Saved drawing settings that could not be read or saved, and login, belong to
                    // General: the menu-bar panel's Open Settings… leads to these words (#134).
                    if let notice = stage.notice(on: .general) { WorkbenchNote(notice).workbenchCard() }
                    WorkbenchTile("Appearance", symbol: "circle.lefthalf.filled") {
                        WorkbenchAppearancePicker().labelsHidden().fixedSize()
                    }
                    // The one floating-toolbar switch the panel, the Window menu and the toolbar's own
                    // Hide toolbar share (#134), with the toolbar's own choices beneath it.
                    // The switch is the card's heading: it keeps the one name its four doors share.
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Floating toolbar", isOn: $model.floatingToolbarVisible).toggleStyle(.switch).font(Workbench.sectionTitle)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sectionFrames?("settings.toolbar.visibility", $0) }
                        ToolbarSettingsView(model: model).padding(.leading, 18)
                        Text(WorkbenchHome.floatingToolbarHelp + " Drag the toolbar to move it, or choose a position here.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.workbenchCard()
                    WorkbenchTile("Startup", symbol: "power") {
                        // On means registered with macOS. macOS may still want the person to approve
                        // it in Login Items; then the switch stays on and says so (docs/desktop.md).
                        Toggle("Open Workbench at login", isOn: Binding(get: { loginEnabled || loginNeedsApproval }, set: { value in
                            loginError = nil
                            do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                            catch { loginError = error.localizedDescription }
                            readLoginItem()
                        })).toggleStyle(.switch)
                        Text("Workbench starts in the menu bar; its window opens when you need it.").font(.caption).foregroundStyle(.secondary)
                        if loginNeedsApproval {
                            HStack(spacing: 8) {
                                WorkbenchNote("macOS needs your approval in System Settings › General › Login Items.", font: .caption)
                                Spacer(minLength: 8)
                                Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
                            }
                        }
                        if let loginError { WorkbenchNote(loginError, font: .caption) }
                    }
                    .onAppear(perform: readLoginItem)
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in readLoginItem() }
                    WorkbenchTile("Updates", symbol: "arrow.down.circle") { WorkbenchUpdateSettings() }
                    // Each capability keeps its options on its own page: Meetings holds Detect Meetings
                    // & Calls, so General names only Dictate's door (#134).
                    WorkbenchTile("Dictate", symbol: WorkbenchHome.symbol(of: "dictate")) {
                        HStack(spacing: 12) {
                            // Opens Dictate on its options and focuses them (#134).
                            Button("Dictate settings…") { model.focusRequest = PageFocusRequest(target: .dictateOptions); model.page = "dictate" }
                            // Until the first dictation, Home's guide can be asked for here too (#15).
                            if !HomeJourney(transcripts: model.history.count, guide: model.preferences.firstDictationGuide).hasDictated {
                                Button("Show me a first dictation") { model.preferences.firstDictationGuide = .offered; model.page = "home" }
                            }
                        }
                        Text("Delivery, text style, shortcut, activation and your dictionary."
                             + (Workbench.isPreview ? " Workbench and Workbench Preview keep separate libraries; your previous Voice and StageMark data remains in place." : ""))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    FounderIntroductionCard(model: introduction, canDismiss: false)
                }
            }
        }
    }

    /// Reads macOS's login item state: on, off, or registered but waiting for approval.
    private func readLoginItem() {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled; loginNeedsApproval = status == .requiresApproval
    }

    /// A sidebar item: the record's symbol and name, at least 36 points tall. Choosing it opens
    /// its page and starts nothing; every door opens History on All, even from History itself.
    private func navItem(_ item: (id: String, title: String, symbol: String), current: String) -> some View {
        Button {
            hoveredSidebarItem = nil
            keyboard.stopInteraction()
            if item.id == "history" { model.openHistory() } else { model.page = item.id }
        } label: {
            sidebarRow(item.id, symbol: item.symbol, name: Text(item.title), weight: current == item.id ? .medium : .regular)
                .foregroundStyle(current == item.id ? Workbench.accent : .primary)
        }.buttonStyle(WorkbenchNavigationStyle(selected: current == item.id))
            .modifier(SidebarHintTarget(id: item.id, title: item.title, enabled: collapsed, hovered: $hoveredSidebarItem))
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(current == item.id ? .isSelected : [])
            .accessibilityIdentifier("sidebar." + item.id)
    }

    /// Every sidebar row has one shape: its icon on the shared column, then its name.
    private func sidebarRow(_ id: String, symbol: String, name: Text, weight: Font.Weight = .regular) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14)).imageScale(.medium).frame(width: SidebarMetrics.iconWidth).accessibilityHidden(true)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sectionFrames?("sidebar." + id, $0) }
            name.font(.system(size: 13, weight: weight)).sidebarName(hidden: collapsed)
        }.padding(.leading, SidebarMetrics.rowInset)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 38, alignment: .leading)
    }

    /// A page with sections: its name from the page record, then its switcher, where every
    /// other page has its title (#134). Each section keeps its own summary below.
    private func sectionedHeader(_ page: String, selection: String) -> some View {
        VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
            WorkbenchPageHeader(page, summary: Self.sectionSummaries[selection])
            sectionSwitcher(page, selection: selection) { model.page = $0 }
        }.padding([.horizontal, .top], Workbench.pagePadding)
    }
    /// Every Settings section is the same scrolling stack of kit cards, capped at one width, so the
    /// four sections read as one page (docs/desktop.md § Page kit).
    private func settingsStack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Workbench.sectionSpacing) { content() }
                .frame(maxWidth: Workbench.settingsWidth, alignment: .leading)
                .padding(Workbench.pagePadding).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A section's one-line summary, in the page header above the switcher where every other page
    /// has its own; the section's view does not repeat it.
    static let sectionSummaries: [String: String] = [
        "shortcuts": "One set of shortcuts for speaking, drawing and presenting.",
        "library": "Keep useful prompts, links and files together.",
        "packs": "Reusable skills, scenes, personas and resources."]

    /// A page whose own view draws no page title takes its name from the page record here, in
    /// the same place and type as every other page (#134).
    private func titled<Page: View>(_ route: String, summary: String, @ViewBuilder page: () -> Page) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkbenchPageHeader(route, summary: summary)
                .padding([.horizontal, .top], Workbench.pagePadding)
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
    /// A delivery that did not finish, kept by its owner after the receipt has
    /// gone (#134 T5). Shown only while no current receipt is.
    var unresolved: UnresolvedDelivery? = nil
    let review: () -> Void
    let showCue: () -> Void
    /// Review for an undelivered result: the Dictate page for the draft's
    /// words, History for a transcript's.
    var reviewUnresolved: (UnresolvedDelivery) -> Void = { _ in }
    var copyAgain: () -> Void = {}
    var dismissUnresolved: () -> Void = {}
    var body: some View {
        let receipt = receipts.receipt.flatMap { $0.isClipboardCurrent ? $0 : nil }
        if receipt != nil || unresolved != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let receipt {
                    // The same words as the floating receipt, so the panel, Home and Dictate agree.
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
                } else if let unresolved {
                    // What happened and where the words are, read as one by VoiceOver;
                    // never a ⌘V after an uncertain paste.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: unresolved.symbolName).foregroundStyle(.orange).accessibilityHidden(true)
                            Text(unresolved.title).font(.callout.weight(.semibold)).lineLimit(1)
                        }
                        Text(unresolved.detail)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }.accessibilityElement(children: .combine)
                }
                HStack {
                    Button("Review text") { if receipt == nil, let unresolved { reviewUnresolved(unresolved) } else { review() } }
                    Spacer()
                    if receipt != nil { Button("Show cue", action: showCue) }
                    else if let unresolved {
                        if unresolved.offersCopy { Button("Copy again", action: copyAgain) }
                        Button("Dismiss", action: dismissUnresolved).accessibilityLabel("Dismiss unfinished delivery")
                    }
                }.controlSize(.small)
            }.padding(12)
                .background(Workbench.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Home (docs/desktop.md § Home) shows state and results, never a list of tools: current work,
/// the first-dictation guide while it is offered, your meetings, your decks (or the sample deck
/// before you have one), what this Mac allows and the keys worth learning. Every action acts on
/// the item beside it.
struct WorkbenchHomePage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var stage: StageKitController
    @ObservedObject var readback: ReadbackModel
    @ObservedObject var snap: SnapModel
    @ObservedObject var introduction: FounderIntroductionModel
    @ObservedObject var jobs: HandoffJobsModel
    @ObservedObject var meetings: MeetingModel
    @ObservedObject var keyboard: KeyboardCoachModel
    var greetingPlayed: Binding<Bool> = .constant(true)
    var openProfile: () -> Void = {}
    /// Opens the reviewed follow-up handoff for a saved meeting, as Meetings' own button does.
    var prepareFollowUp: (UUID) -> Void = { _ in }
    /// Read once per visit: the deck that ships with Workbench, or nil in a build without it.
    @State private var sample: SampleDeck?
    @State private var permissions: MacPermissionSnapshot?
    /// Done for now on the Permissions panel. Something turning off opens it again regardless.
    @AppStorage("workbench.home.permissionsDone.v1") private var permissionsDismissed = false
    /// Keeps the guide up after the first dictation lands, so where the words
    /// went is seen once; Done or leaving Home ends it.
    @State private var stayInGuide = false

    var body: some View {
        // The page's own background fills the scrolled content to at least the window's height,
        // so it is drawn with the content, as Dictate's is.
        GeometryReader { proxy in ScrollView {
            VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Home").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        HomeGreeting(hasPlayed: greetingPlayed, returning: journey.hasDictated)
                        // The one way back to the skipped guide, until someone dictates (#15).
                        if journey.offersGuide {
                            Button("Show me a first dictation") { showGuide() }.buttonStyle(.workbenchLink).font(.callout)
                                .help("Bring back the short guide to your first dictation.")
                                .accessibilityIdentifier("home.guide.show")
                        }
                    }
                    Spacer(minLength: 16)
                    Button(action: openProfile) {
                        VStack(spacing: 4) {
                            Group {
                                if let image = stage.localProfileImage { Image(nsImage: image).resizable().scaledToFill() }
                                else { Image(systemName: "person.crop.circle").resizable().scaledToFit().foregroundStyle(.secondary).padding(5) }
                            }.frame(width: 38, height: 38).clipShape(Circle())
                                .background(Workbench.surface, in: Circle())
                            Text("My Profile").font(.caption)
                        }.padding(6)
                    }.buttonStyle(WorkbenchNavigationStyle()).help("Your profile photo, to show as a Persona")
                        .accessibilityLabel("My Profile. Your profile photo").accessibilityIdentifier("home.profile")
                }.padding(.bottom, 8)
                let layout = journey
                ForEach(layout.above, id: \.self) { self.section($0) }
                // Two columns from about 760 points of content: your results on the left, this Mac
                // and the timeline on the right. Narrower, one column in the journey's own order.
                if proxy.size.width - 2 * Workbench.pagePadding >= HomeJourney.twoColumnWidth {
                    HStack(alignment: .top, spacing: Workbench.sectionSpacing) {
                        VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
                            ForEach(layout.leading, id: \.self) { self.section($0) }
                        }.frame(maxWidth: .infinity, alignment: .topLeading)
                        VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
                            ForEach(layout.trailing, id: \.self) { self.section($0) }
                        }.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    ForEach(layout.below, id: \.self) { self.section($0) }
                } else {
                    ForEach(layout.sections.filter { !layout.above.contains($0) }, id: \.self) { self.section($0) }
                }
            }.padding(Workbench.pagePadding)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                .background(Workbench.background)
        } }
        .background(Workbench.background)
        .onAppear { if journey.offersSkip { stayInGuide = true }; sample = SampleDeck.load(); readPermissions() }
        .onChange(of: model.microphoneAuthorization) { _ in readPermissions() }
        .onChange(of: model.accessibilityGranted) { _ in readPermissions() }
        // Returning from System Settings brings Workbench to the front: read again then.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions(); model.refreshMicrophoneAuthorization(); readPermissions()
        }
    }
    /// What Home shows, from its owners. Dictation alone ends the guide (#15).
    /// Whether the first-dictation guide shows, from the same owners `journey` reads, without
    /// current work (which depends on this).
    private var guideShows: Bool {
        HomeJourney(transcripts: model.history.count, guide: model.preferences.firstDictationGuide, stayInGuide: stayInGuide).showsGuide
    }
    private var journey: HomeJourney {
        HomeJourney(transcripts: model.history.count, guide: model.preferences.firstDictationGuide,
                    hasCurrentWork: hasCurrentWork, stayInGuide: stayInGuide, permissionsFolded: !permissionsSnapshot.expanded(dismissed: permissionsDismissed))
    }
    /// The Permissions panel's passive reading; it never asks macOS anything.
    private var permissionsSnapshot: MacPermissionSnapshot {
        permissions ?? MacPermissionReader.current.snapshot(accessibilityAsked: model.preferences.accessibilityRequested == true)
    }
    private func readPermissions() {
        permissions = MacPermissionReader.current.snapshot(accessibilityAsked: model.preferences.accessibilityRequested == true)
    }
    @ViewBuilder private func section(_ section: HomeJourney.Section) -> some View {
        switch section {
        case .currentWork: currentWork
        case .guide: firstDictation
        case .firstResult: firstResult
        case .permissions: HomePermissionsPanel(model: model, snapshot: permissionsSnapshot, dismissed: $permissionsDismissed, refresh: readPermissions)
        case .meetings: HomeMeetingTile(model: model, library: model.historyLibrary, jobs: jobs, prepareFollowUp: prepareFollowUp)
        case .decks: HomeDecksTile(model: model, readback: readback, sample: sample)
        case .keys: HomeKeysTile(model: model, keyboard: keyboard, recording: model.phase != .idle || meetings.isBusy || readback.isRecording)
        }
    }
    /// Skip for now and Show me a first dictation, saved with the Dictate preferences.
    private func skipGuide() { stayInGuide = false; model.preferences.firstDictationGuide = .skipped }
    private func showGuide() { model.preferences.firstDictationGuide = .offered; stayInGuide = true }

    // MARK: Current work

    /// Live dictation read from its owner.
    private var dictationLive: Bool { model.phase != .idle || model.waitingForDrawing }
    /// Active or paused work. Retained dictation audio belongs on Dictate,
    /// where Retry, the saved files and explicit Discard stay together; it is not current work.
    private var hasCurrentWork: Bool {
        // Preparing speech counts only where the card shows it: the first-dictation guide
        // shows the download itself, and a card holding only its title would be empty.
        // The guide reads only History and the saved guide state, never this property: asking
        // `journey` here recursed until the stack overflowed whenever speech was preparing.
        dictationLive || (model.preparing && !model.ready && !guideShows)
            || readback.isRecording || readback.hasPendingTranscriptions || stage.isDrawing || stage.isPresenting
            || personaControl.isCurrentWork || stage.hasTimerSession || meetings.isBusy || jobs.isBusy
    }
    /// Active input first, then other running or resumable work, each with its
    /// own truthful action. Leaving Home collapses, acknowledges or discards none of it.
    private var currentWork: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkbenchSectionTitle("Current work")
            // Active input. Stop only stops: a click that lands after the recording ended starts nothing.
            if model.phase == .recording {
                liveRow("Dictating · " + time(model.elapsed), "record.circle.fill", recording: true) { Button("Stop") { model.stopRecording() } }
            }
            if readback.isRecording {
                liveRow("Narrating · " + time(readback.recordingElapsed), "record.circle.fill", recording: true) { Button("Stop narration") { readback.stopNarration() } }
            }
            if meetings.isRecording { MeetingQuickStatus(model: meetings) { model.page = "meeting" } }
            // The guide shows the speech engine itself while it is offered.
            if !model.ready && !journey.showsGuide { engineBanner }
            // Other running or resumable work.
            if model.waitingForDrawing {
                liveRow("Text ready", "doc.on.clipboard") { Button("Copy") { model.copyWaitingDelivery() } }
            } else if model.phase == .requesting {
                liveRow("Waiting for microphone access", "mic") { Button("Cancel") { model.cancelRecording() } }
            } else if model.phase != .idle && model.phase != .recording {
                liveRow("Processing speech", "waveform") { ProgressView().controlSize(.small) }
            }
            if !readback.isRecording && readback.hasPendingTranscriptions {
                liveRow("Transcribing narration", WorkbenchHome.symbol(of: "readback")) { ProgressView().controlSize(.small) }
            }
            if stage.isDrawing { liveRow("Drawing", "pencil.tip") { Button("Stop drawing") { stage.finishDrawing() } } }
            if stage.isPresenting {
                // The phone's status from its one owner, which the stage's own observation does not
                // forward, so the row follows it while the presentation runs.
                PhoneLinkObserver(phoneLink: stage.phoneLink) { status in
                    // A phone failure takes the kit's triangle in orange, so the row never reads healthy.
                    let failing = stage.presentationShowsPhone && status.tone == .attention
                    liveRow(stage.presentationShowsPhone ? "Presenting · " + status.title : "Presenting",
                            failing ? "exclamationmark.triangle.fill" : "iphone", attention: failing) {
                        Button("End presentation") { stage.endDeviceScene() }
                    }
                }
            }
            if personaControl.isCurrentWork {
                let persona = personaControl
                liveRow("Persona · " + stage.personaStatus, "person.crop.rectangle") {
                    Button(persona.rowTitle) { perform(persona) }.help(persona.help)
                        .id(persona.operation).disabled(!persona.isEnabled)
                }
            }
            if stage.hasTimerSession {
                // The timer's next step, Show or Hide timer and Stop timer, in the one Timer menu.
                // A finished countdown stays here until it is stopped, as its window keeps it.
                liveRow("Timer · " + stage.timerStateDetail, "timer") { NativeControlMenu(title: "Timer") { stage.makeTimerMenu() }.frame(width: 64, height: 24) }
            }
            if jobs.isBusy {
                liveRow("Running · " + (jobs.jobs.first { $0.id == jobs.activeID }?.title ?? "Hand off task"), "arrow.up.forward.app") {
                    Button("Stop task") { jobs.cancel() }
                }
            }
            if meetings.isBusy && !meetings.isRecording { MeetingQuickStatus(model: meetings) { model.page = "meeting" } }
        }.padding(Workbench.tilePadding).background(Workbench.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Workbench.tileRadius))
    }
    /// Persona's label, tooltip and click, from the action the panel and toolbar share (#134).
    private var personaControl: HomePersonaControl {
        HomePersonaControl(WorkbenchControlContext(model: model, readback: readback, stage: stage, snap: snap).state)
    }
    /// Does exactly what the Persona label names, through the switch the panel and toolbar use.
    private func perform(_ persona: HomePersonaControl) {
        let state = WorkbenchControlContext(model: model, readback: readback, stage: stage, snap: snap).state
        guard persona.isAdmitted(in: state) else { return }
        WorkbenchOperationDispatch(model: model, readback: readback, stage: stage, meetings: meetings) { _ in stage.togglePersona() }
            .perform(persona.operation)
    }
    /// A live row: red for a recording, as the toolbar's dot is, the accent for anything else.
    private func liveRow<Action: View>(_ title: String, _ symbol: String, recording: Bool = false, attention: Bool = false, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(recording ? Color.red : attention ? Workbench.attention : Workbench.accent)
                .frame(width: 20).accessibilityHidden(true)
            Text(title).font(.callout.weight(.medium)).monospacedDigit()
            Spacer()
            action()
        }.controlSize(.small).frame(minHeight: 28)
    }
    private var engineBanner: some View {
        HStack {
            if model.preparing || model.cleanupModels.downloading != nil { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.modelMessage).font(.callout)
                if !model.preparing && !model.ready && model.recognition.configuration.provider == .parakeet {
                    Text("About 450 MB to download.").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The writing model's download or its failure, as Dictate's line shows it (#134).
                if let line = model.writingModelLine {
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                // A failed preparation belongs here, beside Retry model: the menu-bar panel's
                // Open Home… leads to these words (#134).
                if let attention = model.attention, attention.page == .home {
                    Text(attention.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if model.preparing { Button("Cancel setup") { model.cancelSpeechPreparation() }.disabled(model.recognition.phase == .cancelling) }
            else if !model.ready && model.recognition.configuration.provider == .parakeet {
                Button("Download Parakeet") { Task { await model.downloadSpeechModel() } }
                if !journey.offersSkip { Button("Not now") { skipGuide() } }
            }
            Button("Models…") { model.page = "models" }
        }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: First dictation

    // One guided first dictation: the engine banner until speech is ready, then
    // one accent button whose label follows the phase as the Dictate page does.
    private var firstDictation: some View {
        WorkbenchTile("First dictation", symbol: WorkbenchHome.symbol(of: "dictate"), accessory: {
            // One small switch for the guide until the first dictation (#15).
            if journey.offersSkip {
                Button("Skip for now") { skipGuide() }.buttonStyle(.workbenchLink)
                    .help("Hide this guide. Show me a first dictation brings it back.")
            }
        }) {
            Text("Record a thought, then copy your words into any app.").foregroundStyle(.secondary)
            if !model.ready && ![.requesting, .recording].contains(model.phase) { engineBanner } else {
                HStack(spacing: 16) {
                    Button { model.toggleRecording() } label: {
                        Label(model.phase == .requesting ? "Cancel" : model.phase == .recording ? "Stop" : "Start dictating",
                              systemImage: model.phase == .requesting ? "xmark" : model.phase == .recording ? "stop.fill" : "mic.fill")
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(![.idle, .requesting, .recording].contains(model.phase) || readback.blocksDictation)
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
                            Button("Set up automatic paste…") { model.requestAccessibility() }.buttonStyle(.workbenchLink)
                        }
                        Spacer()
                        Button("Done") { stayInGuide = false }.buttonStyle(.workbenchLink)
                    }.controlSize(.large)
                    if model.preferences.delivery == .paste && !model.accessibilityGranted {
                        Text("Automatic paste needs Accessibility approval. Until then, transcripts are copied for ⌘V. Your organisation may need to approve this.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    WorkbenchClipboardShelf(receipts: model.clipboardReceipt, unresolved: model.unresolvedDelivery,
                        review: {
                            let source = model.clipboardReceipt.receipt?.source
                            model.clipboardReceipt.dismissHUD()
                            switch source {
                            case .prompt: model.page = "library"
                            case .result(let id): model.openHistory(HistoryDoor(job: id))
                            default: model.openHistory()
                            }
                        },
                        showCue: { model.clipboardReceipt.revealHUD() },
                        reviewUnresolved: { _ in model.reviewUnresolvedDelivery() },
                        copyAgain: { model.copyUnresolvedDelivery() }, dismissUnresolved: { model.dismissUnresolvedDelivery() })
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
        }.padding(Workbench.tilePadding).background(Workbench.surface, in: RoundedRectangle(cornerRadius: Workbench.tileRadius))
            .overlay(RoundedRectangle(cornerRadius: Workbench.tileRadius).strokeBorder(Workbench.border))
    }

}

/// Draws its content from the phone's current status and again whenever it changes. Present's
/// phone state has its own owner in StageKit, apart from the controller Home observes.
private struct PhoneLinkObserver<Content: View>: View {
    @ObservedObject var phoneLink: PhoneLinkMonitor
    @ViewBuilder let content: (PhoneLinkStatus) -> Content
    var body: some View { content(phoneLink.status) }
}

/// What Home shows, and in what order (docs/desktop.md § Home). Live state comes from every
/// module. The first-dictation guide is gated on dictation alone (#15): Snaps, sessions and
/// results never stop offering it. Skip for now keeps one small way back until someone dictates.
struct HomeJourney: Equatable {
    var transcripts = 0
    /// Saved with the Dictate preferences; nil reads as offered.
    var guide: FirstDictationGuide? = nil
    /// Something is running or paused.
    var hasCurrentWork = false
    var stayInGuide = false
    /// The Permissions panel is one line: nothing is off, and everything is allowed or the
    /// person chose Done for now.
    var permissionsFolded = false
    enum Section: Hashable { case currentWork, guide, firstResult, permissions, meetings, decks, keys }
    /// The content width, in points, from which Home uses two columns.
    static let twoColumnWidth: CGFloat = 760
    /// What spans the page above the columns: live work, then the guide while it is offered.
    var above: [Section] { sections.filter { [.currentWork, .guide, .firstResult].contains($0) } }
    /// Your meetings and decks fill the left half. While Permissions is open it has the right
    /// half and your keys run the full width below, in their wide form; once Permissions is one
    /// line, your keys and the folded panel share the right half.
    var leading: [Section] { [.meetings, .decks] }
    var trailing: [Section] { permissionsFolded ? [.keys, .permissions] : [.permissions] }
    var below: [Section] { permissionsFolded ? [] : [.keys] }
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
    /// Current work first, then the guide while offered, then Permissions while it is open, then
    /// your meetings, decks and keys, and a folded Permissions last. Home holds
    /// only what the app shows nowhere else in that form; History keeps everything else
    /// (docs/desktop.md).
    var sections: [Section] {
        let result = showsGuide && hasDictated
        return (hasCurrentWork ? [.currentWork] : []) + (showsGuide ? [.guide] : []) + (result ? [.firstResult] : [])
            + (permissionsFolded ? [.meetings, .decks, .keys, .permissions] : [.permissions, .meetings, .decks, .keys])
    }
}
