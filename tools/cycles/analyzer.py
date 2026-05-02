"""Per-routine cycle analyzer with loop detection and symbol evaluation."""

from __future__ import annotations
import re
from dataclasses import dataclass, field
from pathlib import Path

from .parser import Instr, Directive, parse_file, EAMode
from .timings import cycles_for, CycleResult
from .symbols import SymbolTable, load_project_symbols


@dataclass
class LoopInfo:
    """Information about a detected loop."""
    label: str
    start_idx: int
    end_idx: int
    iter_count: int
    body_cycles: int
    total_cycles: int


@dataclass
class RoutineAnalysis:
    """Analysis results for a single routine."""
    name: str
    start_line: int
    end_line: int
    instrs: list[tuple[Instr, CycleResult]]
    loops: list[LoopInfo]
    setup_cycles: int       # cycles before first loop
    total_cycles: int       # all cycles including loop iterations
    single_pass: int        # cycles for one pass (no loop multiplication)


@dataclass
class FileAnalysis:
    """Analysis results for an entire file."""
    path: Path
    routines: list[RoutineAnalysis]
    total_cycles: int
    symbols: SymbolTable


def evaluate_immediate(expr: str, symbols: SymbolTable) -> int | None:
    """Try to evaluate an immediate value expression."""
    expr = expr.strip().lstrip('#')

    # Direct integer
    if expr.lstrip('-').isdigit():
        return int(expr)

    # Hex
    if expr.startswith('$'):
        try:
            return int(expr[1:], 16)
        except ValueError:
            pass

    # Try symbol table evaluation
    try:
        return symbols.evaluate(expr)
    except (ValueError, KeyError):
        pass

    return None


def find_loops(
    instrs: list[tuple[Instr, CycleResult]],
    symbols: SymbolTable,
) -> list[LoopInfo]:
    """Find loops in instruction list and calculate their iteration counts."""
    loops: list[LoopInfo] = []

    # Build label -> index map
    label_idx: dict[str, int] = {}
    for idx, (instr, _) in enumerate(instrs):
        if instr.label:
            label_idx[instr.label] = idx

    # Find dbra/dbf that jump backward
    for idx, (instr, _) in enumerate(instrs):
        if instr.mnemonic not in ('dbra', 'dbf'):
            continue

        target = instr.dst_ea.disp if instr.dst_ea else None
        if not target or target not in label_idx:
            continue

        target_idx = label_idx[target]
        if target_idx >= idx:
            continue  # Forward jump, not a loop

        # Found a backward branch — it's a loop
        # Try to find iteration count from annotation or counter setup
        iter_count = instr.annot.get('iters', 0)

        if not iter_count and instr.src_ea and instr.src_ea.reg:
            counter_reg = instr.src_ea.reg
            # Search backward for counter init (up to 100 instrs for REPT-heavy code)
            for back_idx in range(idx - 1, max(0, idx - 100), -1):
                prev_instr, _ = instrs[back_idx]

                # moveq #N, Dn
                if prev_instr.mnemonic == 'moveq':
                    if prev_instr.dst_ea and prev_instr.dst_ea.reg == counter_reg:
                        if prev_instr.src_ea:
                            val = evaluate_immediate(prev_instr.src_ea.disp or '0', symbols)
                            if val is not None:
                                iter_count = val + 1  # dbra loops N+1 times
                        break

                # move.w #N, Dn
                if prev_instr.mnemonic == 'move' and prev_instr.size == 'w':
                    if prev_instr.dst_ea and prev_instr.dst_ea.reg == counter_reg:
                        if prev_instr.src_ea and prev_instr.src_ea.mode == EAMode.IMM:
                            val = evaluate_immediate(prev_instr.src_ea.disp or '0', symbols)
                            if val is not None:
                                iter_count = val + 1
                        break

        if iter_count <= 0:
            iter_count = 1  # Default fallback

        # Calculate loop body cycles
        body_cycles = 0
        for i in range(target_idx, idx + 1):
            _, result = instrs[i]
            body_cycles += result.cycles

        total = body_cycles * iter_count
        # Adjust for dbra exit (last iteration takes exit cycles, not loop cycles)
        # dbra loop=12, exit=16, so add 4 for the final exit
        total += 4

        loops.append(LoopInfo(
            label=target,
            start_idx=target_idx,
            end_idx=idx,
            iter_count=iter_count,
            body_cycles=body_cycles,
            total_cycles=total,
        ))

    return loops


def analyze_routine(
    name: str,
    instrs: list[Instr],
    symbols: SymbolTable,
) -> RoutineAnalysis:
    """Analyze a single routine."""
    # Calculate cycles for each instruction
    instr_cycles = [(instr, cycles_for(instr)) for instr in instrs]

    # Find loops
    loops = find_loops(instr_cycles, symbols)

    # Calculate single-pass total
    single_pass = sum(r.cycles for _, r in instr_cycles)

    # Calculate setup (before first loop)
    if loops:
        first_loop_start = min(l.start_idx for l in loops)
        setup_cycles = sum(r.cycles for _, r in instr_cycles[:first_loop_start])
    else:
        setup_cycles = single_pass

    # Calculate total with loop iterations
    # Start with single pass, then add (iterations-1) * body for each loop
    total = single_pass
    for loop in loops:
        extra_iters = loop.iter_count - 1
        total += extra_iters * loop.body_cycles
        total += 4  # dbra exit adjustment

    start_line = instrs[0].line if instrs else 0
    end_line = instrs[-1].line if instrs else 0

    return RoutineAnalysis(
        name=name,
        start_line=start_line,
        end_line=end_line,
        instrs=instr_cycles,
        loops=loops,
        setup_cycles=setup_cycles,
        total_cycles=total,
        single_pass=single_pass,
    )


def find_routines(items: list) -> list[tuple[str, list[Instr]]]:
    """Extract routines from parsed items.

    A routine starts at a global label (not starting with '.') and ends
    at the next RTS. Labels inside a routine (like loop targets) don't
    start new routines.
    """
    routines: list[tuple[str, list[Instr]]] = []
    current_name: str | None = None
    current_instrs: list[Instr] = []

    for item in items:
        if not isinstance(item, Instr):
            continue

        # Global label after RTS (or at start) = new routine
        # Labels while inside a routine are internal (loop targets, etc.)
        if item.label and not item.label.startswith('.'):
            if current_name is None:
                # Not in a routine — this label starts one
                current_name = item.label
                current_instrs = []

        current_instrs.append(item)

        # RTS ends routine
        if item.mnemonic == 'rts':
            if current_name:
                routines.append((current_name, current_instrs))
            current_name = None
            current_instrs = []

    return routines


def analyze_file(path: str | Path, symbols: SymbolTable | None = None) -> FileAnalysis:
    """Analyze an entire assembly file."""
    path = Path(path)

    # Load symbols from project if not provided
    if symbols is None:
        # Try to find src directory relative to file
        src_dir = path.parent
        while src_dir.name != 'src' and src_dir.parent != src_dir:
            src_dir = src_dir.parent
        if src_dir.name == 'src':
            symbols = load_project_symbols(src_dir)
        else:
            symbols = SymbolTable()

    # Parse file
    items = parse_file(str(path))

    # Find and analyze routines
    routine_list = find_routines(items)
    analyses = [analyze_routine(name, instrs, symbols) for name, instrs in routine_list]

    total = sum(r.total_cycles for r in analyses)

    return FileAnalysis(
        path=path,
        routines=analyses,
        total_cycles=total,
        symbols=symbols,
    )


def format_routine_report(analysis: RoutineAnalysis, verbose: bool = False) -> str:
    """Format a routine analysis as a text report."""
    lines = []

    sl_total = analysis.total_cycles / 512
    lines.append(f"Routine: {analysis.name} (lines {analysis.start_line}-{analysis.end_line})")
    lines.append(f"  Single pass:  {analysis.single_pass:>8,} cycles")
    lines.append(f"  With loops:   {analysis.total_cycles:>8,} cycles  (~{sl_total:.1f} scanlines)")

    if analysis.loops:
        lines.append(f"  Loops:")
        for loop in analysis.loops:
            lines.append(f"    {loop.label}: {loop.iter_count} iters × {loop.body_cycles} cy = {loop.total_cycles:,} cy")

    if verbose:
        lines.append("")
        lines.append(f"  {'Line':>5} {'Cy':>4}  {'Label':<15} {'Mnemonic':<10} {'Operands':<40}")
        lines.append("  " + "-" * 80)

        for instr, result in analysis.instrs:
            mnem = f"{instr.mnemonic}.{instr.size}" if instr.size else instr.mnemonic
            label = instr.label or ''
            operands = ''
            if instr.src_ea:
                operands = instr.src_ea.raw
            if instr.dst_ea:
                operands += f", {instr.dst_ea.raw}"

            # Mark loop starts
            loop_mark = ''
            for loop in analysis.loops:
                if label == loop.label:
                    loop_mark = f" [LOOP×{loop.iter_count}]"
                    break

            lines.append(f"  {instr.line:>5} {result.cycles:>4}  {label:<15} {mnem:<10} {operands:<40}{loop_mark}")

    return '\n'.join(lines)
