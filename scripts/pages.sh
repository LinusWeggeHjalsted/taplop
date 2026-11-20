#!/usr/bin/env bash
# Deploy the release web build to the gh-pages branch (the GitHub Pages
# serving source - the serving-source decision in TODO -> Rename to
# taplop + migrate to GitHub, step 5).
#
# The web artifact is ~16 MB of binaries (all game assets embedded - the
# single-file model). It lives on a disposable orphan branch so master's
# history stays pure source - the same machine-generated-artifacts-
# untracked policy that keeps zig-out/ and the reports out of the tree.
# The branch is ONE commit, rewritten per deploy (force push): the shipped
# artifact has no history value, the source that built it is in master.
#
# taplop.html is renamed index.html on the branch: Pages serves
# index.html for the bare /taplop/ directory URL. The html's asset refs
# are relative, so the rename is safe (verified - see TODO step 5).
#
# Steps: clean-tree gate (a -dirty stamp must never reach the public
# page - the release.sh rationale), release web build with
# --cache-poison=poisoned (fresh version stamp), stamp verification on
# the shipped wasm, orphan-branch assemble in a temp worktree, force
# push.
#
# Usage:
#   scripts/pages.sh             # deploy to origin
#   scripts/pages.sh <remote>    # deploy to a remote name or URL

set -u

remote="${1:-origin}"

# Gate: the page is built from a commit, so the tree must be fully clean
# (same rationale as release.sh - an uncommitted -dirty artifact cannot
# be reproduced from history).
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    printf 'PAGES FAIL: working tree is not clean - commit (or stash) first:\n\n'
    git status --porcelain
    exit 1
fi

# Release web build. --cache-poison=poisoned re-runs configure so the
# embedded game_version stamp reflects the tree's state at THIS build,
# not a cached snapshot (the release.sh staleness note); the emsdk-fetch
# chatter it re-triggers is the price.
printf '== building the release web artifact...\n'
output="$(scripts/web.sh --release=fast --cache-poison=poisoned 2>&1)"
status=$?
if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output"
    printf 'BUILD FAIL (web, exit %d)\n' "$status"
    exit "$status"
fi
printf '%s\n' "$output"

# Assert the wasm's embedded version stamp is clean (machine-walked out
# of the shipped file, never out of a cache - the release.sh verify_stamp
# pattern).
artifact="zig-out/web/taplop.wasm"
if [ ! -f "$artifact" ]; then
    printf 'PAGES FAIL: artifact not found: %s\n' "$artifact"
    exit 1
fi
matches="$(strings "$artifact" | grep -oE 'v20[0-9]{2}\.[0-9]{2}\.[0-9]+(-dirty|-unofficial)?' | sort -u)"
if printf '%s' "$matches" | grep -qE -- '-dirty|-unofficial'; then
    printf 'PAGES FAIL: version stamp in %s carries a suffix:\n%s\n' "$artifact" "$matches"
    exit 1
fi
version="$(printf '%s\n' "$matches" | grep -vE -- '-dirty|-unofficial' | head -1)"
if [ -z "$version" ]; then
    printf 'PAGES FAIL: no version stamp found in %s\n' "$artifact"
    exit 1
fi
printf 'stamp OK: %s\n' "$version"

# Assemble the branch in a throwaway worktree - master's checkout is
# never touched. First deploy creates the orphan branch; later deploys
# clear the worktree and AMEND the single commit (the branch stays one
# commit forever).
worktree="$(mktemp -d)"
cleanup() { git worktree remove --force "$worktree" 2>/dev/null || rm -rf "$worktree"; }
trap cleanup EXIT
amend=0
if git show-ref --verify --quiet refs/heads/gh-pages; then
    git worktree add --force --quiet "$worktree" gh-pages || {
        printf 'PAGES FAIL: could not check out the gh-pages worktree\n'
        exit 1
    }
    rm -rf "$worktree"/*
    amend=1
else
    git worktree add --quiet --orphan -b gh-pages "$worktree" || {
        printf 'PAGES FAIL: could not create the gh-pages orphan worktree\n'
        exit 1
    }
fi
cp zig-out/web/taplop.html "$worktree/index.html"
cp zig-out/web/taplop.js "$worktree/"
cp zig-out/web/taplop.wasm "$worktree/"
git -C "$worktree" add -A
if [ "$amend" -eq 1 ]; then
    git -C "$worktree" commit --amend -m "pages: deploy $version"
else
    git -C "$worktree" commit -m "pages: deploy $version"
fi

printf '== pushing gh-pages to %s (force: the branch is one disposable commit)...\n' "$remote"
if ! git push --force "$remote" gh-pages; then
    printf 'PAGES FAIL: push to %s rejected\n' "$remote"
    exit 1
fi
printf 'PAGES OK (%s -> %s)\n' "$version" "$remote"
