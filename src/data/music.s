; ----------------------------------------------------------------------------
; data/music.s — SNDH music file (player code + YM data, packaged together)
; ----------------------------------------------------------------------------
; This is a raw SNDH dump of the "Thrust" tune (as used in the original
; Bladerunners cracktro sound). The file starts with three BRA.w's at
; offsets 0/4/8 which are the init/exit/play entry points — see music.s.
;
; The file MUST be word-aligned for the entry-point BRAs to execute correctly.
; ----------------------------------------------------------------------------

                    even
music_sndh_file:
                    incbin      'assets/thrust.snd'
                    even

; Channel B music — "Jess / For Your Loader 1". A loader tune: its replay is
; lightweight and fits in vblank, so it does NOT overrun into the visible area
; and block the Timer-B raster (which would kill the gradient). It also leaves
; Timer B alone. (The 505/maxYMiser rips grabbed Timer B → crash; Cassiope was
; clean but too slow → muted gradient. Loader tunes are the right fit here.)
music_sndh_file_b:
                    incbin      'assets/jess_loader1.sndh'
                    even
