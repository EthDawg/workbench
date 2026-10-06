import AppKit
import ToolbarCore
import ToolbarKit

/// The Saved Prompts picker without a window (#159): its frozen list, width
/// and placement, keyboard model, and what a choice does. Copy prompt runs on an
/// isolated pasteboard with injected trust and a paste recorder, so these
/// checks never read or change the person's clipboard or Accessibility approval.
@MainActor
enum PromptPickerChecks {
    static func run() throws {
        var passed = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("PROMPT PICKER CHECK FAILED: " + name) }
            passed += 1
        }
        let now = Date(timeIntervalSince1970: 1_789_546_320)
        func prompt(_ title: String, favourite: Bool = false, product: String = "", persona: String = "",
                    content: String? = nil, age: TimeInterval = 0) -> DemoResource {
            DemoResource(kind: .prompt, title: title, product: product, persona: persona,
                         content: content ?? "Synthetic prompt: \(title)", favorite: favourite, modified: now.addingTimeInterval(-age))
        }

        // The list: one place per prompt, favourites first, no submenus.
        let empty = PromptPickerList(resources: [DemoResource(kind: .link, title: "Demo site", content: "https://example.com")])
        try check(empty.prompts.isEmpty && empty.rows.isEmpty && !empty.hasFilters, "links and files never appear; an empty library shows no rows")
        let one = PromptPickerList(resources: [prompt("Welcome")])
        try check(one.rows.map(\.pickerTitle) == ["Welcome"] && one.favourites.isEmpty && !one.hasFilters,
                  "a single prompt is one row with no category filter")
        let library = [prompt("Recap", age: 10), prompt("Pricing", favourite: true, product: "Acme", age: 30),
                       prompt("Onboarding", product: "Acme", persona: "Manager", age: 20),
                       prompt("Escalation", favourite: true, persona: "HR Admin", age: 5),
                       prompt("Empty", content: ""), prompt("Security", persona: "Manager", age: 40)]
        var list = PromptPickerList(resources: library)
        try check(list.rows.map(\.pickerTitle) == ["Escalation", "Pricing", "Recap", "Onboarding", "Security"],
                  "favourites come first, then the rest, each newest first")
        try check(Set(list.rows.map(\.id)).count == list.rows.count && list.rows.count == list.favourites.count + list.others.count,
                  "every prompt has exactly one list position")
        try check(list.products == ["Acme"] && list.personas == ["HR Admin", "Manager"], "the categories are the prompts' own tags")
        list.filter = .persona("Manager")
        try check(list.rows.map(\.pickerTitle) == ["Onboarding", "Security"], "a category narrows the same list instead of opening a submenu")
        list.query = "onboard"
        try check(list.rows.map(\.pickerTitle) == ["Onboarding"], "search and a category combine")
        list.filter = .all; list.query = "acme"
        try check(list.rows.map(\.pickerTitle) == ["Pricing", "Onboarding"], "search uses the library's matcher, including product tags")
        var large = PromptPickerList(resources: (0..<400).map { prompt("Prompt \($0)", favourite: $0 % 10 == 0, product: "P\($0 % 7)", age: Double($0)) })
        try check(large.rows.count == 400 && Set(large.rows.map(\.id)).count == 400 && large.rows.prefix(40).allSatisfy(\.favorite)
                  && !large.rows.dropFirst(40).contains(where: \.favorite), "a large library keeps one position per prompt, favourites first")
        large.query = "Prompt 399"
        try check(large.rows.map(\.pickerTitle) == ["Prompt 399"], "any prompt in a large library is one search away")
        let long = prompt(String(repeating: "A very long prompt name ", count: 8), product: "Product", persona: "Persona")
        try check(PromptPickerList.accessibilityLabel(long).hasPrefix(long.pickerTitle) && PromptPickerList.accessibilityLabel(long).hasSuffix("Product · Persona"),
                  "a long name keeps its whole text for VoiceOver and the tooltip")

        // Width and placement: 420 points at most, inside any display, near either edge.
        let wide = NSRect(x: 0, y: 0, width: 1512, height: 944), narrow = NSRect(x: 0, y: 0, width: 360, height: 700)
        try check(PromptPickerLayout.width(in: wide) == 420 && PromptPickerLayout.width(in: narrow) == 328,
                  "the picker is 420 points wide at most and never wider than the display less 16 points each side")
        let content = NSSize(width: 420, height: 300)
        for side in [ToolbarAnchor.left, .right] {
            let toolbar = ToolbarGeometry.frame(size: NSSize(width: 40, height: 172), position: .docked(side), screen: narrow)
            let width = PromptPickerLayout.width(in: narrow, beside: toolbar, anchor: side)
            let frame = PromptPickerLayout.frame(content: NSSize(width: width, height: 300), anchor: toolbar, visible: narrow, above: true, toolbarAnchor: side)
            try check(width == 290 && frame.width == width && !frame.intersects(toolbar) && narrow.contains(frame),
                      "a narrow side picker measures its content to the inboard lane before it opens")
        }
        for anchorX in [wide.minX, wide.maxX - 64] {
            let anchor = NSRect(x: anchorX, y: 40, width: 64, height: 30)
            let frame = PromptPickerLayout.frame(content: content, anchor: anchor, visible: wide, above: true)
            try check(frame.minX >= wide.minX + 16 && frame.maxX <= wide.maxX - 16 && frame.width == 420 && frame.minY >= anchor.maxY,
                      "near the \(anchorX == wide.minX ? "left" : "right") edge the picker stays on the display, above the toolbar")
        }
        let bottom = NSRect(x: 600, y: 40, width: 64, height: 30), top = NSRect(x: 600, y: 880, width: 64, height: 30)
        try check(PromptPickerLayout.opensAbove(content: 300, anchor: bottom, visible: wide)
                  && !PromptPickerLayout.opensAbove(content: 300, anchor: top, visible: wide),
                  "it opens above a bottom toolbar and below a top one")
        let tall = PromptPickerLayout.frame(content: NSSize(width: 420, height: 5_000), anchor: bottom, visible: wide, above: true)
        try check(tall.maxY <= wide.maxY - 16 && tall.minY >= bottom.maxY, "a long list is clipped to the display, never past it")

        // What a choice does. Insert types into the frozen field; Copy prompt copies once.
        try check(PromptPickerMode.resolve(trusted: false, destination: nil) == .copy(noField: false)
                  && PromptPickerMode.resolve(trusted: true, destination: nil) == .copy(noField: true)
                  && PromptPickerMode.resolve(trusted: false, destination: .init(app: .current, element: AccessibilityBridge.application(getpid()),
                                                                                  value: "", selection: NSRange(location: 0, length: 0))) == .copy(noField: false),
                  "without approval the action is Copy prompt, even over a readable field")
        let readable = TextDelivery.Target(app: .current, element: AccessibilityBridge.application(getpid()), value: "before", selection: NSRange(location: 6, length: 0))
        let insertMode = PromptPickerMode.resolve(trusted: true, destination: readable)
        try check(insertMode.inserts && insertMode.actionTitle.hasPrefix("Insert into ") && insertMode.note == nil,
                  "with approval and a readable field, the action inserts into that field")
        try check(PromptPickerMode.copy(noField: false).actionTitle == "Copy prompt" && PromptPickerMode.copy(noField: false).note == nil
                  && PromptPickerMode.copy(noField: true).note?.contains("No readable text field") == true,
                  "missing approval is never explained as a nag; a missing field is")

        let board = NSPasteboard(name: .init("Workbench.PromptPickerChecks." + UUID().uuidString))
        defer { board.releaseGlobally() }
        guard TextDelivery.copy("earlier synthetic content", to: board) != nil else {
            throw VoiceError.message("PROMPT PICKER CHECK FAILED: isolated pasteboard unavailable")
        }
        var prepared = 0, posted = 0, inserted: [String] = []
        let system = TextDelivery.System(pasteboard: board, isTrusted: { false }, isEligible: { _ in false },
                                         preparePaste: { _ in prepared += 1; return { posted += 1 } })
        let delivery = PromptInsertion()
        let receipts = ClipboardReceiptModel(clipboardChangeCount: { board.changeCount }, automaticallySchedules: false)
        func model(_ mode: PromptPickerMode, dismissed: @escaping () -> Void = {}) -> PromptPickerModel {
            let action = PromptPickerAction(mode: mode, insert: { text, _ in inserted.append(text) },
                                            copy: { delivery.copy($0.content, title: $0.pickerTitle, receipts: receipts, system: system) })
            return PromptPickerModel(list: PromptPickerList(resources: library), mode: mode, width: 420, available: 600,
                                     perform: { action.perform($0) }, dismiss: dismissed)
        }

        var dismissals = 0
        let copying = model(.copy(noField: false), dismissed: { dismissals += 1 })
        var before = board.changeCount
        copying.cancel()
        try check(dismissals == 1 && board.changeCount == before && receipts.receipt == nil && inserted.isEmpty && delivery.lastAttempt == nil,
                  "Escape or a click outside closes the picker and leaves the clipboard alone")
        try check(copying.highlightedPrompt?.pickerTitle == "Escalation", "the first favourite is highlighted when the picker opens")
        copying.move(1); copying.move(1)
        try check(copying.highlightedPrompt?.pickerTitle == "Recap", "↓ moves through favourites into the rest")
        copying.move(-5)
        try check(copying.highlightedPrompt?.pickerTitle == "Escalation", "↑ stops at the first row")
        copying.list.query = "secur"
        try check(copying.highlightedPrompt?.pickerTitle == "Security", "typing highlights the first match, so Return chooses it")
        before = board.changeCount
        copying.chooseHighlighted()
        try check(board.changeCount == before + 1 && board.string(forType: .string) == "Synthetic prompt: Security",
                  "Copy prompt copies the exact selected text once")
        try check(inserted.isEmpty && prepared == 0 && posted == 0,
                  "Copy prompt writes nothing through Accessibility and posts no paste")
        try check(receipts.receipt?.title == "Copied" && receipts.receipt?.detail == "Paste with ⌘V."
                  && receipts.receipt?.canSuggestPaste == true && receipts.receipt?.source == .prompt,
                  "Copy prompt gives dictation's Copied and Paste with ⌘V. receipt, and Review leads to Library")
        try check(delivery.lastAttempt?.result == TextDelivery.copiedMessage && delivery.lastAttempt?.destination == "Clipboard"
                  && delivery.lastAttempt?.result.contains("readable destination") == false,
                  "without approval Prompts says Copied, never asks for a readable field")

        let inserting = model(insertMode)
        inserting.list.query = "pricing"
        before = board.changeCount
        inserting.chooseHighlighted()
        try check(inserted == ["Synthetic prompt: Pricing"] && board.changeCount == before,
                  "with approval, choosing inserts the exact text once and copies nothing first")
        let busy = model(insertMode)
        busy.show(running: true, attempt: PromptAttempt(prompt: "Pricing", destination: "Notes", result: "Inserting…", finished: false))
        busy.chooseHighlighted()
        try check(inserted.count == 1, "nothing new starts while a prompt is being inserted")
        let stranger = prompt("Not in this picker")
        inserting.choose(stranger)
        try check(inserted.count == 1, "only a prompt frozen into this picker can be chosen")
        inserting.list.query = "no such prompt"
        try check(inserting.list.rows.isEmpty && inserting.highlightedPrompt == nil, "a search with no match highlights nothing")
        inserting.showAll()
        try check(inserting.list.rows.count == 5 && inserting.highlightedPrompt != nil, "Show all prompts clears search and category")

        // The status line belongs to its own attempt and stays one line.
        let stopped = PromptAttempt(prompt: "Pricing", destination: "Notes",
                                    result: "Insertion stopped. 12 characters confirmed; nothing was replayed.")
        try check(stopped.line == "Last prompt · Notes · Insertion stopped." && stopped.hasDetails
                  && stopped.details.contains("12 characters confirmed") && !stopped.line.contains("\n"),
                  "a long result is one line naming its destination, with the full reason behind Details")
        let copied = PromptAttempt(prompt: "Pricing", destination: "Clipboard", result: TextDelivery.copiedMessage)
        try check(copied.line == "Last prompt · Clipboard · Copied. Paste with ⌘V." && !copied.hasDetails,
                  "a short result is shown whole")
        try check(PromptInsertion.describe(.init(message: "", clipboardChangeCount: 3, wasPasted: false, destinationName: "Notes", failure: .focusChanged))
                    == "Copied. The field changed, so nothing was pasted. Paste with ⌘V when ready."
                  && PromptInsertion.describe(.init(message: "", clipboardChangeCount: nil, wasPasted: true, destinationName: "Notes")).hasPrefix("Prompt pasted once.")
                  && PromptInsertion.describe(.init(message: "", clipboardChangeCount: 3, wasPasted: false, destinationName: "Notes", failure: .accessibilityUnavailable)) == TextDelivery.copiedMessage
                  && !PromptInsertion.describe(.init(message: "", clipboardChangeCount: 3, wasPasted: false, destinationName: "Notes", failure: .cancelled)).contains("transcript"),
                  "a paste fallback's result is worded for a prompt, and a copy reads as copied")
        // The Library entry uses the actual Context action with its existing
        // Library copy owner; no captured target or inferred insertion path.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench-LibraryPrompt-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var copiedTexts: [String] = [], copyAllowed = true
        let store = DemoLibraryStore(directory: directory)
        let resources = DemoLibraryModel(store: store, copyText: { text in
            guard copyAllowed else { return nil }
            copiedTexts.append(text); return copiedTexts.count
        })
        let complete = "  e\u{301}\r\n" + String(repeating: "Exact multiline prompt.\n", count: 1_000) + "\tEnd.  "
        let retained = prompt("Complete briefing", favourite: true, product: "Synthetic", content: complete)
        try check(resources.save(retained) && resources.save(prompt("Other task")), "synthetic Library prompts are committed")
        let savedResources = try Data(contentsOf: store.url)
        let context = PromptPickerController.Context.library(resources, delivery: delivery, receipts: receipts, openLibrary: {})
        try check(context.destination == nil && !context.trusted && context.action.mode == .copy(noField: false),
                  "opening Library's picker has no external target and always offers Copy")
        var cancelled = 0
        let libraryPicker = PromptPickerModel(list: PromptPickerList(resources: context.resources), mode: context.action.mode,
            width: 420, available: 600, perform: context.action.perform, dismiss: { cancelled += 1 })
        libraryPicker.list.filter = .product("Synthetic"); libraryPicker.list.query = "briefing"
        try check(libraryPicker.list.favourites.map(\.id) == [retained.id] && libraryPicker.list.others.isEmpty,
                  "Library picker retains its favourite and category/search filtering")
        libraryPicker.cancel()
        try check(cancelled == 1 && copiedTexts.isEmpty, "Cancel leaves the clipboard unchanged")
        libraryPicker.chooseHighlighted()
        try check(copiedTexts.count == 1 && Data(copiedTexts[0].utf8) == Data(complete.utf8)
                  && resources.notice == "Prompt copied. Paste when you are ready.", "Copy uses complete exact UTF-8 and Library's success feedback")
        copyAllowed = false; libraryPicker.chooseHighlighted()
        try check(copiedTexts.count == 1 && resources.notice == nil && resources.error == "The clipboard could not be updated. Try copying again.",
                  "a refused clipboard write reports failure and cannot retain success")
        try check(try Data(contentsOf: store.url) == savedResources, "Copy, cancellation and failure never rewrite prompt originals")
        print("PROMPT_PICKER_CHECKS_OK: \(passed) checks; synthetic prompts, isolated pasteboard and injected trust only")
    }
}
