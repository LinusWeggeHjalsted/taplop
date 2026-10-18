# Ziglop gradient contrast report

Auto-generated from `data/color_themes.txt` through the game's own parser + loader -
regenerate with `scripts/gradient_report.sh` (the sound_report.md
pattern). The numbers decide what is "too close", not memory.

## How the renderer uses the ramp (why some pairs matter)

Every level/hub's world gradient colors the scene at FIXED indices:

- screen background: color 2
- tiles: a checkerboard of color 1 (even tiles) and color 3 (odd tiles)
- decorations default color 0; flag poles color 5; banners color 0

So the seams the renderer actually places adjacent are 1-2 (even
tiles vs background), 1-3 (checkerboard), and 2-3 (odd tiles vs
background). A gradient with a small 1-2 step shows the even tiles
dissolving into the background.

## The rule - what "too close" means

- **Step floor:** any two colors the renderer places adjacent (ramp
  steps 0-1 through 4-5, plus the checkerboard pair 1-3) must be at
  least ΔE 6 apart. ΔE76 is the CIE76 perceptual distance in Lab
  space - hue and lightness both count. Calibrated on the shipped
  wheel: the broken seam sits at ΔE 5.4, seams that read fine start
  at ~6.8.
- **Luminance guard:** the structural seams (1-2, 1-3, 2-3) must keep
  a WCAG contrast ratio of at least 1.06 - catches same-luminance hue
  swaps, which ΔE can score high while flat patches still read as
  one surface.

Not covered here: entity colors vs the tiles they stand on (team
gradients are separate gradients from the level's world gradient -
cross-gradient pairs, a separate calibration).

## Adjacent-step spacing (ΔE76, floor 6)

| gradient | 0-1 | 1-2 | 2-3 | 3-4 | 4-5 | worst |
|---:|---:|---:|---:|---:|---:|---:|
| 0 | 18.2 | 6.6 | 8.0 | 13.8 | 23.8 | 1-2 6.6 |
| 1 | 18.1 | 6.2 | 11.5 | 15.7 | 22.6 | 1-2 6.2 |
| 2 | 16.0 | 6.0 | 11.6 | 12.0 | 24.3 | 1-2 6.0 |
| 3 | 16.4 | 6.6 | 7.9 | 9.7 | 27.6 | 1-2 6.6 |
| 4 | 17.6 | 6.3 | 10.2 | 10.9 | 25.4 | 1-2 6.3 |
| 5 | 13.8 | 7.0 | 9.7 | 8.1 | 24.8 | 1-2 7.0 |
| 6 | 11.5 | 6.5 | 9.1 | 10.3 | 15.3 | 1-2 6.5 |
| 7 | 14.4 | 7.4 | 8.5 | 9.5 | 15.4 | 1-2 7.4 |
| 8 | 17.2 | 8.5 | 7.9 | 8.6 | 17.2 | 2-3 7.9 |
| 9 | 15.9 | 9.6 | 7.3 | 10.4 | 21.2 | 2-3 7.3 |
| 10 | 17.5 | 9.2 | 7.0 | 12.9 | 27.0 | 2-3 7.0 |
| 11 | 16.7 | 9.6 | 7.0 | 13.1 | 27.1 | 2-3 7.0 |
| 12 | 17.2 | 10.9 | 6.9 | 9.0 | 25.6 | 2-3 6.9 |
| 13 | 18.1 | 9.9 | 7.0 | 6.9 | 20.4 | 3-4 6.9 |
| 14 | 19.2 | 10.1 | 6.8 | 8.8 | 18.2 | 2-3 6.8 |
| 15 | 21.5 | 10.6 | 7.3 | 11.4 | 18.4 | 2-3 7.3 |
| 16 | 24.4 | 10.9 | 7.4 | 16.9 | 17.0 | 2-3 7.4 |
| 17 | 24.3 | 10.1 | 8.2 | 17.0 | 16.3 | 2-3 8.2 |
| 18 | 24.1 | 9.6 | 8.3 | 17.1 | 16.7 | 2-3 8.3 |
| 19 | 23.4 | 9.2 | 8.8 | 17.6 | 16.4 | 2-3 8.8 |
| 20 | 23.6 | 8.8 | 9.4 | 16.8 | 17.7 | 1-2 8.8 |
| 21 | 21.5 | 7.3 | 9.1 | 16.1 | 18.6 | 1-2 7.3 |
| 22 | 19.5 | 6.4 | 8.3 | 13.9 | 18.6 | 1-2 6.4 |
| 23 | 19.3 | 6.2 | 11.8 | 16.4 | 20.5 | 1-2 6.2 |

## Structural seams (ΔE76 / WCAG contrast ratio)

| gradient | 1-2 even tiles vs bg | 1-3 checkerboard | 2-3 odd tiles vs bg |
|---:|---:|---:|---:|
| 0 | 6.6 / 1.15 | 12.7 / 1.38 | 8.0 / 1.21 |
| 1 | 6.2 / 1.08 | 12.8 / 1.42 | 11.5 / 1.31 |
| 2 | 6.0 / 1.10 | 12.9 / 1.43 | 11.6 / 1.31 |
| 3 | 6.6 / 1.19 | 12.7 / 1.44 | 7.9 / 1.21 |
| 4 | 6.3 / 1.15 | 13.0 / 1.48 | 10.2 / 1.29 |
| 5 | 7.0 / 1.11 | 12.1 / 1.44 | 9.7 / 1.30 |
| 6 | 6.5 / 1.15 | 14.1 / 1.50 | 9.1 / 1.31 |
| 7 | 7.4 / 1.18 | 14.3 / 1.53 | 8.5 / 1.30 |
| 8 | 8.5 / 1.21 | 14.8 / 1.56 | 7.9 / 1.29 |
| 9 | 9.6 / 1.25 | 15.2 / 1.58 | 7.3 / 1.27 |
| 10 | 9.2 / 1.23 | 14.7 / 1.56 | 7.0 / 1.27 |
| 11 | 9.6 / 1.24 | 15.1 / 1.58 | 7.0 / 1.27 |
| 12 | 10.9 / 1.25 | 15.1 / 1.58 | 6.9 / 1.26 |
| 13 | 9.9 / 1.22 | 14.2 / 1.53 | 7.0 / 1.26 |
| 14 | 10.1 / 1.22 | 14.0 / 1.51 | 6.8 / 1.24 |
| 15 | 10.6 / 1.22 | 14.3 / 1.51 | 7.3 / 1.24 |
| 16 | 10.9 / 1.22 | 14.7 / 1.52 | 7.4 / 1.25 |
| 17 | 10.1 / 1.20 | 13.9 / 1.50 | 8.2 / 1.25 |
| 18 | 9.6 / 1.18 | 14.0 / 1.49 | 8.3 / 1.26 |
| 19 | 9.2 / 1.17 | 14.0 / 1.49 | 8.8 / 1.27 |
| 20 | 8.8 / 1.16 | 10.2 / 1.36 | 9.4 / 1.17 |
| 21 | 7.3 / 1.13 | 13.5 / 1.45 | 9.1 / 1.29 |
| 22 | 6.4 / 1.16 | 13.0 / 1.44 | 8.3 / 1.24 |
| 23 | 6.2 / 1.06 | 13.4 / 1.41 | 11.8 / 1.33 |

## Flags

CLEAN - no gradient below the floors.
