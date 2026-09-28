#!/usr/bin/env python3
"""Read Swift declarations by name, for harnesses that compile production code.

Harnesses compile exact members of files such as AppModel.swift beside their
fixtures. Cutting the text between two neighbouring declarations breaks when a
method moves, quietly takes in a helper added inside the range, and hands an
attribute written above the end marker to the member before it. Here every
declaration is read whole, by name: its doc comments and attributes, then
everything to its end. Braces are matched outside comments and strings,
including multi-line, raw and interpolated strings.

    model = SwiftFile(SOURCES / "AppModel.swift").type("AppModel")
    methods = model.extract(["listen()", "stopPlayback", "canSeekReading"])

A name is a member's bare name, which must identify one declaration, or its
Swift selector, such as `listen(to:)` or `init(preferences:)`, to choose one of
several overloads. `extension Name` names a same-file extension at the top
level. A missing, ambiguous or repeated name raises ExtractError naming each
one. Members come back in source order, whatever order they are listed in.

A type's members include those of its extensions in the same file. Members
inside `#if` cannot be extracted on their own. `var a = 1, b = 2` is named by
its first binding only, and a tuple pattern such as `let (x, y)` has no name.
Top-level statements, as in main.swift, are kept as unnamed items; bare
/regex/ literals are not read.
Anything this reader cannot follow, such as unbalanced delimiters, raises
rather than guessing.

`python3 scripts/swift_extract.py FILE [TYPE]` lists the selectors to use.
"""

import bisect
import os
from pathlib import Path
import re
import sys


class ExtractError(Exception):
    """A name that does not identify one declaration, or source this reader cannot follow."""


KEYWORDS = {'func', 'var', 'let', 'init', 'deinit', 'subscript', 'enum', 'struct', 'class', 'actor',
            'protocol', 'extension', 'typealias', 'associatedtype', 'case', 'import', 'operator',
            'precedencegroup', 'macro'}
MODIFIERS = {'private', 'fileprivate', 'internal', 'public', 'open', 'package', 'static', 'class',
             'final', 'override', 'required', 'convenience', 'lazy', 'weak', 'unowned', 'mutating',
             'nonmutating', 'dynamic', 'optional', 'indirect', 'nonisolated', 'distributed',
             'prefix', 'postfix', 'infix', 'consuming', 'borrowing'}
TYPES = {'enum', 'struct', 'class', 'actor', 'protocol', 'extension'}
CONDITIONS = {'#if', '#elseif', '#else', '#endif'}
# Macros that are expressions, never declarations, when they begin a line.
EXPRESSIONS = {'#selector', '#keyPath', '#available', '#unavailable', '#file', '#fileID', '#filePath',
               '#line', '#column', '#function', '#dsohandle', '#isolation', '#colorLiteral',
               '#imageLiteral', '#fileLiteral', '#externalMacro'}
# A line that begins with one of these continues the line before it.
CONTINUATIONS = {'where', 'throws', 'rethrows', 'async', 'else', 'catch', 'is', 'as'}
OPEN = ('(', '[', '{')

WORD = re.compile(r'`[^`\n]+`|[^\W\d]\w*|\$\w*|\d\w*(?:\.\d\w*)*')
STRING = re.compile(r'(#*)("""|")')
REGEX = re.compile(r'(#+)/')
OPERATOR = re.compile(r'(?:(?!//|/\*)[-/=+!*%<>&|^~?.])+')


def _line(source, offset):
    return source.count('\n', 0, offset) + 1


def _comment_end(source, start, path):
    depth, i = 0, start
    while i < len(source):
        if source.startswith('/*', i):
            depth, i = depth + 1, i + 2
        elif source.startswith('*/', i):
            depth, i = depth - 1, i + 2
            if not depth:
                return i
        else:
            i += 1
    raise ExtractError(f'{path}:{_line(source, start)}: unterminated comment')


def _string_end(source, start, path):
    """The offset after the string literal that opens at start, interpolations included."""
    hashes, quote = STRING.match(source, start).groups()
    close, escape = quote + hashes, '\\' + hashes
    i = start + len(hashes) + len(quote)
    while i < len(source):
        if source.startswith(close, i):
            return i + len(close)
        if source.startswith(escape, i):
            i += len(escape)
            if i < len(source) and source[i] == '(':
                i = _interpolation_end(source, i, path)
            else:
                i += 1
            continue
        if quote == '"' and source[i] == '\n':
            break
        i += 1
    raise ExtractError(f'{path}:{_line(source, start)}: unterminated string')


def _interpolation_end(source, start, path):
    """The offset after the parenthesis that closes the interpolation opening at start."""
    depth, i = 0, start
    while i < len(source):
        if source[i] == '(':
            depth, i = depth + 1, i + 1
        elif source[i] == ')':
            depth, i = depth - 1, i + 1
            if not depth:
                return i
        elif STRING.match(source, i):
            i = _string_end(source, i, path)
        elif source.startswith('/*', i):
            i = _comment_end(source, i, path)
        elif source.startswith('//', i):
            end = source.find('\n', i)
            i = len(source) if end < 0 else end
        else:
            i += 1
    raise ExtractError(f'{path}:{_line(source, start)}: unterminated interpolation')


def tokens(source, path='<source>'):
    """Swift source as (kind, start, end) tokens. Kinds: nl, comment, string, word,
    attr (@Name), hash (#name), op, other, and each of { } ( ) [ ] ; , : as itself."""
    result, i, n = [], 0, len(source)
    while i < n:
        c, start = source[i], i
        if c == '\n':
            kind, i = 'nl', i + 1
        elif c in ' \t\r\f\v':
            i += 1
            continue
        elif source.startswith('//', i):
            end = source.find('\n', i)
            kind, i = 'comment', n if end < 0 else end
        elif source.startswith('/*', i):
            kind, i = 'comment', _comment_end(source, i, path)
        elif STRING.match(source, i):
            kind, i = 'string', _string_end(source, i, path)
        elif REGEX.match(source, i):
            hashes = REGEX.match(source, i).group(1)
            end = source.find('/' + hashes, i + len(hashes) + 1)
            if end < 0:
                raise ExtractError(f'{path}:{_line(source, i)}: unterminated regex literal')
            kind, i = 'string', end + 1 + len(hashes)
        elif c in '{}()[];,:':
            kind, i = c, i + 1
        elif c in '@#' and WORD.match(source, i + 1) and source[i + 1] != '`':
            kind, i = 'attr' if c == '@' else 'hash', WORD.match(source, i + 1).end()
        elif WORD.match(source, i):
            kind, i = 'word', WORD.match(source, i).end()
        elif OPERATOR.match(source, i):
            kind, i = 'op', OPERATOR.match(source, i).end()
        else:
            kind, i = 'other', i + 1
        result.append((kind, start, i))
    return result


class Member:
    """One declaration: what it declares, its modifiers, and its exact source with its doc
    comments and attributes, from the start of its first line to the end of its last."""

    def __init__(self, file, kind, names, selector, start, end, keyword, body, conditional, modifiers=()):
        self.file, self.kind, self.names, self.selector = file, kind, names, selector
        self.name = names[0] if names else None
        self.start, self.end, self.body, self.conditional = start, end, body, conditional
        self.modifiers = modifiers
        self.text = file.source[start:end]
        self.at = file.tokens[keyword][1]
        self.line = file.line(self.at)
        self.first_line, self.last_line = file.line(start), file.line(end)

    @property
    def code(self):
        """The text with its comments blanked out, line for line."""
        code = list(self.text)
        for begin, finish in self.file.comments_between(self.start, self.end):
            for i in range(max(begin, self.start) - self.start, min(finish, self.end) - self.start):
                if code[i] != '\n':
                    code[i] = ' '
        return ''.join(code)

    def lines(self, code=False):
        """(line number, text) for each of the member's lines; code=True blanks comments."""
        return list(enumerate((self.code if code else self.text).split('\n'), self.first_line))

    def __repr__(self):
        return f'<{self.kind} {self.selector or self.name} at line {self.line}>'


class Scope:
    """The declarations directly inside a type, with those of its extensions in the
    same file, or at a file's top level, in source order."""

    def __init__(self, file, name, members):
        self.file, self.name, self.members = file, name, members

    def select(self, names):
        """The members named, in source order. Each name must identify exactly one."""
        if isinstance(names, str):
            raise TypeError('select takes a list of names')
        problems, chosen, listed = [], {}, set()
        for name in names:
            if name in listed:
                problems.append(f"'{name}' is listed twice")
                continue
            listed.add(name)
            if '(' in name:
                found = [m for m in self.members if m.selector == name]
            else:
                found = [m for m in self.members if name in m.names]
            if not found:
                problems.append(f"no member '{name}'")
            elif len(found) > 1:
                problems.append(f"'{name}' matches {len(found)} members, "
                                + ', '.join(f'{m.selector or m.name} (line {m.line})' for m in found)
                                + '; name one by its selector')
            elif found[0].conditional:
                problems.append(f"'{name}' (line {found[0].line}) is inside #if, which extraction would drop")
            elif any(m is found[0] for m in chosen.values()):
                problems.append(f"'{name}' is the declaration already listed at line {found[0].line}")
            else:
                chosen[name] = found[0]
        if problems:
            raise ExtractError(f'{self.file.display}, {self.name}: ' + '; '.join(problems))
        return sorted(chosen.values(), key=lambda m: m.start)

    def extract(self, names):
        """The named members' source text in source order, one after another."""
        return '\n'.join(member.text for member in self.select(names))

    def type(self, name):
        """The members of the type called `name` declared here, which may be dotted."""
        head, _, rest = name.partition('.')
        found = [m for m in self.members if head in m.names and m.kind in TYPES - {'extension'}]
        if len(found) != 1:
            where = 'at the top level' if self is self.file else f'in {self.name}'
            raise ExtractError(f"{self.file.display}: {len(found) or 'no'} types named '{head}' {where}")
        qualified = head if self is self.file else f'{self.name}.{head}'
        members = []
        for body in found + [m for m in self.file.members if m.name == f'extension {qualified}']:
            members += self.file.parse(body.body[0] + 1, body.body[1], body.conditional)
        scope = Scope(self.file, qualified, sorted(members, key=lambda m: m.start))
        return scope.type(rest) if rest else scope


class SwiftFile(Scope):
    """A Swift file; as a Scope, its top-level declarations."""

    def __init__(self, path, source=None):
        self.path = Path(path)
        relative = os.path.relpath(self.path)
        self.display = str(self.path) if relative.startswith('..') else relative
        self.source = self.path.read_text() if source is None else source
        self.tokens = tokens(self.source, self.display)
        self.starts = [0] + [match.end() for match in re.finditer('\n', self.source)]
        self.comments = [(start, end) for kind, start, end in self.tokens if kind == 'comment']
        self.pairs, stack = {}, []
        for index, (kind, start, _) in enumerate(self.tokens):
            if kind in OPEN:
                stack.append(index)
            elif kind in (')', ']', '}'):
                if not stack or self.tokens[stack[-1]][0] != OPEN[(')', ']', '}').index(kind)]:
                    raise ExtractError(f"{self.display}:{self.line(start)}: unbalanced '{kind}'")
                self.pairs[stack.pop()] = index
        if stack:
            raise ExtractError(f"{self.display}:{self.line(self.tokens[stack[-1]][1])}: "
                               f"'{self.tokens[stack[-1]][0]}' is never closed")
        super().__init__(self, self.path.name, self.parse(0, len(self.tokens), False))

    def line(self, offset):
        return bisect.bisect_right(self.starts, offset)

    def comments_between(self, start, end):
        """The comments that overlap the text from start to end."""
        spans = []
        for begin, finish in self.comments[max(0, bisect.bisect_left(self.comments, (start, -1)) - 1):]:
            if begin >= end:
                break
            if finish > start:
                spans.append((begin, finish))
        return spans

    def imports(self):
        """The file's import declarations."""
        return '\n'.join(m.text for m in self.members if m.kind == 'import')

    def text(self, index):
        return self.source[self.tokens[index][1]:self.tokens[index][2]]

    def next(self, index, last):
        """The first token at or after index that is not a newline or a comment."""
        while index < last and self.tokens[index][0] in ('nl', 'comment'):
            index += 1
        return index

    def parse(self, first, last, conditional):
        """The items between token indices first and last: a file or a body's inside."""
        members, conditions = [], []
        k = self.next(first, last)
        while k < last:
            kind, text = self.tokens[k][0], self.text(k)
            if kind == 'hash' and text in CONDITIONS:
                if text == '#if':
                    conditions.append(k)
                elif not conditions:
                    raise ExtractError(f'{self.display}:{self.line(self.tokens[k][1])}: {text} without #if')
                elif text == '#endif':
                    conditions.pop()
                k = self.next(self.item_end(k, last) + 1, last)
                continue
            keyword = self.keyword(k, last)
            if keyword is None and kind == 'hash' and text not in EXPRESSIONS:
                keyword = k
            if keyword is None and first > 0:
                raise ExtractError(f'{self.display}:{self.line(self.tokens[k][1])}: '
                                   f"expected a declaration, found '{text}'")
            end = self.item_end(k if keyword is None else keyword, last)
            members.append(self.member(k, keyword, end, first, conditional or bool(conditions)))
            k = self.next(end + 1, last)
        if conditions:
            raise ExtractError(f'{self.display}:{self.line(self.tokens[conditions[-1]][1])}: #if without #endif')
        return members

    def keyword(self, k, last):
        """The declaration keyword after any attributes and modifiers from token k, or None.
        Attributes may stand on lines of their own."""
        attribute = False
        while k < last:
            kind, text = self.tokens[k][0], self.text(k)
            if kind in ('nl', 'comment') and attribute:
                k += 1
                continue
            if kind == 'attr' or kind == 'word' and text in MODIFIERS and not (
                    text == 'class' and self.names_type(self.next(k + 1, last), last)):
                attribute = kind == 'attr'
                k += 1
                if k < last and self.tokens[k][0] == '(' and self.tokens[k][1] == self.tokens[k - 1][2]:
                    k = self.pairs[k] + 1
                continue
            return k if kind == 'word' and text in KEYWORDS else None
        return None

    def names_type(self, k, last):
        """Whether token k, after `class`, is the name of a class being declared."""
        return k < last and self.tokens[k][0] == 'word' and self.text(k) not in KEYWORDS | MODIFIERS

    def item_end(self, k, last):
        """The last token of the item whose keyword is at k. At bracket depth 0, a line
        begins the next item unless the line before ends in an infix operator, or the
        line itself begins with an operator, a bracket or a continuing keyword."""
        end = k
        while k < last:
            kind = self.tokens[k][0]
            if kind in OPEN:
                end = k = self.pairs[k]
            elif kind == ';':
                return k
            elif kind == 'nl':
                n = self.next(k, last)
                if n >= last or not self.continues(end, n):
                    return end
                k = n
                continue
            elif kind != 'comment':
                end = k
            k += 1
        return end

    def continues(self, previous, k):
        """Whether the line starting at token k continues the one ending at token previous."""
        kind, text = self.tokens[previous][0], self.text(previous)
        spaced = self.source[self.tokens[previous][1] - 1] in ' \t\n'
        if kind in (',', ':') or kind == 'op' and (text in ('=', '->') or spaced):
            return True
        kind, text = self.tokens[k][0], self.text(k)
        return kind in ('op', ':', ',') + OPEN or kind == 'word' and text in CONTINUATIONS

    def member(self, first, keyword, end, body_start, conditional):
        # Comments on the lines directly above, doc or plain, belong to the declaration.
        start, k, newlines = first, first - 1, 0
        while k >= body_start and self.tokens[k][0] in ('nl', 'comment'):
            if self.tokens[k][0] == 'nl':
                newlines += 1
                if newlines > 1:
                    break
            elif k == 0 or self.tokens[k - 1][0] == 'nl':
                start, newlines = k, 0
            else:
                break
            k -= 1
        offset = self.tokens[start][1]
        if start == 0 or self.tokens[start - 1][0] == 'nl':
            offset = self.starts[self.line(offset) - 1]
        # Through the end of the last line, with any comment there, unless code follows on it.
        finish, after = self.tokens[end][2], end + 1
        while after < len(self.tokens) and self.tokens[after][0] == 'comment':
            after += 1
        if after == len(self.tokens) or self.tokens[after][0] == 'nl':
            newline = self.source.find('\n', finish)
            finish = len(self.source) if newline < 0 else newline
        if keyword is None:
            return Member(self, 'statement', (), None, offset, finish, first, None, conditional)
        if self.tokens[keyword][0] == 'hash':
            return Member(self, 'macro', (self.text(keyword),), None, offset, finish, keyword, None, conditional)
        kind = self.text(keyword)
        names, selector = self.names(kind, keyword, end)
        modifiers, k = [], first
        while k < keyword:
            if self.tokens[k][0] == 'word' and self.text(k) in MODIFIERS:
                modifiers.append(self.text(k))
            k = self.pairs[k] + 1 if self.tokens[k][0] in OPEN else k + 1
        body = None
        if kind in TYPES:
            k = keyword
            while k <= end and self.tokens[k][0] != '{':
                k = self.pairs[k] + 1 if self.tokens[k][0] in ('(', '[') else k + 1
            if k > end:
                raise ExtractError(f'{self.display}:{self.line(self.tokens[keyword][1])}: {kind} without a body')
            body = (k, self.pairs[k])
        return Member(self, kind, names, selector, offset, finish, keyword, body, conditional, tuple(modifiers))

    def names(self, kind, keyword, end):
        """The names a declaration introduces and, for a function, its selector."""
        k = self.next(keyword + 1, end + 1)
        bare = self.text(k).strip('`') if k <= end else ''
        if kind in ('init', 'subscript', 'func'):
            name = bare if kind == 'func' else kind
            if kind == 'func':
                k += 1
            while k <= end and self.tokens[k][0] == 'op' and self.text(k) in ('?', '!'):
                k += 1
            k = self.generics(k, end)
            if k > end or self.tokens[k][0] != '(':
                raise ExtractError(f'{self.display}:{self.line(self.tokens[keyword][1])}: '
                                   f'could not read the parameters of {name}')
            # Subscript parameters, and all of an operator's, have no label unless given one.
            unlabeled = 'all' if kind == 'func' and OPERATOR.fullmatch(name) else 'single' if kind == 'subscript' else ''
            return (name,), name + self.labels(k, unlabeled)
        if kind == 'deinit':
            return ('deinit',), 'deinit'
        if kind == 'extension':
            name = bare
            while k + 2 <= end and self.text(k + 1) == '.' and self.tokens[k + 2][0] == 'word':
                name, k = name + '.' + self.text(k + 2), k + 2
            return (f'extension {name}',), None
        if kind == 'import':
            return (f'import {self.source[self.tokens[k][1]:self.tokens[end][2]]}',), None
        if kind == 'case':
            names, expecting = [], True
            while k <= end:
                if self.tokens[k][0] == 'word' and expecting:
                    names.append(self.text(k).strip('`'))
                    expecting = False
                elif self.tokens[k][0] == ',':
                    expecting = True
                elif self.tokens[k][0] in OPEN:
                    k = self.pairs[k]
                k += 1
            return tuple(names), None
        if kind in ('var', 'let'):
            return ((bare,), bare) if self.tokens[k][0] == 'word' else ((), None)
        return (bare,), None

    def generics(self, k, end):
        """The token after a generic parameter clause at k, or k when there is none."""
        if k > end or self.tokens[k][0] != 'op' or not self.text(k).startswith('<'):
            return k
        depth = 0
        while k <= end:
            if self.tokens[k][0] == 'op':
                text = self.text(k).replace('->', '')
                depth += text.count('<') - text.count('>')
            elif self.tokens[k][0] in OPEN:
                k = self.pairs[k]
            k += 1
            if depth <= 0:
                break
        return k

    def labels(self, k, unlabeled):
        """The selector suffix, such as `(_:from:)`, for the parameter clause opening at k.
        Angle brackets count as generic depth in types only, never in a default value."""
        close, labels, names, depth, expecting, default = self.pairs[k], [], [], 0, True, False
        k += 1
        while k < close:
            kind, text = self.tokens[k][0], self.text(k)
            if kind in OPEN:
                k = self.pairs[k]
            elif kind == 'op' and text.startswith('=') and not text.startswith('==') and depth == 0:
                default = True
            elif kind == 'op' and not default:
                text = text.replace('->', '')
                depth = max(0, depth + text.count('<') - text.count('>'))
            elif kind == ',' and (default or depth == 0):
                names, expecting, default = [], True, False
            elif kind == ':' and expecting:
                if len(names) not in (1, 2):
                    raise ExtractError(f'{self.display}:{self.line(self.tokens[k][1])}: '
                                       'could not read a parameter label')
                bare = unlabeled == 'all' or unlabeled == 'single' and len(names) == 1
                labels.append(('_' if bare else names[0]) + ':')
                names, expecting = [], False
            elif kind == 'word' and expecting:
                names.append(text.strip('`'))
            k += 1
        return '(' + ''.join(labels) + ')'


def main(argv):
    if len(argv) not in (2, 3):
        print(__doc__.strip().split('\n\n')[-1], file=sys.stderr)
        return 2
    scope = SwiftFile(argv[1])
    if len(argv) == 3:
        scope = scope.type(argv[2])
    for member in scope.members:
        label = member.selector or ' '.join(member.names) or '(statement)'
        print(f"{member.line:6}  {member.kind:15} {label}{'  (inside #if)' if member.conditional else ''}")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
