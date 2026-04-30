; ----------------------------------------------------------------------------
; vbl.s — VBL handler + install/remove into TOS vbl-queue
; ----------------------------------------------------------------------------
; We install our handler as a slot in TOS's vbl-queue rather than overwriting
; the $70 vector directly. See docs/LEARNINGS.md for the why — short version:
; overwriting $70 breaks keyboard/floppy/timer housekeeping. The queue-slot
; approach means TOS's own VBL runs first (housekeeping), then it calls our
; handler via JSR. So our handler ends with RTS, not RTE.
; ----------------------------------------------------------------------------

NVBLS               equ     $454            ; word: number of vbl-queue entries
VBLQUEUE_PTR        equ     $456            ; long: pointer to vbl-queue array

; ----------------------------------------------------------------------------
; InstallVBL — claim the first empty slot in the TOS vbl-queue.
; Must be called in supervisor mode (to write TOS-owned memory safely).
; On success: slot pointer saved in vbl_slot. On failure: leaves vbl_slot=0.
; Clobbers: d0, a0.
; ----------------------------------------------------------------------------
InstallVBL:
                    clr.l       vbl_counter             ; reset counter (word, but zeros both)
                    clr.l       vbl_slot

                    move.l      VBLQUEUE_PTR.w, a0      ; a0 = &vbl_queue[0]
                    move.w      NVBLS.w, d0             ; d0 = slot count
                    subq.w      #1, d0                  ; dbra needs count-1
.find_slot:
                    tst.l       (a0)
                    beq.s       .found
                    addq.l      #4, a0
                    dbra        d0, .find_slot
                    rts                                 ; no free slot — silent fail
.found:
                    move.l      a0, vbl_slot            ; remember where we stored ourself
                    move.l      #VBLHandler, (a0)
                    rts

; ----------------------------------------------------------------------------
; RemoveVBL — free the slot we claimed.
; Safe to call even if InstallVBL failed (vbl_slot will be 0).
; Clobbers: a0.
; ----------------------------------------------------------------------------
RemoveVBL:
                    move.l      vbl_slot, a0
                    move.l      a0, d0                  ; test without clobbering a0
                    beq.s       .nothing_to_free
                    clr.l       (a0)
                    clr.l       vbl_slot
.nothing_to_free:
                    rts

; ----------------------------------------------------------------------------
; VBLHandler — called by TOS VBL at 50 Hz (PAL).
;
; TOS's vblqueue dispatch saves SR/d0/a0 around each entry (documented), but
; other TOS versions may vary — we save everything to be safe. P1 used this
; handler to pulse color 0 for visual proof; P2 drops the pulse since we now
; own the palette and need color 0 stable for the logo. Future phases hook
; music tick, scroller advance, sequencer tick here.
; ----------------------------------------------------------------------------
VBLHandler:
                    movem.l     d0-a6, -(sp)
                    addq.w      #1, vbl_counter

                    ; Buffer swap moved to MainLoop (SwapBuffers) — we just
                    ; reinstall palette and reset raster_ptr here.

                    ; Reinstall LOGO palette for the new frame's logo area.
                    movem.l     top_logo_palette, d0-d7
                    movem.l     d0-d7, SHIFTER_PALETTE
                    ifne        MUSIC_ENABLED
                    jsr         MusicSndhPlay
                    endif
                    ; ArmTimerBRaster: just resets raster_ptr (Timer-B is
                    ; left running by InstallHBL — see hbl.s). Must reset
                    ; ptr BEFORE the first visible scanline of next frame.
                    bsr         ArmTimerBRaster

                    movem.l     (sp)+, d0-a6
                    rts

; ----------------------------------------------------------------------------
; SwapBuffers — swap front/back pointers and write SCREEN_BASE.
; Called from MainLoop AFTER scroller work is done (like original CONFO.S).
; This makes the just-rendered back buffer become the new front.
; ----------------------------------------------------------------------------
SwapBuffers:
                    move.l      front_buffer_ptr, a0            ; old front
                    move.l      back_buffer_ptr, a1              ; old back (= new front)
                    move.l      a1, front_buffer_ptr
                    move.l      a0, back_buffer_ptr

                    ; Write new front to SCREEN_BASE
                    move.l      a1, d0
                    lsr.l       #8, d0
                    lsr.l       #8, d0
                    move.b      d0, SCREEN_BASE_HIGH
                    move.l      a1, d0
                    lsr.l       #8, d0
                    move.b      d0, SCREEN_BASE_MID
                    move.l      a1, d0
                    move.b      d0, SCREEN_BASE_LOW
                    rts

; ----------------------------------------------------------------------------
; BSS for vbl module
; ----------------------------------------------------------------------------
                    section     BSS

vbl_slot:           ds.l        1           ; address of the queue slot we claimed
vbl_counter:        ds.w        1           ; incremented every VBL by our handler
                    ds.w        1           ; pad to long alignment

                    section     TEXT
