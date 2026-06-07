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

; Timer B counts DE pulses (one per visible scanline). TBDR=N → fire every
; N pulses. With TBDR=2, fires at lines 1, 3, 5, ..., 199 (100/frame, half
; the rate of TBDR=1). Halves ISR overhead at the cost of 2-line gradient
; bands instead of 1-line.
;
; Phase is stable across frames because 200 (visible lines) / 2 = 100 with no
; remainder. raster_ptr advances by RASTER_FIRE_STRIDE bytes per fire so the
; handler reads every 2nd entry of the original 200-entry gradient table.
TIMER_B_INITIAL_COUNT equ   2

; Bytes raster_ptr advances per fire. With TBDR=2, fires happen every 2nd
; scanline, so we step by 2 entries × 2 bytes/entry = 4 bytes. Markers must
; be placed at byte offsets that are multiples of this stride.
RASTER_FIRE_STRIDE  equ     4

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
                    ; Snapshot the (known-good) MFP edge/direction config for
                    ; Timer-B's DE event input. The SNDH music exit/init can
                    ; disturb these, killing the gradient after a switch; the
                    ; switch restores them (see noise.s UnmaskTimerB).
                    move.b      MFP_AER, mfp_aer_save
                    move.b      MFP_DDR, mfp_ddr_save

                    move.l      #raster_table, raster_table_active  ; channel A default
                    bsr         BuildRasterTableB              ; channel-B table (gradient→colour1)

                    ; Encode static markers in raster_table at fire-aligned
                    ; byte offsets (multiples of RASTER_FIRE_STRIDE). Set once;
                    ; they persist in raster_table for the rest of the run.
                    move.w      #MARK_SKIP, RASTER_SKIP_FIRE1   ; line 107
                    move.w      #MARK_SKIP, RASTER_SKIP_FIRE2   ; line 109
                    move.w      #MARK_SKIP, RASTER_SKIP_FIRE3   ; line 111
                    or.w        #MARK_C3, RASTER_SWAP_C3        ; line 159 swap+color

                    bsr         SetupTimerB
                    rts

; ----------------------------------------------------------------------------
; SetupTimerB — (re)establish the full Timer-B raster hardware: stop, install
; the handler vector, enable + unmask the channel in the MFP, reload TBDR,
; re-arm raster_ptr, start event-count mode. Called by InstallHBL AND by the
; channel switch (noise.s UnmaskTimerB): both tunes are TC50 (Timer-C) SNDH
; players, so MusicSndhExit/Init reprogram the MFP — after a switch the WHOLE
; Timer-B config must be restored, not just TBCR/TBDR. (Static markers persist
; in raster_table; SetPalettePointers re-places the dynamic c1/c2 markers.)
; ----------------------------------------------------------------------------
SetupTimerB:
                    move.b      #0, MFP_TBCR                            ; stop while configuring
                    move.l      #TimerBHandler, TIMER_B_VECTOR.w
                    bset.b      #0, MFP_IERA                            ; enable Timer B
                    bset.b      #0, MFP_IMRA                            ; unmask Timer B
                    move.b      #TIMER_B_INITIAL_COUNT, MFP_TBDR
                    move.l      raster_table_active, raster_ptr
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
                    move.l      raster_table_active, raster_ptr
                    rts

; ----------------------------------------------------------------------------
; TimerBHandler — fires on each Shifter DE pulse (every visible scanline).
;
; SESSION 6 OPTIMIZATION (2026-05-01): Inline action codes in raster_table
; values themselves. Top nibble of each word encodes what to do:
;   $0RGB = normal: write color
;   $4xxx = skip:   no write (bus-collision range, lines 107..111)
;   $8RGB = swap c1: write color (top nibble masked by hardware) + load c1
;   $9RGB = swap c2: write color + load c2
;   $ARGB = swap c3: write color + load c3
;
; Common path (~190 fires/frame) is just: read word, check sign bit + bit 14,
; write color, advance ptr — ~176 cy vs ~220 cy in the multi-cmpa.l version.
;
; Static markers (skip range, c3 swap) are patched into raster_table at
; InstallHBL time. Dynamic markers (c1, c2) are placed by SetPalettePointers
; whenever the effect type changes (with old marker auto-cleared by AND).
;
; SESSION 4 history: The skip range fix was added because the Shifter DMA
; fetch collides with palette writes on lines 107..111, shifting row 1's
; last 5 lines by 32 px. The encoded $4xxx marker preserves that fix.
; ----------------------------------------------------------------------------
; Marker byte offsets in raster_table. Fire i (0..99) reads byte i*4. So markers
; must go at byte offsets divisible by RASTER_FIRE_STRIDE (=4). Each entry maps
; to scanline 1+2i (phase 1, fires on odd lines).
;
; Target line → fire i → byte offset = i * RASTER_FIRE_STRIDE.
;   77 → 38 → 152 (c1 default, exact)
;   73 → 36 → 144 (c1 type7, exact)
;  118 → 58 → 232 (c2 default, fires at line 117 — 1 line early, all-background)
;  131 → 65 → 260 (c2 type4, exact)
;  121 → 60 → 240 (c2 type7, exact)
;  159 → 79 → 316 (c3, exact)
RASTER_SWAP_C1_DEFAULT  equ     raster_table+38*RASTER_FIRE_STRIDE   ; line 77
RASTER_SWAP_C1_TYPE7    equ     raster_table+36*RASTER_FIRE_STRIDE   ; line 73
RASTER_SWAP_C2_DEFAULT  equ     raster_table+58*RASTER_FIRE_STRIDE   ; line 117 (was 118)
RASTER_SWAP_C2_TYPE4    equ     raster_table+65*RASTER_FIRE_STRIDE   ; line 131
RASTER_SWAP_C2_TYPE7    equ     raster_table+60*RASTER_FIRE_STRIDE   ; line 121
RASTER_SWAP_C3          equ     raster_table+79*RASTER_FIRE_STRIDE   ; line 159

; Skip fires within bus-collision range (lines 107, 109, 111 with phase-1).
RASTER_SKIP_FIRE1       equ     raster_table+53*RASTER_FIRE_STRIDE   ; line 107
RASTER_SKIP_FIRE2       equ     raster_table+54*RASTER_FIRE_STRIDE   ; line 109
RASTER_SKIP_FIRE3       equ     raster_table+55*RASTER_FIRE_STRIDE   ; line 111

; Marker top-nibbles (OR'd into raster_table words):
MARK_SKIP   equ     $4000
MARK_C1     equ     $8000
MARK_C2     equ     $9000
MARK_C3     equ     $A000

; NOTE: internal labels are GLOBAL (tb_*) on purpose — the GradWrite label below
; must be global so SetGradTarget* can self-modify its operand, and mixing a
; global label among local (.foo) labels would break local-label scoping.
TimerBHandler:
                    move.l      a0, -(sp)
                    move.l      d0, -(sp)
                    move.l      raster_ptr, a0
                    move.w      (a0)+, d0               ; +2, sets flags from d0
                    bmi.s       tb_swap                 ; bit 15 = swap action
                    btst        #14, d0
                    bne.s       tb_skip                 ; bit 14 = skip (no write)

                    ; Common path: write gradient to the patched target register.
                    ; GradWrite's abs.l dest operand is self-modified per channel:
                    ; $FF8240 (colour 0 — channel A backdrop) or $FF8242 (colour 1
                    ; — channel B's font register, so colour 0 stays solid black).
GradWrite:
                    move.w      d0, SHIFTER_PALETTE
                    addq.l      #RASTER_FIRE_STRIDE-2, a0  ; +(stride-2) to total stride
                    move.l      a0, raster_ptr
tb_exit:
                    bclr.b      #0, MFP_ISRA
                    move.l      (sp)+, d0
                    move.l      (sp)+, a0
                    rte

tb_skip:
                    addq.l      #RASTER_FIRE_STRIDE-2, a0
                    move.l      a0, raster_ptr
                    bra.s       tb_exit

tb_swap:
                    addq.l      #RASTER_FIRE_STRIDE-2, a0
                    move.l      a0, raster_ptr
                    move.w      d0, SHIFTER_PALETTE     ; channel-A swaps write colour 0
                    cmp.w       #$8FFF, d0
                    bls.s       tb_swap_c1              ; $8000..$8FFF
                    cmp.w       #$9FFF, d0
                    bls.s       tb_swap_c2              ; $9000..$9FFF
                    ; Fall through: $A000..$AFFF = swap c3

tb_swap_c3:
                    movem.l     d1-d7/a1, -(sp)
                    move.l      font_pal_ptr3, a1
                    movem.l     2(a1), d1-d7
                    movem.l     d1-d7, SHIFTER_PALETTE+2
                    movem.l     (sp)+, d1-d7/a1
                    bra         tb_exit
tb_swap_c2:
                    movem.l     d1-d7/a1, -(sp)
                    move.l      font_pal_ptr2, a1
                    movem.l     2(a1), d1-d7
                    movem.l     d1-d7, SHIFTER_PALETTE+2
                    movem.l     (sp)+, d1-d7/a1
                    bra         tb_exit
tb_swap_c1:
                    movem.l     d1-d7/a1, -(sp)
                    move.l      font_pal_ptr1, a1
                    movem.l     2(a1), d1-d7
                    movem.l     d1-d7, SHIFTER_PALETTE+2
                    movem.l     (sp)+, d1-d7/a1
                    bra         tb_exit

; ----------------------------------------------------------------------------
; SetGradTargetColor0 / ...Color1 — self-modify GradWrite's abs.l dest operand
; (the low byte of the 32-bit address) to point the per-scanline gradient write
; at colour register 0 ($FF8240) or colour register 1 ($FF8242). The ST 68000
; has no instruction cache, so patching code in place is safe.
; ----------------------------------------------------------------------------
SetGradTargetColor0:
                    move.b      #$40, GradWrite+5      ; abs.l addr low byte → colour 0
                    rts
SetGradTargetColor1:
                    move.b      #$42, GradWrite+5      ; → colour 1 (the font register)
                    rts

; ----------------------------------------------------------------------------
; BuildRasterTableB — build the channel-B raster table from the gradient: the
; logo region (Y < TOP_LOGO_HEIGHT) is marked SKIP so colour 1 keeps the logo's
; palette there; the scroll region holds the raw gradient colours (normal write
; → patched target = colour 1). Bus-collision lines are skipped as on channel A.
; Markers from channel A are stripped via AND $0FFF. One-time, at InstallHBL.
; ----------------------------------------------------------------------------
BuildRasterTableB:
                    lea         raster_table, a0
                    lea         raster_table_b, a1
                    moveq       #0, d2                  ; scanline / entry index
                    move.w      #RASTER_TABLE_SLOTS-1, d1
.bcopy:
                    move.w      (a0)+, d0
                    and.w       #$0FFF, d0              ; strip any markers → raw colour
                    cmp.w       #TOP_LOGO_HEIGHT, d2    ; logo occupies Y 0..73
                    bhs.s       .bkeep
                    move.w      #MARK_SKIP, d0          ; logo region: don't touch colour 1
.bkeep:
                    move.w      d0, (a1)+
                    addq.w      #1, d2
                    dbra        d1, .bcopy
                    move.w      #MARK_SKIP, raster_table_b+53*RASTER_FIRE_STRIDE
                    move.w      #MARK_SKIP, raster_table_b+54*RASTER_FIRE_STRIDE
                    move.w      #MARK_SKIP, raster_table_b+55*RASTER_FIRE_STRIDE
                    rts

; ----------------------------------------------------------------------------
; ApplyChannelRaster — configure the raster path for the active channel.
;   channel A: gradient on colour 0 (backdrop), font via c1/c2/c3 swaps.
;   channel B: gradient on colour 1 (font), colour 0 stays black, no swaps.
; Called from the channel switch (replaces the bare SetPalettePointers call).
; ----------------------------------------------------------------------------
ApplyChannelRaster:
                    tst.w       active_channel
                    bne.s       .acr_b
                    move.l      #raster_table, raster_table_active
                    bsr         SetGradTargetColor0
                    move.w      scroll_effect_type, d0
                    bra         SetPalettePointers      ; tail-call (sets markers + font_pal_ptr)
.acr_b:
                    move.l      #raster_table_b, raster_table_active
                    bra         SetGradTargetColor1     ; tail-call

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
                    ; Clear OLD c1/c2 markers in raster_table (in case effect
                    ; changed). Skipped on first call when addrs are still 0.
                    move.l      raster_swap_c1_addr, a0
                    cmpa.l      #0, a0
                    beq.s       .no_old_c1
                    and.w       #$0FFF, (a0)
.no_old_c1:
                    move.l      raster_swap_c2_addr, a0
                    cmpa.l      #0, a0
                    beq.s       .no_old_c2
                    and.w       #$0FFF, (a0)
.no_old_c2:

                    move.l      chan_font_pal_c1, a0
                    move.l      a0, font_pal_ptr1       ; row 1 always c1

                    ; Default raster swap addresses (overridden per-effect below)
                    move.l      #RASTER_SWAP_C1_DEFAULT, raster_swap_c1_addr
                    move.l      #RASTER_SWAP_C2_DEFAULT, raster_swap_c2_addr

                    cmp.w       #4, d0
                    beq.s       .type_4_mirror
                    cmp.w       #7, d0
                    beq.s       .type_7_triangles
                    cmp.w       #1, d0
                    beq.s       .single_row
                    cmp.w       #2, d0
                    beq.s       .single_row             ; Type 2 (reflection) uses single palette
                    cmp.w       #3, d0
                    beq.s       .single_row             ; Type 3 (sine + interleave) uses single palette
                    cmp.w       #5, d0
                    beq.s       .single_row             ; Type 5 (4× tall stretch) uses single palette

                    ; Multi-row (0, 6): c1, c2, c3
                    move.l      chan_font_pal_c2, a0
                    move.l      a0, font_pal_ptr2
                    move.l      chan_font_pal_c3, a0
                    move.l      a0, font_pal_ptr3
                    bra.s       .apply_markers

.single_row:
                    ; Single-row: all c1
                    move.l      chan_font_pal_c1, a0
                    move.l      a0, font_pal_ptr2
                    move.l      a0, font_pal_ptr3
                    bra.s       .apply_markers

.type_4_mirror:
                    ; Mirror: c1 above the symmetry line, c2 below.
                    ; Move the c2 swap from line 118 to line 131 (just before
                    ; the mirror line at Y=132). ptr3 stays c2 so the c3
                    ; swap at line 159 doesn't switch back.
                    move.l      chan_font_pal_c2, a0
                    move.l      a0, font_pal_ptr2
                    move.l      a0, font_pal_ptr3
                    move.l      #RASTER_SWAP_C2_TYPE4, raster_swap_c2_addr
                    bra.s       .apply_markers

.type_7_triangles:
                    ; Triangle 1 = c1, Triangle 2 = c2, Bottom row = c3.
                    ; C1 swap moved 4 lines earlier (line 73, c1 from Y=74)
                    ; to give triangle 1 a bit of headroom.
                    ; C2 swap relocated to line 121 (between the apexes of
                    ; the two triangles); C3 swap stays at line 159.
                    move.l      chan_font_pal_c2, a0
                    move.l      a0, font_pal_ptr2
                    move.l      chan_font_pal_c3, a0
                    move.l      a0, font_pal_ptr3
                    move.l      #RASTER_SWAP_C1_TYPE7, raster_swap_c1_addr
                    move.l      #RASTER_SWAP_C2_TYPE7, raster_swap_c2_addr
                    ; fall through

.apply_markers:
                    ; OR the marker top-nibbles into raster_table at the
                    ; current c1/c2 swap positions. Color (low 12 bits) is
                    ; preserved; hardware ignores top 4 bits on palette write.
                    move.l      raster_swap_c1_addr, a0
                    or.w        #MARK_C1, (a0)
                    move.l      raster_swap_c2_addr, a0
                    or.w        #MARK_C2, (a0)
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
raster_swap_c1_addr: ds.l       1               ; raster_table addr where c1 swap fires
raster_swap_c2_addr: ds.l       1               ; raster_table addr where c2 swap fires
raster_table_active: ds.l       1               ; raster_table (A) or raster_table_b (B)
mfp_aer_save:       ds.b        1               ; good Timer-B input edge config (snapshot)
mfp_ddr_save:       ds.b        1
                    even
raster_table_b:      ds.w        320             ; RASTER_TABLE_SLOTS; channel-B table
                                                ; (gradient→colour 1, logo region skipped)

                    section     TEXT
