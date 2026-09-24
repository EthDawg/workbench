import AppKit

/// UTF-16 is the Accessibility selection coordinate space; chunks end only at
/// Character boundaries, so emoji, combining marks and multiline text survive.
struct PromptInsertionPlan {
    private(set) var expectedValue: String
    private(set) var selection: NSRange
    private(set) var remaining: Substring
    private(set) var insertedCharacters = 0
    init?(value: String, selection: NSRange, text: String) {
        guard selection.location != NSNotFound, Range(selection, in: value) != nil,
              !text.isEmpty, text.count <= 50_000 else { return nil }
        expectedValue = value; self.selection = selection; remaining = text[...]
    }
    var nextChunk: String { String(remaining.prefix(2)) }
    mutating func acknowledge(_ chunk: String) {
        guard !chunk.isEmpty, remaining.hasPrefix(chunk), let range = Range(selection, in: expectedValue) else { return }
        expectedValue.replaceSubrange(range, with: chunk)
        selection = NSRange(location: selection.location + chunk.utf16.count, length: 0)
        remaining = remaining.dropFirst(chunk.count); insertedCharacters += chunk.count
    }
    func matches(value: String?, selection: NSRange?) -> Bool {
        value == expectedValue && selection == self.selection
    }
}

@MainActor
final class PromptInsertion: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = ""
    private var task: Task<Void, Never>?
    private var escapeMonitors: [Any] = []
    var mayInsert: () -> Bool = { true }

    func cancel() { task?.cancel() }

    func insert(_ text: String, into target: TextDelivery.Target?) {
        guard !running else { return }
        guard !text.isEmpty, text.count <= 50_000 else {
            status = "Use a saved prompt between 1 and 50,000 characters. Nothing was inserted."
            return
        }
        guard let target, let element = target.element, let value = target.value, let selection = target.selection,
              PromptInsertionPlan(value: value, selection: selection, text: text) != nil else {
            status = "Choose a readable destination text field, then open Prompts again. Nothing was inserted."
            return
        }
        let destinationName = target.app.localizedName ?? "Selected app"
        running = true; status = "Inserting Prompt into \(destinationName)…"
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.cancel() }
        }) { escapeMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancel(); return nil
        }) { escapeMonitors.append(monitor) }
        // The menu owner starts insertion only after NSMenu.popUp returns.
        // Revalidate the frozen field and selection before any write.
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                escapeMonitors.forEach(NSEvent.removeMonitor); escapeMonitors.removeAll()
                running = false; task = nil
            }
            let destination = PromptInsertionRunner.Snapshot(value: value, selection: selection)
            @MainActor func unchanged() -> Bool {
                !Task.isCancelled && mayInsert() && TextDelivery.eligible(target)
                    && TextDelivery.string(element, kAXValueAttribute) == value
                    && Self.selection(element) == selection
            }
            let driver = PromptInsertionRunner.Driver(
                cancelled: { Task.isCancelled }, permitted: { self.mayInsert() },
                snapshot: {
                    guard TextDelivery.eligible(target), let value = TextDelivery.string(element, kAXValueAttribute),
                          let selection = Self.selection(element) else { return nil }
                    return .init(value: value, selection: selection)
                },
                supportsProgressive: {
                    var settable = DarwinBoolean(false)
                    return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
                },
                insert: { chunk in
                    // Literal text, including newlines. No Return, Tab or submit
                    // key is posted. Failed/uncertain writes are never replayed.
                    AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, chunk as CFString) == .success
                },
                waitForConfirmation: { try await Task.sleep(nanoseconds: 45_000_000) },
                paste: { text, expected in
                    let result = await TextDelivery.deliver(text, target: target, mode: .paste, restoreClipboard: true,
                                                          validateTarget: unchanged, expectedValue: expected.value, expectedSelection: expected.selection)
                    return result.wasPasted ? "Prompt pasted. This field does not support progressive insertion." : result.message
                })
            let result = await PromptInsertionRunner.run(text: text, destination: destination, driver: driver)
            status = "\(destinationName) · \(result)"
        }
    }

    static func selection(_ element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(ax) == .cfRange, AXValueGetValue(ax, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}

@MainActor
enum SavedPromptMenu {
    static func make(library: DemoLibraryModel, delivery: PromptInsertion, target: TextDelivery.Target?,
                     afterTracking: @escaping (@escaping () -> Void) -> Void, prepare: @escaping () -> Void = {}) -> NSMenu {
        let menu = NSMenu(title: "Saved Prompts"); menu.autoenablesItems = false
        // Freeze order, content and destination for this open menu. The library
        // still owns records, favourites and both tags; nothing is copied to a
        // second store and no shortcut collection is registered.
        let prompts = DemoResource.matching(library.resources.filter { $0.kind == .prompt && !$0.content.isEmpty }, query: "")
        func item(_ prompt: DemoResource) -> NSMenuItem {
            ToolbarMenuAction(prompt.title, enabled: !delivery.running) {
                afterTracking { prepare(); delivery.insert(prompt.content, into: target) }
            }
        }
        if prompts.isEmpty { menu.addItem(ToolbarMenuAction("Save a prompt in Saved Resources first.", enabled: false) {}) }
        else {
            menu.addItem(ToolbarMenuAction("Insert into the selected field · never submits", enabled: false) {})
            menu.addItem(ToolbarMenuAction("Types progressively when supported; otherwise pastes once", enabled: false) {})
            let favourites = prompts.filter(\.favorite)
            for prompt in (favourites.isEmpty ? Array(prompts.prefix(8)) : Array(favourites.prefix(8))) { menu.addItem(item(prompt)) }
            menu.addItem(.separator())
            for (title, key) in [("By Product", \DemoResource.product), ("By Persona", \DemoResource.persona)] {
                let tags = Set(prompts.map { $0[keyPath: key] }.filter { !$0.isEmpty }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                if !tags.isEmpty {
                    let tagged = NSMenu(); tagged.autoenablesItems = false
                    for tag in tags {
                        let group = NSMenuItem(title: tag, action: nil, keyEquivalent: "")
                        let list = NSMenu(); list.autoenablesItems = false
                        prompts.filter { $0[keyPath: key] == tag }.forEach { list.addItem(item($0)) }
                        group.submenu = list; tagged.addItem(group)
                    }
                    let group = NSMenuItem(title: title, action: nil, keyEquivalent: ""); group.submenu = tagged; menu.addItem(group)
                }
            }
            let all = NSMenuItem(title: "All Prompts", action: nil, keyEquivalent: "")
            let list = NSMenu(); list.autoenablesItems = false; prompts.forEach { list.addItem(item($0)) }
            all.submenu = list; menu.addItem(all)
        }
        if !delivery.status.isEmpty { menu.addItem(.separator()); menu.addItem(ToolbarMenuAction(delivery.status, enabled: false) {}) }
        if delivery.running { menu.addItem(ToolbarMenuAction("Stop Inserting") { delivery.cancel() }) }
        return menu
    }
}
