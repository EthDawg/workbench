import AppKit
import Carbon

@MainActor
enum KeyboardCoachChecks {
    static func run() throws {
        _ = NSApplication.shared
        let target = VoiceShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
        let other = VoiceShortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey))
        let entries = [ShortcutEntry(id: "voice.dictation", title: "Dictation", shortcut: target), ShortcutEntry(id: "stage.draw", title: "Draw", shortcut: other)]
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw VoiceError.message("Keyboard coach: \(message)") }
        }
        try check(ShortcutConflict.message(for: target, replacing: "voice.dictation", in: entries) == nil, "the legacy default must remain available")
        try check(ShortcutConflict.message(for: other, replacing: "voice.dictation", in: entries)?.contains("Draw") == true, "cross-module duplicate must name its owner")
        var disabled = other; disabled.enabled = false
        try check(ShortcutConflict.message(for: disabled, replacing: "voice.dictation", in: entries) == nil, "turning off a shortcut cannot conflict")
        let disabledEntry = [entries[0], ShortcutEntry(id: "stage.draw", title: "Draw", shortcut: disabled)]
        try check(ShortcutConflict.message(for: other, replacing: "voice.dictation", in: disabledEntry) == nil, "disabled actions must release their combination")
        try check(ShortcutConflict.message(for: VoiceShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey)), replacing: "voice.dictation", in: entries) != nil, "ordinary shifted typing must stay available")
        for (key, modifiers) in [(kVK_Space, cmdKey), (kVK_Tab, cmdKey), (kVK_ANSI_Q, controlKey | cmdKey), (kVK_ANSI_4, shiftKey | cmdKey), (kVK_LeftArrow, controlKey), (kVK_ANSI_Q, cmdKey), (kVK_ANSI_Z, cmdKey | shiftKey)] {
            try check(ShortcutConflict.message(for: VoiceShortcut(keyCode: UInt32(key), modifiers: UInt32(modifiers)), replacing: "voice.dictation", in: entries) != nil, "common Mac command must stay available: \(key), \(modifiers)")
        }
        // Any chord without Control or Option is an app command somewhere, not only the familiar ones.
        for (key, modifiers) in [(kVK_ANSI_T, cmdKey), (kVK_ANSI_R, cmdKey), (kVK_ANSI_1, cmdKey), (kVK_ANSI_N, cmdKey | shiftKey)] {
            try check(ShortcutConflict.message(for: VoiceShortcut(keyCode: UInt32(key), modifiers: UInt32(modifiers)), replacing: "voice.dictation", in: entries)?.contains("Control or Option") == true, "app command must stay with the app: \(key), \(modifiers)")
        }
        try check(ShortcutConflict.message(for: VoiceShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | cmdKey)), replacing: "voice.dictation", in: entries) == nil, "Control makes a Command chord a Workbench key")
        try checkPresenterFirstVoiceDefaults()

        var practice = ShortcutPracticeState(target: target)
        practice.keyUp(target.keyCode)
        try check(practice.completed == 0, "release without a matching press must not count")
        practice.keyDown(target.keyCode, modifiers: UInt32(controlKey), isRepeat: false)
        practice.keyUp(target.keyCode)
        try check(practice.completed == 0 && practice.feedback == .retry, "partial modifier combination must not count")
        practice.keyDown(target.keyCode, modifiers: target.modifiers, isRepeat: true)
        practice.keyUp(target.keyCode)
        try check(practice.completed == 0, "orphan auto-repeat must not count")
        for expected in 1...3 {
            practice.keyDown(target.keyCode, modifiers: target.modifiers, isRepeat: false)
            practice.keyDown(target.keyCode, modifiers: target.modifiers, isRepeat: true)
            practice.keyUp(UInt32(kVK_ANSI_X))
            try check(practice.completed == expected - 1, "repeat or unrelated release must not count")
            practice.keyUp(target.keyCode)
            try check(practice.completed == expected, "complete press and release must count exactly once")
            practice.keyUp(target.keyCode)
            try check(practice.completed == expected, "duplicate release must not count")
        }
        try check(practice.isComplete && practice.feedback == .complete, "three completed repetitions must finish practice")
        practice.keyDown(target.keyCode, modifiers: target.modifiers, isRepeat: false)
        practice.keyUp(target.keyCode)
        try check(practice.completed == 3, "completion must be bounded")
        var disabledPractice = ShortcutPracticeState(target: disabled)
        disabledPractice.keyDown(disabled.keyCode, modifiers: disabled.modifiers, isRepeat: false); disabledPractice.keyUp(disabled.keyCode)
        try check(disabledPractice.completed == 0, "disabled shortcuts must not be practiced")

        var updates: [(String, VoiceShortcut)] = []
        var suspensions: [Bool] = []
        var probeFailure: String? = "Registered elsewhere."
        var updateFailure: String?
        let model = KeyboardCoachModel(entries: entries, update: { id, candidate in
            guard updateFailure == nil else { return updateFailure }
            updates.append((id, candidate)); return nil
        }, suspend: { suspensions.append($0) }, probe: { _ in probeFailure })
        func event(_ type: NSEvent.EventType, shortcut: VoiceShortcut, repeatKey: Bool = false, releaseModifiers: Bool = false) -> NSEvent {
            var flags: NSEvent.ModifierFlags = []
            if !releaseModifiers {
                if shortcut.modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
                if shortcut.modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
                if shortcut.modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
                if shortcut.modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
            }
            return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: UInt16(shortcut.keyCode))!
        }
        let candidate = VoiceShortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(controlKey | optionKey))
        model.beginRecording()
        try check(model.handle(event(.keyDown, shortcut: candidate)) == nil, "recording must consume its event")
        try check(model.selected?.shortcut == target && updates.isEmpty && model.hasError, "failed global probe must preserve the previous shortcut")
        probeFailure = nil; updateFailure = "Registration changed during the save."
        _ = model.handle(event(.keyDown, shortcut: candidate))
        try check(model.selected?.shortcut == target && updates.isEmpty, "failed transactional update must preserve the previous shortcut")
        updateFailure = nil
        _ = model.handle(event(.keyDown, shortcut: candidate))
        try check(model.selected?.shortcut == candidate && updates.count == 1 && !model.isInteracting, "successful edit must save once and restore actions")
        try check(suspensions == [true, false], "recording suspension must be balanced")

        model.beginPractice()
        for _ in 0..<3 {
            try check(model.handle(event(.keyDown, shortcut: candidate)) == nil, "practice must consume matching key-down")
            try check(model.handle(event(.keyUp, shortcut: candidate, releaseModifiers: true)) == nil, "practice must consume key-up after modifiers release")
        }
        try check(model.practice?.completed == 3 && !model.isInteracting, "practice must finish after three genuine complete presses")
        try check(updates.count == 1, "practice must never mutate a shortcut or execute an app action")
        try check(suspensions == [true, false, true, false], "practice completion must restore global actions")
        model.beginPractice(); model.stopInteraction(); model.stopInteraction()
        try check(suspensions.suffix(2) == [true, false], "cancel or deactivation must restore exactly once")
        model.beginRecording(); model.selectedID = "stage.draw"
        try check(!model.isInteracting && suspensions.suffix(2) == [true, false], "changing the selected action must stop recording")
        model.disableSelected()
        try check(model.selected?.shortcut.enabled == false && updates.count == 2 && suspensions.suffix(2) == [true, false], "disable must preserve the action and balance suspension")
        model.beginPractice()
        try check(!model.isInteracting, "disabled action must not start practice")
        model.selectedID = "voice.dictation"; model.beginRecording()
        let escape = VoiceShortcut(keyCode: UInt32(kVK_Escape), modifiers: 0)
        try check(model.handle(event(.keyDown, shortcut: escape)) == nil && !model.isInteracting, "Escape must consume and cancel recording")
        try check(model.handle(event(.keyDown, shortcut: candidate)) != nil, "inactive coach must leave ordinary app controls alone")
        print("KEYBOARD_COACH_CHECKS_OK: cross-module conflicts, native controls, transactional failure, complete press/release practice, event consumption and balanced suspension")
    }
    /// Saved resources (⌃⌥J) and Switch to (⌃⌥G) start off; an update turns off untouched ones once.
    static func checkPresenterFirstVoiceDefaults() throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw VoiceError.message("Shortcut defaults: \(message)") }
        }
        let fresh = VoicePreferences()
        try check([UInt32(1), 2, 5].allSatisfy { fresh.shortcut($0).enabled } && ![UInt32(3), 4].contains { fresh.shortcut($0).enabled }, "only Dictate, Quick controls and Snap & Talk start on")
        let suite = "WorkbenchShortcutChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var previous = VoicePreferences()
        previous.dictationShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey))
        previous.libraryShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_J))
        let chosen = VoiceShortcut(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(controlKey | optionKey | cmdKey))
        previous.presenterShortcut = chosen
        previous.save(to: defaults)
        let updated = VoicePreferences.load(from: defaults)
        try check(!updated.shortcut(3).enabled, "an untouched ⌃⌥J turns off")
        try check(updated.shortcut(1) == VoicePreferences().dictationShortcut, "Dictate leaves ⌘3 to other apps and returns to ⌃⌥Space")
        try check(updated.shortcut(4) == chosen, "a chosen combination is kept")
        var turnedBackOn = updated
        turnedBackOn.libraryShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_J))
        turnedBackOn.save(to: defaults)
        try check(VoicePreferences.load(from: defaults).shortcut(3).enabled, "turning ⌃⌥J back on sticks after relaunch")

        var commandOnly = VoicePreferences()
        commandOnly.dictationShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey))
        commandOnly.controlsShortcut.enabled = false
        commandOnly.readbackShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_Backslash), enabled: false)
        let keys = VoiceHotkeys()
        keys.register(commandOnly)
        try check(keys.failures[1]?.contains("Control or Option") == true, "⌘T is never registered as a global shortcut")
        keys.unregister()
    }
}
