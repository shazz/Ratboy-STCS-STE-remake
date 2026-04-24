; ----------------------------------------------------------------------------
; system.s — Supervisor mode, TOS state save/restore
; ----------------------------------------------------------------------------
; Routines for crossing the kernel/user boundary and preserving TOS state so
; we can hand the machine back cleanly on exit.
;
; Contract:
;   SuperEnter  — switches CPU to supervisor mode, stashes old USP for later.
;   SuperExit   — returns to user mode using the stashed USP.
;   SaveState   — snapshots palette, resolution, screen base. Call once at boot.
;   RestoreState — restores the snapshot. Call once before exit (while still super).
;
; Register usage: these routines clobber d0-d1/a0-a1. Callers save what they need.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
; SuperEnter — enter supervisor mode, keep current SP
; ----------------------------------------------------------------------------
SuperEnter:
                    clr.l       -(sp)                   ; stack=0 → keep current
                    move.w      #GEMDOS_SUPER, -(sp)
                    trap        #GEMDOS
                    addq.l      #6, sp
                    move.l      d0, old_super_stack     ; remember old USP token
                    rts

; ----------------------------------------------------------------------------
; SuperExit — return to user mode with the preserved USP
; ----------------------------------------------------------------------------
SuperExit:
                    move.l      old_super_stack, -(sp)
                    move.w      #GEMDOS_SUPER, -(sp)
                    trap        #GEMDOS
                    addq.l      #6, sp
                    rts

; ----------------------------------------------------------------------------
; SaveState — snapshot palette + resolution + screen base.
; Must be called in supervisor mode (direct reads of $FF82xx).
; ----------------------------------------------------------------------------
SaveState:
                    ; Palette: 16 words at SHIFTER_PALETTE → old_palette
                    lea         SHIFTER_PALETTE, a0
                    lea         old_palette, a1
                    moveq       #15, d0
.pal_copy:
                    move.w      (a0)+, (a1)+
                    dbra        d0, .pal_copy

                    ; Resolution byte
                    move.b      SHIFTER_RES, old_res

                    ; Logical screen base (from TOS system var, the safest read)
                    move.l      VRAM_PTR.w, old_vram
                    rts

; ----------------------------------------------------------------------------
; RestoreState — invert SaveState. Supervisor mode required.
; Also restores TOS's screen base via Setscreen so that after we exit, TOS
; isn't pointed at our (now-freed) BSS buffer. Critical: zero LINEWID and
; HSCROLL *before* Setscreen — TOS's desktop buffer is 160 bytes/line, so if
; we leave LINEWID=12 the Shifter reads past each line and bus-errors.
; ----------------------------------------------------------------------------
RestoreState:
                    ; Zero STE-specific line-width / horizontal-scroll first
                    ; (both are byte regs at odd addresses).
                    clr.b       VIDEO_LINEWID
                    clr.b       VIDEO_HSCROLL

                    ; Restore palette
                    lea         old_palette, a0
                    lea         SHIFTER_PALETTE, a1
                    moveq       #15, d0
.pal_restore:
                    move.w      (a0)+, (a1)+
                    dbra        d0, .pal_restore

                    ; Restore resolution AND screen base in one Setscreen call.
                    ; log=phys=old_vram pins TOS back to its original buffer.
                    clr.w       d0
                    move.b      old_res, d0
                    move.w      d0, -(sp)               ; mode
                    move.l      old_vram, -(sp)         ; phys base
                    move.l      old_vram, -(sp)         ; log base
                    move.w      #XBIOS_SETSCREEN, -(sp)
                    trap        #XBIOS
                    lea         12(sp), sp
                    rts

; ----------------------------------------------------------------------------
; WaitEscKey — blocks on GEMDOS Cconin until ESC is pressed.
; Uses trap #1 so it's safe in either super or user mode.
; ----------------------------------------------------------------------------
WaitEscKey:
.loop:
                    move.w      #GEMDOS_CCONIN, -(sp)
                    trap        #GEMDOS
                    addq.l      #2, sp
                    cmp.b       #KEY_ESC, d0
                    bne.s       .loop
                    rts

; ----------------------------------------------------------------------------
; BSS — all state lives here. Declared at end of system.s so it's close to
; the routines that use it. VASM will place it in the PRG's BSS segment.
; ----------------------------------------------------------------------------
                    section     BSS

old_super_stack:    ds.l        1                       ; USP stash from SuperEnter
old_palette:        ds.w        16                      ; pre-boot palette
old_res:            ds.b        1                       ; pre-boot resolution
                    ds.b        1                       ; align to word
old_vram:           ds.l        1                       ; pre-boot screen base

                    section     TEXT                    ; back to code for caller
