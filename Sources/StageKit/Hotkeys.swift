import AppKit
import Carbon

/// Workbench shortcuts work in every app. A combination without Control or Option (⌘T, ⇧⌘N)
/// belongs to the app in front, so Workbench never takes one.
public enum GlobalShortcutRule {
    public static func allows(modifiers: UInt32) -> Bool { modifiers & UInt32(controlKey | optionKey) != 0 }
    public static func problem(label: String, modifiers: UInt32) -> String? {
        allows(modifiers: modifiers) ? nil : "\(label) belongs to the app you're using. Choose a combination with Control or Option."
    }
}

final class HotkeyManager {
    private var handler: EventHandlerRef?
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: Action] = [:]
    private var shortcuts: [UInt32: Shortcut] = [:]
    private var localMonitor: Any?
    private var escapeRef: EventHotKeyRef?
    private var pressed = Set<UInt32>()
    var onAction: ((Action, Bool) -> Void)?
    var onEscape: (() -> Void)?
    private(set) var failures: [Action: String] = [:]
    private let signature: OSType = 0x5354474D
    init() {
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context -> OSStatus in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(context).takeUnretainedValue()
            var key = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard result == noErr, key.signature == manager.signature else { return OSStatus(eventNotHandledErr) }
            let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            if key.id == 999 { if down { manager.onEscape?() }; return noErr }
            manager.dispatch(key.id, down: down)
            return noErr
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        // Targeted app events (including events from assistive control tools) can
        // bypass the system hotkey dispatcher. Handle our own windows as well.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handleLocalEvent(event)
        }
    }
    private func dispatch(_ id: UInt32, down: Bool) {
        if down {
            guard pressed.insert(id).inserted else { return }
        } else {
            guard pressed.remove(id) != nil else { return }
        }
        if let action = actions[id] { onAction?(action, down) }
    }
    func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == UInt16(kVK_Escape), escapeRef != nil {
            if event.type == .keyDown { onEscape?() }
            return nil
        }
        if event.type == .keyUp,
           let id = pressed.first(where: { shortcuts[$0]?.keyCode == UInt32(event.keyCode) }) {
            dispatch(id, down: false); return nil
        }
        let shortcut = Shortcut(event: event)
        if let id = shortcuts.first(where: { $0.value == shortcut })?.key {
            dispatch(id, down: event.type == .keyDown); return nil
        }
        return event
    }
    func register(_ preferences: Preferences) {
        unregister()
        failures.removeAll()
        for (index, action) in Action.allCases.enumerated() {
            let shortcut = preferences.shortcut(for: action)
            guard shortcut.enabled else { continue }
            if let problem = GlobalShortcutRule.problem(label: shortcut.label, modifiers: shortcut.modifiers) { failures[action] = problem; continue }
            let id = UInt32(index + 1)
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: signature, id: id),
                                            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
            if status == noErr, let reference { registrations[id] = reference; actions[id] = action; shortcuts[id] = shortcut }
            else { failures[action] = "\(shortcut.label) is unavailable (code \(status)). Record a different shortcut." }
        }
    }
    func setEscapeEnabled(_ enabled: Bool) {
        if enabled && escapeRef == nil {
            RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: signature, id: 999), GetApplicationEventTarget(), 0, &escapeRef)
        } else if !enabled, let reference = escapeRef { UnregisterEventHotKey(reference); escapeRef = nil }
    }
    func unregister() {
        registrations.values.forEach { UnregisterEventHotKey($0) }
        registrations.removeAll(); actions.removeAll(); shortcuts.removeAll(); pressed.removeAll()
    }
    deinit {
        unregister(); if let escapeRef { UnregisterEventHotKey(escapeRef) }
        if let handler { RemoveEventHandler(handler) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
