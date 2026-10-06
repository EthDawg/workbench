#!/usr/bin/env python3
"""Keep the Accessibility framework behind its two doors.

Element IPC (AXUIElement*) and observers (AXObserver*) belong in
`AccessibilityBridge.swift`, the one place that calls them, so a check or a
later measurement sees every call go through it. The types AXUIElement,
AXObserver and AXObserverCallback, the AXValue helpers and AXIsProcessTrusted
stay free: they do not message another process.

The voice listings (AVSpeechSynthesisVoice.speechVoices, NSSpeechSynthesizer's
voice list and attributes) belong in `ReadingVoices.swift`, under the rule #269
established: on macOS 26 they log an AXCommon fault, "unsafeForcedSync called
from Swift Concurrent context", for every voice when they run on a Swift
task's thread, main actor or detached; the installed app logged more than
126,000 of them in a week that way, from `MacVoiceCatalog.installed()` in a
`Task.detached` closure. `MacVoiceCatalog` reads them from a plain frame or a
GCD queue, so in any file a `Task {` or `Task.detached {` closure that calls a
listing, `MacVoiceCatalog.listed()`, `installed()` or `sayVoices()`, or the
voice-by-identifier initializer `AVSpeechSynthesisVoice(identifier:)`, fails
(the closure body is brace-tracked; a call after it is a plain frame). Outside
a Task closure the identifier initializer stays free: it constructs an
installed voice from its identifier without a lookup, and
`MacVoiceCatalog.voice(identifier:)` hands out the listed object without even
that. Comments, line and block, and string literals are not code.

    python3 scripts/check-accessibility-bridge.py          # the repository
    python3 scripts/check-accessibility-bridge.py DIR...   # other roots, for its test
"""
from pathlib import Path
import re
import sys

PROJECT = Path(__file__).resolve().parents[1]
BRIDGE = Path('Sources/LocalVoice/AccessibilityBridge.swift')
VOICES = Path('Sources/LocalVoice/ReadingVoices.swift')
# Bare identifiers, so a function reference or a call split after its name
# counts too; the framework's types are the only names left free.
ELEMENT_CALLS = re.compile(r'\b(?:AXUIElement|AXObserver)\w*\b')
TYPES = {'AXUIElement', 'AXObserver', 'AXObserverCallback', 'AXObserverCallbackWithInfo'}
LISTINGS = re.compile(r'\bAVSpeechSynthesisVoice\.speechVoices\b|\bNSSpeechSynthesizer\.availableVoices\b'
                      r'|\bNSSpeechSynthesizer\.attributes\s*\(\s*forVoice\s*:')
LOOKUP = re.compile(r'\bAVSpeechSynthesisVoice(?:\.init)?\s*\(\s*identifier\s*:')
CATALOGUE = re.compile(r'\bMacVoiceCatalog\.(?:listed|installed|sayVoices)\s*\(')
TASK = re.compile(r'\bTask(?:\.detached)?\s*(?:\([^)]*\))?\s*\{')
TASK_REASON = 'runs inside a Task closure; list voices from a plain frame or a GCD queue'
COMMENTS = re.compile(r'/\*.*?\*/|//[^\n]*', re.DOTALL)
STRINGS = re.compile(r'"""[\s\S]*?"""|"(?:\\.|[^"\\\n])*"')


def blank(match):
    return re.sub(r'[^\n]', ' ', match.group())


def code(text):
    """The text with every comment and string literal blanked, line numbers kept."""
    return STRINGS.sub(blank, COMMENTS.sub(blank, text))


def name(match):
    return re.sub(r'\s*\(.*', '', match.group())


def line_of(text, position):
    return text.count('\n', 0, position) + 1


def task_closures(text):
    """(start, end) of every `Task {` / `Task.detached {` closure body in blanked code."""
    spans = []
    for match in TASK.finditer(text):
        depth, start = 0, match.end() - 1
        for position in range(start, len(text)):
            if text[position] == '{':
                depth += 1
            elif text[position] == '}':
                depth -= 1
                if depth == 0:
                    spans.append((start, position))
                    break
        else:
            spans.append((start, len(text)))
    return spans


def strays(root):
    """(relative path, line number, call, why) for every call outside its door or inside a Task closure."""
    found = []
    for path in sorted(root.glob('Sources/**/*.swift')):
        relative = path.relative_to(root)
        text = code(path.read_text())
        if relative != BRIDGE:
            for match in ELEMENT_CALLS.finditer(text):
                if name(match) not in TYPES:
                    found.append((str(relative), line_of(text, match.start()), name(match), f'belongs in {BRIDGE}'))
        closures = task_closures(text)

        def in_task(match):
            return any(start <= match.start() <= end for start, end in closures)

        for match in LISTINGS.finditer(text):
            if relative != VOICES:
                found.append((str(relative), line_of(text, match.start()), name(match), f'belongs in {VOICES}'))
            elif in_task(match):
                found.append((str(relative), line_of(text, match.start()), name(match), TASK_REASON))
        for pattern in (CATALOGUE, LOOKUP):
            for match in pattern.finditer(text):
                if in_task(match):
                    found.append((str(relative), line_of(text, match.start()), name(match), TASK_REASON))
    return found


def main(roots):
    failed = False
    for root in roots:
        missing = [door for door in (BRIDGE, VOICES) if not (root / door).exists()]
        for door in missing:
            print(f'{root}: {door} is missing')
        found = strays(root) if not missing else []
        for path, number, call, reason in found:
            print(f'{path}:{number}: {call} {reason}')
        failed = failed or bool(found) or bool(missing)
    if failed:
        return 1
    print('Accessibility bridge OK')
    return 0


if __name__ == '__main__':
    sys.exit(main([Path(argument) for argument in sys.argv[1:]] or [PROJECT]))
