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
