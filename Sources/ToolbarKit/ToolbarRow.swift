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
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor.contentAlignment)
    }
}

/// The production look and the gallery are the same view, fed one frozen value.
///
/// At rest the toolbar is the compact mark in every state (#134): a small capsule whose
/// indicator says what is running. A click on it only reveals and takes the keyboard; a
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .body) private var systemScale: CGFloat = 1

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

    public var body: some View {
        Group {
            if state.tier == .resting { compact } else { row }
        }
        .tint(accent)
        .environment(\.controlActiveState, .active)
        .onExitCommand(perform: escape)
        .transaction { $0.animation = nil }
    }

    /// The compact rest: the same 48 × 28 target in every state, whatever it shows.
    private var compact: some View {
        ToolbarCompactMark(status: state.status, accent: accent)
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
        // A capsule with circular ends for both the fill and its edge: a continuous-corner fill
        // clamps its radius and would show a sliver of material beyond the stroke at each end.
        .background {
            if reduceTransparency { Capsule(style: .circular).fill(Color(nsColor: .windowBackgroundColor)) }
            else { Capsule(style: .circular).fill(.regularMaterial) }
        }
        .overlay { Capsule(style: .circular).strokeBorder(.primary.opacity(0.14), lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workbench floating toolbar")
    }

    /// Opens the tool's options, from More, a right-click on the launcher or the compact rest.
    private var menuOpener: (NSView) -> Void {
        { [makeMenu, menuBegan, menuEnded] view in
            let menu = makeMenu()
            guard menuBegan(menu) else { return }
            defer { menuEnded() }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 4), in: view)
        }
    }

    @ViewBuilder private var accessory: some View {
        if let accessory = state.accessory, state.shownAccessory != nil {
            ToolbarAccessoryButton(title: accessory.title, opensList: accessory.opensList, description: state.accessoryDescription,
                                   fontSize: 12 * scale, makeMenu: makeAccessoryMenu, openPanel: openAccessory,
                                   began: menuBegan, ended: menuEnded, escape: escape)
                .frame(width: ToolbarLayout.accessoryWidth * scale, height: ToolbarLayout.controlHeight * scale)
        }
    }

    private var primary: some View {
        ToolbarPrimary(title: state.actionTitle, hint: state.actionHint, isEnabled: state.isActionEnabled,
                       fontSize: 13 * scale, minimumWidth: ToolbarLayout.primaryMinimum, minimumTitles: state.minimumTitles,
                       accent: accent, press: press, drag: drag)
            .frame(height: ToolbarLayout.controlHeight * scale)
            .fixedSize()
    }

    private var more: some View {
        ToolbarMore(size: 15 * scale, open: menuOpener, escape: escape)
            .frame(width: ToolbarLayout.moreWidth * scale, height: ToolbarLayout.controlHeight * scale)
    }

    /// The launcher's target is fixed at 48 points, the compact mark's width, so the two share
    /// one centre on screen at every text size; its symbol and chevron grow inside it, centred
    /// together on that centre. The button itself draws nothing: it is the target, the keyboard
    /// focus and the accessibility element.
    private var launcher: some View {
        ToolbarLauncher(state: state, accent: accent, open: openChooser, options: menuOpener,
                        focus: focusButton, escape: escape, drag: drag)
            .frame(width: ToolbarLayout.launcherWidth, height: ToolbarLayout.rowHeight * scale)
            .overlay {
                // While something records, the launcher carries the compact mark's capture signal in
                // place of the tool's symbol and chevron, so opening the row never hides it (#134 T4).
                // The shared trace keeps its size at every text size, so it fits the 48-point target;
                // the launcher still opens the chooser, and its words still name the tool.
                HStack(spacing: 2 * (state.status.indicator == .capture ? 1 : scale)) {
                    if state.status.indicator == .capture {
                        ToolbarCaptureSignal(status: state.status, accent: accent)
                    } else {
                        Image(systemName: state.mode.symbol).font(.system(size: 15 * scale, weight: .medium))
                            .foregroundStyle(state.isBusy ? AnyShapeStyle(accent) : AnyShapeStyle(Color.primary))
                            .overlay(alignment: .topTrailing) {
                                // A waiting result keeps its status on the launcher while the row is
                                // open, the mark's glyph as a badge on the tool's symbol (#211 F1).
                                if let glyph = ToolbarResultGlyph(state.status.indicator) {
                                    ToolbarBadge(id: "result", symbol: glyph.name, color: glyph.color, size: ToolbarLayout.badge * scale)
                                        .offset(x: 5 * scale, y: -4 * scale)
                                }
                            }
                        Image(systemName: "chevron.down").font(.system(size: 6 * scale, weight: .semibold)).foregroundStyle(.secondary)
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

/// The compact rest's look (#134): a 48 × 8 capsule at idle; with work, a 48 × 12 capsule
/// carrying one 12-point indicator. The whole 48 × 28 target is faintly filled so it takes
/// the pointer, while everything outside the panel stays click-through.
public struct ToolbarCompactMark: View {
    let status: ToolbarStatus
    let accent: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(status: ToolbarStatus, accent: Color = .accentColor) { self.status = status; self.accent = accent }

    public var body: some View {
        ZStack {
            // A fill the eye cannot see, so the whole target, not only the capsule, is the window's.
            Rectangle().fill(Color.black.opacity(0.012))
            let height = status.indicator == .idle ? ToolbarLayout.markCapsule.height : ToolbarLayout.statusHeight
            Capsule().fill(capsuleFill)
                .overlay(Capsule().strokeBorder(.primary.opacity(0.3), lineWidth: 1))
                .frame(width: ToolbarLayout.markCapsule.width, height: height)
                .overlay { indicator }
        }
        .frame(width: ToolbarLayout.mark.width, height: ToolbarLayout.mark.height)
        .accessibilityHidden(true)
    }

    private var capsuleFill: AnyShapeStyle {
        reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial)
    }

    @ViewBuilder private var indicator: some View {
        switch status.indicator {
        case .idle: EmptyView()
        case .capture: ToolbarCaptureSignal(status: status, accent: accent)
        case .playback: symbol("speaker.wave.2.fill", accent)
        case .processing: symbol("ellipsis", Color.secondary)
        case .failure, .pendingDelivery, .unsavedCapture:
            if let glyph = ToolbarResultGlyph(status.indicator) { symbol(glyph.name, glyph.color) }
        case .paused: symbol("pause.fill", Color.secondary)
        case .live(let work): symbol(work.symbol, accent)
        }
    }

    private func symbol(_ name: String, _ style: Color) -> some View {
        Image(systemName: name).font(.system(size: 9, weight: .semibold)).foregroundStyle(style)
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
        case .pendingDelivery: (name, color) = ("doc.on.clipboard", .primary)
        case .unsavedCapture: (name, color) = ("pencil", .primary)
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
    let hint: String?
    let isEnabled: Bool
    let fontSize: CGFloat
    let minimumWidth: CGFloat
    let minimumTitles: [String]
    let accent: Color
    let press: () -> (() -> Void)?
    let drag: ToolbarDragActions
    func makeNSView(context: Context) -> PrimaryButton {
        let view = PrimaryButton()
        view.bezelStyle = .rounded
        view.controlSize = .large
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }
    func updateNSView(_ view: PrimaryButton, context: Context) {
        view.title = title
        view.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        view.bezelColor = NSColor(accent)
        view.isEnabled = isEnabled
        view.toolTip = hint
        // The hint (a recording's elapsed time, a count, the key) is VoiceOver's help too (#134 T4).
        view.setAccessibilityHelp(hint)
        view.minimumWidth = max(minimumWidth, minimumTitles.map { PrimaryButton.width(of: $0, like: view) }.max() ?? 0)
        view.setAccessibilityLabel(title)
        view.setAccessibilityIdentifier("toolbar.primary")
        view.press = press; view.drag = drag
        view.invalidateIntrinsicContentSize()
    }
    final class PrimaryButton: NSButton {
        var press: (() -> (() -> Void)?)?
        var drag = ToolbarDragActions()
        /// The widest label any tool would show sets the floor, so choosing another tool
        /// never moves More or the accessory beside it.
        var minimumWidth: CGFloat = 0
        override init(frame: NSRect) { super.init(frame: frame); target = self; action = #selector(runAction) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func runAction() { press?()?() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        /// Tab from the launcher reaches the action.
        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize {
            var size = super.intrinsicContentSize
            size.width = max(size.width, minimumWidth)
            return size
        }
        /// The exact width this button would have with another title, cached
        /// per font size because the style never changes.
        nonisolated(unsafe) private static var widths: [String: CGFloat] = [:]
        static func width(of title: String, like button: NSButton) -> CGFloat {
            let key = "\(button.font?.pointSize ?? 0)|\(button.controlSize.rawValue)|\(title)"
            if let cached = widths[key] { return cached }
            let probe = NSButton()
            probe.bezelStyle = button.bezelStyle; probe.controlSize = button.controlSize
            probe.font = button.font; probe.title = title
            let width = probe.intrinsicContentSize.width
            widths[key] = width
            return width
        }
        /// The operation is latched as the button goes down; the click acts on it only if it
        /// still holds when the button comes up. The second click of a double-click does
        /// nothing, so a double-click on Stop never also starts, and one that began on the
        /// compact rest never reaches work.
        override func mouseDown(with event: NSEvent) {
            guard isEnabled, event.clickCount < 2 else { return }
            let commit = press?()
            trackToolbarDrag(view: self, event: event, actions: drag, click: { commit?() })
        }
        override func performClick(_ sender: Any?) { if isEnabled { press?()?() } }
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
        view.toolTip = (status ? state.launcherDescription + ". " + state.status.description : state.launcherDescription)
            + ". Click to choose a tool; drag to move."
        view.escape = escape; view.drag = drag
        view.open = { [weak view] in if let view { open(view) } }
        view.options = { [weak view] in if let view { options(view) } }
        focus(view)
    }
}

final class LauncherButton: NSButton {
    var open: (() -> Void)?
    var options: (() -> Void)?
    var escape: (() -> Void)?
    var drag = ToolbarDragActions()
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
        trackToolbarDrag(view: self, event: event, actions: drag, click: { [weak self] in self?.open?() })
    }
    override func rightMouseDown(with event: NSEvent) { options?() }
    override func performClick(_ sender: Any?) { open?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { escape?() }
        else if [36, 49, 76, 125].contains(event.keyCode) { open?() }
        else { super.keyDown(with: event) }
    }
}

/// More: the tool's options, the work running elsewhere, and the toolbar's own items.
private struct ToolbarMore: NSViewRepresentable {
    let size: CGFloat
    let open: (NSView) -> Void
    let escape: () -> Void
    func makeNSView(context: Context) -> MoreButton {
        let view = MoreButton()
        view.isBordered = false
        view.imagePosition = .imageOnly
        return view
    }
    func updateNSView(_ view: MoreButton, context: Context) {
        view.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
        view.contentTintColor = .labelColor
        view.setAccessibilityLabel("More")
        view.setAccessibilityHelp("Options for this tool, other work and the toolbar")
        view.setAccessibilityIdentifier("toolbar.more")
        view.toolTip = "More"
        view.escape = escape
        view.open = { [weak view] in if let view { open(view) } }
    }
}

final class MoreButton: NSButton {
    var open: (() -> Void)?
    var escape: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self; action = #selector(openMenu)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func openMenu() { open?() }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { open?() }
    override func performClick(_ sender: Any?) { open?() }
    override func keyDown(with event: NSEvent) {
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
    let opensList: Bool
    let description: String?
    let fontSize: CGFloat
    let makeMenu: () -> NSMenu
    let openPanel: ((NSView) -> Void)?
    let began: (NSMenu) -> Bool
    let ended: () -> Void
    let escape: () -> Void
    func makeNSView(context: Context) -> AccessoryButton { AccessoryButton() }
    func updateNSView(_ view: AccessoryButton, context: Context) {
        view.title = opensList ? title + " ⌄" : title; view.isBordered = false; view.font = .systemFont(ofSize: fontSize)
        view.setAccessibilityLabel(description ?? title); view.setAccessibilityIdentifier("toolbar.accessory")
        view.toolTip = description
        view.escape = escape
        view.open = { [weak view] in
            guard let view else { return }
            if let openPanel { openPanel(view); return }
            let menu = makeMenu(); guard began(menu) else { return }
            defer { ended() }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 4), in: view)
        }
    }
    final class AccessoryButton: NSButton {
        var open: (() -> Void)?
        var escape: (() -> Void)?
        override init(frame: NSRect) { super.init(frame: frame); target = self; action = #selector(openMenu) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        @objc private func openMenu() { open?() }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { escape?() }
            else if [36, 49, 76, 125].contains(event.keyCode) { open?() }
            else { super.keyDown(with: event) }
        }
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
