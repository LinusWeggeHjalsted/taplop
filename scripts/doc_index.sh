#!/usr/bin/env bash
# Regenerate the machine-derived section index in DESIGN.md / DONE.md.
#
# The index lives between the `<!-- doc index: begin -->` and
# `<!-- doc index: end -->` markers: one anchor link per heading
# (DESIGN: `##` sections + `###` subsections nested under them; DONE:
# `##` only - its sections ARE the archive units). GitHub-compatible
# anchors, no line numbers - the index cannot go stale, only
# out-of-date until rerun. Headings inside code fences are skipped.
#
# Run after adding/renaming/removing a section:
#   scripts/doc_index.sh              # both DESIGN.md and DONE.md
#   scripts/doc_index.sh DESIGN.md    # one file
#
# Why generated: a hand-maintained TOC drifts the moment a section
# lands (the machine-walked-truth rule, AGENTS -> Build & Test); the
# markers make the block re-derivable in one command.

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
# (DONE - its `##` entries ARE the archive units).
generate_index() {
    local file=$1
    local levels=$2
    awk -v levels="$levels" '
        function wanted(level) { return index(levels, level) != 0 }
        /^```/ { in_fence = !in_fence; next }
        in_fence { next }
        /^## Index$/ { next }
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

refresh_file() {
    local file=$1
    local levels=$2
    grep -qF "$begin_marker" "$file" || { echo "no begin marker in $file" >&2; exit 1; }
    grep -qF "$end_marker" "$file" || { echo "no end marker in $file" >&2; exit 1; }

    local index_tmp
    index_tmp="$(mktemp)"
    generate_index "$file" "$levels" > "$index_tmp"

    # Splice: keep everything outside the marker block, replace the
    # block's contents with the freshly generated index.
    local heading_count
    heading_count="$(wc -l < "$index_tmp")"
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
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    rm -f "$index_tmp"
    printf 'index refreshed: %s (%s headings)\n' "$file" "$heading_count"
}

if [ $# -eq 0 ]; then
    refresh_file DESIGN.md "2 3"
    refresh_file DONE.md "2"
else
    for file in "$@"; do
        refresh_file "$file" "2 3"
    done
fi
