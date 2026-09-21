import AppKit
import StageKit
import SwiftUI

@MainActor
enum FloatingToolbarChecks {
    static func runNative() async throws {
        guard Workbench.fixtureRoot != nil, NSScreen.main != nil else {
            throw VoiceError.message("Native toolbar checks require the disposable debug app and a display.")
        }
        var count = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("Native toolbar: " + name) }
            count += 1
        }
        func matches(_ actual: NSRect, _ expected: NSRect) -> Bool {
            // AppKit aligns native window origins to pixels; pure geometry can
            // put a centred pill at a half-point on an odd-height visible frame.
            zip([actual.minX, actual.minY, actual.width, actual.height],
                [expected.minX, expected.minY, expected.width, expected.height]).allSatisfy { abs($0 - $1) <= 1 }
        }
        let model = AppModel()
        model.ready = true; model.floatingToolbarVisible = true
        let readback = ReadbackModel(engine: model.engine)
        let stage = StageKitController(onOpenControls: {}, onOpenScenes: {})
        let controls = CaptureHUDControls()
        controls.collapseToolbar()
        let controller = CapturePanelController(model: model, readback: readback, stage: stage,
            dictate: {}, snap: {}, draw: {}, present: {}, controls: controls, monitorsPointer: false)
        defer { controller.close() }
        var pointer = NSPoint(x: -10000, y: -10000)
        // Samples below are synthetic; keep the tracker on that stream rather
        // than resetting it to the unrelated physical mouse on collapse.
        controls.didCollapse = nil
        controls.pointerInside = { controller.window?.frame.contains(pointer) == true }
        controls.pointerInsideCollapsed = {
            guard let frame = controller.window?.frame, let screen = NSScreen.main?.visibleFrame else { return false }
            return CaptureHUDGeometry.frame(size: FloatingToolbarDisclosure.collapsed.size(at: controls.anchor), anchor: controls.anchor,
                previous: frame, screens: [screen], preferred: screen).contains(pointer)
        }
        func settle(_ size: NSSize) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while ProcessInfo.processInfo.systemUptime < deadline {
                if !controller.isAnimatingToolbar, let actual = controller.window?.frame.size,
                   abs(actual.width - size.width) < 1, abs(actual.height - size.height) < 1 { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw VoiceError.message("Native toolbar did not settle at \(size); actual \(String(describing: controller.window?.frame))")
        }
        controller.update(model: model)
        try await settle(FloatingToolbarDisclosure.collapsed.size)
        controls.expandToolbar(); controls.collapseToolbar()
        try await settle(FloatingToolbarDisclosure.collapsed.size)
        try check(controls.toolbarDisclosure == .collapsed, "same-turn collapse cancels an unstarted reveal")
        for _ in 0..<10 {
            controls.expandToolbar()
            try await settle(FloatingToolbarDisclosure.expanded.size)
            let frame = controller.window!.frame
            pointer = NSPoint(x: frame.maxX - 25, y: frame.midY)
            controller.pointerMoved(to: pointer)
            controls.collapseToolbar()
            try await settle(FloatingToolbarDisclosure.collapsed.size)
            controller.pointerMoved(to: pointer)
            controller.update(model: model)
            try await Task.sleep(nanoseconds: 30_000_000)
            try check(controls.toolbarDisclosure == .collapsed && controller.window!.frame.width == 76,
                      "minimise remains collapsed after resize and a stationary pointer sample")
        }
        pointer = NSPoint(x: controller.window!.frame.midX, y: controller.window!.frame.midY)
        controller.pointerMoved(to: pointer)
        try await settle(FloatingToolbarDisclosure.hovered.size)
        try check(controls.toolbarDisclosure == .hovered, "first genuine entry after minimise reveals controls")
        let menu = NSMenu()
        controls.beginMenu(menu)
        pointer = NSPoint(x: -10000, y: -10000); controller.pointerMoved(to: pointer)
        try await Task.sleep(nanoseconds: 500_000_000)
        try check(controller.window!.frame.width == FloatingToolbarDisclosure.hovered.size.width, "native window stays open while choosing a menu item")
        controls.endMenu()
        try await settle(FloatingToolbarDisclosure.collapsed.size)
        pointer = NSPoint(x: controller.window!.frame.midX, y: controller.window!.frame.midY)
        controller.pointerMoved(to: pointer)
        try await settle(FloatingToolbarDisclosure.hovered.size)
        for offset in 0..<7 {
            pointer = NSPoint(x: -10000 + offset, y: -10000); controller.pointerMoved(to: pointer)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try check(controls.toolbarDisclosure == .collapsed, "continued outside motion cannot restart the exit grace period")
        try await settle(FloatingToolbarDisclosure.collapsed.size)
        controls.expandToolbar()
        try await settle(FloatingToolbarDisclosure.expanded.size)
        let collapseMenu = NSMenu()
        controls.beginMenu(collapseMenu)
        controls.collapseToolbar(); controls.endMenu()
        try await settle(FloatingToolbarDisclosure.collapsed.size)
        try check(controls.toolbarDisclosure == .collapsed, "collapse from a native menu closes its tracking hold")
        // Interrupt a spring with another choice, then with active recording UI.
        controls.expandToolbar()
        try await Task.sleep(nanoseconds: 60_000_000)
        try check(controller.window!.frame.width > 76 && controller.window!.frame.width < FloatingToolbarDisclosure.expanded.size.width,
                  "reveal passes through intermediate native window sizes")
        controls.collapseToolbar()
        try await settle(FloatingToolbarDisclosure.collapsed.size)
        try check(controls.toolbarDisclosure == .collapsed, "latest requested size wins during an interrupted reveal")
        controls.expandToolbar()
        try await Task.sleep(nanoseconds: 60_000_000)
        controller.beginDragging()
        try check(!controller.isAnimatingToolbar && controller.window!.frame.size == FloatingToolbarDisclosure.expanded.size,
                  "dragging during reveal settles the window before taking ownership")
        controller.finishDragging()
        controls.collapseToolbar()
        try await settle(FloatingToolbarDisclosure.collapsed.size(at: controls.anchor))
        for anchor in [FloatingControlAnchor.left, .right, .top, .bottom] {
            controls.choosePosition?(anchor)
            try await settle(FloatingToolbarDisclosure.collapsed.size(at: anchor))
            let rest = controller.window!.frame
            try check(rest.size == FloatingToolbarDisclosure.collapsed.size(at: anchor), "native pill orientation follows " + anchor.title)
            pointer = NSPoint(x: rest.midX, y: rest.maxY - 1)
            controller.pointerMoved(to: pointer)
            try await settle(FloatingToolbarDisclosure.hovered.size(at: anchor))
            try check(controller.window!.frame.contains(pointer), "hover preserves the resting tip at " + anchor.title)
            controls.collapseToolbar()
            try await settle(FloatingToolbarDisclosure.collapsed.size(at: anchor))
            pointer = NSPoint(x: -10000, y: -10000); controller.pointerMoved(to: pointer)
        }
        controls.choosePosition?(.left)
        try await Task.sleep(nanoseconds: 60_000_000)
        controls.choosePosition?(.bottom)
        try await settle(FloatingToolbarDisclosure.collapsed.size)
        try check(controls.anchor == .bottom, "changing edges during a snap settles at the latest orientation")
        controls.choosePosition?(.left)
        let pendingDestination = FloatingControlGeometry.frame(anchor: .left,
            size: FloatingToolbarDisclosure.collapsed.size(at: .left), visibleFrame: NSScreen.main!.visibleFrame)
        let savedOrigin = NSPointFromString(UserDefaults.standard.string(forKey: "capturePanelOrigin.v1")!)
        let savedSize = NSSizeFromString(UserDefaults.standard.string(forKey: "capturePanelSize.v1")!)
        try check(NSRect(origin: savedOrigin, size: savedSize) == pendingDestination,
                  "snap destination and display are saved before its first animation frame")
        model.floatingToolbarVisible = false; controller.update(model: model)
        model.floatingToolbarVisible = true; controller.update(model: model)
        try await settle(FloatingToolbarDisclosure.collapsed.size(at: .left))
        try check(matches(controller.window!.frame, pendingDestination),
                  "hiding during a snap restores the selected destination instead of the old one: actual \(controller.window!.frame), expected \(pendingDestination)")
        controls.expandToolbar()
        try await settle(FloatingToolbarDisclosure.expanded.size)
        controller.beginDragging()
        let screen = NSScreen.main!.visibleFrame
        controller.window!.setFrameOrigin(NSPoint(x: screen.midX - 240, y: screen.midY - 58))
        let destination = FloatingToolbarDocking.anchor(for: controller.window!.frame, in: screen)
        controller.previewDragging(); controller.finishDragging()
        try await settle(FloatingToolbarDisclosure.expanded.size)
        try check(controls.anchor == destination && matches(controller.window!.frame, FloatingControlGeometry.frame(
            anchor: destination, size: FloatingToolbarDisclosure.expanded.size, visibleFrame: screen)),
                  "arbitrary mid-screen drop lands in the previewed named slot")
        controls.choosePosition?(.bottom)
        try await settle(FloatingToolbarDisclosure.expanded.size)
        controls.expandToolbar()
        model.previewingPanel = true; controller.update(model: model)
        try await settle(CaptureHUDLayout.compact)
        controller.focusToolbar()
        try check(!(controller.window as! CapturePanel).allowsKeyboardFocus,
                  "idle focus command cannot focus recording controls")
        try check(!controller.isAnimatingToolbar, "recording cancels an idle resize")
        model.previewingPanel = false; model.floatingToolbarVisible = false; controller.update(model: model)
        try check(controller.window?.isVisible == false && !controller.isAnimatingToolbar,
                  "hiding cancels native animation without a stale reappearance")
        model.floatingToolbarVisible = true; controls.collapseToolbar(); controller.update(model: model)
        pointer = NSPoint(x: controller.window!.frame.midX, y: controller.window!.frame.midY)
        controller.pointerMoved(to: pointer)
        try await settle(FloatingToolbarDisclosure.hovered.size)
        controller.close()
        try check(!controller.isAnimatingToolbar, "closing a revealed toolbar cannot schedule another resize")
        try await Task.sleep(nanoseconds: 500_000_000)
        try check(controller.window?.isVisible != true && !controller.isAnimatingToolbar,
                  "closed toolbar remains hidden after pending callbacks")
        let legacyFrame = NSRect(x: screen.midX - 200, y: screen.midY - 40, width: 400, height: 80)
        UserDefaults.standard.removeObject(forKey: "capturePanelAnchor.v2")
        UserDefaults.standard.set(NSStringFromPoint(legacyFrame.origin), forKey: "capturePanelOrigin.v1")
        UserDefaults.standard.set(NSStringFromSize(legacyFrame.size), forKey: "capturePanelSize.v1")
        let restoredControls = CaptureHUDControls()
        let restored = CapturePanelController(model: model, readback: readback, stage: stage,
            dictate: {}, snap: {}, draw: {}, present: {}, controls: restoredControls, monitorsPointer: false)
        restored.update(model: model)
        let restoredAnchor = FloatingToolbarDocking.anchor(for: legacyFrame, in: screen)
        try check(restoredControls.anchor == restoredAnchor && matches(restored.window!.frame, FloatingControlGeometry.frame(
            anchor: restoredAnchor, size: restoredControls.preferredToolbarSize, visibleFrame: screen)),
                  "legacy free placement restores into its nearest named dock")
        restored.close()
        // The menu fits each real SwiftUI state rather than imposing the old
        // fixed 440pt box. No production menu or microphone is involved.
        let quick = NSHostingController(rootView: WorkbenchQuickPanel(model: model, stage: stage, readback: readback,
            open: { _ in }, draw: {}, snap: {}, present: {}, timer: {}, personas: {}))
        quick.sizingOptions = [.preferredContentSize]
        let quickWindow = NSWindow(contentViewController: quick)
        quickWindow.setContentSize(NSSize(width: 288, height: 1))
        quick.view.layoutSubtreeIfNeeded()
        let idleSize = quick.view.fittingSize
        try check(abs(idleSize.width - 288) < 1 && idleSize.height > 180 && idleSize.height < 340,
                  "idle menu fits its compact content without the old empty panel")
        model.phase = .recording
        try await Task.sleep(nanoseconds: 100_000_000)
        quick.view.layoutSubtreeIfNeeded()
        let activeSize = quick.view.fittingSize
        try check(activeSize.height >= idleSize.height && activeSize.height <= idleSize.height + 20,
                  "finishing an active job replaces its start action without another padded row")
        quickWindow.orderOut(nil)
        model.phase = .idle
        print("FLOATING_TOOLBAR_NATIVE_OK: \(count) checks passed")
    }

    /// Render the production views only from the existing disposable debug app.
    /// No microphone, capture, paste, shortcuts or live user library is involved.
    static func render(to directory: URL) throws {
        guard Workbench.fixtureRoot != nil else {
            throw VoiceError.message("Toolbar rendering requires the disposable debug QA bundle.")
        }
        let model = AppModel()
        model.ready = true
        let session = Workbench.fixtureRoot!.appendingPathComponent("menu-captures-" + UUID().uuidString)
        var manifest = try ReadbackStore.create(at: session, title: "Synthetic menu review")
        for index in 1...3 {
            let id = UUID(), path = "items/\(id.uuidString.lowercased())"
            try ReadbackStore.createPrivateDirectory(session.appendingPathComponent(path))
            try ReadbackStore.writePrivate(Data([0x89, 0x50, 0x4e, 0x47]), to: session.appendingPathComponent(path + "/screen.png"))
            manifest.sections.append(ReadbackSection(id: id, capturedAt: Date(timeIntervalSince1970: Double(index)),
                displayName: "Synthetic display", directory: path, screenshot: path + "/screen.png",
                audio: nil, originalTranscript: nil, transcript: nil, status: .needsNarration, failure: nil, deletedAt: nil))
        }
        try ReadbackStore.save(manifest, at: session)
        let domain = Workbench.suiteDomain + ".menu-render"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set([session.path], forKey: "readback.recentSessionPaths.v1")
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: session) }
        let readback = ReadbackModel(engine: model.engine, defaults: defaults)
        let stage = StageKitController(onOpenControls: {}, onOpenScenes: {})
        let collapsed = CaptureHUDControls(), hovered = CaptureHUDControls(), expanded = CaptureHUDControls()
        collapsed.collapseToolbar(); hovered.collapseToolbar(); hovered.hover(true); expanded.expandToolbar()
        let side = CaptureHUDControls()
        side.collapseToolbar(); side.anchor = .left; side.toolbarSize = side.preferredToolbarSize
        func toolbar(_ controls: CaptureHUDControls) -> some View {
            FloatingToolbar(model: model, readback: readback, stage: stage, controls: controls,
                dictate: {}, snap: {}, draw: {}, present: {})
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for appearance in [WorkbenchSettings.Appearance.light, .dark] {
            WorkbenchSettings.shared.setAppearance(appearance)
            let root = VStack(alignment: .leading, spacing: 18) {
                Text("Workbench · floating controls").font(.system(size: 20, weight: .semibold))
                HStack(spacing: 20) {
                    Text("At rest").frame(width: 90, alignment: .leading)
                    toolbar(collapsed)
                    Text("Side edge")
                    toolbar(side)
                }
                HStack(spacing: 20) {
                    Text("On hover").frame(width: 90, alignment: .leading)
                    toolbar(hovered)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Expanded · stays open")
                    toolbar(expanded)
                }
                Text("Actual native views · synthetic idle state").font(.caption).foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(28).frame(width: 580, height: 434, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)).workbenchTheme()
            let view = NSHostingView(rootView: root)
            view.frame = NSRect(x: 0, y: 0, width: 580, height: 434)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw VoiceError.message("Toolbar bitmap allocation failed")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw VoiceError.message("Toolbar PNG encoding failed")
            }
            try png.write(to: directory.appendingPathComponent("toolbar-" + appearance.rawValue.lowercased() + ".png"))
            for tool in WorkbenchControlTool.allCases {
                let sample = AppModel(); sample.ready = true; sample.controlTool = tool
                let tools = CaptureHUDControls(); tools.expandToolbar()
                let hover = CaptureHUDControls(); hover.collapseToolbar(); hover.hover(true)
                let menu = WorkbenchQuickPanel(model: sample, stage: stage, readback: readback,
                    open: { _ in }, draw: {}, snap: {}, present: {}, timer: {}, personas: {})
                let native = HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Menu bar · " + tool.title).font(.system(size: 14, weight: .semibold))
                        menu.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        Text("On hover").font(.system(size: 14, weight: .semibold))
                        FloatingToolbar(model: sample, readback: readback, stage: stage, controls: hover, dictate: {}, snap: {}, draw: {}, present: {})
                        Text("Expanded").font(.system(size: 14, weight: .semibold))
                        FloatingToolbar(model: sample, readback: readback, stage: stage, controls: tools, dictate: {}, snap: {}, draw: {}, present: {})
                        Text("Production SwiftUI views · synthetic state\nChanging tool keeps independent work running.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.padding(24).frame(width: 838, height: 410, alignment: .topLeading)
                    .background(Color(nsColor: .underPageBackgroundColor)).workbenchTheme()
                let hosted = NSHostingView(rootView: native)
                hosted.frame = NSRect(x: 0, y: 0, width: 838, height: 410)
                hosted.layoutSubtreeIfNeeded()
                guard let image = hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds) else {
                    throw VoiceError.message("Contextual menu bitmap allocation failed")
                }
                hosted.cacheDisplay(in: hosted.bounds, to: image)
                guard let data = image.representation(using: .png, properties: [:]) else {
                    throw VoiceError.message("Contextual menu PNG encoding failed")
                }
                try data.write(to: directory.appendingPathComponent("controls-\(tool.rawValue)-\(appearance.rawValue.lowercased()).png"))
            }
        }
        print("FLOATING_TOOLBAR_RENDER_OK: " + directory.path)
    }

    static func run() async throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw VoiceError.message("Floating toolbar: " + name) }
            count += 1
        }
        func eventually(_ name: String, _ condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try check(condition(), name)
        }
        var state = FloatingToolbarInteraction()
        var tracker = FloatingToolbarPointerTracker(lastPoint: NSPoint(x: 100, y: 100))
        try check(!tracker.moved(to: NSPoint(x: 100, y: 100)), "window geometry cannot invent a pointer move")
        try check(tracker.moved(to: NSPoint(x: 101, y: 100)), "a genuine pointer move is detected")
        try check(FloatingToolbarMotion.progress(at: 0) == 0 && FloatingToolbarMotion.progress(at: 1) == 1,
                  "spring has exact resting endpoints")
        let spring = stride(from: 0.0, through: FloatingToolbarMotion.duration, by: 0.005).map(FloatingToolbarMotion.progress)
        try check(spring.allSatisfy { $0 >= 0 && $0 < 1.02 }, "spring overshoot stays restrained")
        try check(state.disclosure == .collapsed, "first launch is a quiet indicator")
        state.enter()
        try check(state.disclosure == .hovered, "hover reveals actions")
        state.menuOpen = true; state.leave()
        try check(state.disclosure == .hovered && !state.canCollapse, "moving into the native menu retains actions")
        state.menuOpen = false; state.dragging = true
        try check(!state.canCollapse, "dragging outside the toolbar retains actions")
        state.dragging = false; state.pinned = true
        try check(state.disclosure == .expanded && !state.canCollapse, "explicit expansion stays open")
        state.enter(); state.collapse(); state.enter()
        try check(state.disclosure == .collapsed, "collapse does not immediately reopen under the pointer")
        state.leave(); state.enter()
        try check(state.disclosure == .hovered, "a fresh hover works after collapse")
        state.keyboardFocused = true; state.leave()
        try check(state.disclosure == .expanded && !state.canCollapse, "keyboard focus is independent of hover")
        state.suspend()
        try check(state.disclosure == .collapsed, "operation changes discard transient state")
        state.collapse(); state.enter()
        try check(state.disclosure == .hovered, "Escape outside the toolbar permits the next hover")

        let domain = "workbench.toolbar.checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let controls = CaptureHUDControls(defaults: defaults)
        var inside = false
        controls.pointerInside = { inside }
        inside = true; controls.hover(true)
        inside = false; controls.hover(false)
        try check(controls.toolbarDisclosure == .hovered, "exit grace period retains click targets")
        inside = true; controls.hover(true)
        try await Task.sleep(nanoseconds: 500_000_000)
        try check(controls.toolbarDisclosure == .hovered, "rapid re-entry cancels delayed collapse")
        let trackingMenu = NSMenu()
        controls.beginMenu(trackingMenu)
        inside = false; controls.hover(false)
        try await Task.sleep(nanoseconds: 500_000_000)
        try check(controls.toolbarDisclosure == .hovered, "an open menu survives an extended pointer exit")
        controls.endMenu()
        try await eventually("menu dismissal outside returns to resting") { controls.toolbarDisclosure == .collapsed }
        inside = true; controls.hover(true); controls.setDragging(true)
        inside = false; controls.hover(false)
        try await Task.sleep(nanoseconds: 500_000_000)
        try check(controls.toolbarDisclosure == .hovered, "dragging locks the actual presentation size")
        controls.setDragging(false)
        try await eventually("drag completion releases the idle reveal") { controls.toolbarDisclosure == .collapsed }
        controls.expandToolbar()
        try check(CaptureHUDControls(defaults: defaults).toolbarDisclosure == .expanded, "explicit expansion persists across relaunch")
        controls.collapseToolbar()
        try check(CaptureHUDControls(defaults: defaults).toolbarDisclosure == .collapsed, "explicit collapse persists across relaunch")
        controls.focusToolbar()
        try check(controls.toolbarDisclosure == .expanded && !CapturePanel().canBecomeKey,
                  "keyboard reveal does not make ordinary mouse panels focusable")
        inside = true; controls.hover(true); controls.unfocusToolbar()
        try check(controls.toolbarDisclosure == .hovered, "releasing keyboard focus restores a current hover")
        controls.suspendToolbar()
        try check(controls.toolbarDisclosure == .collapsed, "active capture cannot inherit keyboard expansion")
        controls.hover(true); controls.isExpanded = true; controls.collapseToolbar()
        try check(controls.isExpanded, "idle disclosure never mutates recording detail")

        let screen = NSRect(x: -1440, y: 30, width: 1440, height: 900)
        for anchor in FloatingControlAnchor.allCases {
            let rest = CaptureHUDGeometry.frame(size: FloatingToolbarDisclosure.collapsed.size(at: anchor), anchor: anchor,
                previous: nil, screens: [screen], preferred: screen)
            try check((rest.height > rest.width) == (anchor == .left || anchor == .right),
                      "pill orientation follows its edge: " + anchor.title)
            for disclosure in [FloatingToolbarDisclosure.hovered, .expanded] {
                let revealed = CaptureHUDGeometry.frame(size: disclosure.size(at: anchor), anchor: anchor,
                    previous: rest, screens: [screen], preferred: screen)
                let collapsed = CaptureHUDGeometry.frame(size: FloatingToolbarDisclosure.collapsed.size(at: anchor),
                    anchor: anchor, previous: revealed, screens: [screen], preferred: screen)
                try check(revealed.contains(rest) && collapsed == rest,
                          "reveal retains the hover target and anchor: " + anchor.title)
            }
        }
        for display in [screen, NSRect(x: 0, y: -900, width: 1440, height: 900)] {
            let drops = stride(from: 0.1, through: 0.9, by: 0.2).flatMap { x in
                stride(from: 0.1, through: 0.9, by: 0.2).map { y in
                    NSRect(x: display.minX + display.width * x, y: display.minY + display.height * y, width: 368, height: 60)
                }
            }
            try check(drops.allSatisfy { drop in
                let anchor = FloatingToolbarDocking.anchor(for: drop, in: display)
                let destination = FloatingControlGeometry.frame(anchor: anchor, size: drop.size, visibleFrame: display)
                return display.contains(destination) && FloatingControlGeometry.nearestAnchor(to: destination, in: display) == anchor
            }, "arbitrary drops on offset displays always resolve to valid named slots")
        }
        var shortcut = VoiceShortcut(keyCode: 18)
        try check(FloatingToolbar.shortcutLabel(shortcut, failure: nil) == shortcut.label, "configured shortcut is shown")
        try check(FloatingToolbar.shortcutLabel(shortcut, failure: "In use") == "Shortcut unavailable", "failed binding is not advertised")
        shortcut.enabled = false
        try check(FloatingToolbar.shortcutLabel(shortcut, failure: nil) == "Shortcut off", "disabled binding is not advertised")
        print("FLOATING_TOOLBAR_CHECKS_OK: \(count) checks passed")
    }
}
