#!/usr/bin/env python3
"""Convert the old Unity TileHighlight.png into a tiled animation strip.

Source: ~/Development/taplop/Assets/Resources/TileHighlight.png — a 64x16
palette image, 4 frames of 16x16 (white pixels on transparent), a
marching-ants dashed border that rotates each frame.

Output: assets/world/tile_highlight.png — a 1024x256 RGBA horizontal strip of
4 frames, each 256x256. Each 16x16 frame is nearest-neighbor upscaled x16 so
the hard pixel edges are preserved; baking the upscale into the PNG means the
existing bilinear texture filter keeps the edges crisp (consistent with the
other baked assets).

Run:  python3 scripts/tile_highlight_slice.py
"""

from PIL import Image

SRC = "/home/strider/Development/taplop/Assets/Resources/TileHighlight.png"
DST = "assets/world/tile_highlight.png"

FRAME = 16      # source frame side (px)
SCALE = 16      # 16 -> 256 (matches tile_size_pixels)
OUT_FRAME = FRAME * SCALE  # 256
FRAME_COUNT = 4


def main() -> None:
    src = Image.open(SRC).convert("RGBA")
    assert src.size == (FRAME * FRAME_COUNT, FRAME), f"unexpected source size {src.size}"

    strip = Image.new("RGBA", (OUT_FRAME * FRAME_COUNT, OUT_FRAME), (0, 0, 0, 0))
    for index in range(FRAME_COUNT):
        frame = src.crop((index * FRAME, 0, (index + 1) * FRAME, FRAME))
        upscaled = frame.resize((OUT_FRAME, OUT_FRAME), Image.NEAREST)
        strip.paste(upscaled, (index * OUT_FRAME, 0))

    strip.save(DST)
    print(f"wrote {DST} ({strip.size[0]}x{strip.size[1]})")


if __name__ == "__main__":
    main()
