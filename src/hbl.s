; ----------------------------------------------------------------------------
; hbl.s — Raster-gradient driver via MFP Timer B (HBL event counter)
; ----------------------------------------------------------------------------
; Based on docs/CSM.S "Cracking Service Munich" bootsector Timer-B pattern.
; Timer B's TBI input is Shifter DE (1 pulse per scanline at HBlank).
; In event-count mode, TBDR counts down HBL events and fires when 0.
;
;   - InstallHBL:           disables ALL MFP ints, re-enables Timer B + ACIA,
;                            installs handler at $120 (L6), leaves Timer B
;                            STOPPED.
;   - ArmTimerBRaster (VBL): stops Timer B, loads TBDR = INITIAL_COUNT (first
;                            fire that many HBLs after VBL end), starts Timer
;                            B in event-count mode, resets raster_ptr.
;   - TimerBHandler:         writes color 0 from raster_ptr, advances, then
;                            stop → TBDR=1 → start re-arm so next fire is on
;                            the following HBL. Acks ISR.
; ----------------------------------------------------------------------------

TIMER_B_VECTOR      equ     $120

; First Timer B fire per frame = INITIAL_COUNT DE pulses after arm.
; Timer B in event-count mode counts DE transitions, which only pulse during
; the 200 visible scanlines. So TBDR=1 → first fire at visible line 0.
; TBDR=N → first fire at visible line N-1. Tune downward to move gradient up.
TIMER_B_INITIAL_COUNT equ   1

; ----------------------------------------------------------------------------
; InstallHBL — MFP setup; Timer B stopped, ready to be armed by VBL.
; Supervisor mode required.
; ----------------------------------------------------------------------------
InstallHBL:
                    move.l      TIMER_B_VECTOR.w, old_timer_b
                    move.b      MFP_TBCR, old_tbcr
                    move.b      MFP_TBDR, old_tbdr

                    ; Stop Timer B, install handler. Selectively enable
                    ; Timer B only — DO NOT wipe other MFP IER bits (TOS
                    ; needs Timer C, ACIA, etc.).
                    move.b      #0, MFP_TBCR
                    move.l      #TimerBHandler, TIMER_B_VECTOR.w
                    bset.b      #0, MFP_IERA            ; enable Timer B
                    bset.b      #0, MFP_IMRA            ; unmask Timer B

                    move.l      #raster_table, raster_ptr
                    rts

; ----------------------------------------------------------------------------
; RemoveHBL — restore everything, stop Timer B.
; ----------------------------------------------------------------------------
RemoveHBL:
                    move.b      #0, MFP_TBCR
                    bclr.b      #0, MFP_IMRA
                    bclr.b      #0, MFP_IERA
                    move.b      old_tbcr, MFP_TBCR
                    move.b      old_tbdr, MFP_TBDR
                    move.l      old_timer_b, TIMER_B_VECTOR.w
                    rts

; ----------------------------------------------------------------------------
; ArmTimerBRaster — called from VBL handler each frame. Arms Timer B with
; INITIAL_COUNT so first fire lands at the first gradient scanline.
; Resets raster_ptr so handler re-walks the table from the top.
; ----------------------------------------------------------------------------
ArmTimerBRaster:
                    move.b      #0, MFP_TBCR            ; stop
                    move.b      #TIMER_B_INITIAL_COUNT, MFP_TBDR
                    move.b      #8, MFP_TBCR            ; event-count, start
                    move.l      #raster_table, raster_ptr
                    rts

; ----------------------------------------------------------------------------
; TimerBHandler — fires at first INITIAL_COUNT-th HBL after VBL, then every
; subsequent HBL (via stop→TBDR=1→start re-arm). Writes color 0 from the
; raster table. At the swap trigger entry, skips color 0 and installs the
; font palette.
; ----------------------------------------------------------------------------
TimerBHandler:
                    move.l      a0, -(sp)
                    move.l      raster_ptr, a0
                    cmp.l       #raster_swap_font, a0
                    beq         .install_font

                    ; Normal: write color 0 from raster table, advance.
                    move.w      (a0)+, SHIFTER_PALETTE
                    move.l      a0, raster_ptr

                    ; Re-arm for next HBL (CSM.S pattern).
                    move.b      #0, MFP_TBCR
                    move.b      #1, MFP_TBDR
                    move.b      #8, MFP_TBCR
                    bclr.b      #0, MFP_ISRA
                    move.l      (sp)+, a0
                    rte

.install_font:
                    ; Skip color 0 write (raster gradient owns it).
                    addq.l      #2, a0
                    move.l      a0, raster_ptr

                    move.l      a1, -(sp)
                    lea         font_palette_c1, a1
                    move.w      2(a1), SHIFTER_PALETTE+2
                    move.w      4(a1), SHIFTER_PALETTE+4
                    move.w      6(a1), SHIFTER_PALETTE+6
                    move.w      8(a1), SHIFTER_PALETTE+8
                    move.w      10(a1), SHIFTER_PALETTE+10
                    move.w      12(a1), SHIFTER_PALETTE+12
                    move.w      14(a1), SHIFTER_PALETTE+14
                    move.w      16(a1), SHIFTER_PALETTE+16
                    move.w      18(a1), SHIFTER_PALETTE+18
                    move.w      20(a1), SHIFTER_PALETTE+20
                    move.w      22(a1), SHIFTER_PALETTE+22
                    move.w      24(a1), SHIFTER_PALETTE+24
                    move.w      26(a1), SHIFTER_PALETTE+26
                    move.w      28(a1), SHIFTER_PALETTE+28
                    move.w      30(a1), SHIFTER_PALETTE+30
                    move.l      (sp)+, a1

                    move.b      #0, MFP_TBCR
                    move.b      #1, MFP_TBDR
                    move.b      #8, MFP_TBCR
                    bclr.b      #0, MFP_ISRA
                    move.l      (sp)+, a0
                    rte

; ----------------------------------------------------------------------------
; BSS
; ----------------------------------------------------------------------------
                    section     BSS

old_timer_b:        ds.l        1
old_tbcr:           ds.b        1
old_tbdr:           ds.b        1
                    even
raster_ptr:         ds.l        1

                    section     TEXT
