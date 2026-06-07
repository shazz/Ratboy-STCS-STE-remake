; ----------------------------------------------------------------------------
; noise.s — Analog-TV static for the channel switch (see switch.s)
; ----------------------------------------------------------------------------
; A real full-screen random write every frame won't fit a 50 Hz / 8 MHz budget
; (the 36 KB store alone is ~110k cy). Instead noise_field (one screen +
; NOISE_SLACK) is filled ONCE with a fast Galois LFSR, then each frame the STE
; screen base is pointed at a random offset into it — a different random slice
; shows every frame → true 50 Hz scintillating snow, nearly free.
;
; Timer-B (the gradient ISR) is masked during the flash so it doesn't overwrite
; color 0; the VBL handler is gated via noise_active (set in switch.s) so it
; doesn't reinstall the logo palette over the grayscale snow palette.
; ----------------------------------------------------------------------------

LFSR_POLY           equ     $04C11DB7               ; CRC-32 feedback for the noise LFSR

; ----------------------------------------------------------------------------
; DoStaticPhase — hold the snow for NOISE_FRAMES frames, panning each frame.
; Clobbers: d0/d1/d6/d7, a0.
; ----------------------------------------------------------------------------
DoStaticPhase:
                    move.w      #NOISE_FRAMES-1, d6
.loop:
                    WAIT_VBL                            ; clobbers d7
                    bsr         NoisePanFrame           ; clobbers d0/d1/a0 (not d6)
                    dbra        d6, .loop
                    rts

; ----------------------------------------------------------------------------
; NoisePanFrame — advance the LFSR, point the STE screen base at a random
; (even-aligned) offset into noise_field. Clobbers: d0, d1, a0.
; ----------------------------------------------------------------------------
NoisePanFrame:
                    move.l      noise_seed, d0
                    bsr         .lfsr_step
                    bsr         .lfsr_step              ; 2 steps → decorrelated offset
                    move.l      d0, noise_seed
                    and.l       #NOISE_SLACK-2, d0      ; mask to slack range, even-align
                    lea         noise_field, a0
                    adda.l      d0, a0
                    move.l      a0, d1
                    move.b      d1, SCREEN_BASE_LOW     ; STE byte-aligned base
                    lsr.l       #8, d1
                    move.b      d1, SCREEN_BASE_MID
                    lsr.l       #8, d1
                    move.b      d1, SCREEN_BASE_HIGH
                    rts
.lfsr_step:
                    add.l       d0, d0
                    bcc.s       .ls_done
                    eori.l      #LFSR_POLY, d0
.ls_done:
                    rts

; ----------------------------------------------------------------------------
; NoiseFillField — fill noise_field once with the Galois LFSR (boot-time).
; One-time ~0.6M cy. Clobbers: d0-d2, a0.
; ----------------------------------------------------------------------------
NoiseFillField:
                    move.l      noise_seed, d0
                    lea         noise_field, a0
                    move.w      #((SCREEN_BYTES+NOISE_SLACK)/4)-1, d2
.fill:
                    add.l       d0, d0
                    bcc.s       .nofb
                    eori.l      #LFSR_POLY, d0
.nofb:
                    move.l      d0, (a0)+
                    dbra        d2, .fill
                    move.l      d0, noise_seed
                    rts

; ----------------------------------------------------------------------------
; InstallNoisePalette — 16 grays for the snow. Clobbers d0-d7, a0.
; ----------------------------------------------------------------------------
InstallNoisePalette:
                    lea         noise_palette, a0
                    movem.l     (a0), d0-d7
                    movem.l     d0-d7, SHIFTER_PALETTE
                    rts

; ----------------------------------------------------------------------------
; MaskTimerB / UnmaskTimerB — gate the gradient ISR. MFP IPRA/IMRA clear-on-
; write-zero semantics make bclr safe (writes 1 to other set bits = no change).
; ----------------------------------------------------------------------------
MaskTimerB:
                    bclr.b      #0, MFP_IMRA
                    rts
UnmaskTimerB:
                    bclr.b      #0, MFP_IPRA            ; drop any pending Timer-B int
                    bset.b      #0, MFP_IMRA
                    rts

; ----------------------------------------------------------------------------
; RestoreScreenBase — point the Shifter back at the real front buffer. Clobbers d0.
; ----------------------------------------------------------------------------
RestoreScreenBase:
                    move.l      front_buffer_ptr, d0
                    move.b      d0, SCREEN_BASE_LOW
                    lsr.l       #8, d0
                    move.b      d0, SCREEN_BASE_MID
                    lsr.l       #8, d0
                    move.b      d0, SCREEN_BASE_HIGH
                    rts

; ----------------------------------------------------------------------------
; BSS
; ----------------------------------------------------------------------------
                    section     BSS

                    even
noise_seed:         ds.l        1               ; Galois LFSR state
noise_field:        ds.b        SCREEN_BYTES+NOISE_SLACK    ; random snow field, panned per frame

                    section     TEXT
