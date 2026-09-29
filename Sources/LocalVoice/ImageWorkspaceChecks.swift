import AppKit
import SwiftUI

@MainActor
enum ImageWorkspaceChecks {
    static func run(output: URL? = nil) async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw VoiceError.message("IMAGE_WORKSPACE_CHECK_FAILED: " + message) }
            checks += 1
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("ImageWorkspaceChecks-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        // The shared theme must read this test's preferences, never the user's app domain.
        try SurfaceGallery.isolatePreferences(home: root, appearance: "Light")
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); NSApp.finishLaunching()
        func setTheme(_ appearance: WorkbenchSettings.Appearance) {
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["appearance"] = appearance.rawValue
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            WorkbenchSettings.shared.setAppearance(appearance)
        }
        let suite = root.appendingPathComponent("preferences").path
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = SnapStore(root: root.appendingPathComponent("Snaps"))
        let png = try CaptureImagePreviewChecks.screenPNG(width: 1600, height: 1000, heading: "A clearer product walkthrough")
        let secondPNG = try CaptureImagePreviewChecks.screenPNG(width: 1200, height: 1800, heading: "Next image")
        let first = try store.insert(originalPNG: png, width: 1600, height: 1000, title: "Product walkthrough", source: .imported)
        let second = try store.insert(originalPNG: secondPNG, width: 1200, height: 1800, title: "Portrait", source: .imported)
        let snap = SnapModel(store: store, desktop: root.appendingPathComponent("Desktop"), preferences: preferences,
                             screenshotInbox: root.appendingPathComponent("Inbox"), screenAccess: .fixed(false))
        snap.analyzeImage = { _, digest in SnapDerivedData(imageSHA256: digest, text: "", featurePrint: nil) }
        snap.announce = { _ in }
        let owner = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1180, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        let preview = CaptureImagePreview()
        preview.present = { panel in
            (panel as? CaptureImagePreviewPanel)?.constrainsToScreen = false; panel.setFrameOrigin(NSPoint(x: -40_000, y: -40_000)); panel.contentView?.layoutSubtreeIfNeeded()
        }
        preview.attach(to: snap, parent: { owner }, stateChanged: {})
        defer { preview.approveDiscard = { true }; preview.cancelEditing(); preview.close(); owner.close() }
        let images: [CaptureImagePreviewItem] = [.snap(first, store: store), .snap(second, store: store)]
        preview.show(images[0], over: owner, collection: images)
        try await settle(preview)
        let originalPanel = preview.panel
        preview.step(1); try await settle(preview)
        try check(preview.index == 1 && preview.model?.item == images[1] && preview.panel === originalPanel, "Next reuses the same window")
        preview.step(1)
        try check(preview.index == 1, "Next is bounded at the last image")
        preview.step(-1); try await settle(preview)
        preview.beginEditing(); try await settle(preview)
        guard let editor = preview.editing else { throw VoiceError.message("Image editor did not open") }
        try check(preview.panel === originalPanel && editor.draft.existing?.id == first.id, "Edit uses the same window and original Snap")
        try check(editor.draft.originalPNG == png && editor.draft.edit == SnapEdit(), "Edit uses full original bytes")
        editor.addText()
        editor.updateSelected { $0.text = "Start here\nOne image, one workspace"; $0.fontSize = 0.045; $0.colour = "black" }
        let textID = editor.selected
        try check(editor.selectedMark?.kind == .text && editor.selectedMark?.text?.contains("workspace") == true, "a comment box is editable text on the image")
        editor.updateSelected { $0 = ImageWorkspaceGeometry.moved($0, dx: -0.15, dy: 0.15) }
        let beforeCrop = editor.draft.edit
        editor.setAspect(.widescreen)
        let size = SnapRendering.outputSize(image: editor.imageSize, edit: editor.draft.edit)
        try check(abs(size.width / size.height - 16 / 9) < 0.002, "widescreen crop exports 16:9")
        let cropped = editor.draft.edit
        editor.undo(); try check(editor.draft.edit == beforeCrop, "Undo restores the previous crop and marks")
        editor.redo(); try check(editor.draft.edit == cropped, "Redo restores the edited crop")
        editor.rotate()
        let rotated = SnapRendering.outputSize(image: editor.imageSize, edit: editor.draft.edit)
        try check(rotated.width == size.height && rotated.height == size.width, "Rotate turns image, crop and text together")
        editor.undo(); editor.select(textID)
        editor.showingOriginal = true
        try check(editor.displayEdit == SnapEdit() && editor.draft.edit == cropped, "Original compares without changing edits")
        editor.showingOriginal = false
        preview.step(1); preview.show(images[1])
        try check(preview.editing === editor && preview.index == 0, "navigation and other open requests cannot discard an edit")
        preview.approveDiscard = { false }; preview.close()
        try check(preview.editing === editor && snap.draft != nil, "Keep editing protects draft on Close")
        try await settle(preview)
        if let output {
            try fm.createDirectory(at: output, withIntermediateDirectories: true)
            for theme in ["light", "dark"] {
                setTheme(theme == "dark" ? .dark : .light)
                preview.panel?.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
                preview.panel?.setContentSize(NSSize(width: 1180, height: 740))
                try await settle(preview)
                try render(preview.panel!, to: output.appendingPathComponent("image-workspace-" + theme + ".png"))
            }
            setTheme(.light)
            preview.panel?.appearance = NSAppearance(named: .aqua)
            editor.tool = .crop; editor.setAspect(.widescreen)
            try await settle(preview)
            try render(preview.panel!, to: output.appendingPathComponent("image-workspace-crop.png"))
            editor.tool = .select
            preview.panel?.setContentSize(NSSize(width: 820, height: 560))
            try await settle(preview)
            try render(preview.panel!, to: output.appendingPathComponent("image-workspace-small.png"))
            preview.panel?.setContentSize(NSSize(width: 1180, height: 740))
        }
        preview.saveEditing(copy: false); try await settle(preview)
        let saved = try store.snapshot(first.id)
        try check(preview.editing == nil && snap.draft == nil && preview.panel === originalPanel, "Save returns to viewing in the same window")
        try check(saved.originalPNG == png && saved.item.edit.marks.first?.kind == .text && saved.item.formatVersion == 2, "saved text is reopenable and original remains exact")
        preview.step(1); try await settle(preview); preview.step(-1); try await settle(preview)
        preview.beginEditing(); try await settle(preview)
        try check(preview.editing?.draft.edit == saved.item.edit, "reopening retains text and crop")
        preview.approveDiscard = { true }; preview.cancelEditing(); try await settle(preview)
        let source = root.appendingPathComponent("Frozen session image.png"); try png.write(to: source)
        preview.show(.savedCopy(title: "Frozen input", url: source)); try await settle(preview); preview.beginEditing(); try await settle(preview)
        try check(preview.editing?.draft.existing == nil && preview.editing?.draft.originalPNG == (try SnapRendering.png(png)), "frozen source edits become new full-resolution Snaps")
        preview.editing?.addText(); preview.saveEditing(copy: false); try await settle(preview)
        try check(try Data(contentsOf: source) == png && store.load().items.count == 3, "saving a copy leaves frozen input unchanged")
        if case .snap(let savedRoot, let savedID) = preview.model?.item.source {
            try check(savedRoot == store.root && (try store.read(savedID)).edit.marks.first?.kind == .text,
                      "Save a copy returns to the newly edited image in the same workspace")
        } else { try check(false, "Save a copy returns to the newly edited image") }
        preview.close()
        try snap.editCopy(png, title: "New Snap")
        try await settle(preview)
        try check(preview.editing != nil && preview.panel != nil, "Paste/import drafts use the same expanded workspace host")
        preview.editing?.addText(); preview.approveDiscard = { false }; preview.cancelEditing()
        try check(snap.draft != nil, "Cancel asks before discarding changed work")
        preview.approveDiscard = { true }; preview.cancelEditing()
        try check(snap.draft == nil && preview.panel == nil, "Discard ends a new unsaved draft without a history record")
        try check(try store.load().items.count == 3, "discarded drafts create no extra Snaps")
        // Send real AppKit pointer/key events to the canvas. A geometry-only test would miss
        // endpoint direction, drag focus and which coordinate system keyboard movement uses.
        let gesture = try ImageWorkspaceEditing(draft: SnapDraft(originalPNG: png, source: .imported, title: "Pointer checks", notes: "", tags: [], edit: .init()))
        let scroll = ImageWorkspaceScrollView(editing: gesture)
        owner.contentView = scroll; scroll.setFrameSize(NSSize(width: 800, height: 500)); scroll.refresh()
        let canvas = scroll.canvas
        func mouse(_ type: NSEvent.EventType, _ x: Double, _ y: Double) throws -> NSEvent {
            let p = canvas.convert(CGPoint(x: x * canvas.bounds.width, y: y * canvas.bounds.height), to: nil)
            guard let event = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                windowNumber: owner.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                throw VoiceError.message("Could not create a canvas pointer event")
            }
            return event
        }
        let arrow = SnapMark(kind: .arrow, points: [.init(x: 0.2, y: 0.8), .init(x: 0.8, y: 0.2)], colour: "red")
        gesture.mutate { $0.marks.append(arrow) }; gesture.select(arrow.id)
        canvas.mouseDown(with: try mouse(.leftMouseDown, 0.2, 0.8))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, 0.3, 0.7))
        canvas.mouseUp(with: try mouse(.leftMouseUp, 0.3, 0.7))
        try check(gesture.selectedMark?.points.last == arrow.points.last && abs((gesture.selectedMark?.points.first?.x ?? 0) - 0.3) < 0.001,
                  "resizing an arrow endpoint preserves its other endpoint and direction")
        gesture.addText(); gesture.select(nil)
        let beforeDrag = gesture.draft.edit.marks.last!
        canvas.mouseDown(with: try mouse(.leftMouseDown, 0.5, 0.5))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, 0.55, 0.55))
        canvas.mouseUp(with: try mouse(.leftMouseUp, 0.55, 0.55))
        try check(gesture.selectedMark?.id == beforeDrag.id && abs((gesture.selectedMark?.points.first?.x ?? 0) - beforeDrag.points[0].x - 0.05) < 0.001,
                  "selecting a text box and dragging it works in a single gesture")
        gesture.rotate(); scroll.refresh()
        let beforeNudge = gesture.selectedMark!.points[0]
        let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: owner.windowNumber,
                                    context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!
        canvas.keyDown(with: right)
        try check(abs(gesture.selectedMark!.points[0].x - beforeNudge.x) < 0.000001 && abs(gesture.selectedMark!.points[0].y - beforeNudge.y - 1.0 / 1000) < 0.000001,
                  "Right nudges a clockwise-rotated mark one visible pixel right")
        for rotation in 0...3 {
            let ratio = ImageCropAspect.widescreen.ratio(image: CGSize(width: 1600, height: 1000), rotation: rotation)!
            for (a,b) in [(SnapPoint(x: 0.1,y: 0.1), SnapPoint(x: 0.95,y: 0.9)), (SnapPoint(x: 0.9,y: 0.9), SnapPoint(x: 0.02,y: 0.1))] {
                let crop = ImageWorkspaceGeometry.crop(from: a, to: b, aspect: ratio, image: CGSize(width: 1600,height: 1000))
                try check(crop.isValid && abs((crop.width * 1600) / (crop.height * 1000) - ratio) < 0.00001, "aspect drag respects bounds and rotation")
            }
        }
        print("IMAGE_WORKSPACE_CHECKS_OK: \(checks) checks for navigation, editable text, crop, rotation, undo, originals, drafts and frozen copies")
    }
    private static func settle(_ preview: CaptureImagePreview) async throws {
        for _ in 0..<40 {
            preview.panel?.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 15_000_000)
            if preview.editing != nil { continue }
            if case .loading = preview.model?.state { continue }
            break
        }
    }
    private static func render(_ panel: NSPanel, to url: URL) throws {
        guard let view = panel.contentView else { throw VoiceError.message("Could not render the image workspace") }
        let rep = try SurfaceGallery.snapshot(view)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw VoiceError.message("Could not encode workspace render") }
        try png.write(to: url)
    }
}
