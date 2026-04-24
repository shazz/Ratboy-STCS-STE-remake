
_NEED_VRAM_CLEAR                 equ 0

; ---------------------------------------------------------------------------------
; Constants
; ---------------------------------------------------------------------------------
NB_MESSAGES                     equ 3
GRAD_SPEED                      equ 18
HBL_START                       equ 39
LINE_HEIGHT                     equ 2
BOOT_CHK                        equ $1234

; ----------------------------------------------------------------------------------------------------------
; Registers
; ----------------------------------------------------------------------------------------------------------
VBL_VECTOR                      equ $70
TIMER_B_HBL                     equ $120
PHYSTOP                         equ $42E                ; $00042E|long |Physical top of RAM 0x100000 on 1MB ST                  |phystop
HDV_BPB                         equ $472                ; $000472|long |Vector for getbpb for hard disk                         |hdv_bpb
HDV_RW                          equ $476                ; $000476|long |Vector for read/write routine for hard disk             |hdv_rw
                                                        ; This vector is used when Rwabs() is called. A value of 0 here indicates that no hard disk is attached.
                                                        ; Applications installing themselves here should expect parameters to be located on the stack as they would
                                                        ; be for the actual function call beginining at 4(sp). If the installed process services the call it should RTS,
                                                        ; otherwise, leaving the stack intact, should JMP through the old vector value
DISKBUFP                        equ $4C6                ; $0004C6|long |Pointer to 1024-byte disk buffer                        |_dskbufp
VRAM_PTR                        equ $44E                ; $00044E|long |Pointer to video RAM (logical screen base)                                  |_v_bas_ad

; ---------------------------------------------------------------------------------
; Addresses
; ---------------------------------------------------------------------------------
RASTER_COLOR_PTR                equ $600
GRADIENT_COLOR_PTR              equ $604
GRADIENT_VBL_COUNTER            equ $608
MESSAGE_COUNTER                 equ $60A
HDV_BPB_OLD_VECTOR_ADDR         equ $60E

START:

; ---------------------------------------------------------------------------------
; Entry point
; ---------------------------------------------------------------------------------

BOOT:
        pea.l L1BE_message(pc)                                          ; load message            
        move.w #$9, -(a7)                                               ; cconout
        trap #$1
        addq.l #$6, a7                                                     

        lea.l $fffffa00.w, a5                                           ; a5 = start of MFP registers

        lea.l L1BC_old_intA_state(pc), a0                               ; a0 = L1BC_old_intA_state
        move.b $7(a5), (a0)                                             ; save Interrupt Enable A 

        lea.l L1BD_old_intB_state(pc), a0                               ; a0 = L1BD_old_intB_state
        move.b $9(a5), (a0)                                             ; save Interrupt Enable B

        lea.l L1B2_old_vbl(pc), a0                                      ; a0 = L1B2_old_vbl
        move.l $70.w, (a0)                                              ; save vbl

        lea.l L1B6_old_hbl(pc), a0                                      ; a0 = L1B6_old_hbl
        move.l $120.w, (a0)                                             ; save user hbl

        lea.l L1BA_old_backcolor(pc), a0                                ; a0 = L1BA_old_backcolor
        move.w $ffff8240.w, (a0)                                        ; save back color

        clr.b $7(a5)                                                    ; clear MFP Interrupt Enable A
        clr.b $9(a5)                                                    ; clear MFP Interrupt Enable B

        lea.l LFE_vbl_handler(pc), a0                                   ; a0 = LFE_vbl_handler
        move.l a0, $70.w                                                ; set new VBL handler LFE_vbl_handler

        lea.l L152_hbl_handler(pc), a0                                  ; a0 = L152_hbl_handler
        move.l a0, $120.w                                               ; set new HBL handler L152_hbl_handler

        clr.b $1b(a5)                                                   ; Timer B Control = 0
        bset.b #$0, $13(a5)                                             ; set timer B for HBL
        bset.b #$0, $7(a5)                                              ; enable Int A
        bset.b #$6, $9(a5)                                              ; enable Int B

        move.w #$7, -(a7)                                               ; Crawcin() wait for key
        trap #$1
        addq.l #$2, a7

        move.b L1BC_old_intA_state(pc), $7(a5)                          ; restore interrupts
        move.b L1BD_old_intB_state(pc), $9(a5)
        move.l L1B2_old_vbl(pc), $70.w                                  ; restore vectors
        move.l L1B6_old_hbl(pc), $120.w
        move.w L1BA_old_backcolor(pc), $ffff8240.w                      ; restore palette
LFA:
        rts

LFE_vbl_handler:
        movem.l d0/a0-a2, -(a7)                                         ; save registers

        lea.l L168_color_table(pc), a1                                  ; a1 = L168_color_table
        bsr.b L130_set_back_color                                       ; call L130_set_back_color sub routine
        
        lea.l L172_position(pc), a1                                     ; a1 = L172_position
        lea.l L1AC_direction(pc), a0                                    ; a0 = L1AC_direction
        move.w (a0), d0                                                 ; d0 = L1AC_direction
        add.w d0, (a1)                                                  ; d0 = L1AC_direction + L172_position
        cmpi.w #$86, (a1)                                               ; if d0 < 134
        bcs.b L120_check_top                                            ; goto L120_check_top
        move.w #$ffff, (a0)                                             ; else set -1 to L1AC_direction
        bra.b L12A_end_vbl                                              ; go to L12A_end_vbl

L120_check_top:
        cmpi.w #$6, (a1)                                                ; if L172_position > 6
        bhi.b L12A_end_vbl                                              ; end vbl 
        move.w #$1, (a0)                                                ; else L1AC_direction = 0
L12A_end_vbl:
        movem.l (a7)+, d0/a0-a2                                         ; exit vbl
        rte

; ---------------------------------------------------------------------
; L130_set_back_color: sub routine to set back color
; input: a1: color table
; ---------------------------------------------------------------------
L130_set_back_color:
        move.w (a1)+, $ffff8240.w                                       ; set backcolor to (a1)+
        lea.l $fffffa00.w, a2                                           ; a2 = MFP regs
        clr.b $1b(a2)                                                   ; clear 

        move.w (a1)+, d0                                                ; get next color 
        bmi.b L150_end

        move.b d0, $21(a2)
        move.b #$8, $1b(a2)

        lea.l L1AE_color_ptr(pc), a0                                    ; update pointer
        move.l a1, (a0)
L150_end:
        rts

; ---------------------------------------------------------------------
; L152_hbl_handler
; ---------------------------------------------------------------------
L152_hbl_handler:
        movem.l d0/a0-a2, -(a7)                                         ; save registers

        movea.l L1AE_color_ptr(pc), a1                                  ; a1 = L1AE_color_ptr
        bsr.b L130_set_back_color                                       ; call L130_set_back_color sub routine

        movem.l (a7)+, d0/a0-a2                                         ; restore registers
        bclr #$0, $fffffa0f.w
        rte

; med rez color table: black, blue, red, dark green
L168_color_table:   
        dc.w $000,$004,$600,$010,$000

L172_position:   
        dc.b $00,$02,$06,$00,$00,$01,$07,$50,$00,$01
        dc.b $07,$70,$00,$01,$00,$70,$00,$01,$00,$57
        dc.b $00,$01,$00,$07,$00,$01,$00,$00,$00,$02
        dc.b $06,$00,$00,$01,$07,$50,$00,$01,$07,$70
        dc.b $00,$01,$00,$70,$00,$01,$00,$57,$00,$01
        dc.b $00,$07,$00,$01,$00,$00,$FF,$FF

L1AC_direction:
        dc.w $0001

L1AE_color_ptr:
        dc.l 0

L1B2_old_vbl:
        dc.l 0

L1B6_old_hbl:
        dc.l 0

L1BA_old_backcolor:
        dc.w 0

L1BC_old_intA_state:
        dc.b 0

L1BD_old_intB_state:
        dc.b 0

L1BE_message:
        ; bell + clear screen + home + position
        dc.b $7,$1b,$45,$1b,$59,$21,$24,"  Cracking Service Munich 1989  ",0
