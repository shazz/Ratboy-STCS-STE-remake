# Stargoose Cracktro STE — Session Status

Last updated: 2026-04-30, session 5c — full intro feature-complete

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

* **Music re-enable + verify** (currently `MUSIC_ENABLED=1`, but worth
  retesting after the recent changes).
* **Polish pass** — startup glitch on first ~4 VBLs while the dual buffer
  pipeline fills (one rightmost-pword anomaly that scrolls off after
  ~ 1 second of run time). Could be hidden by running the shift+fill a
  few times during init.
* **Edge overlap on type 7** — the diverging legs of the two triangles
  geometrically overlap at strips 0/19 because each glyph is 34 lines
  tall. Visually the c2 letters bleed through c1 in the overlap band.
  Could be shortened by either reducing slope or tweaking
  `RASTER_SWAP_C2_TYPE7` to cover the worst-case extent.

## Phase progress

| Phase | Status |
|-------|--------|
| P0–P5 | ✅ done |
| P6 — Mode A (3 parallel rows) | ✅ done |
| P6b — All 8 scroll effects | ✅ done |
| P6c — 8 px/VBL smooth scroll | ✅ done |
| P7 — Effect sequencer (in-text markers) | ✅ done |
| P8 — Original scrolltext + music polish | ✅ scrolltext done |
