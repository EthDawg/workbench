import SwiftUI
import AppKit
import ImageIO
import Carbon

/// Home's two result tiles (docs/desktop.md § Home). Each holds something the app shows nowhere
/// else in that form: your meetings on their own, with the follow-up made from the newest, and
/// your Snap & Talk decks, which otherwise live only in the folders you chose. Until you have a
/// deck, the sample deck that ships with Workbench stands in. Neither tile is a link to a tool.

// MARK: Your meetings

/// Meetings and calls in History, newest first, read from History's own records and metadata.
/// History has no meetings-only view; dictations, which are passing captures, are left out.
enum HomeMeetings {
    struct Summary: Equatable, Identifiable {
        let id: UUID
        let heading: String
        let date: Date
        let seconds: Double
        let excerpt: String
        /// The first thing the recording kept a note about, such as a source that sent no audio.
        let note: String?
    }
    static func newest(_ history: [Transcript], metadata: (UUID) -> TranscriptMetadata, limit: Int = 3) -> [Summary] {
        history.filter { [.meeting, .call].contains(metadata($0.id).purpose) }
            .sorted { $0.date > $1.date }.prefix(limit).map { item in
                let details = metadata(item.id)
                let names = [details.person, details.company].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                return Summary(id: item.id, heading: ([details.purpose.title] + names).joined(separator: " · "), date: item.date,
                               seconds: item.seconds, excerpt: String(item.text.prefix(400)).trimmingCharacters(in: .whitespacesAndNewlines),
                               note: details.captureNotes.first)
            }
    }
    /// "Under a minute", "42 min", "1 h 5 min".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "Under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
    /// Where a meeting's Review leads: History on All, showing that transcript. Nothing is
    /// selected, and Dictate's draft is never replaced.
    static func review(_ id: UUID) -> HistoryDoor { HistoryDoor(transcript: id) }
    /// The newest Hand off task made from this transcript, from History's own task inputs.
    static func followUp(for id: UUID, in jobs: [HandoffJob], inputs: (HandoffJob) -> [WorkbenchItemReference]) -> HandoffJob? {
        let reference = WorkbenchItemReference(kind: .transcript, id: id)
        return jobs.filter { inputs($0).contains(reference) }.max { $0.createdAt < $1.createdAt }
    }
    /// A follow-up's opening words as plain lines: Markdown markers and blank lines dropped, so
    /// the recap reads as sentences.
    static func recap(_ result: String, limit: Int = 400) -> String {
        result.prefix(2_000).split(whereSeparator: \.isNewline)
            .map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#*->_ ")) }
            .filter { !$0.isEmpty }.joined(separator: " · ").prefix(limit).description
    }
}

struct HomeMeetingTile: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: WorkbenchHistoryModel
    @ObservedObject var jobs: HandoffJobsModel
    var prepareFollowUp: (UUID) -> Void
    @State private var copied: UUID?
    /// A copy failure, kept with the meeting it was for.
    @State private var copyProblem: (id: UUID, message: String)?
    /// Meetings picked from History only when History or its details change, never on a level or
    /// clock redraw while something records with Home open (#150).
    @State private var recent: [HomeMeetings.Summary] = []

    var body: some View {
        WorkbenchTile("Your meetings", symbol: WorkbenchHome.symbol(of: "meeting"), accessory: {
            if !recent.isEmpty {
                Button("Open Meetings") { model.page = "meeting" }.buttonStyle(.workbenchLink).font(.callout)
                    .accessibilityIdentifier("home.meeting.open")
            }
        }) {
            // A meeting that is recording or finishing shows in Current work above, with its own
            // door and ending; this tile keeps to saved meetings.
            if let last = recent.first {
                newest(last)
                if recent.count > 1 {
                    Divider()
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(recent.dropFirst()) { earlier($0) }
                    }
                }
            } else {
                WorkbenchEmptyState(symbol: "waveform", title: "No meetings yet",
                                    detail: "Record a call or meeting and leave with every word, ready to paste. Nothing records until you choose Start recording.") {
                    Button("Open Meetings") { model.page = "meeting" }.controlSize(.small)
                        .accessibilityIdentifier("home.meeting.open")
                }
            }
        }
        .task(id: jobs.jobs.map(\.id)) { await jobs.loadTaskFiles(jobs.visibleJobs) }
        .onAppear(perform: pick)
        .onReceive(model.$history.dropFirst()) { _ in DispatchQueue.main.async(execute: pick) }
        .onReceive(library.objectWillChange) { _ in DispatchQueue.main.async(execute: pick) }
        .accessibilityIdentifier("home.meeting")
    }

    /// The newest meeting, open: its names, date and length, its first words, and what to do with
    /// it. A follow-up already made from it replaces Prepare follow-up… with the way to it.
    @ViewBuilder private func newest(_ last: HomeMeetings.Summary) -> some View {
        let followUp = HomeMeetings.followUp(for: last.id, in: jobs.visibleJobs) { jobs.files($0)?.inputs.items.map(\.reference) ?? [] }
        let recap = followUp.flatMap { jobs.files($0)?.resultText }.map { HomeMeetings.recap($0) }.flatMap { $0.isEmpty ? nil : $0 }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(last.heading).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Text(Self.stamp(last.date) + " · " + HomeMeetings.duration(last.seconds)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let note = last.note { WorkbenchNote(note, font: .caption) }
            // Once a follow-up exists, its words are the recap; until then, the meeting's own.
            if let recap {
                Text("Follow-up").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(recap).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            } else {
                Text(last.excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                if let followUp {
                    Text("Follow-up " + followUp.status.title.lowercased()).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        HStack(spacing: 8) {
            Button { copy(last.id) } label: { Label("Copy transcript", systemImage: "doc.on.doc") }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("home.meeting.copy")
            Button("Review transcript") { model.openHistory(HomeMeetings.review(last.id)) }
                .help("Opens this transcript in History, with its original wording.")
                .accessibilityIdentifier("home.meeting.review")
            if let followUp {
                Button("Open follow-up") { model.openHistory(HistoryDoor(job: followUp.id)) }
                    .help("Shows the follow-up made from this meeting in History, where Copy result copies it.")
                    .accessibilityIdentifier("home.meeting.followup.open")
            } else {
                Button("Prepare follow-up…") { prepareFollowUp(last.id) }
                    .accessibilityIdentifier("home.meeting.followup")
            }
            Spacer(minLength: 4)
            if copied == last.id {
                WorkbenchStatusBadge(text: "Copied transcript", tone: .done).transition(.opacity)
            }
        }.controlSize(.small)
        if let copyProblem, copyProblem.id == last.id {
            WorkbenchNote(copyProblem.message, font: .caption)
        }
    }

    private func pick() { recent = HomeMeetings.newest(model.history) { library.metadata(for: $0) } }

    /// An earlier meeting: one line that opens it in History.
    private func earlier(_ meeting: HomeMeetings.Summary) -> some View {
        Button { model.openHistory(HomeMeetings.review(meeting.id)) } label: {
            HStack(spacing: 10) {
                Text(meeting.heading).font(.callout).lineLimit(1)
                Spacer(minLength: 8)
                Text(Self.stamp(meeting.date) + " · " + HomeMeetings.duration(meeting.seconds)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
            }.padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(.plain).help("Show it in History")
            .accessibilityLabel(meeting.heading + ", " + Self.stamp(meeting.date))
    }

    static func stamp(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }

    /// History's complete current record, through the copy Meetings uses. A success is confirmed
    /// beside the button for four seconds; a failure stays until the next try.
    private func copy(_ id: UUID) {
        copyProblem = model.copyMeetingTranscript(id).map { (id, $0) }
        guard copyProblem == nil else { return }
        withAnimation { copied = id }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if copied == id { withAnimation { copied = nil } }
        }
    }
}

// MARK: Sample deck

/// The sample deck that ships with Workbench in Resources/Samples: a short tour of Workbench,
/// designed and rendered from scripts/samples with a real screen per slide. It was not made
/// through Snap & Talk and says nothing about how it was made. It is read-only, never copied
/// into History, and stands in only until the person has a deck of their own.
struct SampleDeck: Equatable {
    struct Slide: Equatable, Decodable {
        let file: String
        let title: String
        let narration: String
    }
    let title: String
    let subtitle: String
    let pdf: URL
    let slides: [Slide]
    let directory: URL

    func url(_ slide: Slide) -> URL { directory.appendingPathComponent(slide.file) }

    private struct Manifest: Decodable { let title: String; let subtitle: String; let pdf: String; let slides: [Slide] }

    /// Only the surface gallery sets this, to the source tree's copy.
    @MainActor static var directoryOverride: URL?
    @MainActor static var directory: URL {
        directoryOverride ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("Samples", isDirectory: true)
    }
    /// The bundled deck, or nil when this build carries none (a development build). Read once;
    /// the bundle does not change while Workbench runs.
    @MainActor static func load() -> SampleDeck? {
        if let cached = loaded, loadedFrom == directory { return cached }
        let deck = load(from: directory)
        loadedFrom = directory; loaded = .some(deck); return deck
    }
    @MainActor private static var loaded: SampleDeck??
    @MainActor private static var loadedFrom: URL?
    static func load(from directory: URL) -> SampleDeck? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data), !manifest.slides.isEmpty else { return nil }
        let deck = SampleDeck(title: manifest.title, subtitle: manifest.subtitle, pdf: directory.appendingPathComponent(manifest.pdf),
                              slides: manifest.slides, directory: directory)
        guard FileManager.default.fileExists(atPath: deck.pdf.path),
              deck.slides.allSatisfy({ FileManager.default.fileExists(atPath: deck.url($0).path) }) else { return nil }
        return deck
    }
}

// MARK: Your decks

/// A Snap & Talk session as Home shows it: its title, how many screens it holds, its first screen
/// and the newest finished deck in its outputs folder. Read from the session's own files.
struct HomeDeck: Equatable, Identifiable {
    let root: URL
    let title: String
    let screens: Int
    let updatedAt: Date
    let thumbnail: URL?
    let deck: URL?
    /// When the newest deck file was last written.
    var deckDate: Date? = nil
    var id: String { root.standardizedFileURL.path }

    /// The files an assistant leaves in outputs/ that are a deck to open and present.
    static let deckExtensions: Set<String> = ["pptx", "key", "pdf"]
    /// The newest deck file, by modification date; nil when outputs/ holds none.
    static func newestDeck(_ files: [(url: URL, modified: Date)]) -> URL? { newest(files)?.url }
    static func newest(_ files: [(url: URL, modified: Date)]) -> (url: URL, modified: Date)? {
        files.filter { deckExtensions.contains($0.url.pathExtension.lowercased()) }.max { $0.modified < $1.modified }
    }
    /// The sessions Snap & Talk remembers, newest first, skipping any whose folder is unavailable.
    /// Reads files only, off the main thread; it never opens, recovers or changes a session.
    static func read(_ roots: [URL], limit: Int = 3) -> [HomeDeck] {
        var decks: [HomeDeck] = []
        for root in roots where decks.count < limit {
            guard ReadbackAvailability.problem(at: root) == nil, let manifest = try? ReadbackStore.load(from: root) else { continue }
            let active = manifest.sections.filter { $0.deletedAt == nil }
            let thumbnail = active.first.flatMap { try? ReadbackStore.safeURL(root: root, relative: $0.screenshot) }
            let outputs = root.appendingPathComponent("outputs", isDirectory: true)
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .isPackageKey]
            let files = ((try? FileManager.default.contentsOfDirectory(at: outputs, includingPropertiesForKeys: Array(keys))) ?? [])
                .compactMap { url -> (url: URL, modified: Date)? in
                    // A Keynote deck can be a package, a folder that opens as one document.
                    guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true || values.isPackage == true else { return nil }
                    return (url, values.contentModificationDate ?? .distantPast)
                }
            let deck = newest(files)
            // A session with no screens and no deck is a started-and-left folder: not a deck yet.
            guard !active.isEmpty || deck != nil else { continue }
            decks.append(HomeDeck(root: root, title: manifest.title, screens: active.count, updatedAt: manifest.updatedAt,
                                  thumbnail: thumbnail, deck: deck?.url, deckDate: deck?.modified))
        }
        return decks
    }
}

struct HomeDecksTile: View {
    @ObservedObject var model: AppModel
    @ObservedObject var readback: ReadbackModel
    let sample: SampleDeck?
    @State private var decks: [HomeDeck] = []
    @State private var quickLook = DemoQuickLookPresenter()
    @State private var problem: String?
    /// Bumped whenever Workbench comes back to the front, which is when an assistant has just
    /// written a deck in another app: the sessions are read again then.
    @State private var returns = 0

    var body: some View {
        WorkbenchTile("Your decks", symbol: WorkbenchHome.symbol(of: "readback"), accessory: {
            if !decks.isEmpty, sample != nil {
                Button("Sample deck") { openSample() }.buttonStyle(.workbenchLink).font(.callout)
                    .help("A short tour of Workbench that came with the app.")
                    .accessibilityIdentifier("home.sample.link")
            }
        }) {
            if let newest = decks.first {
                newestDeck(newest)
                if decks.count > 1 {
                    Divider()
                    VStack(alignment: .leading, spacing: 0) { ForEach(decks.dropFirst()) { earlier($0) } }
                }
            } else if let sample {
                sampleDeck(sample)
            } else {
                WorkbenchEmptyState(symbol: "rectangle.stack", title: "No decks yet",
                                    detail: "Snap a few screens, talk over them, and hand them to your assistant to build a deck. It appears here.") {
                    Button("Open Snap & Talk") { model.page = "readback" }.controlSize(.small).accessibilityIdentifier("home.decks.open")
                }
            }
            if let problem {
                WorkbenchNote(problem, font: .caption)
            }
        }
        .task(id: readback.recentSessionURLs.map(\.path) + [readback.manifest?.updatedAt.description ?? "", "\(returns)"]) {
            let roots = readback.recentSessionURLs
            decks = await Task.detached(priority: .utility) { HomeDeck.read(roots) }.value
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in returns &+= 1 }
        .accessibilityIdentifier("home.decks")
    }

    /// The newest session, open: its first screen beside its name, size and deck, with its
    /// actions across the tile so they never truncate in a half-width column.
    @ViewBuilder private func newestDeck(_ deck: HomeDeck) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // A picture opens as a picture (Fit rule 3).
            CapturePreviewButton("View the first screen of " + deck.title, item: {
                .init(title: deck.title, detail: "Snap & Talk session · first screen",
                      source: .file(deck.thumbnail, missing: "This screen is no longer in the session folder."))
            }) {
                HomeThumbnail(url: deck.thumbnail, revision: deck.updatedAt.description, caption: nil).frame(width: 140)
            }.frame(width: 140, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(deck.title).font(.callout.weight(.semibold)).lineLimit(2)
                Text("\(deck.screens) \(deck.screens == 1 ? "screen" : "screens") · " + HomeMeetingTile.stamp(deck.updatedAt))
                    .font(.caption).foregroundStyle(.secondary)
                if let file = deck.deck {
                    Label("Deck ready" + (deck.deckDate.map { " · " + HomeMeetingTile.stamp($0) } ?? ""), systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(Workbench.accent).help(file.lastPathComponent)
                } else {
                    Text("No deck yet. Use Hand off in Snap & Talk to build it.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack(spacing: 8) {
            if let file = deck.deck {
                Button { open(file) } label: { Label("Open deck", systemImage: "play.rectangle") }
                    .buttonStyle(.borderedProminent).help(file.lastPathComponent).accessibilityIdentifier("home.decks.deck")
            }
            Button("Open in Snap & Talk") { continueSession(deck.root) }
                .help("Opens this session in Snap & Talk. Nothing records until you capture.")
                .accessibilityIdentifier("home.decks.continue")
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([deck.deck ?? deck.root]) }
                .accessibilityIdentifier("home.decks.finder")
        }.controlSize(.small).fixedSize()
    }

    /// An earlier session: one line that continues it in Snap & Talk.
    private func earlier(_ deck: HomeDeck) -> some View {
        Button { continueSession(deck.root) } label: {
            HStack(spacing: 10) {
                Text(deck.title).font(.callout).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(deck.screens) \(deck.screens == 1 ? "screen" : "screens")" + (deck.deck == nil ? "" : " · deck"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
            }.padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(.plain).help("Open it in Snap & Talk")
            .accessibilityLabel(deck.title + ", open in Snap & Talk")
    }

    /// Before the person's own deck: the sample's cover beside what it is, with the whole deck
    /// one click away. It is a tour of Workbench, and says no more than that about how it was made.
    @ViewBuilder private func sampleDeck(_ sample: SampleDeck) -> some View {
        HStack(alignment: .top, spacing: 14) {
            if let cover = sample.slides.first {
                CapturePreviewButton("View the sample deck's slides", item: { item(for: cover, in: sample) }, collection: {
                    sample.slides.map { item(for: $0, in: sample) }
                }) {
                    HomeThumbnail(url: sample.url(cover), revision: "", caption: nil)
                }.frame(width: 190)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Sample deck").font(.callout.weight(.semibold))
                Text("A \(sample.slides.count)-slide tour of Workbench. Decks you build in Snap & Talk appear here.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Open") { openSample() }
                        .help("Shows the sample deck. It came with Workbench and is not saved in History.")
                        .accessibilityLabel("Open sample deck").accessibilityIdentifier("home.sample.open")
                    Button("Make your own") { model.page = "readback" }
                        .help("Opens Snap & Talk. Nothing starts until you choose New session.")
                        .accessibilityIdentifier("home.sample.make")
                }.controlSize(.small).fixedSize().padding(.top, 4)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func item(for slide: SampleDeck.Slide, in deck: SampleDeck) -> CaptureImagePreviewItem {
        .init(title: slide.title, detail: "Sample deck · a tour of Workbench that came with the app",
              source: .file(deck.url(slide), missing: "This sample slide is missing from Workbench. Reinstalling Workbench restores it."))
    }
    private func openSample() {
        guard let sample else { return }
        problem = quickLook.show(url: sample.pdf, title: "Sample deck") ? nil : "The sample deck could not be shown."
    }
    private func open(_ file: URL) {
        problem = NSWorkspace.shared.open(file) ? nil : "No app on this Mac opened \(file.lastPathComponent). Show in Finder to choose one."
    }
    /// The same switch Snap & Talk's Sessions… uses, so its busy and unsaved-edit admission applies.
    private func continueSession(_ root: URL) {
        if readback.sessionURL?.standardizedFileURL.path != root.standardizedFileURL.path { readback.openRecent(root) }
        model.page = "readback"
    }
}

/// A 16:10 thumbnail with an optional one-line caption, loaded off the main thread at
/// thumbnail size.
struct HomeThumbnail: View {
    let url: URL?
    let revision: String
    let caption: String?
    @State private var image: NSImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.aspectRatio(16 / 10, contentMode: .fit)
                .overlay {
                    if let image { Image(nsImage: image).resizable().scaledToFill() }
                    else { Image(systemName: "photo").foregroundStyle(.tertiary) }
                }
                .background(Workbench.background)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Workbench.border))
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(url?.path ?? "")#\(revision)") {
            guard let url else { image = nil; return }
            image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 480, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
                return NSImage(cgImage: cgImage, size: .zero)
            }.value
        }
    }
}

// MARK: Your keys

/// Workbench's keys as a habit, not a list (docs/desktop.md § Home): the left hand's keys drawn
/// as a keyboard with each Option shortcut on its key, so the one-hand, no-look layout is seen at
/// once; a click on a key to practise or change it; a suggested key for a core tool that has
/// none; and the next three worth learning. A key counts as learned once practised or pressed
/// for real. Settings › Keyboard keeps every shortcut and its editing.
enum HomeKeys {
    /// The left hand's keys by position (macOS virtual key codes), so a layout's own letters land
    /// where the fingers are: Q W E R T, A S D F G, Z X C V B.
    static let rows: [[UInt32]] = [[12, 13, 14, 15, 17], [0, 1, 2, 3, 5], [6, 7, 8, 9, 11]]
    /// What to learn, in order: the killer features first (Dictate, Draw, Snap & Talk), then the
    /// rest of the presenter's set.
    static let priority = ["voice.1", "stage.pen", "voice.5", "stage.clear", "stage.arrow", "voice.7",
                           "stage.personaToggle", "stage.undo", "stage.rectangle", "voice.2", "stage.personaNext", "voice.8"]
    /// A word short enough for a keycap; anything else uses its catalogue title.
    static let shortNames = ["voice.1": "Dictate", "voice.2": "Controls", "voice.5": "Snap & Talk", "voice.7": "Present", "voice.8": "Snap",
                             "stage.pen": "Draw", "stage.arrow": "Arrow", "stage.rectangle": "Shape", "stage.clear": "Clear",
                             "stage.undo": "Undo", "stage.personaToggle": "Persona", "stage.personaNext": "Persona ›"]
    /// Core tools that ship without a key, with the free left-hand keys to offer, best first.
    /// E is never offered: Option-E is an accent key.
    static let suggestions: [(id: String, keys: [UInt32])] = [("voice.8", [5, 17, 11])]
    static func name(_ entry: ShortcutEntry) -> String { shortNames[entry.id] ?? entry.title }
    /// A key counts for the combination it was learned on: rebinding a shortcut, or resetting it,
    /// makes it a new habit to learn.
    static func isLearned(_ entry: ShortcutEntry, in learned: Set<String>) -> Bool {
        learned.contains(KeyboardCoachModel.practiceRecord(entry.id, entry.shortcut))
    }
    /// A working shortcut: on, with no conflict or registration problem.
    static func usable(_ entry: ShortcutEntry) -> Bool { entry.shortcut.enabled && entry.error == nil }
    /// The usable Option shortcut on a key, if any.
    static func entry(on keyCode: UInt32, in entries: [ShortcutEntry]) -> ShortcutEntry? {
        entries.first { usable($0) && $0.shortcut.keyCode == keyCode && $0.shortcut.modifiers == UInt32(optionKey) }
    }
    /// The next three usable shortcuts not yet learned, in priority order.
    static func next(_ entries: [ShortcutEntry], learned: Set<String>, count: Int = 3) -> [ShortcutEntry] {
        Array(priority.compactMap { id in entries.first { $0.id == id } }.filter { usable($0) && !isLearned($0, in: learned) }.prefix(count))
    }
    /// How many of the priority shortcuts that work are learned.
    static func progress(_ entries: [ShortcutEntry], learned: Set<String>) -> (done: Int, total: Int) {
        let working = priority.compactMap { id in entries.first { $0.id == id } }.filter(usable)
        return (working.filter { isLearned($0, in: learned) }.count, working.count)
    }
    /// A core tool with no working key, and the first free Option key to put it on.
    static func suggestion(_ entries: [ShortcutEntry]) -> (entry: ShortcutEntry, key: UInt32)? {
        for (id, keys) in suggestions {
            guard let entry = entries.first(where: { $0.id == id }), !usable(entry),
                  let free = keys.first(where: { key in !entries.contains { $0.shortcut.enabled && $0.shortcut.keyCode == key && $0.shortcut.modifiers == UInt32(optionKey) } })
            else { continue }
            return (entry, free)
        }
        return nil
    }
}

struct HomeKeysTile: View {
    @ObservedObject var model: AppModel
    @ObservedObject var keyboard: KeyboardCoachModel
    /// Something is recording. Practice and Change pause Workbench's shortcuts, Stop among them,
    /// so neither starts then.
    var recording: Bool
    @State private var chosen: String?

    var body: some View {
        let entries = keyboard.entries
        WorkbenchTile("Your keys", symbol: "keyboard", accessory: {
            Button("Open Keyboard…") { keyboard.stopInteraction(); model.page = "shortcuts" }.buttonStyle(.workbenchLink).font(.callout)
                .help("Settings › Keyboard: every shortcut, its keys and its conflicts.")
                .accessibilityIdentifier("home.keys.all")
        }) {
            Text("Every tool is ⌥ plus a letter under your left hand, so your right hand stays on the mouse.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    keyMap(entries)
                    learning(entries).frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 12) {
                    keyMap(entries)
                    learning(entries)
                }
            }
        }
        .onDisappear { if keyboard.isInteracting { keyboard.stopInteraction() } }
        .accessibilityIdentifier("home.keys")
    }

    /// What the tile asks of the person now: the practice or new key in progress, a key for a
    /// core tool that has none, or the next three to learn.
    @ViewBuilder private func learning(_ entries: [ShortcutEntry]) -> some View {
        let next = HomeKeys.next(entries, learned: keyboard.practised)
        let progress = HomeKeys.progress(entries, learned: keyboard.practised)
        VStack(alignment: .leading, spacing: 8) {
            if let entry = active {
                if keyboard.interaction == .practicing { practice(entry) } else { changing(entry) }
            } else {
                if let message = keyboard.message, keyboard.hasError {
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let suggestion = HomeKeys.suggestion(entries) { suggest(suggestion.entry, key: suggestion.key) }
                HStack(alignment: .firstTextBaseline) {
                    Text(next.isEmpty ? (progress.total == 0 ? "No shortcuts are on" : "Every key learned") : progress.done == 0 ? "Learn these three first" : "Learn next")
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 8)
                    // The coach's own four-second confirmation, beside the count it just moved.
                    if let confirmation = keyboard.confirmation?.kind { WorkbenchStatusBadge(text: confirmation.rawValue, tone: .done) }
                    if progress.total > 0 { Text("\(progress.done) of \(progress.total) learned").font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(next) { learnRow($0) }
            }
        }
    }

    /// The practice or new key running from this tile, if any.
    private var active: ShortcutEntry? { keyboard.isInteracting ? keyboard.selected : nil }

    /// Three rows of keycaps. A key with a shortcut shows its tool in the accent and opens
    /// Practice and Change; learned keys carry a tick; the rest stay quiet.
    private func keyMap(_ entries: [ShortcutEntry]) -> some View {
        let next = Set(HomeKeys.next(entries, learned: keyboard.practised).map(\.id))
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(HomeKeys.rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { code in
                        let entry = HomeKeys.entry(on: code, in: entries)
                        keycap(code, entry: entry, next: entry.map { next.contains($0.id) } ?? false)
                    }
                }.padding(.leading, CGFloat(index) * 8)
            }
        }.fixedSize()
    }

    /// `next`: one of the three to learn now, ringed so the map itself shows where to start.
    @ViewBuilder private func keycap(_ code: UInt32, entry: ShortcutEntry?, next: Bool) -> some View {
        let letter = VoiceShortcut(keyCode: code, modifiers: 0, enabled: true).label.uppercased()
        let learned = entry.map { HomeKeys.isLearned($0, in: keyboard.practised) } ?? false
        let face = VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text(letter).font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
                if learned { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Workbench.accent).accessibilityHidden(true) }
            }
            Text(entry.map(HomeKeys.name) ?? " ").font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.9)
                .foregroundStyle(entry == nil ? .clear : Workbench.accent)
        }
        .padding(.horizontal, 5).padding(.vertical, 5)
        .frame(width: 64, height: 40, alignment: .topLeading)
        .foregroundStyle(entry == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        .background(entry == nil ? Workbench.background : Workbench.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(entry == nil ? Workbench.border : Workbench.accent.opacity(next ? 1 : 0.35), lineWidth: next ? 2 : 1))
        if let entry {
            Button { chosen = entry.id } label: { face.contentShape(RoundedRectangle(cornerRadius: 7)) }
                .buttonStyle(.plain)
                .help("\(entry.shortcut.label) · \(entry.title)")
                .accessibilityLabel("\(entry.shortcut.label), \(entry.title)\(learned ? ", learned" : next ? ", learn next" : "")")
                .accessibilityHint("Practice or change this key")
                .popover(isPresented: Binding(get: { chosen == entry.id }, set: { if !$0 { chosen = nil } }), arrowEdge: .bottom) {
                    keyActions(entry)
                }
        } else {
            face.accessibilityHidden(true)
        }
    }

    /// A key's two habits: practise it, or move it somewhere your hand prefers.
    private func keyActions(_ entry: ShortcutEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(entry.shortcut.label) · \(entry.title)").font(.callout.weight(.semibold))
            HStack(spacing: 8) {
                Button("Practice") { chosen = nil; keyboard.selectedID = entry.id; keyboard.beginPractice() }
                    .buttonStyle(.borderedProminent)
                Button("Change…") { chosen = nil; keyboard.selectedID = entry.id; keyboard.beginRecording() }
            }.controlSize(.small).disabled(recording)
            if recording { Text("Finish recording first. Practice pauses Workbench’s shortcuts.").font(.caption).foregroundStyle(.secondary) }
        }.padding(14).frame(width: 260, alignment: .leading)
    }

    private func learnRow(_ entry: ShortcutEntry) -> some View {
        HStack(spacing: 10) {
            Text(entry.shortcut.label).font(.system(.callout, design: .rounded).weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Workbench.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Workbench.border))
            Text(HomeKeys.name(entry)).font(.callout)
            if let hint = hint(entry) { Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 8)
            Button("Practice") { keyboard.selectedID = entry.id; keyboard.beginPractice() }
                .controlSize(.small).disabled(recording)
                .help(recording ? "Finish recording first: practice pauses Workbench’s shortcuts." : "Press \(entry.shortcut.label) three times here. Workbench’s shortcuts pause while you practise.")
                .accessibilityLabel("Practice \(entry.shortcut.label), \(HomeKeys.name(entry))")
                .accessibilityIdentifier("home.keys.practice")
        }
    }

    /// How the key is used, where it is not a plain press.
    private func hint(_ entry: ShortcutEntry) -> String? {
        switch entry.id {
        case "stage.pen": return "hold, draw, let go"
        case "voice.1": return model.preferences.capture == .hold ? "hold, talk, let go" : "press to start, again to stop"
        default: return nil
        }
    }

    /// A core tool with no key: put it on a free left-hand key in one click.
    private func suggest(_ entry: ShortcutEntry, key: UInt32) -> some View {
        let shortcut = VoiceShortcut(keyCode: key, modifiers: UInt32(optionKey), enabled: true)
        return HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Workbench.accent).accessibilityHidden(true)
            Text("\(HomeKeys.name(entry)) has no key yet.").font(.callout)
            Spacer(minLength: 8)
            Button("Put \(HomeKeys.name(entry)) on \(shortcut.label)") { keyboard.assign(entry.id, shortcut) }
                .controlSize(.small).disabled(recording)
                .help("Checks for a conflict first. You can change it any time in Settings › Keyboard.")
                .accessibilityIdentifier("home.keys.suggest")
        }
    }

    /// The Keyboard coach's own practice, shown here: the keys, three presses and its words.
    private func practice(_ entry: ShortcutEntry) -> some View {
        let completed = keyboard.practice?.completed ?? 0
        return HStack(spacing: 12) {
            Text(entry.shortcut.label).font(.system(size: 22, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Workbench.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(prompt(entry)).font(.callout)
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Image(systemName: index < completed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(index < completed ? Workbench.accent : Color.secondary.opacity(0.45))
                    }
                }
                Text("Nothing records or draws while you practise. Escape stops.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Stop practice") { keyboard.stopInteraction() }.controlSize(.small)
        }.accessibilityElement(children: .combine)
    }

    /// Recording a new combination, with the coach's own words and Escape to cancel.
    private func changing(_ entry: ShortcutEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "keyboard.badge.ellipsis").font(.system(size: 22)).foregroundStyle(Workbench.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("New keys for \(entry.title)").font(.callout.weight(.semibold))
                Text(keyboard.message ?? "Press your new combination. Escape cancels.").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Cancel") { keyboard.stopInteraction() }.controlSize(.small)
        }.accessibilityElement(children: .combine)
    }

    private func prompt(_ entry: ShortcutEntry) -> String {
        switch keyboard.practice?.feedback {
        case .release: return "Now release the key."
        case .retry: return "Try \(entry.shortcut.label)."
        case .success: return "Good. Press it again."
        default: return "Press and release \(entry.shortcut.label) · \(HomeKeys.name(entry))."
        }
    }
}
