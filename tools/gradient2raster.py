"""gradient2raster.py — Sample a gradient PNG column-by-column into a per-scanline
STE palette-word table, suitable for an HBL raster-bar driver.

Usage:
    uv run tools/gradient2raster.py <input.png> <output_prefix>

Produces:
    <output_prefix>.raster — 2 bytes per scanline (big-endian STE palette word).

The tool samples the middle column (x = width // 2) from each row and snaps to
the ST 3-bit RGB grid. Typical input is a 1- or 3-pixel-wide PNG of exact
display height (200 for low-res ST).
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

from PIL import Image

# Reuse encoding + snap helpers from png2planar.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from png2planar import ste_palette_word, snap_channel  # noqa: E402


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    png_path = Path(sys.argv[1])
    out_prefix = Path(sys.argv[2])
    out_prefix.parent.mkdir(parents=True, exist_ok=True)

    img = Image.open(png_path).convert("RGB")
    w, h = img.size
    col = w // 2

    data = bytearray()
    for y in range(h):
        r, g, b = img.getpixel((col, y))
        r, g, b = snap_channel(r), snap_channel(g), snap_channel(b)
        data.extend(struct.pack(">H", ste_palette_word(r, g, b)))

    out_path = out_prefix.with_suffix(".raster")
    out_path.write_bytes(bytes(data))
    print(f"gradient2raster: {png_path.name} — {w}×{h}, column {col}")
    print(f"  → {out_path}  ({len(data)} bytes, {h} scanlines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
