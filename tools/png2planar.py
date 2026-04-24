"""png2planar.py — PNG to Atari ST/E planar bitmap + palette.

Usage:
    uv run tools/png2planar.py <input.png> <output_prefix>

Produces two files next to <output_prefix>:
    <output_prefix>.pal  — 32 bytes, 16 big-endian STE palette words.
    <output_prefix>.img  — 4-bitplane word-interleaved bitmap.

Palette reduction strategy (in order):
    1. Snap every pixel to the ST 3-bit grid (channel values in {0,32,...,224}).
       The source PNGs are usually already on-grid, so this is often a no-op.
    2. If still >16 unique colors, iteratively merge the least-used color into
       its nearest surviving neighbor (RGB Euclidean distance). This preserves
       the visually dominant colors; only the smallest rendering contributors
       get merged.

The output palette is padded to exactly 16 entries; unused slots are $0000.

Bitmap layout (standard Atari low-res 16-color format):
    For every group of 16 horizontal pixels, emit four 16-bit big-endian words:
      word 0 = bitplane 0 bits of those 16 pixels (MSB = leftmost pixel)
      word 1 = bitplane 1 bits
      word 2 = bitplane 2 bits
      word 3 = bitplane 3 bits
    Then the next 16 pixels. Scanlines go top-to-bottom.
"""
from __future__ import annotations

import struct
import sys
from collections import Counter
from pathlib import Path

from PIL import Image


def ste_palette_word(r: int, g: int, b: int) -> int:
    """Encode an 8-bit RGB triple into the 12-bit STE palette register format.

    STE bit layout (bit 15 is MSB, bit 0 LSB):
      bits 15-12: reserved
      bit 11    : R LSB   (new in STE, ignored on ST)
      bits 10-8 : R bits 3,2,1  (the old 3-bit ST value)
      bit  7    : G LSB
      bits  6-4 : G bits 3,2,1
      bit  3    : B LSB
      bits  2-0 : B bits 3,2,1
    So for an 8-bit PIL channel value we take the top 4 bits, then spread them
    into the scrambled ST/STE layout. Top-3-bit values (ST-compat) put zero in
    the LSB positions and render identically on ST and STE.
    """
    r4, g4, b4 = r >> 4, g >> 4, b >> 4
    w = 0
    w |= ((r4 & 1) << 11) | ((r4 >> 1) << 8)
    w |= ((g4 & 1) << 7)  | ((g4 >> 1) << 4)
    w |= ((b4 & 1) << 3)  | ((b4 >> 1) << 0)
    return w


def snap_channel(c: int) -> int:
    """Round an 8-bit channel to the nearest ST 3-bit level (0,32,...,224)."""
    q = round(c / 32)
    if q > 7:
        q = 7
    return q * 32


def reduce_palette(pixels: list[tuple[int, int, int]], max_colors: int = 16) -> list[tuple[int, int, int]]:
    """Return a list of same length as pixels, with ≤ max_colors unique values.

    Step 1: snap every pixel to the ST grid (lossless if already on-grid).
    Step 2: iteratively collapse the least-used color into the nearest kept
            color until the distinct count is ≤ max_colors.
    """
    snapped = [(snap_channel(r), snap_channel(g), snap_channel(b)) for r, g, b in pixels]
    while True:
        counter = Counter(snapped)
        if len(counter) <= max_colors:
            return snapped
        least_color, least_count = counter.most_common()[-1]
        others = [c for c in counter if c != least_color]
        nearest = min(others, key=lambda c: sum((a - b) ** 2 for a, b in zip(c, least_color)))
        print(f"  merge {least_color} ({least_count}px) → {nearest}", file=sys.stderr)
        snapped = [nearest if c == least_color else c for c in snapped]


def write_palette(palette: list[tuple[int, int, int]], out_pal: Path) -> None:
    assert len(palette) == 16
    data = bytearray()
    for r, g, b in palette:
        data.extend(struct.pack(">H", ste_palette_word(r, g, b)))
    out_pal.write_bytes(bytes(data))


def write_planar(pixels: list[tuple[int, int, int]], w: int, h: int,
                 palette: list[tuple[int, int, int]], out_img: Path) -> None:
    idx_of = {c: i for i, c in enumerate(palette)}
    data = bytearray()
    for y in range(h):
        for x in range(0, w, 16):
            indices = [idx_of[pixels[y * w + x + i]] for i in range(16)]
            for plane in range(4):
                word = 0
                for idx in indices:
                    word = (word << 1) | ((idx >> plane) & 1)
                data.extend(struct.pack(">H", word))
    out_img.write_bytes(bytes(data))


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    png_path = Path(sys.argv[1])
    out_prefix = Path(sys.argv[2])
    out_prefix.parent.mkdir(parents=True, exist_ok=True)

    img = Image.open(png_path).convert("RGB")
    w, h = img.size
    if w % 16 != 0:
        print(f"error: width {w} is not a multiple of 16", file=sys.stderr)
        return 1

    pixels = list(img.getdata())
    print(f"png2planar: {png_path.name} — {w}×{h}")

    reduced = reduce_palette(pixels, max_colors=16)
    palette = list(dict.fromkeys(reduced))
    print(f"  final palette: {len(palette)} colors")
    while len(palette) < 16:
        palette.append((0, 0, 0))

    pal_path = out_prefix.with_suffix(".pal")
    img_path = out_prefix.with_suffix(".img")
    write_palette(palette, pal_path)
    write_planar(reduced, w, h, palette, img_path)

    print(f"  → {pal_path}  ({pal_path.stat().st_size} bytes)")
    print(f"  → {img_path}  ({img_path.stat().st_size} bytes)  [{w}×{h} planar]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
