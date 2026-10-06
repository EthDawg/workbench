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
        for anchor in ToolbarAnchor.allCases {
            let live = anchor == .right
            var state = ToolbarViewState(name: "motion", tier: .resting, anchor: anchor,
                mode: live ? .present : .draw, actionTitle: live ? "End presentation" : "Draw",
                actionSymbol: live ? "stop.fill" : ToolbarOperation.start(.draw).symbol,
                actionHint: live ? "⌥Q" : "⌥D", isBusy: live,
                status: live ? .resolve(ToolbarActivity(live: [.presenting])) : .idle,
                accessory: live ? .prompts : .tools)
            if anchor.growsFromCentre {
                let mode: ToolbarMode = anchor == .top ? .snap : .snapAndTalk
                state = ToolbarGallery.captureSources.first { $0.mode == mode }!
                state.anchor = anchor; state.tier = .resting
            }
            func content() -> AnyView {
                AnyView(ToolbarRow(state: state, accent: WorkbenchPalette.accent)
                    .pinnedToDock(anchor).environment(\.colorScheme, .light))
            }
            var expanded = state; expanded.tier = .revealed
            let full = NSHostingView(rootView: ToolbarRow(state: expanded, accent: WorkbenchPalette.accent)).fittingSize
            let rest = ToolbarLayout.mark(for: anchor)
            let origin = CGPoint(x: -19800, y: -19800)
            let restingFrame = CGRect(origin: origin, size: rest)
            let fixedReference = ToolbarGeometry.restingCentre(inWindow: restingFrame, anchor: anchor)
            let fullFrame = ToolbarGeometry.frame(size: full, reference: fixedReference, anchor: anchor)
            let canvasFrame = fullFrame.union(restingFrame).insetBy(dx: -20, dy: -20)
            let canvas = canvasFrame.size
            let host = NSHostingView(rootView: content())
            host.sizingOptions = []; host.autoresizingMask = [.width, .height]
            let panel = NSPanel(contentRect: restingFrame,
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
                if [9, 11, 13, 39].contains(index) {
                    state.tier = index == 9 || index == 13 ? .revealed : .resting
                    host.rootView = content(); host.layoutSubtreeIfNeeded()
                    let size = state.tier == .resting ? rest : full
                    motion.move(panel, to: ToolbarGeometry.frame(size: size, reference: fixedReference, anchor: anchor), animated: true, anchor: anchor)
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
                context.draw(pixels, in: panel.frame.offsetBy(dx: -canvasFrame.minX, dy: -canvasFrame.minY))
                guard let image = context.makeImage() else { throw NSError(domain: "ToolbarMotion", code: 4) }
                CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 30]] as CFDictionary)
                if [0, 10, 11, 12, 15, 25, 40, 41, 42, 45, 55].contains(index) {
                    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                    try png.write(to: directory.appendingPathComponent("\(anchor.rawValue)-\(index).png"))
                }
                let reference = ToolbarGeometry.restingCentre(inWindow: panel.frame, anchor: anchor)
                guard abs(reference.x - fixedReference.x) <= 0.5, abs(reference.y - fixedReference.y) <= 0.5 else {
                    throw NSError(domain: "ToolbarMotion", code: 7, userInfo: [NSLocalizedDescriptionKey: "\(anchor): reference \(reference) moved from \(fixedReference) in frame \(index), window \(panel.frame)"])
                }
                if index > 55 {
                    let scale = CGFloat(bitmap.pixelsHigh) / host.bounds.height
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide where abs((CGFloat(anchor.isVertical ? x : y) + 0.5) / scale - 14) > 5 && (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 1.0 / 255 {
                            throw NSError(domain: "ToolbarMotion", code: 8, userInfo: [NSLocalizedDescriptionKey: "Collapsed pixels leaked after animation at \(anchor), frame \(index)"])
                        }
                    }
                }
                var sample: [String: Any] = ["frame": index, "tier": state.tier.rawValue, "width": panel.frame.width, "height": panel.frame.height,
                    "referenceX": reference.x, "referenceY": reference.y]
                if let target = launcher(in: host) {
                    let bounds = target.convert(target.bounds, to: host)
                    let inset = anchor.isVertical ? bounds.midY - (host.bounds.height - full.height) / 2
                        : anchor.growsFromCentre ? bounds.midX - (host.bounds.width - full.width) / 2
                        : anchor.growsLeftward ? host.bounds.width - bounds.midX : bounds.midX
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
        report += try renderOrientationMotion(to: directory)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("motion.json"))
        print("TOOLBAR_MOTION_GALLERY_OK: \(report.count) native offscreen sequences, including interrupted expansion, collapse and edge changes")
    }

    /// Change edge while resting and while open, reverse midway, then settle. The compact
    /// cases retain stale recovery state: recording must keep its dot without a warning,
    /// while the quiet handle must stay free of pictograms throughout the same motion.
    @MainActor private static func renderOrientationMotion(to directory: URL) throws -> [[String: Any]] {
        var report: [[String: Any]] = []
        let screen = NSRect(x: -19800, y: -19800, width: 360, height: 320)
        for (from, to, floating) in [(ToolbarAnchor.bottom, ToolbarAnchor.left, false), (.left, .top, false), (.top, .right, false),
                                     (.right, .bottomRight, false), (.left, .bottom, true)] {
            for (tier, recording) in [(ToolbarTier.resting, true), (.resting, false), (.revealed, false)] {
                var state = ToolbarViewState(name: "edge-change", tier: tier, anchor: from, mode: .snapAndTalk,
                    status: tier == .resting ? .resolve(ToolbarActivity(capture: recording ? .narration : nil,
                        level: 0.6, failure: true, pendingDelivery: true, unsavedCapture: true, stopsSoon: true)) : .idle,
                    accessory: .review, captureChoices: ToolbarCaptureKind.allCases)
                func content() -> AnyView { AnyView(ToolbarRow(state: state, accent: WorkbenchPalette.accent).pinnedToDock(state.anchor, isFloating: state.isFloating)) }
                func destination() -> NSRect {
                    let size = NSHostingView(rootView: ToolbarRow(state: state)).fittingSize
                    let position = state.isFloating ? ToolbarPosition.free(.init(releasedAt: CGPoint(x: screen.midX, y: screen.midY), on: screen)) : .docked(state.anchor)
                    return ToolbarGeometry.frame(size: size, position: position, screen: screen)
                }
                let host = NSHostingView(rootView: content())
                host.sizingOptions = []; host.autoresizingMask = [.width, .height]
                let panel = NSPanel(contentRect: destination(), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
                panel.ignoresMouseEvents = true; panel.contentView = host; panel.orderFrontRegardless()
                defer { panel.close() }
                let motion = ToolbarWindowMotion()
                let name = "edge-\(from.rawValue)-\(floating ? "free" : to.rawValue)-\(tier.rawValue)"
                    + (tier == .resting && !recording ? "-quiet" : "")
                guard let gif = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name + ".gif") as CFURL,
                    "com.compuserve.gif" as CFString, 42, nil) else { throw NSError(domain: "ToolbarMotion", code: 10) }
                CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
                var frames: [[String: Any]] = []
                for index in 0..<42 {
                    if [6, 8, 10].contains(index) {
                        let before = panel.frame
                        state.anchor = index == 8 ? from : to
                        state.isFloating = index == 8 ? false : floating
                        host.rootView = content(); host.layoutSubtreeIfNeeded()
                        motion.move(panel, to: destination(), animated: true, anchor: state.anchor, isFloating: state.isFloating)
                        if motion.target != nil, panel.frame != before { throw NSError(domain: "ToolbarMotion", code: 11,
                            userInfo: [NSLocalizedDescriptionKey: "Orientation retarget jumped before its first animation frame"] ) }
                    }
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0 / 30)); host.layoutSubtreeIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "ToolbarMotion", code: 12) }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    var signalPixels: [String: Int] = [:]
                    if tier == .resting {
                        var red = 0, orange = 0, bright = 0
                        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.4 else { continue }
                            // The system colors include a blue component after profile conversion.
                            // Identify their hue, rather than assuming a pure RGB red or orange.
                            if color.redComponent > 0.55, color.redComponent - color.greenComponent > 0.2,
                               abs(color.greenComponent - color.blueComponent) < 0.14 { red += 1 }
                            if color.redComponent > 0.6, color.greenComponent > 0.35,
                               color.greenComponent - color.blueComponent > 0.17 { orange += 1 }
                            // The quiet capsule and its subtle border are dark. Any bright
                            // ink would expose a tool, result, warning or recording pictogram.
                            if max(color.redComponent, color.greenComponent, color.blueComponent) > 0.4 { bright += 1 }
                        } }
                        signalPixels = ["recordingPixels": red, "warningPixels": orange, "brightPixels": bright]
                        guard orange == 0, recording ? red > 2 : bright == 0 else {
                            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + "-signal-failure.png"))
                            throw NSError(domain: "ToolbarMotion", code: 13,
                                userInfo: [NSLocalizedDescriptionKey: "\(name) frame \(index): expected \(recording ? "recording dot without warnings" : "quiet handle without pictograms") (red \(red), orange \(orange), bright \(bright))"])
                        }
                    }
                    guard let pixels = bitmap.cgImage,
                          let context = CGContext(data: nil, width: Int(screen.width * 2), height: Int(screen.height * 2), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                    else { throw NSError(domain: "ToolbarMotion", code: 14) }
                    context.scaleBy(x: 2, y: 2); context.setFillColor(CGColor(gray: 0.96, alpha: 1)); context.fill(CGRect(origin: .zero, size: screen.size))
                    context.draw(pixels, in: panel.frame.offsetBy(dx: -screen.minX, dy: -screen.minY))
                    let image = context.makeImage()!
                    CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 30]] as CFDictionary)
                    if [0, 6, 8, 10, 12, 20, 35].contains(index) {
                        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                            .write(to: directory.appendingPathComponent(name + "-\(index).png"))
                    }
                    if index > 24, panel.frame != destination() { throw NSError(domain: "ToolbarMotion", code: 15,
                        userInfo: [NSLocalizedDescriptionKey: "Orientation change did not settle at its requested edge"]) }
                    frames.append(["frame": index, "anchor": state.anchor.rawValue, "width": panel.frame.width, "height": panel.frame.height,
                                   "x": panel.frame.minX, "y": panel.frame.minY, "signalPixels": signalPixels])
                }
                guard CGImageDestinationFinalize(gif) else { throw NSError(domain: "ToolbarMotion", code: 16) }
                report.append(["file": name + ".gif", "frames": frames])
            }
        }
        return report
    }
}
