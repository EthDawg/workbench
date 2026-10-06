#!/usr/bin/env python3
"""Retired admission and retained-owner checks; no app launch or user stores."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
RETIRED_COMMANDS = {
    "--self-test", "--check-reading", "--check-reading-cancellation",
    "--check-reading-render", "--render-reading-fixture", "--measure-reading-latency",
    "--check-neural-voice", "--check-neural-voice-download", "--check-neural-voice-render",
    "--check-speko", "--check-reading-service", "--check-reading-service-native",
    "--render-reading-service-fixture",
}


class RetirementAdmission(unittest.TestCase):
    def test_no_runtime_tts_implementation_or_startup_admission(self):
        forbidden = ("AVSpeechSynthesizer", "AVSpeechSynthesisVoice", "NSSpeechSynthesizer",
                     "SpekoKeychain", "SpekoClient", "PocketTtsManager", "ReadingPlayer",
                     "ReadingProvider", "NeuralVoiceEngine", "NSUpdateDynamicServices", "servicesProvider =")
        for path in (ROOT / "Sources/LocalVoice").glob("*.swift"):
            if path.stem.endswith("Checks"):
                continue
            source = path.read_text()
            for symbol in forbidden:
                self.assertNotIn(symbol, source, f"retired admission in {path.name}: {symbol}")
        model = (ROOT / "Sources/LocalVoice/AppModel.swift").read_text()
        self.assertIn("library.preserveRetiredReading(speechText)", model)
        self.assertIn("speechText: speechText", model)
        self.assertNotIn("importReading", model)

    def test_old_shortcut_dispatch_and_contextual_doors_are_closed(self):
        main = (ROOT / "Sources/LocalVoice/main.swift").read_text()
        callback = main.split("hotkeys.onKey =", 1)[1].split("readback.onStateChange", 1)[0]
        self.assertIn("VoicePreferences.shortcutIDs.contains(id)", callback.split("if id == 1", 1)[0])
        self.assertNotRegex(callback, r"id\s*==\s*6")
        self.assertIn("id == 5", callback)
        for filename in ["Views.swift", "WorkbenchHome.swift", "CaptureHistoryView.swift", "DemoLibraryView.swift", "HistorySelectionControls.swift"]:
            source = (ROOT / "Sources/LocalVoice" / filename).read_text()
            if filename == "WorkbenchHome.swift":
                self.assertEqual(source.count('"speak"'), 1)
                self.assertIn('if route == "speak" { return ("library", "library") }', source)
            else:
                self.assertNotIn('"speak"', source, filename)
            self.assertNotIn('"Read aloud"', source, filename)
        self.assertIn('"Review result"', (ROOT / "Sources/LocalVoice/HistorySelectionControls.swift").read_text())

    def test_retired_commands_and_service_are_not_release_requirements(self):
        main = (ROOT / "Sources/LocalVoice/main.swift").read_text()
        commands = set(re.findall(r'case "(--[^" ]+)"', main))
        self.assertFalse(commands & RETIRED_COMMANDS)
        for flags in json.loads((ROOT / "scripts/release/config.json").read_text())["checks"]:
            self.assertIn(flags[0], commands)
            self.assertFalse(set(flags) & RETIRED_COMMANDS)
        info = plistlib.loads((ROOT / "scripts/Info.plist").read_bytes())
        self.assertFalse(any(service.get("NSMessage") == "readSelection" for service in info.get("NSServices", [])))

    def test_retained_audio_and_update_insertion_owners(self):
        main = (ROOT / "Sources/LocalVoice/main.swift").read_text()
        self.assertIn("insertion: self.model.promptInsertion.running", main)
        self.assertIn("recordingPlayback", main)
        self.assertIn("ReadbackModel(engine: model.engine)", main)
        persona_check = main.split('case "--check-persona-voice-native":', 1)[1].split('case "--render-surfaces":', 1)[0]
        self.assertIn("guard args.count == 2", persona_check)
        self.assertIn("speak: false", persona_check)
        self.assertTrue((ROOT / "Sources/LocalVoice/RecognitionProviders.swift").exists())
        self.assertTrue((ROOT / "Sources/LocalVoice/MeetingAudio.swift").exists())


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path)
    args = parser.parse_args()
    if args.binary:
        for command in sorted(RETIRED_COMMANDS):
            result = subprocess.run([str(args.binary.resolve()), command], text=True, capture_output=True, timeout=15)
            assert result.returncode != 0 and "Usage: LocalVoice" in result.stderr, command
        result = subprocess.run([str(args.binary.resolve()), "--check-persona-voice-native", "/unused-synthetic-output", "--speak"],
                                text=True, capture_output=True, timeout=15)
        assert result.returncode != 0 and "Usage: --check-persona-voice-native" in result.stderr
        print(f"Retired production commands: {len(RETIRED_COMMANDS)} commands and Persona's speech option refused before app startup")
    else:
        unittest.main(argv=[__file__])
