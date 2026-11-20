# taplop

taplop is a tactical turnbased gridbased rpg working towards full official release

Zig rewrite of the Unity original at https://github.com/LinusWeggeHjalsted/taplop-unity

**Play:** a hosted browser build is planned (GitHub Pages) - this becomes
the link when it lands. until then, build and run locally (see below).

## How this codebase is written

the code, tests, and documentation in this repository are written by an AI
agent (an LLM, currently glm-5.3) working at the direction of the maintainer;
the game's design and every creative and review decision are human.

## Licenses
this game is multi-licensed:

* **Source code:** MIT by Linus Wegge Hjalsted - see LICENSE-CODE.txt
* **Graphic assets:** CC-BY-SA 4.0 by Cille Rosenørn Abildhauge - see LICENSE-GRAPHICS.txt
* **Audio assets:** CC-BY-SA 4.0 by Victor Heiber Bull Willaredt - see LICENSE-AUDIO.txt
* **Font (Cause):** SIL Open Font License 1.1 by The Cause Project Authors, designed by Saurabh Sharma - see LICENSE-FONT.txt. the license texts for all bundled content are also embedded in the exe itself (see `build.zig`, `generateAssetsFile`)

## Build & run

requires [Zig 0.17.1](https://ziglang.org/download/)

```sh
zig build run                    # debug build + run (includes dev tools - see below)
zig build run --release=fast     # release build for general play (no dev tools)
zig build                        # compile the native exe
scripts/test.sh                  # run the test suite (headless, PASS/FAIL summary)
```

the native build targets the host platform (linux is the everyday dev
host). the game also cross-compiles to every supported target - the
verified workflow is cross-compiling from linux:

```sh
zig build -Dtarget=aarch64-macos       # macos (Apple Silicon): bin/taplop + taplop.app/
zig build -Dtarget=x86_64-windows-gnu  # windows 10+ 64-bit: bin/taplop.exe
```

the macos build produces the double-clickable `taplop.app/` bundle next to
the exe; the windows build needs no windows toolchain (zig bundles MinGW).
`scripts/release.sh` wraps the native/web/mac builds with release gating
(`native|web|mac|all`) if you want the full matrix.

### Dev mode

debug builds (`zig build run`, or any build with `optimize == .debug`)
ship with dev-only keybinds gated by the `-Ddev-mode` build option. today
the only one is:

- **ctrl+Enter** - skip the current level (pushes the normal end-level
  cascade; replay-safe).

dev mode follows the optimize level: debug builds (the `zig build` default,
including `zig build web`) have it ON; release builds have it OFF. to opt a
release build into dev mode:

```sh
zig build run --release=fast -Ddev-mode=true
```

the gate is at the handler site, so the binding still parses in any build
but is a no-op when dev mode is off - the general client never has these
tools compiled into their logic path.

### Scratch data dir

you can point the persistent dir at a scratch path so your play sessions
don't mix into real saves:

```sh
zig build run -- --data-dir ./scratch
# or: TAPLOP_DATA=./scratch zig build run
```

## Web build

the web build targets `wasm32-emscripten` and needs the
[emscripten SDK](https://emscripten.org/) (fetched automatically as a
build dependency - no manual install):

```sh
scripts/web.sh            # zig build web  -> zig-out/web/taplop.html (clean output)
scripts/web.sh emrun      # serve + open it in a browser
# (raw: scripts/web.sh --raw passes through unfiltered)
```

the script defaults to a debug build (matching `zig build`'s default). for a
release build, pass any standard `zig build` flag through and it forwards
verbatim:

```sh
scripts/web.sh --release=fast      # ReleaseFast web build
scripts/web.sh --release=safe      # ReleaseSafe
scripts/web.sh emrun --release=fast # serve a release build
```

### Deploying the web build

`scripts/pages.sh` publishes the release web build to the `gh-pages` branch
(the GitHub Pages serving source): it builds `--release=fast`, renames the
html to `index.html`, and force-pushes the branch as one rewritten commit -
the ~16 MB of binaries never enter the repo's main history.
