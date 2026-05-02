"""Tests for the 68000 assembly parser."""

import sys
from pathlib import Path

# Add parent to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent.parent.parent))

from tools.cycles import parse_source, parse_ea, Instr, Directive, EAMode


class TestParseEA:
    """Test effective address parsing."""

    def test_data_register(self):
        ea = parse_ea('d0')
        assert ea.mode == EAMode.DN
        assert ea.reg == 'd0'

    def test_address_register(self):
        ea = parse_ea('a3')
        assert ea.mode == EAMode.AN
        assert ea.reg == 'a3'

    def test_sp_alias(self):
        ea = parse_ea('sp')
        assert ea.mode == EAMode.AN
        assert ea.reg == 'a7'

    def test_indirect(self):
        ea = parse_ea('(a0)')
        assert ea.mode == EAMode.IND
        assert ea.reg == 'a0'

    def test_postinc(self):
        ea = parse_ea('(a1)+')
        assert ea.mode == EAMode.POSTINC
        assert ea.reg == 'a1'

    def test_predec(self):
        ea = parse_ea('-(a7)')
        assert ea.mode == EAMode.PREDEC
        assert ea.reg == 'a7'

    def test_predec_sp(self):
        ea = parse_ea('-(sp)')
        assert ea.mode == EAMode.PREDEC
        assert ea.reg == 'a7'

    def test_displacement_an(self):
        ea = parse_ea('8(a0)')
        assert ea.mode == EAMode.D_AN
        assert ea.reg == 'a0'
        assert ea.disp == '8'

    def test_displacement_an_index(self):
        ea = parse_ea('4(a0,d1.w)')
        assert ea.mode == EAMode.D_AN_RI
        assert ea.reg == 'a0'
        assert ea.index == 'd1'
        assert ea.disp == '4'

    def test_pc_relative(self):
        ea = parse_ea('label(pc)')
        assert ea.mode == EAMode.D_PC
        assert ea.disp == 'label'

    def test_immediate(self):
        ea = parse_ea('#42')
        assert ea.mode == EAMode.IMM
        assert ea.disp == '42'

    def test_immediate_hex(self):
        ea = parse_ea('#$FF8240')
        assert ea.mode == EAMode.IMM
        assert ea.disp == '$FF8240'

    def test_absolute(self):
        ea = parse_ea('some_label')
        assert ea.mode == EAMode.ABS_L
        assert ea.disp == 'some_label'

    def test_reglist(self):
        ea = parse_ea('d0-d3/a0-a2')
        assert ea.mode == EAMode.REGLIST


class TestParseSource:
    """Test full source parsing."""

    def test_simple_move(self):
        items = parse_source('    move.l  d0, d1')
        assert len(items) == 1
        instr = items[0]
        assert isinstance(instr, Instr)
        assert instr.mnemonic == 'move'
        assert instr.size == 'l'
        assert instr.src_ea.mode == EAMode.DN
        assert instr.dst_ea.mode == EAMode.DN

    def test_label_with_instruction(self):
        items = parse_source('loop:\n    dbra d0, loop')
        assert len(items) == 1
        instr = items[0]
        assert instr.label == 'loop'
        assert instr.mnemonic == 'dbra'

    def test_local_label(self):
        items = parse_source('.inner:\n    rts')
        assert len(items) == 1
        assert items[0].label == '.inner'

    def test_directive_equ(self):
        items = parse_source('FOO equ $100')
        assert len(items) == 1
        d = items[0]
        assert isinstance(d, Directive)
        assert d.name == 'equ'
        assert d.label == 'FOO'

    def test_dc_directive(self):
        items = parse_source('    dc.w    1, 2, 3, 4')
        assert len(items) == 1
        d = items[0]
        assert isinstance(d, Directive)
        assert d.name == 'dc'
        assert d.size == 'w'

    def test_rept_expansion(self):
        src = '''    rept 3
    nop
    endr'''
        items = parse_source(src)
        assert len(items) == 3
        for item in items:
            assert isinstance(item, Instr)
            assert item.mnemonic == 'nop'
            assert item.is_rept_expanded

    def test_comment_annotation(self):
        items = parse_source('    dbra d7, .loop  ; @cycles iters=34')
        assert len(items) == 1
        assert items[0].annot.get('iters') == 34

    def test_movem_reglist(self):
        items = parse_source('    movem.l d0-d7/a0-a6, -(sp)')
        assert len(items) == 1
        instr = items[0]
        assert instr.mnemonic == 'movem'
        assert instr.src_ea.mode == EAMode.REGLIST
        assert instr.dst_ea.mode == EAMode.PREDEC

    def test_complex_displacement(self):
        items = parse_source('    move.w  scroll_y_1_base(a5), d0')
        assert len(items) == 1
        instr = items[0]
        assert instr.src_ea.mode == EAMode.D_AN
        assert instr.src_ea.reg == 'a5'
        assert 'scroll_y_1_base' in instr.src_ea.disp


if __name__ == '__main__':
    import pytest
    pytest.main([__file__, '-v'])
