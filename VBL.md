Blitter, full HOG, all inside VBL. Not CPU. Here's the reasoning:

The reason CPU plot looked attractive earlier was race-freeness — but the race only exists because we're doing blitter work during visible time when Timer-B fires the 280-cy palette ISR at
line 77. If we move the whole copy stage into VBL invisible, Timer-B doesn't fire (DE is off), so HOG is safe and there's no ISR to collide with.

With a single shared off-screen buffer, the per-frame work shrinks dramatically:

VBL handler (invisible, ~113 sl budget):
prelude  (music, counter, palette reinstall) ~10 sl
ScrollRender newpword → buffer               ~5 sl
ScrollShift buffer (1 row, HOG)              ~16 sl  ← was 3x this
Copy buffer → screen row1 (HOG)              ~16 sl
Copy buffer → screen row2 (HOG)              ~16 sl
Copy buffer → screen row3 (HOG)              ~16 sl
───────────────────────────────────────────────────
total                                        ~79 sl   (fits in 113)

vs. today's "shift in place 3 times" which forces 2 of the 3 shifts into visible (cooperative) where they get crushed by the palette ISR.

The trick is that copies are cheaper than in-place shifts (no edge merge / skew logic), and we now only shift once (the buffer) instead of 3 times. That's what unlocks fitting everything
inside invisible.

Why not CPU plot:
- We'd burn cycles for no determinism gain (HOG-in-invisible is already deterministic — no other ISRs are firing).
- CPU movem.l fan-out is ~188 sl per frame; HOG-copy is ~48 sl total. Big margin.
- We free the CPU during visible for future work (sine table lookups for P7, sequencer logic, etc).

The CPU plot remains the fallback if budget gets tight — e.g. if some row's start-Y forces work past the line-0 deadline. But we should try blitter HOG first.