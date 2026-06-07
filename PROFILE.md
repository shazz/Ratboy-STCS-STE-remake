# Scroller Profile — session 8 (post clear/MULU/unroll/self-mod-ISR)

Color-bar profiling of `ScrollerStepVblank`, per effect type. Goal: find which
effects spill past 1 VBL and *why*, to aim the next optimisation.

## Method

Toggles (`constants.s`): `PROFILE_ENABLED=1`, `RASTER_ENABLED=0` (else Timer-B
overwrites colour 0), `MUSIC_ENABLED=0` (remove the music ISR). A test scrolltext
cycled every effect. Each section writes colour 0, so its on-screen band height =
the scanlines that section consumed that frame.

Colour legend (`PROFILE_COLOR` sites):

| Colour | Section |
|--------|---------|
| 🟥 red `$F00` | `ScrollRenderNextPword` (glyph blend, every *other* VBL) |
| 🟩 green `$0F0` | `ScrollShiftAndFill` (shift all pwords) |
| 🟨 yellow `$FF0` | clear (`ClearScrollerRegion`/`Range`, cooperative blitter) |
| 🟦 blue `$00F` | `ScrollPlotDispatch` (copy buffer → screen) |
| ⬛ black `$000` | idle (work done — headroom) |

**Caveat — this measures the MAIN THREAD only.** With `RASTER=0` there is no
Timer-B gradient ISR (~30 sl/frame stolen across the frame when on) and no music.
So an effect at ~0 idle here will spill to 2 VBL once the gradient is on. The
**authoritative "what actually feels slow" ranking is Matt's, observed in the
real demo (gradient + music on):**

> **4 & 7 are the slowest, then 1 & 3. The others (0, 2, 5) are fine.**

Also: every capture landed on a *non-render* VBL (no red band), so the
render-frame cost (every other frame) is not shown — it adds to the heavy frames.

## Per-effect (≈ scanlines, non-render frame)

| Type | shift | clear | plot | idle | clear routine | bottleneck | real-demo |
|------|------:|------:|-----:|-----:|---------------|------------|-----------|
| 0 (3-row) | 35 | — | 140 | ~25 | none | plot | fine |
| 1 (2× sine) | sm | sm (Range) | sm | most | `ClearScrollerRange` (targeted) | plot (2× rows) | **slowish** |
| 2 (reflection) | 35 | — | 165 | ~0 | none | plot (2× copy) | fine |
| 3 (interleave) | 35 | **110** | 15 | ~0 | **`ClearScrollerRegion`** (full 130) | **clear** | **slowish** |
| 4 (mirror) | 35 | — | 160 | ~0 | none | plot (2 scrollers) | **slowest** |
| 5 (top+bottom) | 35 | — | 160 | ~0 | none | plot | fine |
| 7 (triangles) | 35 | — | 165 | ~0 | none | plot (2 tri + row) | **slowest** |

(Type 7 is already REPT-unrolled; Type 0 unrolled this session.)

## Findings

1. **The slow effects split into two bottlenecks:**
   - **Plot-bound: 4, 7, 1** — they copy multiple regions to screen (mirror =
     2 scrollers; triangles = 2 + bottom row; Type 1 = 2× vertical = 68 dest
     lines from 34 source). The CPU `movem` plot fills the frame.
   - **Clear-bound: 3** — it's the *only* effect calling `ClearScrollerRegion`
     (the full conservative Y=70..199 = 130 lines). Type 1 already proves the
     **targeted** `ClearScrollerRange` is far cheaper (Type 1's clear barely
     registers).
2. Types 0, 2, 5 fit comfortably (0 has ~25 idle even before the ISR).
3. The `RASTER=0` band heights don't perfectly predict the real spill (e.g. 4 vs
   5 look similar here but differ in the demo) — the ISR + render-frame cost +
   the specific multi-region plots tip 4/7/1 over. Trust the real-demo ranking.

## Recommended next optimisations (in priority order)

1. ~~**Blitter the PLOT**~~ — **TRIED, REVERTED (negative result, see below).**
2. **Type 3: targeted clear** — ✅ DONE (`0a6304b`), ~46 sl saved on Type 3.
3. **Achievable plot win: CPU-side per-strip unrolls** for the plot-bound
   effects (4, 7, 1). Type 4's `.scanline` still uses `dbra`; unroll it like
   Type 0. Modest (~few sl each) but real and low-risk.
4. Re-profile after each, ideally sampling a *render* frame too.

## Blitter plot — negative result (measured)

Profiled Type 0 with a cooperative copy-blit (`ScrollBlitCopyRow`, OP=3 source)
vs the CPU `movem` unroll (`PROFILE_ENABLED=1` / `RASTER=0`):

- Unroll: blue(plot) **~140 sl** + ~25 idle.
- Blit:   blue(plot) **~165 sl**, **0 idle** → **~25 sl SLOWER.**

Why: the plot runs during the visible region, so the blit MUST be cooperative
(hog would freeze the Timer-B gradient). Calibration from the clear: the
cooperative CLEAR already runs ~4.7 cy/word (write-only) — ~2× theoretical
because of the 64-cy bus yields + the `bset/nop/bne` restart busy-wait. A COPY
is read+write (~2× the traffic), landing at ≈ or worse than the CPU's ~9 cy/word
`movem` (which also gets read-sharing across Type 0's 3 rows). The clear won
*only because it is write-only*; the plot is not a win under the cooperative
constraint.

A real blitter-plot win would need CPU/blit **overlap** — run the next frame's
`ShiftAndFill` in the blit's yield slots instead of busy-waiting — a large,
uncertain restructure. Parked. The realistic plot wins are CPU-side (unroll).
