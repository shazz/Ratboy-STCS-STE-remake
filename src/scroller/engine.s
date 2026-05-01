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
                    clr.w       scroll_byte_pending     ; first VBL renders new pword
                    clr.w       scroll_active_buf       ; A is initial active buffer
                    move.l      #scroll_buffer_a, scroll_plot_addr
                    clr.w       sine_frame_count
                    move.w      #1, sine_direction      ; start moving down
                    clr.w       sine_offset

                    moveq       #0, d1
                    ; Clear scroll_buffer_a
                    lea         scroll_buffer_a, a0
                    move.w      #(SCROLL_BUFFER_BYTES/4)-1, d0
.clr_a:
                    move.l      d1, (a0)+
                    dbra        d0, .clr_a
                    ; Clear scroll_buffer_b
                    lea         scroll_buffer_b, a0
                    move.w      #(SCROLL_BUFFER_BYTES/4)-1, d0
.clr_b:
                    move.l      d1, (a0)+
                    dbra        d0, .clr_b
                    ; Clear scroll_next_pword (= 8 bytes × 34 lines = 272 bytes = 68 longs)
                    lea         scroll_next_pword, a0
                    move.w      #(8*SCROLL_HEIGHT/4)-1, d0
.clr_n:
                    move.l      d1, (a0)+
                    dbra        d0, .clr_n
                    rts

; ----------------------------------------------------------------------------
; ScrollerStepVblank — full per-VBL pipeline. Called from MainLoop.
;
; Alternating dual-buffer architecture (RATBOY 1988 trick — see
; docs/LEARNINGS.md "Smooth 8 px / VBL"). Two buffers A and B hold the
; same scroll content offset by 1 byte (= 8 px) horizontally. Each VBL:
;
;   1. Plot from current active buffer (scroll_plot_addr).
;   2. Toggle which buffer is active.
;   3. If scroll_byte_pending == 0, render a fresh pword to scroll_next_pword.
;   4. ScrollShiftAndFill: pword-shift the new active + byte-shift fill
;      its rightmost pword from the just-displayed buffer + scroll_next_pword.
;   5. Toggle scroll_byte_pending so the next VBL uses the other half
;      of the rendered pword.
;
; Visual: 8 px / VBL smooth scroll, ~40 sl shift work per frame.
; ----------------------------------------------------------------------------
ScrollerStepVblank:
                    bsr         ScrollPlotDispatch

                    ; Toggle active buffer flag
                    move.w      scroll_active_buf, d0
                    eor.w       #1, d0
                    move.w      d0, scroll_active_buf

                    ; Set scroll_plot_addr to the new active and load addresses
                    ; into a0 (target = new active) and a1 (source = old active).
                    tst.w       d0
                    beq.s       .new_a
                    move.l      #scroll_buffer_b, scroll_plot_addr
                    lea         scroll_buffer_b, a0
                    lea         scroll_buffer_a, a1
                    bra.s       .render_check
.new_a:
                    move.l      #scroll_buffer_a, scroll_plot_addr
                    lea         scroll_buffer_a, a0
                    lea         scroll_buffer_b, a1
.render_check:
                    ; Render new pword into scroll_next_pword every other VBL
                    tst.w       scroll_byte_pending
                    bne.s       .no_render
                    movem.l     a0/a1, -(sp)
                    bsr         ScrollRenderNextPword
                    movem.l     (sp)+, a0/a1
.no_render:
                    move.w      scroll_byte_pending, d4 ; 0 or 1 = byte offset

                    bsr         ScrollShiftAndFill

                    ; Toggle byte_pending for next VBL
                    move.w      scroll_byte_pending, d0
                    eor.w       #1, d0
                    move.w      d0, scroll_byte_pending
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

; --- .fetch_next_char: read next char from text, return glyph ptr in a0
;
; In-text effect-change markers: bytes 1..8 are interpreted as effect
; markers, where byte N = scroll_effect_type (N-1). The marker byte is
; consumed (does not produce a glyph) and SetPalettePointers is called
; so palette and raster-swap addresses follow the effect change. The
; loop repeats until a non-marker byte is found.
;
; Byte 0 = NULL terminator → wrap cursor back to scrolltext_S1.
; Bytes 1..8 = effect markers (= effects 0..7).
; Bytes 9..31 = unused; clamped to glyph index 0 (space) below.
; Bytes 32..95 = printable ASCII (space..underscore).
; Bytes 96+ = clamped to space (out of font range).
.fetch_next_char:
                    move.l      scroll_text_cursor, a0
.fetch_loop:
                    moveq       #0, d1
                    move.b      (a0)+, d1
                    bne.s       .check_marker
                    lea         scrolltext_S1, a0
                    move.b      (a0)+, d1
.check_marker:
                    cmp.b       #1, d1
                    blt.s       .got_char           ; (defensive; d1=0 already wrapped)
                    cmp.b       #8, d1
                    bhi.s       .got_char           ; not a marker → it's a glyph byte
                    ; Effect-change marker: byte N → effect (N-1)
                    moveq       #0, d0
                    move.b      d1, d0
                    subq.w      #1, d0              ; d0 = new effect type
                    move.w      d0, scroll_effect_type
                    move.l      a0, -(sp)
                    bsr         SetPalettePointers
                    move.l      (sp)+, a0
                    bra.s       .fetch_loop
.got_char:
                    move.l      a0, scroll_text_cursor
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
                    lea         scroll_next_pword, a2
                    move.w      #SCROLL_HEIGHT-1, d7
.copy_line:
                    move.l      (a0), (a2)
                    move.l      4(a0), 4(a2)
                    lea         FONT_GLYPH_LINE_B(a0), a0
                    lea         8(a2), a2
                    dbra        d7, .copy_line
                    rts

; --- .blend_high_high: left 8px from a0, right 8px from a1 (both high bytes) ---
; a0 = source pword A, a1 = source pword B
; Output: (A & $FF00) | ((B >> 8) & $00FF) for each plane word
.blend_high_high:
                    lea         scroll_next_pword, a2
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
                    lea         8(a2), a2
                    dbra        d7, .bhh_line
                    rts

; --- .blend_low_high: left 8px from a0 low byte, right 8px from a1 high byte ---
; Output: ((A << 8) & $FF00) | ((B >> 8) & $00FF) for each plane word
.blend_low_high:
                    lea         scroll_next_pword, a2
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
                    lea         8(a2), a2
                    dbra        d7, .blh_line
                    rts

; ----------------------------------------------------------------------------
; ScrollShiftAndFill — RATBOY-style smooth-scroll engine.
;
; Pword-shifts the target buffer left by 1 pword (= 16 px), then fills the
; rightmost pword by byte-shifting between the SOURCE buffer's rightmost
; pword (the buffer we just plotted = the OTHER page in the alternating
; setup) and the relevant half of scroll_next_pword. Net visual: every two
; VBLs the rendered pword is fully integrated, with each frame in between
; shifting 8 px (because the alternation between target and source = same
; content, 1-byte offset).
;
; Inputs:
;   a0 = target buffer base (the one being prepared for next display)
;   a1 = source buffer base (the one just displayed; provides bytes 152..159
;        for the byte-shift fill)
;   d4 = 0 (use scroll_next_pword high bytes per plane: bytes 0/2/4/6) or
;        1 (use low bytes: bytes 1/3/5/7)
;
; Per scanline cost: 38 long-copies + 8 byte-moves ≈ 600 cy (~40 sl/frame).
; ----------------------------------------------------------------------------
ScrollShiftAndFill:
                    lea         scroll_next_pword, a4
                    adda.w      d4, a4                  ; a4 = scroll_next + offset

                    move.w      #SCROLL_HEIGHT-1, d7
.line:
                    ; Bulk pword-shift target: 38 long copies, bytes 8..159 → 0..151
                    move.l      a0, a3                  ; a3 = dst (= byte 0 of scanline)
                    move.l      a0, a2
                    addq.l      #PWORD_BYTES, a2        ; a2 = src (= byte 8)
                    rept        38
                    move.l      (a2)+, (a3)+
                    endr
                    ; a3 now at byte 152 of target scanline (= pword 19 boundary)

                    ; Byte-shift fill rightmost pword (pword 19):
                    ;   target byte 152 (P0 hi) <- source byte 153 (P0 lo)
                    ;   target byte 153 (P0 lo) <- scroll_next byte (offset+0)
                    ;   target byte 154 (P1 hi) <- source byte 155 (P1 lo)
                    ;   target byte 155 (P1 lo) <- scroll_next byte (offset+2)
                    ;   ... same for P2, P3
                    move.l      a1, a5
                    adda.w      #(SCROLL_BUFFER_VIS_PWORDS-1)*PWORD_BYTES, a5   ; a5 = source pword 19 (= byte 152)

                    move.b      1(a5), (a3)+
                    move.b      (a4), (a3)+
                    move.b      3(a5), (a3)+
                    move.b      2(a4), (a3)+
                    move.b      5(a5), (a3)+
                    move.b      4(a4), (a3)+
                    move.b      7(a5), (a3)+
                    move.b      6(a4), (a3)+

                    ; Advance to next scanline
                    lea         SCROLL_BUFFER_LINE_BYTES(a0), a0
                    lea         SCROLL_BUFFER_LINE_BYTES(a1), a1
                    lea         8(a4), a4               ; scroll_next_pword stride = 8
                    dbra        d7, .line
                    rts

; ----------------------------------------------------------------------------
; ScrollPlot — copy buffer pword 0..19 to all 3 screen rows of back buffer.
; 3-way fan-out CPU. ~108 sl wallclock.
; ----------------------------------------------------------------------------
ScrollPlot:
                    move.l      scroll_plot_addr, a0            ; src = pword 0
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
                    move.l      scroll_plot_addr, a0
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
                    move.l      scroll_plot_addr, a2

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
                    move.l      scroll_plot_addr, a2

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
                    move.l      scroll_plot_addr, a2

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
                    move.l      scroll_plot_addr, a2

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
; ScrollPlotType5 — Static bottom scroller + diagonal interleaved on top
;
; Bottom: a horizontal scroller at SCROLL_Y_3 (= 160), same Y as effect 0's
; row 3. Plain 34-line copy.
;
; Top: a 1-line-interleaved scroller whose Y rises from right to left
; (slopes "from bottom-right to top-left"). Anchored so source line 33 at
; strip 19 lands at TYPE5_TOP_RIGHT_Y (= 176, mid of bottom scroller).
; With 1-line interleave, source line k at strip s lands at
; TYPE5_TOP_BASE_Y + s + 2·k. Slope = 1 line per strip going down to the
; right.
;
; Both scrollers share the same content (read from scroll_buffer twice).
; ClearScrollerRegion is called each frame so the interleave gaps stay
; black and the slope motion doesn't trail.
; ----------------------------------------------------------------------------
TYPE5_BOT_Y         equ     SCROLL_Y_3              ; = 160
TYPE5_TOP_RIGHT_Y   equ     176                     ; bottom of top scroller at strip 19
; Slope = s + s/2 = 1.5 lines per strip → 28 lines total over 19 strips.
; Top-left ends ~10 px higher than the 1-line/strip version.
TYPE5_TOP_BASE_Y    equ     TYPE5_TOP_RIGHT_Y-28-66 ; = 82 (src 0 Y at strip 0)

ScrollPlotType5:
                    bsr         ClearScrollerRegion

                    move.l      back_buffer_ptr, a5
                    move.l      scroll_plot_addr, a2

                    moveq       #19, d6                 ; strip counter

.strip:
                    move.w      #19, d0
                    sub.w       d6, d0                  ; d0 = strip index s (0..19)
                    move.w      d0, d3                  ; save s
                    lsl.w       #3, d0                  ; * 8 bytes per pword
                    lea         0(a2,d0.w), a0          ; source

                    ; --- Bottom scroller: Y = TYPE5_BOT_Y, plain ---
                    move.l      a5, a1
                    lea         (TYPE5_BOT_Y*SCREEN_LINE_BYTES)(a1), a1
                    adda.w      d0, a1

                    move.l      a0, a4                  ; save src for top scroll
                    move.w      #SCROLL_HEIGHT-1, d4
.bot_line:
                    move.l      (a0), (a1)
                    move.l      4(a0), 4(a1)
                    lea         SCROLL_BUFFER_LINE_BYTES(a0), a0
                    lea         SCREEN_LINE_BYTES(a1), a1
                    dbra        d4, .bot_line

                    ; --- Top scroller: 1-line interleave, slope down-right ---
                    move.w      #TYPE5_TOP_BASE_Y, d2
                    add.w       d3, d2                  ; Y = base + s
                    move.w      d3, d5
                    lsr.w       #1, d5
                    add.w       d5, d2                  ; Y = base + s + s/2 = base + 1.5·s
                    mulu.w      #SCREEN_LINE_BYTES, d2
                    move.l      a5, a3
                    adda.l      d2, a3
                    adda.w      d0, a3

                    move.l      a4, a0                  ; reset source
                    move.w      #SCROLL_HEIGHT-1, d4
.top_line:
                    move.l      (a0), (a3)
                    move.l      4(a0), 4(a3)
                    lea         SCROLL_BUFFER_LINE_BYTES(a0), a0
                    lea         SCREEN_LINE_BYTES*2(a3), a3
                    dbra        d4, .top_line

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
                    move.l      scroll_plot_addr, a0
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
; ScrollPlotType7 — Two triangles + bottom row ("Real Effect 7")
;
; Three scrollers, same colors as effect 0:
;   • Triangle 1 (/\): apex at top, legs slope down toward edges. At apex
;     (strips 9-10) source line 0 lands at TYPE7_TRI_APEX_Y; at edges
;     (strips 0/19) source line 0 is `depth` lines further down.
;   • Triangle 2 (\/): apex at bottom, legs slope up toward edges. Mirror
;     of triangle 1 across a horizontal line. Rendered upside-down (source
;     line 33 lands at the TOP of triangle 2's dest extent), so the bottom
;     of triangle 1's font touches the top of triangle 2's font at the
;     center of the screen.
;   • Bottom row: static horizontal scroller at SCROLL_Y_3 (= effect 0's
;     row 3 position).
;
; Palette swap line for c2 is relocated to line 113 (between triangle 1's
; apex bottom at Y=112 and triangle 2's apex top at Y=114), so:
;   Y 78..113 → c1 (triangle 1)
;   Y 114..159 → c2 (triangle 2)
;   Y 160..193 → c3 (bottom row, default c3 swap at line 159)
;
; Geometry overlap at the edges (where the diverging legs each extend up to
; 9 lines past their apex extent) is unavoidable with 34-line glyphs and
; tip-touching at center; the rendered visual reflects this.
; ----------------------------------------------------------------------------
TYPE7_TRI_APEX_Y    equ     79                      ; triangle 1 src line 0 Y at apex (strips 9-10)
TYPE7_TRI2_BOT_Y    equ     155                     ; triangle 2 src line 0 Y at apex (= dest bottom)
TYPE7_BOT_ROW_Y     equ     SCROLL_Y_3              ; = 160

ScrollPlotType7:
                    bsr         ClearScrollerRegion

                    move.l      back_buffer_ptr, a5
                    move.l      scroll_plot_addr, a2

                    moveq       #19, d6                 ; strip counter

.strip:
                    move.w      #19, d0
                    sub.w       d6, d0
                    move.w      d0, d3                  ; d3 = strip s
                    move.w      d0, d2
                    add.w       d2, d2
                    lea         type7_depth_lut, a4
                    move.w      0(a4,d2.w), d5          ; d5 = depth at strip s (0..9)

                    lsl.w       #3, d0                  ; d0 = strip * 8 (X byte offset)
                    lea         0(a2,d0.w), a0          ; a0 = source pword
                    move.l      a0, a6                  ; save source for the 3 plots

                    ; --- Triangle 1 (/\) — forward render ---
                    move.w      #TYPE7_TRI_APEX_Y, d2
                    add.w       d5, d2
                    mulu.w      #SCREEN_LINE_BYTES, d2
                    move.l      a5, a1
                    adda.l      d2, a1
                    adda.w      d0, a1

                    move.w      #SCROLL_HEIGHT-1, d4
.tri1_line:
                    move.l      (a0), (a1)
                    move.l      4(a0), 4(a1)
                    lea         SCROLL_BUFFER_LINE_BYTES(a0), a0
                    lea         SCREEN_LINE_BYTES(a1), a1
                    dbra        d4, .tri1_line

                    ; --- Triangle 2 (\/) — upside-down render ---
                    move.l      a6, a0                  ; reset source
                    move.w      #TYPE7_TRI2_BOT_Y, d2
                    sub.w       d5, d2
                    mulu.w      #SCREEN_LINE_BYTES, d2
                    move.l      a5, a1
                    adda.l      d2, a1
                    adda.w      d0, a1

                    move.w      #SCROLL_HEIGHT-1, d4
.tri2_line:
                    move.l      (a0), (a1)
                    move.l      4(a0), 4(a1)
                    lea         SCROLL_BUFFER_LINE_BYTES(a0), a0
                    lea         -SCREEN_LINE_BYTES(a1), a1   ; backward dest
                    dbra        d4, .tri2_line

                    ; --- Bottom row (static) — forward render ---
                    move.l      a6, a0
                    move.l      a5, a1
                    lea         (TYPE7_BOT_ROW_Y*SCREEN_LINE_BYTES)(a1), a1
                    adda.w      d0, a1

                    move.w      #SCROLL_HEIGHT-1, d4
.bot_line:
                    move.l      (a0), (a1)
                    move.l      4(a0), 4(a1)
                    lea         SCROLL_BUFFER_LINE_BYTES(a0), a0
                    lea         SCREEN_LINE_BYTES(a1), a1
                    dbra        d4, .bot_line

                    dbra        d6, .strip
                    rts

                    even
; /\ + \/ trajectory: depth 13 at edges. Triangle 1 at strip 0 lands at
; Y=79+13=92 (4 px lower than slope-1, 4 px higher than slope-1.89).
; Symmetric, ~13/9 ≈ 1.44 lines per strip.
type7_depth_lut:
                    dc.w        13, 12, 10, 9, 7, 6, 4, 3, 1, 0
                    dc.w        0, 1, 3, 4, 6, 7, 9, 10, 12, 13


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
; Two scroll buffers, alternating display each VBL. They hold the same
; scroll content offset by 1 byte (= 8 px) horizontally.
scroll_buffer_a:      ds.b      SCROLL_BUFFER_BYTES
scroll_buffer_b:      ds.b      SCROLL_BUFFER_BYTES
; Staging area for the next-pword content from the renderer; 1 pword × 34 lines.
scroll_next_pword:    ds.b      8*SCROLL_HEIGHT

scroll_render_phase:  ds.w      1       ; 0-4 phase in 5-pword cycle
scroll_text_cursor:   ds.l      1
scroll_curr_glyph:    ds.l      1       ; current char glyph pointer
scroll_next_glyph:    ds.l      1       ; next char glyph pointer (for blending)

scroll_effect_type:   ds.w      1       ; 0=3-row fixed, 7=sine wave
scroll_active_buf:    ds.w      1       ; 0 = scroll_buffer_a active, 1 = b
scroll_byte_pending:  ds.w      1       ; 0 = render this VBL + use high bytes, 1 = use low bytes
                    even
scroll_plot_addr:     ds.l      1       ; pointer to current active buffer (read by plot routines)
sine_frame_count:     ds.w      1       ; phase index 0..49 (Type 1 trajectory LUT)
sine_direction:       ds.w      1       ; +1 or -1 for bob direction
sine_offset:          ds.w      1       ; current vertical bob offset (scanlines)
type1_prev_vbl:       ds.w      1       ; vbl_counter snapshot from last Type 1 call

                    section     TEXT
