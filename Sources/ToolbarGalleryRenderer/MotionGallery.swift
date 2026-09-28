import AppKit
import SwiftUI
import ImageIO
import ToolbarCore
import ToolbarKit
import StageKit

extension ToolbarGalleryRenderer {
    /// The production row and native window animator in an offscreen, nonactivating
    /// panel. No input is posted, no app is activated and no user store is read.
    @MainActor static func renderMotion(to directory: URL) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited); NSApp.finishLaunching()
        NSApp.appearance = NSAppearance(named: .aqua)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var report: [[String: Any]] = []
        for anchor in [ToolbarAnchor.left, .right] {
            let live = anchor == .right
            var state = ToolbarViewState(name: "motion", tier: .resting, anchor: anchor,
                mode: live ? .present : .draw, actionTitle: live ? "End presentation" : "Draw",
                actionHint: live ? "⌥Q" : "⌥D", isBusy: live,
                status: live ? .resolve(ToolbarActivity(live: [.presenting])) : .idle)
            func content() -> AnyView {
                AnyView(ToolbarRow(state: state, accent: WorkbenchPalette.accent)
                    .pinnedToDock(anchor).environment(\.colorScheme, .light))
            }
            var expanded = state; expanded.tier = .revealed
            let full = NSHostingView(rootView: ToolbarRow(state: expanded, accent: WorkbenchPalette.accent)).fittingSize
            let canvas = CGSize(width: ceil(full.width) + 40, height: 80)
            let host = NSHostingView(rootView: content())
            host.sizingOptions = []; host.autoresizingMask = [.width, .height]
            let origin = CGPoint(x: -19800, y: -19800)
            let panel = NSPanel(contentRect: CGRect(origin: origin, size: ToolbarLayout.mark),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true; panel.contentView = host; panel.orderFrontRegardless()
            defer { panel.close() }
            let motion = ToolbarWindowMotion()
            func launcher(in view: NSView) -> NSView? {
                if view.accessibilityIdentifier() == "toolbar.launcher" { return view }
                return view.subviews.lazy.compactMap { launcher(in: $0) }.first
            }
            let file = "motion-\(anchor.rawValue).gif"
            guard let gif = CGImageDestinationCreateWithURL(directory.appendingPathComponent(file) as CFURL,
                    "com.compuserve.gif" as CFString, 66, nil) else { throw NSError(domain: "ToolbarMotion", code: 1) }
            CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            var frames: [[String: Any]] = []
            for index in 0..<66 {
                if index == 9 || index == 39 {
                    state.tier = index == 9 ? .revealed : .resting
                    host.rootView = content(); host.layoutSubtreeIfNeeded()
                    let size = state.tier == .resting ? ToolbarLayout.mark : full
                    let x = anchor.growsLeftward ? origin.x + ToolbarLayout.mark.width - size.width : origin.x
                    motion.move(panel, to: CGRect(x: x, y: origin.y + (28 - size.height) / 2, width: size.width, height: size.height), animated: true)
                }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0 / 30))
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "ToolbarMotion", code: 2) }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let pixels = bitmap.cgImage,
                      let context = CGContext(data: nil, width: Int(canvas.width * 2), height: Int(canvas.height * 2), bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { throw NSError(domain: "ToolbarMotion", code: 3) }
                context.scaleBy(x: 2, y: 2)
                context.setFillColor(CGColor(gray: 0.96, alpha: 1)); context.fill(CGRect(origin: .zero, size: canvas))
                let x: CGFloat = anchor.growsLeftward ? 20 + full.width - panel.frame.width : 20
                context.draw(pixels, in: CGRect(x: x, y: (canvas.height - panel.frame.height) / 2,
                                              width: panel.frame.width, height: panel.frame.height))
                guard let image = context.makeImage() else { throw NSError(domain: "ToolbarMotion", code: 4) }
                CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 30]] as CFDictionary)
                if [0, 10, 11, 12, 15, 25, 40, 41, 42, 45, 55].contains(index) {
                    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                    try png.write(to: directory.appendingPathComponent("\(anchor.rawValue)-\(index).png"))
                }
                var sample: [String: Any] = ["frame": index, "tier": state.tier.rawValue, "width": panel.frame.width, "height": panel.frame.height]
                if let target = launcher(in: host) {
                    let bounds = target.convert(target.bounds, to: host)
                    let inset = anchor.growsLeftward ? host.bounds.width - bounds.midX : bounds.midX
                    guard abs(inset - ToolbarLayout.launcherInset) <= 0.5 else {
                        throw NSError(domain: "ToolbarMotion", code: 6,
                                      userInfo: [NSLocalizedDescriptionKey: "Launcher moved at frame \(index): \(inset)"])
                    }
                    sample["launcherInset"] = inset
                }
                frames.append(sample)
            }
            guard CGImageDestinationFinalize(gif) else { throw NSError(domain: "ToolbarMotion", code: 5) }
            let unique = Set(frames.compactMap { $0["width"] as? CGFloat }).count
            report.append(["file": file, "uniqueWindowWidths": unique, "frames": frames])
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("motion.json"))
        print("TOOLBAR_MOTION_GALLERY_OK: two native offscreen sequences; inspect motion.json for sampled window interpolation")
    }
}
