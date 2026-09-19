import AppKit
import SwiftUI
import Carbon
import AVFoundation
import Combine
import StageKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var window: NSWindow!
    var capturePanel: CapturePanelController!
    var model: AppModel!
    var statusItem: NSStatusItem!
    let hotkeys = VoiceHotkeys()
    var popover: NSPopover!
    var recorderMonitor: Any?
    var menuTarget: TextDelivery.Target?
    var stage: StageKitController!
    var keyboard: KeyboardCoachModel!
    var shortcutsSuspended = false
    var navigationObserver: NSObjectProtocol?
    var receiptObservations = Set<AnyCancellable>()
    private var receiptStatus: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Workbench.preparePreviewData(component: "LocalVoice", files: ["state.json", "demo-library.json"])
        _ = WorkbenchSettings.shared
        model = AppModel()
        stage = StageKitController(onOpenControls: { [weak self] in self?.navigate("annotate") }, onOpenScenes: { [weak self] in self?.navigate("present") })
        stage.mayBeginInteraction = { [weak self] in
            guard let self else { return false }
            return self.model.phase == .idle && !self.model.rendering && !self.shortcutsSuspended
        }
        stage.onEditShortcuts = { [weak self] in self?.navigate("shortcuts") }
        stage.onBeginActivity = { [weak self] in
            guard let self else { return }
            self.closeControls()
            self.model.previewingPanel = false
            self.model.dismissCaptureFailure()
            self.model.clipboardReceipt.dismissHUD()
            self.window?.orderOut(nil)
        }
        stage.validateExternalShortcut = { [weak self] code, modifiers in
            guard let self else { return nil }
            for id in [UInt32(1), 2, 3] {
                let saved = self.model.preferences.shortcut(id)
                if saved.enabled && saved.keyCode == code && saved.modifiers == modifiers { return "Already used by a Workbench voice action." }
            }
            return nil
        }
        stage.start()
        model.microphoneStartFailure = { [weak self] target in
            guard let self else { return "Workbench is unavailable." }
            return CaptureInputPolicy.canStart(isPresenting: self.stage.isPresenting, hasExternalMacTarget: target != nil)
                ? nil : "To enter text on your phone, use its keyboard or Dictation button. Mac dictation works in a Mac text field."
        }
        keyboard = KeyboardCoachModel(entries: shortcutEntries(), update: { [weak self] id, shortcut in guard let self else { return "Workbench is unavailable." }; return self.saveShortcut(id, shortcut) }, suspend: { [weak self] suspended in
            guard let self else { return }
            self.shortcutsSuspended = suspended
            if suspended { self.hotkeys.unregister(); self.stage.escape(); self.stage.setShortcutsSuspended(true) }
            else { self.stage.setShortcutsSuspended(false); self.registerShortcuts(); self.keyboard.replaceEntries(self.shortcutEntries()) }
        })
        window = NSWindow(contentViewController: NSHostingController(rootView: WorkbenchHome(model: model, stage: stage, keyboard: keyboard)))
        window.title = Workbench.displayName
        window.setContentSize(NSSize(width: 1180, height: 800))
        window.minSize = NSSize(width: 1050, height: 730)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false; window.center()
        capturePanel = CapturePanelController(model: model)
        popover = NSPopover(); popover.behavior = .transient; popover.animates = false; popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: WorkbenchQuickPanel(model: model, stage: stage, open: { [weak self] page in self?.navigate(page) }, draw: { [weak self] in
            self?.resumeTarget { _ in self?.stage.draw() }
        }, timer: { [weak self] in self?.closeControls(); self?.stage.showTimer() }, personas: { [weak self] in
            self?.closeControls(); self?.stage.showPersonas()
        }))
        popover.contentSize = NSSize(width: 370, height: 400)
        model.onPhaseChange = { [weak self] in
            guard let self else { return }
            if self.model.phase != .idle { self.keyboard?.stopInteraction(); self.stage.escape() }
            self.updateRecordingUI()
        }
        model.onShortcutsChanged = { [weak self] in self?.registerShortcuts() }
        model.onEditShortcut = { [weak self] id in self?.navigate("shortcuts") }
        model.onShowEditor = { [weak self] page in self?.model.page = page; self?.showWindow() }
        model.onMenuRecording = { [weak self] in self?.menuRecording() }
        model.onCloseMenu = { [weak self] in self?.closeControls() }
        model.onPasteLast = { [weak self] in self?.pasteLast() }
        model.onPasteTranscript = { [weak self] text in self?.paste(text) }
        model.onCancelShortcut = { [weak self] in self?.finishEditing() }
        model.onResetShortcuts = { [weak self] in
            guard let self else { return }
            self.finishEditing()
            self.model.preferences.dictationShortcut = VoicePreferences().dictationShortcut
            self.model.preferences.controlsShortcut = VoicePreferences().controlsShortcut
            self.model.preferences.libraryShortcut = VoicePreferences().libraryShortcut
        }
        model.onResetPanel = { [weak self] in self?.capturePanel.position(reset: true) }
        hotkeys.onKey = { [weak self] id, down in
            guard let self else { return }
            if id == 1 { self.model.shortcutChanged(down: down) }
            else if down, id == 3 { self.model.showLibrary() }
            else if down { self.toggleControls() }
        }
        navigationObserver = NotificationCenter.default.addObserver(forName: .workbenchNavigate, object: nil, queue: .main) { [weak self] notification in
            guard let page = notification.object as? String else { return }
            Task { @MainActor in self?.navigate(page) }
        }
        setupMenus(); registerShortcuts(); showWindow()
        model.clipboardReceipt.$receipt.receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let receipt = self.model.clipboardReceipt.receipt
                if receipt != nil { self.receiptStatus = self.model.status }
                else {
                    if self.model.phase == .idle, let previous = self.receiptStatus, self.model.status == previous {
                        self.model.status = "Ready when you are."
                    }
                    self.receiptStatus = nil
                }
                self.updateRecordingUI()
            }
            .store(in: &receiptObservations)
    }
    func registerShortcuts() {
        guard model.editingShortcut == nil, !shortcutsSuspended else { return }
        hotkeys.register(model.preferences); model.shortcutFailures = hotkeys.failures
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
            else if shortcut.modifiers & UInt32(controlKey | optionKey | cmdKey) == 0 {
                self.model.shortcutRecordingMessage = "Include Control, Option, or Command."; return nil
            }
            if shortcut.enabled && [UInt32(1), 2, 3].contains(where: { $0 != id && self.model.preferences.shortcut($0) == shortcut }) { self.model.shortcutRecordingMessage = "That shortcut is already assigned in Voice."; return nil }
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
        let main = NSMenu(); let application = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Workbench", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Keyboard shortcuts…", action: #selector(showShortcuts), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Workbench", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Workbench", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = appMenu; main.addItem(application)
        let edit = NSMenuItem(); edit.title = "Edit"; let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] { editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key) }
        edit.submenu = editMenu; main.addItem(edit)
        let windows = NSMenuItem(); windows.title = "Window"; let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Open Workbench", action: #selector(showWindow), keyEquivalent: "0")
        menu.addItem(withTitle: "Quick controls", action: #selector(toggleControls), keyEquivalent: "")
        menu.addItem(withTitle: "Saved resources", action: #selector(showLibrary), keyEquivalent: "l")
        let savePrompt = menu.addItem(withTitle: "Save clipboard as prompt…", action: #selector(saveClipboardPrompt), keyEquivalent: "s")
        savePrompt.keyEquivalentModifierMask = [.command, .shift]
        windows.submenu = menu; main.addItem(windows); NSApp.mainMenu = main; NSApp.windowsMenu = menu
        let help = NSMenuItem(); help.title = "Help"
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Workbench Guide", action: #selector(showGuide), keyEquivalent: "")
        help.submenu = helpMenu; main.addItem(help); NSApp.helpMenu = helpMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = NSStatusItem.AutosaveName("Workbench.MenuBar")
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp]); updateRecordingUI()
    }
    @objc func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Quick controls", action: #selector(toggleControls), keyEquivalent: "")
            menu.addItem(withTitle: "Open Workbench", action: #selector(showWindow), keyEquivalent: "")
            menu.addItem(withTitle: "Recent transcripts…", action: #selector(showHistory), keyEquivalent: "")
            menu.addItem(withTitle: "Saved resources…", action: #selector(showLibrary), keyEquivalent: "")
            menu.addItem(withTitle: "Keyboard shortcuts…", action: #selector(showShortcuts), keyEquivalent: "")
            menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
            menu.addItem(.separator()); menu.addItem(withTitle: "Quit Workbench", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else { toggleControls() }
    }
    @objc func toggleControls() { if popover.isShown { closeControls() } else { showControls() } }
    @objc func showGuide() { NSWorkspace.shared.open(URL(string: "https://workbench-mac.vercel.app/guide/")!) }
    func showControls() {
        guard let button = statusItem.button else { return }
        menuTarget = TextDelivery.capture()
        model.refreshPermissions(); keyboard.stopInteraction(); NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    func closeControls() { popover.performClose(nil); finishEditing() }
    func popoverDidClose(_ notification: Notification) { finishEditing() }
    func resumeTarget(_ action: @escaping (TextDelivery.Target?) -> Void) {
        let target = menuTarget
        closeControls()
        // Restore only the app from which controls were opened. Delivery checks the
        // exact focused element again after processing; it never presses Return.
        target?.app.activate(options: [])
        Task { try? await Task.sleep(nanoseconds: 160_000_000); action(target) }
    }
    func menuRecording() {
        if model.phase == .requesting { closeControls(); model.cancelRecording(); return }
        if model.phase == .recording { closeControls(); model.stopRecording(); return }
        resumeTarget { [weak self] target in self?.model.toggleRecording(target: target) }
    }
    func pasteLast() {
        paste(model.history.first?.text ?? model.transcript)
    }
    func paste(_ text: String) {
        guard !text.isEmpty, model.phase == .idle else { return }
        resumeTarget { [weak self] target in
            guard let self else { return }
            guard self.model.phase == .idle else { return }
            self.model.clipboardReceipt.clear(); self.model.dismissCaptureFailure()
            self.model.phase = .delivering; self.model.onPhaseChange?()
            Task {
                let outcome = await TextDelivery.deliver(text, target: target, mode: .paste, restoreClipboard: self.model.preferences.restoreClipboard)
                self.model.status = outcome.message
                self.model.clipboardReceipt.record(outcome: outcome, wordCount: TextRules.wordCount(text))
                self.model.phase = .idle; self.model.onPhaseChange?()
            }
        }
    }
    func updateRecordingUI() {
        let receipt = model.clipboardReceipt.receipt
        let symbol: String
        let state: String
        switch model.phase {
        case .recording: symbol = "mic.fill"; state = "Recording"
        case .requesting: symbol = "mic.badge.plus"; state = "Starting microphone"
        case .transcribing, .cleaning: symbol = "waveform"; state = "Processing speech"
        case .delivering: symbol = "arrow.up.doc"; state = "Delivering text"
        case .cancelling: symbol = "xmark.circle"; state = "Cancelling"
        case .idle:
            symbol = receipt?.isClipboardCurrent == true ? "doc.on.clipboard" : "square.stack.3d.up"
            state = receipt?.isClipboardCurrent == true ? (receipt?.title ?? "Transcript copied") : "Quick controls"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Workbench · " + state)
        statusItem?.button?.toolTip = "Workbench · " + state + " · " + model.preferences.controlsShortcut.label
        capturePanel?.update(model: model)
    }
    @objc func showSettings() { model.page = "settings"; showWindow() }
    @objc func showShortcuts() { model.page = "shortcuts"; showWindow() }
    @objc func showHistory() { model.page = "history"; showWindow() }
    @objc func showLibrary() { model.showLibrary() }
    @objc func saveClipboardPrompt() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { model.showLibrary(); model.library.notice = "Copy some text first."; return }
        model.savePrompt(text)
    }
    @objc func showWindow() { closeControls(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func showAbout() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Workbench", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development", .credits: NSAttributedString(string: "Everyday tools for speaking, explaining and presenting.\nSpeech powered by Parakeet, FluidAudio, macOS voices and your chosen providers.")]) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        keyboard?.stopInteraction(); stage?.shutdown(); model?.shutdown(); hotkeys.unregister()
        if let navigationObserver { NotificationCenter.default.removeObserver(navigationObserver) }
    }
    func navigate(_ page: String) {
        keyboard?.stopInteraction(); keyboard?.replaceEntries(shortcutEntries()); model.page = page; showWindow()
    }
    func shortcutEntries() -> [ShortcutEntry] {
        let voiceEntries = [(UInt32(1), "Dictate"), (UInt32(2), "Quick controls"), (UInt32(3), "Saved resources")].map { id, title in
            ShortcutEntry(id: "voice.\(id)", title: title, shortcut: model.preferences.shortcut(id), error: model.shortcutFailures[id])
        }
        let entries = voiceEntries + stage.shortcutDescriptors.map { entry in
            ShortcutEntry(id: "stage." + entry.id, title: entry.label, shortcut: VoiceShortcut(keyCode: entry.keyCode, modifiers: entry.modifiers, enabled: entry.enabled), error: entry.error)
        }
        // Imported custom combinations are preserved, but their conflicts must be
        // just as visible as conflicts discovered while assigning new keys.
        return entries.map { entry in
            var result = entry
            if result.error == nil { result.error = ShortcutConflict.message(for: entry.shortcut, replacing: entry.id, in: entries) }
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
        let engine = RecognitionEngine()
        switch args.first {
        case "--check-core":
            try CorrectionRuleChecks.run()
            try CoreChecks.run(); try CleanupChecks.run(); try DemoLibraryChecks.run(); try ProviderChecks.run(); try CaptureHUDChecks.run(); try CaptureSettingsChecks.run(); try LocalRefinementChecks.run()
            try await MainActor.run { try DemoLibraryChecks.runModelChecks(); try IntegrationChecks.run(); try KeyboardCoachChecks.run(); try ClipboardReceiptChecks.run() }
        case "--check-providers":
            try ProviderChecks.run(); try await ProviderChecks.runTransportChecks()
        case "--check-refinement":
            try LocalRefinementChecks.run(); try await LocalRefinementChecks.runTransportChecks()
        case "--check-input":
            try await MainActor.run { try InputChecks.run() }
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
            try await engine.prepare(); print("MODEL_READY: \(await engine.statusDescription())")
        case "--transcribe":
            guard args.count == 2 else { throw VoiceError.message("Usage: LocalVoice --transcribe AUDIO_FILE") }
            print(try await engine.transcribe(URL(fileURLWithPath: args[1])))
        case "--self-test":
            try CoreChecks.run()
            let phrase = "The quick brown fox jumps over the lazy dog. Please bring the blue notebook to the meeting tomorrow morning."
            let audio = try AudioRenderer.render(text: phrase, voice: "Karen", rate: 165)
            defer { AudioRenderer.remove(audio) }
            let output = try await engine.transcribe(audio)
            let lower = output.lowercased()
            guard lower.contains("brown fox"), lower.contains("blue notebook"), lower.contains("tomorrow") else { throw VoiceError.message("Speech round-trip failed: \(output)") }
            print("ROUND_TRIP_OK: \(output)")
            let m4a = FileManager.default.temporaryDirectory.appendingPathComponent("LocalVoice-self-test.m4a")
            defer { try? FileManager.default.removeItem(at: m4a) }
            try AudioRenderer.export(audio, to: m4a)
            let file = try AVAudioFile(forReading: m4a)
            guard file.length > 0 else { throw VoiceError.message("M4A export was empty") }
            print("AUDIO_EXPORT_OK: \(Double(file.length) / file.processingFormat.sampleRate) seconds")
            let second = try await engine.transcribe(m4a)
            guard second.lowercased().contains("blue notebook") else { throw VoiceError.message("M4A recognition failed: \(second)") }
            print("M4A_TRANSCRIPTION_OK")
        default: throw VoiceError.message("Usage: LocalVoice [--prepare-model | --transcribe AUDIO_FILE | --check-core | --self-test]")
        }
        return 0
    } catch { fputs("Local Voice: \(error.localizedDescription)\n", stderr); return 1 }
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1].hasPrefix("--") {
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
