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
