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

; Channel B music — a different rip of the tune (SNDH "505"). Same 3-BRA.w
; entry interface, so the music.s wrapper drives it unchanged.
music_sndh_file_b:
                    incbin      'assets/thrust-505.sndh'
                    even
