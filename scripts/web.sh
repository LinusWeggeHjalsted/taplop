#!/usr/bin/env bash
# Build (and optionally serve) the web client with clean output.
#
# `zig build web` runs `emsdk install` + `emsdk activate` as build steps every
# invocation. Those print a wall of "Resolving SDK version / Setting tools
# active / Next steps / consider adding to PATH / source emsdk_env.sh" text
# that buries whether the build actually succeeded. This script filters the
# emsdk noise and surfaces only the build summary + real errors, then prints a
# final WEB OK / WEB FAIL line (trust the exit code).
#
# The web build needs a one-line-patched stdlib (Zig 0.16.0's std/os/emscripten.zig
# STOPSIG bug — see AGENTS → Build & Test). The patched copy lives at
# ~/.local/zig-patched-lib; native + tests use the normal zig (no env var).
#
# Usage:
#   scripts/web.sh            # zig build web  -> zig-out/web/ziglop.html
#   scripts/web.sh --raw      # full verbatim output (no filtering)
#   scripts/web.sh emrun      # zig build emrun (serve + open in a browser)
#   scripts/web.sh emrun --raw

set -u

raw=0
target="web"
for arg in "$@"; do
  case "$arg" in
    --raw) raw=1 ;;
    emrun) target="emrun" ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# Suppress emsdk_env.sh noise if anything in the build sources it.
export EMSDK_QUIET=1

output="$(ZIG_LIB_DIR="${ZIG_LIB_DIR:-$HOME/.local/zig-patched-lib}" zig build "$target" 2>&1)"
status=$?

if [ "$raw" -eq 1 ]; then
  printf '%s\n' "$output"
  exit "$status"
fi

# Filtered view: drop the emsdk install/activate chatter + env-setup lines,
# keep everything else (build summary, errors, warnings).
filtered="$(printf '%s\n' "$output" | grep -vE \
  -e '^Resolving SDK version' \
  -e '^Setting the following tools as active:' \
  -e '^   (node-|releases-|sdk-)' \
  -e '^All SDK components already installed' \
  -e '^Skipped installing' \
  -e '^Installing SDK' \
  -e '^Next steps:' \
  -e '^- To conveniently access emsdk tools' \
  -e '^  consider adding the following directories to your PATH:' \
  -e '^    '"$(printf '%s' "$HOME" | sed 's/[&|]/\\&/g')"'/.*zig-pkg' \
  -e '^- This can be done for the current shell' \
  -e '^- Configure emsdk in your shell startup' \
  -e "^    (source|echo) .*emsdk_env\.sh" \
  -e '^Setting up EMSDK environment' \
  -e '^Adding directories to PATH:' \
  -e '^PATH = ' \
  -e '^EMSDK = ' \
  -e '^EMSDK_NODE = ' \
  -e '^$' \
  || true)"

if [ -n "$filtered" ]; then
  printf '%s\n' "$filtered"
fi

if [ "$status" -eq 0 ]; then
  printf 'WEB OK (exit 0)\n'
else
  printf 'WEB FAIL (exit %d)\n' "$status"
fi
exit "$status"
