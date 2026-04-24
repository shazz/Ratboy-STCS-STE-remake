; ----------------------------------------------------------------------------
; music.s — SNDH music driver wrapper (init / play / exit)
; ----------------------------------------------------------------------------
; SNDH is a "self-contained" YM2149 music format: the .snd file embeds both
; the data and the 68000 player code. The first three BRA.w instructions at
; file start ARE the player's public entry points:
;     offset 0  = init  (d0.w = song number, 1-based)
;     offset 4  = exit
;     offset 8  = play  (call once per replay tick, typically 50 Hz from VBL)
;
; We hook Play into our VBL handler, so at 50 Hz PAL the player runs once
; per frame and updates the YM2149 registers. Simpler than Timer-C replay
; and doesn't tie up an MFP timer.
;
; Pattern (init/play/exit stash a flag so redundant calls are no-ops, and
; so our VBL handler can tst before jsr). Ported from the stvirus template
; but simplified — we only carry one SNDH, no song table.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
; MusicSndhInit — load song 1 into the player.
; Must be called in supervisor mode (SNDH players poke hardware registers).
; No-op if already inited.
; ----------------------------------------------------------------------------
MusicSndhInit:
                    tst.w       MusicIsInited
                    bne.s       .already
                    movem.l     d0-a6, -(sp)
                    lea         music_sndh_file, a0
                    moveq       #1, d0                  ; song number 1 (1-based)
                    jsr         (a0)                    ; offset 0 = init
                    move.w      #1, MusicIsInited
                    movem.l     (sp)+, d0-a6
.already:
                    rts

; ----------------------------------------------------------------------------
; MusicSndhPlay — tick the player once. Safe to call from VBL. No-op if not inited.
; ----------------------------------------------------------------------------
MusicSndhPlay:
                    tst.w       MusicIsInited
                    beq.s       .skip
                    movem.l     d0-a6, -(sp)
                    lea         music_sndh_file, a0
                    jsr         8(a0)                   ; offset 8 = play
                    move.w      #1, MusicIsPlaying
                    movem.l     (sp)+, d0-a6
.skip:
                    rts

; ----------------------------------------------------------------------------
; MusicSndhExit — tear down the player. Restores whatever YM state it chose
; to. No-op if never inited.
; ----------------------------------------------------------------------------
MusicSndhExit:
                    tst.w       MusicIsInited
                    beq.s       .skip
                    ; Clear the flag FIRST so any VBL-driven MusicSndhPlay
                    ; racing with our exit becomes a no-op instead of calling
                    ; into the half-torn-down player.
                    clr.w       MusicIsInited
                    movem.l     d0-a6, -(sp)
                    lea         music_sndh_file, a0
                    jsr         4(a0)                   ; offset 4 = exit
                    clr.w       MusicIsPlaying
                    movem.l     (sp)+, d0-a6
.skip:
                    rts

; ----------------------------------------------------------------------------
; BSS
; ----------------------------------------------------------------------------
                    section     BSS

MusicIsInited:      ds.w        1                       ; 1 = init succeeded
MusicIsPlaying:     ds.w        1                       ; 1 = at least one play tick has run

                    section     TEXT
