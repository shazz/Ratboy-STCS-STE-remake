# Learnings — Stargoose STE Port

Accumulated as we go. Each entry dated. Not an ADR (those go in `decisions.md`) —
these are small but expensive-to-rediscover facts.

---

## VASM quirks

### 2026-04-22 — `-spaces` is required for spaces after commas

**Symptom:** `error 10: number or identifier expected` on any line using normal
operand formatting like `move.w  #$0700, $FF8240`.

**Cause:** VASM in Motorola syntax mode parses operand separators strictly. By
default, a space immediately following a `,` is rejected.

**Fix:** Pass `-spaces` to `vasmm68k_mot.exe`. Already wired into
`tools/build.py`. Without it, you'd have to write `move.w #$0700,$FF8240`
everywhere — readable code loses this fight.

**Rediscovery cost if forgotten:** ~15 minutes of staring at valid-looking
assembly wondering what's wrong.

---

## Atari ST/E system

### 2026-04-22 — Install VBL via the TOS vbl-queue, not by overwriting $70

**Rule:** Don't write your VBL handler address directly to `$70.w` unless you
chain to the original. Use the TOS vbl-queue instead.

**Why:** The vector at `$70` is the Level-4 autovector. TOS installs its own
handler there, which does critical housekeeping (keyboard polling via IKBD
drain, `_frclock` / `_hz_200` counters, floppy VBL processing) and THEN
iterates the vbl-queue at `_vblqueue` (`$456.w` → pointer to an array of
`_nvbls` (`$454.w`) long-aligned entries, default size 8, starting at `$4EA`).

If you replace `$70` directly, you lose all that housekeeping — GEMDOS
`Cconis` keyboard polling stops working, the `hz_200` timer stops ticking,
floppy access misbehaves.

**How to apply:** Find the first null slot in the vbl-queue, store your
handler pointer there. TOS calls each non-null slot from its VBL via **JSR**,
so your handler returns with **RTS**, not RTE.

**On exit:** null-out the slot you claimed.

### 2026-04-22 — STE byte registers at odd addresses — word access = 3 bombs

**Symptom:** 3 bombs (68000 Address Error) at boot after wiring LINEWID +
HSCROLL into the scroller.

**Cause:** `$FF820F` (LINEWID) and `$FF8265` (HSCROLL) are both **byte-only**
registers and live at **odd** addresses. A `move.w` / `clr.w` to those
addresses triggers the Address Error exception — 68000 requires word/long
memory accesses to be on even addresses. The bombs appear instantly at boot
because InitScreen is the very first place we poke either one.

**Fix:** Always use `.b` size for these. For example, to push our 0..15 word
`scroll_hscroll` into HSCROLL, use `move.b scroll_hscroll+1, VIDEO_HSCROLL`
— the `+1` picks up the low byte of the word (68K is big-endian).

**Which STE video registers are odd/byte?**
- `$FF8201/03/0D` — screen base (three separate byte regs, odd)
- `$FF820F` — LINEWID (byte)
- `$FF8265` — HSCROLL (byte)
- `$FF8260` — RES (byte, but at even-hmm — confirm before writing)

**Which are word-safe?**
- `$FF8240..$FF825E` — palette (16 words, even)
- `$FF8205/07/09` — video counter (byte reads, even)

When in doubt: check `docs/memory_map.txt`. Byte registers crash on word access.

### 2026-04-22 — STE HSCROLL ($FF8265) didn't move anything in our Hatari setup

**Symptom:** With LINEWID=12 (proven working — logo displays correctly at the
184-byte stride) and HSCROLL written per scanline via HBL, writing HSCROLL=8
statically into every scroll-row scanline did not shift displayed pixels.
Diagnostic #5 (static 'A' + HSCROLL=8 hardcoded) confirmed: 'A' stayed
exactly where HSCROLL=0 would put it.

**Hypotheses we couldn't confirm:**
- Possible Hatari STE emulation quirk with our TOS image version.
- Possible $FF8264 "preset" register also needs a write to enable fine-scroll.
- Possible LINEWID+HSCROLL pairing requirement we missed.

**What we did instead:** dropped HSCROLL entirely. Software scroll uses the
LINEWID pipeline but shifts content with CPU byte-moves (8-bit shift = half
a byte, hence byte-movable). See scroller/engine.s `ScrollShiftLeft8Bits`.
The blitter SKEW would be the authentic STE way — kept as a P10 option.

### 2026-04-23 — Hatari RESET does NOT reinitialize the blitter

**Symptom:** Blitter appeared to be completely dead — writing `$C0` to
`$FF8A3C` never cleared BUSY, the `btst` wait loop hung forever, firing
fire-and-forget produced no visible output, even a 1-word blit to screen
memory left no trace. Spent hours hypothesising broken register config,
wrong YINC formula, wrong HOP/LOP, TOS state, VBL-context issues…

**Cause:** We had been pressing Hatari's "reset" button between iterations.
Reset does NOT flush the emulated blitter's internal state. If a previous
build left the blitter in a weird state (mid-op, stuck BUSY, corrupted
latch), reset does not clear it — it stays hung across the "cold boot".
Subsequent builds see a permanently dead blitter even though the code is
fine.

**Fix:** Fully **quit and relaunch Hatari** when blitter behavior changes
unexpectedly. Don't trust reset.

**How to apply:** Any time blitter ops seem broken — especially if they
were working in a previous build — close Hatari entirely (kill the
window, not just reset) and rerun `uv run tools/build.py --run`. If the
first relaunched frame shows the expected blitter output, Hatari was
cached; your code was fine.

**Rediscovery cost:** ~8 hours of wrong-turn debugging, chasing phantom
YINC bugs, rewriting the scroller from scratch, pinging a subagent for
help. All because of a stale emulator state.

### 2026-04-22 — Blitter SKEW for sub-word shifts (from docs/blitter_faq.txt)

Notes for a future P10 upgrade to blitter-accelerated smooth scroll:

- **SKEW register (bits 3..0)** — 0..15 bit shift per copy. The blitter reads
  16 bits from bit position (15 - SKEW), using bits from an internal "upper
  overlap" buffer to fill the gap. After each word write, the lower 16 bits
  are copied into the upper for the next transfer. Effectively "hardware
  right-shift with carry between words" — no bit-by-bit shifting.

- **FXSR / NFSR flags** control initial-extra-read-source and no-final-read
  behavior at span ends. Matters when the skewed transfer needs an extra
  word at the start (FXSR) or can skip the final source read (NFSR).

- **Blitter takes the bus** — CPU and blitter can either contend (`BLiT mode`)
  or blitter has exclusive access (`HOG mode`) set by bit 6 of the control
  register. HOG is faster but freezes CPU; BLiT shares.

- **Historical note from the FAQ:** "STE demos mainly focussed on hardware
  scrolling and DMA sound, but, if at all, the BLiTTER was usually only
  being used for a couple of sprites." Blitter is underutilized — a smooth
  scroller via SKEW is a nice P10 effect.

**Planar trap:** Blitter is plane-agnostic. To shift 4 planes independently
with matching skew, we do **4 separate blits** (one per plane), each with
SRC_X_INC=8 (to skip past the other 3 interleaved planes in ST planar layout).
Setup cost ~4 × ~50 cy = 200 cy; transfer at ~4 cy/word × 680 words ≈ 2720 cy;
total ~3000 cy per plane × 4 planes = ~12K cy per frame. An order of magnitude
faster than the CPU 8-bit shift (~132K cy).

### 2026-04-24 — IKBD mouse packets shake the raster gradient

**Symptom:** With Timer-B-driven raster gradient working, gradient is
*scanline-stable* until the user moves the mouse — then it visibly
shifts up/down by 1+ scanlines, sometimes flicker-walking.

**Cause:** IKBD on the ACIA fires a L6 interrupt for every mouse delta
packet. TOS's ACIA ISR drains the byte queue and decodes the packet —
many cycles, often spanning multiple scanlines. While ACIA's L6 ISR
is running, Timer-B (also L6, same IPL mask in SR) cannot preempt.
Multiple DE pulses fire during the ACIA ISR, but MFP only latches ONE
pending interrupt per channel — so all but one Timer-B fire is lost.
Each lost fire = one scanline of the gradient table never written =
visible "shift" of the gradient phase.

**Fix:** at boot, send IKBD command `$12` ("disable mouse") via
ACIA1 data register `$FFFC02`. Wait for TDRE (status bit 1) before
the write. Restore on exit with `$08` (set relative — re-enables).
See `src/system.s` `DisableMouse` / `EnableMouse`.

**Rediscovery cost:** ~hour. Easy to miss because the rasters look
fine when you're not touching the mouse. Always disable IKBD-mouse
in any demo that uses Timer-B rasters.

### 2026-04-24 — Don't re-arm Timer-B every frame; let it free-run

**Symptom:** Even with mouse disabled, gradient shifts by exactly 1
scanline some frames. Pure phase jitter.

**Cause:** ArmTimerBRaster did `stop → write TBDR=1 → start` every
VBL. The exact moment the start hits depends on the variable latency
of TOS's vbl-queue dispatch + our handler prologue. Sometimes the
restart lands just before a DE pulse (first fire on next visible
line 0), sometimes just after (first fire on visible line 1). That's
the 1-line jitter.

**Fix:** start Timer-B ONCE in `InstallHBL` and leave it running for
the lifetime of the demo. The MFP auto-reloads TBDR=1 from its latch
on every fire (event-count mode, datasheet behavior). Per-frame, the
VBL handler only resets `raster_ptr`. The first DE pulse of every
visible area is just "the next event" the timer was already waiting
for — no per-frame restart, no jitter.

### 2026-04-24 — HOG mode blocks Timer-B; cooperative mode races at line boundaries

**Rule:** STE blitter HOG mode (`$C0` in CTRL) and per-scanline raster
Timer-B fundamentally cannot coexist during visible area. HOG mode
stalls the 68000 entirely — Timer-B interrupts queue but only one is
latched, and all others are lost.

Cooperative mode (`$80`) works in principle: blitter yields the bus
every 64 cycles, CPU services Timer-B during yields. But two non-obvious
issues bite:

1. **Wait-loop race.** The canonical Atari `bset/nop/bne` idiom can
   exit while the blitter still has lines to process — `bset` reads
   bit 7, sets it, tests its old value. At line-boundary arbitration
   the blitter can transiently clear bit 7 internally, the read
   returns 0 → Z=1 → loop exits → CPU writes new blit setup → the
   in-flight blit picks up new SRC/DST/YCOUNT and produces a corrupt
   row. Symptom: row N has lines 0..K correct, lines K..33 from a
   different source. Where K varies frame-to-frame (timing-dependent).

   **Mitigation:** after the bset/nop/bne loop, verify the YCOUNT
   register is 0 — if not, loop again. YCOUNT is the only state
   that monotonically reflects real progress. This catches most but
   not all instances of the race.

2. **ISR stretching.** FAQ §3.j: "the interrupt service routine should
   finish in less than 64 cycles, otherwise it is potentially stalled
   by the BLiTTER again." If the ISR is longer than 64 cy, the
   blitter steals bus mid-ISR, ISR wall-time can exceed 1 scanline,
   and Timer-B fires queue + collapse exactly like the mouse case
   above. Symptom: gradient flickers in the visible region where the
   blitter is active.

**Strategy used here:** split scroller work into HOG-during-vblank
and cooperative-during-visible. Heaviest work (shift + 1 of 3 row
copies = 97 sl) runs in the VBL handler in HOG mode — no rasters
firing yet, no harm. Lighter work (2 cooperative copies = 108 sl)
runs in MainLoop during visible. See `src/scroller/engine.s`
`ScrollerStepVblank` / `ScrollerStepVisible`.

### 2026-04-24 — Use `move.b` not `or.b` to start a clean cooperative blit

**Bug:** `or.b #$80, BLIT_CTRL` only sets bit 7. If the previous blit
was HOG mode (bit 6 = 1), the OR preserves bit 6 — the "cooperative"
blit is accidentally HOG.

**Fix:** `move.b #$80, BLIT_CTRL` writes the full byte: BUSY=1, HOG=0,
SMUDGE=0, halftone-line=0. Use this for cooperative starts. Use
`move.b #$C0` for HOG starts.

The Atari FAQ recommends `or.b #$80` as the canonical first-start in
cooperative mode, but it's only safe when bit 6 is already known to
be 0 (e.g., never in HOG before). In a mixed-mode pipeline (HOG shift
followed by cooperative copies), use explicit `move.b` to break HOG
residue.

### 2026-04-22 — HBL autovector ($68) fires on every scanline, not just rendered ones

**Symptom (first):** Raster gradient drifts position frame-to-frame. Different
Hatari runs show the gradient at different Y positions.

**Cause (initial assumption, wrong):** "HBL fires exactly 200 times per frame
in low-res so a self-wrapping 200-entry table will stay in phase."
Reality on ST/STE: HBL level-2 autovector fires on *every* horizontal scanline
including top/bottom borders and vertical retrace — ~313 per PAL frame, not
200. A 200-entry table self-wraps multiple times per frame, and its phase
relative to the display depends on where the Shifter is when we install the
handler. Hence the drift.

**Fix (drift):** Anchor `raster_ptr` to `raster_table` in the VBL handler
every frame. Bounds-check in the HBL handler so HBL #201..#~313 don't re-read
the table. Block VBL in HBL via SR IPL=5 (`move.w #$2500, sr`) so the VBL
reset can't corrupt HBL's read-modify-store on `raster_ptr`.

**Symptom (next):** With the VBL anchor fixed, gradient is stable but starts
too early — visible line 0 shows a blue already mid-gradient, and red fills
from visible line ~137 to 199 (see screenshots/grab0005).

**Cause:** The first ~62 HBLs after VBL fire during top overscan + vertical
retrace, *before* the first visible rendered line. Those 62 HBLs consume
table entries 0-61 during invisible scanlines. By the time visible line 0
renders, the pointer is already 62 entries in.

**Fix:** Pad the front of `raster_table` with `RASTER_TOP_OVERSCAN` (62) zero
words. The overscan HBLs then write black into color 0 (invisible anyway),
and the first visible line gets gradient entry 0 as intended. Total table
length = 62 + 200 = 262 entries.

**If we ever want Timer-B precision** (firing only on specific visible lines),
switch to MFP Timer B in event-count mode and arm/disarm it per frame. For
now the IPL-synced HBL autovector with VBL reset + overscan padding is plenty
accurate.

### 2026-04-22 — 68000 word-sized memory ops are atomic wrt interrupts

Reading/writing a word in memory from the main flow while a VBL handler
modifies the same word is safe — 68000 instructions are atomic relative to
external interrupts. No need for explicit sync (disabling IPL) for single-word
shared counters like `vbl_counter`. Matters for longs though: a `.l` store is
two bus cycles and CAN be interrupted between high/low words. Stick with `.w`
for shared counters unless you really need 32 bits.

---

## Build / run

### 2026-04-22 — Hatari auto-runs PRGs passed as argv

Passing the `.PRG` path as the last positional arg to `hatari.exe` is enough
to make TOS auto-execute it on boot — no disk image or GEMDOS drive mount
needed for simple PRG development. If auto-run ever stops working, the
fallback is `--hd <build-dir>` to mount build/ as GEMDOS C: and run from the
desktop.

### 2026-04-22 — Output filename truncates to 8.3 in TOS UI

Named the PRG `STRGOOSE.PRG` (8 chars base + `.PRG`) to match what TOS
displays. Longer names work but render truncated.

### 2026-04-22 — `AUTO/` folder skips GEM entirely

**Workflow:** put the PRG in a `AUTO/` subfolder on the Hatari-mounted drive
(C: via `--harddrive build/hd_c` for example). TOS executes every PRG in
`AUTO/` in alphabetical order *before* GEM/the desktop loads — so the demo
takes over the screen immediately, no flash of TOS desktop, no clutter.

On `Pterm0` return, TOS continues to the next AUTO PRG (or GEM if none). For
a demo this is perfect: clean start, clean shutdown.

Manual workflow for now: copy `build/STRGOOSE.PRG` into a mounted `AUTO/`.
Could automate in `build.py` by mounting `build/hd_c/` and dropping the PRG
in `build/hd_c/AUTO/` — defer until it becomes annoying.

---

## Scroll effects architecture (session 5)

### 2026-04-29 — Modular effect dispatcher pattern

**Pattern:** Use a dispatcher that routes to effect-specific plot routines:
```asm
ScrollPlotDispatch:
    move.w      scroll_effect_type, d0
    beq         ScrollPlotType0
    cmp.w       #1, d0
    beq         ScrollPlotType1
    ; ... etc
    bra         ScrollPlotType0    ; fallback
```

**Why it works:** Each effect is a self-contained function. Easy to:
- Test effects in isolation (change `SCROLL_EFFECT_DEFAULT`)
- Compare our implementation against original CONFO.S
- Add new effects without touching existing code

**Implementation notes:**
- Effects share `scroll_buffer` (21 pwords × 34 lines)
- Each effect calculates its own Y positions per strip (20 strips = 320 pixels)
- Vertical doubling (Type 1, Type 4) writes each source line multiple times
- Sine/diagonal effects use per-strip Y offset calculations

### 2026-04-29 — Strip-based column plotting for wave effects

**Pattern:** Process 20 "strips" (pword columns, 16 pixels each) left-to-right,
calculating Y offset per strip to create wave/diagonal shapes.

**Original CONFO.S approach:**
- Loop counter `d0` = 19 down to 0 (right to left in original)
- Cumulative Y offset modified per strip iteration
- Different offset rules create different wave patterns

**Our implementation:**
- Strip index = 19 - d6 (0 to 19, left to right)
- Calculate offset based on strip index position
- Apply offset to Y position before plotting

**Wave patterns:**
- Type 7 (sine): staircase pattern — strips 0-5 down, 6 flat, 7-13 up, 14 flat, 15-19 down
- Type 5 (converge): min(strip, 19-strip) creates symmetric bulge at center
- Type 3 (diagonal): linear offset = strip index

### 2026-04-29 — Vertical scaling via line repetition

**For 2× tall (Type 1):** Write each source scanline twice:
```asm
move.l      d0, (a1)
move.l      d1, 4(a1)
move.l      d0, SCREEN_LINE_BYTES(a1)
move.l      d1, SCREEN_LINE_BYTES+4(a1)
lea         SCREEN_LINE_BYTES*2(a1), a1   ; advance 2 lines
```

**For 4× tall (Type 4):** Write each source scanline four times. Only plot
25 of 34 source lines to fit on screen (25 × 4 = 100 lines output).

**Tradeoff:** Larger output means fewer source lines fit — 4× tall truncates
the bottom of glyphs slightly.

---

## Smooth 8 px / VBL scrolling: alternating-page byte-shift

### 2026-04-30 — How RATBOY did smooth 8 px scrolling on a 1988 STF

**Problem:** Naive CPU pword-shift gives 16 px / VBL — visibly chunky for a
40-px-wide font. Naive CPU per-plane byte-shift across the whole buffer is
correct for 8 px / VBL but is too slow on a 68000 (~5700 byte-moves per
frame, ~190 scanlines of work, frame-budget-blowing).

**RATBOY's trick (CONFO.S):** double-buffered screen pages, where each page
holds the same scroll content but offset from the other by 1 byte (= 8 px)
horizontally. Display alternates each frame; visual rate = 8 px / VBL.
Per-frame work amortizes to **~40 sl** (≈ 5× cheaper than full byte-shift):

1. **Bulk pword-shift** of the inactive page's scroll row (38 long-copies =
   152 bytes = pwords 1..19 → pwords 0..18).
2. **Fill rightmost pword** (8 bytes) from the OTHER (currently-displayed)
   page's rightmost pword via 2 long-copies (= the `ad_copy` reference).
3. **Byte-shift the rightmost pword in place** with 8 byte-moves: per-plane
   high byte ← previous page's plane low; per-plane low byte ← incoming
   "next pword" data (from a separate staging slot).

**Why it works:** the bulk shift is content-preserving (just slides existing
content left by 16 px). The OTHER page's rightmost pword already represents
"the latest 16 px the player has seen at the right edge", so copying it over
and byte-shifting gives the inactive page content offset by 8 px from the
displayed one. When alternation happens at vsync, the eye sees a smooth 8-px
slide every frame.

**Memory layout (CONFO.S):**

```
$080000  ────►  Page A (full 32K screen)
                ├── displayed scroll row (line 73 ish)
                └── off-screen scroll buffer (deca = 33600 bytes from base,
                    past the visible 200 lines)

$090000  ────►  Page B  (mirror layout)
```

`deb_blk = phys + deca` (off-screen workarea on the back-buffer page).
`ad_copy = front-buffer page + deca + 152` (= rightmost pword of the
displayed page's off-screen scroll buffer). `phys` toggles between
$080000 and $090000 each frame via `swap`.

**Why two pages instead of two RAM buffers?** On STF the screen base
register can only point to RAM-aligned 256-byte pages, so the natural
double-buffer slots ARE the screen. Off-screen workarea on the same page
is just a bigger allocation — both pages are 32K each and only the first
~32000 bytes are visible, the rest is free workspace.

**Cost breakdown (CONFO.S `scrolg`, per scanline):**

| Step          | Cycles | Bytes moved |
| ------------- | -----: | ----------: |
| REPT 38 long-copy | 456 | 152 (pwords 1..19 → 0..18) |
| REPT 2 long-copy  |  24 |   8 (ad_copy → pword 19) |
| 8 byte-moves      | 128 |   8 (rightmost pword byte-shift) |
| **Per scanline**  | **608** | **168** |

× 34 scanlines ≈ 20700 cycles ≈ **40 sl per frame** for the whole shift.
Compare to ~190 sl for naive full-buffer byte-shift — **~5× speedup**.

### 2026-04-30 — Adapting to our 21-pword off-RAM buffer architecture

Our scroll buffer is a 21-pword × 34-line area in regular RAM (not on the
screen pages), and our plot routines copy from the buffer to the back
screen. To get the same 8-px/VBL effect with our architecture we keep the
double-buffering at the **scroll-buffer** level rather than the screen-page
level:

* Two scroll buffers, `scroll_buffer_a` and `scroll_buffer_b`, both 21-pword
  × 34-line in RAM. They hold the same scroll content offset by 1 byte (= 8 px).
* `scroll_active_buf` (0/1) flips each VBL — it picks which buffer the plot
  routines read from this frame.
* `scroll_next_pword` (1 pword × 34 lines in RAM) is the "queue" the
  renderer fills with the upcoming character data.
* `scroll_byte_pending` (0/1) tracks the byte-shift phase: one half of
  `scroll_next_pword` per VBL.

**Per-VBL pipeline:**

1. Plot the active buffer to the back screen (existing plot routines, but
   now reading from `scroll_buffer_a` or `scroll_buffer_b` based on flag).
2. Toggle `scroll_active_buf` — the *other* buffer is what we plot next frame.
3. **Update the now-active buffer:**
   * Pword-shift it left by 1 pword (in-place, like the existing
     `ScrollShift`).
   * Fill its new rightmost pword from a byte-shift of the *previously
     displayed* buffer's rightmost pword + the relevant half of
     `scroll_next_pword` (selected by `scroll_byte_pending`).
4. Toggle `scroll_byte_pending`. When it wraps from 1 → 0, render a new
   pword into `scroll_next_pword` (existing 5-phase glyph blender, just
   targeting the staging area instead of `scroll_buffer + RIGHT_OFFS`).

The plot routines need one tiny change: `lea scroll_buffer, a2` becomes
`move.l scroll_plot_addr, a2`, where `scroll_plot_addr` is set in
`ScrollerStepVblank` to whichever of A/B is active this frame.

**Result:** smooth 8-px/VBL scrolling matching the 1988 original, at ~50 sl
of shift work per frame instead of ~190.
