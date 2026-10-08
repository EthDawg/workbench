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
        do {
            let suite = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench.ToolbarOrientationChecks." + UUID().uuidString).path
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let controls = CaptureHUDControls(defaults: defaults)
            controls.activateToolbar(); controls.focusToolbar()
            controls.reportSize(NSSize(width: 252, height: 40), tier: .revealed, anchor: .bottom, isResult: false,
                                accessoryAvailable: true, accessoryShown: true)
            controls.rowAnchor = .left
            try check(controls.preferredToolbarSize == NSSize(width: 40, height: 252), "orientation seeds the correct column before a new size report")
            controls.reportSize(NSSize(width: 400, height: 40), tier: .revealed, anchor: .bottom, isResult: false,
                                accessoryAvailable: true, accessoryShown: true)
            try check(controls.preferredToolbarSize == NSSize(width: 40, height: 252), "a delayed horizontal measurement cannot widen a vertical column")
            let small = NSRect(x: 0, y: 0, width: 800, height: 250)
            let landing = controls.size(for: .left, screen: small)
            try check(landing == NSSize(width: 40, height: 212) && !controls.fittedRow(for: .left, screen: small).accessoryFits,
                      "guide and release both leave Review in More when the destination edge is short")
            controls.reportSize(landing, tier: .revealed, anchor: .left, isResult: false, accessoryAvailable: true, accessoryShown: false)
            try check(controls.size(for: .left, screen: small) == landing, "committing the fitted column keeps the preview size")
            try check(controls.size(for: .bottom, screen: small) == NSSize(width: 252, height: 40), "returning to a long edge restores the contextual accessory")
            controls.suspendToolbar()
            controls.resultPending = { true }; controls.activateToolbar(); controls.toolbar.send(.pointerEntered)
            controls.reportSize(NSSize(width: 320, height: 100), tier: .revealed, anchor: .left, isResult: true,
                                accessoryAvailable: false, accessoryShown: false)
            try check(controls.preferredToolbarSize == NSSize(width: 320, height: 100), "side placement keeps a result card horizontal")
            controls.resultEnded()
            try check(controls.preferredToolbarSize == landing, "result measurement never overwrites the toolbar column")
            controls.suspendToolbar()
        }
        try check(WorkbenchControlTool.allCases.map(\.title) == ["Dictate", "Snap", "Snap & Talk", "Draw", "Present", "Persona", "Timer"], "panel rows contain only the retained tools")
        try check(WorkbenchControlTool.allCases.contains(.snap) && WorkbenchControlTool(mode: .snap) == .snap && WorkbenchControlTool.timer.mode == nil, "Snap is a real row sharing the toolbar's Snap mode; Timer is a row without a mode")
        try check(VoicePreferences().shortcut(8).enabled == false, "the Snap shortcut (voice.8) starts off")
        do {
            var snapKey = VoicePreferences(); snapKey.setShortcut(VoiceShortcut(keyCode: 20), for: 8)
            let restored = try JSONDecoder().decode(VoicePreferences.self, from: JSONEncoder().encode(snapKey))
            try check(restored.shortcut(8) == snapKey.shortcut(8) && restored.enabledCombinations.contains(snapKey.shortcut(8).combination), "an assigned Snap shortcut survives reload and registers")
        }
        // Each row names and controls its own capability, including while other work runs.
        do {
            var live = WorkbenchControlState()
            try check(WorkbenchControlTool.allCases.allSatisfy { live.actionTitle($0) == $0.title }, "idle rows read their capability's name")
            live.phase = .recording
            try check(live.actionTitle(.dictate) == "Finish dictation", "Dictate names the shared Finish action while recording")
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
            live = WorkbenchControlState(); live.drawing = true; live.presenting = true; live.overlays = true; live.timerStarted = true
            let independent: [(WorkbenchControlTool, WorkbenchRowAction, String)] = [
                (.dictate, .operation(.start(.dictate)), "Dictate"),
                (.snap, .operation(.start(.snap)), "Snap"),
                (.snapAndTalk, .operation(.start(.snapAndTalk)), "Snap & Talk"),
                (.annotate, .operation(.finishDrawing), "Stop drawing"),
                (.present, .operation(.endPresentation), "End presentation"),
                (.persona, .operation(.hidePersona), "Hide persona"),
                (.timer, .stopTimer, "Stop timer")]
            for (tool, operation, title) in independent {
                try check(live.rowAction(tool) == operation && live.actionTitle(tool) == title && live.enabled(tool),
                          "\(tool.title) keeps its own enabled action while drawing, presenting, showing a persona and timing")
            }
            try check(WorkbenchControlTool.allCases.filter { live.active($0) } == [.annotate, .present, .persona, .timer],
                      "only the live owners receive the menu's accent")
            live.phase = .recording; live.mayPresent = false
            for (tool, operation, title) in independent where tool != .dictate {
                try check(live.rowAction(tool) == operation && live.actionTitle(tool) == title,
                          "recording does not replace \(tool.title)'s action with Stop")
            }
            try check(live.rowAction(.dictate) == .operation(.stopDictation) && live.enabled(.dictate), "only Dictate stops its recording")
            try check(!live.enabled(.snap) && !live.enabled(.snapAndTalk),
                      "recording disables incompatible captures")
            try check([WorkbenchControlTool.annotate, .present, .persona, .timer].allSatisfy(live.enabled),
                      "live Draw, Present, Persona and Timer endings stay reachable during recording")
            try check(ToolbarNextAction.resolve(live.live(.present)).operation == .stopDictation,
                      "the toolbar retains its global recording priority while menu rows stay independent")
            live.phase = .idle
            try check(ToolbarNextAction.resolve(live.live(.present)).operation == .finishDrawing,
                      "the toolbar retains its global drawing priority")
            live = WorkbenchControlState()
            try check(WorkbenchControlTool.allCases.allSatisfy { tool in
                tool.mode.map { live.rowAction(tool) == .operation(.start($0)) } ?? (live.rowAction(tool) == .startTimer)
            }, "idle, each row's click starts its own mode, or the timer")
            live.timerStarted = true
            try check(live.rowAction(.timer) == .stopTimer, "a started timer's row stops it")
            try check(AppDelegate.voiceShortcutCatalogue.map(\.0) == VoicePreferences.shortcutIDs, "the voice catalogue titles cover exactly the shortcut ids")
        }
        // Admission belongs to the operation shown. A continuation is a new capture, a
        // hidden Persona set must pass its owner's resume guard, and waits never dispatch.
        do {
            var live = WorkbenchControlState(); live.hasSession = true; live.captureCount = 3
            live.phase = .recording
            try check(live.rowAction(.snapAndTalk) == .operation(.captureNext) && !live.enabled(.snapAndTalk),
                      "Capture next stays visible but disabled while Dictate owns the microphone")
            live.phase = .idle; live.meetingBusy = true
            try check(!live.enabled(.dictate) && !live.enabled(.snapAndTalk), "meeting work retains shared audio admission")
            live.meetingRecording = true
            try check(live.rowAction(.dictate) == .operation(.stopMeetingTranscription) && live.enabled(.dictate),
                      "a live meeting keeps its own Stop transcribing action")
            live = WorkbenchControlState(); live.capturing = true
            try check(live.actionTitle(.snapAndTalk) == "Capturing…" && !live.enabled(.snapAndTalk)
                      && !live.admits(.operation(.wait), for: .snapAndTalk), "a screen capture wait can never dispatch")
            for phase in [AppModel.Phase.transcribing, .cleaning, .delivering, .cancelling] {
                live = WorkbenchControlState(); live.phase = phase; live.drawing = true
                try check(live.rowAction(.dictate) == .operation(.wait) && !live.enabled(.dictate)
                          && !live.admits(.operation(.wait), for: .dictate) && live.enabled(.annotate),
                          "Dictate waits during \(phase.rawValue) while Draw keeps Stop drawing")
            }
            live = WorkbenchControlState(); live.overlays = true; live.overlaySession = true; live.overlaysPaused = true
            live.phase = .recording; live.mayPresent = false
            try check(live.actionTitle(.persona) == "Show personas" && !live.enabled(.persona) && !HomePersonaControl(live).isEnabled,
                      "a hidden Persona set retains its identity and waits for its owner's resume admission")
            live.overlaysPaused = false
            try check(live.rowAction(.persona) == .operation(.pauseOverlays) && live.enabled(.persona),
                      "hiding an active Persona set stays available while a new start is blocked")
            live.overlaySession = false
            try check(live.rowAction(.persona) == .operation(.hidePersona) && live.enabled(.persona),
                      "hiding one live card stays available while a new start is blocked")
            live = WorkbenchControlState(); live.presenting = true; live.insertingPrompt = true
            try check(live.rowAction(.present) == .operation(.endPresentation), "Present still ends its scene during independent prompt insertion")
        }
        // A rendered action is a commitment to that operation, never a toggle resolved
        // again on release. SwiftUI also replaces the button's identity when it changes.
        do {
            let ending: [(WorkbenchControlTool, (inout WorkbenchControlState) -> Void)] = [
                (.dictate, { $0.phase = .recording }),
                (.snapAndTalk, { $0.narrating = true }), (.annotate, { $0.drawing = true }),
                (.present, { $0.presenting = true }), (.persona, { $0.overlays = true }),
                (.timer, { $0.timerStarted = true })]
            for (tool, start) in ending {
                var live = WorkbenchControlState(); start(&live)
                let pressed = live.rowAction(tool)
                try check(live.admits(pressed, for: tool), "the unchanged \(tool.title) ending is admitted")
                live = WorkbenchControlState()
                try check(!live.admits(pressed, for: tool), "a completed \(tool.title) ending cannot become a fresh start on release")
            }
            var live = WorkbenchControlState(); live.hasSession = true
            let next = live.rowAction(.snapAndTalk)
            live.phase = .recording
            try check(live.rowAction(.snapAndTalk) == next && !live.admits(next, for: .snapAndTalk),
                      "a still-matching Capture next is rejected when admission changes before release")
            live = WorkbenchControlState(); live.overlays = true
            let hide = live.rowAction(.persona)
            live.overlaySession = true
            try check(!live.admits(hide, for: .persona), "Hide persona cannot act on a newly active prepared set")
            live.overlaysPaused = true
            let resume = live.rowAction(.persona)
            live.mayPresent = false
            try check(!live.admits(resume, for: .persona), "a pending Show personas is rejected if its owner becomes busy")
            live.mayPresent = true
            let homeResume = HomePersonaControl(live)
            try check(homeResume.isAdmitted(in: live), "Home admits an unchanged enabled Show personas")
            live.mayPresent = false
            try check(!homeResume.isAdmitted(in: live), "Home rejects a rendered Show personas when its owner becomes busy")
            live.overlaysPaused = false
            let homeHide = HomePersonaControl(live)
            try check(homeHide.isAdmitted(in: live), "Home keeps Hide personas admitted while new starts are blocked")
            live = WorkbenchControlState()
            try check(!homeHide.isAdmitted(in: live), "Home never turns an ended Persona's old Hide into Show")
        }
        var saved = VoicePreferences()
        saved.dictationShortcut.keyCode = 42
        saved.readbackShortcut = VoiceShortcut(keyCode: 18, enabled: false)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        legacy.removeValue(forKey: "readingShortcut"); legacy.removeValue(forKey: "presentationShortcut")
        let migrated = try JSONDecoder().decode(VoicePreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        try check(migrated.dictationShortcut == saved.dictationShortcut && migrated.shortcut(5) == saved.shortcut(5), "adding utility shortcuts preserves existing and disabled bindings")
        try check(!VoicePreferences.shortcutIDs.contains(6) && migrated.shortcut(7) == VoicePreferences.defaultPresentationShortcut, "Read is inactive and Present keeps its presenter key")
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
        try check(ToolbarModeFollower.liveModes(dictating: false, narrating: false, drawing: false, presenting: false, persona: false, snapping: false).isEmpty, "a restored session at launch is not a start")
        try check(FloatingToolbarSurface.resolve(enabled: true, capturingScreen: true, dictation: false, narration: false) == .hidden, "capture hides controls")
        // Hide toolbar is authoritative for the tools over live Draw, Present and Persona (#155).
        func surface(shown: Bool = false, drawing: Bool = false, presenting: Bool = false, persona: Bool = false, inserting: Bool = false,
                     dictation: Bool = false, narration: Bool = false, cue: Bool = false,
                     capturing: Bool = false) -> FloatingToolbarSurface {
            .resolve(shown: shown, drawing: drawing, presenting: presenting, persona: persona, inserting: inserting,
                     capturingScreen: capturing, dictation: dictation, narration: narration, cue: cue)
        }
        try check(surface() == .hidden && surface(drawing: true) == .hidden && surface(presenting: true) == .hidden && surface(persona: true) == .hidden
                  && surface(drawing: true, presenting: true, persona: true) == .hidden, "Hide toolbar hides the tools while drawing, presenting or showing a persona")
        try check(surface(shown: true) == .tools && surface(shown: true, drawing: true, presenting: true, persona: true) == .tools,
                  "Show Floating Toolbar brings the tools back over live work")
        // Recording, narration and their results share the tools' host (#134 T4): it stays
        // up while they run even with the tools hidden, and only the no-speech cue has its own view.
        try check(surface(drawing: true, dictation: true) == .tools && surface(presenting: true, narration: true) == .tools
                  , "a live recording or narration keeps the shared host while the tools are hidden")
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
        // Words waiting for drawing to end lead the toolbar with Stop drawing, which delivers them;
        // Copy now is in More (#211 F5). The menu's rows stay with their own capability (#214):
        // Dictate waits and Draw's own row offers Stop drawing.
        do {
            var waiting = WorkbenchControlState(); waiting.phase = .delivering; waiting.waitingForDrawing = true; waiting.drawing = true
            try check(waiting.live(.dictate).dictation == .waitingForDrawing && ToolbarNextAction.resolve(waiting.live(.dictate)).operation == .finishDrawing,
                      "the toolbar leads words waiting for drawing with Stop drawing, not a disabled Processing…")
            try check(waiting.rowAction(.dictate) == .operation(.wait) && !waiting.enabled(.dictate) && waiting.actionTitle(.dictate) == "Processing…",
                      "the menu's Dictate row waits for them, disabled")
            try check(waiting.rowAction(.annotate) == .operation(.finishDrawing) && waiting.enabled(.annotate) && waiting.actionTitle(.annotate) == "Stop drawing",
                      "and Draw's own row offers Stop drawing")
            waiting.drawing = false
            try check(ToolbarNextAction.resolve(waiting.live(.dictate)).title == "Processing…" && waiting.actionTitle(.dictate) == "Processing…",
                      "once drawing has ended they are a moment's processing")
        }
        // Keyboard entry keeps the launcher row: only the pointer's own reveal shows a waiting
        // result's controls, and a row that Keep open brings back waits for the pointer and holds
        // as the kept-open swap does (#211 F1, F8).
        do {
            let suite = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench.ToolbarResultChecks." + UUID().uuidString).path
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
            kept.suspendToolbar()
            // The host's resize runs its update again from inside the return, before it has looked
            // for the pointer; that update tries the kept-open swap too.
            kept.resize = { [weak kept] in kept?.showResultIfKeptOpen() }
            kept.activateToolbar()
            kept.resize = nil
            try check(kept.toolbar.state.tier == .revealed && !kept.revealsResult,
                      "a kept-open row that comes back keeps its launcher until the host has found the pointer, even from the host's update inside the return")
            kept.toolbar.send(.pointerEntered); kept.pointerSettled(); kept.showResultIfKeptOpen()
            try check(!kept.revealsResult, "and while the pointer is on it the result waits")
            kept.focusToolbar(); kept.toolbar.send(.pointerLeft); kept.showResultIfKeptOpen()
            try check(!kept.revealsResult, "as it does while the keyboard holds the row")
            kept.unfocusToolbar(); kept.showResultIfKeptOpen()
            try check(kept.revealsResult, "once nothing is on it, the result takes the kept-open row's place")
            kept.toolbar.send(.keepOpenChanged(false))
        }
        // Persona's Appearance (#134 part B): Circle, Card and Original for the copy taken as the menu
        // opens, its current look checked; a choice changes that copy and no other.
        do {
            var looks: [Int: StageKitController.PersonaShape] = [1: .card, 2: .circle]
            let menu = ToolbarAccessoryMenus.appearance(copy: 1, current: { looks[$0] }, choose: { looks[$1] = $0 })
            try check(menu.items.map(\.title) == ["Circle", "Card", "Original"] && menu.items.map(\.state) == [.off, .on, .off],
                      "Appearance lists Circle, Card and Original with the copy's current look checked")
            let original = menu.items[2]
            _ = (original.target as AnyObject?)?.perform(original.action, with: original)
            try check(looks == [1: .original, 2: .circle], "an Appearance choice changes the copy its menu opened for, and no other")
            try check(ToolbarAccessoryMenus.appearance(copy: Int?.none, current: { _ in nil }, choose: { _, _ in }).items.isEmpty,
                      "with no copy, Appearance has nothing to change")
            // When the row has no room for Appearance it waits in More, unless Persona's own menu there
            // already holds the choice, as a shown card's and a set's Appearance do. The StageKit suite
            // checks the real Persona menus; these stand-ins check the rule around them (#216).
            func personaMenu(_ titles: [String], appearance choices: [String]?) -> NSMenu {
                let menu = NSMenu()
                titles.forEach { menu.addItem(withTitle: $0, action: nil, keyEquivalent: "") }
                if let choices {
                    let item = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: ""), submenu = NSMenu()
                    choices.forEach { submenu.addItem(withTitle: $0, action: nil, keyEquivalent: "") }
                    item.submenu = submenu; menu.addItem(item)
                }
                return menu
            }
            let hiddenCard = personaMenu(["Show Again", "End Overlay"], appearance: nil)
            let shownCard = personaMenu(["Choose Persona", "End Overlay"], appearance: ["Circle", "Card", "Original"])
            // Choices that grow or change order under Persona's Appearance never bring a second one.
            for grown in [["Card", "Circle", "Original"], ["Circle", "Card", "Original", "Outline"]] {
                try check(!ToolbarAccessoryMenus.moreNeedsAppearance(personaMenu(["Choose Persona"], appearance: grown),
                                                                      accessoryFits: false, hasCopy: true),
                          "Persona's Appearance is found by its title, whatever choices it holds: \(grown)")
            }
            try check(ToolbarAccessoryMenus.moreNeedsAppearance(hiddenCard, accessoryFits: false, hasCopy: true),
                      "a hidden card's Appearance waits in More when the row has no room for it")
            try check(!ToolbarAccessoryMenus.moreNeedsAppearance(hiddenCard, accessoryFits: true, hasCopy: true),
                      "while it fits, Appearance stays on the row and More does not repeat it")
            try check(!ToolbarAccessoryMenus.moreNeedsAppearance(shownCard, accessoryFits: false, hasCopy: true),
                      "a shown copy's Appearance in More already holds Circle, Card and Original")
            try check(!ToolbarAccessoryMenus.moreNeedsAppearance(hiddenCard, accessoryFits: false, hasCopy: false), "with no copy, More has no Appearance")
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
            let suite = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench.ToolbarPositionChecks." + UUID().uuidString).path
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
            let attached = ToolbarFreePosition(centre: CGPoint(x: 470, y: 61), growsLeftward: false,
                attachment: ToolbarEdgeAttachment(edge: .bottom, fraction: 0.3, displayID: "synthetic-display"))
            defaults.set(CapturePanelController.launcherRecord(attached), forKey: "capturePanelLauncher.v1")
            defaults.set(CapturePanelController.record(attached), forKey: "capturePanelFreePosition.v1")
            try check(saved() == (.free(attached), false), "the edge and fraction survive a restart beside the downgrade record")
            let moved = ToolbarFreePosition(glyphEdge: 300, centreY: 200, growsLeftward: false)
            defaults.set(CapturePanelController.record(moved), forKey: "capturePanelFreePosition.v1")
            try check(saved() == (.free(moved), true), "a move an earlier build made since wins over this build's older record")
            defaults.set("topRight", forKey: "capturePanelAnchor.v2")
            try check(saved() == (.docked(.topRight), false), "a dock by name wins over any free record")
            let dockFrame = NSRect(x: 1000, y: 400, width: 132, height: 36)
            defaults.set(CapturePanelController.dockDisplayRecord("synthetic-display", anchor: "topRight", frame: dockFrame),
                         forKey: "capturePanelDockDisplay.v1")
            try check(CapturePanelController.savedDockDisplay(defaults) == "synthetic-display", "a named dock retains its display through relaunch")
            defaults.set(NSStringFromPoint(NSPoint(x: 500, y: 400)), forKey: "capturePanelOrigin.v1")
            try check(CapturePanelController.savedDockDisplay(defaults) == nil, "an older build's later move wins over the named dock's saved display")
            defaults.set(NSStringFromPoint(dockFrame.origin), forKey: "capturePanelOrigin.v1")
            defaults.set("left", forKey: "capturePanelAnchor.v2")
            try check(CapturePanelController.savedDockDisplay(defaults) == nil, "an older build's changed dock wins over the display companion")
            defaults.set("topRight", forKey: "capturePanelAnchor.v2")
            defaults.set(NSStringFromSize(NSSize(width: 48, height: 28)), forKey: "capturePanelSize.v1")
            try check(CapturePanelController.savedDockDisplay(defaults) == nil, "a changed legacy frame invalidates stale display affinity")
            defaults.set(["id": "incomplete"], forKey: "capturePanelDockDisplay.v1")
            try check(CapturePanelController.savedDockDisplay(defaults) == nil, "an incomplete display companion cannot claim the dock")
        }
        var state = WorkbenchControlState()
        state.presenting = true; state.drawing = true; state.phase = .recording
        try check(state.enabled(.dictate) && state.enabled(.annotate) && state.enabled(.present),
                  "all three running activities retain their own finish controls")
        state.ready = false; state.narrating = true
        state.mayDraw = false; state.mayPresent = false
        try check(state.enabled(.dictate) && state.enabled(.annotate) && state.enabled(.present) && state.enabled(.snapAndTalk),
                  "finish actions remain available when new work is disallowed")
        state.phase = .requesting
        try check(state.enabled(.dictate) && state.actionTitle(.dictate) == "Cancel request", "microphone permission requests remain cancellable")
        state.phase = .idle; state.drawing = false; state.presenting = false; state.narrating = false
        try check(!state.enabled(.dictate) && !state.enabled(.annotate) && !state.enabled(.present) && state.enabled(.snapAndTalk),
                  "idle speech and stage starts respect availability while manual screen capture stays usable")
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
        // presentation and running timer, and while dictating leaves their own actions reachable.
        do {
            let alongside: [(String, (inout WorkbenchControlState) -> Void)] = [
                ("alone", { _ in }),
                ("beside a presentation and a running timer", { $0.presenting = true; $0.timerStarted = true; $0.timerRunning = true }),
                ("while dictating", { $0.phase = .recording })]
            let personas: [(String, (inout WorkbenchControlState) -> Void, ToolbarLiveState.Persona, String, ToolbarOperation)] = [
                ("a hidden prepared set", { $0.overlays = true; $0.overlaySession = true; $0.overlaysPaused = true }, .sessionHidden, "Show personas", .resumeOverlays),
                ("an active prepared set", { $0.overlays = true; $0.overlaySession = true }, .session, "Hide personas", .pauseOverlays),
                ("one card", { $0.overlays = true }, .shown, "Hide persona", .hidePersona),
                ("a camera waiting for its first frame", { $0.personaCamera = .starting }, .cameraStarting, "Cancel", .cancelPersonaCamera),
                ("a live camera", { $0.personaCamera = .live }, .cameraShown, "Hide Live Camera", .hidePersonaCamera),
                ("a hidden camera", { $0.personaCamera = .hidden }, .cameraHidden, "Show Live Camera again", .showPersonaCamera),
                ("a stopped camera", { $0.personaCamera = .failed }, .cameraFailed, "Try again", .retryPersonaCamera),
                ("an ended set", { _ in }, .none, "Show persona", .start(.persona))]
            for (context, setUp) in alongside {
                for (name, configure, persona, title, operation) in personas {
                    var live = WorkbenchControlState(); setUp(&live); configure(&live)
                    let home = HomePersonaControl(live)
                    try check(home.isCurrentWork == (persona != .none),
                              "Home keeps the resume or recovery row for \(name) \(context) until its visit ends")
                    let toolbar = ToolbarNextAction.resolve(ToolbarLiveState(mode: .persona, persona: persona))
                    try check(home.rowTitle == title && home.rowTitle == toolbar.title && home.operation == operation && home.isEnabled,
                              "Home's Persona control reads \(title) for \(name) \(context), as the toolbar's Persona mode does")
                }
            }
            var camera = WorkbenchControlState(); camera.personaCamera = .starting; camera.personaIdentity = UUID()
            let cancel = HomePersonaControl(camera)
            camera.personaCamera = .live
            try check(!cancel.isAdmitted(in: camera), "a rendered camera Cancel cannot turn into Hide when the first frame arrives")
            let hideCamera = HomePersonaControl(camera)
            camera.personaIdentity = UUID()
            try check(!hideCamera.isAdmitted(in: camera), "a rendered camera Hide cannot act on a replacement visit")
            camera.mayPresent = false
            try check(camera.enabled(.persona), "a live camera can always be hidden when new starts are blocked")
            camera.personaCamera = .hidden
            try check(!camera.enabled(.persona), "Show camera again respects input admission")
            camera.personaCamera = .failed
            try check(!camera.enabled(.persona), "Try again respects input admission")
            camera.mayPresent = true; camera.personaCameraMayResume = false
            try check(!camera.enabled(.persona), "restricted camera access is not retryable from another surface")
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
