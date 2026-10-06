import AppKit
import Combine
import SwiftUI
import ToolbarCore
import ToolbarKit

extension DemoResource {
    /// A saved prompt's name in the picker. The library requires one; the
    /// prompt's opening words stand in for a record saved without it.
    var pickerTitle: String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(content.prefix(80)) : name
    }
}

/// The prompts one picker shows, frozen when it opens (#159). Library
/// stays the store. Favourites come first, then every other prompt, each in
/// one place; search and one optional Product or Persona filter narrow that
/// same list, and nothing opens a submenu.
struct PromptPickerList: Equatable {
    enum Filter: Hashable {
        case all, product(String), persona(String)
        var title: String {
            switch self {
            case .all: return "All prompts"
            case .product(let name), .persona(let name): return name
            }
        }
    }
    let prompts: [DemoResource]
    var query = ""
    var filter = Filter.all

    init(resources: [DemoResource]) {
        prompts = DemoResource.matching(resources.filter { $0.kind == .prompt && !$0.content.isEmpty }, query: "")
    }
    var products: [String] { tags(\.product) }
    var personas: [String] { tags(\.persona) }
    var hasFilters: Bool { !products.isEmpty || !personas.isEmpty }
    private func tags(_ key: KeyPath<DemoResource, String>) -> [String] {
        Set(prompts.map { $0[keyPath: key] }.filter { !$0.isEmpty })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    /// The library's own search, then the chosen category.
    private var shown: [DemoResource] {
        DemoResource.matching(prompts, query: query).filter { prompt in
            switch filter {
            case .all: return true
            case .product(let name): return prompt.product == name
            case .persona(let name): return prompt.persona == name
            }
        }
    }
    var favourites: [DemoResource] { shown.filter(\.favorite) }
    var others: [DemoResource] { shown.filter { !$0.favorite } }
    /// Every shown prompt once: favourites, then the rest.
    var rows: [DemoResource] {
        let shown = self.shown
        return shown.filter(\.favorite) + shown.filter { !$0.favorite }
    }
    /// The whole name for VoiceOver and the tooltip, however the row truncates it.
    static func accessibilityLabel(_ prompt: DemoResource) -> String {
        [prompt.pickerTitle, prompt.group, prompt.favorite ? "favourite" : ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// What choosing a prompt does, decided when the picker opens for its frozen field.
enum PromptPickerMode: Equatable {
    /// Accessibility is approved and the field can be read: type the prompt into it.
    case insert(into: String)
    /// Copy prompt. `noField` says a readable field was missing; otherwise
    /// automatic insertion waits for approval, which is not repeated as a nag.
    case copy(noField: Bool)

    static func resolve(trusted: Bool, destination: TextDelivery.Target?) -> Self {
        guard trusted else { return .copy(noField: false) }
        guard let destination, destination.element != nil, destination.value != nil, destination.selection != nil else {
            return .copy(noField: true)
        }
        return .insert(into: destination.app.localizedName ?? "the selected app")
    }
    var inserts: Bool { if case .insert = self { return true }; return false }
    var actionTitle: String {
        switch self {
        case .insert(let app): return "Insert into \(app)"
        case .copy: return "Copy prompt"
        }
    }
    var accessibilityHint: String {
        switch self {
        case .insert(let app): return "Types the prompt into \(app). It is never submitted."
        case .copy: return "Copies the prompt. Paste it with Command-V."
        }
    }
    /// Missing approval reads as plain copying; only a missing field is explained.
    var note: String? {
        self == .copy(noField: true) ? "No readable text field was selected, so choosing a prompt copies it." : nil
    }
}

/// One prompt delivery, kept for the picker's status line. It names its prompt
/// and destination, so it can never read as describing the next field.
struct PromptAttempt: Equatable {
    var prompt: String
    var destination: String
    var result: String
    var finished = true
    /// One line: a short result whole, otherwise its first sentence.
    var summary: String {
        guard result.count > 44, let end = result.range(of: ". ") else { return result }
        return String(result[..<end.lowerBound]) + "."
    }
    var hasDetails: Bool { summary != result }
    var line: String { finished ? "Last prompt · \(destination) · \(summary)" : "Inserting “\(prompt)” into \(destination)…" }
    var details: String { "“\(prompt)” · \(destination): \(result)" }
}

/// Where the picker sits: 420 points wide at most, never wider than its
/// display less 16 points each side, above its anchor when it fits there.
enum PromptPickerLayout {
    static let maxWidth: CGFloat = 420
    static let edgeMargin: CGFloat = 16
    static let gap: CGFloat = 6

    static func width(in visible: NSRect) -> CGFloat {
        max(0, min(maxWidth, visible.width - 2 * edgeMargin))
    }
    static func width(in visible: NSRect, beside toolbar: NSRect, anchor: ToolbarAnchor) -> CGFloat {
        guard anchor.isVertical else { return width(in: visible) }
        return ToolbarGeometry.sidePanelFrame(size: NSSize(width: width(in: visible), height: 1), toolbar: toolbar,
                                               anchor: anchor, visible: visible, inset: edgeMargin, gap: gap).width
    }
    /// The height available above and below the anchor, inside the margins.
    static func room(anchor: NSRect, visible: NSRect) -> (above: CGFloat, below: CGFloat) {
        (max(0, visible.maxY - edgeMargin - (anchor.maxY + gap)), max(0, anchor.minY - gap - (visible.minY + edgeMargin)))
    }
    /// Above when the content fits there, below when only that fits, else the roomier side.
    static func opensAbove(content height: CGFloat, anchor: NSRect, visible: NSRect) -> Bool {
        let room = room(anchor: anchor, visible: visible)
        return height <= room.above || room.above >= room.below
    }
    static func frame(content: NSSize, anchor: NSRect, visible: NSRect, above: Bool, toolbarAnchor: ToolbarAnchor = .bottom) -> NSRect {
        if toolbarAnchor.isVertical {
            return ToolbarGeometry.sidePanelFrame(size: content, toolbar: anchor, anchor: toolbarAnchor, visible: visible, inset: edgeMargin, gap: gap)
        }
        let width = min(content.width, width(in: visible))
        let room = room(anchor: anchor, visible: visible)
        let height = min(content.height, above ? room.above : room.below)
        let x = min(max(anchor.minX, visible.minX + edgeMargin), visible.maxX - edgeMargin - width)
        let y = above ? anchor.maxY + gap : anchor.minY - gap - height
        return NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height.rounded())
    }
}

/// Choosing runs after the picker has gone, as a menu item's action runs
/// after tracking. Insert types into the frozen field through
/// PromptInsertion; Copy prompt copies once and posts nothing.
struct PromptPickerAction {
    var mode: PromptPickerMode
    var insert: (_ text: String, _ title: String) -> Void
    var copy: (DemoResource) -> Void
    func perform(_ prompt: DemoResource) {
        if mode.inserts { insert(prompt.content, prompt.pickerTitle) } else { copy(prompt) }
    }
}

/// The picker's state: the frozen list, the keyboard highlight and the last
/// delivery. The view reads only this, so fixtures and checks can drive it.
@MainActor
final class PromptPickerModel: ObservableObject {
    @Published var list: PromptPickerList {
        didSet { if oldValue.query != list.query || oldValue.filter != list.filter { highlightFirst() } }
    }
    @Published private(set) var highlighted: UUID?
    /// Set by keyboard moves only, so hovering never scrolls the list.
    @Published private(set) var scrollTarget: UUID?
    @Published var showsDetails = false
    @Published private(set) var running = false
    @Published private(set) var attempt: PromptAttempt?
    @Published var listHeight: CGFloat
    @Published var chromeHeight: CGFloat = 120
    let mode: PromptPickerMode
    let width: CGFloat
    /// The height the picker may use on its side of the anchor.
    var available: CGFloat
    let textScale: CGFloat
    private let perform: (DemoResource) -> Void
    private let dismiss: () -> Void
    private let stopInserting: () -> Void
    private let showLibrary: () -> Void
    private var observation: AnyCancellable?

    init(list: PromptPickerList, mode: PromptPickerMode, width: CGFloat, available: CGFloat, textScale: CGFloat = 1,
         perform: @escaping (DemoResource) -> Void, dismiss: @escaping () -> Void,
         stopInserting: @escaping () -> Void = {}, openLibrary: @escaping () -> Void = {}) {
        self.list = list; self.mode = mode; self.width = width; self.available = available; self.textScale = textScale
        self.perform = perform; self.dismiss = dismiss; self.stopInserting = stopInserting; showLibrary = openLibrary
        // An estimate until the rows are measured, so the picker opens near its size.
        listHeight = min(CGFloat(list.rows.count) * 34 + 30, 360) * textScale
        highlighted = list.rows.first?.id
    }

    /// Mirror the delivery owner, so a new attempt or Stop shows while open.
    func follow(_ delivery: PromptInsertion) {
        running = delivery.running; attempt = delivery.lastAttempt
        observation = delivery.objectWillChange.receive(on: RunLoop.main).sink { [weak self, weak delivery] _ in
            guard let self, let delivery else { return }
            running = delivery.running; attempt = delivery.lastAttempt
        }
    }
    /// For the surface gallery's fixtures.
    func show(running: Bool, attempt: PromptAttempt?) { self.running = running; self.attempt = attempt }

    var maxListHeight: CGFloat { max(88 * textScale, min(360 * textScale, available - chromeHeight)) }
    var highlightedPrompt: DemoResource? { list.rows.first { $0.id == highlighted } }

    func move(_ delta: Int) {
        let rows = list.rows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == highlighted }
        let next = current.map { min(rows.count - 1, max(0, $0 + delta)) } ?? (delta > 0 ? 0 : rows.count - 1)
        highlighted = rows[next].id; scrollTarget = rows[next].id
    }
    func hover(_ id: UUID) { highlighted = id }
    /// The rows' measured height; nothing measured yet keeps the estimate.
    func measureList(_ height: CGFloat) {
        guard height > 1, abs(height - listHeight) > 0.5 else { return }
        listHeight = height
    }
    func chooseHighlighted() { if let prompt = highlightedPrompt { choose(prompt) } }
    /// A prompt is chosen once; nothing new starts while one is being inserted.
    func choose(_ prompt: DemoResource) {
        guard !running, list.prompts.contains(where: { $0.id == prompt.id }) else { return }
        perform(prompt)
    }
    func cancel() { dismiss() }
    func stop() { stopInserting() }
    func openLibrary() { showLibrary() }
    func showAll() { list.query = ""; list.filter = .all }
    private func highlightFirst() { highlighted = list.rows.first?.id; scrollTarget = highlighted }
}

/// One compact list: search and an optional category, favourites then the
/// rest, and one line about the last delivery with Details for its reason.
/// The width is fixed; long names wrap to two lines or truncate, never widen it.
struct PromptPickerView: View {
    @ObservedObject var model: PromptPickerModel
    var searchField: (NSSearchField) -> Void = { _ in }
    var resized: (CGSize) -> Void = { _ in }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .body) private var systemScale: CGFloat = 1
    private var scale: CGFloat { model.textScale * systemScale }

    var body: some View {
        let favourites = model.list.favourites, others = model.list.others
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.list.prompts.isEmpty { emptyLibrary }
            else if favourites.isEmpty && others.isEmpty { noMatch }
            else { prompts(favourites, others) }
            if hasFooter {
                Divider()
                footer
            }
        }
        .frame(width: model.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        // The host sizes its panel from this report. A preference written from a
        // background GeometryReader never reaches onPreferenceChange once the view
        // holds conditional content (#152), so the panel would keep its opening size.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            // Everything but the list, so a long list shrinks to leave the footer on screen.
            let chrome = size.height - (model.list.rows.isEmpty ? 0 : min(model.listHeight, model.maxListHeight))
            if abs(chrome - model.chromeHeight) > 0.5 { model.chromeHeight = chrome }
            resized(size)
        }
        .background {
            if reduceTransparency { RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)) }
            else { RoundedRectangle(cornerRadius: 12).fill(.regularMaterial) }
        }
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12)) }
        .tint(Workbench.accent)
        .environment(\.controlActiveState, .active)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved Prompts")
        .workbenchTheme()
    }

    private var header: some View {
        HStack(spacing: 8 * scale) {
            PromptSearchField(text: $model.list.query, fontSize: 13 * scale, move: model.move,
                              submit: model.chooseHighlighted, cancel: model.cancel, made: searchField)
                .frame(maxWidth: .infinity)
            if model.list.hasFilters {
                Picker("Category", selection: $model.list.filter) {
                    Text("All prompts").tag(PromptPickerList.Filter.all)
                    if !model.list.products.isEmpty {
                        Section("Product") {
                            ForEach(model.list.products, id: \.self) { Text($0).tag(PromptPickerList.Filter.product($0)) }
                        }
                    }
                    if !model.list.personas.isEmpty {
                        Section("Persona") {
                            ForEach(model.list.personas, id: \.self) { Text($0).tag(PromptPickerList.Filter.persona($0)) }
                        }
                    }
                }
                .pickerStyle(.menu).labelsHidden().font(.system(size: 12 * scale))
                .frame(maxWidth: model.width * 0.38)
                .help("Show one product's or persona's prompts")
            }
        }.padding(10 * scale)
    }

    private func prompts(_ favourites: [DemoResource], _ others: [DemoResource]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2 * scale) {
                    if !favourites.isEmpty {
                        heading("Favourites")
                        ForEach(favourites) { row($0) }
                        if !others.isEmpty { heading("Other prompts") }
                    }
                    ForEach(others) { row($0) }
                }
                .padding(6 * scale)
                // The rows' natural height, measured inside the scroll view.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.measureList($0) }
            }
            .frame(height: min(model.listHeight, model.maxListHeight))
            .onChange(of: model.scrollTarget) { _, target in if let target { proxy.scrollTo(target) } }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 10 * scale, weight: .semibold)).tracking(1.2)
            .foregroundStyle(.secondary).padding(.horizontal, 8 * scale).padding(.top, 6 * scale).padding(.bottom, 2 * scale)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ prompt: DemoResource) -> some View {
        let highlighted = model.highlighted == prompt.id
        return Button { model.choose(prompt) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
                Image(systemName: prompt.favorite ? "star.fill" : "text.quote")
                    .font(.system(size: 10 * scale))
                    .foregroundStyle(prompt.favorite ? Workbench.accent : Color.secondary)
                    .frame(width: 14 * scale)
                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text(prompt.pickerTitle).font(.system(size: 13 * scale)).lineLimit(2).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    if !prompt.group.isEmpty {
                        Text(prompt.group).font(.system(size: 11 * scale)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5 * scale).padding(.horizontal, 8 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Workbench.accent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.running)
        .id(prompt.id)
        .onHover { if $0 { model.hover(prompt.id) } }
        .help(prompt.pickerTitle)
        .accessibilityLabel(PromptPickerList.accessibilityLabel(prompt))
        .accessibilityHint(model.mode.accessibilityHint)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            Text("No saved prompts yet.").font(.system(size: 13 * scale, weight: .medium))
            Text("Save a prompt in Library, then choose it here.")
                .font(.system(size: 11 * scale)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open Library…") { model.openLibrary() }.font(.system(size: 12 * scale))
        }.padding(12 * scale).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var noMatch: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            Text(model.list.query.isEmpty ? "No prompts in \(model.list.filter.title)." : "No prompt matches “\(model.list.query)”.")
                .font(.system(size: 12 * scale)).lineLimit(2).truncationMode(.middle)
            Button("Show all prompts") { model.showAll() }.font(.system(size: 12 * scale))
        }.padding(12 * scale).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// An empty library or a search with no match has nothing to act on.
    private var hasFooter: Bool {
        model.running || model.attempt != nil || !model.list.rows.isEmpty
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            if let note = model.mode.note, !model.list.rows.isEmpty {
                Text(note).font(.system(size: 11 * scale)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let attempt = model.attempt { status(attempt) }
            if model.running || !model.list.rows.isEmpty { actions }
        }.padding(10 * scale)
    }

    private var actions: some View {
        HStack(spacing: 8 * scale) {
            Spacer(minLength: 0)
            if model.running {
                Button("Stop inserting") { model.stop() }.font(.system(size: 12 * scale))
            } else {
                Button { model.chooseHighlighted() } label: {
                    HStack(spacing: 6 * scale) {
                        Text(model.mode.actionTitle).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "return").font(.system(size: 10 * scale)).accessibilityHidden(true)
                    }.font(.system(size: 12 * scale))
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.highlightedPrompt == nil)
                .accessibilityLabel(model.mode.actionTitle)
                .help(model.mode.actionTitle + " · Return")
            }
        }
    }

    /// One line tied to its own attempt; the full reason waits behind Details.
    private func status(_ attempt: PromptAttempt) -> some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            HStack(spacing: 6 * scale) {
                Image(systemName: attempt.finished ? "clock.arrow.circlepath" : "text.cursor").foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(attempt.line).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                    .accessibilityLabel(attempt.finished ? "Last prompt, \(attempt.prompt), \(attempt.destination): \(attempt.summary)" : attempt.line)
                Spacer(minLength: 4 * scale)
                if attempt.finished && attempt.hasDetails {
                    Button(model.showsDetails ? "Hide details" : "Details") { model.showsDetails.toggle() }
                        .buttonStyle(.link).accessibilityLabel(model.showsDetails ? "Hide details of the last prompt" : "Details of the last prompt")
                }
            }
            if attempt.finished && model.showsDetails {
                Text(attempt.details).lineLimit(6).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11 * scale))
        .help(attempt.finished ? attempt.details : attempt.line)
    }
}

/// Typing searches; ↑ ↓ move through the list, Return chooses and Escape closes.
private struct PromptSearchField: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var move: (Int) -> Void
    var submit: () -> Void
    var cancel: () -> Void
    var made: (NSSearchField) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = FocusingSearchField()
        field.placeholderString = "Search prompts"
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search saved prompts")
        made(field)
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        field.font = .systemFont(ofSize: fontSize)
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: PromptSearchField
        init(_ parent: PromptSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }
}

/// Takes keyboard focus as soon as the picker shows it, so typing searches at once.
private final class FocusingSearchField: NSSearchField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window is PromptPickerPanel { window?.makeFirstResponder(self) }
    }
}

private final class PromptPickerPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

/// The one transient Saved Prompts picker. It takes keyboard focus without
/// activating Workbench, so the field it froze stays in front, and it leaves
/// on Escape, a click outside or a choice. The toolbar keeps its row up while
/// it shows, as it does for a native menu.
@MainActor
final class PromptPickerController: NSObject, NSWindowDelegate {
    static let shared = PromptPickerController()

    @MainActor struct Context {
        /// The library's resources when the picker was asked for; it freezes its prompts from these.
        var resources: [DemoResource]
        var delivery: PromptInsertion
        var receipts: ClipboardReceiptModel
        /// The field in front when the picker was asked for.
        var destination: TextDelivery.Target?
        var trusted: Bool
        var controls: CaptureHUDControls?
        var openLibrary: () -> Void
        var copyPrompt: ((DemoResource) -> Void)? = nil

        /// Library supplies no external field. Its existing copy owner keeps
        /// exact text and shows success or failure beside the saved resource.
        static func library(_ library: DemoLibraryModel, delivery: PromptInsertion,
                            receipts: ClipboardReceiptModel, openLibrary: @escaping () -> Void) -> Self {
            Self(resources: library.resources, delivery: delivery, receipts: receipts, destination: nil,
                 trusted: false, controls: nil, openLibrary: openLibrary, copyPrompt: { library.copy($0) })
        }
        var action: PromptPickerAction {
            PromptPickerAction(mode: PromptPickerMode.resolve(trusted: trusted, destination: destination),
                insert: { text, title in delivery.insert(text, title: title, into: destination) },
                copy: { prompt in
                    if let copyPrompt { copyPrompt(prompt) }
                    else { delivery.copy(prompt.content, title: prompt.pickerTitle, receipts: receipts) }
                })
        }
    }

    private var panel: PromptPickerPanel?
    private var model: PromptPickerModel?
    private var context: Context?
    private var monitors: [Any] = []
    private var observations = Set<AnyCancellable>()
    private weak var anchorView: NSView?
    private var anchor = NSRect.zero
    private var visible = NSRect.zero
    private var above = true
    private var toolbarAnchor: ToolbarAnchor = .bottom
    private weak var searchField: NSSearchField?

    var isShown: Bool { model != nil }

    /// The surface gallery opens the real panel invisibly to check its size: no keyboard
    /// focus, no pointer and no click monitors, so a local run never takes anyone's input.
    var offscreenForChecks = false
    /// What the gallery's host check reads: the open panel, its model and placement, and
    /// the size its content last reported.
    var shownPanel: NSPanel? { panel }
    var shownModel: PromptPickerModel? { model }
    var opensAbove: Bool { above }
    private(set) var reportedSize: CGSize?

    /// Anchored to the button that asked for it; a second click closes it.
    func show(from view: NSView, context: Context) {
        guard let window = view.window else { return }
        let anchor = context.controls?.rowAnchor.isVertical == true ? window.frame : window.convertToScreen(view.convert(view.bounds, to: nil))
        show(anchor: anchor, view: view, context: context)
    }
    /// Anchored to a toolbar window, after its glyph menu has closed.
    func show(anchor: NSRect, context: Context) { show(anchor: anchor, view: nil, context: context) }

    private func show(anchor: NSRect, view: NSView?, context: Context) {
        if isShown { close(); return }
        // The same admission and hold a native menu takes from the active toolbar.
        if let controls = context.controls {
            guard controls.toolbar.isActive else { return }
            controls.toolbar.send(.holdBegan(.menu))
        }
        let center = NSPoint(x: anchor.midX, y: anchor.midY)
        guard let visible = (NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main)?.visibleFrame else {
            context.controls?.endMenu(); return
        }
        self.anchor = anchor; self.visible = visible; anchorView = view; self.context = context
        toolbarAnchor = context.controls?.rowAnchor ?? .bottom
        let action = context.action, mode = action.mode
        let room = PromptPickerLayout.room(anchor: anchor, visible: visible)
        let model = PromptPickerModel(list: PromptPickerList(resources: context.resources), mode: mode,
            width: PromptPickerLayout.width(in: visible, beside: anchor, anchor: toolbarAnchor),
            available: toolbarAnchor.isVertical ? visible.height - 2 * PromptPickerLayout.edgeMargin : max(room.above, room.below),
            perform: { [weak self] prompt in self?.choose(prompt, action: action) },
            dismiss: { [weak self] in self?.close() },
            stopInserting: { context.delivery.cancel() },
            openLibrary: { [weak self] in self?.close(then: context.openLibrary) })
        model.follow(context.delivery)
        self.model = model

        let panel = PromptPickerPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: model.width, height: 200)),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Saved Prompts"
        panel.isFloatingPanel = true
        // Above the floating toolbar, which sits above the drawing canvas.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.dismiss = { [weak self] in self?.close() }
        let hosting = NSHostingView(rootView: PromptPickerView(model: model,
            searchField: { [weak self] in self?.searchField = $0 },
            resized: { [weak self] in self?.resize($0) }))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel

        // The panel's own hosting view has no sizing options, so it reports no fitting size;
        // measure the same content once, unseen, and open at that size. After that the view's
        // own reports size the panel.
        func natural() -> NSSize { NSHostingView(rootView: PromptPickerView(model: model)).fittingSize }
        above = PromptPickerLayout.opensAbove(content: natural().height, anchor: anchor, visible: visible)
        model.available = toolbarAnchor.isVertical ? visible.height - 2 * PromptPickerLayout.edgeMargin : above ? room.above : room.below
        panel.setFrame(PromptPickerLayout.frame(content: natural(), anchor: anchor, visible: visible, above: above, toolbarAnchor: toolbarAnchor), display: false)
        if offscreenForChecks {
            panel.alphaValue = 0; panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
            return
        }
        panel.makeKeyAndOrderFront(nil)
        if let searchField { panel.makeFirstResponder(searchField) }

        monitors = [
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.consumes(event) ?? false } ? nil : event
            },
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        ].compactMap { $0 }
        // Leaving the tools surface (dictation, a capture, Hide toolbar) takes the picker too.
        context.controls?.toolbar.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self, let controls = self.context?.controls, !controls.toolbar.isActive else { return }
            close()
        }.store(in: &observations)
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    /// A click outside closes the picker. On the button that opened it, the
    /// click only closes it, so that button toggles.
    private func consumes(_ event: NSEvent) -> Bool {
        guard let panel, event.window !== panel else { return false }
        let onAnchor = anchorView.map { view in
            event.window === view.window && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        } ?? false
        close()
        return onAnchor
    }

    private func resize(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        reportedSize = size
        let frame = PromptPickerLayout.frame(content: size, anchor: anchor, visible: visible, above: above, toolbarAnchor: toolbarAnchor)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// The picker goes first; the choice then acts on the field frozen at open.
    private func choose(_ prompt: DemoResource, action: PromptPickerAction) {
        guard let context else { return }
        close(then: {
            context.controls?.endKeyboardInteraction()
            // Keyboard focus on the toolbar brought Workbench forward: give the field
            // back, as the menu-bar panel's rows do. Insertion then waits until that
            // field is in front again (PromptFieldReturn), whichever way the picker opened.
            if NSApp.isActive, let app = context.destination?.app, app.processIdentifier != getpid() {
                app.activate(options: [])
            }
            action.perform(prompt)
        })
    }

    func close(then action: (() -> Void)? = nil) {
        guard let panel, let context else { return }
        self.panel = nil; self.context = nil; model = nil; reportedSize = nil
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        observations.removeAll()
        panel.delegate = nil
        panel.orderOut(nil)
        // A row's own action can close the picker, so its view outlives that action.
        Task { @MainActor in panel.contentView = nil }
        context.controls?.endMenu()
        if let action { Task { @MainActor in action() }; return }
        // Escape or a click outside: if Workbench had come forward for the
        // toolbar's keyboard focus, return to the field that was in front.
        if NSApp.isActive {
            context.controls?.endKeyboardInteraction()
            if let app = context.destination?.app, app.processIdentifier != getpid() { app.activate(options: []) }
        }
    }
}
