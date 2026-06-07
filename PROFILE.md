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

1. **🥇 Blitter the PLOT** — fixes the plot-bound slow trio (**4, 7, 1**), the
   biggest lever. Move the per-region buffer→screen copy to the cooperative
   blitter so the CPU overlaps the next frame's shift. The original's cheap-
   3-row secret. (`ste-blitter-expert`.)
2. **🥈 Type 3: `ClearScrollerRegion` → targeted `ClearScrollerRange`** — clear
   only the deformed footprint (as Type 1 does), not the full 130 lines. Small,
   low-risk, removes the ~110-line yellow band. Quick win.
3. Re-profile after each, ideally also sampling a *render* frame and confirming
   with the gradient on (drop to a brief `RASTER=1` visual check).
