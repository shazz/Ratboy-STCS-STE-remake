# Stargoose Cracktro STE — Session Status

Last updated: 2026-04-24, end of session 2

## Where we are

Logo + raster gradient + 3-row scroller all running together with rasters
**rock-solid** and **rows 1 + 2 perfectly synced**. Row 3 has a residual
glitch (mid-row split — half shifted, half frozen) that has resisted every
wait-loop fix tried. Open question: how to close that out.

Last commit: `d4f8042` (in-place architecture). Build: `uv run tools/build.py`
(or `./bin/vasm/vasmm68k_mot -Ftos -quiet -spaces -I src -I . -o build/AUTO/STRGOOSE.PRG src/main.s`).

## Phase progress

| Phase | Status | Notes |
|-------|--------|-------|
| P0  — Hello ST                              | ✅ done | |
| P1  — Interrupt plumbing (VBL + HBL)        | ✅ done | VBL via `_vblqueue` slot |
| P2  — Static background (logo + stars)      | ✅ done | |
| P3  — Raster gradient                       | ✅ done | Now via Timer-B event-count, not HBL autovector |
| P4  — SNDH music                            | ⏸ disabled | `MUSIC_ENABLED equ 0` for diagnosis; works, re-enable when scroller is settled |
| P5  — Single-row scroller                   | ✅ done | Replaced with 3-row in P6 |
| P6  — Mode A (3 parallel rows)              | 🟡 **mostly done** | Rows 1/2 clean; row 3 has mid-row split glitch |
| P7+ — Sine, dual, sequencer                 | ⬜ pending | |

## What's working end-to-end (verified screenshots)

Boot into Hatari STE → BLADE RUNNERS logo + starfield top → smooth
blue→red raster gradient bottom half → 3 scroll rows showing identical
text in purple font palette → ESC exits cleanly. With `SCROLLER_ENABLED=0`
the gradient is **scanline-locked** with zero shake.

## Architecture (current — major changes from session 1)

- **No off-screen `scroll_buffer`.** Replaced with **in-place shifts** on
  screen memory. Each row at `SCROLL_Y_{1,2,3}` is its own independent
  shift target. The off-screen LINEWID extras (pwords 20–22) of each row
  are the staging area for new chars.
- **Timer-B event-count free-running.** `InstallHBL` starts Timer-B once
  with `TBDR=1` and never touches it again. Per-frame, only `raster_ptr`
  is reset in VBL. MFP auto-reloads TBDR from latch. Eliminates the
  per-frame restart jitter that used to shift gradient by 1 line.
- **Mouse disabled** at boot via IKBD command `$12` to ACIA1
  (`src/system.s` `DisableMouse`). Mouse motion → ACIA L6 ISR → blocks
  Timer-B for many scanlines → gradient skips lines. Re-enabled on exit.
- **Hybrid blitter mode:** row 1 in HOG (in VBL handler, invisible time);
  rows 2 + 3 in cooperative (in MainLoop, during visible).
- **Simplified Timer-B handler** (`src/hbl.s`): no per-fire stop/start
  re-arm — keeps ISR < 64 cycles so it survives blitter bus
  re-arbitration in cooperative mode. Font-palette install ISR uses
  8 long writes to be as short as possible (~280 cy total).
- **VBL pipeline (in invisible time, ~58 sl of 113 sl available):**
  `ScrollRenderNextPword` (writes new pword to all 3 rows in one pass via
  shared d3/d4 source read + 3-destination writes) → `ScrollShiftRow1Hog`.
- **MainLoop pipeline (during visible, ~104 sl):**
  `ScrollShiftRow2Coop` → `ScrollShiftRow3Coop`.
- **Cooperative wait idiom:** `bset/tst.w YCOUNT/bne` then `move.b #0` to
  fully idle CTRL. Verified YCOUNT to avoid stale-bit-7 → phantom blit.

## File map (current)

```
src/
  main.s                 entry; Main, MainLoop, CheckEsc; calls
                         DisableMouse before Install*, EnableMouse
                         before RestoreState
  constants.s            HW + SCROLLER_ENABLED, MUSIC_ENABLED toggles,
                         SCROLL_Y_1/2/3 (78/119/160), PALETTE_SWAP_ENTRY=77
  macros.s               WAIT_VBL, SET_COLOR_IMM
  system.s               Super, SaveState/RestoreState, DisableMouse/
                         EnableMouse (NEW), WaitEscKey
  screen.s               InitScreen — low-res, LINEWID=12, palette,
                         buffer alloc, logo blit
  vbl.s                  VBL handler: counter + palette reinstall +
                         (if SCROLLER_ENABLED) ScrollerStepVblank
  hbl.s                  Timer-B free-run setup; TimerBHandler is
                         simplified (no re-arm); install_font path
                         uses 8 long writes
  music.s                SNDH wrapper (currently disabled)
  scroller/engine.s      In-place 3-row scroller. ScrollerInit (zeros
                         3 screen-row regions), ScrollRenderNextPword
                         (writes to all 3 rows simultaneously),
                         ScrollShiftRow{1Hog,2Coop,3Coop},
                         ScrollerStepVblank, ScrollerStepVisible
  data/
    background.s         logo bitmap + palette
    font.s               font.bin + 3 palette variants (c1/c2/c3,
                         currently only c1 used)
    music.s              thrust.snd (disabled)
    gradient.s           raster_table — 200 entries (entries 0-69
                         black for logo, 70-199 gradient) + 120 zero
                         pad. NO leading pad (Timer-B doesn't fire
                         during overscan).
    scrolltext.s         9 sequence text blocks (S1 active)
docs/
  ARCHITECTURE.md, decisions.md, PLAN.md
  LEARNINGS.md           ← updated this session with mouse/Timer-B/
                           HOG/cooperative/wait-loop rules
  STATUS.md              this file
  blitter_manual.md, blitter_faq.txt, blitter_execution_times.md
  CSM.S                  reference Timer-B-on-HBL bootsector
screenshots/
  example.png            target reference
  grab0001..grab0015.png session 2 progression
```

## Open issue — single residual blocker

### Row 3 mid-row split glitch

**Symptom:** Row 3 (bottom of the 3 scrollers, at SCROLL_Y_3=160) shows a
horizontal split mid-way through its 34 scanlines. Lines 0..K are shifted
correctly to current frame's scroll position; lines K..33 show the previous
frame's content (1 pword behind). Position is **consistent** (~line 17),
not jittering — suggests it's deterministic, not a wait-loop race.

Rows 1 (HOG in VBL) and 2 (cooperative in MainLoop) are perfect. Only row 3.

**Things tried that didn't fix it:**
- HOG-shift (everything in VBL) — overruns invisible window, gradient
  delayed.
- Cooperative shift with `bset/nop/bne` exit — race exit at line ~7.
- Adding YCOUNT verify after bset/bne loop — improved but still races.
- Adding `bclr.b #7, CTRL` after wait — *worsened* it (bclr halts blitter
  mid-blit if YCOUNT verify ever races).
- Switching to `move.b #0, CTRL` after wait + double YCOUNT verify — still
  glitches.
- Pure `bset+tst.w YCOUNT+bne` (no separate bit-7 check) — still glitches.

**Likely cause:** the font-palette-install ISR (PALETTE_SWAP_ENTRY=77, ~280
cycles) fires DURING row 3's cooperative blit. ISR exceeds 64-cycle yield
window. FAQ §3.j: *"the ISR should finish in less than 64 cycles, otherwise
it is potentially stalled by the BLiTTER again."* The cycle-stretching
interaction between long ISR and cooperative blitter creates a deterministic
mid-blit corruption that the wait loop can't catch.

### Decision needed next session — how to close out P6

Three paths forward, in increasing effort:

**Option A: Drop to 2 rows.** Definitely works (rows 1 + 2 already do).
Loses the third visual row. Simplest.

**Option B: Move row 3 to AFTER the gradient finishes.** Poll the video
counter (`$FF8205/07/09`) to wait until visible line ~150, then HOG-shift
row 3. The shift happens during the bottom of the gradient where rasters
have largely fired. Trades the deepest red of the gradient (entries
~150-199) for keeping all 3 rows. Tricky to time.

**Option C: Eliminate the long palette-swap ISR.** Three sub-options:
- Pre-bake font palette as a constant in dN/aN registers held permanently
  (steep register-discipline cost across the rest of the demo).
- Split the swap into one color per scanline across N scanlines (but the
  visible scanlines from line 77-onwards already render text, so partial
  palettes mid-render look weird).
- Combine logo + font palette into a single 16-color set so no swap
  needed (asset redesign).

My instinct: **Option A** is the pragmatic answer if the visual is good
enough. If 3 rows is non-negotiable, **Option B** with video-counter
polling is the principled fix that doesn't compromise rasters.

## Important non-obvious facts (also in LEARNINGS.md, copied here for handoff)

- **Mouse must be disabled** for stable rasters. ACIA mouse-packet ISRs
  block Timer-B.
- **Timer-B runs continuously**, not re-armed per VBL. Re-arming jitters
  the gradient by 1 scanline.
- **Cooperative blitter mode requires `bset/nop/bne` (not just `tst.b`)**
  to keep blitter making progress — but the bset has Z-flag race issues.
  `tst.w YCOUNT` is the only reliable progress check.
- **Use `move.b #$80` (not `or.b #$80`)** to start cooperative blits in a
  pipeline that mixes HOG and cooperative — `or.b` preserves leftover
  HOG bit from the previous blit.
- **`raster_table` has NO leading overscan pad anymore.** Timer-B
  event-count only fires during visible (DE-active) scanlines, so
  entry 0 maps directly to visible line 0. Old HBL-autovector wanted a
  62-entry pad; Timer-B does not.
- **Hatari reset does not flush blitter state.** When blitter behavior
  changes unexpectedly, fully quit and relaunch Hatari.

## Next session restart plan

1. Read this file + last few entries in `docs/LEARNINGS.md` (Apr 24).
2. Look at `screenshots/grab0013.png` and `grab0014.png` to see current
   row-3 glitch.
3. Decide A/B/C above.
4. Once row 3 is settled, re-enable music (`MUSIC_ENABLED equ 1` in
   `src/constants.s`) and verify it still works alongside the scroller.
5. Move on to P7 (big sine + reflection).

## Key invariants to preserve

- `screen_base` (in `src/screen.s` BSS) = 256-byte aligned. Any code
  needing the Shifter base uses `move.l screen_base, aN`.
- `raster_ptr` must be at `raster_table` at start of every frame (VBL
  resets it).
- Each scroll row owns bytes `screen_base + SCROLL_Y_n*SCREEN_LINE_BYTES`
  through `+(SCROLL_Y_n+34)*SCREEN_LINE_BYTES`. Modified by
  `ScrollerStepVblank` (row 1) and `ScrollerStepVisible` (rows 2/3).
- `SCREEN_LINEWID=12`, so `SCREEN_LINE_BYTES=184`. Every blit/shift
  respects this stride.
- Timer-B is started ONCE in `InstallHBL` and runs continuously until
  `RemoveHBL`. Don't add stop/start in the per-frame path.
- IKBD mouse must be disabled before any raster-critical work. The
  current `Main` order — `DisableMouse → InstallVBL → InstallHBL` — is
  load-bearing.
- VBL handler ends by RTS (NOT RTE) because TOS calls us from its
  vbl-queue dispatcher via JSR.
