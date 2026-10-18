# Ziglop

Zig 0.16.0 rewrite of a Unity tactical grid game (original at https://github.com/LinusWeggeHjalsted/taplop).

## Documentation

Four files, each with a clear job. Keep a fact in ONE place; never restate
settled decisions across files (that's how drift crept in before).

- **AGENTS.md** (this file) - the "how to work here" rules: build/test/commit
  workflow, code style, Zig gotchas, config format, the subsystem map. Single
  source of truth for working conventions. Read at the start of a session.
- **DESIGN.md** - settled subsystem design: architecture, invariants, the
  "why X is shaped this way." Read on demand when a task touches a
  subsystem's design, not every session. AGENTS points into it via the
  Subsystem Map below.
- **TODO.md** - active + near-term + deferred **tasks**, plus **open /
  undecided design questions** kept inline where they're being worked.
  Settled decisions do NOT live here - when a question settles, move the
  prose to DESIGN.md and leave a one-line pointer. Keeps it scannable.
- **DONE.md** - archive of completed work, resolved tech debt, and the
  "why we did X" history. Read on demand when you need the reasoning behind
  something that already landed, not every session.

Lifecycle of a fact:
  - **Open question** lives inline in TODO.md with the task that needs it.
  - **Settles** → move the design prose into DESIGN.md; in TODO.md drop to a
    pointer (`see DESIGN → <section>`) and check off the task.
  - **Task completes** → move its prose to DONE.md; in TODO.md leave a `[x]`
    one-liner (or just delete the line) so TODO stays scannable.

Read AGENTS.md + TODO.md at the start of a session. Reach for DESIGN.md when
a task touches a subsystem's settled design; reach for DONE.md only when you
need the history behind something already built. Keep all four in sync with
the lifecycle above. A fact lives in ONE place: AGENTS never restates design
- it points (Subsystem Map below); DESIGN never restates a working rule - it
links to AGENTS.

Two hygiene rules that keep the above true in practice:

- **Staleness is cleaned WHILE working, never deferred.** When renaming or
  removing a code symbol, grep DESIGN.md + TODO.md for stale references and
  fix them in the same commit - a doc naming a dead symbol is worse than no
  doc (it reads as truth). Same for comments the edit invalidates.
- **Prefer machine-walked truth over hand-maintained lists.** When an
  inventory/report/lookup can be DERIVED from source truth (an enum, a
  directory scan), generate it instead of curating it -
  `generated_lookups.zig`, `generated_sprite_metadata.zig`, `sound_report.zig`,
  `art_report.zig`, and `gradient_report.zig` are the pattern: new content appears automatically and
  a lie is structurally impossible. Hand-maintained duplicates of
  machine-derivable facts are drift by definition.

> **Collaboration style** (small steps, pause at checkpoints, surface
> tradeoffs, clarifying questions, stay inside the cwd) lives in
> `~/.pi/agent/APPEND_SYSTEM.md` as cross-project working conventions.

## Build & Test

- `zig build` - compile the native (raylib desktop) exe
- `zig build run` - build and run the native client
- `zig build test` - run all tests (headless; must never link raylib)
- `scripts/test.sh` - `zig build test` with an unambiguous PASS/FAIL summary.
  Prefer this over raw `zig build test`: the raw runner can print a
  `failed command: .../test ...` line on SUCCESS (exit 0) whenever a test
  writes to stderr (advisory warnings, etc.), which looks like failure. The
  script labels advisory output `[advisory, non-fatal]`, surfaces only real
  failures, and prints a final `PASS (exit 0)` / `FAIL (exit N)`. **Trust the
  exit code, not the text.** Don't fish for test binaries in `.zig-cache/o/`
  to "check" - `find` races the build and returns stale binaries; the exit
  code is authoritative.
  `scripts/test.sh --raw` prints the full verbatim output if needed.
- OK to run these directly without asking

### Testing discipline (arena blind spots)

The suite's settled design - the four bug classes it exists to catch, the
tier conventions (where each kind of test lives), the assertion patterns
(derived expectations, exhaustiveness properties over pinned windows, the
deletion policy), and the rejected coverage-matrix - live in DESIGN →
Testing. This section holds only the working mechanics.

Most tests wrap in an `ArenaAllocator` for easy cleanup (every sub-allocation
freed at once on deinit). Arena-wrapping MASKS two classes of bug:
- **Leaks** - arena `free` is a no-op, so a forgotten `free` is invisible
  (the arena reclaims everything at deinit anyway). Under `testing.allocator`
  a forgotten free is a hard leak error.
- **Use-after-free** - arena free does nothing, so a dangling slice into
  "freed" memory stays mapped and returns stale-but-valid bytes (test passes
  silently). `testing.allocator` reclaims freed memory and may reuse it, but
  doesn't deterministically detect reads of freed memory.

**No `expectPanics` in Zig 0.16.** A fail-fast validation site (e.g.
`verifyReplayMatch`, `validatePlayerAction`) can't be unit-tested at the
panic path - `std.testing` has no `expectPanics`/`expectError` for panics
(only for `error` unions). The convention: split the legality **logic**
into a bool-returning helper (`isPlayerMoveLegal`, `skillOnBarAndOffCooldown`,
`skillTargetLegal`) and test THAT directly; the `validate*` wrapper that
formats a message + `@panic`s is a thin policy layer over it, not unit-tested
(the panic call is obvious + the bool helper is covered). This also separates
"is this legal" from "what do we do about it" - useful design discipline
independent of the test limitation.

So: once a loader is made self-owned (see DESIGN → File System & IO →
Settings ownership), its tests should run under `testing.allocator` (no
arena) so leak detection fires - this is the path that caught nothing for the
mangled-settings bug while arena-wrapped. The overlay-user-settings test in
`session_setup.zig` is the model: it builds self-owned defaults WITHOUT going
through `loadConfigWithFallback` (which intentionally leaks for process
lifetime and would flag under `testing.allocator`), then overlays + frees via
`freeSettings`, asserting no leaks. The use-after-free class is removed by
construction (owned strings, no borrows); the leak class is now catchable.

Loaders that still borrow into leaked bytes (levels, hubs, themes - not yet
self-owned) stay arena-wrapped; their ownership fix is the prerequisite for
leak-checked testing, deferred until a load change lands (the campaign
editor's slice 1 is the load change that opens `loadHub` + `loadCampaign` -
see TODO → Level Editor → campaign editor). `scripts/test.sh`
cleans `crashes/` before and after a passing run so a panicking test's crash
dump doesn't pollute the tree.

**Sweep scripts and repeated test churn** (lessons from the Tier A skills
session + the ButtonPayload migration):
- **Dry-run one-shot sweep scripts against ONE file and inspect its full
  diff before running them across the tree.** Asserted replacements catch
  VALUE errors, but nothing catches SHAPE errors - the ai_options migration
  ran on all 31 skill files with a broken doc-walk and left doubled stale
  doc comments everywhere, invisible to the compiler for several commits.
- **A sweep script's own asserts can lose its applied work.** The
  assert-then-write-all shape (collect everything, verify, write once)
  throws away every already-computed replacement when a LATER step's
  assert fails - the ButtonPayload test-migration script hit this twice
  in one session, silently rolling back applied fixes between runs.
  Write after each successful step (asserts become post-conditions of
  what landed), so a bad step aborts with the good steps landed, not
  rolled back. The compiler is the real verifier anyway - the script's
  asserts are diagnostics, not gates.
- **When the same test breaks twice for the same structural reason, fix
  the test's SHAPE, don't patch the number again.** The utility-skill
  census counts were hand-updated twice before being derived from the
  same list the picker iterates (self-updating, still catches emission
  bugs). Snapshot counts of anything that grows by design are churn.

### Commit policy

- **Commit at each TODO slice checkoff.** The TODO slice boundaries are the
  natural commit units - each `[x]` is a unit that's done + tested + has a
  DONE.md entry. Committing at checkoff gives a clean, reversible baseline
  before the next slice starts (so breakages can be compared against it).
- **Commit locally without pushing.** Local commits are free; pushing is a
  separate step. Don't hold uncommitted work across sessions - 27 files of
  uncommitted changes across multiple sessions makes it impossible to tell
  whether a breakage is from the latest change or latent prior work.
- **Commit non-slice work as it happens.** Not every commit is a TODO slice -
  doc edits, tooling, quick fixes, and small refactors land on their own
  commit when the change is coherent and self-contained, rather than batching
  them into a pile to sort out later. A good unit is "one thing that builds
  and is done"; if a change has no DONE.md entry, the commit body is the
  record (see below). Don't split a landed commit after the fact when two
  small riders share it (e.g. a cleanup pair from one reflection) - the
  split costs more than the benefit; accept the commit as is.
- **Commit message: one line by default.** Shape: `<area>: <summary>` (e.g.
  `error handling: slice 1 - modal error popup surface`). `<area>` is the
  conceptual bucket (matches AGENTS.md sections / TODO items); `<summary>` is
  a single line, imperative mood, specific enough to distinguish from
  neighboring commits. The DONE.md entry is the detailed record; the commit
  message is the index - searchable in `git log --oneline`, then DONE.md for
  the why.
- **Body only when it adds information the DONE.md entry doesn't already
  carry.** The realistic cases: a bug-fix diagnosis (repro + root cause)
  before the DONE.md entry catches up; a commit that isn't a TODO slice and
  has no DONE.md entry (a quick fix, a reverted typo) - the body is the only
  record; a decision worth recording inline before it moves to AGENTS.md. If
  the DONE.md entry exists, the body is redundant - skip it. If there's no
  DONE.md entry, the body is the record - use it. The rule is self-policing:
  if you can't point to information the body adds beyond DONE.md, don't write
  one.
- **No conventional-commit prefixes** (`feat:`, `fix:`, `chore:`). There's no
  CI gate parsing them, no release-notes generation, no semver automation.
  The area name (`error handling:`, `editor:`) is more informative than a
  type tag and costs less typing.
- **Data-file edits from manual testing get reverted or committed separately.**
  A typo introduced to test the parser (`chracter_code`, `Metadta`) must not
  leak into a real code commit - it breaks tests and is indistinguishable from
  a real content change. Revert test artifacts before committing, or commit
  them with a `test:` prefix.
- Web build: a `wasm32-emscripten` exe reusing the SAME raylib backend +
  gameLoop as native (route B). `zig build web` produces zig-out/web/ziglop.html;
  `zig build emrun` serves + opens it. `scripts/web.sh` wraps both with
  emsdk-noise filtering (like `scripts/test.sh` does for tests) - prefer it
  over the raw commands. The old `wasm32-freestanding` + JS-renderer target
  was removed - do not reintroduce it.
- WEB BUILD NEEDS A PATCHED STDLIB: Zig 0.16.0's std/os/emscripten.zig has a
  bug (W.STOPSIG declared to return u32 but body returns the SIG enum) that
  breaks emscripten compilation. The fix is upstream on the 0.16.x branch
  (STOPSIG -> SIG). We carry it locally by copying /usr/lib/zig to
  ~/.local/zig-patched-lib, applying the one-line fix, and running the web
  build with `ZIG_LIB_DIR=~/.local/zig-patched-lib zig build web`. Native +
  tests use the normal zig (no env var). When 0.16.1 ships and Arch packages
  it, the patched copy becomes unnecessary.
- WEB COMPILES ≠ WEB RUNS: `scripts/web.sh` only compiles. Runtime breakage
  (GLSL shaders, allocator traps, init-order) is invisible until someone
  opens the page - the web build once sat broken for 136 commits this way
  (a `page_allocator` segfault landed with the TTF wiring and nothing
  surfaced it; see DONE.md, "Web black screen"). When a change touches the
  platform seam (`src/raylib/`, `web.zig`, build.zig wiring, anything
  shader- or allocation-adjacent), spend the 30 seconds: `scripts/web.sh
  emrun` and confirm the main menu loads. Runtime web bugs can be debugged
  WITHOUT a browser: `node zig-out/web/ziglop.js` runs the emcc output
  headlessly - `std.debug.print` works there, so early-boot code paths
  (anything before GL init) can be probed like a native CLI. That
  technique diagnosed the 136-commit black screen entirely outside a
  browser.
- macOS build: `zig build -Dtarget=aarch64-macos` cross-compiles from the
  Linux box (Apple Silicon; raylib's macOS path uses the lazy
  `xcode_frameworks` .tbd-stub package - fetched once, then offline; our
  build.zig.zon declares the same package so the exe's link step gets the
  framework search paths raylib's own module doesn't propagate - see
  DONE.md, mac port). The build also links the OpenGL framework
  explicitly (the dev diag's glGetString needs it - an earlier
  upload-fix's glFinish was also cited here but that fix was falsified
  and reverted; raylib itself goes through its glad loader).
  Produces `zig-out/bin/ziglop` PLUS the double-clickable
  `zig-out/ziglop.app/` bundle (minimal Info.plist, no icon yet, unsigned -
  a browser-downloaded copy needs `xattr -cr ziglop.app` once; codesigning
  needs a mac host). **MAC COMPILES ≠ MAC RUNS** (the same lesson as web):
  the binary is only validated when someone opens it on real hardware -
  the runtime checklist lives in TODO (macOS native port). Persistent dir
  on mac: `~/Library/Application Support/ziglop/` - see DESIGN → File
  System & IO → Persistent path.
- **CONSOLE COMPILES ≠ CONSOLE RUNS** (the same lesson, at home): the
  console channel's stdout/TTY behavior is invisible to the headless
  suite - no test can see a prompt, a boot hint, or output interleaving.
  Behavioral changes to the channel (or anything stdout-adjacent) get the
  30-second smoke runs against the REAL binary: piped
  (`printf 'help\nquit\n' | ./zig-out/bin/ziglop` - commands must work,
  prompts must NOT print) and interactive via a pty
  (`printf '<cmds>\n' | script -qec ./zig-out/bin/ziglop /dev/null` -
  boot hint + prompts must print; the pty also exercises the TTY gate,
  which a plain pipe can't). Case study: the console prompt's first
  commit shipped an ungated boot prompt with 824 tests passing; the
  piped run caught it in seconds (DONE.md, "console: help + inputs").
- **`.zig-cache` grows unbounded** (one directory per build variant - it
  accumulated to 90 GB on a 234 GB disk before being noticed). Prune it
  (`rm -rf .zig-cache`) when disk gets tight or every few months: a fresh
  cache is only ~350 MB (one native build + one test run), and a cold
  full rebuild is ~40 s - pruning is cheap, letting it pile up is not.
- Test discovery is automatic: build.zig generates `src/generated_test_root.zig`
  (gitignored) importing every `src/**/*.zig`, and `addTest` uses it as root. Any
  `test` block in any src file is picked up with no manual wiring. Note this
  means the test build compiles the whole tree, including files main.zig may not
  reach directly. EXCEPTION: `native.zig`, `web.zig`, and the whole
  `src/raylib/` directory are excluded
  from the scan because they link raylib and the test build must stay headless.
  `web.zig` is also excluded (same reason).

## Code Style

- Verbose naming everywhere: `ScreenPosition` not `ScreenPos`, `index` not `idx`, `allocator` not `alloc`
- Multiline function signatures - one parameter per line when long
- All gameplay logic uses integers. Floats only for input, settings, rendering
- No abbreviations
- **Em-dashes, en-dashes, and ellipses are ALLOWED while working - the
  sweep normalizes before commit.** Write naturally; avoiding them
  per-token costs more than the cleanup. `scripts/dash_sweep.sh`
  replaces em-dash (U+2014) and en-dash (U+2013) with `-` and ellipsis
  (U+2026) with `...` across every tracked file - RUN IT BEFORE COMMITTING
  (it is cheap; `--check` is the gate and exits 1 on findings, so a clean
  commit needs a clean check). Shipped text stays plain by construction:
  the tree is normalized at every commit. Rendering: the atlas bakes the
  font's FULL cmap coverage (`src/font_codepoints.zig` - DESIGN → Platform
  Seam → SDF text outline), so covered punctuation renders correctly; a
  codepoint the font lacks still draws `?`, and the committed-plain rule
  keeps the tree inside the covered set in practice. `scripts/test.sh`
  surfaces findings as a non-fatal advisory (the commit checkpoint) - a
  hard gate was deliberately rejected: failing a build over prose
  punctuation would reintroduce the per-token avoidance the relax removed.
- **Minimize `pub`.** Mark a symbol `pub` only if another file imports it;
  everything else is `fn`/`const` (file-private). The compiler errors on
  unused file-private symbols, so this turns it into a free dead-code detector.
  A `pub` symbol is presumed to be API - nothing flags an unused one - so
  dead `pub` scaffolding (`computeFrameLength`, `DecorationId`) can linger
  across redesigns. The machine-walked check is
  `scripts/unused_pub_report.sh` (Dev Tools below) - the discipline plus
  the report is the lever. If a symbol needs to be `pub` for a
  test (`test "..."` blocks in the same file can see file-private symbols, so
  this is rare), keep it `pub` but note why.

### Code Comments

Comments describe the code AS IT IS - never an imagined future state. This
is the rule that prevents drift: a comment written as "lands later" / "wired
later" / "for now" rots the moment the work lands, because nothing points
back at the comment to update it.

- **TODO.md owns all forward-looking notes.** No `TODO`/`FIXME`/`HACK`
  markers, no "will eventually"/"lands when"/"revisit" prose in code. If a
  gap is worth tracking, it lives in TODO.md; the code says nothing about it.
  A runtime stub may use a descriptive panic message (e.g.
  `"editor event handler not yet implemented"`), but that's a diagnostic,
  not a comment.
- **File-level `//!` header** on every file with a distinct architectural
  role: one short paragraph - what the file owns, key invariants - plus an
  `DESIGN → <section>` link where a settled design lives. `src/raylib/backend.zig`
  is the model. Skill/effect files are exempt: each is self-documenting via a
  `///` doc on its `pub const skill`/`pub const effect`.
- **`///` doc comments** on public types/fns/fields with non-obvious meaning:
  WHAT + WHY, not HOW.
- **Inline `//` only for the non-obvious** - a tricky invariant, a tiebreak
  convention, a "why this not the obvious thing". Not for restating what the
  next line does.
- **Link, don't restate settled decisions.** Instead of a 5-line inline
  explanation of the replay cache, write `// Reconstruction cache - see
  DESIGN → File System & IO`. Same single-source-of-truth rule as the .md
  files: the design lives in DESIGN.md, the code points at it.

### Belong, don't fit

When adding something, find where the design would have put it - the seam
that already exists for this kind of problem (the Subsystem Map + the
relevant DESIGN section answer "where?"). "Making it fit" - adapters,
one-off flags, a special case in someone else's code, a seam built at the
same time as its one consumer - defers a design decision into many small
future payments, and the fit is invisible to the compiler (`walkingDistance`
survived many sessions this way).

- **Fit smells**: a name needing vocabulary the design doesn't use
  (adapter/shim/compat/legacy/special); a comment justifying the thing's
  EXISTENCE rather than describing it; a flag consumed in exactly one place;
  a seam with one implementation and one consumer, born together.
- **Belonging tests**: would the design have specified it before the need
  arose? If it vanished, would the design feel incomplete (belongs) or get
  cleaner (fits)? Is it riding a seam that existed for other reasons?
- **Precedents**: mac Command → the backend key table (the site that owns
  physical-key→id mapping), not a platform field threaded through bindings;
  console input reusing `applyAction` instead of a second dispatch path; the
  dispatch convergence - bindings fire by design, not by remembered wiring
  (the ctrl+S missing-dispatch-line bug class is what "fit" looks like).
- Fitting is legitimate as acknowledged debt: tracked in TODO.md, never
  annotated "for now" in code (see Code Comments above).

## Config File Format

- `.txt` files with CamelCase section headers (whitelisted in parser.zig) and snake_case keys
- Values separated by space, can contain spaces: `player_name New Player`
- Blank lines separate entry groups within sections
- Enum values must match code exactly (lowercase)
- Layout sections are raw character grids, not key-value

## Zig 0.16 Gotchas

- A switch prong with a RESULT TYPE needs a labeled block to yield its
  value: `.a => { stmt; value },` fails ("expected ';' after statement" -
  the trailing value parses as a statement, not the block's yield);
  `.a => blk: { stmt; break :blk value; },` works. Verified by minimal
  repro; harmless in void-context switches (statement bodies are fine).
- A switch prong whose body is a bare `if (cond) thing = value,` also
  fails ("invalid left-hand side to assignment") - the blockless `if` in
  prong position parses as an expression. Same fix as above: give it a
  body, `if (cond) { thing = value; },`. Hit twice in one session
  (a scrollbar test, an Export Game label check) - same shape class as
  the result-type prongs, different trigger.
- ArrayList is unmanaged: `.empty`, pass allocator to each call
- ArrayList has no `.writer()` - use `.print(allocator, fmt, args)` and `.appendSlice(allocator, items)` directly
- PriorityQueue: `.empty`, `.push(allocator, item)`, `.pop()`, `.deinit(allocator)`
- Dir.writeFile takes an options struct: `.{ .sub_path = path, .data = data }`
- File I/O needs Io handle: `std.Io.Threaded.init(allocator, .{})`, `std.Io.Dir.cwd()`
- No `std.enums.count()` - use `@typeInfo(MyEnum)."@"enum".fields.len`
- No default parameter values - `fn f(x: i32 = 0)` is a compile error. Use
  a required param + callers pass the default, or an optional `?T` the
  caller fills with `null`.
- `///` doc comments are valid ONLY on declarations (top-level consts,
  fns, types, fields). Inside a function body it's always `//` - a `///`
  there is "expected statement, found a document comment".
- `opaque` is a reserved keyword (opaque types) - don't name a variable it.
- **By-value extern-struct arguments on aarch64 - a 0.16.0 compiler
  bug; avoid the triggering pattern until the 0.17 migration:** Zig
  0.16.0 lowers the caller side of a by-value extern-struct parameter
  (raylib's `Color`, `Rectangle`, ...) to an out-of-bounds 8-byte load
  from the 4-byte object - IR-level poison, which licensed LLVM to
  DELETE the stores building the value, silently passing uninitialized
  (or `undef`) memory to the C call. The trigger shape is an if/else
  EXPRESSION whose branches are calls returning the extern struct by
  value, with the extern call as the value's only consumer. RULE:
  pre-select the plain source value, then convert once - the
  `drawNineSlice`/`drawTextLabel` tint shape. Affects ALL aarch64
  targets, optimized builds only (Debug is fine; ReleaseSafe breaks
  SILENTLY - no panic). Fixed on zig master (fa3a9fcd / PR #35711);
  NOT in any 0.16.x release. History: DONE → "mac 9-slice panels -
  ROOT CAUSE FOUND"; repro + report kit:
  `../ziglop-mac-bisect/repro/` (UPSTREAM_REPORT.md).
- **`std.Io.Threaded.init(allocator, .{})` spawns children with an EMPTY
  environment** - the options' `environ` field defaults to `.empty`, so a
  child process (e.g. `xdg-open`) gets no PATH/DISPLAY/DBUS and fails
  with a baffling exit code while the spawn itself "succeeds". When
  spawning, pass the process environ explicitly (the C `environ` global,
  reachable only in libc builds; start.zig wires no environ source
  otherwise). Related trap: `std.process.run` NEVER errors on a nonzero
  child exit - check `result.term` or "success" is a false positive.
  Found as the repo-link bug (xdg-open exit 3 from the game, exit 0 from
  any shell); the spawn design was then removed entirely in favor of the
  clipboard - history in DONE.md.
- `std.heap.page_allocator` is UNUSABLE on wasm32-emscripten: on wasm it is
  BrkAllocator, which grows memory via the raw `@wasmMemoryGrow` intrinsic
  behind emscripten's back - the JS heap views detach and SAFE_HEAP bounds
  go stale, so the first access to page-allocated memory reports a
  segfault. On web, ALL allocation goes through libc; transient untracked
  buffers use `src/transient_allocator.zig` (c_allocator on emscripten,
  page_allocator on native). Never call `std.heap.page_allocator` directly
  from shared code. Full why: DESIGN → Platform Seam → Allocator rule for
  emscripten.

## Dev Tools

Dev-only keybinds (skip level, future debug tools) are gated by a build
option, not a runtime flag:

- `-Ddev-mode` build option (in `build.zig`), defaulted to
  `optimize == .Debug`. So `zig build run` (debug) gets dev tools for free;
  `-Ddev-mode=true -Doptimize=ReleaseFast` opts in for a near-release build.
  Dev mode follows the optimize level, so the web build (which defaults to
  Debug like every `zig build` target) has it ON unless you pass
  `--release=fast`; a release web build is clean (no dev tools compiled in).
  Exposed to
code via `@import("build_info").dev_mode` (comptime-constant per build,
  threaded through the shared `build_info_module` used by exe + wasm +
  tests).
- `-Dweb-debug-runtime` build option (in `build.zig`), defaulted false. The
  web Debug build strips emscripten's expensive runtime-debug features
  (ASSERTIONS, SAFE_HEAP, source maps) by default to speed up the emcc link
  (the dominant web-build cost). Pass `-Dweb-debug-runtime=true` to restore
  them for browser-devtools work (source maps, null-pointer checks, etc.).
- **Diagnostics log** (`src/diagnostics.zig` - the raylib-free type:
  buffer + section policy + flush scheduling, unit-tested headless;
  `src/raylib/diagnostics.zig` - the GL-touching probe sites that
  gather values; not on web): best-effort writes to
  `logs/diagnostics.txt` in the persistent dir, rewritten whole at the
  END-OF-FRAME safe point (after present - never mid-draw). Holds
  boot-time GL context info (window points vs framebuffer pixels, GL
  vendor/renderer/version/GLSL via a direct `glGetString` call - the macos
  build links the OpenGL framework for this in build.zig) plus ONE-SHOT draw
  probes: the first plain sprite draw (the known-working control - fires on
  slots/health bars in-game) and the first 9-slice panel draw (full draw
  state: texture, tint, destination, all nine pieces) + the render-target
  pixel readback on the frame a probe armed. Activation is RUNTIME:
  dev-mode builds default active, and the `--diagnostics` CLI flag turns
  it on in ANY build - plain release included (the binary that exhibits
  a bug produces its own data). Purpose: hardware troubleshooting without
  a Terminal (the mac bring-up; future player bug reports). Extend by
  adding a probe site + a `Diagnostics.record*` section; never let a
  diagnostics write surface as a crash (best-effort `catch return` on
  every write). Settled design: DESIGN → Platform Seam → Diagnostics.
  `-fsanitize=undefined` stays on regardless (raylib's C objects reference
  UBSan symbols). The sdf_atlas_generator also builds in Debug (not
  ReleaseFast) for faster clean builds; the SDF generation run is a few
  seconds slower but only runs once per clean build.
- The BINDING ships in `data/default_settings.txt` regardless (so the
  settings file stays the source of truth and a future binding-UI sees one
  set). The gate is at the HANDLER site (`if (build_info.dev_mode and ...)`),
  so in a non-dev build the binding parses + maps to a `PlayerInput` flag but
  the flag is never consumed - a no-op. `translateInput` stays build-agnostic
  (pure binding→action); policy lives in the consumption layer.
- `skip_level` (ctrl+Enter): an idle input (`IdleInput.skip_level`) handled
  in `handleIdleInput`. Pushes `end_level` with the default continuation -
  the normal next-level / mission-end cascade (same path the options-menu
  exit uses). Level-only (`current.screen == .level`); `handleIdleInput`
  only runs with an empty stack + no active wait, so it never interleaves
  with a draining enemy turn. Replay-safe by construction (a normal recorded
  event). See DESIGN → Input (hybrid precedence) for why ctrl+Enter doesn't
  also fire the plain-Enter `confirm`/`dismiss_error` bindings.
- **Doc-symbol staleness checker** (`scripts/doc_symbol_check.sh`): every
  backticked dot-path in AGENTS/DESIGN/TODO checked against the source tree -
  STALE (member name in no .zig file) + MOVED (member exists but not in the
  file the doc names - the recorded drift class). Advisory by default,
  `--strict` for a gate. Convention it settles: TODO prose naming a
  NOT-YET-LANDED symbol uses the bare name - a backticked dot-path is the
  checker's "exists today" signal. DONE.md is not scanned (history
  legitimately names dead symbols).
- **Unused-pub report** (`scripts/unused_pub_report.sh`): the machine-walked
  minimize-pub check - walks pub fn/var + typed consts under src/ (raylib
  seam excluded), reports DEAD (deletion candidates - declaration is the
  only occurrence), UNUSED (de-pub candidates - internal-only), TEST-ONLY
  (keep pub + note why). Run it when touching pub surface; the findings
  list informs, each de-pub/delete is a per-symbol decision. Known blind
  spots (types consumed unnamed, namespace contracts) are documented in
  the script header.

## Key Files

- `src/main.zig` - platform-agnostic composition root: the uncapped game
  loop (`gameLoop`/`run`), the per-iteration `update` step that ties input +
  event processing together, and the round-trip reconstruction test. Config
  loading lives in `session_setup.zig` (raylib-free).
- `src/session_setup.zig` - session startup: loading all config (settings,
  color themes, weapon types, salvage tables) + `SessionSetup`/
  `createSessionSetup`/`fixupPointers`/`freeSessionSetup` (the web re-boot's
  teardown: the tracked startup memory `StartupMemory` + the history deinit)
  + `FrameState`. The entry files (`native.zig`/`web.zig`) call
  `createSessionSetup` then hand the result to `main.run`/`main.frame`.
- `src/test_harness.zig` - reusable harness for `processEvent` handler tests
  (`Harness.init` + `newHistory` + `runToIdle`); test build only.
- `src/event_handlers.zig` - the thin `processEvent` dispatch: pop +
  record/replay bookkeeping, the start_level/start_hub checkpoint policy,
  the editor arm's cache-needing inline cases, and the routing to the
  category handlers. (The round-trip reconstruction test lives in
  `main.zig`.)
- `src/handlers/meta.zig` - `handleMetaEvent` (the `.meta_event` arm):
  session flow - menus, saves, campaign/hub/mission/level lifecycle,
  editor framing, waits.
- `src/handlers/level.zig` - `handleLevelEvent`/`handleSubLevelEvent`
  (the `.level_event`/`.sub_level_event` arms): turn flow + combat
  primitives, enemy AI, anim/pacing constants.
- `src/event_push.zig` - the event-stack push utilities (`pushEvents`/
  `pushPlayerSkillUse`/`pushPlayerAction`, the input-side compile-time gate)
  shared by the handlers, input_handlers, main.zig, and the tests.
- `src/editor/planning.zig` - the pure editor click planners
  (`planEditor*Actions`, one per tool) + editor selection algebra, shared by
  the editor handlers and the input-side no-op gate
  (see DESIGN → Level Editor → Active-tool model).
- `src/editor/handlers.zig` - `handleEditorEvent` (the `.editor_event`
  arm's state transform, minus the cache-needing framing events handled
  inline in the dispatch) + the editor session helpers (playtest data,
  player import, palette defaults, fresh-mission open, decoration
  registry) + selection-mutation + template/layer edit helpers.
- `src/handlers/shared.zig` - cross-category handler helpers (entity
  accessors, the recoverable reconstruction-read failure, config-key
  validation + warning surfacing, campaign load, gameplay start batch,
  move-highlight refresh + prepared-skill cancel).
- `src/handlers/player_input.zig` - `handlePlayerInputEvent`, the
  `.player_input_event` arm (player-initiated orchestrator actions).
- `src/handlers/player.zig` - the `.player_event` + `.super_event` arms
  (player verbs, entity↔PlayerData sync) + gear/salvage helpers + clone
  harvest math.
- `src/input_handlers.zig` - input consumption: `handleAnytimeInput`,
  `handleIdleInput`, `resolveTileCursor`, the text-field commit sites, the
  keybind-edit mutation machinery (`applyKeybindEdit`/`removeKeybindBinding`/
  `rebuildInputBindings`), the per-action sound choke point
  (`dispatchFiredActionSounds`), and session-log dev tooling (dumpEventLog,
  build-version warn, timestamp formatter).
- `src/input_gestures.zig` - pointer gesture resolution: the drag
  lifecycle + click intents, camera pan, settings sliders, right-click
  inspect, and the editor viewport gestures (right-click delete, marquee,
  selection move drag).
- `src/editor/mission_io.zig` - editor mission save/export/import (uuid
  resolution, stem-namespace normalization + the referenced-art carry on
  save, STORE zip bundling, the web import marker poll) + the
  mission list/sprite rescans + the validation-replay write
  (`writeValidationReplay`, the one handler-owned side effect - the
  end_validation success path calls it gated `!replaying`).
- `src/view.zig` - `view()` (builds ViewState each frame from GameState +
  SessionState + the per-frame arena) + world drawable builders (tiles,
  overlays, entities, decoration pieces, ground items, flag poles, occlusion
  insets, health bars) + camera math (computeCamera, tileToScreen) +
  sprite/flag frame/pivot constants.
- `src/native.zig` - native exe entry (raylib); `src/web.zig` - web (emscripten)
  exe entry (the in-memory persistent mount + emscripten main-loop driver +
  the Import Game re-boot + the web audio queue watchdog - see DESIGN →
  Platform Seam → Web audio onset latency);
  `src/raylib/backend.zig` - the raylib platform backend (window/clock/
  render target/render driver, the duck-typed `RaylibBackend` interface) +
  `src/raylib/input_poll.zig` (the key/mouse mapping tables + the per-frame
  edge/position/char-queue read) + `src/raylib/audio.zig` (the layered-cue
  sound caches + the ambient-music intensity stack) +
  `src/raylib/textures.zig` (the lazy sprite caches + outline/inset mask
  generation + opaque-bounds scans) + `src/raylib/text.zig` (the SDF
  text-outline pipeline + text drawing; the codepoint source is
  `src/font_codepoints.zig`, the cmap reader both the build-time atlas
  generator and the contract tests use) +
  `src/raylib/conversions.zig` (shared Color/rect raylib conversions) +
  `src/browser_url.zig` (the upstream-repo link click: web opens a new
  tab via the emscripten seam - `window.open` with `'_blank'`, spec-
  guaranteed never to navigate the game tab; native queues a clipboard
  copy on SessionState that frame() drains to the backend's raylib
  clipboard; the URL is the `origin` remote derived at build time -
  build.zig computeRepoUrl) +
  `src/raylib/diagnostics.zig` (the GL-gathering probe sites for the
  diagnostics log - see Dev Tools; the type is raylib-free
  `src/diagnostics.zig`) + `src/raylib/draw.zig` (the world +
  UI element drawing passes). The ONLY directory whose files import raylib;
  the test-root scan skips it wholesale (see DESIGN → Platform Seam)
- `src/state.zig` - GameState, GameStateHistory (+ SessionState, undo/redo/
  replay timeline: recordEvent/discardFutureTimeline/replayTo/
  reconstructFromEventLog/validatePlayerAction, + the debounced settings
  persistence: PendingWrite/writeSettingsToFile/markSettingsDirty), Screen,
  + `deinit` (the teardown's history free - see DESIGN → File System & IO →
  Web storage model)
- `src/types.zig` - all game data types, Entity with getEffective* methods
- `src/events.zig` - event hierarchy (Meta, Super, Player, Level, SubLevel,
  Editor, PlayerInput, ReplayViewer categories)
- `src/parser.zig` - generic config-file format layer: `Section`/
  `EntryGroup`/`KeyValuePair` types, `parseConfigFile`, section/key
  whitelists + `validateSections`/`validateFileFormatVersion`/
  `validateKeys`, value coercion (`asU32`/`asBool`/`asColor`/`parseEnum`),
  `findSection`/`findValue`, and the shared `file_format_version`
  constants. The format layer the other three build on.
- `src/loaders.zig` - game-content loaders (config sections → typed
  `types.*`): `loadLevel`/`loadHub`/`loadMission`/`loadCampaign`/
  `loadPlayerSave`/`loadSettings`/`loadWeaponTypeDefinition`/
  `loadColorThemeDefinitions`/`loadSalvageDefinitions`/`loadDecorationRegistry`/
  `loadPlayerLoadout`, decoration footprint/anchor validation, editor dedup
  (`buildEditorMission`)/instantiation (`instantiateEditorLevel`), the
  `free*`/`clone*`/equality helpers, balance bounds (`boundedU32`/`max_*`),
  custom-sprite PNG dim resolution.
- `src/writers.zig` - save/settings writers (typed objects → config text):
  `writePlayerSave`/`writeSettings`/`writePlayerSaveToFile`. The inverse of
  `loaders.zig`.
- `src/console.zig` - the console input channel (stdin - see DESIGN →
  Input → Console input): the command parser, the SPSC reader→game queue,
  the per-frame command drain + PlatformInput merge, the applyAction fold,
  and the dump routing. Raylib-free.
- `src/dump_walker.zig` - `dump <path>` reflection over the live object
  graph: a path is a Zig member-access expression (fields, union tags,
  indexes) evaluated read-only against the FrameState root. Never follows
  pointers, never calls methods - see DESIGN → Input → Console input →
  dump paths for the safety invariants + rendering rules.
- `src/session_log_bundle.zig` - the session-log BUNDLE (the folder
  artifact: session_log.txt + a ReconstructionCache manifest + `content/`
  byte copies of every reconstruction read; writer via FileSource, loader via
  std.Io.Dir with per-copy sha256 verification). See DESIGN → Logging &
  Replay → Session-log bundle.
- `src/session_log.zig` - session-log serializer/deserializer
  (`writeEventLog`/`loadEventLog`/`SessionLog`, comptime-generic over the
  `Event` union) + the shared session-log timestamp formatter. See
  DESIGN → Logging & Replay.
- `src/validation_replay.zig` - the validation-replay artifact's pure
  machinery: structural loader + turn derivation + medal targets + the
  personal-best overwrite decision. See DESIGN → Custom Missions & Online
  Services → Validation replay.
- `src/functions.zig` - pathfinding (A*), chebyshevDistance, helpers
- `src/ui.zig` - the facade: re-exports every pub symbol of `src/ui/` so
  consumers keep `ui.X` (see DESIGN → UI Framework)
- `src/ui/element.zig` - the UiElement union + variants, Rect algebra
  (Row/Grid), layout constants, FontMetrics, hit-testing, wrapRow
- `src/ui/state.zig` - UiState (classes 2-4 of the UI state classification - see DESIGN → UI Framework → UI state classification) + drag/click/marquee types; the class-1 surface state lives on GameState (`types.UiSurfaceState` + `Editor.picker`)
- `src/ui/text_input.zig` - the text-field widget core + routing
- `src/ui/keybind_edit.zig` - the keybinds tab's edit state machine (listening/
  picker/pending) + the translateInput capture seam (`routeKeybindCapture`) -
  see DESIGN → UI Framework → Settings screen
- `src/ui/tooltip.zig` - tooltip placement + content builders
- `src/ui/emit.zig` - shared builder primitives (buttons/headers/number
  labels, sprite-id resolution, material icons)
- `src/ui/editor_shell.zig` - the editor's always-present structural UI:
  the tool palette (bottom bar), level tabs, Test/Validate primary
  actions, palette group math
- `src/ui/editor_inspector.zig` - buildEditorInspectorPanel +
  buildEditorMetadataSidebar, the inspector target inference, the field
  emitters, textEditPressProceeds
- `src/ui/editor_pickers.zig` - the centered pickers (skill / sprite /
  theme / footprint editor) + the official sprite tables
- `src/ui/bottom_bar.zig` - the in-game bottom bar
- `src/ui/panels.zig` - in-game middle panels (inventory/gear/skills/
  entity inspect) + slot-content support
- `src/ui/screens.zig` - error popup, top bar, mission complete/fail
- `src/ui/menus.zig` - options/main menu, load-save + editor browsers,
  credits, settings
- `src/input.zig` - input pipeline, translateInput, bindings
- `src/combat_log.zig` - combat-log projection (projectCombatLog + combatLogTier)
- `src/file_source.zig` - unified file I/O (FileSource: embedded map +
  persistent dir + future VFS; the web seams: browser download/upload JS,
  the game import marker + staging temp, the artifact-name listing
  exclusion set; see DESIGN → File System & IO)
- `src/game_zip.zig` - the game-folder zip round trip (Export Game's
  writer + Import Game's overlay machinery + marker poll - see DESIGN →
  File System & IO → Web storage model)
- `src/content_hash.zig` - mission content identity (SHA-256 over the
  mission's config files; see DESIGN → Custom Missions & Online Services → Content
  identity). v1 hashes config files only; extends to custom assets when the
  VFS lands with directory listing.
- `src/crash_dump.zig` - custom panic namespace installed in both entry files;
  dumps the live session as a session-log bundle to `crashes/crash_*/`
  before `@trap`. See
  DESIGN → Error Handling → Crash dump.
- `src/diagnostics.zig` - the raylib-free diagnostics type (buffer + section
  one-shot policy + end-of-frame flush scheduling), runtime-gated by the
  `--diagnostics` CLI flag (dev-mode default). See DESIGN → Platform Seam →
  Diagnostics.
- `src/deep_copy.zig` - comptime-generic `deepCopy`/`deepEqual`/
  `firstDiffField` over GameState + Event; `deepEqual` backs replay
  verification (`verifyReplayMatch`). See DESIGN → Determinism & Tiebreaking.
- `src/tween.zig` - pure easing fns (`easeOutCubic`); read by `view()` for
  one-shot anim interpolation. See DESIGN → Animation.
- `src/skill.zig` - the Skill interface (Skill struct, AiOption, the
  ai_options_fn signature + the pass-scoped EvalFrame, deals_damage +
  self_centered flags). See DESIGN → Architecture (AI rating scale + AI
  cast selection)
- `src/skill_helpers.zig` - skill building blocks (targeting/lookup helpers
  shared by most skill recipes) + the enhancement-enchantment machinery
  (`bestCastsWithVirtualEffect` + `simDifferentialGain`). See DESIGN →
  Architecture (AI rating scale, the virtual-effect sim differential)
- `src/ai_threat.zig` - AI range/threat math (shared by the enemy AI and
  defensive skills' rating fns). See DESIGN → Architecture (AI threat model)
- `src/ai_select.zig` - the ONE enemy cast-selection algorithm
  (`bestCasts` + `optionsFor`, the pass-scoped `EvalFrame` memoization +
  cycle guard) shared by `enemy_turn_attack` and enhancement
  enchantments' ratings. See DESIGN → Architecture (AI rating scale + AI
  cast selection)
- `src/ai_movement.zig` - AI movement-mode selection (how a non-player
  entity moves each turn). See DESIGN → Architecture (AI movement modes)
- `src/effect.zig` - the Effect interface with 18 callbacks (interception +
  on-effect/turn/attack hooks + outgoing/incoming pairs for damage/stun/effect/
  knockback/collision + onRetreat + onOpponentDeath)
- `src/skills/` - one file per skill (every file in the directory is a
  skill; the SkillId scan in build.zig assumes exactly that)
- `src/effects/` - one file per effect (same convention as src/skills/)

## Subsystem Map

One line per subsystem, pointing into DESIGN.md (settled design) and the key
source file(s). Read DESIGN → <section> when a task touches that subsystem.
Working rules (build/test/commit, code style, Zig gotchas, config format)
stay here in AGENTS; this map is the seam between the two.

- **Platform seam (raylib)** - DESIGN → Platform Seam (raylib): native/web
  driver split, budget-driven drain, render gating, letterbox, two-camera
  model, camera pan, render target resolution, SDF text outline, allocator
  rule for emscripten, web audio onset latency watchdog. Key:
  `src/raylib/` (backend.zig), `native.zig`, `web.zig`, `transient_allocator.zig`,
  `tools/sdf_atlas_generator.zig`.
- **Audio** - DESIGN → Audio: sound as side effect, sfx queue + looping music
  stream, button press/release model, backend cache + init-order gotchas.
- **Animation** - DESIGN → Animation: looping vs one-shot anims, the
  replay-purity invariant (clock read in `frame()` only), animation clock,
  frame rate.
- **Replay & side effects** - DESIGN → Replay & Side Effects: pure state
  transforms in handlers, side effects gated `!replaying`, transient state
  off GameState, undo mid-drain.
- **Versioning** - DESIGN → Versioning: `game_version` (advisory) vs
  `file_format_version` (hard gate); per-type constants in parser.zig.
- **Logging & replay** - DESIGN → Logging & Replay: one log
  (`event_history`), session dump, combat-log projection, reconstruction.
- **Determinism & tiebreaking** - DESIGN → Determinism & Tiebreaking:
  natural-stack replay verification, player-action legality validation,
  explicit tiebreak conventions.
- **Input** - DESIGN → Input: modifier-subset binding match, engine-owned
  key repeat, settings persistence + binding overlay, debounced writes.
- **Error handling** - DESIGN → Error Handling: unrecoverable vs
  recoverable, the popup surface, three recoverable contexts, B-simple
  recording, crash dump.
- **File system & IO** - DESIGN → File System & IO: single-file exe,
  FileSource (VFS/persistent/embedded), embedding, persistent path, raylib
  seam, settings ownership, reconstruction cache, web session-scoped
  storage (an in-memory persistent mount, no browser storage, +
  Import/Export Game).
- **Custom missions & online services** - DESIGN → Custom Missions & Online
  Services: dreams, browser, content identity/hash, balance bounds, turn
  counters + author medals, auth/server seam.
- **Campaigns & the campaign editor** - DESIGN → Campaigns & the Campaign
  Editor: the hub/mission graph model (missions as unique hub→hub edges),
  campaign/hub/mission file formats, NPC = type + position, discovery +
  travel, the world-map mirror, the campaign view + hub drill-in + mission
  hand-off. Design settled, NOT YET BUILT - slices + open questions in
  TODO → Level Editor → campaign editor.
- **Clones (clone system)** - DESIGN → Clones: mission-completion material
  harvesting, the pickup accumulator, clone keying + overwrite rule.
  Key: `src/handlers/level.zig` (end_level completion flow),
  `src/handlers/player.zig` (clone harvest math).
- **Gear upgrading** - DESIGN → Gear Upgrading: the upgrade economy
  (clone-derived income model, the two anchors, the cost ladder + α
  table, drops-as-pre-bought-rungs, the tier frontier), the hub vendor
  panel. Builds on DESIGN → Clones; implementation deferred (TODO →
  Gear Upgrading).
- **Post-game rewards & cosmetics** - DESIGN → Post-game Rewards &
  Cosmetics: the post-campaign material sink - central-hub decoration
  customization (buy-once-place-freely), weapon skins (per-type registry,
  item-flag unlocks incl. custom-mission-shipped art), the static tier
  price ladder, the saturating material-add guard. Low priority (TODO →
  Post-game Rewards & Cosmetics).
- **Architecture** - DESIGN → Architecture: Elm-like update/view, event
  stack, generic verbs vs skill recipes, orchestrator convention, arenas,
  PlayerData/Entity sync, level editor.
- **Decorations & footprint** - DESIGN → Decorations & Footprint: multi-tile
  props, footprint vs overhang, per-bbox-tile split + sort assignment,
  color, multi-sprite layers.
- **Entity & UI coloring** - DESIGN → Entity & UI Coloring: team gradients,
  entity color_index + layers, weapon/health-bar coloring, fixed UI palette.
- **Memory & budget** - DESIGN → Memory & Budget: arena backing, history
  residency, level caps, safety ceiling, asset-memory levers.
- **UI framework** - DESIGN → UI Framework: ViewState, flat UiElement list,
  Rect algebra, builders, text coloring + measurement seam.
- **Testing** - DESIGN → Testing: the four bug classes, tier conventions
  (inline pure-fn tests / handler drain tests via the harness / skill
  contracts / UI structure tests), assertion patterns (derived
  expectations, exhaustiveness properties, awkward values), deletion
  policy, the rejected coverage matrix. Working mechanics (test.sh,
  discovery, arena blind spots) stay in AGENTS → Build & Test. Key:
  `src/test_harness.zig`, `src/handler_tests_*.zig`, `src/skill_tests.zig`.
