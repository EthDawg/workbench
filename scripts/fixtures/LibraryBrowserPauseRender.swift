import AppKit
import Carbon
import SwiftUI

/// Renders the production Library view offscreen with one old bound destination.
@main struct LibraryBrowserPauseRender {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("browser-pause")
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = DemoLibraryStore(directory: root)
        var link = DemoResource(kind: .link, title: "Project reference", product: "Example project", content: "https://example.com/reference", notes: "Saved before browser switching was paused.")
        link.browserTarget = BrowserTarget(profileID: UUID(), profileName: "Project profile", machineID: UUID())
        try store.save([link])
        let original = try Data(contentsOf: store.url)
        let suite = root.appendingPathComponent("preferences").path
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = VoicePreferences()
        preferences.presenterShortcut = VoiceShortcut(keyCode: 16, modifiers: UInt32(optionKey))
        preferences.save(to: defaults)
        let library = DemoLibraryModel(store: store, copyText: { _ in 1 }, openURL: { _ in false })
        library.selection = link.id
        for (width, scheme, name) in [(920.0, ColorScheme.light, "library-browser-paused-light"), (740.0, ColorScheme.dark, "library-browser-open-failed-dark")] {
            if scheme == .dark { library.open(link) }
            let view = NSHostingView(rootView: DemoLibraryView(library: library, model: AppModel(), browserDefaults: defaults).padding(24)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
            view.frame = NSRect(x: 0, y: 0, width: width, height: 720)
            view.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = view.appearance; window.contentView = view; window.displayIfNeeded()
            view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15)); view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw VoiceError.message("Render allocation failed") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        guard try Data(contentsOf: store.url) == original else { throw VoiceError.message("Browser fixture changed its saved binding") }
        print("BROWSER_PAUSE_RENDER_OK: production Library, light and narrow dark, saved metadata unchanged")
    }
}
