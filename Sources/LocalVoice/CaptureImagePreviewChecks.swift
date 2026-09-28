import AppKit
import SwiftUI

/// `LocalVoice --check-capture-preview` (#154): the one
/// read-only preview shows each capture's current image, for Snaps (edited,
/// archived), Snap & Talk sections (replaced, failed, recently deleted) and a
/// task's saved copy, says clearly when a file is missing, fits the window,
/// zooms to actual size and back with the usual keys, and closes on Escape
/// without editing, moving or rewriting anything. Everything is synthetic, in
/// a new temporary folder, and the preview window is never on a display. The
/// surface gallery renders the same window.
@MainActor
enum CaptureImagePreviewChecks {
    static func run() async throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("CAPTURE_PREVIEW_CHECK_FAILED: " + name) }
            count += 1
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("CapturePreviewChecks-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        func load(_ item: CaptureImagePreviewItem, limit: Int = 8_192) -> Result<CapturePreviewImage, Error> {
            Result { try CaptureImageLoader.image(item.source, maximumPixelSize: limit) }
        }
        /// The decoded pixels, which match the original's unless it was larger than the limit.
        func pixels(_ result: Result<CapturePreviewImage, Error>) -> CGSize? {
            (try? result.get()).flatMap { $0.pixelSize == CGSize(width: $0.image.width, height: $0.image.height) ? $0.pixelSize : nil }
        }
        func message(_ result: Result<CapturePreviewImage, Error>) -> String? { if case .failure(let error) = result { return error.localizedDescription }; return nil }
        /// Every file under the folder with its bytes, to show a preview changed nothing.
        func snapshot(_ folder: URL) throws -> [String: Data] {
            var files: [String: Data] = [:]
            for case let url as URL in fm.enumerator(at: folder, includingPropertiesForKeys: nil) ?? FileManager.DirectoryEnumerator() {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files[url.path] = try Data(contentsOf: url) }
            }
            return files
        }

        // Snaps: the current revision is the rendered edit; archived Snaps open too.
        let screen = try screenPNG(width: 2_880, height: 1_800, heading: "Synthetic release notes")
        let store = SnapStore(root: root.appendingPathComponent("Snaps", isDirectory: true))
        let plain = try store.insert(originalPNG: screen, width: 2_880, height: 1_800, title: "Release notes", source: .screen)
        let crop = SnapEdit(crop: .init(x: 0, y: 0.5, width: 0.5, height: 0.5))
        var edited = try store.insert(originalPNG: screen, width: 2_880, height: 1_800, title: "Cropped notes", source: .region)
        edited.edit = crop
        edited = try store.save(edited, renderedPNG: try SnapRendering.render(screen, edit: crop))
        try store.setArchived(true, ids: [plain.id])
        let archived = try store.read(plain.id)
        let snapsBefore = try snapshot(store.root)
        try check(pixels(load(.snap(archived, store: store))) == CGSize(width: 2_880, height: 1_800), "an archived Snap opens at its full size")
        try check(pixels(load(.snap(edited, store: store))) == CGSize(width: 1_440, height: 900), "an edited Snap shows its current, cropped revision")
        try check(CaptureImagePreviewItem.snap(edited, store: store).detail.contains("Edited; the original is kept")
                  && CaptureImagePreviewItem.snap(archived, store: store).detail.contains("Archived"), "the preview says a Snap is edited or archived")
        let changed = store.root.appendingPathComponent(archived.id.uuidString.lowercased()).appendingPathComponent(archived.imageName)
        try Data(try screenPNG(width: 64, height: 40, heading: "x")).write(to: changed)
        try check(message(load(.snap(archived, store: store)))?.contains("changed outside Workbench") == true,
                  "a Snap image changed outside Workbench explains itself instead of showing other bytes")
        try screen.write(to: changed)
        try check(try snapshot(store.root) == snapsBefore, "opening Snaps wrote nothing")

        // Snap & Talk: the current screenshot, after a replacement, in a failed and a recently deleted section.
        let session = root.appendingPathComponent("Synthetic walkthrough", isDirectory: true)
        var manifest = try ReadbackStore.create(at: session, title: "Synthetic walkthrough")
        func section(_ index: Int, status: ReadbackSectionStatus, png: Data) throws -> ReadbackSection {
            let id = UUID(), directory = "items/\(id.uuidString.lowercased())"
            try ReadbackStore.createPrivateDirectory(session.appendingPathComponent(directory))
            try ReadbackStore.writePrivate(png, to: session.appendingPathComponent(directory + "/screen.png"))
            return ReadbackSection(id: id, capturedAt: Date(timeIntervalSince1970: 1_789_546_320 + Double(index) * 60), displayName: "Synthetic display",
                directory: directory, screenshot: directory + "/screen.png", audio: nil, originalTranscript: nil, transcript: nil,
                status: status, failure: status == .failed ? "No speech was recognised. Record the narration again." : nil, deletedAt: nil)
        }
        let first = try section(0, status: .ready, png: try screenPNG(width: 1_470, height: 956, heading: "First screen"))
        let failed = try section(1, status: .failed, png: try screenPNG(width: 1_470, height: 956, heading: "Failed narration"))
        var deleted = try section(2, status: .ready, png: try screenPNG(width: 1_470, height: 956, heading: "Deleted screen"))
        manifest.sections = [first, failed, deleted]
        try ReadbackStore.save(manifest, at: session)
        // Replace Screenshot keeps the old one under history/ and writes the new one in place.
        let history = session.appendingPathComponent(first.directory + "/history")
        try ReadbackStore.createPrivateDirectory(history)
        try fm.moveItem(at: session.appendingPathComponent(first.screenshot), to: history.appendingPathComponent("1-screen.png"))
        let replacement = try screenPNG(width: 2_940, height: 1_912, heading: "Replacement screen")
        try ReadbackStore.writePrivate(replacement, to: session.appendingPathComponent(first.screenshot))
        // Delete moves the whole section into trash/.
        let trashDirectory = "trash/\(deleted.id.uuidString.lowercased())"
        try ReadbackStore.createPrivateDirectory(session.appendingPathComponent("trash"))
        try fm.moveItem(at: session.appendingPathComponent(deleted.directory), to: session.appendingPathComponent(trashDirectory))
        deleted.moveFiles(from: deleted.directory, to: trashDirectory); deleted.deletedAt = Date(timeIntervalSince1970: 1_789_550_000)
        var sameMinute = deleted; sameMinute.capturedAt = deleted.capturedAt.addingTimeInterval(1)
        let sessionBefore = try snapshot(session)
        try check(pixels(load(.section(first, number: 1, session: session))) == CGSize(width: 2_940, height: 1_912),
                  "a replaced section shows its current screenshot")
        try check(pixels(load(.section(failed, number: 2, session: session))) == CGSize(width: 1_470, height: 956),
                  "a section whose transcription failed opens without re-recording")
        try check(pixels(load(.section(deleted, number: nil, session: session))) == CGSize(width: 1_470, height: 956),
                  "a recently deleted section opens without restoring it")
        try check(ReadbackItemNames.view(sectionNumber: 3) == "View screenshot for section 3"
                  && ReadbackItemNames.viewDeleted(deleted) == "View screenshot captured \(deleted.capturedAt.formatted(date: .abbreviated, time: .standard)), recently deleted"
                  && ReadbackItemNames.viewDeleted(deleted) != ReadbackItemNames.viewDeleted(sameMinute)
                  && CaptureImagePreviewItem.section(deleted, number: nil, session: session).title.hasPrefix("Screenshot captured ")
                  && CaptureImagePreviewItem.section(failed, number: 2, session: session).title == "Screenshot for section 2",
                  "section thumbnails and previews have specific names, and recently deleted ones say when they were captured, to the second")
        try check(try snapshot(session) == sessionBefore, "opening sections left the session folder byte for byte as it was")
        try fm.removeItem(at: session.appendingPathComponent(failed.screenshot))
        let sessionNow = try snapshot(session)
        try check(message(load(.section(failed, number: 2, session: session))) == "This screenshot is missing from the session folder. The section and its narration are unchanged.",
                  "a missing screenshot says so instead of failing silently")
        try check(message(load(.section(first, number: 1, session: nil))) != nil, "a section without its session folder says so")

        // A task's saved copy opens as it was frozen, and a missing copy says so.
        let frozen = root.appendingPathComponent("Handoffs/job/inputs/snap.png")
        try fm.createDirectory(at: frozen.deletingLastPathComponent(), withIntermediateDirectories: true)
        try screen.write(to: frozen)
        try check(pixels(load(.savedCopy(title: "Release notes", url: frozen))) == CGSize(width: 2_880, height: 1_800)
                  && (try Data(contentsOf: frozen)) == screen, "a task's saved copy opens unchanged")
        try check(message(load(.savedCopy(title: "Release notes", url: nil))) == "This saved image is missing from the task’s folder.",
                  "a missing saved copy says so")
        // An image the Hand off review is about to share opens from its bytes.
        try check(pixels(load(.toShare(title: "Release notes", png: screen))) == CGSize(width: 2_880, height: 1_800)
                  && CaptureImagePreviewItem.toShare(title: "Release notes", png: screen).title == "Image to share for Release notes",
                  "an image a Hand off is about to share opens as it will be sent")
        // A very large image is decoded no larger than the limit, and Actual size still means its own pixels.
        if case .success(let large) = load(.savedCopy(title: "Release notes", url: frozen), limit: 1_000) {
            try check(max(large.image.width, large.image.height) <= 1_000 && large.pixelSize == CGSize(width: 2_880, height: 1_800),
                      "an image larger than the limit is decoded smaller, keeping its own size for Actual size")
        } else { try check(false, "an image larger than the limit is decoded smaller, keeping its own size for Actual size") }
        try check((2_048...8_192).contains(CaptureImageLoader.pixelLimit(screens: [])) && (2_048...8_192).contains(CaptureImageLoader.pixelLimit()),
                  "the decode limit is about twice the display, within 2,048 and 8,192 pixels")
        let cancelled = CapturePreviewCancellation(); cancelled.cancel()
        do { _ = try CaptureImageLoader.image(CaptureImagePreviewItem.savedCopy(title: "Release notes", url: root.appendingPathComponent("not-there.png")).source,
                                              maximumPixelSize: 8_192, cancellation: cancelled)
            try check(false, "a closed preview reads no file")
        } catch { try check(error is CancellationError, "a closed preview reads no file, so it cannot even find one missing") }
        do { _ = try CaptureImageLoader.image(CaptureImagePreviewItem.savedCopy(title: "Release notes", url: frozen).source, maximumPixelSize: 8_192, cancellation: cancelled)
            try check(false, "a closed preview never decodes its image")
        } catch { try check(error is CancellationError, "a closed preview never decodes its image") }

        // Fit, actual size and zoom steps. Magnification 1 is one image pixel per screen pixel.
        let actual = CaptureImageZoom.actualSize(pixels: CGSize(width: 2_940, height: 1_912), backingScale: 2)
        try check(actual == CGSize(width: 1_470, height: 956) && CaptureImageZoom.actualSize(pixels: actual, backingScale: 1) == actual,
                  "actual size is one image pixel per screen pixel on Retina and standard displays")
        try check(abs(CaptureImageZoom.fit(image: actual, in: CGSize(width: 1_000, height: 700)) - min(1_000.0 / 1_470.0, 700.0 / 956.0)) < 0.0001
                  && CaptureImageZoom.fit(image: CGSize(width: 300, height: 200), in: CGSize(width: 1_000, height: 700)) == 1,
                  "fit shows the whole image and never enlarges a small one")
        try check(CaptureImageZoom.clamp(100, fit: 0.5) == CaptureImageZoom.largest && CaptureImageZoom.clamp(0.001, fit: 0.05) == 0.05
                  && CaptureImageZoom.percent(1) == 100, "zoom stays between the fit and eight times actual size")
        for (key, command) in [("+", CaptureImagePreviewModel.Command.zoomIn), ("=", .zoomIn), ("-", .zoomOut), ("0", .actualSize), ("9", .fit)] {
            try check(CaptureImagePreviewPanel.command(for: key) == command, "⌘\(key) zooms the preview")
        }
        try check(CaptureImagePreviewPanel.command(for: "c") == nil, "other keys pass through to Workbench")

        // The real preview window, off every display: fit, zoom keys, a resize while fitting, and Escape.
        // Once with scroll bars that show only while scrolling, and once with bars always shown, as on
        // a Mac without a trackpad such as the CI runners: fitting must not count bars that then hide (#188).
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let owner = NSWindow(contentRect: NSRect(x: -40_000, y: -40_000, width: 1_180, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        defer { owner.close() }
        let preview = CaptureImagePreview()
        preview.present = { _ in }
        for style in [NSScroller.Style.overlay, .legacy] {
            let bars = style == .legacy ? "with scroll bars always shown" : "with scroll bars shown while scrolling"
            preview.show(.section(first, number: 1, session: session), over: owner)
            guard let panel = preview.panel, let model = preview.model else { throw VoiceError.message("CAPTURE_PREVIEW_CHECK_FAILED: no preview window") }
            panel.setFrame(NSRect(x: -40_000, y: -40_000, width: 1_100, height: 760), display: false)
            try await settle(panel) { model.isShowingImage && scrollView(in: panel) != nil }
            guard let scroll = scrollView(in: panel) else { throw VoiceError.message("CAPTURE_PREVIEW_CHECK_FAILED: the preview shows no image") }
            scroll.scrollerStyle = style
            try await settle(panel) { false }
            /// The whole image in the scroll view with no bars, which is how a fitted image is shown.
            func expectedFit() -> CGFloat {
                let space = NSScrollView.contentSize(forFrameSize: scroll.frame.size, horizontalScrollerClass: nil, verticalScrollerClass: nil,
                                                     borderType: scroll.borderType, controlSize: .regular, scrollerStyle: style)
                return CaptureImageZoom.fit(image: scroll.documentView?.frame.size ?? .zero, in: space)
            }
            try check(!panel.isVisible && panel.parent === owner && panel.title == "Screenshot for section 1", "the preview belongs to Workbench's window and names its image")
            try check(showsWholeImage(scroll, legacyBars: style == .legacy), "a fitted image shows all of itself with no scroll bar, \(bars): \(fitReport(scroll))")
            let fitted = scroll.magnification
            try check(scroll.fitting && abs(fitted - expectedFit()) < 0.001 && fitted < 1 && model.percent == CaptureImageZoom.percent(fitted),
                      "a full-display screenshot opens fitted to the window, \(bars)")
            func key(_ characters: String, shift: Bool = false) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.command, .shift] : [.command], timestamp: 0,
                                 windowNumber: panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                 isARepeat: false, keyCode: 0)!
            }
            try check(panel.performKeyEquivalent(with: key("0")) && abs(scroll.magnification - 1) < 0.001 && model.percent == 100 && !scroll.fitting,
                      "⌘0 shows actual size, \(bars)")
            try check(panel.performKeyEquivalent(with: key("+", shift: true)) && abs(scroll.magnification - 1.25) < 0.001 && model.percent == 125, "⌘+ zooms in, \(bars)")
            try check(panel.performKeyEquivalent(with: key("-")) && abs(scroll.magnification - 1) < 0.001, "⌘− zooms out, \(bars)")
            panel.setFrame(NSRect(x: -40_000, y: -40_000, width: 900, height: 620), display: false)
            try await settle(panel) { false }
            try check(abs(scroll.magnification - 1) < 0.001, "a chosen zoom survives resizing the preview, \(bars)")
            try check(panel.performKeyEquivalent(with: key("9")), "⌘9 is the preview's own key, \(bars)")
            try await settle(panel) { false }
            try check(scroll.fitting && abs(scroll.magnification - expectedFit()) < 0.001 && scroll.magnification < fitted,
                      "⌘9 fits the image again, and fitting follows the window, \(bars): \(scroll.magnification) for \(expectedFit())")
            try check(showsWholeImage(scroll, legacyBars: style == .legacy), "after ⌘9 the image shows all of itself with no scroll bar, \(bars): \(fitReport(scroll))")
            panel.cancelOperation(nil)
            try check(preview.panel == nil && owner.childWindows?.contains(panel) != true, "Escape closes the preview and leaves Workbench's window, \(bars)")
        }
        try check(try snapshot(session) == sessionNow, "viewing, zooming and closing changed no session file")

        // Rounding at an exact fit can leave the image a hair larger than the window, and an
        // always-shown bar then appears and crops it. Sweep window and image sizes the way SwiftUI
        // resizes the real view, with bars always shown, and see what is actually drawn (#188).
        let sweepWindow = NSWindow(contentRect: NSRect(x: -40_000, y: -40_000, width: 1_200, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        sweepWindow.isReleasedWhenClosed = false
        defer { sweepWindow.close() }
        let sweep = PreviewImageScrollView()
        sweepWindow.contentView = sweep
        sweep.scrollerStyle = .legacy
        var misses: [String] = [], cases = 0
        for (name, png) in [("2940×1912 screenshot", replacement), ("2880×1800 Snap", screen),
                            ("1200×2400 portrait", try screenPNG(width: 1_200, height: 2_400, heading: "Portrait"))] {
            guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw VoiceError.message("CAPTURE_PREVIEW_CHECK_FAILED: could not decode the \(name)")
            }
            sweep.show(CapturePreviewImage(image: image, pixelSize: CGSize(width: image.width, height: image.height)), label: name)
            for width in stride(from: 900, through: 1_100, by: 7) {
                for height in [560, 700, 840] {
                    sweep.setFrameSize(NSSize(width: width, height: height))
                    sweep.layoutSubtreeIfNeeded()
                    cases += 1
                    if !showsWholeImage(sweep, legacyBars: true) { misses.append("\(name) at \(width)×\(height): \(fitReport(sweep))") }
                }
            }
        }
        try check(misses.isEmpty, "fitting \(cases) window and image sizes with bars always shown never shows a bar or crops the image; "
                  + "\(misses.count) did: " + misses.prefix(3).joined(separator: "; "))

        // A missing file shows its message in the window, with no zoom controls.
        preview.show(.section(failed, number: 2, session: session), over: owner)
        guard let missingPanel = preview.panel, let missingModel = preview.model else { throw VoiceError.message("CAPTURE_PREVIEW_CHECK_FAILED: no preview window") }
        missingPanel.setFrame(NSRect(x: -40_000, y: -40_000, width: 900, height: 620), display: false)
        try await settle(missingPanel) { if case .unavailable = missingModel.state { return true }; return false }
        if case .unavailable(let text) = missingModel.state {
            try check(text.contains("missing from the session folder") && !missingModel.isShowingImage && scrollView(in: missingPanel) == nil,
                      "the window explains a missing screenshot")
        } else { try check(false, "the window explains a missing screenshot") }
        // Showing another image reuses the one window.
        preview.show(.snap(edited, store: store), over: owner)
        try check(preview.panel === missingPanel && missingPanel.title == "Cropped notes", "another image opens in the same preview window")
        try await settle(missingPanel) { preview.model?.isShowingImage == true && scrollView(in: missingPanel) != nil }
        preview.close()
        try check(preview.panel == nil, "Close closes the preview")
        try check(try snapshot(store.root) == snapsBefore, "no Snap file changed")
        print("CAPTURE_PREVIEW_CHECKS_OK: \(count) checks for current revisions, archived and deleted captures, saved copies, missing files, fit, zoom keys and Escape")
    }

    /// A fitted image draws all of itself: every part of it is in the visible rect, within half a
    /// point, and with bars always shown neither bar is showing.
    private static func showsWholeImage(_ scroll: PreviewImageScrollView, legacyBars: Bool) -> Bool {
        guard let document = scroll.documentView?.frame else { return false }
        let visible = scroll.contentView.documentVisibleRect
        let covered = visible.minX <= document.minX + 0.5 && visible.maxX >= document.maxX - 0.5
            && visible.minY <= document.minY + 0.5 && visible.maxY >= document.maxY - 0.5
        let barsHidden = (scroll.horizontalScroller?.isHidden ?? true) && (scroll.verticalScroller?.isHidden ?? true)
        return covered && (!legacyBars || barsHidden)
    }

    private static func fitReport(_ scroll: PreviewImageScrollView) -> String {
        let document = scroll.documentView?.frame.size ?? .zero, visible = scroll.contentView.documentVisibleRect.size
        return String(format: "magnification %.6f, image %.2f×%.2f, visible %.2f×%.2f, bars %@/%@", scroll.magnification,
                      document.width, document.height, visible.width, visible.height,
                      scroll.horizontalScroller?.isHidden == false ? "shown" : "hidden", scroll.verticalScroller?.isHidden == false ? "shown" : "hidden")
    }

    private static func scrollView(in panel: NSWindow) -> PreviewImageScrollView? {
        func find(_ view: NSView) -> PreviewImageScrollView? {
            if let scroll = view as? PreviewImageScrollView { return scroll }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return panel.contentView.flatMap(find)
    }

    /// Lets SwiftUI lay out the never-shown window until `done` or a short deadline.
    private static func settle(_ window: NSWindow, until done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(done() ? 0.2 : 3)
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        } while !done() && Date() < deadline
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// A synthetic screen: a heading, a window and lines of small text.
    static func screenPNG(width: Int, height: Int, heading: String) throws -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let w = CGFloat(width), h = CGFloat(height)
        NSColor(calibratedWhite: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        NSColor.white.setFill(); NSRect(x: w * 0.08, y: h * 0.08, width: w * 0.84, height: h * 0.8).fill()
        (heading as NSString).draw(at: NSPoint(x: w * 0.1, y: h * 0.8), withAttributes: [.font: NSFont.boldSystemFont(ofSize: max(8, h * 0.04))])
        for line in 0..<12 {
            ("Row \(line + 1) · build 20260928 · 21 checks passed · synthetic value \(line * 7 + 3)" as NSString)
                .draw(at: NSPoint(x: w * 0.1, y: h * 0.72 - CGFloat(line) * h * 0.045), withAttributes: [.font: NSFont.systemFont(ofSize: max(6, h * 0.012))])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw VoiceError.message("Could not draw a synthetic screen.") }
        return png
    }
}
