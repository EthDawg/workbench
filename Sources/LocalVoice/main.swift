import AppKit
import SwiftUI
import Carbon
import AVFoundation
import Combine
import StageKit
import ToolbarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var window: NSWindow!
    var capturePanel: CapturePanelController!
    var model: AppModel!
    var statusItem: NSStatusItem!
    let hotkeys = VoiceHotkeys()
    var popover: NSPopover!
    var recorderMonitor: Any?
    /// The field the menu-bar panel was opened over, for actions started from that visit only.
    var menuTarget = PanelDestination<TextDelivery.Target>()
    var stage: StageKitController!
    var keyboard: KeyboardCoachModel!
    /// The panel's inline shortcut editor, ended on every open and close (#153).
    var panelEditor: PanelShortcutEditor!
    /// Closes the panel on a click in another app or when Workbench gives up focus.
    let panelLeave = PanelLeaveWatch()
    var presenterPanel: PresenterPanelController!
    var readback: ReadbackModel!
    var snap: SnapModel!
    var snapCapture: SnapCaptureHost!
    var toolbarModeFollower: ToolbarModeFollower?
    var shortcutsSuspended = false
    var navigationObserver: NSObjectProtocol?
    var receiptObservations = Set<AnyCancellable>()
    var readSelectionService: ReadSelectionService!
    private var receiptStatus: String?
    private var registeredVoiceShortcutConflicts: [String: String] = [:]
    private var terminating = false
    private var terminationPending = false
    private var meetingOffer: MeetingOfferPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let editions = ["com.ethdawg.workbench", "com.ethdawg.workbench.preview", "com.ethdawg.localvoice", "com.ethdawg.localvoice.preview", "local.ethan.StageMark", "local.ethan.StageMark.preview"]
        if let other = NSWorkspace.shared.runningApplications.first(where: { editions.contains($0.bundleIdentifier ?? "") && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            let alert = NSAlert()
            alert.messageText = "Another Workbench is already running"
            alert.informativeText = "\(other.localizedName ?? "Workbench") owns the tools and shortcuts. Quit that copy before opening \(Workbench.displayName). Your saved work stays in place."
            alert.addButton(withTitle: "Open running app")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = other.bundleURL {
                    let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
                    NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                } else { other.activate(options: [.activateAllWindows]) }
            }
            NSApp.terminate(nil); return
        }
        Workbench.preparePreviewData(component: "LocalVoice", files: ["state.json", "demo-library.json"])
        _ = WorkbenchSettings.shared
        // Read chosen Stage keys before either catalogue's new defaults can claim them.
        let preferences = VoicePreferences.load(reserving: StageShortcutSettings.migrationReservations())
        model = AppModel(preferences: preferences)
        readback = ReadbackModel(engine: model.engine)
        snap = SnapModel()
        readback.onSaveCapturedSnap = { [weak snap] bytes, name in
            guard let snap else { throw VoiceError.message("History is unavailable.") }
            return try snap.saveNarratedCapture(bytes, displayName: name)
        }
        model.resolveAdditionalHandoffItems = { [weak snap] references in
            guard let snap, references.allSatisfy({ $0.kind == .snap }) else {
                throw VoiceError.message("A selected item cannot be found. Review the selection.")
            }
            return try snap.handoffSnapshots(ids: Set(references.map(\.id))).map(\.reviewedHandoffSource)
        }
        snap.mayBeginCapture = { [weak self] in
            guard let self, !self.terminating else { return "Workbench is closing." }
            return self.readback.isCapturing || self.shortcutsSuspended || self.stage?.isTakingScreenshot == true
                ? "Finish the current screen capture or shortcut edit first." : nil
        }
        // One completion path for every Snap door: the editor opens on the Snap
        // page, a problem shows there, and a cancelled selector puts things back.
        snapCapture = SnapCaptureHost(desktop: AppKitSnapCaptureDesktop(window: { [weak self] in self?.window },
                                                                      openSnapPage: { [weak self] in self?.navigate("snap") }))
        snapCapture.attach(to: snap) { [weak self] in
            self?.closeControls(); self?.capturePanel?.window?.orderOut(nil)
        }
        CaptureImagePreview.shared.snapOwner = snap
        model.library.showImages = { images, selected in CaptureImagePreview.shared.showLibrary(images, selected: selected) }
        CaptureImagePreview.shared.attach(to: snap, parent: { [weak self] in self?.window }) { [weak self] in self?.updateRecordingUI() }
        model.handoffJobs.onStateChange = { [weak self] in self?.updateRecordingUI() }
        model.handoffJobs.currentReviewDigest = { [weak snap] key in snap?.store.organizationDigest(key: key) }
        model.handoffJobs.onOpenReview = { [weak snap] key in
            guard let snap, let current = try? snap.store.readOrganization(key: key) else { return }
            NSWorkspace.shared.open(current.url)
        }
        model.handoffJobs.onPublishReview = { [weak snap, weak model] job, snapshot, text, replace in
            guard let snap, let model else {
                throw VoiceError.message("The Snap review owner is unavailable. The task result is kept.")
            }
            return try HandoffReviewPublication.publish(job: job, snapshot: snapshot, result: text, store: snap.store,
                root: model.handoffJobs.folder(job), replacingChanges: replace)
        }
        model.meetings.saveTranscript = { [weak model] capture, purpose in
            guard let model else { throw VoiceError.message("The transcript library is unavailable.") }
            try model.retainMeetingTranscript(capture, purpose: purpose)
        }
        model.meetings.mayStart = { [weak self] in
            guard let self, !self.terminating else { return "Workbench is closing." }
            guard self.model.ready else { return "Prepare your speech engine in Settings › Models first." }
            return self.model.phase == .idle && !self.model.rendering && !self.readback.blocksDictation && !self.shortcutsSuspended
                ? nil : "Finish Dictate, reading or Snap & Talk before starting a meeting."
        }
        model.meetings.mayPlayRecording = { [weak self] in
            guard let self, !self.terminating else { return false }
            return self.model.phase == .idle && !self.model.rendering && !self.model.playing
                && !self.model.meetings.isBusy && !self.readback.blocksDictation
        }
        model.meetings.onStateChange = { [weak self] in self?.updateRecordingUI() }
        PackLibraryModel.shared.onSkillsChanged = { [weak self] skills in self?.readback.setPackSkills(skills) }
        PackLibraryModel.shared.start()
        stage = StageKitController(onOpenControls: { [weak self] in self?.navigate("annotate") }, onOpenScenes: { [weak self] in self?.navigate("present") }, reserving: preferences.enabledCombinations)
        stage.useSharedActivityControls()
        stage.onOpenPersonas = { [weak self] in self?.navigate("personas") }
        stage.onViewImages = { images, selected in
            let collection = images.map { CaptureImagePreviewItem(title: $0.title, detail: $0.detail, source: .generated($0.id), render: $0.png) }
            if let index = images.firstIndex(where: { $0.id == selected }) {
                CaptureImagePreview.shared.show(collection[index], collection: collection)
            }
        }
        stage.mayBeginInteraction = { [weak self] in
            guard let self else { return false }
            return self.model.phase == .idle && !self.model.rendering && !self.shortcutsSuspended && !self.readback.isRecording && !self.readback.isCapturing
        }
        stage.mayBeginDrawing = { [weak self] in
            guard let self else { return false }
            return WorkbenchDrawingAdmission.allows(phase: self.model.phase, suspended: self.shortcutsSuspended,
                capturingScreen: self.readback.isCapturing || self.snap.isCapturing, terminating: self.terminating)
        }
        model.shouldDeferDelivery = { [weak self] in self?.stage.isDrawing == true }
        stage.onDrawingChanged = { [weak self] drawing in
            guard let self, !self.terminating else { return }
            if !drawing {
                if self.shortcutsSuspended || self.readback.isCapturing { self.model.copyWaitingDelivery() }
                else { self.model.resumeWaitingDelivery() }
            }
            self.updateRecordingUI()
        }
        stage.onEditShortcuts = { [weak self] in self?.navigate("shortcuts") }
        stage.onBeginActivity = { [weak self] in self?.beginStageActivity() }
        stage.validateExternalShortcut = { [weak self] code, modifiers in
            guard let self else { return nil }
            for entry in self.voiceShortcutEntries() {
                let saved = entry.shortcut
                if saved.enabled && saved.keyCode == code && saved.modifiers == modifiers {
                    return "Also assigned to \(entry.title). Both shortcuts are paused; change or turn off one in Settings › Keyboard."
                }
            }
            return nil
        }
        stage.start()
        model.microphoneStartFailure = { [weak self] target in
            guard let self else { return "Workbench is unavailable." }
            if self.readback.blocksDictation { return "Finish the current Snap & Talk capture, narration and transcription queue before starting ordinary dictation." }
            if self.model.meetings.isBusy { return "Finish the meeting recording or transcription before starting Dictate." }
            return CaptureInputPolicy.canStart(isPresenting: self.stage.isPresenting, hasExternalMacTarget: target != nil, delivery: self.model.preferences.delivery)
                ? nil : "Choose Copy to clipboard to capture a thought, or focus a Mac text field. To enter text on your phone, use its keyboard or Dictation button."
        }
        readback.mayBeginCapture = { [weak self] in
            guard let self else { return "Workbench is unavailable." }
            if self.shortcutsSuspended { return "Finish changing the shortcut before starting Snap & Talk." }
            if self.snap.isCapturing { return "Finish the current Snap before starting Snap & Talk." }
            return self.model.phase == .idle && !self.model.rendering && !self.model.meetings.isBusy
                ? nil : "Finish the current dictation, reading or meeting before starting Snap & Talk narration."
        }
        readback.onEditShortcut = { [weak self] in self?.navigate("shortcuts") }
        readback.onNarrationNotHeard = { [weak self] in self?.model.showNarrationCue() }
        keyboard = KeyboardCoachModel(entries: shortcutEntries(), update: { [weak self] id, shortcut in guard let self else { return "Workbench is unavailable." }; return self.saveShortcut(id, shortcut) }, suspend: { [weak self] suspended in
            guard let self else { return }
            self.shortcutsSuspended = suspended
            if suspended { self.model.promptInsertion.cancel(); self.hotkeys.unregister(); self.stage.escape(); self.stage.setShortcutsSuspended(true) }
            else { self.stage.setShortcutsSuspended(false); self.registerShortcuts(); self.keyboard.replaceEntries(self.shortcutEntries()) }
        })
        panelEditor = PanelShortcutEditor(keyboard: keyboard)
        let homeWindow = WorkbenchHomeWindow(contentViewController: NSHostingController(rootView: WorkbenchHome(model: model, stage: stage, keyboard: keyboard, readback: readback, snap: snap)))
        homeWindow.onHide = { [weak self] in
            self?.model.library.closePreview()
            self?.model.meetings.recordingPlayback.pause()
        }
        window = homeWindow
        window.title = Workbench.displayName
        window.setContentSize(NSSize(width: 1180, height: 800))
        window.minSize = NSSize(width: 1050, height: 730)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false; window.center()
        // The normal launch below opens the window after its controls exist.
        if PackLibraryModel.shared.pendingSource != nil { model.page = "packs" }
        capturePanel = CapturePanelController(model: model, readback: readback, stage: stage, snapModel: snap,
            dictate: { [weak self] in self?.toolbarDictation() },
            snap: { [weak self] in self?.toolbarSnap() },
            snapCapture: { [weak self] in self?.toolbarSnapCapture() },
            draw: { [weak self] in
                guard let self else { return }
                if self.stage.isDrawing { self.stage.finishDrawing() }
                else { self.model.toolbarMode = .draw; self.stage.draw() }
            }, present: { [weak self] in
                guard let self else { return }
                if self.stage.isPresenting { self.stage.endDeviceScene() }
                else { self.model.toolbarMode = .present; self.stage.presentSelectedScene() }
            }, capture: { [weak self] tool, kind in
                guard let self, let mode = SnapCapture.Mode(rawValue: kind.rawValue) else { return }
                if tool == .snap { self.toolbarSnapCapture(mode) }
                else if tool == .snapAndTalk { self.toolbarSnap(mode) }
            })
        capturePanel.independentScreenCapture = { [weak snap] in snap?.isCapturing == true }
        // The toolbar's mode follows every door, not only the closures above.
        toolbarModeFollower = ToolbarModeFollower(model: model, readback: readback, stage: stage, meetings: model.meetings, snap: snap) { [weak self] mode in
            guard let self, self.model.toolbarMode != mode else { return }
            self.model.toolbarMode = mode
        }
        stage.onFocusActivityControls = { [weak self] tool in
            guard let self else { return }
            self.model.toolbarMode = tool == "persona" ? .persona : .present
            self.capturePanel.focusToolbar()
        }
        model.promptInsertion.mayInsert = { [weak self] in
            guard let self else { return false }
            return self.model.phase == .idle && !self.stage.isDrawing && !self.shortcutsSuspended && !self.readback.isRecording && !self.readback.isCapturing
        }
        presenterPanel = PresenterPanelController(model: model.presenter, setup: { [weak self] in self?.navigate("library") })
        model.onShowPresenter = { [weak self] in self?.showPresenter() }
        model.presenter.mayActivate = { [weak self] in
            guard let self else { return false }
            return self.model.phase == .idle && !self.shortcutsSuspended && !self.readback.isRecording && !self.readback.isCapturing
        }
        model.library.switchBrowser = { [weak self] id in
            self?.model.presenter.activate(id) { [weak self] reply in
                if reply.ok != true { self?.showPresenter() }
            }
        }
        model.presenter.onSwitch = { [weak self] in
            self?.stage.escape(); self?.presenterPanel.hide(); self?.closeControls(); self?.window.orderOut(nil)
        }
        popover = NSPopover(); popover.behavior = .transient; popover.animates = false; popover.delegate = self
        // These are the panel's doors: each starts its capability. Ending,
        // stopping and hiding go through the shared operation switch, so a row
        // does exactly what its label says. Timer keeps both directions here
        // because it is not a toolbar mode.
        let quickController = NSHostingController(rootView: WorkbenchQuickPanel(model: model, stage: stage, readback: readback, keyboard: keyboard, editor: panelEditor, receipts: model.clipboardReceipt, snapModel: snap, open: { [weak self] page in self?.navigate(page) }, draw: { [weak self] in
            self?.resumeTarget { [weak self] _ in self?.stage.draw() }
        }, snap: { [weak self] in self?.toolbarSnap() }, snapCapture: { [weak self] mode in self?.toolbarSnapCapture(mode) }, present: { [weak self] in
            self?.closeControls(); self?.stage.presentSelectedScene()
        }, timer: { [weak self] in
            guard let self else { return }
            self.closeControls()
            if self.stage.hasTimerSession { self.stage.stopTimer() } else { self.stage.startTimer() }
        }, personas: { [weak self] in
            self?.closeControls(); self?.stage.togglePersona()
        }))
        quickController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = quickController
        model.onPhaseChange = { [weak self] in
            guard let self else { return }
            if self.model.phase != .idle { self.presenterPanel?.hide(); self.keyboard?.stopInteraction() }
            self.updateRecordingUI()
        }
        model.onShortcutsChanged = { [weak self] in self?.registerShortcuts() }
        stage.onShortcutsChanged = { [weak self] in
            guard let self else { return }
            let conflicts = ShortcutConflict.duplicateFailures(in: self.shortcutEntries()).filter { $0.key.hasPrefix("voice.") }
            // An unrelated Stage edit must not discard the key-up of held dictation.
            if conflicts != self.registeredVoiceShortcutConflicts { self.registerShortcuts() }
        }
        model.onEditShortcut = { [weak self] id in self?.navigate("shortcuts") }
        model.onShowEditor = { [weak self] page in self?.model.page = page; self?.showWindow() }
        model.onShowAnnotationMenu = { [weak self] in self?.showAnnotationMenu() }
        model.onMenuRecording = { [weak self] in self?.menuRecording() }
        model.onCloseMenu = { [weak self] in self?.closeControls() }
        model.onCancelShortcut = { [weak self] in self?.finishEditing() }
        model.onResetShortcuts = { [weak self] in
            guard let self else { return }
            self.finishEditing()
            var preferences = self.model.preferences
            for id in VoicePreferences.shortcutIDs { preferences.setShortcut(VoicePreferences().shortcut(id), for: id) }
            self.model.preferences = preferences
            self.stage.resetShortcuts()
        }
        model.onResetPanel = { [weak self] in self?.capturePanel.position(reset: true) }
        hotkeys.onKey = { [weak self] id, down, time in
            guard let self else { return }
            if id == 1 { self.model.shortcutChanged(down: down, at: time) }
            else if down, id == 3 { self.model.showLibrary() }
            else if down, id == 4 { self.showPresenter() }
            else if down, id == 6 {
                if self.model.rendering { self.model.cancelReading() }
                else if self.model.playing || self.model.paused { self.model.listen() }
                else { self.navigate("speak") }
            }
            else if down, id == 7 {
                if self.stage.isPresenting { self.stage.endDeviceScene() }
                else { self.stage.presentSelectedScene() }
            }
            else if down, id == 8 { self.toolbarSnapCapture() }
            else if down, id == 5 {
                self.readback.refreshPermissionState()
                if self.readback.sessionURL == nil {
                    self.readback.notice = "Create or open a Snap & Talk session before using the capture shortcut."
                    self.navigate("readback")
                } else if self.readback.currentSessionProblem != nil && !self.readback.isRecording {
                    self.navigate("readback")
                } else if !self.readback.permissionsReady {
                    self.readback.notice = "Snap & Talk needs Screen Recording and Microphone access first."
                    self.navigate("readback")
                } else { Task { await self.readback.toggleCapture() } }
            }
            else if down { self.toggleControls() }
        }
        readback.onStateChange = { [weak self] in
            guard let self else { return }
            self.updateRecordingUI()
        }
        readback.onHideForEditorCapture = { [weak self] in self?.window.orderOut(nil) }
        readback.onRestoreAfterEditorCapture = { [weak self] in self?.showWindow() }
        navigationObserver = NotificationCenter.default.addObserver(forName: .workbenchNavigate, object: nil, queue: .main) { [weak self] notification in
            guard let page = notification.object as? String else { return }
            Task { @MainActor in self?.navigate(page) }
        }
        WorkbenchUpdates.shared.activity = { [weak self] in
            guard let self else { return WorkbenchUpdateActivity(interaction: true) }
            return WorkbenchUpdateActivity(voice: self.model.phase != .idle || self.model.preparing,
                reading: self.model.rendering || self.model.playing || self.model.paused || self.model.promptInsertion.running,
                capture: self.readback.blocksDictation || self.snap.isBusy || self.stage.isTakingScreenshot || self.model.meetings.isBusy || self.model.handoffJobs.isBusy,
                presentation: self.stage.isPresenting || self.stage.hasActivePersona, drawing: self.stage.isDrawing,
                timer: self.stage.hasActiveTimer,
                interaction: self.shortcutsSuspended || NSApp.modalWindow != nil || NSApp.windows.contains(where: { $0.attachedSheet != nil }))
        }
        WorkbenchUpdates.shared.start()
        setupMenus()
        readSelectionService = ReadSelectionService { [weak self] selection in
            self?.model.receiveReadingSelection(selection)
        }
        NSApp.servicesProvider = readSelectionService
        registerShortcuts(); showWindow()
        meetingOffer = MeetingOfferPanelController(model: model.meetings) { [weak self] in self?.navigate("meeting") }
        model.clipboardReceipt.$receipt.receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let receipt = self.model.clipboardReceipt.receipt
                if receipt != nil { self.receiptStatus = self.model.status }
                else {
                    if self.model.phase == .idle, let previous = self.receiptStatus, self.model.status == previous {
                        self.model.status = ""
                    }
                    self.receiptStatus = nil
                }
                self.updateRecordingUI()
            }
            .store(in: &receiptObservations)
        stage.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateRecordingUI()
        }.store(in: &receiptObservations)
        model.$rendering.combineLatest(model.$playing, model.$paused).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateRecordingUI() }.store(in: &receiptObservations)
        model.promptInsertion.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateRecordingUI()
        }.store(in: &receiptObservations)
    }
    func registerShortcuts() {
        guard model.editingShortcut == nil, !shortcutsSuspended else { return }
        let conflicts = ShortcutConflict.duplicateFailures(in: shortcutEntries()).filter { $0.key.hasPrefix("voice.") }
        hotkeys.register(ShortcutConflict.voiceRegistrationPreferences(model.preferences, failures: conflicts))
        registeredVoiceShortcutConflicts = conflicts
        model.shortcutFailures = hotkeys.failures
        for id in VoicePreferences.shortcutIDs { if let message = conflicts["voice.\(id)"] { model.shortcutFailures[id] = message } }
        stage.refreshShortcutRegistration()
        readback?.setShortcutFailure(model.shortcutFailures[5])
    }
    func editShortcut(_ id: UInt32) {
        guard model.phase == .idle else { return }
        finishEditing(); hotkeys.unregister(); model.editingShortcut = id
        NSApp.activate(ignoringOtherApps: true)
        if popover.isShown { popover.contentViewController?.view.window?.makeKey() }
        else { window.makeKey() }
        recorderMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard !event.isARepeat else { return nil }
            if event.keyCode == 53 { self.finishEditing(); return nil }
            var shortcut = VoiceShortcut(event: event)
            if event.keyCode == 51 && shortcut.modifiers == 0 { shortcut.enabled = false }
            else if shortcut.modifiers & UInt32(controlKey | optionKey) == 0 {
                self.model.shortcutRecordingMessage = "Include Control or Option."; return nil
            }
            if shortcut.enabled && VoicePreferences.shortcutIDs.contains(where: { $0 != id && self.model.preferences.shortcut($0) == shortcut }) { self.model.shortcutRecordingMessage = "That shortcut is already assigned in Workbench."; return nil }
            var candidate = self.model.preferences
            candidate.setShortcut(shortcut, for: id)
            self.hotkeys.register(candidate)
            let failure = self.hotkeys.failures[id]
            self.hotkeys.unregister()
            if let failure { self.model.shortcutRecordingMessage = failure; return nil }
            self.model.preferences = candidate
            self.model.status = "Shortcut saved: \(shortcut.label)."
            self.finishEditing(); return nil
        }
    }
    func finishEditing() {
        if let recorderMonitor { NSEvent.removeMonitor(recorderMonitor); self.recorderMonitor = nil }
        // Closing ordinary controls must not clear the key-down state of a held dictation shortcut.
        guard model != nil, model.editingShortcut != nil else { return }
        model.editingShortcut = nil; model.shortcutRecordingMessage = nil; registerShortcuts()
    }
    private func setupMenus() {
        let menus = makeMainMenu()
        NSApp.mainMenu = menus.main; NSApp.servicesMenu = menus.services; NSApp.windowsMenu = menus.window; NSApp.helpMenu = menus.help
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = NSStatusItem.AutosaveName("Workbench.MenuBar")
        // AppKit restores autosaved visibility, including a previously removed
        // item. Workbench's always-running utility needs an entry point at launch.
        statusItem.isVisible = true
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp]); updateRecordingUI()
    }
    /// The menu bar, built without installing it, so the surface gallery lists the same items.
    /// Window keeps window and surface controls, then the few pages worth a menu door; every
    /// page item takes its name and route from the page record the sidebar uses (#134).
    func makeMainMenu() -> (main: NSMenu, services: NSMenu, window: NSMenu, help: NSMenu) {
        let main = NSMenu(); let application = NSMenuItem(); let appMenu = NSMenu(title: "Workbench")
        appMenu.addItem(withTitle: "About Workbench", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(showUpdates), keyEquivalent: "")
        appMenu.addItem(withTitle: "Copy build details", action: #selector(copyBuildDetails), keyEquivalent: "")
        appMenu.addItem(pageItem("settings", more: true, key: ","))
        appMenu.addItem(pageItem("shortcuts", more: true))
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services; appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Workbench", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Workbench", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = appMenu; main.addItem(application)
        let edit = NSMenuItem(); edit.title = "Edit"; let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] { editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key) }
        edit.submenu = editMenu; main.addItem(edit)
        let draw = NSMenuItem(title: "Draw", action: nil, keyEquivalent: "")
        draw.submenu = stage.makeAnnotationMenu(); main.addItem(draw)
        let windows = NSMenuItem(); windows.title = "Window"; let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: "Open Workbench", action: #selector(showWindow), keyEquivalent: "0")
        // Show or Hide by the saved preference, through the same switch as the panel and Settings (#134).
        menu.addItem(withTitle: Self.floatingToolbarTitle(visible: model.floatingToolbarVisible), action: #selector(toggleFloatingToolbar), keyEquivalent: "")
        menu.addItem(withTitle: "Focus floating toolbar", action: #selector(focusFloatingToolbar), keyEquivalent: "")
        menu.addItem(withTitle: "Restore menu-bar icon", action: #selector(restoreMenuBarIcon), keyEquivalent: "")
        menu.addItem(withTitle: "Switch to…", action: #selector(showPresenter), keyEquivalent: "")
        menu.addItem(.separator())
        // Every sidebar page, in the sidebar's order and by its name, so the Window menu's doors never
        // differ from the window's own list (#134).
        menu.addItem(pageItem("dictate")); menu.addItem(pageItem("meeting", more: true)); menu.addItem(pageItem("speak"))
        menu.addItem(pageItem("snap")); menu.addItem(pageItem("readback")); menu.addItem(pageItem("annotate"))
        menu.addItem(pageItem("present")); menu.addItem(pageItem("personas"))
        menu.addItem(.separator())
        menu.addItem(pageItem("history")); menu.addItem(pageItem("library", key: "l"))
        windows.submenu = menu; main.addItem(windows)
        let help = NSMenuItem(); help.title = "Help"
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Workbench Guide", action: #selector(showGuide), keyEquivalent: "")
        help.submenu = helpMenu; main.addItem(help)
        return (main, services, menu, helpMenu)
    }
    /// A menu item that opens a page: `WorkbenchHome.name(of:)` names it, so it can't differ from
    /// the sidebar, and `more` adds the native … for a page that asks for more before anything
    /// happens. scripts/check-surfaces.py reads these calls.
    private func pageItem(_ route: String, more: Bool = false, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: WorkbenchHome.name(of: route) + (more ? "…" : ""), action: #selector(openPage(_:)), keyEquivalent: key)
        item.representedObject = route
        return item
    }
    /// Opens the page a menu item names. History starts on All and Library focuses its search,
    /// as their other doors do.
    @objc func openPage(_ sender: NSMenuItem) {
        guard let route = sender.representedObject as? String else { return }
        switch route {
        case "history": keyboard?.stopInteraction(); model.openHistory(); showWindow()
        case "library": keyboard?.stopInteraction(); model.showLibrary()
        default: navigate(route)
        }
    }
    @objc func statusClicked(_ sender: Any?) {
        // Left click, right click and the shortcut open the same panel.
        toggleControls()
    }

    @objc func toggleControls() { if popover.isShown { closeControls() } else { showControls() } }
    @objc func showAnnotationMenu() {
        closeControls()
        guard let button = statusItem.button, button.window?.isVisible == true else {
            model.page = "annotate"; showWindow(); return
        }
        statusItem.menu = stage.makeAnnotationMenu()
        button.performClick(nil)
        statusItem.menu = nil
    }
    @objc func showFloatingToolbar() {
        model.floatingToolbarVisible = true
        capturePanel.update(model: model)
    }
    @objc func toggleFloatingToolbar() { model.floatingToolbarVisible.toggle() }
    /// The Window menu's toolbar item names what choosing it does now.
    static func floatingToolbarTitle(visible: Bool) -> String { visible ? "Hide floating toolbar" : "Show floating toolbar" }
    @objc func focusFloatingToolbar() { capturePanel.focusToolbar() }
    @objc func restoreMenuBarIcon() {
        statusItem.isVisible = true
        updateRecordingUI()
        // A crowded/notched menu bar can conceal a visible status item. The
        // toolbar is a dependable recovery surface without changing other apps.
        showFloatingToolbar()
    }
    @objc func showGuide() { NSWorkspace.shared.open(URL(string: "https://workbench-mac.vercel.app/guide/")!) }
    func showControls() {
        guard let button = statusItem.button, button.window?.isVisible == true else {
            showFloatingToolbar(); return
        }
        menuTarget.opened(capturing: TextDelivery.capture())
        // Each visit starts in the normal state, whatever the last one left.
        model.refreshPermissions(); panelEditor.end(); keyboard.replaceEntries(shortcutEntries()); NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        panelLeave.watch { [weak self] in self?.closeControls() }
    }
    /// Starting independent Stage work hides preparation surfaces. It does not
    /// dismiss another capability's pending result or its recovery controls.
    func beginStageActivity() {
        closeControls()
        presenterPanel?.hide()
        model.previewingPanel = false
        window?.orderOut(nil)
    }
    func closeControls() { popover.performClose(nil); finishEditing() }
    /// Every way the panel closes ends here: the editor and its recorder end
    /// and global actions resume.
    func popoverDidClose(_ notification: Notification) { menuTarget.closed(); panelLeave.stop(); panelEditor?.end(); finishEditing(); keyboard?.stopInteraction() }
    func resumeTarget(_ action: @escaping (TextDelivery.Target?) -> Void) {
        let target = menuTarget.current
        closeControls()
        // Restore only the app from which controls were opened. Delivery checks the
        // exact focused element again after processing; it never presses Return.
        target?.app.activate(options: [])
        Task { try? await Task.sleep(nanoseconds: 160_000_000); action(target) }
    }
    func menuRecording() {
        if model.phase == .requesting { closeControls(); model.cancelRecording(); return }
        if model.phase == .recording { closeControls(); model.stopRecording(); return }
        model.toolbarMode = .dictate
        resumeTarget { [weak self] target in self?.model.toggleRecording(target: target) }
    }
    func toolbarDictation() {
        // The toolbar is nonactivating. Capture the current field at the click,
        // never reuse an old popover target for a later toolbar operation.
        let target = capturePanel.targetForDictation()
        model.toolbarMode = .dictate
        model.toggleRecording(target: target)
    }
    /// Snap mode's start: one standalone capture into Snap. Source choices are per capture;
    /// the existing shortcut and generic starts retain their region default.
    func toolbarSnapCapture(_ mode: SnapCapture.Mode = .region) {
        // From the panel, a cancelled capture returns to the app it was opened
        // over. Read before closing: closing the panel expires its field.
        let origin = menuTarget.current?.app.processIdentifier
        model.toolbarMode = .snap
        closeControls()
        Task { await snap.capture(mode, origin: origin) }
    }
    func toolbarSnap(_ mode: SnapCapture.Mode = .screen) {
        if readback.isRecording { readback.stopNarration(); return }
        model.toolbarMode = .snapAndTalk
        readback.refreshPermissionState()
        readback.refreshSessionAvailability()
        // A missing session folder or a refused start is explained on the page, as the
        // capture key does; hiding Workbench first made the press look like nothing happened.
        guard readback.sessionURL != nil, readback.permissionsReady, readback.currentSessionProblem == nil else {
            navigate("readback"); return
        }
        // Refused by other work: say so where Snap & Talk's notices show, without leaving
        // what the person is doing (navigating would end a shortcut being changed).
        if let reason = readback.mayBeginCapture?() { readback.notice = reason; return }
        closeControls(); window.orderOut(nil)
        Task { await readback.captureNewSection(fromEditor: false, mode: mode) }
    }
    func updateRecordingUI() {
        model.meetings.updateRecordingPlaybackAdmission()
        let receipt = model.clipboardReceipt.receipt
        let state: String
        switch model.phase {
        case .recording: state = "Recording"
        case .requesting: state = "Starting microphone"
        case .transcribing, .cleaning: state = "Processing speech"
        case .delivering: state = model.waitingForDrawing ? "Text ready · finish drawing or copy" : "Delivering text"
        case .cancelling: state = "Cancelling"
        case .idle:
            if model.meetings.isRecording { state = "Recording meeting" }
            else if model.meetings.isStarting { state = "Starting meeting capture" }
            else if model.meetings.isProcessing { state = "Transcribing meeting" }
            else if readback?.isRecording == true { state = "Recording Snap & Talk narration" }
            else if (readback?.pendingTranscriptionCount ?? 0) > 0 { state = "Processing Snap & Talk narration" }
            else if stage.isDrawing { state = stage.isPresenting ? "Presenting · Drawing" : "Drawing" }
            else if stage.isPresenting { state = "Presenting" }
            else if stage.hasActivePersona { state = "Persona Overlays" }
            else if model.promptInsertion.running { state = "Inserting Prompt" }
            else if model.playing || model.paused { state = model.paused ? "Reading Paused" : "Reading" }
            else if model.rendering { state = "Preparing Reading" }
            else {
                state = receipt?.isClipboardCurrent == true ? (receipt?.title ?? "Transcript copied") : "Quick controls"
            }
        }
        let icon = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Workbench · " + state)
            ?? NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Workbench")
        // Keep the stack recognisable. A small dot marks activity without
        // turning the app into a clipboard or microphone icon.
        let busy = model.phase != .idle || model.meetings.isBusy || model.handoffJobs.isBusy || model.rendering || model.playing || model.paused || readback.isRecording || readback.hasPendingTranscriptions || stage.isDrawing || stage.isPresenting || stage.hasActivePersona || model.promptInsertion.running
        let statusIcon = busy ? NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            icon?.draw(in: NSRect(x: 0, y: 1, width: 16, height: 16))
            NSColor.labelColor.setFill(); NSBezierPath(ovalIn: NSRect(x: 16, y: 0, width: 4, height: 4)).fill()
            return true
        } : icon
        statusIcon?.isTemplate = true
        statusItem?.button?.image = statusIcon
        statusItem?.button?.setAccessibilityLabel("Workbench · " + state)
        statusItem?.button?.toolTip = WorkbenchUpdates.shared.build.label + " · " + state + " · " + model.preferences.controlsShortcut.label
        capturePanel?.update(model: model)
    }
    @objc func showUpdates() { showSettings(); WorkbenchUpdates.shared.checkForUpdates() }
    @objc func copyBuildDetails() { WorkbenchUpdates.shared.copyDetails() }
    @objc func showSettings() { model.page = "settings"; showWindow() }
    @objc func showPresenter() {
        guard model.phase == .idle, !shortcutsSuspended else { return }
        stage.escape(); closeControls(); presenterPanel.show()
    }
    @objc func showWindow() { closeControls(); if window.isMiniaturized { window.deminiaturize(nil) }; window.makeKeyAndOrderFront(nil); statusItem?.isVisible = true; NSApp.activate(ignoringOtherApps: true) }
    @objc func showAbout() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: Workbench.displayName, .applicationVersion: WorkbenchUpdates.shared.build.label, .credits: NSAttributedString(string: "\(WorkbenchUpdates.shared.build.details)\n\nEveryday tools for speaking, explaining and presenting.\nSpeech powered by Parakeet, FluidAudio, macOS voices and your chosen providers.")]) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationDidBecomeActive(_ notification: Notification) {
        readback?.refreshPermissionState()
        PackLibraryModel.shared.checkAutomatically()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where PackLibraryModel.shared.acceptLink(url) {
            model?.page = "packs"
            if window != nil { showWindow() }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readback?.hasUnsavedNarration == true {
            readback.reviewUnsavedNarration(); model?.page = "readback"; showWindow()
            return .terminateCancel
        }
        guard WorkbenchUpdates.shared.canTerminate(saveSession: { model?.saveBeforeUpdate() == true }) else { return .terminateCancel }
        if terminationPending { return .terminateLater }
        guard CaptureImagePreview.shared.canTerminate() else { return .terminateCancel }
        guard let model, model.meetings.isBusy || model.handoffJobs.isBusy || model.hasActiveVoiceCapture else { return .terminateNow }
        terminationPending = true
        terminating = true
        Task {
            await model.meetings.prepareForShutdown()
            await model.prepareVoiceForShutdown()
            await model.handoffJobs.prepareForShutdown()
            _ = model.saveBeforeUpdate()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        NSApp.servicesProvider = nil
        presenterPanel?.hide(); model?.presenter.stop()
        capturePanel?.close()
        meetingOffer?.close()
        snap?.cancelCapture()
        model?.promptInsertion.cancel(); keyboard?.stopInteraction(); stage?.shutdown(); readback?.shutdown(); model?.cleanupModels.cancel(); model?.shutdown(); hotkeys.unregister()
        if let navigationObserver { NotificationCenter.default.removeObserver(navigationObserver) }
    }
    func navigate(_ page: String) {
        keyboard?.stopInteraction(); keyboard?.replaceEntries(shortcutEntries()); model.page = page; showWindow()
    }
    /// The voice catalogue's titles, one per id in `VoicePreferences.shortcutIDs`.
    static let voiceShortcutCatalogue: [(UInt32, String)] = [(1, "Dictate"), (2, "Quick controls"), (3, "Library"), (4, "Switch to"), (5, "Snap & Talk"), (6, "Read"), (7, "Present"), (8, "Snap")]
    func voiceShortcutEntries() -> [ShortcutEntry] {
        Self.voiceShortcutCatalogue.map { id, title in
            ShortcutEntry(id: "voice.\(id)", title: title, shortcut: model.preferences.shortcut(id), error: model.shortcutFailures[id])
        }
    }
    func shortcutEntries() -> [ShortcutEntry] {
        let entries = voiceShortcutEntries() + stage.shortcutDescriptors.map { entry in
            ShortcutEntry(id: "stage." + entry.id, title: entry.label, shortcut: VoiceShortcut(keyCode: entry.keyCode, modifiers: entry.modifiers, enabled: entry.enabled), error: entry.error)
        }
        // Imported custom combinations are preserved, but their conflicts must be
        // just as visible as conflicts discovered while assigning new keys.
        let conflicts = ShortcutConflict.duplicateFailures(in: entries)
        return entries.map { entry in
            var result = entry
            result.error = conflicts[entry.id] ?? result.error ?? ShortcutConflict.message(for: entry.shortcut, replacing: entry.id, in: entries)
            return result
        }
    }
    func saveShortcut(_ id: String, _ shortcut: VoiceShortcut) -> String? {
        if shortcut.enabled, let duplicate = shortcutEntries().first(where: { $0.id != id && $0.shortcut.enabled && $0.shortcut.keyCode == shortcut.keyCode && $0.shortcut.modifiers == shortcut.modifiers }) {
            return "Already used by \(duplicate.title)."
        }
        if id.hasPrefix("voice."), let key = UInt32(id.dropFirst(6)) {
            model.preferences.setShortcut(shortcut, for: key); return nil
        }
        if id.hasPrefix("stage.") { return stage.updateShortcut(id: String(id.dropFirst(6)), keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, enabled: shortcut.enabled) }
        return "Unknown shortcut."
    }
}

func runCLI(_ args: [String]) async -> Int32 {
    do {
        // Only the modes that recognise speech create an engine: creating one
        // reads the saved model choice, which other checks never need.
        var recognition: RecognitionEngine?
        func engine() -> RecognitionEngine {
            if let recognition { return recognition }
            let created = RecognitionEngine(); recognition = created; return created
        }
        switch args.first {
        case "--check-presenter":
            try await PresenterChecks.run()
        case "--build-info":
            print(WorkbenchBuild().details)
        case "--check-shortcut-migration":
            try ShortcutMigrationChecks.run()
        case "--check-updates":
            try await WorkbenchUpdateChecks.run()
        case "--check-core":
            try await WorkbenchUpdateChecks.run()
            try await WorkbenchControlChecks.run()
            try CorrectionRuleChecks.run()
            try HomeJourneyChecks.run()
            try PanelDestinationChecks.run()
            try await MainActor.run { try WorkbenchPageChecks.run(); try HomeRecentWorkChecks.run() }
            try CoreChecks.run(); try CleanupChecks.run(); try DemoLibraryChecks.run(); try ReadbackChecks.run(); try await ReadbackChecks.runAdmissionChecks(); try ProviderChecks.run(); try CaptureHUDChecks.run(); try CaptureSettingsChecks.run(); try LocalRefinementChecks.run()
            try await AudioRendererCancellationChecks.run()
            try await NeuralVoiceChecks.run()
            try await MainActor.run { try ReadSelectionChecks.run(); try DemoLibraryChecks.runModelChecks(); try IntegrationChecks.run(); try KeyboardCoachChecks.run(); try ClipboardReceiptChecks.run(); try FeedbackChecks.run(); try ReadingChecks.run() }
        case "--check-feedback":
            // Brief feedback alone (#134 T5): no check here writes preferences outside its own temporary folder.
            try await MainActor.run { try ClipboardReceiptChecks.run(); try FeedbackChecks.run() }
        case "--check-floating-toolbar":
            try await WorkbenchControlChecks.run()
        case "--check-reading-cancellation":
            try await AudioRendererCancellationChecks.run()
        case "--check-reading":
            try await MainActor.run { try ReadingChecks.run() }
        case "--check-reading-render":
            try await ReadingChecks.runRender()
        case "--check-neural-voice":
            try await NeuralVoiceChecks.run()
        case "--check-neural-voice-download":
            guard args.count == 2 else { throw VoiceError.message("Usage: --check-neural-voice-download NEW_FOLDER") }
            try await NeuralVoiceChecks.runDownload(root: URL(fileURLWithPath: args[1]))
        case "--check-neural-voice-render":
            // --check-neural-voice-render [FOLDER holding Models/pocket-tts]
            try await NeuralVoiceChecks.runRender(root: args.count > 1 ? URL(fileURLWithPath: args[1]) : nil)
        case "--measure-reading-latency":
            // --measure-reading-latency VOICE_ID[,VOICE_ID] TEXT_FILE…
            guard args.count >= 3 else { throw VoiceError.message("Usage: --measure-reading-latency VOICE_ID[,VOICE_ID] TEXT_FILE…") }
            try await ReadingChecks.measureLatency(voices: args[1].split(separator: ",").map(String.init), files: args.dropFirst(2).map { URL(fileURLWithPath: $0) })
        case "--render-reading-fixture":
            guard args.count == 2 else { throw VoiceError.message("Usage: --render-reading-fixture NEW_OUTPUT_FOLDER") }
            try await MainActor.run {
                _ = NSApplication.shared
                try ReadingChecks.renderFixtures(to: URL(fileURLWithPath: args[1]))
            }
        case "--check-library":
            try DemoLibraryChecks.run()
            try await MainActor.run { try DemoLibraryChecks.runModelChecks() }
        case "--check-capture-preview":
            try await CaptureImagePreviewChecks.run()
        case "--check-image-workspace":
            try await ImageWorkspaceChecks.run(output: args.count > 1 ? URL(fileURLWithPath: args[1]) : nil)
        case "--check-quick-look-panel":
            let urls = args.dropFirst().map { URL(fileURLWithPath: $0).standardizedFileURL }
            try await MainActor.run { try DemoLibraryChecks.runQuickLookPanelChecks(urls) }
        case "--check-reading-service":
            try await MainActor.run { try ReadSelectionChecks.run() }
        case "--check-reading-service-native":
            try await MainActor.run {
                _ = NSApplication.shared
                NSApp.setActivationPolicy(.prohibited)
                NSApp.finishLaunching()
                try ReadSelectionChecks.runNativePasteboard()
            }
        case "--check-persona-voice-native":
            guard args.count >= 2 else { throw VoiceError.message("Usage: --check-persona-voice-native NEW_OUTPUT_FOLDER [--speak]") }
            await MainActor.run {
                _ = NSApplication.shared
                NSApp.setActivationPolicy(.accessory)
                NSApp.finishLaunching()
            }
            print(try await PersonaVoiceNativeCheck.run(output: URL(fileURLWithPath: args[1]), speak: args.dropFirst(2).contains("--speak")))
            print(WorkbenchBuild().details)
        case "--render-reading-service-fixture":
            guard args.count == 2 else { throw VoiceError.message("Usage: --render-reading-service-fixture OUTPUT.png") }
            try await MainActor.run {
                _ = NSApplication.shared
                try ReadSelectionChecks.renderReviewCard(to: URL(fileURLWithPath: args[1]))
            }
        case "--render-surfaces":
            guard args.count == 2 else { throw VoiceError.message("Usage: --render-surfaces OUTPUT_DIRECTORY") }
            try SurfaceGallery.run(output: URL(fileURLWithPath: args[1], isDirectory: true))
        case "--check-providers":
            try ProviderChecks.run(); try await ProviderChecks.runTransportChecks()
        case "--check-subscription-cli":
            try SubscriptionCLIChecks.run()
            try await SubscriptionCLIChecks.runAdapterChecks()
            try await SubscriptionCLIChecks.runProcessChecks()
            try await SubscriptionCLIChecks.runSandboxChecks()
        case "--check-meetings":
            try await MeetingChecks.run()
            try await LiveVoiceChecks.run()
            try await MainActor.run { try LiveVoiceExperienceChecks.run() }
        case "--check-live-dictation-delivery":
            try await MainActor.run { try LiveDictationDeliveryChecks.run() }
        case "--render-live-voice":
            guard args.count == 2 else { throw VoiceError.message("Usage: --render-live-voice OUTPUT_DIRECTORY") }
            try await MainActor.run {
                _ = NSApplication.shared
                try LiveVoiceExperienceChecks.render(to: URL(fileURLWithPath: args[1]))
            }
        case "--check-live-voice-model":
            guard args.count == 2 || (args.count == 3 && args[2] == "--two-sources") else { throw VoiceError.message("Supply one synthetic audio fixture path and optionally --two-sources.") }
            try await LiveVoiceModelCheck.run(audio: URL(fileURLWithPath: args[1]), twoSources: args.count == 3)
        case "--check-handoff-visual":
            guard args.count == 3 else { throw VoiceError.message("Usage: --check-handoff-visual SYNTHETIC_IMAGES NEW_OUTPUT_FOLDER") }
            try await HandoffJobsChecks.runVisualFixture(images: URL(fileURLWithPath: args[1]), output: URL(fileURLWithPath: args[2]))
        case "--check-handoff-metadata":
            guard args.count == 2 else { throw VoiceError.message("Usage: --check-handoff-metadata NEW_OUTPUT_FOLDER") }
            try await HandoffJobsChecks.runMetadataFixture(output: URL(fileURLWithPath: args[1]))
        case "--check-integrations":
            try await MainActor.run { try IntegrationChecks.run() }
        case "--check-speko":
            try SpekoChecks.run()
        case "--check-refinement":
            try LocalRefinementChecks.run(); try await LocalRefinementChecks.runTransportChecks()
            try await LocalRefinementChecks.runOwnershipChecks()
        case "--check-input":
            try await MainActor.run { try InputChecks.run() }
        case "--check-readback":
            try ReadbackChecks.run(); try await ReadbackChecks.runAdmissionChecks()
            try await ReadbackChecks.runAvailabilityChecks()
            try await MainActor.run { try ReadbackOrderingChecks.run() }
        case "--check-readback-resources":
            try ReadbackChecks.runPackagedResources()
        case "--check-snap-capture":
            try await SnapCaptureChecks.run()
        case "--check-transcript-handoff":
            try await MainActor.run { try TranscriptHandoffChecks.runAll() }
        // These write receipt.json and summary.txt to a new folder (optional
        // for the first two), since a run through the signed app has no stdout.
        case "--check-history-library":
            try await CheckReceipt.run(mode: args[0], folder: args.dropFirst().first) { _ in
                [try await MainActor.run { try WorkbenchHistoryChecks.run() }] + (try await HistoryChecks.run())
            }
        case "--check-handoff-jobs":
            try await CheckReceipt.run(mode: args[0], folder: args.dropFirst().first) { _ in try await HandoffJobsChecks.run() }
        case "--check-history-journey":
            guard args.count == 2 else { throw VoiceError.message("Usage: --check-history-journey NEW_OUTPUT_FOLDER") }
            try await CheckReceipt.run(mode: args[0], folder: args[1]) { folder in
                try await HistoryJourneyCheck.run(stores: folder!.appendingPathComponent("stores"))
            }
        case "--check-readback-pack":
            try await MainActor.run { try ReadbackPackChecks.run() }
        case "--check-readback-ordering-ui":
            let output = args.count > 1 ? URL(fileURLWithPath: args[1]) : nil
            try await MainActor.run { try ReadbackOrderingChecks.runNative(output: output) }
        case "--check-cleanup":
            try CleanupChecks.run()
            let result = await CleanupEngine().clean(CleanupChecks.example, style: .natural)
            guard DictationCleanup.isFaithful(result.text, to: DictationCleanup.light(CleanupChecks.example)), result.text.contains("• Apples") else { throw VoiceError.message("Natural cleanup changed the checked example") }
            print("NATURAL_CHECK_OK: \(result.method)\n\(result.text)")
        case "--clean-text":
            guard args.count >= 2 else { throw VoiceError.message("Usage: --clean-text TEXT_FILE [Original|Light|Natural]") }
            let text = try String(contentsOfFile: args[1], encoding: .utf8)
            let result = await CleanupEngine().clean(text, style: args.count > 2 ? (CleanupStyle(rawValue: args[2]) ?? .light) : .light)
            print(result.text)
        case "--prepare-model":
            try await engine().prepare(); print("MODEL_READY: \(await engine().statusDescription())")
        case "--transcribe":
            guard args.count == 2 else { throw VoiceError.message("Usage: LocalVoice --transcribe AUDIO_FILE") }
            print(try await engine().transcribe(URL(fileURLWithPath: args[1])))
        case "--self-test":
            try CoreChecks.run()
            let phrase = "The quick brown fox jumps over the lazy dog. Please bring the blue notebook to the meeting tomorrow morning."
            let audio = try AudioRenderer.render(text: phrase, voice: "Karen", rate: 165)
            defer { AudioRenderer.remove(audio) }
            let output = try await engine().transcribe(audio)
            let lower = output.lowercased()
            guard lower.contains("brown fox"), lower.contains("blue notebook"), lower.contains("tomorrow") else { throw VoiceError.message("Speech round-trip failed: \(output)") }
            print("ROUND_TRIP_OK: \(output)")
            let m4a = FileManager.default.temporaryDirectory.appendingPathComponent("LocalVoice-self-test.m4a")
            defer { try? FileManager.default.removeItem(at: m4a) }
            try AudioRenderer.export(audio, to: m4a)
            let file = try AVAudioFile(forReading: m4a)
            guard file.length > 0 else { throw VoiceError.message("M4A export was empty") }
            print("AUDIO_EXPORT_OK: \(Double(file.length) / file.processingFormat.sampleRate) seconds")
            let second = try await engine().transcribe(m4a)
            guard second.lowercased().contains("blue notebook") else { throw VoiceError.message("M4A recognition failed: \(second)") }
            print("M4A_TRANSCRIPTION_OK")
        default: throw VoiceError.message("Usage: LocalVoice [--prepare-model | --transcribe AUDIO_FILE | --check-core | --check-readback | --check-speko | --check-reading-cancellation | --check-library | --check-quick-look-panel FILE… | --check-reading-service | --check-reading-service-native | --render-reading-service-fixture OUTPUT.png | --render-surfaces OUTPUT_DIRECTORY | --self-test]")
        }
        return 0
    } catch { fputs("Local Voice: \(error.localizedDescription)\n", stderr); return 1 }
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--presenter-fixture", CommandLine.arguments[2].hasPrefix("/tmp/wb-presenter-fixture-") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = PresenterFixtureDelegate(root: URL(fileURLWithPath: CommandLine.arguments[2]))
        app.delegate = delegate; app.run()
    }
} else if CommandLine.arguments.count > 1, CommandLine.arguments[1] == SurfaceGallery.passFlag {
    // An isolated pass started by --render-surfaces. It waits on the main run loop for SwiftUI,
    // so it runs here rather than inside a main-queue job.
    MainActor.assumeIsolated { exit(SurfaceGallery.runPass(Array(CommandLine.arguments.dropFirst(2)))) }
} else if CommandLine.arguments.count > 1, CommandLine.arguments[1].hasPrefix("--") {
    Task { let code = await runCLI(Array(CommandLine.arguments.dropFirst())); exit(code) }
    RunLoop.main.run()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

/// The Window menu's floating-toolbar item follows the saved preference each time it opens.
extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleFloatingToolbar) { item.title = Self.floatingToolbarTitle(visible: model.floatingToolbarVisible) }
        return true
    }
}
