import Foundation
import AppKit
import ToolbarCore
import ToolbarKit
import StageKit

@MainActor
enum WorkbenchControlChecks {
    static func run() async throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("Contextual controls: " + name) }
            count += 1
        }
        try check(WorkbenchControlTool.allCases.map(\.title) == ["Dictate", "Read", "Snap", "Snap & Talk", "Draw", "Present", "Persona", "Timer"], "panel rows follow the moments: Dictate, Read, Snap, Snap & Talk, Draw, Present, Persona, Timer")
        try check(WorkbenchControlTool.allCases.contains(.snap) && WorkbenchControlTool(mode: .snap) == .snap && WorkbenchControlTool.timer.mode == nil, "Snap is a real row sharing the toolbar's Snap mode; Timer is a row without a mode")
        try check(VoicePreferences().shortcut(8).enabled == false, "the Snap shortcut (voice.8) starts off")
        do {
            var snapKey = VoicePreferences(); snapKey.setShortcut(VoiceShortcut(keyCode: 20), for: 8)
            let restored = try JSONDecoder().decode(VoicePreferences.self, from: JSONEncoder().encode(snapKey))
            try check(restored.shortcut(8) == snapKey.shortcut(8) && restored.enabledCombinations.contains(snapKey.shortcut(8).combination), "an assigned Snap shortcut survives reload and registers")
        }
        // Two states per row: idle carries the capability's name, live the same next action the toolbar shows.
        do {
            var live = WorkbenchControlState()
            try check(WorkbenchControlTool.allCases.allSatisfy { live.actionTitle($0) == $0.title }, "idle rows read their capability's name")
            live.phase = .recording
            try check(live.actionTitle(.dictate) == "Stop", "Dictate reads Stop while recording")
            live = WorkbenchControlState(); live.playing = true
            try check(live.actionTitle(.read) == "Stop reading", "Read reads Stop reading while playing (pause and resume stay on the Read page)")
            live = WorkbenchControlState(); live.snapBusy = true
            try check(live.actionTitle(.snap) == "Snap" && !live.enabled(.snap), "Snap keeps its name and disables while a Snap is busy")
            live = WorkbenchControlState(); live.narrating = true
            try check(live.actionTitle(.snapAndTalk) == "Stop narration", "Snap & Talk reads Stop narration while narrating")
            live = WorkbenchControlState(); live.hasSession = true; live.captureCount = 3
            try check(live.actionTitle(.snapAndTalk) == "Capture next · 3", "an open session continues with its count in the label")
            live = WorkbenchControlState(); live.drawing = true
            try check(live.actionTitle(.annotate) == "Stop drawing", "Draw reads Stop drawing")
            live = WorkbenchControlState(); live.presenting = true
            try check(live.actionTitle(.present) == "End presentation" && live.nextAction(.present)?.operation == .endPresentation, "the Present row ends the presentation itself rather than focusing the toolbar")
            live = WorkbenchControlState(); live.overlays = true
            try check(live.actionTitle(.persona) == "Hide persona" && live.nextAction(.persona)?.operation == .hidePersona, "the Persona row hides the persona itself")
            live = WorkbenchControlState(); live.timerStarted = true
            try check(live.actionTitle(.timer) == "Stop timer", "Timer reads Stop timer once started")
            live = WorkbenchControlState(); live.phase = .recording; live.presenting = true
            try check(live.actionTitle(.present) == "Stop", "input-consuming work claims every row's label, exactly as it claims the toolbar's")
            try check(live.rowAction(.present) == .operation(.stopDictation), "and the Present row's click stops the recording, never ends the scene")
            live = WorkbenchControlState(); live.drawing = true; live.presenting = true; live.overlays = true; live.timerStarted = true
            try check(WorkbenchControlTool.allCases.allSatisfy { live.rowAction($0) == .operation(.finishDrawing) && live.actionTitle($0) == "Stop drawing" },
                      "while drawing every row, Timer included, reads Stop drawing and its click stops drawing")
            live = WorkbenchControlState(); live.rendering = true
            try check(live.actionTitle(.read) == "Cancel" && live.rowAction(.read) == .operation(.cancelReading), "Read says Cancel while preparing, because that discards")
            live.rendering = false; live.playing = true
            try check(live.rowAction(.read) == .operation(.stopReading), "the Read row stops rather than pauses")
            live = WorkbenchControlState()
            try check(WorkbenchControlTool.allCases.allSatisfy { tool in
                tool.mode.map { live.rowAction(tool) == .operation(.start($0)) } ?? (live.rowAction(tool) == .startTimer)
            }, "idle, each row's click starts its own mode, or the timer")
            live.timerStarted = true
            try check(live.rowAction(.timer) == .stopTimer, "a started timer's row stops it")
            try check(AppDelegate.voiceShortcutCatalogue.map(\.0) == VoicePreferences.shortcutIDs, "the voice catalogue titles cover exactly the shortcut ids")
        }
        var saved = VoicePreferences()
        saved.dictationShortcut.keyCode = 42
        saved.readbackShortcut = VoiceShortcut(keyCode: 18, enabled: false)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        legacy.removeValue(forKey: "readingShortcut"); legacy.removeValue(forKey: "presentationShortcut")
        let migrated = try JSONDecoder().decode(VoicePreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        try check(migrated.dictationShortcut == saved.dictationShortcut && migrated.shortcut(5) == saved.shortcut(5), "adding utility shortcuts preserves existing and disabled bindings")
        try check(!migrated.shortcut(6).enabled && migrated.shortcut(7) == VoicePreferences.defaultPresentationShortcut, "Read stays opt-in and Present starts on its presenter key")
        saved.setShortcut(VoiceShortcut(keyCode: 20), for: 6); saved.setShortcut(VoiceShortcut(keyCode: 21), for: 7)
        let restored = try JSONDecoder().decode(VoicePreferences.self, from: JSONEncoder().encode(saved))
        try check(restored.shortcut(6) == saved.shortcut(6) && restored.shortcut(7) == saved.shortcut(7), "opt-in utility shortcut assignments survive reload")
        try check(ToolbarModeFollower.modeToSelect(previous: [], current: [.draw]) == .draw, "a capability going live becomes the toolbar mode")
        try check(ToolbarModeFollower.modeToSelect(previous: [.draw], current: [.draw]) == nil, "already-live work does not move the mode")
        try check(ToolbarModeFollower.modeToSelect(previous: [.draw, .present], current: [.draw]) == nil, "ending leaves the mode where it was")
        try check(ToolbarModeFollower.modeToSelect(previous: [.draw], current: [.draw, .present]) == .present, "a Present door pressed in Draw mode starts a presentation and moves the mode to Present")
        try check(ToolbarNextAction.resolve(ToolbarLiveState(mode: .present, drawing: true, presenting: true)).title == "Stop drawing"
                  && ToolbarNextAction.resolve(ToolbarLiveState(mode: .present, presenting: true)).title == "End presentation", "after that start the resting label reads End presentation once drawing has stopped")
        try check(ToolbarNextAction.resolve(ToolbarLiveState(mode: .draw, presenting: true)).title == "Draw"
                  && ToolbarNextAction.choices(for: ToolbarLiveState(mode: .draw, presenting: true)).contains { $0.mode == .present && $0.isLive },
                  "choosing Draw during a live scene keeps Draw as the label and lights the chooser's Present row")
        try check(ToolbarModeFollower.modeToSelect(previous: [], current: [.draw, .persona, .present]) == .present, "several starts in one tick: Present before Persona before the rest")
        try check(ToolbarModeFollower.modeToSelect(previous: [.present], current: [.present, .persona, .dictate]) == .persona, "Persona outranks the rest once Present is already live")
        try check(ToolbarModeFollower.liveModes(dictating: false, reading: false, narrating: false, drawing: false, presenting: false, persona: false, snapping: false).isEmpty, "a restored session at launch is not a start")
        try check(FloatingToolbarSurface.resolve(enabled: false, capturingScreen: false, dictation: false, narration: false, reading: true) == .tools, "active reading keeps the shared host even with the idle toolbar disabled (#134 T4)")
        try check(FloatingToolbarSurface.resolve(enabled: true, capturingScreen: true, dictation: false, narration: false, reading: true) == .hidden, "capture hides reading controls too")
        // Hide toolbar is authoritative for the tools over live Draw, Present and Persona (#155).
        func surface(shown: Bool = false, drawing: Bool = false, presenting: Bool = false, persona: Bool = false, inserting: Bool = false,
                     dictation: Bool = false, narration: Bool = false, reading: Bool = false, cue: Bool = false,
                     capturing: Bool = false) -> FloatingToolbarSurface {
            .resolve(shown: shown, drawing: drawing, presenting: presenting, persona: persona, inserting: inserting,
                     capturingScreen: capturing, dictation: dictation, narration: narration, reading: reading, cue: cue)
        }
        try check(surface() == .hidden && surface(drawing: true) == .hidden && surface(presenting: true) == .hidden && surface(persona: true) == .hidden
                  && surface(drawing: true, presenting: true, persona: true) == .hidden, "Hide toolbar hides the tools while drawing, presenting or showing a persona")
        try check(surface(shown: true) == .tools && surface(shown: true, drawing: true, presenting: true, persona: true) == .tools,
                  "Show floating toolbar brings the tools back over live work")
        // Recording, narration, reading and their results share the tools' host (#134 T4): it stays
        // up while they run even with the tools hidden, and only the no-speech cue has its own view.
        try check(surface(drawing: true, dictation: true) == .tools && surface(presenting: true, narration: true) == .tools
                  && surface(persona: true, reading: true) == .tools, "a live recording, narration or reading keeps the shared host while the tools are hidden")
        try check(surface(dictation: true, cue: true) == .cue && surface(shown: true, cue: true) == .cue
                  && surface(dictation: true, cue: true, capturing: true) == .hidden, "the no-speech cue has its own view, and screen capture hides it too")
        try check(surface(inserting: true) == .tools, "a prompt insertion keeps its Stop on the tools until it ends")
        // Position… opened from the toolbar's keyboard focus hands the keyboard back (#197 review).
        let closes: [ToolbarPositionClose] = [.chose, .reset, .escape, .dismissed]
        try check(closes.map { $0.returnsKeyboard(openedFromKeyboard: true) } == [true, true, true, false]
                  && !closes.contains { $0.returnsKeyboard(openedFromKeyboard: false) },
                  "Position… gives the keyboard back to the toolbar after a choice, Reset or Escape, only when opened from the keyboard")
        // The break timer on the compact mark (#205 review): running is live work, paused is paused
        // work, and a finished timer ("Time is up") is neither, though its session stays started.
        try check(WorkbenchControlContext.timerActivity(.running) == (true, false) && WorkbenchControlContext.timerActivity(.paused) == (false, true),
                  "a running timer is live work and a paused one is paused")
        try check(WorkbenchControlContext.timerActivity(.finished) == (false, false) && WorkbenchControlContext.timerActivity(.idle) == (false, false),
                  "a finished timer never reads as paused on the mark, and an idle one shows nothing")
        try check(WorkbenchControlState.liveTimer(.finished) == .finished && WorkbenchControlState.liveTimer(.paused) == .paused
                  && WorkbenchControlState.liveTimer(.running) == .running && WorkbenchControlState.liveTimer(.idle) == .none,
                  "the next action's live state tells a finished timer from a paused one")
        // More's Active work reaches everything the mark can show from any other tool (#205 review).
        do {
            func items(_ mode: ToolbarMode, _ edit: (inout ToolbarActiveWork.Facts) -> Void) -> [ToolbarActiveWork] {
                var facts = ToolbarActiveWork.Facts(mode: mode, nextAction: .start(mode))
                edit(&facts)
                return ToolbarActiveWork.items(facts)
            }
            let others = ToolbarMode.allCases
            try check(others.allSatisfy { items($0) { $0.meetingRecovery = true } == [.meetingRecovery] },
                      "a meeting recording saved for retry is offered from every tool, since Dictate's options hold only its page")
            try check(others.filter { $0 != .snap }.allSatisfy { items($0) { $0.snapDraft = true } == [.snapDraft] }
                      && items(.snap) { $0.snapDraft = true }.isEmpty,
                      "an unsaved Snap capture opens the Snap editor from every other tool; Snap's own options already do")
            try check(others.allSatisfy { mode in
                          [TimerTransport.running, .paused, .finished].allSatisfy { transport in items(mode) { $0.timer = transport } == [.timer(transport)] }
                              && items(mode) { $0.timer = .idle }.isEmpty },
                      "the timer offers the next transport TimerTransport names, Pause, Resume or Restart, whichever tool is chosen")
            try check(items(.present) { $0.drawing = true; $0.meetingRecording = true; $0.persona = .sessionHidden }
                          == [.stopDrawing, .persona("Show personas"), .stopTranscribing]
                      && items(.draw) { $0.presenting = true } == [.endPresentation] && items(.dictate) { $0.meetingRecording = true; $0.meetingRecovery = true }.isEmpty,
                      "the other tools' finishes are unchanged, and a recording meeting is not offered for recovery")
        }
        // Reading keeps its own commands in More while another job holds the primary (#211 F6).
        do {
            func reading(_ primary: ToolbarOperation, _ state: ToolbarLiveState.Reading) -> [ToolbarOperation] {
                ToolbarReadingCommands.operations(primary: primary, reading: state)
            }
            try check(reading(.finishDrawing, .playing) == [.pauseReading, .stopReading] && reading(.stopInserting, .paused) == [.resumeReading, .stopReading],
                      "while drawing or an insertion holds the primary, More offers Pause reading or Resume reading, and Stop reading")
            try check(reading(.finishDrawing, .preparing) == [.cancelReading], "and Cancel while the reading is still preparing")
            try check(reading(.pauseReading, .playing) == [.stopReading] && reading(.cancelReading, .preparing).isEmpty && reading(.finishDrawing, .idle).isEmpty,
                      "the row's own reading action is not repeated there, and no reading offers nothing")
        }
        // Words waiting for drawing to end lead with Stop drawing, which delivers them; Copy now
        // is in More (#211 F5).
        do {
            var waiting = WorkbenchControlState(); waiting.phase = .delivering; waiting.waitingForDrawing = true; waiting.drawing = true
            try check(waiting.live(.dictate).dictation == .waitingForDrawing && waiting.actionTitle(.dictate) == "Stop drawing"
                      && waiting.rowAction(.dictate) == .operation(.finishDrawing), "words waiting for drawing lead with Stop drawing, not a disabled Processing…")
            waiting.drawing = false
            try check(waiting.actionTitle(.dictate) == "Processing…", "once drawing has ended they are a moment's processing")
        }
        // Keyboard entry keeps the launcher row: only the pointer's own reveal shows a waiting
        // result's controls, and a row that Keep open brings back waits for the pointer and holds
        // as the kept-open swap does (#211 F1, F8).
        do {
            let suite = "Workbench.ToolbarResultChecks." + UUID().uuidString
            guard let defaults = UserDefaults(suiteName: suite) else { throw VoiceError.message("Could not create isolated test preferences.") }
            defer { defaults.removePersistentDomain(forName: suite) }
            func toolbar() -> CaptureHUDControls {
                let controls = CaptureHUDControls(defaults: defaults)
                controls.resultPending = { true }
                controls.toolbar.activate()
                return controls
            }
            let keyboard = toolbar()
            keyboard.focusToolbar()
            try check(keyboard.toolbar.state.tier == .revealed && !keyboard.revealsResult,
                      "keyboard entry onto a waiting result reveals the launcher row, not the result's controls")
            let pointer = toolbar()
            pointer.toolbar.send(.pointerEntered)
            try check(pointer.revealsResult, "the pointer's own reveal shows the waiting result's controls")
            pointer.focusToolbar()
            try check(pointer.revealsResult, "and the keyboard taken after it, by the click on the mark, keeps them")
            let kept = toolbar()
            kept.toolbar.send(.keepOpenChanged(true))
            kept.suspendToolbar(); kept.toolbar.activate()
            try check(kept.toolbar.state.tier == .revealed && !kept.revealsResult,
                      "a kept-open row that comes back keeps its launcher until the host has found the pointer")
            kept.toolbar.send(.pointerEntered); kept.showResultIfKeptOpen()
            try check(!kept.revealsResult, "and while the pointer is on it the result waits")
            kept.focusToolbar(); kept.toolbar.send(.pointerLeft); kept.showResultIfKeptOpen()
            try check(!kept.revealsResult, "as it does while the keyboard holds the row")
            kept.unfocusToolbar(); kept.showResultIfKeptOpen()
            try check(kept.revealsResult, "once nothing is on it, the result takes the kept-open row's place")
            kept.toolbar.send(.keepOpenChanged(false))
        }
        // The tool chooser (#134): a choice or Escape gives the keyboard back to the launcher, so a
        // second Escape leaves the toolbar; a click elsewhere leaves it where the person went.
        try check([ToolbarChooserClose.chose, .escape, .dismissed].map(\.returnsKeyboardToLauncher) == [true, true, false],
                  "the chooser returns the keyboard to the launcher after a choice or Escape, never after a click elsewhere")
        do {
            // It opens on the side with room, from the launcher's outer edge, inside the display.
            let visible = NSRect(x: 0, y: 25, width: 1440, height: 875), content = NSSize(width: 280, height: 264)
            let bottom = NSRect(x: 700, y: 41, width: 48, height: 40), topRight = NSRect(x: 1376, y: 844, width: 48, height: 40)
            let above = ToolbarChooserPlacement.frame(content: content, launcher: bottom, visible: visible, growsLeftward: false)
            let below = ToolbarChooserPlacement.frame(content: content, launcher: topRight, visible: visible, growsLeftward: true)
            try check(above.minY == bottom.maxY + ToolbarChooserPlacement.gap && above.minX == bottom.minX && above.size == content && visible.contains(above),
                      "from a bottom dock the chooser opens above the launcher, from its outer edge, at its full size")
            try check(below.maxY == topRight.minY - ToolbarChooserPlacement.gap && below.maxX == topRight.maxX && below.size == content && visible.contains(below),
                      "from a top-right dock it opens below, aligned to the launcher's right edge")
            let short = NSRect(x: 0, y: 0, width: 400, height: 200), launcher = NSRect(x: 10, y: 80, width: 48, height: 40)
            let squeezed = ToolbarChooserPlacement.frame(content: content, launcher: launcher, visible: short, growsLeftward: false)
            try check(short.insetBy(dx: ToolbarChooserPlacement.edgeMargin, dy: ToolbarChooserPlacement.edgeMargin).contains(squeezed)
                      && squeezed.height < content.height && !squeezed.intersects(launcher),
                      "on a short display it takes the roomier side, stays inside the margins and never covers the launcher")
        }
        // Every earlier save keeps its place (#134): a dock by name, this build's launcher centre,
        // #163's glyph edge, a move an earlier build made since, and the resting element alone.
        do {
            let suite = "Workbench.ToolbarPositionChecks." + UUID().uuidString
            guard let defaults = UserDefaults(suiteName: suite) else { throw VoiceError.message("Could not create isolated test preferences.") }
            defer { defaults.removePersistentDomain(forName: suite) }
            let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)
            func saved() -> (position: ToolbarPosition, migrated: Bool) {
                CapturePanelController.savedPosition(defaults, screens: [screen], preferred: screen)
            }
            try check(saved() == (.docked(.bottom), false), "with nothing saved the toolbar rests at bottom centre")
            defaults.set(NSStringFromPoint(NSPoint(x: 1000, y: 400)), forKey: "capturePanelOrigin.v1")
            defaults.set(NSStringFromSize(NSSize(width: 132, height: 36)), forKey: "capturePanelSize.v1")
            try check(saved() == (.free(ToolbarFreePosition(centre: CGPoint(x: 1114, y: 418), growsLeftward: true)), true),
                      "the oldest save, a resting element alone, keeps its glyph where it was and the side it was left on")
            defaults.set(CapturePanelController.record(ToolbarFreePosition(glyphEdge: 1100, centreY: 400, growsLeftward: true)), forKey: "capturePanelFreePosition.v1")
            let current = ToolbarFreePosition(centre: CGPoint(x: 1082, y: 400), growsLeftward: true)
            try check(saved() == (.free(current), true), "#163's glyph edge becomes the launcher centre 18 points inside it")
            defaults.set(CapturePanelController.launcherRecord(current), forKey: "capturePanelLauncher.v1")
            try check(saved() == (.free(current), false), "this build's launcher record stands while the glyph copy beside it is unchanged")
            // 1010.123456789 + 18 crosses 1024, so the glyph edge converts back one bit off.
            let exact = ToolbarFreePosition(centre: CGPoint(x: 1010.123456789, y: 400.987654321), growsLeftward: true)
            defaults.set(CapturePanelController.launcherRecord(exact), forKey: "capturePanelLauncher.v1")
            defaults.set(CapturePanelController.record(exact), forKey: "capturePanelFreePosition.v1")
            try check(saved() == (.free(exact), false), "a glyph copy that converts back a hair off is not a move")
            let moved = ToolbarFreePosition(glyphEdge: 300, centreY: 200, growsLeftward: false)
            defaults.set(CapturePanelController.record(moved), forKey: "capturePanelFreePosition.v1")
            try check(saved() == (.free(moved), true), "a move an earlier build made since wins over this build's older record")
            defaults.set("topRight", forKey: "capturePanelAnchor.v2")
            try check(saved() == (.docked(.topRight), false), "a dock by name wins over any free record")
        }
        var state = WorkbenchControlState()
        state.presenting = true; state.drawing = true; state.phase = .recording
        try check(state.enabled(.dictate) && state.enabled(.annotate) && state.enabled(.present),
                  "all three running activities retain their own finish controls")
        state.ready = false; state.rendering = true; state.narrating = true
        state.mayDraw = false; state.mayPresent = false
        try check(state.enabled(.dictate) && state.enabled(.annotate) && state.enabled(.present) && state.enabled(.snapAndTalk),
                  "finish actions remain available when new work is disallowed")
        state.phase = .requesting
        try check(state.enabled(.dictate) && state.actionTitle(.dictate) == "Cancel request", "microphone permission requests remain cancellable")
        state.phase = .idle; state.drawing = false; state.presenting = false; state.narrating = false
        try check(!state.enabled(.dictate) && !state.enabled(.annotate) && !state.enabled(.present) && !state.enabled(.snapAndTalk),
                  "idle starts respect availability")
        state = WorkbenchControlState(); state.pendingNarration = true
        try check(!state.enabled(.dictate) && state.enabled(.snapAndTalk), "ordinary dictation waits for the narration queue while another capture can queue")
        state.capturing = true
        try check(!state.enabled(.snapAndTalk), "screen capture cannot be re-entered")
        state = WorkbenchControlState(); state.hasSession = true
        try check(state.actionTitle(.snapAndTalk) == "Capture next · 0", "an existing session continues instead of starting another")
        state = WorkbenchControlState(); state.overlays = true
        try check(state.actionTitle(.persona) == "Hide persona", "one floating card is hidden by the main Persona action")
        state.overlaySession = true
        try check(state.actionTitle(.persona) == "Hide personas", "a prepared set's main action names the hide it performs, not an end")
        state.overlaysPaused = true
        try check(state.actionTitle(.persona) == "Show personas", "a temporarily hidden set offers to show again")
        // Home's Persona row and tile (#134) read Persona's own action from the shared owner: a hidden
        // prepared set, an active one, one card and an ended set, alone, beside an independent
        // presentation and running timer, and while dictating claims the panel rows.
        do {
            let alongside: [(String, (inout WorkbenchControlState) -> Void)] = [
                ("alone", { _ in }),
                ("beside a presentation and a running timer", { $0.presenting = true; $0.timerStarted = true; $0.timerRunning = true }),
                ("while dictating", { $0.phase = .recording })]
            let personas: [(String, (inout WorkbenchControlState) -> Void, ToolbarLiveState.Persona, String, ToolbarOperation)] = [
                ("a hidden prepared set", { $0.overlays = true; $0.overlaySession = true; $0.overlaysPaused = true }, .sessionHidden, "Show personas", .resumeOverlays),
                ("an active prepared set", { $0.overlays = true; $0.overlaySession = true }, .session, "Hide personas", .pauseOverlays),
                ("one card", { $0.overlays = true }, .shown, "Hide persona", .hidePersona),
                ("an ended set", { _ in }, .none, "Show persona", .start(.persona))]
            for (context, setUp) in alongside {
                for (name, configure, persona, title, operation) in personas {
                    var live = WorkbenchControlState(); setUp(&live); configure(&live)
                    let home = HomePersonaControl(live)
                    let toolbar = ToolbarNextAction.resolve(ToolbarLiveState(mode: .persona, persona: persona))
                    try check(home.rowTitle == title && home.rowTitle == toolbar.title && home.operation == operation && home.isEnabled,
                              "Home's Persona control reads \(title) for \(name) \(context), as the toolbar's Persona mode does")
                }
            }
            var hidden = WorkbenchControlState(); hidden.overlays = true; hidden.overlaySession = true; hidden.overlaysPaused = true
            try check(HomePersonaControl(hidden).tileVerb == "Show personas" && HomePersonaControl(hidden).help.hasPrefix("Show the set again"),
                      "a hidden prepared set's tile and tooltip offer to show it again, never to hide it")
            try check(HomePersonaControl(WorkbenchControlState()).tileVerb == "Show a card over your apps", "with nothing live the tile keeps its description")
            hidden.presenting = true; hidden.timerStarted = true; hidden.timerRunning = true
            try check(hidden.actionTitle(.persona) == "Show personas" && hidden.rowAction(.persona) == .operation(.resumeOverlays)
                      && hidden.actionTitle(.present) == "End presentation" && hidden.actionTitle(.timer) == "Stop timer",
                      "the panel agrees, and Present and Timer keep their own actions")
        }
        state = WorkbenchControlState(); state.timerStarted = true
        try check(state.actionTitle(.timer) == "Stop timer", "a started timer offers to stop")
        state.timerStarted = false
        try check(state.actionTitle(.timer) == "Timer", "a reset timer offers a new start")
        for phase in [AppModel.Phase.idle, .requesting, .recording, .transcribing, .cleaning] {
            try check(WorkbenchDrawingAdmission.allows(phase: phase, suspended: false, capturingScreen: false, terminating: false),
                      "annotation can coexist with \(phase.rawValue)")
        }
        for phase in [AppModel.Phase.delivering, .cancelling] {
            try check(!WorkbenchDrawingAdmission.allows(phase: phase, suspended: false, capturingScreen: false, terminating: false),
                      "annotation cannot steal input during \(phase.rawValue)")
        }
        try check(!WorkbenchDrawingAdmission.allows(phase: .recording, suspended: true, capturingScreen: false, terminating: false), "shortcut practice retains input")
        try check(!WorkbenchDrawingAdmission.allows(phase: .recording, suspended: false, capturingScreen: true, terminating: false), "screen capture retains input")
        try check(!WorkbenchDrawingAdmission.allows(phase: .recording, suspended: false, capturingScreen: false, terminating: true), "shutdown cannot start drawing")
        let gate = DrawingDeliveryGate()
        func waitUntilPending() async throws {
            for _ in 0..<100 where !gate.isWaiting { await Task.yield() }
            try check(gate.isWaiting, "delivery waits without occupying the main thread")
        }
        let resume = Task { try await gate.wait() }
        try await waitUntilPending()
        gate.resolve(.resume)
        try check(try await resume.value == .resume && !gate.isWaiting, "ending annotation releases exactly one delivery")
        gate.resolve(.resume)
        let copy = Task { try await gate.wait() }
        try await waitUntilPending(); gate.resolve(.copy)
        try check(try await copy.value == .copy, "copy now bypasses paste without stopping drawing")
        let cancel = Task { try await gate.wait() }
        try await waitUntilPending(); cancel.cancel()
        do { _ = try await cancel.value; throw VoiceError.message("Cancelled delivery resumed") }
        catch is CancellationError { try check(!gate.isWaiting, "cancellation releases its continuation") }
        try await PromptInsertionChecks.run()
        // Prompts and dictation share TextDelivery's copy and paste.
        try await TextDeliveryChecks.run()
        try AccessibilitySetupChecks.run()
        try PromptPickerChecks.run()
        print("WORKBENCH_CONTROL_CHECKS_OK: \(count) checks passed")
    }
}
