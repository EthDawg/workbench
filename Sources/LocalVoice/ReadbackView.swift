import AppKit
import Combine
import ImageIO
import StageKit
import SwiftUI

struct ReadbackView: View {
    @ObservedObject var model: ReadbackModel
    var onOpenPacks: () -> Void = {}
    var onChooseSnaps: (() -> Void)?
    var onReviewHandoff: (() -> Void)?
    var onSaveImageToLibrary: ((CaptureImagePreviewItem) -> String?)?
    /// The speech model narration is transcribed with, as the host's readiness line names it;
    /// nil only where no host owns one, such as the isolated gallery.
    var engine: NarrationEngine?
    var onOpenModels: () -> Void = {}
    var onRetryModel: () -> Void = {}
    @State private var sheet: Sheet?
    @State private var afterSheet: (() -> Void)?
    @State private var captureMode: SnapCapture.Mode = .screen
    @State private var confirmEmptyTrash = false
    @State private var discardEdit: UUID?
    @State private var copyResult: String?
    @State private var imageResult: String?
    /// Cancel discards a narration; past a few seconds it asks first, because Stop keeps it.
    @State private var confirmCancelNarration = false
    @Environment(\.pageSectionFrames) private var sectionFrames
    /// Only the isolated gallery supplies presentation values; live controls read their owner.
    private var capturePresentation: CapturePresentation?
    struct CapturePresentation { var recording = false; var capturing = false; var elapsed = 0.0 }
    private var isRecording: Bool { capturePresentation?.recording ?? model.isRecording }
    private var isCapturing: Bool { capturePresentation?.capturing ?? model.isCapturing }

    init(model: ReadbackModel, onOpenPacks: @escaping () -> Void = {}, onChooseSnaps: (() -> Void)? = nil,
         onReviewHandoff: (() -> Void)? = nil, onSaveImageToLibrary: ((CaptureImagePreviewItem) -> String?)? = nil, initialSheet: Sheet? = nil, capturePresentation: CapturePresentation? = nil,
         engine: NarrationEngine? = nil, onOpenModels: @escaping () -> Void = {}, onRetryModel: @escaping () -> Void = {}) {
        self.model = model; self.onOpenPacks = onOpenPacks; self.onChooseSnaps = onChooseSnaps; self.onReviewHandoff = onReviewHandoff; self.onSaveImageToLibrary = onSaveImageToLibrary
        self._sheet = State(initialValue: initialSheet); self.capturePresentation = capturePresentation
        self.engine = engine; self.onOpenModels = onOpenModels; self.onRetryModel = onRetryModel
    }

    /// What turns narration into text, where it runs, and the way to change it (workbench.md,
    /// rule 9), beside Record narration. While the model is not ready, it says so here with Retry
    /// model and Models…, so a recording never waits in a silent queue (Fit rule 2).
    @ViewBuilder private var narrationEngine: some View {
        if let engine {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if engine.preparing { ProgressView().controlSize(.small) }
                    // Orange words fail contrast on a light page: only the symbol carries attention.
                    Label {
                        Text(engine.line).foregroundStyle(engine.needsAttention ? Color.primary : Color.secondary)
                    } icon: {
                        Image(systemName: engine.needsAttention ? "exclamationmark.triangle.fill" : "waveform")
                            .foregroundStyle(engine.needsAttention ? Workbench.attention : Color.secondary)
                    }
                        .font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if engine.needsAttention { Button("Retry model", action: onRetryModel).buttonStyle(.link).font(.caption) }
                    Button("Models…", action: onOpenModels).buttonStyle(.link).font(.caption)
                        .help("Choose the speech model in Settings › Models")
                }
                if engine.needsAttention {
                    Text("You can record now. If the model still can’t be prepared, the recording is kept with Retry transcription.").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !engine.ready {
                    Text("You can record for later. Open Models when you want to prepare speech; setup never starts recording.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    enum Sheet: String, Identifiable { case sessions, settings, ordering, deleted; var id: String { rawValue } }

    /// The host supplies its actual phase; unavailable or deferred is never
    /// inferred to mean preparing. The readiness line already names any failure.
    struct NarrationEngine: Equatable {
        var name: String
        var ready: Bool
        var failure: String?
        /// Still on its way: the line carries its progress and needs only patience.
        var preparing: Bool = false
        /// A stopped preparation with no ready engine needs Retry model.
        var needsAttention: Bool { failure != nil && !ready }
        /// The line beside Record narration: the ready engine's name, or the readiness line with its reason.
        var line: String { name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkbenchPageHeader("readback", summary: "Capture a screen, say what matters, and hand the story off.") {
                Button("Sessions…") { sheet = .sessions }
                    .accessibilityIdentifier("readback.sessions")
                Button("Settings…") { sheet = .settings }
                    .accessibilityIdentifier("readback.settings")
            }.padding(Workbench.pagePadding)
            if model.sessionURL == nil { emptyState }
            else {
                sessionHeader
                captureControls
                workspaceNotices
                Divider()
                if let problem = model.currentSessionProblem {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            unavailableSession(problem)
                            if let section = model.reviewedSection, model.transcriptSaveFailures[section.id] != nil,
                               let index = model.activeSections.firstIndex(where: { $0.id == section.id }) {
                                sectionDetail(section, number: index + 1)
                            }
                        }.padding(Workbench.pagePadding)
                    }
                } else if model.activeSections.isEmpty {
                    ContentUnavailableView("Capture your first screen", systemImage: "camera.viewfinder",
                        description: Text("Choose a region, window or screen above, then explain what matters. You can also add saved Snaps."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { sectionWorkspace }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Workbench.background)
        .onChange(of: model.reviewedSectionID) { _, _ in copyResult = nil; imageResult = nil }
        .confirmationDialog("Discard this unsaved narration edit?", isPresented: Binding(get: { discardEdit != nil }, set: { if !$0 { discardEdit = nil } })) {
            Button("Discard unsaved edit", role: .destructive) {
                if let id = discardEdit { model.discardTranscriptEdit(id) }; discardEdit = nil
            }
            Button("Keep editing", role: .cancel) { discardEdit = nil }
        } message: { Text("Copy the text first if you need it. Saved screenshots, audio and original transcription stay intact.") }
        .confirmationDialog("Discard this narration?", isPresented: $confirmCancelNarration) {
            Button("Discard", role: .destructive) { model.cancelNarration() }
            Button("Keep recording", role: .cancel) {}
        } message: { Text("Stop narration keeps it. Discarding removes this recording; the screenshot and any earlier narration stay.") }
        .sheet(item: $sheet, onDismiss: {
            let action = afterSheet; afterSheet = nil; action?()
        }) { destination in
            switch destination {
            case .sessions: sheetContent("Sessions", dismiss: "Close") { sessionChoices }
            case .settings: sheetContent("Snap & Talk settings", dismiss: "Done") { settings }
            case .deleted: sheetContent("Recently Deleted", dismiss: "Close") { recentlyDeleted }
            case .ordering:
                if let root = model.sessionURL { ReadbackOrderingView(model: model, sessionURL: root) }
            }
        }
        .task {
            model.refreshSkillPacks()
            while !Task.isCancelled {
                model.refreshSessionAvailability()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { break }
            }
        }
        .onDisappear { model.cancelCaptureAccess() }
    }

    // Native file panels and navigation start after the current sheet has closed.
    private func dismissThen(_ action: @escaping () -> Void) { afterSheet = action; sheet = nil }

    /// Close leaves a list; Done finishes the settings it changed.
    private func sheetContent<Content: View>(_ title: String, dismiss: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(dismiss) { sheet = nil }.keyboardShortcut(.defaultAction)
            }.padding(24)
            Divider()
            ScrollView { content().padding(24).frame(maxWidth: .infinity, alignment: .leading) }
        }.frame(width: 570, height: 520).onExitCommand { sheet = nil }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Workbench.sectionSpacing) {
                WorkbenchEmptyState(symbol: "rectangle.dashed.badge.record", title: "Capture a screen. Tell its story.",
                                    detail: "Build a session of screenshots and narration, review it, then hand it off to your assistant.") {
                    Button("New session…") { model.createSession() }.buttonStyle(.borderedProminent)
                        .disabled(model.newSessionStyleProblem != nil)
                    Button("Open session…") { model.openSession() }
                }.workbenchCard()
                if let problem = model.newSessionStyleProblem {
                    VStack(alignment: .leading, spacing: 8) {
                        WorkbenchNote(problem)
                        Button("Choose a session skill…") { sheet = .settings }
                    }
                }
                if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                if !model.recentSessionURLs.isEmpty {
                    WorkbenchSectionTitle("Recent sessions")
                    recentSessions(inSheet: false)
                }
            }.padding(.horizontal, Workbench.pagePadding).padding(.bottom, 24)
                .frame(maxWidth: 900, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sessionHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.manifest?.title ?? model.sessionURL?.lastPathComponent ?? "Session")
                    .font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    .help(model.manifest?.title ?? "Session").accessibilityAddTraits(.isHeader)
                Text(sessionSummary).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("readback.session-status")
            }
            Spacer(minLength: 8)
            Menu {
                if let onReviewHandoff {
                    Button("Review selected evidence…", action: onReviewHandoff)
                    Divider()
                }
                ForEach(ReadbackHandoffTarget.allCases) { target in
                    Button { model.handOff(to: target) } label: {
                        Label(target.title, systemImage: target == .claude ? "sparkles" : "bubble.left.and.text.bubble.right")
                    }
                }
                Divider()
                Text("Copies instructions. You share the session.")
            } label: { Label("Hand off", systemImage: "arrow.up.forward.app") }
                .disabled(!model.canHandOffSession || isRecording || isCapturing)
                .help(model.sessionProcessingCount > 0 ? "Wait for this session's narration to finish transcribing." : "Review the session, or copy instructions and open your assistant. Nothing is sent automatically.")
                .accessibilityIdentifier("readback.handoff")
            Menu {
                Button("Reorder sections…") { sheet = .ordering }
                    .disabled(model.currentSessionProblem != nil || model.activeSections.count < 2 || model.isRecording || model.isCapturing)
                Button("Recently Deleted…") { sheet = .deleted }
                    .disabled(model.currentSessionProblem != nil || model.deletedSections.isEmpty)
                Divider()
                Button("Show in Finder") { model.revealSession() }.disabled(model.currentSessionProblem != nil)
                Button("Close session") { model.closeSession() }.disabled(model.isRecording)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Session actions")
        }.padding(.horizontal, Workbench.pagePadding).padding(.bottom, 14)
    }

    private var elapsed: Double { capturePresentation?.elapsed ?? model.recordingElapsed }

    private var sessionSummary: String {
        let count = model.activeSections.count
        let base = "\(count) \(count == 1 ? "section" : "sections")"
        if model.sessionProcessingCount > 0 { return base + " · \(model.sessionProcessingCount) transcribing" }
        let failed = model.activeSections.filter { $0.status == .failed }.count
        if failed > 0 { return base + " · " + (failed == 1 ? "1 needs a retry" : "\(failed) need a retry") }
        return base
    }

    /// Outside the scrolling section content: Stop and Cancel never scroll away.
    private var captureControls: some View {
        HStack(spacing: 12) {
            if isRecording {
                Image(systemName: "record.circle").foregroundStyle(.red)
                // The rail's and the toolbar's words for this state, with the toolbar's live level.
                Text("Recording narration").font(.body.weight(.medium))
                Text(time(elapsed)).monospacedDigit().foregroundStyle(.secondary)
                NarrationLevel(level: capturePresentation == nil ? model.recordingLevel : 0.55)
                Spacer(minLength: 8)
                // Stop keeps; Cancel discards, so a long narration asks first (Escape too).
                Button("Cancel") { if elapsed > 10 { confirmCancelNarration = true } else { model.cancelNarration() } }
                    .keyboardShortcut(.cancelAction)
                    .help("Discard this narration. The screenshot stays.")
                Button("Stop narration") { model.stopNarration() }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("readback.stop")
            } else if isCapturing {
                ProgressView().controlSize(.small)
                Text("Capturing…")
                Spacer()
                Button("Cancel capture") { model.cancelCapture() }
            } else {
                Picker("Capture area", selection: $captureMode) {
                    ForEach(SnapCapture.Mode.allCases) { Text($0.title).tag($0) }
                // Its natural width, so the control starts on the page's column rather than centred in a frame.
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Button {
                    Task { await model.captureNewSection(fromEditor: true, mode: captureMode) }
                } label: { Label("Capture & narrate", systemImage: "camera.viewfinder") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.permissionsReady || model.currentSessionProblem != nil)
                    .help("Capture the chosen area, then start narration. \(model.shortcutLabel) captures the display under your pointer.")
                    .accessibilityIdentifier("readback.capture")
                Spacer(minLength: 0)
                if let onChooseSnaps {
                    Button("Add from Snap History…", action: onChooseSnaps)
                        .disabled(model.currentSessionProblem != nil)
                }
            }
        // On the page itself, so its controls start on the 24 pt column with the header's;
        // the height stays fixed while recording replaces the capture choices.
        }.controlSize(.regular)
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.horizontal, Workbench.pagePadding).padding(.bottom, 12)
            .accessibilityElement(children: .contain).accessibilityLabel("Capture controls")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sectionFrames?("readback.capture-controls", $0) }
    }

    @ViewBuilder private var workspaceNotices: some View {
        if model.hasUnsavedNarration {
            HStack {
                WorkbenchNote("A narration edit couldn’t be saved.")
                Spacer()
                Button("Review unsaved edit") { model.reviewUnsavedNarration() }
            }.padding(.horizontal, 24).padding(.bottom, 12)
        }
        if !model.isRecording && !model.isCapturing && model.currentSessionProblem == nil && !model.permissionsReady {
            // Snap's card: what is off, what still works, then its buttons below the words.
            CaptureAccessCard(title: accessTitle, symbol: model.screenPermissionGranted ? "mic.slash" : "rectangle.dashed.badge.record",
                              detail: accessDetail,
                              reopenHint: model.suggestsReopenForScreenAccess && !model.screenPermissionGranted ? ScreenCaptureAccess.reopenHint : nil,
                              footnote: model.screenPermissionGranted ? nil : "Allow Workbench under Privacy & Security › Screen Recording. macOS may ask you to quit and reopen Workbench afterwards. If your organisation manages this Mac, it may keep screen capture off.") {
                if !model.screenPermissionGranted || model.microphonePermission == .notDetermined {
                    Button("Request capture access") { Task { await model.requestCaptureAccess() } }
                        .disabled(model.isRequestingCaptureAccess)
                }
                Button("Check access") { Task { await model.preflightPermissions() } }
                Spacer(minLength: 8)
                Button("Open System Settings…") {
                    if model.screenPermissionGranted { model.openMicrophoneSettings() } else { model.openScreenRecordingSettings() }
                }.help(model.screenPermissionGranted ? "Privacy & Security › Microphone. Workbench changes no setting itself." : "Privacy & Security › Screen Recording. Workbench changes no setting itself.")
            }.padding(.horizontal, Workbench.pagePadding).padding(.bottom, 12)
        }
        if let failure = model.shortcutFailure {
            HStack {
                WorkbenchNote(failure, symbol: "keyboard", font: .caption)
                Spacer()
                Button("Change shortcut…") { model.onEditShortcut?() }
            }.padding(.horizontal, 24).padding(.bottom, 12)
        }
        if let notice = model.notice, notice != model.permissionsProblem {
            Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 24).padding(.bottom, 12)
        }
    }

    private var accessTitle: String {
        if model.isRequestingCaptureAccess { return "Finish the request in macOS" }
        if !model.screenPermissionGranted { return "Screen Recording is off for Workbench" }
        switch model.microphonePermission {
        case .notDetermined: return "Narration needs the microphone"
        case .restricted: return "The microphone is restricted on this Mac"
        default: return "Microphone is off for Workbench"
        }
    }
    private var accessDetail: String {
        if model.isRequestingCaptureAccess { return model.captureAccessMessage ?? "" }
        if !model.screenPermissionGranted {
            return "Capture & narrate needs it to take a screenshot. Your sessions, screenshots and narration stay here, and you can add Snaps you already have."
        }
        switch model.microphonePermission {
        case .notDetermined: return "Request capture access when you want to record narration. Your sessions and screenshots stay here, and you can type notes."
        case .restricted: return "macOS reports it as restricted, so narration can’t record. Your sessions and screenshots stay here, and you can type notes."
        default: return "Narration needs it to record. Your sessions and screenshots stay here, and you can type notes."
        }
    }

    private var sectionWorkspace: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(model.activeSections.enumerated()), id: \.element.id) { index, section in
                            Button { model.reviewSection(section.id) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    ReadbackThumbnail(root: model.sessionURL, relative: section.screenshot, revision: section.capturedAt, maxPixelSize: 400)
                                        .frame(maxWidth: .infinity).frame(height: 76).clipped()
                                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                    HStack(spacing: 6) {
                                        Text("Section \(index + 1)").font(.caption.weight(.medium))
                                        Spacer(minLength: 0)
                                        // A ready section needs no mark; only one that is not ready shows why.
                                        if section.status != .ready {
                                            Image(systemName: statusSymbol(section.status))
                                                .foregroundStyle(section.status == .failed ? Workbench.attention : Color.secondary)
                                        }
                                    }
                                    if let words = firstLine(model.transcriptDrafts[section.id]) {
                                        Text(words).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }.padding(8).contentShape(Rectangle())
                            }.buttonStyle(WorkbenchNavigationStyle(selected: model.reviewedSectionID == section.id))
                                .accessibilityLabel("Section \(index + 1), \(section.status.title)")
                                .accessibilityAddTraits(model.reviewedSectionID == section.id ? .isSelected : [])
                                .id(section.id)
                        }
                    }.padding(12)
                }
                .onChange(of: model.reviewedSectionID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .onAppear { if let id = model.reviewedSectionID { proxy.scrollTo(id) } }
            }.frame(width: 164).accessibilityLabel("Session sections")
            Divider()
            ScrollView {
                if let section = model.reviewedSection,
                   let index = model.activeSections.firstIndex(where: { $0.id == section.id }) {
                    sectionDetail(section, number: index + 1).padding(Workbench.pagePadding)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionDetail(_ section: ReadbackSection, number: Int) -> some View {
        let changing = model.isRecording || model.isCapturing || [.queued, .transcribing].contains(section.status) || model.transcriptSaveFailures[section.id] != nil
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Section \(number) of \(model.activeSections.count)").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                WorkbenchStatusBadge(text: section.status.title,
                                     tone: section.status == .failed ? .attention : section.status == .ready ? .done : .neutral,
                                     symbol: section.status == .failed ? "exclamationmark.triangle.fill" : statusSymbol(section.status))
                Menu {
                    Button("View image") { CaptureImagePreview.shared.show(preview(section, number: number), collection: activeImages) }
                    if let onSaveImageToLibrary {
                        Button("Save image to Library…") { imageResult = onSaveImageToLibrary(preview(section, number: number)) }
                    }
                    Divider()
                    Button("Replace screenshot…") { Task { await model.replaceScreenshot(section.id) } }.disabled(changing)
                    Button(section.audio == nil ? "Record narration" : "Re-record narration") { model.startNarration(for: section.id) }
                        .disabled(changing || model.microphonePermission != .authorized)
                    Button("Redo screenshot and narration…") { Task { await model.redoBoth(section.id) } }.disabled(changing)
                    Divider()
                    Button("Move to Recently Deleted") { model.deleteSection(section.id) }.disabled(changing)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Actions for section \(number)")
            }
            CapturePreviewButton(ReadbackItemNames.view(sectionNumber: number), item: { preview(section, number: number) }, collection: { activeImages }) {
                ReadbackThumbnail(root: model.sessionURL, relative: section.screenshot, revision: section.capturedAt, maxPixelSize: 1600)
                    .frame(maxWidth: .infinity).frame(height: 250)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10)).clipped()
            }
            if let imageResult { Text(imageResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if let failure = section.failure { WorkbenchNote(failure) }
            if section.status == .ready {
                HStack {
                    WorkbenchSectionTitle(section.audio == nil ? "Notes" : "Narration")
                    Spacer()
                    if section.audio == nil {
                        Button("Record narration") { model.startNarration(for: section.id) }
                            .disabled(changing || model.microphonePermission != .authorized)
                    }
                }
                if section.audio == nil { narrationEngine }
                TextEditor(text: Binding(get: { model.transcriptDrafts[section.id] ?? "" }, set: { model.updateTranscript($0, for: section.id) }))
                    .font(.body).frame(height: 180).padding(8)
                    .background(Workbench.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Workbench.border))
                    .accessibilityLabel(section.audio == nil ? "Notes for section \(number)" : "Narration for section \(number)")
                if let failure = model.transcriptSaveFailures[section.id] {
                    WorkbenchNote(failure)
                    HStack {
                        Button("Retry save") { model.retryTranscriptSave(section.id) }
                        Button("Copy text") { copyResult = TextDelivery.copy(model.transcriptDrafts[section.id] ?? "") == nil ? "Text could not be copied." : "Copied" }
                        Spacer()
                        Button("Discard unsaved edit…") { discardEdit = section.id }
                    }
                    if let copyResult { Text(copyResult).font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text(section.originalTranscript == nil ? "Optional notes save automatically." : "Edits save automatically. The original narration is kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if section.status == .failed, section.audio != nil {
                Button("Retry transcription") { model.retryTranscription(section.id) }
                    .disabled(model.isRecording || model.isCapturing)
                narrationEngine
            } else if section.status == .needsNarration {
                HStack {
                    Text("The screenshot is saved. Add narration when you’re ready.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Record narration") { model.startNarration(for: section.id) }
                        .disabled(changing || model.microphonePermission != .authorized)
                }
                narrationEngine
            } else if section.status == .failed {
                Button("Record narration") { model.startNarration(for: section.id) }
                    .disabled(changing || model.microphonePermission != .authorized)
                narrationEngine
            } else {
                HStack(spacing: 8) {
                    if section.status != .recording { ProgressView().controlSize(.small) }
                    Text(section.status == .recording ? "Narration is recording. Use Stop narration above when you’re done." : "Transcribing this section. You can review another section while it finishes.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sessionChoices: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("New session…") { dismissThen { model.createSession() } }
                    .buttonStyle(.borderedProminent).disabled(model.isRecording || model.newSessionStyleProblem != nil)
                Button("Open session…") { dismissThen { model.openSession() } }.disabled(model.isRecording)
            }
            if model.newSessionStyleProblem != nil {
                WorkbenchNote("The skill for new sessions is unavailable. Choose another in Snap & Talk settings.")
            }
            Divider()
            WorkbenchSectionTitle("Recent sessions")
            if model.recentSessionURLs.isEmpty { Text("Sessions you create or open appear here.").foregroundStyle(.secondary) }
            recentSessions(inSheet: true)
        }
    }

    private func recentSessions(inSheet: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.recentSessionURLs, id: \.path) { url in
                let problem = model.unavailableSessions[url.standardizedFileURL.path]
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        if inSheet { dismissThen { model.openRecent(url) } } else { model.openRecent(url) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: problem == nil ? "folder" : "folder.badge.questionmark").foregroundStyle(.secondary)
                            Text(url.lastPathComponent).lineLimit(2)
                            Spacer()
                            if model.sessionURL?.standardizedFileURL == url.standardizedFileURL { Text("Current").font(.caption).foregroundStyle(.secondary) }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.padding(10).contentShape(Rectangle())
                    }.buttonStyle(WorkbenchNavigationStyle()).disabled(model.isRecording)
                    if problem != nil {
                        HStack {
                            WorkbenchStatusBadge(text: "Folder unavailable", tone: .attention, symbol: "folder.badge.questionmark")
                            Spacer()
                            Button("Locate…") {
                                if inSheet { dismissThen { model.locateSession(url) } } else { model.locateSession(url) }
                            }.disabled(model.isRecording || model.isCapturing || model.hasPendingTranscriptions)
                            Button("Remove") { model.forgetRecentSession(url) }
                                .disabled(model.sessionURL?.standardizedFileURL == url.standardizedFileURL && (model.isRecording || model.isCapturing))
                                .help("Remove this entry from Recents only; no files are deleted")
                        }.controlSize(.small).padding(.horizontal, 10)
                    }
                }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let root = model.sessionURL {
                VStack(alignment: .leading, spacing: 6) {
                    WorkbenchSectionTitle("Current session")
                    Text(model.manifest?.title ?? root.lastPathComponent).font(.body.weight(.medium))
                    Label(root.lastPathComponent, systemImage: "folder").font(.caption).foregroundStyle(.secondary).help(root.path)
                    Text("Skill: \(model.manifest?.skillPack?.name ?? "Session skill")").font(.callout).foregroundStyle(.secondary)
                    Button("Show in Finder") { dismissThen { model.revealSession() } }.disabled(model.currentSessionProblem != nil)
                }
                Divider()
            }
            VStack(alignment: .leading, spacing: 8) {
                WorkbenchSectionTitle("New sessions")
                Picker("Skill", selection: Binding(get: { model.selectedSkillChoice }, set: { model.selectSkill($0) })) {
                    Text("Neutral slides").tag("legacy-neutral")
                    if model.installedServiceNow != nil || model.newSessionStyle == .serviceNow {
                        Text("ServiceNow (previously installed)").tag("legacy-serviceNow")
                    }
                    ForEach(model.packSkills) { Text($0.title).tag($0.id) }
                    if let id = model.newSessionSkillID, !model.packSkills.contains(where: { $0.id == id }) { Text("Unavailable skill").tag(id) }
                }.pickerStyle(.menu)
                Text("Each new session keeps a copy. Existing sessions keep their chosen skill.").font(.caption).foregroundStyle(.secondary)
                Button("Manage packs…") { dismissThen(onOpenPacks) }
                if let problem = model.newSessionStyleProblem { WorkbenchNote(problem, font: .caption) }
                else if let notice = model.skillPackNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                WorkbenchSectionTitle("Capture access")
                permission("Screen Recording", granted: model.screenPermissionGranted) { model.openScreenRecordingSettings() }
                permission("Microphone", granted: model.microphonePermission == .authorized, notAsked: model.microphonePermission == .notDetermined) { model.openMicrophoneSettings() }
                Button("Check access") { Task { await model.preflightPermissions() } }
                if !model.screenPermissionGranted || model.microphonePermission == .notDetermined {
                    Button("Request capture access") { Task { await model.requestCaptureAccess() } }
                        .disabled(model.isRequestingCaptureAccess)
                }
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    WorkbenchSectionTitle("Keyboard shortcut")
                    Text("\(model.shortcutLabel) captures the display under your pointer and starts narration. Press again to stop.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Change shortcut…") { dismissThen { model.onEditShortcut?() } }
            }
        }
    }

    /// macOS's own distinctions, as Home's Permissions rows say them; only Off is orange.
    private func permission(_ title: String, granted: Bool, notAsked: Bool = false, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            WorkbenchStatusBadge(text: granted ? "Allowed" : notAsked ? "Not asked yet" : "Off", tone: granted ? .done : notAsked ? .neutral : .attention)
            Button("Open System Settings…", action: action)
        }
    }

    private func unavailableSession(_ problem: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Session folder unavailable", systemImage: "folder.badge.questionmark").font(.title3.weight(.semibold))
            Text(problem).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Locate its folder or reconnect the drive to continue. Removing it from Recents leaves its files intact.")
                .font(.callout).foregroundStyle(.secondary)
            if let root = model.sessionURL {
                HStack {
                    Button("Locate folder…") { model.locateSession(root) }.buttonStyle(.borderedProminent)
                        .disabled(model.isRecording || model.isCapturing || model.hasPendingTranscriptions)
                    Button("Check again") { model.refreshSessionAvailability() }
                    Button("Remove from Recents") { model.forgetRecentSession(root) }.disabled(model.isRecording || model.isCapturing)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recentlyDeleted: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restore a section to put its screenshot and narration back in the session.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(model.deletedSections) { section in
                HStack(spacing: 12) {
                    CapturePreviewButton(ReadbackItemNames.viewDeleted(section), item: { preview(section, number: nil) }, collection: { deletedImages }) {
                        ReadbackThumbnail(root: model.sessionURL, relative: section.screenshot, revision: section.capturedAt, maxPixelSize: 400)
                            .frame(width: 100, height: 60).clipped()
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }
                    // Named by when it was captured and what was said, not by the display it came from.
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Section from \(section.capturedAt.formatted(date: .abbreviated, time: .shortened))").font(.callout.weight(.medium))
                        if let words = firstLine(model.transcriptDrafts[section.id]) {
                            Text(words).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let deletedAt = section.deletedAt {
                            Text("Deleted \(deletedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Restore") { model.restoreSection(section.id) }
                }.padding(10).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Workbench.border))
            }
            Button("Empty Recently Deleted…", role: .destructive) { confirmEmptyTrash = true }
                .disabled(model.deletedSections.isEmpty)
        }.confirmationDialog("Permanently delete every section in Recently Deleted?", isPresented: $confirmEmptyTrash) {
            Button("Empty Recently Deleted", role: .destructive) { model.emptyRecentlyDeleted() }
        } message: { Text("Workbench cannot recover these screenshots, recordings or transcripts afterward.") }
    }

    private var activeImages: [CaptureImagePreviewItem] { model.activeSections.enumerated().map { preview($0.element, number: $0.offset + 1) } }
    private var deletedImages: [CaptureImagePreviewItem] { model.deletedSections.map { preview($0, number: nil) } }
    private func preview(_ section: ReadbackSection, number: Int?) -> CaptureImagePreviewItem { .section(section, number: number, session: model.sessionURL) }
    /// The first words of a narration or note, for a row's second line.
    private func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
    private func statusSymbol(_ status: ReadbackSectionStatus) -> String {
        switch status {
        case .needsNarration: "mic.badge.plus"
        case .recording: "mic.fill"
        case .queued: "clock"
        case .transcribing: "waveform"
        case .ready: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}

/// A section's screenshot, decoded away from the main thread at the size it is shown, as
/// SnapThumbnail does: a full-size screenshot never decodes in a view's body.
struct ReadbackThumbnail: View {
    let root: URL?
    let relative: String
    let revision: Date
    var maxPixelSize: Int = 1024
    private struct Key: Equatable { var path: String?; var relative: String; var revision: Date; var size: Int }
    private enum Load { case loading, loaded(NSImage), missing }
    @State private var load = Load.loading
    var body: some View {
        Group {
            switch load {
            case .loaded(let image): Image(nsImage: image).resizable().scaledToFit()
            case .missing: Image(systemName: "photo.badge.exclamationmark").font(.title).foregroundStyle(.secondary)
            case .loading: Color.clear
            }
        }.accessibilityLabel("Snap & Talk screenshot")
            .task(id: Key(path: root?.path, relative: relative, revision: revision, size: maxPixelSize)) {
                guard let root, let url = try? ReadbackStore.safeURL(root: root, relative: relative) else { load = .missing; return }
                let size = maxPixelSize
                let image = await Task.detached(priority: .utility) { () -> NSImage? in
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: size, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
                    return NSImage(cgImage: cgImage, size: .zero)
                }.value
                guard !Task.isCancelled else { return }
                load = image.map(Load.loaded) ?? .missing
            }
    }
}

/// The live microphone level beside Recording narration, as the toolbar's trace shows it.
struct NarrationLevel: View {
    let level: Double
    var body: some View {
        Capsule().fill(Color.primary.opacity(0.1)).frame(width: 40, height: 4)
            .overlay(alignment: .leading) { Capsule().fill(Color.red).frame(width: 40 * max(0.05, min(1, level)), height: 4) }
            .animation(.linear(duration: 0.1), value: level)
            .accessibilityHidden(true)
    }
}
