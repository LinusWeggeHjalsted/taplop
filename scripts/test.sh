#!/usr/bin/env bash
# Run the test suite and print an unambiguous PASS/FAIL summary.
#
# `zig build test` can emit a "failed command: .../test ..." line on SUCCESS
# (exit 0) whenever a test writes to stderr - here, the advisory game_version
# mismatch warning from the session-log repro test. That line looks like
# failure and sent me fishing for stale binaries in .zig-cache. This script
# is the fix: trust the exit code, surface only real failures + the advisory
# (labeled non-fatal), and cap output so it never exceeds the agent's view.
#
# Usage: scripts/test.sh [--raw]
#   --raw  print the full `zig build test` output verbatim (no filtering).

set -u

raw=0
if [ "${1:-}" = "--raw" ]; then
    raw=1
fi

# A panicking test triggers the custom panic namespace (crash_dump.zig),
# which writes crashes/crash_*.txt into the cwd before trapping. Those
# artifacts pollute the working tree and don't correspond to a real crash
# (just a failing test). Clean them up before running so a prior run's
# leftovers don't linger, and again after so a passing run leaves none.
# Same for saves/: some handler tests exercise real write_save paths through
# cwd-backed FileSources (autosaves are not replay-gated), planting
# saves/autosave*.txt in the project root. The test harness itself reads a
# scratch dir (test_harness.zig), so these are inert artifacts - just tree
# pollution.
rm -rf crashes saves 2>/dev/null || true

# Platform-seam boundary assert (machine-walked truth - see AGENTS →
# Documentation): raylib may be imported ONLY from files under src/raylib/,
# the directory the test-root scan excludes wholesale (build.zig
# collectZigFiles). A stray import anywhere else would leak raylib into the
# headless test build.
violations="$(grep -rn '@import("raylib")' src --include='*.zig' | grep -v '^src/raylib/' || true)"
if [ -n "$violations" ]; then
    printf 'FAIL - raylib imported outside src/raylib/ (platform seam broken):\n%s\n' "$violations"
    exit 1
fi

# Run the build, capturing stdout+stderr together and the exit code separately.
output="$(zig build test 2>&1)"
status=$?

if [ "$raw" -eq 1 ]; then
    printf '%s\n' "$output"
    exit "$status"
fi

# Filtered view: real failures + the advisory warning (labeled), nothing else.
# A real test failure shows as:   error: '<test name>' failed:
# The game_version warning is advisory (exit 0) - label it so it's not mistaken
# for failure.
failures="$(printf '%s\n' "$output" | grep -E "^error: '|FAIL|panic|expected.*found" || true)"
advisory="$(printf '%s\n' "$output" | grep -E "^warning: session log recorded on game_version" || true)"

if [ -n "$advisory" ]; then
    printf '%s\n' "[advisory, non-fatal] $advisory"
fi

# Dash-sweep advisory (non-fatal): banned punctuation in the tree is one
# pre-commit sweep away from clean. Surface it here because this script is
# the canonical pre-commit verification (the commit checkpoint), but never
# FAIL a test run over prose punctuation - a hard gate would make agents
# avoid the characters mid-sentence again (the tax the relaxed rule
# removed; see AGENTS -> Code Style + scripts/dash_sweep.sh).
dash_summary="$("$(dirname "$0")/dash_sweep.sh" --check 2>/dev/null | grep -oE '[0-9]+ occurrence\(s\) across [0-9]+ file\(s\)' || true)"
if [ -n "$dash_summary" ]; then
    printf '[dash sweep, advisory] %s - run scripts/dash_sweep.sh before committing\n' "$dash_summary"
fi

# zig fmt advisory (non-fatal): same posture as the dash sweep - this script
# is the commit checkpoint, so formatting divergence surfaces here, but a
# formatting nit never fails a test run. The fix is one command
# (`zig fmt <file>`); see AGENTS -> Commit policy.
fmt_dirty="$(zig fmt --check $(git ls-files '*.zig') 2>/dev/null || true)"
if [ -n "$fmt_dirty" ]; then
    fmt_count="$(printf '%s\n' "$fmt_dirty" | wc -l)"
    printf '[zig fmt, advisory] %s file(s) not canonically formatted - run zig fmt before committing\n' "$fmt_count"
fi

if [ -n "$failures" ]; then
    printf '%s\n' "--- failures ---"
    printf '%s\n' "$failures"
fi

# The pass count line (e.g. "All 161 tests passed." or "139 pass, 1 fail").
summary="$(printf '%s\n' "$output" | grep -E "All [0-9]+ tests passed|[0-9]+ pass, [0-9]+ fail" | sort -u || true)"
if [ -n "$summary" ]; then
    printf '%s\n' "$summary"
fi

if [ "$status" -eq 0 ]; then
    # A passing run should leave no crash or autosave artifacts.
    rm -rf crashes saves 2>/dev/null || true
    printf 'PASS (exit 0)\n'
else
    printf 'FAIL (exit %d)\n' "$status"
fi

exit "$status"
