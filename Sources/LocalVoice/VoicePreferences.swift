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
    // Presenter keys are Option plus one key under the left hand: V Dictate, C Snap & Talk, Q Present
    // and W the Workbench menu, which lists every key. Drawing owns A, S, D, F, R, Z and X.
    static let defaultDictationShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey))
    static let defaultControlsShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(optionKey))
    static let defaultReadbackShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(optionKey))
    static let defaultPresentationShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(optionKey))
    static let legacyReadbackShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_R))
    // Saved resources and Switch to start off; ⌃⌥J and ⌃⌥G are also Rectangle and Magnet window keys.
    static let defaultLibraryShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_J), enabled: false)
    static let defaultPresenterShortcut = VoiceShortcut(keyCode: UInt32(kVK_ANSI_G), enabled: false)
    /// The 2.0.0 defaults, so an update can tell an untouched shortcut from a chosen one.
    static let legacyDefaults: [UInt32: VoiceShortcut] = [1: VoiceShortcut(), 2: VoiceShortcut(keyCode: UInt32(kVK_ANSI_V)),
        3: VoiceShortcut(keyCode: UInt32(kVK_ANSI_J)), 4: VoiceShortcut(keyCode: UInt32(kVK_ANSI_G)),
        5: VoiceShortcut(keyCode: UInt32(kVK_ANSI_Backslash)), 6: VoiceShortcut(enabled: false), 7: VoiceShortcut(enabled: false)]
    var cleanup = CleanupStyle.light
    var capture = CaptureMode.toggle
    var delivery = DeliveryMode.paste
    var dictationShortcut = VoicePreferences.defaultDictationShortcut
    var controlsShortcut = VoicePreferences.defaultControlsShortcut
    // Optional decoding preserves pre-library preferences without resetting dictation.
    var libraryShortcut: VoiceShortcut? = VoicePreferences.defaultLibraryShortcut
    var presenterShortcut: VoiceShortcut? = VoicePreferences.defaultPresenterShortcut
    // Optional decoding preserves preferences written before Snap & Talk sessions existed.
    var readbackShortcut: VoiceShortcut? = VoicePreferences.defaultReadbackShortcut
    // Read is opt-in and Present defaults to its presenter key; earlier assignments remain unchanged.
    var readingShortcut: VoiceShortcut?
    var presentationShortcut: VoiceShortcut?
    var restoreClipboard = true
    func shortcut(_ id: UInt32) -> VoiceShortcut {
        switch id {
        case 6: readingShortcut ?? VoiceShortcut(enabled: false)
        case 7: presentationShortcut ?? Self.defaultPresentationShortcut
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
    private func stored(_ id: UInt32) -> VoiceShortcut? {
        switch id {
        case 1: dictationShortcut
        case 2: controlsShortcut
        case 3: libraryShortcut
        case 4: presenterShortcut
        case 5: readbackShortcut
        case 6: readingShortcut
        default: presentationShortcut
        }
    }
    /// Runs once. Moves each shortcut still on its 2.0.0 default, or on an app command Workbench no
    /// longer takes (⌘3), to its presenter default. Any other chosen combination is kept, and a new
    /// default that would take one keeps its old combination.
    static func movingUntouchedShortcuts(_ preferences: VoicePreferences) -> VoicePreferences {
        func keys(_ shortcut: VoiceShortcut) -> [UInt32] { [shortcut.keyCode, shortcut.modifiers] }
        let ids = Array(UInt32(1)...7)
        let untouched = ids.filter { id in
            guard let saved = preferences.stored(id) else { return true }
            return saved == legacyDefaults[id] || saved.enabled && !GlobalShortcutRule.allows(modifiers: saved.modifiers)
        }
        var taken = Set(ids.filter { !untouched.contains($0) }.map { preferences.shortcut($0) }.filter(\.enabled).map(keys))
        var result = preferences
        for id in untouched {
            var next = VoicePreferences().shortcut(id)
            if next.enabled && taken.contains(keys(next)) { next = legacyDefaults[id] ?? next }
            result.setShortcut(next, for: id)
            if next.enabled { taken.insert(keys(next)) }
        }
        return result
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
