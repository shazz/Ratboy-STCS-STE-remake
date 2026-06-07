# Performance Review — Reaching 1 VBL

Date: 2026-06-07 (session 7). Builds on `OPTIM.md` (session-6 analysis) and the
current `src/scroller/engine.s`. Goal: all effects at **1 VBL** like the 1988
original. Current: **2 VBL** across the board (Effect 0 and Effects 1–7).

Budget reference: PAL 50 Hz = **160,000 cy/frame = 313 scanlines ≈ 512 cy/sl**.
Shifter steals ~1.5× on CPU accesses to video RAM during the visible window.

---

## 1. What's already optimized (don't redo)

| Area | State | File |
|------|-------|------|
| Timer-B ISR: encoded markers (sign-bit dispatch), no `cmpa.l` chain | ✅ ~184 cy/fire | `hbl.s:141` |
| Timer-B fire rate TBDR=2 (100 fires/frame, 2-line bands) | ✅ | `hbl.s:29` |
| Glyph offset LUT (kills ×816 `mulu`) | ✅ | `engine.s:1151` |
| Per-strip Y LUT `y_offset_lut` (kills ×184 `mulu` in inner loops) | ✅ | `engine.s:1123` |
| `type5_top_offset_lut` (Y math + X offset folded into one word) | ✅ | `engine.s:1109` |
| `ScrollShiftAndFill`: 4× 9-reg `movem` groups, `a5` hoist, runs in system RAM (no contention) | ✅ | `engine.s:372` |
| `ClearScrollerRange`: 13-reg `movem` clear (432 cy/line vs 552) | ✅ | `engine.s:1053` |
| Plot reordered after shift (shift dodges Shifter contention) | ✅ | `engine.s:96` |

So the cheap wins are spent. What remains is **memory bandwidth to video RAM**
and **shared ISR overhead** — the two things that actually gate 1 VBL.

---

## 2. Where the time goes now

The decisive session-6 finding still holds: **with `RASTER_ENABLED=0` the
scroller already fits in 1 VBL; with the gradient ON it spills to 2.** So we are
sitting right on the boundary and two costs push us over:

### A. The plot (video-RAM writes, contended) — dominant
- **Type 0 / Type 7 write 3 rows** = 3 × 34 lines × 160 B = **16,320 B/frame**.
  This is the dominant cost. NOTE: the **1988 original also has 3 scroller rows**
  and still hits 1 VBL — so the row count isn't the differentiator. Crucially the
  original ran on an **STF, which has NO blitter** (blitter is STE-only), so its
  cheaper 3-row render is a *CPU* trick (source-rewind / beam-timing — see
  `WRITE_UP.md`), NOT a blitter. Plot ≈ **~160 sl** for Type 0 (`engine.s:457`).
- Effects 1 & 3 write a row (+ deformation) **plus a clear** (`ClearScrollerRegion`
  130 lines / targeted `ClearScrollerRange`). The clear was CPU `movem` — now
  **blitter** (DONE, see §3 #1).

### B. Timer-B ISR — shared overhead
- TBDR=2 → 100 fires × 184 cy = **~18.4k cy ≈ 36 sl per VBL of work**.
- This compounds: a 2-VBL effect pays it twice. It is the shared cost that, once
  cut, helps *every* effect simultaneously.

### C. Channel-switch indirection — negligible (verified)
The new `chan_*` pointer indirection added to the hot path is essentially free:
`engine.s:268` (font base, 1×/2 VBL), `vbl.s` logo-palette `move.l`+`movem`
(~16 cy/frame), and `SetPalettePointers` runs only on effect change, not per
fire. **No action needed** — the switch feature does not stand between us and 1 VBL.

---

## 3. Ranked optimizations to reach 1 VBL

### TIER 1 — the levers that actually close the gap

| # | Optimization | Est. gain | Affects | Risk |
|---|--------------|-----------|---------|------|
| 1 | **Blitter for the clear** (`ClearScrollerRegion`/`Range`) — ✅ DONE | ~30–80 sl | 1, 3 | Low–Med |
| 2 | ~~Blitter for the plot~~ — ❌ TRIED, **~25 sl SLOWER** (cooperative copy ≈ CPU; see PROFILE.md) | — | — | — |
| 3 | **TBDR=3** (67 fires, 3-line bands) | ~12 sl/VBL | all | Med (phase/jitter) |
| 4 | **Cheaper 3-row render for Type 0/7** — CPU source-rewind/beam-timing (STF original had no blitter; NOT a blit) | ~?? | 0, 7 | High |

Also DONE (banked) this session:
- Remaining per-frame/per-strip `mulu #184` + `muls` removed (→ `y_offset_lut`
  + conditional negate) across Type1/3/4.
- **Type 0 & Type 4 plot loops unrolled** (REPT + baked `(d16,An)` displacements,
  no per-line `dbra`/`lea`): ~5 sl (Type 0), ~29 sl (Type 4 — was the slowest).
- **Type 3 clear**: full `ClearScrollerRegion` → targeted `ClearScrollerRange`
  (~46 sl — Type 3 was the only clear-bound effect).
- **Self-modifying Timer-B handler** (Tier 2 below) — ~7 sl/VBL, shared.

**#1 Blitter clear** is the cleanest big win and was scoped in `OPTIM.md` but
never implemented (the code still CPU-clears at `engine.s:1053`). The blitter
clears ~2 cy/word and overlaps CPU; a 130-line clear drops from ~130 sl to
~50 sl. For effects 1–7 (which all clear) this alone may land 1 VBL. Use the
`ste-blitter-expert` agent; mind the end-of-op quirk and HOG-vs-cooperative
choice.

**#2 Blitter plot — ❌ TRIED, NEGATIVE RESULT (reverted; see PROFILE.md).** A
cooperative copy-blit on Type 0 measured **~25 sl SLOWER** than the CPU `movem`.
The plot runs in the visible region so the blit must be cooperative (hog freezes
the gradient); the 64-cy yields + `bset/nop/bne` busy-wait + a copy's read+write
traffic land it ≈/worse than the CPU (which also read-shares the 3 rows). The
clear won only because it is write-only. The ONLY remaining blitter angle is
genuine CPU/blit **overlap** (do `ShiftAndFill` in the blit's yield slots, not a
busy-wait) — a large, uncertain restructure. Parked.

**#3 TBDR=3** is shared overhead reduction; smaller than it was pre-session-6
(~12 sl now, not the old ~45) because the handler is already lean, but it is
**low-effort and helps every effect**, and it is literally what the 1988 code
did. Needs the same phase-stability care as TBDR=2 (200/3 has a remainder →
verify marker fire-alignment, see `hbl.s` stride notes).

**#4 Cheaper 3-row rendering for Type 0/7.** The 1988 original has 3 scroller
rows and still hits 1 VBL — on an STF with **no blitter**, so its trick is pure
CPU: source-rewind (write a line + its neighbour from one source read) and/or
beam-timed writes (see `WRITE_UP.md` and Tier 3 beam-racing). This is the real
path now that #2 (blitter plot) is ruled out. The cheap slice — unrolling the
per-strip `.scanline` loops — is being banked (Type 0, 4 done; 1 next). The
deeper source-rewind / beam-racing is Tier 2/3.

### TIER 2 — your "autogenerated / patched code" idea (honest assessment)

You flagged autogenerated and self-modifying code. Both apply here, but they are
**polish, not the gap-closer** — useful to bank the last few scanlines once
Tier 1 lands.

**Autogenerated (REPT / macro-unrolled straight-line code):**
- Fully unroll the per-row plot loops (`REPT SCROLL_HEIGHT`) with **baked
  displacements** instead of `lea <stride>(aN)` + `dbra` per line. Type 0's
  inner loop pays 34 × (`dbra` ~14 + 3× `lea` 8) ≈ **~1.3k cy ≈ 2.5 sl/frame**;
  removing it is free real estate (34 × 184 = 6256 < ±32 K displacement limit).
- Adopt the original CONFO.S **source-rewind vertical-double** for the 2× effects
  (write line N and N+1 from one source read — see `OPTIM.md` §"Original type1").
  Saves the second *read*, not the write, so the gain is modest under contention
  but real for the 2×/4× tall effects.
- Net: **~2–5 sl per effect.** Macro-generate the unrolled bodies so the 8 plot
  routines stay maintainable.

**Patched (self-modifying) code:**
- **Dispatch:** replace the `cmp.w`/`beq` chain in `ScrollPlotDispatch`
  (`engine.s:436`) with a single patched `jmp (An)` updated only on effect
  change. Saves the chain each frame (~30–60 cy) — **<0.2 sl**, basically noise.
- **Double-buffer dest:** there are only two back-buffer addresses. You *could*
  patch absolute screen displacements into the unrolled plot at `SwapBuffers`
  time instead of indexing off `back_buffer_ptr` in a register. Saves a handful
  of cy/line — marginal, and it fights the unrolled-displacement scheme.
- **Timer-B handler — ✅ DONE.** Self-modified the read pointer into `GradRead`'s
  abs.l operand (eliminates the a0 save/restore + the `raster_ptr` memory
  round-trip) and collapsed the marker decode to one branch (`cmp #$1000 / bhs`
  → cold path). ~184 → ~148 cy/fire = **~7 sl/VBL**. The data-driven markers were
  already lean, so the realized gain is below the original ~13-sl ceiling estimate.
  Stacks with TBDR=3 if that lands later.

**Verdict on Tier 2:** the self-modifying *Timer-B handler* (done, ~7 sl/VBL) was
worth it — ISR cost is shared and compounding. The dispatch/dest patches and the
source-rewind unroll are each <3 sl — bank them last. Self-mod is harmless here
(we already patch `raster_table` markers + `GradWrite`/`GradRead` operands at
runtime), but keep it confined to the ISR and document every patched site.

### TIER 3 — architectural (high effort, high ceiling)

- **Beam-racing split:** plot the scroll rows *just ahead of the beam* so the
  writes land in already-displayed (or not-yet-displayed) scanlines, dodging
  contention. This is implicitly how the original fit 1 VBL. Big potential
  (~30+ sl of contention removed) but timing-fragile; needs `VIDEO_COUNTER`
  polling or careful budget accounting.
- **In-screen scroll row** (CONFO.S `type6` source-at-Y=160): tried and reverted
  in session 6 — it breaks effects 1–7 (clear wipes the source). Only viable as
  a Type-0-only hybrid; the Timer-B win already recovered its ~22 sl.

---

## 4. Recommended attack order

1. **Blitter clear** (Tier 1 #1) — ✅ DONE.
2. **TBDR=3** (Tier 1 #3) — low effort, shared, authentic; re-profile. STILL OPEN.
3. **Self-modifying Timer-B handler** (Tier 2) — ✅ DONE (~7 sl/VBL shared).
4. ~~Blitter plot~~ — ❌ TRIED & REVERTED: the cooperative copy-blit measured
   ~25 sl SLOWER than the CPU on Type 0 (see PROFILE.md "negative result"). A
   real win needs CPU/blit overlap (big restructure). The achievable plot wins
   are CPU-side per-strip unrolls (e.g. Type 4's `.scanline` still uses `dbra`).
5. **Unroll + source-rewind** (Tier 2) — Type 0 unroll ✅ DONE; source-rewind for
   the 2× effects still open (small).

Re-measure with HRDB / color-bar profiling (`PROFILE_ENABLED=1`,
`RASTER_ENABLED=0` to isolate, then ON to confirm) after each step — a blue band
at the *top* of a frame = last frame's plot bled past the VBL boundary.

## 5. One-line summary

The blitter helped the **clear** (write-only) but NOT the **plot** — a
cooperative copy is ≈/slower than the CPU (measured, reverted). The shared
**Timer-B ISR** was trimmed (self-mod, ~7 sl/VBL) and the one clear-bound effect
(Type 3) fixed. What remains toward 1 VBL is **CPU-side**: unroll the per-strip
plot loops (Type 0/4 done, 1 next), then the harder **source-rewind / beam-
racing** the STF original used — or TBDR=3 for a shared ~12 sl. The blitter plot
is a dead end unless CPU/blit overlap is built.
