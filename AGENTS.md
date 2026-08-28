# Ziglop

Zig 0.16.0 rewrite of a Unity tactical grid game (original at https://github.com/LinusWeggeHjalsted/taplop).

## Documentation

Four files, each with a clear job. Keep a fact in ONE place; never restate
settled decisions across files (that's how drift crept in before).

- **AGENTS.md** (this file) — the "how to work here" rules: build/test/commit
  workflow, code style, Zig gotchas, config format, the subsystem map. Single
  source of truth for working conventions. Read at the start of a session.
- **DESIGN.md** — settled subsystem design: architecture, invariants, the
  "why X is shaped this way." Read on demand when a task touches a
  subsystem's design, not every session. AGENTS points into it via the
  Subsystem Map below.
- **TODO.md** — active + near-term + deferred **tasks**, plus **open /
  undecided design questions** kept inline where they're being worked.
  Settled decisions do NOT live here — when a question settles, move the
  prose to DESIGN.md and leave a one-line pointer. Keeps it scannable.
- **DONE.md** — archive of completed work, resolved tech debt, and the
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
— it points (Subsystem Map below); DESIGN never restates a working rule — it
links to AGENTS.

> **Collaboration style** (small steps, pause at checkpoints, surface
> tradeoffs, clarifying questions, stay inside the cwd) lives in
> `~/.pi/agent/APPEND_SYSTEM.md` as cross-project working conventions.

## Build & Test

- `zig build` — compile the native (raylib desktop) exe
- `zig build run` — build and run the native client
- `zig build test` — run all tests (headless; must never link raylib)
- `scripts/test.sh` — `zig build test` with an unambiguous PASS/FAIL summary.
  Prefer this over raw `zig build test`: the raw runner can print a
  `failed command: .../test ...` line on SUCCESS (exit 0) whenever a test
  writes to stderr (advisory warnings, etc.), which looks like failure. The
  script labels advisory output `[advisory, non-fatal]`, surfaces only real
  failures, and prints a final `PASS (exit 0)` / `FAIL (exit N)`. **Trust the
  exit code, not the text.** Don't fish for test binaries in `.zig-cache/o/`
  to "check" — `find` races the build and returns stale binaries; the exit
  code is authoritative.
  `scripts/test.sh --raw` prints the full verbatim output if needed.
- OK to run these directly without asking

### Testing discipline (arena blind spots)

Most tests wrap in an `ArenaAllocator` for easy cleanup (every sub-allocation
freed at once on deinit). Arena-wrapping MASKS two classes of bug:
- **Leaks** — arena `free` is a no-op, so a forgotten `free` is invisible
  (the arena reclaims everything at deinit anyway). Under `testing.allocator`
  a forgotten free is a hard leak error.
- **Use-after-free** — arena free does nothing, so a dangling slice into
  "freed" memory stays mapped and returns stale-but-valid bytes (test passes
  silently). `testing.allocator` reclaims freed memory and may reuse it, but
  doesn't deterministically detect reads of freed memory.

**No `expectPanics` in Zig 0.16.** A fail-fast validation site (e.g.
`verifyReplayMatch`, `validatePlayerAction`) can't be unit-tested at the
panic path — `std.testing` has no `expectPanics`/`expectError` for panics
(only for `error` unions). The convention: split the legality **logic**
into a bool-returning helper (`isPlayerMoveLegal`, `skillOnBarAndOffCooldown`,
`skillTargetLegal`) and test THAT directly; the `validate*` wrapper that
formats a message + `@panic`s is a thin policy layer over it, not unit-tested
(the panic call is obvious + the bool helper is covered). This also separates
"is this legal" from "what do we do about it" — useful design discipline
independent of the test limitation.

So: once a loader is made self-owned (see DESIGN → File System & IO →
Settings ownership), its tests should run under `testing.allocator` (no
arena) so leak detection fires — this is the path that caught nothing for the
mangled-settings bug while arena-wrapped. The overlay-user-settings test in
`session_setup.zig` is the model: it builds self-owned defaults WITHOUT going
through `loadConfigWithFallback` (which intentionally leaks for process
lifetime and would flag under `testing.allocator`), then overlays + frees via
`freeSettings`, asserting no leaks. The use-after-free class is removed by
construction (owned strings, no borrows); the leak class is now catchable.

Loaders that still borrow into leaked bytes (levels, hubs, themes — not yet
self-owned) stay arena-wrapped; their ownership fix is the prerequisite for
leak-checked testing, deferred until a load change lands. `scripts/test.sh`
cleans `crashes/` before and after a passing run so a panicking test's crash
dump doesn't pollute the tree.

### Commit policy

- **Commit at each TODO slice checkoff.** The TODO slice boundaries are the
  natural commit units — each `[x]` is a unit that's done + tested + has a
  DONE.md entry. Committing at checkoff gives a clean, reversible baseline
  before the next slice starts (so breakages can be compared against it).
- **Commit locally without pushing.** Local commits are free; pushing is a
  separate step. Don't hold uncommitted work across sessions — 27 files of
  uncommitted changes across multiple sessions makes it impossible to tell
  whether a breakage is from the latest change or latent prior work.
- **Commit non-slice work as it happens.** Not every commit is a TODO slice —
  doc edits, tooling, quick fixes, and small refactors land on their own
  commit when the change is coherent and self-contained, rather than batching
  them into a pile to sort out later. A good unit is "one thing that builds
  and is done"; if a change has no DONE.md entry, the commit body is the
  record (see below).
- **Commit message: one line by default.** Shape: `<area>: <summary>` (e.g.
  `error handling: slice 1 — modal error popup surface`). `<area>` is the
  conceptual bucket (matches AGENTS.md sections / TODO items); `<summary>` is
  a single line, imperative mood, specific enough to distinguish from
  neighboring commits. The DONE.md entry is the detailed record; the commit
  message is the index — searchable in `git log --oneline`, then DONE.md for
  the why.
- **Body only when it adds information the DONE.md entry doesn't already
  carry.** The realistic cases: a bug-fix diagnosis (repro + root cause)
  before the DONE.md entry catches up; a commit that isn't a TODO slice and
  has no DONE.md entry (a quick fix, a reverted typo) — the body is the only
  record; a decision worth recording inline before it moves to AGENTS.md. If
  the DONE.md entry exists, the body is redundant — skip it. If there's no
  DONE.md entry, the body is the record — use it. The rule is self-policing:
  if you can't point to information the body adds beyond DONE.md, don't write
  one.
- **No conventional-commit prefixes** (`feat:`, `fix:`, `chore:`). There's no
  CI gate parsing them, no release-notes generation, no semver automation.
  The area name (`error handling:`, `editor:`) is more informative than a
  type tag and costs less typing.
- **Data-file edits from manual testing get reverted or committed separately.**
  A typo introduced to test the parser (`chracter_code`, `Metadta`) must not
  leak into a real code commit — it breaks tests and is indistinguishable from
  a real content change. Revert test artifacts before committing, or commit
  them with a `test:` prefix.
- Web build: a `wasm32-emscripten` exe reusing the SAME raylib backend +
  gameLoop as native (route B). `zig build web` produces zig-out/web/ziglop.html;
  `zig build emrun` serves + opens it. `scripts/web.sh` wraps both with
  emsdk-noise filtering (like `scripts/test.sh` does for tests) — prefer it
  over the raw commands. The old `wasm32-freestanding` + JS-renderer target
  was removed — do not reintroduce it.
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
  opens the page — the web build once sat broken for 136 commits this way
  (a `page_allocator` segfault landed with the TTF wiring and nothing
  surfaced it; see DONE.md, "Web black screen"). When a change touches the
  platform seam (`raylib_backend.zig`, `web.zig`, build.zig wiring, anything
  shader- or allocation-adjacent), spend the 30 seconds: `scripts/web.sh
  emrun` and confirm the main menu loads. Runtime web bugs can be debugged
  WITHOUT a browser: `node zig-out/web/ziglop.js` runs the emcc output
  headlessly — `std.debug.print` works there, so early-boot code paths
  (anything before GL/IDBFS init) can be probed like a native CLI. That
  technique diagnosed the 136-commit black screen entirely outside a
  browser.
- Test discovery is automatic: build.zig generates `src/generated_test_root.zig`
  (gitignored) importing every `src/**/*.zig`, and `addTest` uses it as root. Any
  `test` block in any src file is picked up with no manual wiring. Note this
  means the test build compiles the whole tree, including files main.zig may not
  reach directly. EXCEPTION: `native.zig` and `raylib_backend.zig` are excluded
  from the scan because they link raylib and the test build must stay headless.
  `web.zig` is also excluded (same reason).

## Code Style

- Verbose naming everywhere: `ScreenPosition` not `ScreenPos`, `index` not `idx`, `allocator` not `alloc`
- Multiline function signatures — one parameter per line when long
- All gameplay logic uses integers. Floats only for input, settings, rendering
- No abbreviations
- **Minimize `pub`.** Mark a symbol `pub` only if another file imports it;
  everything else is `fn`/`const` (file-private). The compiler errors on
  unused file-private symbols, so this turns it into a free dead-code detector.
  A `pub` symbol is presumed to be API — nothing flags an unused one — so
  dead `pub` scaffolding (`computeFrameLength`, `DecorationId`) can linger
  across redesigns. There is no Zig tool that reliably detects unused `pub`
  symbols; the discipline is the lever. If a symbol needs to be `pub` for a
  test (`test "..."` blocks in the same file can see file-private symbols, so
  this is rare), keep it `pub` but note why.

### Code Comments

Comments describe the code AS IT IS — never an imagined future state. This
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
  role: one short paragraph — what the file owns, key invariants — plus an
  `DESIGN → <section>` link where a settled design lives. `raylib_backend.zig`
  is the model. Skill/effect files are exempt: each is self-documenting via a
  `///` doc on its `pub const skill`/`pub const effect`.
- **`///` doc comments** on public types/fns/fields with non-obvious meaning:
  WHAT + WHY, not HOW.
- **Inline `//` only for the non-obvious** — a tricky invariant, a tiebreak
  convention, a "why this not the obvious thing". Not for restating what the
  next line does.
- **Link, don't restate settled decisions.** Instead of a 5-line inline
  explanation of the replay cache, write `// Reconstruction cache — see
  DESIGN → File System & IO`. Same single-source-of-truth rule as the .md
  files: the design lives in DESIGN.md, the code points at it.

## Config File Format

- `.txt` files with CamelCase section headers (whitelisted in parser.zig) and snake_case keys
- Values separated by space, can contain spaces: `player_name New Player`
- Blank lines separate entry groups within sections
- Enum values must match code exactly (lowercase)
- Layout sections are raw character grids, not key-value

## Zig 0.16 Gotchas

- ArrayList is unmanaged: `.empty`, pass allocator to each call
- ArrayList has no `.writer()` — use `.print(allocator, fmt, args)` and `.appendSlice(allocator, items)` directly
- PriorityQueue: `.empty`, `.push(allocator, item)`, `.pop()`, `.deinit(allocator)`
- Dir.writeFile takes an options struct: `.{ .sub_path = path, .data = data }`
- File I/O needs Io handle: `std.Io.Threaded.init(allocator, .{})`, `std.Io.Dir.cwd()`
- No `std.enums.count()` — use `@typeInfo(MyEnum)."@"enum".fields.len`
- No default parameter values — `fn f(x: i32 = 0)` is a compile error. Use
  a required param + callers pass the default, or an optional `?T` the
  caller fills with `null`.
- `///` doc comments are valid ONLY on declarations (top-level consts,
  fns, types, fields). Inside a function body it's always `//` — a `///`
  there is "expected statement, found a document comment".
- `opaque` is a reserved keyword (opaque types) — don't name a variable it.
- `std.heap.page_allocator` is UNUSABLE on wasm32-emscripten: on wasm it is
  BrkAllocator, which grows memory via the raw `@wasmMemoryGrow` intrinsic
  behind emscripten's back — the JS heap views detach and SAFE_HEAP bounds
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
- The BINDING ships in `data/default_settings.txt` regardless (so the
  settings file stays the source of truth and a future binding-UI sees one
  set). The gate is at the HANDLER site (`if (build_info.dev_mode and ...)`),
  so in a non-dev build the binding parses + maps to a `PlayerInput` flag but
  the flag is never consumed — a no-op. `translateInput` stays build-agnostic
  (pure binding→action); policy lives in the consumption layer.
- `skip_level` (ctrl+Enter): an idle input (`IdleInput.skip_level`) handled
  in `handleIdleInput`. Pushes `end_level` with the default continuation —
  the normal next-level / mission-end cascade (same path the options-menu
  exit uses). Level-only (`current.screen == .level`); `handleIdleInput`
  only runs with an empty stack + no active wait, so it never interleaves
  with a draining enemy turn. Replay-safe by construction (a normal recorded
  event). See DESIGN → Input (hybrid precedence) for why ctrl+Enter doesn't
  also fire the plain-Enter `confirm`/`dismiss_error` bindings.

## Key Files

- `src/main.zig` — platform-agnostic composition root: the uncapped game
  loop (`gameLoop`/`run`), the per-iteration `update` step that ties input +
  event processing together, and the round-trip reconstruction test. Config
  loading lives in `session_setup.zig` (raylib-free).
- `src/session_setup.zig` — session startup: loading all config (settings,
  color themes, weapon types, salvage tables) + `SessionSetup`/
  `createSessionSetup`/`fixupPointers` + `FrameState`. The entry files
  (`native.zig`/`web.zig`) call `createSessionSetup` then hand the result to
  `main.run`/`main.frame`.
- `src/test_harness.zig` — reusable harness for `processEvent` handler tests
  (`Harness.init` + `newHistory` + `runToIdle`); test build only.
- `src/event_handlers.zig` — `processEvent` (the one-event dispatch + all
  handler arms) and handler-internal helpers (entity accessors, gear mutators,
  move-highlight refresh, prepared-skill cancel, AI min-range, tile tiebreak).
  Also the event-pushing utilities (`pushEvents`/`pushPlayerSkillUse`) shared
  with the input handlers. (The round-trip reconstruction test lives in
  `main.zig`.)
- `src/input_handlers.zig` — input consumption: `handleAnytimeInput`,
  `handleIdleInput`, `resolveTileCursor`, the drag lifecycle, and session-log
  dev tooling (dumpEventLog, build-version warn, timestamp formatter). The
  dragToEvent test lives here.
- `src/view.zig` — `view()` (builds ViewState each frame from GameState +
  SessionState + the per-frame arena) + world drawable builders (tiles,
  overlays, entities, decoration pieces, ground items, flag poles, occlusion
  insets, health bars) + camera math (computeCamera, tileToScreen) +
  sprite/flag frame/pivot constants.
- `src/native.zig` — native exe entry (raylib); `src/web.zig` — web (emscripten)
  exe entry (IDBFS persistence + emscripten main-loop driver);
  `src/raylib_backend.zig` — raylib window/clock/input/render backend (see DESIGN → Platform Seam)
- `src/state.zig` — GameState, GameStateHistory (+ SessionState, undo/redo/
  replay timeline: recordEvent/discardFutureTimeline/replayTo/
  reconstructFromEventLog/validatePlayerAction), Screen
- `src/types.zig` — all game data types, Entity with getEffective* methods
- `src/events.zig` — event hierarchy (Meta, Super, Player, Level, SubLevel,
  Editor, PlayerInput, ReplayViewer categories)
- `src/parser.zig` — generic config-file format layer: `Section`/
  `EntryGroup`/`KeyValuePair` types, `parseConfigFile`, section/key
  whitelists + `validateSections`/`validateFileFormatVersion`/
  `validateKeys`, value coercion (`asU32`/`asBool`/`asColor`/`parseEnum`),
  `findSection`/`findValue`, and the shared `file_format_version`
  constants. The format layer the other three build on.
- `src/loaders.zig` — game-content loaders (config sections → typed
  `types.*`): `loadLevel`/`loadHub`/`loadMission`/`loadCampaign`/
  `loadPlayerSave`/`loadSettings`/`loadWeaponTypeDefinition`/
  `loadColorThemeDefinitions`/`loadSalvageDefinitions`/`loadDecorationRegistry`/
  `loadPlayerLoadout`, decoration footprint/anchor validation, editor dedup
  (`buildEditorMission`)/instantiation (`instantiateEditorLevel`), the
  `free*`/`clone*`/equality helpers, balance bounds (`boundedU32`/`max_*`),
  custom-sprite PNG dim resolution.
- `src/writers.zig` — save/settings writers (typed objects → config text):
  `writePlayerSave`/`writeSettings`/`writePlayerSaveToFile`. The inverse of
  `loaders.zig`.
- `src/session_log.zig` — session-log serializer/deserializer
  (`writeEventLog`/`loadEventLog`/`SessionLog`), comptime-generic over the
  `Event` union. See DESIGN → Logging & Replay.
- `src/functions.zig` — pathfinding (A*), chebyshevDistance, helpers
- `src/ui.zig` — UiState, UiElement types, layout helpers (Rect algebra, Row/Grid), panel builders
- `src/input.zig` — input pipeline, translateInput, bindings
- `src/combat_log.zig` — combat-log projection (projectCombatLog + combatLogTier)
- `src/file_source.zig` — unified file I/O (FileSource: embedded map +
  persistent dir + future VFS; see DESIGN → File System & IO)
- `src/content_hash.zig` — mission content identity (SHA-256 over the
  mission's config files; see DESIGN → Custom Missions & Online Services → Content
  identity). v1 hashes config files only; extends to custom assets when the
  VFS lands with directory listing.
- `src/crash_dump.zig` — custom panic namespace installed in both entry files;
  dumps `event_history` to `crashes/crash_*.txt` before `@trap`. See
  DESIGN → Error Handling → Crash dump.
- `src/deep_copy.zig` — comptime-generic `deepCopy`/`deepEqual`/
  `firstDiffField` over GameState + Event; `deepEqual` backs replay
  verification (`verifyReplayMatch`). See DESIGN → Determinism & Tiebreaking.
- `src/tween.zig` — pure easing fns (`easeOutCubic`); read by `view()` for
  one-shot anim interpolation. See DESIGN → Animation.
- `src/skills/` — one file per skill, Skill interface
- `src/effects/` — Effect interface with 18 callbacks (interception +
  on-effect/turn/attack hooks + outgoing/incoming pairs for damage/stun/effect/
  knockback/collision + onRetreat + onOpponentDeath)

## Subsystem Map

One line per subsystem, pointing into DESIGN.md (settled design) and the key
source file(s). Read DESIGN → <section> when a task touches that subsystem.
Working rules (build/test/commit, code style, Zig gotchas, config format)
stay here in AGENTS; this map is the seam between the two.

- **Platform seam (raylib)** — DESIGN → Platform Seam (raylib): native/web
  driver split, budget-driven drain, render gating, letterbox, two-camera
  model, camera pan, SDF text outline, allocator rule for emscripten. Key:
  `raylib_backend.zig`, `native.zig`, `web.zig`, `transient_allocator.zig`,
  `tools/sdf_atlas_generator.zig`.
- **Audio** — DESIGN → Audio: sound as side effect, sfx queue + looping music
  stream, button press/release model, backend cache + init-order gotchas.
- **Animation** — DESIGN → Animation: looping vs one-shot anims, the
  replay-purity invariant (clock read in `frame()` only), animation clock,
  frame rate.
- **Replay & side effects** — DESIGN → Replay & Side Effects: pure state
  transforms in handlers, side effects gated `!replaying`, transient state
  off GameState, undo mid-drain.
- **Versioning** — DESIGN → Versioning: `game_version` (advisory) vs
  `file_format_version` (hard gate); per-type constants in parser.zig.
- **Logging & replay** — DESIGN → Logging & Replay: one log
  (`event_history`), session dump, combat-log projection, reconstruction.
- **Determinism & tiebreaking** — DESIGN → Determinism & Tiebreaking:
  natural-stack replay verification, player-action legality validation,
  explicit tiebreak conventions.
- **Input** — DESIGN → Input: modifier-subset binding match, engine-owned
  key repeat, settings persistence + binding overlay, debounced writes.
- **Error handling** — DESIGN → Error Handling: unrecoverable vs
  recoverable, the popup surface, three recoverable contexts, B-simple
  recording, crash dump.
- **File system & IO** — DESIGN → File System & IO: single-file exe,
  FileSource (VFS/persistent/embedded), embedding, persistent path, raylib
  seam, settings ownership, reconstruction cache.
- **Custom missions & online services** — DESIGN → Custom Missions & Online
  Services: dreams, browser, content identity/hash, balance bounds, turn
  counters + author medals, auth/server seam.
- **Architecture** — DESIGN → Architecture: Elm-like update/view, event
  stack, generic verbs vs skill recipes, orchestrator convention, arenas,
  PlayerData/Entity sync, level editor.
- **Decorations & footprint** — DESIGN → Decorations & Footprint: multi-tile
  props, footprint vs overhang, per-bbox-tile split + sort assignment,
  color, multi-sprite layers.
- **Entity & UI coloring** — DESIGN → Entity & UI Coloring: team gradients,
  entity color_index + layers, weapon/health-bar coloring, fixed UI palette.
- **Memory & budget** — DESIGN → Memory & Budget: arena backing, history
  residency, level caps, safety ceiling, asset-memory levers.
- **UI framework** — DESIGN → UI Framework: ViewState, flat UiElement list,
  Rect algebra, builders, text coloring + measurement seam.
