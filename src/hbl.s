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
;
; SESSION 4 FIX (2026-04-29): Skip palette write for scanlines 107-111.
; The move.w to SHIFTER_PALETTE during those specific scanlines causes a
; bus collision with Shifter DMA fetch, shifting row 1's last 5 lines by
; 32 pixels. Skipping the write creates a 5-line "freeze" in the gradient
; (imperceptible since it's in the red-to-dark transition area).
;
; Also handles font palette swaps: c1 at line 77, c2 at line 118, c3 at line 159.
; ----------------------------------------------------------------------------
RASTER_SKIP_START       equ     raster_table+107*2      ; scanline 107
RASTER_SKIP_END         equ     raster_table+112*2      ; scanline 112 (exclusive)
RASTER_SWAP_C1          equ     raster_table+77*2       ; before row 1 (Y=78)
RASTER_SWAP_C2_DEFAULT  equ     raster_table+118*2      ; multi-row layout (Y=119)
RASTER_SWAP_C2_TYPE4    equ     raster_table+131*2      ; mirror line (Y=132)
RASTER_SWAP_C3          equ     raster_table+159*2      ; before row 3 (Y=160)

TimerBHandler:
                    move.l      a0, -(sp)
                    move.l      raster_ptr, a0

                    ; Check for font palette swaps at row boundaries.
                    ; The c2 swap address is a variable so effect 4 can move
                    ; the swap from line 118 to line 131 (mirror line).
                    cmpa.l      #RASTER_SWAP_C1, a0
                    beq.s       .swap_c1
                    cmpa.l      raster_swap_c2_addr, a0
                    beq.s       .swap_c2
                    cmpa.l      #RASTER_SWAP_C3, a0
                    beq.s       .swap_c3
                    bra.s       .check_skip

.swap_c1:
                    movem.l     d0-d7/a1, -(sp)
                    move.l      font_pal_ptr1, a1
                    movem.l     2(a1), d0-d6
                    movem.l     d0-d6, SHIFTER_PALETTE+2
                    movem.l     (sp)+, d0-d7/a1
                    bra.s       .check_skip

.swap_c2:
                    movem.l     d0-d7/a1, -(sp)
                    move.l      font_pal_ptr2, a1
                    movem.l     2(a1), d0-d6
                    movem.l     d0-d6, SHIFTER_PALETTE+2
                    movem.l     (sp)+, d0-d7/a1
                    bra.s       .check_skip

.swap_c3:
                    movem.l     d0-d7/a1, -(sp)
                    move.l      font_pal_ptr3, a1
                    movem.l     2(a1), d0-d6
                    movem.l     d0-d6, SHIFTER_PALETTE+2
                    movem.l     (sp)+, d0-d7/a1

.check_skip:
                    ; Skip palette write for scanlines 107-111 to avoid
                    ; Shifter bus collision that causes row-1 glitch.
                    cmpa.l      #RASTER_SKIP_START, a0
                    blo.s       .do_write
                    cmpa.l      #RASTER_SKIP_END, a0
                    bhs.s       .do_write
                    addq.l      #2, a0
                    bra.s       .done

.do_write:
                    move.w      (a0)+, SHIFTER_PALETTE

.done:
                    move.l      a0, raster_ptr
                    bclr.b      #0, MFP_ISRA
                    move.l      (sp)+, a0
                    rte

; ----------------------------------------------------------------------------
; SetPalettePointers — set up palette pointers + c2 swap address based on
; effect type.
;
; d0.w = effect type (0-7)
; - Single-row effects (1, 2, 3, 5): all pointers → c1
; - Multi-row effects (0, 6, 7):     ptr1→c1, ptr2→c2, ptr3→c3
; - Type 4 mirror:                   ptr1→c1, ptr2→c2, ptr3→c2
;                                     c2 swap relocated to line 131 (mirror)
; ----------------------------------------------------------------------------
SetPalettePointers:
                    lea         font_palette_c1, a0
                    move.l      a0, font_pal_ptr1       ; row 1 always c1

                    ; Default c2 swap fires at line 118 (multi-row layout)
                    move.l      #RASTER_SWAP_C2_DEFAULT, raster_swap_c2_addr

                    cmp.w       #4, d0
                    beq.s       .type_4_mirror
                    cmp.w       #1, d0
                    beq.s       .single_row
                    cmp.w       #2, d0
                    beq.s       .single_row             ; Type 2 (reflection) uses single palette
                    cmp.w       #3, d0
                    beq.s       .single_row             ; Type 3 (sine + interleave) uses single palette
                    cmp.w       #5, d0
                    beq.s       .single_row             ; Type 5 (4× tall stretch) uses single palette

                    ; Multi-row (0, 6, 7): c1, c2, c3
                    lea         font_palette_c2, a0
                    move.l      a0, font_pal_ptr2
                    lea         font_palette_c3, a0
                    move.l      a0, font_pal_ptr3
                    rts

.single_row:
                    ; Single-row: all c1
                    lea         font_palette_c1, a0
                    move.l      a0, font_pal_ptr2
                    move.l      a0, font_pal_ptr3
                    rts

.type_4_mirror:
                    ; Mirror: c1 above the symmetry line, c2 below.
                    ; Move the c2 swap from line 118 to line 131 (just before
                    ; the mirror line at Y=132). ptr3 stays c2 so the c3
                    ; swap at line 159 doesn't switch back.
                    lea         font_palette_c2, a0
                    move.l      a0, font_pal_ptr2
                    move.l      a0, font_pal_ptr3
                    move.l      #RASTER_SWAP_C2_TYPE4, raster_swap_c2_addr
                    rts

; ----------------------------------------------------------------------------
; BSS
; ----------------------------------------------------------------------------
                    section     BSS

old_timer_b:        ds.l        1
old_tbcr:           ds.b        1
old_tbdr:           ds.b        1
                    even
raster_ptr:         ds.l        1
font_pal_ptr1:      ds.l        1               ; palette pointer for row 1
font_pal_ptr2:      ds.l        1               ; palette pointer for row 2
font_pal_ptr3:      ds.l        1               ; palette pointer for row 3
raster_swap_c2_addr: ds.l       1               ; raster_table addr where c2 swap fires

                    section     TEXT
