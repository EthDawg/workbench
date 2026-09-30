import SwiftUI
import AppKit

/// Sidebar rows and Home's large actions use the same restrained pointer response.
struct WorkbenchNavigationStyle: ButtonStyle {
    var selected = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? Workbench.accent.opacity(scheme == .dark ? 0.19 : 0.12) : Color.clear)
            }
            .overlay(RoundedRectangle(cornerRadius: 9)
                .fill(Color.primary.opacity(isEnabled ? (configuration.isPressed ? 0.12 : hovered ? (scheme == .dark ? 0.08 : 0.045) : 0) : 0))
                .allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Workbench.accent.opacity(0.22) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { hovered = $0 }
    }
}

/// Home's sidebar geometry. Both widths share one icon column, centred in the collapsed
/// sidebar, so collapsing or expanding moves only the trailing edge.
enum SidebarMetrics {
    static let collapsedWidth: CGFloat = 68
    static let expandedWidth: CGFloat = 215
    /// The sidebar's side padding, the same in both widths.
    static let inset: CGFloat = 10
    static let iconWidth: CGFloat = 22
    /// From a row's leading edge to its icon: centres the icon in the collapsed sidebar.
    static let rowInset = (collapsedWidth - iconWidth) / 2 - inset
    /// The header's 36-point toggle sits on the same centre.
    static let toggleSize: CGFloat = 36
    static let toggleInset = (collapsedWidth - toggleSize) / 2 - inset
    /// Names that could wrap or truncate lay out at their expanded width in both states.
    static let headerNameWidth = expandedWidth - 2 * inset - toggleInset - toggleSize
    static let buildLabelWidth = expandedWidth - 2 * inset - rowInset
    static let motion = Animation.smooth(duration: 0.25)
}

extension View {
    /// A sidebar name keeps its expanded layout (its own width, or `width`) whatever the
    /// sidebar's width, so it never rewraps or truncates as the edge moves. It takes no room
    /// from the icon column, fades out before the edge reaches it, fades in once there is
    /// room, and leaves VoiceOver while hidden.
    func sidebarName(hidden: Bool, width: CGFloat? = nil) -> some View {
        modifier(SidebarName(hidden: hidden, width: width))
    }
}

private struct SidebarName: ViewModifier {
    var hidden: Bool
    var width: CGFloat?
    @ViewBuilder private func laidOut(_ content: Content) -> some View {
        if let width { content.frame(width: width, alignment: .leading) }
        else { content.fixedSize(horizontal: true, vertical: false) }
    }
    func body(content: Content) -> some View {
        laidOut(content)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .opacity(hidden ? 0 : 1)
            .animation(hidden ? .easeOut(duration: 0.1) : .easeOut(duration: 0.18).delay(0.08), value: hidden)
            .accessibilityHidden(hidden)
    }
}

/// Anchor hints at the window level so a sidebar ScrollView cannot clip their words.
/// They are read-only: the original button remains the only hit target and accessible control.
struct SidebarHintAnchor {
    var title: String
    var bounds: Anchor<CGRect>
}
struct SidebarHintAnchors: PreferenceKey {
    static var defaultValue: [String: SidebarHintAnchor] { [:] }
    static func reduce(value: inout [String: SidebarHintAnchor], nextValue: () -> [String: SidebarHintAnchor]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
struct SidebarHintTarget: ViewModifier {
    var id: String
    var title: String
    var enabled: Bool
    @Binding var hovered: String?
    func body(content: Content) -> some View {
        content
            .help(enabled ? "" : title)
            .anchorPreference(key: SidebarHintAnchors.self, value: .bounds) {
                enabled ? [id: SidebarHintAnchor(title: title, bounds: $0)] : [:]
            }
            .onHover { inside in
                if inside && enabled { hovered = id }
                else if hovered == id { hovered = nil }
            }
            .onDisappear { if hovered == id { hovered = nil } }
    }
}
/// A separate native layer keeps the hint above the window's native scroll documents.
/// Its content has no hit target and duplicates no accessibility element.
struct SidebarHintLabel: NSViewRepresentable {
    var title: String
    func makeNSView(context: Context) -> SidebarHintHostingView {
        let view = SidebarHintHostingView(rootView: SidebarHintText(title: title))
        view.wantsLayer = true
        return view
    }
    func updateNSView(_ view: SidebarHintHostingView, context: Context) { view.rootView = SidebarHintText(title: title) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SidebarHintHostingView, context: Context) -> CGSize? {
        nsView.fittingSize
    }
}
final class SidebarHintHostingView: NSHostingView<SidebarHintText> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
struct SidebarHintText: View {
    var title: String
    var body: some View {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
            .padding(.horizontal, 10).padding(.vertical, 6).fixedSize()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }
}

/// A finite sequence rather than a repeating timer. Home's shell remembers that it played,
/// so changing pages never restarts it. The accessible label is stable throughout.
enum HomeGreetingSequence {
    static let welcome = "Welcome back!"
    static let settled = "Let’s make something. ✨"
    struct Frame: Equatable { let text: String; let milliseconds: UInt64 }
    static var frames: [Frame] {
        let hello = Array(welcome), finish = Array(settled)
        return (1...hello.count).map { Frame(text: String(hello.prefix($0)), milliseconds: 45) }
            + [Frame(text: welcome, milliseconds: 650)]
            + (0..<hello.count).reversed().map { Frame(text: String(hello.prefix($0)), milliseconds: 22) }
            + (1...finish.count).map { Frame(text: String(finish.prefix($0)), milliseconds: 36) }
    }
}

struct HomeGreeting: View {
    @Binding var hasPlayed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var text = HomeGreetingSequence.settled
    var body: some View {
        // Reserve the finished line's space, including while text is being erased.
        Text(HomeGreetingSequence.settled).hidden().overlay(alignment: .leading) { Text(text) }
            .font(.system(size: 29, weight: .semibold, design: .rounded))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(HomeGreetingSequence.settled).accessibilityAddTraits(.isHeader)
            .task(id: reduceMotion) {
                guard !reduceMotion, !hasPlayed, !ProcessInfo.processInfo.arguments.contains(SurfaceGallery.passFlag) else {
                    hasPlayed = true; text = HomeGreetingSequence.settled; return
                }
                hasPlayed = true
                for frame in HomeGreetingSequence.frames {
                    guard !Task.isCancelled else { return }
                    text = frame.text
                    do { try await Task.sleep(nanoseconds: frame.milliseconds * 1_000_000) } catch { return }
                }
            }
    }
}
