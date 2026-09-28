#!/usr/bin/env python3
"""Check Workbench's entry points against docs/surfaces.json.

An entry point starts a capability, opens a place or page, or changes a setting
that reaches beyond one page (docs/workbench.md#grammar, rule 8). A new or
renamed one needs a deliberate registry change classified under the Grammar.
The check finds changes; people decide taste.

Scope: ENTRY_POINTS, CATALOGUES and offers. That is the quick panel (header,
capability rows, each row's shortcut key and options, status rows, footer and
views embedded in it); the Draw, Present, Persona and Timer menus that the
rows, the floating toolbar and the app menu bar open, with any native views
embedded in them, and the Saved Prompts picker the toolbar opens; the
floating toolbar's modes (its launcher's chooser), next action and hover
labels, accessory and More menu, and the live dictation, narration and
reading controls shown in the same window; the app menu bar and any status
item menu built in AppDelegate; the window sidebar; every control on Home and on the
Settings page, including views embedded in them; the global shortcut
catalogue; proactive offers, found as types named *Offer* or *Cue plus
OFFER_TYPES; a capability page's own options (mode 'options' below), since a
setting that reaches beyond one page counts wherever it appears; and a
capability page's doors (mode 'doors'), controls whose action leaves the page
for a place or another page. Headings and status lines on Home and Settings are
not entries. Controls that act only on a page's own content are out, and so are
the inline shortcut editors in EXCLUDED: the shortcut catalogue records those
shortcuts.

Entries: an ID joins module, file, enclosing type, control API and the literal
label, or a hash of a runtime label's source expression. Quick panel IDs also
name the panel area, and catalogues use their case or shortcut id. IDs carry
no line numbers or helper names, so reordering, comments and extracting a
helper do not change them, and a control keeps its ID whether its label is an
argument or a Text or Label inside it. Identical repeated definitions get
occurrence suffixes. A literal rename is a new entry plus a stale one; a
catalogue rename keeps its ID and reports a change. A runtime label is recorded
as its source expression with label null, never as guessed text.

Lists: an item that shows its own title from an enum (Enum.allCases) is
recorded once per enum, wherever it appears. An item worded around an enum
case or a literal list element, such as "Open \(app.title)" or
"\(minutes) min", becomes one entry per case or element. Items generated from
runtime content (the person's scenes, personas, prompts or devices) are rows,
and the menu or picker holding them is the entry, but fixed actions inside
such a loop are entries. A disabled item without an action is a note. A label
that a helper receives as a String parameter belongs to the helper's call
sites.

Registry: every entry needs a kind and belongsTo. --update adds new or changed
entries as unclassified, so the check fails until someone classifies them, and
removes stale ones; reviewed fields survive only while the source facts match.
aliasOf declares an intentional alternative or repeated label and needs a note.
Other exact labels shared by different owners fail as a collision; runtime
expressions are not compared as text.

Limits: this is a small Swift lexer with targeted extractors, not a compiler
or a reachability analysis, so it also inventories definitions behind
conditions. A new kind of entry point (another menu builder, a status menu
outside AppDelegate, an offer named differently, a new label-taking helper,
localized or generated labels) needs ENTRY_POINTS, OFFER_TYPES or the
extractors updated. A moved or renamed owner fails as missing instead of
passing silently. Moving a definition to another file or type changes its ID,
and a stale entry can mean the check stopped recognising a control, so confirm
it is gone before removing it. The registry is not proof of installed
acceptance or of Ethan's approval.

--root measures another source tree against this checkout's registry,
--registry selects another registry and --json prints entries and errors.
scripts/test-check-surfaces.py holds the fixtures; neither script builds or
launches the app.
"""

import argparse
from collections import Counter, defaultdict
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import sys

REPO = Path(__file__).resolve().parents[1]
MODULES = ('LocalVoice', 'StageKit', 'ToolbarCore', 'ToolbarKit')
OWNERS = set('dictate snap snapAndTalk read draw present persona timer history library settings app'.split())
KINDS = set('capability workflow option action place setting status'.split())
GUIDANCE = ("Workbench keeps a small grammar (docs/workbench.md#grammar). "
            "Before adding an entry: can this be Quality (no new entry) or an Option "
            "inside one capability's own options? A new capability, named workflow or "
            "place needs Ethan's decision. Record the result in docs/surfaces.json "
            "(python3 scripts/check-surfaces.py --update adds it as unclassified).")

# (file under Sources, type or function that builds it, surface, what counts)
#   panel     every labelled control; runtime Text and standalone Labels are
#             status rows; embedded SwiftUI and native views count
#   controls  every labelled control and menu item, and embedded native views
#   page      every labelled control except headings and status lines, and
#             embedded SwiftUI and native views
#   options   on a capability page, only a Toggle, Picker or Stepper bound to a
#             persistent preference (the preferences model, @AppStorage or
#             UserDefaults) and the choices under it; nothing is followed
#   doors     on a capability page, only a Button or Link whose action changes
#             the route (page =), opens a place (a bare open(...), ROUTES) or
#             calls a closure the host injected into the view; nothing is followed
ENTRY_POINTS = [
    ('LocalVoice/WorkbenchQuickPanel.swift', 'WorkbenchQuickPanel', 'quick panel', 'panel'),
    # More: the tool's options, the work running elsewhere and the toolbar's own items (#134).
    ('LocalVoice/FloatingToolbar.swift', 'FloatingToolbar', 'floating toolbar More menu', 'controls'),
    # Position… in that menu opens the toolbar's placement control (#163).
    ('LocalVoice/ToolbarPositionControl.swift', 'ToolbarPositionControl', 'floating toolbar position control', 'controls'),
    # The same window's live controls: the no-speech cue, and a result's own controls, which the
    # toolbar reveals in place of its row (#134 T4). Recording, narration and reading are the row's.
    ('LocalVoice/FloatingToolbar.swift', 'WorkbenchFloatingContent', 'floating toolbar live controls', 'page'),
    ('LocalVoice/FloatingToolbar.swift', 'FloatingResultView', 'floating toolbar live controls', 'page'),
    ('StageKit/AnnotationMenu.swift', 'AnnotationMenu', 'Draw menu', 'controls'),
    ('StageKit/DemoScenes.swift', 'DemoScenes.makeControlsMenu', 'Present menu', 'controls'),
    ('StageKit/DemoPresentation.swift', 'DemoPresentation.makeControlsMenu', 'Present menu', 'controls'),
    ('StageKit/StageKitController.swift', 'StageKitController.makePersonaMenu', 'Persona menu', 'controls'),
    ('StageKit/Persona.swift', 'PersonaLibrary.makeControlsMenu', 'Persona menu', 'controls'),
    ('StageKit/StageKitController.swift', 'StageKitController.makeTimerMenu', 'Timer menu', 'controls'),
    ('LocalVoice/PromptPicker.swift', 'PromptPickerView', 'Saved Prompts picker', 'controls'),
    ('LocalVoice/main.swift', 'AppDelegate', 'app menu bar', 'controls'),
    ('LocalVoice/WorkbenchHome.swift', 'WorkbenchHome.settings', 'settings page', 'page'),
    ('LocalVoice/WorkbenchHome.swift', 'WorkbenchHome.welcome', 'window home', 'page'),
    # The window's own controls around the pages: the sidebar column.
    ('LocalVoice/WorkbenchHome.swift', 'WorkbenchHome.body', 'window sidebar', 'controls'),
    # Capability pages own their options (Grammar: options live with their
    # capability). The page body is scanned in mode 'options', so its transient
    # controls (editor buttons, selection, the current draft) stay out while a
    # new persistent preference on it is found. The page's options area is an
    # ordinary page surface: its buttons are doors or setting actions, as on
    # Settings, and the views it embeds (VoiceOptions) are followed.
    ('LocalVoice/Views.swift', 'ContentView.dictate', 'dictate page options', 'options'),
    ('LocalVoice/Views.swift', 'ContentView.dictateOptions', 'dictate page options', 'page'),
    # Capability pages also carry doors (rule 8: opens a place or page, wherever
    # it appears). Mode 'doors' keeps the page's own actions (editor, selection,
    # copy, save) out. A closure the host injects, such as ReadbackView's
    # onOpenPacks, counts because the page cannot know where it leads.
    ('LocalVoice/Views.swift', 'ContentView.dictate', 'dictate page', 'doors'),
    ('LocalVoice/MeetingWorkspaceView.swift', 'MeetingWorkspaceView', 'meeting page', 'doors'),
    ('LocalVoice/ReadbackView.swift', 'ReadbackView', 'snap & talk page', 'doors'),
    ('LocalVoice/SnapWorkspaceView.swift', 'SnapWorkspaceView', 'snap page', 'doors'),
    # History is one page made of several views: its header, the transcript,
    # Snap and task rows, a task's frozen inputs, the shared selection footer
    # and the details sheet a transcript opens. Connections in the header opens
    # the provider settings over History, so the header is an ordinary page
    # surface and its button is recorded.
    ('LocalVoice/HistoryView.swift', 'HistoryView', 'history page', 'doors'),
    ('LocalVoice/HistoryView.swift', 'HistoryView.header', 'history page', 'page'),
    ('LocalVoice/HistoryView.swift', 'HistorySnapRow', 'history page', 'doors'),
    ('LocalVoice/HistoryView.swift', 'HistoryMadeFrom', 'history page', 'doors'),
    ('LocalVoice/HistoryView.swift', 'HistoryInputChip', 'history page', 'doors'),
    ('LocalVoice/CaptureHistoryView.swift', 'TranscriptHistoryRow', 'history page', 'doors'),
    ('LocalVoice/HistorySelectionControls.swift', 'HandoffJobCard', 'history page', 'doors'),
    ('LocalVoice/HistorySelectionControls.swift', 'HistorySelectionControls', 'history page', 'doors'),
    ('LocalVoice/HistorySelectionControls.swift', 'TranscriptMetadataEditor', 'history page', 'doors'),
    ('LocalVoice/DemoLibraryView.swift', 'DemoLibraryView', 'library page', 'doors'),
]
# Calls that change the window's route or open a place (mode 'doors').
# openHistory opens History with a door's starting view; openTranscript opens
# a transcript on the Dictate page; importReading opens text on the Read page
# through its import decision.
ROUTES = {'navigate', 'onShowEditor', 'showHistory', 'showLibrary', 'showControls', 'openHistory', 'openTranscript', 'importReading'}
# Inline shortcut editors: the global shortcut catalogue records these shortcuts.
EXCLUDED = {'LocalVoice/WorkbenchQuickPanel.swift': ['WorkbenchQuickPanel.shortcutEditor'],
            'LocalVoice/QuickControls.swift': ['ShortcutControl', 'ShortcutKeycap']}
# Catalogue owners that must exist; their extractors are below.
CATALOGUES = [
    ('LocalVoice/WorkbenchControlTool.swift', 'WorkbenchControlState.actionTitle'),
    ('ToolbarCore/ToolbarViewState.swift', 'ToolbarMode'),
    ('ToolbarCore/ToolbarViewState.swift', 'ToolbarViewState'),
    ('StageKit/Settings.swift', 'Action'),
    ('LocalVoice/main.swift', 'AppDelegate.voiceShortcutEntries'),
    ('LocalVoice/WorkbenchHome.swift', 'WorkbenchHome'),
    # The floating toolbar's next action, one title per operation and start verb.
    ('ToolbarCore/ToolbarNextAction.swift', 'ToolbarNextAction.title'),
]
OFFER_NAME = re.compile(r'\b(?:struct|class)\s+(\w*Offer\w*|\w+Cue)\b')
OFFER_TYPES = ['FounderIntroductionCard']
# Choice lists with their own stable IDs and surface.
ROWS = {'WorkbenchControlTool': ('quick-panel.row.', 'quick panel rows')}

# CapturePreviewButton is a capture image that opens the read-only preview; its
# first argument is its accessible name.
CONTROLS = set('''Button Toggle Picker Menu Label ColorPicker TextField SecureField
    Stepper Slider Link NativeControlMenu ToolbarMenuAction StageMenuAction
    NSMenuItem NSButton addItem addSubmenu card command actionItem action CapturePreviewButton'''.split())
# Label-taking helpers, counted only in the file that declares them.
HELPERS = {'card', 'command', 'actionItem', 'action'}
IDENT = r'[A-Za-z_$][\w$]*'
KEYWORDS = set('''return in let var case try await if guard else where for while
    switch throw defer do catch is as some any'''.split())


@dataclass
class Token:
    value: str
    start: int
    end: int


def lex(source):
    """Keep Swift strings intact, including nested interpolation and comments."""
    def string_end(start):
        match = re.match(r'(#+)?("""|")', source[start:])
        hashes, quote = match.group(1) or '', match.group(2)
        pos = start + len(match.group())
        close = quote + hashes
        escape = '\\' + hashes
        while pos < len(source):
            if source.startswith(close, pos):
                return pos + len(close)
            if source.startswith(escape + '(', pos):
                depth = 1
                pos += len(escape) + 1
                while pos < len(source) and depth:
                    if re.match(r'#*"', source[pos:]):
                        pos = string_end(pos)
                        continue
                    if source[pos] == '(':
                        depth += 1
                    elif source[pos] == ')':
                        depth -= 1
                    pos += 1
            elif source.startswith(escape, pos):
                pos += len(escape) + 1
            else:
                pos += 1
        raise ValueError('Unterminated Swift string')

    result, pos = [], 0
    while pos < len(source):
        if source[pos].isspace():
            pos += 1
            continue
        if source.startswith('//', pos):
            end = source.find('\n', pos)
            pos = len(source) if end < 0 else end
            continue
        if source.startswith('/*', pos):
            depth = 1
            pos += 2
            while pos < len(source) and depth:
                if source.startswith('/*', pos):
                    depth += 1
                    pos += 2
                elif source.startswith('*/', pos):
                    depth -= 1
                    pos += 2
                else:
                    pos += 1
            continue
        start = pos
        if re.match(r'#*"', source[pos:]):
            pos = string_end(pos)
        else:
            match = re.match(r'[A-Za-z_$][\w$]*|\d+(?:\.\d+)?|->|\?\?|==|!=', source[pos:])
            pos += len(match.group()) if match else 1
        result.append(Token(source[start:pos], start, pos))
    return result


def literal(tokens):
    if len(tokens) != 1:
        return None
    value = tokens[0].value
    match = re.fullmatch(r'(#+)?"(.*?)"\1', value, re.S) if value.startswith('#') else None
    if match:
        return None if '\\' + match.group(1) + '(' in value else match.group(2)
    if not value.startswith('"') or '\\(' in value or value.startswith('"""'):
        return None
    try:
        return json.loads(value)
    except ValueError:
        return None


def expression(tokens):
    # Whitespace/comments outside literals are immaterial. Keep literal bytes.
    return ' '.join(t.value for t in tokens)


def slug(value):
    return re.sub(r'[^a-z0-9]+', '-', value.lower()).strip('-')[:70] or 'empty'


def simple(tokens):
    """An item's own title inside a loop: x, x.title or $0.rawValue."""
    return bool(re.fullmatch(IDENT + r'(?: \. ' + IDENT + ')?', expression(tokens)))


def references(tokens, names):
    """Does a label use one of a loop's names, directly or interpolated?"""
    for n, token in enumerate(tokens):
        if token.value in names and (n == 0 or tokens[n - 1].value != '.'):
            return True
        if token.value[:1] == '"' and any(re.search(r'\\\(\s*' + re.escape(name) + r'\b', token.value) for name in names):
            return True
    return False


def template(tokens, names):
    """A string worded around the item alone: "\\(x) min", "Open \\(x.title)"."""
    if len(tokens) != 1 or not tokens[0].value.startswith('"') or tokens[0].value.startswith('"""'):
        return None
    parts = re.split(r'\\\(\s*([\w$]+)\s*(?:\.\s*(\w+)\s*)?\)', tokens[0].value[1:-1])
    texts, slots = parts[0::3], list(zip(parts[1::3], parts[2::3]))
    if not slots or any('\\(' in text for text in texts) or any(name not in names for name, _ in slots):
        return None
    try:
        return [json.loads('"' + text + '"') for text in texts], slots
    except ValueError:
        return None


def fill(form, values):
    texts, _ = form
    return ''.join(text + value for text, value in zip(texts, values)) + texts[-1]


class Swift:
    def __init__(self, path, source):
        self.path, self.source = path, source
        parts = Path(path).parts
        self.module, self.stem = parts[-2], Path(path).stem
        self.tokens = lex(source)
        self.v = [t.value for t in self.tokens]
        self.pairs, self.openers, stack = {}, {}, []
        for i, value in enumerate(self.v):
            if value in ('(', '[', '{'):
                stack.append(i)
            elif value in (')', ']', '}'):
                if not stack or self.v[stack[-1]] != {')': '(', ']': '[', '}': '{'}[value]:
                    raise ValueError(f'{path}: unbalanced Swift delimiters')
                start = stack.pop()
                self.pairs[start], self.openers[i] = i, start
        if stack:
            raise ValueError(f'{path}: unbalanced Swift delimiters')
        # (body start, body end, kind, name, declaration keyword index)
        self.scopes = []
        for i, value in enumerate(self.v[:-1]):
            if value not in ('struct', 'class', 'enum', 'extension', 'func', 'var'):
                continue
            if not re.fullmatch(r'\w+', self.v[i + 1]):
                continue
            j = i + 2
            while j < len(self.v) and self.v[j] not in ('{', '}', ';', '=', '@', 'var', 'let', 'func', 'struct', 'class', 'enum', 'extension'):
                if self.v[j] in ('(', '['):
                    j = self.pairs[j] + 1
                else:
                    j += 1
            if j < len(self.v) and self.v[j] == '{':
                self.scopes.append((j, self.pairs[j], value, self.v[i + 1], i))

    def context(self, index):
        return '.'.join(s[3] for s in self.scopes if s[0] < index < s[1]) or 'file'

    def type_context(self, index):
        return '.'.join(s[3] for s in self.scopes
                        if s[2] in ('struct', 'class', 'enum', 'extension') and s[0] < index < s[1]) or 'file'

    def find(self, path):
        """Scopes whose dotted path is `path` or ends with it."""
        found = []
        for scope in self.scopes:
            full = '.'.join(s[3] for s in self.scopes if s[0] < scope[0] < s[1]) + '.' + scope[3]
            if ('.' + full.strip('.')).endswith('.' + path):
                found.append(scope)
        return found

    def args(self, start):
        """Split an argument list without mistaking closure commas for separators."""
        end = self.pairs[start]
        parts, begin, i = [], start + 1, start + 1
        while i < end:
            if self.v[i] in ('(', '[', '{'):
                i = self.pairs[i] + 1
            elif self.v[i] == ',':
                parts.append(self.tokens[begin:i])
                begin = i = i + 1
            else:
                i += 1
        if begin < end:
            parts.append(self.tokens[begin:end])
        return parts

    def calls(self, names):
        for i, name in enumerate(self.v[:-1]):
            if name in names and self.v[i + 1] == '(' and (i == 0 or self.v[i - 1] != 'func'):
                yield i, name, self.args(i + 1), self.pairs[i + 1]

    def string_parameters(self, index):
        """String parameters of the innermost function around index."""
        funcs = [s for s in self.scopes if s[2] == 'func' and s[0] < index < s[1]]
        if not funcs:
            return set()
        keyword = max(funcs, key=lambda s: s[0])[4]
        j = keyword + 2
        if self.v[j] == '<':
            while self.v[j] != '(':
                j += 1
        if self.v[j] != '(':
            return set()
        names = set()
        for param in self.args(j):
            values = [t.value for t in param]
            if ':' in values:
                colon = values.index(':')
                if colon and values[colon + 1:colon + 2] == ['String']:
                    names.add(values[colon - 1])
        return names


def named_arg(args, name):
    return next((arg[2:] for arg in args if len(arg) > 1 and arg[0].value == name and arg[1].value == ':'), None)


def enum_cases(swift, start, end):
    cases = {}
    for i in range(start + 1, end):
        if swift.v[i] != 'case' or swift.v[i + 1] == '.':
            continue
        # Only enum declarations, not cases in its computed properties.
        if any(a > start and a < i < b for a, b, _, _, _ in swift.scopes):
            continue
        j = i + 1
        while j < end and re.fullmatch(r'\w+', swift.v[j]):
            name = swift.v[j]
            cases[name] = (j, name)
            j += 1
            if swift.v[j] == '=':
                cases[name] = (j - 1, literal([swift.tokens[j + 1]]) or name)
                j += 2
            if swift.v[j] != ',':
                break
            j += 1
    return cases


def case_returns(swift, start, end):
    result = {}
    for i in range(start, end):
        if swift.v[i] != 'case' or swift.v[i + 1] != '.':
            continue
        j, names = i + 1, []
        while j < end and swift.v[j] != ':':
            if swift.v[j] == '.':
                names.append(swift.v[j + 1])
            j += 1
        j += 1
        if swift.v[j] == 'return':
            j += 1
        k = j  # The whole case body, including nested blocks.
        while k < end and swift.v[k] not in ('case', 'default', '}', ';'):
            k = swift.pairs[k] + 1 if swift.v[k] in ('(', '[', '{') else k + 1
        for name in names:
            result[name] = swift.tokens[j:k]
    return result


def evaluate(tokens, case, raw):
    """Resolve the few title forms Workbench uses; anything else stays runtime."""
    text = expression(tokens)
    if literal(tokens) is not None:
        return literal(tokens)
    if text == 'rawValue':
        return raw
    if text == 'rawValue . capitalized':
        return raw[:1].upper() + raw[1:].lower()
    match = re.fullmatch(r'(self == \. (\w+)|rawValue == ("(?:[^"\\]|\\.)*")) \? ("(?:[^"\\]|\\.)*") : (.+)', text)
    if match:
        hit = case == match[2] if match[2] else raw == json.loads(match[3])
        return json.loads(match[4]) if hit else evaluate(lex(match[5]), case, raw)
    return None


def choice_labels(swift, start, end, member):
    """Case -> (label or None, expression) for an enum, as `member` shows it."""
    cases = enum_cases(swift, start, end)
    prop = None
    if member != 'rawValue':
        prop = next(((a, b) for a, b, kind, name, _ in swift.scopes
                     if kind == 'var' and name == member and start < a < b < end), None)
    returns = case_returns(swift, *prop) if prop else {}
    result = {}
    for case, (_, raw) in cases.items():
        if not prop:
            result[case] = (raw, None)
            continue
        tokens = returns.get(case)
        if tokens is None:
            body = swift.tokens[prop[0] + 1:prop[1]]
            # A switch default or one shared expression.
            default = re.search(r'default : (?:return )?(.+?)(?: \})?$', expression(body))
            tokens = lex(default[1]) if default and 'switch' in expression(body) else body
        label = evaluate(tokens, case, raw)
        result[case] = (label, None if label is not None else expression(tokens))
    return result


class Tree:
    """Lazily lexed Mac module sources, with a raw-text index for lookups."""
    def __init__(self, root):
        self.root = root
        self.paths = sorted(p for module in MODULES for p in (root / 'Sources' / module).glob('*.swift'))
        self.texts = {p: p.read_text() for p in self.paths}
        self.parsed = {}

    def swift(self, path):
        if path not in self.parsed:
            self.parsed[path] = Swift(path.relative_to(self.root).as_posix(), self.texts[path])
        return self.parsed[path]

    def file(self, relative):
        path = self.root / 'Sources' / relative
        return self.swift(path) if path in self.texts else None

    def declaring(self, kind, name, near=None):
        """Files declaring `kind name` (kind is a regex such as struct|class), the referencing module first."""
        if not hasattr(self, '_declared'):
            self._declared = {}
            for p in self.paths:
                for m in re.finditer(r'\b(struct|class|enum)\s+(\w+)', self.texts[p]):
                    self._declared.setdefault((m[1], m[2]), []).append(p)
        paths = {p for k in ('struct', 'class', 'enum') if re.fullmatch(kind, k) for p in self._declared.get((k, name), [])}
        return sorted(paths, key=lambda p: (p.parent.name != near, str(p)))

    def views(self, native):
        """Names of SwiftUI views, or of AppKit views, declared in the modules."""
        key = '_native' if native else '_swiftui'
        if not hasattr(self, key):
            pattern = re.compile(r'\b(struct|class)\s+(\w+)\s*:\s*([^{]*)\{')
            kinds = r'\b(NS\w*View|NSControl|NSButton)\b' if native else r'\b(View|NSViewRepresentable)\b'
            setattr(self, key, {m[2]: m[1] for p in self.paths for m in pattern.finditer(self.texts[p])
                                if (m[1] == 'class') == native and re.search(kinds, m[3].split(',')[0] if native else m[3])})
        return getattr(self, key)


class Inventory:
    def __init__(self, tree, strict):
        self.tree, self.strict = tree, strict
        self.entries, self.visited, self.enums = [], set(), {}

    def owner(self, relative, scope, kinds=None):
        """The file and the ranges of `scope` in it. Missing owners fail loudly."""
        swift = self.tree.file(relative)
        found = [s[:2] for s in swift.find(scope) if kinds is None or s[2] in kinds] if swift else []
        if not found and self.strict:
            raise ValueError(f'Missing surface owner: Sources/{relative} {scope}. Check --root, or update '
                             'ENTRY_POINTS or CATALOGUES in scripts/check-surfaces.py after a move or rename.')
        return swift, found

    def add(self, swift, index, api, tokens, surface, identity=None, **metadata):
        label = literal(tokens)
        expr = expression(tokens)
        context = swift.type_context(index)
        if swift.stem == 'WorkbenchQuickPanel' and context.startswith('WorkbenchQuickPanel'):
            context += '.' + slug(surface)  # The panel's areas are separate surfaces.
        key = identity or (slug(label) if label is not None else 'runtime-' + hashlib.sha256(expr.encode()).hexdigest()[:12])
        entry = {'id': f'{swift.module}.{swift.stem}.{context}.{api}.{key}', 'surface': surface, 'label': label, **metadata}
        if label is None:
            entry['expression'] = expr
            entry['note'] = 'Runtime label from ' + expr + '; no rendered text assumed.'
        self.entries.append(entry)

    # Loops over enums or literal lists: choices are recorded from the list.
    def iterations(self, swift, inside):
        v = swift.v
        for i, value in enumerate(v):
            if not inside(i):
                continue
            body = collection = var = None
            if value == 'ForEach' and v[i + 1:i + 2] == ['('] and v[i - 1] != '.':
                close = swift.pairs[i + 1]
                args = swift.args(i + 1)
                if args and v[close + 1:close + 2] == ['{']:
                    first = swift.tokens.index(args[0][0])
                    collection, body = (first, first + len(args[0])), (close + 1, swift.pairs[close + 1])
            elif value == 'for' and v[i - 1] not in ('.', '(', ',') and ':' not in v[i + 1:i + 3]:
                j = i + 1  # A loop, not the `for` argument label in f(for x: T).
                while j < len(v) and v[j] not in ('in', '{', '}', ')'):
                    j = swift.pairs[j] + 1 if v[j] in ('(', '[') else j + 1
                k = j + 1
                while k < len(v) and v[k] not in ('{', 'where', '}', ')'):
                    k = swift.pairs[k] + 1 if v[k] in ('(', '[') else k + 1
                collection, var = (j + 1, k), [t for t in v[i + 1:j] if re.fullmatch(IDENT, t)]
                while k < len(v) and v[k] not in ('{', '}', ')'):
                    k += 1
                if v[j:j + 1] != ['in'] or v[k:k + 1] != ['{']:
                    continue
                body = (k, swift.pairs[k])
            elif value == '.' and v[i + 1:i + 2] and v[i + 1] in ('map', 'forEach', 'compactMap', 'flatMap'):
                k = i + 2
                if v[k:k + 1] == ['('] and v[k + 1:k + 2] == ['{']:
                    k += 1
                if v[k:k + 1] != ['{']:
                    continue
                j, start = i - 1, i
                while j >= 0:
                    if v[j] in (')', ']'):
                        j = swift.openers[j]
                        start, j = j, j - 1
                        if j >= 0 and v[j] not in KEYWORDS and (re.fullmatch(IDENT, v[j]) or v[j] in (')', ']')):
                            continue
                    elif re.fullmatch(IDENT, v[j]) and v[j] not in KEYWORDS:
                        start, j = j, j - 1
                    else:
                        break
                    if j >= 0 and v[j] == '.':
                        j -= 1
                        continue
                    break
                collection, body = (start, i), (k, swift.pairs[k])
            if body is None:
                continue
            if var is None:
                head = v[body[0] + 1:body[1]]
                var = [t for t in head[:head.index('in')] if re.fullmatch(IDENT, t)] if 'in' in head[:8] else []
            # Names bound in the loop body (guard let action = ...) also stand for the item.
            bound = [v[j + 1] for j in range(body[0], body[1] - 2) if v[j] == 'let' and v[j + 2] == '=']
            yield i, collection, body, var + ['$0'], bound

    def use_enum(self, found, member):
        self.enums.setdefault(found[0].type_context(found[1] + 1), (found, member or 'title'))

    def element(self, swift, element, position, member, hint):
        """(label, identity) of one literal list element, or None if it is not literal."""
        words = [t.value for t in element]
        if words[:1] == ['('] and swift.pairs.get(swift.tokens.index(element[0])) == swift.tokens.index(element[-1]):
            parts = swift.args(swift.tokens.index(element[0]))
            return self.element(swift, parts[position], 0, member, hint) if position < len(parts) else None
        if len(words) >= 2 and words[-2] == '.' and all(re.fullmatch(IDENT + r'|\.', w) for w in words):
            found = self.find_enum(swift, '.'.join(w for w in words[:-2] if w != '.') or hint)
            label = choice_labels(*found, member or 'title').get(words[-1], (None,))[0] if found else None
            return (label, words[-1]) if label is not None else None
        text = literal(element)
        if member is None and text is None and len(words) == 1 and re.fullmatch(r'\d+(?:\.\d+)?', words[0]):
            text = words[0]
        return (text, None) if text is not None and member is None else None

    def items(self, swift, i, api, tokens, where, loop):
        """A label that shows a loop's item stands for every item in the list."""
        _, (first, last), _, names, bound = loop
        values = swift.v[first:last]
        own = simple(tokens) and tokens[0].value in names + bound
        member = tokens[2].value if own and len(tokens) == 3 and tokens[0].value in names else None
        form = template(tokens, names)

        def text(label):
            return [Token(json.dumps(label), 0, 0)]
        if 'allCases' in values:
            k = values.index('allCases') - 1
            parts = []
            while k > 0 and re.fullmatch(IDENT, values[k - 1]):
                parts.insert(0, values[k - 1])
                if k > 1 and values[k - 2] == '.':
                    k -= 2
                else:
                    break
            found = self.find_enum(swift, '.'.join(parts))
            if not found:
                return  # Cases defined outside the Mac modules are treated as content.
            if own:
                self.use_enum(found, member)  # Recorded once, wherever the list appears.
                return
            if form:
                cases = list(enum_cases(*found))
                labels = {m: choice_labels(*found, m) for _, m in form[1] if m}
                filled = [(case, [labels[m][case][0] if m else case for _, m in form[1]]) for case in cases]
                if all(None not in parts for _, parts in filled):
                    for case, parts in filled:
                        self.add(swift, i, api, text(fill(form, parts)), where, identity=case, case=case)
                    return
            self.use_enum(found, None)
            self.add(swift, i, api, tokens, where)
            return
        if values[:1] == ['['] and swift.pairs.get(first) == last - 1:
            elements = swift.args(first)
            hint = next(('.'.join(w for w in words[:-2] if w != '.') for words in ([t.value for t in e] for e in elements)
                         if len(words) > 2 and words[-2] == '.'), '')
            order = [n for n in names if n != '$0']

            def value(element, name, part):
                return self.element(swift, element, order.index(name) if name in order else 0, part, hint)
            if own or form:
                slots = [(tokens[0].value, member)] if own else form[1]
                found = [[value(element, name, part) for name, part in slots] for element in elements]
                if all(None not in row for row in found):
                    for row in found:
                        label = row[0][0] if own else fill(form, [label for label, _ in row])
                        self.add(swift, i, api, text(label), where, identity=row[0][1])
                    return
            # Another wording: keep it, and record the list's literal values.
            for element in elements:
                item = self.element(swift, element, 0, None, hint)
                if item:
                    self.add(swift, i, 'choice', text(item[0]), where, identity=item[1])
            self.add(swift, i, api, tokens, where)
        # Otherwise the list is runtime content (the person's scenes, prompts or
        # devices): its items are rows, and the menu or picker holding them is the entry.

    def note(self, swift, i, args, end):
        """A disabled item without an action is a note, not an entry point."""
        v = swift.v
        if expression(named_arg(args, 'enabled') or []) == 'false' and v[end + 1:end + 3] == ['{', '}']:
            return True
        if expression(named_arg(args, 'action') or []) == 'nil' and v[i - 3] in ('let', 'var') and v[i - 1] == '=':
            block = min((q for p, q in swift.pairs.items() if v[p] == '{' and p < i < q), default=len(v))
            after = expression(swift.tokens[end:block])
            name = v[i - 2]
            return f'{name} . isEnabled = false' in after and f'{name} . submenu =' not in after
        return False

    def find_enum(self, swift, name):
        last = name.split('.')[-1]
        for path in self.tree.declaring('enum', last, near=swift.module) if last else []:
            owner = self.tree.swift(path)
            for start, end, kind, _, _ in owner.scopes:
                full = owner.type_context(start + 1)
                if kind == 'enum' and (full == name or full.endswith('.' + name)):
                    return owner, start, end
        return None

    def collect(self, swift, ranges, surface, mode, exclude=(), follow=False):
        v = swift.v

        def inside(i):
            return any(a < i < b for a, b in ranges) and not any(a < i < b for a, b in exclude)
        loops = sorted(self.iterations(swift, inside), key=lambda loop: -loop[2][0])  # Innermost first.

        # Mode 'options': a property declared with @AppStorage, or a binding into
        # the preferences model or UserDefaults, marks a control as persistent.
        stored = {v[j + 1] for k in range(len(v) - 1) if v[k] == 'AppStorage' and v[k + 1] == '('
                  for j in range(swift.pairs[k + 1] + 1, min(swift.pairs[k + 1] + 4, len(v) - 1)) if v[j] == 'var'}
        persistent_ranges = []

        def persistent(i, api):
            if api == 'choice':
                return any(a < i < b for a, b in persistent_ranges)
            if api not in ('Toggle', 'Picker', 'Stepper') or v[i + 1] != '(':
                return False
            words = v[i + 2:swift.pairs[i + 1]]
            return 'preferences' in words or 'UserDefaults' in words or any(w[1:] in stored for w in words if w.startswith('$'))
        if mode == 'options':
            for i, api, _, end in swift.calls({'Toggle', 'Picker', 'Stepper'}):
                if inside(i) and persistent(i, api):
                    persistent_ranges.append((i, swift.pairs[end + 1] if v[end + 1:end + 2] == ['{'] else end))

        # Mode 'doors': closures the host injects into the view, `var onOpenPacks: () -> Void`
        # or `(() -> Void)?`; the type starts with ( and reaches -> before any other declaration.
        injected = {v[k + 1] for k in range(len(v) - 4) if v[k] == 'var' and v[k + 2:k + 4] == [':', '('] and '->' in v[k + 4:k + 12]
                    and not {'{', '=', 'var', 'let', 'func'} & set(v[k + 4:v.index('->', k + 4)])}

        def door(i, api):
            """A Button or Link whose action leaves the page: page = …, a route call,
            a bare open(…), or an injected closure whose destination the page cannot know."""
            if api not in ('Button', 'Link'):
                return False
            if v[i + 1] == '(':
                end = swift.pairs[i + 1]
                action = named_arg(swift.args(i + 1), 'action') or (swift.tokens[end + 2:swift.pairs[end + 1]] if v[end + 1:end + 2] == ['{'] else [])
            elif v[i - 1] == '}':  # Button { action } label: { ... }: i is the label.
                action = swift.tokens[swift.openers[i - 1] + 1:i - 1]
            else:
                return False
            words = [t.value for t in action]
            calls = {w for n, w in enumerate(words[:-1]) if words[n + 1] in ('(', '?')}
            return (any(words[n:n + 2] == ['page', '='] for n in range(len(words) - 1))
                    or bool(calls & ROUTES) or bool(set(words) & injected)
                    or any(words[n:n + 2] == ['open', '('] and words[n - 1] != '.' for n in range(1, len(words) - 1)))

        def record(i, api, tokens):
            if mode == 'options' and not persistent(i, api):
                return  # The page's own content is not an entry point.
            if mode == 'doors' and not door(i, api):
                return  # A page-local action is not an entry point.
            names = swift.string_parameters(i)
            if any(t.value in names for n, t in enumerate(tokens) if n == 0 or tokens[n - 1].value != '.'):
                return  # A helper's String parameter: its call sites are the entries.
            where = surface(swift, i, api)
            loop = next((loop for loop in loops if loop[2][0] < i < loop[2][1] and references(tokens, loop[3] + loop[4])), None)
            if loop:
                self.items(swift, i, api, tokens, where, loop)
            else:
                self.add(swift, i, api, tokens, where)

        # A closure that labels a control: Button(action:) { ... }, Toggle(isOn:) { ... },
        # Link(destination:) { ... } or label: { ... }. Its first Text or Label is the
        # control's label, so both ways of writing a control keep one ID.
        closures = []
        for i, api, args, end in swift.calls({'Button', 'Toggle', 'Link'}):
            titled = named_arg(args, 'title') is not None or (args and not (len(args[0]) > 1 and args[0][1].value == ':'))
            if inside(i) and not titled and v[end + 1:end + 2] == ['{']:
                closures.append((i, api, end + 1, swift.pairs[end + 1]))
        for i, value in enumerate(v):
            if value == 'label' and v[i + 1:i + 3] == [':', '{'] and inside(i):
                j = i - 1
                if v[j] == '}':
                    j = swift.openers[j] - 1
                if v[j] == ')':
                    j = swift.openers[j] - 1
                closures.append((i, v[j], i + 2, swift.pairs[i + 2]))
        consumed = set()
        for i, owner, start, end in closures:
            texts = [j for j in range(start + 1, end - 1) if v[j] in ('Text', 'Label') and v[j + 1] == '(' and swift.args(j + 1)]
            icons = [j for j in range(start + 1, end - 1) if v[j] == 'Image' and v[j + 1] == '(']
            if texts:
                consumed.add(texts[0])
                record(i, owner, swift.args(texts[0] + 1)[0])
            elif icons:
                # An icon is not visible text. Its source expression is evidence.
                record(i, owner, swift.tokens[icons[0]:swift.pairs[icons[0] + 1] + 1])

        def in_closure(i):
            return any(a < i < b for _, _, a, b in closures)

        declared = {v[k + 1] for k in range(len(v) - 1) if v[k] == 'func'}
        for i, api, args, end in swift.calls(CONTROLS):
            if not inside(i) or i in consumed or (api in HELPERS and api not in declared):
                continue
            if api == 'Label' and (in_closure(i) or mode == 'page'):
                continue  # Outside a control, a Label is a heading or a status line.
            if self.note(swift, i, args, end):
                continue
            tokens = named_arg(args, 'title')
            if api == 'NSButton':
                tokens = tokens or named_arg(args, 'checkboxWithTitle') or named_arg(args, 'radioButtonWithTitle')
            if api == 'addItem':
                tokens = named_arg(args, 'withTitle')
            elif tokens is None and args and not (len(args[0]) > 1 and args[0][1].value == ':'):
                tokens = args[0]
            if not tokens or (literal(tokens) == '' and api not in ('TextField', 'SecureField')):
                continue
            record(i, api, tokens)

        for i, _, args, end in swift.calls({'Text', 'setAccessibilityLabel'}):
            if not inside(i) or not args or i in consumed:
                continue
            if v[i] == 'setAccessibilityLabel':
                if literal(args[0]):
                    record(i, 'native-control', args[0])  # An AppKit control's only label.
            elif v[end + 1:end + 4] == ['.', 'tag', '(']:
                record(i, 'choice', args[0])  # Text tags are a picker's choices.
            elif mode == 'panel' and literal(args[0]) is None and not in_closure(i):
                record(i, 'status', args[0])  # Runtime Text in the panel is a status row.

        if mode not in ('page', 'options', 'doors'):
            self.live_labels(swift, inside)
        if follow or mode not in ('page', 'options', 'doors'):
            self.follow(swift, inside, mode, surface, swiftui=follow)

    def live_labels(self, swift, inside):
        """Titles assigned in code rather than passed to a control."""
        v = swift.v
        for i in range(len(v) - 3):
            if not inside(i):
                continue
            # Native menu titles assigned after construction.
            if v[i:i + 3] == ['.', 'title', '='] and swift.stem == 'main' and literal([swift.tokens[i + 3]]):
                self.add(swift, i, 'menu-title', [swift.tokens[i + 3]], 'app menu bar', identity=v[i - 1])
            # The floating toolbar resolves its action title before rendering the row.
            # A title computed by another function is recorded where that function is.
            if v[i:i + 2] == ['title', '='] and v[i - 1] != '.' and swift.stem == 'FloatingToolbar':
                j = k = i + 2
                while k < len(v) and v[k] not in (';', '}', 'case'):
                    if k > j and '\n' in swift.source[swift.tokens[k - 1].end:swift.tokens[k].start]:
                        break
                    k = swift.pairs[k] + 1 if v[k] in ('(', '[', '{') else k + 1
                if '(' not in v[j:k]:
                    self.add(swift, i, 'hover-title', swift.tokens[j:k], 'floating toolbar hover action')

    def follow(self, swift, inside, mode, surface, swiftui):
        """Views embedded in a surface belong to it. Menus embed only AppKit views."""
        kinds = [('class', self.tree.views(native=True))] + ([('struct', self.tree.views(native=False))] if swiftui else [])
        for i, name in enumerate(swift.v[:-1]):
            if not inside(i) or swift.v[i + 1] != '(' or swift.v[i - 1] in ('.', 'struct', 'class', 'func'):
                continue
            for kind, views in kinds:
                if name not in views:
                    continue
                for path in self.tree.declaring(kind, name, near=swift.module)[:1]:
                    relative = path.relative_to(self.tree.root / 'Sources').as_posix()
                    if (path, name) in self.visited or name in EXCLUDED.get(relative, []):
                        continue
                    self.visited.add((path, name))
                    owner = self.tree.swift(path)
                    ranges = [(s[0], s[1]) for s in owner.scopes if s[2] == kind and s[3] == name]
                    embedded = 'quick panel status rows' if mode == 'panel' else surface(swift, i, '')
                    self.collect(owner, ranges, lambda *_, e=embedded: e, mode, follow=swiftui)

    def catalogues(self):
        def labelled(label, expr):
            return [Token(json.dumps(label), 0, 0)] if label is not None else lex(expr)
        # Panel row action titles for each tool and state, and the floating
        # toolbar's next action for each operation and start verb.
        for catalogue, surface in ((CATALOGUES[0], 'floating toolbar hover action'), (CATALOGUES[6], 'floating toolbar next action')):
            swift, ranges = self.owner(*catalogue, kinds=('func',))
            for start, end in ranges:
                for case, tokens in case_returns(swift, start, end).items():
                    if tokens and tokens[0].value != 'switch':  # Nested state switches are recorded below it.
                        self.add(swift, start + 1, 'hover-title', tokens, surface, identity=case)
        # Floating toolbar modes (the launcher and its chooser's seven rows) and its accessory.
        swift, ranges = self.owner(*CATALOGUES[1], kinds=('enum',))
        for start, end in ranges[:1]:
            for case, (label, expr) in choice_labels(swift, start, end, 'title').items():
                self.add(swift, start + 1, 'title', labelled(label, expr), 'floating toolbar modes', identity=case, case=case)
        swift, ranges = self.owner(*CATALOGUES[2], kinds=('struct',))
        for start, end in ranges:
            for i in range(start, end - 3):
                if swift.v[i:i + 4] == ['self', '.', 'accessoryTitle', '=']:
                    k = i + 5
                    while k < end and '\n' not in swift.source[swift.tokens[k - 1].end:swift.tokens[k].start]:
                        k += 1
                    self.add(swift, i, 'accessory-title', swift.tokens[i + 4:k], 'floating toolbar accessory', identity='present-prompts')
        # Stage shortcuts: every Action case, titled as the shortcut list shows it.
        swift, ranges = self.owner(*CATALOGUES[3], kinds=('enum',))
        for start, end in ranges[:1]:
            tools = self.find_enum(swift, 'DrawingTool')
            tool_labels = choice_labels(*tools, 'title') if tools else {}
            for case, (label, expr) in choice_labels(swift, start, end, 'title').items():
                self.add(swift, start + 1, 'title', labelled(*tool_labels.get(case, (label, expr))),
                         'global shortcuts', identity=case, case=case)
                self.entries[-1]['id'] = 'shortcut.stage.' + case
        # Voice shortcuts: (id, title) pairs.
        swift, ranges = self.owner(*CATALOGUES[4], kinds=('func',))
        for start, end in ranges:
            for i in range(start, end):
                args = swift.args(i) if swift.v[i] == '(' else []
                if len(args) > 1 and re.fullmatch(r'UInt32 \( \d+ \)', expression(args[0])) and literal(args[1]):
                    number = args[0][2].value
                    self.add(swift, i, 'shortcut', args[1], 'global shortcuts', identity=number)
                    self.entries[-1]['id'] = 'shortcut.voice.' + number
        # Window sidebar: (page, title, symbol).
        swift, ranges = self.owner(*CATALOGUES[5], kinds=('struct',))
        for start, end in ranges[:1]:
            j = next((j for j in range(start, end - 2) if swift.v[j] == 'navItems' and swift.v[j - 1] == 'let'), None)
            if j is None and self.strict:
                raise ValueError('Missing surface owner: Sources/LocalVoice/WorkbenchHome.swift navItems. '
                                 'Update CATALOGUES in scripts/check-surfaces.py after a move.')
            while j is not None and swift.v[j] != '=':
                j += 1
            if j is not None and swift.v[j + 1] == '[':
                for item in swift.args(j + 1):
                    k = swift.tokens.index(item[0])
                    parts = swift.args(k) if swift.v[k] == '(' else []
                    if len(parts) > 1 and literal(parts[0]) and literal(parts[1]):
                        self.add(swift, k, 'sidebar', parts[1], 'window sidebar', identity=literal(parts[0]), page=literal(parts[0]))

    def enum_choices(self):
        for name, ((swift, start, end), member) in sorted(self.enums.items()):
            prefix, where = ROWS.get(name, (f'choices.{name}.', f'choices {name}'))
            for case, (label, expr) in choice_labels(swift, start, end, member).items():
                self.add(swift, start + 1, 'choice', [Token(json.dumps(label), 0, 0)] if label is not None else lex(expr),
                         where, identity=case, case=case)
                self.entries[-1]['id'] = prefix + case


def quick_panel_surface(swift, index, api):
    """The panel's areas, from its structure rather than helper names."""
    v = swift.v
    # Row options are built per tool: switch tool { case .dictate: ... }.
    blocks = sorted(p for p, q in swift.pairs.items() if v[p] == '{' and p < index < q)
    switch = next((p for p in reversed(blocks) if 'switch' in v[max(0, p - 4):p]), None)
    if switch is not None:
        cases = [v[k + 2] for k in range(switch, index) if v[k] == 'case' and v[k + 1] == '.']
        if cases:
            return f'quick panel {cases[-1]} options'
    # A fixed control inside the rows loop, ForEach(WorkbenchControlTool.allCases), is a row.
    for p in blocks:
        call = swift.openers.get(p - 1)
        if call is not None and v[call - 1] == 'ForEach' and 'WorkbenchControlTool' in v[call:p]:
            return 'quick panel rows'
    funcs = [s for s in swift.scopes if s[2] == 'func' and s[0] < index < s[1]]
    if funcs and 'WorkbenchControlTool' in v[max(funcs)[4]:max(funcs)[0]]:
        return 'quick panel row controls'
    if api == 'Toggle':
        return 'quick panel header'
    return 'quick panel status rows' if api == 'status' else 'quick panel footer'


def derive(root, require_roots=True):
    tree = Tree(root)
    inventory = Inventory(tree, require_roots)
    # Proactive offers, the app raises these on its own. First, so a surface
    # that embeds an offer does not claim it.
    offers = {(p, m[1]) for p in tree.paths if p.parent.name in ('LocalVoice', 'StageKit') for m in OFFER_NAME.finditer(tree.texts[p])}
    for name in OFFER_TYPES:
        offers.update((p, name) for p in tree.declaring('struct|class', name))
    for path, name in sorted(offers):
        swift = tree.swift(path)
        ranges = [(s[0], s[1]) for s in swift.scopes if s[2] in ('struct', 'class') and s[3] == name]
        inventory.visited.add((path, name))
        inventory.collect(swift, ranges, lambda *_, n=name: 'proactive offer ' + n, 'controls', follow=True)
    for relative, scope, where, mode in ENTRY_POINTS:
        swift, ranges = inventory.owner(relative, scope)
        if not ranges:
            continue
        if '.' not in scope:
            inventory.visited.add((tree.root / 'Sources' / relative, scope))  # Not collected again when embedded.
        exclude = [s[:2] for path in EXCLUDED.get(relative, []) for s in swift.find(path)]
        surface = quick_panel_surface if where == 'quick panel' else lambda *_, w=where: w
        inventory.collect(swift, ranges, surface, mode, exclude, follow=mode in ('panel', 'page'))
    inventory.catalogues()
    inventory.enum_choices()
    # Count repeated definitions as separate entries. IDs do not contain line
    # numbers; inserting or reordering unrelated entries does not churn them.
    unique, counts = {}, Counter()
    for entry in inventory.entries:
        key = entry['id']
        if key in unique and unique[key] != entry:
            entry['id'] += '.' + hashlib.sha256(json.dumps(entry, sort_keys=True).encode()).hexdigest()[:8]
        counts[entry['id']] += 1
        if counts[entry['id']] > 1:
            entry['id'] += '.' + str(counts[entry['id']])
        unique[entry['id']] = entry
    return [unique[key] for key in sorted(unique)]


SOURCE_FIELDS = ('surface', 'label', 'expression', 'case', 'page')


def reconcile(actual, registered):
    old = {entry['id']: entry for entry in registered}
    result = []
    for entry in actual:
        previous = old.get(entry['id'])
        unchanged = previous and all(previous.get(k) == entry.get(k) for k in SOURCE_FIELDS)
        if unchanged:
            result.append(previous)
        else:
            # A rename must be reviewed just like an addition. Preserve neither
            # classification nor aliases automatically on changed source facts.
            result.append({**entry, 'kind': 'unclassified', 'belongsTo': previous.get('belongsTo', 'app') if previous else 'app'})
    return result


def compare(actual, registered):
    errors = []
    ids = Counter(e.get('id') for e in registered)
    for key, count in sorted(ids.items(), key=lambda pair: str(pair[0])):
        if count > 1:
            errors.append(f'Duplicate registry id: {key}.')
    source = {e['id']: e for e in actual}
    registry = {e.get('id'): e for e in registered}
    for key, entry in source.items():
        label = json.dumps(entry['label'], ensure_ascii=False) if entry['label'] is not None else 'runtime label ' + entry['expression']
        if key not in registry:
            errors.append(f'Unregistered entry on {entry["surface"]}: {label}. {GUIDANCE} [{key}]')
        elif any(entry.get(field) != registry[key].get(field) for field in SOURCE_FIELDS):
            errors.append(f'Changed entry on {entry["surface"]}: {label}. {GUIDANCE} [{key}]')
    for key in sorted(registry.keys() - source.keys(), key=str):
        errors.append(f'Stale entry: {key}. The check no longer finds this control. Confirm it is really gone before removing its registration (--update removes it): a stale entry can also mean the check stopped recognising it after a move or a new way of writing it.')
    for entry in registered:
        key = entry.get('id')
        if not isinstance(key, str) or not key or not isinstance(entry.get('surface'), str):
            errors.append(f'Entry needs a nonempty string id and surface: {key!r}.')
        if entry.get('label') is not None and not isinstance(entry['label'], str):
            errors.append(f'Label for {key} must be a string, or null for a runtime label.')
        if entry.get('kind') == 'unclassified':
            errors.append(f'Unclassified entry: {key}. Choose a kind and belongsTo after reading docs/workbench.md#grammar. {GUIDANCE}')
        elif entry.get('kind') not in KINDS:
            errors.append(f'Invalid kind for {key}: {entry.get("kind")!r}. Use one of {", ".join(sorted(KINDS))}.')
        if entry.get('belongsTo') not in OWNERS:
            errors.append(f'Invalid belongsTo for {key}: use a Grammar capability or place id ({", ".join(sorted(OWNERS))}).')
        if entry.get('label') is None and not entry.get('note'):
            errors.append(f'Runtime label {key} needs a note explaining its source.')
        alias = entry.get('aliasOf')
        if alias and (alias not in OWNERS and alias not in registry or alias == key):
            errors.append(f'Invalid aliasOf for {key}: name a Grammar id or a different registered entry.')
        if alias and not entry.get('note'):
            errors.append(f'Alias {key} needs a note explaining the intentional alternative.')
    labels = defaultdict(list)
    for entry in registered:
        if entry.get('label') and entry.get('id') in source:
            labels[entry['label']].append(entry)
    for label, entries in sorted(labels.items()):
        owners = {e.get('belongsTo') for e in entries if not e.get('aliasOf')}
        if len(owners) > 1:
            details = ', '.join(f'{e["id"]} ({e.get("belongsTo")})' for e in entries if not e.get('aliasOf'))
            errors.append(f'Label collision: {json.dumps(label, ensure_ascii=False)} belongs to different capabilities or places: {details}. Use the Grammar name; declare an intentional alternative with aliasOf and a note. The check does not choose the name.')
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--root', type=Path, default=REPO, help='Source tree to inspect (registry still defaults to this checkout).')
    parser.add_argument('--registry', type=Path, default=REPO / 'docs/surfaces.json')
    parser.add_argument('--update', action='store_true', help='Reconcile source entries; additions/renames remain unclassified.')
    parser.add_argument('--json', action='store_true', help='Machine-readable actual entries and errors for review.')
    args = parser.parse_args(argv)
    try:
        actual = derive(args.root.resolve())
        registered = json.loads(args.registry.read_text()) if args.registry.exists() else []
        if not isinstance(registered, list) or any(not isinstance(e, dict) for e in registered):
            raise ValueError('Registry must be a JSON array of entry objects.')
        if args.update:
            registered = reconcile(actual, registered)
            args.registry.write_text(json.dumps(registered, indent=2, ensure_ascii=False) + '\n')
        errors = compare(actual, registered)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f'Surface registry error: {error}', file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps({'entries': actual, 'errors': errors}, indent=2, ensure_ascii=False))
    elif errors:
        print('\n'.join(errors))
        print(f'Surface registry FAILED: {len(errors)} issue(s), {len(actual)} source entries.')
    else:
        print(f'Surface registry OK: {len(actual)} entries.')
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
