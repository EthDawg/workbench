import AppKit
import QuickLookUI

@MainActor
protocol DemoResourcePreviewing: AnyObject {
    var onClose: (() -> Void)? { get set }
    @discardableResult func show(url: URL, title: String) -> Bool
    func close()
}

/// Owns the native Quick Look view without copying or modifying its source file.
@MainActor
final class DemoQuickLookPresenter: NSObject, DemoResourcePreviewing, NSWindowDelegate {
    var onClose: (() -> Void)?
    private(set) var panel: DemoQuickLookPanel?

    @discardableResult func show(url: URL, title: String) -> Bool {
        close()
        guard let preview = QLPreviewView(frame: .zero, style: .normal) else { return false }
        preview.shouldCloseWithWindow = true
        preview.autostarts = false
        preview.previewItem = url as NSURL

        let panel = DemoQuickLookPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Quick Look — \(title)"
        panel.contentView = preview
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 480, height: 320)
        panel.center()
        if let owner = NSApp.mainWindow { owner.addChildWindow(panel, ordered: .above) }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        return panel.isVisible
    }

    func close() { panel?.close() }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        if let parent = window.parent { parent.removeChildWindow(window) }
        window.delegate = nil
        panel = nil
        onClose?()
    }
}

/// Escape is scoped to the preview panel and never closes Workbench itself.
final class DemoQuickLookPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
}

final class DemoResourcePreviewAccess {
    let url: URL
    private let shouldStop: Bool
    private let stop: (URL) -> Void
    private var released = false

    init(url: URL,
         start: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stop: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.url = url
        shouldStop = start(url)
        self.stop = stop
    }

    func release() {
        guard !released else { return }
        released = true
        if shouldStop { stop(url) }
    }

    deinit { release() }
}
