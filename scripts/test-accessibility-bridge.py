#!/usr/bin/env python3
"""Synthetic trees for check-accessibility-bridge.py. Compiles nothing."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().with_name('check-accessibility-bridge.py')
BRIDGE = Path('Sources/LocalVoice/AccessibilityBridge.swift')


def tree(files):
    root = Path(tempfile.mkdtemp(prefix='bridge-check-'))
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    return root


def run(root):
    result = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True)
    return result.returncode, result.stdout


BRIDGE_TEXT = 'enum AccessibilityBridge { static func read() { AXUIElementCopyAttributeValue(e, k, &v) } }\n'


class BridgeCheck(unittest.TestCase):
    def test_clean_tree_passes(self):
        root = tree({str(BRIDGE): BRIDGE_TEXT,
                     'Sources/LocalVoice/TextDelivery.swift': 'let a = AccessibilityBridge.attribute(e, k)\n'
                                                              '// AXUIElementCopyAttributeValue( in a comment is text\n'
                                                              'let r = AXValueGetType(v); let t = AXIsProcessTrusted()\n'
                                                              'let o = LiveDictationAXObserver(target: t)\n'})
        code, out = run(root)
        self.assertEqual((code, out.strip()), (0, 'Accessibility bridge OK'))

    def test_each_stray_call_is_named(self):
        root = tree({str(BRIDGE): BRIDGE_TEXT,
                     'Sources/LocalVoice/Stray.swift': 'let a = AXUIElementSetAttributeValue(e, k, v)\n'
                                                       'var o: AXObserver?; _ = AXObserverCreate(pid, cb, &o)\n'
                                                       'let v = AVSpeechSynthesisVoice.speechVoices()\n'
                                                       'let w = AVSpeechSynthesisVoice(identifier: id)\n'
                                                       'let s = NSSpeechSynthesizer.availableVoices\n'
                                                       'let x = NSSpeechSynthesizer.attributes(forVoice: s[0])\n',
                     'Sources/StageKit/Other.swift': 'let t = AXUIElementCreateApplication(pid) // not here\n'})
        code, out = run(root)
        self.assertEqual(code, 1)
        for line in ['Stray.swift:1: AXUIElementSetAttributeValue', 'Stray.swift:2: AXObserverCreate',
                     'Stray.swift:3: AVSpeechSynthesisVoice.speechVoices', 'Stray.swift:4: AVSpeechSynthesisVoice',
                     'Stray.swift:5: NSSpeechSynthesizer.availableVoices', 'Stray.swift:6: NSSpeechSynthesizer.attributes',
                     'Other.swift:1: AXUIElementCreateApplication']:
            self.assertIn(line, out)
        self.assertEqual(out.count('belongs in'), 7)

    def test_missing_bridge_fails(self):
        code, out = run(tree({'Sources/LocalVoice/A.swift': 'let a = 1\n'}))
        self.assertEqual(code, 1)
        self.assertIn('is missing', out)


if __name__ == '__main__':
    unittest.main()
