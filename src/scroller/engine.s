; ----------------------------------------------------------------------------
; scroller/engine.s — Strategy E: integrated CPU shift + 3-way fan-out plot
; ----------------------------------------------------------------------------
; Session 3 (2026-04-25) second rewrite. Option F (4 HOG blits per VBL)
; structurally worked but the visible-time blits collided with Shifter bus
; contention (~12 cy/word in visible vs 8 cy/word in invisible), so HOG ran
; ~210 sl, ending around scanline 120 — far past the line-77 palette swap.
;
; Strategy E removes the blitter from the per-VBL hot path entirely. One CPU
; pass per scanline does both the buffer-shift AND the splat to all 3 screen
; rows. Cost is bounded (~135 sl pure CPU work, ~170 sl wallclock with
; Shifter contention + Timer-B ISR overhead) and — critically — CPU is
; interruptible, so Timer-B continues to fire one ISR per scanline. Gradient
; color 0 and the line-77 palette swap fire on time, no fix-up needed.
;
; This is also the architecture the 1988 STF original uses (CPU shift + CPU
; splat to multiple Y positions) — see WRITE_UP.md Lesson 1.
;
; Per-VBL pipeline:
;   1. ScrollRenderNextPword   — write next 8-byte glyph slice → buffer[pword 20]
;   2. ScrollShiftAndPlot      — read buffer[pword 1..20] one scanline at a time,
;                                 write to buffer[pword 0..19] (= shift) +
;                                 screen row 1, 2, 3 (= splat) simultaneously
;
; Buffer layout (off-screen, 21 pwords × 34 lines = 5712 bytes):
;
;     pword 0  1  2  ... 19  20
;            visible            staging
;            ↑                  ↑
;            copied to screen   render writes here each VBL
;
; Each VBL the staging slot (pword 20) gets a fresh glyph slice from CPU,
; then the integrated read-once-write-four pass migrates it left into the
; visible region while simultaneously laying the visible region into all
; three on-screen row positions. Net: the same scrolling text appears at
; SCROLL_Y_1, SCROLL_Y_2, SCROLL_Y_3 every frame.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
; ScrollerInit — clear scroll_buffer, reset cursor + word state.
; ----------------------------------------------------------------------------
ScrollerInit:
                    clr.w       scroll_word_in_char
                    lea         scrolltext_S1, a0
                    move.l      a0, scroll_text_cursor

                    lea         scroll_buffer, a0
                    move.w      #(SCROLL_BUFFER_BYTES/4)-1, d0
                    moveq       #0, d1
.clr:
                    move.l      d1, (a0)+
                    dbra        d0, .clr
                    rts

; ----------------------------------------------------------------------------
; ScrollerStepVblank — full per-VBL pipeline. Runs in VBL handler.
;
; Reverted to integrated shift+plot (~135 sl pure) — the split version made
; the glitch worse because total work grew from 135 to 162 sl, widening the
; race window. The split routines are kept below for reference.
; ----------------------------------------------------------------------------
ScrollerStepVblank:
                    bsr         ScrollRenderNextPword
                    bsr         ScrollShiftAndPlot
                    rts

; ----------------------------------------------------------------------------
; ScrollRenderNextPword — write the next 1/3 (8 bytes / 16 pixels) of the
; current glyph into pword 20 of scroll_buffer (rightmost staging slot).
;
; scroll_word_in_char cycles 0..2 across calls:
;   0 — pull next char from scrolltext, compute glyph base, render pword 0
;   1 — render pword 1 of cached glyph
;   2 — render pword 2 of cached glyph, reset to 0 next call
; ----------------------------------------------------------------------------
ScrollRenderNextPword:
                    move.w      scroll_word_in_char, d0
                    bne.s       .not_new_char

                    move.l      scroll_text_cursor, a0
                    move.b      (a0)+, d1
                    bne.s       .got_char
                    lea         scrolltext_S1, a0
                    move.b      (a0)+, d1
.got_char:
                    move.l      a0, scroll_text_cursor

                    and.w       #$00FF, d1
                    sub.w       #FONT_FIRST_ASCII, d1
                    bpl.s       .range_ok
                    moveq       #0, d1
.range_ok:
                    cmp.w       #63, d1
                    ble.s       .in_range
                    moveq       #0, d1
.in_range:
                    mulu.w      #FONT_GLYPH_BYTES, d1
                    lea         font_bitmap, a0
                    adda.l      d1, a0
                    move.l      a0, scroll_glyph_ptr
                    moveq       #0, d2
                    bra.s       .do_render

.not_new_char:
                    move.l      scroll_glyph_ptr, a0
                    move.w      d0, d2
                    lsl.w       #3, d2                          ; pword index × 8 bytes

.do_render:
                    adda.w      d2, a0                          ; a0 = glyph row 0, pword d0
                    lea         scroll_buffer+SCROLL_BUFFER_RIGHT_OFFS, a2

                    move.w      #SCROLL_HEIGHT-1, d0
.line:
                    move.l      (a0), (a2)                      ; planes 0,1
                    move.l      4(a0), 4(a2)                    ; planes 2,3
                    lea         FONT_GLYPH_LINE_B(a0), a0       ; glyph stride (24 bytes)
                    lea         SCROLL_BUFFER_LINE_BYTES(a2), a2
                    dbra        d0, .line

                    addq.w      #1, scroll_word_in_char
                    cmp.w       #FONT_GLYPH_PWORDS, scroll_word_in_char
                    blt.s       .done
                    clr.w       scroll_word_in_char
.done:
                    rts

; ----------------------------------------------------------------------------
; ScrollShift — buffer-only shift (pword 1..20 → 0..19) per scanline.
; Pure CPU. ~54 sl wallclock. Independent of screen plot.
; ----------------------------------------------------------------------------
ScrollShift:
                    lea         scroll_buffer+PWORD_BYTES, a0   ; src = pword 1
                    lea         scroll_buffer, a1                ; dst = pword 0
                    move.w      #SCROLL_HEIGHT-1, d7
.line:
                    rept        5
                    movem.l     (a0)+, d0-d6/a6
                    movem.l     d0-d6/a6, (a1)
                    lea         32(a1), a1
                    endr
                    addq.l      #8, a0
                    addq.l      #8, a1
                    dbra        d7, .line
                    rts

; ----------------------------------------------------------------------------
; ScrollPlot — copy buffer pword 0..19 to all 3 screen rows of back buffer.
; 3-way fan-out CPU. ~108 sl wallclock.
; ----------------------------------------------------------------------------
ScrollPlot:
                    lea         scroll_buffer, a0                ; src = pword 0
                    move.l      back_buffer_ptr, a5
                    lea         (SCROLL_Y_1*SCREEN_LINE_BYTES)(a5), a2
                    lea         (SCROLL_Y_2*SCREEN_LINE_BYTES)(a5), a3
                    lea         (SCROLL_Y_3*SCREEN_LINE_BYTES)(a5), a4
                    move.w      #SCROLL_HEIGHT-1, d7
.line:
                    rept        5
                    movem.l     (a0)+, d0-d6/a6
                    movem.l     d0-d6/a6, (a2)
                    lea         32(a2), a2
                    movem.l     d0-d6/a6, (a3)
                    lea         32(a3), a3
                    movem.l     d0-d6/a6, (a4)
                    lea         32(a4), a4
                    endr
                    addq.l      #8, a0                           ; buffer stride 168, read 160
                    lea         24(a2), a2                       ; screen stride 184, wrote 160
                    lea         24(a3), a3
                    lea         24(a4), a4
                    dbra        d7, .line
                    rts

; ----------------------------------------------------------------------------
; ScrollShiftAndPlot — integrated CPU shift + 3-way fan-out plot.
; (Kept for reference. Currently unused; ScrollerStepVblank calls the split
; ScrollShift + ScrollPlot pair.)
;
; Per scanline: read 8 longs (16 words = 2 pwords) from buffer[pword 1..]
; via movem.l with auto-increment, then write the same 8 longs to four
; destinations (buffer-shift dst, screen row 1, row 2, row 3). 5 such
; chunks cover the 80 words / 20 pwords / 160 bytes of the visible row
; width. After 34 scanlines the entire row is shifted-in-buffer AND
; splatted to all three on-screen rows.
;
; Register allocation:
;   a0 = src   (scroll_buffer + pword 1, auto-incremented by movem read)
;   a1 = dst-shift (scroll_buffer + pword 0; bumped manually)
;   a2 = screen row 1 dst (bumped manually)
;   a3 = screen row 2 dst
;   a4 = screen row 3 dst
;   a5 = scratch (used during pointer setup)
;   a6 = movem payload (8th long of each transfer)
;   d0-d6 = movem payload (longs 1..7)
;   d7 = scanline loop counter (kept out of the movem range)
;
; The choice of d0-d6/a6 instead of d0-d7 lets us use d7 for `dbra` without
; needing stack juggling each iteration. Both register groups give the same
; movem.l timing (8 longs = 76 cy read / 72 cy write).
;
; Per-scanline cost: 5 × (76 + 4×(72+8)) + 5×8 + 14 ≈ 2034 cy. × 34 lines
; ≈ 69 Kcy ≈ 135 sl pure rate. With Shifter bus contention (~30%) and one
; ~150-cy Timer-B ISR per visible scanline of work, expect ~165-175 sl
; wallclock. Plot starts after render (sl ~22) so ends around sl ~190 =
; visible line ~78. Plot writes scanlines in order, so row 1 line 0 (=
; screen line 78) is written first, well before Shifter fetches it at
; sl 191. Margin to row 1's last line (sl 224) is ~40 sl — comfortable.
; ----------------------------------------------------------------------------
ScrollShiftAndPlot:
                    lea         scroll_buffer+PWORD_BYTES, a0   ; src = pword 1
                    lea         scroll_buffer, a1                ; dst (shift) = pword 0
                    move.l      back_buffer_ptr, a5              ; off-display buffer
                    lea         (SCROLL_Y_1*SCREEN_LINE_BYTES)(a5), a2
                    lea         (SCROLL_Y_2*SCREEN_LINE_BYTES)(a5), a3
                    lea         (SCROLL_Y_3*SCREEN_LINE_BYTES)(a5), a4

                    move.w      #SCROLL_HEIGHT-1, d7
.line:
                    rept        5
                    movem.l     (a0)+, d0-d6/a6
                    movem.l     d0-d6/a6, (a1)
                    lea         32(a1), a1
                    movem.l     d0-d6/a6, (a2)
                    lea         32(a2), a2
                    movem.l     d0-d6/a6, (a3)
                    lea         32(a3), a3
                    movem.l     d0-d6/a6, (a4)
                    lea         32(a4), a4
                    endr

                    addq.l      #8, a0
                    addq.l      #8, a1
                    lea         24(a2), a2
                    lea         24(a3), a3
                    lea         24(a4), a4

                    dbra        d7, .line
                    rts

; ----------------------------------------------------------------------------
; BSS
; ----------------------------------------------------------------------------
                    section     BSS

                    even
scroll_buffer:        ds.b      SCROLL_BUFFER_BYTES

scroll_word_in_char:  ds.w      1
scroll_text_cursor:   ds.l      1
scroll_glyph_ptr:     ds.l      1

                    section     TEXT
