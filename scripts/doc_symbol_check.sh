#!/usr/bin/env bash
# Doc-symbol staleness checker (machine-walked truth for doc prose - see
# AGENTS → Documentation). DESIGN/AGENTS/TODO name code symbols in
# backticks (`main.dumpEventLog`, `types.producible_key_ids`) and drift
# silently when symbols move or are renamed - every stale ref found so far
# was found by accident during unrelated sessions. This script extracts
# every backticked dot-path from the three living docs and flags the ones
# the source tree can't back:
#
#   STALE   the member name (last segment) appears in NO .zig file under
#           src/ (raylib seam included) + tools/ + build.zig - the symbol
#           the doc names does not exist anywhere.
#   MOVED   the member exists, but the first segment is a file stem
#           (types., state., parser., ...) whose file does not contain
#           the member - the doc points at the wrong file (the recorded
#           drift class: symbols moving between files).
#
# Both tiers are advisory - read the flagged line and fix the doc (or
# discover the rename was wrong). Known limits, by design:
# - DONE.md is NOT scanned: it records history, where dead symbols are
#   legitimate.
# - Only the MEMBER name is hard-checked; a generic member name (run,
#   frame) passing via an unrelated same-named token is a false pass.
# - Doc comments inside .zig files are stripped before tokenizing, so a
#   symbol that exists only in a (possibly stale) code comment still
#   flags - code is the truth, comments can drift too.
# - Deliberate non-symbols are allowlisted below: external APIs (zig
#   stdlib, raylib_zig, OS interfaces) and meta-placeholders (`ui.X`).
# - TODO prose naming a NOT-YET-LANDED symbol must use the bare name
#   (`inspect_cursor`), not the backticked dot-path form - a dot-path is
#   the checker's signal that the symbol exists today.
#
# Usage: scripts/doc_symbol_check.sh [--strict]
#   --strict  exit 1 on any finding (CI-if-ever); default exits 0.
set -euo pipefail
cd "$(dirname "$0")/.."

docs=(AGENTS.md DESIGN.md TODO.md)

# Deliberate non-symbols: external APIs (zig stdlib / raylib_zig / OS)
# and the ui.X facade meta-placeholder.
allowlist="W.STOPSIG std.debug.simple_panic LazyPath.getPath ui.X"

# File-extension-like segments: `foo.zig`, `sound_report.sh` are file
# references, not symbol paths.
extensions="zig txt sh md zon png ogg wav html js cs py tbd icns app zip so dylib ht"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# -- corpus: every .zig the docs could name symbols in. The generated
# files (src/generated_*.zig, generated_sprite_metadata.zig) are gitignored
# and only exist after a build; note their absence so a fresh-clone run
# can't silently false-flag. --
corpus=()
while IFS= read -r file; do corpus+=("$file"); done < <(
    find src tools -name '*.zig'
    [[ -f build.zig ]] && echo build.zig
    [[ -f generated_sprite_metadata.zig ]] && echo generated_sprite_metadata.zig
)
generated_present=1
for file in src/generated_lookups.zig src/generated_test_root.zig generated_sprite_metadata.zig; do
    [[ -f "$file" ]] || generated_present=0
done

for file in "${corpus[@]}"; do
    stem="${file##*/}"; stem="${stem%.zig}"
    # Strip comments, keep identifiers (string literals stay: a symbol
    # named in a panic/compileError string is a deliberate reference).
    sed 's|//.*$||' "$file" \
        | grep -oE '[A-Za-z_][A-Za-z0-9_]*' \
        | sort -u >> "$tmp/all.tok"
    # Per-stem tokens for the MOVED tier. Colliding stems (src/state.zig
    # vs src/ui/state.zig) merge - acceptable for an advisory tier.
    sed 's|//.*$||' "$file" \
        | grep -oE '[A-Za-z_][A-Za-z0-9_]*' \
        | sort -u >> "$tmp/stem_$stem.tok"
done
sort -u "$tmp/all.tok" -o "$tmp/all.tok"

# -- extraction: backticked dot-paths from the living docs. A trailing
# call form (`session.queueSound(allocator, .id)`) keeps its path. --
is_extension_segment() {
    local segment
    for segment in $extensions; do
        [[ "$1" == "$segment" ]] && return 0
    done
    return 1
}

declare -a stale_paths=() moved_paths=() ok_count_paths=()
stale=0; moved=0; ok=0

for doc in "${docs[@]}"; do
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        [[ "$allowlist" == *"$path"* ]] && continue

        # Split into segments; skip file references.
        IFS='.' read -r -a segments <<< "$path"
        skip=0
        for segment in "${segments[@]}"; do
            is_extension_segment "$segment" && skip=1 && break
        done
        [[ $skip -eq 1 ]] && continue

        member="${segments[${#segments[@]}-1]}"
        first="${segments[0]}"

        if ! grep -qxF "$member" "$tmp/all.tok"; then
            stale_paths+=("$doc: \`$path\` - no .zig file contains '$member'")
            stale=$((stale + 1))
        elif [[ -f "$tmp/stem_$first.tok" ]] && ! grep -qxF "$member" "$tmp/stem_$first.tok"; then
            moved_paths+=("$doc: \`$path\` - '$member' exists but not in $first.zig")
            moved=$((moved + 1))
        else
            ok=$((ok + 1))
        fi
    done < <(
        grep -oP '(?<=`)[^`]+(?=`)' "$doc" \
            | sed 's/(.*$//' \
            | grep -E '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$' \
            | sort -u
    )
done

echo "Doc-symbol staleness check - ${#docs[@]} docs, $((stale + moved + ok)) symbol paths"
[[ $generated_present -eq 1 ]] || echo "  note: generated .zig files absent (build first) - std/generated refs may false-flag"
echo
if (( ${#stale_paths[@]} )); then
    echo "STALE (symbol does not exist anywhere in src/): $stale"
    printf '  %s\n' "${stale_paths[@]}"
    echo
fi
if (( ${#moved_paths[@]} )); then
    echo "MOVED (symbol exists, but not in the file the doc names): $moved"
    printf '  %s\n' "${moved_paths[@]}"
    echo
fi
if (( stale == 0 && moved == 0 )); then
    echo "CLEAN - every doc-named symbol path resolves against the source tree."
fi

if [[ "${1:-}" == "--strict" ]] && (( stale + moved > 0 )); then
    exit 1
fi
