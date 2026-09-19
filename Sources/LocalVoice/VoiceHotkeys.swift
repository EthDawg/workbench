import AppKit
import Carbon

final class VoiceHotkeys {
    private var handler: EventHandlerRef?
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var shortcuts: [UInt32: VoiceShortcut] = [:]
    private var pressed = Set<UInt32>()
    private var localMonitor: Any?
    var onKey: ((UInt32, Bool) -> Void)?
    private(set) var failures: [UInt32: String] = [:]
    init() {
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)), EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr, key.signature == 0x4C564F49 else { return OSStatus(eventNotHandledErr) }
            Unmanaged<VoiceHotkeys>.fromOpaque(context).takeUnretainedValue().dispatch(key.id, down: GetEventKind(event) == UInt32(kEventHotKeyPressed))
            return noErr
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }
    func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyUp, let id = pressed.first(where: { shortcuts[$0]?.keyCode == UInt32(event.keyCode) }) {
            dispatch(id, down: false); return nil
        }
        if let id = shortcuts.first(where: { $0.value == VoiceShortcut(event: event) })?.key {
            dispatch(id, down: event.type == .keyDown); return nil
        }
        return event
    }
    private func dispatch(_ id: UInt32, down: Bool) {
        if down { guard pressed.insert(id).inserted else { return } }
        else { guard pressed.remove(id) != nil else { return } }
        onKey?(id, down)
    }
    func register(_ preferences: VoicePreferences) {
        unregister(); failures = [:]
        for id in [UInt32(1), UInt32(2), UInt32(3), UInt32(4)] where preferences.shortcut(id).enabled {
            let shortcut = preferences.shortcut(id)
            var reference: EventHotKeyRef?
            let code = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x4C564F49, id: id), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
            if code == noErr, let reference { references[id] = reference; shortcuts[id] = shortcut }
            else { failures[id] = "\(shortcut.label) is in use. Choose a different shortcut." }
        }
    }
    func unregister() {
        for ref in references.values { UnregisterEventHotKey(ref) }
        references = [:]; shortcuts = [:]; pressed = []
    }
    deinit { unregister(); if let handler { RemoveEventHandler(handler) }; if let localMonitor { NSEvent.removeMonitor(localMonitor) } }
}
