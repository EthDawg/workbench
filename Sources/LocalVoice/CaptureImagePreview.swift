import AppKit
import ImageIO
import SwiftUI

/// One capture image for the read-only preview (#154): a Snap's current
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
    }
    var title: String
    var detail: String
    var source: Source

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

    static func image(_ source: CaptureImagePreviewItem.Source, maximumPixelSize: Int,
                      cancellation: CapturePreviewCancellation = CapturePreviewCancellation()) throws -> CapturePreviewImage {
        let data: Data
        switch source {
        case .file(let url, let missing):
            guard let url, let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let bytes = try? Data(contentsOf: url) else { throw CaptureImagePreviewError.unavailable(missing) }
            guard (values.fileSize ?? bytes.count) <= maximumBytes, bytes.count <= maximumBytes else {
                throw CaptureImagePreviewError.unavailable("This image is larger than 100 MB, so it is not shown here. Its file is unchanged.")
            }
            data = bytes
        case .snap(let root, let id):
            // A store of its own: SnapStore's load state belongs to the main thread's owner.
            data = try SnapStore(root: root).snapshot(id).imagePNG
        case .bytes(let bytes):
            data = bytes
        }
        if cancellation.isCancelled { throw CancellationError() }
        let notAnImage = CaptureImagePreviewError.unavailable("This file is not an image Workbench can show. It is unchanged.")
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw notAnImage }
        let image = max(width, height) > maximumPixelSize
            ? CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize] as CFDictionary)
            : CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        guard let image else { throw notAnImage }
        return CapturePreviewImage(image: image, pixelSize: CGSize(width: width, height: height))
    }
}

/// Zoom steps shared by the buttons, the keys and the checks. Magnification 1
/// is Actual size: one image pixel on one screen pixel.
enum CaptureImageZoom {
    static let step: CGFloat = 1.25
    static let largest: CGFloat = 8
    /// Fit never enlarges a small image past its actual size.
    static func fit(image: CGSize, in viewport: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(1, viewport.width / image.width, viewport.height / image.height)
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
    @Published fileprivate(set) var percent = 100
    fileprivate weak var view: PreviewImageScrollView?
    private var loading: Task<Void, Never>?
    private let cancellation = CapturePreviewCancellation()

    init(item: CaptureImagePreviewItem) { self.item = item }

    func load() {
        let source = item.source, limit = CaptureImageLoader.pixelLimit(), cancellation = cancellation
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

/// The preview's chrome: title, zoom and Close. Nothing here edits, replaces
/// or copies the image.
struct CaptureImagePreviewView: View {
    @ObservedObject var model: CaptureImagePreviewModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.item.title).font(.headline).lineLimit(1)
                    Text(model.item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                if model.isShowingImage {
                    Button("Fit") { model.perform(.fit) }.help("Fit the whole image in the window (⌘9)")
                    Button("Actual size") { model.perform(.actualSize) }.help("One image pixel for each screen pixel (⌘0)")
                    HStack(spacing: 2) {
                        Button { model.perform(.zoomOut) } label: { Image(systemName: "minus.magnifyingglass") }
                            .accessibilityLabel("Zoom out").help("Zoom out (⌘−)")
                        Text("\(model.percent)%").font(.callout.monospacedDigit()).frame(minWidth: 48)
                            .accessibilityLabel("Zoom \(model.percent) percent of actual size")
                        Button { model.perform(.zoomIn) } label: { Image(systemName: "plus.magnifyingglass") }
                            .accessibilityLabel("Zoom in").help("Zoom in (⌘+)")
                    }
                }
                Button("Close", action: close).keyboardShortcut(.cancelAction).help("Close the preview (Escape)")
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            switch model.state {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .shown(let image):
                PreviewImage(loaded: image, model: model, accessibilityLabel: model.item.title)
            case .unavailable(let message):
                VStack(spacing: 10) {
                    Image(systemName: "photo.badge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                    Text(message).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 420)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(minWidth: 520, minHeight: 360).tint(Workbench.accent).workbenchTheme()
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
    var command: ((CaptureImagePreviewModel.Command) -> Void)?
    override func cancelOperation(_ sender: Any?) { close() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
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

    /// Shows `item` over `parent`, or over Workbench's main window. A popover
    /// or panel that asked for it never becomes its owner.
    func show(_ item: CaptureImagePreviewItem, over parent: NSWindow? = nil) {
        let owner = parent ?? NSApp.mainWindow
        let model = CaptureImagePreviewModel(item: item)
        let panel = self.panel ?? makePanel(over: owner)
        self.model?.cancel()
        self.model = model
        panel.title = item.title
        panel.setAccessibilityTitle(item.title)
        panel.command = { [weak model] in model?.perform($0) }
        let content = NSHostingView(rootView: CaptureImagePreviewView(model: model) { [weak self] in self?.close() })
        // The panel keeps its own size; the content only sets a minimum.
        content.sizingOptions = [.minSize]
        panel.contentView = content
        model.load()
        present(panel)
    }

    func close() { panel?.close() }

    private func makePanel(over owner: NSWindow?) -> CaptureImagePreviewPanel {
        let visible = (owner?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_280, height: 800)
        let size = NSSize(width: min(1_600, max(520, visible.width * 0.8)), height: min(1_100, max(360, visible.height * 0.85)))
        let panel = CaptureImagePreviewPanel(contentRect: NSRect(origin: .zero, size: size),
                                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 520, height: 360)
        panel.delegate = self
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        if let owner {
            // It travels with Workbench's window, so it is also hidden while a capture hides that window.
            owner.addChildWindow(panel, ordered: .above)
            parentObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
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
        model?.cancel(); model = nil; panel = nil
    }
}

/// Names for Snap & Talk sections' preview doors, shared with the checks.
enum ReadbackItemNames {
    static func view(sectionNumber: Int) -> String { "View screenshot for section \(sectionNumber)" }
    static func viewDeleted(_ section: ReadbackSection) -> String { "View screenshot captured \(captured(section)), recently deleted" }
    static func captured(_ section: ReadbackSection) -> String { section.capturedAt.formatted(date: .abbreviated, time: .shortened) }
}

/// A capture thumbnail that opens the read-only preview on click, and on
/// Space or Return when focused. Editing and replacing stay separate actions.
struct CapturePreviewButton<Label: View>: View {
    let accessibilityLabel: String
    let item: () -> CaptureImagePreviewItem
    let label: Label

    init(_ accessibilityLabel: String, item: @escaping () -> CaptureImagePreviewItem, @ViewBuilder label: () -> Label) {
        self.accessibilityLabel = accessibilityLabel; self.item = item; self.label = label()
    }

    var body: some View {
        Button { CaptureImagePreview.shared.show(item()) } label: { label.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Opens a larger view to read. Escape closes it.")
            .help(accessibilityLabel)
            .onKeyPress(.return) { CaptureImagePreview.shared.show(item()); return .handled }
    }
}
