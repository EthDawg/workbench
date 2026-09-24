import AppKit
import SwiftUI
import ToolbarCore
import ToolbarKit
import StageKit

@main struct ToolbarGalleryRenderer {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            print("Usage: swift run ToolbarGalleryRenderer OUTPUT_DIRECTORY")
            exit(2)
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest: [[String: Any]] = []
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for scale in [CGFloat(1), 1.35] {
                let scaleName = scale == 1 ? "standard" : "large"
                for state in ToolbarGallery.states {
                    let row = ToolbarRow(state: state, textScale: scale, accent: WorkbenchPalette.accent)
                        .tint(WorkbenchPalette.accent)
                        .padding(12).background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let name = "\(state.name)-\(theme)-\(scaleName).png"
                    let size = try render(row, to: directory.appendingPathComponent(name))
                    manifest.append(["file": name, "width": size.width, "height": size.height])
                }
                // Compact overview is committed for ordinary PR image diffs.
                let samples = ToolbarGallery.tools + ToolbarGallery.bindings + ToolbarGallery.activity + ToolbarGallery.idle
                let overview = VStack(alignment: .leading, spacing: 14) {
                    Text("Workbench toolbar · \(theme) · \(scaleName)").font(.title2.weight(.semibold))
                    ForEach(samples, id: \.name) { state in
                        HStack(spacing: 18) {
                            Text(state.name).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary).frame(width: 220, alignment: .leading)
                            ToolbarRow(state: state, textScale: scale, accent: WorkbenchPalette.accent)
                        }
                    }
                }.padding(24).fixedSize()
                    .tint(WorkbenchPalette.accent)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light)
                _ = try render(overview, to: directory.appendingPathComponent("overview-\(theme)-\(scaleName).png"))
            }
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"))
        print("TOOLBAR_GALLERY_OK: \(manifest.count) production-view fixtures in \(directory.path)")
    }

    @MainActor static func render<V: View>(_ root: V, to url: URL) throws -> NSSize {
        let view = NSHostingView(rootView: root)
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw NSError(domain: "ToolbarGallery", code: 1)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ToolbarGallery", code: 2)
        }
        try png.write(to: url)
        return size
    }
}
