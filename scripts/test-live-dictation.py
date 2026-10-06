#!/usr/bin/env python3
"""Compile the actual live field owner and AX adapter with inert receiver checks."""
from pathlib import Path
import subprocess
import tempfile
import sys
sys.dont_write_bytecode = True
from swift_extract import SwiftFile

root = Path(__file__).resolve().parents[1]
shortcut = SwiftFile(root / 'Sources/LocalVoice/VoicePreferences.swift').extract(['VoiceShortcut'])
with tempfile.TemporaryDirectory(prefix='workbench-live-field-') as directory:
    directory = Path(directory)
    harness = directory / 'main.swift'
    harness.write_text('import AppKit\nimport Carbon\nstruct GlobalShortcutCombination { var keyCode: UInt32; var modifiers: UInt32 }\n'
                       + shortcut + '\nenum DeliveryMode { case paste, clipboard }\n'
                       + '@main struct CheckMain { @MainActor static func main() throws { try LiveDictationDeliveryChecks.run() } }\n')
    executable = directory / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(directory / 'ModuleCache'),
                    str(harness), *[str(root / 'Sources/LocalVoice' / name) for name in [
                        'AccessibilityBridge.swift', 'TextDelivery.swift', 'OpaqueEditorDestination.swift', 'InsertionBoundary.swift',
                        'LiveDictationDelivery.swift', 'LiveDictationDeliveryChecks.swift']],
                    '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
