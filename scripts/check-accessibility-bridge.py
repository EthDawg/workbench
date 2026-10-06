#!/usr/bin/env python3
"""Keep every Accessibility framework call inside AccessibilityBridge.swift.

On macOS 26 an Accessibility call that waits on another process from a Swift
task's thread logs an AXCommon fault, "unsafeForcedSync called from Swift
Concurrent context"; the installed app logged more than 126,000 of them in a
week, nearly all from listing the Mac voices. `AccessibilityBridge` runs such
calls where macOS counts them as plain code, so this check fails when one is
named anywhere else, called or merely referenced: element IPC (AXUIElement*),
observers (AXObserver*) and the voice catalogue (AVSpeechSynthesisVoice.speechVoices,
the voice-by-identifier initializer, NSSpeechSynthesizer's voice list and
attributes). The types AXUIElement, AXObserver and AXObserverCallback, AXValue
helpers and AXIsProcessTrusted stay free: they do not message another process.
Comments, line and block, are not code.

    python3 scripts/check-accessibility-bridge.py          # the repository
    python3 scripts/check-accessibility-bridge.py DIR...   # other roots, for its test
"""
from pathlib import Path
import re
import sys

PROJECT = Path(__file__).resolve().parents[1]
BRIDGE = Path('Sources/LocalVoice/AccessibilityBridge.swift')
# Bare identifiers, so a function reference or a call split after its name
# counts too; the framework's types are the only names left free.
CALLS = re.compile(r'\b(?:AXUIElement|AXObserver)\w*\b|\bAVSpeechSynthesisVoice\.speechVoices\b'
                   r'|\bAVSpeechSynthesisVoice(?:\.init)?\s*\(\s*identifier\s*:|\bNSSpeechSynthesizer\.availableVoices\b'
                   r'|\bNSSpeechSynthesizer\.attributes\s*\(\s*forVoice\s*:')
TYPES = {'AXUIElement', 'AXObserver', 'AXObserverCallback', 'AXObserverCallbackWithInfo'}
COMMENTS = re.compile(r'/\*.*?\*/|//[^\n]*', re.DOTALL)


def code(text):
    """The text with every comment blanked, line numbers kept."""
    return COMMENTS.sub(lambda match: re.sub(r'[^\n]', ' ', match.group()), text)


def strays(root):
    """(relative path, line number, call) for every call outside the bridge."""
    found = []
    for path in sorted(root.glob('Sources/**/*.swift')):
        relative = path.relative_to(root)
        if relative == BRIDGE:
            continue
        for number, line in enumerate(code(path.read_text()).splitlines(), 1):
            for match in CALLS.finditer(line):
                name = re.sub(r'\s*\(.*', '', match.group())
                if name not in TYPES:
                    found.append((str(relative), number, name))
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
