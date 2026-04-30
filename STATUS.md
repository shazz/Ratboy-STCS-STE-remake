# Stargoose Cracktro STE — Session Status

Last updated: 2026-04-29, session 5 complete

## Session 5 — SCROLL EFFECTS COMPLETE (2026-04-29)

**All 8 scroll effect types implemented**, matching the original CONFO.S.

| Type | Effect | Description |
|------|--------|-------------|
| 0 | 3 fixed rows | Original default — 3 horizontal rows at Y=78, 119, 160 |
| 1 | 2× tall + sine | Single row, vertically doubled (68 lines), staircase sine bob |
| 2 | Anti-symmetric | 2 rows with opposite Y offsets — mirror wave effect |
| 3 | Diagonal same | 2 rows both tilting same direction (parallel diagonal) |
| 4 | 4× tall spread | Single giant row, 4× vertical stretch (100 lines output) |
| 5 | Converging (bulge) | 2 rows diverging toward center, converging at edges |
| 6 | 2 fixed rows | Simplest — just 2 straight horizontal rows |
| 7 | Sine wave | Single row with staircase Y-offset pattern + slow bob |

**To test an effect:** change `SCROLL_EFFECT_DEFAULT` in `src/constants.s` (currently set to 6).

**Architecture:** Modular dispatcher in `src/scroller/engine.s`:
```asm
ScrollPlotDispatch:
    move.w      scroll_effect_type, d0
    beq         ScrollPlotType0
    cmp.w       #1, d0
    beq         ScrollPlotType1
    ; ... etc
```

Each effect is a self-contained plot routine. Easy to test/compare effects by changing the default.

**Pending:** User will provide screenshots from original STARGOOS.PRG to verify Type 5 matches the original "merge on left" behavior.

---

## Session 4 — GLITCH FIXED (2026-04-29)

Row-1 Y=107-111 glitch root cause: bus collision between Timer-B palette write and Shifter DMA fetch at those specific scanlines. Fix: skip palette write for scanlines 107-111 in TimerBHandler (creates imperceptible 5-line gradient freeze).

---

## Current Architecture

**Strategy E (pure CPU)** + **double-buffer**:
- Off-screen `scroll_buffer` (21 pwords × 34 lines)
- Per-VBL: render new pword → CPU shift buffer left → CPU plot to screen rows
- Plot via effect dispatcher — each effect implements its own row layout
- Timer-B raster gradient runs independently, scanline-locked

**All working:** gradient ✓, font palette ✓, double-buffer ✓, row-1 glitch FIXED ✓, all 8 scroll effects ✓

## File map (current)

```
src/
  main.s              entry; Main, MainLoop, CheckEsc
  constants.s         SCROLL_EFFECT_DEFAULT selects active effect (0-7)
  scroller/engine.s   Effect dispatcher + 8 plot routines:
                      ScrollPlotType{0,1,2,3,4,5,6,7}
  hbl.s               Timer-B handler with Y=107-111 skip fix
  screen.s            Double-buffer setup
  vbl.s               VBL handler calls ScrollerStepVblank
  data/
    scrolltext.s      Text sequences (currently diagnostic "ABCDEFGH...")
    font.s            font.bin + palettes
    gradient.s        raster_table
docs/
  LEARNINGS.md        Accumulated platform knowledge
  STATUS.md           This file
  STCS.RAT/CONFO.S    Original 1988 source (reference for effects)
```

## How to resume next session

1. Read this file + `docs/LEARNINGS.md`
2. Test effects by changing `SCROLL_EFFECT_DEFAULT` in `src/constants.s`
3. Build: `/home/matt/projects/MJJ/bin/vasm/vasmm68k_mot -Ftos -quiet -spaces -I src -I . -o build/AUTO/STRGOOSE.PRG src/main.s`
4. Run: `hatari --machine ste --tos bin/hatari/TOS/tos162fr.img --harddrive build --fast-boot on`

## Remaining work

- **Compare Type 5** with original STARGOOS.PRG screenshots — may need adjustment
- **Restore original scrolltext** (currently diagnostic "ABCDEFGH...")
- **Restore font palette swap** (PALETTE_SWAP_ENTRY=77, currently may be diagnostic value)
- **Re-enable music** (MUSIC_ENABLED=1)
- **Effect sequencer** — switch effects via bytes in scroll text (P7)

## Phase progress

| Phase | Status |
|-------|--------|
| P0-P5 | ✅ done |
| P6 — Mode A (3 parallel rows) | ✅ done |
| P6b — All 8 scroll effects | ✅ done (session 5) |
| P7 — Effect sequencer | ⬜ pending |
