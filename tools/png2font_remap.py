"""png2font_remap.py — Convert a font PNG with a NON-ASCII glyph order into the
engine's ASCII-indexed planar glyph pack.

Some font PNGs lay their glyphs out in a custom order (e.g. the fuzion font:
A-Z, then !'()-.?:, then 0-9, then comma) and on a different grid than the
8×8 / ASCII-32 layout png2font.py assumes. This tool maps each source glyph to
its ASCII slot (glyph index = ASCII - 32) so the runtime glyph_offset_lut and
.fetch_next_char parser address it unchanged.

It reuses png2font's exact planar encoder (encode_glyph) and png2planar's
palette reduction, so the output .bin is byte-compatible with build/font.bin —
only the glyph CONTENT and ORDER differ. Characters absent from the source
order become blank (index-0) glyphs.

Usage:
    uv run tools/png2font_remap.py <input.png> <output_prefix> \
        [--order STR] [--cols N] [--rows N] [--cellw N] [--cellh N]

Defaults match assets/fuzion_fonts.png (320×200, 8×6 grid of 40×34 cells).
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import png2font as pf  # noqa: E402  — reuse encode_glyph + glyph constants
from png2planar import reduce_palette, ste_palette_word  # noqa: E402

# Fuzion font's native glyph order (row-major in the source grid).
FUZION_ORDER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ!'()-.?:0123456789,"

FONT_FIRST_ASCII = 32  # glyph 0 = space (matches constants.s FONT_FIRST_ASCII)


def build_palette(reduced: list[tuple[int, int, int]]) -> tuple[list, dict]:
    """Reduce to ≤16 colors, pin (0,0,0) to slot 0 (the transparent/gradient
    index), pad to 16 — identical policy to png2font."""
    palette = list(dict.fromkeys(reduced))
    if (0, 0, 0) in palette:
        palette.remove((0, 0, 0))
    palette.insert(0, (0, 0, 0))
    while len(palette) < 16:
        palette.append((0, 0, 0))
    palette = palette[:16]
    # First-occurrence wins: the black padding entries (indices >0) must NOT
    # overwrite black→0. A plain dict comprehension takes the LAST index, which
    # maps black to 15 and breaks single-index 2-colour fonts (cell background
    # lands on colour 15 instead of 0). setdefault keeps the pinned index 0.
    idx_of: dict[tuple[int, int, int], int] = {}
    for i, c in enumerate(palette):
        idx_of.setdefault(c, i)
    return palette, idx_of


def build_inverted(reduced: list[tuple[int, int, int]]) -> tuple[list, dict]:
    """Two-index INVERTED mapping for gradient-filled letters: glyph body →
    index 0 (so the per-scanline raster gradient written to color 0 fills the
    letters), background → index 1 (a solid surround set by the font palette
    swap). Luminance threshold; suits a clean 2-color (single-plane) source.
    The .pal is unused at runtime (font_palette_b is inline in data/font.s)."""
    idx_of = {c: (1 if sum(c) < 96 else 0) for c in set(reduced) | {(0, 0, 0)}}
    palette = [(0, 0, 0)] * 16  # placeholder; runtime palette is font_palette_b
    return palette, idx_of


def extract_glyph(reduced, w, h, gx, gy):
    """Pull one pf.GLYPH_W_SRC×pf.GLYPH_H cell at (gx,gy), padding out-of-bounds
    pixels (e.g. a clipped bottom row) with background (0,0,0)."""
    out = []
    for ly in range(pf.GLYPH_H):
        for lx in range(pf.GLYPH_W_SRC):
            x, y = gx + lx, gy + ly
            out.append(reduced[y * w + x] if (x < w and y < h) else (0, 0, 0))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("png")
    ap.add_argument("out_prefix")
    ap.add_argument("--order", default=FUZION_ORDER)
    ap.add_argument("--cols", type=int, default=8)
    ap.add_argument("--rows", type=int, default=6)
    ap.add_argument("--cellw", type=int, default=pf.GLYPH_W_SRC)
    ap.add_argument("--cellh", type=int, default=pf.GLYPH_H)
    ap.add_argument("--invert", action="store_true",
                    help="glyph body → index 0 (raster gradient fills the letters), "
                         "background → index 1 (solid surround)")
    a = ap.parse_args()

    img = Image.open(a.png).convert("RGB")
    w, h = img.size
    reduced = reduce_palette(list(img.getdata()), max_colors=16)
    palette, idx_of = build_inverted(reduced) if a.invert else build_palette(reduced)
    print(f"png2font_remap: {Path(a.png).name} — {w}×{h}, "
          f"{a.cols}×{a.rows} grid, {len(a.order)} source glyphs"
          f"{' (inverted: gradient-filled)' if a.invert else ''}")

    out = Path(a.out_prefix)
    out.parent.mkdir(parents=True, exist_ok=True)
    pal = bytearray()
    for r, g, b in palette:
        pal.extend(struct.pack(">H", ste_palette_word(r, g, b)))
    out.with_suffix(".pal").write_bytes(bytes(pal))

    pos = {ch: i for i, ch in enumerate(a.order)}  # char → source cell index
    blank = [(0, 0, 0)] * (pf.GLYPH_W_SRC * pf.GLYPH_H)
    bin_bytes = bytearray()
    for ascii_code in range(FONT_FIRST_ASCII, FONT_FIRST_ASCII + pf.GLYPH_COUNT):
        ch = chr(ascii_code)
        if ch in pos:
            cell = pos[ch]
            gx, gy = (cell % a.cols) * a.cellw, (cell // a.cols) * a.cellh
            bin_bytes.extend(pf.encode_glyph(extract_glyph(reduced, w, h, gx, gy), idx_of))
        else:
            bin_bytes.extend(pf.encode_glyph(blank, idx_of))

    assert len(bin_bytes) == pf.GLYPH_COUNT * pf.GLYPH_BYTES
    out.with_suffix(".bin").write_bytes(bytes(bin_bytes))
    mapped = sum(1 for c in range(FONT_FIRST_ASCII, FONT_FIRST_ASCII + pf.GLYPH_COUNT)
                 if chr(c) in pos)
    print(f"  → {out.with_suffix('.bin')}  ({len(bin_bytes)} bytes, "
          f"{mapped} glyphs mapped, {pf.GLYPH_COUNT - mapped} blank)")
    print(f"  → {out.with_suffix('.pal')}  ({len(pal)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
