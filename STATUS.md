# Stargoose Cracktro STE — Session Status

Last updated: 2026-04-29, session 4 in progress

## Session 4 — GLITCH FIXED! (2026-04-29)

**Root cause identified and fixed.**

The `move.w` to `SHIFTER_PALETTE` during scanlines 107-111 causes a bus
collision with Shifter DMA fetch. The write lands at a cycle boundary that
shifts the Shifter's internal state, displaying row 1's last 5 lines 32
pixels to the right.

**Fix**: Skip palette write for scanlines 107-111 in `TimerBHandler`. The
ISR still fires (ptr advances), but doesn't write to palette. Creates a
5-scanline "freeze" in the gradient — imperceptible since it's in the
red-to-dark transition zone.

**Code change** (`src/hbl.s`):
```asm
RASTER_SKIP_START   equ     raster_table+107*2
RASTER_SKIP_END     equ     raster_table+112*2

TimerBHandler:
    ...
    cmpa.l      #RASTER_SKIP_START, a0
    blo.s       .do_write
    cmpa.l      #RASTER_SKIP_END, a0
    bhs.s       .do_write
    addq.l      #2, a0          ; skip write, advance ptr
    bra.s       .done
.do_write:
    move.w      (a0)+, SHIFTER_PALETTE
.done:
    ...
```

**Why this worked**: Row 1's lines 29-33 fall at screen Y=107-111. At those
exact scanlines, the Shifter is fetching row 1's pixels while our ISR tries
to write palette[0]. On STE, the Shifter and CPU share the bus; the write
corrupts the Shifter's fetch timing. Rows 2/3 aren't affected because their
equivalent internal lines (29-33) fall at screen Y=148-152 and Y=189-193,
which don't hit the same bus-collision window.

---

## Where we are (end of session 4)

**Architecture is Strategy E (pure CPU integrated shift+plot) +
double-buffer**, all three rows splat from one off-screen `scroll_buffer`,
plot runs in MainLoop after WAIT_VBL. 

**All working**: gradient ✓, font palette ✓, double-buffer flip ✓, 
**row-1 glitch FIXED** ✓ (Timer-B skip for scanlines 107-111).

## Diagnostics to clean up

Now that the glitch is fixed, these temporary diagnostic changes can be
reverted when ready:

1. `src/data/scrolltext.s` — currently "ABCDEFGH..." for dense test pattern.
   Restore original "PLEASE, READ ALL THIS..." text.
2. `src/constants.s` — `PALETTE_SWAP_ENTRY equ 250` disables font palette
   swap. Restore to `77` for proper font colors.
3. `src/screen.s` — diagnostic bars at lines 195/197 for buffer-flip
   verification. Remove once no longer needed.



## Where we are

## How to resume next session

1. **Read this file + `DEBUG.md`** (new this session — Hatari debugger
   workflow for memory inspection from terminal).
2. Note current `src/data/scrolltext.s` — has been temporarily replaced
   with `"ABCDEFGH..."` as a diagnostic so the buffer always has dense
   non-zero content. **Restore the original `PLEASE, READ ALL THIS
   SCROLL...` text once the glitch is fixed.** Original is preserved as
   a commented-out line in the file.
3. Note current `src/constants.s` flags:
   - `RASTER_ENABLED equ 1`
   - `PALETTE_SWAP_ENTRY equ 250` (DIAGNOSTIC value — set back to 77 once
     glitch is fixed). With 250 the swap never fires so font-palette
     never gets installed → scroller renders in **logo palette colours**
     (looks "wrong" but glyph SHAPES are what we care about for now).
4. Note `src/scroller/engine.s` has the **row-1/row-3 swap diagnostic**
   in `ScrollShiftAndPlot` (a2 → row 3, a4 → row 1). Swap back to normal
   ordering once glitch is solved.
5. Note `src/screen.s` has DIAGNOSTIC bars at line 195 (buffer A) and
   line 197 (buffer B) for verifying double-buffer flip. Remove once
   glitch is solved.

## SESSION 3 KEY FINDING (continued debug after first wrap)

Used Hatari debugger to dump buffer content at the exact moment plot
finishes (`pc=$b00a` breakpoint, rts of `ScrollShiftAndPlot`).

**Confirmed via direct memory dump:**

For diagnostic scrolltext "ABCDEFGH...", at one specific frame
(front=$25300, back=$1c200):

```
Front row 1 line 28 ($29F30):   88 cc 0c c3 7f c0 0b 3f e6 66 ...
Front row 2 line 28 ($2BCA8):   88 cc 0c c3 7f c0 0b 3f e6 66 ...   ← identical
Front row 3 line 28 ($2DA20):   88 cc 0c c3 7f c0 0b 3f e6 66 ...   ← identical

Front row 1 line 29 ($29FE8):   83 38 13 78 7f 70 0c b0 ...
Front row 2 line 29 ($2BD60):   83 38 13 78 7f 70 0c b0 ...        ← identical
Front row 3 line 29 ($2DAD8):   83 38 13 78 7f 70 0c b0 ...        ← identical

Front row 1 line 33 ($2A398):   00 00 00 00 ...   (text bottom-empty for ABCD glyphs)
Front row 2 line 33 ($2C110):   00 00 00 00 ...                    ← identical
Front row 3 line 33 ($2DE88):   00 00 00 00 ...                    ← identical
```

Same for back buffer — also identical across rows. Same for line 27
(= last line BEFORE the visible glitch) — identical across rows.

**Conclusion: plot writes byte-identical content to all 3 rows. The glitch
is NOT in the buffer. It's in how the Shifter reads/displays row 1's
lines 29-33 (= screen lines 107-111).**

This means the bug is something STE-Shifter-hardware-level — the
Shifter reads identical memory but displays it differently for row 1
last 5 scanlines vs rows 2 and 3 same scanlines (relative-to-row).

Matt's hint: "Y=107 as visible line (320x200) so it has to be shifted
from non-visible screen" — pointing toward Shifter's address counter
slipping by some amount at scanline 107, possibly reading from off-
screen / non-visible memory area (like LINEWID's pad bytes, or shifted
into a different line's data) for those specific scanlines.

**Why does it ONLY happen on row 1, not at the equivalent dest-line-29
of rows 2 (= screen line 148) or row 3 (= screen line 189)?** Open
question. Hypothesis: there's a specific cycle alignment between Timer-B
ISRs (= 1 per visible scanline, ~150 cy) and Shifter DMA fetches that
glitches at one specific accumulation point — and that accumulation
point lands at screen line 107 in our setup. With rows 2/3 starting
later (lines 119, 160), they don't hit the same accumulation point.

## Session 3 debug findings (Hatari debugger via fifo)

Set up Hatari + fifo workflow this session — see `DEBUG.md` for the
full automated debugger pattern. Got working:
- Symbol resolution via `hatari-debug symbols prg`.
- Breakpoint at `pc=$b00a` (rts of `ScrollShiftAndPlot`) with
  `:file dump_cmds.txt :once` action.
- Memory dumps via `m $XXXX 60` (literal hex addresses; `m` does NOT
  accept indirect parens — workflow is `evaluate (back_buffer_ptr)` →
  note the value → `m $value n`).

Initial dumps showed ALL ZEROS at expected row 1 buffer locations. Two
reasons combined:
1. Original scrolltext starts with 14 spaces → buffer mostly zeros for
   first 5 seconds of demo. Worked around by switching to `ABCD...`.
2. Address arithmetic done wrong — used wrong buffer base. Confirmed by
   later dumps that **back/front buffer pointers vary between Hatari
   sessions** (PRG load address can change). Always re-evaluate
   `(back_buffer_ptr)` per session.

After fixing both, `m $25300+$4C30` style still doesn't work (`m` doesn't
parse compound expressions). Workflow:
1. `evaluate (back_buffer_ptr)` → e.g. returns `$25300`.
2. Compute: `$25300 + 14352 = $28B10` (row 1 line 0).
3. Compute: `$25300 + 19504 = $29F30` (row 1 line 28 = first glitched).
4. `m $28B10 40` and `m $29F30 40` — both showed glyph data (non-zero).

So the buffer DOES contain plot output at lines 28-33. Buffer content
appears valid. The next step is to **dump the SAME line 28 from rows 1,
2, AND 3 of one buffer** to see if they're identical (as they should be
under fan-out plot). If they differ, we've found a write going wrong.

Specific addresses for next session (assuming back = $25300):
- Row 1 line 28 = $25300 + 78×184 + 28×184 = $29F30.
- Row 2 line 28 = $25300 + 119×184 + 28×184 = $2BCA8.
- Row 3 line 28 = $25300 + 160×184 + 28×184 = $2DA20.

Dump all three with `m $XXXX 40`. If row 1's bytes differ from rows 2/3,
the bug is confirmed at write-time. If all three match, the bug is in
the SHIFTER reading row 1's last 5 lines.

## Path forward suggestions

- **Verify the buffer content hypothesis first** (above). 5 minutes of
  Hatari debugger work using `DEBUG.md` workflow.
- If buffer content is identical across rows but only row 1 displays
  wrong, this is a Shifter quirk — possibly something to do with where
  row 1's last 5 lines fall in DRAM banking relative to where Shifter is
  fetching at the same time.
- Consider Lesson 2 from `WRITE_UP.md`: switch to HBL autovector + self-
  modifying handler. Even shorter ISR. Worth doing for P7+ anyway.
- Consider running the **original CPU shift loop pattern** (per
  `WRITE_UP.md` `scrolg`, lines 416-444) — byte-by-byte in MAIN LOOP,
  not VBL handler. Different timing might avoid the bug.

Last commit: `423d4ee` (STATUS.md Option D). Build (this session's
state):
`./bin/vasm/vasmm68k_mot -Ftos -quiet -spaces -I src -I . -o build/AUTO/STRGOOSE.PRG src/main.s`
(or `uv run tools/build.py`).

## Phase progress

| Phase | Status | Notes |
|-------|--------|-------|
| P0  — Hello ST                              | ✅ done | |
| P1  — Interrupt plumbing (VBL + HBL)        | ✅ done | VBL via `_vblqueue` slot |
| P2  — Static background (logo + stars)      | ✅ done | |
| P3  — Raster gradient                       | ✅ done | Now via Timer-B event-count, not HBL autovector |
| P4  — SNDH music                            | ⏸ disabled | `MUSIC_ENABLED equ 0` for diagnosis; works, re-enable when scroller is settled |
| P5  — Single-row scroller                   | ✅ done | Replaced with 3-row in P6 |
| P6  — Mode A (3 parallel rows)              | 🟡 **session 3 in flight** | Pivoting to off-screen buffer + CPU fan-out plot (Option D refined) |
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

### Session 3 chosen path — Option D refined (HOG shift + CPU fan-out)

**Decision (2026-04-25):** keep all scroller work in VBL invisible time.
This kills the cooperative-mode race entirely — no blitter activity
during visible, so the 280 cy palette ISR can never collide with a blit.

**Architecture:**

- One off-screen `scroll_buffer`, 21 pwords × 34 lines (20 visible + 1
  staging on the right). ~5712 bytes.
- Per-VBL pipeline (all in the 113 sl invisible window):

```
  1. Render new pword       → buffer[pword 20]    CPU, ~11 sl
  2. HOG shift              buffer[1..20] → [0..19]   43 sl  (XCOUNT=80×34, HOP=2 OP=3 → 8 cy/word)
  3. CPU fan-out plot       buffer[0..19] → screen rows 1/2/3   ~57 sl
  ────────────────────────────────────────────────────────
                                         total      ~111 sl
```

CPU fan-out reads ONE scanline of buffer (40 longs) into d0-d7 with
movem.l, then writes to 3 destinations on screen. Fan-out gain: 1 read
per scanline serves 3 rows. Per-line cost ≈ 5 read movems + 15 write
movems + pointer advances ≈ 864 cy/line × 34 lines = 57 sl wallclock
(no Timer-B overhead because we're in invisible).

**Why this works where in-place did not:**
- Cooperative blits during visible were the only thing racing the
  280 cy palette ISR. We're eliminating cooperative blits entirely.
- HOG-in-invisible is already proven safe (current row 1 uses it
  cleanly). We're just doing more HOG work in the same window.
- CPU plotting is interruptible without corruption — Timer-B can fire
  mid-plot and just delay it by ISR cost; no torn writes possible.
  Pure CPU work rate is fast enough that the plot finishes inside
  invisible (no ISR overhead actually charged).

**File changes coming:**
- `src/scroller/engine.s` — full rewrite. New `ScrollerStepVblank`:
  render → HOG shift on buffer → CPU plot to all 3 rows.
- `src/main.s` — remove `ScrollerStepVisible` call from MainLoop
  (no more visible-time scroller work).
- `src/constants.s` — add buffer dims; reduce SCREEN_LINEWID? No,
  keep LINEWID=12 for now (logo blit uses the stride). Buffer is
  separate.
- `src/scroller/engine.s` BSS — declare `scroll_buffer`.

**Cycle math sanity check:**
- HOP=2 OP=3 (LOP=3) = 2 nops/word per blitter exec-time table
  (docs/blitter_execution_times.md). 1 nop = 4 cy → 8 cy/word.
- Shift cost = 80 words × 34 lines × 8 cy = 21760 cy = 43 sl.
  (Saved 4 sl over current 88-word shift by narrowing buffer.)
- CPU plot per scanline: 5× movem.l read (32 cy each = 160 cy)
  + 15× movem.l write (32 cy each = 480 cy) + 3 dest advances
  (24 cy) + loop overhead (~50 cy) ≈ 720 cy. × 34 = 24480 cy = 48 sl.
  Padded to 57 sl for safety.

**Risk:** if CPU plot is slower than estimated and overruns invisible,
plot continues into visible logo region. CPU is interruptible so no
corruption — Timer-B fires for those scanlines as normal, gradient
stays clean. Worst case plot finishes ~line 20 of visible — still
58 sl of margin before line 78 (row 1 fetch).

### Adopted findings from `WRITE_UP.md` (1988 STF original analysis)

The agent's reverse-engineering of `docs/STCS.RAT/CONFO.S` produced 5
concrete techniques worth folding into the STE port. Two are immediate
priorities; the rest are P7+ groundwork.

**Now (P6 close-out):**

1. **Double-buffered screen** (`$30000` / `$40000` in the original,
   line 798 of CONFO.S). The original splats one shifted glyph row into
   the *back* buffer while the *front* buffer displays. We're currently
   single-buffered, which is part of why HOG-into-logo timing is so
   load-bearing — with double buffer we can write to off-display memory
   and the Shifter never sees in-progress work. **This is Matt's call
   for P6 v2.** Plan:
   - Allocate two 37-KB screen buffers (256-aligned).
   - `InitScreen` paints the LOGO into both.
   - VBL handler flips `screen_base` register before kicking the
     scroller pipeline. Scroller writes to whichever buffer is now
     "back".
   - Cost: +37 KB BSS. STE has 1 MB; trivial.

2. **Manual font-palette install in fix-up** (defensive). The original
   doesn't need this because it has no blitter; we do because HOG can
   straddle the swap line. Add 8 long writes of `font_palette_c1` at
   the start of `FixupRasterPtrAfterHog` so the font palette is in
   regardless of whether the Timer-B swap entry was reached. Cost:
   ~150 cy. The Timer-B swap-entry branch becomes a redundant safety
   net rather than the only path.

**Later (P7+ groundwork):**

3. **Effect-change bytes embedded in scroll text** (CONFO.S lines
   816-843). The original encodes mode switches (sine, double-height,
   trio, etc.) as bytes 1..7 inside the text stream. Our text consumer
   recognises them and updates a `type` byte that the splat dispatcher
   reads. Eliminates a separate sequencer-table subsystem. Adopt this
   for the `sequencer.s` design.

4. **Self-modifying HBL handler** (CONFO.S lines 723, 726 with patches
   at 125, 217, 280, 319). Instead of reading a per-frame parameter
   table in the HBL hot path, the original *patches* `cmp.b #N,d0`
   immediates inside the running HBL when an effect changes. Faster
   than table-driven (no read in hot path). Worth considering once we
   have multiple visual zones to swap between.

5. **STE HSCROLL + splat synergy.** The original is stuck with 8-pixel
   shift granularity (byte-by-byte CPU shift). On STE we have a
   hardware fine-scroll register (`$FF8265`) that gives 1-pixel
   granularity for free. Combine with the "1 row splatted 3 times"
   architecture: shift the off-screen buffer by 1 pword every 8 frames
   (cheap), use HSCROLL to interpolate the 1..15 pixel offsets between.
   Reduces buffer-shift cost by 8×.

### Older options (reference — kept for context)

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

**Option D: Off-screen buffer + cheap per-frame plots.** Go back to a
single off-screen `scroll_buffer` (the architecture we had before this
session's in-place refactor) BUT redesign the per-frame screen update so
it's far cheaper than the 3 full blitter copies that bit us before.

Key insight: all 3 rows display *identical* pixel content (same text,
same font palette — only the per-row palette swap, which we're
considering removing in Option C, would differ). The expensive work
(rendering glyphs, advancing the scroll position) only needs to happen
**once per frame**, into the shared buffer. The screen-update is a
read-once-write-three-places problem.

Sub-options for the "cheap plot":

- **CPU plot via `movem.l` chains.** 3-way fan-out: for each scanline,
  load 80 visible words from buffer into d0-d7+a2-a6 with one `movem.l`,
  then write the bank to all 3 screen rows. Cost ≈ 3 × the in-place
  shift cost, but **deterministic** — no cooperative-mode wait-loop
  race, no Timer-B-vs-blitter contention, no half-row split. CPU
  plotting also runs in lockstep with rasters: each scanline of CPU
  plot takes a fixed # of cycles, so we know exactly when we're past
  the gradient region.

- **Blitter plot but with SKEW.** Maintain `scroll_buffer` at pword
  granularity (shift 1 pword every frame, OR less often if combined
  with hardware scroll). Use blitter SKEW to do sub-pword positioning
  within the per-row blits. The SKEW is per-blit so it can be set
  separately for each row's blit — but in our case all rows want the
  same skew, so it's the same SKEW value × 3 blits.

- **Single-source double-row blit.** If we pack the 3 rows tightly
  (no gradient gaps between them) at one screen location and use
  screen-base + LINEWID tricks to *display* them at 3 different Y
  positions… probably not feasible on STE without exotic tricks.

The CPU-plot variant is the most attractive because it's **race-free
by construction**. CPU writes are atomic; no blitter state to worry
about; no FAQ §3.j cooperative warnings. Cost is purely cycles, and
cycles fit in the 313 sl frame budget. We'd lose blitter parallelism
but gain determinism and predictability — which is what we keep
running out of.

Rough cost: 80 words × 34 lines = 2720 source reads. With
`movem.l (a0)+, d0-d7/a2-a6` (16 longs = 8 words per movem), that's
2720 / 8 = 340 movems × ~70 cy each = ~24K cy = 47 sl wall. Plus
3-way write fan-out: 3 × `movem.l d0-d7/a2-a6, (aN)+` × 340 = 3 × 47
= 141 sl. **Total ≈ 188 sl per frame.** Roughly the same as the
current 3 cooperative shifts but **deterministic** — no race window.

My instinct: **Option A** is the pragmatic answer if the visual is good
enough. If 3 rows is non-negotiable, **Option D (CPU plot)** is the
principled fix — trades blitter parallelism for race-free determinism.
**Option B (video-counter timing)** is a clever middle ground but
fragile to timing assumptions.

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
