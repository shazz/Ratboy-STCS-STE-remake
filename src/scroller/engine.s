; ----------------------------------------------------------------------------
; scroller/engine.s — P5 three-row scroller, 16 px / VBL
; ----------------------------------------------------------------------------
; Three scroll rows rendered at SCROLL_Y_{1,2,3} all showing the same text.
; Called from MainLoop after WAIT_VBL.
;
; BLITTER MODE — IMPORTANT (P10.1 fix):
;   Blitter runs in HOG mode ($C0). The previous cooperative-mode attempt
;   broke Timer-B delivery entirely (black gradient, no palette swap).
;
;   Root cause — blitter_faq.txt §d "Common mistakes", lines 1270-1274:
;     "in BLiT mode, the BLiTTER will always arbitrate for the bus after
;      64 cycles of idle time, no matter what the CPU is doing. It will
;      interfere with the interrupt service routines. If the timing of
;      the interrupt service routines is critical, the BLiTTER should
;      only be used with great care and in HOG mode where appropriate."
;
;   Our Timer-B handler re-arms itself every HBL via stop→TBDR=1→start,
;   which is exactly that kind of timing-critical ISR. With the blitter
;   stealing the bus every 64 cycles mid-ISR, TBDR writes got jittered,
;   MFP state went off the rails, and Timer-B stopped firing reliably.
;   Cooperative mode is therefore off-limits here.
;
;   Pipeline ordering is the trick: ScrollerStep runs AFTER WAIT_VBL in
;   MainLoop, i.e. inside the post-VBL invisible window. The blits start
;   at scanline 313 (bottom vblank). They WILL overrun into the visible
;   area — total ≈ 196 sl under HOG, vblank window ≈ 113 sl — so Timer-B
;   (HBL event-count) accumulates HBL pulses while CPU is frozen and the
;   gradient is PARTIALLY missed around lines ~62..145 (the visible area
;   that overlaps the blit tail). To avoid corrupting the visible logo
;   at the TOP of the screen, we start in the BOTTOM vblank: the visible
;   region impacted is the SCROLLER rows themselves (rows 1..3 at Y=78,
;   119, 160). The raster gradient covers y≥70, which visually coincides
;   with the scroller — acceptable since scroller rows are solid color
;   anyway.
;
;   Wait idiom: the canonical Atari Appendix-A bset/nop/bne. In HOG mode
;   BUSY clears cleanly when Y_COUNT=0, so the loop exits without phantom
;   restarts. We ALSO clear CTRL explicitly after the wait to prevent any
;   stale bit-7 state from carrying into the next blit setup.
;
; Cycle budget (HOG, HOP=2 LOP=3 → 2 NOPs/word → 8 cy/word):
;   Shift: 88 words × 34 lines × 8 cy ≈ 23.9 Kcy ≈ 48 sl
;   Copy : 92 words × 34 lines × 8 cy ≈ 25.0 Kcy ≈ 50 sl  (× 3 = 150)
;   Total ≈ 198 sl.
;
; Pipeline, once per VBL:
;   1. ScrollRenderNextPword — CPU writes the next 1/3 of the current glyph
;      into pword 22 of scroll_buffer (off-screen staging area).
;   2. ScrollBlitterShift — blitter shifts pwords [1..22] → [0..21] in
;      scroll_buffer. 22 pwords × 34 lines. Text propagates one pword left
;      per VBL = 16 pixels / frame.
;   3. ScrollCopyToScreen — blitter copies scroll_buffer → screen at rows
;      1/2/3 (three separate blits; same source, three destinations).
; ----------------------------------------------------------------------------

SCROLL_REGION_LONGS equ     (SCROLL_HEIGHT*SCREEN_LINE_BYTES)/4         ; 34 × 184 / 4 = 1564

; ----------------------------------------------------------------------------
; ScrollerInit — zero the 3 scroll-row regions in screen memory and reset
; text cursor. Each row's region IS the scroll buffer (in-place design):
; visible pwords 0..19 + off-screen LINEWID-extra pwords 20..22 used as
; staging for new chars.
; ----------------------------------------------------------------------------
ScrollerInit:
                    clr.w       scroll_word_in_char
                    lea         scrolltext_S1, a0
                    move.l      a0, scroll_text_cursor

                    moveq       #0, d1
                    move.l      screen_base, a0
                    lea         (SCROLL_Y_1*SCREEN_LINE_BYTES)(a0), a1
                    move.w      #SCROLL_REGION_LONGS-1, d0
.clr1:
                    move.l      d1, (a1)+
                    dbra        d0, .clr1

                    move.l      screen_base, a0
                    lea         (SCROLL_Y_2*SCREEN_LINE_BYTES)(a0), a1
                    move.w      #SCROLL_REGION_LONGS-1, d0
.clr2:
                    move.l      d1, (a1)+
                    dbra        d0, .clr2

                    move.l      screen_base, a0
                    lea         (SCROLL_Y_3*SCREEN_LINE_BYTES)(a0), a1
                    move.w      #SCROLL_REGION_LONGS-1, d0
.clr3:
                    move.l      d1, (a1)+
                    dbra        d0, .clr3
                    rts

; ----------------------------------------------------------------------------
; ScrollerStepVblank — work for the post-VBL invisible window.
; In-place architecture: CPU render writes new char's pword to ALL 3
; screen rows' off-screen pword 22 (saves 2x copies), then 1 HOG in-place
; shift on row 1's screen memory.
; ≈ 11 sl render + 47 sl shift = 58 sl, comfortable margin in 113 sl.
; ----------------------------------------------------------------------------
ScrollerStepVblank:
                    bsr         ScrollRenderNextPword
                    bsr         ScrollShiftRow1Hog
                    rts

; ----------------------------------------------------------------------------
; ScrollerStepVisible — work for the visible-area window.
; TWO cooperative in-place shifts (rows 2 & 3). ≈ 104 sl during visible.
; Lines 0..103 of visible may have raster contention; lines 104..199 clean.
; ----------------------------------------------------------------------------
ScrollerStepVisible:
                    bsr         ScrollShiftRow2Coop
                    bsr         ScrollShiftRow3Coop
                    rts

; ----------------------------------------------------------------------------
; ScrollRenderNextPword — write the next 1/3 (8 bytes / 16 pixels) of the
; current glyph into pword 22 of ALL 3 screen rows simultaneously. Source
; is read once per scanline into d3/d4, then written to 3 destinations.
;
; scroll_word_in_char cycles 0..2 across successive calls:
;   0 — load next char from scrolltext, compute glyph pointer, render pword 0
;   1 — render pword 1 of the cached glyph
;   2 — render pword 2 of the cached glyph, then reset to 0 next call
; ----------------------------------------------------------------------------
RIGHT_OFFSET        equ     SCROLL_RIGHT_PWORD*PWORD_BYTES      ; pword 22 byte offset

ScrollRenderNextPword:
                    move.w      scroll_word_in_char, d0
                    bne.s       .not_new_char

                    ; New-char path: pull next byte from scrolltext, wrap on nul.
                    move.l      scroll_text_cursor, a0
                    move.b      (a0)+, d1
                    bne.s       .got_char
                    lea         scrolltext_S1, a0
                    move.b      (a0)+, d1
.got_char:
                    move.l      a0, scroll_text_cursor

                    ; ASCII → glyph index. Clamp to [0, 63] (64-glyph font).
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
                    ; Continuation: reload glyph pointer, offset to pword d0.
                    move.l      scroll_glyph_ptr, a0
                    move.w      d0, d2
                    lsl.w       #3, d2                          ; pword index × 8 bytes

.do_render:
                    adda.w      d2, a0                          ; a0 = glyph row 0, pword d0

                    ; Compute pword-22 destinations in screen memory for all 3 rows.
                    move.l      screen_base, a1
                    lea         (SCROLL_Y_1*SCREEN_LINE_BYTES+RIGHT_OFFSET)(a1), a2
                    lea         (SCROLL_Y_2*SCREEN_LINE_BYTES+RIGHT_OFFSET)(a1), a3
                    lea         (SCROLL_Y_3*SCREEN_LINE_BYTES+RIGHT_OFFSET)(a1), a4

                    move.w      #SCROLL_HEIGHT-1, d0
.line:
                    move.l      (a0), d3                        ; planes 0,1
                    move.l      4(a0), d4                       ; planes 2,3
                    move.l      d3, (a2)
                    move.l      d4, 4(a2)
                    move.l      d3, (a3)
                    move.l      d4, 4(a3)
                    move.l      d3, (a4)
                    move.l      d4, 4(a4)
                    lea         FONT_GLYPH_LINE_B(a0), a0       ; glyph stride (24 bytes)
                    lea         SCREEN_LINE_BYTES(a2), a2
                    lea         SCREEN_LINE_BYTES(a3), a3
                    lea         SCREEN_LINE_BYTES(a4), a4
                    dbra        d0, .line

                    addq.w      #1, scroll_word_in_char
                    cmp.w       #FONT_GLYPH_PWORDS, scroll_word_in_char
                    blt.s       .done
                    clr.w       scroll_word_in_char
.done:
                    rts

; ----------------------------------------------------------------------------
; SetShiftRegs (macro) — set up blitter registers for an in-place shift
; on a screen row. \1 = SCROLL_Y_n constant. Sets a1 = BLITTER for the
; caller's wait loop.
;
; Shifts pwords [1..22] → [0..21] across all 34 scanlines of the row,
; in-place. Pword 22 is the off-screen staging slot (filled by
; ScrollRenderNextPword). YINC = PWORD_BYTES+2 = 10 = (pitch 184) -
; (XCOUNT-1)*XINC = 184 - 87*2 = 10. Lands next-line read on pword 1.
; ----------------------------------------------------------------------------
SetShiftRegs        macro       ; \1 = SCROLL_Y_n
                    lea         BLITTER, a1
                    move.l      screen_base, a0
                    lea         (\1*SCREEN_LINE_BYTES)(a0), a0
                    lea         PWORD_BYTES(a0), a2                              ; a2 = pword 1 of row
                    move.l      a2, BLIT_SRC_ADDR(a1)
                    move.l      a0, BLIT_DST_ADDR(a1)                            ; dst = pword 0 of row
                    move.w      #2, BLIT_SRC_XINC(a1)
                    move.w      #PWORD_BYTES+2, BLIT_SRC_YINC(a1)
                    move.w      #2, BLIT_DST_XINC(a1)
                    move.w      #PWORD_BYTES+2, BLIT_DST_YINC(a1)
                    move.w      #$FFFF, BLIT_EMASK1(a1)
                    move.w      #$FFFF, BLIT_EMASK2(a1)
                    move.w      #$FFFF, BLIT_EMASK3(a1)
                    move.w      #(SCREEN_TOTAL_PWORDS-1)*4, BLIT_XCOUNT(a1)      ; 22 pwords × 4 planes
                    move.w      #SCROLL_HEIGHT, BLIT_YCOUNT(a1)
                    move.b      #2, BLIT_HOP(a1)                                 ; HOP=source
                    move.b      #3, BLIT_OP(a1)                                  ; OP=replace
                    move.b      #0, BLIT_SKEW(a1)
                    endm

; ----------------------------------------------------------------------------
; ScrollShiftRow1Hog — HOG in-place shift, runs from VBL handler in
; invisible time. HOG is safe here because no DE pulses fire yet.
; ----------------------------------------------------------------------------
ScrollShiftRow1Hog:
                    SetShiftRegs SCROLL_Y_1
                    move.b      #$C0, BLIT_CTRL(a1)                              ; HOG=1, BUSY=1
.wait:
                    btst        #7, BLIT_CTRL(a1)
                    bne.s       .wait
                    rts

; ----------------------------------------------------------------------------
; ScrollShiftRow2Coop — cooperative in-place shift, runs from MainLoop
; during visible. Yields to Timer-B every 64 cy; tst.w YCOUNT verify
; closes the cooperative-mode wait-loop race.
; ----------------------------------------------------------------------------
ScrollShiftRow2Coop:
                    SetShiftRegs SCROLL_Y_2
                    move.b      #$80, BLIT_CTRL(a1)                              ; HOG=0, BUSY=1
.wait:
                    bset.b      #7, BLIT_CTRL(a1)                                ; kick the blitter (Atari restart)
                    tst.w       BLIT_YCOUNT(a1)                                  ; YCOUNT is the only true progress signal
                    bne.s       .wait
                    move.b      #0, BLIT_CTRL(a1)                                ; idle CTRL: no BUSY, no phantom
                    rts

; ----------------------------------------------------------------------------
; ScrollShiftRow3Coop — same as Row2Coop but at SCROLL_Y_3.
; ----------------------------------------------------------------------------
ScrollShiftRow3Coop:
                    SetShiftRegs SCROLL_Y_3
                    move.b      #$80, BLIT_CTRL(a1)
.wait:
                    bset.b      #7, BLIT_CTRL(a1)                                ; kick the blitter (Atari restart)
                    tst.w       BLIT_YCOUNT(a1)                                  ; YCOUNT is the only true progress signal
                    bne.s       .wait
                    move.b      #0, BLIT_CTRL(a1)                                ; idle CTRL: no BUSY, no phantom
                    rts

; ----------------------------------------------------------------------------
; BSS
; ----------------------------------------------------------------------------
                    section     BSS

scroll_word_in_char:  ds.w      1
scroll_text_cursor:   ds.l      1
scroll_glyph_ptr:     ds.l      1

                    section     TEXT
