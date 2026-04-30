; ----------------------------------------------------------------------------
; constants.s — Hardware register equates and system constants
; ----------------------------------------------------------------------------
; Atari STE hardware addresses, TOS system variables, and GEMDOS/XBIOS trap
; function numbers. Include this first in every assembly file that needs them.
; No code, no data — pure equates.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
; Shifter (video subsystem)
; ----------------------------------------------------------------------------
SHIFTER_BASE        equ     $FF8200
SCREEN_BASE_HIGH    equ     $FF8201                 ; byte: bits 23-16 of screen addr
SCREEN_BASE_MID     equ     $FF8203                 ; byte: bits 15-8  of screen addr
SCREEN_BASE_LOW     equ     $FF820D                 ; byte: STE only, bits 7-0
VIDEO_COUNTER_HIGH  equ     $FF8205                 ; current scanline read pos
VIDEO_COUNTER_MID   equ     $FF8207
VIDEO_COUNTER_LOW   equ     $FF8209
VIDEO_SYNC          equ     $FF820A                 ; 00=60Hz, $02=50Hz
VIDEO_LINEWID       equ     $FF820F                 ; STE: extra words per scanline
SHIFTER_PALETTE     equ     $FF8240                 ; 16 × word palette
SHIFTER_RES         equ     $FF8260                 ; byte: 0=low 1=med 2=hi
VIDEO_HSCROLL       equ     $FF8265                 ; STE: fine pixel hscroll (0..15)

; ----------------------------------------------------------------------------
; MFP 68901 (timers, interrupts)
; ----------------------------------------------------------------------------
MFP_GPIP            equ     $FFFA01
MFP_AER             equ     $FFFA03
MFP_DDR             equ     $FFFA05
MFP_IERA            equ     $FFFA07
MFP_IERB            equ     $FFFA09
MFP_IPRA            equ     $FFFA0B
MFP_IPRB            equ     $FFFA0D
MFP_ISRA            equ     $FFFA0F
MFP_ISRB            equ     $FFFA11
MFP_IMRA            equ     $FFFA13
MFP_IMRB            equ     $FFFA15
MFP_VR              equ     $FFFA17
MFP_TACR            equ     $FFFA19
MFP_TBCR            equ     $FFFA1B
MFP_TCDCR           equ     $FFFA1D
MFP_TADR            equ     $FFFA1F
MFP_TBDR            equ     $FFFA21
MFP_TCDR            equ     $FFFA23
MFP_TDDR            equ     $FFFA25

; ----------------------------------------------------------------------------
; Interrupt vectors (in low RAM)
; ----------------------------------------------------------------------------
HBL_VECTOR          equ     $68                     ; Level 2 autovector (HBL)
VBL_VECTOR          equ     $70                     ; Level 4 autovector (VBL)

; ----------------------------------------------------------------------------
; TOS system variables (low RAM)
; ----------------------------------------------------------------------------
VBLSEM              equ     $452                    ; if nonzero, VBL queue runs
VBLQUEUE            equ     $456                    ; pointer to VBL queue
VRAM_PTR            equ     $44E                    ; logical screen base

; ----------------------------------------------------------------------------
; Feature toggles (for diagnostics)
; ----------------------------------------------------------------------------
; 1 = music enabled; 0 = skip MusicSndhPlay calls (isolate blitter etc.)
MUSIC_ENABLED       equ     1
; 1 = scroller enabled; 0 = skip ScrollerInit + ScrollerStep (no blitter
; activity at all — use to verify Timer-B rasters in isolation).
SCROLLER_ENABLED    equ     1
; 1 = raster (Timer-B per-scanline color 0 + line-77 font-palette swap)
; enabled; 0 = skip InstallHBL/RemoveHBL entirely. With RASTER_ENABLED=0
; the screen displays in LOGO palette only, no gradient — useful to test
; whether per-scanline ISR activity is interacting with the scroller.
RASTER_ENABLED      equ     1

; ----------------------------------------------------------------------------
; Trap numbers
; ----------------------------------------------------------------------------
GEMDOS              equ     1
BIOS                equ     13
XBIOS               equ     14

; GEMDOS functions
GEMDOS_PTERM0       equ     $00                     ; terminate process, return 0
GEMDOS_CCONIN       equ     $01                     ; read char from console, echo
GEMDOS_CRAWCIN      equ     $07                     ; read char, no echo (preferred while we own the screen)
GEMDOS_CCONIS       equ     $0B                     ; console input status (non-blocking)
GEMDOS_SUPER        equ     $20                     ; Super(stack) — supervisor mode toggle

; XBIOS functions
XBIOS_GETREZ        equ     4                       ; Getrez() — current resolution
XBIOS_SETSCREEN     equ     5                       ; Setscreen(log,phys,mode)
XBIOS_SETCOLOR      equ     7                       ; Setcolor(idx,val)

; ----------------------------------------------------------------------------
; Keyboard scancodes / ASCII
; ----------------------------------------------------------------------------
KEY_ESC             equ     $1B

; ----------------------------------------------------------------------------
; Screen constants
; ----------------------------------------------------------------------------
SCREEN_WIDTH        equ     320                     ; visible pixels per line
SCREEN_HEIGHT       equ     200
; Option A: LINEWID=12 gives 3 extra pwords (48 px) of off-screen pipeline
; on the right. Each VBL, CPU shifts ALL 23 pwords left by 8 bits (via a
; byte-move trick that's fast enough to fit the VBL budget). New content
; is rendered into pword 22 (off-screen) every 2 VBLs = every 16 px
; cumulative shift. Effective scroll: 8 px / VBL = 400 px/sec, smooth at 50 Hz.
SCREEN_LINEWID      equ     12
SCREEN_VIS_WORDS    equ     80                      ; 20 pwords × 4 planes
SCREEN_EXTRA_WORDS  equ     SCREEN_LINEWID
SCREEN_LINE_WORDS   equ     SCREEN_VIS_WORDS+SCREEN_EXTRA_WORDS  ; 92
SCREEN_LINE_BYTES   equ     SCREEN_LINE_WORDS*2     ; 184 bytes per scanline
SCREEN_BYTES        equ     SCREEN_LINE_BYTES*SCREEN_HEIGHT      ; 36800 bytes
SCREEN_ALIGN        equ     256                     ; ST 256-align

PWORD_BYTES         equ     8                       ; 16-pixel slice = 4 planes × 2 bytes
SCREEN_VIS_PWORDS   equ     20                      ; 320 px / 16
SCREEN_TOTAL_PWORDS equ     23                      ; 20 visible + 3 off-screen

; Resolution modes (for XBIOS Setscreen)
RES_LOW             equ     0                       ; 320x200x16
RES_MED             equ     1                       ; 640x200x4
RES_HIGH            equ     2                       ; 640x400x2

; ----------------------------------------------------------------------------
; Scroller geometry — 3 rows sharing the same scroll_buffer + palette
; ----------------------------------------------------------------------------
; HBL installs the font palette at PALETTE_SWAP_LINE so colors 1..15 hold
; font_palette_c1 from there through the bottom of the last scroll row.
; All three rows display the same content (one scroll_buffer, three copies).
; Scroller geometry — original positions
SCROLL_Y            equ     78                      ; top row
SCROLL_Y_1          equ     78                      ; row 1: Y=78-111
SCROLL_Y_2          equ     119                     ; row 2: Y=119-152
SCROLL_Y_3          equ     160                     ; row 3: Y=160-193
SCROLL_HEIGHT       equ     34                      ; glyph height
SCROLL_RIGHT_PWORD  equ     SCREEN_TOTAL_PWORDS-1   ; 22 — legacy in-place pword (kept for compat)

; Off-screen scroll_buffer (Option F architecture, session 3):
;   21 pwords wide = 20 visible + 1 staging on the right.
;   Render new pword each VBL into pword 20, HOG-shift buffer left,
;   HOG-copy buffer[0..19] to screen rows 1/2/3. Total HOG ≈ 183 sl,
;   straddling the 113 sl invisible window plus first 70 sl of the
;   logo region. Timer-B raster_ptr is fixed up after HOG to skip the
;   missed gradient lines.
SCROLL_BUFFER_PWORDS      equ 21                                  ; 20 visible + 1 staging
SCROLL_BUFFER_VIS_PWORDS  equ 20                                  ; visible portion copied to screen
SCROLL_BUFFER_LINE_BYTES  equ SCROLL_BUFFER_PWORDS*PWORD_BYTES    ; 168
SCROLL_BUFFER_BYTES       equ SCROLL_BUFFER_LINE_BYTES*SCROLL_HEIGHT   ; 5712
SCROLL_BUFFER_RIGHT_OFFS  equ (SCROLL_BUFFER_PWORDS-1)*PWORD_BYTES ; pword 20 byte offset = 160

; ----------------------------------------------------------------------------
; Blitter registers (STE, base $FF8A00)
; ----------------------------------------------------------------------------
BLITTER             equ     $FF8A00
BLIT_SRC_XINC       equ     $20
BLIT_SRC_YINC       equ     $22
BLIT_SRC_ADDR       equ     $24
BLIT_EMASK1         equ     $28
BLIT_EMASK2         equ     $2A
BLIT_EMASK3         equ     $2C
BLIT_DST_XINC       equ     $2E
BLIT_DST_YINC       equ     $30
BLIT_DST_ADDR       equ     $32
BLIT_XCOUNT         equ     $36
BLIT_YCOUNT         equ     $38
BLIT_HOP            equ     $3A                     ; byte
BLIT_OP             equ     $3B                     ; byte
BLIT_CTRL           equ     $3C                     ; byte, bit 7 start, bit 6 hog
BLIT_SKEW           equ     $3D                     ; byte

; ----------------------------------------------------------------------------
; VBL timing calibration
; ----------------------------------------------------------------------------
; Starting raster_ptr entry at VBL end, in units of table entries.
; Tune: RAISE to shift gradient UP on screen, LOWER to shift DOWN.
; Table wraps at entry 313 (= one PAL frame).
VBL_RASTER_COMPENSATION equ 11

; Font
FONT_GLYPH_W        equ     48                      ; padded width (40 source + 8 blank)
FONT_GLYPH_H        equ     34
FONT_GLYPH_PWORDS   equ     3                       ; 48 / 16
FONT_GLYPH_LINE_B   equ     FONT_GLYPH_PWORDS*PWORD_BYTES  ; 24 bytes per glyph scanline
FONT_GLYPH_BYTES    equ     FONT_GLYPH_H*FONT_GLYPH_LINE_B ; 816 bytes per glyph
FONT_FIRST_ASCII    equ     32                      ; glyph 0 = space

; Absolute raster_table entry index at which the font-palette-swap HBL
; fires. Timer-B event-count only pulses on visible lines, so entry N
; maps directly to visible scanline N. Target: line 77 — just before
; SCROLL_Y_1 (78), in the gap between logo bottom (~line 73) and the
; top scroll row.
PALETTE_SWAP_ENTRY  equ     77                      ; line 77 = just before SCROLL_Y_1 (78)

; Scroll effect type (change to test different effects):
;   0 = 3 fixed rows (default)
;   7 = sine wave (single row with vertical wobble)
SCROLL_EFFECT_DEFAULT equ   1                       ; TEST

; ----------------------------------------------------------------------------
; Colors (ST-compatible palette values — $0rgb with 3 bits per channel,
; STE extra bit lives in bit 3 of each nibble. These values work on both.)
; ----------------------------------------------------------------------------
COLOR_BLACK         equ     $0000
COLOR_RED           equ     $0700                   ; max ST red
COLOR_GREEN         equ     $0070
COLOR_BLUE          equ     $0007
COLOR_WHITE         equ     $0777
