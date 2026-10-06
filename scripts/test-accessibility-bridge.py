#!/usr/bin/env python3
"""Synthetic trees for check-accessibility-bridge.py. Compiles nothing."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().with_name('check-accessibility-bridge.py')
BRIDGE = Path('Sources/LocalVoice/AccessibilityBridge.swift')
VOICES = Path('Sources/LocalVoice/ReadingVoices.swift')


def run(root):
    result = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True)
    return result.returncode, result.stdout


BRIDGE_TEXT = 'enum AccessibilityBridge { static func read() { AXUIElementCopyAttributeValue(e, k, &v) } }\n'
# The catalogue as #269 shaped it: both listings from plain frames, the
# lookup in a comment and a string, and a Task that lists nothing.
VOICES_TEXT = ('enum MacVoiceCatalog {\n'
               '    static func listed() -> [MacVoice] { AVSpeechSynthesisVoice.speechVoices().map(MacVoice.init) }\n'
               '    @MainActor static func sayVoices() -> [SayVoice] {\n'
               '        NSSpeechSynthesizer.availableVoices.map { NSSpeechSynthesizer.attributes(forVoice: $0) }\n'
               '    }\n'
               '    // `AVSpeechSynthesisVoice(identifier:)` constructs without a lookup\n'
               '    static let note = "Task { AVSpeechSynthesisVoice.speechVoices() } in a string is text"\n'
               '    static func refresh() { Task { @MainActor in apply(listed()) } }\n'
               '}\n')


class BridgeCheck(unittest.TestCase):
    def tree(self, files):
        """A synthetic Sources tree, removed when the test ends."""
        root = Path(tempfile.mkdtemp(prefix='bridge-check-'))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        for name, text in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        return root

    def test_clean_tree_passes(self):
        root = self.tree({str(BRIDGE): BRIDGE_TEXT, str(VOICES): VOICES_TEXT,
                     'Sources/LocalVoice/TextDelivery.swift': 'let a = AccessibilityBridge.attribute(e, k)\n'
                                                              '// AXUIElementCopyAttributeValue( in a comment is text\n'
                                                              'let r = AXValueGetType(v); let t = AXIsProcessTrusted()\n'
                                                              'let o = LiveDictationAXObserver(target: t)\n'
                                                              '/* AXObserverCreate(pid, cb, &o) in a block\n'
                                                              '   comment is text too */ var e: AXUIElement?\n'
                                                              'var ob: AXObserver?; let cb: AXObserverCallback = f\n',
                     # The app as #269 and the catalogue cache shaped it: the lookup from a
                     # plain frame, the listing on a GCD queue, a Task that applies a list
                     # read before it and hands out the cached voice object.
                     'Sources/LocalVoice/AppModel.swift': 'let v = AVSpeechSynthesisVoice(identifier: id) // the lookup is free here\n'
                                                          'DispatchQueue.global(qos: .utility).async { listed = MacVoiceCatalog.listed() }\n'
                                                          'let all = MacVoiceCatalog.installed(preferredLanguage: language)\n'
                                                          'Task { @MainActor in self.apply(listed); _ = MacVoiceCatalog.voice(identifier: id) }\n'
                                                          'Task.detached { say("Task { MacVoiceCatalog.installed() } in a string is text") }\n'
                                                          '_ = MacVoiceCatalog.sayVoices() // after the closures: a plain frame\n'})
        code, out = run(root)
        self.assertEqual((code, out.strip()), (0, 'Accessibility bridge OK'))

    def test_each_stray_element_call_is_named(self):
        root = self.tree({str(BRIDGE): BRIDGE_TEXT, str(VOICES): VOICES_TEXT,
                     'Sources/LocalVoice/Stray.swift': 'let a = AXUIElementSetAttributeValue(e, k, v)\n'
                                                       'var o: AXObserver?; _ = AXObserverCreate(pid, cb, &o)\n',
                     'Sources/LocalVoice/Reference.swift': 'let read = AXUIElementCopyAttributeValue\n'
                                                           'let value = AXUIElementCopyParameterizedAttributeValue\n'
                                                           '    (e, k, p, &v)\n',
                     'Sources/StageKit/Other.swift': 'let t = AXUIElementCreateApplication(pid) // not here\n'})
        code, out = run(root)
        self.assertEqual(code, 1)
        for line in ['Stray.swift:1: AXUIElementSetAttributeValue belongs in', 'Stray.swift:2: AXObserverCreate belongs in',
                     'Reference.swift:1: AXUIElementCopyAttributeValue belongs in',
                     'Reference.swift:2: AXUIElementCopyParameterizedAttributeValue belongs in',
                     'Other.swift:1: AXUIElementCreateApplication belongs in']:
            self.assertIn(line, out)
        self.assertEqual(out.count('belongs in'), 5)

    def test_voice_listings_outside_the_catalogue_are_named(self):
        root = self.tree({str(BRIDGE): BRIDGE_TEXT, str(VOICES): VOICES_TEXT,
                     'Sources/LocalVoice/Stray.swift': 'let v = AVSpeechSynthesisVoice.speechVoices()\n'
                                                       'let s = NSSpeechSynthesizer.availableVoices\n'
                                                       'let x = NSSpeechSynthesizer.attributes(forVoice: s[0])\n'
                                                       'let w = AVSpeechSynthesisVoice(identifier: id)\n'})
        code, out = run(root)
        self.assertEqual(code, 1)
        for line in ['Stray.swift:1: AVSpeechSynthesisVoice.speechVoices belongs in Sources/LocalVoice/ReadingVoices.swift',
                     'Stray.swift:2: NSSpeechSynthesizer.availableVoices belongs in',
                     'Stray.swift:3: NSSpeechSynthesizer.attributes belongs in']:
            self.assertIn(line, out)
        self.assertEqual(out.count('belongs in'), 3)

    def test_listing_inside_a_task_closure_is_named(self):
        root = self.tree({str(BRIDGE): BRIDGE_TEXT,
                     str(VOICES): 'enum MacVoiceCatalog {\n'
                                  '    static func refresh() {\n'
                                  '        Task.detached(priority: .utility) { [weak self] in\n'
                                  '            let voices = AVSpeechSynthesisVoice.speechVoices()\n'
                                  '            let names = NSSpeechSynthesizer.availableVoices.map { NSSpeechSynthesizer.attributes(forVoice: $0) }\n'
                                  '        }\n'
                                  '        Task { @MainActor in _ = AVSpeechSynthesisVoice(identifier: id) }\n'
                                  '        _ = AVSpeechSynthesisVoice.speechVoices() // after the closures: a plain frame\n'
                                  '    }\n'
                                  '}\n'})
        code, out = run(root)
        self.assertEqual(code, 1)
        for line in ['ReadingVoices.swift:4: AVSpeechSynthesisVoice.speechVoices runs inside a Task closure',
                     'ReadingVoices.swift:5: NSSpeechSynthesizer.availableVoices runs inside',
                     'ReadingVoices.swift:5: NSSpeechSynthesizer.attributes runs inside',
                     'ReadingVoices.swift:7: AVSpeechSynthesisVoice runs inside']:
            self.assertIn(line, out)
        self.assertEqual(out.count('runs inside'), 4)
        self.assertNotIn(':8:', out)

    def test_catalogue_calls_inside_a_task_closure_anywhere_are_named(self):
        # The flood's own shape: the installed app listed the catalogue from a
        # detached task on every return to the front.
        root = self.tree({str(BRIDGE): BRIDGE_TEXT, str(VOICES): VOICES_TEXT,
                          'Sources/LocalVoice/AppModel.swift': 'func refresh() {\n'
                                                               '    Task.detached(priority: .utility) { [weak self] in\n'
                                                               '        let voices = MacVoiceCatalog.installed(preferredLanguage: language)\n'
                                                               '        await self?.apply(voices)\n'
                                                               '    }\n'
                                                               '    Task { @MainActor in apply(MacVoiceCatalog.listed(preferredLanguage: language),\n'
                                                               '                                sayVoices: MacVoiceCatalog.sayVoices()) }\n'
                                                               '    _ = MacVoiceCatalog.installed() // after the closures: a plain frame\n'
                                                               '}\n',
                          'Sources/LocalVoice/MacSpeechRenderer.swift': 'Task { let w = AVSpeechSynthesisVoice(identifier: id) }\n'
                                                                        'let v = AVSpeechSynthesisVoice(identifier: id)\n',
                          'Sources/StageKit/Other.swift': 'Task.detached { _ = AVSpeechSynthesisVoice.speechVoices() }\n'})
        code, out = run(root)
        self.assertEqual(code, 1)
        for line in ['AppModel.swift:3: MacVoiceCatalog.installed runs inside a Task closure; list voices from a plain frame or a GCD queue',
                     'AppModel.swift:6: MacVoiceCatalog.listed runs inside',
                     'AppModel.swift:7: MacVoiceCatalog.sayVoices runs inside',
                     'MacSpeechRenderer.swift:1: AVSpeechSynthesisVoice runs inside',
                     'Other.swift:1: AVSpeechSynthesisVoice.speechVoices belongs in Sources/LocalVoice/ReadingVoices.swift']:
            self.assertIn(line, out)
        self.assertEqual(out.count('runs inside'), 4)
        self.assertEqual(out.count('belongs in'), 1)
        self.assertNotIn('AppModel.swift:8:', out)
        self.assertNotIn('MacSpeechRenderer.swift:2:', out)

    def test_missing_doors_fail(self):
        code, out = run(self.tree({'Sources/LocalVoice/A.swift': 'let a = 1\n'}))
        self.assertEqual(code, 1)
        self.assertIn('AccessibilityBridge.swift is missing', out)
        self.assertIn('ReadingVoices.swift is missing', out)


if __name__ == '__main__':
    unittest.main()
