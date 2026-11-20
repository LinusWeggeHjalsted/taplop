#!/usr/bin/env bash
# Regenerate the machine-derived section index in DESIGN.md / DONE.md.
#
# The index lives between the `<!-- doc index: begin -->` and
# `<!-- doc index: end -->` markers (the block carries its own `## Index`
# container heading): one anchor link per heading
# (DESIGN: `##` sections + `###` subsections nested under them; DONE:
# `##` only - its sections ARE the archive units). GitHub-compatible
# anchors, no line numbers - the index cannot go stale, only
# out-of-date until rerun. Headings inside code fences are skipped.
#
# Usage:
#   scripts/doc_index.sh              # regenerate both files
#   scripts/doc_index.sh DESIGN.md    # regenerate one file
#   scripts/doc_index.sh --check      # exit 1 + findings when either
#                                     # index is out of date (no writes)
#
# Why generated: a hand-maintained TOC drifts the moment a section
# lands (the machine-walked-truth rule, AGENTS -> Build & Test); the
# markers make the block re-derivable in one command. The --check mode
# is the drift backstop for the "run it in the SAME commit that adds a
# heading" discipline: regenerating relies on remembering, and the
# gear-upgrading session found the DONE index ~295 lines stale across
# many sessions of exactly that forgetting. scripts/test.sh surfaces
# --check as a non-fatal advisory (same posture as the dash sweep).

set -euo pipefail

begin_marker='<!-- doc index: begin -->'
end_marker='<!-- doc index: end -->'

# GitHub anchor: lowercase, drop everything but alnum/space/hyphen,
# spaces -> hyphens ("Campaigns & the Hub" -> "campaigns--the-hub").
to_anchor() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9 -]//g' \
        | tr ' ' '-'
}

# Emit the index lines for one file: "level<TAB>title" per heading
# (fences skipped), then one markdown link per heading, with GitHub's
# duplicate-anchor numbering (-1, -2, ... for repeated titles). The
# index's own container heading ("Index") is skipped. `levels` selects
# the depth: "2 3" = sections + nested subsections (DESIGN), "2" = flat
# (DONE - its `##` entries ARE the archive units). The generated block
# includes its own `## Index` container heading (between the markers),
# and the scanner skips the marker REGION - the generated block is never
# input to itself, so no name-based special-casing (a body section titled
# "Index" is indexed like any other).
generate_index() {
    local file=$1
    local levels=$2
    awk -v levels="$levels" -v begin="$begin_marker" -v end="$end_marker" '
        function wanted(level) { return index(levels, level) != 0 }
        $0 == begin { in_block = 1; next }
        $0 == end { in_block = 0; next }
        in_block { next }
        /^```/ { in_fence = !in_fence; next }
        in_fence { next }
        /^## / { if (!wanted(2)) next; sub(/^## /, ""); print "2\t" $0; next }
        /^### / { if (!wanted(3)) next; sub(/^### /, ""); print "3\t" $0 }
    ' "$file" | {
        declare -A seen
        while IFS=$'\t' read -r level title; do
            anchor="$(to_anchor "$title")"
            count=$(( ${seen["${anchor}"]:-0} + 1 ))
            seen["${anchor}"]=$count
            suffix=""
            if [ "$count" -gt 1 ]; then
                suffix="-$((count - 1))"
            fi
            if [ "$level" = "2" ]; then
                printf -- '- [%s](#%s%s)\n' "$title" "$anchor" "$suffix"
            else
                printf -- '  - [%s](#%s%s)\n' "$title" "$anchor" "$suffix"
            fi
        done
    }
}

# Produce the file's full content with a freshly generated index block:
# write the regenerated block to `index_tmp` and the spliced whole-file
# content to `out`. The original file is never touched. Shared by
# refresh (splices in place) and --check (splices to a temp, diffs).
splice_fresh_index() {
    local file=$1
    local levels=$2
    local index_tmp=$3
    local out=$4
    grep -qF "$begin_marker" "$file" || { echo "no begin marker in $file" >&2; exit 1; }
    grep -qF "$end_marker" "$file" || { echo "no end marker in $file" >&2; exit 1; }

    {
        echo '## Index'
        echo
        generate_index "$file" "$levels"
    } > "$index_tmp"

    # Splice: keep everything outside the marker block, replace the
    # block's contents with the freshly generated index.
    awk -v begin="$begin_marker" -v end="$end_marker" -v idxfile="$index_tmp" '
        $0 == begin {
            print
            while ((getline line < idxfile) > 0) print line
            close(idxfile)
            in_block = 1
            next
        }
        $0 == end { in_block = 0; print; next }
        !in_block { print }
    ' "$file" > "$out"
}

refresh_file() {
    local file=$1
    local levels=$2
    local index_tmp
    index_tmp="$(mktemp)"
    splice_fresh_index "$file" "$levels" "$index_tmp" "$file.tmp"
    local heading_count
    heading_count="$(wc -l < "$index_tmp")"
    mv "$file.tmp" "$file"
    rm -f "$index_tmp"
    printf 'index refreshed: %s (%s headings)\n' "$file" "$heading_count"
}

# --check: regenerate each index into a TEMP copy and diff against the
# committed file. Prints one line per stale file (the first divergent
# line as a hint); exits 1 when anything is out of date, 0 + CLEAN
# otherwise. Never writes.
check_file() {
    local file=$1
    local levels=$2
    local index_tmp
    index_tmp="$(mktemp)"
    splice_fresh_index "$file" "$levels" "$index_tmp" "$file.check.tmp"
    local stale=0
    if ! cmp -s "$file" "$file.check.tmp"; then
        stale=1
        local first_divergence
        first_divergence="$(diff "$file" "$file.check.tmp" | grep '^[<>]' | head -1)"
        printf 'doc index: STALE %s - run scripts/doc_index.sh\n  first divergence: %s\n' \
            "$file" "$first_divergence"
    fi
    rm -f "$index_tmp" "$file.check.tmp"
    return "$stale"
}

if [ "${1:-}" = "--check" ]; then
    shift
    any_stale=0
    check_file DESIGN.md "2 3" || any_stale=1
    check_file DONE.md "2" || any_stale=1
    if [ "$any_stale" -eq 0 ]; then
        printf 'doc index: CLEAN (both indexes current)\n'
    fi
    exit "$any_stale"
fi

if [ $# -eq 0 ]; then
    refresh_file DESIGN.md "2 3"
    refresh_file DONE.md "2"
else
    # Per-file levels: DONE is FLAT ("2" - its `##` sections are the
    # archive units; indexing its `###` subsections bloats the index and
    # breaks the convention). Anything else gets sections + subsections.
    # (The one-file form once hardcoded "2 3" for everything - passing
    # DONE.md regeneratED its index WRONG, which is exactly what the
    # gear-upgrading session's stale-index cleanup commit did; --check
    # caught it the moment it existed.)
    for file in "$@"; do
        if [ "$file" = "DONE.md" ]; then
            refresh_file "$file" "2"
        else
            refresh_file "$file" "2 3"
        fi
    done
fi
