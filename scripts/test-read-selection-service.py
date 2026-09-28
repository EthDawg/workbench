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
        model.rendering = true
        model.replaceReadingWithSelection()
        try check(model.speechText == exact && model.pendingReadingSelection != nil && model.invalidations == invalidations && model.cancels == 0,
                  "Replace waits while Save audio writes its file, without altering its input")
        model.readingGenerationActive = true
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

        // History and Saved resources take the same decision, named for where the text came from.
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
        try check(home.speechText == "Copied text" && home.pendingReadingSelection == nil && home.invalidations == 1 && home.listens == 1,
                  "Home's tile replaces the draft through the owner and starts Listen at once")
        home.playing = true
        home.listen(to: "Copied text")
        try check(home.listens == 1 && home.invalidations == 1 && home.speechText == "Copied text", "the same text already playing carries on")
        home.playing = false; home.rendering = true
        home.listen(to: "Other copied text")
        try check(home.speechText == "Copied text" && home.listens == 1 && home.status.contains("Save audio"),
                  "the tile waits while Save audio writes its file")
        home.rendering = false; home.meetings.isBusy = true
        home.listen(to: "Other copied text")
        try check(home.speechText == "Copied text" && home.listens == 1 && home.error?.contains("meeting") == true,
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
    "Saved resources' Read aloud must go through importReading"
home = (ROOT / "Sources/LocalVoice/WorkbenchHome.swift").read_text()
tile = home[home.index("    private func readClipboard()"):]
tile = tile[:tile.index("\n    }\n")]
assert "model.listen(to: text)" in tile and "speechText" not in tile, "Home's Read tile must replace through listen(to:)"
assert "self?.model.receiveReadingSelection(selection)" in (ROOT / "Sources/LocalVoice/main.swift").read_text(), \
    "the Service must hand its selection to the import owner"
writes = []
for path in sorted((ROOT / "Sources/LocalVoice").glob("*.swift")):
    # AppModel owns the draft; checks and the offscreen gallery set up their own fixtures.
    if path.name == "AppModel.swift" or path.name.endswith(("Checks.swift", "Check.swift")) or path.name == "SurfaceGallery.swift":
        continue
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if re.search(r"(?<!var )(?<!let )\bspeechText\s*=(?!=)", line):
            writes.append(f"{path.name}:{number}: {line.strip()}")
assert not writes, "only AppModel writes the reading draft:\n" + "\n".join(writes)
print("READ_IMPORT_DOORS_OK: 5 checks; History, Saved resources, Home and the Service use the one import owner")
