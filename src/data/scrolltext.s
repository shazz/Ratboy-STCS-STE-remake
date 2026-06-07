; ----------------------------------------------------------------------------
; data/scrolltext.s — merged scroll text with embedded effect-change markers
; ----------------------------------------------------------------------------
; Lifted from Shazz's 2011 JS port (text_S1..text_S8, see js_version/main.html
; lines 166..239), in turn preserving RATBOY's 1988 originals.
;
; Markers:
;   bytes 1..8  → switch active scroll effect to (byte-1), per the parser
;                 in ScrollRenderNextPword .fetch_next_char.
;   byte 0      → NULL terminator → scroller engine wraps to scrolltext_S1.
;
; Layout:
;   <byte N>  <text segment for effect N-1>  <byte N+1>  <next segment>  …
;
; The cycle covers all 8 effects (0..7). After the trailing NULL the cursor
; wraps to the top, which begins again with the byte-1 marker → effect 0.
;
; Leading-space padding inside each segment is the original 1988 padding —
; gives a pause before the first glyph enters from the right edge.
; ----------------------------------------------------------------------------

                    even
; -----------------------------------------------------------------------------
; PERF-TEST scrolltext: no effect-change markers → effect stays locked to
; SCROLL_EFFECT_DEFAULT for the full session. Simple repeating alphabet
; lets us read VBL counts cleanly. Restore the production scrolltext below
; before shipping.
; -----------------------------------------------------------------------------
scrolltext_S1_test:
                    dc.b    "ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789       "
                    dc.b    0                       ; wrap → back to scrolltext_S1
                    even

; -----------------------------------------------------------------------------
; PRODUCTION scrolltext (commented out for perf-testing).
; -----------------------------------------------------------------------------
                    ifne    1
scrolltext_S1:
                    ; --- TEST: quick channel switch right at the start ---
                    ; "HELLO" scrolls in, then byte 9 flips the channel. Fast to
                    ; test; move/delete this block for production timing.
                    dc.b    1
                    dc.b    "    HELLO                              "
                    dc.b    SWITCH_MARKER

                    ; --- effect 0 — three fixed rows ---
                    dc.b    1
                    dc.b    "              PLEASE, READ ALL THIS SCROLL !!!           "
                    dc.b    "THE S.T.C.S. STRIKES BACK WITH THIS MEGA-NEWS CALLED                "

                    ; --- effect 1 — single row 2x tall + sine ---
                    dc.b    2
                    dc.b    "-- STARGOOSE --            "

                    ; --- effect 2 — water reflection ---
                    dc.b    3
                    dc.b    "CRACKED ON 22-09-88 BY RATBOY FROM S.T.C.S.      "
                    dc.b    "THIS VERY NICE NEW INTRO WAS CODED AND DESIGNED BY RATBOY.    "
                    dc.b    "THE BLADERUNNERS ACRONYM WAS DESIGNED BY NINJA.     "
                    dc.b    "NEW ?     YOU THINK !                         "

                    ; --- effect 3 — sine + 1-line interleave + clearing ---
                    dc.b    4
                    dc.b    "YES, NEW !!!    "
                    dc.b    "NOW, THERE IS NO MORE ROOM FOR DOUBT CONCERNING THE FACT THAT "
                    dc.b    "THE S.T.C.S IS THE BEST COMPUTER GROUP EVER MADE IN FRANCE ON THE ATARI-ST.   "
                    dc.b    "SO, I WANT TO PRESENT YOU HIS 8 MEMBERS...                                   "

                    ; --- effect 4 — mirror diagonals + palette swap ---
                    dc.b    5
                    dc.b    "ACTARUS WHO CREATED THE GROUP AND WHO IS PERHAPS (CERTAINLY !) "
                    dc.b    "THE BEST SWAPPER IN EUROPE ON THE ATARI AND I WANT TO GREET HIM "
                    dc.b    "FOR HIS MORAL SUPPORT...         "
                    dc.b    "NINJA, THE NEW MEMBER WHO IS A VERY GOOD SWAPPER TOO (AND DESIGNER !!!)...     "
                    dc.b    "KICKSTART WHO SWAPS VERY WELL...    "
                    dc.b    "WHEN HE DOESN'T SLEEP  (THINK TO THE CSS CONVENTION !)...                     "

                    ; --- effect 5 — static bottom + diagonal interleaved overlay ---
                    dc.b    6
                    dc.b    "THE S.T.C.S. WAS COMPOSED BY ONE DEMOS PROGRAMMER CALLED BILLY OCTET "
                    dc.b    "AND BY FOUR CRACKERS TOO:       "
                    dc.b    "THE LORD,   BANZAI (WHO CRACKS VERY WELL WHEN HE DOESN'T SLEEP TOO !),  "
                    dc.b    "JABBERWOCKY AND RATBOY.       "
                    dc.b    "NOW IT'S TIME TO GREET SOME OTHER PEOPLE WHO MAKE A LOT OF GOOD THINGS ON THE ST.                                          "

                    ; --- effect 6 — two fixed rows ---
                    dc.b    7
                    dc.b    "MEGA-GIGA GREETINGS TO:   - THE BLADERUNNERS (ALL MEMBERS !) - TSUNOO -                      "

                    ; --- effect 7 — triangle trajectory pair + bottom row ---
                    dc.b    8
                    dc.b    "NORMAL GREETINGS TO:    -  THE UNION (HOWDY, ES, XXX INTERNATIONAL)  "
                    dc.b    "-  THE REPLICANTS (DO YOU KNOW WHAT THE WORD  'NEWS'  MEANS ?)  "
                    dc.b    "-  MCA  -  AH-A  -  THE BIG FOUR  -  WAS (NOT WAS)  "
                    dc.b    "-  FIRE CRACKERS  -  CSS  -  B.O.S.S  -                          "

                    dc.b    0                       ; wrap → back to scrolltext_S1
                    even
                    endc
