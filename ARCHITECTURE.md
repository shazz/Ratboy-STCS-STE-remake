# Architecture — Stargoose Cracktro (Bladerunners) — Atari STE port

## Overview

A 68000-assembly recreation of RATBOY's 1988 Bladerunners / S.T.C.S. Stargoose cracktro,
running on Atari STE (no overscan). Renders a static top image (logo + stars) over a
live raster-gradient backdrop, with a 9-sequence multi-effect scroller (3-row palette-
variation, double-height sine, reflections, dual-stacked) and YM2149 music from an
embedded SNDH. Built with VASM (Motorola syntax) and run under Hatari.

Ported from Shazz's 2011 HTML5/CODEF port (`js_version/main.html`), whose scroll-text is
verbatim from the 1988 original.

## Tech Stack

- **CPU/target:** Motorola 68000 @ 8 MHz, Atari STE, 50 Hz PAL, low resolution (320×200×16)
- **HW used:** Shifter (palette, screen base), MFP 68901 (HBL, Timer B), YM2149 (via SNDH), STE Blitter, STE HSCROLL fine-scroll register
- **Assembler:** `vasmm68k_mot` (Motorola syntax, `.PRG` output)
- **Emulator:** Hatari 2.6.1
- **Tooling:** Python (uv) for PNG→planar converters and build orchestration

## Project Structure

```
MJJ/
├── src/
│   ├── main.s              ; entry, init sequence, main loop, cleanup
│   ├── constants.s         ; HW register equates, palette indices
│   ├── macros.s            ; WAIT_VBL, SUPERVISOR_*, SET_COLOR, INSTALL_VEC
│   ├── system.s            ; super mode, state save/restore, TOS hand-off
│   ├── screen.s            ; screen base alloc, palette init, buffer clear
│   ├── vbl.s               ; VBL handler: music tick, frame counter, dispatch
│   ├── hbl.s               ; HBL handler: per-line color 0 write (raster gradient)
│   ├── music.s             ; SNDH wrapper (init/play/exit)
│   ├── sequencer.s         ; 9-entry sequence table → mode dispatch by VBL counter
│   ├── scroller/
│   │   ├── engine.s        ; text feed, STE HSCROLL, word-crank
│   │   ├── mode_a_3rows.s  ; 3 parallel rows, palette-swap per row
│   │   ├── mode_b_sine.s   ; big double-height sine + vertical-flip reflection
│   │   ├── mode_c_dual.s   ; small + big stacked, with reflection
│   │   ├── mode_d_mixed.s  ; small at Y=160 + big sine, no reflection
│   │   └── mode_e_trio.s   ; triple layered
│   └── data/
│       ├── background.s    ; incbin logo+stars bitmap + base palette
│       ├── font.s          ; incbin ONE 40×34 bitmap + palette variants (row / mode)
│       ├── gradient.s      ; raster color-0 table (one $0rgb per scanline)
│       ├── scroltext.s     ; the 9 sequence text blocks + timing table
│       ├── music.s         ; incbin assets/thrust.snd
│       └── sintab.s        ; 256-entry sine table (signed words, amplitude pre-scaled)
├── tools/
│   ├── build.py            ; uv-runnable build orchestrator (assemble + launch Hatari)
│   ├── png2planar.py       ; PNG → ST 4-bitplane planar + 16-color palette
│   ├── png2font.py         ; font PNG (8×8 glyph grid) → per-glyph planar pack
│   └── gradient2raster.py  ; gradient.png → per-scanline $0rgb table
├── assets/                 ; source PNGs + thrust.snd (read-only inputs)
├── build/                  ; generated .bin + .PRG (gitignored)
├── bin/                    ; VASM + Hatari binaries
├── js_version/             ; reference CODEF/JS port
├── ARCHITECTURE.md · decisions.md · PLAN.md · README.md
└── pyproject.toml
```

## Layer Responsibilities

### Hardware layer — `constants.s`, `macros.s`

Pure equates and inlined register pokes. Zero state, zero logic.

```
SHIFTER_PALETTE  equ $FF8240      ; 16 × word (color 0..15)
SHIFTER_RES      equ $FF8260      ; 0=low 1=med 2=hi
STE_HSCROLL      equ $FF8265      ; STE only, 0..15 fine pixel offset
STE_LINEWID      equ $FF820F      ; STE only, extra words per line
MFP_GPIP         equ $FFFA01      ; HBL detection
VBL_VECTOR       equ $70
HBL_VECTOR       equ $68
```

### System layer — `system.s`, `vbl.s`, `hbl.s`

Owns supervisor mode, vector install/remove, register state save/restore.
Never mentions game content or modes.

### Data layer — `data/*.s`

Immutable blobs and tables via `incbin` or literal `dc.w`. No executable code.

### Engine layer — `scroller/engine.s`

Text-feed state machine + STE HSCROLL fine scroll + word-crank when offset wraps.
Independent of which mode is active. Exposes `ScrollerStep(a0=text_ptr)` returning
the new text_ptr; modes call this once per VBL.

### Mode layer — `scroller/mode_*.s`

Each file implements one visual composition. Exposes:
- `mode_X_init(params)` — reset state, set palette, prepare buffers
- `mode_X_render()` — called every VBL by the sequencer

Modes do not know which sequence activated them. All variability is parameterized.

**Render-time scaling primitives** (used by modes B/C/D/E for double-height rows):
- `DrawDoubled` — each source scanline written to TWO destination scanlines (solid 2× zoom)
- `DrawInterline` — each source scanline written to one destination scanline, next dest
  scanline left untouched (shows raster-gradient through gaps → chrome/CRT look — the
  JS port's `font40x68_ce` effect, done live here)

**Row palette variation** (mode A): HBL handler installs a different 16-color palette on
each row boundary (82/34 + 122/34 + 162/34 in JS coordinates), so the same font bitmap
renders in three different colors on the three rows. Base palette stays 16 colors total.

### Sequencer — `sequencer.s`

Owns a 9-entry table `{duration_vbl, mode_id, text_ptr, fx_params_ptr, y_offsets}`.
At each VBL: compares `vbl_counter` to current sequence's end; if past, advances
(wrapping S9 → S1). Then calls active mode's `render` routine.

### Entry — `main.s`

Boot: supervisor → save TOS state → init screen (low-res, palette, screen base)
→ install VBL/HBL → init music → enter main loop. Main loop polls keyboard for ESC
(via `Bconstat`/`Bconin` or raw IKBD), otherwise idles (everything happens in
VBL handler). Exit: stop music → remove handlers → restore state → `Pterm0`.

## Data Flow (one VBL tick at 50 Hz)

```
  Shifter ──VBL──> vbl.s
                    ├─ MusicSndhPlay        (always, if inited)
                    ├─ addq.w #1, vbl_counter
                    └─ SequencerTick
                         ├─ if counter > current_seq.end: advance_sequence
                         └─ jsr  current_mode.render
                                 ├─ ScrollerStep          (engine)
                                 ├─ advance HSCROLL       (1 write to $FF8265)
                                 ├─ word-crank + draw new char (when HSCROLL wraps)
                                 └─ mode-specific draws   (sine Y, reflection, ...)
```

HBL fires per scanline in the bottom half (lines ~70..199); `hbl.s` pulls the next
word from the gradient table and writes it to `$FF8240` (color 0). Top half's HBLs
may also write row-boundary palettes for 3-row mode color variation.

## Key Domain Concepts

- **Sequence** (9): a time-slice {duration, mode, text, params}; totals 9500 VBLs (≈190 s).
- **Mode** (5 types): a visual composition (A=3rows, B=big-sine, C=dual, D=mixed, E=trio).
- **Scroller engine**: STE-hscroll-based pixel-pusher, mode-agnostic.
- **Raster line**: a scanline whose color 0 is swapped by HBL (bottom half only).
- **SNDH**: self-contained music (player + data); 3 entries at base+0/+4/+8 for init/exit/play.

## State Machines

### Sequence FSM

```
  ┌────────────────────────────────────────────────────────────────────┐
  ▼                                                                    │
  S1 ──(667vbl)──▶ S2 ──(146)──▶ S3 ──(1083)──▶ S4 ──(1146)──▶         │
  S5 ──(1896)──▶ S6 ──(1645)──▶ S7 ──(459)──▶ S8 ──(1291)──▶ S9 ──(1167)┘

  Any state ──(ESC)──▶ Exit
```

Transitions are time-driven (via `vbl_counter`). ESC poll in main loop triggers exit.

### Scroller engine (per row)

```
  Idle ──(mode_init)──▶ Scrolling
  Scrolling on each VBL:
     hscroll += 2
     if hscroll >= 16:
        hscroll -= 16
        shift buffer left by 1 word
        advance text_ptr by 1 char (wrap on nul)
        render new char into right edge
```

## Memory Budget (rough)

| Block                      | Size    |
|----------------------------|---------|
| Code                       | ~20 KB  |
| Screen buffer (1×)         | 32 KB   |
| Background bitmap (top)    | ~12 KB  |
| Font 40×34 (single bitmap) | ~35 KB  |
| Palette variants (tables)  | ~200 B  |
| SNDH (thrust.snd)          | ~50 KB (TBD) |
| Gradient table             | ~260 B  |
| Sine table                 | 512 B   |
| Scroll buffers, misc       | ~5 KB   |
| **Total**                  | **~155 KB** |

Fits trivially on a 512 KB STE. Double-height (40×68) rendering is CPU/blitter work at
render time — no extra bitmap storage.
