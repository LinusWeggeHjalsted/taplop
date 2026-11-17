#!/usr/bin/env bash
# TODO drift lint - the machine-walked check behind AGENTS.md →
# Documentation's deletion policy ("task completes → DELETE from TODO";
# TODO lists only work that is not done). The residue patterns a
# completed task leaves when its checkoff missed a deletion site:
#
#   [x]        a checked box - the policy deletes the block, never ticks it
#   COMPLETE   a bullet whose status word says the work is finished
#   "X below"  a pointer whose target phrase appears NOWHERE later in the
#              file - the section it pointed at was deleted by a checkoff
#              and the pointer dangled (the web-storage-model class: the
#              NEXT UP bullet outlived the final slice that deleted its
#              target section)
#
# Advisory posture, same as scripts/dash_sweep.sh --check: exit 1 on
# findings, 0 clean; scripts/test.sh surfaces findings as a non-fatal
# advisory (the commit checkpoint).
#
# Known limits, by design:
# - Stale status PROSE ("build not started" over built work) has no
#   mechanical signal - only reading the pointed-at section catches that
#   class.
# - The "below" check covers the pointer shapes actually used in TODO.md
#   (`"Phrase" below` and `→ phrase below`, each followed by sentence
#   punctuation, so prose like "dips below 60fps" is not a pointer) and
#   requires the phrase to appear on a LATER line - the reference is
#   always forward and single-paragraph in this file.
# - Quoted targets are checked only when the quote sits directly before
#   "below" (a list like `"A" + "B" below` checks just "B") - the arrowed
#   form catches the rest.

set -u
cd "$(dirname "$0")/.."

usage() {
    printf 'usage: scripts/todo_lint.sh\n'
    exit "${1:-0}"
}
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
fi
if [ "$#" -gt 0 ]; then
    usage 1
fi

findings=""

# 1. Checked boxes: the deletion policy is delete-never-tick.
if grep -q '\[x\]' TODO.md; then
    findings+="$(grep -n '\[x\]' TODO.md |
        sed 's/^/[todo lint] checked box - delete the block, never tick it: /')"
    findings+=$'\n'
fi

# 2. COMPLETE status words: a bullet saying the work is complete is a
#    completed task lingering.
if grep -q 'COMPLETE' TODO.md; then
    findings+="$(grep -n 'COMPLETE' TODO.md |
        sed 's/^/[todo lint] COMPLETE-status bullet - completed task lingering: /')"
    findings+=$'\n'
fi

# 3. Dangling "below" pointers. Paragraph mode (RS = "") joins a pointer
#    wrapped across lines; the paragraph's END line number is tracked
#    from its internal newline count so the existence check only looks at
#    LATER lines. Bullet groups in TODO run long without blank lines, so
#    extraction anchors on each "below" occurrence and works BACKWARD:
#    quoted targets from the enclosing quotes, arrowed targets from the
#    NEAREST preceding arrow. A captured phrase that still contains
#    quotes / "below" / sentence punctuation means the anchor crossed a
#    bullet boundary - rejected (over-long captures are exactly the
#    ambiguous ones; a missed check on them is acceptable, this is
#    advisory). Output: one "<end-line> <phrase>" pair per pointer.
pointers="$(awk '
    function arrow_tail(text) {
        # The text after the LAST arrow, or "" if none. split() keeps the
        # separator matching in the same coordinate system as the text
        # (substr arithmetic over the multibyte arrow mixes char and
        # byte positions under some locales).
        n = split(text, parts, "→")
        if (n < 2) return ""
        return parts[n]
    }
    BEGIN { RS = ""; line = 1 }
    {
        newlines = gsub(/\n/, "\n", $0)
        end = line + newlines
        line = end + 2
        para = $0
        gsub(/\n/, " ", para)
        s = para
        while (match(s, /below[.,);:]/)) {
            # Capture BEFORE any nested match - RSTART/RLENGTH are global
            # and last_arrow_after/match below would clobber them.
            below_end = RSTART + RLENGTH
            before = substr(s, 1, RSTART - 1)
            # Quoted target: a closing quote just before "below".
            quote = 0
            if (match(before, /"[^"]*"$/)) {
                quote = RSTART
            }
            t = arrow_tail(before)
            if (quote > 0) {
                t = substr(before, quote)
                gsub(/^"|"$/, "", t)
                gsub(/[ ]+/, " ", t)
                gsub(/^ +| +$/, "", t)
                if (t != "") print end " " t
            } else {
                gsub(/[ ]+/, " ", t)
                gsub(/^ +| +$/, "", t)
                # Crossed-bullet guard: a real section name carries no
                # quotes, no "below", no sentence punctuation.
                if (t != "" && t !~ /[".;:)]/ && t !~ /below/) print end " " t
            }
            s = substr(s, below_end)
        }
    }
' TODO.md)"

while IFS= read -r pointer; do
    [ -z "$pointer" ] && continue
    end_line="${pointer%% *}"
    phrase="${pointer#* }"
    if ! tail -n +"$((end_line + 1))" TODO.md | grep -qiF -- "$phrase"; then
        findings+="[todo lint] dangling \"below\" pointer: \"$phrase\" appears nowhere later in the file (the target section was deleted by a checkoff - delete the pointer too; ends line $end_line)"
        findings+=$'\n'
    fi
done <<< "$pointers"

if [ -n "$findings" ]; then
    printf '%s' "$findings"
    exit 1
fi
printf 'todo lint: CLEAN (no checked boxes, no COMPLETE bullets, no dangling below-pointers)\n'
