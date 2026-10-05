import AppKit
import Carbon

@MainActor
enum InputChecks {
    static func run() throws {
        _ = NSApplication.shared
        // The check registers its own keys, ⌃⌥⇧F13 to F20, one per shortcut, so it proves global
        // registration, conflict reporting and release on the packaged app without depending on
        // which Workbench edition is running and holding the person's shortcuts.
        var preferences = VoicePreferences()
        for (index, id) in VoicePreferences.shortcutIDs.enumerated() {
            let keyCodes = [kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
            preferences.setShortcut(VoiceShortcut(keyCode: UInt32(keyCodes[index % keyCodes.count]),
                                                  modifiers: UInt32(controlKey | optionKey | shiftKey), enabled: true), for: id)
        }
        let keys = VoiceHotkeys(); keys.register(preferences)
        guard keys.failures.isEmpty else { throw VoiceError.message("Another process holds the input check's keys (⌃⌥⇧F13 to F20): \(keys.failures)") }
        defer { keys.unregister() }
        var events: [String] = []
        var times: [TimeInterval] = []
        keys.onKey = { events.append("\($0):\($1)"); times.append($2) }
        let dictation = preferences.shortcut(1)
        var modifiers: NSEvent.ModifierFlags = []
        let modifierMapping: [(Int, NSEvent.ModifierFlags)] = [
            (controlKey, .control), (optionKey, .option), (shiftKey, .shift), (cmdKey, .command)
        ]
        for (carbon, flag) in modifierMapping where dictation.modifiers & UInt32(carbon) != 0 { modifiers.insert(flag) }
        func event(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags, repeatKey: Bool = false, at time: TimeInterval) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: time, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: UInt16(dictation.keyCode))!
        }
        _ = keys.handle(event(.keyDown, modifiers: modifiers, at: 100))
        _ = keys.handle(event(.keyDown, modifiers: modifiers, repeatKey: true, at: 100.2))
        _ = keys.handle(event(.keyUp, modifiers: [], at: 100.3))
        guard events == ["1:true", "1:false"] else { throw VoiceError.message("Shortcut press/release or repeat handling failed: \(events)") }
        // The hold is timed by the key events themselves; a repeat never moves the press (#134 T5).
        guard times == [100, 100.3] else { throw VoiceError.message("Shortcut events must carry their own timestamps, keeping the first press: \(times)") }
        let competing = VoiceHotkeys(); competing.register(preferences)
        defer { competing.unregister() }
        let enabled = Set(VoicePreferences.shortcutIDs.filter { preferences.shortcut($0).enabled })
        guard Set(competing.failures.keys) == enabled else {
            throw VoiceError.message("Conflicts must identify every enabled shortcut: expected \(enabled.sorted()), got \(competing.failures.keys.sorted())")
        }
        competing.unregister(); keys.unregister(); competing.register(preferences)
        guard competing.failures.isEmpty else { throw VoiceError.message("Shortcuts were not released") }
        competing.unregister()
        print("INPUT_CHECKS_OK: global registration, conflict reporting, key repeat, modifier-first release, and unregister")
    }
}
