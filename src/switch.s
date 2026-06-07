; ----------------------------------------------------------------------------
; switch.s — Channel switch ("TV channel flip") effect: orchestration
; ----------------------------------------------------------------------------
; A "channel" is a complete swappable asset set (logo, font, palettes, music)
; described by a row in channel_table (data/channels.s). The effect toggles
; between channel 0 and channel 1:
;
;   1. byte-9 marker in the scroll text sets switch_pending (see engine.s)
;   2. MainLoop notices the flag and calls DoChannelSwitch (main-loop context,
;      NOT an ISR — the blocking static phase is safe here)
;   3. music stops, the whole screen fills with analog static for NOISE_FRAMES
;      (the snow itself lives in noise.s)
;   4. the active channel toggles, all chan_* pointers are repointed, the logo
;      is repainted, music re-inits, the scroller resets → new "broadcast"
;
; The chan_* pointers replace the formerly-hardcoded asset labels in screen.s /
; vbl.s / hbl.s / engine.s / music.s, matching the project's indirect-pointer
; style (the palette pointers in hbl.s).
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
; InitChannels — boot setup: select channel 0, load its pointers, fill the
; noise field once. MUST run before InitScreen (which paints via chan_*).
; Clobbers: d0-d2, a0.
; ----------------------------------------------------------------------------
InitChannels:
                    clr.w       active_channel
                    clr.w       switch_pending
                    clr.w       noise_active
                    move.l      #$13579BDF, noise_seed  ; arbitrary nonzero LFSR seed
                    bsr         ApplyChannel
                    bsr         NoiseFillField
                    rts

; ----------------------------------------------------------------------------
; ApplyChannel — copy channel_table[active_channel] into the chan_* pointers.
; Field order MUST match data/channels.s. Clobbers: d0, a0.
; ----------------------------------------------------------------------------
ApplyChannel:
                    move.w      active_channel, d0
                    mulu.w      #CHAN_SIZE, d0          ; row byte offset
                    lea         channel_table, a0
                    adda.l      d0, a0
                    move.l      (a0)+, chan_logo_bitmap
                    move.l      (a0)+, chan_logo_palette
                    move.l      (a0)+, chan_font_base
                    move.l      (a0)+, chan_music_ptr
                    move.l      (a0)+, chan_font_pal_c1
                    move.l      (a0)+, chan_font_pal_c2
                    move.l      (a0)+, chan_font_pal_c3
                    rts

; ----------------------------------------------------------------------------
; DoChannelSwitch — the whole flip. Called from MainLoop when switch_pending.
; Runs in main-loop context (interrupts live; noise_active gates the VBL and
; Timer-B is masked so nothing fights the static). See noise.s for the snow.
; ----------------------------------------------------------------------------
DoChannelSwitch:
                    movem.l     d0-d7/a0-a6, -(sp)
                    move.w      #1, noise_active        ; gate the VBL handler
                    ifne        RASTER_ENABLED
                    bsr         MaskTimerB              ; STOP Timer B before touching music —
                    endif                               ; the SNDH may share it; avoids a fire
                    ifne        MUSIC_ENABLED            ; into half-torn-down replay code
                    bsr         MusicSndhExit           ; silence
                    endif
                    bsr         InstallNoisePalette
                    bsr         DoStaticPhase           ; ~NOISE_FRAMES of snow
                    move.w      active_channel, d0      ; toggle A<->B
                    eori.w      #1, d0
                    move.w      d0, active_channel
                    bsr         ApplyChannel
                    bsr         RestoreScreenBase       ; base → real front buffer
                    bsr         RepaintChannel          ; clear both buffers + new logo
                    ifne        MUSIC_ENABLED
                    bsr         MusicSndhInit           ; new channel's music
                    endif
                    ; Configure the raster path for the new channel (A: gradient
                    ; on colour 0 + font swaps; B: gradient on colour 1, colour 0
                    ; black, no swaps). Does NOT reset the scroller — the text
                    ; continues where it left off, not from the top.
                    bsr         ApplyChannelRaster
                    bsr         InstallChannelLogoPalette
                    ifne        RASTER_ENABLED
                    bsr         UnmaskTimerB
                    endif
                    clr.w       noise_active
                    clr.w       switch_pending
                    movem.l     (sp)+, d0-d7/a0-a6
                    rts

; ----------------------------------------------------------------------------
; RepaintChannel — clear both screen buffers and paint the (new) channel logo
; into both. Removes the snow from the logo + inter-row gaps; the scroller
; re-plots the row regions over the next frames. Clobbers: d0-d2, a0, a1.
; ----------------------------------------------------------------------------
RepaintChannel:
                    move.l      screen_buffer_a, a0
                    bsr         ClearScreenBuffer
                    move.l      screen_buffer_b, a0
                    bsr         ClearScreenBuffer
                    move.l      screen_buffer_a, a1
                    bsr         PaintLogoInto
                    move.l      screen_buffer_b, a1
                    bsr         PaintLogoInto
                    rts

; ----------------------------------------------------------------------------
; InstallChannelLogoPalette — the active channel's logo palette. Clobbers d0-d7, a0.
; ----------------------------------------------------------------------------
InstallChannelLogoPalette:
                    move.l      chan_logo_palette, a0
                    movem.l     (a0), d0-d7
                    movem.l     d0-d7, SHIFTER_PALETTE
                    rts

; ----------------------------------------------------------------------------
; BSS
; ----------------------------------------------------------------------------
                    section     BSS

active_channel:     ds.w        1               ; 0 or 1 — current channel
switch_pending:     ds.w        1               ; set by byte-9 marker, read by MainLoop
noise_active:       ds.w        1               ; 1 while the static flash is showing (gates VBL)
                    even

; Active asset pointers (loaded by ApplyChannel from channel_table).
chan_logo_bitmap:   ds.l        1
chan_logo_palette:  ds.l        1
chan_font_base:     ds.l        1
chan_music_ptr:     ds.l        1
chan_font_pal_c1:   ds.l        1
chan_font_pal_c2:   ds.l        1
chan_font_pal_c3:   ds.l        1

                    section     TEXT
