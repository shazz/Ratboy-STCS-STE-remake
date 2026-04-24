; ----------------------------------------------------------------------------
; screen.s — Screen buffer ownership, resolution switch, palette, blit primitives
; ----------------------------------------------------------------------------
; InitScreen is the boot-time setup:
;   1. Switch to low-res (320x200x16) via XBIOS Setscreen (mode only; bases
;      stay put while TOS does its thing).
;   2. Compute a 256-byte-aligned base inside our BSS buffer. Original ST
;      requires this alignment; STE tolerates any byte, but staying
;      ST-compatible is harmless and keeps the code portable.
;   3. Point the Shifter at our buffer by writing $FF8201/$FF8203/$FF820D.
;   4. Zero the buffer.
;   5. Install the top logo's palette (16 words via MOVEM).
;   6. Blit the top-logo bitmap into the first N scanlines of the buffer.
;
; Exported label: screen_base — the aligned buffer address, saved for other
; modules (scroller, HBL handler) that need to compute line offsets.
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
                    ; LINEWID=12 adds 12 extra words/line (= 3 pwords = 48 px
                    ; of off-screen buffer on the right). The CPU 8-bit shift
                    ; uses this as the scroller's lookahead pipeline. HSCROLL
                    ; stays at 0 — we're not using hardware sub-word scroll.
                    move.b      #SCREEN_LINEWID, VIDEO_LINEWID
                    clr.b       VIDEO_HSCROLL

                    ; ---------- 3. align our buffer to 256 bytes ----------
                    lea         screen_buffer_raw, a0
                    move.l      a0, d0
                    add.l       #SCREEN_ALIGN-1, d0
                    clr.b       d0                      ; zero low byte → round down to boundary
                    move.l      d0, screen_base         ; publish for other modules

                    ; ---------- 4. point Shifter at our buffer ----------
                    move.l      d0, d1
                    move.b      d1, SCREEN_BASE_LOW     ; STE: bits 7-0
                    lsr.l       #8, d1
                    move.b      d1, SCREEN_BASE_MID     ; bits 15-8
                    lsr.l       #8, d1
                    move.b      d1, SCREEN_BASE_HIGH    ; bits 23-16

                    ; ---------- 5. zero the whole buffer ----------
                    ; 36800 bytes / 4 = 9200 longs. d0 = aligned base.
                    move.l      d0, a0
                    move.w      #(SCREEN_BYTES/4)-1, d1
                    moveq       #0, d2
.clear:
                    move.l      d2, (a0)+
                    dbra        d1, .clear

                    ; ---------- 6. install logo palette ----------
                    ; 16 words = 8 longs via MOVEM. Fastest full-palette write.
                    movem.l     top_logo_palette, d0-d7
                    movem.l     d0-d7, SHIFTER_PALETTE

                    ; ---------- 7. blit logo into top of buffer ----------
                    ; Logo is 160 bytes × 74 lines (no LINEWID in source).
                    ; Screen line is 184 bytes; write 160 then skip 24.
                    move.l      screen_base, a1
                    lea         top_logo_bitmap, a0
                    move.w      #TOP_LOGO_HEIGHT-1, d0          ; outer: 74 lines
.blit_line:
                    move.w      #(TOP_LOGO_LINE_B/4)-1, d1      ; 40 longs/line
.blit_word:
                    move.l      (a0)+, (a1)+
                    dbra        d1, .blit_word
                    lea         (SCREEN_EXTRA_WORDS*2)(a1), a1  ; skip 24-byte pad
                    dbra        d0, .blit_line
                    rts

; ----------------------------------------------------------------------------
; BSS — screen buffer + aligned base pointer
; The raw buffer has SCREEN_ALIGN extra bytes so the runtime alignment
; computation always has room to round up.
; ----------------------------------------------------------------------------
                    section     BSS

screen_buffer_raw:  ds.b        SCREEN_BYTES+SCREEN_ALIGN
screen_base:        ds.l        1

                    section     TEXT
