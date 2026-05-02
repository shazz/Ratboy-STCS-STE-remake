# Stargoose Cracktro STE — Session Status

Last updated: 2026-05-01, session 6 — performance pass

## Session 6 — Performance: 1 VBL goal

**Starting state (HRDB measurement):**
- Effect 0: 70% @ 2 VBL, 30% @ 3 VBL
- Effects 1-7: 4-6 VBL each

**Current state after session 6:**
- Effect 0: 2 VBL (was working at 1 VBL with in-screen architecture, but
  reverted — see "Reverted: in-screen architecture" below)
- **Effects 1-7: 2 VBL** ← was 4-6 VBL, big win

**Target:** all effects @ 1 VBL like the 1988 original.

### Wins committed this session

| Commit | Description | Saving |
|--------|-------------|--------|
| `1cc3dbc` | In-screen scroll-row (CONFO.S `type6` trick) for Type 0 | ~22 sl |
| `635256e` | Phase 1 polish: glyph LUT + ShiftAndFill movem groups + a5 hoist | ~3 sl |
| `8c98092` | `PROFILE_ENABLED` toggle: color-bar timing of ScrollerStepVblank | (debug aid) |
| `7dee278` | Timer-B HBL: encoded markers + TBDR=2 → ~50 sl/VBL of work | ~50 sl |
| `ff04fb4` | **Reverted** in-screen architecture (broke effects 1-7) | (-22 sl on Type 0) |
| `0ba5f76` | ClearScrollerRegion: movem.l-based clear (13 regs) | ~40-50 sl |

### Reverted: in-screen architecture (1cc3dbc → ff04fb4)

The CONFO.S `type6` trick puts the scroll source row at Y=160 inside the
visible area — row 3 IS the source, no copy needed. Saved ~22 sl on
Type 0 by dropping the 3rd row plot.

**Why reverted:** for effects 1-7, `ClearScrollerRegion` clears Y=70..198
(includes Y=160..193 = the source row), wiping the source before the
plot reads it. AND multi-row effects (Type 1 bob extends to Y=167; Type 4
mirror writes Y=80..193) overwrite the source area. After SwapBuffers
the corrupted "source" becomes front, and next frame's `ScrollShiftAndFill`
byte-fills from corrupted data → cascading source corruption.

The in-screen trick is elegant for Type 0 in isolation but couldn't
survive the rest of the effect zoo. See `OPTIM.md` for the analysis and
discussion of the matching CONFO.S pattern.

### Timer-B HBL optimization (the big win)

Color-bar profiling (`PROFILE_ENABLED=1` + `RASTER_ENABLED=0`) revealed
the gradient HBL ISR was the bottleneck — visible scroller fits in 1 VBL
when raster is OFF, spills to 2 VBL when ON.

**Two-part optimization:**

1. **Encoded markers in raster_table values** — top nibble of each word
   encodes the action: `$0RGB`=normal write, `$4xxx`=skip (no write,
   bus-collision range), `$8RGB`/`$9RGB`/`$ARGB`=swap c1/c2/c3 + write.
   Common path drops from ~220 cy (3 cmpa.l + range check) to ~184 cy
   (one bmi + one btst). Static markers (skip, c3) patched in InstallHBL;
   dynamic markers (c1, c2) managed by SetPalettePointers via OR/AND.

2. **TBDR=2** — Timer-B fires every 2nd visible scanline, not every line.
   100 fires/frame instead of 200. Phase stable (200/2=100, no remainder).
   Gradient appears in 2-line bands. Swap markers and skip range
   realigned to fire-aligned byte offsets (multiples of `RASTER_FIRE_STRIDE=4`).

**Combined saving: ~50 sl per VBL of work.** Compounds across
multi-VBL effects.

### Movem clear (last win of session 6)

`ClearScrollerRegion` rewritten to use movem.l with 13 pre-zeroed
registers (d0-d6 + a1-a6). Per scanline: 432 cy vs 552 cy. Saves ~40-50 sl
wallclock per Clear call (with Shifter contention). For multi-VBL effects
this compounds — exactly what dropped them from 4-6 VBL to 2 VBL.

---

## Session 5c — RATBOY's smooth-scroll trick + Real Effect 7 + sequencer

**Highlights:**

1. **Smooth 8 px/VBL horizontal scroll** matching the 1988 STF original.
   Replaces the chunky 16 px/VBL pword shift with RATBOY's
   alternating-buffer trick — two scroll buffers `scroll_buffer_a` and
   `scroll_buffer_b` hold the same content offset by 1 byte (= 8 px),
   display alternates each frame, only ~40 sl/frame of shift work.
   See `docs/LEARNINGS.md` "Smooth 8 px / VBL scrolling" for the
   full explanation.

2. **Per-effect palette swap lines.** `raster_swap_c1_addr` and
   `raster_swap_c2_addr` are now runtime variables in `hbl.s` — each
   effect can relocate its palette boundaries to align with its content.
   See `EFFECTS.md` "Tuning palette swap lines per effect".

3. **Real Effect 7 implemented:** triangle-trajectory pair (/\\ and \\/)
   with letters meeting tip-to-tip at the centre + static bottom row.
   Per-effect c1 swap moved 4 lines higher (line 73 → c1 from Y=74) for
   triangle 1 headroom; c2 swap at line 121 between the apexes.

4. **Effect sequencer (P7) wired** — same trick as the original 1988
   code: bytes 1..8 embedded in the scroll text are effect-change
   markers (= effects 0..7); the parser consumes them, calls
   `SetPalettePointers`, and continues fetching. `src/data/scrolltext.s`
   now holds the full RATBOY 1988 sequence (text segments S1..S8 from
   the JS port, see `js_version/main.html`) cycling through all 8
   effects. After NULL wrap → loop back to effect 0.

| Type | Effect | Status |
|------|--------|--------|
| 0 | 3 fixed rows | ✅ |
| 1 | 2× tall + sine bob + per-strip deformation | ✅ |
| 2 | Water reflection (diagonal scroller + interleaved mirror) | ✅ |
| 3 | Sine wave + 1-line interleave + frame clearing | ✅ |
| 4 | Mirror diagonals across symmetry line + palette swap | ✅ |
| 5 | Static bottom + diagonal interleaved overlay | ✅ |
| 6 | 2 fixed rows | ✅ |
| 7 | Triangle trajectories (/\\ + \\/) + bottom row | ✅ |

**To select an effect:** change `SCROLL_EFFECT_DEFAULT` in
`src/constants.s` and rebuild.

---

## Architecture (current)

**8 px/VBL alternating-buffer scroll:**

* `scroll_buffer_a`, `scroll_buffer_b` (21 pwords × 34 lines each) hold
  the scroll content at offsets differing by 1 byte horizontally.
* `scroll_active_buf` flips each VBL; `scroll_plot_addr` points at the
  buffer plot routines should read from this frame.
* `scroll_next_pword` (1 pword × 34 lines) is the renderer's staging
  area, refilled every other VBL by the 5-phase glyph blender.
* `ScrollShiftAndFill` does a pword-shift on the just-flipped-active
  buffer plus a per-plane byte-shift fill on its rightmost pword,
  combining `scroll_other_buf[19]`'s low bytes with one half of
  `scroll_next_pword` (selected by `scroll_byte_pending`).
* `scroll_byte_pending` toggles each VBL: 0 → render this frame + use
  `scroll_next_pword` high bytes; 1 → no render, use low bytes.

**Per-effect palette swap lines** (runtime-configurable in `hbl.s`):

* `RASTER_SWAP_C1_DEFAULT` (line 77, c1 from Y=78) — used by all effects
  except 7.
* `RASTER_SWAP_C1_TYPE7` (line 73, c1 from Y=74).
* `RASTER_SWAP_C2_DEFAULT` (line 118, c2 from Y=119) — multi-row
  default.
* `RASTER_SWAP_C2_TYPE4` (line 131, c2 from Y=132) — type 4 mirror line.
* `RASTER_SWAP_C2_TYPE7` (line 121, c2 from Y=122) — type 7 between
  triangle apexes.
* `RASTER_SWAP_C3` (line 159, c3 from Y=160) — fixed for all effects.

**Strategy E (pure CPU)** + **double-buffer** for the screen pages:

* Off-screen scroll buffers in RAM (not on screen, unlike the original).
* Per-VBL: render new pword into `scroll_next_pword` (every other VBL) →
  ScrollShiftAndFill on inactive buffer → plot from active buffer to
  back screen → swap front/back screen pages.
* Plot routines read from `scroll_plot_addr` (one of the two scroll
  buffers, alternating).

## File map

```
src/
  main.s              entry; Main, MainLoop, CheckEsc
  constants.s         SCROLL_EFFECT_DEFAULT selects active effect (0..7)
  scroller/engine.s   render + ShiftAndFill + 8 effect plot routines
                      ClearScrollerRegion for moving effects
                      type1_traj_lut, type1_inside_lut, type7_depth_lut
  hbl.s               Timer-B handler + SetPalettePointers
                      raster_swap_c1_addr, raster_swap_c2_addr (BSS, per-effect)
  screen.s            Double-buffer setup
  vbl.s               VBL handler calls ScrollerStepVblank
  data/
    scrolltext.s      Text sequences (currently the diagnostic dense pattern)
    font.s            font.bin + c1/c2/c3 palettes
    gradient.s        raster_table
EFFECTS.md            per-effect configuration guide + palette swap tuning
docs/LEARNINGS.md     accumulated learnings; "Smooth 8 px / VBL" explains the
                      RATBOY trick we ported from CONFO.S
```

## How to resume next session

1. Read this file + `EFFECTS.md` + `docs/LEARNINGS.md`.
2. Pick effect via `SCROLL_EFFECT_DEFAULT` in `src/constants.s`.
3. Build: `/home/matt/projects/MJJ/bin/vasm/vasmm68k_mot -Ftos -quiet -spaces -I src -I . -o build/AUTO/STRGOOSE.PRG src/main.s`.
4. Run: `./run.sh` (Hatari STE, mounts `build/` as C:, AUTO-runs the PRG).

## Remaining work

* **Effect 0 → 1 VBL.** Currently 2 VBL. Lost the ~22 sl in-screen win to
  the architecture revert. Options:
  - Re-introduce in-screen architecture but ONLY for effect 0 (hybrid:
    BSS source for shift, copy to Y=160 only when effect 0 active).
  - Find another ~22 sl in plot/shift inner loops (movem grouping in
    plot, etc.).
* **Effects 1-7 → 1 VBL.** Currently 2 VBL. Matt's "extended-source"
  idea (pad scroll_buffer with zero lines so plot covers the bob range
  and replaces the explicit clear) — could save another 30-50 sl per
  VBL of work. Implement on Type 1 first as proof of concept, then
  replicate.
* **Original scrolltext + music polish** — re-test after Timer-B changes.

## Profile mode (debug)

Set in `src/constants.s`:
- `PROFILE_ENABLED=1` (also requires `RASTER_ENABLED=0` and recommended
  `MUSIC_ENABLED=0`).

Effect: `ScrollerStepVblank` writes color 0 at section boundaries:
- RED = `ScrollRenderNextPword` (every other VBL)
- GREEN = `ScrollShiftAndFill`
- BLUE = `ScrollPlotDispatch`
- BLACK = idle (work complete)

A blue band at the TOP of a frame indicates last frame's plot work bled
past the VBL boundary (= 2 VBL).

## Phase progress

| Phase | Status |
|-------|--------|
| P0–P5 | ✅ done |
| P6 — Mode A (3 parallel rows) | ✅ done |
| P6b — All 8 scroll effects | ✅ done |
| P6c — 8 px/VBL smooth scroll | ✅ done |
| P7 — Effect sequencer (in-text markers) | ✅ done |
| P8 — Original scrolltext + music polish | ✅ scrolltext done |
| P9 — Performance: all effects @ 1 VBL | 🚧 in progress (effects at 2 VBL) |
