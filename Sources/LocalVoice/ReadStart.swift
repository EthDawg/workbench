import AppKit
import ToolbarCore

/// Read's one host-level start (workbench.md, Fit rule 6): the panel row, the
/// pill and the Read key resolve here, and the label follows the same state
/// (Read / Stop reading). What it does is decided from the reading's state
/// first, then from the front app's selection, which is read only when nothing
/// is playing, so a stop never touches Accessibility. Home's sidebar and the
/// Window menu are page doors by the Desktop contract: they open Read and
/// start nothing.
enum ReadStart {
    enum Decision: Equatable {
        /// Audio is still being made: Cancel discards it, as the row's label says.
        case cancel
        /// A reading plays or is paused: stop it and keep its text.
        case stop
        /// The front app's focused element exposes this non-empty selection: read it now.
        case read(String)
        /// Nothing is live and nothing is selected: open the Read page, as before.
        case page
    }

    /// The three-way machine. `selection` is asked once, and only when idle.
    static func decide(reading: ToolbarLiveState.Reading, selection: () -> String?) -> Decision {
        switch reading {
        case .preparing: return .cancel
        case .playing, .paused: return .stop
        case .idle:
            if let text = selection(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .read(text) }
            return .page
        }
    }

    /// What the selection does to Read's draft, under the existing Replace reading / Keep
    /// current rule. The quiet default: an empty or identical draft, or one whose audio was
    /// already made (heard or saved), is replaced and the selection reads at once. A different
    /// draft nobody has heard is never discarded silently: the selection waits behind Replace
    /// reading / Keep current on the Read page, which opens, and nothing plays.
    enum Draft: Equatable { case readNow, review }
    static func draft(current: String, incoming: String, heard: Bool) -> Draft {
        guard ReadingSelectionImport.needsReview(current: current, incoming: incoming) else { return .readNow }
        return heard ? .readNow : .review
    }

    /// The selected text under an app's focused element, through the same Accessibility
    /// reads dictation makes (TextDelivery): the selected text, else the selected range
    /// and the string for it. This is Read's only Accessibility use, so the bridge the
    /// ax stream is building has one call to repoint. Never the clipboard, the window
    /// or the whole document: no selection is nil. Workbench's own windows are never
    /// read, nor a secure field, and the range read is bounded like a dictation field's.
    static func selectedText(of app: NSRunningApplication?, accessibility: TextDelivery.Accessibility = .live) -> String? {
        guard let app else { return nil }
        return selectedText(pid: app.processIdentifier, accessibility: accessibility)
    }

    static func selectedText(pid: pid_t, accessibility ax: TextDelivery.Accessibility) -> String? {
        guard pid != ProcessInfo.processInfo.processIdentifier, ax.isTrusted() else { return nil }
        guard let raw = ax.attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        guard ax.attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return nil }
        func plain(_ value: CFTypeRef?) -> String? { (value as? String) ?? (value as? NSAttributedString)?.string }
        if let text = plain(ax.attribute(element, kAXSelectedTextAttribute)), !text.isEmpty { return text }
        guard let rangeValue = ax.attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        let value = rangeValue as! AXValue
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range),
              range.location >= 0, range.length > 0, range.length <= ReadingSelectionImport.maximumCharacters,
              let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        return plain(ax.parameterized(element, kAXStringForRangeParameterizedAttribute, parameter))
            ?? plain(ax.parameterized(element, kAXAttributedStringForRangeParameterizedAttribute, parameter))
    }
}
