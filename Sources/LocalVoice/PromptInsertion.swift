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

/// The picker has just closed when insertion starts, and the frozen field may take a
/// moment to be in front again, longer when Workbench had come forward for the
/// toolbar's keyboard focus. Typing waits for it, for about a second at most; the
/// runner still checks the field before every write.
enum PromptFieldReturn {
    static let limit: TimeInterval = 1
    static let interval: UInt64 = 20_000_000
    /// Returns whether the field came back in time.
    @MainActor static func wait(until returned: () -> Bool, limit: TimeInterval = limit, now: () -> Date = Date.init,
                                pause: () async -> Void = { try? await Task.sleep(nanoseconds: interval) }) async -> Bool {
        let deadline = now().addingTimeInterval(limit)
        while !returned() {
            guard now() < deadline, !Task.isCancelled else { return false }
            await pause()
        }
        return true
    }
}

@MainActor
final class PromptInsertion: ObservableObject {
    @Published private(set) var running = false
    private(set) var operationIdentity = UUID()
    /// The latest delivery, named by its prompt and destination (#159).
    @Published private(set) var lastAttempt: PromptAttempt?
    private var task: Task<Void, Never>?
    private var escapeMonitors: [Any] = []
    var mayInsert: () -> Bool = { true }

    func cancel() { task?.cancel() }

    func insert(_ text: String, title: String, into target: TextDelivery.Target?) {
        guard !running else { return }
        let destinationName = target?.app.localizedName ?? "Selected app"
        guard !text.isEmpty, text.count <= 50_000 else {
            lastAttempt = PromptAttempt(prompt: title, destination: destinationName,
                                        result: "Use a saved prompt between 1 and 50,000 characters. Nothing was inserted.")
            return
        }
        guard let target, let element = target.element, let value = target.value, let selection = target.selection,
              PromptInsertionPlan(value: value, selection: selection, text: text) != nil else {
            lastAttempt = PromptAttempt(prompt: title, destination: destinationName,
                                        result: "Choose a readable destination text field, then open Prompts again. Nothing was inserted.")
            return
        }
        operationIdentity = UUID()
        running = true
        lastAttempt = PromptAttempt(prompt: title, destination: destinationName, result: "Inserting…", finished: false)
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.cancel() }
        }) { escapeMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancel(); return nil
        }) { escapeMonitors.append(monitor) }
        // The picker starts insertion only after it has closed. Revalidate
        // the frozen field and selection before any write.
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                escapeMonitors.forEach(NSEvent.removeMonitor); escapeMonitors.removeAll()
                running = false; task = nil
            }
            // Escape, Stop and shortcut editing end the wait as they end insertion.
            _ = await PromptFieldReturn.wait(until: { !self.mayInsert() || TextDelivery.eligible(target) })
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
                supportsProgressive: { AccessibilityBridge.isAttributeSettable(element, kAXSelectedTextAttribute) },
                insert: { chunk in
                    // Literal text, including newlines. No Return, Tab or submit
                    // key is posted. Failed/uncertain writes are never replayed.
                    AccessibilityBridge.setAttribute(element, kAXSelectedTextAttribute, chunk as CFString) == .success
                },
                waitForConfirmation: { try await Task.sleep(nanoseconds: 45_000_000) },
                paste: { text, expected in
                    Self.describe(await TextDelivery.deliver(text, target: target, mode: .paste, restoreClipboard: true,
                                                             validateTarget: unchanged, expectedValue: expected.value,
                                                             expectedSelection: expected.selection))
                })
            let result = await PromptInsertionRunner.run(text: text, destination: destination, driver: driver)
            lastAttempt = PromptAttempt(prompt: title, destination: destinationName, result: result)
        }
    }

    /// Copy prompt: the action when a prompt cannot be typed into a field.
    /// One copy of the exact text, and the same receipt as a copied dictation.
    /// It posts no paste and writes nothing through Accessibility.
    @discardableResult
    func copy(_ text: String, title: String, receipts: ClipboardReceiptModel, system: TextDelivery.System? = nil) -> Bool {
        guard !running else { return false }
        let pasteboard = (system ?? .live).pasteboard
        guard let owned = TextDelivery.copy(text, to: pasteboard) else {
            receipts.record(outcome: .init(message: "Could not copy the prompt.", clipboardChangeCount: nil, wasPasted: false,
                                           destinationName: nil, failure: .copyFailed), wordCount: TextRules.wordCount(text), source: .prompt)
            lastAttempt = PromptAttempt(prompt: title, destination: "Clipboard", result: "Could not copy the prompt. Nothing was changed.")
            return false
        }
        receipts.record(outcome: .init(message: TextDelivery.copiedMessage, clipboardChangeCount: owned, wasPasted: false,
                                       destinationName: nil), wordCount: TextRules.wordCount(text), source: .prompt)
        lastAttempt = PromptAttempt(prompt: title, destination: "Clipboard", result: TextDelivery.copiedMessage)
        return true
    }

    /// A paste fallback's result in a prompt's words; dictation's say "transcript".
    static func describe(_ outcome: TextDelivery.Outcome) -> String {
        if outcome.wasPasted {
            return outcome.failure == .clipboardRestoreFailed
                ? "Prompt pasted once. This field does not support typing, so it was pasted, and the previous clipboard could not be restored. Nothing was submitted."
                : "Prompt pasted once. This field does not support typing, so it was pasted. Nothing was submitted."
        }
        switch outcome.failure {
        case .copyFailed: return "Could not copy the prompt for pasting. Nothing was inserted."
        case .accessibilityUnavailable: return TextDelivery.copiedMessage
        case .focusChanged, .fieldUnreadable, .pasteUnavailable: return "Copied. " + TextDelivery.copiedDetail(outcome.failure)
        case .clipboardChanged: return "The clipboard changed before pasting, so nothing was pasted."
        case .pasteUnconfirmed: return "Paste sent. Insertion could not be confirmed; check the field before trying again."
        case .cancelled:
            if outcome.pasteWasAttempted { return "Stopped after the paste was sent. Check the field; nothing was replayed." }
            return outcome.clipboardChangeCount == nil ? "Stopped before pasting. Nothing was inserted."
                : "Stopped before pasting. The prompt is copied; paste with ⌘V if you still want it."
        default: return outcome.message
        }
    }

    static func selection(_ element: AXUIElement) -> NSRange? {
        let (error, value) = AccessibilityBridge.attribute(element, kAXSelectedTextRangeAttribute)
        return error == .success ? AccessibilityBridge.range(value) : nil
    }
}
