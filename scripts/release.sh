#!/usr/bin/env bash
# Build a release artifact with a verified-clean version stamp.
#
# game_version is stamped at CONFIGURE time (build.zig computeGameVersion)
# and the 0.17 build system caches configure, so a clean tree can keep
# building with a stale -dirty suffix - git state cannot be a declared
# configure dependency (see the STALENESS note in build.zig). A release
# must not wear that suffix, so this script:
#   1. gates on a fully-clean tree (uncommitted work is exactly what
#      -dirty flags; a release built from it cannot be reproduced from
#      history),
#   2. builds with --cache-poison=poisoned (never cache the
#      configuration -> the stamp is computed from the tree's state RIGHT
#      NOW, not from a cached snapshot),
#   3. machine-verifies the version string inside the artifact that
#      actually ships - a -dirty / -unofficial stamp fails the run.
# Trust the exit code; the final line is RELEASE OK / RELEASE FAIL.
#
# Usage:
#   scripts/release.sh              # native (zig-out/bin/ziglop)
#   scripts/release.sh native
#   scripts/release.sh web          # zig-out/web/ziglop.html
#   scripts/release.sh mac          # zig-out/bin/ziglop + ziglop.app/
#   scripts/release.sh all           # web, native, mac (mac LAST - see note)
#
# NOTE (mac): the mac cross-build installs to the SAME zig-out/bin/ziglop
# path as native, replacing the linux binary - which is why `all` builds
# mac last, after the native artifact has been verified. MAC COMPILES !=
# MAC RUNS: the stamp check is a build check, not a runtime one (TODO ->
# macOS native port for the runtime checklist).
#
# Extra args are forwarded to the build (the scripts/web.sh pattern), so
# `scripts/release.sh native --release=fast` produces an optimized
# artifact. No optimize flag means a debug build - the script prints a
# reminder rather than silently shipping one.

set -u

usage() {
    sed -n '2,/^set -u/p' "$0" | sed '/^set -u/d; s/^# \{0,1\}//'
}

target="${1:-native}"
if [ "$target" = "native" ] || [ "$target" = "web" ] || [ "$target" = "mac" ] || [ "$target" = "all" ]; then
    shift || true
else
    printf 'unknown target: %s\n\n' "$target" >&2
    usage >&2
    exit 2
fi

forwarded=("$@")
optimize_given=0
for arg in "${forwarded[@]+"${forwarded[@]}"}"; do
    case "$arg" in
        --release=*|-Doptimize=*) optimize_given=1 ;;
    esac
done
if [ "$optimize_given" -eq 0 ]; then
    printf 'note: no optimize flag given - artifact is a debug build (pass --release=fast for an optimized release)\n\n'
fi

# Gate: a release stamps a commit, so the tree must be fully clean.
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    printf 'RELEASE FAIL: working tree is not clean - commit (or stash) first:\n\n'
    git status --porcelain
    exit 1
fi

# --cache-poison=poisoned: never cache the configuration, so
# computeGameVersion sees the tree's state at this build, not a stale
# snapshot. (The flag must reach the actual build; for web it is forwarded
# through scripts/web.sh, which passes unknown args to zig build.)
build_one() {
    local name="$1"
    shift
    printf '== building %s...\n' "$name"
    local output status
    if [ "$name" = "web" ]; then
        # Through scripts/web.sh (emsdk-noise filtering); it forwards its
        # unknown args to `zig build web`, so the poisoned flag rides along.
        output="$(scripts/web.sh --cache-poison=poisoned "$@" 2>&1)"
    else
        output="$(zig build --cache-poison=poisoned "$@" 2>&1)"
    fi
    status=$?
    if [ "$status" -ne 0 ]; then
        printf '%s\n' "$output"
        printf 'BUILD FAIL (%s, exit %d)\n' "$name" "$status"
        exit "$status"
    fi
    printf '%s\n' "$output"
}

# Assert the artifact's embedded version stamp is clean (machine-walked:
# read the string out of the shipped file, never out of a cache).
verify_stamp() {
    local name="$1"
    local artifact="$2"
    if [ ! -f "$artifact" ]; then
        printf 'RELEASE FAIL (%s): artifact not found: %s\n' "$name" "$artifact"
        exit 1
    fi
    local matches
    matches="$(strings "$artifact" | grep -oE 'v20[0-9]{2}\.[0-9]{2}\.[0-9]+(-dirty|-unofficial)?' | sort -u)"
    if printf '%s' "$matches" | grep -qE -- '-dirty|-unofficial'; then
        printf 'RELEASE FAIL (%s): version stamp in %s carries a suffix:\n%s\n' "$name" "$artifact" "$matches"
        exit 1
    fi
    local clean
    clean="$(printf '%s\n' "$matches" | grep -vE -- '-dirty|-unofficial' | head -1)"
    if [ -z "$clean" ]; then
        printf 'RELEASE FAIL (%s): no version stamp found in %s\n' "$name" "$artifact"
        exit 1
    fi
    printf 'stamp OK: %s  (%s)\n' "$clean" "$artifact"
}

build_and_verify() {
    local name="$1"
    shift
    build_one "$name" "$@"
    case "$name" in
        native) verify_stamp native zig-out/bin/ziglop ;;
        mac)    verify_stamp mac zig-out/bin/ziglop
                if [ -d zig-out/ziglop.app ]; then
                    printf 'bundle:    zig-out/ziglop.app/\n'
                fi ;;
        web)    verify_stamp web zig-out/web/ziglop.wasm
                printf 'page:      zig-out/web/ziglop.html\n' ;;
    esac
}

case "$target" in
    native) build_and_verify native "${forwarded[@]+"${forwarded[@]}"}" ;;
    web)    build_and_verify web "${forwarded[@]+"${forwarded[@]}"}" ;;
    mac)    build_and_verify mac -Dtarget=aarch64-macos "${forwarded[@]+"${forwarded[@]}"}" ;;
    all)
        # Mac last: it replaces zig-out/bin/ziglop (see header note).
        build_and_verify web "${forwarded[@]+"${forwarded[@]}"}"
        build_and_verify native "${forwarded[@]+"${forwarded[@]}"}"
        build_and_verify mac -Dtarget=aarch64-macos "${forwarded[@]+"${forwarded[@]}"}"
        ;;
esac

printf '\nRELEASE OK\n'
