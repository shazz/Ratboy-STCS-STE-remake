; ----------------------------------------------------------------------------
; data/scrolltext.s — Scroll-text strings (lifted from Shazz's JS port)
; ----------------------------------------------------------------------------
; These are the nine sequence strings from RATBOY's 1988 original, as
; preserved in Shazz's 2011 CODEF port. P5 uses S1 only; P8 will wire all
; nine into the sequencer.
;
; Leading-space padding is intentional — it gives the text a pause before
; the first character visibly enters from the right edge.
;
; Null terminator (dc.b 0) marks end; the scroller engine wraps to the
; beginning on encountering it, producing the classic infinite-loop scroll.
; ----------------------------------------------------------------------------

                    even
scrolltext_S1:
                    dc.b    "              PLEASE, READ ALL THIS SCROLL !!!           THE S.T.C.S. STRIKES BACK WITH THIS MEGA-NEWS CALLED                ",0
                    even
