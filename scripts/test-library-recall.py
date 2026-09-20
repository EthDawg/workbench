#!/usr/bin/env python3
"""Check actual Saved resources model/view source with disposable dependencies.

No saved user state, general clipboard, URL launch or model is used by checks.
--native-fixture builds a separate synthetic app for manual Return/IME checks;
it does not launch it. Its injected Copy/Open actions only update a visible log;
Quick Look uses only the fixture's disposable local file.
"""

import argparse
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time


PROJECT = Path(__file__).resolve().parents[1]
SOURCES = [PROJECT / "Sources/LocalVoice" / name for name in ("DemoLibrary.swift", "DemoLibraryView.swift", "DemoQuickLook.swift", "DemoLibraryImport.swift", "DemoLibraryImportView.swift")]
SOURCES.append(PROJECT / "Sources/PresenterKit/PresenterProtocol.swift")

DEPENDENCIES = r'''
import AppKit
import Combine
import SwiftUI

enum VoiceError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let message): return message } }
}
struct StateStore {
    let url: URL
    init() { fatalError("The fixture must always inject its temporary library store") }
}
@MainActor enum TextDelivery {
    static func copy(_ text: String) -> Int? { fatalError("The fixture must inject its private Copy action") }
}
struct FixtureShortcut { var label = "⌃⌥J" }
struct FixturePreferences { func shortcut(_ id: UInt32) -> FixtureShortcut { FixtureShortcut() } }
@MainActor final class AppModel: ObservableObject {
    @Published var transcript = "A synthetic transcript for this disposable app."
    @Published var speechText = ""
    @Published var page = "library"
    @Published var libraryFocusToken = UUID()
    @Published var preferences = FixturePreferences()
    @Published var showingPhonePhotos = false
    let photoHandoff = FixturePhotoHandoff()
    let presenter = FixturePresenter()
    var onUsePhotoAsBackdrop: ((URL, String) -> Void)?
}
// Photo arrival is covered by its own shared-module and UI checks. This recall
// fixture deliberately keeps cloud and handoff dependencies out of its scope.
final class FixturePhotoHandoff {}
final class FixturePresenter {}
struct ChromeConnectionView: View {
    let presenter: FixturePresenter
    var body: some View { EmptyView() }
}
struct PhotoHandoffView: View {
    let handoff: FixturePhotoHandoff
    var onUseAsBackdrop: ((URL, String) -> Void)?
    var body: some View { Text("Photo handoff is outside this recall fixture.") }
}
enum Workbench {
    static let accent = Color.accentColor
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
}
extension View { func workbenchTheme() -> some View { self } }
'''

CHECKS = r'''
import AppKit
import Foundation

@main struct Checks {
    @MainActor static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    }
    @MainActor static func run() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("Workbench-recall-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DemoLibraryStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalURL = directory.appendingPathComponent("Offline guide.txt")
        let originalData = Data("Synthetic guide. Keep this original intact.".utf8)
        try originalData.write(to: originalURL)
        let executableURL = directory.appendingPathComponent("Not a document.txt")
        try Data("Synthetic executable fixture".utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
        let bookmark = try originalURL.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        let first = DemoResource(title: "First prompt", content: " \nKeep this exact text.\nSecond line.\t ", favorite: true)
        let second = DemoResource(title: "Second prompt", content: "Second selected text")
        let link = DemoResource(kind: .link, title: "Web reference", content: "https://example.com/guide?step=2")
        let file = DemoResource(kind: .file, title: "Offline guide", content: originalURL.path, bookmark: bookmark)
        let missing = DemoResource(kind: .file, title: "Missing document", content: directory.appendingPathComponent("missing.txt").path)
        let executable = DemoResource(kind: .file, title: "Executable document", content: executableURL.path)
        let items = [first, second, link, file, missing, executable]
        try store.save(items)
        let savedBefore = try Data(contentsOf: store.url)
        var copied: [String] = [], opened: [URL] = []
        var copySucceeds = true, openSucceeds = true
        let model = DemoLibraryModel(store: store, copyText: { text in
            copied.append(text); return copySucceeds ? 42 : nil
        }, openURL: { url in opened.append(url); return openSucceeds })
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw VoiceError.message("LIBRARY_RECALL_CHECK_FAILED: " + name) }
            count += 1
        }

        try check(model.performPrimaryAction(), "Initial filtered selection has a primary action")
        try check(copied == [first.content] && opened.isEmpty, "Prompt recall copies exact whitespace and never opens anything")
        try check(model.notice?.contains("copied") == true && model.error == nil, "Successful copy reports success")
        model.query = "selected"
        try check(model.selected?.id == second.id && model.performPrimaryAction(), "Search changes the action to the visible selected result")
        try check(copied.last == second.content, "Filtered action cannot copy the formerly selected prompt")

        copySucceeds = false
        try check(model.performPrimaryAction(), "A failed copy is still a handled action")
        try check(model.notice == nil && model.error?.contains("clipboard") == true, "Copy failure clears old success and reports retryable failure")
        copySucceeds = true
        try check(model.performPrimaryAction() && model.error == nil && model.notice?.contains("copied") == true,
                  "Successful retry clears the action error")

        for kind in DemoResourceKind.allCases {
            let draft = DemoResource(kind: kind, title: "Unfinished", content: "Keep this edit\nand its newlines")
            model.draft = draft
            let countBefore = copied.count + opened.count
            try check(!model.performPrimaryAction() && model.draft == draft && copied.count + opened.count == countBefore,
                      "A \(kind.rawValue) editor blocks recall and retains its draft")
            model.draft = nil
        }
        model.query = "No matching resource"
        let effectCount = copied.count + opened.count
        try check(!model.performPrimaryAction() && copied.count + opened.count == effectCount, "No results means no action")
        model.query = "selected"; model.selection = UUID()
        try check(!model.performPrimaryAction(), "A stale or absent selection cannot act on a fallback row")

        model.query = "Web reference"
        try check(model.performPrimaryAction() && opened.last == link.webURL && copied.count + opened.count == effectCount + 1,
                  "Link recall opens only the selected validated URL")
        openSucceeds = false
        try check(model.performPrimaryAction() && model.error?.contains("open this link") == true, "URL opener failure remains visible")
        openSucceeds = true
        model.query = "Offline guide"
        try check(model.performPrimaryAction() && opened.last?.resolvingSymlinksInPath() == originalURL.resolvingSymlinksInPath(),
                  "File recall opens the bookmarked original document")
        let openedBefore = opened.count
        model.query = "Missing document"
        try check(!model.performPrimaryAction() && opened.count == openedBefore, "Missing files never reach the opener")
        model.query = "Executable document"
        try check(!model.performPrimaryAction() && opened.count == openedBefore, "Return cannot launch executable files")
        try check(try Data(contentsOf: store.url) == savedBefore && Data(contentsOf: originalURL) == originalData,
                  "Recall and failed actions leave library bytes, bookmark and original file intact")

        // These are the production view's input-policy boundaries; native field
        // submission still owns IME composition and the list owns its own focus.
        func allowed(search: Bool = false, editable: Bool = false, marked: Bool = false,
                     modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false) -> Bool {
            DemoLibraryReturnPolicy.allows(fromSearch: search, editableText: editable,
                hasMarkedText: marked, modifiers: modifiers, isRepeat: repeated)
        }
        try check(allowed(), "Plain Return in the results list can act")
        try check(allowed(search: true, editable: true), "Committed search submission can act")
        try check(!allowed(editable: true), "Return in another editable text view remains text input")
        try check(!allowed(search: true, editable: true, marked: true) && !allowed(marked: true), "IME marked text never activates recall")
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            try check(!allowed(search: true, editable: true, modifiers: modifier), "Modified Return is not repurposed: \(modifier.rawValue)")
        }
        try check(!allowed(repeated: true) && !allowed(search: true, repeated: true), "Holding Return cannot repeatedly copy or launch")
        try check(allowed(modifiers: [.capsLock, .numericPad]), "Caps Lock/keypad flags do not block plain Return")
        print("LIBRARY_RECALL_CHECKS_OK: \(count) checks; actual model and view, temporary store, injected Copy/Open")
    }
}
'''

NATIVE = r'''
import SwiftUI

@MainActor final class FixtureEvents: ObservableObject {
    @Published var latest = "No action yet. Copy/Open below are simulated."
    @Published var failCopy = false
    var count = 0
}
@MainActor final class FixtureSession: ObservableObject {
    let model = AppModel()
    let events = FixtureEvents()
    let library: DemoLibraryModel
    init() {
        let directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("SyntheticData")
        let store = DemoLibraryStore(directory: directory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("Offline guide.txt")
            try Data("Only a synthetic guide for previewing Saved resources.".utf8).write(to: file)
            try store.save([
                DemoResource(title: "Follow-up prompt", product: "People", persona: "Manager", content: "Thanks for the conversation.\nWhat would you like to explore next?", favorite: true),
                DemoResource(title: "Second prompt", product: "People", content: "This is the second selected prompt."),
                DemoResource(kind: .link, title: "Example reference", content: "https://example.com/guide"),
                DemoResource(kind: .file, title: "Offline guide", content: file.path),
                DemoResource(kind: .file, title: "Missing guide", content: directory.appendingPathComponent("Missing.txt").path)
            ])
        } catch { fatalError("Synthetic fixture preparation failed: \(error)") }
        let events = self.events
        library = DemoLibraryModel(store: store, copyText: { text in
            events.count += 1
            events.latest = "\(events.count). \(events.failCopy ? "COPY FAILED" : "COPY"): \(text)"
            return events.failCopy ? nil : events.count
        }, openURL: { url in
            events.count += 1; events.latest = "\(events.count). OPEN (simulated): \(url.absoluteString)"
            return true
        })
    }
}
struct FixtureView: View {
    @ObservedObject var session: FixtureSession
    @ObservedObject var events: FixtureEvents
    var body: some View {
        VStack(spacing: 0) {
            DemoLibraryView(library: session.library, model: session.model).padding(24)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Simulate clipboard failure", isOn: $events.failCopy)
                Text(events.latest).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(4)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minWidth: 850, minHeight: 680)
    }
}
@main struct LibraryRecallFixture: App {
    @StateObject private var session = FixtureSession()
    var body: some Scene {
        WindowGroup("Saved resources · Disposable QA") { FixtureView(session: session, events: session.events) }
            .defaultSize(width: 960, height: 790)
    }
}
'''


def compile_fixture(directory: Path, main: str, binary: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    copied = []
    for source in SOURCES:
        path = directory / source.name
        path.write_text(source.read_text().replace("import PresenterKit\n", ""))
        copied.append(path)
    dependencies = directory / "FixtureDependencies.swift"
    dependencies.write_text(DEPENDENCIES)
    checks = directory / "FixtureMain.swift"
    checks.write_text(main)
    binary.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        "swiftc", "-parse-as-library", "-swift-version", "5", "-module-cache-path", str(directory / "ModuleCache"),
        *(str(path) for path in copied), str(dependencies), str(checks), "-o", str(binary),
    ], check=True, timeout=120)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--native-fixture", type=Path, help="Build a disposable native QA app in this directory; do not launch")
parser.add_argument("--import-review", action="store_true", help="Check the import transaction with the actual model and store")
parser.add_argument("--render-import-review", type=Path, help="Render the actual import review with synthetic records")
args = parser.parse_args()
started = time.monotonic()
if args.native_fixture:
    directory = args.native_fixture.resolve()
    app = directory / "LibraryRecallFixture.app"
    compile_fixture(directory, NATIVE, app / "Contents/MacOS/LibraryRecallFixture")
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "local.workbench.qa.library-recall", "CFBundleName": "Library Recall QA",
        "CFBundleExecutable": "LibraryRecallFixture", "CFBundlePackageType": "APPL",
        "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
    }))
    print(f"Disposable native app (not launched): {app}")
    print("Check search Return, result-list Return, Quick Look/Escape, changed selection, no results, editor newlines, IME confirmation and copy failure/retry.")
    print("Copy/Open are simulated and visible below the actual Saved resources view. No live library is loaded.")
else:
    with tempfile.TemporaryDirectory(prefix="workbench-library-recall-", dir="/private/tmp") as temporary:
        directory = Path(temporary)
        binary = directory / "Checks"
        main = (PROJECT / "scripts/fixtures/LibraryImportChecks.swift").read_text() if args.import_review or args.render_import_review else CHECKS
        compile_fixture(directory, main, binary)
        subprocess.run([str(binary), *([str(args.render_import_review.resolve())] if args.render_import_review else [])], check=True, timeout=30)
print(f"Compilation and checks: {time.monotonic() - started:.3f}s")
