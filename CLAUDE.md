# Stargoose Cracktro — Atari STE 68000

A 68000-assembly port of RATBOY's 1988 Bladerunners / S.T.C.S. Stargoose
cracktro. Target: Atari STE, 50 Hz PAL, low-res 320×200×16.

## Quick Reference

- **Assemble:** `./build.sh` (vasm → `build/AUTO/STRGOOSE.PRG`). Does NOT
  regenerate `build/*.bin`/`.img`/`.pal` from `assets/`.
- **Regenerate assets:** `uv run tools/build.py --assets` (PNG/SNDH → `build/`).
  Run this after changing a source asset or a converter.
- **Run:** `./run.sh` (assembles + launches Hatari STE, AUTO-runs the PRG).
- **Debug headless:** see `DEBUG.md` — Hatari `--cmd-fifo` + breakpoints +
  memory dumps from the terminal. Use `DISPLAY=:0`; `--fast-forward on` so PRG
  symbols load, real-time (no fast-forward) for screenshots that render.
- **Architecture:** `ARCHITECTURE.md` (structure + patterns); `decisions.md` (ADRs).

## Critical gotchas (read before touching the raster / music)

- **Timer-B owns the per-scanline raster gradient** (event-count mode, the only
  ST timer wired to display-enable). Don't repurpose it.
- **Channel music must not contend for Timer-B AND must be vblank-fast.** SNDH
  players can grab Timer-B (→ crash) or be too slow (→ gradient starved). The
  SNDH header timer tag is NOT reliable — vet at runtime (`$120`/`TBCR`). Loader
  tunes work; the maxYMiser "505" rips don't.
- **Blitter operations during the visible region must be COOPERATIVE, not HOG** —
  HOG halts the CPU and defers Timer-B → gradient freezes.
- **MULU is expensive (70 cy).** Prefer LUTs (`y_offset_lut`, `glyph_offset_lut`).
- The channel switch writes the gradient to colour 0 (A, backdrop) or colour 1
  (B, the font) via a self-modified ISR write target. See `LEARNINGS.md`.

## Important files

- `WRITE_UP.md` — reverse-engineering of the original 1988 STF cracktro.
- `OPTIM.md`, `PERF_REVIEW.md` — performance studies + the plan to reach 1 VBL
  (like the original STF). `STATUS.md` — session-by-session status (read first).
- `DEBUG.md` — how to drive the Hatari debugger to solve issues FASTER.

In `docs/`:
- `LEARNINGS.md` — accumulated learnings while coding this cracktro (read it!).
- `blitter_faq.txt` — STE Blitter FAQ.
- `blitter_execution_times.md` — STE Blitter execution times.
- `68000_execution_cycles.md` — 68000 CPU execution times.

## Tools

- tools/cycles/README.md: a python tool to count used cycles