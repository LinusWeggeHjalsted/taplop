#!/usr/bin/env bash
# dash_sweep.sh - normalize the banned punctuation to plain equivalents
# across the tracked tree: em-dash (U+2014) and en-dash (U+2013) become
# "-", ellipsis (U+2026) becomes "...". See AGENTS.md -> Code Style (the
# dash rule: agents may write them freely; this script is the normalizer).
#
# Usage:
#   scripts/dash_sweep.sh              sweep every tracked file
#   scripts/dash_sweep.sh <pathspec>   sweep a subset (dry-run discipline:
#                                      pass ONE file, then git diff it)
#   scripts/dash_sweep.sh --check      report only; exit 1 if anything is
#                                      found (the gate - run before commit)
#
# Walker: `git grep -I` over TRACKED files, so binaries (.png/.ogg/.ttt) are
# skipped structurally (-I), untracked dirs (.zig-cache/, zig-out/, zig-pkg/)
# never enter, and LICENSE-*.txt (third-party legal text) is excluded by
# pathspec. The match patterns are BYTE ESCAPES below - this script contains
# none of the banned sequences literally, so it never sweeps itself; a clean
# tree reports CLEAN even with this file in scope (self-verifying).
#
# Replacement is per-file write-after-replace (the sweep-script lesson: a
# later failure must not roll back already-swept files).

set -euo pipefail

mode="apply"
if [[ "${1:-}" == "--check" ]]; then
    mode="check"
    shift
fi

# The banned sequences as bash byte escapes (UTF-8).
EM_DASH=$'\xe2\x80\x94'    # U+2014 -> -
EN_DASH=$'\xe2\x80\x93'    # U+2013 -> -
ELLIPSIS=$'\xe2\x80\xa6'   # U+2026 -> ...

if [[ $# -gt 0 ]]; then
    pathspecs=("$@" ':(exclude)LICENSE-*.txt')
else
    pathspecs=('.' ':(exclude)LICENSE-*.txt')
fi

# git grep exits 1 on "no matches" - that is the CLEAN case, not a failure.
mapfile -t files < <(git grep -l -I -e "$EM_DASH" -e "$EN_DASH" -e "$ELLIPSIS" -- "${pathspecs[@]}" || true)

if [[ ${#files[@]} -eq 0 ]]; then
    echo "dash sweep: CLEAN (no em-dash / en-dash / ellipsis in scope)"
    exit 0
fi

total=0
for file in "${files[@]}"; do
    count=$(grep -o -F -e "$EM_DASH" -e "$EN_DASH" -e "$ELLIPSIS" -- "$file" | wc -l)
    total=$((total + count))
    echo "  $file: $count"
done
echo "dash sweep: $total occurrence(s) across ${#files[@]} file(s)"

if [[ "$mode" == "check" ]]; then
    echo "FAIL (banned punctuation present - run scripts/dash_sweep.sh to normalize)"
    exit 1
fi

# Byte-level replace (perl without a utf8 layer works in raw bytes; the
# sequences never span a line boundary). Written per file, immediately.
for file in "${files[@]}"; do
    perl -i -pe 's/\xe2\x80\x94/-/g; s/\xe2\x80\x93/-/g; s/\xe2\x80\xa6/.../g' -- "$file"
done

echo "dash sweep: applied. Verify with: scripts/dash_sweep.sh --check"
