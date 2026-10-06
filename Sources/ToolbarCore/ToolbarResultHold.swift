/// Which waiting result the pointer's reveal may show over input-consuming work (#220, #222).
///
/// The result that was pending when that work began is held back while the work lasts, so the
/// work's own row stays under the pointer: a click answering the mark reaches Stop reading, not
/// an old Retry. A result that arrives during the work is revealed as any new result is (#134 T4),
/// and the chosen tool's own sessions hold nothing back. The host observes each change of what
/// is live and pending, and reports when the held result's own slot is set again, to a new
/// result or to none: from then on, what is pending of that kind is new.
public struct ToolbarResultHold<ID: Hashable>: Equatable {
    /// The result pending when the live work began, until the work ends or its slot is set again.
    public private(set) var held: ID?
    /// Input-consuming work was live at the last observation.
    public private(set) var working = false

    public init() {}

    /// What is live now and which result is pending: work that begins holds back the result
    /// pending at that moment, and the work ending lets it go.
    public mutating func observe(_ live: ToolbarLiveState, pending: ID?) {
        guard live.consumesInput else { working = false; held = nil; return }
        if !working { working = true; held = pending }
    }

    /// The held result's own slot was set again, to a new result or to none. Only that kind's
    /// slot counts: another result's owner clearing its own slot keeps this one held.
    public mutating func slotChanged(_ id: ID) {
        if held == id { held = nil }
    }

    /// Whether the pointer's reveal may show this pending result.
    public func reveals(_ id: ID) -> Bool { id != held }
}
