taplop is a tactical turnbased gridbased rpg in early stages of development

Zig 0.16 rewrite of the Unity original at https://github.com/LinusWeggeHjalsted/taplop

## Licenses
this game is multi-licensed:

* **Source code:** MIT by Linus Wegge Hjalsted - see LICENSE-CODE.txt
* **Graphic assets:** CC-BY-SA 4.0 by Cille Rosenørn Abildhauge - see LICENSE-GRAPHICS.txt
* **Audio assets:** CC-BY-SA 4.0 by Victor Heiber Bull Willaredt - see LICENSE-AUDIO.txt
* **Font (Cause):** SIL Open Font License 1.1 by The Cause Project Authors, designed by Saurabh Sharma - see LICENSE-FONT.txt. the license texts for all bundled content are also embedded in the exe itself (see `build.zig`, `generateAssetsFile`)

## Build & run

requires [Zig 0.16.0](https://ziglang.org/download/)

```sh
zig build run                    # debug build + run (includes dev tools - see below)
zig build run --release=fast     # release build for general play (no dev tools)
zig build                        # compile the native exe
scripts/test.sh                  # run the test suite (headless, PASS/FAIL summary)
```

### Dev mode

debug builds (`zig build run`, or any build with `optimize == .Debug`)
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

during dev, point the persistent dir at a scratch path so your play sessions
don't mix into real saves:

```sh
zig build run -- --data-dir ./scratch
# or: ZIGLOP_DATA=./scratch zig build run
```

## Web build

the web build targets `wasm32-emscripten` and needs the
[emscripten SDK](https://emscripten.org/). Zig 0.16.0's stdlib has a bug in
`std/os/emscripten.zig` (fixed upstream on the 0.16.x branch) that breaks
emscripten compilation, so the web build needs a one-line-patched stdlib copy:

```sh
# once: copy your Zig install and apply the fix (STOPSIG -> SIG in std/os/emscripten.zig)
cp -r <your-zig-install> ~/.local/zig-patched-lib
# then:
scripts/web.sh            # zig build web  -> zig-out/web/ziglop.html (clean output)
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

this workaround goes away once Zig 0.16.1 ships and your distro packages it.
