import SwiftUI

/// The desktop pages' shared type and spacing (#134): one 22 pt semibold title per page, 13 pt
/// semibold section titles and 13 pt body text, inside 24 pt of padding with 16 pt between
/// sections. Text styles, so larger text grows them; native controls keep their own sizes.
extension Workbench {
    static let pageTitle = Font.title.weight(.semibold)
    static let sectionTitle = Font.body.weight(.semibold)
    static let bodyText = Font.body
    static let pagePadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 16
    /// One card shape for every page (docs/desktop.md § Page kit): 12 pt corners, 16 pt inside,
    /// on the control surface with a hairline, so a card reads the same on Home and on a tool page.
    static let tileRadius: CGFloat = 12
    static let tilePadding: CGFloat = 16
    /// Orange asks for attention and nothing else; red stays for recording and removal.
    static let attention = Color.orange
}

/// A card on a page: a symbol in the accent, a section title, an optional trailing status or
/// door, then its content. The whole card is never a button; its actions sit inside it, beside
/// the thing they act on.
struct WorkbenchTile<Accessory: View, Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String, symbol: String, @ViewBuilder accessory: @escaping () -> Accessory, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.symbol = symbol; self.accessory = accessory; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Workbench.accent)
                    .frame(width: 18).accessibilityHidden(true)
                Text(title).font(Workbench.sectionTitle).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                accessory()
            }
            content()
        }
        .workbenchCard()
        // One named group per card for VoiceOver, and one stop for keyboard focus moving between cards.
        .accessibilityElement(children: .contain).accessibilityLabel(title)
        .focusSection()
    }
}

extension WorkbenchTile where Accessory == EmptyView {
    init(_ title: String, symbol: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, symbol: symbol, accessory: { EmptyView() }, content: content)
    }
}

extension View {
    /// A card without a title row: the tile's padding, surface and hairline, full width. Every
    /// surface container on a page carries the hairline, because the window and control
    /// backgrounds are the same colour on macOS 26. `outlined` marks the row a door revealed.
    func workbenchCard(outlined: Bool = false) -> some View {
        padding(Workbench.tilePadding).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Workbench.surface, in: RoundedRectangle(cornerRadius: Workbench.tileRadius))
            .overlay(RoundedRectangle(cornerRadius: Workbench.tileRadius)
                .strokeBorder(outlined ? Workbench.accent : Workbench.border, lineWidth: outlined ? 2 : 1))
    }
}

/// A sentence about a problem or a state: primary words that wrap, with the tone on the symbol
/// only, so orange never carries text (2.2:1 on a light card). Problems and cautions use the
/// triangle; the one-line `WorkbenchStatusBadge` keeps the circle.
struct WorkbenchNote: View {
    let text: String
    var tone: WorkbenchTone = .attention
    var symbol: String? = nil
    var font: Font = .callout
    var selectable = true
    init(_ text: String, tone: WorkbenchTone = .attention, symbol: String? = nil, font: Font = .callout, selectable: Bool = true) {
        self.text = text; self.tone = tone; self.symbol = symbol; self.font = font; self.selectable = selectable
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol ?? defaultSymbol).foregroundStyle(color).accessibilityHidden(true)
            if selectable {
                Text(text).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } else {
                Text(text).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            }
        }.font(font).accessibilityElement(children: .combine)
    }
    private var defaultSymbol: String {
        switch tone { case .attention: return "exclamationmark.triangle.fill"; case .done: return "checkmark.circle.fill"; case .neutral: return "info.circle" }
    }
    private var color: Color {
        switch tone { case .done: return Workbench.accent; case .attention: return Workbench.attention; case .neutral: return .secondary }
    }
}

/// What a status says about itself: done, needs the person, or plain information.
enum WorkbenchTone: Equatable { case done, attention, neutral }

/// A short status beside the thing it describes: a symbol and a few words, coloured by tone.
struct WorkbenchStatusBadge: View {
    let text: String
    let tone: WorkbenchTone
    var symbol: String? = nil
    var body: some View {
        // Orange words fail contrast on a light card, so attention colours only its symbol.
        Label {
            Text(text).lineLimit(1).foregroundStyle(tone == .attention ? Color.primary : color)
        } icon: {
            Image(systemName: symbol ?? defaultSymbol).foregroundStyle(color).accessibilityHidden(true)
        }
        .font(.caption.weight(.medium)).labelStyle(.titleAndIcon)
        .fixedSize()
    }
    private var defaultSymbol: String {
        switch tone { case .done: return "checkmark.circle.fill"; case .attention: return "exclamationmark.circle.fill"; case .neutral: return "circle.dashed" }
    }
    private var color: Color {
        switch tone { case .done: return Workbench.accent; case .attention: return Workbench.attention; case .neutral: return .secondary }
    }
}

/// A card or page with nothing in it yet: what will appear, why it is useful, and the one next
/// step. Left-aligned inside a card; a whole empty page centres it.
struct WorkbenchEmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(Workbench.accent)
                .frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { actions() }.padding(.top, 4)
            }
        }.accessibilityElement(children: .contain)
    }
}

/// A page's title, read from the page record so it is the name the sidebar, the menus and the
/// switchers use, with an optional one-line summary and the page's own trailing controls.
struct WorkbenchPageHeader<Trailing: View>: View {
    let route: String
    var summary: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ route: String, summary: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.route = route; self.summary = summary; self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(WorkbenchHome.name(of: route)).font(Workbench.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                if let summary {
                    Text(summary).font(Workbench.bodyText).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

extension WorkbenchPageHeader where Trailing == EmptyView {
    init(_ route: String, summary: String? = nil) { self.init(route, summary: summary) { EmptyView() } }
}

/// A section title inside a page: 13 pt semibold, a heading for VoiceOver.
struct WorkbenchSectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View { Text(title).font(Workbench.sectionTitle).accessibilityAddTraits(.isHeader) }
}

private struct PageSectionFramesKey: EnvironmentKey {
    static let defaultValue: ((String, CGRect) -> Void)? = nil
}

extension EnvironmentValues {
    /// Checks read where a page laid out a named section and its visible scroll area, in window
    /// coordinates, from here; nil in the app. Dictate reports "dictate.options" and
    /// "dictate.visible", so the surface gallery can see Settings' Dictate options… land (#134).
    var pageSectionFrames: ((String, CGRect) -> Void)? {
        get { self[PageSectionFramesKey.self] }
        set { self[PageSectionFramesKey.self] = newValue }
    }
}
