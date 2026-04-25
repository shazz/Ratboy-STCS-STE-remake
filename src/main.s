; ============================================================================
; Stargoose Cracktro — Atari STE 68000 port
; (c) 2026 Matt / Anima
;
; Port of RATBOY's 1988 Bladerunners / S.T.C.S. Stargoose cracktro, from
; Shazz's 2011 HTML5/CODEF JavaScript reference port (js_version/main.html).
;
; Target: Atari STE, 50 Hz PAL, low-res 320×200×16.
; Assembler: vasmm68k_mot (Motorola syntax, -spaces flag required).
; Emulator:  Hatari.
;
; main.s is the entry point. It includes every other .s file; VASM makes a
; single pass over the tree to produce one .PRG.
;
; ----------------------------------------------------------------------------
; P5 — Font + single-row scroller
; ----------------------------------------------------------------------------
; Adds a STE HSCROLL-based text scroller at Y=130. The screen buffer is
; widened via LINEWID=12 (3 extra pwords/line = 48 px off-screen right of
; each scanline). The HBL handler writes scroll_hscroll into VIDEO_HSCROLL
; only on scroll-row scanlines, so the logo doesn't wiggle.
;
;   1. supervisor mode
;   2. save TOS state
;   3. init screen: low-res, LINEWID=12, own buffer, logo palette, logo blit
;   4. init scroller: clear row, reset state, prime text cursor
;   5. install VBL + HBL handlers
;   6. init music (song 1)
;   7. lower IPL to 1 → HBL fires, scroll + raster + music all live
;   8. main loop: WAIT_VBL + non-blocking ESC poll
;   9. on ESC: raise IPL, tear down in reverse order, restore, exit
;
; ============================================================================

                    include     "constants.s"
                    include     "macros.s"

                    section     TEXT

; ----------------------------------------------------------------------------
; Entry point — TOS jumps here from the PRG header
; ----------------------------------------------------------------------------
Main:
                    bsr         SuperEnter              ; cross into kernel mode
                    bsr         SaveState               ; snapshot TOS palette/res/base
                    bsr         InitScreen              ; low-res, own buffer, logo painted
                    ifne        SCROLLER_ENABLED
                    bsr         ScrollerInit            ; zero scroll row, reset cursor
                    endif
                    bsr         DisableMouse            ; stop IKBD mouse packets — they shake rasters
                    bsr         InstallVBL              ; claim a vbl-queue slot
                    bsr         InstallHBL              ; hook $68 for the raster gradient
                    ifne        MUSIC_ENABLED
                    bsr         MusicSndhInit           ; song 1 loaded; VBL handler will tick it
                    endif

                    move.w      #$2100, sr              ; IPL=1 — HBL (L2) + VBL (L4) firing

                    bsr         MainLoop                ; blocks until ESC

                    ; Exit music FIRST, while interrupts are still live — the
                    ; SNDH exit routine may expect its VBL/timer context to
                    ; still be functional while it shuts down the YM chip.
                    ; MusicSndhExit self-protects by clearing MusicIsInited
                    ; before the jsr, so VBL ticks become no-ops during exit.
                    ifne        MUSIC_ENABLED
                    bsr         MusicSndhExit
                    endif

                    move.w      #$2700, sr              ; NOW mask all; remove handlers
                    bsr         RemoveHBL
                    bsr         RemoveVBL
                    bsr         EnableMouse             ; hand mouse back to TOS
                    bsr         RestoreState            ; hand TOS back its palette/res/base
                    bsr         SuperExit               ; back to user mode

                    clr.w       -(sp)                   ; Pterm0
                    trap        #GEMDOS
                    ; never returns

; ----------------------------------------------------------------------------
; MainLoop — runs until ESC is detected by CheckEsc.
; Sleeps a VBL, polls keyboard, repeats. All visual work happens in the VBL
; handler (where it's cycle-synced). This loop is just keyboard + throttling.
; ----------------------------------------------------------------------------
MainLoop:
.tick:
                    WAIT_VBL                            ; block one frame
                    ifne        SCROLLER_ENABLED
                    bsr         ScrollerStepVisible     ; rows 2/3 cooperative copy
                                                        ; (heavy work — render + shift
                                                        ;  + row 1 — already done in
                                                        ;  VBL handler in HOG mode)
                    endif
                    bsr         CheckEsc                ; non-blocking keyboard poll
                    tst.w       exit_flag
                    beq.s       .tick
                    rts

; ----------------------------------------------------------------------------
; CheckEsc — non-blocking keyboard poll via GEMDOS.
;   Cconis ($0B): returns d0 = -1 if a char is waiting, 0 otherwise
;   Cconin ($01): reads a char (blocking — safe here because Cconis just said yes)
; On ESC, sets exit_flag. On any other key, consumes it silently.
; Clobbers: d0.
; ----------------------------------------------------------------------------
CheckEsc:
                    move.w      #GEMDOS_CCONIS, -(sp)
                    trap        #GEMDOS
                    addq.l      #2, sp
                    tst.l       d0
                    beq.s       .no_key

                    move.w      #GEMDOS_CRAWCIN, -(sp)  ; no-echo — we own the screen
                    trap        #GEMDOS
                    addq.l      #2, sp

                    cmp.b       #KEY_ESC, d0
                    bne.s       .no_key
                    move.w      #1, exit_flag
.no_key:
                    rts

; ----------------------------------------------------------------------------
; Subsystems
; ----------------------------------------------------------------------------
                    include     "system.s"
                    include     "screen.s"
                    include     "music.s"
                    include     "scroller/engine.s"
                    include     "vbl.s"
                    include     "hbl.s"
                    include     "data/background.s"
                    include     "data/font.s"
                    include     "data/scrolltext.s"
                    include     "data/music.s"
                    include     "data/gradient.s"

; ----------------------------------------------------------------------------
; BSS — per-module vars live in their own files; main's own vars live here.
; ----------------------------------------------------------------------------
                    section     BSS

exit_flag:          ds.w        1                       ; nonzero = ESC was pressed
