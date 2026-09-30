import AppKit
import SwiftUI
import ToolbarCore
import VoiceAppearance

public struct ToolbarDragActions {
    public var begin: () -> Void
    public var move: () -> Void
    public var end: () -> Void
    public var cancel: () -> Void
    public var isCancelled: () -> Bool
    public var constrain: (CGRect) -> CGRect
    public init(begin: @escaping () -> Void = {}, move: @escaping () -> Void = {}, end: @escaping () -> Void = {}, cancel: @escaping () -> Void = {},
                isCancelled: @escaping () -> Bool = { false }, constrain: @escaping (CGRect) -> CGRect = { $0 }) {
        self.begin = begin; self.move = move; self.end = end
        self.cancel = cancel; self.isCancelled = isCancelled; self.constrain = constrain
    }
}

public extension ToolbarAnchor {
    /// Keep content on the same reference as the native window during measurement and
    /// animation: centred at top/bottom, or against the inward growth edge at the sides.
    var contentAlignment: Alignment {
        Alignment(horizontal: self == .top || self == .bottom ? .center : growsLeftward ? .trailing : .leading,
                  vertical: isVertical ? .center : self == .top || self == .topLeft || self == .topRight ? .top : .bottom)
    }
}

public extension View {
    /// Hold toolbar content against its dock whatever size the window is. Apply
    /// outside any measurement of the row, so the row still reports its own size.
    func pinnedToDock(_ anchor: ToolbarAnchor, isFloating: Bool = false) -> some View {
        GeometryReader { geometry in
            self.environment(\.toolbarViewport, geometry.size)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
                       alignment: isFloating ? .center : anchor.contentAlignment)
        }
        .coordinateSpace(name: ToolbarRevealVisuals.coordinateSpace)
    }
}

/// The production look and the gallery are the same view, fed one frozen value.
///
/// At rest the toolbar is the compact mark in every state (#134): a small capsule whose
/// only visual activity is the recording dot and voice trace; tool identity waits for reveal.
/// A click on it only reveals and takes the keyboard; a
/// drag moves the toolbar. Revealed, the row is `[switch tool] [recording signal] [next action] [contextual controls]`,
/// horizontal at top/bottom/free/corner positions and vertical at side edges. Right-hand
/// corners reverse the row; both side columns keep the same top-to-bottom order.
/// The launcher opens tools and their activity commands. Contextual controls act on
/// their named owner; a right-click opens only toolbar settings.
public struct ToolbarRow: View {
    public let state: ToolbarViewState
    private let press: () -> (() -> Void)?
    private let pressCapture: (ToolbarCaptureKind) -> (() -> Void)?
    private let openChooser: (NSView) -> Void
    private let makeMenu: () -> NSMenu
    private let menuBegan: (NSMenu) -> Bool
    private let menuEnded: () -> Void
    private let focusButton: (NSButton) -> Void
    private let escape: () -> Void
    private let revealFromRest: () -> Void
    private let drag: ToolbarDragActions
    private let textScale: CGFloat
    private let accent: Color
    private let makeAccessoryMenu: () -> NSMenu
    /// When set, the accessory opens the host's own surface anchored to the
    /// button instead of popping up `makeAccessoryMenu`'s menu.
    private let openAccessory: ((NSView) -> Void)?
    private let makeViewMenu: () -> NSMenu
    private let pressQuick: () -> (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.toolbarViewport) private var viewport
    @ScaledMetric(relativeTo: .body) private var systemScale: CGFloat = 1
    /// Tab and Shift-Tab between the row's controls (#223).
    @State private var keyCycle = ToolbarKeyCycle()
    @State private var hints = ToolbarHintController()

    /// `press` latches the next action when the button goes down and returns what to do if
    /// the press ends as a click; nil when there is nothing to do. `action` is the plain form.
    public init(state: ToolbarViewState, textScale: CGFloat = 1, accent: Color = .accentColor,
                makeAccessoryMenu: @escaping () -> NSMenu = { NSMenu() },
                openAccessory: ((NSView) -> Void)? = nil,
                makeViewMenu: @escaping () -> NSMenu = { NSMenu() },
                pressQuick: @escaping () -> (() -> Void)? = { nil },
                action: @escaping () -> Void = {},
                press: (() -> (() -> Void)?)? = nil,
                pressCapture: @escaping (ToolbarCaptureKind) -> (() -> Void)? = { _ in nil },
                openChooser: @escaping (NSView) -> Void = { _ in },
                makeMenu: @escaping () -> NSMenu = { NSMenu() },
                menuBegan: @escaping (NSMenu) -> Bool = { _ in true }, menuEnded: @escaping () -> Void = {},
                focusButton: @escaping (NSButton) -> Void = { _ in }, escape: @escaping () -> Void = {},
                revealFromRest: @escaping () -> Void = {},
                drag: ToolbarDragActions = ToolbarDragActions()) {
        self.state = state; self.textScale = textScale; self.accent = accent
        self.press = press ?? { action }
        self.pressCapture = pressCapture
        self.openChooser = openChooser; self.makeMenu = makeMenu
        self.menuBegan = menuBegan; self.menuEnded = menuEnded; self.focusButton = focusButton
        self.escape = escape; self.revealFromRest = revealFromRest; self.drag = drag
        self.makeAccessoryMenu = makeAccessoryMenu
        self.openAccessory = openAccessory
        self.makeViewMenu = makeViewMenu; self.pressQuick = pressQuick
    }
    private var interactionDrag: ToolbarDragActions {
        ToolbarDragActions(begin: { hints.isReady = false; drag.begin() }, move: drag.move,
            end: { drag.end(); hints.isReady = controlsReady },
            cancel: { drag.cancel(); hints.isReady = controlsReady }, isCancelled: drag.isCancelled, constrain: drag.constrain)
    }

    private var scale: CGFloat { textScale * systemScale }
    private var vertical: Bool { state.anchor.isVertical }
    private var alignment: Alignment { state.isFloating ? .center : state.anchor.contentAlignment }
    private func oriented(_ width: CGFloat, _ height: CGFloat) -> CGSize {
        ToolbarLayout.oriented(CGSize(width: width, height: height), for: state.anchor)
    }
    private var rowLength: CGFloat {
        let actions = max(1, state.captureChoices.count), accessory = state.showsAccessory ? state.accessoryCount : 0
        let signal = state.status.indicator == .capture ? 1 : 0
        return ToolbarLayout.launcherWidth + scale * (CGFloat(actions) * ToolbarLayout.primaryMinimum
            + CGFloat(accessory) * ToolbarLayout.accessoryWidth + ToolbarLayout.padding
            + CGFloat(signal) * ToolbarLayout.captureSignalWidth
            + CGFloat(actions + accessory + signal) * ToolbarLayout.gap)
    }
    /// A resting handle turning a corner has a different footprint from an opening row.
    /// Derive its ink from the same native frame, without another animation or state owner.
    private var turnsAtRest: Bool {
        guard state.tier == .resting, let viewport else { return false }
        let major = vertical ? viewport.height : viewport.width, cross = vertical ? viewport.width : viewport.height
        return major < 48 && major >= 28 && cross > 28 && cross <= 48
    }

    private var revealProgress: CGFloat {
        if turnsAtRest { return 0 }
        guard !reduceMotion, let viewport else { return state.tier == .resting ? 0 : 1 }
        return ToolbarRevealVisuals.progress(viewportHeight: vertical ? viewport.width : viewport.height, rowHeight: ToolbarLayout.rowHeight * scale)
    }

    // Let the capsule make room before controls appear. The same curve reverses
    // on close, so glyphs disappear before the shrinking edge can cut through them.
    private var controlOpacity: CGFloat {
        let major = viewport.map { vertical ? $0.height : $0.width } ?? rowLength
        let progress = min(revealProgress, max(0, (major - 48) / max(1, rowLength - 48)))
        return ToolbarRevealVisuals.glyphOpacity(progress: progress)
    }
    private var controlsReady: Bool {
        let expected = oriented(rowLength, ToolbarLayout.rowHeight * scale)
        return state.tier == .revealed && revealProgress >= 0.999
            && (viewport.map { abs($0.width - expected.width) < 1 && abs($0.height - expected.height) < 1 } ?? true)
    }
    private var symbolSize: CGFloat { 12 + (15 * scale - 12) * revealProgress }

    public var body: some View {
        Group {
            if state.tier == .resting { compact.opacity(1 - controlOpacity) }
            else { row.opacity(controlOpacity).allowsHitTesting(controlsReady).disabled(!controlsReady) }
        }
        .overlay(alignment: alignment) {
            if state.tier == .resting, revealProgress > 0 {
                row.opacity(controlOpacity).allowsHitTesting(false).disabled(true).accessibilityHidden(true)
            } else if state.tier == .revealed, revealProgress < 1 {
                compact.opacity(1 - controlOpacity).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .mask {
            // Only the transition needs to clip unfolding controls.
            if state.tier == .resting && revealProgress == 0 { Color.white }
            else { chrome(mask: true) }
        }
        .background { chrome() }
        .contentShape(Rectangle())
        .tint(accent)
        .environment(\.colorScheme, .dark)
        .environment(\.controlActiveState, .active)
        .onExitCommand(perform: escape)
        .onDisappear { hints.hide() }
        .onChange(of: controlsReady, initial: true) { _, ready in hints.anchor = state.anchor; hints.isReady = ready }
        .onChange(of: state.anchor) { _, anchor in hints.hide(); hints.anchor = anchor }
        .transaction { $0.animation = nil }
    }

    /// The dock supplies its current layout bounds synchronously. The chrome and
    /// mask share those bounds without observing, resizing or animating a window.
    private func chrome(mask: Bool = false) -> some View {
        GeometryReader { geometry in
            let size = viewport ?? geometry.size
            let viewportCross = vertical ? size.width : size.height
            let cross = viewportCross > ToolbarLayout.rowHeight * scale ? viewportCross
                : ToolbarRevealVisuals.capsuleHeight(progress: revealProgress, rowHeight: ToolbarLayout.rowHeight * scale, indicator: state.status.indicator)
            let restCross = ToolbarLayout.restingCapsuleHeight(for: state.status.indicator)
            let capsule = turnsAtRest
                ? CGSize(width: restCross + (size.width - 28) * (48 - restCross) / 20,
                         height: restCross + (size.height - 28) * (48 - restCross) / 20)
                : vertical ? CGSize(width: cross, height: size.height) : CGSize(width: size.width, height: cross)
            let x = alignment.horizontal == .center ? (geometry.size.width - size.width) / 2
                : alignment.horizontal == .trailing ? geometry.size.width - size.width : 0
            let y = alignment.vertical == .center ? (geometry.size.height - size.height) / 2
                : alignment.vertical == .bottom ? geometry.size.height - size.height : 0
            Capsule(style: .circular).fill(mask ? AnyShapeStyle(Color.white) : chromeFill)
                .overlay {
                    if !mask { Capsule(style: .circular).strokeBorder(.white.opacity(0.14), lineWidth: 1) }
                }
                .frame(width: capsule.width, height: capsule.height)
                .offset(x: x + (size.width - capsule.width) / 2, y: y + (size.height - capsule.height) / 2)
        }
        .allowsHitTesting(false)
    }

    private var chromeFill: AnyShapeStyle {
        AnyShapeStyle(Color(white: 0.055))
    }

    /// The compact rest: a 48 × 28 target, transposed at the sides, whatever it shows.
    private var compact: some View {
        ToolbarCompactMark(status: state.status, accent: accent, drawsChrome: false, symbolSize: symbolSize, anchor: state.anchor)
            // Status glyphs stay upright and inside the current native window while its
            // handle changes orientation. Only this visual scales; the hit target does not.
            .scaleEffect(compactSignalScale)
            .offset(compactSignalOffset)
            .overlay {
                ToolbarRestTarget(label: "Workbench floating toolbar, \(state.mode.title)", status: state.status.spokenValue,
                                  reveal: revealFromRest, options: menuOpener, drag: interactionDrag)
            }
            .frame(width: ToolbarLayout.mark(for: state.anchor).width, height: ToolbarLayout.mark(for: state.anchor).height)
    }
    private var compactSignalScale: CGFloat {
        guard let viewport, state.tier == .resting else { return 1 }
        let rest = ToolbarLayout.mark(for: state.anchor)
        return min(1, viewport.width / rest.width, viewport.height / rest.height)
    }
    private var compactSignalOffset: CGSize {
        guard turnsAtRest, let viewport else { return .zero }
        let rest = ToolbarLayout.mark(for: state.anchor)
        return CGSize(width: (viewport.width - rest.width) / 2 * (alignment.horizontal == .leading ? 1 : alignment.horizontal == .trailing ? -1 : 0),
                      height: (viewport.height - rest.height) / 2 * (alignment.vertical == .top ? 1 : alignment.vertical == .bottom ? -1 : 0))
    }

    private var row: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: ToolbarLayout.gap * scale)) : AnyLayout(HStackLayout(spacing: ToolbarLayout.gap * scale))
        return layout {
            if !vertical && state.anchor.growsLeftward { quickControl; accessory; captureOrPrimary; captureSignal; launcher }
            else { launcher; captureSignal; captureOrPrimary; accessory; quickControl }
        }
        .padding(vertical ? .bottom : state.anchor.growsLeftward ? .leading : .trailing, ToolbarLayout.padding * scale)
        .frame(minWidth: vertical ? ToolbarLayout.rowHeight * scale : nil, minHeight: vertical ? nil : ToolbarLayout.rowHeight * scale).fixedSize()
        // Empty chrome is a handle too: a drag that starts beside or between the controls
        // moves the row. The controls sit above it and keep their own clicks.
        .background { ToolbarDragRegion(drag: interactionDrag, showsHandCursor: false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workbench floating toolbar")
    }

    /// Opens toolbar settings from a right-click on the launcher or compact rest.
    private var menuOpener: (NSView) -> Void {
        { [makeMenu, menuBegan, menuEnded, hints, anchor = state.anchor] view in
            hints.hide()
            let menu = makeMenu()
            guard menuBegan(menu) else { return }
            defer { (view as? ToolbarIconButton)?.reconcileHover(); menuEnded() }
            menu.popUp(positioning: nil, at: toolbarMenuLocation(menu, from: view, anchor: anchor), in: view)
        }
    }

    @ViewBuilder private var accessory: some View {
        if let accessory = state.accessory, state.shownAccessory != nil {
            ToolbarAccessoryButton(title: accessory.title, symbol: accessory.symbol, opensList: accessory.opensList, description: state.accessoryDescription,
                                   fontSize: 16 * scale, makeMenu: makeAccessoryMenu, openPanel: openAccessory,
                                   began: menuBegan, ended: menuEnded, escape: escape, keyCycle: keyCycle, hints: hints, anchor: state.anchor)
                .frame(width: oriented(ToolbarLayout.accessoryWidth * scale, ToolbarLayout.controlHeight * scale).width,
                       height: oriented(ToolbarLayout.accessoryWidth * scale, ToolbarLayout.controlHeight * scale).height)
                .modifier(ToolbarControlReveal(viewport: viewport, anchor: state.anchor))
        }
    }

    private var primary: some View {
        ToolbarPrimary(title: state.actionTitle, symbol: state.actionSymbol, help: state.actionHelp, isEnabled: state.isActionEnabled,
                       fontSize: 16 * scale, press: press, drag: interactionDrag, keyCycle: keyCycle, hints: hints)
            // SwiftUI sets a hosted control's enabled state from its environment once it is in a
            // window, over the one set below, so a disabled action says so here too (#223).
            .disabled(!state.isActionEnabled)
            .frame(width: oriented(ToolbarLayout.primaryMinimum * scale, ToolbarLayout.controlHeight * scale).width,
                   height: oriented(ToolbarLayout.primaryMinimum * scale, ToolbarLayout.controlHeight * scale).height)
            .modifier(ToolbarControlReveal(viewport: viewport, anchor: state.anchor))
    }

    @ViewBuilder private var captureOrPrimary: some View {
        if state.captureChoices.isEmpty {
            primary
        } else {
            // Keep Region, Window, Screen in reading order at either dock. Each target uses
            // the primary's native focus, hover hint, drag threshold and latched press.
            ForEach(state.captureChoices, id: \.self) { kind in
                ToolbarPrimary(title: kind.title, symbol: kind.symbol, help: state.captureHelp(kind),
                               isEnabled: state.isActionEnabled, fontSize: 16 * scale,
                               press: { pressCapture(kind) }, drag: interactionDrag, keyCycle: keyCycle, hints: hints,
                               identifier: "toolbar.capture." + kind.rawValue, slot: .capture(kind))
                    .disabled(!state.isActionEnabled)
                    .frame(width: oriented(ToolbarLayout.primaryMinimum * scale, ToolbarLayout.controlHeight * scale).width,
                           height: oriented(ToolbarLayout.primaryMinimum * scale, ToolbarLayout.controlHeight * scale).height)
                    .modifier(ToolbarControlReveal(viewport: viewport, anchor: state.anchor))
            }
        }
    }

    @ViewBuilder private var quickControl: some View {
        if let control = state.quickControl, state.showsAccessory {
            Group {
                if control == .presentationView {
                    ToolbarAccessoryButton(title: control.title, symbol: control.symbol, opensList: true, description: nil,
                        fontSize: 16 * scale, makeMenu: makeViewMenu, openPanel: nil,
                        began: menuBegan, ended: menuEnded, escape: escape, keyCycle: keyCycle, hints: hints,
                        anchor: state.anchor, identifier: "toolbar.view", slot: .quick)
                } else {
                    ToolbarPrimary(title: control.title, symbol: control.symbol, help: control.title, isEnabled: true,
                        fontSize: 16 * scale, press: pressQuick, drag: interactionDrag, keyCycle: keyCycle, hints: hints,
                        identifier: "toolbar.next-persona", slot: .quick)
                }
            }
            .frame(width: oriented(ToolbarLayout.accessoryWidth * scale, ToolbarLayout.controlHeight * scale).width,
                   height: oriented(ToolbarLayout.accessoryWidth * scale, ToolbarLayout.controlHeight * scale).height)
            .modifier(ToolbarControlReveal(viewport: viewport, anchor: state.anchor))
        }
    }

    /// Recording feedback has its own space, so Switch tool never changes identity.
    @ViewBuilder private var captureSignal: some View {
        if state.status.indicator == .capture {
            ToolbarCaptureSignal(status: state.status, accent: accent, vertical: vertical)
                .frame(width: oriented(ToolbarLayout.captureSignalWidth * scale, ToolbarLayout.controlHeight * scale).width,
                       height: oriented(ToolbarLayout.captureSignalWidth * scale, ToolbarLayout.controlHeight * scale).height)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    /// One stable chooser icon, including while a tool is recording or has a saved result.
    /// The native button retains its fixed target, keyboard handling and drag behaviour.
    private var launcher: some View {
        ToolbarLauncher(state: state, accent: accent, open: { view in hints.hide(); openChooser(view) }, options: menuOpener,
                        focus: { if state.tier == .revealed { focusButton($0) } }, escape: escape, drag: interactionDrag, keyCycle: keyCycle, hints: hints)
            .frame(width: oriented(ToolbarLayout.launcherWidth, ToolbarLayout.rowHeight * scale).width,
                   height: oriented(ToolbarLayout.launcherWidth, ToolbarLayout.rowHeight * scale).height)
            .overlay {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: symbolSize, weight: .medium)).foregroundStyle(.white)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }

}

/// Native options and accessory menus use the same inboard side as the custom panels.
@MainActor func toolbarMenuLocation(_ menu: NSMenu, from view: NSView, anchor: ToolbarAnchor) -> NSPoint {
    guard anchor.isVertical, let window = view.window else { return NSPoint(x: 0, y: view.bounds.maxY + 4) }
    var point = window.convertToScreen(view.convert(view.bounds, to: nil)).origin
    point.x = anchor == .right ? window.frame.minX - 8 - menu.size.width : window.frame.maxX + 8
    return view.convert(window.convertPoint(fromScreen: point), from: nil)
}

/// The compact rest's look: a quiet 48 × 8 handle, with a taller capsule only for a
/// recording dot and voice trace. Side edges transpose these dimensions.
/// The native target owns the full 48 × 28 or 28 × 48
/// bounds. One imperceptible native fill retains WindowServer hit routing; the compact
/// view itself paints only its capsule and signal, with no native window shadow.
public struct ToolbarCompactMark: View {
    let status: ToolbarStatus
    let accent: Color
    let drawsChrome: Bool
    let symbolSize: CGFloat
    let anchor: ToolbarAnchor

    public init(status: ToolbarStatus, accent: Color = .accentColor,
                drawsChrome: Bool = true, symbolSize: CGFloat = 12, anchor: ToolbarAnchor = .bottom) {
        self.status = status; self.accent = accent; self.drawsChrome = drawsChrome; self.symbolSize = symbolSize
        self.anchor = anchor
    }

    public var body: some View {
        ZStack {
            let height = ToolbarLayout.restingCapsuleHeight(for: status.indicator)
            if drawsChrome {
                Capsule().fill(capsuleFill)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                    .frame(width: anchor.isVertical ? height : ToolbarLayout.markCapsule.width,
                           height: anchor.isVertical ? ToolbarLayout.markCapsule.width : height)
            }
            indicator
        }
        .frame(width: ToolbarLayout.mark(for: anchor).width, height: ToolbarLayout.mark(for: anchor).height)
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }

    private var capsuleFill: AnyShapeStyle {
        AnyShapeStyle(Color(white: 0.055))
    }

    @ViewBuilder private var indicator: some View {
        if status.indicator == .capture {
            ToolbarCaptureSignal(status: status, accent: accent, vertical: anchor.isVertical)
        }
    }
}

/// A red recording dot and the input's own voice trace. Recovery belongs to the
/// owning page, so another job can never put a warning or timer icon on this signal.
struct ToolbarCaptureSignal: View {
    let status: ToolbarStatus
    let accent: Color
    var vertical = false
    static let size = CGSize(width: ToolbarLayout.markCapsule.width - 4, height: ToolbarLayout.statusHeight)
    var body: some View {
        VoiceTrace(level: status.level, accent: accent)
            .rotationEffect(.degrees(vertical ? 90 : 0))
            .frame(width: vertical ? VoiceTraceGeometry.size.height : VoiceTraceGeometry.size.width,
                   height: vertical ? VoiceTraceGeometry.size.width : VoiceTraceGeometry.size.height)
            .frame(width: vertical ? Self.size.height : Self.size.width, height: vertical ? Self.size.width : Self.size.height)
    }
}

/// The compact rest's pointer target. A click only reveals, and the whole click is its:
/// the mouse-up is taken here even if the row has already appeared under the pointer.
/// A drag moves the toolbar, and a right-click opens the tool's options.
private struct ToolbarRestTarget: NSViewRepresentable {
    let label: String
    let status: String
    let reveal: () -> Void
    let options: (NSView) -> Void
    let drag: ToolbarDragActions
    func makeNSView(context: Context) -> RestTargetView { RestTargetView() }
    func updateNSView(_ view: RestTargetView, context: Context) {
        view.reveal = reveal; view.options = options; view.drag = drag
        view.setAccessibilityLabel(label); view.setAccessibilityValue(status)
        view.setAccessibilityIdentifier("toolbar.rest")
    }
}

final class RestTargetView: NSView {
    var reveal: (() -> Void)?
    var options: ((NSView) -> Void)?
    var drag = ToolbarDragActions()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityHelp("Shows the toolbar")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // WindowServer passes clicks through alpha-zero pixels, regardless of NSView's
        // hitTest. One 8-bit alpha step keeps the generous target without the previous
        // stacked 1.2% rectangles or a shadow around their bounds.
        NSColor.black.withAlphaComponent(FloatingHitTarget.backingAlpha).setFill()
        bounds.fill()
    }
    override func mouseDown(with event: NSEvent) {
        trackToolbarDrag(view: self, event: event, actions: drag, clickAnywhere: true, click: { [weak self] in self?.reveal?() })
    }
    override func rightMouseDown(with event: NSEvent) { options?(self) }
    override func accessibilityPerformPress() -> Bool { reveal?(); return true }
}

/// The next action. A native button so a drag that starts on it moves the
/// window, exactly as it does from the launcher, and a click does the action.
private struct ToolbarPrimary: NSViewRepresentable {
    let title: String
    let symbol: String
    let help: String
    let isEnabled: Bool
    let fontSize: CGFloat
    let press: () -> (() -> Void)?
    let drag: ToolbarDragActions
    let keyCycle: ToolbarKeyCycle
    let hints: ToolbarHintController
    var identifier = "toolbar.primary"
    var slot: ToolbarKeyCycle.Slot = .primary
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PrimaryButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 36, height: proposal.height ?? 32)
    }
    func makeNSView(context: Context) -> PrimaryButton {
        let view = PrimaryButton()
        return view
    }
    func updateNSView(_ view: PrimaryButton, context: Context) {
        view.setSymbol(symbol, size: fontSize)
        // A resize can update this representable while the parent remains disabled.
        // Preserve that admission gate on every update, not just initial insertion.
        view.isEnabled = isEnabled && context.environment.isEnabled
        view.hints = hints; view.hint = help
        view.setAccessibilityHelp(help)
        view.setAccessibilityLabel(title)
        view.setAccessibilityIdentifier(identifier)
        view.press = press; view.drag = drag
        view.keyCycle = keyCycle; keyCycle.register(view, as: slot)
        view.invalidateIntrinsicContentSize()
    }
    final class PrimaryButton: ToolbarIconButton {
        var press: (() -> (() -> Void)?)?
        var drag = ToolbarDragActions()
        var keyCycle: ToolbarKeyCycle?
        override init(frame: NSRect) { super.init(frame: frame); target = self; action = #selector(runAction) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func runAction() { if isEnabled { press?()?() } }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        /// Tab from the launcher reaches the action.
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if keyCycle?.handle(event, from: self) == true { return }
            super.keyDown(with: event)
        }
        /// The operation is latched as the button goes down; the click acts on it only if it
        /// still holds when the button comes up. The second click of a double-click does
        /// nothing, so a double-click on Stop never also starts, and one that began on the
        /// compact rest never reaches work.
        override func mouseDown(with event: NSEvent) {
            guard event.clickCount < 2 else { return }
            dismissHint()
            highlight(true)
            defer { highlight(false) }
            // A disabled action still moves the toolbar when dragged, as it did while SwiftUI kept
            // it enabled in the window; a click on it does nothing.
            let commit = isEnabled ? press?() : nil
            trackToolbarDrag(view: self, event: event, actions: drag, click: { commit?() })
        }
        override func performClick(_ sender: Any?) { dismissHint(); if isEnabled { press?()?() } }
    }
}

/// The tool launcher: the current tool's symbol with a chevron. A click, Space, Return or
/// Down opens the chooser; a drag moves the toolbar; a right-click opens the tool's options.
private struct ToolbarLauncher: NSViewRepresentable {
    let state: ToolbarViewState
    let accent: Color
    let open: (NSView) -> Void
    let options: (NSView) -> Void
    let focus: (NSButton) -> Void
    let escape: () -> Void
    let drag: ToolbarDragActions
    let keyCycle: ToolbarKeyCycle
    let hints: ToolbarHintController
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LauncherButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 48, height: proposal.height ?? 40)
    }
    func makeNSView(context: Context) -> LauncherButton {
        let view = LauncherButton()
        view.isBordered = false
        view.title = ""
        view.imagePosition = .imageOnly
        return view
    }
    func updateNSView(_ view: LauncherButton, context: Context) {
        view.setAccessibilityLabel("Switch tool")
        view.setAccessibilityValue(state.launcherDescription)
        view.setAccessibilityHelp("Switch tool")
        view.setAccessibilityIdentifier("toolbar.launcher")
        view.hints = hints
        view.hint = "Switch tool · " + state.launcherDescription
        view.escape = escape; view.drag = drag
        view.keyCycle = keyCycle; keyCycle.register(view, as: .launcher)
        view.open = { [weak view] in if let view { open(view) } }
        view.options = { [weak view] in if let view { options(view) } }
        focus(view)
    }
}

final class LauncherButton: ToolbarIconButton {
    var open: (() -> Void)?
    var options: (() -> Void)?
    var escape: (() -> Void)?
    var drag = ToolbarDragActions()
    var keyCycle: ToolbarKeyCycle?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self; action = #selector(openChooser)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func openChooser() { if isEnabled { open?() } }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The second click of a double-click, including one that began on the compact rest, does nothing.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, event.clickCount < 2 else { return }
        dismissHint()
        highlight(true)
        defer { highlight(false) }
        trackToolbarDrag(view: self, event: event, actions: drag, click: { [weak self] in self?.open?() })
    }
    override func rightMouseDown(with event: NSEvent) { if isEnabled { options?() } }
    override func performClick(_ sender: Any?) { guard isEnabled else { return }; dismissHint(); open?() }
    override func keyDown(with event: NSEvent) {
        if keyCycle?.handle(event, from: self) == true { return }
        if event.keyCode == 53 { escape?() }
        else if isEnabled, [36, 49, 76, 125].contains(event.keyCode) { open?() }
        else { super.keyDown(with: event) }
    }
}

/// The chosen tool's contextual menu control. One that opens a list, a menu or the picker
/// carries a chevron; Review goes straight to the session's review and carries none. VoiceOver
/// hears its title or current-owner description, which the tooltip shows too. It answers
/// the keyboard as the launcher does: Space, Return, Enter or Down opens it, a menu only with admission, and
/// Escape leaves keyboard interaction.
private struct ToolbarAccessoryButton: NSViewRepresentable {
    let title: String
    let symbol: String
    let opensList: Bool
    let description: String?
    let fontSize: CGFloat
    let makeMenu: () -> NSMenu
    let openPanel: ((NSView) -> Void)?
    let began: (NSMenu) -> Bool
    let ended: () -> Void
    let escape: () -> Void
    let keyCycle: ToolbarKeyCycle
    let hints: ToolbarHintController
    let anchor: ToolbarAnchor
    var identifier = "toolbar.accessory"
    var slot: ToolbarKeyCycle.Slot = .accessory
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AccessoryButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 36, height: proposal.height ?? 32)
    }
    func makeNSView(context: Context) -> AccessoryButton { AccessoryButton() }
    func updateNSView(_ view: AccessoryButton, context: Context) {
        view.setSymbol(symbol, size: fontSize)
        view.setAccessibilityLabel(description ?? title); view.setAccessibilityIdentifier(identifier)
        view.hints = hints; view.hint = description ?? title
        view.setAccessibilityHelp(description ?? title)
        view.opensList = opensList
        view.escape = escape
        view.keyCycle = keyCycle; keyCycle.register(view, as: slot)
        view.open = { [weak view] in
            guard let view else { return }
            view.dismissHint()
            if let openPanel { openPanel(view); return }
            let menu = makeMenu(); guard began(menu) else { return }
            defer { view.reconcileHover(); ended() }
            menu.popUp(positioning: nil, at: toolbarMenuLocation(menu, from: view, anchor: anchor), in: view)
        }
    }
    final class AccessoryButton: ToolbarIconButton {
        var open: (() -> Void)?
        var escape: (() -> Void)?
        var keyCycle: ToolbarKeyCycle?
        var opensList = false
        override init(frame: NSRect) { super.init(frame: frame); target = self; action = #selector(openMenu) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        @objc private func openMenu() { if isEnabled { open?() } }
        override func mouseDown(with event: NSEvent) {
            guard isEnabled, event.clickCount < 2 else { return }
            dismissHint()
            highlight(true)
            defer { highlight(false); reconcileHover() }
            if opensList { open?() } else { super.mouseDown(with: event) }
        }
        override func keyDown(with event: NSEvent) {
            if keyCycle?.handle(event, from: self) == true { return }
            if event.keyCode == 53 { escape?() }
            else if isEnabled, [36, 49, 76, 125].contains(event.keyCode) { open?() }
            else { super.keyDown(with: event) }
        }
    }
}

/// The revealed row's keyboard cycle (#223). Tab moves the focus from the launcher to the next
/// action, contextual controls, and round to the launcher; Shift-Tab goes the other way. The
/// order is the same at every dock, whichever way the row is drawn, and a control that is absent,
/// hidden or disabled is passed over. The row moves the focus itself: AppKit's key-view loop
/// leaves buttons out while Full Keyboard Access is off (`canBecomeKeyView` is false for each),
/// so Tab there never left the launcher.
final class ToolbarKeyCycle {
    enum Slot: Hashable, CaseIterable {
        case launcher, primary, capture(ToolbarCaptureKind), accessory, quick
        static var allCases: [Self] { [.launcher, .primary] + ToolbarCaptureKind.allCases.map(Self.capture) + [.accessory, .quick] }
    }
    private final class Entry {
        weak var button: NSButton?
        init(_ button: NSButton) { self.button = button }
    }
    private var entries: [Slot: Entry] = [:]
    init() {}

    @MainActor func register(_ button: NSButton, as slot: Slot) {
        if entries[slot]?.button !== button { entries[slot] = Entry(button) }
    }

    /// Takes Tab or Shift-Tab, alone or with Control, and moves the focus from `button` to the
    /// next control in the cycle that can take it. Any other key is left to the button.
    @MainActor func handle(_ event: NSEvent, from button: NSButton) -> Bool {
        let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard event.keyCode == 48, held.isSubset(of: [.shift, .control]) else { return false }
        guard let window = button.window else { return true }
        let cycle = Slot.allCases.compactMap { entries[$0]?.button }.filter { control in
            control === button || (control.window === window && control.isEnabled && !control.isHiddenOrHasHiddenAncestor)
        }
        guard let index = cycle.firstIndex(where: { $0 === button }), cycle.count > 1 else { return true }
        window.makeFirstResponder(cycle[(index + (held.contains(.shift) ? cycle.count - 1 : 1)) % cycle.count])
        return true
    }
}

private struct ToolbarDragRegion: NSViewRepresentable {
    let drag: ToolbarDragActions
    var showsHandCursor = true
    func makeNSView(context: Context) -> DragRegion { DragRegion() }
    func updateNSView(_ view: DragRegion, context: Context) {
        view.drag = drag
        if view.showsHandCursor != showsHandCursor { view.showsHandCursor = showsHandCursor; view.window?.invalidateCursorRects(for: view) }
    }
}
private final class DragRegion: NSView {
    var drag = ToolbarDragActions()
    var showsHandCursor = true
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { trackToolbarDrag(view: self, event: event, actions: drag) }
    override func resetCursorRects() { if showsHandCursor { addCursorRect(bounds, cursor: .openHand) } }
}

/// Follows one press until the button comes up: past the drag threshold it moves the
/// window, otherwise it is a click, delivered only if the press ends over `view` (or
/// anywhere, for the compact rest, which may have been replaced by the row meanwhile).
/// Either way the whole press is taken here, so no other control ever sees its mouse-up.
@MainActor private func trackToolbarDrag(view: NSView, event: NSEvent, actions: ToolbarDragActions,
                                       clickAnywhere: Bool = false, click: (() -> Void)? = nil) {
    guard let window = view.window else { return }
    let start = window.convertPoint(toScreen: event.locationInWindow)
    var origin = window.frame.origin
    var dragging = false
    var endedNormally = false
    defer { if dragging { endedNormally ? actions.end() : actions.cancel() } }
    while window.isVisible {
        if dragging && actions.isCancelled() { break }
        guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .appKitDefined],
            until: Date(timeIntervalSinceNow: 0.1), inMode: .eventTracking, dequeue: true) else { continue }
        if dragging && actions.isCancelled() { break }
        if next.type == .appKitDefined {
            NSApp.sendEvent(next)
            if next.subtype == .applicationDeactivated { break }
            continue
        }
        let point = window.convertPoint(toScreen: next.locationInWindow)
        if !dragging && ToolbarDrag.isDrag(from: start, to: point) {
            actions.begin(); origin = window.frame.origin; dragging = true
        }
        if dragging {
            let proposed = CGRect(origin: NSPoint(x: origin.x + point.x - start.x, y: origin.y + point.y - start.y), size: window.frame.size)
            window.setFrame(actions.constrain(proposed), display: true)
            actions.move()
        }
        if next.type == .leftMouseUp {
            endedNormally = true
            if !dragging && (clickAnywhere || (view.window === window && view.bounds.contains(view.convert(next.locationInWindow, from: nil)))) {
                click?()
            }
            break
        }
    }
}
