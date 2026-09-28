import AppKit
import SwiftUI

/// The Draw page as unified Workbench embeds it: every option it shows must do
/// something there. The floating palette belongs only to the standalone app,
/// so its settings stay there, with their stored values untouched (#160).
final class DrawPageTests {
    private func withSettings(_ body: (SettingsStore, URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorkbenchDrawPageTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A plist in the temporary folder: never the person's preferences, and nothing left behind.
        let defaults = UserDefaults(suiteName: folder.appendingPathComponent("stage").path)!
        try body(SettingsStore(defaults: defaults), folder)
    }

    /// The page's view value for one tab, written out with every label and text
    /// it would draw. SwiftUI builds only the branches that apply, so a control
    /// the page leaves out is absent here too.
    private func pageText(_ app: AppCoordinator, _ settings: SettingsStore, tab: String) -> String {
        app.selectedTab = tab
        var text = ""
        dump(ControlCenter(app: app, settings: settings).body, to: &text)
        return text
    }

    func testEmbeddedDrawPageShowsNoInactivePaletteSettings() throws {
        try withSettings { settings, folder in
            settings.value.showDrawingPalette = true
            settings.value.boardPalette = .show
            let palette = ["Show the palette while drawing", "Board palette", "move the mouse to reveal the palette", "The palette"]
            let embedded = AppCoordinator(settings: settings, archiveURL: folder.appendingPathComponent("boards.json"), embedded: true)
            let drawing = pageText(embedded, settings, tab: "Drawing"), boards = pageText(embedded, settings, tab: "Boards")
            XCTAssertTrue(drawing.contains("Pressure-sensitive pen") && drawing.contains("Drawing indicator")
                          && boards.contains("Keep board drawings separate from the screen"), "The embedded Drawing and Boards tabs are read")
            for text in palette {
                XCTAssertFalse(drawing.contains(text) || boards.contains(text), "Embedded Draw offers no inactive palette setting or instruction: \(text)")
            }
            XCTAssertTrue(boards.contains("Escape closes the board and returns to your presentation."), "Escape's way back is still explained")
            XCTAssertTrue(boards.contains("The floating toolbar"), "The board note names what hides in Workbench during selection")

            let standalone = AppCoordinator(settings: settings, archiveURL: folder.appendingPathComponent("boards.json"), embedded: false)
            let legacy = pageText(standalone, settings, tab: "Drawing") + pageText(standalone, settings, tab: "Boards")
            XCTAssertTrue(legacy.contains("Show the palette while drawing") && legacy.contains("Board palette")
                          && legacy.contains("With Auto-hide, move the mouse to reveal the palette again."), "The standalone app keeps its palette settings")
            XCTAssertTrue(settings.value.showDrawingPalette && settings.value.boardPalette == .show, "Stored palette preferences are untouched")

            // Optional before/after evidence, as the other StageKit layout checks write it.
            if let output = ProcessInfo.processInfo.environment["WORKBENCH_LAYOUT_EVIDENCE"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for (app, edition) in [(embedded, "workbench"), (standalone, "standalone")] {
                    for tab in ["Drawing", "Boards"] {
                        app.selectedTab = tab
                        try render(ControlCenter(app: app, settings: settings), to: directory.appendingPathComponent("draw-\(tab.lowercased())-\(edition).png"))
                    }
                }
            }
        }
    }

    private func render<V: View>(_ content: V, size: CGSize = CGSize(width: 900, height: 1_000), to url: URL) throws {
        let hosting = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.frame = CGRect(origin: .zero, size: size)
        for _ in 0..<5 { hosting.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
    }
}
