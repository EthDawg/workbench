import AppKit
import Carbon
import StageKit

enum CaptureMode: String, Codable, CaseIterable { case toggle = "Toggle", hold = "Press & hold" }
enum DeliveryMode: String, Codable, CaseIterable { case paste = "Paste automatically", clipboard = "Copy to clipboard" }

struct VoiceShortcut: Codable, Equatable {
    var keyCode: UInt32 = UInt32(kVK_Space)
    var modifiers: UInt32 = UInt32(controlKey | optionKey)
    var enabled = true
    var label: String {
        guard enabled else { return "Off" }
        var label = ""
        if modifiers & UInt32(controlKey) != 0 { label += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { label += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { label += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { label += "⌘" }
        let special: [UInt32:String] = [49:"Space", 36:"↩", 53:"Esc", 51:"⌫", 123:"←", 124:"→", 125:"↓", 126:"↑", 48:"Tab", 122:"F1", 120:"F2", 99:"F3", 118:"F4", 96:"F5", 97:"F6", 98:"F7", 100:"F8", 101:"F9", 109:"F10", 103:"F11", 111:"F12"]
        if let key = special[keyCode] { return label + key }
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(), let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
            var state: UInt32 = 0; var length = 0; var chars = [UniChar](repeating: 0, count: 8)
            if UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &state, 8, &length, &chars) == noErr, length > 0 {
                return label + String(utf16CodeUnits: chars, count: length).uppercased()
            }
        }
        return label + "Key \(keyCode)"
    }
    init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(controlKey | optionKey), enabled: Bool = true) { self.keyCode = keyCode; self.modifiers = modifiers; self.enabled = enabled }
    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode); modifiers = 0
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
    }
}
struct VoicePreferences: Codable, Equatable {
    static let defaultReadbackShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_Backslash))
    static let legacyReadbackShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_R))
    // Saved resources and Switch to start off: ⌃⌥J and ⌃⌥G are Rectangle and Magnet window keys,
    // and neither is a presenter's everyday action. Each is one recording away in Keyboard.
    static let defaultLibraryShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_J), enabled: false)
    static let defaultPresenterShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_G), enabled: false)
    var cleanup = CleanupStyle.light
    var capture = CaptureMode.toggle
    var delivery = DeliveryMode.paste
    var dictationShortcut = VoiceShortcut()
    var controlsShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_V))
    // Optional decoding preserves pre-library preferences without resetting dictation.
    var libraryShortcut: VoiceShortcut? = VoicePreferences.defaultLibraryShortcut
    var presenterShortcut: VoiceShortcut? = VoicePreferences.defaultPresenterShortcut
    // Optional decoding preserves preferences written before Snap & Talk sessions existed.
    var readbackShortcut: VoiceShortcut? = VoicePreferences.defaultReadbackShortcut
    // New utility bindings are opt-in; earlier assignments remain unchanged.
    var readingShortcut: VoiceShortcut?
    var presentationShortcut: VoiceShortcut?
    var restoreClipboard = true
    func shortcut(_ id: UInt32) -> VoiceShortcut {
        switch id {
        case 6: readingShortcut ?? VoiceShortcut(enabled: false)
        case 7: presentationShortcut ?? VoiceShortcut(enabled: false)
        case 1: dictationShortcut
        case 4: presenterShortcut ?? Self.defaultPresenterShortcut
        case 3: libraryShortcut ?? Self.defaultLibraryShortcut
        case 5: readbackShortcut ?? Self.defaultReadbackShortcut
        default: controlsShortcut
        }
    }
    mutating func setShortcut(_ shortcut: VoiceShortcut, for id: UInt32) {
        switch id {
        case 6: readingShortcut = shortcut
        case 7: presentationShortcut = shortcut
        case 1: dictationShortcut = shortcut
        case 4: presenterShortcut = shortcut
        case 3: libraryShortcut = shortcut
        case 5: readbackShortcut = shortcut
        default: controlsShortcut = shortcut
        }
    }
    static let key = "voicePreferences.v2"
    static func migratingLegacyDefaults(_ preferences: VoicePreferences) -> VoicePreferences {
        var preferences = preferences
        if preferences.readbackShortcut == legacyReadbackShortcut {
            preferences.readbackShortcut = defaultReadbackShortcut
        }
        return preferences
    }
    static let shortcutRevisionKey = "voicePreferences.shortcutRevision"
    /// Runs once: turns off the 2.0.0 ⌃⌥J and ⌃⌥G defaults and returns any app command Workbench
    /// no longer takes (⌘3) to its default. Any other chosen combination is kept.
    static func movingUntouchedShortcuts(_ preferences: VoicePreferences) -> VoicePreferences {
        var preferences = preferences
        if preferences.libraryShortcut == VoiceShortcut(keyCode: UInt32(kVK_ANSI_J)) { preferences.libraryShortcut = defaultLibraryShortcut }
        if preferences.presenterShortcut == VoiceShortcut(keyCode: UInt32(kVK_ANSI_G)) { preferences.presenterShortcut = defaultPresenterShortcut }
        for id in UInt32(1)...7 where preferences.shortcut(id).enabled && !GlobalShortcutRule.allows(modifiers: preferences.shortcut(id).modifiers) {
            preferences.setShortcut(VoicePreferences().shortcut(id), for: id)
        }
        return preferences
    }
    static func load(from defaults: UserDefaults = .standard) -> VoicePreferences {
        guard let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Self.self, from: data) else {
            // Fresh settings already hold the current defaults.
            defaults.set(1, forKey: shortcutRevisionKey)
            return VoicePreferences()
        }
        var preferences = migratingLegacyDefaults(saved)
        if defaults.integer(forKey: shortcutRevisionKey) < 1 {
            // Saved once, so a shortcut someone turns back on stays on.
            preferences = movingUntouchedShortcuts(preferences)
            preferences.save(to: defaults)
            defaults.set(1, forKey: shortcutRevisionKey)
        }
        return preferences
    }
    func save(to defaults: UserDefaults = .standard) { if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) } }
}
