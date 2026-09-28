#!/usr/bin/env python3
"""Check Services metadata and actual model handoff methods with isolated state."""
from pathlib import Path
import plistlib


ROOT = Path(__file__).resolve().parents[1]
info = plistlib.loads((ROOT / "scripts/Info.plist").read_bytes())
services = [item for item in info.get("NSServices", []) if item.get("NSMessage") == "readSelection"]
assert len(services) == 1, "expected exactly one readSelection Service"
service = services[0]
assert service.get("NSMenuItem", {}).get("default") == "Read Selection in Workbench"
assert service.get("NSPortName") == "Workbench"
assert service.get("NSSendTypes") == ["public.utf8-plain-text"]
assert "NSReturnTypes" not in service, "the Service must not replace text in the requesting app"
assert service.get("NSRequiredContext") == {}
assert service.get("NSRestricted") is False
assert "selected text" in service.get("NSServiceDescription", "").lower()
print("READ_SELECTION_METADATA_OK: 8 checks passed")

# Exercise the exact model handoff methods without AppModel initialization,
# Keychain, model downloads, playback, provider calls or saved user state.
import subprocess
import tempfile

model_source = (ROOT / "Sources/LocalVoice/AppModel.swift").read_text()
start = model_source.index("    func receiveReadingSelection(")
methods = model_source[start:model_source.index("    func toggleRecording(", start)]
harness = r'''
import AppKit

enum VoiceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
enum ReadingProvider: String { case mac, speko }
final class Receipt { func dismissHUD() {} }
@MainActor final class SelectionHarness {
    var error: String?
    let clipboardReceipt = Receipt()
    var speechText = "" { didSet { saves += 1 } }
    var saves = 0
    var invalidations = 0
    var pendingReadingSelection: ReadingSelectionImport?
    var rendering = false
    var status = ""
    var page = ""
    var onShowEditor: ((String) -> Void)?
    var readingProvider: ReadingProvider = .speko
    var voice = "Existing Mac voice"
    var selectedSpekoVoice = "Existing online voice"
    var rate = 180.0
    var readingLimit: Int { readingProvider == .speko ? 10_000 : 50_000 }
    func invalidateAudio() { invalidations += 1; playing = false }
    // The reading the decision ends: stand-ins that record what it asked for.
    var playing = false
    var readingGenerationActive = false
    var readingGenerationID: UUID?
    var readingTask: Task<Void, Never>?
    var cancels = 0, listens = 0
    struct MeetingWork { var isBusy = false }
    var meetings = MeetingWork()
    enum Phase { case idle, recording }
    var phase: Phase = .idle
    func cancelReading() { cancels += 1; readingGenerationActive = false; rendering = false; readingGenerationID = nil; readingTask = nil }
    var savingAudio = false
    func listen() { listens += 1 }
    var failureClears = 0
    func clearReadingFailure() { failureClears += 1 }
__METHODS__
}
@main struct Checks {
    @MainActor static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw VoiceError.message("READ_SELECTION_MODEL_FAILED: " + label) }
            count += 1
        }
        let model = SelectionHarness()
        let exact = "  Exact selection.\nSecond line.  "
        model.receiveReadingSelection(try ReadingSelectionImport(text: exact))
        try check(model.speechText == exact && model.saves == 1 && model.page == "speak", "empty draft adopts only exact supplied text")
        try check(model.readingProvider == .speko && model.voice == "Existing Mac voice" && model.selectedSpekoVoice == "Existing online voice" && model.rate == 180, "selection keeps provider, both voice choices and pace")
        let invalidations = model.invalidations
        model.receiveReadingSelection(try ReadingSelectionImport(text: exact))
        try check(model.saves == 1 && model.invalidations == invalidations && model.pendingReadingSelection == nil, "identical selection leaves saved draft and audio unchanged")
        model.receiveReadingSelection(try ReadingSelectionImport(text: "Incoming replacement"))
        try check(model.speechText == exact && model.saves == 1 && model.invalidations == invalidations, "different incoming selection stages without overwriting text or audio")
        model.keepCurrentReading()
        try check(model.pendingReadingSelection == nil && model.speechText == exact && model.saves == 1, "Keep current discards only the pending import")
        model.receiveReadingSelection(try ReadingSelectionImport(text: "Incoming replacement"))
        model.savingAudio = true; model.rendering = true; model.readingGenerationActive = true
        model.replaceReadingWithSelection()
        try check(model.speechText == exact && model.pendingReadingSelection != nil && model.invalidations == invalidations && model.cancels == 0
                  && model.status.contains("Save audio"), "Replace waits for Save audio, even while it makes its audio, and says why")
        model.savingAudio = false
        model.replaceReadingWithSelection()
        try check(model.speechText == "Incoming replacement" && model.pendingReadingSelection == nil && model.cancels == 1
                  && model.invalidations == invalidations + 1 && !model.rendering && model.listens == 0,
                  "Replace during generation cancels it, invalidates the old audio and waits for Listen")
        let long = String(repeating: "a", count: 10_001)
        model.receiveReadingSelection(try ReadingSelectionImport(text: long))
        model.replaceReadingWithSelection()
        try check(model.speechText == long && model.readingLimitMessage(for: long)?.contains("Speko") == true, "online provider limit retains oversized text for editing")
        model.readingProvider = .mac
        try check(model.readingLimitMessage(for: long) == nil, "limit follows the existing selected provider")

        // History and Library take the same decision, named for where the text came from.
        let doors = SelectionHarness()
        doors.speechText = "Current draft"; doors.saves = 0
        doors.importReading("A transcript to hear", from: .transcript)
        try check(doors.speechText == "Current draft" && doors.pendingReadingSelection?.origin == .transcript && doors.page == "speak"
                  && doors.status == "The transcript is ready. Choose Replace reading or Keep current." && doors.saves == 0,
                  "History's Read aloud stages a different draft for review instead of replacing it")
        doors.keepCurrentReading()
        try check(doors.speechText == "Current draft" && doors.pendingReadingSelection == nil && doors.invalidations == 0
                  && doors.status == "Current reading kept. The transcript is still in History.", "Keep current leaves the draft and the reading")
        doors.receiveReadingSelection(try ReadingSelectionImport(text: "Selected elsewhere"))
        doors.importReading("Saved prompt", from: .savedText)
        try check(doors.pendingReadingSelection?.text == "Saved prompt" && doors.pendingReadingSelection?.origin == .savedText,
                  "a newer import replaces a pending Service review, so it never stays attached to other text")
        doors.importReading("Current draft", from: .transcript)
        try check(doors.pendingReadingSelection == nil && doors.invalidations == 0 && doors.speechText == "Current draft"
                  && doors.status == "The transcript already matches this reading draft.", "the same text clears a stale review and does not restart")
        doors.importReading("  \n ", from: .savedText)
        try check(doors.error == "This saved item has no text to read." && doors.speechText == "Current draft" && doors.page == "speak",
                  "an empty item explains itself and leaves the draft")
        let emptyDraft = SelectionHarness()
        emptyDraft.playing = true
        emptyDraft.importReading("Saved prompt", from: .savedText)
        try check(emptyDraft.speechText == "Saved prompt" && emptyDraft.invalidations == 1 && !emptyDraft.playing && emptyDraft.listens == 0,
                  "an empty draft takes new text directly, ending the old reading and waiting for Listen")

        // Home's Read tile: the click is the choice, through the same replace step.
        let home = SelectionHarness()
        home.speechText = "Old draft"
        home.receiveReadingSelection(try ReadingSelectionImport(text: "Selected elsewhere"))
        home.listen(to: "Copied text")
        try check(home.speechText == "Copied text" && home.pendingReadingSelection == nil && home.invalidations == 1 && home.listens == 1
                  && home.status.contains("instead of the text waiting for review"),
                  "Home's tile replaces the draft through the owner, says it set the review aside, and starts Listen at once")
        home.status = "An earlier status"
        home.listen(to: "Newer copied text")
        try check(home.speechText == "Newer copied text" && home.status == "An earlier status" && home.listens == 2,
                  "with nothing set aside and nothing cancelled, the tile leaves the status for Listen instead of blanking it")
        home.speechText = "Copied text"
        home.playing = true
        home.listen(to: "Copied text")
        try check(home.listens == 2 && home.speechText == "Copied text", "the same text already playing carries on")
        home.playing = false; home.savingAudio = true
        home.listen(to: "Other copied text")
        try check(home.speechText == "Copied text" && home.listens == 2 && home.status.contains("Save audio"),
                  "the tile waits for Save audio")
        home.savingAudio = false; home.meetings.isBusy = true
        home.listen(to: "Other copied text")
        try check(home.speechText == "Copied text" && home.listens == 2 && home.error?.contains("meeting") == true,
                  "a meeting in progress leaves the draft alone and says why")
        print("READ_SELECTION_MODEL_OK: \(count) checks; actual handoff methods, isolated draft and provider state")
    }
}
'''.replace("__METHODS__", methods)
with tempfile.TemporaryDirectory(prefix="workbench-read-selection-", dir="/private/tmp") as temporary:
    directory = Path(temporary)
    fixture = directory / "SelectionChecks.swift"
    fixture.write_text(harness)
    executable = directory / "Checks"
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", "-module-cache-path", str(directory / "ModuleCache"),
                    str(ROOT / "Sources/LocalVoice/ReadSelectionService.swift"), str(fixture), "-o", str(executable)], check=True, timeout=120)
    subprocess.run([str(executable)], check=True, timeout=30)

# Every door that brings text into Read uses AppModel's one import owner. The
# model checks above prove the owner; these prove each door calls it, so a door
# cannot write the draft behind a paused or preparing reading again (#173).
import re


def button_action(path: str, label: str) -> str:
    source = (ROOT / path).read_text()
    assert source.count(f'Button("{label}")') == 1, f"expected one {label} button in {path}"
    start = source.index("{", source.index(f'Button("{label}")'))
    depth = 0
    for index in range(start, len(source)):
        depth += {"{": 1, "}": -1}.get(source[index], 0)
        if depth == 0:
            return source[start + 1:index].strip()
    raise AssertionError(f"unclosed action for {label} in {path}")


assert button_action("Sources/LocalVoice/CaptureHistoryView.swift", "Read aloud") == "model.importReading(item.text, from: .transcript)", \
    "History's Read aloud must go through importReading"
assert button_action("Sources/LocalVoice/DemoLibraryView.swift", "Read aloud") == "model.importReading(item.content, from: .savedText)", \
    "Library's Read aloud must go through importReading"
home = (ROOT / "Sources/LocalVoice/WorkbenchHome.swift").read_text()
tile = home[home.index("    private func readClipboard()"):]
tile = tile[:tile.index("\n    }\n")]
assert "model.listen(to: text)" in tile and "speechText" not in tile, "Home's Read tile must replace through listen(to:)"
assert "self?.model.receiveReadingSelection(selection)" in (ROOT / "Sources/LocalVoice/main.swift").read_text(), \
    "the Service must hand its selection to the import owner"
# Nothing else writes the reading draft. AppModel's three writers are the saved
# session's restore, Home's listen(to:) and the import decision's apply; the
# Read editor's binding is the person typing. Any other write or binding fails.
WRITE = re.compile(r"(?<!var )(?<!let )\bspeechText\s*(\+=|=(?!=))|\bspeechText\.(append|insert|remove|replace)")
BINDING = re.compile(r"\$\w*\.?speechText\b")
# A member is the declaration a line belongs to: any non-blank line at four
# spaces or less that is not a comment or a closing brace starts a new one, so
# a write in a property or type after an allowed method is not the method's.
DECLARATION = re.compile(r"^ {0,4}(?! )(?!//)(?!\})\S")
ALLOWED_WRITERS = ("    init(preferences:", "    func listen(to text: String)", "    private func applyReadingSelection(")


def draft_writes(root: Path) -> list:
    found = []
    for path in sorted((root / "Sources").rglob("*.swift")):
        member = ""
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if DECLARATION.match(line):
                member = line
            if WRITE.search(line) and not (path.name == "AppModel.swift" and member.startswith(ALLOWED_WRITERS)):
                found.append(f"{path.relative_to(root)}:{number}: {line.strip()}")
            for _ in BINDING.finditer(line):
                if not (path.name == "Views.swift" and "editor(text: $model.speechText," in line):
                    found.append(f"{path.relative_to(root)}:{number}: binds the draft outside Read's editor: {line.strip()}")
    return found


writes = draft_writes(ROOT)
assert not writes, "only Read's import owner, restore and editor change the reading draft:\n" + "\n".join(writes)

# The check itself: writes are found by member, not by position in the file.
with tempfile.TemporaryDirectory(prefix="workbench-draft-writers-", dir="/private/tmp") as temporary:
    fixture = Path(temporary)
    (fixture / "Sources/LocalVoice").mkdir(parents=True)
    (fixture / "Sources/LocalVoice/AppModel.swift").write_text("""final class AppModel {
    @Published var speechText = ""
    private func applyReadingSelection(_ selection: ReadingSelectionImport) {
        speechText = selection.text
    }
    var shortcut: String {
        speechText = "a computed property after an allowed method"
        return speechText
    }
    // A comment at member depth does not end the method above it.
    subscript(index: Int) -> String { speechText += "a subscript"; return "" }
    private func applyReadingSelection2() {
        speechText.append("similar name, other member")
    }
}
""")
    (fixture / "Sources/LocalVoice/Views.swift").write_text("""struct Probe: View {
    var body: some View {
        editor(text: $model.speechText, placeholder: "", label: "Text to read")
        TextField("x", text: $model.speechText)
    }
}
""")
    found = [entry.split(": ", 1)[0] for entry in draft_writes(fixture)]
    assert found == ["Sources/LocalVoice/AppModel.swift:7", "Sources/LocalVoice/AppModel.swift:11",
                     "Sources/LocalVoice/AppModel.swift:13", "Sources/LocalVoice/Views.swift:4"], found
print("READ_IMPORT_DOORS_OK: 6 checks; History, Library, Home and the Service use the one import owner, nothing else writes the draft, and the writer check finds writes by member")
