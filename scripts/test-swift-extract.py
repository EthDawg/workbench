#!/usr/bin/env python3
"""Synthetic Swift and the files the harnesses read. Does not compile or launch anything."""
from pathlib import Path
import random
import sys
import unittest

sys.dont_write_bytecode = True
from swift_extract import ExtractError, Scope, SwiftFile, tokens

PROJECT = Path(__file__).resolve().parents[1]
# Every file a harness extracts from, so the reader is checked on the exact text it reads.
HARNESS_SOURCES = ['AppModel.swift', 'Core.swift', 'ReadbackModel.swift', 'Shortcuts.swift', 'WorkbenchHome.swift']

MODEL = '''import Foundation

@MainActor
final class Model {
    enum Phase { case idle, busy }
    /// Braces and quotes inside strings and comments are text, not code.
    func first() -> String {
        let a = "}" + "{" // }
        let b = "\\(a.isEmpty ? "}" : "{")" /* } /* nested { */ */
        let c = #"a "quoted" } and \\(not interpolated) and \\#(a)"#
        let d = """
            }
            \\(a + "}")
            """
        let e = ##"""
            """# }
            """##
        return a + b + c + d + e
    }
    // A plain comment directly above describes the next member.
    @discardableResult
    private func second(_ value: Int, label other: String = { "x" }()) -> Int { value }

    // MARK: A floating comment belongs to no member

    static let limit = 5_000
    var computed: Int {
        get { 1 }
        set { }
    }
    @Published private(set) var observed = 0 {
        didSet { print(observed) }
    }
    var optional: String?
    var trailing = 1 // kept with its member
    lazy var made: [Int: String] = {
        [1: "}"]
    }()
    init(preferences: Int) {}
    init?(maybe: Int) { return nil }
    subscript(index: Int) -> Int { index }
    func listen() {}
    func listen(to text: String) {}
    func generic<T: Collection>(_ items: Dictionary<String, T>, then: (Int, Int) -> Void) {}
    func `default`() {}
    static func == (lhs: Model, rhs: Model) -> Bool { true }
    func wrapped(
        one: Int,
        two: Int
    )
        throws -> Int
    {
        one + two
    }
    deinit {}
}

extension Model {
    func fromExtension() {}
}

struct Outer {
    struct Inner { func deep() {} }
}
'''


def model(source=MODEL):
    return SwiftFile(Path('Model.swift'), source)


class Lexing(unittest.TestCase):
    def test_strings_and_comments_hide_braces(self):
        first = model().type('Model').select(['first'])[0]
        self.assertTrue(first.text.startswith('    /// Braces'))
        self.assertTrue(first.text.endswith('return a + b + c + d + e\n    }'))

    def test_interpolation_is_code_that_can_hold_strings(self):
        kinds = [kind for kind, _, _ in tokens('let x = "\\(y ? "}" : "{")" + z')]
        self.assertEqual(kinds, ['word', 'word', 'op', 'string', 'op', 'word'])

    def test_unbalanced_or_unterminated_source_raises(self):
        for source, message in [('func f() {\n', 'never closed'), ('func f() }\n', "unbalanced '}'"),
                                ('let x = "open\n', 'unterminated string'), ('/* open\n', 'unterminated comment')]:
            with self.assertRaisesRegex(ExtractError, message):
                model(source)


class Declarations(unittest.TestCase):
    def setUp(self):
        self.model = model().type('Model')

    def text(self, name):
        return self.model.select([name])[0].text

    def test_selectors(self):
        selectors = [m.selector or m.name for m in self.model.members]
        for expected in ['first()', 'second(_:label:)', 'limit', 'computed', 'observed', 'init(preferences:)',
                         'init(maybe:)', 'subscript(_:)', 'listen()', 'listen(to:)', 'generic(_:then:)',
                         'default()', '==(lhs:rhs:)', 'wrapped(one:two:)', 'deinit', 'fromExtension()', 'Phase']:
            self.assertIn(expected, selectors)

    def test_attribute_on_its_own_line_belongs_to_its_member(self):
        # Cutting up to "func second(" left @discardableResult on the member before it (#203).
        self.assertNotIn('@discardableResult', self.text('first'))
        self.assertTrue(self.text('second').startswith(
            '    // A plain comment directly above describes the next member.\n    @discardableResult\n'))

    def test_floating_comments_stay_out_and_trailing_comments_stay_in(self):
        self.assertTrue(self.text('limit').startswith('    static let limit'))
        self.assertEqual(self.text('trailing'), '    var trailing = 1 // kept with its member')
        self.assertEqual(self.text('optional'), '    var optional: String?')
        self.assertNotIn('MARK', ''.join(m.text for m in self.model.members))

    def test_multi_line_members_end_where_they_end(self):
        self.assertTrue(self.text('computed').endswith('set { }\n    }'))
        self.assertTrue(self.text('observed').startswith('    @Published private(set) var observed = 0 {'))
        self.assertTrue(self.text('made').endswith('}()'))
        self.assertTrue(self.text('wrapped').endswith('one + two\n    }'))

    def test_modifiers_skip_attributes_and_their_arguments(self):
        modifiers = {m.selector or m.name: m.modifiers for m in self.model.members}
        self.assertEqual(modifiers['second(_:label:)'], ('private',))
        self.assertEqual(modifiers['observed'], ('private',))
        self.assertEqual(modifiers['limit'], ('static',))
        self.assertEqual(modifiers['first()'], ())

    def test_code_blanks_comments_only(self):
        first = self.model.select(['first'])[0]
        self.assertNotIn('Braces', first.code)
        self.assertNotIn('nested', first.code)
        self.assertIn('"}"', first.code)
        self.assertEqual(first.code.count('\n'), first.text.count('\n'))

    def test_members_come_back_in_source_order(self):
        names = [m.name for m in self.model.select(['listen()', 'limit', 'first'])]
        self.assertEqual(names, ['first', 'limit', 'listen'])

    def test_extensions_and_nested_types(self):
        self.assertEqual(self.text('fromExtension'), '    func fromExtension() {}')
        self.assertEqual(model().type('Outer.Inner').extract(['deep']), 'func deep() {}')
        top = model()
        self.assertEqual(top.imports(), 'import Foundation')
        self.assertTrue(top.extract(['extension Model']).startswith('extension Model {'))
        self.assertTrue(top.extract(['Model']).startswith('@MainActor\nfinal class Model {'))


class Names(unittest.TestCase):
    def setUp(self):
        self.model = model().type('Model')

    def fails(self, names, *messages):
        with self.assertRaises(ExtractError) as raised:
            self.model.select(names)
        for message in messages:
            self.assertIn(message, str(raised.exception))

    def test_missing_ambiguous_and_repeated_names_fail_loudly(self):
        self.fails(['nothing'], "no member 'nothing'")
        line = MODEL.split('\n').index('    func listen() {}') + 1
        self.fails(['listen'], f"'listen' matches 2 members, listen() (line {line}), listen(to:) (line {line + 1})")
        self.fails(['first', 'first'], "'first' is listed twice")
        self.fails(['idle'], "no member 'idle'")
        # Every problem at once, each with its name.
        self.fails(['gone', 'listen', 'first', 'first'], "no member 'gone'", "'listen' matches", "listed twice")

    def test_one_declaration_by_two_names(self):
        phase = model().type('Model.Phase')
        self.assertEqual(phase.extract(['idle']), 'case idle, busy')
        with self.assertRaisesRegex(ExtractError, "'busy' is the declaration already listed"):
            phase.select(['idle', 'busy'])

    def test_a_list_not_a_string(self):
        with self.assertRaises(TypeError):
            self.model.select('first')

    def test_members_inside_if_cannot_be_extracted_alone(self):
        conditional = model('final class C {\n    #if DEBUG\n    func debug() {}\n    #endif\n    func always() {}\n}\n')
        scope = conditional.type('C')
        self.assertEqual(scope.extract(['always']), '    func always() {}')
        with self.assertRaisesRegex(ExtractError, "'debug' .* is inside #if"):
            scope.select(['debug'])

    def test_a_helper_added_between_listed_members_is_not_taken(self):
        source = MODEL.replace('    func listen() {}\n', '    func listen() {}\n    func newHelper() {}\n')
        extracted = model(source).type('Model').extract(['listen()', 'listen(to:)'])
        self.assertNotIn('newHelper', extracted)

    def test_moving_members_changes_nothing_extracted(self):
        # Reorder the class's members every which way: each named member reads the same.
        names = ['first', 'second', 'limit', 'computed', 'observed', 'trailing', 'made', 'init(preferences:)',
                 'listen()', 'listen(to:)', 'generic', 'wrapped', 'deinit', 'Phase']
        original = model().type('Model')
        expected = {m.selector or m.name: m.text for m in original.select(names)}
        body = original.members
        head = MODEL[:MODEL.index('@MainActor')]
        tail = MODEL[MODEL.index('\nextension Model'):]
        generator = random.Random(134)
        for _ in range(20):
            order = [m.text for m in body if m.name != 'fromExtension']
            generator.shuffle(order)
            moved = head + '@MainActor\nfinal class Model {\n' + '\n'.join(order) + '\n}' + tail
            found = {m.selector or m.name: m.text for m in model(moved).type('Model').select(names)}
            self.assertEqual(found, expected)


class HarnessSources(unittest.TestCase):
    """The reader agrees with itself on every file a harness extracts from."""

    def test_members_cover_each_body_and_read_back_alone(self):
        for name in HARNESS_SOURCES:
            file = SwiftFile(PROJECT / 'Sources/LocalVoice' / name)
            self.check(file, file, 0, len(file.source))

    def check(self, file, scope, start, end):
        position = start
        for member in scope.members:
            with self.subTest(file=file.path.name, member=repr(member)):
                between = file.source[position:member.start]
                self.assertEqual(self.uncommented(file, position, between), '', 'text outside any member')
                self.assertGreaterEqual(member.start, position)
                wrapped = SwiftFile(file.path, member.text if scope is file else 'struct W {\n' + member.text + '\n}\n')
                again = wrapped.members if scope is file else wrapped.type('W').members
                self.assertEqual([(m.kind, m.names, m.selector) for m in again],
                                 [(member.kind, member.names, member.selector)])
            position = member.end
            if member.body:
                # Each body on its own: a type's scope also holds its extensions' members.
                inside = Scope(file, member.name, file.parse(member.body[0] + 1, member.body[1], member.conditional))
                self.check(file, inside, file.tokens[member.body[0]][2], file.tokens[member.body[1]][1])
        self.assertEqual(self.uncommented(file, position, file.source[position:end]), '')

    @staticmethod
    def uncommented(file, offset, text):
        for begin, finish in file.comments_between(offset, offset + len(text)):
            text = text[:max(0, begin - offset)] + ' ' * (min(finish, offset + len(text)) - max(begin, offset)) \
                + text[min(len(text), finish - offset):]
        return text.strip()


if __name__ == '__main__':
    unittest.main(verbosity=1)
