# TODO

## Fix: crash / freeze on exit (ESC)

Pressing **ESC** quits `MainLoop` and the teardown runs, but TOS is left
crashed / frozen afterwards.

**Diagnosis (session 7):** forced an auto-exit and traced it under Hatari —
the teardown runs to completion (`Pterm0` is reached, debugger reports
"no program loaded"), but the CPU returns to TOS ROM with
**IMASK=7 (all interrupts masked)**. That's the anomaly.

**Suspects:**
1. `Main` sets `move.w #$2700, sr` (IMASK 7) for the teardown and never lowers
   it → TOS may be left frozen with no keyboard / timer interrupts.
2. A leftover SNDH music-timer interrupt (jess loader tune) firing *after*
   `Pterm0` frees the PRG memory → vectors into freed RAM.

**Fix ideas:**
- Restore a TOS-safe IMASK (e.g. `move.w #$2300, sr`) just before
  `SuperExit` / `Pterm0` — but only AFTER confirming no handler still points
  into the PRG.
- Ensure the music timer is fully torn down before `Pterm0`: after
  `MusicSndhExit`, explicitly mask the SNDH player's MFP timer interrupt.
- Reproduce via a temporary auto-exit (`cmp.w #N, vbl_counter` → set
  `exit_flag`) and single-step the teardown in the Hatari debugger.

**Files:** `src/main.s` (exit sequence ~L62-84), `src/music.s`
(`MusicSndhExit`), `src/hbl.s` (`RemoveHBL`), `src/vbl.s` (`RemoveVBL`).
