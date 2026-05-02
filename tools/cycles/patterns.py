"""Optimization pattern matchers for 68000 assembly."""

from __future__ import annotations
from dataclasses import dataclass
from typing import Callable

from .parser import Instr, EAMode
from .timings import cycles_for


@dataclass
class Match:
    """A matched optimization pattern."""
    pattern_name: str
    start_idx: int
    end_idx: int
    instrs: list[Instr]
    current_cycles: int
    optimized_cycles: int
    savings: int
    suggestion: str
    line: int


@dataclass
class Pattern:
    """An optimization pattern to look for."""
    name: str
    description: str
    matcher: Callable[[list[Instr], int], Match | None]


def match_consecutive_moves_to_movem(instrs: list[Instr], idx: int) -> Match | None:
    """
    Pattern: N consecutive move.l from DIFFERENT registers with sequential dest.
    Suggestion: Replace with movem.l if N >= 4.

    Example:
        move.l  d0, (a0)
        move.l  d1, 4(a0)
        move.l  d2, 8(a0)
        move.l  d3, 12(a0)
    Could become:
        movem.l d0-d3, (a0)

    NOTE: Skips patterns where same register is written multiple times
    (e.g., vertical doubling pattern: d0→(a1), d0→184(a1)).
    """
    if idx >= len(instrs):
        return None

    instr = instrs[idx]
    if instr.mnemonic != 'move' or instr.size != 'l':
        return None

    # Check source is a data register
    if not instr.src_ea or instr.src_ea.mode != EAMode.DN:
        return None

    # Check dest is post-increment only (sequential writes)
    if not instr.dst_ea or instr.dst_ea.mode != EAMode.POSTINC:
        return None

    # Look for consecutive moves to same base register from DIFFERENT source regs
    base_reg = instr.dst_ea.reg
    consecutive = [instr]
    regs_used = {instr.src_ea.reg}

    for i in range(idx + 1, min(idx + 16, len(instrs))):
        next_instr = instrs[i]
        if next_instr.mnemonic != 'move' or next_instr.size != 'l':
            break
        if not next_instr.src_ea or next_instr.src_ea.mode != EAMode.DN:
            break
        if not next_instr.dst_ea:
            break
        if next_instr.dst_ea.mode != EAMode.POSTINC or next_instr.dst_ea.reg != base_reg:
            break
        # Must be a different source register
        if next_instr.src_ea.reg in regs_used:
            break
        consecutive.append(next_instr)
        regs_used.add(next_instr.src_ea.reg)

    if len(consecutive) < 4:
        return None

    # Calculate savings
    current = sum(cycles_for(i).cycles for i in consecutive)
    # movem.l to mem: 8 + 8n cycles
    n_regs = len(consecutive)
    optimized = 8 + (8 * n_regs)

    if optimized >= current:
        return None

    reg_list = '/'.join(sorted(regs_used))
    return Match(
        pattern_name='consecutive_moves_to_movem',
        start_idx=idx,
        end_idx=idx + len(consecutive) - 1,
        instrs=consecutive,
        current_cycles=current,
        optimized_cycles=optimized,
        savings=current - optimized,
        suggestion=f"Replace {n_regs}× move.l with: movem.l {reg_list}, ({base_reg})+",
        line=instr.line,
    )


def match_lea_addq_replacement(instrs: list[Instr], idx: int) -> Match | None:
    """
    Pattern: lea d(An), An where d <= 8.
    Suggestion: Replace with addq.l #d, An (saves 4 cycles).

    lea 8(a0), a0     ; 8 cycles
    →
    addq.l #8, a0     ; 8 cycles (same for d<=8, but smaller code)

    Actually for d <= 8, addq is same speed. But for showing the pattern.
    Real win: lea with d > 8 that could be split.
    """
    if idx >= len(instrs):
        return None

    instr = instrs[idx]
    if instr.mnemonic != 'lea':
        return None

    if not instr.src_ea or instr.src_ea.mode != EAMode.D_AN:
        return None

    if not instr.dst_ea or instr.dst_ea.mode != EAMode.AN:
        return None

    # Same register?
    if instr.src_ea.reg != instr.dst_ea.reg:
        return None

    # Try to parse displacement
    try:
        disp = int(instr.src_ea.disp or '0')
    except ValueError:
        return None

    if disp <= 0 or disp > 8:
        return None

    # lea d(An),An with d<=8 is 8 cycles, addq.l #d,An is also 8 cycles
    # No cycle savings, but smaller code. Skip for now.
    return None


def match_clr_then_move(instrs: list[Instr], idx: int) -> Match | None:
    """
    Pattern: clr followed by move to same location (not pre-decrement).
    Suggestion: Remove the clr (move overwrites anyway).

    clr.l   (a0)      ; 12 cycles
    move.l  d0, (a0)  ; 12 cycles
    →
    move.l  d0, (a0)  ; 12 cycles (saves 12)
    """
    if idx >= len(instrs) - 1:
        return None

    instr = instrs[idx]
    if instr.mnemonic != 'clr':
        return None

    next_instr = instrs[idx + 1]
    if next_instr.mnemonic != 'move':
        return None

    # Check same destination (but not pre-decrement — those push to different locations)
    if not instr.src_ea or not next_instr.dst_ea:
        return None

    # Skip pre-decrement — each -(An) is a different location
    if instr.src_ea.mode == EAMode.PREDEC or next_instr.dst_ea.mode == EAMode.PREDEC:
        return None

    if instr.src_ea.raw != next_instr.dst_ea.raw:
        return None

    current = cycles_for(instr).cycles + cycles_for(next_instr).cycles
    optimized = cycles_for(next_instr).cycles

    return Match(
        pattern_name='redundant_clr',
        start_idx=idx,
        end_idx=idx + 1,
        instrs=[instr, next_instr],
        current_cycles=current,
        optimized_cycles=optimized,
        savings=current - optimized,
        suggestion=f"Remove clr.{instr.size} {instr.src_ea.raw} — move overwrites it",
        line=instr.line,
    )


def match_move_via_register(instrs: list[Instr], idx: int) -> Match | None:
    """
    Pattern: move.l (src), Dn followed by move.l Dn, (dst) where Dn is not used again.
    Suggestion: Replace with move.l (src), (dst) if no intervening use of Dn.

    move.l  (a0), d0  ; 12 cycles
    move.l  d0, (a1)  ; 12 cycles
    →
    move.l  (a0), (a1) ; 20 cycles (saves 4)

    NOTE: Only suggest if destination is simple (An) or (An)+, otherwise
    mem→mem addressing might not be cheaper.
    """
    if idx >= len(instrs) - 1:
        return None

    instr1 = instrs[idx]
    if instr1.mnemonic != 'move' or instr1.size != 'l':
        return None

    # First move: mem → Dn
    if not instr1.src_ea or not instr1.dst_ea:
        return None
    if instr1.dst_ea.mode != EAMode.DN:
        return None
    # Source should be simple indirect
    if instr1.src_ea.mode not in (EAMode.IND, EAMode.POSTINC, EAMode.D_AN):
        return None

    temp_reg = instr1.dst_ea.reg

    instr2 = instrs[idx + 1]
    if instr2.mnemonic != 'move' or instr2.size != 'l':
        return None

    # Second move: Dn → mem (simple indirect only)
    if not instr2.src_ea or not instr2.dst_ea:
        return None
    if instr2.src_ea.mode != EAMode.DN or instr2.src_ea.reg != temp_reg:
        return None
    if instr2.dst_ea.mode not in (EAMode.IND, EAMode.POSTINC):
        return None

    # Check if register is used later (within next few instructions)
    for i in range(idx + 2, min(idx + 5, len(instrs))):
        later = instrs[i]
        if later.src_ea and later.src_ea.reg == temp_reg:
            return None
        if later.dst_ea and later.dst_ea.reg == temp_reg:
            break  # Overwritten, so OK

    current = cycles_for(instr1).cycles + cycles_for(instr2).cycles
    # move.l (An), (An) is 20 cycles
    optimized = 20

    if optimized >= current:
        return None

    return Match(
        pattern_name='move_via_register',
        start_idx=idx,
        end_idx=idx + 1,
        instrs=[instr1, instr2],
        current_cycles=current,
        optimized_cycles=optimized,
        savings=current - optimized,
        suggestion=f"Replace via-{temp_reg} with: move.l {instr1.src_ea.raw}, {instr2.dst_ea.raw}",
        line=instr1.line,
    )


def match_expensive_ea_in_loop(instrs: list[Instr], idx: int) -> Match | None:
    """
    Pattern: d(An,Ri) addressing mode inside a tight loop.
    Suggestion: Hoist the indexed calculation outside the loop.

    This is expensive (14-18 cycles for the EA alone).
    """
    if idx >= len(instrs):
        return None

    instr = instrs[idx]

    # Check for expensive EA modes
    expensive_src = instr.src_ea and instr.src_ea.mode == EAMode.D_AN_RI
    expensive_dst = instr.dst_ea and instr.dst_ea.mode == EAMode.D_AN_RI

    if not expensive_src and not expensive_dst:
        return None

    # Check if we're in a loop (look for dbra within 20 instructions)
    in_loop = False
    for i in range(idx, min(idx + 30, len(instrs))):
        if instrs[i].mnemonic in ('dbra', 'dbf'):
            in_loop = True
            break
        if instrs[i].mnemonic == 'rts':
            break

    if not in_loop:
        return None

    ea = instr.src_ea if expensive_src else instr.dst_ea
    current = cycles_for(instr).cycles

    return Match(
        pattern_name='expensive_ea_in_loop',
        start_idx=idx,
        end_idx=idx,
        instrs=[instr],
        current_cycles=current,
        optimized_cycles=current - 6,  # Rough estimate
        savings=6,
        suggestion=f"Hoist d(An,Ri) calculation: {ea.raw} — consider lea + (An)+ pattern",
        line=instr.line,
    )


def match_unrolling_candidate(instrs: list[Instr], idx: int) -> Match | None:
    """
    Pattern: Tight dbra loop with body <= 4 instructions.
    Suggestion: Consider unrolling by 2x or 4x.

    dbra overhead is 10 cycles/iteration. If body is small, dbra dominates.
    """
    if idx >= len(instrs):
        return None

    instr = instrs[idx]
    if instr.mnemonic not in ('dbra', 'dbf'):
        return None

    # Find loop start
    target = instr.dst_ea.disp if instr.dst_ea else None
    if not target:
        return None

    # Find target label
    start_idx = None
    for i in range(idx - 1, max(0, idx - 30), -1):
        if instrs[i].label == target:
            start_idx = i
            break

    if start_idx is None:
        return None

    body_len = idx - start_idx
    if body_len > 6:  # Only flag very tight loops
        return None

    body_cycles = sum(cycles_for(instrs[i]).cycles for i in range(start_idx, idx))
    dbra_cycles = 10  # per iteration

    # If dbra is more than 30% of body, unrolling helps
    if dbra_cycles < body_cycles * 0.3:
        return None

    overhead_pct = (dbra_cycles / (body_cycles + dbra_cycles)) * 100

    return Match(
        pattern_name='unroll_candidate',
        start_idx=start_idx,
        end_idx=idx,
        instrs=instrs[start_idx:idx + 1],
        current_cycles=body_cycles + dbra_cycles,
        optimized_cycles=body_cycles + 5,  # Unroll 2x halves dbra overhead
        savings=5,  # Approximate per iteration
        suggestion=f"Tight loop ({body_len} instrs, dbra={overhead_pct:.0f}% overhead) — consider 2x unroll",
        line=instrs[start_idx].line,
    )


def match_postinc_opportunity(instrs: list[Instr], idx: int) -> Match | None:
    """
    Pattern: move from d(An) followed by lea/addq to advance An.
    Suggestion: Use (An)+ instead.

    move.l  (a0), d0
    addq.l  #4, a0
    →
    move.l  (a0)+, d0
    """
    if idx >= len(instrs) - 1:
        return None

    instr1 = instrs[idx]
    if instr1.mnemonic != 'move':
        return None

    if not instr1.src_ea or instr1.src_ea.mode != EAMode.IND:
        return None

    base_reg = instr1.src_ea.reg

    instr2 = instrs[idx + 1]

    # Check for addq #4, An or lea 4(An), An
    is_advance = False
    if instr2.mnemonic == 'addq' and instr2.dst_ea and instr2.dst_ea.reg == base_reg:
        if instr2.src_ea and instr2.src_ea.mode == EAMode.IMM:
            try:
                if int(instr2.src_ea.disp or '0') == 4 and instr1.size == 'l':
                    is_advance = True
                elif int(instr2.src_ea.disp or '0') == 2 and instr1.size == 'w':
                    is_advance = True
                elif int(instr2.src_ea.disp or '0') == 1 and instr1.size == 'b':
                    is_advance = True
            except ValueError:
                pass

    if instr2.mnemonic == 'lea' and instr2.dst_ea and instr2.dst_ea.reg == base_reg:
        if instr2.src_ea and instr2.src_ea.mode == EAMode.D_AN and instr2.src_ea.reg == base_reg:
            try:
                disp = int(instr2.src_ea.disp or '0')
                if disp == 4 and instr1.size == 'l':
                    is_advance = True
                elif disp == 2 and instr1.size == 'w':
                    is_advance = True
            except ValueError:
                pass

    if not is_advance:
        return None

    current = cycles_for(instr1).cycles + cycles_for(instr2).cycles
    # (An)+ is same cost as (An) for the move, saves the addq/lea
    optimized = cycles_for(instr1).cycles

    return Match(
        pattern_name='use_postinc',
        start_idx=idx,
        end_idx=idx + 1,
        instrs=[instr1, instr2],
        current_cycles=current,
        optimized_cycles=optimized,
        savings=current - optimized,
        suggestion=f"Use ({base_reg})+ instead of ({base_reg}) + advance",
        line=instr1.line,
    )


def match_byte_moves_in_sequence(instrs: list[Instr], idx: int) -> Match | None:
    """
    Pattern: 4+ consecutive move.b that could be 1-2 move.l.

    NOTE: Skips interleaved byte patterns (alternating sources with odd/even
    offsets) which are intentional for blending/shifting tricks.
    """
    if idx >= len(instrs):
        return None

    instr = instrs[idx]
    if instr.mnemonic != 'move' or instr.size != 'b':
        return None

    # Count consecutive byte moves
    consecutive = [instr]
    for i in range(idx + 1, min(idx + 12, len(instrs))):
        next_instr = instrs[i]
        if next_instr.mnemonic != 'move' or next_instr.size != 'b':
            break
        consecutive.append(next_instr)

    if len(consecutive) < 8:
        return None

    # Check for interleaved pattern (alternating source registers) — skip these
    # as they're intentional byte-blending code
    source_regs = []
    for c in consecutive:
        if c.src_ea:
            reg = c.src_ea.reg or 'imm'
            source_regs.append(reg)

    # If sources alternate between 2 registers, it's likely byte-blending
    if len(set(source_regs)) == 2:
        # Check for alternating pattern
        is_alternating = True
        for i in range(2, len(source_regs)):
            if source_regs[i] != source_regs[i % 2]:
                is_alternating = False
                break
        if is_alternating:
            return None  # Skip byte-blending patterns

    # Check if in a loop
    in_loop = False
    for i in range(idx, min(idx + 40, len(instrs))):
        if instrs[i].mnemonic in ('dbra', 'dbf'):
            in_loop = True
            break
        if instrs[i].mnemonic == 'rts':
            break

    if not in_loop:
        return None

    current = sum(cycles_for(i).cycles for i in consecutive)
    estimated_optimized = (len(consecutive) // 4) * 12 + (len(consecutive) % 4) * 12

    if estimated_optimized >= current:
        return None

    return Match(
        pattern_name='byte_sequence',
        start_idx=idx,
        end_idx=idx + len(consecutive) - 1,
        instrs=consecutive,
        current_cycles=current,
        optimized_cycles=estimated_optimized,
        savings=current - estimated_optimized,
        suggestion=f"{len(consecutive)}× move.b in loop — check if word/long moves possible",
        line=instr.line,
    )


def match_mulu_power_of_two(instrs: list[Instr], idx: int) -> Match | None:
    """
    Pattern: mulu/muls by a power of 2.
    Suggestion: Replace with lsl (much faster).

    mulu #4, d0   ; 70 cycles
    →
    lsl.w #2, d0  ; 8 cycles
    """
    if idx >= len(instrs):
        return None

    instr = instrs[idx]
    if instr.mnemonic not in ('mulu', 'muls'):
        return None

    if not instr.src_ea or instr.src_ea.mode != EAMode.IMM:
        return None

    # Try to parse the immediate
    try:
        val = int(instr.src_ea.disp.replace('#', '').replace('$', '0x'), 0)
    except (ValueError, AttributeError):
        return None

    # Check if power of 2
    if val <= 0 or (val & (val - 1)) != 0:
        return None

    shift_count = val.bit_length() - 1
    if shift_count > 8:  # lsl only does up to 8 in immediate form
        return None

    current = cycles_for(instr).cycles  # ~70 cycles
    optimized = 6 + 2 * shift_count  # lsl.w base + 2× shift count

    return Match(
        pattern_name='mulu_to_lsl',
        start_idx=idx,
        end_idx=idx,
        instrs=[instr],
        current_cycles=current,
        optimized_cycles=optimized,
        savings=current - optimized,
        suggestion=f"Replace {instr.mnemonic} #{val} with: lsl.w #{shift_count}, {instr.dst_ea.raw}",
        line=instr.line,
    )


# All patterns to check
ALL_PATTERNS = [
    Pattern('consecutive_moves', 'N× move.l → movem.l', match_consecutive_moves_to_movem),
    Pattern('redundant_clr', 'clr then move to same loc', match_clr_then_move),
    Pattern('move_via_reg', 'mem→Dn→mem could be mem→mem', match_move_via_register),
    Pattern('expensive_ea_loop', 'd(An,Ri) in loop', match_expensive_ea_in_loop),
    Pattern('unroll', 'Tight loop unroll candidate', match_unrolling_candidate),
    Pattern('postinc', 'Use (An)+ instead of (An)+addq', match_postinc_opportunity),
    Pattern('byte_sequence', 'Many byte moves in loop', match_byte_moves_in_sequence),
    Pattern('mulu_power2', 'mulu by power of 2 → lsl', match_mulu_power_of_two),
]


def find_patterns(instrs: list[Instr], patterns: list[Pattern] | None = None) -> list[Match]:
    """Find all optimization patterns in instruction list."""
    if patterns is None:
        patterns = ALL_PATTERNS

    matches: list[Match] = []
    matched_ranges: set[tuple[int, int]] = set()

    for pattern in patterns:
        for idx in range(len(instrs)):
            # Skip if already matched by another pattern
            if any(start <= idx <= end for start, end in matched_ranges):
                continue

            match = pattern.matcher(instrs, idx)
            if match:
                matches.append(match)
                matched_ranges.add((match.start_idx, match.end_idx))

    return sorted(matches, key=lambda m: -m.savings)


def format_pattern_report(matches: list[Match], top_n: int = 20) -> str:
    """Format pattern matches as a text report."""
    lines = []
    lines.append("=" * 80)
    lines.append("OPTIMIZATION HINTS")
    lines.append("=" * 80)
    lines.append("")

    if not matches:
        lines.append("No optimization patterns found.")
        return '\n'.join(lines)

    total_savings = sum(m.savings for m in matches)
    lines.append(f"Found {len(matches)} patterns, total potential savings: {total_savings:,} cycles")
    lines.append("")
    lines.append(f"{'#':<3} {'Line':>5} {'Savings':>8} {'Pattern':<25} Suggestion")
    lines.append("-" * 80)

    for i, match in enumerate(matches[:top_n], 1):
        lines.append(f"{i:<3} {match.line:>5} {match.savings:>8} {match.pattern_name:<25} {match.suggestion[:50]}")

    if len(matches) > top_n:
        lines.append(f"... and {len(matches) - top_n} more")

    return '\n'.join(lines)
