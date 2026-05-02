"""CLI entry point for cycle counter tool."""

from __future__ import annotations
import argparse
import sys
from pathlib import Path

from .parser import parse_file, Instr, Directive, EAMode
from .timings import cycles_for, CycleResult
from .analyzer import analyze_file, format_routine_report
from .symbols import load_project_symbols
from .patterns import find_patterns, format_pattern_report, ALL_PATTERNS
from .ste_model import (
    format_contention_report, format_frame_budget_with_contention,
    apply_contention, ExecutionContext,
)
from .differ import diff_files, format_diff_report, analyze_confo_routines


def format_ea(ea) -> str:
    """Format EA for display."""
    if ea is None:
        return '-'
    mode_name = ea.mode.name
    if ea.reg:
        mode_name += f'({ea.reg})'
    if ea.index:
        mode_name += f',{ea.index}'
    if ea.disp and ea.mode not in (EAMode.DN, EAMode.AN, EAMode.SR, EAMode.CCR):
        mode_name += f'={ea.disp[:20]}'
    return mode_name


def cmd_parse(args: argparse.Namespace) -> int:
    """Parse and dump IR."""
    path = Path(args.file)
    if not path.exists():
        print(f"Error: {path} not found", file=sys.stderr)
        return 1

    items = parse_file(str(path))

    instrs = [i for i in items if isinstance(i, Instr)]
    directives = [d for d in items if isinstance(d, Directive)]

    print(f"Parsed {path.name}: {len(instrs)} instructions, {len(directives)} directives")
    print()

    if args.verbose:
        print("=" * 80)
        print(f"{'Line':>5}  {'Label':<20} {'Mnemonic':<10} {'Src EA':<25} {'Dst EA':<25}")
        print("=" * 80)

        for item in items:
            if isinstance(item, Instr):
                mnem = f"{item.mnemonic}.{item.size}" if item.size else item.mnemonic
                label = item.label or ''
                src = format_ea(item.src_ea)
                dst = format_ea(item.dst_ea)
                expanded = ' [R]' if item.is_rept_expanded else ''
                print(f"{item.line:>5}  {label:<20} {mnem:<10} {src:<25} {dst:<25}{expanded}")
            elif isinstance(item, Directive) and args.directives:
                label = item.label or ''
                name = f"{item.name}.{item.size}" if item.size else item.name
                print(f"{item.line:>5}  {label:<20} {name:<10} {item.operand[:50]}")

        print("=" * 80)
    else:
        # Summary by mnemonic
        mnem_counts: dict[str, int] = {}
        ea_mode_counts: dict[str, int] = {}

        for instr in instrs:
            key = f"{instr.mnemonic}.{instr.size}" if instr.size else instr.mnemonic
            mnem_counts[key] = mnem_counts.get(key, 0) + 1

            if instr.src_ea:
                ea_mode_counts[instr.src_ea.mode.name] = ea_mode_counts.get(instr.src_ea.mode.name, 0) + 1
            if instr.dst_ea:
                ea_mode_counts[instr.dst_ea.mode.name] = ea_mode_counts.get(instr.dst_ea.mode.name, 0) + 1

        print("Instruction counts (top 20):")
        for mnem, count in sorted(mnem_counts.items(), key=lambda x: -x[1])[:20]:
            print(f"  {mnem:<15} {count:>5}")

        print()
        print("EA mode counts:")
        for mode, count in sorted(ea_mode_counts.items(), key=lambda x: -x[1]):
            print(f"  {mode:<15} {count:>5}")

    # Show labels
    if args.labels:
        print()
        print("Labels:")
        labels = [i.label for i in items if hasattr(i, 'label') and i.label]
        for label in labels:
            print(f"  {label}")

    return 0


def cmd_cycles(args: argparse.Namespace) -> int:
    """Show cycle counts for each instruction."""
    path = Path(args.file)
    if not path.exists():
        print(f"Error: {path} not found", file=sys.stderr)
        return 1

    items = parse_file(str(path))
    instrs = [i for i in items if isinstance(i, Instr)]

    total_cycles = 0
    by_mnemonic: dict[str, tuple[int, int]] = {}  # mnemonic -> (total_cy, count)

    if args.verbose:
        print(f"{'Line':>5} {'Cy':>4}  {'Mnemonic':<12} {'Operands':<50} {'Note'}")
        print("-" * 90)

    for instr in instrs:
        result = cycles_for(instr)
        total_cycles += result.cycles

        mnem = f"{instr.mnemonic}.{instr.size}" if instr.size else instr.mnemonic
        prev = by_mnemonic.get(mnem, (0, 0))
        by_mnemonic[mnem] = (prev[0] + result.cycles, prev[1] + 1)

        if args.verbose:
            operands = ''
            if instr.src_ea:
                operands = instr.src_ea.raw
            if instr.dst_ea:
                operands += f", {instr.dst_ea.raw}"
            note = result.note
            if result.is_branch:
                note = f"taken={result.taken_cycles}, not={result.not_taken_cycles}"
            print(f"{instr.line:>5} {result.cycles:>4}  {mnem:<12} {operands:<50} {note}")

    print()
    print(f"Total: {total_cycles:,} cycles ({total_cycles // 512} scanlines approx)")
    print()

    # Top consumers
    print("Top cycle consumers by instruction type:")
    print(f"  {'Mnemonic':<15} {'Total Cy':>10} {'Count':>8} {'Avg':>6}")
    print("  " + "-" * 45)
    for mnem, (cy, count) in sorted(by_mnemonic.items(), key=lambda x: -x[1][0])[:15]:
        avg = cy // count if count > 0 else 0
        print(f"  {mnem:<15} {cy:>10,} {count:>8} {avg:>6}")

    return 0


def cmd_routines(args: argparse.Namespace) -> int:
    """List routines (labels followed by instructions ending in rts)."""
    path = Path(args.file)
    if not path.exists():
        print(f"Error: {path} not found", file=sys.stderr)
        return 1

    items = parse_file(str(path))

    routines: list[tuple[str, int, int]] = []
    current_routine: str | None = None
    start_line: int = 0
    instr_count: int = 0

    for item in items:
        if isinstance(item, Instr):
            if item.label and not item.label.startswith('.'):
                # New global label = new routine candidate
                if current_routine and instr_count > 0:
                    routines.append((current_routine, start_line, instr_count))
                current_routine = item.label
                start_line = item.line
                instr_count = 0

            instr_count += 1

            if item.mnemonic == 'rts':
                if current_routine:
                    routines.append((current_routine, start_line, instr_count))
                    current_routine = None
                    instr_count = 0

    print(f"Routines in {path.name}:")
    print()
    # Calculate cycles for each routine
    routines_with_cycles: list[tuple[str, int, int, int]] = []
    for name, line, count in routines:
        routine_cycles = 0
        in_routine = False
        for item in items:
            if isinstance(item, Instr):
                if item.label == name:
                    in_routine = True
                if in_routine:
                    result = cycles_for(item)
                    routine_cycles += result.cycles
                if item.mnemonic == 'rts' and in_routine:
                    in_routine = False
                    break
        routines_with_cycles.append((name, line, count, routine_cycles))

    print(f"{'Name':<35} {'Line':>6} {'Instrs':>8} {'Cycles':>10} {'~SL':>6}")
    print("-" * 70)
    for name, line, count, cycles in sorted(routines_with_cycles, key=lambda x: -x[3]):
        sl = cycles // 512
        print(f"{name:<35} {line:>6} {count:>8} {cycles:>10,} {sl:>6}")

    return 0


def find_loop_info(instrs: list[tuple[Instr, CycleResult]]) -> dict[str, tuple[int, int]]:
    """Find loop labels and their iteration counts."""
    loops: dict[str, tuple[int, int]] = {}  # label -> (start_idx, iter_count)

    # Build label -> index map
    label_idx: dict[str, int] = {}
    for idx, (instr, _) in enumerate(instrs):
        if instr.label:
            label_idx[instr.label] = idx

    # Find dbra/dbf that jump backward
    for idx, (instr, _) in enumerate(instrs):
        if instr.mnemonic in ('dbra', 'dbf'):
            target = instr.dst_ea.disp if instr.dst_ea else None
            if target and target in label_idx:
                target_idx = label_idx[target]
                if target_idx < idx:
                    # Look for moveq/move.w that sets the counter
                    iter_count = instr.annot.get('iters', 0)
                    if not iter_count:
                        # Try to infer from preceding moveq
                        for back_idx in range(idx - 1, max(0, idx - 10), -1):
                            prev_instr, _ = instrs[back_idx]
                            if prev_instr.mnemonic == 'moveq' and prev_instr.dst_ea:
                                if prev_instr.dst_ea.reg == instr.src_ea.reg:
                                    try:
                                        val = prev_instr.src_ea.disp if prev_instr.src_ea else '0'
                                        iter_count = int(val.replace('#', '')) + 1
                                    except (ValueError, AttributeError):
                                        pass
                                    break
                            elif prev_instr.mnemonic == 'move' and prev_instr.size == 'w':
                                if prev_instr.dst_ea and prev_instr.dst_ea.reg == instr.src_ea.reg:
                                    if prev_instr.src_ea and prev_instr.src_ea.mode == EAMode.IMM:
                                        try:
                                            val = prev_instr.src_ea.disp or '0'
                                            iter_count = int(val.replace('#', '')) + 1
                                        except (ValueError, AttributeError):
                                            pass
                                    break
                    if iter_count > 0:
                        loops[target] = (target_idx, iter_count)

    return loops


def cmd_routine(args: argparse.Namespace) -> int:
    """Analyze a single routine in detail."""
    path = Path(args.file)
    if not path.exists():
        print(f"Error: {path} not found", file=sys.stderr)
        return 1

    items = parse_file(str(path))
    instrs = [i for i in items if isinstance(i, Instr)]

    # Find the routine
    in_routine = False
    routine_instrs: list[tuple[Instr, CycleResult]] = []
    start_line = 0

    for instr in instrs:
        if instr.label == args.name:
            in_routine = True
            start_line = instr.line

        if in_routine:
            result = cycles_for(instr)
            routine_instrs.append((instr, result))
            if instr.mnemonic == 'rts':
                break

    if not routine_instrs:
        print(f"Routine '{args.name}' not found", file=sys.stderr)
        return 1

    # Find loops
    loops = find_loop_info(routine_instrs)

    # Calculate per-iteration and total
    total_once = sum(r.cycles for _, r in routine_instrs)
    loop_total = 0

    for label, (start_idx, iter_count) in loops.items():
        loop_cycles = 0
        for idx in range(start_idx, len(routine_instrs)):
            instr, result = routine_instrs[idx]
            loop_cycles += result.cycles
            if instr.mnemonic in ('dbra', 'dbf'):
                break
        loop_total += loop_cycles * (iter_count - 1)  # -1 because first iter is in total_once

    total_with_loops = total_once + loop_total

    print(f"Routine: {args.name} (line {start_line})")
    print(f"Single pass: {total_once:,} cycles")
    if loops:
        print(f"With loops:  {total_with_loops:,} cycles (~{total_with_loops // 512} scanlines)")
        print(f"Loops detected: {', '.join(f'{l}×{c}' for l, (_, c) in loops.items())}")
    print()
    print(f"{'Line':>5} {'Cy':>4}  {'Label':<15} {'Mnemonic':<10} {'Operands':<40} {'Note'}")
    print("-" * 100)

    for instr, result in routine_instrs:
        mnem = f"{instr.mnemonic}.{instr.size}" if instr.size else instr.mnemonic
        label = instr.label or ''
        operands = ''
        if instr.src_ea:
            operands = instr.src_ea.raw
        if instr.dst_ea:
            operands += f", {instr.dst_ea.raw}"
        note = result.note
        if result.is_branch:
            note = f"t={result.taken_cycles}/f={result.not_taken_cycles}"
        # Mark loop start
        if label in loops:
            note = f"[LOOP×{loops[label][1]}] {note}"
        print(f"{instr.line:>5} {result.cycles:>4}  {label:<15} {mnem:<10} {operands:<40} {note}")

    return 0


def cmd_diff(args: argparse.Namespace) -> int:
    """Compare against CONFO.S."""
    if args.analyze_confo:
        confo_path = Path(args.confo)
        if not confo_path.exists():
            print(f"Error: {confo_path} not found", file=sys.stderr)
            return 1
        print(analyze_confo_routines(confo_path))
        return 0

    our_path = Path(args.file)
    confo_path = Path(args.confo)

    if not our_path.exists():
        print(f"Error: {our_path} not found", file=sys.stderr)
        return 1
    if not confo_path.exists():
        print(f"Error: {confo_path} not found", file=sys.stderr)
        return 1

    # Load symbols for our code
    src_dir = our_path.parent
    while src_dir.name != 'src' and src_dir.parent != src_dir:
        src_dir = src_dir.parent
    our_symbols = load_project_symbols(src_dir) if src_dir.name == 'src' else None

    diff = diff_files(our_path, confo_path, our_symbols)
    print(format_diff_report(diff))

    return 0


def cmd_contention(args: argparse.Namespace) -> int:
    """Show STE Shifter contention effects."""
    path = Path(args.file)
    if not path.exists():
        print(f"Error: {path} not found", file=sys.stderr)
        return 1

    # Load symbols
    src_dir = path.parent
    while src_dir.name != 'src' and src_dir.parent != src_dir:
        src_dir = src_dir.parent
    symbols = load_project_symbols(src_dir) if src_dir.name == 'src' else None

    analysis = analyze_file(path, symbols)

    if args.budget:
        print(format_frame_budget_with_contention(analysis))
    else:
        print(format_contention_report(analysis))

    return 0


def cmd_optimize(args: argparse.Namespace) -> int:
    """Find optimization patterns."""
    path = Path(args.file)
    if not path.exists():
        print(f"Error: {path} not found", file=sys.stderr)
        return 1

    items = parse_file(str(path))
    instrs = [i for i in items if isinstance(i, Instr)]

    if args.routine:
        # Filter to specific routine
        routine_instrs = []
        in_routine = False
        for instr in instrs:
            if instr.label == args.routine:
                in_routine = True
            if in_routine:
                routine_instrs.append(instr)
                if instr.mnemonic == 'rts':
                    break
        if not routine_instrs:
            print(f"Routine '{args.routine}' not found", file=sys.stderr)
            return 1
        instrs = routine_instrs
        print(f"Analyzing routine: {args.routine}")
    else:
        print(f"Analyzing: {path.name}")

    print(f"Instructions: {len(instrs)}")
    print()

    matches = find_patterns(instrs)
    print(format_pattern_report(matches, top_n=args.top))

    return 0


def cmd_frame(args: argparse.Namespace) -> int:
    """Show frame-level cycle budget."""
    path = Path(args.file)
    if not path.exists():
        print(f"Error: {path} not found", file=sys.stderr)
        return 1

    # Load symbols
    src_dir = path.parent
    while src_dir.name != 'src' and src_dir.parent != src_dir:
        src_dir = src_dir.parent
    symbols = load_project_symbols(src_dir) if src_dir.name == 'src' else None

    analysis = analyze_file(path, symbols)

    # Frame budget constants (PAL 50Hz)
    CYCLES_PER_SL = 512
    TOTAL_SCANLINES = 313
    VISIBLE_SCANLINES = 200
    VBLANK_SCANLINES = 113
    TOTAL_CYCLES = TOTAL_SCANLINES * CYCLES_PER_SL  # 160,256

    # Known hot-path routines (called per VBL)
    hot_path = ['ScrollerStepVblank', 'ScrollShiftAndFill', 'ScrollPlotDispatch',
                'ScrollRenderNextPword', 'ScrollPlot', 'ScrollPlotType0',
                'ScrollPlotType1', 'ScrollPlotType2', 'ScrollPlotType3',
                'ScrollPlotType4', 'ScrollPlotType5', 'ScrollPlotType7']

    # Find routines in hot path
    hot_routines = []
    for name in hot_path:
        for r in analysis.routines:
            if r.name == name:
                hot_routines.append(r)
                break

    print("=" * 70)
    print("FRAME CYCLE BUDGET — PAL 50Hz")
    print("=" * 70)
    print()
    print(f"Frame budget:      {TOTAL_CYCLES:>10,} cycles  ({TOTAL_SCANLINES} scanlines)")
    print(f"VBlank window:     {VBLANK_SCANLINES * CYCLES_PER_SL:>10,} cycles  ({VBLANK_SCANLINES} scanlines)")
    print(f"Visible window:    {VISIBLE_SCANLINES * CYCLES_PER_SL:>10,} cycles  ({VISIBLE_SCANLINES} scanlines)")
    print()
    print("-" * 70)
    print("Per-VBL Hot Path (scroller routines)")
    print("-" * 70)
    print()
    print(f"{'Routine':<30} {'Cycles':>10} {'SL':>8} {'%Frame':>8}")
    print("-" * 60)

    total_hot = 0
    for r in sorted(hot_routines, key=lambda x: -x.total_cycles):
        sl = r.total_cycles / CYCLES_PER_SL
        pct = (r.total_cycles / TOTAL_CYCLES) * 100
        print(f"{r.name:<30} {r.total_cycles:>10,} {sl:>8.1f} {pct:>7.1f}%")
        total_hot += r.total_cycles

    # Calculate realistic estimate
    # Plot types are mutually exclusive — use average
    plot_types = [r for r in hot_routines if r.name.startswith('ScrollPlotType')]
    non_plot = [r for r in hot_routines if not r.name.startswith('ScrollPlotType')]

    base_cost = sum(r.total_cycles for r in non_plot)
    # ScrollRenderNextPword runs every other VBL
    render_routine = next((r for r in non_plot if r.name == 'ScrollRenderNextPword'), None)
    if render_routine:
        base_cost -= render_routine.total_cycles // 2  # Average

    print()
    print("-" * 70)
    print("Realistic Per-VBL Estimate")
    print("-" * 70)
    print()

    if plot_types:
        heaviest = max(plot_types, key=lambda x: x.total_cycles)
        lightest = min(plot_types, key=lambda x: x.total_cycles)
        avg_plot = sum(r.total_cycles for r in plot_types) // len(plot_types)

        worst_case = base_cost + heaviest.total_cycles
        best_case = base_cost + lightest.total_cycles
        avg_case = base_cost + avg_plot

        print(f"Base cost (always runs):       {base_cost:>10,} cycles ({base_cost/CYCLES_PER_SL:.1f} sl)")
        print()
        print(f"With heaviest ({heaviest.name}):")
        print(f"  Total:                       {worst_case:>10,} cycles ({worst_case/CYCLES_PER_SL:.1f} sl)")
        print(f"  Margin:                      {TOTAL_CYCLES - worst_case:>10,} cycles ({(TOTAL_CYCLES - worst_case)/CYCLES_PER_SL:.1f} sl)")
        print()
        print(f"With lightest ({lightest.name}):")
        print(f"  Total:                       {best_case:>10,} cycles ({best_case/CYCLES_PER_SL:.1f} sl)")
        print(f"  Margin:                      {TOTAL_CYCLES - best_case:>10,} cycles ({(TOTAL_CYCLES - best_case)/CYCLES_PER_SL:.1f} sl)")
        print()
        print(f"Average case:")
        print(f"  Total:                       {avg_case:>10,} cycles ({avg_case/CYCLES_PER_SL:.1f} sl)")
        print(f"  Margin:                      {TOTAL_CYCLES - avg_case:>10,} cycles ({(TOTAL_CYCLES - avg_case)/CYCLES_PER_SL:.1f} sl)")

    return 0


def cmd_analyze(args: argparse.Namespace) -> int:
    """Full analysis with symbol resolution and loop detection."""
    path = Path(args.file)
    if not path.exists():
        print(f"Error: {path} not found", file=sys.stderr)
        return 1

    # Load symbols from src directory
    src_dir = path.parent
    while src_dir.name != 'src' and src_dir.parent != src_dir:
        src_dir = src_dir.parent
    if src_dir.name == 'src':
        symbols = load_project_symbols(src_dir)
        print(f"Loaded {len(symbols)} symbols from {src_dir}")
    else:
        symbols = None
        print("Warning: Could not find src directory for symbol resolution")

    analysis = analyze_file(path, symbols)

    if args.routine:
        # Single routine
        for r in analysis.routines:
            if r.name == args.routine:
                print()
                print(format_routine_report(r, verbose=args.verbose))
                return 0
        print(f"Routine '{args.routine}' not found", file=sys.stderr)
        return 1

    # All routines summary
    print()
    print(f"File: {path.name}")
    print(f"Total cycles (all routines): {analysis.total_cycles:,}")
    print()
    print(f"{'Routine':<35} {'Cycles':>12} {'~SL':>6} {'Loops'}")
    print("-" * 70)

    for r in sorted(analysis.routines, key=lambda x: -x.total_cycles):
        sl = r.total_cycles / 512
        loop_info = ', '.join(f"{l.label}×{l.iter_count}" for l in r.loops) or '-'
        print(f"{r.name:<35} {r.total_cycles:>12,} {sl:>6.1f} {loop_info}")

    if args.verbose:
        print()
        print("=" * 80)
        for r in sorted(analysis.routines, key=lambda x: -x.total_cycles):
            print()
            print(format_routine_report(r, verbose=True))
            print()

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        prog='cycles',
        description='68000 cycle counter and optimization finder',
    )
    subparsers = parser.add_subparsers(dest='command', required=True)

    # parse command
    p_parse = subparsers.add_parser('parse', help='Parse and dump IR')
    p_parse.add_argument('file', help='Assembly file to parse')
    p_parse.add_argument('-v', '--verbose', action='store_true', help='Show each instruction')
    p_parse.add_argument('-d', '--directives', action='store_true', help='Include directives')
    p_parse.add_argument('-l', '--labels', action='store_true', help='List all labels')
    p_parse.set_defaults(func=cmd_parse)

    # cycles command
    p_cycles = subparsers.add_parser('cycles', help='Count cycles per instruction')
    p_cycles.add_argument('file', help='Assembly file to analyze')
    p_cycles.add_argument('-v', '--verbose', action='store_true', help='Show each instruction')
    p_cycles.set_defaults(func=cmd_cycles)

    # routines command
    p_routines = subparsers.add_parser('routines', help='List routines with cycle counts')
    p_routines.add_argument('file', help='Assembly file to parse')
    p_routines.set_defaults(func=cmd_routines)

    # routine command - show single routine detail
    p_routine = subparsers.add_parser('routine', help='Analyze a single routine')
    p_routine.add_argument('file', help='Assembly file')
    p_routine.add_argument('name', help='Routine name')
    p_routine.set_defaults(func=cmd_routine)

    # analyze command - full analysis with symbol resolution
    p_analyze = subparsers.add_parser('analyze', help='Full analysis with loop detection')
    p_analyze.add_argument('file', help='Assembly file')
    p_analyze.add_argument('-v', '--verbose', action='store_true', help='Show per-instruction detail')
    p_analyze.add_argument('-r', '--routine', help='Analyze only this routine')
    p_analyze.set_defaults(func=cmd_analyze)

    # frame command - frame-level budget
    p_frame = subparsers.add_parser('frame', help='Frame-level cycle budget')
    p_frame.add_argument('file', help='Assembly file')
    p_frame.set_defaults(func=cmd_frame)

    # optimize command - find optimization patterns
    p_opt = subparsers.add_parser('optimize', help='Find optimization patterns')
    p_opt.add_argument('file', help='Assembly file')
    p_opt.add_argument('-n', '--top', type=int, default=20, help='Show top N matches')
    p_opt.add_argument('-r', '--routine', help='Analyze only this routine')
    p_opt.set_defaults(func=cmd_optimize)

    # contention command - STE Shifter contention model
    p_cont = subparsers.add_parser('contention', help='STE Shifter contention model')
    p_cont.add_argument('file', help='Assembly file')
    p_cont.add_argument('--budget', action='store_true', help='Show frame budget with contention')
    p_cont.set_defaults(func=cmd_contention)

    # diff command - compare against CONFO.S
    p_diff = subparsers.add_parser('diff', help='Compare against CONFO.S (1988 original)')
    p_diff.add_argument('file', help='Our assembly file')
    p_diff.add_argument('--confo', default='docs/STCS.RAT/CONFO.S', help='Path to CONFO.S')
    p_diff.add_argument('--analyze-confo', action='store_true', help='Just analyze CONFO.S')
    p_diff.set_defaults(func=cmd_diff)

    args = parser.parse_args()
    return args.func(args)


if __name__ == '__main__':
    sys.exit(main())
