/// The field the menu-bar panel was opened over. It belongs to that visit only:
/// the panel's own rows deliver to it, and closing the panel expires it, so a
/// later action from Home, the toolbar or a shortcut can never paste into a
/// field that was chosen for an earlier visit (#162).
struct PanelDestination<Target> {
    private var captured: Target?
    private(set) var isOpen = false

    mutating func opened(capturing target: Target?) { captured = target; isOpen = true }
    mutating func closed() { captured = nil; isOpen = false }
    /// The destination an action from the open panel may use; nothing once it has closed.
    var current: Target? { isOpen ? captured : nil }
}

/// The destination lifetime, without AppKit or Accessibility.
enum PanelDestinationChecks {
    static func run() throws {
        var passed = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("PANEL_DESTINATION_CHECK_FAILED: \(name)") }
            passed += 1
        }
        var destination = PanelDestination<String>()
        try check(destination.current == nil, "nothing is captured before the panel first opens")
        destination.opened(capturing: "Notes: field A")
        try check(destination.current == "Notes: field A", "a row in the open panel reaches the field the panel was opened over")
        destination.closed()
        try check(destination.current == nil, "closing the panel expires its field, so Home or the toolbar cannot reuse it")
        destination.opened(capturing: nil)
        try check(destination.current == nil, "a panel opened over Workbench itself has no field to paste into")
        destination.closed()
        destination.opened(capturing: "Mail: field B")
        try check(destination.current == "Mail: field B", "the next visit captures its own field, never an earlier one")
        destination.closed()
        destination.closed()
        try check(destination.current == nil && !destination.isOpen, "closing twice leaves nothing behind")
        print("PANEL_DESTINATION_CHECKS_OK: \(passed) checks")
    }
}
