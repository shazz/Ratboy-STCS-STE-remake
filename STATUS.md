# Stargoose Cracktro STE — Session Status

Last updated: 2026-04-29, session 5 continued

## Session 5b — SPACING + EFFECTS REFINED (2026-04-29)

**Major improvements this session:**

1. **0px letter spacing** via 5-phase glyph blending — characters now render tight (40px each) instead of 48px with 8px gaps

2. **Per-row palette pointers** — ISR uses indirect pointers (no conditionals in hot path), effects configure which palettes to use

3. **Type 2 rewritten as water reflection effect:**
   - Scroller with 10-line diagonal slope (down from right to left)
   - Mirrored reflection below with 1-line interleaving
   - Single palette for unified look
   - Matches original CONFO.S behavior

4. **Screen clearing** for moving effects (Type 1, 2) — ClearScrollerRegion clears lines 70-199

| Type | Effect | Status |
|------|--------|--------|
| 0 | 3 fixed rows | ✅ tested |
| 1 | 2× tall + sine | ✅ tested |
| 2 | Water reflection | ✅ tested (rewritten this session) |
| 3 | Diagonal same | pending test |
| 4 | 4× tall spread | pending test |
| 5 | Converging (bulge) | pending test |
| 6 | 2 fixed rows | pending test |
| 7 | Sine wave | pending test |

**To test an effect:** change `SCROLL_EFFECT_DEFAULT` in `src/constants.s` (currently set to 2).

---

## Architecture Updates

**Glyph blending (5-phase cycle per 2 characters):**
- Phase 0-1: direct copy of char A pwords 0-1
- Phase 2: blend A[32-39] + B[0-7] (high bytes)
- Phase 3-4: blend B's remaining pixels
- Result: 40px glyphs with 0px gaps

**Palette pointer system:**
- `font_pal_ptr1/2/3` — set by `SetPalettePointers(effect_type)`
- Single-row effects (1, 2, 4, 7): all point to c1
- Multi-row effects (0, 3, 5, 6): point to c1/c2/c3

**Clear region:** Extended to 70-199 (129 lines) to cover all effect positions

---

## Session 4 — GLITCH FIXED (2026-04-29)

Row-1 Y=107-111 glitch root cause: bus collision between Timer-B palette write and Shifter DMA fetch. Fix: skip palette write for scanlines 107-111.

---

## Current Architecture

**Strategy E (pure CPU)** + **double-buffer**:
- Off-screen `scroll_buffer` (21 pwords × 34 lines)
- Per-VBL: render new pword → CPU shift buffer left → CPU plot to screen rows
- Plot via effect dispatcher — each effect implements its own row layout
- Timer-B raster gradient runs independently, scanline-locked

## File map

```
src/
  main.s              entry; Main, MainLoop, CheckEsc
  constants.s         SCROLL_EFFECT_DEFAULT selects active effect (0-7)
  scroller/engine.s   5-phase blending + effect dispatcher + 8 plot routines
                      ClearScrollerRegion for moving effects
  hbl.s               Timer-B handler + SetPalettePointers + palette pointers
  screen.s            Double-buffer setup
  vbl.s               VBL handler calls ScrollerStepVblank
  data/
    scrolltext.s      Text sequences
    font.s            font.bin + c1/c2/c3 palettes
    gradient.s        raster_table
```

## How to resume next session

1. Read this file + `docs/LEARNINGS.md`
2. Test effects by changing `SCROLL_EFFECT_DEFAULT` in `src/constants.s`
3. Build: `/home/matt/projects/MJJ/bin/vasm/vasmm68k_mot -Ftos -quiet -spaces -I src -I . -o build/AUTO/STRGOOSE.PRG src/main.s`
4. Run: `hatari --machine ste --tos bin/hatari/TOS/tos162fr.img --harddrive build --fast-boot on`

## Remaining work

- **Test remaining effects** (3, 4, 5, 6, 7)
- **Effect sequencer** — switch effects via bytes in scroll text (P7)
- **Restore original scrolltext**
- **Re-enable music** (MUSIC_ENABLED=1)

## Phase progress

| Phase | Status |
|-------|--------|
| P0-P5 | ✅ done |
| P6 — Mode A (3 parallel rows) | ✅ done |
| P6b — All 8 scroll effects | 🔄 in progress (0,1,2 tested) |
| P7 — Effect sequencer | ⬜ pending |
