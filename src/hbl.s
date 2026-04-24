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
; InstallHBL — MFP setup; Timer B started in event-count mode and left
; running for the whole demo. Per-frame phasing is achieved by resetting
; raster_ptr in the VBL handler — NOT by re-arming Timer B (which gave
; a 1-scanline frame-to-frame jitter as restart timing crossed DE-pulse
; boundaries unpredictably). MFP auto-reloads TBDR=1 from its latch so
; the timer fires on every DE pulse forever.
; Supervisor mode required.
; ----------------------------------------------------------------------------
InstallHBL:
                    move.l      TIMER_B_VECTOR.w, old_timer_b
                    move.b      MFP_TBCR, old_tbcr
                    move.b      MFP_TBDR, old_tbdr

                    move.b      #0, MFP_TBCR                            ; stop while configuring
                    move.l      #TimerBHandler, TIMER_B_VECTOR.w
                    bset.b      #0, MFP_IERA                            ; enable Timer B
                    bset.b      #0, MFP_IMRA                            ; unmask Timer B

                    move.b      #TIMER_B_INITIAL_COUNT, MFP_TBDR        ; reload value = 1
                    move.l      #raster_table, raster_ptr
                    move.b      #8, MFP_TBCR                            ; start, event-count mode
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
; ArmTimerBRaster — called from VBL each frame. Just resets raster_ptr;
; Timer B is left running continuously by InstallHBL. Resetting only the
; pointer (not the timer itself) eliminates the per-frame restart-jitter
; that used to shift the gradient up/down by 1 scanline between frames.
; ----------------------------------------------------------------------------
ArmTimerBRaster:
                    move.l      #raster_table, raster_ptr
                    rts

; ----------------------------------------------------------------------------
; TimerBHandler — fires on each Shifter DE pulse (every visible scanline).
; MFP event-count mode auto-reloads TBDR from its latch, so no re-arm is
; needed in the hot path — critically, this keeps the ISR short enough to
; co-exist with a cooperative-mode blitter (the blitter re-arbitrates the
; bus every 64 cycles; a re-arm sequence would get stretched and corrupt
; MFP state — see blitter_faq.txt §d and the earlier failed attempt).
;
; At the swap-trigger entry, skips the color 0 write and installs the font
; palette instead (colors 1..15).
; ----------------------------------------------------------------------------
TimerBHandler:
                    move.l      a0, -(sp)
                    move.l      raster_ptr, a0
                    cmp.l       #raster_swap_font, a0
                    beq         .install_font

                    ; Normal: write color 0 from raster table, advance.
                    move.w      (a0)+, SHIFTER_PALETTE
                    move.l      a0, raster_ptr
                    bclr.b      #0, MFP_ISRA
                    move.l      (sp)+, a0
                    rte

.install_font:
                    ; Consume gradient entry (we own color 0 for this scanline).
                    addq.l      #2, a0
                    move.l      a0, raster_ptr

                    ; 8 long writes instead of 15 word writes — ~30% fewer
                    ; cycles. Overwrites color 0 with font_palette_c1[0] for
                    ; THIS scanline only; the next gradient ISR (line 78)
                    ; restores gradient color 0. The font palette's color 0
                    ; is near-black so the 1-line artifact is invisible.
                    move.l      a1, -(sp)
                    lea         font_palette_c1, a1
                    move.l      (a1), SHIFTER_PALETTE
                    move.l      4(a1), SHIFTER_PALETTE+4
                    move.l      8(a1), SHIFTER_PALETTE+8
                    move.l      12(a1), SHIFTER_PALETTE+12
                    move.l      16(a1), SHIFTER_PALETTE+16
                    move.l      20(a1), SHIFTER_PALETTE+20
                    move.l      24(a1), SHIFTER_PALETTE+24
                    move.l      28(a1), SHIFTER_PALETTE+28
                    move.l      (sp)+, a1

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
