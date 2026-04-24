# Architecture Decision Records

## 2026-04-22 — Target Atari STE, not original ST

**Status:** accepted
**Context:** The original 1988 Bladerunners cracktro was coded for the ST (no blitter, no
hardware scroll). Recreating on vanilla ST would force pre-shifted font tables,
software scroll by word-swap, and manual blitting of every glyph — a significant
complexity tax.
**Decision:** Target STE. Use the Blitter for bulk copies and `HSCROLL` ($FF8265) for
1-pixel fine horizontal scrolling.
**Alternatives considered:**
- Original ST with pre-shifted fonts (most authentic, weeks of extra work).
- Falcon with DSP (overkill, wrong era).
**Consequences:**
- Code is dramatically simpler.
- Runs on STE / Mega STE / Falcon; does NOT run on original ST.
- The visual result is indistinguishable from the ST original; only the code is different.

## 2026-04-22 — No overscan (border removal deferred indefinitely)

**Status:** accepted
**Context:** Cycle-exact border-removal via 50/60 Hz toggling is a classic ST trick but
consumes significant engineering time to debug and is sensitive to CPU variant.
**Decision:** Stay inside the standard 320×200 display area. Live with black borders.
**Alternatives considered:** Implement top + bottom border removal as a Phase 10 polish.
**Consequences:** The original cracktro likely didn't use overscan either (it was drawn
within standard borders), so no visual loss.

## 2026-04-22 — Static top half from bitmap; raster gradient for bottom half

**Status:** accepted
**Context:** The JS port's `background.png` composes logo + stars + full gradient as one
bitmap. On real ST, rendering the gradient as a bitmap wastes colors (needs many of the
16 palette slots for the gradient bands). The authentic approach uses palette-register
writes per scanline for the gradient.
**Decision:** Split the backdrop:
- **Top ~70 scanlines**: bake as 16-color planar bitmap from a cropped PNG (logo + stars).
- **Bottom ~130 scanlines**: color 0 filled; HBL handler writes `$FF8240` per scanline
  from a pre-computed table extracted from `gradient.png`.
**Alternatives considered:**
- Full-bitmap backdrop (simpler, burns palette slots).
- Procedural stars + authentic raster (cleanest, but stars require extra code).
**Consequences:** Only 1 palette slot (color 0) is consumed by the gradient; 15 slots
remain for text, logo, stars. Stars are baked into the bitmap, fixed positions.

## 2026-04-22 — STE HSCROLL fine scroll at 2 px/VBL

**Status:** accepted
**Context:** Scroll speed affects both authenticity and CPU budget. JS port uses 6 px/JS-
frame (60 Hz) ≈ 360 px/s. Original 1988 ST cracktro ran at 50 Hz VBL with whatever speed
the CPU allowed after the other effects — likely 2-3 px/VBL.
**Decision:** 2 px/VBL using STE `HSCROLL` register. Every VBL, add 2 to hscroll; when it
wraps past 15, shift the pre-rendered scroll buffer left by one word and blit the next
character into the right edge.
**Alternatives considered:**
- 6 px/VBL to match JS visual speed (feels too fast for the era).
- 1 px/VBL (too slow, reads like a lecture).
- 8 px/VBL word-aligned without HSCROLL (no STE features used, chunky look).
**Consequences:** Smooth as butter. HSCROLL update is one byte write. Word-crank happens
once every 8 VBLs, so the blitter/CPU has 8 frames to render the next glyph.

## 2026-04-22 — Single-PRG build via INCLUDE, not linker

**Status:** accepted
**Context:** VASM supports both `INCLUDE` directives (single assembler invocation) and
separate-compile + `vlink` for multi-module builds. This project has <15 source files and
compiles in <1 second regardless.
**Decision:** `main.s` is the only file fed to VASM; it `INCLUDE`s everything else.
**Alternatives considered:** `vlink`-based build.
**Consequences:** Build is one command. Label visibility is global (watch for collisions —
we use `mode_X_` / `scroller_` / `music_` prefixes). Incremental compile is not possible,
but compile time is too fast to matter.

## 2026-04-22 — Python (uv) for asset converters and build orchestration

**Status:** accepted
**Context:** We need to convert PNGs → ST planar format, extract a per-scanline color
table from the gradient PNG, and chain assembler + emulator launch. The existing tooling
on the machine includes `uv`.
**Decision:** A `tools/build.py` script orchestrates: asset conversion (if stale) →
VASM → optionally Hatari launch. Invoked via `uv run tools/build.py [--run|--clean]`.
Converters (`png2planar.py`, `png2font.py`, `gradient2raster.py`) are Python+Pillow.
**Alternatives considered:**
- Plain Makefile (requires MSYS2/mingw-make; portability overhead).
- PowerShell (ties us to Windows).
- Batch files (painful to maintain).
**Consequences:** Cross-platform if ever needed. Easy to extend. Pillow is the only
external Python dep.

## 2026-04-22 — Single font bitmap + code-generated effects (no baked variants)

**Status:** accepted
**Context:** The JS port carries five font PNGs: three 40×34 color variants (c1/c2/c3) and
two 40×68 double-height variants (c1 "solid", ce "chrome-scanlined"). That's cheating in
the demoscene sense — baking what should be runtime effects into the assets.
**Decision:** Extract exactly **one** 40×34 font bitmap (from `font40x34_c1.png`). All
derivative effects are generated at render time:
- **3-row color variation (mode A):** HBL swaps the palette at each row boundary; the
  same bitmap draws in three color schemes. Palette tables extracted from c1/c2/c3 PNGs
  but shipped as 16-word arrays, not bitmap copies.
- **Double-height "solid" (mode B, some sequences):** `DrawDoubled` primitive — each
  source font scanline written to TWO destination scanlines.
- **Double-height "chrome" (mode B, other sequences):** `DrawInterline` primitive — each
  source scanline written to one dest scanline, next dest scanline left showing the raster
  gradient through → the scanline/CRT look without baking it into the bitmap.
**Alternatives considered:**
- Keep the JS approach (5 font assets, ~364 KB): faster to render, massive memory cost,
  creatively dishonest.
- Single bitmap with runtime color recolor (palette only): accepted.
**Consequences:**
- Font budget drops from ~364 KB to ~35 KB.
- More authentic — this is how the 1988 original would have rendered multi-color rows
  (palette trick), though not necessarily how it did double-height.
- Slightly more CPU per frame for double-height — negligible on STE with blitter.

## 2026-04-22 — SNDH replay via VBL, not dedicated Timer

**Status:** accepted
**Context:** SNDH files can be replayed from VBL (50 Hz) or a dedicated MFP timer
(Timer A/C at configurable rate). Many SNDHs are authored for 50 Hz VBL replay; using
VBL is simpler and does not steal a timer.
**Decision:** Call `MusicSndhPlay` (= `jsr base+8`) from the VBL handler. Init on boot
with song number 1 in `d0`.
**Alternatives considered:** Timer C at 200 Hz for higher-resolution effects (deferred
unless `thrust.snd` demands it at test time).
**Consequences:** If `thrust.snd` needs Timer-driven replay, we'll hear it on first test
and switch. The MusicSndhPlay wrapper is trivial to re-hook.
