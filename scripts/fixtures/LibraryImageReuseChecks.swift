import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@main struct LibraryImageReuseChecks {
    @MainActor static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    }
    @MainActor static func run() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("Workbench-library-images-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = DemoLibraryStore(directory: root.appendingPathComponent("Library"))
        let source = root.appendingPathComponent("Synthetic image.png")
        let context = CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 320,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        context.setFillColor(CGColor(red: 1, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
        let buffer = NSMutableData(), output = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(output) else { throw VoiceError.message("Synthetic PNG failed") }
        let rendered = buffer as Data
        try rendered.write(to: source)
        let bookmark = try source.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        let resource = DemoResource(kind: .file, title: "Synthetic reusable image", content: source.path, bookmark: bookmark)
        let prompt = DemoResource(title: "Existing prompt", content: "Keep these exact words.")
        try store.save([prompt, resource])
        let before = try Data(contentsOf: store.url)
        var starts = 0, stops = 0, written = 0, chosen = 0, checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw VoiceError.message("LIBRARY_IMAGE_REUSE_FAILED: " + label) }
            checks += 1
        }
        let model = DemoLibraryModel(store: store, copyText: { _ in 1 }, openURL: { _ in false }, makePreviewAccess: { url in
            DemoResourcePreviewAccess(url: url, start: { _ in starts += 1; return true }, stop: { _ in stops += 1 })
        })
        model.query = "Synthetic reusable"; model.selection = resource.id
        let snapshot = model.prepareImage(resource, for: .present)
        try check(snapshot?.data == rendered && snapshot?.title == resource.title, "Present receives frozen source bytes")
        try check(model.prepareImage(resource, for: .persona)?.data == rendered, "Persona receives the same frozen source bytes")
        try check(starts == 2 && stops == 2, "Both access leases end immediately after reading")
        try check(model.resources == [prompt, resource] && model.query == "Synthetic reusable" && model.selection == resource.id,
                  "Choosing and cancelling a handoff keep the Library selection and contents")
        try check(try Data(contentsOf: store.url) == before && Data(contentsOf: source) == rendered, "Preparation writes no metadata or media")

        let relocated = root.appendingPathComponent("Moved image.png")
        try FileManager.default.moveItem(at: source, to: relocated)
        try check(model.prepareImage(resource, for: .present) == nil && model.error?.contains("Locate file") == true,
                  "Moved bookmarked image requires Locate instead of silently retargeting")
        try check(try Data(contentsOf: store.url) == before, "Failed preparation keeps the old bookmark and path")
        try FileManager.default.moveItem(at: relocated, to: source)
        try Data("Not an image".utf8).write(to: source)
        try check(model.prepareImage(resource, for: .persona) == nil, "Invalid image data is never offered to an editor")
        try rendered.write(to: source)
        var stale = resource; stale.bookmark = Data("invalid bookmark".utf8)
        try check(model.prepareImage(stale, for: .present) == nil, "Stale resource cannot replace the saved reference")
        try check(model.prepareImage(prompt, for: .present) == nil, "Prompts are never images")
        let oversized = try FileHandle(forWritingTo: source)
        try oversized.truncate(atOffset: UInt64(DemoLibraryImageFile.maximumPreparationBytes + 1)); try oversized.close()
        try check(model.prepareImage(resource, for: .present) == nil, "Oversized files reject before decoding or opening an editor")
        try rendered.write(to: source)
        try check(starts == stops, "Failure releases its scoped access")
        try check(snapshot?.data == rendered, "A later source change cannot change an already prepared image")

        let exported = root.appendingPathComponent("User-chosen export.png")
        model.error = "An earlier failed action"; model.notice = "An earlier success"
        let cancel = model.saveImageToLibrary(renderedPNG: rendered, title: "Saved Snap", chooseDestination: { _ in chosen += 1; return nil },
                                             write: { _, _ in written += 1 })
        try check(!cancel && chosen == 1 && written == 0, "Save panel cancellation never writes or adds a reference")
        try check(model.error == nil && model.notice == nil, "Cancel cannot replay feedback from an earlier invocation")
        try check(try Data(contentsOf: store.url) == before, "Cancelled export preserves library bytes")
        let failed = model.saveImageToLibrary(renderedPNG: rendered, title: "Saved Snap", chooseDestination: { _ in exported },
                                             write: { _, _ in throw VoiceError.message("Synthetic disk failure") })
        try check(!failed && !FileManager.default.fileExists(atPath: exported.path), "Write failure cannot add an image reference")
        try check(model.notice == nil && model.error?.contains("not saved to Library") == true, "Write failure reports no false success")
        try check(try Data(contentsOf: store.url) == before && Data(contentsOf: source) == rendered, "Failure leaves Library and source intact")
        let mismatched = root.appendingPathComponent("Mismatched export.png")
        try check(!model.saveImageToLibrary(renderedPNG: rendered, title: "Mismatched", chooseDestination: { _ in mismatched },
            write: { _, url in try Data("Wrong bytes".utf8).write(to: url) }), "Unverified output never adds a reference")
        try check(try Data(contentsOf: store.url) == before && !model.resources.contains { $0.title == "Mismatched" },
                  "Mismatched export preserves Library and reports no success")
        let unreadable = DemoLibraryStore(directory: root.appendingPathComponent("Unreadable"))
        try FileManager.default.createDirectory(at: unreadable.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Unsupported library".utf8).write(to: unreadable.url)
        let blocked = DemoLibraryModel(store: unreadable, copyText: { _ in 1 }, openURL: { _ in false })
        let persistenceFailure = blocked.error
        try check(!blocked.saveImageToLibrary(renderedPNG: rendered, title: "Blocked", chooseDestination: { _ in chosen += 1; return exported })
                  && blocked.error == persistenceFailure && chosen == 1, "Read-only Library keeps its actual persistence failure without opening a save panel")
        try check(model.saveImageToLibrary(renderedPNG: rendered, title: "Saved Snap", chooseDestination: { _ in exported }),
                  "Successful user-chosen export adds its reference")
        try check(try Data(contentsOf: exported) == rendered, "Export keeps the actual rendered PNG bytes exactly")
        let saved = model.resources.first { $0.title == "Saved Snap" }
        try check(saved?.content == exported.path && saved?.bookmark != nil && saved?.content != source.path,
                  "Only the exported file is referenced, never capture internals")
        try check(model.resources.contains(prompt) && model.resources.contains(resource), "Other resources and the original reference survive")

        let secondExport = root.appendingPathComponent("Second export.png")
        let outside = DemoResource(title: "External edit", content: "Preserve the newer Library")
        let second = model.saveImageToLibrary(renderedPNG: rendered, title: "Second saved Snap", chooseDestination: { _ in secondExport }, write: { data, url in
            try data.write(to: url, options: .atomic)
            try store.save([outside])
        })
        try check(!second && model.notice == nil && model.error?.contains("exported to") == true && model.error?.contains("not added to Library") == true,
                  "Export success plus Library commit failure is an explicit partial result")
        try check(try Data(contentsOf: secondExport) == rendered && store.load() == [outside],
                  "Library conflict preserves both the exported file and newer metadata")
        try check(!model.resources.contains { $0.title == "Second saved Snap" }, "Failed commit leaves no in-memory reference")
        try check(starts == stops, "Export scopes close on success and partial failure")

        if CommandLine.arguments.count == 2 {
            // Offscreen source view only. The real image buttons are wired to no-op callbacks.
            _ = NSApplication.shared
            let directory = URL(fileURLWithPath: CommandLine.arguments[1])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try store.save([prompt, resource])
            let fixture = DemoLibraryModel(store: store, copyText: { _ in 1 }, openURL: { _ in false })
            fixture.selection = resource.id
            for (width, scheme, name) in [(920.0, ColorScheme.light, "library-image-light"), (740.0, ColorScheme.dark, "library-image-narrow-dark")] {
                let view = NSHostingView(rootView: DemoLibraryView(library: fixture, model: AppModel(),
                    onUseImageInPresent: { _ in }, onUseImageInPersona: { _ in }).padding(24)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
                view.frame = NSRect(x: 0, y: 0, width: width, height: 720)
                view.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = view.appearance; window.contentView = view; window.displayIfNeeded()
                view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15)); view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw VoiceError.message("Render allocation failed") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
                window.orderOut(nil)
            }
        }
        print("LIBRARY_IMAGE_REUSE_CHECKS_OK: \(checks) checks; synthetic images and temporary stores only")
    }
}
