"""Lexer for vasm Motorola 68000 assembly syntax."""

from __future__ import annotations
import re
from dataclasses import dataclass
from enum import Enum, auto
from typing import Iterator


class TokenType(Enum):
    LABEL = auto()
    MNEMONIC = auto()
    OPERAND = auto()
    DIRECTIVE = auto()
    COMMENT = auto()
    STRING = auto()
    NEWLINE = auto()
    EOF = auto()


@dataclass(frozen=True, slots=True)
class Token:
    type: TokenType
    value: str
    line: int
    col: int


DIRECTIVES = frozenset({
    'equ', 'dc', 'ds', 'even', 'odd', 'align', 'section', 'org',
    'include', 'incbin', 'incdir', 'ifne', 'ifeq', 'ifgt', 'ifge',
    'iflt', 'ifle', 'else', 'endif', 'endc', 'rept', 'endr',
    'macro', 'endm', 'set', 'xdef', 'xref', 'public', 'extern',
})

MNEMONICS = frozenset({
    'abcd', 'add', 'adda', 'addi', 'addq', 'addx', 'and', 'andi',
    'asl', 'asr', 'bcc', 'bcs', 'beq', 'bge', 'bgt', 'bhi', 'ble',
    'bls', 'blt', 'bmi', 'bne', 'bpl', 'bra', 'bset', 'bsr', 'btst',
    'bclr', 'bchg', 'bvc', 'bvs', 'chk', 'clr', 'cmp', 'cmpa', 'cmpi',
    'cmpm', 'dbcc', 'dbcs', 'dbeq', 'dbf', 'dbge', 'dbgt', 'dbhi',
    'dble', 'dbls', 'dblt', 'dbmi', 'dbne', 'dbpl', 'dbra', 'dbt',
    'dbvc', 'dbvs', 'divs', 'divu', 'eor', 'eori', 'exg', 'ext',
    'illegal', 'jmp', 'jsr', 'lea', 'link', 'lsl', 'lsr', 'move',
    'movea', 'movem', 'movep', 'moveq', 'muls', 'mulu', 'nbcd', 'neg',
    'negx', 'nop', 'not', 'or', 'ori', 'pea', 'reset', 'rol', 'ror',
    'roxl', 'roxr', 'rte', 'rtr', 'rts', 'sbcd', 'scc', 'scs', 'seq',
    'sf', 'sge', 'sgt', 'shi', 'sle', 'sls', 'slt', 'smi', 'sne',
    'spl', 'st', 'stop', 'sub', 'suba', 'subi', 'subq', 'subx',
    'svc', 'svs', 'swap', 'tas', 'trap', 'trapv', 'tst', 'unlk',
})

_RE_LABEL = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*|\.[A-Za-z_][A-Za-z0-9_]*):')
_RE_LABEL_NO_COLON = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)(?=\s+equ\s)', re.I)
# Label at col 0 followed by tab/space then mnemonic (CONFO.S style)
_RE_LABEL_COL0 = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)(?=[\t ]+[A-Za-z])')
_RE_WORD = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
_RE_WHITESPACE = re.compile(r'[ \t]+')


def tokenize_line(line: str, lineno: int) -> list[Token]:
    """Tokenize a single line of assembly. Returns list of tokens."""
    tokens: list[Token] = []
    pos = 0
    original = line

    # Strip trailing newline but keep for position tracking
    line = line.rstrip('\n\r')
    if not line:
        return [Token(TokenType.NEWLINE, '', lineno, 0)]

    # Check for full-line comment (* at column 0)
    if line.startswith('*'):
        return [
            Token(TokenType.COMMENT, line, lineno, 0),
            Token(TokenType.NEWLINE, '', lineno, len(line)),
        ]

    # Check for label at start of line (with colon)
    m = _RE_LABEL.match(line)
    if m:
        label = m.group(1)
        tokens.append(Token(TokenType.LABEL, label, lineno, pos))
        pos = m.end()
    else:
        # Check for EQU-style label (no colon): NAME equ VALUE
        m = _RE_LABEL_NO_COLON.match(line)
        if m:
            label = m.group(1)
            tokens.append(Token(TokenType.LABEL, label, lineno, pos))
            pos = m.end()
        else:
            # Check for col-0 label followed by instruction or directive (CONFO.S style)
            m = _RE_LABEL_COL0.match(line)
            if m:
                label = m.group(1)
                # Only if it's not a known mnemonic or directive itself
                if label.lower() not in MNEMONICS and label.lower() not in DIRECTIVES:
                    tokens.append(Token(TokenType.LABEL, label, lineno, pos))
                    pos = m.end()
            else:
                # Check for label followed by directive (e.g., "sc_blkg REPT 38")
                m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)(?=[\t ]+(?:rept|dc|ds|equ)\b)', line, re.I)
                if m:
                    label = m.group(1)
                    if label.lower() not in MNEMONICS and label.lower() not in DIRECTIVES:
                        tokens.append(Token(TokenType.LABEL, label, lineno, pos))
                        pos = m.end()
    # Skip whitespace
    m = _RE_WHITESPACE.match(line, pos)
    if m:
        pos = m.end()

    # Check for ; comment after optional whitespace only
    if pos < len(line) and line[pos] == ';':
        tokens.append(Token(TokenType.COMMENT, line[pos:], lineno, pos))
        tokens.append(Token(TokenType.NEWLINE, '', lineno, len(line)))
        return tokens

    # Nothing left after label?
    if pos >= len(line):
        tokens.append(Token(TokenType.NEWLINE, '', lineno, len(line)))
        return tokens

    # Expect mnemonic or directive
    m = _RE_WORD.match(line, pos)
    if not m:
        # Could be a macro call or something unexpected
        tokens.append(Token(TokenType.NEWLINE, '', lineno, len(line)))
        return tokens

    word = m.group(0)
    word_start = pos
    pos = m.end()

    # Check for size suffix (.b, .w, .l, .s)
    size = None
    if pos < len(line) and line[pos] == '.':
        if pos + 1 < len(line) and line[pos + 1].lower() in 'bwls':
            size = line[pos + 1].lower()
            pos += 2

    word_lower = word.lower()
    word_with_size = f"{word_lower}.{size}" if size else word_lower

    # Classify: directive, mnemonic, or macro
    if word_lower in DIRECTIVES or (word_lower in ('dc', 'ds') and size):
        tokens.append(Token(TokenType.DIRECTIVE, word_with_size, lineno, word_start))
    elif word_lower in MNEMONICS:
        tokens.append(Token(TokenType.MNEMONIC, word_with_size, lineno, word_start))
    else:
        # Assume macro invocation — treat as mnemonic for now
        tokens.append(Token(TokenType.MNEMONIC, word, lineno, word_start))

    # Skip whitespace before operands
    m = _RE_WHITESPACE.match(line, pos)
    if m:
        pos = m.end()

    # Rest until comment is operands
    if pos < len(line):
        # Find comment start (but not inside strings)
        operand_end = len(line)
        in_string = False
        string_char = None
        for i in range(pos, len(line)):
            c = line[i]
            if not in_string:
                if c in '"\'':
                    in_string = True
                    string_char = c
                elif c == ';':
                    operand_end = i
                    break
            else:
                if c == string_char:
                    in_string = False

        operand = line[pos:operand_end].rstrip()
        if operand:
            tokens.append(Token(TokenType.OPERAND, operand, lineno, pos))

        if operand_end < len(line):
            tokens.append(Token(TokenType.COMMENT, line[operand_end:], lineno, operand_end))

    tokens.append(Token(TokenType.NEWLINE, '', lineno, len(line)))
    return tokens


def tokenize(source: str) -> Iterator[Token]:
    """Tokenize full assembly source. Yields tokens."""
    for lineno, line in enumerate(source.splitlines(keepends=True), start=1):
        yield from tokenize_line(line, lineno)
    yield Token(TokenType.EOF, '', lineno + 1 if source else 1, 0)


def tokenize_file(path: str) -> Iterator[Token]:
    """Tokenize assembly file. Yields tokens."""
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        source = f.read()
    yield from tokenize(source)
