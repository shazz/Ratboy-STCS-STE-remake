"""Parser for 68000 assembly — builds IR from tokens."""

from __future__ import annotations
import re
from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Iterator

from .lexer import Token, TokenType, tokenize, tokenize_file


class EAMode(Enum):
    """68000 effective addressing modes."""
    DN = auto()          # Dn
    AN = auto()          # An
    IND = auto()         # (An)
    POSTINC = auto()     # (An)+
    PREDEC = auto()      # -(An)
    D_AN = auto()        # d(An) or (d,An)
    D_AN_RI = auto()     # d(An,Ri) or (d,An,Ri)
    ABS_W = auto()       # xxx.w
    ABS_L = auto()       # xxx.l or label
    D_PC = auto()        # d(pc) or label(pc)
    D_PC_RI = auto()     # d(pc,Ri)
    IMM = auto()         # #xxx
    REGLIST = auto()     # movem register list
    SR = auto()          # sr
    CCR = auto()         # ccr
    USP = auto()         # usp


@dataclass(frozen=True, slots=True)
class EA:
    """Parsed effective address."""
    mode: EAMode
    reg: str | None = None       # register name (d0, a3, etc.)
    index: str | None = None     # index register for D_AN_RI modes
    disp: str | None = None      # displacement or label
    size: str | None = None      # index size (.w or .l)
    raw: str = ''                # original text


@dataclass(slots=True)
class Instr:
    """Parsed instruction."""
    mnemonic: str
    size: str | None              # 'b', 'w', 'l', 's', or None
    src_ea: EA | None
    dst_ea: EA | None
    label: str | None             # label on this line
    line: int
    raw: str
    annot: dict = field(default_factory=dict)
    is_rept_expanded: bool = False


@dataclass(slots=True)
class Directive:
    """Parsed directive (dc, ds, equ, etc.)."""
    name: str
    size: str | None
    operand: str
    label: str | None
    line: int
    raw: str


@dataclass(slots=True)
class ReptBlock:
    """REPT/ENDR block."""
    count: int
    instrs: list[Instr | Directive]
    line: int


# Register patterns
_RE_DN = re.compile(r'^d([0-7])$', re.I)
_RE_AN = re.compile(r'^a([0-7])$', re.I)
_RE_SP = re.compile(r'^sp$', re.I)

# EA patterns (order matters — more specific first)
_RE_PREDEC = re.compile(r'^-\((a[0-7]|sp)\)$', re.I)
_RE_POSTINC = re.compile(r'^\((a[0-7]|sp)\)\+$', re.I)
_RE_IND = re.compile(r'^\((a[0-7]|sp)\)$', re.I)
_RE_D_AN_RI = re.compile(
    r'^([^(]*)\((a[0-7]|sp)\s*,\s*(d[0-7]|a[0-7])(?:\.(w|l))?\)$', re.I
)
_RE_D_AN = re.compile(r'^([^(]*)\((a[0-7]|sp)\)$', re.I)
_RE_D_PC_RI = re.compile(
    r'^([^(]*)\(pc\s*,\s*(d[0-7]|a[0-7])(?:\.(w|l))?\)$', re.I
)
_RE_D_PC = re.compile(r'^([^(]*)\(pc\)$', re.I)
_RE_IMM = re.compile(r'^#(.+)$', re.I)
_RE_ABS_W = re.compile(r'^(.+)\.w$', re.I)
_RE_ABS_L = re.compile(r'^(.+)\.l$', re.I)


def parse_ea(text: str) -> EA:
    """Parse a single effective address operand."""
    text = text.strip()
    raw = text

    # Data register
    if _RE_DN.match(text):
        return EA(EAMode.DN, reg=text.lower(), raw=raw)

    # Address register (including sp)
    if _RE_AN.match(text) or _RE_SP.match(text):
        reg = 'a7' if text.lower() == 'sp' else text.lower()
        return EA(EAMode.AN, reg=reg, raw=raw)

    # Special registers
    if text.lower() == 'sr':
        return EA(EAMode.SR, raw=raw)
    if text.lower() == 'ccr':
        return EA(EAMode.CCR, raw=raw)
    if text.lower() == 'usp':
        return EA(EAMode.USP, raw=raw)

    # Pre-decrement -(An)
    m = _RE_PREDEC.match(text)
    if m:
        reg = 'a7' if m.group(1).lower() == 'sp' else m.group(1).lower()
        return EA(EAMode.PREDEC, reg=reg, raw=raw)

    # Post-increment (An)+
    m = _RE_POSTINC.match(text)
    if m:
        reg = 'a7' if m.group(1).lower() == 'sp' else m.group(1).lower()
        return EA(EAMode.POSTINC, reg=reg, raw=raw)

    # Indirect (An)
    m = _RE_IND.match(text)
    if m:
        reg = 'a7' if m.group(1).lower() == 'sp' else m.group(1).lower()
        return EA(EAMode.IND, reg=reg, raw=raw)

    # d(An,Ri)
    m = _RE_D_AN_RI.match(text)
    if m:
        disp = m.group(1).strip() or '0'
        reg = 'a7' if m.group(2).lower() == 'sp' else m.group(2).lower()
        idx = m.group(3).lower()
        sz = m.group(4).lower() if m.group(4) else 'w'
        return EA(EAMode.D_AN_RI, reg=reg, index=idx, disp=disp, size=sz, raw=raw)

    # d(An)
    m = _RE_D_AN.match(text)
    if m:
        disp = m.group(1).strip() or '0'
        reg = 'a7' if m.group(2).lower() == 'sp' else m.group(2).lower()
        return EA(EAMode.D_AN, reg=reg, disp=disp, raw=raw)

    # d(pc,Ri)
    m = _RE_D_PC_RI.match(text)
    if m:
        disp = m.group(1).strip() or '0'
        idx = m.group(2).lower()
        sz = m.group(3).lower() if m.group(3) else 'w'
        return EA(EAMode.D_PC_RI, index=idx, disp=disp, size=sz, raw=raw)

    # d(pc)
    m = _RE_D_PC.match(text)
    if m:
        disp = m.group(1).strip() or '0'
        return EA(EAMode.D_PC, disp=disp, raw=raw)

    # Immediate #xxx
    m = _RE_IMM.match(text)
    if m:
        return EA(EAMode.IMM, disp=m.group(1), raw=raw)

    # Check for register list (movem)
    if '/' in text or '-' in text:
        # Looks like d0-d3/a0-a2 or similar
        if any(c in text.lower() for c in 'da'):
            return EA(EAMode.REGLIST, disp=text, raw=raw)

    # Absolute with explicit size
    m = _RE_ABS_W.match(text)
    if m:
        return EA(EAMode.ABS_W, disp=m.group(1), raw=raw)

    m = _RE_ABS_L.match(text)
    if m:
        return EA(EAMode.ABS_L, disp=m.group(1), raw=raw)

    # Default: assume label or absolute long
    return EA(EAMode.ABS_L, disp=text, raw=raw)


def split_operands(operand_str: str) -> tuple[str | None, str | None]:
    """Split operand string into src and dst, handling nested parens."""
    if not operand_str:
        return None, None

    # Find comma that's not inside parentheses
    depth = 0
    in_string = False
    string_char = None

    for i, c in enumerate(operand_str):
        if not in_string:
            if c in '"\'':
                in_string = True
                string_char = c
            elif c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
            elif c == ',' and depth == 0:
                src = operand_str[:i].strip()
                dst = operand_str[i + 1:].strip()
                return src or None, dst or None
        else:
            if c == string_char:
                in_string = False

    # No comma found — single operand
    return operand_str.strip(), None


def parse_annotation(comment: str) -> dict:
    """Parse @cycles annotation from comment."""
    annot = {}
    if '@cycles' not in comment:
        return annot

    # Extract key=value pairs after @cycles
    m = re.search(r'@cycles\s+(.+?)(?:;|$)', comment)
    if not m:
        m = re.search(r'@cycles\s*$', comment)
        if m:
            return {'present': True}
        return annot

    pairs = m.group(1)
    for pair in re.finditer(r'(\w+)=(\S+)', pairs):
        key, val = pair.groups()
        # Convert types
        if val.lower() == 'true':
            annot[key] = True
        elif val.lower() == 'false':
            annot[key] = False
        elif val.isdigit():
            annot[key] = int(val)
        else:
            annot[key] = val

    return annot


def parse_size(mnemonic: str) -> tuple[str, str | None]:
    """Extract base mnemonic and size suffix."""
    if '.' in mnemonic:
        base, size = mnemonic.rsplit('.', 1)
        return base, size if size in 'bwls' else None
    return mnemonic, None


ParsedItem = Instr | Directive


def parse_tokens(tokens: Iterator[Token]) -> Iterator[ParsedItem]:
    """Parse token stream into instructions and directives."""
    tokens_list = list(tokens)
    i = 0
    current_label: str | None = None
    pending_comment: str | None = None
    rept_stack: list[tuple[int, list[ParsedItem]]] = []

    while i < len(tokens_list):
        tok = tokens_list[i]

        if tok.type == TokenType.EOF:
            break

        if tok.type == TokenType.NEWLINE:
            # Don't reset current_label — it persists until consumed by an instr
            pending_comment = None
            i += 1
            continue

        if tok.type == TokenType.COMMENT:
            pending_comment = tok.value
            i += 1
            continue

        if tok.type == TokenType.LABEL:
            current_label = tok.value
            i += 1
            continue

        if tok.type == TokenType.DIRECTIVE:
            base, size = parse_size(tok.value)

            # Get operand
            operand = ''
            if i + 1 < len(tokens_list) and tokens_list[i + 1].type == TokenType.OPERAND:
                operand = tokens_list[i + 1].value
                i += 1

            # Handle REPT
            if base == 'rept':
                try:
                    count = int(operand.strip())
                except ValueError:
                    count = 1
                rept_stack.append((count, []))
                i += 1
                continue

            # Handle ENDR
            if base == 'endr':
                if rept_stack:
                    count, body = rept_stack.pop()
                    # Expand the REPT block
                    for rep_idx in range(count):
                        for item in body:
                            if isinstance(item, Instr):
                                # Preserve label only on first iteration
                                lbl = item.label if rep_idx == 0 else None
                                expanded = Instr(
                                    mnemonic=item.mnemonic,
                                    size=item.size,
                                    src_ea=item.src_ea,
                                    dst_ea=item.dst_ea,
                                    label=lbl,
                                    line=item.line,
                                    raw=item.raw,
                                    annot=item.annot,
                                    is_rept_expanded=True,
                                )
                                if rept_stack:
                                    rept_stack[-1][1].append(expanded)
                                else:
                                    yield expanded
                            else:
                                if rept_stack:
                                    rept_stack[-1][1].append(item)
                                else:
                                    yield item
                i += 1
                continue

            raw_line = f"{current_label + ': ' if current_label else ''}{tok.value} {operand}"
            directive = Directive(
                name=base,
                size=size,
                operand=operand,
                label=current_label,
                line=tok.line,
                raw=raw_line.strip(),
            )

            if rept_stack:
                rept_stack[-1][1].append(directive)
            else:
                yield directive

            current_label = None
            i += 1
            continue

        if tok.type == TokenType.MNEMONIC:
            base, size = parse_size(tok.value)

            # Get operand
            operand_str = ''
            if i + 1 < len(tokens_list) and tokens_list[i + 1].type == TokenType.OPERAND:
                operand_str = tokens_list[i + 1].value
                i += 1

            # Check for comment with annotation
            annot = {}
            if i + 1 < len(tokens_list) and tokens_list[i + 1].type == TokenType.COMMENT:
                annot = parse_annotation(tokens_list[i + 1].value)

            # Also check pending comment
            if pending_comment:
                annot.update(parse_annotation(pending_comment))

            # Parse operands
            src_str, dst_str = split_operands(operand_str)
            src_ea = parse_ea(src_str) if src_str else None
            dst_ea = parse_ea(dst_str) if dst_str else None

            raw_line = f"{current_label + ': ' if current_label else ''}{tok.value} {operand_str}"
            instr = Instr(
                mnemonic=base,
                size=size,
                src_ea=src_ea,
                dst_ea=dst_ea,
                label=current_label,
                line=tok.line,
                raw=raw_line.strip(),
                annot=annot,
            )

            if rept_stack:
                rept_stack[-1][1].append(instr)
            else:
                yield instr

            current_label = None
            i += 1
            continue

        i += 1


def parse_source(source: str) -> list[ParsedItem]:
    """Parse assembly source string."""
    return list(parse_tokens(tokenize(source)))


def parse_file(path: str) -> list[ParsedItem]:
    """Parse assembly file."""
    return list(parse_tokens(tokenize_file(path)))
