import AppKit
import Combine
import SwiftUI
import PresenterKit

private final class DestinationPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}
private final class DestinationTable: NSTableView {
    var choose: (() -> Void)?
    var dismiss: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { choose?() }
        else if event.keyCode == 53 { dismiss?() }
        else { super.keyDown(with: event) }
    }
}
private final class DestinationRow: NSStackView {
    var activate: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { activate?(); return activate != nil }
}

@MainActor
final class PresenterPanelController: NSWindowController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let model: PresenterModel
    private let setup: () -> Void
    private let search = NSSearchField()
    private let table = DestinationTable()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var rows: [PresenterDestination] = []
    private var observations = Set<AnyCancellable>()
    private var previous: NSRunningApplication?

    init(model: PresenterModel, setup: @escaping () -> Void) {
        self.model = model; self.setup = setup
        let panel = DestinationPanel(contentRect: NSRect(x: 0, y: 0, width: 450, height: 440),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Switch to"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false; panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true; panel.delegate = self
        panel.dismiss = { [weak self] in self?.cancel() }
        let content = NSVisualEffectView(); content.material = .popover; content.blendingMode = .behindWindow; content.state = .active
        panel.contentView = content
        search.placeholderString = "Switch to…"; search.font = .systemFont(ofSize: 22, weight: .medium)
        search.focusRingType = .none; search.delegate = self; search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Search presenter destinations")
        let column = NSTableColumn(identifier: .init("destination")); table.addTableColumn(column); table.headerView = nil
        table.delegate = self; table.dataSource = self; table.rowHeight = 57; table.intercellSpacing = NSSize(width: 0, height: 3)
        table.backgroundColor = .clear; table.style = .fullWidth; table.selectionHighlightStyle = .regular
        table.target = self; table.action = #selector(choose); table.setAccessibilityLabel("Presenter destinations")
        table.choose = { [weak self] in self?.choose() }; table.dismiss = { [weak self] in self?.cancel() }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 4
        let settings = NSButton(title: "Manage destinations", target: self, action: #selector(manage)); settings.bezelStyle = .rounded
        let hint = NSTextField(labelWithString: "↑ ↓ choose   ↩ switch   Esc close")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .tertiaryLabelColor
        let footer = NSStackView(views: [settings, NSView(), hint]); footer.orientation = .horizontal
        let stack = NSStackView(views: [search, scroll, status, footer]); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor), search.heightAnchor.constraint(equalToConstant: 38),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 70),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor), footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        model.$destinations.receive(on: RunLoop.main).sink { [weak self] _ in self?.reload() }.store(in: &observations)
        model.$message.receive(on: RunLoop.main).sink { [weak self] _ in self?.reload() }.store(in: &observations)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show() {
        if window?.isVisible != true {
            previous = NSWorkspace.shared.frontmostApplication
            search.stringValue = ""
            window?.setContentSize(NSSize(width: 450, height: max(280, min(5, model.destinations.count) * 60 + 195)))
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main,
               let window {
                let frame = screen.visibleFrame
                window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2 + min(80, frame.height * 0.08)))
            }
        }
        model.refresh(); reload(); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(search)
    }
    func hide() { window?.orderOut(nil) }
    private func cancel() { hide(); if previous?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous?.activate(options: []) } }
    func windowDidResignKey(_ notification: Notification) { hide() }
    func controlTextDidChange(_ obj: Notification) { reload() }
    private func reload() {
        let selectedID = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        let terms = search.stringValue.split(whereSeparator: \.isWhitespace)
        rows = model.destinations.filter { item in terms.allSatisfy { (item.title + " " + item.profileName).localizedStandardContains(String($0)) } }
        table.reloadData()
        if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: rows.firstIndex(where: { $0.id == selectedID }) ?? 0), byExtendingSelection: false) }
        status.stringValue = model.message ?? (model.destinations.isEmpty
            ? "Save your first demo tab with the Workbench Chrome extension. Then switch here from any app."
            : rows.isEmpty ? "No matching destination. Try its name or Chrome profile."
            : "Uses your saved Chrome profile and tab. Keep destination labels safe to show while sharing.")
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor
        let title = NSTextField(labelWithString: item.title); title.font = .systemFont(ofSize: 15, weight: .medium); title.lineBreakMode = .byTruncatingTail
        let subtitle = NSTextField(labelWithString: item.profileName + (item.connected ? "" : " · Open profile to connect"))
        subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = .secondaryLabelColor; subtitle.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [title, subtitle]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 4
        let rowView = DestinationRow(views: [icon, text]); rowView.orientation = .horizontal; rowView.spacing = 12
        rowView.activate = { [weak self] in self?.activate(item.id) }
        rowView.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        rowView.setAccessibilityElement(true); rowView.setAccessibilityRole(.button)
        rowView.setAccessibilityLabel(item.title + ", " + subtitle.stringValue)
        return rowView
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { choose(); return true }
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
            guard !rows.isEmpty else { return true }
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let next = min(rows.count - 1, max(0, table.selectedRow + delta))
            table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false); table.scrollRowToVisible(next); return true
        }
        return false
    }
    @objc private func choose() {
        guard rows.indices.contains(table.selectedRow), !model.busy else { return }
        activate(rows[table.selectedRow].id)
    }
    private func activate(_ id: UUID) { model.activate(id) { [weak self] reply in if reply.ok != true { self?.show() } } }
    @objc private func manage() { hide(); setup() }
}

struct ChromeConnectionView: View {
    @ObservedObject var presenter: PresenterModel
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Save a tab as Manager or HR Admin in each Chrome profile. Use Switch to from any app to bring back the right tab.")
                HStack {
                    Button(presenter.enabled ? "Repair Chrome connection" : "Enable Chrome connection") { presenter.enable() }
                    Button("Show Chrome extension") {
                        if let url = presenter.extensionFolder { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    if presenter.enabled { Button("Pause connection") { presenter.pause() } }
                }
                Text("Once per profile: open chrome://extensions, turn on Developer mode, choose Load unpacked and select the BrowserExtension folder. Open the extension, name the profile and connect it.")
                    .foregroundStyle(.secondary).textSelection(.enabled)
                Text("Allow only each site you save. Passwords stay in Chrome or your password manager. Connections are local to this Mac; keep Workbench and the participating Chrome profiles open.")
                    .foregroundStyle(.secondary)
                if let message = presenter.message { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
            }.font(.caption).padding(.top, 8)
        } label: {
            HStack {
                Label("Chrome destinations", systemImage: "arrow.up.forward.app")
                Spacer()
                Text(presenter.enabled ? "\(presenter.connectedCount) profiles connected" : "Set up once")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12).background(Workbench.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}
