This article documents '''[[blitter]] execution times''' for blitter operations

==Blitter Execution Times==

{|
|-
!width="50"|
!width="50"|
!width="50"|HOP
!width="50"|
!width="50"|
|-
| LOP || 0 || 1 || 2 || 3    
|-
|0  || 1 ||  1  || 1  || 1
|-
|1  || 2 || 2 || 3 || 3    
|-
|2  || 2 || 2 || 3 || 3    
|-
|3  || 1 || 1 || 2 || 2    
|-
|4  || 2 || 2 || 3 || 3    
|-
|5  || 2 || 2 || 2 || 2
|-
|6  || 2 || 2 || 3 || 3    
|-
|7  || 2 || 2 || 3 || 3    
|-
|8  || 2 || 2 || 3 || 3    
|-
|9  || 2 || 2 || 3 || 3
|-
|10 || 2 || 2 || 2 || 2
|-
|11 || 2 || 2 || 3 || 3
|-
|12 || 1 || 1 || 2 || 2
|-
|13 || 2 || 2 || 3 || 3
|-
|14 || 2 || 2 || 3 || 3
|-
|15 || 1 || 1 || 1 || 1
|}

HOP = Halftone Operation

LOP = Logical Operation


All timings are assuming the BLITTER is the only DMA device using the BUS. If other devices are using the BUS the figures may increase.

All timing figures are given in nops per word of transfer. Ie. a value of 2 would take the equivilent time of 2 nops to transfer 1 word of data.

[[Category:Blitter]][[Category:Programming]]
