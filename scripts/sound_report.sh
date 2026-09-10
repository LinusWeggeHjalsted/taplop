#!/usr/bin/env bash
# Regenerates sound_report.md — the complete inventory of every wired sound
# path (skill/button/item bases + layers, one-shots, music stems), with a
# per-asset status: shipped / shadowed (persistent-dir override) / MISSING
# (plays silence — no fallbacks, so the status column is the whole truth).
# Built for the sound designer: paths are exact drop-in locations for asset
# shadowing (.wav or .ogg; layers hot-load without relaunching).
#
# Usage: scripts/sound_report.sh            (writes + prints sound_report.md)
#        scripts/sound_report.sh --open    (writes + opens it in $EDITOR/less)
set -euo pipefail
cd "$(dirname "$0")/.."

zig build sound-report

if [[ "${1:-}" == "--open" ]]; then
    "${EDITOR:-less}" sound_report.md
else
    cat sound_report.md
fi
