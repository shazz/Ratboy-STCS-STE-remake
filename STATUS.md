# Stargoose Cracktro STE — Session Status

Last updated: 2026-04-22, end of session 1

## Phase progress

| Phase | Status | Notes |
|-------|--------|-------|
| P0  — Hello ST (boot + red screen + exit) | ✅ completed | |
| P1  — Interrupt plumbing (VBL + HBL) | ✅ completed | VBL via `_vblqueue` slot (not `$70` overwrite) |
| P2  — Static background (logo + stars) | ✅ completed | `png2planar.py` + baked top 74 lines |
| P3  — Raster gradient via HBL | ✅ completed | Per-scanline color-0 writes; 62-entry top-overscan padding |
| P4  — SNDH music integration | ✅ completed | Thrust.snd, VBL-driven, clean ESC teardown |
| P5  — Font + single-row scroller | ✅ **completed with known limitation** | See "Open issues" |
| P6  — Mode A (3 rows + palette swap) | 🟡 **in progress** | Boundary palette swap (logo→font at line 74) just implemented; 3-row rendering still TODO |
| P7  — Mode B (big sine + reflection) | ⬜ pending | |
| P8  — Modes C/D/E + 9-sequence sequencer | ⬜ pending | |
| P9  — Polish | ⬜ pending | |
| P10 — Authenticity + cycle optimization | ⬜ pending | **Carries the P5 tear fix** |

## What's working end-to-end

Boot into Hatari STE (via `uv run tools/build.py --run`, which places `STRGOOSE.PRG` in `build/AUTO/` and mounts `build/` as GEMDOS C:):

- BLADE RUNNERS logo + starfield in top 74 scanlines (baked bitmap + palette)
- Blue→red raster gradient in the bottom 126 scanlines (per-scanline color-0 writes via HBL, table padded 62 entries to match PAL top overscan)
- Thrust YM music from SNDH, 50 Hz VBL-driven replay
- Scroller row at Y=130 with S1 text ("PLEASE, READ ALL THIS SCROLL..."), 8 px/VBL (400 px/sec), smooth motion at 50 Hz update rate
- Transparent font background — the gradient shows through inter-letter areas via red-sentinel → index 0 mapping in `png2font.py`
- Palette swap at visible line 74 — logo's colors 1-15 above, font's colors 1-15 below; color 0 always tracks the raster gradient
- ESC exits cleanly (restores palette, resolution, screen base, un-hooks interrupts)

## File map (source of truth)

```
src/
  main.s               entry point; Main, MainLoop, CheckEsc; includes everything else
  constants.s          HW register equates, screen/scroll geometry, font dims
  macros.s             WAIT_VBL, SET_COLOR_IMM
  system.s             Super mode enter/exit, SaveState/RestoreState, WaitEscKey
  screen.s             InitScreen — low-res, LINEWID=12, palette, buffer alloc, logo blit
  vbl.s                VBL handler: counter + palette reinstall + music + scroll-buffer copy (IPL=1 during copy)
  hbl.s                HBL handler: color-0 raster + one-shot palette swap at PALETTE_SWAP_LINE
  music.s              SNDH wrapper (MusicSndhInit / Play / Exit)
  scroller/engine.s    Scroller — scroll_buffer (34×184 BSS), shift, render, copy-to-screen
  data/
    background.s       incbin build/top_logo.img + top_logo.pal
    font.s             incbin build/font.bin + font.pal
    music.s            incbin assets/thrust.snd
    gradient.s         raster_table with top-overscan + bottom padding, swap-trigger label
    scrolltext.s       9 sequence text blocks (S1 active; others for P8)
tools/
  build.py             uv-runnable orchestrator (assets → VASM → Hatari)
  png2planar.py        PNG → ST 4-bitplane + STE palette
  png2font.py          Font PNG (8×8 glyph grid, red=transparent) → per-glyph pack
  gradient2raster.py   gradient.png → per-scanline $0rgb table
assets/
  top_logo.png, fonts40x34_red_as_transparent.png, gradient.png, thrust.snd, ...
docs/
  ARCHITECTURE.md, decisions.md, PLAN.md, LEARNINGS.md, STATUS.md (this file),
  memory_map.txt, 68000_execution_cycles.md, blitter_manual.md, blitter_faq.txt,
  blitter_execution_times.md
```

## Open issues / deferred work

### P5: scroll row tear at ~visible line 157

**Symptom:** bottom ~7 scanlines of scroll row (lines ~157–163) show the previous frame's shift state — an 8 px horizontal offset on the lower portion of each glyph.

**Root cause:** `ScrollCopyToScreen` (in VBL handler) can't finish copying the 6256-byte scroll_buffer to screen before the Shifter reaches scroll row at scanline ~193. Plain `move.l (a0)+, (a1)+` loop runs ~47K cy pure + ~20K cy during visible area (bus-contended at roughly 20%).

**Attempts:** Tried MOVEM-batched copy — smaller cycle estimate but runs *slower* in practice under Shifter contention (possibly fewer interleaved bus windows). Reverted.

**P10 fix:** Replace with STE blitter simple copy. Blitter transfers ~1 word per 4 bus cycles → ~12K cy for the full 6256-byte copy. Finishes during overscan window (first 62 scanlines) with plenty of margin. `docs/blitter_manual.md` + `docs/blitter_faq.txt` have the spec.

### STE HSCROLL ($FF8265) silently ignored in our Hatari setup

**Symptom:** Writing HSCROLL=8 statically (diagnostic #5) did not shift the displayed 'A' at all. Confirmed it was reaching the register; the Shifter just didn't honor it.

**Hypotheses (unconfirmed):** may need $FF8264 "preset" written first in prefetch mode; may be a Hatari STE quirk with our TOS; may need specific LINEWID+HSCROLL timing.

**Workaround:** Dropped HSCROLL entirely. Use ST-style CPU byte-move shift of scroll_buffer (8 px per VBL, byte moves since 8 px = exactly a byte boundary). Works, runs ~132K cy per frame.

**P10 follow-up:** Investigate via Hatari debugger or web research. Blitter SKEW would obsolete HSCROLL anyway (does hardware bit-shift during copy).

### 8 px/VBL scroll speed is fast (400 px/sec)

Original cracktro was ~150 px/sec. Our chunky-by-8-px scroll runs 2.5× too fast. In P10, blitter SKEW unlocks 2 px/VBL smooth for authentic pacing.

## Next session restart plan

1. **Resume P6** — 3-row rendering with per-row palette swap.
   - Boundary swap at line 74 is already in (logo→font). Works for one band.
   - Add 3-row mode: three scroll row bands at Y=82, Y=122, Y=162 (from JS sequence S1), each with same text but different palette.
   - Need to extract palette variants from `font40x34_c2.png`, `font40x34_c3.png` (we've been using only c1). `png2font.py` would need a `--palette-only` mode to produce `.pal` files without re-extracting bitmap.
   - Add per-row HBL palette swaps (3 swap events per frame, same mechanism as current line-74 swap).

2. **OR skip ahead to P10 scroll-tear fix** if the visual bug is bothering. Blitter-simple-copy is a bounded ~1 hour task and gives tear-free smooth.

3. **Either way:** test the in-progress build first (`uv run tools/build.py --run`) — as of end of session, the line-74 palette swap was just built (74559 bytes) but hadn't been verified visually yet. Verify font colors now look right in the scroll row before moving on.

## Key invariants to preserve

- `screen_base` (in `src/screen.s` BSS) = 256-byte aligned offset into `screen_buffer_raw`. Any code needing the Shifter base uses `move.l screen_base, aN`.
- `raster_ptr` must be at `raster_table` at start of every frame (VBL resets it).
- Scroll row owns bytes `screen_base + SCROLL_Y*SCREEN_LINE_BYTES` through `+(SCROLL_Y+34)*SCREEN_LINE_BYTES`. Only written by VBL's `ScrollCopyToScreen`.
- `scroll_buffer` (BSS, 6256 bytes) is the off-screen work area; only modified in main loop via `ScrollerStep`.
- `SCREEN_LINEWID=12`, so `SCREEN_LINE_BYTES=184` (not 160). Every blit/shift respects this stride.
- VBL handler writes `move.w #$2100, sr` BEFORE `ScrollCopyToScreen` so HBL fires during copy — this keeps the raster gradient aligned. Don't remove unless you also rework the raster_ptr compensation.
- Font index 0 is pure black (from red→black sentinel mapping in `png2font.py`). Don't render opaque pixels there — they pick up the HBL gradient at render time.
