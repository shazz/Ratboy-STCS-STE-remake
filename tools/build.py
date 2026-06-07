"""Build orchestrator for the Stargoose cracktro STE port.

Usage:
    uv run tools/build.py              # assemble only (build/STARGOOSE.PRG)
    uv run tools/build.py --run        # assemble + launch in Hatari
    uv run tools/build.py --assets     # regenerate build/*.bin from assets/
    uv run tools/build.py --clean      # wipe build/

Chains the VASM assembler and Hatari emulator from bin/. Asset converters
(png2planar, png2font, gradient2raster) will be invoked from --assets mode
once they exist (P2/P3/P5).
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
BUILD = ROOT / "build"
ASSETS = ROOT / "assets"
TOOLS = ROOT / "tools"

VASM = ROOT / "bin" / "vasm" / "vasmm68k_mot.exe"
HATARI_DIR = ROOT / "bin" / "hatari-2.6.1_windows64"
HATARI = HATARI_DIR / "hatari.exe"
TOS_IMG = HATARI_DIR / "tos.img"

MAIN_S = SRC / "main.s"
# Output under build/AUTO/ so Hatari (with --harddrive build/ mounting build as
# C:) boots straight into the demo via TOS's AUTO-folder auto-run — no GEM flash.
AUTO_DIR = BUILD / "AUTO"
PRG = AUTO_DIR / "STRGOOSE.PRG"


def log(tag: str, msg: str) -> None:
    print(f"[{tag}] {msg}")


def check_tools() -> None:
    missing = [p for p in (VASM, HATARI, TOS_IMG) if not p.exists()]
    if missing:
        for p in missing:
            log("error", f"missing: {p}")
        sys.exit(2)


def assemble() -> int:
    """Invoke VASM. -Ftos emits an Atari TOS .PRG. -I src and -I . let the
    source-tree includes and the build/ incbins resolve correctly."""
    AUTO_DIR.mkdir(parents=True, exist_ok=True)
    cmd = [
        str(VASM),
        "-Ftos",                                # Atari TOS .PRG executable
        "-quiet",
        "-spaces",                              # allow spaces after commas in operand lists
        "-I", str(SRC),                         # resolves include "..." from src/
        "-I", str(ROOT),                        # resolves incbin 'build/...' from project root
        "-o", str(PRG),
        str(MAIN_S),
    ]
    log("vasm", " ".join(cmd))
    rc = subprocess.run(cmd, cwd=ROOT).returncode
    if rc == 0:
        size = PRG.stat().st_size if PRG.exists() else 0
        log("vasm", f"ok — {PRG.relative_to(ROOT)} ({size} bytes)")
    return rc


def run_hatari() -> int:
    """Launch Hatari, mounting build/ as C: so TOS auto-runs build/AUTO/*.PRG."""
    if not PRG.exists():
        log("error", f"no PRG at {PRG}")
        return 1
    cmd = [
        str(HATARI),
        "--machine", "ste",
        "--memsize", "1",
        "--tos", str(TOS_IMG),
        "--harddrive", str(BUILD),              # mounts build/ as GEMDOS C:
        "--fast-boot", "on",
        "--fast-forward", "off",
        "--sound", "on",
        "--confirm-quit", "off",
    ]
    log("hatari", " ".join(cmd))
    return subprocess.run(cmd, cwd=ROOT).returncode


## ----------------------------------------------------------------------------
## Asset converters
## ----------------------------------------------------------------------------
# Each entry: (input_file, output_prefix, tool_script). Tool gets invoked as
#     uv run <tool> <input> <output_prefix>
# Staleness check: output.* missing or older than input → rebuild.
CONVERTERS = [
    (ASSETS / "top_logo.png", BUILD / "top_logo", "png2planar.py", (".pal", ".img")),
    (ASSETS / "gradient.png", BUILD / "gradient", "gradient2raster.py", (".raster",)),
    # Main font: used for bitmap AND c1-variant palette (the canonical scroller colors)
    (ASSETS / "fonts40x34_red_as_transparent.png", BUILD / "font", "png2font.py", (".pal", ".bin")),
    # 3-row palette variants (c2, c3) — we only need their .pal files, .bin is discarded
    (ASSETS / "font40x34_c2.png", BUILD / "font_c2", "png2font.py", (".pal", ".bin")),
    (ASSETS / "font40x34_c3.png", BUILD / "font_c3", "png2font.py", (".pal", ".bin")),
    # Channel B font (HOOKER): single-plane 2-color, non-ASCII glyph order →
    # remapped to ASCII layout. NOT inverted: glyph body → index 1, background →
    # index 0. The raster gradient is written to colour register 1 (the font),
    # leaving colour 0 (= border/backcolor) solid black. Glyph order = HOOKER's
    # own grid layout (A-Z, !'<=>., ?:, 0-9, comma — note the ':' between '?' and
    # '0'; the <=> cells are HOOKER's logo decoration). 5th tuple = extra args.
    (ASSETS / "HOOKER.png", BUILD / "font_b", "png2font_remap.py", (".pal", ".bin"),
     ("--order", "ABCDEFGHIJKLMNOPQRSTUVWXYZ!'<=>.?:0123456789,")),
    # Channel B logo (MJJ graffiti): mjj_logo74.png is logo-mjj.png's graffiti block
    # pre-cropped + scaled to 320×74 (the engine's logo geometry).
    (ASSETS / "mjj_logo74.png", BUILD / "mjj_logo", "png2planar.py", (".pal", ".img")),
]


def regenerate_assets() -> int:
    """Run each registered converter whose outputs are missing/stale."""
    for entry in CONVERTERS:
        inp, out_prefix, tool, exts = entry[:4]
        extra = list(entry[4]) if len(entry) > 4 else []
        outs = [out_prefix.with_suffix(e) for e in exts]
        fresh = all(o.exists() and o.stat().st_mtime >= inp.stat().st_mtime for o in outs)
        if fresh:
            log("assets", f"{inp.name}: up to date")
            continue
        cmd = [sys.executable, str(TOOLS / tool), str(inp), str(out_prefix), *extra]
        log("assets", " ".join(cmd))
        rc = subprocess.run(cmd, cwd=ROOT).returncode
        if rc != 0:
            log("error", f"converter {tool} failed on {inp.name}")
            return rc
    return 0


def clean() -> int:
    if BUILD.exists():
        shutil.rmtree(BUILD)
        log("clean", f"removed {BUILD.relative_to(ROOT)}")
    else:
        log("clean", "nothing to clean")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run", action="store_true", help="launch Hatari after build")
    parser.add_argument("--assets", action="store_true", help="regenerate build/*.bin from assets/")
    parser.add_argument("--clean", action="store_true", help="wipe build/")
    args = parser.parse_args()

    if args.clean:
        return clean()

    check_tools()

    # Always run asset regeneration — staleness check makes it cheap when there's
    # nothing to do. --assets is now a no-op flag kept for explicit intent.
    rc = regenerate_assets()
    if rc != 0:
        return rc

    rc = assemble()
    if rc != 0:
        return rc

    if args.run:
        return run_hatari()
    return 0


if __name__ == "__main__":
    sys.exit(main())
