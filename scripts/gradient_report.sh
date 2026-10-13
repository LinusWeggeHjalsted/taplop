#!/usr/bin/env bash
# Regenerates gradient_report.md — the perceptual-spacing + seam-contrast
# report over data/color_themes.txt (read through the game's own parser +
# loader): ΔE76 per adjacent ramp step, WCAG contrast on the seams the
# renderer actually places adjacent (tile-vs-background, checkerboard),
# flags for "too close" pairs, and suggested replacement colors for
# violations. Built for the artist: the numbers decide, not memory.
#
# Usage: scripts/gradient_report.sh            (writes + prints gradient_report.md)
#        scripts/gradient_report.sh --open    (writes + opens it in $EDITOR/less)
set -euo pipefail
cd "$(dirname "$0")/.."

zig build gradient-report

if [[ "${1:-}" == "--open" ]]; then
    "${EDITOR:-less}" gradient_report.md
else
    cat gradient_report.md
fi
