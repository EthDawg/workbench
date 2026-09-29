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
    public init(begin: @escaping () -> Void = {}, move: @escaping () -> Void = {}, end: @escaping () -> Void = {}, cancel: @escaping () -> Void = {},
                isCancelled: @escaping () -> Bool = { false }) {
        self.begin = begin; self.move = move; self.end = end
        self.cancel = cancel; self.isCancelled = isCancelled
    }
}

public extension ToolbarAnchor {
    /// Where content sits inside its window: against the growth edge, where the launcher is,
    /// and centred on the launcher vertically. The window is sometimes briefly the wrong
    /// size, placed before new content has been measured or while it animates. Content
    /// centred in the window would then move the launcher out from under the pointer.
    var contentAlignment: Alignment {
        Alignment(horizontal: growsLeftward ? .trailing : .leading, vertical: .center)
    }
}

public extension View {
    /// Hold toolbar content against its dock whatever size the window is. Apply
    /// outside any measurement of the row, so the row still reports its own size.
    func pinnedToDock(_ anchor: ToolbarAnchor) -> some View {
        GeometryReader { geometry in
            self.environment(\.toolbarViewport, geometry.size)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
                       alignment: anchor.contentAlignment)
        }
        .coordinateSpace(name: ToolbarRevealVisuals.coordinateSpace)
    }
}

/// The production look and the gallery are the same view, fed one frozen value.
///
/// At rest the toolbar is the compact mark in every state (#134): a small capsule whose
/// signals highlight recording, transport and recovery; tool identity waits for reveal.
/// A click on it only reveals and takes the keyboard; a
/// drag moves the toolbar. Revealed, the row is `[tool ▾] [next action] [accessory] [⋯]`,
/// growing inward from the launcher, which sits exactly where the mark was; on a right-hand
/// dock the order is reversed. The launcher opens the tool chooser, More holds the tool's
/// options and the work running elsewhere, and a right-click anywhere on the tool opens
/// those options.
public struct ToolbarRow: View {
    public let state: ToolbarViewState
    private let press: () -> (() -> Void)?
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
                action: @escaping () -> Void = {},
                press: (() -> (() -> Void)?)? = nil,
                openChooser: @escaping (NSView) -> Void = { _ in },
                makeMenu: @escaping () -> NSMenu = { NSMenu() },
                menuBegan: @escaping (NSMenu) -> Bool = { _ in true }, menuEnded: @escaping () -> Void = {},
                focusButton: @escaping (NSButton) -> Void = { _ in }, escape: @escaping () -> Void = {},
                revealFromRest: @escaping () -> Void = {},
                drag: ToolbarDragActions = ToolbarDragActions()) {
        self.state = state; self.textScale = textScale; self.accent = accent
        self.press = press ?? { action }
        self.openChooser = openChooser; self.makeMenu = makeMenu
        self.menuBegan = menuBegan; self.menuEnded = menuEnded; self.focusButton = focusButton
        self.escape = escape; self.revealFromRest = revealFromRest; self.drag = drag
        self.makeAccessoryMenu = makeAccessoryMenu
        self.openAccessory = openAccessory
    }
    private var scale: CGFloat { textScale * systemScale }

    private var revealProgress: CGFloat {
        guard !reduceMotion, let viewport else { return state.tier == .resting ? 0 : 1 }
        return ToolbarRevealVisuals.progress(viewportHeight: viewport.height, rowHeight: ToolbarLayout.rowHeight * scale)
    }

    // Let the capsule make room before controls appear. The same curve reverses
    // on close, so glyphs disappear before the shrinking edge can cut through them.
    private var controlOpacity: CGFloat { ToolbarRevealVisuals.glyphOpacity(progress: revealProgress) }
    private var symbolSize: CGFloat { 12 + (15 * scale - 12) * revealProgress }

    public var body: some View {
        Group {
            if state.tier == .resting { compact.opacity(1 - controlOpacity) }
            else { row.opacity(controlOpacity) }
        }
        .overlay(alignment: state.anchor.contentAlignment) {
            if state.tier == .resting, revealProgress > 0 {
                row.opacity(controlOpacity).allowsHitTesting(false).accessibilityHidden(true)
            } else if state.tier == .revealed, revealProgress < 1 {
                compact.opacity(1 - controlOpacity).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .mask { chrome(mask: true) }
        .background { chrome() }
        // The whole resting target receives the pointer, including the clear
        // space above and below its smaller visible capsule.
        .background {
            if state.tier == .resting { Rectangle().fill(Color.black.opacity(0.012)) }
        }
        .tint(accent)
        .environment(\.colorScheme, .dark)
        .environment(\.controlActiveState, .active)
        .onExitCommand(perform: escape)
        .onDisappear { hints.hide() }
        .transaction { $0.animation = nil }
    }

    /// The dock supplies its current layout bounds synchronously. The chrome and
    /// mask share those bounds without observing, resizing or animating a window.
    private func chrome(mask: Bool = false) -> some View {
        GeometryReader { geometry in
            let size = viewport ?? geometry.size
            let height = ToolbarRevealVisuals.capsuleHeight(progress: revealProgress, rowHeight: ToolbarLayout.rowHeight * scale, indicator: state.status.indicator)
            Capsule(style: .circular).fill(mask ? AnyShapeStyle(Color.white) : chromeFill)
                .overlay {
                    if !mask { Capsule(style: .circular).strokeBorder(.white.opacity(0.14), lineWidth: 1) }
                }
                .frame(width: size.width, height: height)
                .overlay(alignment: state.anchor.contentAlignment) {
                    // Status badges can sit above the capsule. Mask only the
                    // unfolding controls; keep the full launcher target visible.
                    if mask { Rectangle().fill(.white).frame(width: ToolbarLayout.launcherWidth, height: size.height) }
                }
                .offset(x: state.anchor.growsLeftward ? geometry.size.width - size.width : 0,
                        y: (geometry.size.height - height) / 2)
        }
        .allowsHitTesting(false)
    }

    private var chromeFill: AnyShapeStyle {
        AnyShapeStyle(Color(white: 0.055))
    }

    /// The compact rest: the same 48 × 28 target in every state, whatever it shows.
    private var compact: some View {
        ToolbarCompactMark(status: state.status, accent: accent, drawsChrome: false, symbolSize: symbolSize)
            .overlay {
                ToolbarRestTarget(label: "Workbench floating toolbar, \(state.mode.title)", status: state.status.spokenValue,
                                  reveal: revealFromRest, options: menuOpener, drag: drag)
            }
            .frame(width: ToolbarLayout.mark.width, height: ToolbarLayout.mark.height)
            .help(state.mode.title + " · " + state.status.description + ". Click to show the toolbar; drag to move.")
    }

    private var row: some View {
        HStack(spacing: ToolbarLayout.gap * scale) {
            if state.anchor.growsLeftward { more; accessory; primary; launcher }
            else { launcher; primary; accessory; more }
        }
        .padding(state.anchor.growsLeftward ? .leading : .trailing, ToolbarLayout.padding * scale)
        .frame(minHeight: ToolbarLayout.rowHeight * scale).fixedSize()
        // Empty chrome is a handle too: a drag that starts beside or between the controls
        // moves the row. The controls sit above it and keep their own clicks.
        .background { ToolbarDragRegion(drag: drag, showsHandCursor: false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workbench floating toolbar")
    }

    /// Opens the tool's options, from More, a right-click on the launcher or the compact rest.
    private var menuOpener: (NSView) -> Void {
        { [makeMenu, menuBegan, menuEnded, hints] view in
            hints.hide()
            let menu = makeMenu()
            guard menuBegan(menu) else { return }
            defer { (view as? ToolbarIconButton)?.reconcileHover(); menuEnded() }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 4), in: view)
        }
    }

    @ViewBuilder private var accessory: some View {
        if let accessory = state.accessory, state.shownAccessory != nil {
            ToolbarAccessoryButton(title: accessory.title, symbol: accessory.symbol, opensList: accessory.opensList, description: state.accessoryDescription,
                                   fontSize: 16 * scale, makeMenu: makeAccessoryMenu, openPanel: openAccessory,
                                   began: menuBegan, ended: menuEnded, escape: escape, keyCycle: keyCycle, hints: hints)
                .frame(width: ToolbarLayout.accessoryWidth * scale, height: ToolbarLayout.controlHeight * scale)
                .modifier(ToolbarControlReveal(viewport: viewport, anchor: state.anchor))
        }
    }

    private var primary: some View {
        ToolbarPrimary(title: state.actionTitle, symbol: state.actionSymbol, help: state.actionHelp, isEnabled: state.isActionEnabled,
                       fontSize: 16 * scale, press: press, drag: drag, keyCycle: keyCycle, hints: hints)
            // SwiftUI sets a hosted control's enabled state from its environment once it is in a
            // window, over the one set below, so a disabled action says so here too (#223).
            .disabled(!state.isActionEnabled)
            .frame(width: ToolbarLayout.primaryMinimum * scale, height: ToolbarLayout.controlHeight * scale)
            .modifier(ToolbarControlReveal(viewport: viewport, anchor: state.anchor))
    }

    private var more: some View {
        ToolbarMore(tool: state.mode.title, size: 15 * scale, open: menuOpener, escape: escape, keyCycle: keyCycle, hints: hints)
            .frame(width: ToolbarLayout.moreWidth * scale, height: ToolbarLayout.controlHeight * scale)
            .modifier(ToolbarControlReveal(viewport: viewport, anchor: state.anchor))
    }

    /// The launcher's target is fixed at 48 points, the compact mark's width, so the two share
    /// one centre on screen at every text size. Its symbol stays on that centre as the
    /// capsule opens; a chevron appears beside it. The button itself draws nothing: it is the target, the keyboard
    /// focus and the accessibility element.
    private var launcher: some View {
        ToolbarLauncher(state: state, accent: accent, open: { view in hints.hide(); openChooser(view) }, options: menuOpener,
                        focus: { if state.tier == .revealed { focusButton($0) } }, escape: escape, drag: drag, keyCycle: keyCycle, hints: hints)
            .frame(width: ToolbarLayout.launcherWidth, height: ToolbarLayout.rowHeight * scale)
            .overlay {
                Group {
                    // Recording keeps the same voice trace and badges in both tiers.
                    if state.status.indicator == .capture {
                        ToolbarCaptureSignal(status: state.status, accent: accent)
                    } else {
                        Image(systemName: state.mode.symbol).font(.system(size: symbolSize, weight: .medium))
                            .foregroundStyle(.white)
                            .overlay(alignment: .topTrailing) {
                                if let glyph = ToolbarResultGlyph(state.status.indicator) {
                                    ToolbarBadge(id: "result", symbol: glyph.name, color: glyph.color, size: ToolbarLayout.badge * scale)
                                        .offset(x: 5 * scale, y: -4 * scale)
                                }
                            }
                            .overlay {
                                Image(systemName: "chevron.down").font(.system(size: 6 * scale, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.6)).offset(x: 12 * scale)
                            }
                    }
                }
                .allowsHitTesting(false).accessibilityHidden(true)
            }
            .overlay(alignment: .bottom) {
                // Otherwise one dot says work is live in some tool.
                if state.status.indicator != .capture && state.hasLiveWork {
                    Circle().fill(.tint).frame(width: 4, height: 4).padding(.bottom, 6 * scale).allowsHitTesting(false)
                }
            }
    }
}

/// The compact rest's look: a quiet 48 × 8 handle, with a taller capsule only for a
/// recording, transport or recovery signal. The whole 48 × 28 target is faintly filled
/// so it takes the pointer, while everything outside the panel stays click-through.
public struct ToolbarCompactMark: View {
    let status: ToolbarStatus
    let accent: Color
    let drawsChrome: Bool
    let symbolSize: CGFloat

    public init(status: ToolbarStatus, accent: Color = .accentColor,
                drawsChrome: Bool = true, symbolSize: CGFloat = 12) {
        self.status = status; self.accent = accent; self.drawsChrome = drawsChrome; self.symbolSize = symbolSize
    }

    public var body: some View {
        ZStack {
            // A fill the eye cannot see, so the whole target, not only the capsule, is the window's.
            Rectangle().fill(Color.black.opacity(0.012))
            let height = ToolbarLayout.restingCapsuleHeight(for: status.indicator)
            if drawsChrome {
                Capsule().fill(capsuleFill)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                    .frame(width: ToolbarLayout.markCapsule.width, height: height)
            }
            indicator
        }
        .frame(width: ToolbarLayout.mark.width, height: ToolbarLayout.mark.height)
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }

    private var capsuleFill: AnyShapeStyle {
        AnyShapeStyle(Color(white: 0.055))
    }

    @ViewBuilder private var indicator: some View {
        switch status.indicator {
        case .idle, .live: EmptyView()
        case .capture: ToolbarCaptureSignal(status: status, accent: accent)
        case .playback: symbol("speaker.wave.2.fill", accent)
        case .processing: symbol("ellipsis", Color.white.opacity(0.7))
        case .failure, .pendingDelivery, .unsavedCapture:
            if let glyph = ToolbarResultGlyph(status.indicator) { symbol(glyph.name, glyph.color) }
        case .paused: symbol("pause.fill", Color.white.opacity(0.7))
        }
    }

    private func symbol(_ name: String, _ style: Color) -> some View {
        Image(systemName: name).font(.system(size: symbolSize, weight: .medium)).foregroundStyle(style)
            .frame(width: ToolbarLayout.statusHeight, height: ToolbarLayout.statusHeight)
    }
}

/// A waiting result's glyph: a failure's warning, a result waiting to be delivered, or an unsaved
/// capture. The compact mark shows it at rest, and the launcher as a badge while the row is open.
struct ToolbarResultGlyph {
    let name: String
    let color: Color
    init?(_ indicator: ToolbarStatus.Indicator) {
        switch indicator {
        case .failure: (name, color) = ("exclamationmark.triangle.fill", .orange)
        case .pendingDelivery: (name, color) = ("doc.on.clipboard", .white)
        case .unsavedCapture: (name, color) = ("pencil", .white)
        default: return nil
        }
    }
}

/// A badge's glyph in a fixed square, so where it sits never depends on its symbol's metrics
/// (#211 F4). It reports where it was laid out to checks through `toolbarBadgeFrames`.
struct ToolbarBadge: View {
    /// "stopsSoon", "attention" or "result": what checks find it by.
    let id: String
    let symbol: String
    let color: Color
    var size: CGFloat = ToolbarLayout.badge
    @Environment(\.toolbarBadgeFrames) private var report
    var body: some View {
        Image(systemName: symbol).resizable().scaledToFit().fontWeight(.bold).foregroundStyle(color)
            .frame(width: size, height: size)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in report?(id, frame) }
    }
}

private struct ToolbarBadgeFramesKey: EnvironmentKey {
    static let defaultValue: ((String, CGRect) -> Void)? = nil
}

extension EnvironmentValues {
    /// Checks read each badge's frame, in its hosting view, from here; nil in the app.
    var toolbarBadgeFrames: ((String, CGRect) -> Void)? {
        get { self[ToolbarBadgeFramesKey.self] }
        set { self[ToolbarBadgeFramesKey.self] = newValue }
    }
}

/// The capture signal: the shared voice trace, a red recording dot and the recording owner's own
/// level through the shared envelope and stroke (#134, #209), with its badges. A timer beside the
/// trace says this recording stops at its limit within seconds; a warning on the capsule's corner
/// says another job needs attention, like a badge on an icon. Both show when both apply (#211 F4),
/// each about 7 points, inside the 48 × 28 target, and the words name every state
/// (`ToolbarStatus.description`). The compact mark shows it at rest and the launcher while the row
/// is open. The trace keeps still in silence and follows Reduce Motion and Increase Contrast.
struct ToolbarCaptureSignal: View {
    let status: ToolbarStatus
    let accent: Color
    /// The signal's box: the capsule's width less a 2-point margin each side, and its height.
    static let size = CGSize(width: ToolbarLayout.markCapsule.width - 4, height: ToolbarLayout.statusHeight)
    var body: some View {
        HStack(spacing: 3) {
            VoiceTrace(level: status.level, accent: accent)
            if status.badges.contains(.stopsSoon) {
                ToolbarBadge(id: "stopsSoon", symbol: "timer", color: .orange)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .overlay(alignment: .topTrailing) {
            if status.badges.contains(.attention) {
                ToolbarBadge(id: "attention", symbol: "exclamationmark.triangle.fill", color: .orange)
                    .offset(x: 1, y: -7)
            }
        }
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
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PrimaryButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 36, height: proposal.height ?? 32)
    }
    func makeNSView(context: Context) -> PrimaryButton {
        let view = PrimaryButton()
        return view
    }
    func updateNSView(_ view: PrimaryButton, context: Context) {
        view.setSymbol(symbol, size: fontSize)
        view.isEnabled = isEnabled
        view.hints = hints; view.hint = help
        view.setAccessibilityHelp(help)
        view.setAccessibilityLabel(title)
        view.setAccessibilityIdentifier("toolbar.primary")
        view.press = press; view.drag = drag
        view.keyCycle = keyCycle; keyCycle.register(view, as: .primary)
        view.invalidateIntrinsicContentSize()
    }
    final class PrimaryButton: ToolbarIconButton {
        var press: (() -> (() -> Void)?)?
        var drag = ToolbarDragActions()
        var keyCycle: ToolbarKeyCycle?
        override init(frame: NSRect) { super.init(frame: frame); target = self; action = #selector(runAction) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func runAction() { press?()?() }
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
        view.setAccessibilityLabel("Tool: " + state.mode.title)
        // A recording, and a result waiting for the person, keep their words on the launcher while
        // the row is open, as the mark carries them at rest (#134 T4, #211 F1).
        let status = state.status.indicator == .capture || ToolbarResultGlyph(state.status.indicator) != nil
        view.setAccessibilityValue(status ? state.launcherDescription + ". " + state.status.spokenValue : state.launcherDescription)
        view.setAccessibilityHelp("Choose a tool")
        view.setAccessibilityIdentifier("toolbar.launcher")
        view.hints = hints
        view.hint = "Choose a tool · " + (status ? state.launcherDescription + ". " + state.status.description : state.launcherDescription)
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
    @objc private func openChooser() { open?() }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The second click of a double-click, including one that began on the compact rest, does nothing.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount < 2 else { return }
        dismissHint()
        highlight(true)
        defer { highlight(false) }
        trackToolbarDrag(view: self, event: event, actions: drag, click: { [weak self] in self?.open?() })
    }
    override func rightMouseDown(with event: NSEvent) { options?() }
    override func performClick(_ sender: Any?) { dismissHint(); open?() }
    override func keyDown(with event: NSEvent) {
        if keyCycle?.handle(event, from: self) == true { return }
        if event.keyCode == 53 { escape?() }
        else if [36, 49, 76, 125].contains(event.keyCode) { open?() }
        else { super.keyDown(with: event) }
    }
}

/// More: the tool's options, the work running elsewhere, and the toolbar's own items.
private struct ToolbarMore: NSViewRepresentable {
    let tool: String
    let size: CGFloat
    let open: (NSView) -> Void
    let escape: () -> Void
    let keyCycle: ToolbarKeyCycle
    let hints: ToolbarHintController
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MoreButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 32, height: proposal.height ?? 32)
    }
    func makeNSView(context: Context) -> MoreButton {
        let view = MoreButton()
        view.isBordered = false
        view.imagePosition = .imageOnly
        return view
    }
    func updateNSView(_ view: MoreButton, context: Context) {
        view.setSymbol("ellipsis", size: size)
        view.setAccessibilityLabel("More")
        view.setAccessibilityHelp("Options for " + tool + ", other work and the toolbar")
        view.setAccessibilityIdentifier("toolbar.more")
        view.hints = hints; view.hint = "Options for " + tool
        view.escape = escape
        view.keyCycle = keyCycle; keyCycle.register(view, as: .more)
        view.open = { [weak view] in if let view { open(view) } }
    }
}

final class MoreButton: ToolbarIconButton {
    var open: (() -> Void)?
    var escape: (() -> Void)?
    var keyCycle: ToolbarKeyCycle?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self; action = #selector(openMenu)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func openMenu() { open?() }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { open?() }
    // Menus track the initiating press themselves, as a native popup button does. Do not
    // nest NSButton's mouse-up tracking around NSMenu in a nonactivating panel.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, event.clickCount < 2 else { return }
        highlight(true)
        defer { highlight(false); reconcileHover() }
        dismissHint(); open?()
    }
    override func performClick(_ sender: Any?) { dismissHint(); open?() }
    override func keyDown(with event: NSEvent) {
        if keyCycle?.handle(event, from: self) == true { return }
        if event.keyCode == 53 { escape?() }
        else if [36, 49, 76, 125].contains(event.keyCode) { open?() }
        else { super.keyDown(with: event) }
    }
}

/// The chosen tool's one accessory (#134 part B). One that opens a list, a menu or the picker
/// carries a chevron; Review goes straight to the session's review and carries none. VoiceOver
/// hears its title without the chevron, or its description when it has one ("Appearance of the
/// selected persona, hidden"), which the tooltip shows too. It answers the keyboard as the
/// launcher and More do: Space, Return, Enter or Down opens it, a menu only with admission, and
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
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AccessoryButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 36, height: proposal.height ?? 32)
    }
    func makeNSView(context: Context) -> AccessoryButton { AccessoryButton() }
    func updateNSView(_ view: AccessoryButton, context: Context) {
        view.setSymbol(symbol, size: fontSize)
        view.setAccessibilityLabel(description ?? title); view.setAccessibilityIdentifier("toolbar.accessory")
        view.hints = hints; view.hint = description ?? title
        view.setAccessibilityHelp(description ?? title)
        view.opensList = opensList
        view.escape = escape
        view.keyCycle = keyCycle; keyCycle.register(view, as: .accessory)
        view.open = { [weak view] in
            guard let view else { return }
            view.dismissHint()
            if let openPanel { openPanel(view); return }
            let menu = makeMenu(); guard began(menu) else { return }
            defer { view.reconcileHover(); ended() }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 4), in: view)
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
        @objc private func openMenu() { open?() }
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
            else if [36, 49, 76, 125].contains(event.keyCode) { open?() }
            else { super.keyDown(with: event) }
        }
    }
}

/// The revealed row's keyboard cycle (#223). Tab moves the focus from the launcher to the next
/// action, the accessory and More, and round to the launcher; Shift-Tab goes the other way. The
/// order is the same at every dock, whichever way the row is drawn, and a control that is absent,
/// hidden or disabled is passed over. The row moves the focus itself: AppKit's key-view loop
/// leaves buttons out while Full Keyboard Access is off (`canBecomeKeyView` is false for each),
/// so Tab there never left the launcher.
final class ToolbarKeyCycle {
    enum Slot: CaseIterable { case launcher, primary, accessory, more }
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
        if next.type == .leftMouseUp {
            endedNormally = true
            if !dragging && (clickAnywhere || (view.window === window && view.bounds.contains(view.convert(next.locationInWindow, from: nil)))) {
                click?()
            }
            break
        }
        if dragging {
            window.setFrameOrigin(NSPoint(x: origin.x + point.x - start.x, y: origin.y + point.y - start.y))
            actions.move()
        }
    }
}
