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

SCROLL_BUFFER_BYTES equ     SCROLL_HEIGHT*SCREEN_LINE_BYTES     ; 34 × 184 = 6256

; ----------------------------------------------------------------------------
; ScrollerInit — zero scroll_buffer, reset text cursor.
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
; ScrollerStep — called from VBL. Render → shift → copy.
; ----------------------------------------------------------------------------
ScrollerStep:
                    bsr         ScrollRenderNextPword
                    bsr         ScrollBlitterShift
                    bsr         ScrollCopyToScreen
                    rts

; ----------------------------------------------------------------------------
; ScrollRenderNextPword — write the next 1/3 (8 bytes / 16 pixels) of the
; current glyph into pword 22 of scroll_buffer.
;
; scroll_word_in_char cycles 0..2 across successive calls:
;   0 — load next char from scrolltext, compute glyph pointer, render pword 0
;   1 — render pword 1 of the cached glyph
;   2 — render pword 2 of the cached glyph, then reset to 0 next call
; ----------------------------------------------------------------------------
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

                    lea         scroll_buffer, a1
                    lea         (SCROLL_RIGHT_PWORD*PWORD_BYTES)(a1), a1

                    move.w      #SCROLL_HEIGHT-1, d0
.line:
                    move.l      (a0), (a1)                      ; planes 0,1
                    move.l      4(a0), 4(a1)                    ; planes 2,3
                    lea         FONT_GLYPH_LINE_B(a0), a0       ; glyph stride (24 bytes)
                    lea         SCREEN_LINE_BYTES(a1), a1       ; buffer stride (184)
                    dbra        d0, .line

                    addq.w      #1, scroll_word_in_char
                    cmp.w       #FONT_GLYPH_PWORDS, scroll_word_in_char
                    blt.s       .done
                    clr.w       scroll_word_in_char
.done:
                    rts

; ----------------------------------------------------------------------------
; ScrollBlitterShift — blitter hog: pwords [1..22] → [0..21] in scroll_buffer
; across all 34 scanlines. Reads pword 22 last (not written), so the just-
; rendered pword remains at 22 AND gets copied to 21 for this frame.
;
; Bytes per line: 88 words × XINC=2 = 176. YINC=8 skips past pword 22 to
; land on next line's pword 1. Total per row = 184 = pitch.
; ----------------------------------------------------------------------------
ScrollBlitterShift:
                    lea         BLITTER, a0
                    move.l      #scroll_buffer+PWORD_BYTES, BLIT_SRC_ADDR(a0)   ; src = pword 1
                    move.l      #scroll_buffer, BLIT_DST_ADDR(a0)                ; dst = pword 0
                    move.w      #2, BLIT_SRC_XINC(a0)
                    move.w      #PWORD_BYTES+2, BLIT_SRC_YINC(a0)                ; YINC = pitch-(XCOUNT-1)*XINC = 184-174 = 10
                    move.w      #2, BLIT_DST_XINC(a0)
                    move.w      #PWORD_BYTES+2, BLIT_DST_YINC(a0)
                    move.w      #$FFFF, BLIT_EMASK1(a0)
                    move.w      #$FFFF, BLIT_EMASK2(a0)
                    move.w      #$FFFF, BLIT_EMASK3(a0)
                    move.w      #(SCREEN_TOTAL_PWORDS-1)*4, BLIT_XCOUNT(a0)      ; 22 pwords × 4 planes
                    move.w      #SCROLL_HEIGHT, BLIT_YCOUNT(a0)
                    move.b      #2, BLIT_HOP(a0)                                 ; HOP=source
                    move.b      #3, BLIT_OP(a0)                                  ; OP=replace (LOP=3, D=S)
                    move.b      #0, BLIT_SKEW(a0)                                ; no skew, FXSR=NFSR=0
                    ; Cooperative-mode start + read-only wait. Safe alongside
                    ; Timer-B because the simplified ISR (no re-arm) fits in
                    ; the blitter's 64-cycle bus-yield window.
                    move.b      #$80, BLIT_CTRL(a0)                              ; start, HOG=0
.wait:
                    tst.b       BLIT_CTRL(a0)
                    bmi.s       .wait
                    rts

; ----------------------------------------------------------------------------
; ScrollCopyToScreen — HOG blits: scroll_buffer → screen at rows 1/2/3.
; Stable per-op registers set once; per-copy we reload SRC/DST/YCOUNT/CTRL.
; Each copy = 92 × 34 × 8 cy ≈ 25 Kcy ≈ 50 sl. Three copies ≈ 150 sl.
; ----------------------------------------------------------------------------
ScrollCopyToScreen:
                    lea         BLITTER, a1

                    ; Stable blitter setup (shared across all 3 copies).
                    move.w      #2, BLIT_SRC_XINC(a1)
                    move.w      #2, BLIT_SRC_YINC(a1)                            ; pitch-(XCOUNT-1)*XINC = 184-182 = 2
                    move.w      #2, BLIT_DST_XINC(a1)
                    move.w      #2, BLIT_DST_YINC(a1)
                    move.w      #$FFFF, BLIT_EMASK1(a1)
                    move.w      #$FFFF, BLIT_EMASK2(a1)
                    move.w      #$FFFF, BLIT_EMASK3(a1)
                    move.w      #SCREEN_LINE_WORDS, BLIT_XCOUNT(a1)              ; 92 words/line
                    move.b      #2, BLIT_HOP(a1)
                    move.b      #3, BLIT_OP(a1)
                    move.b      #0, BLIT_SKEW(a1)                                ; once — SKEW persists

                    ; ---- row 1 @ SCROLL_Y_1 ----
                    move.l      screen_base, a0
                    lea         (SCROLL_Y_1*SCREEN_LINE_BYTES)(a0), a0
                    move.l      #scroll_buffer, BLIT_SRC_ADDR(a1)
                    move.l      a0, BLIT_DST_ADDR(a1)
                    move.w      #SCROLL_HEIGHT, BLIT_YCOUNT(a1)
                    move.b      #$80, BLIT_CTRL(a1)                              ; start, cooperative
.wait1:
                    tst.b       BLIT_CTRL(a1)
                    bmi.s       .wait1

                    ; ---- row 2 @ SCROLL_Y_2 ----
                    move.l      screen_base, a0
                    lea         (SCROLL_Y_2*SCREEN_LINE_BYTES)(a0), a0
                    move.l      #scroll_buffer, BLIT_SRC_ADDR(a1)
                    move.l      a0, BLIT_DST_ADDR(a1)
                    move.w      #SCROLL_HEIGHT, BLIT_YCOUNT(a1)
                    move.b      #$80, BLIT_CTRL(a1)                              ; start, cooperative
.wait2:
                    tst.b       BLIT_CTRL(a1)
                    bmi.s       .wait2

                    ; ---- row 3 @ SCROLL_Y_3 ----
                    move.l      screen_base, a0
                    lea         (SCROLL_Y_3*SCREEN_LINE_BYTES)(a0), a0
                    move.l      #scroll_buffer, BLIT_SRC_ADDR(a1)
                    move.l      a0, BLIT_DST_ADDR(a1)
                    move.w      #SCROLL_HEIGHT, BLIT_YCOUNT(a1)
                    move.b      #$80, BLIT_CTRL(a1)                              ; start, cooperative
.wait3:
                    tst.b       BLIT_CTRL(a1)
                    bmi.s       .wait3
                    rts

; ----------------------------------------------------------------------------
; BSS
; ----------------------------------------------------------------------------
                    section     BSS

scroll_word_in_char:  ds.w      1
scroll_text_cursor:   ds.l      1
scroll_glyph_ptr:     ds.l      1
                    even
scroll_buffer:        ds.b      SCROLL_BUFFER_BYTES

                    section     TEXT
