#!/usr/bin/env python3
"""Refit assets/ui/panel.original.png into a flush 9-slice panel.

The original is a 384x384 canvas carrying a 176x176 framed border graphic
centered and inset 104px on every side (border thickness 24px, 9 tiles of
128x128). The graphic does NOT sit flush with the canvas edges.

This script rebuilds a 384x384 panel where the border is flush to all four
edges and the interior is pure white:

  1. Corner pieces (24x24) are moved to the four corners of the canvas.
  2. Edge strips (thickness 24, 128 long) are moved to their canvas edge
     and stretched along their long axis to span corner-to-corner (128 ->
     336, since 384 - 2*24 = 336). Smooth bilinear resize.
  3. The remaining center interior is filled pure white at full alpha.

Crop boxes are derived from each tile's alpha bounding box rather than
hardcoded, so the source layout is discovered rather than assumed.

Writes assets/ui/panel.png (overwriting the placeholder).

Run:  python3 scripts/panel_slice.py
"""

from PIL import Image
import numpy as np

SRC = "assets/ui/panel.original.png"
DST = "assets/ui/panel.png"

TILE = 128
BORDER = 24  # border thickness in source pixels

CANVAS = 384
GAP = CANVAS - 2 * BORDER  # 336: edge span corner-to-corner


def alpha_bounds(region: np.ndarray) -> tuple[int, int, int, int]:
    """Bounding box (left, upper, right, lower) of opaque pixels in region."""
    ys, xs = np.where(region[:, :, 3] > 0)
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def main() -> None:
    src = Image.open(SRC).convert("RGBA")
    arr = np.array(src)

    # Discover each tile's opaque bounding box in image coordinates.
    # Tile (ty, tx) occupies image rows [ty*128, (ty+1)*128) and
    # cols [tx*128, (tx+1)*128). alpha_bounds is tile-local; offset by the
    # tile origin to get image coordinates.
    def tile_bounds(ty: int, tx: int) -> tuple[int, int, int, int]:
        local = arr[ty * TILE : (ty + 1) * TILE, tx * TILE : (tx + 1) * TILE]
        left, upper, right, lower = alpha_bounds(local)
        return tx * TILE + left, ty * TILE + upper, tx * TILE + right, ty * TILE + lower

    corners = {
        "TL": tile_bounds(0, 0),
        "TR": tile_bounds(0, 2),
        "BL": tile_bounds(2, 0),
        "BR": tile_bounds(2, 2),
    }
    edges = {
        "T": tile_bounds(0, 1),
        "B": tile_bounds(2, 1),
        "L": tile_bounds(1, 0),
        "R": tile_bounds(1, 2),
    }
    for name, box in {**corners, **edges}.items():
        w, h = box[2] - box[0], box[3] - box[1]
        print(f"  {name}: image crop {box}  size {w}x{h}")

    out = Image.new("RGBA", (CANVAS, CANVAS), (255, 255, 255, 0))

    # 1. Corners -> canvas corners (no resize; flush by construction).
    out.paste(src.crop(corners["TL"]), (0, 0))
    out.paste(src.crop(corners["TR"]), (CANVAS - BORDER, 0))
    out.paste(src.crop(corners["BL"]), (0, CANVAS - BORDER))
    out.paste(src.crop(corners["BR"]), (CANVAS - BORDER, CANVAS - BORDER))

    # 2. Edges -> canvas edge, stretched along the long axis to GAP (336).
    out.paste(src.crop(edges["T"]).resize((GAP, BORDER), Image.BILINEAR), (BORDER, 0))
    out.paste(src.crop(edges["B"]).resize((GAP, BORDER), Image.BILINEAR), (BORDER, CANVAS - BORDER))
    out.paste(src.crop(edges["L"]).resize((BORDER, GAP), Image.BILINEAR), (0, BORDER))
    out.paste(src.crop(edges["R"]).resize((BORDER, GAP), Image.BILINEAR), (CANVAS - BORDER, BORDER))

    # 3. Fill the interior (everything inside the border) pure white.
    interior = Image.new("RGBA", (GAP, GAP), (255, 255, 255, 255))
    out.paste(interior, (BORDER, BORDER))

    out.save(DST)
    print(f"wrote {DST} ({CANVAS}x{CANVAS})")


if __name__ == "__main__":
    main()
