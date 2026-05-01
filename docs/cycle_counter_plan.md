# 68000 cycle-counter & optimization-finder — implementation plan

> Static-analysis tool for our vasm Motorola assembly, predicting cycle
> usage per instruction / loop / subroutine and surfacing optimization
> candidates. Lives in `tools/`, written in Python ≥ 3.10, no external
> deps beyond the stdlib.

---

## Goals

1. **Predict cycle usage** of each instruction, loop iteration, and
   subroutine on a stock 68000 at 8 MHz, using the timing data in
   `docs/68000_execution_cycles.md`.
2. **Aggregate to frame budget** (313 sl × ~512 cy/sl ≈ 160 K cycles)
   for the per-VBL hot path so we can see who eats the most.
3. **Surface optimization candidates** — pattern-match the assembly for
   known rewrites (e.g. expensive `(d8,An) → (d8,An)` moves that could
   become `(An)+`-form) and output a prioritized punch list.
4. **Diff against CONFO.S** — parse both our engine and the original
   1988 routine, compute per-routine cycle deltas, identify where we
   are slower than the original and by how much.
5. **STE-aware** — model Shifter DMA contention during visible
   scanlines (~12 cy/word vs 8 cy/word in vblank). Same code costs
   different cycles depending on when it runs.

---

## Architecture

```
tools/cycles/
├── __main__.py        # CLI entry: tools/cycles --help
├── lexer.py           # tokenize vasm Motorola syntax
├── parser.py          # build IR: list of (label, instr, operand_str, ea_in/out, src_size, ...)
├── timings.py         # cycle table loaded from 68000_execution_cycles.md
├── cfg.py             # basic-block + subroutine CFG construction
├── analyzer.py        # cycle counting per block, per loop, per routine
├── patterns.py        # optimization-pattern matchers (rewrites + savings)
├── ste_model.py       # Shifter contention + Timer-B overhead model
├── differ.py          # routine-vs-routine diff (e.g. ours vs CONFO.S)
└── report.py          # text + (later) HTML output

tools/cycles/data/
├── instr_table.json   # the canonical instruction timings (manually
│                      # transcribed from docs/68000_execution_cycles.md
│                      # and double-checked against the Motorola PRM)
└── confo_s_baseline.json # cached CONFO.S analysis for diffing

tools/cycles/tests/
└── ...
```

---

## Phase 1 — Lexer + parser

### Lexer

Token types: `LABEL`, `MNEMONIC`, `OPERAND`, `DIRECTIVE`, `STRING`, `COMMENT`, `NEWLINE`, `EOF`.

Vasm-specific quirks:

- Labels end with `:` (most cases) but vasm also accepts label-at-col-1
  with no `:`. Be conservative and require `:` for our codebase since
  that's the convention.
- `.localname` labels are scoped to the previous global label.
- Comments: `;` to EOL (vasm-mot default) and `*` at column 0 (legacy).
- Directives: `equ`, `dc.b/.w/.l`, `ds.b/.w/.l`, `even`, `section`,
  `include`, `incbin`, `ifne`/`endif`, `rept`/`endr`.

### Parser → IR

For each instruction line, produce:

```python
@dataclass
class Instr:
    mnemonic: str           # 'move', 'add', 'movem', 'dbra', 'bsr', ...
    size: str               # 'b' | 'w' | 'l' | None
    src_ea: EA | None       # parsed EA mode (Dn / An / (An) / (d,An) / (xxx).w / Imm / ...)
    dst_ea: EA | None
    label: str | None       # label that precedes this instr on the same logical line
    line: int               # source line for error reporting
    raw: str                # original line for printing
    annot: dict             # parsed @cycles ... annotations
```

Effective-address modes (`EA`) are an enum: `DN`, `AN`, `IND`,
`POSTINC`, `PREDEC`, `D_AN` (= `d8(An)`), `D_AN_RI` (= `d8(An, Rn)`),
`ABS_W`, `ABS_L`, `D_PC`, `D_PC_RI`, `IMM`, `MOVEM_LIST`.

Handle vasm conveniences: `lea label(pc), An` is `D_PC` mode; `lea
label, An` may be assembled as either `ABS_L` or `D_PC` depending on
optimizer — assume `ABS_L` (worst case) by default.

### REPT / ENDR

Expand `REPT N` blocks inline so per-line cycle counts cover the
expansion. Keep a flag on `Instr` to mark expanded-vs-source so the
report can fold them.

### Annotations

Special comments drive analyzer behaviour:

```asm
                    ; @cycles iters=34       ; loop runs 34 times
                    ; @cycles taken=true     ; assume conditional branch is taken
                    ; @cycles entry=ScrollPlotType0  ; manually mark a routine entry
                    ; @cycles visible=on     ; this block runs during visible scanlines
                    ; @cycles ignore         ; don't count this block (e.g. dead code)
```

Default assumptions when no annotation present:

- DBRA fires `n+1` times where `n` is its initial counter value if
  detectable (`moveq #N, dN` immediately preceding); otherwise emit a
  warning and assume 1 iteration with a hint to annotate.
- Conditional branches: split into two paths, report both.
- `bsr` and `jsr`: recurse into the called routine if its body is in
  scope; otherwise report it as opaque.

---

## Phase 2 — Instruction timing table

### Source

Manually transcribe `docs/68000_execution_cycles.md` into
`tools/cycles/data/instr_table.json`. The MOVE matrix is the largest
piece (9 src × 9 dst × 2 sizes). Other instructions are individual
entries.

```json
{
  "move": {
    "matrix": {
      "Dn,Dn":     {"b/w": 4,  "l": 4},
      "Dn,(An)":   {"b/w": 8,  "l": 12},
      "Dn,(An)+":  {"b/w": 8,  "l": 12},
      "Dn,(d,An)": {"b/w": 12, "l": 16},
      ...
    }
  },
  "ea_calc": {
    "(An)":     {"b/w": 4,  "l": 8},
    "(An)+":    {"b/w": 4,  "l": 8},
    "(d,An)":   {"b/w": 8,  "l": 12},
    ...
  },
  "movem.w_to_regs":   "12 + 4n",
  "movem.l_to_regs":   "12 + 8n",
  "movem.w_to_mem":    "8 + 4n",
  "movem.l_to_mem":    "8 + 8n",
  "dbcc": {"taken": 10, "not_taken": 12, "fallthrough": 14},
  "bsr.s":   18,
  "rts":     16,
  ...
}
```

### Cycle calculator

```python
def cycles_for(instr: Instr) -> int:
    # 1. base cycles from instruction + src EA + dst EA matrix lookup
    # 2. add operand-size variant (b/w vs l)
    # 3. round to multiples of 4 (8MHz ST quirk per the doc)
    # 4. for movem, expand n × per-register cost
    # 5. for branches, return tuple (taken, not_taken)
```

Round to multiples of 4 per the doc's guidance ("On the ST at 8 MHz
you need to round all times to multiples of four. i.e 10 becomes 12.")

---

## Phase 3 — Control-flow graph

### Basic blocks

Split routine bodies at every label and after every branch / `rts` /
`jmp`. Each block has:

```python
@dataclass
class Block:
    label: str | None
    instrs: list[Instr]
    fallthrough: Block | None
    branches: list[tuple[str, Block]]   # (condition, target)
    is_loop_body: bool                   # auto-detected
    iter_count: int | None               # from annotation or moveq inference
```

### Subroutines

A subroutine starts at a `bsr`/`jsr` target label and ends at `rts` (or
`bra` to outside the subroutine). Recurse: if a routine calls another,
include the callee's cycle cost in the caller's total.

### Loops

Detect via backward `dbra` / `bra` to a label inside the same
subroutine. Compute `loop_total = body_cycles × iter_count`.

For `REPT N` blocks, inline expansion already handles the unrolling.

---

## Phase 4 — Per-routine reports

### Plain-text report

```
ScrollPlotType0   (src/scroller/engine.s:438-464)
─────────────────────────────────────────────────
  Setup:                       40 cy
  Outer loop (.line, 34 iters):
    REPT 5 movem (per iter):    560 cy   *** 70% ***
    addq.l #8, a0:               8 cy
    lea 24(a2), a2:              8 cy
    lea 24(a3), a3:              8 cy
    lea 24(a4), a4:              8 cy
    dbra d7, .line:             10 cy
  Total per iter:               602 cy
  Loop total (× 34):          20,468 cy
  Routine total:              20,508 cy   ≈ 40 sl

  Visible-cycle penalty (~30%):  +6,150 cy
  Effective on-visible:        26,658 cy   ≈ 52 sl
```

### Frame-level rollup

```
Per-VBL hot path (ScrollerStepVblank caller chain):
─────────────────────────────────────────────────
  ScrollPlotDispatch                  → routes to one of:
    ScrollPlotType7                   → 195 sl  ★ heaviest
    ScrollPlotType5                   → 167 sl
    ScrollPlotType4                   → 142 sl
    ...
  ScrollShiftAndFill                  →  41 sl
  ScrollRenderNextPword (avg ½ frame) →  12 sl
  ─────────────────────────────────────────────
  Frame budget                        → 313 sl
  Margin (with Type 7)                →  65 sl
  Margin (with Type 0)                → 130 sl
```

---

## Phase 5 — Optimization patterns

A pattern is `(matcher, savings_estimator, suggestion)`:

```python
@dataclass
class Pattern:
    name: str
    matcher: Callable[[list[Instr]], list[Match]]
    savings: Callable[[Match], int]   # cycles saved if applied
    suggest: Callable[[Match], str]   # textual rewrite suggestion
```

### Patterns to ship in v1

1. **`(d8,An) → (d8,An)` byte/word move**: 18-22 cy. Suggest
   `(d8,An) → (An)+` if dst is sequential = 16-18 cy.
2. **N consecutive `move.l` with sequential addresses**: replace with
   `movem.l reg-list, (An)` if N ≥ 4. Savings:
   `4 × 12 = 48 cy` vs `8 + 8×4 = 40 cy` per movem.l.
3. **`clr` followed by `move`**: collapse to a single `move` if the
   target was just cleared.
4. **`addq.l #N, An` with N > 8**: not allowed (addq max 8); flag
   if so. Suggest `lea N(An), An` (12-16 cy) instead of two addq's.
5. **Tight `dbra` loop with body ≤ 3 instructions**: unroll
   candidate. Estimate: dbra is 10 cy + ~16 cy fallthrough = 26 cy
   per iter overhead; if body is 12 cy, dbra dominates 70% of time.
6. **`move.l (a0), Dn / move.l Dn, (a1)`**: collapse to `move.l (a0),
   (a1)` (saves Dn round-trip, ~4 cy).
7. **`lea (d,An), An` where d ≤ 8 and same An**: replace with
   `addq.l #d, An`. Saves 8 cy.

### Output

```
OPTIMIZATION HINTS — top 10 by total cycles saved
──────────────────────────────────────────────────
1. ScrollShiftAndFill:.line  byte-shift loop            → 32 cy/iter  × 34 = 1,088 cy/frame
   Pattern: 4× consecutive (d,An)→(An)+
   Suggestion: replace with movem.l-based byte-permute via long ops
2. ScrollPlotType7:.scanline  3 sequential move.l       → 4 cy/iter × 34 × 20 = 2,720 cy/frame
   Pattern: triple write with same source
   Suggestion: load source once into d0/d1, then 3× write
...
```

---

## Phase 6 — STE contention model

Per `docs/LEARNINGS.md` (cooperative blitter section): Shifter
contention adds ~50% to CPU access cost during visible scanlines (12
cy/word vs 8 in vblank).

Model: each block carries a `visibility` flag (set by the
`@cycles visible=on` annotation, or inferred from where the block is
called: `ScrollerStepVblank` runs during MainLoop = visible;
`TimerBHandler` runs during visible scanlines, etc.).

When computing `effective_cycles`:

```
effective = baseline × (1 + contention_factor × visible_fraction)
```

Default `contention_factor = 0.4` (= 12/8 - 1 / 2, conservative
average across instruction mix).

Show both raw and effective cycles in reports — the gap between them
is itself a hint ("this routine costs 20% more than its raw count
because it runs during visible scanlines").

---

## Phase 7 — Diff vs CONFO.S

Parse `docs/STCS.RAT/CONFO.S` and our `src/scroller/engine.s` side by
side. For each routine pair (e.g. `scrolg` ↔ `ScrollShiftAndFill`),
report:

```
ScrollShiftAndFill ↔ scrolg
───────────────────────────
                    ours      original    delta
  per scanline:    608 cy    608 cy       0 cy     ✓ matches
  per frame:    20,672 cy   20,672 cy     0 cy     ✓ matches

ScrollPlotType0 ↔ scroh+typeN
─────────────────────────────
                    ours      original    delta
  per strip:        ?           ?          ?
  ...
```

Useful as a sanity check (we should be able to MATCH the original
within ~10%) and as a goal-setter (gap = optimization opportunity).

---

## Phase 8 — Bonus ideas worth exploring

1. **Hatari profiler integration**: Hatari has a built-in profiler
   (`debug profile on`). Capture its output and compare against our
   static prediction. Find divergences (= where our model is wrong).
2. **HTML visualisation**: per-line cycle bars rendered in a
   side-by-side view of the source. Quick eyeballing of hot spots.
3. **Branch-coverage flag**: track whether every conditional branch
   has been annotated with a `taken=true/false` hint. Unannotated
   branches show as warnings in the report.
4. **Register pressure heatmap**: track which registers are live at
   each program point. Find spots where we save registers we never
   use, or where movem could batch what's currently scattered moves.
5. **Loop unroll preview**: for any `dbra` loop, compute the cycle
   delta if unrolled by factor 2, 4, 8. Show as a "what-if" table.
6. **HBL/Timer-B overhead amortisation**: parse `TimerBHandler`,
   compute its per-fire cost, multiply by ~200 visible scanlines per
   frame, add to a running "interrupt overhead" accumulator. Result:
   a cycle budget for "non-mainloop" work that we can compare against
   our visible-line CPU time.
7. **Symbolic execution for d-register tracking**: when the analyzer
   sees `moveq #34, d7` then `dbra d7, .label`, it knows the loop
   runs 35 times. With a small symbolic interpreter (just for
   `moveq`, `move.w #imm, dn`, and arithmetic), we can auto-derive
   most loop counts without needing manual annotations.

---

## Implementation order (what to build first)

| Order | Phase | Goal |
|-------|-------|------|
| 1 | Lexer + parser | Read `engine.s` and produce a list of Instrs without crashing |
| 2 | Instruction timing table | Hardcode cycles for the 30 most-common ops in our codebase |
| 3 | Per-routine cycle aggregator | First report: ScrollPlotType0 cycle breakdown |
| 4 | Loop iter inference (moveq + dbra symbolic) | Eliminate need for most annotations |
| 5 | Frame-level rollup | First view: per-VBL hot path bar chart |
| 6 | Pattern matchers | Top-10 optimization hints |
| 7 | CONFO.S diff | Compare ScrollShiftAndFill ↔ scrolg |
| 8 | STE contention model | Add visible-vs-vblank weighting |
| 9 | HTML output | Side-by-side source + cycle bars |
| 10 | Hatari profiler diff | Verify static predictions against runtime |

Phases 1-3 give us the first useful output. Phases 4-6 give us the
optimization-finder. Phases 7-10 are polish + cross-validation.

---

## Risks / non-goals

- **Not** a cycle-exact emulator. The 68000 has prefetch effects,
  bus arbitration with the Shifter, DMA holds, etc. that we're
  approximating by ±10%. For more precision, run in Hatari with the
  built-in profiler.
- **Won't** track self-modifying code. CONFO.S has a few SMC
  patterns (e.g. `mod1` patches) — flag and ignore.
- **Won't** re-implement vasm. We're a reader, not an assembler. If
  vasm-specific syntax (e.g. operator precedence in `equ`
  expressions) is ambiguous, fall back to "warn and use 0 cycles for
  the expression evaluation".
- **No external deps** — Python stdlib only. Keeps the tool portable
  and easy to invoke from CI later.
