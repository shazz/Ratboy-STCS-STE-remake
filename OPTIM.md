# Optimization Plan: Effect 0 → 1 VBL

Session 6 (2026-05-01) — Cycle analysis and optimization roadmap.

## Current State

**Measured with HRDB (start of session):**
- Effect 0 (fastest): 70% @ 2 VBLs, 30% @ 3 VBLs
- Effects 1-7: 4-6 VBLs each

**Target:** All effects @ 1 VBL (like original CONFO.S from 1988)

## Mid-Session Update (2026-05-01)

After implementing in-screen scroll architecture + Phase 1 polish, HRDB
showed Effect 0 was now consistently 2 VBLs. **Color-bar profiling** (set
PROFILE_ENABLED=1, RASTER_ENABLED=0, MUSIC_ENABLED=0) revealed that with
the gradient OFF, the scroller fits in 1 VBL. So the **Timer-B HBL ISR
itself** is what pushes us over the boundary.

### The Timer-B Discovery

Reading WRITE_UP.md's analysis of CONFO.S revealed:
- **Original uses TBDR=3** (fires every 3rd scanline, ~67 fires/frame, NOT
  200). 3× reduction in ISR count alone.
- Original handler is ~30 cy common path (vs our ~220 cy) — counter inside
  the table, immediate-value compares, self-modifying code per-effect.
- Bulk palette load (movem) at 4 specific scanlines, not per-line.

### Cycle Audit of Our TimerBHandler (before Session-6 opts)

Original common path: 220 cy/fire. With 200 fires/frame:
```
200 × 220 cy = 44,000 cy/frame ≈ 86 sl wallclock per VBL of work
```

This compounds across multi-VBL effects:
- Effect 0 (2 VBL): ~172 sl HBL cost
- Effects 1-7 (5 VBL avg): ~430 sl HBL cost — bigger than the entire 313 sl frame

**The HBL is shared overhead — fixing it once helps every effect.**

## Where the Time Goes (Effect 0)

| Component | Cycles | Scanlines | Notes |
|-----------|--------|-----------|-------|
| `ScrollPlotType0` | ~82K | ~160 sl | Writes 16KB to video RAM (×1.5 Shifter contention) |
| `ScrollShiftAndFill` | ~32K | ~62 sl | System RAM, no contention |
| `ScrollRenderNextPword` | ~7K | ~13 sl | Every other VBL |
| Timer-B ISR overhead | ~21K | ~41 sl | 200 fires/frame |
| **Total** | ~142K | **~276 sl** | Frame = 313 sl → bleeds into VBL 2 |

## MULU Locations (the 70-cycle killers)

```
engine.s:248   mulu.w #FONT_GLYPH_BYTES, d1   ; .fetch_next_char (1× per 2 VBLs)
engine.s:526   muls.w d1, d0                  ; Type1 trajectory (1× per frame)
engine.s:551   mulu.w #SCREEN_LINE_BYTES, d2  ; Type1 inner loop (20× per frame)
engine.s:616   mulu.w #SCREEN_LINE_BYTES, d2  ; Type2 inner loop (20× per frame)
engine.s:696   muls.w d1, d0                  ; Type3 trajectory (1× per frame)
engine.s:719   mulu.w #SCREEN_LINE_BYTES, d2  ; Type3 inner loop (20× per frame)
engine.s:778   mulu.w #SCREEN_LINE_BYTES, d2  ; Type4 inner loop (20× per frame)
engine.s:787   mulu.w #SCREEN_LINE_BYTES, d2  ; Type4 inner loop (20× per frame)
engine.s:869   mulu.w #SCREEN_LINE_BYTES, d2  ; Type5 inner loop (20× per frame)
engine.s:969   mulu.w #SCREEN_LINE_BYTES, d2  ; Type7 inner loop (20× per frame)
engine.s:986   mulu.w #SCREEN_LINE_BYTES, d2  ; Type7 inner loop (20× per frame)
```

**Key insight:** Effect 0 has NO MULU in its hot path. The slowness comes from video RAM contention, not multiply instructions.

## Optimizations by Estimated Gain

### TIER 1: BIG WINS

| # | Optimization | Est. Gain | Complexity | Affects |
|---|-------------|-----------|------------|---------|
| 1 | Blitter for ClearScrollerRegion | ~80 sl | Medium | Effects 1,2,3,5,7 |
| 2 | Y-offset LUT (×184) | ~3 sl | Low | Effects 1-7 |
| 3 | Glyph offset LUT (×816) | ~1 sl | Low | All |

### TIER 2: MEDIUM WINS

| # | Optimization | Est. Gain | Complexity | Affects |
|---|-------------|-----------|------------|---------|
| 4 | movem.l in ScrollShiftAndFill | ~1 sl | Low | All |
| 5 | Unroll byte-shift epilogue | ~0.5 sl | Low | All |

### TIER 3: ARCHITECTURAL

| # | Optimization | Est. Gain | Complexity | Affects |
|---|-------------|-----------|------------|---------|
| 6 | Reduce Effect 0 to 2 rows | ~53 sl | Visual change | Effect 0 |
| 7 | Split work across VBL boundary | ~31 sl | Medium | All |

### TIER 0: SHARED OVERHEAD (Timer-B HBL)

These reduce the per-VBL ISR cost. Saving compounds with VBL count of each effect.

| # | Optimization | Est. Gain | Complexity | Affects |
|---|-------------|-----------|------------|---------|
| T1 | Encoded markers in raster_table (sign-bit dispatch) | ~17 sl/VBL | Low | All |
| T2 | TBDR=2 (halve fire rate, 2-line bands) | ~33 sl/VBL | Medium | All |
| T3 | TBDR=3 + re-arm (CONFO.S style) | ~45 sl/VBL | High (jitter risk) | All |
| T4 | Bulk movem palette swap once per frame | ~5-10 sl | Medium | All |

## LUT Implementation Details

### Y-offset LUT (SCREEN_LINE_BYTES = 184)

```asm
; 200 entries × 2 bytes = 400 bytes
y_offset_lut:
    dc.w    0, 184, 368, 552, 736, ...  ; Y × 184 for Y = 0..199

; Usage: replace mulu.w #SCREEN_LINE_BYTES, d2
    add.w   d2, d2              ; 4 cy (word index)
    lea     y_offset_lut, a0    ; 8 cy (or keep in register)
    move.w  0(a0,d2.w), d2      ; 14 cy
    ; Total: 26 cy vs 70 cy = 44 cy saved per lookup
```

### Glyph offset LUT (FONT_GLYPH_BYTES = 816)

```asm
; 64 entries × 4 bytes = 256 bytes
glyph_offset_lut:
    dc.l    0, 816, 1632, 2448, ...  ; glyph × 816 for glyph 0..63

; Usage: replace mulu.w #FONT_GLYPH_BYTES, d1
    lsl.w   #2, d1              ; 12 cy (long index)
    lea     glyph_offset_lut, a1
    move.l  0(a1,d1.w), d1      ; 18 cy
    ; Total: 30 cy vs 70 cy = 40 cy saved per glyph fetch
```

## Blitter ClearScrollerRegion

Current CPU clear: 130 lines × 46 longs × 12 cy = ~71K cycles (~140 sl with contention)

Blitter clear:
- 130 lines × 184 bytes = 23,920 bytes = 11,960 words
- Blitter: ~2 cy/word (during VBL) or ~2.5 cy/word (visible)
- Total: ~24-30K cycles = ~47-58 sl

**Gain: ~80 scanlines for effects that use ClearScrollerRegion**

```asm
ClearScrollerRegionBlitter:
    lea     BLITTER, a0
    move.l  back_buffer_ptr, d0
    add.l   #CLEAR_START_Y*SCREEN_LINE_BYTES, d0
    
    move.w  #2, BLIT_DST_XINC(a0)           ; word increment
    move.w  #SCREEN_LINE_BYTES-184+2, BLIT_DST_YINC(a0)  ; = 2 (no skip)
    move.l  d0, BLIT_DST_ADDR(a0)
    move.w  #$FFFF, BLIT_EMASK1(a0)
    move.w  #$FFFF, BLIT_EMASK2(a0)
    move.w  #$FFFF, BLIT_EMASK3(a0)
    move.w  #92, BLIT_XCOUNT(a0)            ; 184 bytes = 92 words
    move.w  #CLEAR_HEIGHT, BLIT_YCOUNT(a0)  ; 130 lines
    move.b  #0, BLIT_HOP(a0)                ; all zeros
    move.b  #0, BLIT_OP(a0)                 ; clear (0)
    move.b  #$C0, BLIT_CTRL(a0)             ; start, HOG mode
.wait:
    btst.b  #7, BLIT_CTRL(a0)
    bne.s   .wait
    rts
```

## THE KEY INSIGHT: Original CONFO.S Never Writes 3 Rows!

After analyzing the original CONFO.S source, the critical difference is clear:

**Original CONFO.S effect types:**
| Effect | Rows Written | Technique |
|--------|--------------|-----------|
| type1 | 1 row | Vertical doubled (36 lines → 72 pixels) |
| type2 | 2 rows | Row 1 + inverted row 2 |
| type3 | 2 rows | Both diagonal same direction |
| type4 | 2 rows | 4× tall spread |
| type5 | 2 rows | Wider gap, opposite directions |
| type6 | 2 rows | Diagonal travel |
| type7 | 1 row | Single-tall, sine wave |

**Our effect types:**
| Effect | Rows Written | Difference |
|--------|--------------|------------|
| Type0 | **3 rows** | +50% vs original |
| Type1 | 1 row (2× tall) | Similar |
| Type2 | 2 rows | Similar |
| Type3 | 1 row (interleaved) | Similar |
| Type4 | 2 rows | Similar |
| Type5 | 2 rows | Similar |
| Type6 | 2 rows | Similar |
| Type7 | **3 rows** | +50% vs original |

**The original CONFO.S has NO 3-row effect!**

Data written per frame:
- Original (2 rows): 34 lines × 160 bytes × 2 = **10,880 bytes**
- Our Type0 (3 rows): 34 lines × 160 bytes × 3 = **16,320 bytes** (+50%!)

This 50% extra data volume with Shifter contention is why our fastest effect takes 2 VBLs.

## Original Architecture (from CONFO.S)

```
Main Loop (debg):
    bsr new_lt?    ; advance scroll text
    bsr scrolg     ; shift scroll row LEFT by 8 bytes (in video RAM)
    bsr scroh      ; splat scroll row to 2 Y positions (in video RAM)
    bsr swap       ; flip double buffer
    bsr vsync      ; wait for VBL

Key insight: deb_blk points to Y=210 (below visible area in video RAM).
The scroll row lives OFF-SCREEN but in the same memory region.
scrolg shifts it in-place, scroh copies it to visible Y positions.
```

Their cycle budget (WRITE_UP.md estimates):
- scrolg: ~32K cycles (no contention - below visible area)
- scroh: ~25K cycles (2 rows with contention)
- Total: ~57K cycles = ~35% of frame = comfortable margin

Our cycle budget:
- ScrollShiftAndFill: ~32K cycles (no contention - system RAM)
- ScrollPlotType0: ~82K cycles (3 rows with contention)
- Total: ~114K cycles = ~71% of frame = marginal, slips to 2 VBLs

## Architectural Fix: Reduce Type0 to 2 Rows

To match original timing, reduce Type0 from 3 rows to 2 rows:
- Current: SCROLL_Y_1 (78), SCROLL_Y_2 (119), SCROLL_Y_3 (160)
- Proposed: SCROLL_Y_1 (78), SCROLL_Y_2 (130) — vertically doubled like original type1

**Estimated gain: 33% reduction in ScrollPlotType0 = ~27K cycles = ~53 scanlines**

This would bring Type0 from ~114K cycles to ~87K cycles = 54% of frame = solid 1 VBL.

## Alternative: Use Original's In-Place Shift

Instead of separate scroll_buffer, shift directly in back_buffer's off-screen area:
1. Reserve Y=200-233 as scroll row (below visible, in LINEWID extra space)
2. Shift in-place (same memory region as screen)
3. Splat to visible Y positions

This eliminates the scroll_buffer abstraction but requires careful memory layout.

## Recommended Attack Order

### Phase 1: Effect 0 → 1 VBL (THE PRIORITY)
1. ~~**Reduce Type0 to 2 rows** via in-screen scroll-row architecture~~
   ❌ REVERTED — broke effects 1-7. The "row 3 IS the source" trick works
   for effect 0 (which doesn't write to Y=160..193) but `ClearScrollerRegion`
   in effects 1-7 wipes the source, AND multi-row plots overwrite source
   for next frame. Architecture restored to BSS scroll_buffer.
2. Implement glyph LUT (item 3) — low risk, ~1 sl ✅ DONE
3. ScrollShiftAndFill polish: movem groups + hoist a5 ✅ DONE (~2 sl)
4. **Encoded markers in TimerBHandler** ✅ DONE (~17 sl/VBL of work)
   - sign-bit dispatch for swaps + bit-14 for skip
5. **TBDR=2 (Timer-B fire rate halved)** ✅ DONE (~33 sl/VBL of work)
6. Re-profile with HRDB — Timer-B savings (~50 sl) more than cover the
   lost in-screen savings (~22 sl), so Effect 0 should still hit 1 VBL.

### Phase 2: Effects 1-7 → 1-2 VBLs
1. **Blitter for ClearScrollerRegion** — THE BIG WIN (~80 sl!)
2. **Y-offset LUT** — kills per-strip MULU (~3 sl per effect)
3. Re-profile — should be at 2 VBLs now

### Phase 3: Polish
1. movem.l in ScrollShiftAndFill (~1 sl)
2. Unroll byte-shift epilogue (~0.5 sl)
3. Fine-tune any remaining effects

## Timer-B Handler Encoding Scheme (Session 6)

The optimized `TimerBHandler` does NOT use cmpa.l checks for special lines.
Instead, special actions are **encoded as the top nibble of the raster_table
word** itself. The hardware ignores the top 4 bits when writing to color 0,
so we get marker info "for free" alongside the gradient color.

### Encoding

| Top nibble | Action | Bottom 12 bits |
|------------|--------|----------------|
| 0 | Normal write | $RGB color |
| 4 | Skip (no write) | unused |
| 8 | Swap c1 + write | $RGB color |
| 9 | Swap c2 + write | $RGB color |
| A | Swap c3 + write | $RGB color |

### Common Path (no special action)

```asm
TimerBHandler:
    move.l  a0, -(sp)              ; 14
    move.l  d0, -(sp)               ; 14
    move.l  raster_ptr, a0          ; 16
    move.w  (a0)+, d0               ; 12 — sets flags from d0
    bmi.s   .swap                   ; 8 not taken
    btst    #14, d0                 ; 10
    bne.s   .skip                   ; 8 not taken
    move.w  d0, SHIFTER_PALETTE     ; 16
    addq.l  #RASTER_FIRE_STRIDE-2, a0 ; 8 — finish fire-stride advance
    move.l  a0, raster_ptr          ; 16
.exit:
    bclr.b  #0, MFP_ISRA            ; 18
    move.l  (sp)+, d0               ; 12
    move.l  (sp)+, a0               ; 12
    rte                             ; 20
; Total: ~184 cy per common-path fire
```

### Marker Placement

- **Static** (set once in `InstallHBL`): skip range, c3 swap
- **Dynamic** (set in `SetPalettePointers` per-effect): c1, c2 swap. Old
  markers cleared via `and.w #$0FFF, (a0)`; new markers OR'd in.

### TBDR=2 + Phase 1

- TBDR=2 → fires every 2nd visible scanline → 100 fires/frame
- 200 events / 2 = 100, no remainder → phase stable across frames
- First fire at scanline 1, then 3, 5, ..., 199 (odd lines)
- raster_ptr advances by RASTER_FIRE_STRIDE (=4) bytes per fire — reads
  every 2nd entry of the 200-entry gradient table
- Visual: 2-line gradient bands instead of 1-line. Original CONFO.S used
  TBDR=3 for 3-line bands.

### Markers must be at fire-aligned byte offsets (multiples of 4)

| Target line | Fire i | Byte offset | Notes |
|-------------|--------|-------------|-------|
| 77 (c1)     | 38     | 152         | exact |
| 73 (c1 t7)  | 36     | 144         | exact |
| 117 (c2)    | 58     | 232         | was 118 (even, no fire); shift -1 |
| 131 (c2 t4) | 65     | 260         | exact |
| 121 (c2 t7) | 60     | 240         | exact |
| 159 (c3)    | 79     | 316         | exact (preserves color via OR) |
| 107, 109, 111 (skip) | 53, 54, 55 | 212, 216, 220 | 3 fires in bus-collision range |

## Reference: 68000 Cycle Counts

| Instruction | Cycles | Notes |
|-------------|--------|-------|
| `mulu.w #imm, Dn` | 70 | The killer |
| `muls.w #imm, Dn` | 70 | Signed version |
| `divu.w #imm, Dn` | 140 | Even worse |
| `move.l (An)+, (An)+` | 20 | Memory to memory |
| `movem.l (An)+, regs` | 12 + 8n | n = register count |
| `movem.l regs, (An)` | 8 + 8n | n = register count |
| `lsl.w #n, Dn` | 6 + 2n | Fast shift |
| `lea d16(An), An` | 8 | Address calc |
| `dbra Dn, label` | 10/14 | Taken/not taken |

## Session Notes

- HRDB confirmed timing: effect 0 = 2-3 VBLs, effects 1-7 = 4-6 VBLs
- Original CONFO.S achieves <1 VBL for all effects
- **KEY FINDING:** Original CONFO.S never writes 3 rows — always 1-2 rows
- Our Type0/Type7 write 3 rows = 50% more data = why we're slow
- Memory is cheap — burn it for speed (LUTs over multiply)
- Shifter contention ~1.5× during visible display

## Reference: Original CONFO.S Architecture

```
deb_blk = phys + deca    ; scroll row lives at Y=210 (off-screen in video RAM)
scrolg:  shift deb_blk left by 8 bytes (REPT 38 move.l, in video RAM)
scroh:   copy deb_blk to 2 visible Y positions (per-strip, 34 lines each)
swap:    flip phys between $30000 and $40000
```

The scroll row is IN the screen buffer but below visible area.
No separate off-screen buffer. Shift + splat, both in video RAM.

Original type1 inner loop (key optimization — vertical doubling by source rewind):
```asm
REPT 36
    move.l  a0,a4           ; save source
    move.l  (a0)+,(a1)+     ; 8 bytes to dest line N
    move.l  (a0)+,(a1)+
    move.l  a4,a0           ; REWIND source
    add.w   #160-8,a1       ; next dest line
    move.l  (a0)+,(a1)+     ; SAME 8 bytes to dest line N+1 (vertical double!)
    move.l  (a0)+,(a1)+
    add.w   #160-8,a0       ; next source line
    add.w   #160-8,a1
endr
```

This writes 2 screen lines from 1 source line = 2× vertical zoom for free.
