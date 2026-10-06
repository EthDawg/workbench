import AppKit
import SwiftUI
import ToolbarCore

@MainActor
enum ReadSelectionChecks {
    private struct Failure: LocalizedError {
        let label: String
        var errorDescription: String? { "READ SELECTION CHECK FAILED: \(label)" }
    }

    static func run() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
            guard value() else { throw Failure(label: label) }
            count += 1
        }
        func invoke(_ service: ReadSelectionService, pasteboard: NSPasteboard) -> String? {
            var message: NSString?
            withUnsafeMutablePointer(to: &message) { pointer in
                service.readSelection(pasteboard, userData: nil, error: AutoreleasingUnsafeMutablePointer(pointer))
            }
            return message as String?
        }

        let requestPasteboard = NSPasteboard.withUniqueName()
        var received: [ReadingSelectionImport] = []
        let exact = "  First line.\nSecond line — unchanged.  "
        let service = ReadSelectionService(reader: { _ in try ReadingSelectionImport(text: exact) }) { received.append($0) }
        try check(service.responds(to: NSSelectorFromString("readSelection:userData:error:")), "Objective-C Services selector is exported")

        try check(invoke(service, pasteboard: requestPasteboard) == nil, "explicit string selection is accepted")
        try check(received.last?.text == exact, "selection whitespace and Unicode are preserved exactly")

        let missing = ReadSelectionService(reader: { _ in
            throw VoiceError.message("Workbench received no text selection. Select text in the other app and try again.")
        }) { received.append($0) }
        try check(invoke(missing, pasteboard: requestPasteboard)?.contains("no text selection") == true, "missing input reports a selection error")
        try check(received.count == 1, "missing input never invents text from another source")

        let longText = String(repeating: "a", count: 50_001)
        let long = ReadSelectionService(reader: { _ in try ReadingSelectionImport(text: longText) }) { received.append($0) }
        try check(invoke(long, pasteboard: requestPasteboard) == nil && received.last?.text == longText,
                  "a selection beyond the local reading limit still opens intact for review")

        let oversizedText = String(repeating: "b", count: ReadingSelectionImport.maximumCharacters + 1)
        let oversized = ReadSelectionService(reader: { _ in try ReadingSelectionImport(text: oversizedText) }) { received.append($0) }
        try check(invoke(oversized, pasteboard: requestPasteboard)?.contains("too large") == true, "unbounded selection is rejected")
        try check(received.count == 2, "rejected selection never reaches the reading draft")

        try check(!ReadingSelectionImport.needsReview(current: "", incoming: "Incoming"), "empty reading can adopt the selection directly")
        try check(!ReadingSelectionImport.needsReview(current: "Incoming", incoming: "Incoming"), "identical re-import needs no destructive choice")
        try check(ReadingSelectionImport.needsReview(current: "Current", incoming: "Incoming"), "different existing reading requires replace or keep")

        // History and Library use the same import, named for where the text came from.
        func emptyMessage(_ origin: ReadingSelectionImport.Origin) -> String? {
            do { _ = try ReadingSelectionImport(text: " \n", origin: origin); return nil } catch { return error.localizedDescription }
        }
        try check(emptyMessage(.transcript) == "This transcript has no words to read." && emptyMessage(.savedText) == "This saved item has no text to read."
                  && emptyMessage(.selection)?.contains("Read Selection") == true, "an empty import explains itself for each origin")
        try check((try? ReadingSelectionImport(text: "Saved prompt", origin: .savedText))?.origin == .savedText
                  && (try? ReadingSelectionImport(text: "Selected"))?.origin == .selection, "the Service's import stays a selection by default")
        let origins: [ReadingSelectionImport.Origin] = [.selection, .transcript, .savedText]
        let copy = origins.flatMap { [$0.name, $0.keepNote, $0.keptNote] }.joined(separator: " ")
        try check(!copy.contains("—") && !copy.contains("–") && !copy.contains(" - ") && !copy.lowercased().contains("attention"),
                  "import wording is plain, with no dash punctuation")
        try checkReadStart(check)
        print("READ_SELECTION_CHECKS_OK: \(count) checks passed")
    }

    /// Read's one host-level start (Fit rule 6): the three-way machine, the draft rule's quiet
    /// default, and the one Accessibility read, against a scripted adapter that never touches
    /// another app.
    private static func checkReadStart(_ check: (@autoclosure () -> Bool, String) throws -> Void) throws {
        // Selection → reading; active → stop; none → page. The selection is asked once, only when idle.
        var asked = 0
        func decide(_ reading: ToolbarLiveState.Reading, _ selection: String?) -> ReadStart.Decision {
            ReadStart.decide(reading: reading) { asked += 1; return selection }
        }
        try check(decide(.idle, "Read this.") == .read("Read this.") && asked == 1, "idle with a selection reads it at once")
        asked = 0
        try check(decide(.idle, nil) == .page && decide(.idle, "") == .page && decide(.idle, " \n\t") == .page && asked == 3,
                  "idle with no selection, or only whitespace, opens the Read page as before")
        asked = 0
        try check(decide(.playing, "Read this.") == .stop && decide(.paused, "Read this.") == .stop && asked == 0,
                  "a reading that plays or is paused stops, without asking for a selection (the label reads Stop reading)")
        try check(decide(.preparing, "Read this.") == .cancel && asked == 0, "a reading still being made is cancelled, as the row's Cancel says")
        try check(ToolbarNextAction.resolve(ToolbarLiveState(mode: .read, reading: .playing)).title == "Stop reading"
                  && ToolbarNextAction.resolve(ToolbarLiveState(mode: .read, reading: .paused)).title == "Stop reading"
                  && ToolbarNextAction.resolve(ToolbarLiveState(mode: .read)).title == "Read"
                  && ToolbarOperation.stopReading.keyMode == .read && ToolbarOperation.pauseReading.keyMode == nil,
                  "the pill follows the same state, Read / Stop reading, and the Read key is hinted for the stop")
        var state = WorkbenchControlState(); state.playing = true
        try check(state.actionTitle(.read) == "Stop reading" && ToolbarNextAction.resolve(ToolbarLiveState(mode: .read, reading: .playing)).operation == .stopReading,
                  "the panel row and the pill resolve to the same operation while reading (Fit rule 6)")

        // The draft rule: never discard an unread draft silently; otherwise read at once.
        try check(ReadStart.draft(current: "", incoming: "New", heard: false) == .readNow, "an empty draft takes the selection and reads")
        try check(ReadStart.draft(current: "Same", incoming: "Same", heard: false) == .readNow, "the same text reads again without a review")
        try check(ReadStart.draft(current: "Heard", incoming: "New", heard: true) == .readNow, "a different draft whose audio was made is replaced and the selection reads")
        try check(ReadStart.draft(current: "Unheard", incoming: "New", heard: false) == .review, "a different draft nobody heard waits behind Replace reading / Keep current")
        try check(ReadStart.draft(current: "  \n", incoming: "New", heard: false) == .readNow, "a whitespace draft is empty")
        // What a door does with the outcome: focus goes back to the app only while a reading plays;
        // the Read page, opened with its reason, is never covered.
        try check(ReadStart.outcome(of: .read("Read this."), started: true) == .reading, "a selection that started reading gives focus back")
        try check(ReadStart.outcome(of: .read("Read this."), started: false) == .page
                  && ReadStart.outcome(of: .page, started: false) == .page,
                  "a selection that opened the Read page instead (review, refusal or work to finish first) leaves the page in front")
        try check(ReadStart.outcome(of: .stop, started: false) == .stopped && ReadStart.outcome(of: .cancel, started: false) == .cancelled,
                  "a stop or cancel is shown where you acted and gives nothing back")

        // The one Accessibility read: selected text, else the selected range's string; never a
        // secure field, nothing without approval, and no clipboard or window.
        let token = AXUIElementCreateSystemWide()
        var rangeAsked: CFRange?
        func adapter(trusted: Bool = true, focused: Bool = true, subrole: String? = nil, selected: CFTypeRef? = nil,
                     range: CFRange? = nil, string: CFTypeRef? = nil, attributed: NSAttributedString? = nil) -> TextDelivery.Accessibility {
            .init(isTrusted: { trusted }, frontmostPID: { 1 },
                  attribute: { _, key in
                      switch key {
                      case kAXFocusedUIElementAttribute: return focused ? token : nil
                      case kAXSubroleAttribute: return subrole as CFTypeRef?
                      case kAXSelectedTextAttribute: return selected
                      case kAXSelectedTextRangeAttribute:
                          guard var range else { return nil }
                          return AXValueCreate(.cfRange, &range)
                      default: return nil
                      }
                  }, parameterized: { _, key, parameter in
                      var asked = CFRange()
                      if CFGetTypeID(parameter) == AXValueGetTypeID(), AXValueGetValue(parameter as! AXValue, .cfRange, &asked) { rangeAsked = asked }
                      if key == kAXStringForRangeParameterizedAttribute { return string }
                      if key == kAXAttributedStringForRangeParameterizedAttribute { return attributed }
                      return nil
                  }, setBoolean: { _, _, _ in false })
        }
        func read(_ ax: TextDelivery.Accessibility) -> String? { ReadStart.selectedText(pid: 1, accessibility: ax) }
        try check(read(adapter(selected: "Selected words" as CFString)) == "Selected words", "the focused element's selected text is read")
        try check(read(adapter(selected: NSAttributedString(string: "Rich words"))) == "Rich words", "an attributed selection reads as its string")
        try check(read(adapter(trusted: false, selected: "Selected words" as CFString)) == nil, "without Accessibility approval nothing is read")
        try check(read(adapter(focused: false, selected: "Selected words" as CFString)) == nil, "no focused element means no selection")
        try check(read(adapter(subrole: kAXSecureTextFieldSubrole, selected: "hunter2" as CFString)) == nil, "a secure field is never read")
        try check(read(adapter(selected: "" as CFString, range: CFRange(location: 4, length: 5), string: "words" as CFString)) == "words"
                  && rangeAsked?.location == 4 && rangeAsked?.length == 5, "an empty selected text falls back to the selected range's string, for exactly that range")
        try check(read(adapter(range: CFRange(location: 4, length: 5), attributed: NSAttributedString(string: "words"))) == "words",
                  "the attributed string for the range serves when the plain one is missing")
        try check(read(adapter(range: CFRange(location: 4, length: 0), string: "words" as CFString)) == nil, "a collapsed selection is no selection: the window and document are never read")
        try check(read(adapter(range: CFRange(location: 0, length: ReadingSelectionImport.maximumCharacters + 1), string: "x" as CFString)) == nil,
                  "a range beyond Read's limit is not read")
        try check(read(adapter()) == nil, "nothing selected reads nothing")
        try check(ReadStart.selectedText(pid: ProcessInfo.processInfo.processIdentifier, accessibility: adapter(selected: "Mine" as CFString)) == nil
                  && ReadStart.selectedText(of: nil, accessibility: adapter(selected: "Mine" as CFString)) == nil,
                  "Workbench's own windows and no app are never read")
    }

    static func runNativePasteboard() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
            guard value() else { throw Failure(label: label) }
            count += 1
        }
        func invoke(_ service: ReadSelectionService, pasteboard: NSPasteboard) -> String? {
            var message: NSString?
            withUnsafeMutablePointer(to: &message) { pointer in
                service.readSelection(pasteboard, userData: nil, error: AutoreleasingUnsafeMutablePointer(pointer))
            }
            return message as String?
        }

        let exact = "Selected in a native requester — kept exactly."
        let requestPasteboard = NSPasteboard.withUniqueName()
        requestPasteboard.clearContents()
        try check(requestPasteboard.setString(exact, forType: .string), "native request pasteboard accepts selected text")
        var received: [ReadingSelectionImport] = []
        let service = ReadSelectionService { received.append($0) }
        try check(invoke(service, pasteboard: requestPasteboard) == nil, "production pasteboard reader accepts native string input")
        try check(received.map(\.text) == [exact], "production provider returns only the supplied request selection")
        requestPasteboard.clearContents()
        try check(invoke(service, pasteboard: requestPasteboard)?.contains("no text selection") == true,
                  "an empty native request fails without a fallback source")
        print("READ_SELECTION_NATIVE_OK: \(count) checks passed")
    }

    static func renderReviewCard(to url: URL) throws {
        let selection = try ReadingSelectionImport(id: UUID(uuidString: "D7A7A755-1B43-4D03-A9D5-49A4E6CA38F4")!, text: "Workbench should read only this selected passage. The current reading remains untouched until I choose Replace reading, and no online provider receives anything until I choose Listen.")
        let root = VStack(alignment: .leading, spacing: 18) {
            Text("Read aloud").font(.system(size: 26, weight: .bold))
            ReadingSelectionReviewCard(selection: selection, limitMessage: nil, keep: {}, replace: {})
            HStack {
                Label("Mac voices · on this Mac", systemImage: "desktopcomputer")
                Spacer()
                Text("Nothing has been played or sent.").foregroundStyle(.secondary)
            }.font(.caption)
        }.padding(28).frame(width: 820, height: 430, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark)
        let view = NSHostingView(rootView: root)
        view.frame = NSRect(x: 0, y: 0, width: 820, height: 430)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw Failure(label: "review card bitmap allocation")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(label: "review card PNG encoding")
        }
        try png.write(to: url, options: .atomic)
        print("READ_SELECTION_UI_RENDER_OK: \(url.path)")
    }
}
