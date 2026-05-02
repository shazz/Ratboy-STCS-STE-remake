# Reverse-Engineering the 1988 S.T.C.S. / Bladerunners "Stargoose" Cracktro

Source: `/home/matt/projects/MJJ/docs/STCS.RAT/CONFO.S` (~899 lines, 68000 asm).
Companion data: `PIC.PAC` (background picture, 44 KB compressed/raw),
`THRUST.BIN` (YM2149 music, ~4.7 KB).

The original ran on a **stock 520STF — 512 KB RAM, 8 MHz 68000, no blitter, no
Genlock, no DMA sound**. Everything you see (multi-row scrolling text, glyphs
that shift across the screen at different vertical positions, full-screen
per-scanline color gradients, 4-channel PSG music) is done by the CPU between
HBL/VBL interrupts.

---

## 1. Overall architecture

The program is a single, flat assembly file. It does five things in this order:

1. Boot: become supervisor, save the GEMDOS basepage, install custom HBL+VBL
   handlers, kill the mouse, kill `Alt+Help`, hook the YM music player.
2. Decompress the picture (via the loader/launcher logic at `chargeprg` and
   `INCBIN pic.pac` at line 876) into a screen-shaped buffer named `charge`.
3. Loop forever (label `debg`, lines 84–90):

   ```
   debg    bsr     new_lt?    * advance scroll text by one byte every 5 frames
           bsr     scrolg     * shift the off-screen "glyph row" left by one byte
           bsr     scroh      * splat the glyph row into the visible screen
           bsr     swap       * flip the double buffer
           bsr     vsync      * wait VBL
           bra     debg
   ```

4. The HBL handler (lines 714–783) drives the per-scanline palette gradient.
5. The VBL handler (lines 705–712) re-arms Timer-B for the next field.

The work is split: the **main loop** does the heavy CPU memcpy / pixel-shift
and runs in user time (between VBLs), while the **HBL** does only the colour
writes and **the VBL** resets state for the next frame. There is no blitter —
the main loop _is_ the blitter, hand-unrolled.

There are **two screen buffers** (double-buffered, swapped via `sw_ec`
containing `$00030004` at line 798 — i.e. screens at `$30000` and `$40000`
ish, base supplied by GEMDOS `Physbase`). Code, font data, music, picture,
and the small scratch buffers all coexist in the lower 256 KB.

---

## 2. The scroller — pre-shifted glyph row

This is the cleverest part of the file. The scroller does **not** bit-shift
pixels per frame. Instead it maintains a single off-screen "glyph row" and
shifts its content **one byte (= 8 pixels in 4-bitplane chunky-planar layout =
2 logical pixels of horizontal resolution at 16-pixel font width) leftward
per frame** by literally copying byte N+1 over byte N.

### 2.1 The byte-by-byte left-shift loop

`scrolg` (lines 416–444) is the heart:

```
scrolg  move.l  deb_blk,a1
        move.l  a1,a2
        addq.l  #8,a2          * a2 = source = a1 + 8 bytes (= 1 char-cell over)
        move.l  a1,a0          * a0 = destination
        ...
sc_blkg REPT    38              * 38 char-cells wide
        move.l  (a2)+,(a0)+    * copy 8 longs (= 32 bytes) of "scrolled" data
        ENDR                   * — i.e. shift all but the right-most cell left by 8 bytes
        ...
        move.b  1(a2),(a0)+    * ROUTINE DE DECALAGE OCTET PAR OCTET
        move.b  0(a3),(a0)+    * SUR 8 MOTS C A D 32 PIXELS
        move.b  3(a2),(a0)+    * A EFFECTUER 10 FOIS POUR UN DECALAGE
        move.b  2(a3),(a0)+    * TRANSFERT PLUS INTERRESSENT QUE
        move.b  5(a2),(a0)+    * CEUX DU TYPE move.b 1(a2),0(a2)
        move.b  4(a3),(a0)+    * QUI PRENNENT 20 CYCLES CE TYPE
        move.b  7(a2),(a0)+    * N'EN PREND QUE 16 PAR INSTRUCTION
        move.b  6(a3),(a0)+
```

Translation of the in-line comment, lines 431–438:

> "Byte-by-byte shift routine over 8 words (i.e. 32 pixels), to be repeated
> 10 times for a transfer. More interesting than `move.b 1(a2),0(a2)` style
> which takes 20 cycles — this type only takes 16 cycles per instruction."

So the author is consciously cycle-counting:

- `move.b 1(a2),0(a2)` (memory-to-same-memory) = 20 cycles
- `move.b 1(a2),(a0)+` (memory-to-memory with post-inc destination) = 16 cycles

That 4-cycle saving × 8 instructions × 33 row repeats × 50 Hz adds up to a
**huge** savings on an 8 MHz 68000 (~3 KHz of free CPU per frame just from
this micro-optimisation).

The trick of copying alternating bytes from `(a2)` (the just-shifted plane
data) and `(a3)` (a fresh column that comes in from the right edge from
`ad_copy`, line 420) is how the scroller "feeds in" the new character one
plane-byte at a time. `ad_copy` points into the rendered next-letter buffer
(`buf_let`); each frame `cmt_lettre` (`new_lt?`, line 498) decrements, and
when it hits zero a new ASCII byte is consumed from `text` (line 816+) and
the source pointer is advanced.

### 2.2 Sub-byte shifting and the `cmt_lettre = 5` cycle

`cmt_lettre` starts at 5 (line 503). Each frame `new_lt?` does
`sub.b #1,cmt_lettre` and on zero advances to the next letter. So the
scroller takes **5 frames per byte = 5 × 8 = 40 pixels per character**, which
matches the font width visible on screen. The "smoothness" is achieved purely
because each frame the pixels move 8 pixels left at 50 Hz — no sub-pixel
pre-shifts are stored. The original is only **8-pixel-granular** horizontal
scrolling. (At 50 Hz, that still reads as smooth-ish text because 400
px/sec.) This is a much simpler design than e.g. a Union scroller which
needs 16 pre-shifted glyph copies.

### 2.3 The `inc_sc` / `impair` / `f_imp` swap

Look at `impair`, line 582, and `end_sc`, line 572:

```
impair  move.l  #$00010007,inc_sc
        ...
        divu #2,d0              * d0 = ASCII letter index
        swap d0
        tst.w   d0
        beq     f_imp
        moveq.l #17,d3
        move.l  #$00070001,inc_sc
        bra     s_imp
f_imp   moveq.l #20,d3
```

The **font is laid out two letters per row in memory**. Even-indexed letters
start at offset 20 within the font cell (`f_imp`, line 591); odd-indexed
letters at offset 17 (`s_imp`); and `inc_sc` is loaded with **either
`$00010007` or `$00070001`** — a packed pair of (current, next) byte
increments. At `end_sc` (lines 572–578) it does

```
swap d0       * swap the words of inc_sc — flips current and next
ext.l d0
add.l d0,a3   * advance buf_let by 1 or 7 alternately
```

so over two letters the pointer advances 1+7 = 8 bytes (= one full screen
chunky long). This is the "pack two letters per chunky long" trick: in ST
4-plane chunky-planar layout, an 8-pixel-wide letter is 8 bytes (one long
per plane = 4 longs for two planes? actually 4 bytes for 1 plane × 8 px
× 4 planes = 8 bytes total). Storing letters paired and stepping by 1 then
by 7 hops over the partner letter, then re-aligns at the next pair.

### 2.4 Blitting the scroll row into screen — `aff_blk`

`aff_blk`, lines 99–107:

```
aff_blk movea.l phys,a1
        move.w  #69,d0          * NOMBRE DE LIGNE = 70 lines
        movea.l buf_des,a0
        add.l   #32640,a0
aff_lin rept    40
        move.l  (a0)+,(a1)+
        endr
        dbf     d0,aff_lin
        rts
```

70 lines × 40 longs = 70 × 160 bytes = 11200 bytes copied per call. This is
called once at startup (lines 78, 81) to lay down the font/scroll background
into both screen buffers. After that the actual visible scroller is fed
purely by `scrolg` writing into `deb_blk` (a sub-rect of the active screen)
plus `scroh` (see next section).

---

## 3. The "multi-row" / wave / 3-row text — `scroh` and the seven `typeN` variants

This is where the cracktro shows off. `scroh`, lines 109–124, dispatches on a
byte `type` (0–7). Each `typeN` function reads the **already-shifted scroll
row** (at `deb_blk`) and copies it into the visible screen at **two or three
different vertical positions**, optionally offsetting each row independently
each frame to produce wave / sine / counter-rotating effects.

The genius: the row is rendered **once** (by `scrolg`), and `scroh` just
**duplicates** it cheaply into multiple Y positions. There is no separate
"render 3 rows of text"; it's one row, splatted three times with vertical
offsets.

### 3.1 Example — `type1` (lines 125–184)

```
type1   move.l  #$60000122,mod1   * self-modify the HBL gradient
        move.l  phys,a1
        move.l  deb_blk,a0
        sub.l   #160,a0
        move.l  a0,a2
        move.l  a1,a3
        add.l   #11680,a3         * row 2: 11680 bytes below screen top
        add.l   cst,a3            * + sine offset
        move.l  a3,a1
        move.l  a1,a6
        add.l   #15360,a6         * row 3: a further 15360 bytes lower
        move.l  a6,a5
        moveq   #19,d0            * 20 vertical strips
loobi1  REPT    36                * 36 columns
        move.l  a0,a4
        MOVE.L  (A0)+,(A1)+       * copy plane long to row-2 dest
        move.l  (a0)+,(a1)+
        move.l  a4,a0             * rewind source
        add.w   #160-8,a1         * next scanline of row-2 dest
        move.l  (a0)+,(a1)+       * copy plane long again to row-2 next line
        move.l  (a0)+,(a1)+
        add.w   #160-8,a0
        add.w   #160-8,a1
        endr
```

Note **the source is rewound** (`move.l a4,a0`) so the same source long is
written **twice** to two consecutive destination scanlines — i.e. the row is
**vertically doubled** (2× zoom in Y) on the fly without any precomputation.
That is how a single 8-pixel-tall glyph row becomes a fat 16-pixel-tall
display row.

After the column REPT, the loop branches based on `d0` (the strip counter)
and adds different sine-table-ish offsets to `a3`:

```
        cmp.w   #6,d0
        bne     gg1
        addq.l  #8,a3            * jog right by 8 bytes at strip 6
        bra     glups1
gg1     cmp.w   #14,d0
        bne     sinus1
        addq.l  #8,a3            * jog right by 8 bytes at strip 14
        bra     glups1
sinus1  cmp.w   #5,d0
        bhi     su1spsc
        add.l   #160*1+8,a3      * down a line + right 8 bytes
        bra     glups1
su1spsc cmp.w   #13,d0
        bhi     su1sps1
        sub.l   #160*1-8,a3      * up a line + right 8 bytes (the - is a + due to reversed sense)
        bra     glups1
su1sps1 add.l   #160*1+8,a3
```

This is a hard-coded, hand-tuned **vertical-slither pattern** — different
slices of the row land at different Y positions, producing the "letters
ripple up and down as they move" look.

The whole thing is wrapped by `cst` (line 887, a long stored in BSS) which
is incremented every 49 frames by either +160 or −160 (lines 172–183), then
the sign of `ss` flips, giving a slow vertical bob superimposed on the
per-strip wobble.

### 3.2 The seven types

| type | Effect (inferred) | Key lines |
|------|-------------------|-----------|
| 1    | 2-row, top row + bottom row 2× tall, sine bob | 125–184 |
| 2    | 2 rows, anti-symmetric travel (sub instead of add on a3/a6) | 186–215 |
| 3    | 2 rows, both rolling diagonally same direction | 217–247 |
| 4    | Spread vertical (a1 += 320-8 instead of 160-8 → 4× tall) | 249–278 |
| 5    | Wider gap, opposite directions, deca = 160*160 | 280–317 |
| 6    | Diagonal travel, both rows shift right 8 px per strip | 319–351 |
| 7    | Single-tall row, no sub-row duplication, sine | 353–412 |

The **`type` byte is embedded inline in the `text` data** (lines 816, 824,
828, 832, 836, 840 — bytes 6, 1, 2, 7, 3, 4, 5). Inside `new_lt?`:

```
        move.b  (a0),d0
        addq.l  #1,point_text
        cmp.b   #1,d0
        bcs     nv1
        cmp.b   #7,d0
        bhi     nv1
        move.b  d0,type           * 1..7 = effect change
        bra     nvlet             * skip, get next byte
```

So values 1–7 in the text stream act as **inline directives** that switch
visual effect mid-message. This is a very compact way to script an intro: no
separate timeline, just embed effect-change bytes between sentences.

### 3.3 Self-modifying code: `mod1` and `mod2`

Each `typeN` does e.g. `move.l #$60000122,mod1`. `mod1` is a **label inside
the HBL handler** (line 723):

```
mod1    cmp.b   #74,d0
        beq    cont2
        cmp.b   #100,d0
mod2    bne    fhbl
```

The bytes `$60000122` are a `BRA.W +$122` (i.e. *don't do this raster
sub-test, jump straight to a different gradient block*). Other types write
`$b07c005a` = `cmp.w #$5a,d0` to **change the scanline at which the HBL
swaps palette**. `mod2` similarly toggles between `bne` ($66) and `bra`
($60).

In other words: **the choice of effect also rewrites the HBL handler's own
opcodes** so that the per-scanline gradient is repositioned to match where
the duplicated rows now sit. No branch table, no flag-and-test — they patch
the conditional opcodes in place.

---

## 4. Raster gradient — Timer-B + HBL

Timer-B on the MFP is the standard ST raster trick. Setup at `inter_on`
(lines 638–667):

```
        move.b  $fffa07,d0
        ori.b   #1,d0
        move.b  d0,$fffa07     * IERA bit 0 = enable Timer-B IRQ
        move.b  $fffa13,d0
        ori.b   #1,d0
        move.b  d0,$fffa13     * IMRA bit 0 = unmask
```

(Earlier `andi.b #$df,d0 / move.b d0,$fffa09` and `andi.b #$fe,d0 / move.b
d0,$fffa07` clear the AER and disable the existing handler so the new vector
takes over cleanly.)

`hbl` is **vectored from $120** (line 660) — that's the MFP auto-vector for
Timer-B, which on the Atari ST fires once per scanline of the displayed area
when programmed in event-count mode.

### 4.1 The HBL gradient handler

Lines 714–783:

```
hbl     movem.l  d0/a0,-(sp)
        lea     tabcoul,a0
        move.w  (a0),d0          * d0 = scanline counter (in bytes, ×2)
        move.w  2(a0,d0),$ff8240 * write 1 word to colour 0 from table
        addq.w  #2,(a0)          * advance counter
        cmp.b   #0,d0
        beq    cont1             * line 0  → load full gradient block A
        cmp.b   #40,d0
        beq    cont               * line 20 → load full gradient block B
mod1    cmp.b   #74,d0           * (self-modified by typeN!)
        beq    cont2              * line 37 → load gradient block C
        cmp.b   #100,d0
mod2    bne    fhbl               * (self-modified by typeN!)
        move.l #$ff8240,a0       * line 50 → load yet another block
        move.w #$127,2(a0)
        ...
```

The neat thing: instead of having a single 200-entry colour table the HBL
walks through, it **bulk-loads 14 palette registers** at four specific
scanlines (`cont1`, `cont`, `cont2`, and the inline block in `mod2`'s
fallthrough). Between those checkpoints, only **colour 0** is being
modified, by reading sequential words out of `tabcoul` (lines 861–866):

```
tabcoul dc.w   200             * counter, starts at 200(?)... see VBL
        rept   20
        dc.w   0
        endr
        dc.w   $1,$1,$1,$1,$1,$1,$2,$2,$2,$2,$2,$2,$3,$3,$3,$3,$3,
        dc.w   $4,$5,$6,$7,$117,$227,$337,$447,$557,$667,$777,$767,
        dc.w   $757,$747,$737,$727,$717,$707,$706,$705,$704,$703,$702,$701,$701,$700,$700,$700,$0
```

So a single 47-step table drives the colour-0 fade-in/out, and **the rest of
the palette is bulk-rewritten exactly 4 times per frame** at known scanlines
to "switch palette zones" — top/middle/bottom of the screen each get their
own sub-palette.

The HBL is short (write 1 word, advance, 4 compares, RTE) for ~180 of 200
lines, and only the 4 "switch" scanlines do the 14× longer bulk write. That
fits comfortably in the ~512 cycles of HBLANK on a 50 Hz ST.

### 4.2 The VBL — Timer-B re-arm

Lines 705–712:

```
vbl     clr.w   $ff8240            * reset colour 0 to black
        move.b  #0,$fffa1b         * stop Timer-B
        move.w  #0,tabcoul         * reset table index
loop1   move.b  #3,$fffa21         * Timer-B data = 3
        cmp.b   #3,$fffa21         * read back to confirm latched
        bne     loop1
        move.b  #8,$fffa1b         * start Timer-B in event-count mode
        rts
```

The `move.b #3,$fffa21 / cmp.b / bne loop1` busy-wait is **the** classic ST
Timer-B latching idiom: write the count, then re-read until the chip
acknowledges the write, before starting the timer. Mode 8 = event-count
mode (advance on each HBL pulse from Shifter). With count 3, Timer-B fires
every 3rd HBL — but on the ST you typically use 1 to fire every line; here
3 means colour 0 changes every 3 scanlines, i.e. ~67 colour bands over 200
lines, matching the size of the gradient table.

---

## 5. Memory layout / budget

Within 512 KB:

- **Code + data** — the entire `.S` file assembled is small, well under
  64 KB. With `INCBIN` of `pic.pac` (~44 KB) and `thrust.bin` (~5 KB) it
  rounds to roughly 64–96 KB of BSS+TEXT in low memory.
- **Two screen buffers** at `$30000` and `$40000` (from `sw_ec dc.l
  $00030004`, line 798) — 32 KB each, 64 KB total.
- **Off-screen glyph row + scroll buffer** lives inside the picture buffer
  (`buf_des dc.l charge`, line 802; `aff_blk` reads from `charge + 32640`).
  No separate allocation.
- **`tabcoul`** (96 bytes), `cst`, `ss`, `cmt_lettre`, etc — a dozen
  scalars. BSS total < 256 bytes.

The picture buffer doubles as the scroller's "ROM" (font + permanent
graphics in `pic.pac`), and the visible scroll is rendered into the screen
buffer directly. **There is no off-screen render buffer for the scroller** —
all the splatting in `typeN` writes straight into the back-buffer, which is
then made visible by `swap`.

`swap`, lines 619–636:

```
swap    move.l  sw_ec,d0        * sw_ec = $00030004
        swap    d0
        move.l  d0,sw_ec        * → $00040003  (alternates each call)
        ...
        move.b  d0,$ff8201      * write screen base hi-byte
        move.b  #0,$ff8203      * mid-byte = 0  (STF only has 2 bytes!)
        ...
        move.l  d0,phys
        add.l   deca,d0          * deca = vertical offset to start of scroll area
        move.l  d0,deb_blk       * pointer to the row to scroll into
```

Two interesting points:

1. **STF screen-base register is only 2 bytes** (`$ff8201` hi, `$ff8203` mid)
   — the STE adds `$ff820d` (low byte) for fine-pixel scroll, but the
   original doesn't use that and couldn't, since STF doesn't have it.
2. `deca` (the vertical offset) is just added to `phys` — they offset the
   destination address rather than skipping scanlines, so `scrolg` /
   `typeN` write at the right Y without any per-line conditional.

---

## 6. Cycle accounting & scanline timing

The author **does** count cycles in comments. Examples:

- Lines 431–438 — the explicit "16 vs 20 cycles per `move.b`" comparison.
- Line 442 — `add.l #160,a3 * POINTEUR DECALE DE 20 OCTETS=40 PIXELS` — a
  comment confirming the author thinks in pixels and bytes interchangeably.

There is **no explicit "this fits in N HBLs"** comment, but the design
implicitly relies on:

- Main loop runs in user time, between VBLs. With `vsync` (Trap #14 #$25, line
  452) it waits for frame-end. So the heavy work (`scrolg`, `scroh`, `swap`)
  has up to **one full 50 Hz frame ≈ 8 MHz × 1/50 = 160000 cycles** to
  complete.
- `scrolg` REPT 38 × ~24 cycles + 8 × 16 cycles + bookkeeping = ~32×38 + 128
  ≈ 1350 cycles per row × 33 rows = ~45 000 cycles ≈ 28% of a frame.
- `scroh` (`type1`): REPT 36 × (32+ cycles) × 20 outer iterations ≈ 25 000
  cycles ≈ 16% of a frame.
- HBL cost: ~30 cycles common path × 200 lines = 6000 cycles, +4× bulk
  loads of ~70 cycles each = 280 cycles. Total per frame ≈ 6300 cycles ≈
  4%.

So the original probably runs at ~50% CPU utilisation with plenty of
headroom — which is why the cycle-counting matters: the author is aiming to
**stay inside a single 50 Hz frame so vsync never misses**.

---

## 7. Anything surprising or clever

A grab-bag of techniques worth knowing:

1. **In-band effect changes** — bytes 1..7 in the scroll text stream
   directly switch the visual mode. No timeline, no scheduler.
2. **Self-modifying HBL** — `mod1`/`mod2` patch the conditional opcodes of
   the active HBL handler whenever the effect changes (lines 125, 217, 280
   etc. write `$60000122` or `$b07c005a` directly into the running code).
3. **Vertical doubling by source rewind** — `move.l a0,a4` then later
   `move.l a4,a0` lets two consecutive scanlines read the **same** source,
   so a 1-row glyph becomes 2-row tall for free (lines 138–148).
4. **Pair-packed font** — letters stored two-per-row with `$00010007 /
   $00070001` step toggling (lines 582, 589) saves font ROM.
5. **`#$12,$fffc02`** (line 64) — the ST-MIDI/Keyboard ACIA write that
   silences the IKBD's mouse packets. Without this the keyboard ISR keeps
   firing and stealing cycles from the rasters. Restored at line 696 to
   `$08`.
6. **`move.l #hard,$502`** (line 65) — `$502` is the GEMDOS Alt+Help
   screendump vector; pointing it at an `rts` (label `hard`, line 807)
   blocks the user from triggering a print and crashing.
7. **`tab_xpos` set to 160** but never actually consulted in the inner loop
   — looks like leftover from a previous non-fullscreen version.
8. **The `$2f3c0000` patch** at line 32 (commented "ds le prg a lancer /
   contre les connards") is anti-cracker: the launched STARGOOSE binary
   has its first long word replaced at runtime with a `move.l #$0,-(sp)`
   so disassembling the file directly shows garbage. (This is the "rat"
   in S.T.C.S.RAT.)
9. **No interrupt nesting protection** — the HBL just `movem.l d0/a0,-(sp)
   / ... / movem.l (sp)+,d0/a0 / bclr #0,$fffa0f / rte`. It assumes the
   main loop never raises IPL > 1, which is only safe because there's no
   blitter and no other timer in flight.

---

## 8. Lessons for the STE port

We are currently struggling with 3-row scroller timing on STE because our
mental model is "blitter does 3 rows independently". The original suggests
several simpler architectures to consider:

### Lesson 1 — One row, splatted three times (DROP THE 3-ROW BLITTER MODEL)

The original **never has 3 separate rows of glyph data anywhere in
memory**. It has **one** scrolled row (built in-place by `scrolg`) and a
splat function (`scroh` / `typeN`) that writes that row into the visible
screen at multiple Y positions, optionally Y-doubled and X-offset per
strip.

For STE this means: do the (cheap, one-row) byte-shift in screen memory
exactly as the original does (or with the STE blitter once), then use the
blitter or CPU to **memcpy that row into rows 2 and 3** of the visible
area. The "3-row scroller" stops being a scheduling problem and becomes a
copy problem.

Even simpler on STE: use the **STE hardware horizontal fine-scroll
register `$ff8265`** to do the 8-pixel-granularity shift for free, then
each frame just memcpy the source row into rows 1, 2, 3 of the visible
area at three different vertical offsets. The blitter's HOG vs cooperative
debate goes away because you only need **one** blit per frame for the
row content; the multi-row illusion is pure address arithmetic.

### Lesson 2 — Self-modifying HBL beats a parametric HBL

We currently have (or were planning) an HBL that reads from a per-frame
table to decide which scanlines do what. The original instead **patches
its own conditional opcodes** each time the effect changes (`mod1`,
`mod2`). This is faster (no table read in the hot path) and simpler to
reason about — the HBL has fixed branch points, just at different line
numbers.

On STE we could do exactly the same: pick 3-4 scanlines for "switch
palette zone", encode them as immediate operands in `cmp.w #N,d0`
instructions, and rewrite N when the effect changes.

### Lesson 3 — Effect changes embedded in the text stream

If/when we add multiple visual modes, follow the original's lead: put
effect-change bytes (1..7) **inside** the scroll text itself, with the
text consumer recognising them and updating a `type` byte that the
`scroh`-equivalent dispatches on. This eliminates a separate timeline /
scheduler subsystem.

### Lesson 4 — Vertical doubling for free via source-rewind

To get fat-pixel glyphs (16 px tall from an 8-px-tall row) on STE without
running the blitter twice or storing pre-doubled glyphs, use the same
trick as `type1` at lines 138–148: save the source pointer before the
column-write, write one scanline of destination, restore the source
pointer, advance only the destination, write the same source again. This
works for both blitter (set source-Y-increment to 0 for one pass) and CPU
copy.

### Lesson 5 — Cycle-count the inner loop, not the overall frame

The original's `move.b 1(a2),(a0)+` choice over `move.b 1(a2),0(a2)` is
a textbook example: a single addressing-mode change saved ~20% on a
function called 1000+ times per frame. Our STE port should similarly
prefer:

- `move.l (a0)+,(a1)+` over `move.l (a0),(a1) / addq.l #4,a0/a1` (8 cycles
  saved per long).
- Pre-decremented displacement constants (e.g. `add.w #160-8,a1`) baked
  into the REPT body rather than computed each iteration.
- REPT-unrolled inner loops up to the I-cache / prefetch limit (the
  original unrolls up to 38× — clearly the 68000's lack of cache means
  `dbf` overhead matters).

Apply this when we revisit the 3-row scroller copy: an unrolled `move.l`
sequence (one per row of pixels) will likely outperform a blitter-driven
copy for short runs, since the blitter setup overhead (~20 cycles) is
significant per row.

### (Bonus) Lesson 6 — Kill the keyboard ACIA before measuring rasters

If our STE port keeps mouse/keyboard interrupts enabled while measuring
HBL timing, we will see jitter exactly when the IKBD sends a packet. The
original's `move.b #$12,$fffc02` (line 64) — "set ACIA mode = no IRQ on
RX" — eliminates that. We already partially do this (`STATUS.md` notes
"disable mouse"), but worth confirming `$fffc02` is being written, not
just the higher-level Line-A `hide`.

---

## Cross-reference: where to find each technique in CONFO.S

| Technique | Lines |
|-----------|-------|
| Boot, supervisor, interrupt setup | 50–73, 638–667 |
| Disable mouse / IKBD / Alt+Help | 64–65 |
| Music init | 67, 612–617 |
| Main loop | 82–90 |
| Scroller byte-shift | 416–444 |
| Sub-byte font stepping (1/7 toggle) | 582–610 |
| Multi-row splat dispatcher | 109–124 |
| Type 1 (sine, 2-row, 2× tall) | 125–184 |
| Type 7 (1-row, sine) | 353–412 |
| HBL per-scanline colour | 714–783 |
| Palette-zone bulk rewrite | 735–773 |
| Self-modified HBL opcodes | 723, 726, with patches at 125, 217, 280, 319 |
| VBL Timer-B re-arm | 705–712 |
| Double-buffer swap | 619–636 |
| Colour gradient table | 861–866 |
| Embedded effect-change bytes in text | 816–843 |
| Cycle-counting comments | 431–438, 442 |
