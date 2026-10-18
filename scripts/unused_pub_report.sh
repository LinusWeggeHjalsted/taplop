#!/usr/bin/env bash
# Unused-pub report - machine-walked truth for the minimize-pub discipline
# (AGENTS → Code Style). The compiler errors on unused file-private symbols,
# but NOTHING flags an unused `pub` - dead pub scaffolding survives
# redesigns (`walkingDistance`, the `ui.tile_highlight_frame_size` re-export).
# This script walks every `pub fn/const/var` declaration under src/ - the
# src/raylib/ seam excluded (its surface is a backend interface, not the
# game's API discipline) - and reports, per declaring file:
#
#   DEAD       not referenced from ANY file, not even their own (the
#              declaration line is the symbol's only occurrence): deletion
#              candidates - the walkingDistance class.
#   UNUSED     zero references outside their own file but used internally:
#              de-pub candidates (file-private preserves the compiler's
#              dead-code check).
#   TEST-ONLY  referenced only from test files (name contains "test"):
#              a candidate for file-private + a why-note, per AGENTS →
#              Code Style (same-file test blocks see file-private symbols,
#              so cross-file test refs are the only real pub-for-test case).
#
# The walk covers `pub fn`, `pub var`, and TYPED value consts
# (`pub const name: u32 = ...`). Plain `pub const name = ...` decls
# (types, aliases) are deliberately NOT walked: types are consumed
# without ever being named cross-file (as field types, via enum literals,
# through namespace re-exports), so a never-named type is not a dead type
# and word-matching cannot judge it - the dead-type class is code review's
# job. `src/crash_dump.zig`'s struct-member pub fns are skipped too: they
# are zig's panic-namespace contract, installed wholesale as
# `pub const panic = crash_dump.panic` and called by compiler-generated
# code that never names them.
#
# The ui.zig facade is NOT a consumer: a src/ui/*.zig symbol's re-export
# line in ui.zig is plumbing, not a use - and a facade decl counts as used
# only when a file OUTSIDE src/ui/ names the symbol (src/ui files import
# each other directly, never through the facade).
#
# Known blind spots (advisory tool, not a gate):
# - word-match: generic names (skill, effect, damage) false-pass - the name
#   appearing as an enum variant / field / method anywhere counts as a use.
# - references inside string literals count; comment references do not
#   (comments are stripped before tokenizing - a symbol only a comment
#   names is reported, because comments can be stale too).
#
# `pub fn main` is skipped outright: zig's entry-point convention - called
# by startup code, never referenced by imports.
#
# Usage: scripts/unused_pub_report.sh [--strict]
#   --strict  exit 1 on any UNUSED finding (pre-commit gate / CI-if-ever);
#             default exits 0.
set -euo pipefail
cd "$(dirname "$0")/.."

# Known-legit zero-ref pub symbols, "file<TAB>symbol" - none today; the
# natural entries are externally-called entry points (emscripten callbacks).
allowlist=""

# Files whose struct-MEMBER pub fns are consumed as a namespace by external
# machinery (zig's panic-handler contract) rather than by name.
namespace_files="src/crash_dump.zig"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# -- corpus: every .zig in the tree as a REFERENCE source (the raylib seam
# included - src/raylib/draw.zig consumes ui symbols; native/web entry
# files consume the game API). Generated files are gitignored and only
# exist after a build; note their absence so a fresh-clone run can't
# silently false-flag. --
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

: > "$tmp/refs.tsv"
: > "$tmp/manifest.tsv"
: > "$tmp/decls.tsv"
: > "$tmp/counts.tsv"

for file_index in "${!corpus[@]}"; do
    file="${corpus[$file_index]}"
    printf '%s\t%s\n' "$file_index" "$file" >> "$tmp/manifest.tsv"
    # Strip comments, keep identifiers (string literals stay: a symbol
    # named in a panic/compileError string is a deliberate reference).
    sed 's|//.*$||' "$file" \
        | grep -oE '[A-Za-z_][A-Za-z0-9_]*' \
        | sort | uniq -c \
        | awk -v file_index="$file_index" '{ print $2 "\t" $1 "\t" file_index }' >> "$tmp/counts.tsv"
    sed 's|//.*$||' "$file" \
        | grep -oE '[A-Za-z_][A-Za-z0-9_]*' \
        | sort -u \
        | awk -v file_index="$file_index" '{ print $0 "\t" file_index }' >> "$tmp/refs.tsv"

    # Definitions: everything under src/ except the raylib seam, the
    # generated files (machine-written, not discipline targets), and the
    # zig entry-point convention. Struct-MEMBER pub fns are skipped in the
    # panic-namespace files (see header).
    case "$file" in
        src/raylib/*|src/generated_*|src/native.zig|src/web.zig) continue ;;
    esac
    while IFS= read -r symbol; do
        [[ -z "$symbol" || "$symbol" == "main" ]] && continue
        [[ "$allowlist" == *"$file	$symbol"* ]] && continue
        printf '%s\t%s\n' "$symbol" "$file_index" >> "$tmp/decls.tsv"
    done < <(
        if [[ "$namespace_files" == *"$file"* ]]; then
            # file-level decls only (member fns are the compiler contract)
            rg -N --no-filename '^pub (fn|var) +([A-Za-z_][A-Za-z0-9_]*)' \
                -or '$2' "$file" || true
        else
            rg -N --no-filename '^[[:space:]]*pub (fn|var) +([A-Za-z_][A-Za-z0-9_]*)' \
                -or '$2' "$file" || true
        fi
        # typed value consts (`pub const name: T = ...`); `=`-form consts
        # (types/aliases) are deliberately not walked - see header
        rg -N --no-filename '^[[:space:]]*pub const +([A-Za-z_][A-Za-z0-9_]*):' \
            -or '$1' "$file" || true
    )
done

LC_ALL=C sort -t$'\t' -k1,1 "$tmp/decls.tsv" -o "$tmp/decls.sorted"
LC_ALL=C sort -t$'\t' -k1,1 "$tmp/refs.tsv" -o "$tmp/refs.sorted"

# join -a1 keeps decls with zero refs (the UNUSED tier's purest case).
LC_ALL=C join -t$'\t' -a 1 "$tmp/decls.sorted" "$tmp/refs.sorted" \
    | awk -F'\t' -v manifest="$tmp/manifest.tsv" -v counts="$tmp/counts.tsv" '
        BEGIN {
            while ((getline line < manifest) > 0) {
                split(line, parts, "\t");
                path[parts[1]] = parts[2];
            }
            # per-file token occurrence counts: a symbol whose defining-file
            # count is 1 occurs ONLY on its declaration line - DEAD.
            while ((getline line < counts) > 0) {
                split(line, parts, "\t");
                occurrences[parts[1] SUBSEP parts[3]] = parts[2];
            }
        }
        {
            symbol = $1; definition = $2;
            key = symbol SUBSEP definition;
            seen[key] = 1;
            if (NF < 3) next;  # no refs anywhere
            reference = $3;
            if (reference == definition) next;
            reference_path = path[reference];
            definition_path = path[definition];
            # facade plumbing, not uses (see header)
            if (definition_path ~ /^src\/ui\// && reference_path == "src/ui.zig") next;
            if (definition_path == "src/ui.zig" && reference_path ~ /^src\/ui\//) next;
            references[key] = references[key] " " reference_path;
            if (reference_path !~ /test/) real_use[key] = 1;
        }
        END {
            for (key in seen) {
                split(key, parts, SUBSEP);
                symbol = parts[1]; definition = parts[2];
                definition_path = path[definition];
                if (!real_use[key]) {
                    if (references[key] == "") {
                        if (occurrences[key] <= 1)
                            print definition_path "\t" symbol "\tDEAD";
                        else
                            print definition_path "\t" symbol "\tUNUSED";
                    } else {
                        print definition_path "\t" symbol "\tTEST-ONLY";
                    }
                }
            }
        }
    ' > "$tmp/findings.tsv"

dead_count=$(awk -F'\t' '$3 == "DEAD"' "$tmp/findings.tsv" | wc -l)
unused_count=$(awk -F'\t' '$3 == "UNUSED"' "$tmp/findings.tsv" | wc -l)
testonly_count=$(awk -F'\t' '$3 == "TEST-ONLY"' "$tmp/findings.tsv" | wc -l)
total_decls=$(wc -l < "$tmp/decls.tsv")

echo "Unused-pub report - $total_decls pub declarations walked (src/ minus the raylib seam)"
[[ $generated_present -eq 1 ]] || echo "  note: generated .zig files absent (build first) - a reference living only in them may false-flag"
echo
if (( dead_count > 0 )); then
    echo "DEAD (not referenced anywhere, not even their own file): $dead_count"
    awk -F'\t' '$3 == "DEAD" { printf "  %s: %s\n", $1, $2 }' "$tmp/findings.tsv" | sort
    echo
fi
if (( unused_count > 0 )); then
    echo "UNUSED (used only inside their own file): $unused_count"
    awk -F'\t' '$3 == "UNUSED" { printf "  %s: %s\n", $1, $2 }' "$tmp/findings.tsv" | sort
    echo
fi
if (( testonly_count > 0 )); then
    echo "TEST-ONLY (referenced only from test files): $testonly_count"
    awk -F'\t' '$3 == "TEST-ONLY" { printf "  %s: %s\n", $1, $2 }' "$tmp/findings.tsv" | sort
    echo
fi
if (( dead_count == 0 && unused_count == 0 && testonly_count == 0 )); then
    echo "CLEAN - every pub symbol is referenced from at least one non-test file."
fi

if [[ "${1:-}" == "--strict" ]] && (( dead_count + unused_count > 0 )); then
    exit 1
fi
