# Debugging the demo with Hatari

This document explains how Claude (or any developer) can use Hatari's
built-in CPU debugger to inspect the running demo non-interactively from
a Linux terminal. Useful for memory inspection, breakpoint-driven dumps,
disassembly checks, and verifying buffer contents at specific moments.

## Prerequisites

- `hatari` installed system-wide (`apt install hatari` or similar). Verify
  with `hatari --version`.
- TOS image at `bin/hatari/TOS/tos162fr.img` (check it exists).
- An X display available — set `DISPLAY=:0` before launching Hatari, or
  the emulator will fail to start. Hatari needs an SDL window even in
  fast-forward mode, but you don't need to interact with it.
- A built `build/AUTO/STRGOOSE.PRG` (run `./bin/vasm/vasmm68k_mot ...`).

## Launch Hatari with command-fifo support

Hatari reads commands from a fifo while emulation is running. Pattern:

```bash
pkill hatari 2>/dev/null; sleep 1
rm -f /tmp/hatari_fifo /tmp/hatari_out.log

hatari --machine ste --memsize 1 \
    --tos /home/matt/projects/MJJ/bin/hatari/TOS/tos162fr.img \
    --harddrive /home/matt/projects/MJJ/build \
    --fast-boot on --fast-forward on --confirm-quit off \
    --cmd-fifo /tmp/hatari_fifo > /tmp/hatari_out.log 2>&1 &
HATARI_PID=$!

# Wait for fifo to be created by Hatari
for i in 1 2 3 4 5; do [ -p /tmp/hatari_fifo ] && break; sleep 1; done

# Wait for demo to boot — TOS load + auto-run takes ~3-4 seconds
sleep 4
```

**Important flags:**

- `--cmd-fifo` — Hatari **creates** this fifo (don't pre-create with `mkfifo`,
  it'll error). Send commands by writing lines to the fifo.
- `--harddrive build/` — mounts `build/` as drive C:. TOS auto-runs
  `build/AUTO/STRGOOSE.PRG` at startup.
- `--fast-forward on` — runs at maximum speed. Demo doesn't render at 50
  Hz; it runs hundreds of VBLs per second. Use this for non-interactive
  scripts to capture state quickly.
- `--confirm-quit off` — Hatari won't ask "are you sure?" when killed.

## Sending commands via the fifo

The fifo expects **wrapper commands**, NOT raw debugger syntax:

| Wrapper | What it does |
|---------|--------------|
| `hatari-debug <CLI command>` | Execute one debugger CLI command |
| `hatari-stop` | Pause emulation |
| `hatari-cont` | Resume emulation |
| `hatari-shortcut <name>` | Trigger keyboard shortcut (`screenshot`, `quit`, ...) |

Example: take a screenshot of the running demo.

```bash
echo "hatari-debug screenshot /tmp/hatari_demo.png" > /tmp/hatari_fifo
sleep 1
ls -la /tmp/hatari_demo.png
# The PNG can be viewed with the Read tool to verify visual state.
```

Always `sleep` briefly after sending each command — the fifo is async and
Hatari needs a moment to process and write output to its log.

## Loading our PRG's symbols

The PRG is built with embedded DRI/GST symbols (vasm `-Ftos` produces them
by default). To resolve symbols by name:

```bash
echo "hatari-debug symbols prg" > /tmp/hatari_fifo
sleep 1
```

This prints something like:

```
Reading symbols from program '...STRGOOSE.PRG' symbol table...
TOS executable, DRI / GST symbol table, ...
Loaded 184 symbols (40 TEXT) from '...STRGOOSE.PRG'.
```

After this, **symbols can be used in any debugger command** — `evaluate
ScrollShiftAndPlot`, `b pc=ScrollShiftAndPlot`, `disasm ScrollShiftAndPlot`,
etc.

**Symbols only auto-load if the PRG was started via GEMDOS HD emulation
(`--harddrive`).** Always use `--harddrive build/` to enable this.

**Symbols are freed when the program exits.** If the demo terminates
before you finish your session, symbols vanish.

## Useful debugger commands

Send each via `hatari-debug <command>` through the fifo.

| Command | Purpose |
|---------|---------|
| `evaluate <expr>` | Print value of expression. Use parens to dereference: `evaluate (back_buffer_ptr)` reads the long stored at that address. |
| `m <addr> [n]` | Dump n longs of memory (default 16) starting at address. **Address must be a literal hex/decimal — does NOT accept indirect parens.** Compute the address with `evaluate` first, then dump. |
| `disasm <addr>` | Disassemble starting at address (or symbol). |
| `cpureg` (or `r`) | Dump all CPU registers (d0-d7, a0-a7, PC, SR). |
| `b <condition>` | Set conditional breakpoint. Common form: `b pc=$XXXX` or `b pc=SymbolName`. Options after condition: `:once` (delete after one hit), `:trace` (don't pause, just print), `:file <path>` (run commands from file on hit). |
| `b` (no args) | List active breakpoints. |
| `b <index>` | Remove breakpoint by index. |
| `b all` | Remove all breakpoints. |
| `c` | Continue emulation. |
| `s` | Single-step CPU. |
| `screenshot <path>` | Save current screen as PNG. |
| `symbols code` | List loaded TEXT symbols by address. |
| `symbols data` | List loaded DATA/BSS/ABS symbols by address (paginated — Hatari pauses at "--- q to exit listing"). |

## Breakpoint-driven memory dumps

**The pattern:** set a breakpoint on a specific PC, attach a `:file
<dump_cmds.txt>` action, and continue. When the breakpoint hits, Hatari
runs the commands from the file, capturing their output to the log.

```bash
# Step 1: write the dump commands to a file.
cat > /tmp/dump_cmds.txt << 'EOF'
evaluate (back_buffer_ptr)
m $1FB10 60
m $20F30 60
c
EOF

# Step 2: load symbols and arm the breakpoint.
echo "hatari-debug symbols prg" > /tmp/hatari_fifo
sleep 1
echo "hatari-debug b pc=ScrollShiftAndPlot+\$EA :file /tmp/dump_cmds.txt :once" > /tmp/hatari_fifo
sleep 1

# Step 3: continue (the demo was paused on debugger entry).
echo "hatari-debug c" > /tmp/hatari_fifo
sleep 3   # let the breakpoint fire and the dump complete

# Step 4: kill Hatari and read the log.
kill $HATARI_PID 2>/dev/null
sleep 1
cat /tmp/hatari_out.log
```

The `:once` qualifier deletes the breakpoint after one hit, so the output
is bounded. Without it the breakpoint fires every VBL and floods the log.

## Address arithmetic — Hatari's idiosyncrasies

- Use `$` for hex (`$AF20`) — bare numbers are decimal.
- `evaluate` accepts **indirect** with parens: `evaluate (addr)` reads the
  long at `addr`.
- `m` (memdump) does NOT accept indirect — pass a literal address.
  Workflow: `evaluate (back_buffer_ptr)` to get the runtime value, then
  use that hex value in a follow-up `m` command.
- Addresses can mix symbols and offsets: `evaluate ScrollShiftAndPlot+$EA`,
  `b pc=ScrollShiftAndPlot+$EA`.
- The PRG load address varies between runs — TEXT symbols (`ScrollShiftAndPlot`
  etc.) resolve correctly via `symbols prg`, but BSS pointer **values**
  (where the screen buffers actually live) change per run. Dereference at
  runtime via `evaluate (back_buffer_ptr)`.

## Output capture

Hatari writes debugger output to **stdout/stderr** of the process (the
log file `/tmp/hatari_out.log` if you redirected). Some output is
paginated — listings show `--- q to exit listing, just enter to continue ---`.
Subsequent fifo commands act as the "continue" key, but if you need the
listing in full, send a continuation command after the paginated one.

## Reading screenshots

Hatari's `screenshot <path>.png` writes a PNG at the requested path. Read
it with the `Read` tool to view the demo's visual output:

```
Read /tmp/hatari_demo.png
```

The PNG is the actual emulated 320×200 framebuffer.

## Worked example: dumping row 1 of the back buffer

Goal: at the moment the scroller plot finishes, dump the row 1 area of
the back buffer to compare lines 0-4 (visible top of row) against lines
28-33 (the glitch region).

```bash
# Find addresses we'll need (do this once per build; symbols don't move
# within a single Hatari session but the PRG's load address can change
# between sessions).
echo "hatari-debug evaluate ScrollShiftAndPlot" > /tmp/hatari_fifo  # → $AF20 (entry)
echo "hatari-debug disasm ScrollShiftAndPlot" > /tmp/hatari_fifo    # locate the rts

# From the listing the rts is at section offset $4EA, so absolute = $AF20 + $EA = $B00A.

# Set breakpoint at the rts; on hit, dump back_buffer_ptr value, then
# manually re-run with that value substituted into the m commands.
cat > /tmp/dump_cmds.txt << 'EOF'
evaluate (back_buffer_ptr)
c
EOF

echo "hatari-debug b pc=\$b00a :file /tmp/dump_cmds.txt :once" > /tmp/hatari_fifo
sleep 1
echo "hatari-debug c" > /tmp/hatari_fifo
sleep 2
```

Read `/tmp/hatari_out.log` for the resolved `back_buffer_ptr` value,
then construct a second dump_cmds with the literal addresses:

```
m <BACK>+$3810 60       ← row 1 line 0  (back + 78*184)
m <BACK>+$4C30 60       ← row 1 line 28 (back + 106*184)
```

(In a single session you can chain both — first run sets the breakpoint,
captures the value into a known location via `cpureg`, second run dumps
based on that value.)

## Setting up an automated session

Full automated session template:

```bash
#!/bin/bash
set -e

# 1. Ensure a fresh build
./bin/vasm/vasmm68k_mot -Ftos -spaces -I src -I . -o build/AUTO/STRGOOSE.PRG src/main.s

# 2. Clean up any previous Hatari instance
pkill hatari 2>/dev/null; sleep 1
rm -f /tmp/hatari_fifo /tmp/hatari_out.log

# 3. Launch Hatari
hatari --machine ste --memsize 1 \
    --tos bin/hatari/TOS/tos162fr.img \
    --harddrive build \
    --fast-boot on --fast-forward on --confirm-quit off \
    --cmd-fifo /tmp/hatari_fifo > /tmp/hatari_out.log 2>&1 &
HATARI_PID=$!
trap "kill $HATARI_PID 2>/dev/null" EXIT

# 4. Wait for fifo + boot
for i in 1 2 3 4 5; do [ -p /tmp/hatari_fifo ] && break; sleep 1; done
sleep 4

# 5. Send your commands
echo "hatari-debug symbols prg" > /tmp/hatari_fifo
sleep 1
echo "hatari-debug screenshot /tmp/hatari_demo.png" > /tmp/hatari_fifo
sleep 1
# ... your debug commands ...

# 6. Quit Hatari and read the log
sleep 1
kill $HATARI_PID
sleep 1
cat /tmp/hatari_out.log
```

## Pitfalls

- **`hatari-shortcut debug`** does NOT work (the `debug` shortcut is not
  registered). Use `hatari-debug` directly.
- **`hatari-stop`** pauses emulation but does NOT drop into the CLI in a
  way that prints output. Use `hatari-debug <cmd>` to execute commands.
- **Pagination**: `symbols data`, `disasm` (long), and other listings
  pause at `--- q to exit listing ---`. Subsequent fifo commands act as
  Enter; for clean capture, suppress pagination by passing a small symbol
  range, or send a manual continuation.
- **Variable PRG load address**: between Hatari runs, the PRG can land at
  different addresses. Always `evaluate` symbol values per-session
  rather than caching addresses across sessions.
- **`m <indirect>` doesn't work**: memdump only takes literal addresses.
  Workflow is two-step: `evaluate (ptr)` → note the value → `m $value n`.
- **All zeros in a buffer dump** can mean (a) the buffer was just
  initialized but plot hasn't run yet, (b) the plot writes color-0
  content (initial scroller text often is mostly background pixels), or
  (c) the wrong buffer / wrong offset. Sanity-check by dumping a
  KNOWN-non-zero region (e.g., the diagnostic bar at line 195) first.

## Current debug findings (2026-04-25)

Investigating the Y=107-111 row 1 glitch. Confirmed via Hatari debugger:

- ScrollShiftAndPlot at `$AF20` (this session's load), rts at `$B00A`.
- back_buffer_ptr value at plot-end alternates between two buffers
  (e.g. `$1C300` and `$25300` per-run, depending on TOS load).
- A breakpoint-driven dump of the back buffer's row 1 line 28
  area at the rts shows the buffer content needs further investigation
  (initial dump showed unexpected zeros — needs re-dump with verified
  addresses).

Continue from here with:
- Dumping a known-content offset (logo area at line 0-73 of either
  buffer) to verify buffer pointers are correct.
- Then dumping row 1 line 28 vs line 0 to see if shift/plot wrote
  glyph data correctly.
