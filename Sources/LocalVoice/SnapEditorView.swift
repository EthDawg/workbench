import SwiftUI
import AppKit

struct SnapEditorView: View {
    @ObservedObject var model: SnapModel
    @State var draft: SnapDraft
    @State private var tool = "crop"
    @State private var colour = "red"
    @State private var tags: String
    @State private var undo: [SnapEdit] = []
    @Environment(\.dismiss) private var dismiss

    init(model: SnapModel, draft: SnapDraft) {
        self.model = model; _draft = State(initialValue: draft)
        _tags = State(initialValue: draft.tags.joined(separator: ", "))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(draft.existing == nil ? "New Snap" : "Edit Snap").font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel", role: .cancel) { model.draft = nil; dismiss() }.keyboardShortcut(.cancelAction)
            }
            GeometryReader { available in
            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $draft.title).textFieldStyle(.roundedBorder).accessibilityLabel("Snap title")
            ViewThatFits(in: .horizontal) {
                HStack { tools; Spacer(); editActions }
                VStack(alignment: .leading) { tools; editActions }
            }
            Text(tool == "crop" ? "Drag over the area to keep. Your original stays unchanged." : "Drag on the image to annotate. Crop and marks remain editable.")
                .font(.caption).foregroundStyle(.secondary)
            SnapCanvas(bytes: draft.originalPNG, edit: draft.edit, tool: tool, colour: colour) { changed in
                undo.append(draft.edit); draft.edit = changed
            }.frame(minWidth: 430).frame(height: max(260, available.size.height - 200))
                .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Snap image editor")
                .accessibilityHint("Choose a drawing tool and drag on the image. Reset crop and Undo are available as buttons.")
            HStack {
                TextField("Tags, separated by commas", text: $tags).textFieldStyle(.roundedBorder).accessibilityLabel("Snap tags")
                Button("Clear marks") { change { $0.marks = [] } }.disabled(draft.edit.marks.isEmpty)
            }
            TextField("Note (optional)", text: $draft.notes, axis: .vertical).lineLimit(2...3).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Snap note")
            }.frame(maxWidth: .infinity, alignment: .leading)
            }
            }
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(3).help(notice) }
            HStack {
                Text("Saved locally in History.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save") { save(copy: false) }.keyboardShortcut("s", modifiers: .command)
                Button("Save & Copy") { save(copy: true) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(minWidth: 560, idealWidth: 850, minHeight: 560, idealHeight: 700)
    }
    private var tools: some View {
        HStack(spacing: 8) {
            Picker("Tool", selection: $tool) {
                Text("Crop").tag("crop"); Text("Pen").tag("pen"); Text("Arrow").tag("arrow"); Text("Box").tag("rectangle")
            }.pickerStyle(.segmented).frame(width: 275)
            Picker("Colour", selection: $colour) {
                ForEach(["red", "yellow", "blue", "white", "black"], id: \.self) { Text($0.capitalized).tag($0) }
            }.labelsHidden().frame(width: 80).accessibilityLabel("Annotation colour")
        }
    }
    private var editActions: some View {
        HStack {
            Button("Undo") { if let previous = undo.popLast() { draft.edit = previous } }.disabled(undo.isEmpty).keyboardShortcut("z", modifiers: .command)
            Button("Reset crop") { change { $0.crop = .full } }.disabled(draft.edit.crop == .full)
        }
    }
    private func change(_ mutate: (inout SnapEdit) -> Void) { undo.append(draft.edit); mutate(&draft.edit) }
    private func save(copy: Bool) {
        draft.tags = Array(Set(tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        if model.saveDraft(draft, copyAfterSaving: copy) { dismiss() }
    }
}

private struct SnapCanvas: NSViewRepresentable {
    let bytes: Data
    let edit: SnapEdit
    let tool: String
    let colour: String
    let onChange: (SnapEdit) -> Void
    func makeNSView(context: Context) -> SnapCanvasView { SnapCanvasView() }
    func updateNSView(_ view: SnapCanvasView, context: Context) {
        if view.original != bytes { view.original = bytes; view.image = try? SnapRendering.image(bytes) }
        view.edit = edit; view.tool = tool; view.colour = colour; view.onChange = onChange; view.needsDisplay = true
    }
}

private final class SnapCanvasView: NSView {
    var original = Data()
    var image: CGImage?
    var edit = SnapEdit()
    var tool = "crop"
    var colour = "red"
    var onChange: ((SnapEdit) -> Void)?
    private var points: [SnapPoint] = []
    override var acceptsFirstResponder: Bool { true }
    private var imageRect: CGRect {
        guard let image else { return .zero }
        let scale = min((bounds.width - 20) / CGFloat(image.width), (bounds.height - 20) / CGFloat(image.height))
        let size = CGSize(width: max(1, CGFloat(image.width) * scale), height: max(1, CGFloat(image.height) * scale))
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = imageRect
        context.saveGState(); context.draw(image, in: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        var marks = edit.marks
        if let kind = SnapMark.Kind(rawValue: tool), points.count >= 2 { marks.append(.init(kind: kind, points: points, colour: colour)) }
        SnapRendering.draw(marks, in: context, size: rect.size)
        context.restoreGState()
        let crop = tool == "crop" && points.count >= 2 ? cropBetween(points.first!, points.last!) : edit.crop
        let kept = CGRect(x: rect.minX + crop.x * rect.width, y: rect.minY + crop.y * rect.height, width: crop.width * rect.width, height: crop.height * rect.height)
        let shade = NSBezierPath(rect: rect); shade.appendRect(kept); shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill(); shade.fill()
        if crop != .full { NSColor.white.setStroke(); let border = NSBezierPath(rect: kept); border.lineWidth = 1.5; border.stroke() }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(point) else { return }
        window?.makeFirstResponder(self); points = [normalised(point)]; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !points.isEmpty else { return }
        let point = normalised(convert(event.locationInWindow, from: nil))
        if tool == "pen" { if points.count < 20_000 { points.append(point) } }
        else { points = [points[0], point] }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let first = points.first else { return }
        let last = normalised(convert(event.locationInWindow, from: nil))
        var changed = edit
        if tool == "crop" {
            let crop = cropBetween(first, last)
            if let image, crop.width * Double(image.width) >= 2, crop.height * Double(image.height) >= 2 { changed.crop = crop }
        } else if let kind = SnapMark.Kind(rawValue: tool), first != last || points.count > 2 {
            let mark = SnapMark(kind: kind, points: tool == "pen" ? points + [last] : [first, last], colour: colour)
            if mark.isValid { changed.marks.append(mark) }
        }
        points = []; if changed != edit { onChange?(changed) }; needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !points.isEmpty { points = []; needsDisplay = true; return }
        super.keyDown(with: event)
    }
    private func normalised(_ point: CGPoint) -> SnapPoint {
        let rect = imageRect
        return .init(x: min(1, max(0, (point.x - rect.minX) / rect.width)), y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }
    private func cropBetween(_ first: SnapPoint, _ last: SnapPoint) -> SnapCrop {
        .init(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
    }
}
