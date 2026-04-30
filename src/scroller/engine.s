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
                    clr.w       scroll_render_phase
                    lea         scrolltext_S1, a0
                    move.l      a0, scroll_text_cursor

                    ; Initialize effect state
                    move.w      #SCROLL_EFFECT_DEFAULT, scroll_effect_type
                    move.w      #SCROLL_EFFECT_DEFAULT, d0
                    bsr         SetPalettePointers      ; set palette ptrs based on effect
                    bsr         SetScrollSpeedExtra     ; set 2x speed flag based on effect
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
; Some effects (1, 2, 7) need 2× horizontal speed to match the original —
; for those, render+shift runs twice before plot.
; ----------------------------------------------------------------------------
ScrollerStepVblank:
                    bsr         ScrollRenderNextPword
                    bsr         ScrollShift
                    tst.w       scroll_speed_extra
                    beq.s       .plot
                    bsr         ScrollRenderNextPword
                    bsr         ScrollShift
.plot:
                    bsr         ScrollPlotDispatch
                    rts

; ----------------------------------------------------------------------------
; ScrollRenderNextPword — write 16 pixels into pword 20 of scroll_buffer.
;
; For 40px glyphs with 0px spacing, we use a 5-phase cycle per 2 characters:
;   Phase 0: pword 0 of char A (pixels 0-15) — direct copy
;   Phase 1: pword 1 of char A (pixels 16-31) — direct copy
;   Phase 2: A[32-39] + B[0-7] — blend high bytes of A_pw2 and B_pw0
;   Phase 3: B[8-23] — blend low byte B_pw0 + high byte B_pw1
;   Phase 4: B[24-39] — blend low byte B_pw1 + high byte B_pw2
;   Then char B becomes new "current" and we repeat from phase 0 for C.
;
; Blending: (src_word << 8) | (src_word >> 8) shifts left/right halves.
; ----------------------------------------------------------------------------
ScrollRenderNextPword:
                    move.w      scroll_render_phase, d0
                    cmp.w       #2, d0
                    bhs.s       .phase_2_plus

                    ; --- Phase 0 or 1: direct copy from current glyph ---
                    tst.w       d0
                    bne.s       .phase1
                    ; Phase 0: fetch new current char
                    bsr         .fetch_next_char
                    move.l      a0, scroll_curr_glyph
.phase1:
                    move.l      scroll_curr_glyph, a0
                    move.w      scroll_render_phase, d2
                    lsl.w       #3, d2                          ; pword index × 8 bytes
                    adda.w      d2, a0
                    bsr         .copy_pword
                    addq.w      #1, scroll_render_phase
                    rts

.phase_2_plus:
                    cmp.w       #2, d0
                    bne.s       .phase_3_4

                    ; --- Phase 2: blend curr[pw2] high + next[pw0] high ---
                    bsr         .fetch_next_char
                    move.l      a0, scroll_next_glyph
                    move.l      scroll_curr_glyph, a0
                    lea         16(a0), a0                      ; curr pword 2
                    move.l      scroll_next_glyph, a1           ; next pword 0
                    bsr         .blend_high_high
                    addq.w      #1, scroll_render_phase
                    rts

.phase_3_4:
                    cmp.w       #3, d0
                    bne.s       .phase_4

                    ; --- Phase 3: blend next[pw0] low + next[pw1] high ---
                    move.l      scroll_next_glyph, a0           ; next pword 0
                    lea         8(a0), a1                       ; next pword 1
                    bsr         .blend_low_high
                    addq.w      #1, scroll_render_phase
                    rts

.phase_4:
                    ; --- Phase 4: blend next[pw1] low + next[pw2] high ---
                    move.l      scroll_next_glyph, a0
                    lea         8(a0), a0                       ; next pword 1
                    lea         8(a0), a1                       ; next pword 2
                    bsr         .blend_low_high
                    ; Cycle complete: next becomes current, reset phase
                    move.l      scroll_next_glyph, scroll_curr_glyph
                    clr.w       scroll_render_phase
                    rts

; --- .fetch_next_char: read next char from text, return glyph ptr in a0 ---
.fetch_next_char:
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
                    rts

; --- .copy_pword: direct copy 34 lines from a0 to scroll_buffer staging ---
.copy_pword:
                    lea         scroll_buffer+SCROLL_BUFFER_RIGHT_OFFS, a2
                    move.w      #SCROLL_HEIGHT-1, d7
.copy_line:
                    move.l      (a0), (a2)
                    move.l      4(a0), 4(a2)
                    lea         FONT_GLYPH_LINE_B(a0), a0
                    lea         SCROLL_BUFFER_LINE_BYTES(a2), a2
                    dbra        d7, .copy_line
                    rts

; --- .blend_high_high: left 8px from a0, right 8px from a1 (both high bytes) ---
; a0 = source pword A, a1 = source pword B
; Output: (A & $FF00) | ((B >> 8) & $00FF) for each plane word
.blend_high_high:
                    lea         scroll_buffer+SCROLL_BUFFER_RIGHT_OFFS, a2
                    move.w      #SCROLL_HEIGHT-1, d7
.bhh_line:
                    ; Plane 0
                    move.w      (a0), d0
                    and.w       #$FF00, d0
                    move.w      (a1), d1
                    lsr.w       #8, d1
                    or.w        d1, d0
                    move.w      d0, (a2)
                    ; Plane 1
                    move.w      2(a0), d0
                    and.w       #$FF00, d0
                    move.w      2(a1), d1
                    lsr.w       #8, d1
                    or.w        d1, d0
                    move.w      d0, 2(a2)
                    ; Plane 2
                    move.w      4(a0), d0
                    and.w       #$FF00, d0
                    move.w      4(a1), d1
                    lsr.w       #8, d1
                    or.w        d1, d0
                    move.w      d0, 4(a2)
                    ; Plane 3
                    move.w      6(a0), d0
                    and.w       #$FF00, d0
                    move.w      6(a1), d1
                    lsr.w       #8, d1
                    or.w        d1, d0
                    move.w      d0, 6(a2)
                    lea         FONT_GLYPH_LINE_B(a0), a0
                    lea         FONT_GLYPH_LINE_B(a1), a1
                    lea         SCROLL_BUFFER_LINE_BYTES(a2), a2
                    dbra        d7, .bhh_line
                    rts

; --- .blend_low_high: left 8px from a0 low byte, right 8px from a1 high byte ---
; Output: ((A << 8) & $FF00) | ((B >> 8) & $00FF) for each plane word
.blend_low_high:
                    lea         scroll_buffer+SCROLL_BUFFER_RIGHT_OFFS, a2
                    move.w      #SCROLL_HEIGHT-1, d7
.blh_line:
                    ; Plane 0
                    move.w      (a0), d0
                    lsl.w       #8, d0
                    move.w      (a1), d1
                    lsr.w       #8, d1
                    or.w        d1, d0
                    move.w      d0, (a2)
                    ; Plane 1
                    move.w      2(a0), d0
                    lsl.w       #8, d0
                    move.w      2(a1), d1
                    lsr.w       #8, d1
                    or.w        d1, d0
                    move.w      d0, 2(a2)
                    ; Plane 2
                    move.w      4(a0), d0
                    lsl.w       #8, d0
                    move.w      4(a1), d1
                    lsr.w       #8, d1
                    or.w        d1, d0
                    move.w      d0, 4(a2)
                    ; Plane 3
                    move.w      6(a0), d0
                    lsl.w       #8, d0
                    move.w      6(a1), d1
                    lsr.w       #8, d1
                    or.w        d1, d0
                    move.w      d0, 6(a2)
                    lea         FONT_GLYPH_LINE_B(a0), a0
                    lea         FONT_GLYPH_LINE_B(a1), a1
                    lea         SCROLL_BUFFER_LINE_BYTES(a2), a2
                    dbra        d7, .blh_line
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
; SetScrollSpeedExtra — choose 2x horizontal scroll for effects that need it.
; Effects 1, 2, 7 match the original at 2 pwords/VBL; others run 1 pword/VBL.
; In:  d0 = effect type
; Out: scroll_speed_extra = 0 (default speed) or 1 (extra render+shift per VBL)
; ----------------------------------------------------------------------------
SetScrollSpeedExtra:
                    cmp.w       #1, d0
                    beq.s       .fast
                    cmp.w       #2, d0
                    beq.s       .fast
                    ; Future: cmp.w #7, d0 — enable when type 7 is tuned.
                    clr.w       scroll_speed_extra
                    rts
.fast:
                    move.w      #1, scroll_speed_extra
                    rts

; ============================================================================
; EFFECT DISPATCHER — routes to the current effect's plot routine
; ============================================================================
; scroll_effect_type selects which visual effect to use:
;   0 = 3 fixed rows (default)
;   1 = 2-row, vertically doubled (2× tall), sine bob
;   7 = sine wave (single row with vertical wobble)
;
; To test effects: change SCROLL_EFFECT_DEFAULT in constants.s
; ============================================================================

ScrollPlotDispatch:
                    move.w      scroll_effect_type, d0
                    beq         ScrollPlotType0         ; type 0 = 3 fixed rows
                    cmp.w       #1, d0
                    beq         ScrollPlotType1         ; type 1 = 2× tall + sine
                    cmp.w       #2, d0
                    beq         ScrollPlotType2         ; type 2 = anti-symmetric
                    cmp.w       #3, d0
                    beq         ScrollPlotType3         ; type 3 = diagonal same dir
                    cmp.w       #4, d0
                    beq         ScrollPlotType4         ; type 4 = 4× tall spread
                    cmp.w       #5, d0
                    beq         ScrollPlotType5         ; type 5 = converging diagonal
                    cmp.w       #6, d0
                    beq         ScrollPlotType6         ; type 6 = 2 fixed rows
                    cmp.w       #7, d0
                    beq         ScrollPlotType7         ; type 7 = sine wave
                    bra         ScrollPlotType0         ; fallback

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
; ScrollPlotType1 — Single row, vertically doubled (2× tall), sine bob
;
; Each source scanline is written TWICE to consecutive dest lines = 2× zoom.
; Single row centered on screen with staircase sine wave offset.
; 34 source lines → 68 dest lines, positioned to avoid screen bounds.
; ----------------------------------------------------------------------------
TYPE1_ROW_Y         equ     100                     ; centered, leaves room for 68-line height

ScrollPlotType1:
                    ; Clear scroller region to avoid artifacts from sine movement
                    bsr         ClearScrollerRegion

                    ; Trajectory sine via LUT, driven by REAL VBL count so the
                    ; rate is independent of how many VBLs MainLoop work spans.
                    ; 50 frames per half-cycle = 1 second top-to-bottom at 50 Hz.
                    move.w      vbl_counter, d0
                    move.w      type1_prev_vbl, d1
                    move.w      d0, type1_prev_vbl
                    sub.w       d1, d0                  ; d0 = VBLs since last call
                    add.w       d0, sine_frame_count
.wrap_check:
                    cmp.w       #50, sine_frame_count
                    blt.s       .no_flip
                    sub.w       #50, sine_frame_count
                    neg.w       sine_direction
                    bra.s       .wrap_check
.no_flip:
                    move.w      sine_frame_count, d0
                    add.w       d0, d0                  ; word index
                    lea         type1_traj_lut, a3
                    move.w      0(a3,d0.w), d1          ; LUT value (0..20)
                    move.w      sine_direction, d0
                    muls.w      d1, d0
                    move.w      d0, sine_offset

                    move.l      back_buffer_ptr, a5
                    lea         scroll_buffer, a2

                    ; Base Y + bob offset
                    move.w      #TYPE1_ROW_Y, d3
                    add.w       sine_offset, d3

                    ; Plot 20 strips: per-strip Y offset from LUT (4 sine cycles)
                    moveq       #19, d6                 ; strip counter

.strip:
                    ; Inside sine: 4 cycles across 20 strips via LUT (period 5, amp ±3)
                    move.w      #19, d0
                    sub.w       d6, d0                  ; d0 = strip index 0-19
                    move.w      d0, d2
                    add.w       d2, d2                  ; * 2 (word index)
                    lea         type1_inside_lut, a3
                    move.w      0(a3,d2.w), d5          ; d5 = absolute Y offset for this strip

                    ; Calculate Y = base + per-strip offset
                    move.w      d3, d2
                    add.w       d5, d2
                    mulu.w      #SCREEN_LINE_BYTES, d2

                    ; Buffer source for this strip
                    lsl.w       #3, d0                  ; * 8 bytes per pword
                    lea         0(a2,d0.w), a0

                    ; Screen dest
                    move.l      a5, a1
                    adda.l      d2, a1
                    adda.w      d0, a1

                    ; Copy 34 source lines → 68 dest lines (2× vertical)
                    move.w      #SCROLL_HEIGHT-1, d4
.scanline:
                    move.l      (a0), d0                ; planes 0,1
                    move.l      4(a0), d1               ; planes 2,3

                    ; Write line N
                    move.l      d0, (a1)
                    move.l      d1, 4(a1)
                    ; Write line N+1 (vertical double)
                    move.l      d0, SCREEN_LINE_BYTES(a1)
                    move.l      d1, SCREEN_LINE_BYTES+4(a1)

                    ; Advance: source +1 line, dest +2 lines
                    lea         SCROLL_BUFFER_LINE_BYTES(a0), a0
                    lea         SCREEN_LINE_BYTES*2(a1), a1
                    dbra        d4, .scanline

                    dbra        d6, .strip
                    rts

; ----------------------------------------------------------------------------
; ScrollPlotType2 — Water reflection effect
;
; Scroller with diagonal (down from right to left) + mirrored reflection below.
; Simplified: plot row 1 normally, then reflection with backward source read.
; ----------------------------------------------------------------------------
TYPE2_BASE_Y        equ     78                      ; row 1 Y at right edge (after palette swap)
TYPE2_REFLECT_GAP   equ     6                       ; gap (lines) between row 1 and reflection

ScrollPlotType2:
                    bsr         ClearScrollerRegion

                    move.l      back_buffer_ptr, a5
                    lea         scroll_buffer, a2

                    moveq       #19, d6                 ; strip counter

.strip:
                    ; X offset = (19 - d6) * 8
                    move.w      #19, d0
                    sub.w       d6, d0
                    move.w      d0, d3
                    lsl.w       #3, d3

                    ; Buffer source
                    lea         0(a2,d3.w), a0

                    ; Row 1 Y = base + d6/2 (left=high Y, right=low Y = down from right to left)
                    ; Halved slope to fit reflection on screen
                    move.w      d6, d7
                    lsr.w       #1, d7                  ; d7 = d6/2 (0..9)
                    move.w      #TYPE2_BASE_Y, d2
                    add.w       d7, d2
                    mulu.w      #SCREEN_LINE_BYTES, d2
                    move.l      a5, a1
                    adda.l      d2, a1
                    adda.w      d3, a1

                    ; Plot 34 lines for row 1
                    move.l      a0, a4                  ; save source ptr
                    move.w      #SCROLL_HEIGHT-1, d4
.row1_line:
                    move.l      (a0), (a1)
                    move.l      4(a0), 4(a1)
                    lea         SCROLL_BUFFER_LINE_BYTES(a0), a0
                    lea         SCREEN_LINE_BYTES(a1), a1
                    dbra        d4, .row1_line

                    ; Reflection: start below row 1, read source backward, write doubled
                    ; a1 is now at row 1 bottom + 1 line, add gap
                    lea         TYPE2_REFLECT_GAP*SCREEN_LINE_BYTES(a1), a1

                    ; Point source to last line
                    move.l      a4, a0
                    adda.l      #(SCROLL_HEIGHT-1)*SCROLL_BUFFER_LINE_BYTES, a0

                    ; Plot reflection: 34 source lines, each single with 1-line gap (interleaved)
                    move.w      #SCROLL_HEIGHT-1, d4
.reflect_line:
                    move.l      (a0), d0
                    move.l      4(a0), d1
                    ; Write single line
                    move.l      d0, (a1)
                    move.l      d1, 4(a1)

                    lea         -SCROLL_BUFFER_LINE_BYTES(a0), a0    ; backward through source
                    lea         SCREEN_LINE_BYTES*2(a1), a1          ; 1 written + 1 gap
                    dbra        d4, .reflect_line

                    dbra        d6, .strip
                    rts

; ----------------------------------------------------------------------------
; ScrollPlotType3 — Sine wave + 1-line interleave + frame clearing
;
; Same staircase + slow vertical bob as the classic sine scroller, but each
; source scanline is plotted with a 1-line gap below it: 34 source lines
; occupy 68 dest lines, every other line cleared. Clears the scroller
; region each frame (via ClearScrollerRegion) to avoid trails.
;
; Staircase Y-offset across 20 strips:
;   Strips 0-5:   down 1 line per strip
;   Strip 6:      flat
;   Strips 7-13:  up 1 line per strip
;   Strip 14:     flat
;   Strips 15-19: down 1 line per strip
; Slow vertical bob (sine_offset) flips direction every 49 frames.
; ----------------------------------------------------------------------------
TYPE3_ROW_Y         equ     100                     ; centered for 68-line interleaved height

ScrollPlotType3:
                    bsr         ClearScrollerRegion

                    ; Trajectory sine via LUT, driven by REAL VBL count — same
                    ; mechanism as Type 1: 50 frames per half-cycle = 1 second
                    ; top-to-bottom at 50 Hz, robust to MainLoop VBL slippage.
                    move.w      vbl_counter, d0
                    move.w      type1_prev_vbl, d1
                    move.w      d0, type1_prev_vbl
                    sub.w       d1, d0
                    add.w       d0, sine_frame_count
.wrap_check:
                    cmp.w       #50, sine_frame_count
                    blt.s       .no_flip
                    sub.w       #50, sine_frame_count
                    neg.w       sine_direction
                    bra.s       .wrap_check
.no_flip:
                    move.w      sine_frame_count, d0
                    add.w       d0, d0
                    lea         type1_traj_lut, a3
                    move.w      0(a3,d0.w), d1
                    move.w      sine_direction, d0
                    muls.w      d1, d0
                    move.w      d0, sine_offset

                    move.l      back_buffer_ptr, a5
                    lea         scroll_buffer, a2

                    move.w      #TYPE3_ROW_Y, d3
                    add.w       sine_offset, d3         ; d3 = base Y this frame

                    moveq       #19, d6                 ; strip counter

.strip:
                    ; Inside sine via LUT — same table as Type 1 (2 sine
                    ; cycles across 20 strips, amplitude ±3 lines).
                    move.w      #19, d0
                    sub.w       d6, d0                  ; d0 = strip index 0-19
                    move.w      d0, d2
                    add.w       d2, d2                  ; * 2 (word index)
                    lea         type1_inside_lut, a3
                    move.w      0(a3,d2.w), d5          ; d5 = per-strip Y offset

                    move.w      d3, d2
                    add.w       d5, d2
                    mulu.w      #SCREEN_LINE_BYTES, d2

                    lsl.w       #3, d0                  ; * 8 bytes per pword
                    lea         0(a2,d0.w), a0          ; buffer column

                    move.l      a5, a1
                    adda.l      d2, a1
                    adda.w      d0, a1                  ; screen column

                    ; 1-line interleave: source +1 line per iter, dest +2 lines
                    ; (each source row written, 1 line gap below).
                    move.w      #SCROLL_HEIGHT-1, d4
.scanline:
                    move.l      (a0), (a1)
                    move.l      4(a0), 4(a1)
                    lea         SCROLL_BUFFER_LINE_BYTES(a0), a0
                    lea         SCREEN_LINE_BYTES*2(a1), a1
                    dbra        d4, .scanline

                    dbra        d6, .strip
                    rts

; ----------------------------------------------------------------------------
; ScrollPlotType4 — Two diagonal scrollers mirrored across a horizontal line
;
; Row 1 slopes DOWN to the right (1 line per strip). Row 2 is the vertical
; mirror image of row 1 across the symmetry line (TYPE4_MIRROR_Y), rendered
; upside-down. The two rows touch at the symmetry line on the right edge of
; the screen and open up like an X to the left.
;
; Geometry per strip s (0..19):
;   Row 1 occupies Y = TYPE4_ROW1_TOP_Y + s ... TYPE4_ROW1_TOP_Y + s + 33
;   Row 2 (mirror): source line k → Y = 2·MIRROR − TYPE4_ROW1_TOP_Y − s − k
;     i.e., starts at Y = 2·MIRROR − T1 − s and decrements per source line.
;
; Default values pin the mirror at the lowest extent of row 1 (= row 1's
; bottom at strip 19), so row 1 and row 2 just touch at strip 19.
; ----------------------------------------------------------------------------
TYPE4_ROW1_TOP_Y    equ     80                      ; row 1 top at strip 0
TYPE4_MIRROR_Y      equ     132                     ; horizontal symmetry line
TYPE4_ROW2_START_Y  equ     2*TYPE4_MIRROR_Y-TYPE4_ROW1_TOP_Y       ; = 184

ScrollPlotType4:
                    move.l      back_buffer_ptr, a5
                    lea         scroll_buffer, a2

                    moveq       #19, d6                 ; strip counter

.strip:
                    move.w      #19, d0
                    sub.w       d6, d0                  ; d0 = strip index s (0..19)
                    move.w      d0, d3                  ; save s

                    lsl.w       #3, d0                  ; * 8 bytes per pword
                    lea         0(a2,d0.w), a0          ; buffer source

                    ; Row 1: Y_top = TYPE4_ROW1_TOP_Y + s
                    move.w      #TYPE4_ROW1_TOP_Y, d2
                    add.w       d3, d2
                    mulu.w      #SCREEN_LINE_BYTES, d2
                    move.l      a5, a1
                    adda.l      d2, a1
                    adda.w      d0, a1

                    ; Row 2 start (source line 0): Y = 2·MIRROR − T1 − s
                    ; Each source line decrements dest Y → upside-down render.
                    move.w      #TYPE4_ROW2_START_Y, d2
                    sub.w       d3, d2
                    mulu.w      #SCREEN_LINE_BYTES, d2
                    move.l      a5, a3
                    adda.l      d2, a3
                    adda.w      d0, a3

                    ; Plot 34 source lines: row 1 forward, row 2 backward.
                    move.w      #SCROLL_HEIGHT-1, d4
.scanline:
                    move.l      (a0), d1
                    move.l      4(a0), d2

                    move.l      d1, (a1)
                    move.l      d2, 4(a1)
                    move.l      d1, (a3)
                    move.l      d2, 4(a3)

                    lea         SCROLL_BUFFER_LINE_BYTES(a0), a0
                    lea         SCREEN_LINE_BYTES(a1), a1
                    lea         -SCREEN_LINE_BYTES(a3), a3
                    dbra        d4, .scanline

                    dbra        d6, .strip
                    rts

; ----------------------------------------------------------------------------
; ScrollPlotType5 — Spread vertical (4× tall)
;
; Each source scanline written 4 times to consecutive dest lines = 4× zoom.
; Only plots 25 source lines (of 34) to fit on screen: 25×4 = 100 dest lines.
; Single centered row, no sine wave (pure vertical stretch).
; (Will be replaced later when we tackle "real effect 5".)
; ----------------------------------------------------------------------------
TYPE5_ROW_Y         equ     90                      ; centered for 100-line output
TYPE5_SRC_LINES     equ     25                      ; only plot 25 of 34 lines

ScrollPlotType5:
                    move.l      back_buffer_ptr, a5
                    lea         scroll_buffer, a2

                    moveq       #19, d6                 ; strip counter

.strip:
                    move.w      #19, d0
                    sub.w       d6, d0
                    lsl.w       #3, d0                  ; * 8 bytes per pword
                    lea         0(a2,d0.w), a0

                    move.l      a5, a1
                    lea         TYPE5_ROW_Y*SCREEN_LINE_BYTES(a1), a1
                    adda.w      d0, a1

                    move.w      #TYPE5_SRC_LINES-1, d4
.scanline:
                    move.l      (a0), d0                ; planes 0,1
                    move.l      4(a0), d1               ; planes 2,3

                    move.l      d0, (a1)
                    move.l      d1, 4(a1)
                    move.l      d0, SCREEN_LINE_BYTES(a1)
                    move.l      d1, SCREEN_LINE_BYTES+4(a1)
                    move.l      d0, SCREEN_LINE_BYTES*2(a1)
                    move.l      d1, SCREEN_LINE_BYTES*2+4(a1)
                    move.l      d0, SCREEN_LINE_BYTES*3(a1)
                    move.l      d1, SCREEN_LINE_BYTES*3+4(a1)

                    lea         SCROLL_BUFFER_LINE_BYTES(a0), a0
                    lea         SCREEN_LINE_BYTES*4(a1), a1
                    dbra        d4, .scanline

                    dbra        d6, .strip
                    rts

; ----------------------------------------------------------------------------
; ScrollPlotType6 — 2 fixed horizontal rows (simplest effect)
;
; Just two straight horizontal rows, no wave, no diagonal.
; Like Type 0 but with 2 rows instead of 3.
; ----------------------------------------------------------------------------
TYPE6_ROW1_Y        equ     78                      ; row 1 (from original)
TYPE6_ROW2_Y        equ     119                     ; row 2 (41 lines below)

ScrollPlotType6:
                    lea         scroll_buffer, a0
                    move.l      back_buffer_ptr, a5
                    lea         (TYPE6_ROW1_Y*SCREEN_LINE_BYTES)(a5), a2
                    lea         (TYPE6_ROW2_Y*SCREEN_LINE_BYTES)(a5), a3

                    move.w      #SCROLL_HEIGHT-1, d7
.line:
                    rept        5
                    movem.l     (a0)+, d0-d6/a6
                    movem.l     d0-d6/a6, (a2)
                    lea         32(a2), a2
                    movem.l     d0-d6/a6, (a3)
                    lea         32(a3), a3
                    endr
                    addq.l      #8, a0                  ; buffer stride 168, read 160
                    lea         24(a2), a2              ; screen stride 184, wrote 160
                    lea         24(a3), a3
                    dbra        d7, .line
                    rts

; ----------------------------------------------------------------------------
; ScrollPlotType7 — Diagonal same direction (2 rows)
;
; 2 rows, both with linear Y offset increasing left-to-right. Creates a
; diagonal wave where both rows tilt the same way.
; (Will be replaced later with the triangle /\ + reflection \/ + bottom row.)
; ----------------------------------------------------------------------------
TYPE7_ROW1_Y        equ     80                      ; row 1 base
TYPE7_ROW2_Y        equ     145                     ; row 2 base
TYPE7_SLOPE         equ     1                       ; lines per strip

ScrollPlotType7:
                    move.l      back_buffer_ptr, a5
                    lea         scroll_buffer, a2

                    moveq       #19, d6                 ; strip counter

.strip:
                    move.w      #19, d0
                    sub.w       d6, d0
                    move.w      d0, d5                  ; d5 = Y offset (0-19 lines)

                    lsl.w       #3, d0                  ; * 8 bytes per pword
                    lea         0(a2,d0.w), a0

                    ; Row 1: Y = base + offset (diagonal down-right)
                    move.w      #TYPE7_ROW1_Y, d2
                    add.w       d5, d2
                    mulu.w      #SCREEN_LINE_BYTES, d2
                    move.l      a5, a1
                    adda.l      d2, a1
                    adda.w      d0, a1

                    ; Row 2: same direction diagonal
                    move.w      #TYPE7_ROW2_Y, d2
                    add.w       d5, d2
                    mulu.w      #SCREEN_LINE_BYTES, d2
                    move.l      a5, a3
                    adda.l      d2, a3
                    adda.w      d0, a3

                    move.w      #SCROLL_HEIGHT-1, d4
.scanline:
                    move.l      (a0), d1
                    move.l      4(a0), d3

                    move.l      d1, (a1)
                    move.l      d3, 4(a1)
                    move.l      d1, (a3)
                    move.l      d3, 4(a3)

                    lea         SCROLL_BUFFER_LINE_BYTES(a0), a0
                    lea         SCREEN_LINE_BYTES(a1), a1
                    lea         SCREEN_LINE_BYTES(a3), a3
                    dbra        d4, .scanline

                    dbra        d6, .strip
                    rts

; ----------------------------------------------------------------------------
; ClearScrollerRegion — Clear screen area used by sine effects (lines 78-193)
;
; For moving effects (Type 1, 4, 7), previous frame's pixels must be erased
; to avoid artifacts. Clears 116 lines × 184 bytes ≈ 21KB.
; ----------------------------------------------------------------------------
CLEAR_START_Y       equ     70
CLEAR_END_Y         equ     199                     ; extended to cover full reflection
CLEAR_HEIGHT        equ     CLEAR_END_Y-CLEAR_START_Y   ; 116 lines

ClearScrollerRegion:
                    move.l      back_buffer_ptr, a0
                    ; Start at line 78
                    adda.l      #CLEAR_START_Y*SCREEN_LINE_BYTES, a0
                    move.w      #CLEAR_HEIGHT-1, d7
                    moveq       #0, d0
.clear_line:
                    ; Clear 184 bytes = 46 longwords per line
                    rept        11
                    move.l      d0, (a0)+
                    move.l      d0, (a0)+
                    move.l      d0, (a0)+
                    move.l      d0, (a0)+
                    endr
                    move.l      d0, (a0)+
                    move.l      d0, (a0)+
                    ; 11*4 + 2 = 46 longwords = 184 bytes
                    dbra        d7, .clear_line
                    rts

; ----------------------------------------------------------------------------
; type1_inside_lut — per-strip Y offset for Type 1's deformation sine.
; 2 sine cycles across 20 strips (period 10), amplitude ±3 lines.
; Pattern derived from sin(2π·2·i/20), rounded.
; ----------------------------------------------------------------------------
                    even
type1_inside_lut:
                    dc.w        0, 2, 3, 3, 2, 0, -2, -3, -3, -2
                    dc.w        0, 2, 3, 3, 2, 0, -2, -3, -3, -2

; ----------------------------------------------------------------------------
; type1_traj_lut — half-sine for Type 1's trajectory bob.
; 50 entries = 1 second per half-cycle at 50 Hz.
; Values are |sin(π·i/50)| × 20 rounded; sign is applied via sine_direction.
; ----------------------------------------------------------------------------
                    even
type1_traj_lut:
                    dc.w        0, 1, 3, 4, 5, 6, 7, 9, 10, 11
                    dc.w        12, 13, 14, 15, 15, 16, 17, 18, 18, 19
                    dc.w        19, 19, 20, 20, 20, 20, 20, 20, 20, 19
                    dc.w        19, 19, 18, 18, 17, 16, 15, 15, 14, 13
                    dc.w        12, 11, 10, 9, 7, 6, 5, 4, 3, 1

; ----------------------------------------------------------------------------
; BSS
; ----------------------------------------------------------------------------
                    section     BSS

                    even
scroll_buffer:        ds.b      SCROLL_BUFFER_BYTES

scroll_render_phase:  ds.w      1       ; 0-4 phase in 5-pword cycle
scroll_text_cursor:   ds.l      1
scroll_curr_glyph:    ds.l      1       ; current char glyph pointer
scroll_next_glyph:    ds.l      1       ; next char glyph pointer (for blending)

scroll_effect_type:   ds.w      1       ; 0=3-row fixed, 7=sine wave
scroll_speed_extra:   ds.w      1       ; 0=1x, 1=2x horizontal scroll/VBL
sine_frame_count:     ds.w      1       ; phase index 0..49 (Type 1 trajectory LUT)
sine_direction:       ds.w      1       ; +1 or -1 for bob direction
sine_offset:          ds.w      1       ; current vertical bob offset (scanlines)
type1_prev_vbl:       ds.w      1       ; vbl_counter snapshot from last Type 1 call

                    section     TEXT
