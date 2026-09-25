import AppKit
import SwiftUI
import Carbon

enum ActivationMode: String, Codable, CaseIterable { case hold = "Press & hold", toggle = "Toggle" }
enum PointerStyle: String, Codable, CaseIterable { case ring = "Ring", disc = "Disc", laser = "Laser", spotlight = "Spotlight" }
enum PointerVisibility: String, Codable, CaseIterable { case always = "Always", moving = "While moving", clicking = "On click" }
enum IndicatorStyle: String, Codable, CaseIterable { case dot = "Dot", scaled = "Brush size", crosshair = "Crosshair", tool = "Tool icon", none = "None" }
enum BoardStyle: String, Codable { case white, black }
enum PaletteMode: String, Codable, CaseIterable { case autoHide = "Auto-hide", show = "Always show", hide = "Hidden" }

enum Action: String, CaseIterable, Codable, Identifiable {
    case pen, highlighter, arrow, line, rectangle, ellipse, text, eraser
    case clear, undo, redo, whiteboard, blackboard, pointer, fade, timer, controls, scenes
    case color1, color2, color3, color4, color5, color6
    case personaToggle, personaNext, personaPrevious
    case overlayControls, overlayNext, overlayPrevious, overlayVisibility, overlayEnd
    var id: String { rawValue }
    var tool: DrawingTool? { DrawingTool(rawValue: rawValue) }
    var title: String {
        if let tool { return tool.title }
        switch self {
        case .clear: return "Clear & return to demo"
        case .whiteboard: return "Whiteboard"
        case .blackboard: return "Blackboard"
        case .pointer: return "Cursor highlight"
        case .fade: return "Auto-fade"
        case .timer: return "Break timer"
        case .controls: return "Open drawing controls"
        case .scenes: return "Demo scenes"
        case .personaToggle: return "Show or hide one persona"
        case .personaNext: return "Next floating persona"
        case .personaPrevious: return "Previous floating persona"
        case .overlayControls: return "Focus overlay controls"
        case .overlayNext: return "Next prepared overlay set"
        case .overlayPrevious: return "Previous prepared overlay set"
        case .overlayVisibility: return "Hide or show presentation overlays"
        case .overlayEnd: return "End presentation overlays"
        case .color1, .color2, .color3, .color4, .color5, .color6:
            return InkColor.presetName(at: Int(String(rawValue.last!))! - 1) + " colour"
        default: return rawValue.capitalized
        }
    }
    /// On by default: the killer presenter keys, Option plus one key under the left hand while the
    /// right hand stays on the mouse. Home row marks (A Arrow, S Shape, D Draw, F Persona on/off),
    /// the row below fixes (Z Undo, X Clear) and R steps personas. Voice owns Q, W, C and V.
    /// Hold a mark key to draw and let go to return to the demo. Everything else starts off.
    static let presenterKeys: [Action: Int] = [.arrow: kVK_ANSI_A, .rectangle: kVK_ANSI_S, .pen: kVK_ANSI_D,
        .personaToggle: kVK_ANSI_F, .personaNext: kVK_ANSI_R, .undo: kVK_ANSI_Z, .clear: kVK_ANSI_X]
    static var presenterEssentials: Set<Action> { Set(presenterKeys.keys) }
    var defaultShortcut: Shortcut {
        // Control-letter would take Terminal's ⌃C and ⌃Z, and Control-Option letters are Rectangle
        // and Magnet window keys, so the presenter keys use Option alone.
        if let key = Self.presenterKeys[self] { return Shortcut(keyCode: UInt32(key), modifiers: UInt32(optionKey)) }
        // Shift steps back, ready for anyone who turns Previous persona on.
        if self == .personaPrevious { return Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | shiftKey), enabled: false) }
        var dormant = legacyDefaultShortcut
        dormant.enabled = false
        return dormant
    }
    /// The 2.0.0 defaults. An update moves a shortcut only while it still matches one of these.
    var legacyDefaultShortcut: Shortcut {
        let key: Int
        switch self {
        case .pen: key = kVK_ANSI_D
        case .highlighter: key = kVK_ANSI_H
        case .arrow: key = kVK_ANSI_A
        case .line: key = kVK_ANSI_L
        case .rectangle: key = kVK_ANSI_R
        case .ellipse: key = kVK_ANSI_O
        case .text: key = kVK_ANSI_T
        case .eraser: key = kVK_ANSI_E
        case .clear: key = kVK_ANSI_X
        case .undo, .redo: key = kVK_ANSI_Z
        case .whiteboard: key = kVK_ANSI_W
        case .blackboard: key = kVK_ANSI_B
        case .pointer: key = kVK_ANSI_C
        case .fade: key = kVK_ANSI_F
        case .timer: key = kVK_ANSI_K
        case .controls: key = kVK_ANSI_S
        case .scenes: key = kVK_ANSI_P
        case .color1: key = kVK_ANSI_1
        case .color2: key = kVK_ANSI_2
        case .color3: key = kVK_ANSI_3
        case .color4: key = kVK_ANSI_4
        case .color5: key = kVK_ANSI_5
        case .color6: key = kVK_ANSI_6
        case .personaToggle: key = kVK_ANSI_I
        case .personaNext: key = kVK_RightArrow
        case .personaPrevious: key = kVK_LeftArrow
        case .overlayControls: key = kVK_ANSI_I
        case .overlayNext: key = kVK_RightArrow
        case .overlayPrevious: key = kVK_LeftArrow
        case .overlayVisibility: key = kVK_ANSI_U
        case .overlayEnd: key = kVK_ANSI_J
        }
        let shifted = self == .redo || rawValue.hasPrefix("color")
        return Shortcut(keyCode: UInt32(key), modifiers: UInt32(controlKey | optionKey | (shifted ? shiftKey : 0)), enabled: !isPresentationOverlayAction)
    }
    var isPersonaAction: Bool { [.personaToggle, .personaNext, .personaPrevious].contains(self) }
    var isPresentationOverlayAction: Bool { [.overlayControls, .overlayNext, .overlayPrevious, .overlayVisibility, .overlayEnd].contains(self) }
    var isOverlayAction: Bool { isPersonaAction || isPresentationOverlayAction }
}

struct Shortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32
    var enabled = true
    var label: String {
        guard enabled else { return "Off" }
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        return prefix + Self.keyName(keyCode)
    }
    static func keyName(_ code: UInt32) -> String {
        let special: [UInt32: String] = [49:"Space", 36:"↩", 53:"Esc", 51:"⌫", 123:"←", 124:"→", 125:"↓", 126:"↑", 48:"Tab", 122:"F1", 120:"F2", 99:"F3", 118:"F4", 96:"F5", 97:"F6", 98:"F7", 100:"F8", 101:"F9", 109:"F10", 103:"F11", 111:"F12"]
        if let value = special[code] { return value }
        // Use the current keyboard layout, not an assumed US label.
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
            var state: UInt32 = 0; var length = 0; var chars = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &state, 8, &length, &chars)
            if status == noErr && length > 0 { return String(utf16CodeUnits: chars, count: length).uppercased() }
        }
        return "Key \(code)"
    }
    init(keyCode: UInt32, modifiers: UInt32, enabled: Bool = true) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.enabled = enabled
    }
    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode); modifiers = 0
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
    }
}

struct PointerAppearance: Codable, Equatable {
    var radius: Double = 26
    var opacity: Double = 0.75
    var color: InkColor = .amber
}

struct Preferences: Codable, Equatable {
    var activation = ActivationMode.hold
    var color = InkColor.coral
    var lineWidth: Double = 4
    var highlighterWidth: Double = 22
    var fontSize: Double = 32
    var penPressure = true
    var indicator = IndicatorStyle.crosshair
    var autoFade = false
    var fadeDelay: Double = 3
    var pointerStyle = PointerStyle.ring
    var pointerVisibility = PointerVisibility.always
    var pointerAppearances: [String: PointerAppearance] = [
        "Ring": .init(), "Disc": .init(radius: 28, opacity: 0.25),
        "Laser": .init(radius: 9, opacity: 0.9, color: .coral),
        "Spotlight": .init(radius: 110, opacity: 0.6, color: .black)
    ]
    var clickRipple = true
    var idleDelay: Double = 1.5
    var separateBoards = true
    var boardPalette = PaletteMode.autoHide
    var showDrawingPalette = false
    var timerMinutes: Double = 5
    var timerMessage = "Back in a moment"
    var timerChime = true
    var timerOpacity: Double = 0.96
    var timerColor = InkColor.white
    var timerBackground = InkColor(0.055, 0.07, 0.11)
    var shortcuts = Dictionary(uniqueKeysWithValues: Action.allCases.map { ($0.rawValue, $0.defaultShortcut) })
    var onboardingComplete = false
    var pointerAppearance: PointerAppearance { pointerAppearances[pointerStyle.rawValue] ?? .init() }
    func shortcut(for action: Action) -> Shortcut { shortcuts[action.rawValue] ?? action.defaultShortcut }
    mutating func validate() {
        lineWidth = min(20, max(1, lineWidth.isFinite ? lineWidth : 4))
        highlighterWidth = min(60, max(8, highlighterWidth.isFinite ? highlighterWidth : 22))
        fontSize = min(144, max(12, fontSize.isFinite ? fontSize : 32))
        fadeDelay = min(30, max(0.5, fadeDelay.isFinite ? fadeDelay : 3))
        timerMinutes = min(180, max(0.1, timerMinutes.isFinite ? timerMinutes : 5))
        timerOpacity = min(1, max(0.2, timerOpacity))
        for style in PointerStyle.allCases {
            var appearance = pointerAppearances[style.rawValue] ?? .init()
            appearance.radius = min(240, max(4, appearance.radius))
            appearance.opacity = min(1, max(0.05, appearance.opacity))
            pointerAppearances[style.rawValue] = appearance
        }
    }
}

final class SettingsStore: ObservableObject {
    @Published var value: Preferences {
        didSet {
            var checked = value; checked.validate()
            if checked != value { value = checked; return }
            save(); onChange?()
        }
    }
    @Published var notice: String?
    var onChange: (() -> Void)?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedData = defaults.data(forKey: "preferences.v1")
        var decoded = false
        if let data = savedData {
            do { value = try JSONDecoder().decode(Preferences.self, from: data); value.validate(); decoded = true }
            catch { value = Preferences(); notice = "Saved settings could not be read. Defaults are in use; the original settings have been preserved."; defaults.set(data, forKey: "preferences.recovery") }
        } else { value = Preferences() }
        if defaults.integer(forKey: "preferences.schema") < 2 {
            var migrated = value
            for action in Action.allCases where action.rawValue.hasPrefix("color") {
                let old = Shortcut(keyCode: action.legacyDefaultShortcut.keyCode, modifiers: UInt32(controlKey | optionKey))
                if migrated.shortcut(for: action) == old { migrated.shortcuts[action.rawValue] = action.legacyDefaultShortcut }
            }
            value = migrated
            defaults.set(2, forKey: "preferences.schema")
        }
        if savedData != nil, defaults.integer(forKey: "preferences.schema") < 3 {
            var migrated = value
            for action in [Action.personaToggle, .personaPrevious, .personaNext] where migrated.shortcuts[action.rawValue] == nil {
                let candidate = action.legacyDefaultShortcut
                let collides = migrated.shortcuts.values.contains {
                    $0.enabled && $0.keyCode == candidate.keyCode && $0.modifiers == candidate.modifiers
                }
                if collides {
                    var disabled = candidate; disabled.enabled = false
                    migrated.shortcuts[action.rawValue] = disabled
                }
            }
            value = migrated
            defaults.set(3, forKey: "preferences.schema")
        }
        if defaults.integer(forKey: "preferences.schema") < 4 {
            // Fresh and unreadable settings already hold the current defaults. Observers do not run
            // during init, so the move is saved here rather than recomputed on every launch.
            if decoded { value = Self.movingUntouchedShortcuts(value); save() }
            defaults.set(4, forKey: "preferences.schema")
        }
    }
    /// Moves each shortcut still on its 2.0.0 default, or on an app command Workbench no longer
    /// takes (⌘S, ⌘W), to its presenter-first default. Any other chosen combination always wins:
    /// a new default that would take one keeps its old combination.
    static func movingUntouchedShortcuts(_ preferences: Preferences) -> Preferences {
        func keys(_ shortcut: Shortcut) -> [UInt32] { [shortcut.keyCode, shortcut.modifiers] }
        let untouched = Action.allCases.filter { action in
            guard let saved = preferences.shortcuts[action.rawValue] else { return true }
            return saved == action.legacyDefaultShortcut || saved.enabled && !GlobalShortcutRule.allows(modifiers: saved.modifiers)
        }
        var taken = Set(Action.allCases.filter { !untouched.contains($0) }
            .map { preferences.shortcut(for: $0) }.filter(\.enabled).map(keys))
        var result = preferences
        for action in untouched {
            var next = action.defaultShortcut
            if next.enabled && taken.contains(keys(next)) { next = action.legacyDefaultShortcut }
            result.shortcuts[action.rawValue] = next
            if next.enabled { taken.insert(keys(next)) }
        }
        return result
    }
    private func save() {
        do { defaults.set(try JSONEncoder().encode(value), forKey: "preferences.v1") }
        catch { notice = "Your settings could not be saved: \(error.localizedDescription)" }
    }
    func setPointer(_ transform: (inout PointerAppearance) -> Void) {
        var appearance = value.pointerAppearance; transform(&appearance)
        value.pointerAppearances[value.pointerStyle.rawValue] = appearance
    }
}

struct BoardArchive: Codable {
    var version = 1
    var displays: [String: [Annotation]] = [:]
}

enum BoardStorage {
    static func load(from url: URL) throws -> BoardArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return BoardArchive() }
        let archive = try JSONDecoder().decode(BoardArchive.self, from: Data(contentsOf: url))
        guard archive.version == 1 else { throw CocoaError(.fileReadUnknown) }
        return archive
    }
    static func save(_ archive: BoardArchive, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(archive).write(to: url, options: .atomic)
    }
}
