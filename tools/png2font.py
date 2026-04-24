"""png2font.py — Convert a tile-grid font PNG into an ST-planar glyph pack.

Usage:
    uv run tools/png2font.py <input.png> <output_prefix>

The input PNG must be a regular grid of fixed-size glyphs, laid out
row-major starting at ASCII code 32 (space). For the Stargoose cracktro
this is 8×8 tiles of 40×34 each (320×272 total).

To stay word-aligned in the ST planar format, each 40-pixel glyph is
padded to 48 pixels (3 pixel-words × 16 pixels). That wastes 8 pixels
of horizontal budget per glyph but eliminates the need for a per-pixel
pre-shifted table (which would be ~500 KB in low-res 16-color).

Output:
    <output_prefix>.bin  — GLYPH_COUNT × GLYPH_BYTES of planar data.
    <output_prefix>.pal  — 16 big-endian STE palette words (32 bytes).

Planar layout per glyph:
    For each of 34 scanlines:
      For each of 3 pixel-words (16 pixels each):
        4 × 16-bit plane words interleaved (plane 0, 1, 2, 3)
    Total per glyph: 34 × 3 × 4 × 2 = 816 bytes.

The glyph at index (ASCII - 32) is at file offset (ASCII - 32) × 816.
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from png2planar import ste_palette_word, snap_channel, reduce_palette  # noqa: E402

GLYPH_W_SRC = 40
GLYPH_H = 34
GLYPH_W_PADDED = 48                     # rounded up to a multiple of 16
PWORDS_PER_GLYPH = GLYPH_W_PADDED // 16  # = 3
GLYPH_BYTES = GLYPH_H * PWORDS_PER_GLYPH * 4 * 2  # = 816
GRID_COLS = 8
GRID_ROWS = 8
GLYPH_COUNT = GRID_COLS * GRID_ROWS  # 64, ASCII 32..95


def encode_glyph(pixels: list[tuple[int, int, int]], idx_of: dict) -> bytes:
    """Encode one 48×34 glyph (right-padded with index 0) into planar words."""
    data = bytearray()
    for line in range(GLYPH_H):
        for pword in range(PWORDS_PER_GLYPH):
            indices = []
            for i in range(16):
                x = pword * 16 + i
                if x < GLYPH_W_SRC:
                    indices.append(idx_of[pixels[line * GLYPH_W_SRC + x]])
                else:
                    indices.append(0)  # pad with background index
            for plane in range(4):
                word = 0
                for idx in indices:
                    word = (word << 1) | ((idx >> plane) & 1)
                data.extend(struct.pack(">H", word))
    return bytes(data)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    png_path = Path(sys.argv[1])
    out_prefix = Path(sys.argv[2])
    out_prefix.parent.mkdir(parents=True, exist_ok=True)

    img = Image.open(png_path).convert("RGB")
    w, h = img.size
    expected_w = GRID_COLS * GLYPH_W_SRC
    expected_h = GRID_ROWS * GLYPH_H
    if (w, h) != (expected_w, expected_h):
        print(f"error: expected {expected_w}×{expected_h}, got {w}×{h}", file=sys.stderr)
        return 1

    pixels = list(img.getdata())
    print(f"png2font: {png_path.name} — {w}×{h}, {GLYPH_COUNT} glyphs")

    # Sentinel: pure red (255, 0, 0) in the source PNG marks the intended
    # "transparent" background — pixels that should map to palette index 0
    # at runtime, where the HBL handler writes a per-scanline gradient.
    # We remap that sentinel to (0, 0, 0) *before* palette reduction so it
    # naturally collapses with any other pure-black pixels into one slot.
    TRANSPARENT_SENTINEL = (255, 0, 0)
    pixels = [(0, 0, 0) if p == TRANSPARENT_SENTINEL else p for p in pixels]

    # Reduce to ≤16 colors via snap + merge; same approach as png2planar.
    reduced = reduce_palette(pixels, max_colors=16)
    palette = list(dict.fromkeys(reduced))

    # Pin (0,0,0) to palette index 0 — that's the transparent/gradient slot.
    if (0, 0, 0) in palette:
        palette.remove((0, 0, 0))
    palette.insert(0, (0, 0, 0))

    while len(palette) < 16:
        palette.append((0, 0, 0))
    palette = palette[:16]
    idx_of = {c: i for i, c in enumerate(palette)}
    print(f"  palette slot 0 = (0,0,0) [transparent, gradient-tracking]")
    print(f"  {len(set(palette))} distinct palette entries")

    # Palette output
    pal_path = out_prefix.with_suffix(".pal")
    pal_bytes = bytearray()
    for r, g, b in palette:
        pal_bytes.extend(struct.pack(">H", ste_palette_word(r, g, b)))
    pal_path.write_bytes(bytes(pal_bytes))
    print(f"  → {pal_path}  ({len(pal_bytes)} bytes)")

    # Glyph bitmap output
    bin_bytes = bytearray()
    for gi in range(GLYPH_COUNT):
        col = gi % GRID_COLS
        row = gi // GRID_COLS
        gx = col * GLYPH_W_SRC
        gy = row * GLYPH_H
        glyph_pixels = []
        for ly in range(GLYPH_H):
            for lx in range(GLYPH_W_SRC):
                glyph_pixels.append(reduced[(gy + ly) * w + (gx + lx)])
        bin_bytes.extend(encode_glyph(glyph_pixels, idx_of))

    assert len(bin_bytes) == GLYPH_COUNT * GLYPH_BYTES
    bin_path = out_prefix.with_suffix(".bin")
    bin_path.write_bytes(bytes(bin_bytes))
    print(f"  → {bin_path}  ({len(bin_bytes)} bytes, {GLYPH_BYTES} per glyph × {GLYPH_COUNT})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
