#!/usr/bin/env python3
"""Keep every Accessibility framework call inside AccessibilityBridge.swift.

On macOS 26 an Accessibility call that waits on another process from a Swift
task's thread logs an AXCommon fault, "unsafeForcedSync called from Swift
Concurrent context"; the installed app logged more than 126,000 of them in a
week, nearly all from listing the Mac voices. `AccessibilityBridge` runs such
calls where macOS counts them as plain code, so this check fails when a call
appears anywhere else: element IPC (AXUIElement*), observers (AXObserver*) and
the voice catalogue (AVSpeechSynthesisVoice.speechVoices, the voice-by-identifier
initializer, NSSpeechSynthesizer's voice list and attributes). AXValue helpers
and AXIsProcessTrusted stay free: they do not message another process.

    python3 scripts/check-accessibility-bridge.py          # the repository
    python3 scripts/check-accessibility-bridge.py DIR...   # other roots, for its test
"""
from pathlib import Path
import re
import sys

PROJECT = Path(__file__).resolve().parents[1]
BRIDGE = Path('Sources/LocalVoice/AccessibilityBridge.swift')
CALLS = re.compile(r'\bAXUIElement\w*\(|\bAXObserver\w*\(|\bAVSpeechSynthesisVoice\.speechVoices\('
                   r'|\bAVSpeechSynthesisVoice\(identifier:|\bNSSpeechSynthesizer\.availableVoices\b'
                   r'|\bNSSpeechSynthesizer\.attributes\(forVoice:')
LINE_COMMENT = re.compile(r'//.*')


def strays(root):
    """(relative path, line number, call) for every call outside the bridge."""
    found = []
    for path in sorted(root.glob('Sources/**/*.swift')):
        relative = path.relative_to(root)
        if relative == BRIDGE:
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            for match in CALLS.finditer(LINE_COMMENT.sub('', line)):
                found.append((str(relative), number, match.group().rstrip('(')))
    return found


def main(roots):
    failed = False
    for root in roots:
        if not (root / BRIDGE).exists():
            print(f'{root}: {BRIDGE} is missing')
            failed = True
            continue
        found = strays(root)
        for path, number, call in found:
            print(f'{path}:{number}: {call} belongs in {BRIDGE}')
        failed = failed or bool(found)
    if failed:
        return 1
    print('Accessibility bridge OK')
    return 0


if __name__ == '__main__':
    sys.exit(main([Path(argument) for argument in sys.argv[1:]] or [PROJECT]))
