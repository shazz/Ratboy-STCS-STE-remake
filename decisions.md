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

## 2026-06-07 — Channel switch via indirect "channel descriptor" + byte-9 trigger

**Status:** accepted
**Context:** A new (non-1988) effect: a "TV channel flip" that swaps the entire
asset set (logo, font, palettes, music) behind a few seconds of analog static.
The engine hardcoded its asset labels everywhere, so swapping them needed an
indirection layer. Three sub-decisions:
**Decision:**
1. **Indirect channel descriptor.** Asset bases become `chan_*` BSS pointers
   loaded by `ApplyChannel` from a `channel_table` row, replacing hardcoded
   labels in screen/vbl/hbl/engine/music. Mirrors the existing palette-pointer
   pattern. Channel B starts as a scaffold duplicate of A; real assets swap in
   one at a time.
2. **Byte-9 in-text trigger, toggle topology.** Reuses the existing in-text
   marker scheme (bytes 1–8 = effects). Byte 9 sets a flag; the blocking switch
   runs in `MainLoop`, not an ISR. One state bit toggles A↔B.
3. **Static = panned random field, not per-frame random write.** A real
   full-screen fresh-random write can't fit 50 Hz/8 MHz (≥110k cy for the store
   alone, before any PRNG). Instead fill a screen+slack `noise_field` once with a
   Galois LFSR, then per frame point the STE byte-aligned screen base at a random
   offset → uncorrelated random slice every frame → true 50 Hz snow for ~free.
**Alternatives considered:**
- Per-frame full-screen PRNG fill (the "obvious" approach) — physically can't
  hit 50 Hz on the 68000; would update at ~18 Hz and still cost the whole frame.
- A second `channel_table` of scrolltext per channel (deferred — shared text is
  fine for now; the byte-9 marker simply ping-pongs A↔B each scroll cycle).
- Keypress / counter trigger (rejected — in-text marker fits the existing
  sequencer and keeps the "sequence IS the data" philosophy).
**Consequences:**
- Switch logic is isolated in `switch.s` (orchestration) + `noise.s` (snow);
  consumers each changed one label → one pointer read.
- The static phase is ~3 s unresponsive to ESC (blocking) — acceptable.
- On unmask, Timer-B may emit ≤1 frame of stale gradient before the next VBL
  re-arms `raster_ptr` — invisible in practice.
- Holding two full asset sets in RAM is cheap (logo 11840 B, thrust.snd 4830 B)
  vs the ~110 KB working set on a 1 MB STE.

## 2026-06-07 — Channel-B gradient font on colour 1; music must not contend for Timer-B

**Status:** accepted
**Context:** Channel B should show the screen-spanning raster gradient *inside*
the scroll letters (not as the backdrop), on a solid black border/backcolor. The
gradient is written per-scanline by the Timer-B ISR to a single colour register.
**Decision:**
1. **Gradient → a different colour register per channel, via self-modifying code.**
   Channel A keeps the gradient on colour 0 (backdrop + border). Channel B writes
   it to colour 1 (the font's index), leaving colour 0 black. The ISR's common-path
   write (`GradWrite`) has its abs.l destination operand patched between `$FF8240`
   (col 0) and `$FF8242` (col 1) at switch time (`SetGradTargetColor0/1`). Zero
   per-fire cost; safe because the ST 68000 has no instruction cache.
2. **Channel-B font is single-index, non-inverted** (glyph = index 1, bg = index 0).
   A second raster table `raster_table_b` (built once at boot from the gradient,
   logo region Y<74 marked SKIP to protect the 16-colour logo's colour 1) feeds
   the colour-1 writes; channel B uses no per-row palette swaps.
3. **Channel B needs a Timer-B-free, vblank-fast SNDH tune.** The gradient owns
   Timer-B (only ST timer wired to display-enable). A tune that (a) installs its
   own Timer-B replay, or (b) has a slow replay overrunning the visible area
   (masking interrupts), will break the gradient. Chose **Jess / For Your Loader 1**
   (a lightweight loader tune). The VBL also re-arms `raster_ptr` *before* the
   music tick so a slightly-slow replay can't delay it past the scroll rows.
**Alternatives considered:**
- *Inverted font with the gradient on colour 0* (letters = index 0): rejected —
  colour 0 is the shared border/backcolor, so the gradient leaked outside the
  letters (visible in the border).
- *Per-frame "reclaim Timer-B" hack* to fight a Timer-B-grabbing tune (505):
  rendered the gradient but the two replayers' vector save/restore raced →
  **crashed** after enough switches. Rejected in favour of choosing a clean tune.
- *Baked per-glyph gradient palette* (immune to music timing): kept as a fallback,
  but loses the screen-spanning look.
**Consequences:**
- Channel B = MJJ logo + HOOKER gradient font (blue→magenta on black) + Jess
  loader music, stable.
- **The `SNDH` timer tag is not trustworthy** — vet a tune at runtime (Hatari
  debugger, `$120`/`TBCR` after its play tick). Documented in `ARCHITECTURE.md`.
- New `tools/png2font_remap.py` remaps non-ASCII / single-plane font PNGs (custom
  glyph order, `--invert` option) into the engine's ASCII-indexed planar layout.
