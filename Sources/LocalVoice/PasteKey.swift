import Carbon
import CoreGraphics

/// The key that types “v” while ⌘ is held in the current keyboard layout, so automatic paste
/// sends ⌘V on Dvorak, Dvorak Right-Handed, Turkish F and every other layout, not the US key
/// position. Only the key code is chosen: setting the event's text stops AppKit's Paste menu
/// item firing, and the receiving app translates the key with its own layout.
enum PasteKey {
    /// The US “V”, used when a layout's data can't be read.
    static let fallback: CGKeyCode = 9

    /// Nil when the layout has no key that types “v” with ⌘ (Turkmen): paste can't start, so the
    /// words are copied, never sent as some other shortcut.
    static func current() -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return fallback }
        return keyCode(in: source)
    }
    static func currentLayoutID() -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String
    }
    /// Reads the layout's own data; it never selects or changes an input source.
    static func keyCode(in source: TISInputSource) -> CGKeyCode? {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return fallback }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        // Key equivalents match the characters typed with ⌘ held, which is how Dvorak – QWERTY ⌘
        // switches to QWERTY for shortcuts. The US position wins a tie, so nothing changes there.
        if typed(layout, fallback) == "v" { return fallback }
        return (0..<128).lazy.map { CGKeyCode($0) }.first { typed(layout, $0) == "v" }
    }
    private static func typed(_ layout: UnsafePointer<UCKeyboardLayout>, _ key: CGKeyCode) -> String? {
        var dead: UInt32 = 0, length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown), UInt32(cmdKey >> 8) & 0xFF, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, characters.count, &length, &characters)
        return status == noErr && length > 0 ? String(utf16CodeUnits: characters, count: length).lowercased() : nil
    }
}
