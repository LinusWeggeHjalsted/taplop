#!/usr/bin/env bash
# Regenerates tooltip_report.md - the complete inventory of every tooltip
# the game can show, for wording review in one place. Two parts: the real
# builders walked over their enums with example values (every skill,
# effect, item shape, material kind - new content appears automatically),
# then every literal `.tooltip = ` emission site under src/ (format
# placeholders stay; runtime-built sites list their expression so nothing
# is invisible).
#
# Usage: scripts/tooltip_report.sh            (writes + prints tooltip_report.md)
#        scripts/tooltip_report.sh --open    (writes + opens it in $EDITOR/less)
set -euo pipefail
cd "$(dirname "$0")/.."

zig build tooltip-report

if [[ "${1:-}" == "--open" ]]; then
    "${EDITOR:-less}" tooltip_report.md
else
    cat tooltip_report.md
fi
