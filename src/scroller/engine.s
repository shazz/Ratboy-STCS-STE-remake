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
; ScrollerInit — clear scroll_buffer, reset cursor + word state + effect.
; ----------------------------------------------------------------------------
ScrollerInit:
                    clr.w       scroll_word_in_char
                    lea         scrolltext_S1, a0
                    move.l      a0, scroll_text_cursor

                    ; Initialize effect state
                    move.w      #SCROLL_EFFECT_DEFAULT, scroll_effect_type
                    clr.w       sine_frame_count
                    move.w      #1, sine_direction      ; start moving down
                    clr.w       sine_offset

                    lea         scroll_buffer, a0
                    move.w      #(SCROLL_BUFFER_BYTES/4)-1, d0
                    moveq       #0, d1
.clr:
                    move.l      d1, (a0)+
                    dbra        d0, .clr
                    rts

; ----------------------------------------------------------------------------
; ScrollerStepVblank — full per-VBL pipeline. Called from MainLoop.
;
; Pipeline: render new pword → shift buffer left → plot via current effect.
; ----------------------------------------------------------------------------
ScrollerStepVblank:
                    bsr         ScrollRenderNextPword
                    bsr         ScrollShift
                    bsr         ScrollPlotDispatch
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

; ============================================================================
; EFFECT DISPATCHER — routes to the current effect's plot routine
; ============================================================================
; scroll_effect_type selects which visual effect to use:
;   0 = 3 fixed rows (default, current behavior)
;   7 = sine wave (single row with vertical wobble)
;
; To test effects: change scroll_effect_type in BSS or add runtime switching.
; ============================================================================

ScrollPlotDispatch:
                    move.w      scroll_effect_type, d0
                    beq         ScrollPlotType0         ; type 0 = 3 fixed rows
                    cmp.w       #7, d0
                    beq         ScrollPlotType7         ; type 7 = sine wave
                    ; Default fallback to type 0
                    bra         ScrollPlotType0

; ----------------------------------------------------------------------------
; ScrollPlotType0 — 3-row fixed plot (original behavior)
; Copies buffer[0..19] to all 3 screen rows at fixed Y positions.
; ----------------------------------------------------------------------------
ScrollPlotType0:
                    lea         scroll_buffer, a0
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
                    addq.l      #8, a0                  ; buffer stride = 168, read 160
                    lea         24(a2), a2              ; screen stride = 184, wrote 160
                    lea         24(a3), a3
                    lea         24(a4), a4
                    dbra        d7, .line
                    rts

; ----------------------------------------------------------------------------
; ScrollPlotType7 — Sine wave scroller (matches original CONFO.S type7)
;
; Uses a staircase Y-offset pattern across 20 strips (like original):
;   Strips 0-5:   go DOWN 2 lines per strip
;   Strip 6:      flat
;   Strips 7-13:  go UP 2 lines per strip
;   Strip 14:     flat
;   Strips 15-19: go DOWN 2 lines per strip
;
; Plus a slow vertical bob (sine_offset) that oscillates every 49 frames.
; ----------------------------------------------------------------------------
ScrollPlotType7:
                    ; Update slow vertical bob every 49 frames
                    addq.w      #1, sine_frame_count
                    cmp.w       #49, sine_frame_count
                    blt.s       .no_bob_change
                    clr.w       sine_frame_count
                    neg.w       sine_direction          ; flip direction
.no_bob_change:
                    move.w      sine_direction, d0
                    add.w       d0, sine_offset         ; bob up or down 1 line/frame

                    ; Clamp sine_offset to reasonable range (-20 to +20)
                    cmp.w       #20, sine_offset
                    ble.s       .not_too_high
                    move.w      #20, sine_offset
.not_too_high:
                    cmp.w       #-20, sine_offset
                    bge.s       .not_too_low
                    move.w      #-20, sine_offset
.not_too_low:

                    move.l      back_buffer_ptr, a5
                    lea         scroll_buffer, a2

                    ; Base Y position + current bob offset
                    move.w      #SCROLL_Y_2, d3
                    add.w       sine_offset, d3         ; d3 = base Y for this frame

                    ; Plot 20 strips, accumulating Y offset per strip
                    moveq       #0, d5                  ; cumulative Y offset (in lines)
                    moveq       #19, d6                 ; strip counter (19 down to 0)

.strip:
                    ; Calculate staircase offset based on strip number
                    ; Strip index = 19 - d6 (so 0,1,2...19)
                    move.w      #19, d0
                    sub.w       d6, d0                  ; d0 = strip index 0-19

                    ; Staircase pattern (matching original type7):
                    cmp.w       #6, d0
                    beq.s       .flat1
                    cmp.w       #14, d0
                    beq.s       .flat2
                    cmp.w       #6, d0
                    bhi.s       .check_mid
                    ; Strips 0-5: go down (1 line per strip = gentler wave)
                    addq.w      #1, d5
                    bra.s       .do_plot
.check_mid:
                    cmp.w       #14, d0
                    bhi.s       .go_down
                    ; Strips 7-13: go up
                    subq.w      #1, d5
                    bra.s       .do_plot
.go_down:
                    ; Strips 15-19: go down
                    addq.w      #1, d5
.flat1:
.flat2:
                    ; Strips 6 and 14: stay flat (no Y change)
.do_plot:
                    ; Calculate final Y = base + cumulative offset
                    move.w      d3, d2
                    add.w       d5, d2
                    mulu.w      #SCREEN_LINE_BYTES, d2  ; d2 = Y byte offset

                    ; Buffer source for this strip (pword column)
                    move.w      #19, d0
                    sub.w       d6, d0
                    lsl.w       #3, d0                  ; * 8 bytes
                    lea         0(a2,d0.w), a0          ; a0 = buffer column

                    ; Screen dest
                    move.l      a5, a1
                    adda.l      d2, a1
                    adda.w      d0, a1                  ; a1 = screen column

                    ; Copy 34 scanlines of this pword column
                    move.w      #SCROLL_HEIGHT-1, d4
.scanline:
                    move.l      (a0), (a1)
                    move.l      4(a0), 4(a1)
                    lea         SCROLL_BUFFER_LINE_BYTES(a0), a0
                    lea         SCREEN_LINE_BYTES(a1), a1
                    dbra        d4, .scanline

                    dbra        d6, .strip
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

scroll_effect_type:   ds.w      1       ; 0=3-row fixed, 7=sine wave
sine_frame_count:     ds.w      1       ; frames since last bob direction change
sine_direction:       ds.w      1       ; +1 or -1 for bob direction
sine_offset:          ds.w      1       ; current vertical bob offset (scanlines)

                    section     TEXT
