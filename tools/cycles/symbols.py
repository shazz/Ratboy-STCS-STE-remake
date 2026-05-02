"""Symbol table and expression evaluator for EQU directives."""

from __future__ import annotations
import re
from pathlib import Path
from typing import Iterator

from .parser import Directive, parse_file


class SymbolTable:
    """Symbol table for EQU values with expression evaluation."""

    def __init__(self) -> None:
        self._symbols: dict[str, int] = {}
        self._raw: dict[str, str] = {}  # original expressions

    def define(self, name: str, expr: str) -> None:
        """Define a symbol with an expression."""
        self._raw[name] = expr
        # Try to evaluate immediately
        try:
            self._symbols[name] = self.evaluate(expr)
        except (ValueError, KeyError):
            pass  # Will try again when needed

    def get(self, name: str) -> int | None:
        """Get symbol value, evaluating if needed."""
        if name in self._symbols:
            return self._symbols[name]
        if name in self._raw:
            try:
                val = self.evaluate(self._raw[name])
                self._symbols[name] = val
                return val
            except (ValueError, KeyError):
                return None
        return None

    def evaluate(self, expr: str) -> int:
        """Evaluate an expression to an integer."""
        expr = expr.strip()

        # Handle hex ($xxx or 0x...)
        if expr.startswith('$'):
            return int(expr[1:], 16)
        if expr.startswith('0x'):
            return int(expr, 16)

        # Handle binary (%...)
        if expr.startswith('%'):
            return int(expr[1:], 2)

        # Handle simple integer
        if expr.lstrip('-').isdigit():
            return int(expr)

        # Handle character literal ('x')
        if len(expr) == 3 and expr[0] == "'" and expr[2] == "'":
            return ord(expr[1])

        # Tokenize and evaluate expression
        return self._eval_expr(expr)

    def _eval_expr(self, expr: str) -> int:
        """Evaluate arithmetic expression with symbols."""
        # Replace symbols with their values
        result = expr

        # Find all symbol references (uppercase identifiers)
        for match in re.finditer(r'\b([A-Z_][A-Z0-9_]*)\b', expr):
            sym = match.group(1)
            val = self.get(sym)
            if val is not None:
                result = result.replace(sym, str(val))

        # Replace hex values
        result = re.sub(r'\$([0-9A-Fa-f]+)', r'0x\1', result)

        # Safe eval with only arithmetic
        try:
            # Only allow safe operations
            allowed = set('0123456789+-*/()&|^~<> ')
            if not all(c in allowed or c == 'x' for c in result):
                raise ValueError(f"Unsafe expression: {result}")
            return int(eval(result, {"__builtins__": {}}, {}))
        except Exception as e:
            raise ValueError(f"Cannot evaluate: {expr} -> {result}") from e

    def load_from_file(self, path: str | Path) -> int:
        """Load EQU definitions from an assembly file. Returns count loaded."""
        items = parse_file(str(path))
        count = 0
        for item in items:
            if isinstance(item, Directive) and item.name == 'equ' and item.label:
                self.define(item.label, item.operand)
                count += 1
        return count

    def load_from_dir(self, directory: str | Path, pattern: str = '*.s') -> int:
        """Load EQU definitions from all matching files in a directory."""
        directory = Path(directory)
        count = 0
        for path in sorted(directory.rglob(pattern)):
            count += self.load_from_file(path)
        return count

    def __len__(self) -> int:
        return len(self._raw)

    def __contains__(self, name: str) -> bool:
        return name in self._raw

    def items(self) -> Iterator[tuple[str, int | None]]:
        """Iterate over (name, value) pairs."""
        for name in self._raw:
            yield name, self.get(name)


def load_project_symbols(src_dir: str | Path) -> SymbolTable:
    """Load all symbols from a project's source directory."""
    table = SymbolTable()
    table.load_from_dir(src_dir)
    return table
