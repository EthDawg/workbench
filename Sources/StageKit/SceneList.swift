import AppKit
import SwiftUI

struct SceneListSelection: Equatable {
    var ids = Set<UUID>()
    var primaryID: UUID?

    func reconciled(with visible: [UUID]) -> Self {
        var retained = ids.intersection(visible)
        if retained.isEmpty, let first = visible.first { retained.insert(first) }
        let primary = primaryID.flatMap { retained.contains($0) ? $0 : nil }
            ?? visible.first { retained.contains($0) }
        return Self(ids: retained, primaryID: primary)
    }
}

/// Boundaries include before the first and after the last row. A moved
/// selection keeps its original relative order, including nonadjacent rows.
struct SceneListOrder {
    var ids: [UUID]

    func moving(_ selected: Set<UUID>, to boundary: Int) -> [UUID]? {
        guard !selected.isEmpty, selected.isSubset(of: Set(ids)), Set(ids).count == ids.count,
              (0...ids.count).contains(boundary) else { return nil }
        let moving = ids.filter { selected.contains($0) }
        let insertion = boundary - ids.prefix(boundary).filter { selected.contains($0) }.count
        var result = ids.filter { !selected.contains($0) }
        result.insert(contentsOf: moving, at: insertion)
        return result == ids ? nil : result
    }
}

/// A private one-drag token cannot be replayed from another table or after a
/// cancellation. A changed library order invalidates the frozen insertion math.
struct SceneListDrag {
    static let type = NSPasteboard.PasteboardType("com.ethdawg.workbench.scene-order")
    private var token: String?
    private(set) var originalOrder: [UUID] = []
    private var selected = Set<UUID>()

    mutating func begin(selected: Set<UUID>, order: [UUID]) -> String {
        if token == nil { token = UUID().uuidString; self.selected = selected; originalOrder = order }
        return token!
    }
    func proposedOrder(payload: String?, fromThisTable: Bool, currentOrder: [UUID], boundary: Int) -> [UUID]? {
        guard fromThisTable, let token, payload == token, originalOrder == currentOrder else { return nil }
        return SceneListOrder(ids: originalOrder).moving(selected, to: boundary)
    }
    mutating func end() { token = nil; originalOrder = []; selected = [] }
}

/// Only the table as first responder owns these keys. A search field, inline
/// editor or any other control keeps normal text editing, including Backspace.
final class SceneListTableView: NSTableView {
    var onDelete: (() -> Void)?
    var onRename: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    @discardableResult func handleListKey(_ event: NSEvent) -> Bool {
        guard window?.firstResponder === self, isEnabled,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 51, 117: onDelete?(); return true
        case 36, 76: onRename?(); return true
        default: return false
        }
    }
    override func keyDown(with event: NSEvent) {
        if !handleListKey(event) { super.keyDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return contextMenu?()
    }
}

/// AppKit owns Command/Shift selection, keyboard navigation, field editing,
/// autoscroll and drag insertion feedback. SwiftUI owns only saved model state.
struct SceneList: NSViewRepresentable {
    @ObservedObject var model: DemoScenes
    var onDelete: ([DemoScene]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = SceneListTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("scene"))
        column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 34; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .sourceList; table.allowsMultipleSelection = true; table.allowsEmptySelection = false
        table.backgroundColor = .clear
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.renameSelected)
        table.registerForDraggedTypes([SceneListDrag.type])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.draggingDestinationFeedbackStyle = .gap
        table.setAccessibilityLabel("Scenes")
        table.setAccessibilityHelp("Command-click to select scenes, or Shift-click to select a range. Return renames one scene. Delete removes the selection after confirmation. Drag to reorder when search is empty.")
        let coordinator = context.coordinator
        coordinator.table = table
        table.onDelete = { [weak coordinator] in coordinator?.deleteSelected() }
        table.onRename = { [weak coordinator] in coordinator?.renameSelected() }
        table.contextMenu = { [weak coordinator] in coordinator?.makeMenu() }
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refresh()
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.drag.end(); coordinator.cancelRename()
        coordinator.table?.dataSource = nil; coordinator.table?.delegate = nil
        coordinator.table?.onDelete = nil; coordinator.table?.onRename = nil; coordinator.table?.contextMenu = nil
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var parent: SceneList
        weak var table: SceneListTableView?
        var drag = SceneListDrag()
        private(set) var rows: [DemoScene] = []
        private var updating = false
        private var editing: DemoScene?
        private weak var editingField: NSTextField?
        private var cancelledRename = false

        init(_ parent: SceneList) { self.parent = parent }
        func refresh() {
            guard let table, editing == nil else { return }
            updating = true; defer { updating = false }
            let next = parent.model.matches
            if rows != next || rows.map(\.libraryRevision) != next.map(\.libraryRevision) {
                rows = next; table.reloadData()
            }
            let indices = IndexSet(rows.indices.filter { parent.model.selection.ids.contains(rows[$0].id) })
            if table.selectedRowIndexes != indices { table.selectRowIndexes(indices, byExtendingSelection: false) }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let scene = rows[row]
            let cell = NSTableCellView()
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: scene.showsPhone ? "iphone" : "photo", accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
            let field = NSTextField(labelWithString: scene.name)
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
            field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1
            field.delegate = self; field.setAccessibilityLabel("Scene name")
            field.toolTip = scene.name
            cell.imageView = icon; cell.textField = field
            for view in [icon, field] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 20),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            parent.model.selectScenes(Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }))
        }
        private var selectedRows: [DemoScene] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        }
        private var canEditSelection: Bool {
            !selectedRows.isEmpty && selectedRows.allSatisfy { !parent.model.isSceneReadOnly($0) }
        }
        @objc func deleteSelected() {
            guard editing == nil, canEditSelection else { return }
            parent.onDelete(selectedRows)
        }
        @objc func renameSelected() {
            guard editing == nil, let table, selectedRows.count == 1, canEditSelection,
                  let cell = table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField else { return }
            editing = selectedRows[0]; editingField = field; cancelledRename = false
            field.isEditable = true; field.isSelectable = true
            field.cell?.refusesFirstResponder = false
            field.isBezeled = true; field.drawsBackground = true; field.backgroundColor = .textBackgroundColor
            table.editColumn(0, row: table.selectedRow, with: nil, select: true)
        }
        func cancelRename() {
            cancelledRename = true
            if let table, editing != nil { table.window?.makeFirstResponder(table) }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancelRename(); return true }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if let table { table.window?.makeFirstResponder(table) }
                return true
            }
            return false
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let captured = editing, let field = notification.object as? NSTextField, field === editingField else { return }
            let name = field.stringValue
            let cancelled = cancelledRename
            editing = nil; editingField = nil; cancelledRename = false
            field.isEditable = false; field.isSelectable = false; field.isBezeled = false; field.drawsBackground = false
            field.stringValue = captured.name
            if !cancelled { _ = parent.model.renameScene(captured, to: name) }
            // Force a refresh even when a blank/cancelled rename did not publish.
            rows = []; refresh()
        }
        @objc private func duplicateSelected() {
            guard selectedRows.count == 1, canEditSelection, let scene = selectedRows.first else { return }
            parent.model.selectedID = scene.id; parent.model.duplicate()
        }
        @objc private func exportSelected() {
            guard selectedRows.count == 1, canEditSelection, let scene = selectedRows.first else { return }
            parent.model.selectedID = scene.id; parent.model.exportSceneCopy()
        }
        @objc private func moveUp() { moveSelection(up: true) }
        @objc private func moveDown() { moveSelection(up: false) }
        private func movedSelection(up: Bool) -> [UUID]? {
            guard parent.model.canReorderScenes, let table,
                  let first = table.selectedRowIndexes.first, let last = table.selectedRowIndexes.last,
                  up ? first > 0 : last + 1 < rows.count else { return nil }
            return SceneListOrder(ids: rows.map(\.id)).moving(Set(selectedRows.map(\.id)), to: up ? first - 1 : last + 2)
        }
        private func moveSelection(up: Bool) {
            guard let next = movedSelection(up: up) else { return }
            _ = parent.model.reorderScenes(next, expectedOrder: rows.map(\.id))
        }
        func makeMenu() -> NSMenu? {
            guard editing == nil, !selectedRows.isEmpty else { return nil }
            let menu = NSMenu(); menu.autoenablesItems = false
            func add(_ title: String, _ action: Selector, enabled: Bool) {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self; item.isEnabled = enabled; menu.addItem(item)
            }
            let single = selectedRows.count == 1 && canEditSelection
            add("Rename", #selector(renameSelected), enabled: single)
            add("Duplicate", #selector(duplicateSelected), enabled: single)
            add("Save editable copy…", #selector(exportSelected), enabled: single)
            menu.addItem(.separator())
            add("Move up", #selector(moveUp), enabled: movedSelection(up: true) != nil)
            add("Move down", #selector(moveDown), enabled: movedSelection(up: false) != nil)
            menu.addItem(.separator())
            add(selectedRows.count == 1 ? "Delete scene…" : "Delete \(selectedRows.count) scenes…", #selector(deleteSelected), enabled: canEditSelection)
            return menu
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard editing == nil, parent.model.canReorderScenes, rows.indices.contains(row) else { return nil }
            var selected = Set(selectedRows.map(\.id)); selected.insert(rows[row].id)
            let item = NSPasteboardItem()
            item.setString(drag.begin(selected: selected, order: rows.map(\.id)), forType: SceneListDrag.type)
            return item
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            tableView.setDropRow(row, dropOperation: .above)
            return proposedOrder(tableView, info: info, row: row) == nil ? [] : .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            defer { drag.end() }
            guard let next = proposedOrder(tableView, info: info, row: row) else { return false }
            return parent.model.reorderScenes(next, expectedOrder: drag.originalOrder)
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) { drag.end() }
        private func proposedOrder(_ table: NSTableView, info: NSDraggingInfo, row: Int) -> [UUID]? {
            guard parent.model.canReorderScenes else { return nil }
            return drag.proposedOrder(payload: info.draggingPasteboard.string(forType: SceneListDrag.type),
                fromThisTable: (info.draggingSource as? NSTableView) === table,
                currentOrder: parent.model.scenes.map(\.id), boundary: row)
        }
    }
}

struct SceneRemovalRequest: Identifiable {
    let id = UUID()
    let scenes: [DemoScene]
}

struct SceneRemovalConfirmation: View {
    let request: SceneRemovalRequest
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.scenes.count == 1 ? "Delete this scene?" : "Delete \(request.scenes.count) scenes?")
                .font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(request.scenes) { scene in Text(scene.name).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }.frame(maxHeight: min(220, CGFloat(request.scenes.count) * 30))
            Text("These saved layouts will be deleted. If scene sync is enabled, deletion also syncs to your devices. Original pictures are kept.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) { onDelete(); dismiss() }
            }
        }.padding(24).frame(width: 420).workbenchTheme()
    }
}
