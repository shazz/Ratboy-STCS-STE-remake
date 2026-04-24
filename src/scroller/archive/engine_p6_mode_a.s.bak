; ----------------------------------------------------------------------------
; scroller/engine.s — 16 px/VBL scroller, Mode A (3 rows), blitter-assisted
; ----------------------------------------------------------------------------
; Everything scroll-related runs in the VBL handler:
;   1. Render next 1/3 of current glyph into pword 22 of scroll_buffer (CPU)
;   2. Blitter shift scroll_buffer left by 1 pword (22 pwords × 34 lines)
;   3. Blitter copy scroll_buffer → screen at Y_1, Y_2, Y_3 (3 calls)
;
; Why in VBL? Main loop's CPU shift was getting interrupted by VBL itself
; (~26 of 34 lines done before next VBL → tear). Blitter is both faster
; AND runs atomically in hog mode, so no interruption.
; ----------------------------------------------------------------------------

SCROLL_BUFFER_BYTES equ     SCROLL_HEIGHT*SCREEN_LINE_BYTES     ; 6256

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
; ScrollerStep — single call from VBL. Render → shift → copy×3.
; ----------------------------------------------------------------------------
ScrollerStep:
                    bsr         ScrollRenderNextPword           ; fill pword 22 with next slice
                    bsr         ScrollBlitterShift              ; shift pwords [1..22]→[0..21] in scroll_buffer
                    bsr         ScrollCopyToScreen              ; 3x blit scroll_buffer → screen
                    rts

; ----------------------------------------------------------------------------
; ScrollRenderNextPword — write next 1/3 of current glyph into pword 22.
; Unchanged from single-row version.
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
                    lsl.w       #3, d2

.do_render:
                    adda.w      d2, a0

                    lea         scroll_buffer, a1
                    lea         (SCROLL_RIGHT_PWORD*PWORD_BYTES)(a1), a1

                    move.w      #SCROLL_HEIGHT-1, d0
.line:
                    move.l      (a0), (a1)
                    move.l      4(a0), 4(a1)
                    lea         FONT_GLYPH_LINE_B(a0), a0
                    lea         SCREEN_LINE_BYTES(a1), a1
                    dbra        d0, .line

                    addq.w      #1, scroll_word_in_char
                    cmp.w       #FONT_GLYPH_PWORDS, scroll_word_in_char
                    blt.s       .done
                    clr.w       scroll_word_in_char
.done:
                    rts

; ----------------------------------------------------------------------------
; ScrollBlitterShift — blitter in-place shift: pwords [1..22] → [0..21]
; for all 34 scroll_buffer scanlines. Runs in hog mode (~12K cy).
; ----------------------------------------------------------------------------
ScrollBlitterShift:
                    lea         BLITTER, a0
                    move.l      #scroll_buffer+PWORD_BYTES, BLIT_SRC_ADDR(a0)   ; src = line+8
                    move.l      #scroll_buffer, BLIT_DST_ADDR(a0)                ; dst = line
                    move.w      #2, BLIT_SRC_XINC(a0)
                    move.w      #PWORD_BYTES, BLIT_SRC_YINC(a0)                  ; skip 8 bytes to next line's src
                    move.w      #2, BLIT_DST_XINC(a0)
                    move.w      #PWORD_BYTES, BLIT_DST_YINC(a0)                  ; skip 8 bytes to next line's dst
                    move.w      #$FFFF, BLIT_EMASK1(a0)
                    move.w      #$FFFF, BLIT_EMASK2(a0)
                    move.w      #$FFFF, BLIT_EMASK3(a0)
                    move.w      #(SCREEN_TOTAL_PWORDS-1)*4, BLIT_XCOUNT(a0)      ; 22 pwords × 4 planes = 88 words
                    move.w      #SCROLL_HEIGHT, BLIT_YCOUNT(a0)
                    move.b      #2, BLIT_HOP(a0)
                    move.b      #3, BLIT_OP(a0)
                    move.b      #0, BLIT_SKEW(a0)
                    move.b      #$80, BLIT_CTRL(a0)     ; start, BLIT mode (shares bus 64/64 with CPU)
                    ; bset restart pattern from blitter_faq.txt — in BLIT mode
                    ; the blitter pauses every 64 cy and the CPU MUST re-set
                    ; BUSY to resume it. Simple btst wait hangs the blitter.
                    ; Old bit: 1 = still busy (loop); 0 = Y_COUNT hit 0 (done).
.wait:
                    bset        #7, BLIT_CTRL(a0)
                    nop
                    bne.s       .wait
                    rts

; ----------------------------------------------------------------------------
; ScrollCopyToScreen — 3× blitter-hog copy of scroll_buffer to screen Y_1/2/3.
; ----------------------------------------------------------------------------
ScrollCopyToScreen:
                    move.l      screen_base, a0
                    lea         (SCROLL_Y_1*SCREEN_LINE_BYTES)(a0), a0
                    bsr         BlitScrollRow
                    move.l      screen_base, a0
                    lea         (SCROLL_Y_2*SCREEN_LINE_BYTES)(a0), a0
                    bsr         BlitScrollRow
                    move.l      screen_base, a0
                    lea         (SCROLL_Y_3*SCREEN_LINE_BYTES)(a0), a0
                    bsr         BlitScrollRow
                    rts

; ----------------------------------------------------------------------------
; BlitScrollRow — a0 = destination. Hog-copy scroll_buffer → (a0).
; ----------------------------------------------------------------------------
BlitScrollRow:
                    lea         BLITTER, a1
                    move.l      #scroll_buffer, BLIT_SRC_ADDR(a1)
                    move.w      #2, BLIT_SRC_XINC(a1)
                    move.w      #0, BLIT_SRC_YINC(a1)
                    move.l      a0, BLIT_DST_ADDR(a1)
                    move.w      #2, BLIT_DST_XINC(a1)
                    move.w      #0, BLIT_DST_YINC(a1)
                    move.w      #$FFFF, BLIT_EMASK1(a1)
                    move.w      #$FFFF, BLIT_EMASK2(a1)
                    move.w      #$FFFF, BLIT_EMASK3(a1)
                    move.w      #SCREEN_LINE_WORDS, BLIT_XCOUNT(a1)
                    move.w      #SCROLL_HEIGHT, BLIT_YCOUNT(a1)
                    move.b      #2, BLIT_HOP(a1)
                    move.b      #3, BLIT_OP(a1)
                    move.b      #0, BLIT_SKEW(a1)
                    move.b      #$C0, BLIT_CTRL(a1)     ; start + hog (HBL blocked; runs in vblank)
.wait:
                    btst        #7, BLIT_CTRL(a1)
                    bne.s       .wait
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
