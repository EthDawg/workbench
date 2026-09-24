import AppKit
import Combine
import SwiftUI

/// Drawing geometry only. Destination selection stays with nearestAnchor.
struct FloatingControlGuideLayout {
    let visibleFrame: NSRect
    let targets: [FloatingControlTarget]
    let activeID: FloatingControlAnchor?
    let usesCompactMarks: Bool

    init?(controlFrame: NSRect?, visibleFrame: NSRect, activeAnchor: FloatingControlAnchor?) {
        guard let controlFrame,
              [controlFrame.minX, controlFrame.minY, controlFrame.width, controlFrame.height].allSatisfy(\.isFinite),
              controlFrame.width > 0, controlFrame.height > 0 else { return nil }
        let targets = FloatingControlGeometry.targets(size: controlFrame.size, visibleFrame: visibleFrame)
        guard !targets.isEmpty else { return nil }
        self.visibleFrame = visibleFrame; self.targets = targets
        let activeFrame = activeAnchor.map {
            FloatingControlGeometry.frame(anchor: $0, size: controlFrame.size, visibleFrame: visibleFrame)
        }
        // Named anchors may coincide on small displays. Highlight their one guide.
        activeID = targets.first { $0.frame == activeFrame }?.id
        usesCompactMarks = targets.enumerated().contains { index, target in
            targets.dropFirst(index + 1).contains { other in
                let overlap = target.frame.intersection(other.frame)
                return !overlap.isNull && overlap.width * overlap.height > target.frame.width * target.frame.height * 0.35
            }
        }
    }

    /// Convert global AppKit coordinates to this guide's top-left SwiftUI canvas.
    func localFrame(_ frame: NSRect) -> NSRect {
        NSRect(x: frame.minX - visibleFrame.minX, y: visibleFrame.maxY - frame.maxY,
               width: frame.width, height: frame.height)
    }
    func markFrame(for target: FloatingControlTarget) -> NSRect {
        guard usesCompactMarks else { return target.frame }
        let side = min(12, target.frame.width, target.frame.height)
        return NSRect(x: target.frame.midX - side / 2, y: target.frame.midY - side / 2, width: side, height: side)
    }
    func activeOutline(for target: FloatingControlTarget) -> NSRect {
        // Keep a ring visible when the dragged control covers its destination.
        target.frame.insetBy(dx: -5, dy: -5).intersection(visibleFrame)
    }
}

/// Shared by in-window presentation controls and the two floating HUDs.
public struct FloatingControlGuides: View {
    private let layout: FloatingControlGuideLayout?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(controlFrame: NSRect?, visibleFrame: NSRect, activeAnchor: FloatingControlAnchor?) {
        layout = FloatingControlGuideLayout(controlFrame: controlFrame, visibleFrame: visibleFrame, activeAnchor: activeAnchor)
    }

    public var body: some View {
        Group {
            if let layout {
                ZStack(alignment: .topLeading) {
                    ForEach(layout.targets) { target in
                        let active = layout.activeID == target.id
                        let frame = layout.localFrame(layout.markFrame(for: target))
                        outline(active: active, compact: layout.usesCompactMarks)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                        if active {
                            let ring = layout.localFrame(layout.activeOutline(for: target))
                            outline(active: true, compact: false)
                                .frame(width: ring.width, height: ring.height)
                                .position(x: ring.midX, y: ring.midY)
                        }
                    }
                }
                .frame(width: layout.visibleFrame.width, height: layout.visibleFrame.height)
                .clipped()
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
        .transaction { $0.disablesAnimations = true }
        .tint(Workbench.accent).workbenchTheme()
    }

    private func outline(active: Bool, compact: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 4 : 12)
        return shape
            .fill(active && !reduceTransparency ? Workbench.accent.opacity(0.10) : Color.clear)
            .overlay(shape.stroke(Color(nsColor: .windowBackgroundColor), lineWidth: active ? 5 : 3))
            .overlay(shape.stroke(active ? Workbench.accent : Color.primary,
                                  style: StrokeStyle(lineWidth: active ? 3 : 1, dash: active ? [] : [4, 3])))
    }
}

private final class FloatingControlGuidePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Own one temporary, click-through drawing surface for a floating control drag.
/// Each caller owns its lifetime and calls hide on drag end/cancel/control hide.
@MainActor public final class FloatingControlGuideController {
    private var panel: FloatingControlGuidePanel?
    private var hostingView: NSHostingView<FloatingControlGuides>?
    private weak var owner: NSWindow?
    private var observations = Set<AnyCancellable>()
    private var isShutDown = false

    public init() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.hide() }.store(in: &observations)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.shutdown() }.store(in: &observations)
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .receive(on: RunLoop.main).sink { [weak self] notification in
                guard let self, let window = notification.object as? NSWindow, window === self.owner else { return }
                self.hide()
            }.store(in: &observations)
    }

    public func show(controlFrame: NSRect, visibleFrame: NSRect, activeAnchor: FloatingControlAnchor?, below window: NSWindow) {
        guard !isShutDown, window.isVisible,
              FloatingControlGuideLayout(controlFrame: controlFrame, visibleFrame: visibleFrame, activeAnchor: activeAnchor) != nil else {
            hide(); return
        }
        if panel == nil {
            let panel = FloatingControlGuidePanel(contentRect: visibleFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.setAccessibilityElement(false)
            self.panel = panel
        }
        guard let panel else { return }
        owner = window; panel.level = window.level
        panel.setFrame(visibleFrame, display: false, animate: false)
        let guides = FloatingControlGuides(controlFrame: controlFrame, visibleFrame: visibleFrame, activeAnchor: activeAnchor)
        if let hostingView { hostingView.rootView = guides }
        else {
            let hostingView = NSHostingView(rootView: guides)
            self.hostingView = hostingView; panel.contentView = hostingView
        }
        panel.order(.below, relativeTo: window.windowNumber)
    }

    public func hide() {
        panel?.orderOut(nil); panel?.contentView = nil; hostingView = nil; owner = nil
    }

    public func shutdown() {
        hide(); isShutDown = true; observations.removeAll()
        panel?.close(); panel = nil
    }
}
