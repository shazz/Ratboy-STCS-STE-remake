"""STE Shifter contention model.

On the Atari ST/STE, the CPU and Shifter share the bus. During visible
scanlines, the Shifter steals cycles for video DMA, making CPU code
run slower. This module models that contention.

Key facts (from docs/LEARNINGS.md):
- VBlank (113 scanlines): CPU has full bus access, ~8 cycles/word
- Visible (200 scanlines): Shifter contention, ~12 cycles/word average
- Contention factor: roughly 50% overhead (12/8 = 1.5x)

The exact contention depends on instruction mix and timing, but
40-50% overhead is a good approximation for memory-intensive code.
"""

from __future__ import annotations
from dataclasses import dataclass
from enum import Enum, auto

from .analyzer import RoutineAnalysis, FileAnalysis


class ExecutionContext(Enum):
    """When code runs relative to the display."""
    VBLANK = auto()      # During vertical blank (no contention)
    VISIBLE = auto()     # During visible scanlines (contention)
    MIXED = auto()       # Spans both regions
    UNKNOWN = auto()     # Not specified


# Contention factors
CONTENTION_VBLANK = 1.0      # No contention
CONTENTION_VISIBLE = 1.45    # ~45% overhead (conservative, actual is 40-50%)
CONTENTION_MIXED = 1.25      # Weighted average


@dataclass
class ContentionResult:
    """Cycle count with contention applied."""
    raw_cycles: int           # Cycles without contention
    effective_cycles: int     # Cycles with contention applied
    context: ExecutionContext
    contention_factor: float
    overhead_cycles: int      # Extra cycles due to contention
    overhead_scanlines: float # Extra scanlines due to contention


def apply_contention(
    cycles: int,
    context: ExecutionContext = ExecutionContext.VISIBLE,
) -> ContentionResult:
    """Apply Shifter contention to a cycle count."""
    factors = {
        ExecutionContext.VBLANK: CONTENTION_VBLANK,
        ExecutionContext.VISIBLE: CONTENTION_VISIBLE,
        ExecutionContext.MIXED: CONTENTION_MIXED,
        ExecutionContext.UNKNOWN: CONTENTION_VISIBLE,  # Assume worst case
    }

    factor = factors[context]
    effective = int(cycles * factor)
    overhead = effective - cycles

    return ContentionResult(
        raw_cycles=cycles,
        effective_cycles=effective,
        context=context,
        contention_factor=factor,
        overhead_cycles=overhead,
        overhead_scanlines=overhead / 512,
    )


# Known routine execution contexts (when they typically run)
ROUTINE_CONTEXTS = {
    # VBlank-only routines (run during VBL interrupt or early main loop)
    'ScrollerInit': ExecutionContext.VBLANK,

    # Main loop routines (run during visible scanlines)
    'ScrollerStepVblank': ExecutionContext.VISIBLE,
    'ScrollShiftAndFill': ExecutionContext.VISIBLE,
    'ScrollPlotDispatch': ExecutionContext.VISIBLE,
    'ScrollRenderNextPword': ExecutionContext.VISIBLE,
    'ScrollPlot': ExecutionContext.VISIBLE,
    'ScrollPlotType0': ExecutionContext.VISIBLE,
    'ScrollPlotType1': ExecutionContext.VISIBLE,
    'ScrollPlotType2': ExecutionContext.VISIBLE,
    'ScrollPlotType3': ExecutionContext.VISIBLE,
    'ScrollPlotType4': ExecutionContext.VISIBLE,
    'ScrollPlotType5': ExecutionContext.VISIBLE,
    'ScrollPlotType7': ExecutionContext.VISIBLE,

    # Clear routines (typically run once at init)
    'ClearScrollerRegion': ExecutionContext.VBLANK,
    'ClearScrollerRange': ExecutionContext.VBLANK,
}


def get_routine_context(name: str) -> ExecutionContext:
    """Get the execution context for a routine."""
    return ROUTINE_CONTEXTS.get(name, ExecutionContext.UNKNOWN)


def analyze_with_contention(analysis: RoutineAnalysis) -> ContentionResult:
    """Apply contention model to a routine analysis."""
    context = get_routine_context(analysis.name)
    return apply_contention(analysis.total_cycles, context)


def format_contention_report(file_analysis: FileAnalysis) -> str:
    """Format a contention-aware report for all routines."""
    lines = []
    lines.append("=" * 85)
    lines.append("STE CONTENTION MODEL — Effective Cycle Costs")
    lines.append("=" * 85)
    lines.append("")
    lines.append("Contention factors:")
    lines.append(f"  VBlank (no contention):  {CONTENTION_VBLANK:.2f}x")
    lines.append(f"  Visible (with Shifter):  {CONTENTION_VISIBLE:.2f}x")
    lines.append("")
    lines.append("-" * 85)
    lines.append(f"{'Routine':<30} {'Context':<10} {'Raw Cy':>10} {'Eff Cy':>10} {'Overhead':>10} {'~SL':>6}")
    lines.append("-" * 85)

    total_raw = 0
    total_eff = 0

    for routine in sorted(file_analysis.routines, key=lambda r: -r.total_cycles):
        result = analyze_with_contention(routine)
        total_raw += result.raw_cycles
        total_eff += result.effective_cycles

        ctx_name = result.context.name.lower()
        overhead_pct = ((result.contention_factor - 1) * 100)
        eff_sl = result.effective_cycles / 512

        lines.append(
            f"{routine.name:<30} {ctx_name:<10} {result.raw_cycles:>10,} "
            f"{result.effective_cycles:>10,} {overhead_pct:>9.0f}% {eff_sl:>6.1f}"
        )

    lines.append("-" * 85)
    total_overhead = total_eff - total_raw
    total_sl = total_eff / 512
    lines.append(
        f"{'TOTAL':<30} {'':<10} {total_raw:>10,} "
        f"{total_eff:>10,} {total_overhead:>10,} {total_sl:>6.1f}"
    )

    return '\n'.join(lines)


def format_frame_budget_with_contention(file_analysis: FileAnalysis) -> str:
    """Format frame budget with contention factored in."""
    CYCLES_PER_SL = 512
    TOTAL_SCANLINES = 313
    TOTAL_CYCLES = TOTAL_SCANLINES * CYCLES_PER_SL

    lines = []
    lines.append("=" * 75)
    lines.append("FRAME BUDGET WITH STE CONTENTION")
    lines.append("=" * 75)
    lines.append("")

    # Separate routines by context
    vblank_routines = []
    visible_routines = []

    for r in file_analysis.routines:
        ctx = get_routine_context(r.name)
        if ctx == ExecutionContext.VBLANK:
            vblank_routines.append(r)
        elif ctx in (ExecutionContext.VISIBLE, ExecutionContext.UNKNOWN):
            visible_routines.append(r)

    # Hot path (per-VBL routines, excluding init-only)
    hot_path_names = {
        'ScrollerStepVblank', 'ScrollShiftAndFill', 'ScrollPlotDispatch',
        'ScrollRenderNextPword', 'ScrollPlot',
    }
    plot_types = {
        'ScrollPlotType0', 'ScrollPlotType1', 'ScrollPlotType2',
        'ScrollPlotType3', 'ScrollPlotType4', 'ScrollPlotType5',
        'ScrollPlotType7',
    }

    hot_path = [r for r in visible_routines if r.name in hot_path_names]
    plot_routines = [r for r in visible_routines if r.name in plot_types]

    # Base cost (always runs, with contention)
    base_raw = sum(r.total_cycles for r in hot_path)
    base_contention = apply_contention(base_raw, ExecutionContext.VISIBLE)

    # Adjust for ScrollRenderNextPword running every 2nd VBL
    render_routine = next((r for r in hot_path if r.name == 'ScrollRenderNextPword'), None)
    if render_routine:
        render_adj = render_routine.total_cycles // 2
        base_raw -= render_adj
        base_contention = apply_contention(base_raw, ExecutionContext.VISIBLE)

    lines.append("Base cost (always runs, with contention):")
    lines.append(f"  Raw cycles:       {base_raw:>10,}")
    lines.append(f"  With contention:  {base_contention.effective_cycles:>10,} (+{base_contention.overhead_cycles:,})")
    lines.append(f"  Scanlines:        {base_contention.effective_cycles / CYCLES_PER_SL:>10.1f}")
    lines.append("")

    if plot_routines:
        heaviest = max(plot_routines, key=lambda r: r.total_cycles)
        lightest = min(plot_routines, key=lambda r: r.total_cycles)
        avg_raw = sum(r.total_cycles for r in plot_routines) // len(plot_routines)

        heavy_cont = apply_contention(heaviest.total_cycles, ExecutionContext.VISIBLE)
        light_cont = apply_contention(lightest.total_cycles, ExecutionContext.VISIBLE)
        avg_cont = apply_contention(avg_raw, ExecutionContext.VISIBLE)

        lines.append(f"Plot type costs (with contention):")
        lines.append(f"  Heaviest ({heaviest.name}):")
        lines.append(f"    Raw: {heaviest.total_cycles:,}  →  Effective: {heavy_cont.effective_cycles:,}")
        lines.append(f"  Lightest ({lightest.name}):")
        lines.append(f"    Raw: {lightest.total_cycles:,}  →  Effective: {light_cont.effective_cycles:,}")
        lines.append(f"  Average:")
        lines.append(f"    Raw: {avg_raw:,}  →  Effective: {avg_cont.effective_cycles:,}")
        lines.append("")

        # Worst case total
        worst_raw = base_raw + heaviest.total_cycles
        worst_cont = apply_contention(worst_raw, ExecutionContext.VISIBLE)
        best_raw = base_raw + lightest.total_cycles
        best_cont = apply_contention(best_raw, ExecutionContext.VISIBLE)

        lines.append("-" * 75)
        lines.append("Per-VBL totals:")
        lines.append("")
        lines.append(f"  Worst case ({heaviest.name}):")
        lines.append(f"    Raw:        {worst_raw:>10,} cycles ({worst_raw/CYCLES_PER_SL:.1f} sl)")
        lines.append(f"    Effective:  {worst_cont.effective_cycles:>10,} cycles ({worst_cont.effective_cycles/CYCLES_PER_SL:.1f} sl)")
        lines.append(f"    Margin:     {TOTAL_CYCLES - worst_cont.effective_cycles:>10,} cycles ({(TOTAL_CYCLES - worst_cont.effective_cycles)/CYCLES_PER_SL:.1f} sl)")
        lines.append("")
        lines.append(f"  Best case ({lightest.name}):")
        lines.append(f"    Raw:        {best_raw:>10,} cycles ({best_raw/CYCLES_PER_SL:.1f} sl)")
        lines.append(f"    Effective:  {best_cont.effective_cycles:>10,} cycles ({best_cont.effective_cycles/CYCLES_PER_SL:.1f} sl)")
        lines.append(f"    Margin:     {TOTAL_CYCLES - best_cont.effective_cycles:>10,} cycles ({(TOTAL_CYCLES - best_cont.effective_cycles)/CYCLES_PER_SL:.1f} sl)")

    return '\n'.join(lines)
