import AppKit
import Carbon

@MainActor
enum InputChecks {
    static func run() throws {
        _ = NSApplication.shared
        let preferences = VoicePreferences()
        let keys = VoiceHotkeys(); keys.register(preferences)
        guard keys.failures.isEmpty else { throw VoiceError.message("Quit Workbench Voice before input checks: \(keys.failures)") }
        defer { keys.unregister() }
        var events: [String] = []
        keys.onKey = { events.append("\($0):\($1)") }
        func event(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags, repeatKey: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: repeatKey, keyCode: UInt16(kVK_Space))!
        }
        _ = keys.handle(event(.keyDown, modifiers: [.control, .option]))
        _ = keys.handle(event(.keyDown, modifiers: [.control, .option], repeatKey: true))
        _ = keys.handle(event(.keyUp, modifiers: []))
        guard events == ["1:true", "1:false"] else { throw VoiceError.message("Shortcut press/release or repeat handling failed: \(events)") }
        let competing = VoiceHotkeys(); competing.register(preferences)
        guard Set(competing.failures.keys) == Set<UInt32>([1, 2, 3, 4, 5]) else {
            throw VoiceError.message("Conflicts must identify all five shortcuts, including Chrome and Snap & Talk: \(competing.failures.keys.sorted())")
        }
        competing.unregister(); keys.unregister(); competing.register(preferences)
        guard competing.failures.isEmpty else { throw VoiceError.message("Shortcuts were not released") }
        competing.unregister()
        print("INPUT_CHECKS_OK: global registration, conflict reporting, key repeat, modifier-first release, and unregister")
    }
}
