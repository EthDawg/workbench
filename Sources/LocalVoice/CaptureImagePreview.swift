import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// One image in the shared workspace: a Snap's current
/// revision, a Snap & Talk section's screenshot or a task's saved copy. It is
/// named for the person and for VoiceOver, and says what to show when its
/// file cannot be read.
struct CaptureImagePreviewItem: Equatable {
    enum Source: Equatable {
        /// A file read as it is, such as a section screenshot or a task's saved copy.
        case file(URL?, missing: String)
        /// A Snap's current image: the rendered edit when there is one, checked against its record.
        case snap(root: URL, id: UUID)
        /// Bytes already in hand, such as an image a Hand off is about to share.
        case bytes(Data)
        case generated(UUID)
    }
    var title: String
    var detail: String
    var source: Source
    var render: (@MainActor () throws -> Data)? = nil
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.title == rhs.title && lhs.detail == rhs.detail && lhs.source == rhs.source }

    /// A Snap & Talk section. Active sections are numbered as the session shows them.
    static func section(_ section: ReadbackSection, number: Int?, session: URL?) -> Self {
        let captured = section.capturedAt.formatted(date: .abbreviated, time: .shortened)
        let deleted = section.deletedAt.map { " · Recently deleted " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        return .init(title: sectionTitle(number: number, section: section),
                     detail: "\(section.displayName) · Captured \(captured)" + deleted,
                     source: .file(session.flatMap { try? ReadbackStore.safeURL(root: $0, relative: section.screenshot) },
                                   missing: "This screenshot is missing from the session folder. The section and its narration are unchanged."))
    }
    /// A deleted section has no number, and its display name is shared by every
    /// capture from that display, so it is named by when it was captured.
    static func sectionTitle(number: Int?, section: ReadbackSection) -> String {
        number.map { "Screenshot for section \($0)" } ?? "Screenshot captured \(ReadbackItemNames.captured(section)), recently deleted"
    }

    /// A Snap in History or on the Snap page, archived or not.
    static func snap(_ item: SnapItem, store: SnapStore) -> Self {
        var detail = "Snap · \(item.source.title) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))"
        if item.edit != SnapEdit() { detail += " · Edited; the original is kept" }
        if item.archivedAt != nil { detail += " · Archived" }
        return .init(title: item.title, detail: detail, source: .snap(root: store.root, id: item.id))
    }

    /// An image the Hand off review is about to share.
    static func toShare(title: String, png: Data) -> Self {
        .init(title: "Image to share for \(title)", detail: "The image this Hand off will share, as it will be sent.", source: .bytes(png))
    }

    /// The frozen copy a Hand off task used, which outlives the item it came from.
    static func savedCopy(title: String, url: URL?) -> Self {
        .init(title: "Saved image for \(title)", detail: "The copy this task used. Changing or archiving the original does not change it.",
              source: .file(url, missing: "This saved image is missing from the task’s folder."))
    }
}

enum CaptureImagePreviewError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let message) = self { return message }; return nil }
}

/// A decoded preview image and the size of the image it came from, which is
/// what Actual size shows even when a very large image was decoded smaller.
struct CapturePreviewImage {
    let image: CGImage
    let pixelSize: CGSize
    var sourceBytes: Data? = nil
}

/// Set once a preview is closed or replaced, so a decode that has not started never starts.
final class CapturePreviewCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Reads and decodes a preview image on its own queue, off the main thread and
/// outside Swift's shared pool. It never writes, moves or copies the file.
enum CaptureImageLoader {
    static let maximumBytes = 100 * 1_024 * 1_024
    static let queue = DispatchQueue(label: "Workbench.CaptureImagePreview", qos: .userInitiated)

    /// About twice the largest display's longer side in pixels, within 2,048 and 8,192: a larger
    /// image is decoded at this size, so an unusually large import cannot exhaust memory.
    @MainActor static func pixelLimit(screens: [NSScreen] = NSScreen.screens) -> Int {
        let largest = screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 2_560
        return min(8_192, max(2_048, Int(largest * 2)))
    }

    static func bytes(_ source: CaptureImagePreviewItem.Source) throws -> Data {
        let data: Data
        switch source {
        case .file(let url, let missing):
            guard let url, let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? Int.max) <= maximumBytes, let bytes = try? Data(contentsOf: url) else { throw CaptureImagePreviewError.unavailable(missing) }
            guard (values.fileSize ?? bytes.count) <= maximumBytes, bytes.count <= maximumBytes else {
                throw CaptureImagePreviewError.unavailable("This image is larger than 100 MB, so it is not shown here. Its file is unchanged.")
            }
            data = bytes
        case .snap(let root, let id):
            // A store of its own: SnapStore's load state belongs to the main thread's owner.
            data = try SnapStore(root: root).snapshot(id).imagePNG
        case .bytes(let bytes):
            data = bytes
        case .generated:
            throw CaptureImagePreviewError.unavailable("This image could not be prepared. Its source is unchanged.")
        }
        guard data.count <= maximumBytes else { throw CaptureImagePreviewError.unavailable("Choose an image under 100 MB.") }
        return data
    }

    static func image(_ source: CaptureImagePreviewItem.Source, maximumPixelSize: Int,
                      cancellation: CapturePreviewCancellation = CapturePreviewCancellation()) throws -> CapturePreviewImage {
        // A preview closed while this waited in the queue reads nothing, not even up to 100 MB of file.
        if cancellation.isCancelled { throw CancellationError() }
        let data = try bytes(source)
        if cancellation.isCancelled { throw CancellationError() }
        let notAnImage = CaptureImagePreviewError.unavailable("This file is not an image Workbench can show. It is unchanged.")
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw notAnImage }
        let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        let image = max(width, height) > maximumPixelSize || orientation != 1
            ? CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize] as CFDictionary)
            : CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        guard let image else { throw notAnImage }
        return CapturePreviewImage(image: image, pixelSize: (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height), sourceBytes: data)
    }
}

/// Zoom steps shared by the buttons, the keys and the checks. Magnification 1
/// is Actual size: one image pixel on one screen pixel.
enum CaptureImageZoom {
    static let step: CGFloat = 1.25
    static let largest: CGFloat = 8
    /// Fit never enlarges a small image past its actual size. An exact ratio can round to an
    /// image a hair larger than the window, and a scroll bar that is always shown would then
    /// appear and crop it, so a fit stays just inside (#188).
    static func fit(image: CGSize, in viewport: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        let ratio = min(viewport.width / image.width, viewport.height / image.height)
        return ratio < 1 ? ratio * (1 - 1e-9) : 1
    }
    static func smallest(fit: CGFloat) -> CGFloat { min(fit, 0.1) }
    static func clamp(_ magnification: CGFloat, fit: CGFloat) -> CGFloat { min(largest, max(smallest(fit: fit), magnification)) }
    /// The image's size in points at actual size on a display of this scale.
    static func actualSize(pixels: CGSize, backingScale: CGFloat) -> CGSize {
        let scale = max(1, backingScale)
        return CGSize(width: pixels.width / scale, height: pixels.height / scale)
    }
    static func percent(_ magnification: CGFloat) -> Int { Int((magnification * 100).rounded()) }
}

@MainActor
final class CaptureImagePreviewModel: ObservableObject {
    enum State { case loading, shown(CapturePreviewImage), unavailable(String) }
    enum Command { case fit, actualSize, zoomIn, zoomOut }
    let item: CaptureImagePreviewItem
    @Published private(set) var state: State = .loading
    @Published var notice: String?
    @Published fileprivate(set) var percent = 100
    fileprivate weak var view: PreviewImageScrollView?
    private var loading: Task<Void, Never>?
    private var noticeEvent = UUID()
    private let cancellation = CapturePreviewCancellation()

    init(item: CaptureImagePreviewItem) { self.item = item }
    func report(_ message: String, success: Bool) {
        notice = message; noticeEvent = UUID()
        guard success else { return }
        FeedbackAnnouncement.post(message)
        let event = noticeEvent
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if let self, self.noticeEvent == event { self.notice = nil }
        }
    }

    func load() {
        let source: CaptureImagePreviewItem.Source
        do { source = try item.render.map { .bytes(try $0()) } ?? item.source }
        catch { state = .unavailable(error.localizedDescription); return }
        let limit = CaptureImageLoader.pixelLimit(), cancellation = cancellation
        loading = Task { [weak self] in
            let result: Result<CapturePreviewImage, Error> = await withCheckedContinuation { finished in
                CaptureImageLoader.queue.async {
                    finished.resume(returning: Result { try CaptureImageLoader.image(source, maximumPixelSize: limit, cancellation: cancellation) })
                }
            }
            guard let self, !cancellation.isCancelled else { return }
            switch result {
            case .success(let image): self.state = .shown(image)
            case .failure(let error): self.state = .unavailable(error.localizedDescription)
            }
        }
    }
    /// Closing or replacing the preview stops a decode that has not started and drops any result.
    func cancel() { cancellation.cancel(); loading?.cancel() }

    func perform(_ command: Command) {
        guard let view else { return }
        switch command {
        case .fit: view.fit()
        case .actualSize: view.zoom(to: 1)
        case .zoomIn: view.zoom(to: view.magnification * CaptureImageZoom.step)
        case .zoomOut: view.zoom(to: view.magnification / CaptureImageZoom.step)
        }
    }
    var isShowingImage: Bool { if case .shown = state { return true }; return false }
}

/// Viewing and editing share this window, with explicit save boundaries.
struct CaptureImagePreviewView: View {
    @ObservedObject var model: CaptureImagePreviewModel
    var position = ""
    var previous: (() -> Void)? = nil
    var next: (() -> Void)? = nil
    var edit: (() -> Void)? = nil
    var editTitle = "Edit a copy"
    var copy: (() -> Void)? = nil
    var export: (() -> Void)? = nil
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.item.title).font(.headline).lineLimit(1)
                    Text(model.item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 12)
                if let copy { Button("Copy image", action: copy).disabled(!model.isShowingImage) }
                if let export { Button("Export…", action: export).disabled(!model.isShowingImage) }
                if let edit { Button(editTitle, action: edit).buttonStyle(.borderedProminent).disabled(!model.isShowingImage) }
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            switch model.state {
            case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .shown(let image): PreviewImage(loaded: image, model: model, accessibilityLabel: model.item.title)
            case .unavailable(let message):
                VStack(spacing: 10) {
                    Image(systemName: "photo.badge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                    Text(message).multilineTextAlignment(.center).frame(maxWidth: 420)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let notice = model.notice { Text(notice).font(.callout).padding(8) }
            Divider()
            HStack(spacing: 10) {
                if !position.isEmpty {
                    Button { previous?() } label: { Image(systemName: "chevron.left") }.disabled(previous == nil).accessibilityLabel("Previous image").help("Previous image (←)")
                    Text(position).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Button { next?() } label: { Image(systemName: "chevron.right") }.disabled(next == nil).accessibilityLabel("Next image").help("Next image (→)")
                }
                if case .shown(let image) = model.state {
                    Text("\(Int(image.pixelSize.width)) × \(Int(image.pixelSize.height)) px").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                ImageWorkspaceZoomControls(percent: model.percent, perform: model.perform).disabled(!model.isShowingImage)
            }.padding(.horizontal, 16).padding(.vertical, 10)
        }.frame(minWidth: 720, minHeight: 440).tint(Workbench.accent).workbenchTheme()
    }
}

private struct PreviewImage: NSViewRepresentable {
    let loaded: CapturePreviewImage
    let model: CaptureImagePreviewModel
    let accessibilityLabel: String
    func makeNSView(context: Context) -> PreviewImageScrollView {
        let view = PreviewImageScrollView()
        view.onZoom = { [weak model] percent in model?.percent = percent }
        model.view = view
        view.show(loaded, label: accessibilityLabel)
        return view
    }
    func updateNSView(_ view: PreviewImageScrollView, context: Context) {
        if view.image !== loaded.image { view.show(loaded, label: accessibilityLabel) }
    }
}

/// A scroll view that shows one image at a chosen magnification. It fits the
/// window until the person zooms, stays centred when smaller than the window,
/// and follows pinch.
final class PreviewImageScrollView: NSScrollView {
    private let imageView = NSImageView()
    private(set) var image: CGImage?
    /// The original image's pixels, which Actual size shows one to one.
    private(set) var pixelSize: CGSize = .zero
    /// Fitting follows window resizes until the person chooses a zoom.
    private(set) var fitting = true
    var onZoom: ((Int) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        contentView = CenteringClipView()
        backgroundColor = .underPageBackgroundColor; drawsBackground = true
        hasHorizontalScroller = true; hasVerticalScroller = true; autohidesScrollers = true
        allowsMagnification = true
        imageView.imageScaling = .scaleAxesIndependently
        imageView.isEditable = false; imageView.allowsCutCopyPaste = false
        imageView.setAccessibilityRole(.image)
        documentView = imageView
        NotificationCenter.default.addObserver(self, selector: #selector(pinched), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    /// The space a fitted image has. Scroll bars hide once it fits, whether the Mac shows them
    /// always or only while scrolling, so they never count (#188).
    private var fitSpace: NSSize {
        NSScrollView.contentSize(forFrameSize: frame.size, horizontalScrollerClass: nil, verticalScrollerClass: nil,
                                 borderType: borderType, controlSize: .regular, scrollerStyle: scrollerStyle)
    }
    var fitMagnification: CGFloat { CaptureImageZoom.fit(image: imageView.frame.size, in: fitSpace) }

    func show(_ loaded: CapturePreviewImage, label: String) {
        image = loaded.image; pixelSize = loaded.pixelSize
        imageView.image = NSImage(cgImage: loaded.image, size: .zero)
        imageView.setAccessibilityLabel(label)
        layoutImage()
        fit()
    }

    private func layoutImage() {
        guard let image else { return }
        let size = CaptureImageZoom.actualSize(pixels: pixelSize == .zero ? CGSize(width: image.width, height: image.height) : pixelSize, backingScale: backingScale)
        imageView.frame = NSRect(origin: .zero, size: size)
        minMagnification = CaptureImageZoom.smallest(fit: fitMagnification)
        maxMagnification = CaptureImageZoom.largest
    }

    func fit() {
        fitting = true
        minMagnification = CaptureImageZoom.smallest(fit: fitMagnification)
        magnification = fitMagnification
        report()
    }

    /// Zooms about the centre of what is showing.
    func zoom(to proposed: CGFloat) {
        fitting = false
        let visible = contentView.documentVisibleRect
        setMagnification(CaptureImageZoom.clamp(proposed, fit: fitMagnification), centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        report()
    }

    private func report() { onZoom?(CaptureImageZoom.percent(magnification)) }
    @objc private func pinched() { fitting = false; report() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if fitting, image != nil { fit() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Actual size means one image pixel per screen pixel on this display.
        layoutImage()
        if fitting { fit() } else { report() }
    }
}

/// Keeps an image smaller than the window in its middle.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView?.frame else { return rect }
        if rect.width > document.width { rect.origin.x = (document.width - rect.width) / 2 }
        if rect.height > document.height { rect.origin.y = (document.height - rect.height) / 2 }
        return rect
    }
}

/// Escape closes the preview only, never Workbench, and the usual zoom keys
/// work wherever focus is inside it.
final class CaptureImagePreviewPanel: NSPanel {
    var constrainsToScreen = true
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        constrainsToScreen ? super.constrainFrameRect(frameRect, to: screen) : frameRect
    }
    var command: ((CaptureImagePreviewModel.Command) -> Void)?
    var navigate: ((Int) -> Void)?
    var requestClose: (() -> Void)?
    override func cancelOperation(_ sender: Any?) {
        if (firstResponder as? ImageWorkspaceCanvasView)?.cancelCurrentGesture() == true { return }
        if let requestClose { requestClose() } else { close() }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, (firstResponder as? ImageWorkspaceCanvasView)?.cancelCurrentGesture() == true { return true }
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           !(firstResponder is NSTextView), let navigate, [123, 124].contains(event.keyCode) {
            navigate(event.keyCode == 123 ? -1 : 1); return true
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .numericPad, .function])
        guard modifiers == .command, let key = event.charactersIgnoringModifiers,
              let command = Self.command(for: key) else { return super.performKeyEquivalent(with: event) }
        self.command?(command)
        return true
    }
    static func command(for key: String) -> CaptureImagePreviewModel.Command? {
        switch key {
        case "+", "=": .zoomIn
        case "-", "_", "−": .zoomOut
        case "0": .actualSize
        case "9": .fit
        default: nil
        }
    }
}

/// Owns the one preview window. Showing another image replaces what it shows;
/// the page underneath keeps its section, scroll and selection.
@MainActor
final class CaptureImagePreview: NSObject, NSWindowDelegate {
    static let shared = CaptureImagePreview()
    /// Brings the window forward. Checks keep it off every display.
    var present: (NSPanel) -> Void = { $0.makeKeyAndOrderFront(nil) }
    private(set) var panel: CaptureImagePreviewPanel?
    private(set) var model: CaptureImagePreviewModel?
    private var parentObserver: NSObjectProtocol?

    weak var snapOwner: SnapModel?
    private(set) var editing: ImageWorkspaceEditing?
    private(set) var items: [CaptureImagePreviewItem] = []
    private(set) var index = 0
    private var editingFromPreview = false
    /// Read scopes and generated images belong to this visit, not the library.
    var onClose: (() -> Void)?
    var approveDiscard: (() -> Bool)?

    func attach(to snap: SnapModel, parent: @escaping () -> NSWindow?, stateChanged: @escaping () -> Void) {
        snapOwner = snap
        snap.onStateChange = { [weak self, weak snap] in
            stateChanged()
            if let snap, let draft = snap.draft { self?.showEditor(snap: snap, draft: draft, over: parent()) }
        }
    }

    func show(_ item: CaptureImagePreviewItem, over parent: NSWindow? = nil,
              collection: [CaptureImagePreviewItem] = []) {
        guard editing == nil else { if let panel { present(panel) }; return }
        onClose?(); onClose = nil
        items = collection.contains(item) ? collection : [item]
        index = items.firstIndex(of: item) ?? 0
        showCurrent(over: parent)
    }

    func step(_ offset: Int) {
        guard editing == nil, items.indices.contains(index + offset) else { return }
        index += offset; showCurrent()
    }

    func showLibrary(_ resources: [DemoResource], selected: UUID) {
        let collection = resources.map { resource in
            CaptureImagePreviewItem(title: resource.title, detail: "Library image · Edit a copy to save in Snap History", source: .generated(resource.id)) {
                guard let resolved = resource.resolvedFile else { throw CaptureImagePreviewError.unavailable("Locate this file again to reconnect it.") }
                let url = resolved.url, access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return try CaptureImageLoader.bytes(.file(url, missing: "This image is unavailable. Reconnect its drive or locate the file again."))
            }
        }
        if let index = resources.firstIndex(where: { $0.id == selected }) { show(collection[index], collection: collection) }
    }

    private func showCurrent(over parent: NSWindow? = nil) {
        guard items.indices.contains(index) else { return }
        let item = items[index], model = CaptureImagePreviewModel(item: items[index])
        let panel = self.panel ?? makePanel(over: parent ?? NSApp.mainWindow)
        self.model?.cancel(); self.model = model
        panel.title = item.title; panel.setAccessibilityTitle(item.title)
        panel.command = { [weak model] in model?.perform($0) }
        panel.navigate = { [weak self] in self?.step($0) }
        panel.requestClose = { [weak self] in self?.close() }
        let canEdit = snapOwner != nil
        let content = NSHostingView(rootView: CaptureImagePreviewView(model: model,
            position: items.count > 1 ? "\(index + 1) of \(items.count)" : "",
            previous: index > 0 ? { [weak self] in self?.step(-1) } : nil,
            next: index + 1 < items.count ? { [weak self] in self?.step(1) } : nil,
            edit: canEdit ? { [weak self] in self?.beginEditing() } : nil,
            editTitle: editableSnapID(item) != nil ? "Edit" : "Edit a copy",
            copy: { [weak self] in self?.copyImage() }, export: { [weak self] in self?.exportImage() },
            close: { [weak self] in self?.close() }))
        content.sizingOptions = [.minSize]; panel.contentView = content
        model.load(); present(panel)
    }

    private func editableSnapID(_ item: CaptureImagePreviewItem) -> UUID? {
        guard case .snap(let root, let id) = item.source, root == snapOwner?.store.root,
              let current = try? snapOwner?.store.read(id), current.archivedAt == nil else { return nil }
        return id
    }
    func beginEditing() {
        guard let snap = snapOwner, let item = model?.item, editing == nil else { return }
        if snap.isBusy { model?.notice = "Finish the open Snap before editing another image."; return }
        editingFromPreview = true
        if let id = editableSnapID(item) { snap.edit(id) }
        else {
            do { try snap.editCopy(shownBytes(), title: item.title) }
            catch { model?.notice = error.localizedDescription }
        }
        if let draft = snap.draft { showEditor(snap: snap, draft: draft) }
        else {
            if let message = snap.notice { model?.report(message, success: false) }
            editingFromPreview = false
        }
    }

    func showEditor(snap: SnapModel, draft: SnapDraft, over parent: NSWindow? = nil) {
        if editing?.draft.id == draft.id { if let panel { present(panel) }; return }
        guard editing == nil else { return }
        do {
            let editor = try ImageWorkspaceEditing(draft: draft)
            snapOwner = snap; editing = editor
            let panel = self.panel ?? makePanel(over: parent ?? NSApp.mainWindow)
            panel.title = draft.existing == nil ? "New Snap" : draft.title
            panel.setAccessibilityTitle(panel.title)
            panel.minSize = NSSize(width: 820, height: 560)
            if panel.frame.width < 1_080 || panel.frame.height < 680 {
                let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
                panel.setContentSize(NSSize(width: min(1_180, visible.width - 40), height: min(780, visible.height - 60)))
            }
            panel.command = { [weak editor] in editor?.zoom($0) }; panel.navigate = nil
            panel.requestClose = { [weak self] in self?.cancelEditing() }
            let content = NSHostingView(rootView: SnapEditorView(model: snap, editing: editor,
                save: { [weak self] in self?.saveEditing(copy: $0) }, cancel: { [weak self] in self?.cancelEditing() }))
            content.sizingOptions = [.minSize]; panel.contentView = content; present(panel)
        } catch { snap.notice = error.localizedDescription }
    }

    func saveEditing(copy: Bool) {
        guard let editing, let snap = snapOwner else { return }
        var draft = editing.draft
        draft.tags = Array(Set(draft.tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        var savedItem: SnapItem?
        if snap.saveDraft(draft, copyAfterSaving: copy, didSave: { savedItem = $0 }) {
            if let savedItem, items.indices.contains(index) {
                // After Edit a copy, show what was just saved while keeping the original source untouched.
                items[index] = .snap(savedItem, store: snap.store)
            }
            let message = snap.notice ?? snap.confirmation?.kind.rawValue
            finishEditing()
            if let message { model?.report(message, success: snap.notice == nil) }
        }
    }
    func cancelEditing() {
        guard resolveDiscard() else { return }
        snapOwner?.draft = nil; finishEditing()
    }
    private func resolveDiscard() -> Bool {
        guard editing?.dirty == true else { return true }
        if let approveDiscard { return approveDiscard() }
        let alert = NSAlert(); alert.messageText = "Discard these image edits?"
        alert.informativeText = "Your saved image and original will stay unchanged."
        alert.addButton(withTitle: "Keep editing"); alert.addButton(withTitle: "Discard edits")
        return alert.runModal() == .alertSecondButtonReturn
    }
    /// Decide before shutdown starts, without discarding if another activity later cancels Quit.
    func canTerminate() -> Bool { resolveDiscard() }
    private func finishEditing() {
        editing = nil
        if editingFromPreview { editingFromPreview = false; showCurrent() }
        else { close() }
    }
    private func copyImage() {
        guard model?.isShowingImage == true else { return }
        do {
            let bytes = try SnapRendering.png(shownBytes())
            NSPasteboard.general.clearContents()
            let copied = NSPasteboard.general.setData(bytes, forType: .png)
            model?.report(copied ? "Image copied. Paste with ⌘V." : "The image could not be copied.", success: copied)
        } catch { model?.notice = error.localizedDescription }
    }
    private func exportImage() {
        guard let item = model?.item else { return }
        let save = NSSavePanel(); save.allowedContentTypes = [.png]; save.nameFieldStringValue = item.title + ".png"
        guard save.runModal() == .OK, let url = save.url else { return }
        do { try SnapRendering.png(shownBytes()).write(to: url, options: .atomic); model?.report("Image exported.", success: true) }
        catch { model?.notice = error.localizedDescription }
    }
    private func shownBytes() throws -> Data {
        guard case .shown(let image) = model?.state, let bytes = image.sourceBytes else {
            throw CaptureImagePreviewError.unavailable("Wait for the image to finish opening.")
        }
        return bytes
    }
    func close() {
        guard admitClose() else { return }
        panel?.close()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        admitClose()
    }
    private func admitClose() -> Bool {
        guard resolveDiscard() else { return false }
        if editing != nil { editing = nil; snapOwner?.draft = nil; editingFromPreview = false }
        return true
    }
    private func parentWillClose() {
        guard editing != nil, let panel else { close(); return }
        // The main window can close independently. Keep the draft's own window alive.
        panel.parent?.removeChildWindow(panel)
        if let parentObserver { NotificationCenter.default.removeObserver(parentObserver) }
        parentObserver = nil
        present(panel)
    }

    private func makePanel(over owner: NSWindow?) -> CaptureImagePreviewPanel {
        let visible = (owner?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_280, height: 800)
        let size = NSSize(width: min(1_600, max(520, visible.width * 0.8)), height: min(1_100, max(360, visible.height * 0.85)))
        let panel = CaptureImagePreviewPanel(contentRect: NSRect(origin: .zero, size: size),
                                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior.insert(.fullScreenPrimary)
        panel.minSize = NSSize(width: 520, height: 360)
        panel.delegate = self
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        if let owner {
            // It travels with Workbench's window, so it is also hidden while a capture hides that window.
            owner.addChildWindow(panel, ordered: .above)
            parentObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.parentWillClose() }
            }
        }
        self.panel = panel
        return panel
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        window.parent?.removeChildWindow(window)
        window.delegate = nil
        if let parentObserver { NotificationCenter.default.removeObserver(parentObserver) }
        parentObserver = nil
        model?.cancel(); model = nil; panel = nil; editing = nil; items = []
        onClose?(); onClose = nil
    }
}

/// Names for Snap & Talk sections' preview doors, shared with the checks.
enum ReadbackItemNames {
    static func view(sectionNumber: Int) -> String { "View screenshot for section \(sectionNumber)" }
    static func viewDeleted(_ section: ReadbackSection) -> String { "View screenshot captured \(captured(section)), recently deleted" }
    /// With seconds, so two sections captured in the same minute still have different names.
    static func captured(_ section: ReadbackSection) -> String { section.capturedAt.formatted(date: .abbreviated, time: .standard) }
}

/// A capture thumbnail that opens the shared image workspace on click, and on
/// Space or Return when focused. Editing and replacing stay separate actions.
struct CapturePreviewButton<Label: View>: View {
    let accessibilityLabel: String
    let item: () -> CaptureImagePreviewItem
    let label: Label
    let collection: () -> [CaptureImagePreviewItem]

    init(_ accessibilityLabel: String, item: @escaping () -> CaptureImagePreviewItem, collection: @escaping () -> [CaptureImagePreviewItem] = { [] }, @ViewBuilder label: () -> Label) {
        self.accessibilityLabel = accessibilityLabel; self.item = item; self.label = label(); self.collection = collection
    }

    var body: some View {
        Button { CaptureImagePreview.shared.show(item(), collection: collection()) } label: { label.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Opens a larger view to read. Escape closes it.")
            .help(accessibilityLabel)
            .onKeyPress(.return) { CaptureImagePreview.shared.show(item(), collection: collection()); return .handled }
    }
}
