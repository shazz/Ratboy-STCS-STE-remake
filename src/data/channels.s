; ----------------------------------------------------------------------------
; data/channels.s — Channel descriptor table + analog-static palette
; ----------------------------------------------------------------------------
; A "channel" is a complete set of swappable assets for the cracktro. The
; channel-switch effect (see switch.s) toggles between channel 0 and channel 1,
; flashing TV static in between. Each channel is CHAN_SIZE bytes = 7 longs of
; base pointers; ApplyChannel copies the active row into the chan_* BSS pointers
; that screen.s / vbl.s / hbl.s / engine.s / music.s now read instead of the
; old hardcoded asset labels.
;
; SCAFFOLD: channel 1 currently points at the SAME assets as channel 0. With
; B == A a switch should look like nothing changed except the static flash and
; the music restart — that proves the plumbing. Replace channel 1's entries
; one at a time (e.g. top_logo_bitmap_b, font_bitmap_b, a 2nd .snd) to give the
; second channel its own look.
;
; Field order (must match the ApplyChannel loader in switch.s):
;   0  logo bitmap        4  font palette c1
;   1  logo palette       5  font palette c2
;   2  font bitmap        6  font palette c3
;   3  music SNDH
; ----------------------------------------------------------------------------

CHAN_FIELDS         equ     7
CHAN_SIZE           equ     CHAN_FIELDS*4

                    even
channel_table:
chan0:
                    dc.l    top_logo_bitmap
                    dc.l    top_logo_palette
                    dc.l    font_bitmap
                    dc.l    music_sndh_file
                    dc.l    font_palette_c1
                    dc.l    font_palette_c2
                    dc.l    font_palette_c3
chan1:
                    ; Channel B — being differentiated one asset at a time.
                    dc.l    top_logo_bitmap         ; TODO: top_logo_bitmap_b
                    dc.l    top_logo_palette        ; TODO: top_logo_palette_b
                    dc.l    font_bitmap             ; TODO: font_bitmap_b
                    dc.l    music_sndh_file_b       ; DONE: thrust-505.sndh
                    dc.l    font_palette_c1
                    dc.l    font_palette_c2
                    dc.l    font_palette_c3

; ----------------------------------------------------------------------------
; noise_palette — 16 distinct STE grays (black→white) for the static flash.
; Pixels are random across all 4 bitplanes, so each pixel lands on a random
; gray — convincing TV snow. (On STE all 16 nibble values are distinct
; intensities; the index→gray mapping is irrelevant since pixels are random.)
; ----------------------------------------------------------------------------
                    even
noise_palette:
                    dc.w    $000,$111,$222,$333,$444,$555,$666,$777
                    dc.w    $888,$999,$AAA,$BBB,$CCC,$DDD,$EEE,$FFF
