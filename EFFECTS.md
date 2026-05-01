# Scroll Effects — Configuration Guide

This file documents the configuration knobs for each scroll effect. To switch
between effects at build time, change `SCROLL_EFFECT_DEFAULT` in
`src/constants.s` to the number of the effect you want.

```asm
SCROLL_EFFECT_DEFAULT equ   1     ; 0..7
```

Then rebuild and run:

```sh
./run.sh
```

---

## Common architecture

Smooth **8 px/VBL** scroll via RATBOY's 1988 alternating-buffer trick — two
scroll buffers `scroll_buffer_a` and `scroll_buffer_b` hold the same scroll
content offset by 1 byte (= 8 px) horizontally. Display alternates each
frame.

Per-VBL pipeline in `ScrollerStepVblank` (`src/scroller/engine.s`):

1. `ScrollPlotDispatch` — hands off to the active effect's plot routine.
   Plot routines read source from `scroll_plot_addr` (pointer to whichever
   of `scroll_buffer_a` / `scroll_buffer_b` is active this frame) and write
   to the back screen buffer.
2. Toggle `scroll_active_buf` and update `scroll_plot_addr` to the other
   buffer (= the one to display next frame).
3. `ScrollRenderNextPword` — runs every other VBL (gated by
   `scroll_byte_pending`). Writes a fresh 16-px pword into `scroll_next_pword`
   (a 1-pword × 34-line staging area) using the 5-phase blending cycle.
4. `ScrollShiftAndFill` — pword-shifts the new active buffer left by 1 pword
   and fills its rightmost pword by byte-shifting between the just-displayed
   buffer's rightmost pword and the relevant half (high or low bytes per
   plane) of `scroll_next_pword`. ~40 sl/frame.
5. Toggle `scroll_byte_pending`.

`SwapBuffers` is then called from `MainLoop` to publish the frame.

See `docs/LEARNINGS.md` "Smooth 8 px / VBL scrolling" for the full
explanation of how this trick works.

**Per-effect palette swap lines:** the c1 and c2 raster swap addresses are
runtime variables (`raster_swap_c1_addr`, `raster_swap_c2_addr`) so each
effect can relocate them to align with its content boundaries. The c3
swap stays fixed at line 159 (the bottom-row boundary, used by every
multi-row effect identically). See `SetPalettePointers` in `src/hbl.s`
for the per-effect overrides.

---

## Tuning palette swap lines per effect

Each multi-row effect splits the visible scroll area into bands that get
different font palettes (`font_palette_c1`, `c2`, `c3`). The palette
boundary is a horizontal line — the **swap line** — at which the
Timer-B handler rewrites colours 1..15 of the Shifter palette. Because
the swap fires at the END of a scanline, **a swap on raster line N
takes effect from scanline N+1 onwards.** So pick the swap line as
`(target Y) − 1` where `target Y` is the first scanline you want in the
new palette.

### How the swap is dispatched

`TimerBHandler` (`src/hbl.s`) compares `raster_ptr` against three
addresses each HBL:

```asm
cmpa.l   raster_swap_c1_addr, a0   ; runtime-configurable (BSS)
beq.s    .swap_c1
cmpa.l   raster_swap_c2_addr, a0   ; runtime-configurable (BSS)
beq.s    .swap_c2
cmpa.l   #RASTER_SWAP_C3, a0       ; compile-time constant (line 159)
beq.s    .swap_c3
```

The c1 and c2 addresses are **per-effect**: `SetPalettePointers` writes
their value at scroller init time based on the effect type. The c3 swap
is shared by all effects.

### Defining a new swap line

Constants live in `src/hbl.s`:

```asm
RASTER_SWAP_C1_DEFAULT  equ raster_table+77*2       ; c1 from Y=78  (default)
RASTER_SWAP_C1_TYPE7    equ raster_table+73*2       ; c1 from Y=74  (triangle 1 effect)
RASTER_SWAP_C2_DEFAULT  equ raster_table+118*2      ; c2 from Y=119 (multi-row default)
RASTER_SWAP_C2_TYPE4    equ raster_table+131*2      ; c2 from Y=132 (mirror line for type 4)
RASTER_SWAP_C2_TYPE7    equ raster_table+121*2      ; c2 from Y=122 (between triangles for type 7)
RASTER_SWAP_C3          equ raster_table+159*2      ; c3 from Y=160 (bottom row, fixed)
```

The pattern: `RASTER_SWAP_C{1,2}_<EFFECT> equ raster_table + <line> * 2`,
where `<line>` is the scanline number of the swap (zero-based). The `*2`
is because each `raster_table` entry is a word (2 bytes).

### Selecting the swap line for a new effect

In `SetPalettePointers`, add a case for your effect:

```asm
.my_new_effect:
    lea     font_palette_c2, a0
    move.l  a0, font_pal_ptr2
    lea     font_palette_c3, a0
    move.l  a0, font_pal_ptr3
    move.l  #RASTER_SWAP_C1_MYEFFECT, raster_swap_c1_addr   ; if c1 needs to move
    move.l  #RASTER_SWAP_C2_MYEFFECT, raster_swap_c2_addr   ; if c2 needs to move
    rts
```

If your effect only needs one swap moved, omit the other line — the
defaults are pre-loaded at the top of `SetPalettePointers`. If the
effect is single-row (everything in c1), use `.single_row` instead and
skip the swap overrides.

### Rules of thumb

1. **Keep c1 ≥ line ~70** to stay below the logo region.
2. **Keep c3 ≤ line ~195** to stay above the screen bottom (line 199
   exists but the gradient table padding makes it risky).
3. **`c1 < c2 < c3`** — they must fire in order across the frame.
4. The scroll buffer's content above the c1 swap shows in the LOGO
   palette (since c1 hasn't fired yet). Don't put scroll content there
   unless you really mean it.
5. If you move a swap line, double-check whether each effect's plot
   routine still has its content fully inside the intended band — see
   the geometry notes in each effect's section.

---

## Sequencing effects via the scroll text

The scroller engine looks for effect-change markers embedded directly in
the scroll text. This means the entire timeline (which effect plays for
how long) is just the layout of the bytes in `src/data/scrolltext.s` —
no separate timeline data structure, no frame counter, no "scene"
manager.

### Marker bytes

| Byte    | Meaning                           |
| ------- | --------------------------------- |
| `0`     | NULL — wrap cursor back to start  |
| `1..8`  | Effect-change marker (= effect N-1) |
| `9..31` | Reserved (treated as glyph index 0 = space) |
| `32..95`| Printable ASCII glyph              |
| `96+`   | Out of range, clamped to space     |

Effect N-1 means: byte `1` → effect 0, byte `2` → effect 1, ..., byte
`8` → effect 7. The original RATBOY 1988 code used bytes 1..7 directly
as effects 1..7 (no effect 0); we extended the range to byte 8 so all
8 of our effects are addressable.

### How it parses

`ScrollRenderNextPword .fetch_next_char` (`src/scroller/engine.s`) reads
one byte from the cursor each fetch. If the byte is in `1..8`, the
parser:

1. Sets `scroll_effect_type = byte − 1`.
2. Calls `SetPalettePointers` so the new effect's palette pointers and
   c1/c2 raster-swap addresses take effect immediately.
3. Loops back to read the next byte (which is the actual glyph or
   another marker).

Markers are never rendered as glyphs — they're consumed and skipped.
You can chain markers (e.g. `byte 1, byte 5`) to cycle without any text
between, though that's rarely useful.

### Authoring a sequence

In `src/data/scrolltext.s`, write segments back-to-back, each prefixed
with its effect-change byte:

```asm
scrolltext_S1:
    ; --- segment 1: effect 0 ---
    dc.b    1
    dc.b    "              FIRST SEGMENT TEXT HERE...                  "

    ; --- segment 2: effect 3 ---
    dc.b    4
    dc.b    "           SECOND SEGMENT (RUNS UNDER EFFECT 3)...        "

    ; --- segment 3: effect 7 ---
    dc.b    8
    dc.b    "        THIRD SEGMENT (RUNS UNDER EFFECT 7)...            "

    dc.b    0                       ; NULL → wrap back to scrolltext_S1
    even
```

A few practical rules:

* **Start with a marker.** The cursor wraps to position 0 of
  `scrolltext_S1` after each NULL, so the first byte should be a marker
  to put the engine in a known effect on the loop's first VBL. If you
  don't, the loop will keep whatever effect was active when the NULL
  was reached.
* **Match `SCROLL_EFFECT_DEFAULT`** to the first marker. The engine
  initialises `scroll_effect_type` to `SCROLL_EFFECT_DEFAULT` *before*
  the first character is fetched, so for one VBL the effect can differ
  from what the marker about to be read says. Setting them equal keeps
  init clean.
* **Trailing padding.** When a marker fires, the *next* effect plot
  starts immediately, but the scroll buffer still has 21 pwords of
  previous-segment content scrolling out under the new effect. Long
  trailing spaces (the original 1988 padding pattern is `"...  "` with
  20–40 trailing spaces) let one segment fully exit before the next
  segment's text enters.
* **Order is yours.** No constraint that effects appear in numeric
  order. The original CONFO.S used `6, 1, 2, 7, 3, 4, 5` (no effect
  0). Our default ordering is `0, 1, 2, …, 7` purely for clarity.
* **Apostrophes and punctuation** must be in the font's printable
  range (ASCII 32..95). Lowercase letters are *not* in our font and
  will render as garbage glyphs.

### Visual lag

A marker fires when the cursor passes it, but the scroll content
already in the buffer (= last ~21 pwords ≈ 7 characters of preceding
text) keeps scrolling for a few VBLs after the effect changes. The
result: the new effect "captures" the tail of the previous segment as
it exits the screen. This is the original 1988 behaviour and tends to
look like a smooth visual transition rather than a jarring cut.

---

## Effect 0 — Three fixed rows

The classic 3-row look: same scroll text drawn at three vertical positions,
each row with its own palette via Timer-B per-scanline palette swap.

### Configuration

| Knob                    | Where                       | Current value | What it does                       |
| ----------------------- | --------------------------- | ------------- | ---------------------------------- |
| Row 1 Y position        | `src/constants.s` `SCROLL_Y_1` | 78         | top row, scanline                  |
| Row 2 Y position        | `src/constants.s` `SCROLL_Y_2` | 119        | middle row, scanline               |
| Row 3 Y position        | `src/constants.s` `SCROLL_Y_3` | 160        | bottom row, scanline               |
| Glyph height            | `src/constants.s` `SCROLL_HEIGHT` | 34      | font height in scanlines           |
| Per-row palettes        | `src/hbl.s` `SetPalettePointers` | c1/c2/c3 | indirect ptrs for Timer-B swap   |

### Routine

`ScrollPlotType0` — copies `scroll_buffer[0..19]` to all three screen rows
using 3-way `movem.l` fan-out. ~108 sl wallclock.

---

## Effect 1 — Single row, 2× tall, sine bob + sine deformation

A vertically-doubled (40 px tall) row that bobs up and down on a slow sine
trajectory while each pword column gets its own per-strip Y offset, giving
the text a wavy "carried by water" feel. Horizontal scroll runs at 2× speed.

### Configuration

| Knob                          | Where                                    | Current value | What it does                              |
| ----------------------------- | ---------------------------------------- | ------------- | ----------------------------------------- |
| Base Y position               | `src/scroller/engine.s` `TYPE1_ROW_Y`    | 100           | center of the 68-line row                 |
| Trajectory amplitude          | `type1_traj_lut` peak value              | 20            | max ± lines from base Y                   |
| Trajectory period             | `type1_traj_lut` length × 2              | 100 frames    | full sine cycle (= 2 s @ 50 Hz)           |
| Top-to-bottom time            | `type1_traj_lut` length                  | 50 frames     | half cycle (= **1 s @ 50 Hz**)            |
| Inside-sine cycle count       | `type1_inside_lut`                       | 2 cycles      | per-strip deformation freq (over 20)      |
| Inside-sine amplitude         | `type1_inside_lut` peak value            | 3             | max ± lines per strip                     |
| Horizontal scroll speed       | `SetScrollSpeedExtra`                    | 2× (extra=1)  | two render+shift per VBL                  |

### Trajectory LUT (`type1_traj_lut`)

50 entries of `|sin(π·i/50)| × 20`, rounded. The sign is applied via
`sine_direction` which flips after each 50-frame half-cycle:

```asm
type1_traj_lut:
    dc.w  0,  1,  3,  4,  5,  6,  7,  9, 10, 11
    dc.w 12, 13, 14, 15, 15, 16, 17, 18, 18, 19
    dc.w 19, 19, 20, 20, 20, 20, 20, 20, 20, 19
    dc.w 19, 19, 18, 18, 17, 16, 15, 15, 14, 13
    dc.w 12, 11, 10,  9,  7,  6,  5,  4,  3,  1
```

To **change top-to-bottom time**, change the table length and the matching
`cmp.w #N` in the wrap check to the same N.

To **change trajectory amplitude**, regenerate the LUT with a new peak
(replace `× 20` with the new amplitude in the formula).

The phase is driven from `vbl_counter` (the real 50 Hz tick from inside the
VBL ISR), so the bob rate is independent of how many VBLs MainLoop work
spans:

```asm
move.w  vbl_counter, d0
move.w  type1_prev_vbl, d1
move.w  d0, type1_prev_vbl
sub.w   d1, d0                  ; d0 = VBLs since last call
add.w   d0, sine_frame_count
```

### Inside-sine LUT (`type1_inside_lut`)

20 entries of `sin(2π·N·i/20) × 3`, rounded — N is the cycle count.

```asm
type1_inside_lut:
    dc.w 0, 2, 3, 3, 2, 0, -2, -3, -3, -2
    dc.w 0, 2, 3, 3, 2, 0, -2, -3, -3, -2
```

To **change inside cycle count**, regenerate the table with a new N. Examples:

* 1 cycle (slowest, full sine across the row):
  `0, 1, 2, 2, 3, 3, 3, 2, 2, 1, 0, -1, -2, -2, -3, -3, -3, -2, -2, -1`
* 2 cycles (current — gentle wave): `0, 2, 3, 3, 2, 0, -2, -3, -3, -2 ×2`
* 4 cycles (faster wave, period 5): `0, 3, 2, -2, -3 ×4`

To **change inside amplitude**, scale every value in the table.

### Routine

`ScrollPlotType1` — clears the scroller region (lines 70–199) each frame to
avoid trails, then plots 20 strips with vertical doubling. Each strip's Y
offset is `TYPE1_ROW_Y + sine_offset + type1_inside_lut[strip]`.

---

## Effect 2 — Water reflection

A scroller tilted on a gentle diagonal (down from right to left), with a
mirrored, 1-line interleaved reflection drawn underneath — the visual
illusion is text floating above its own ripple. Horizontal scroll runs at
2× speed.

### Configuration

| Knob                    | Where                                       | Current value | What it does                              |
| ----------------------- | ------------------------------------------- | ------------- | ----------------------------------------- |
| Top-row base Y          | `src/scroller/engine.s` `TYPE2_BASE_Y`      | 78            | Y of right-most column of top scroller    |
| Reflection gap          | `src/scroller/engine.s` `TYPE2_REFLECT_GAP` | 6             | scanlines between row 1 and reflection    |
| Top-row diagonal slope  | `lsr.w #1, d7` inside `.strip`              | d6/2 (½ line/strip) | tilt rate: lines per pword column   |
| Horizontal scroll speed | `SetScrollSpeedExtra`                       | 2× (extra=1)  | two render+shift per VBL                  |

To **steepen the diagonal**, replace `lsr.w #1, d7` with no shift (1 line per
strip). To **flatten** it, replace with `lsr.w #2, d7` (¼ line per strip).

To **change the gap**, edit `TYPE2_REFLECT_GAP` (in scanlines).

### Routine

`ScrollPlotType2` — clears the scroller region, then for each of 20 strips:

1. Computes a Y offset based on column position (right → low Y, left → high Y).
2. Plots the 34-line scroller column at that Y.
3. Plots the reflection below, reading the source backward (line 33 → line 0)
   at 2× line stride so each source line appears with a 1-line gap (giving
   the interleaved "ripple" look).

---

## Effect 3 — Sine wave + 1-line interleave + clearing

A single sine-wave scroller drawn with each source scanline followed by a
1-line gap (so 34 source lines occupy 68 dest lines, every other line
empty). The scroller region is cleared each frame to avoid trails. Reuses
Type 1's trajectory and inside-sine LUTs.

### Configuration

| Knob                          | Where                                    | Current value | What it does                              |
| ----------------------------- | ---------------------------------------- | ------------- | ----------------------------------------- |
| Base Y position               | `src/scroller/engine.s` `TYPE3_ROW_Y`    | 100           | center of the 68-line interleaved row     |
| Trajectory amplitude / period | `type1_traj_lut` (shared with Type 1)    | ±20, 1 s half | see Effect 1 section                      |
| Inside-sine LUT               | `type1_inside_lut` (shared with Type 1)  | 2 cycles, ±3  | see Effect 1 section                      |
| Horizontal scroll speed       | `SetScrollSpeedExtra`                    | 1× (default)  | add `cmp #3 / beq .fast` to enable 2×     |
| Clearing                      | `bsr ClearScrollerRegion`                | enabled       | wipes lines 70–199 each frame             |

To **change interleave density**, edit the `lea SCREEN_LINE_BYTES*2(a1), a1`
in `.scanline`:

* `*2` → 1 line written + 1 gap (current — comb teeth on every other line)
* `*3` → 1 line written + 2 gap (sparser comb, 102-line tall total)
* `*1` → no interleave (back to a 34-line solid scroller — same look as
  the old Type 7)

To **change trajectory or inside-sine**, edit the shared LUTs (see Effect 1).
Note: changes to the shared LUTs affect both effects.

### Routine

`ScrollPlotType3` — clears the scroller region, computes the trajectory
sine offset (LUT-driven, vbl_counter-anchored), then plots 20 strips. Each
strip's Y offset is `TYPE3_ROW_Y + sine_offset + type1_inside_lut[strip]`,
and each source scanline is written with a 1-line gap below it.

---

## Effect 4 — Two diagonals mirrored across a horizontal line

A pair of scrollers tilted on a steep diagonal (1 line per strip), with
row 2 rendered as the upside-down vertical mirror of row 1 across a
horizontal symmetry line. Row 1 uses palette c1, row 2 uses palette c2 —
the swap fires at the mirror line so the colour change visually marks
the axis of symmetry.

Geometry per strip s (0..19):

* Row 1 occupies `Y = TYPE4_ROW1_TOP_Y + s ... + s + 33`
* Row 2 (mirror): source line k → `Y = 2·MIRROR − T1 − s − k`,
  starting at `Y = 2·MIRROR − T1 − s` and decrementing each line.

With the default constants the rows touch at the right edge (strip 19,
where row 1 bottom = mirror line) and open up like an X to the left.

### Configuration

| Knob                          | Where                                       | Current value | What it does                                |
| ----------------------------- | ------------------------------------------- | ------------- | ------------------------------------------- |
| Row 1 top at strip 0          | `src/scroller/engine.s` `TYPE4_ROW1_TOP_Y`  | 80            | top of upper diagonal at the left edge      |
| Symmetry / mirror line        | `src/scroller/engine.s` `TYPE4_MIRROR_Y`    | 132           | horizontal axis row 2 reflects across       |
| Slope                         | hardcoded `add.w d3, d2` / `sub.w d3, d2`   | 1 line/strip  | swap to `lsr.w #1, d3` for ½ line/strip     |
| Palette c2 swap line          | `src/hbl.s` `RASTER_SWAP_C2_TYPE4`          | line 131      | must equal `TYPE4_MIRROR_Y - 1`             |
| Above-mirror palette          | `font_pal_ptr1` (set in `SetPalettePointers`) | c1          | colour of row 1                             |
| Below-mirror palette          | `font_pal_ptr2` / `font_pal_ptr3`           | c2 / c2       | colour of row 2 (ptr3=c2 prevents c3 swap)  |

To **move the mirror line**, change `TYPE4_MIRROR_Y` AND
`RASTER_SWAP_C2_TYPE4` (= mirror − 1) in lockstep.

To **change slope steepness**, edit the two `add.w d3, d2 / sub.w d3, d2`
lines in `ScrollPlotType4`. Replace `d3` with a shifted copy
(`move.w d3, d4 / lsr.w #1, d4 / add.w d4, d2`) for fractional slopes.

### Routine

`ScrollPlotType4` — for each of 20 strips: computes row 1's top Y, computes
row 2's source-line-0 dest Y (above the mirror), then plots 34 source
lines writing forward into row 1 (`+SCREEN_LINE_BYTES` per line) and
backward into row 2 (`-SCREEN_LINE_BYTES` per line) for the upside-down
look.

The c2 palette swap is wired through a runtime BSS slot
(`raster_swap_c2_addr`) so this effect can move the swap to its own line
without touching the C1/C3 swap addresses. `SetPalettePointers` writes
`RASTER_SWAP_C2_TYPE4` for type 4 and `RASTER_SWAP_C2_DEFAULT` for
everything else.

---

## Effect 5 — Static bottom scroller + diagonal interleaved overlay

Two scrollers stacked: a static horizontal one at the bottom (same Y as
effect 0's row 3), and a 1-line-interleaved diagonal overlay sloping from
top-left to bottom-right whose bottom-right corner lands at the mid-height
of the bottom scroller. `ClearScrollerRegion` runs each frame to keep the
interleave gaps black.

### Configuration

| Knob                         | Where                                       | Current value | What it does                              |
| ---------------------------- | ------------------------------------------- | ------------- | ----------------------------------------- |
| Bottom scroller Y            | `src/scroller/engine.s` `TYPE5_BOT_Y`       | `SCROLL_Y_3` (160) | static row position                  |
| Top scroller right anchor    | `src/scroller/engine.s` `TYPE5_TOP_RIGHT_Y` | 176           | Y of top scroller's source line 33 at strip 19 |
| Top scroller base Y          | `src/scroller/engine.s` `TYPE5_TOP_BASE_Y`  | 82            | derived from right anchor + slope         |
| Top scroller slope           | hardcoded `+ s + s/2` in plot               | 1.5 line/strip | tilt rate                                |

To **change the slope**, edit the lines `add.w d3, d2` + `move.w d3, d5;
lsr.w #1, d5; add.w d5, d2` in the top-scroller plot (currently produces
`s + s/2`). For 1 line/strip (less steep), drop the `s/2` adjustment.

### Routine

`ScrollPlotType5` — clears the scroller region, then for each of 20 strips:
plots the bottom scroller forward (34 lines), then plots the top scroller
forward with `2× SCREEN_LINE_BYTES` dest stride (= 1 written + 1 gap line)
at a Y offset depending on the strip index.

---

## Effect 6 — 2 fixed horizontal rows

The simplest effect: two static horizontal rows. Two-row variant of
effect 0.

### Configuration

| Knob               | Where                                   | Current value | What it does                              |
| ------------------ | --------------------------------------- | ------------- | ----------------------------------------- |
| Row 1 Y            | `src/scroller/engine.s` `TYPE6_ROW1_Y`  | 78            | top row Y                                 |
| Row 2 Y            | `src/scroller/engine.s` `TYPE6_ROW2_Y`  | 119           | bottom row Y                              |

### Routine

`ScrollPlotType6` — copies `scroll_buffer[0..19]` to two screen rows using
2-way `movem.l` fan-out. Multi-row palette (c1 / c2 via raster swap at
default lines 77 / 118).

---

## Effect 7 — Triangle trajectories + bottom row ("Real Effect 7")

Three scrollers, same colours as effect 0:

* **Triangle 1** (`/\` trajectory): the scroller's Y traces a downward V
  across the 20 strips — apex (highest on screen, lowest Y) at strips 9-10,
  legs slope down toward the edges. Forward render. → c1 palette.
* **Triangle 2** (`\/` trajectory, upside-down letters): the scroller's Y
  traces an upward V — apex (lowest on screen, highest Y) at strips 9-10,
  legs slope up toward the edges. Source rendered upside-down so triangle 1's
  font bottom touches triangle 2's font top at the apex. → c2 palette.
* **Bottom row**: static horizontal at `SCROLL_Y_3` (= effect 0's row 3 Y).
  → c3 palette.

The c2 raster swap line is moved to line 117 for type 7 (between the two
triangle apexes); c1 / c3 swaps stay at the default lines 77 / 159.

### Configuration

| Knob                  | Where                                       | Current value | What it does                                      |
| --------------------- | ------------------------------------------- | ------------- | ------------------------------------------------- |
| Triangle 1 apex Y     | `src/scroller/engine.s` `TYPE7_TRI_APEX_Y`  | 79            | source line 0 Y at strips 9-10 (= apex of /\\)    |
| Triangle 2 bottom Y   | `src/scroller/engine.s` `TYPE7_TRI2_BOT_Y`  | 151           | source line 0 Y in dest at apex (= bottom of \\/) |
| Bottom row Y          | `src/scroller/engine.s` `TYPE7_BOT_ROW_Y`   | `SCROLL_Y_3` (160) | static row position                          |
| Trajectory depth LUT  | `src/scroller/engine.s` `type7_depth_lut`   | 13 → 0 → 13   | per-strip Y delta from apex (one entry per strip) |
| C2 palette swap line  | `src/hbl.s` `RASTER_SWAP_C2_TYPE7`          | line 117      | scanline at which palette flips c1 → c2           |

### Tuning the triangles

The triangle trajectory is fully described by **`type7_depth_lut`** — a
20-entry symmetric word table giving the Y offset (from apex) at each
strip. Both triangles read the same LUT: triangle 1 *adds* depth (legs
slope down at edges), triangle 2 *subtracts* depth (legs slope up at
edges).

Current values:
```asm
type7_depth_lut:
    dc.w 13, 12, 10, 9, 7, 6, 4, 3, 1, 0
    dc.w  0,  1,  3, 4, 6, 7, 9, 10, 12, 13
```
Slope ≈ 1.44 lines/strip (= 13 / 9). At strip 0 / 19, triangle 1 lands at
`TYPE7_TRI_APEX_Y + 13 = 92`; at strips 9 / 10, at the apex Y=79.

**To make the triangles steeper or flatter:** rewrite the LUT with a new
edge maximum. Keep it symmetric: `LUT[s] == LUT[19-s]`. Some recipes:

* Slope = 1 (gentlest, peak/trough less pronounced):
  ```
  9, 8, 7, 6, 5, 4, 3, 2, 1, 0,  0, 1, 2, 3, 4, 5, 6, 7, 8, 9
  ```
* Slope ≈ 1.5:
  ```
  14, 12, 11, 9, 8, 6, 5, 3, 2, 0,  0, 2, 3, 5, 6, 8, 9, 11, 12, 14
  ```
* Slope = 2 (steeper, sharper peak):
  ```
  18, 16, 14, 12, 10, 8, 6, 4, 2, 0,  0, 2, 4, 6, 8, 10, 12, 14, 16, 18
  ```

**To move the apex** (top of /\\ on the screen): change
`TYPE7_TRI_APEX_Y`. To keep triangle 1 from ducking under the line-77
palette swap, keep `TYPE7_TRI_APEX_Y >= 78`.

**To change the gap between the two triangle apexes** (where the letter
tips meet at the centre): change `TYPE7_TRI2_BOT_Y` (= triangle 2's apex
Y, the dest position of source line 0). The visible top of triangle 2 at
the apex is at `TYPE7_TRI2_BOT_Y − 33`; the gap from triangle 1's bottom
at the apex (`TYPE7_TRI_APEX_Y + 33`) is therefore
`TYPE7_TRI2_BOT_Y − TYPE7_TRI_APEX_Y − 66`. Current gap: `151 − 79 − 66 = 6`.

**Important:** when you change `TYPE7_TRI2_BOT_Y`, also update
`RASTER_SWAP_C2_TYPE7` in `src/hbl.s` so the palette swap line still falls
between the two triangles at the apex. Rule of thumb:
`RASTER_SWAP_C2_TYPE7 = raster_table + (TYPE7_TRI2_BOT_Y − 33 − 1) × 2`.

**To move the bottom row** (e.g. away from triangle 2's lowest extent):
change `TYPE7_BOT_ROW_Y`. The c3 palette swap is fixed at line 159 — keep
the bottom row at Y ≥ 160 to stay in c3.

### Edge overlap (geometric note)

Because each glyph is 34 lines tall and the triangles must touch at the
centre, the diverging legs at the screen edges *always* overlap by an
amount proportional to the slope. With the current slope ~1.89, triangle
1 reaches Y=129 at strip 0 while triangle 2 starts at Y=101 — a 28-line
overlap. Triangle 2 plots after triangle 1, so the overlap region shows
triangle 2's upside-down letters.

Trade-offs:
* **Steeper slope** → more dramatic /\\ shape, more overlap at edges.
* **Larger apex gap** (`TYPE7_TRI2_BOT_Y` higher) → less overlap, but
  triangle 2 may push into the bottom row.
* **Shallower slope** → cleaner separation at edges, less pronounced
  triangles.

The c2 palette swap is a hard horizontal line, so triangle 2 content
above the swap line will show in c1 (and triangle 1 content below it in
c2). For the steepest LUTs you may want to also bump
`RASTER_SWAP_C2_TYPE7` up to cover the worst-case edge extent of
triangle 2's top.

### Routine

`ScrollPlotType7` — clears the scroller region, then for each of 20 strips:

1. Looks up `depth(s)` from `type7_depth_lut`.
2. Plots triangle 1 at `Y_top = TYPE7_TRI_APEX_Y + depth(s)` (forward render,
   34 lines).
3. Plots triangle 2 starting at dest `Y_bottom = TYPE7_TRI2_BOT_Y − depth(s)`
   and walking *up* (= upside-down letters), 34 lines.
4. Plots the static bottom row at `TYPE7_BOT_ROW_Y` forward, 34 lines.
