import AppKit
import Carbon

@MainActor
enum InputChecks {
    static func run() throws {
        _ = NSApplication.shared
        let preferences = VoicePreferences()
        let keys = VoiceHotkeys(); keys.register(preferences)
        guard keys.failures.isEmpty else { throw VoiceError.message("Quit all Workbench editions before input checks: \(keys.failures)") }
        defer { keys.unregister() }
        var events: [String] = []
        keys.onKey = { events.append("\($0):\($1)") }
        let dictation = preferences.shortcut(1)
        var modifiers: NSEvent.ModifierFlags = []
        let modifierMapping: [(Int, NSEvent.ModifierFlags)] = [
            (controlKey, .control), (optionKey, .option), (shiftKey, .shift), (cmdKey, .command)
        ]
        for (carbon, flag) in modifierMapping where dictation.modifiers & UInt32(carbon) != 0 { modifiers.insert(flag) }
        func event(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags, repeatKey: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: UInt16(dictation.keyCode))!
        }
        _ = keys.handle(event(.keyDown, modifiers: modifiers))
        _ = keys.handle(event(.keyDown, modifiers: modifiers, repeatKey: true))
        _ = keys.handle(event(.keyUp, modifiers: []))
        guard events == ["1:true", "1:false"] else { throw VoiceError.message("Shortcut press/release or repeat handling failed: \(events)") }
        let competing = VoiceHotkeys(); competing.register(preferences)
        defer { competing.unregister() }
        let enabled = Set((UInt32(1)...7).filter { preferences.shortcut($0).enabled })
        guard Set(competing.failures.keys) == enabled else {
            throw VoiceError.message("Conflicts must identify every enabled shortcut: expected \(enabled.sorted()), got \(competing.failures.keys.sorted())")
        }
        competing.unregister(); keys.unregister(); competing.register(preferences)
        guard competing.failures.isEmpty else { throw VoiceError.message("Shortcuts were not released") }
        competing.unregister()
        print("INPUT_CHECKS_OK: global registration, conflict reporting, key repeat, modifier-first release, and unregister")
    }
}
