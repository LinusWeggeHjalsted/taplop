#!/usr/bin/env bash
# Regenerates art_report.md — the complete inventory of every sprite id the
# game can consume (engine enums + derivations, src string literals, shipped
# data sprite references), with a per-id status: shipped / shadowed
# (persistent-dir override) / MISSING (draws magenta — no fallbacks), plus
# the shipped-but-unconsumed orphans. Built for the artist / asset duty:
# ids are exact drop-in locations for asset shadowing (PNG; checked at every
# launch).
#
# Usage: scripts/art_report.sh            (writes + prints art_report.md)
#        scripts/art_report.sh --open    (writes + opens it in $EDITOR/less)
set -euo pipefail
cd "$(dirname "$0")/.."

zig build art-report

if [[ "${1:-}" == "--open" ]]; then
    "${EDITOR:-less}" art_report.md
else
    cat art_report.md
fi
