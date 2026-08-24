taplop is a tactical turnbased gridbased rpg in early stages of development

Zig 0.16 rewrite of the Unity original at https://github.com/LinusWeggeHjalsted/taplop

## Licenses
this game is multi-licensed:

* **Source code:** MIT by Linus Wegge Hjalsted - see LICENSE-CODE.txt
* **Graphic assets:** CC-BY-SA 4.0 by Cille Rosenørn Abildhauge - see LICENSE-GRAPHICS.txt
* **Audio assets:** CC-BY-SA 4.0 by Victor Heiber Bull Willaredt - see LICENSE-AUDIO.txt

## Build & run

requires [Zig 0.16.0](https://ziglang.org/download/)

```sh
zig build run          # build and run the native (raylib) client
zig build              # compile the native exe
scripts/test.sh        # run the test suite (headless, PASS/FAIL summary)
```

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
ZIG_LIB_DIR=~/.local/zig-patched-lib zig build web    # -> zig-out/web/ziglop.html
zig build emrun                                        # serve + open it
```

this workaround goes away once Zig 0.16.1 ships and your distro packages it.
