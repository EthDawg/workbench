import AppKit
import Combine

enum ImageWorkspaceTool: String, CaseIterable, Identifiable {
    case select, crop, text, pen, arrow, rectangle
    var id: String { rawValue }
    var title: String { switch self { case .select: "Select"; case .crop: "Crop"; case .text: "Text"; case .pen: "Pen"; case .arrow: "Arrow"; case .rectangle: "Box" } }
    var symbol: String { switch self { case .select: "cursorarrow"; case .crop: "crop"; case .text: "textformat"; case .pen: "pencil.tip"; case .arrow: "arrow.up.right"; case .rectangle: "rectangle" } }
}

enum ImageCropAspect: String, CaseIterable, Identifiable {
    case free, original, widescreen, standard, square, portrait, story
    var id: String { rawValue }
    var title: String { switch self {
    case .free: "Freeform"; case .original: "Original"; case .widescreen: "16:9 · Slides"; case .standard: "4:3 · Slides"
    case .square: "1:1 · Square"; case .portrait: "4:5 · Portrait"; case .story: "9:16 · Vertical"
    } }
    func ratio(image: CGSize, rotation: Int) -> Double? {
        let ratio: Double?
        switch self {
        case .free: ratio = nil
        case .original: return image.width / image.height
        case .widescreen: ratio = 16 / 9
        case .standard: ratio = 4 / 3
        case .square: ratio = 1
        case .portrait: ratio = 4 / 5
        case .story: ratio = 9 / 16
        }
        return ratio.map { rotation % 2 == 0 ? $0 : 1 / $0 }
    }
}

/// Geometry is in original pixels, independent of zoom and display scale.
enum ImageWorkspaceGeometry {
    static func originalDelta(x: Double, y: Double, rotation: Int) -> CGPoint {
        switch rotation { case 1: CGPoint(x: -y, y: x); case 2: CGPoint(x: -x, y: -y); case 3: CGPoint(x: y, y: -x); default: CGPoint(x: x, y: y) }
    }
    static func crop(from a: SnapPoint, to b: SnapPoint, aspect: Double?, image: CGSize) -> SnapCrop {
        var w = abs(b.x - a.x), h = abs(b.y - a.y)
        if let aspect {
            let normalized = aspect * image.height / image.width
            if w / max(h, 0.000001) > normalized { h = w / normalized } else { w = h * normalized }
            let maxW = b.x >= a.x ? 1 - a.x : a.x, maxH = b.y >= a.y ? 1 - a.y : a.y
            let factor = min(1, maxW / max(w, 0.000001), maxH / max(h, 0.000001))
            w *= factor; h *= factor
        }
        return SnapCrop(x: b.x >= a.x ? a.x : a.x - w, y: b.y >= a.y ? a.y : a.y - h, width: w, height: h)
    }
    static func fittedCrop(_ crop: SnapCrop, aspect: Double, image: CGSize) -> SnapCrop {
        let ratio = aspect * image.height / image.width
        let w = min(crop.width, crop.height * ratio), h = min(crop.height, crop.width / ratio)
        return SnapCrop(x: crop.x + (crop.width - w) / 2, y: crop.y + (crop.height - h) / 2, width: w, height: h)
    }
    static func bounds(_ mark: SnapMark) -> CGRect {
        guard let first = mark.points.first else { return .zero }
        let xs = mark.points.map(\.x), ys = mark.points.map(\.y)
        return CGRect(x: xs.min() ?? first.x, y: ys.min() ?? first.y,
                      width: (xs.max() ?? first.x) - (xs.min() ?? first.x), height: (ys.max() ?? first.y) - (ys.min() ?? first.y))
    }
    static func moved(_ mark: SnapMark, dx: Double, dy: Double) -> SnapMark {
        let bounds = bounds(mark)
        let x = min(1 - bounds.maxX, max(-bounds.minX, dx)), y = min(1 - bounds.maxY, max(-bounds.minY, dy))
        var result = mark; result.points = mark.points.map { SnapPoint(x: $0.x + x, y: $0.y + y) }
        return result
    }
    /// Display unit coordinates to original normalized coordinates, with crop and clockwise rotation.
    static func originalPoint(_ p: CGPoint, crop: SnapCrop, rotation: Int) -> SnapPoint {
        let q: CGPoint
        switch rotation { case 1: q = CGPoint(x: 1 - p.y, y: p.x); case 2: q = CGPoint(x: 1 - p.x, y: 1 - p.y)
        case 3: q = CGPoint(x: p.y, y: 1 - p.x); default: q = p }
        return SnapPoint(x: min(1, max(0, crop.x + q.x * crop.width)), y: min(1, max(0, crop.y + q.y * crop.height)))
    }
}

@MainActor
final class ImageWorkspaceEditing: ObservableObject {
    @Published var draft: SnapDraft
    @Published var tool: ImageWorkspaceTool = .select
    @Published var aspect: ImageCropAspect = .free
    @Published var selected: UUID?
    @Published var colour = "red"
    @Published var background = "white"
    @Published var fontSize = 0.035
    @Published var lineWidth = 0.004
    @Published var showingOriginal = false
    @Published var showingDetails = true
    @Published var percent = 100
    @Published private(set) var undoStack: [SnapEdit] = []
    @Published private(set) var redoStack: [SnapEdit] = []
    let image: CGImage
    let initial: SnapDraft
    weak var canvas: ImageWorkspaceScrollView?
    var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
    var selectedMark: SnapMark? { draft.edit.marks.first { $0.id == selected } }
    var dirty: Bool { draft.edit != initial.edit || draft.title != initial.title || draft.notes != initial.notes || draft.tags != initial.tags }
    var displayEdit: SnapEdit {
        if showingOriginal { return SnapEdit() }
        var edit = draft.edit
        if tool == .crop { edit.crop = .full }
        return edit
    }
    init(draft: SnapDraft) throws { self.draft = draft; initial = draft; image = try SnapRendering.image(draft.originalPNG) }
    func change(_ edit: SnapEdit) {
        guard edit != draft.edit, edit.isValid else { return }
        undoStack.append(draft.edit)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack = []; draft.edit = edit
    }
    func mutate(_ body: (inout SnapEdit) -> Void) { var edit = draft.edit; body(&edit); change(edit) }
    func undo() { guard let edit = undoStack.popLast() else { return }; redoStack.append(draft.edit); draft.edit = edit; selected = nil }
    func redo() { guard let edit = redoStack.popLast() else { return }; undoStack.append(draft.edit); draft.edit = edit; selected = nil }
    func select(_ id: UUID?) {
        selected = id
        if let mark = selectedMark { colour = mark.colour; lineWidth = mark.width; fontSize = mark.fontSize ?? fontSize; background = mark.background ?? "none" }
    }
    func updateSelected(_ body: (inout SnapMark) -> Void) {
        guard let index = draft.edit.marks.firstIndex(where: { $0.id == selected }) else { return }
        mutate { body(&$0.marks[index]) }
    }
    func removeSelected() { guard let selected else { return }; mutate { $0.marks.removeAll { $0.id == selected } }; self.selected = nil }
    func setAspect(_ value: ImageCropAspect) {
        aspect = value
        guard let ratio = value.ratio(image: imageSize, rotation: draft.edit.quarterTurns) else { return }
        mutate { $0.crop = ImageWorkspaceGeometry.fittedCrop($0.crop, aspect: ratio, image: imageSize) }
    }
    func rotate() {
        mutate { $0.rotation = ($0.quarterTurns + 1) % 4 }
        aspect = .free
    }
    func addText(at point: SnapPoint? = nil) {
        let crop = draft.edit.crop
        let sideways = draft.edit.quarterTurns % 2 != 0
        let w = crop.width * (sideways ? 0.25 : 0.6), h = crop.height * (sideways ? 0.6 : 0.25)
        let x = min(1 - w, max(0, point?.x ?? (crop.x + (crop.width - w) / 2)))
        let y = min(1 - h, max(0, point?.y ?? (crop.y + (crop.height - h) / 2)))
        let mark = SnapMark(kind: .text, points: [.init(x: x, y: y), .init(x: x + w, y: y + h)],
                            colour: background == "black" ? "white" : "black", text: "Your text", fontSize: fontSize,
                            background: background, textRotation: (4 - draft.edit.quarterTurns) % 4)
        mutate { $0.marks.append(mark) }; select(mark.id); tool = .select; showingDetails = true
    }
    func zoom(_ command: CaptureImagePreviewModel.Command) {
        switch command { case .fit: canvas?.fit(); case .actualSize: canvas?.zoom(to: 1)
        case .zoomIn: canvas?.zoom(to: (canvas?.magnification ?? 1) * 1.25)
        case .zoomOut: canvas?.zoom(to: (canvas?.magnification ?? 1) / 1.25) }
    }
}
