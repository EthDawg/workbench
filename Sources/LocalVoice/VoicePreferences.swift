import AppKit
import Carbon

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
    var cleanup = CleanupStyle.light
    var capture = CaptureMode.toggle
    var delivery = DeliveryMode.paste
    var dictationShortcut = VoiceShortcut()
    var controlsShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_V))
    // Optional decoding preserves pre-library preferences without resetting dictation.
    var libraryShortcut: VoiceShortcut? = VoiceShortcut(keyCode: UInt32(kVK_ANSI_J))
    // Optional decoding preserves preferences written before Snap & Talk sessions existed.
    var readbackShortcut: VoiceShortcut? = VoicePreferences.defaultReadbackShortcut
    var restoreClipboard = true
    func shortcut(_ id: UInt32) -> VoiceShortcut {
        switch id {
        case 1: dictationShortcut
        case 3: libraryShortcut ?? VoiceShortcut(keyCode: UInt32(kVK_ANSI_J))
        case 4: readbackShortcut ?? Self.defaultReadbackShortcut
        default: controlsShortcut
        }
    }
    mutating func setShortcut(_ shortcut: VoiceShortcut, for id: UInt32) {
        switch id {
        case 1: dictationShortcut = shortcut
        case 3: libraryShortcut = shortcut
        case 4: readbackShortcut = shortcut
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
    static func load() -> VoicePreferences {
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode(Self.self, from: data) { return migratingLegacyDefaults(saved) }
        return VoicePreferences()
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) } }
}
