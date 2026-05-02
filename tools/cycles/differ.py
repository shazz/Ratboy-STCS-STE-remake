"""Diff analyzer — compare our code against CONFO.S (1988 original)."""

from __future__ import annotations
from dataclasses import dataclass
from pathlib import Path

from .analyzer import analyze_file, RoutineAnalysis, FileAnalysis
from .symbols import SymbolTable


# Mapping of our routines to CONFO.S equivalents
# Format: our_name -> (confo_name, notes)
ROUTINE_MAP = {
    'ScrollShiftAndFill': ('scrolg', 'Main scroll shift routine'),
    'ScrollRenderNextPword': ('scroh', 'Render next character slice'),
    'ScrollPlotType1': ('type1', 'Effect 1 - vertical double'),
    'ScrollPlotType2': ('type2', 'Effect 2'),
    'ScrollPlotType3': ('type3', 'Effect 3'),
    'ScrollPlotType4': ('type4', 'Effect 4'),
    'ScrollPlotType5': ('type5', 'Effect 5'),
    'ScrollPlotType7': ('type7', 'Effect 7 - sine wave'),
}


@dataclass
class RoutineDiff:
    """Comparison between our routine and the original."""
    our_name: str
    original_name: str
    our_cycles: int
    original_cycles: int
    delta: int
    delta_pct: float
    notes: str


@dataclass
class FileDiff:
    """Full comparison between our code and original."""
    our_analysis: FileAnalysis
    original_analysis: FileAnalysis
    routine_diffs: list[RoutineDiff]
    total_our: int
    total_original: int
    total_delta: int


def find_routine_by_name(analysis: FileAnalysis, name: str) -> RoutineAnalysis | None:
    """Find a routine by name in an analysis."""
    for r in analysis.routines:
        if r.name == name:
            return r
    return None


def diff_files(
    our_path: str | Path,
    original_path: str | Path,
    our_symbols: SymbolTable | None = None,
    original_symbols: SymbolTable | None = None,
) -> FileDiff:
    """Compare our code against the original CONFO.S."""
    our_analysis = analyze_file(our_path, our_symbols)
    original_analysis = analyze_file(original_path, original_symbols)

    diffs = []

    for our_name, (orig_name, notes) in ROUTINE_MAP.items():
        our_routine = find_routine_by_name(our_analysis, our_name)
        orig_routine = find_routine_by_name(original_analysis, orig_name)

        if our_routine and orig_routine:
            delta = our_routine.total_cycles - orig_routine.total_cycles
            delta_pct = (delta / orig_routine.total_cycles * 100) if orig_routine.total_cycles > 0 else 0

            diffs.append(RoutineDiff(
                our_name=our_name,
                original_name=orig_name,
                our_cycles=our_routine.total_cycles,
                original_cycles=orig_routine.total_cycles,
                delta=delta,
                delta_pct=delta_pct,
                notes=notes,
            ))

    total_our = sum(d.our_cycles for d in diffs)
    total_original = sum(d.original_cycles for d in diffs)

    return FileDiff(
        our_analysis=our_analysis,
        original_analysis=original_analysis,
        routine_diffs=diffs,
        total_our=total_our,
        total_original=total_original,
        total_delta=total_our - total_original,
    )


def format_diff_report(diff: FileDiff) -> str:
    """Format the diff as a text report."""
    lines = []
    lines.append("=" * 85)
    lines.append("CODE COMPARISON: engine.s vs CONFO.S (1988 original)")
    lines.append("=" * 85)
    lines.append("")

    if not diff.routine_diffs:
        lines.append("No matching routines found for comparison.")
        return '\n'.join(lines)

    lines.append(f"{'Our Routine':<25} {'CONFO.S':<15} {'Ours':>10} {'Orig':>10} {'Delta':>10} {'%':>8}")
    lines.append("-" * 85)

    for d in sorted(diff.routine_diffs, key=lambda x: -abs(x.delta)):
        sign = '+' if d.delta > 0 else ''
        status = '✓' if abs(d.delta_pct) < 10 else ('!' if d.delta > 0 else '★')
        lines.append(
            f"{d.our_name:<25} {d.original_name:<15} {d.our_cycles:>10,} "
            f"{d.original_cycles:>10,} {sign}{d.delta:>9,} {d.delta_pct:>7.1f}% {status}"
        )

    lines.append("-" * 85)
    sign = '+' if diff.total_delta > 0 else ''
    total_pct = (diff.total_delta / diff.total_original * 100) if diff.total_original > 0 else 0
    lines.append(
        f"{'TOTAL (compared)':<25} {'':<15} {diff.total_our:>10,} "
        f"{diff.total_original:>10,} {sign}{diff.total_delta:>9,} {total_pct:>7.1f}%"
    )
    lines.append("")
    lines.append("Legend: ✓ = within 10%, ★ = faster than original, ! = slower than original")

    return '\n'.join(lines)


def analyze_confo_routines(confo_path: str | Path) -> str:
    """Analyze CONFO.S and list its routines."""
    analysis = analyze_file(confo_path)

    lines = []
    lines.append("=" * 70)
    lines.append("CONFO.S (1988 original) — Routine Analysis")
    lines.append("=" * 70)
    lines.append("")
    lines.append(f"{'Routine':<25} {'Lines':>12} {'Cycles':>12} {'~SL':>8}")
    lines.append("-" * 60)

    for r in sorted(analysis.routines, key=lambda x: -x.total_cycles):
        sl = r.total_cycles / 512
        lines.append(f"{r.name:<25} {r.start_line:>5}-{r.end_line:<5} {r.total_cycles:>12,} {sl:>8.1f}")

    lines.append("")
    lines.append("Key routines to match:")
    lines.append("  scrolg — main scroll shift (our: ScrollShiftAndFill)")
    lines.append("  scroh  — render next char (our: ScrollRenderNextPword)")
    lines.append("  scrol0 — copy to screen (our: ScrollPlot)")

    return '\n'.join(lines)
