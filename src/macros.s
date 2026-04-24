; ----------------------------------------------------------------------------
; macros.s — Reusable assembler macros
; ----------------------------------------------------------------------------
; Pure preprocessing — no code or data emitted from this file directly.
; `\@` is VASM's unique-per-invocation suffix for local labels.
; ----------------------------------------------------------------------------

; ----------------------------------------------------------------------------
; WAIT_VBL — block until the VBL counter advances.
; Clobbers: d7.
; Requires: vbl_counter (word) in BSS, incremented by our VBL handler.
; ----------------------------------------------------------------------------
WAIT_VBL            macro
                    move.w      vbl_counter, d7
.wvbl_\@:
                    cmp.w       vbl_counter, d7
                    beq.s       .wvbl_\@
                    endm

; ----------------------------------------------------------------------------
; SET_COLOR — write a palette register.
;   \1 = index (0..15)
;   \2 = value ($0rgb immediate)
; No clobbers (uses direct absolute write).
; ----------------------------------------------------------------------------
SET_COLOR           macro
                    move.w      #\2, SHIFTER_PALETTE+(\1)*2
                    endm
