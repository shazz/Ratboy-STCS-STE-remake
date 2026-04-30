; ----------------------------------------------------------------------------
; screen.s — Double-buffered screen memory + boot-time setup
; ----------------------------------------------------------------------------
; Two screen buffers (37 KB each, 256-aligned), both pre-painted with the
; static LOGO at boot. Each VBL the front/back pointers swap and the new
; front address is written to the Shifter base registers; the scroller plot
; writes its rows into whichever buffer is currently "back" (i.e. NOT being
; displayed). This eliminates the plot-vs-Shifter race that the single-buffer
; build hit at row 1's last few scanlines.
;
; Memory layout in BSS:
;   screen_buffer_a_raw  — raw, 36800 + 256 bytes for alignment slack
;   screen_buffer_b_raw  — raw, same
;   screen_buffer_a      — 256-byte-aligned pointer into _a_raw
;   screen_buffer_b      — 256-byte-aligned pointer into _b_raw
;   front_buffer_ptr     — currently-displayed buffer (Shifter reading this)
;   back_buffer_ptr      — currently-rendering buffer (CPU plot writing here)
; ----------------------------------------------------------------------------

InitScreen:
                    ; ---------- 1. low resolution ----------
                    move.w      #RES_LOW, -(sp)         ; new mode
                    move.l      #-1, -(sp)              ; phys unchanged
                    move.l      #-1, -(sp)              ; log unchanged
                    move.w      #XBIOS_SETSCREEN, -(sp)
                    trap        #XBIOS
                    lea         12(sp), sp

                    ; ---------- 2. STE LINEWID for off-screen pipeline ----------
                    move.b      #SCREEN_LINEWID, VIDEO_LINEWID
                    clr.b       VIDEO_HSCROLL

                    ; ---------- 3. align both buffers to 256 bytes ----------
                    lea         screen_buffer_a_raw, a0
                    move.l      a0, d0
                    add.l       #SCREEN_ALIGN-1, d0
                    clr.b       d0
                    move.l      d0, screen_buffer_a

                    lea         screen_buffer_b_raw, a0
                    move.l      a0, d0
                    add.l       #SCREEN_ALIGN-1, d0
                    clr.b       d0
                    move.l      d0, screen_buffer_b

                    ; ---------- 4. init front/back pointers ----------
                    move.l      screen_buffer_a, front_buffer_ptr
                    move.l      screen_buffer_b, back_buffer_ptr

                    ; ---------- 5. point Shifter at front (= buffer A) ----------
                    move.l      front_buffer_ptr, d1
                    move.b      d1, SCREEN_BASE_LOW
                    lsr.l       #8, d1
                    move.b      d1, SCREEN_BASE_MID
                    lsr.l       #8, d1
                    move.b      d1, SCREEN_BASE_HIGH

                    ; ---------- 6. zero both buffers ----------
                    move.l      screen_buffer_a, a0
                    bsr         .clear_one
                    move.l      screen_buffer_b, a0
                    bsr         .clear_one

                    ; ---------- 7. install logo palette ----------
                    movem.l     top_logo_palette, d0-d7
                    movem.l     d0-d7, SHIFTER_PALETTE

                    ; ---------- 8. blit logo into BOTH buffers ----------
                    ; The logo is static for the entire demo, so we paint
                    ; it once into each buffer and never touch it again.
                    ; The scroller writes only into the row regions
                    ; (SCROLL_Y_1..3), well below the logo.
                    move.l      screen_buffer_a, a1
                    bsr         .paint_logo
                    move.l      screen_buffer_b, a1
                    bsr         .paint_logo

                    rts

; ---------- helpers ----------
.clear_one:
                    ; a0 = buffer to clear (SCREEN_BYTES bytes)
                    move.w      #(SCREEN_BYTES/4)-1, d1
                    moveq       #0, d2
.clear_loop:
                    move.l      d2, (a0)+
                    dbra        d1, .clear_loop
                    rts

.paint_logo:
                    ; a1 = destination buffer base
                    lea         top_logo_bitmap, a0
                    move.w      #TOP_LOGO_HEIGHT-1, d0          ; 74 lines
.blit_line:
                    move.w      #(TOP_LOGO_LINE_B/4)-1, d1      ; 40 longs/line
.blit_word:
                    move.l      (a0)+, (a1)+
                    dbra        d1, .blit_word
                    lea         (SCREEN_EXTRA_WORDS*2)(a1), a1  ; skip 24-byte LINEWID pad
                    dbra        d0, .blit_line
                    rts

; ----------------------------------------------------------------------------
; BSS — two raw buffers + two aligned pointers + front/back swap pointers.
; ----------------------------------------------------------------------------
                    section     BSS

screen_buffer_a_raw:  ds.b      SCREEN_BYTES+SCREEN_ALIGN
screen_buffer_b_raw:  ds.b      SCREEN_BYTES+SCREEN_ALIGN
screen_buffer_a:      ds.l      1
screen_buffer_b:      ds.l      1
front_buffer_ptr:     ds.l      1
back_buffer_ptr:      ds.l      1

                    section     TEXT
