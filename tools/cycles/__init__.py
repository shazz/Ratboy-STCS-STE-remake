"""68000 cycle counter and optimization finder."""

from .lexer import Token, TokenType, tokenize, tokenize_file
from .parser import (
    EA, EAMode, Instr, Directive,
    parse_ea, parse_source, parse_file,
)
from .timings import cycles_for, CycleResult, TABLE
from .symbols import SymbolTable, load_project_symbols
from .analyzer import analyze_file, RoutineAnalysis, FileAnalysis
from .patterns import find_patterns, Match, Pattern, ALL_PATTERNS
from .ste_model import (
    apply_contention, ExecutionContext, ContentionResult,
    CONTENTION_VBLANK, CONTENTION_VISIBLE,
)

__all__ = [
    'Token', 'TokenType', 'tokenize', 'tokenize_file',
    'EA', 'EAMode', 'Instr', 'Directive',
    'parse_ea', 'parse_source', 'parse_file',
    'cycles_for', 'CycleResult', 'TABLE',
    'SymbolTable', 'load_project_symbols',
    'analyze_file', 'RoutineAnalysis', 'FileAnalysis',
    'find_patterns', 'Match', 'Pattern', 'ALL_PATTERNS',
    'apply_contention', 'ExecutionContext', 'ContentionResult',
    'CONTENTION_VBLANK', 'CONTENTION_VISIBLE',
]
