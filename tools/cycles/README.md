# 68000 Cycle Counter

A static analysis tool for Motorola 68000 assembly that predicts cycle usage per instruction, routine, and loop. Designed for Atari ST/STE demo and game development.

## Usage

```bash
python -m tools.cycles <command> [options] <file>
```

## Commands

### analyze — Full analysis with loop detection

The main command. Shows cycle counts per routine with loop detection and iteration counts.

```bash
python -m tools.cycles analyze src/scroller/engine.s
```

Output:
```
File: engine.s
Total cycles (all routines): 322,660

Routine                                   Cycles    ~SL Loops
----------------------------------------------------------------------
ScrollShiftAndFill                        30,796   60.1 .line×34
ScrollPlotType4                           11,788   23.0 .scanline×34, .strip×20
...
```

Options:
- `-v, --verbose` — Show per-instruction cycle breakdown
- `-r ROUTINE` — Analyze only the specified routine

### frame — Frame-level cycle budget

Shows how routines fit within a PAL 50Hz frame (160,256 cycles / 313 scanlines).

```bash
python -m tools.cycles frame src/scroller/engine.s
```

Output includes:
- Per-routine cycle cost and percentage of frame
- Hot path totals (base + heaviest/lightest effect)
- Margin remaining in the frame

### optimize — Find optimization patterns

Detects common 68000 optimization opportunities.

```bash
python -m tools.cycles optimize src/scroller/engine.s
```

Patterns detected:
- **expensive_ea_in_loop** — Complex addressing modes inside tight loops
- **unroll_candidate** — Small loops that could benefit from unrolling
- **lea_vs_adda** — `adda.l #N,An` that could be `lea N(An),An`
- **moveq_range** — `move.l #N,Dn` where N fits in moveq range (-128..127)
- **clr_vs_moveq** — `clr.l Dn` that could be `moveq #0,Dn`
- **swap_add_swap** — Patterns replaceable with `add.l`
- **consecutive_moves** — Multiple moves to sequential addresses (use `movem`)
- **redundant_clr** — Clearing memory about to be overwritten

Options:
- `-n TOP` — Show top N matches (default: 10)
- `-r ROUTINE` — Analyze only the specified routine

### contention — STE Shifter contention model

Models the CPU/Shifter bus contention on Atari STE during visible scanlines.

```bash
python -m tools.cycles contention src/scroller/engine.s
python -m tools.cycles contention --budget src/scroller/engine.s
```

Contention factors:
- **VBlank** (113 scanlines): 1.0x (no contention)
- **Visible** (200 scanlines): 1.45x (~45% overhead)

The `--budget` flag shows frame budget with contention factored in.

### diff — Compare against CONFO.S (1988 original)

Compares your routines against the original RATBOY cracktro code.

```bash
python -m tools.cycles diff src/scroller/engine.s --confo docs/STCS.RAT/CONFO.S
```

Output:
```
CODE COMPARISON: engine.s vs CONFO.S (1988 original)

Our Routine               CONFO.S               Ours       Orig      Delta        %
-------------------------------------------------------------------------------------
ScrollShiftAndFill        scrolg              30,796     35,308    -4,512   -12.8% ★
...

Legend: ✓ = within 10%, ★ = faster than original, ! = slower than original
```

Options:
- `--confo PATH` — Path to CONFO.S file
- `--analyze-confo` — Just analyze CONFO.S without comparison

### Other commands

- `parse` — Dump parsed IR (labels, instructions, directives)
- `cycles` — Show cycle count per instruction
- `routines` — List routines with basic cycle counts (no loop detection)
- `routine` — Analyze a single routine by name

## How it works

1. **Lexer** (`lexer.py`) — Tokenizes vasm Motorola 68000 syntax
2. **Parser** (`parser.py`) — Builds IR with effective address parsing, expands REPT blocks
3. **Timings** (`timings.py`) — Cycle lookup from `data/instr_table.json` (full 68000 timing tables)
4. **Symbols** (`symbols.py`) — Evaluates EQU expressions for loop iteration counts
5. **Analyzer** (`analyzer.py`) — Detects loops via backward `dbra`/`dbf` branches, infers iteration counts from counter setup (`moveq`/`move.w`)
6. **Patterns** (`patterns.py`) — Pattern matching for optimization opportunities
7. **STE Model** (`ste_model.py`) — Shifter contention modeling

## Limitations

- **Subroutine calls**: `bsr`/`jsr` cycles are counted, but the called routine's cycles are not inlined. For routines that delegate heavily to subroutines, the reported cycles will be lower than actual execution.
- **Conditional branches**: All branch paths are counted once; no branch prediction modeling.
- **Self-modifying code**: Not detected or handled.
- **Macro expansion**: Only `REPT`/`ENDR` is expanded; other macros are treated as unknown mnemonics.

## Example workflow

```bash
# 1. Get overview of all routines
python -m tools.cycles analyze src/scroller/engine.s

# 2. Check frame budget
python -m tools.cycles frame src/scroller/engine.s

# 3. Find optimization opportunities
python -m tools.cycles optimize src/scroller/engine.s

# 4. Deep-dive into a specific routine
python -m tools.cycles analyze -v -r ScrollShiftAndFill src/scroller/engine.s

# 5. Compare against original CONFO.S
python -m tools.cycles diff src/scroller/engine.s --confo docs/STCS.RAT/CONFO.S
```
