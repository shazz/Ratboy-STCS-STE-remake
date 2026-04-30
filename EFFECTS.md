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

All effects share the same per-VBL pipeline in `ScrollerStepVblank`
(`src/scroller/engine.s`):

1. `ScrollRenderNextPword` — emits one 16-pixel column into `scroll_buffer[20]`
   (the off-screen staging slot) using a 5-phase blending cycle so glyphs
   tile flush at 0px letter spacing.
2. `ScrollShift` — shifts the whole 21-pword × 34-line buffer one pword left.
3. `ScrollPlotDispatch` — hands off to the active effect's plot routine,
   which reads `scroll_buffer[0..19]` and writes to one or more rows of the
   back screen buffer.

`SwapBuffers` is then called from `MainLoop` to publish the frame.

Effects can opt into **2× horizontal scroll speed** via `SetScrollSpeedExtra`,
which causes `ScrollRenderNextPword + ScrollShift` to run twice per VBL.

```asm
SetScrollSpeedExtra:
    cmp.w   #1, d0
    beq.s   .fast      ; effect 1 = 2× speed
    clr.w   scroll_speed_extra
    rts
.fast:
    move.w  #1, scroll_speed_extra
    rts
```

Add another `cmp.w #N / beq.s .fast` line here to enable 2× scroll for any
future effect.

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
