import AppKit
import SwiftUI

/// An insertion boundary is between rows, including before the first and after
/// the last. Hovering never changes this draft or the saved session.
struct ReadbackSectionOrder {
    var ids: [UUID]

    func moving(_ id: UUID, to boundary: Int) -> [UUID]? {
        guard (0...ids.count).contains(boundary), let source = ids.firstIndex(of: id) else { return nil }
        var result = ids
        result.remove(at: source)
        result.insert(id, at: boundary > source ? boundary - 1 : boundary)
        return result == ids ? nil : result
    }
}

/// A token belongs to one native drag from one table. It is invalidated on drop,
/// cancellation or dismantling the sheet; generic text and old tokens cannot move rows.
struct ReadbackSectionDrag {
    static let type = NSPasteboard.PasteboardType("com.ethdawg.workbench.section-order")
    private var source: UUID?
    private var token: String?

    mutating func begin(_ id: UUID) -> String {
        source = id; token = UUID().uuidString
        return token!
    }

    func proposedOrder(payload: String?, fromThisTable: Bool, ids: [UUID], boundary: Int) -> [UUID]? {
        guard fromThisTable, let source, let token, payload == token else { return nil }
        return ReadbackSectionOrder(ids: ids).moving(source, to: boundary)
    }

    mutating func end() { source = nil; token = nil }
}

struct ReadbackOrderingView: View {
    @ObservedObject var model: ReadbackModel
    @Environment(\.dismiss) private var dismiss
    @State private var sessionURL: URL
    @State private var sections: [ReadbackSection]
    private var originalOrder: [UUID] { sections.map(\.id) }
    @State private var order: [UUID]
    @State private var selection: UUID?
    @State private var error: String?

    init(model: ReadbackModel, sessionURL: URL) {
        self.model = model
        _sessionURL = State(initialValue: sessionURL)
        _sections = State(initialValue: model.activeSections)
        _order = State(initialValue: model.activeSections.map(\.id))
        _selection = State(initialValue: model.activeSections.first?.id)
    }

    private var sessionUnchanged: Bool {
        model.sessionURL?.standardizedFileURL == sessionURL.standardizedFileURL
            && model.activeSections.map(\.id) == originalOrder
    }
    private var selectedIndex: Int? { selection.flatMap { order.firstIndex(of: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Reorder sections").font(.title2.weight(.semibold))
                Text("Drag a row between sections, or select one and use Move up or Move down.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ReadbackOrderTable(root: sessionURL, sections: sections, transcripts: model.transcriptDrafts,
                               order: $order, selection: $selection)
                .frame(height: 390)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .disabled(!sessionUnchanged)
            HStack {
                Button { moveSelected(up: true) } label: { Label("Move up", systemImage: "arrow.up") }
                    .disabled(!sessionUnchanged || selectedIndex == nil || selectedIndex == 0)
                Button { moveSelected(up: false) } label: { Label("Move down", systemImage: "arrow.down") }
                    .disabled(!sessionUnchanged || selectedIndex == nil || selectedIndex == order.count - 1)
                Spacer()
                Text("\(order.count) sections").font(.caption).foregroundStyle(.secondary)
            }
            if !sessionUnchanged {
                Text("The session changed. Cancel and reopen Reorder sections to use its latest order.")
                    .font(.callout).foregroundStyle(.orange)
            } else if let error {
                Text(error).font(.callout).foregroundStyle(.orange)
            } else {
                Text("Your screenshots and narration stay together. Nothing changes until you save.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save order") {
                    if model.saveSectionOrder(order, expectedOrder: originalOrder, session: sessionURL) { dismiss() }
                    else { error = model.notice ?? "The order could not be saved. Your session is unchanged." }
                }.keyboardShortcut(.defaultAction)
                    .disabled(!sessionUnchanged || order == originalOrder)
            }
        }.padding(24).frame(width: 660).workbenchTheme()
    }

    private func moveSelected(up: Bool) {
        guard let selection, let index = selectedIndex,
              let moved = ReadbackSectionOrder(ids: order).moving(selection, to: up ? index - 1 : index + 2) else { return }
        order = moved; error = nil
    }
}

/// NSTableView supplies native row selection, keyboard navigation, autoscrolling
/// and an insertion line, without moving the large narration-editing cards.
struct ReadbackOrderTable: NSViewRepresentable {
    let root: URL
    let sections: [ReadbackSection]
    let transcripts: [UUID: String]
    @Binding var order: [UUID]
    @Binding var selection: UUID?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 72; table.intercellSpacing = NSSize(width: 0, height: 1)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .inset; table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false; table.allowsEmptySelection = false
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.registerForDraggedTypes([ReadbackSectionDrag.type])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.draggingDestinationFeedbackStyle = .gap
        table.setAccessibilityLabel("Section order")
        table.setAccessibilityHelp("Drag a section between rows, or select it and use Move up or Move down.")
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        let changed = coordinator.renderedOrder != order || coordinator.renderedTranscripts != transcripts
            || coordinator.renderedSections != sections
        coordinator.parent = self
        table.isEnabled = context.environment.isEnabled
        coordinator.updating = true
        if changed {
            table.reloadData()
            coordinator.renderedOrder = order; coordinator.renderedTranscripts = transcripts
            coordinator.renderedSections = sections
        }
        if let selection, let index = order.firstIndex(of: selection), table.selectedRow != index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
        coordinator.updating = false
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.drag.end()
        (scroll.documentView as? NSTableView)?.dataSource = nil
        (scroll.documentView as? NSTableView)?.delegate = nil
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ReadbackOrderTable
        var drag = ReadbackSectionDrag()
        var updating = false
        var renderedOrder: [UUID] = []
        var renderedTranscripts: [UUID: String] = [:]
        var renderedSections: [ReadbackSection] = []
        init(_ parent: ReadbackOrderTable) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.order.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.order.indices.contains(row),
                  let section = parent.sections.first(where: { $0.id == parent.order[row] }) else { return nil }
            let narration = parent.transcripts[section.id]?.split(whereSeparator: \.isNewline).joined(separator: " ") ?? ""
            return NSHostingView(rootView: ReadbackOrderRow(root: parent.root, section: section, number: row + 1,
                                                          narration: narration))
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView,
                  parent.order.indices.contains(table.selectedRow) else { return }
            parent.selection = parent.order[table.selectedRow]
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.order.indices.contains(row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(drag.begin(parent.order[row]), forType: ReadbackSectionDrag.type)
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
            guard let moved = proposedOrder(tableView, info: info, row: row) else { return false }
            parent.order = moved
            return true
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) { drag.end() }

        private func proposedOrder(_ table: NSTableView, info: NSDraggingInfo, row: Int) -> [UUID]? {
            drag.proposedOrder(payload: info.draggingPasteboard.string(forType: ReadbackSectionDrag.type),
                               fromThisTable: (info.draggingSource as AnyObject?) === table, ids: parent.order, boundary: row)
        }
    }
}

private struct ReadbackOrderRow: View {
    let root: URL
    let section: ReadbackSection
    let number: Int
    let narration: String

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24)
            ReadbackThumbnail(root: root, relative: section.screenshot, revision: section.capturedAt)
                .frame(width: 86, height: 52).background(.quaternary, in: RoundedRectangle(cornerRadius: 4)).clipped()
            VStack(alignment: .leading, spacing: 4) {
                Text(narration.isEmpty ? section.displayName : narration).font(.callout).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(section.displayName) · \(section.status.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).padding(.trailing, 8)
        }.padding(.horizontal, 8).frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Section \(number). \(narration.isEmpty ? section.displayName : narration). \(section.status.title)")
    }
}
