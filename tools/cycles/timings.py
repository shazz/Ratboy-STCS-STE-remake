"""68000 instruction timing calculator."""

from __future__ import annotations
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from .parser import Instr, EA, EAMode


@dataclass(frozen=True, slots=True)
class CycleResult:
    """Result of cycle calculation."""
    cycles: int
    raw_cycles: int           # before ST rounding
    note: str = ''
    is_branch: bool = False
    taken_cycles: int = 0     # for branches
    not_taken_cycles: int = 0


# Load timing table
_TABLE_PATH = Path(__file__).parent / 'data' / 'instr_table.json'
with open(_TABLE_PATH) as f:
    TABLE = json.load(f)


def round_st(cycles: int) -> int:
    """Round to multiples of 4 for ST at 8MHz."""
    return ((cycles + 3) // 4) * 4


def ea_to_table_key(ea: EA) -> str:
    """Convert EA to table lookup key."""
    mode_map = {
        EAMode.DN: 'dn',
        EAMode.AN: 'an',
        EAMode.IND: '(an)',
        EAMode.POSTINC: '(an)+',
        EAMode.PREDEC: '-(an)',
        EAMode.D_AN: 'd(an)',
        EAMode.D_AN_RI: 'd(an,ri)',
        EAMode.ABS_W: 'abs.w',
        EAMode.ABS_L: 'abs.l',
        EAMode.D_PC: 'd(pc)',
        EAMode.D_PC_RI: 'd(pc,ri)',
        EAMode.IMM: 'imm',
        EAMode.REGLIST: 'reglist',
        EAMode.SR: 'sr',
        EAMode.CCR: 'ccr',
        EAMode.USP: 'usp',
    }
    return mode_map.get(ea.mode, 'abs.l')


def size_index(size: str | None) -> int:
    """Get index into [b/w, l] timing arrays."""
    return 1 if size == 'l' else 0


def is_memory_ea(ea: EA) -> bool:
    """Check if EA accesses memory."""
    return ea.mode not in (EAMode.DN, EAMode.AN, EAMode.IMM, EAMode.SR, EAMode.CCR, EAMode.USP)


def count_registers(reglist: str) -> int:
    """Count registers in a movem register list like 'd0-d3/a0-a2'."""
    count = 0
    for part in reglist.replace(' ', '').split('/'):
        if '-' in part:
            # Range like d0-d3
            m = re.match(r'([ad])(\d)-([ad])(\d)', part, re.I)
            if m:
                start, end = int(m.group(2)), int(m.group(4))
                count += abs(end - start) + 1
            else:
                count += 1
        else:
            count += 1
    return count


def cycles_for_move(instr: Instr) -> CycleResult:
    """Calculate cycles for MOVE instruction."""
    if not instr.src_ea or not instr.dst_ea:
        return CycleResult(4, 4, note='move: missing operand')

    src_key = ea_to_table_key(instr.src_ea)
    dst_key = ea_to_table_key(instr.dst_ea)
    idx = size_index(instr.size)

    # Look up in move matrix
    move_table = TABLE.get('move', {})
    src_row = move_table.get(src_key)
    if not src_row:
        return CycleResult(12, 12, note=f'move: unknown src {src_key}')

    timing = src_row.get(dst_key)
    if not timing:
        # Try abs.l as fallback for labels
        timing = src_row.get('abs.l', [16, 20])

    raw = timing[idx] if isinstance(timing, list) else timing
    return CycleResult(round_st(raw), raw)


def cycles_for_movea(instr: Instr) -> CycleResult:
    """Calculate cycles for MOVEA (move to address register)."""
    if not instr.src_ea:
        return CycleResult(4, 4, note='movea: missing src')

    src_key = ea_to_table_key(instr.src_ea)
    idx = size_index(instr.size)

    move_table = TABLE.get('move', {})
    src_row = move_table.get(src_key)
    if not src_row:
        return CycleResult(12, 12, note=f'movea: unknown src {src_key}')

    timing = src_row.get('an', [4, 4])
    raw = timing[idx] if isinstance(timing, list) else timing
    return CycleResult(round_st(raw), raw)


def cycles_for_moveq(instr: Instr) -> CycleResult:
    """Calculate cycles for MOVEQ."""
    return CycleResult(4, 4)


def cycles_for_movem(instr: Instr) -> CycleResult:
    """Calculate cycles for MOVEM."""
    if not instr.src_ea or not instr.dst_ea:
        return CycleResult(12, 12, note='movem: missing operand')

    # Determine direction: reg→mem or mem→reg
    if instr.src_ea.mode == EAMode.REGLIST:
        # reg → mem
        reglist = instr.src_ea.disp or ''
        n_regs = count_registers(reglist)
        dst_key = ea_to_table_key(instr.dst_ea)
        base_table = TABLE.get('movem', {}).get('reg_to_mem', {})
        base = base_table.get(dst_key, 8)
    else:
        # mem → reg
        reglist = instr.dst_ea.disp or '' if instr.dst_ea.mode == EAMode.REGLIST else ''
        n_regs = count_registers(reglist)
        src_key = ea_to_table_key(instr.src_ea)
        base_table = TABLE.get('movem', {}).get('mem_to_reg', {})
        base = base_table.get(src_key, 12)

    # Add per-register cost: 4 for .w, 8 for .l
    per_reg = 8 if instr.size == 'l' else 4
    raw = base + (per_reg * n_regs)
    return CycleResult(round_st(raw), raw, note=f'{n_regs} regs')


def cycles_for_lea(instr: Instr) -> CycleResult:
    """Calculate cycles for LEA."""
    if not instr.src_ea:
        return CycleResult(8, 8, note='lea: missing src')

    src_key = ea_to_table_key(instr.src_ea)
    lea_table = TABLE.get('control', {}).get('lea', {})
    raw = lea_table.get(src_key, 12)
    return CycleResult(round_st(raw), raw)


def cycles_for_standard(instr: Instr, mnemonic: str) -> CycleResult:
    """Calculate cycles for standard ALU ops (add, sub, and, or, cmp, eor)."""
    std_table = TABLE.get('standard', {}).get(mnemonic)
    if not std_table:
        return CycleResult(8, 8, note=f'{mnemonic}: not in table')

    idx = size_index(instr.size)

    # Determine operand pattern
    if instr.dst_ea and instr.dst_ea.mode == EAMode.AN:
        timing = std_table.get('ea_an', [8, 8])
    elif instr.dst_ea and instr.dst_ea.mode == EAMode.DN:
        timing = std_table.get('ea_dn', [4, 8])
    elif instr.src_ea and instr.src_ea.mode == EAMode.DN and instr.dst_ea and is_memory_ea(instr.dst_ea):
        timing = std_table.get('dn_mem', [8, 12])
    else:
        timing = std_table.get('ea_dn', [4, 8])

    raw = timing[idx] if isinstance(timing, list) else timing

    # Add EA calculation time for memory operands
    if instr.src_ea and is_memory_ea(instr.src_ea):
        ea_key = ea_to_table_key(instr.src_ea)
        ea_time = TABLE.get('ea_calc', {}).get(ea_key, [0, 0])
        raw += ea_time[idx] if isinstance(ea_time, list) else ea_time

    return CycleResult(round_st(raw), raw)


def cycles_for_immediate(instr: Instr, mnemonic: str) -> CycleResult:
    """Calculate cycles for immediate instructions (addi, subi, addq, subq, etc.)."""
    imm_table = TABLE.get('immediate', {}).get(mnemonic)
    if not imm_table:
        return CycleResult(8, 8, note=f'{mnemonic}: not in table')

    idx = size_index(instr.size)

    # Determine destination type
    if instr.dst_ea:
        if instr.dst_ea.mode == EAMode.DN:
            timing = imm_table.get('dn', [4, 8])
        elif instr.dst_ea.mode == EAMode.AN:
            timing = imm_table.get('an', [8, 8])
        else:
            timing = imm_table.get('mem', [8, 12])
    elif instr.src_ea:
        # Single operand (clr, tst, etc.)
        if instr.src_ea.mode == EAMode.DN:
            timing = imm_table.get('dn', [4, 8])
        elif instr.src_ea.mode == EAMode.AN:
            timing = imm_table.get('an', [8, 8])
        else:
            timing = imm_table.get('mem', [8, 12])
    else:
        timing = imm_table.get('dn', [4, 8])

    raw = timing[idx] if isinstance(timing, list) else timing
    return CycleResult(round_st(raw), raw)


def cycles_for_shift(instr: Instr, mnemonic: str) -> CycleResult:
    """Calculate cycles for shift/rotate instructions."""
    shift_table = TABLE.get('shift', {}).get(mnemonic)
    if not shift_table:
        return CycleResult(8, 8, note=f'{mnemonic}: not in table')

    idx = size_index(instr.size)

    # Register or memory?
    if instr.dst_ea and is_memory_ea(instr.dst_ea):
        raw = shift_table.get('mem', 8)
    else:
        base = shift_table.get('reg', [6, 8])
        raw = base[idx] if isinstance(base, list) else base
        # Add 2 × shift count (default 1 if not specified)
        shift_count = 1
        if instr.src_ea and instr.src_ea.mode == EAMode.IMM:
            try:
                shift_count = int(instr.src_ea.disp or '1')
            except ValueError:
                pass
        raw += 2 * shift_count

    return CycleResult(round_st(raw), raw)


def cycles_for_branch(instr: Instr, mnemonic: str) -> CycleResult:
    """Calculate cycles for branch instructions."""
    branch_table = TABLE.get('branch', {})
    timing = branch_table.get(mnemonic)

    if timing is None:
        return CycleResult(10, 10, note=f'{mnemonic}: not in table')

    if isinstance(timing, dict):
        taken = timing.get('taken', 10)
        not_taken = timing.get('not_taken', 8)
        return CycleResult(
            round_st(taken), taken,
            is_branch=True,
            taken_cycles=round_st(taken),
            not_taken_cycles=round_st(not_taken)
        )
    else:
        return CycleResult(round_st(timing), timing)


def cycles_for_dbcc(instr: Instr, mnemonic: str) -> CycleResult:
    """Calculate cycles for DBcc instructions."""
    dbcc_table = TABLE.get('dbcc', {})
    timing = dbcc_table.get(mnemonic)

    if timing is None:
        return CycleResult(10, 10, note=f'{mnemonic}: not in table')

    loop = timing.get('loop', 10)
    exit_cy = timing.get('exit', 14)
    return CycleResult(
        round_st(loop), loop,
        note=f'loop={loop}, exit={exit_cy}',
        is_branch=True,
        taken_cycles=round_st(loop),
        not_taken_cycles=round_st(exit_cy)
    )


def cycles_for_control(instr: Instr, mnemonic: str) -> CycleResult:
    """Calculate cycles for JMP, JSR, PEA."""
    ctrl_table = TABLE.get('control', {}).get(mnemonic)
    if not ctrl_table:
        return CycleResult(16, 16, note=f'{mnemonic}: not in table')

    if instr.src_ea:
        ea_key = ea_to_table_key(instr.src_ea)
        raw = ctrl_table.get(ea_key, 12)
    else:
        raw = 12

    return CycleResult(round_st(raw), raw)


def cycles_for_bit(instr: Instr, mnemonic: str) -> CycleResult:
    """Calculate cycles for bit instructions (btst, bset, bclr, bchg)."""
    bit_table = TABLE.get('bit', {}).get(mnemonic)
    if not bit_table:
        return CycleResult(8, 8, note=f'{mnemonic}: not in table')

    # Destination is register or memory?
    if instr.dst_ea and is_memory_ea(instr.dst_ea):
        timing = bit_table.get('mem', [8, 12])
    else:
        timing = bit_table.get('reg', [8, 12])

    # Bit ops on reg are .l, on mem are .b
    idx = 1 if (instr.dst_ea and not is_memory_ea(instr.dst_ea)) else 0
    raw = timing[idx] if isinstance(timing, list) else timing
    return CycleResult(round_st(raw), raw)


def cycles_for_misc(instr: Instr, mnemonic: str) -> CycleResult:
    """Calculate cycles for miscellaneous instructions."""
    misc_table = TABLE.get('misc', {})
    timing = misc_table.get(mnemonic)

    if timing is None:
        return CycleResult(4, 4, note=f'{mnemonic}: not in misc table')

    if isinstance(timing, dict):
        # Has variants
        if 'reg' in timing and instr.src_ea and instr.src_ea.mode in (EAMode.DN, EAMode.AN):
            raw = timing['reg']
        elif 'mem' in timing:
            raw = timing['mem']
        else:
            raw = list(timing.values())[0]
    else:
        raw = timing

    return CycleResult(round_st(raw), raw)


def cycles_for(instr: Instr) -> CycleResult:
    """Calculate cycles for an instruction."""
    mnem = instr.mnemonic.lower()

    # MOVE family
    if mnem == 'move':
        return cycles_for_move(instr)
    if mnem == 'movea':
        return cycles_for_movea(instr)
    if mnem == 'moveq':
        return cycles_for_moveq(instr)
    if mnem == 'movem':
        return cycles_for_movem(instr)

    # LEA
    if mnem == 'lea':
        return cycles_for_lea(instr)

    # Standard ALU
    if mnem in ('add', 'adda', 'and', 'cmp', 'cmpa', 'eor', 'or', 'sub', 'suba', 'divs', 'divu', 'muls', 'mulu'):
        return cycles_for_standard(instr, mnem)

    # Immediate ops
    if mnem in ('addi', 'addq', 'andi', 'cmpi', 'eori', 'ori', 'subi', 'subq', 'clr', 'neg', 'negx', 'not', 'nbcd', 'tst'):
        return cycles_for_immediate(instr, mnem)

    # Scc
    if mnem.startswith('s') and len(mnem) <= 3 and mnem != 'sub' and mnem != 'swap' and mnem != 'stop':
        return cycles_for_immediate(instr, 'scc')

    # Shift/rotate
    if mnem in ('asl', 'asr', 'lsl', 'lsr', 'rol', 'ror', 'roxl', 'roxr'):
        return cycles_for_shift(instr, mnem)

    # Branches (bhs=bcc, blo=bcs are aliases)
    if mnem == 'bhs':
        mnem = 'bcc'
    if mnem == 'blo':
        mnem = 'bcs'
    if mnem in ('bcc', 'bcs', 'beq', 'bge', 'bgt', 'bhi', 'ble', 'bls', 'blt', 'bmi', 'bne', 'bpl', 'bvc', 'bvs', 'bra', 'bsr'):
        return cycles_for_branch(instr, mnem)

    # DBcc
    if mnem.startswith('db'):
        return cycles_for_dbcc(instr, mnem)

    # Control flow
    if mnem in ('jmp', 'jsr', 'pea'):
        return cycles_for_control(instr, mnem)

    # Bit ops
    if mnem in ('btst', 'bset', 'bclr', 'bchg'):
        return cycles_for_bit(instr, mnem)

    # Misc
    if mnem in TABLE.get('misc', {}):
        return cycles_for_misc(instr, mnem)

    # Other table
    other = TABLE.get('other', {}).get(mnem)
    if other:
        idx = size_index(instr.size)
        if isinstance(other, dict):
            if 'reg' in other:
                timing = other['reg']
                raw = timing[idx] if isinstance(timing, list) else timing
            elif 'mem' in other:
                timing = other['mem']
                raw = timing[idx] if isinstance(timing, list) else timing
            else:
                raw = list(other.values())[0]
        else:
            raw = other
        return CycleResult(round_st(raw), raw)

    # Unknown — return a default
    return CycleResult(4, 4, note=f'unknown instruction: {mnem}')
