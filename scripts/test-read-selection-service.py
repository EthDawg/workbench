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
    func invalidateAudio() { invalidations += 1 }
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
        try check(model.speechText == exact && model.pendingReadingSelection != nil && model.invalidations == invalidations, "active audio generation defers replacement without altering its input")
        model.rendering = false
        model.replaceReadingWithSelection()
        try check(model.speechText == "Incoming replacement" && model.pendingReadingSelection == nil && model.invalidations == invalidations + 1, "explicit replacement invalidates only the prior audio and adopts incoming text")
        let long = String(repeating: "a", count: 10_001)
        model.receiveReadingSelection(try ReadingSelectionImport(text: long))
        model.replaceReadingWithSelection()
        try check(model.speechText == long && model.readingLimitMessage(for: long)?.contains("Speko") == true, "online provider limit retains oversized text for editing")
        model.readingProvider = .mac
        try check(model.readingLimitMessage(for: long) == nil, "limit follows the existing selected provider")
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
