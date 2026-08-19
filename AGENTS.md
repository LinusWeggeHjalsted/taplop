# Ziglop

Zig 0.16.0 rewrite of a Unity tactical grid game (original at ~/Development/taplop).

## Project Tracking

- `TODO.txt` is the running task list / roadmap. Read it at the start of a
  session and keep it updated as work lands (check off items, add follow-ups).

## Collaboration

- Work in small steps. Before editing, propose the approach and wait for approval.
- Pause at natural checkpoints to discuss design decisions instead of
  implementing an entire feature in one go.
- Prefer surfacing tradeoffs for discussion over silently picking one and running.
- Stay inside the current working directory. Before reading, searching, or
  otherwise accessing anything outside it, ask first and give a reason. Scope
  commands (rg/find/etc.) to the project so they can't wander into system files.

## Build & Test

- `zig build` — compile the native (raylib desktop) exe
- `zig build run` — build and run the native client
- `zig build test` — run all tests (headless; must never link raylib)
- OK to run these directly without asking
- Web build: a `wasm32-emscripten` exe reusing the SAME raylib backend +
  gameLoop as native (route B). `zig build web` produces zig-out/web/ziglop.html;
  `zig build emrun` serves + opens it. The old `wasm32-freestanding` +
  JS-renderer target was removed — do not reintroduce it.
- WEB BUILD NEEDS A PATCHED STDLIB: Zig 0.16.0's std/os/emscripten.zig has a
  bug (W.STOPSIG declared to return u32 but body returns the SIG enum) that
  breaks emscripten compilation. The fix is upstream on the 0.16.x branch
  (STOPSIG -> SIG). We carry it locally by copying /usr/lib/zig to
  ~/.local/zig-patched-lib, applying the one-line fix, and running the web
  build with `ZIG_LIB_DIR=~/.local/zig-patched-lib zig build web`. Native +
  tests use the normal zig (no env var). When 0.16.1 ships and Arch packages
  it, the patched copy becomes unnecessary.
- Test discovery is automatic: build.zig generates `src/generated_test_root.zig`
  (gitignored) importing every `src/**/*.zig`, and `addTest` uses it as root. Any
  `test` block in any src file is picked up with no manual wiring. Note this
  means the test build compiles the whole tree, including files main.zig may not
  reach directly. EXCEPTION: `native.zig` and `raylib_backend.zig` are excluded
  from the scan because they link raylib and the test build must stay headless.
  `web.zig` is also excluded (same reason).

## Platform Seam (raylib)

- raylib is linked ONLY into the native exe. Keep it out of the test build (and
  the future emscripten build's shared code) by never importing raylib from any
  file the test-root scan pulls in.
- `src/main.zig` stays raylib-free. The game loop is platform-agnostic and
  SPLIT into a shared per-frame core + a thin platform driver:
  - `frame(backend, *FrameState)` is the deterministic core: poll input,
    compute camera, drain events up to a 10ms budget (see below), maybe
    render. NEVER yields/sleeps — scheduling is the driver's job. Called by
    BOTH platforms, so gameplay outcome is identical across native and web
    (event order + real-clock wait deltas match; only wall-clock drain
    duration differs).
  - `gameLoop(...)` is the NATIVE driver: a blocking `while (!shouldClose())`
    that calls `frame()` each iteration and yields (`backend.waitTime(0.1ms)`)
    when idle. The WEB driver (web.zig) replaces this with
    `emscripten_set_main_loop_arg(callback, ...)` — the browser schedules rAFs
    and handles yielding, so no sleep/asyncify.
  - `FrameState` holds the per-session mutable state that lives across frames:
    `history`, `previous_view_state`, `frame_arena`, `last_render_time`.
  The backend is duck-typed with `shouldClose()`, `deltaMicroseconds()`,
  `pollInput() PlatformInput`, `render(ViewState, ViewportSize)`, plus timing
  helpers (`realClockMicroseconds`, `renderIntervalMicroseconds`, `waitTime`,
  `applyVsync`). Entry is `pub fn run(backend, allocator, file_source, io)`.
- The drain is BUDGET-DRIVEN: `frame()` calls `update()` repeatedly while the
  stack is non-empty, no wait is active, and <10ms has elapsed — so a
  multi-event drain completes within a single frame instead of one event per
  iteration (the old shape). This keeps web responsive (a 100-event drain
  would otherwise take 100 rAFs ≈ 1.6s) and improves native too (the window
  stays responsive during a big drain instead of blocking the main thread).
  Rendering is gated to a real-clock interval (vsync → monitor refresh rate,
  or 1/render_fps_cap, or 0 = uncapped) and SKIPPED while a drain is in
  progress (stack non-empty, no wait): vsync (`swapScreenBuffer`) blocks the
  thread for a full refresh, so rendering every drain iteration would
  frame-lock the drain. We render only when the drain completes (stack
  empties) or pauses (a wait is active). Gameplay logic drains as fast as the
  CPU allows between renders; waits use real-clock deltas (`rl.getTime`, not
  `getFrameTime`) so turn-flow pacing is framerate-independent. The native
  driver's idle/wait yield (`waitTime(0.1ms)` when the stack is empty OR a
  wait is active) avoids 100% CPU spin while keeping ~0.1ms input latency;
  the web driver doesn't yield (the browser's rAF IS the yield).
  CAVEAT: a very long non-wait drain (thousands of events) would show nothing
  until it ends — not a concern for current workloads; revisit if a long-drain
  feature lands (see TODO PACING).
- `pollInput()` reads edges FIRST, then pumps (`rl.pollInputEvents()` after).
  raylib's PollInputEvents copies `previous = current`; on web, events arrive
  async via JS callbacks between frames (current is already set on entry), so
  pumping before reading would erase the edge (current == previous → no
  press detected). Read-then-pump works on both platforms (native gets ~1
  iteration of latency at the uncapped speed, negligible).
- `src/raylib_backend.zig` is the ONLY file that `@import("raylib")` (plus
  `native.zig` and `web.zig`, which import the backend). It owns the window, the real-clock
  (`rl.getTime` → microseconds for deltas + render gating), input polling
  (`pollInputEvents` each poll, independent of rendering), and rendering. Built
  with `SUPPORT_CUSTOM_FRAME_CONTROL` so `endDrawing()` only flushes the render
  batch — we call `swapScreenBuffer()` (vsync paces there) and `pollInputEvents()`
  ourselves, so the uncapped loop owns event polling. Without this,
  `endDrawing()`'s built-in `PollInputEvents` eats input events that accumulate
  during the vsync block (lost clicks).
- Rendering: all content is authored in the reference resolution
  (`types.reference_width` x `reference_height`). render() draws it 1:1 into a
  reference-sized `RenderTexture`, then blits that to the window LETTERBOXED
  (aspect-preserving, centered). Element `Color` is passed as raylib's
  DrawTexturePro tint — that multiply IS the grayscale×color theming path.
  Textures are lazy-loaded from `assets/<sprite_id>.png` and cached; MISSING art
  draws a magenta box (dev-friendly) instead of failing fast — the one place we
  deliberately don't panic, since absent art is a normal in-progress state.
- The reference↔window letterbox transform lives in one place
  (`viewTransform()`): render() uses it to blit, pollInput() inverts it to map
  the pointer back into reference space. Keep them in sync via that helper.
- `src/native.zig` is the native exe root (`pub fn main`): sets up allocator/IO/
  window/persistent-dir, then calls `main.run` with a `RaylibBackend`. Drives
  the shared `frame()` via a blocking while-loop (the native driver).
- `src/web.zig` is the web (emscripten) exe root: mirrors native but mounts
  IDBFS at /ziglop for persistence and drives `frame()` via
  `emscripten_set_main_loop_arg` (the browser schedules rAFs; no sleep/yield,
  no asyncify). See "Web build" under Build & Test above for the patched-stdlib
  workflow.
- All three raylib-linked files (`native.zig`, `web.zig`, `raylib_backend.zig`)
  are excluded from the test-root scan in `build.zig` (`collectZigFiles`). If
  you add another raylib-linked file, exclude it too.
- raylib key ids are emitted in Web `KeyboardEvent.code` form (`KeyZ`, `Escape`,
  `Digit1`, `ControlLeft`, ...) to match `data/settings.txt` bindings.
- Coordinate space: `pollInput` reports the viewport AS the reference
  resolution and maps the pointer into reference space (inverse letterbox), so
  the whole game — UI hit-testing and screenToTile alike — works in reference
  coordinates.
- `build.zig` also generates `src/generated_lookups.zig` and the `generated`
  module (SkillId/EffectId enums) by scanning `src/skills/` and `src/effects/`

## Replay & Side Effects

- Undo/redo reconstruct past states by replaying the event history through
  `processEvent` (see `GameStateHistory.replayTo`). `history.replaying` is true
  during this.
- Event handlers must run **pure state transforms unconditionally**, but gate
  **observable side effects** (file writes/downloads, audio, dialogs) on
  `if (history.replaying) return;` so scrubbing history doesn't re-fire them.
- **Reconstruction reads** (level/hub/save config loads in start_level/
  start_hub/load_save) still run during replay — the rebuilt state depends on
  their contents. On web these are asset fetches, not user dialogs.
- The `wait` event already satisfies this by construction (it lives in
  `update()`, which replay bypasses).
- **All undoable gameplay state is mutated only inside event handlers.** Replay
  rebuilds state by re-running events, so a direct write in the input/update
  path (`handleIdleInput`, `handleAnytimeInput`, `gameLoop`) is NOT reproduced
  and the reconstructed state silently diverges. To change gameplay state, push
  and handle an event (e.g. `clear_highlights`, `clear_prepared_skill`, and
  `turn_end` owning `turn_phase = null`). Helpers like `refreshMoveHighlights` /
  `cancelPreparedSkill` write directly ONLY because they are called exclusively
  from event handlers, so they already run during replay.
- **Transient view/input state lives off the undoable GameState.**
  `state.SessionState` (`input_state`, `ui_state`, `tile_cursor`) hangs on
  `GameStateHistory` next to `settings` — never deep-copied into snapshots,
  never touched by replay. Clean rule: **in `GameState` → change via events; in
  `SessionState` → change directly in the input/update path.** The screen-
  transition UI reset lives in the live loop (`gameLoop` clears
  `session.ui_state` when `screen` changes across `update()`, covering both
  event transitions and undo/redo across a screen boundary), NOT in
  `transitionScreen`. `input_state` is never reset — it is live hardware
  state. `tile_cursor` is the logical cursor (mouse or arrow-key driven);
  `auto_target_at_cursor` reads it in the input path, and the resulting
  `player_use_skill` event is what replay reproduces — the cursor value at
  prepare-time is never needed for reconstruction, so it's safe off GameState.
  Resolved per-frame in `update()` (`resolveTileCursor`): mouse-move drives it
  (with UI occlusion + tile validity), arrow keys nudge when the mouse is idle
  (snapping to the player tile if null).
- **Replay must not create events; new actions branch the timeline.**
  `processEvent` records into `event_history` only when `!replaying` (via
  `GameStateHistory.recordEvent`); the event index still advances so
  `replayTo`'s loop progresses. Taking a new action after an undo discards the
  stale future first (`discardFutureTimeline`: trims `event_history` +
  `idle_points`, frees snapshots/checkpoints ahead of the branch), so the new
  action continues a fresh timeline from the undone position.

## Versioning

- `game_version` is the runtime "which build" stamp: `YYYY.MM.<commits-this-
  month>[-dirty]`, computed in `build.zig` (`computeGameVersion`) from the
  build clock + git and exposed to code via `@import("build_info").game_version`
  (a `b.addOptions` module wired onto BOTH the exe and test root modules).
  Git is optional/build-time-only (never a runtime dependency — the string is
  baked in): git ran → real count (a true `.0` is legitimate) plus `-dirty` on
  a modified tree; git absent/no repo → `YYYY.MM.unofficial`.
- `game_version` is ADVISORY: recorded into artifacts and warn-on-mismatch, not
  a hard gate (a hard replay-validity guarantee would need content-hashing the
  gameplay logic — future work). It is NOT `build.zig.zon` `.version`, which
  stays a static, vestigial package-identity `0.0.0`.
- Two orthogonal versions, both recorded in serialized artifacts:
  `file_format_version` (monotonic int per artifact, in its `Metadata` section)
  answers "can this parser read the file?"; `game_version` answers "will a
  correctly-parsed file behave in this build?".

## Logging & Replay

(session-log read/write/reconstruct is built; combat log + replay-viewer UI
still TODO)

- There is ONE log: `event_history` (see Replay & Side Effects). The session
  dump, the combat log, and the future replay viewer are all it plus
  projections — not separate capture systems.
- Session dump (ctrl+L → `dump_event_log` → `main.dumpEventLog`): serialize
  `event_history` to config format via `parser.writeEventLog` — a
  comptime-generic serializer over the `Event` union (lives in parser.zig with
  the other writers; new events need no changes). `Metadata` header carries
  file_format_version + game_version + created timestamp; an `EventLog` section
  holds one entry group per event (`event <category> <variant>` discriminator +
  one line per payload field; optionals omit their line when null;
  Vector2/Materials/slices space-separated). Events alone reproduce a session —
  do NOT also log player input (the input→event translation is deterministic
  and would be redundant/divergent).
- Reader: `parser.loadEventLog(sections)` → `SessionLog { file_format_version,
  game_version, created, events }`, the comptime-generic inverse.
  file_format_version is a HARD gate; game_version is advisory (caller warns via
  `main.warnIfSessionLogFromDifferentBuild`).
- Reload does NOT re-drive events through the input path. `event_history` is the
  fully-linearized event stream; `GameStateHistory.reconstructFromEventLog`
  deep-copies the loaded events into `history_arena` and drives the existing
  `replayTo`/`restoreTo` machinery (which forces each recorded event onto the
  stack in turn, discarding handler-pushed sub-events since those were
  themselves recorded). `idle_points` are NOT serialized — step boundaries are
  derived, not stored. The `runToIdle` + `reconstructFromEventLog` end-to-end
  test (main.zig) proves forward play == replay.
- Combat log = a filtered PROJECTION of `event_history` (leaning: derive on
  demand, do NOT store on GameState — deletes the `CombatLogEntry`-on-`Level`
  scaffolding rather than filling it). The replay viewer steps over the SAME
  filter, so one whitelist drives both the combat-log UI and replay stepping.
  Coarse (one entry per skill use) vs granular (skill + each consequence:
  attack/death/stun/…) projection is still UNDECIDED.

## Determinism & Tiebreaking

- Replay does NOT require the engine's decision logic to be deterministic:
  `replayTo` forces each RECORDED event onto the stack and discards
  handler-pushed events, so AI/sort/targeting decisions are already
  crystallized as recorded events (see Logging & Replay). Determinism still
  matters for DEFINED behavior in live play and for any future input-based
  replay (speedrun verification) — so make ordering explicit regardless.
- Tiebreaking convention — every ordering/selection over equal keys must break
  ties EXPLICITLY (in the comparator) or by a documented scan order:
  - Entities: ascending `entity_index`.
  - Tiles: ascending `(x, y)` (A* `comparePathNodes` already does this).
  - Skills: slot order.
- `std.mem.sort` is UNSTABLE: a distance/priority-only comparator leaves equal
  elements in an arbitrary order — always add the secondary key (e.g. `turn_end`
  enemy ordering breaks distance ties by `entity_index`). A strict `<`/`>`
  accumulation loop that iterates in the convention's order already yields the
  right tiebreak (lowest entity_index / first slot); document it with a comment
  rather than restructuring.

## Error Handling

- Errors here are effectively unrecoverable (OOM, startup file/parse failure,
  broken invariants). Fail fast: `catch @panic("descriptive message")`.
- Never silently swallow (`catch {}`) — a dropped result becomes a confusing
  silent bug; a panic points at the exact failure. Same spirit as the
  intentional `current.level.?` invariant unwraps.
- Allocation panics are written inline (e.g. `catch @panic("failed to append
  event")`); no shared helper for now.
- Revisit only if a logging layer lands: truly cosmetic per-frame failures
  could then degrade-with-log instead of crashing — but never silently.

## Code Style

- Verbose naming everywhere: `ScreenPosition` not `ScreenPos`, `index` not `idx`, `allocator` not `alloc`
- Multiline function signatures — one parameter per line when long
- All gameplay logic uses integers. Floats only for input, settings, rendering
- No abbreviations

## File System & IO

The game ships as a SINGLE-FILE executable: all `data/` + `assets/` content is
embedded into the binary at build time. It runs from anywhere regardless of
the current working directory. Writable artifacts (saves, session logs, future
replays/custom missions) live in a persistent data directory, also independent
of cwd.

### File source (one unified source, session-resident)

ALL content + artifact reads go through ONE `FileSource` object living on
`GameStateHistory` next to `settings` (never deep-copied into snapshots,
never touched by replay). It exposes:
  - `readFile(allocator, path) -> []const u8` — reads against a normalized
    project-root-relative path (`"data/settings.txt"`, `"assets/world/tile.png"`).
  - `writeFile(path, bytes)` — writes to the persistent dir ONLY; rejects
    `data/`/`assets/` prefixes with a panic (shipped content is immutable
    from the game's perspective).

Read order (first hit wins):
  1. in-memory VFS — uploaded zips / fetched custom missions (transient; lands
     when custom-mission support does)
  2. persistent dir — `~/.ziglop/`
  3. embedded map — `data/**` + `assets/**` baked into the exe at build time

A read of a shipped path with no persistent/VFS override hits layer 3. A read
of a save/log hits layer 2 (misses VFS + embedded). A read of a custom mission
hits layer 1 (VFS) or 2 (persisted custom_missions/), depending on how it was
acquired.

### Embedding

`build.zig` walks `data/` + `assets/` and emits `src/generated_assets.zig`
(gitignored, like `generated_lookups.zig` / `generated_test_root.zig`) with one
`@embedFile` entry per file, assembled into a
`std.StaticStringMap([]const u8).initComptime` map keyed by project-root-
relative paths. The build step re-runs every `zig build`, so new files are
picked up automatically; *content* edits to existing files require a recompile
(which `zig build run` does anyway). `@embedFile` paths are relative to the
emitted file's location (`src/`), so the generated entries use `../data/...` /
`../assets/...` — owned by the build step, not a caller concern.

### Persistent path

Default: `~/.ziglop/` (dotfile in `$HOME`, NOT XDG — chosen for player-
discoverability of saves/custom content over convention). Holds `autosave.txt`,
`saves/`, `logs/`, future `replays/` and `custom_missions/`. Overridable via
`--data-dir` flag / `$ZIGLOP_DATA` env var (dev, portable installs, tests);
the flag wins over the env var, which wins over the default. For dev work,
prefer `zig build run -- --data-dir <scratch-dir>` so session logs and
autosaves don't mix into your real `~/.ziglop/` play data.
macOS/Windows native paths are DEFERRED but the abstraction does not paint
us into a corner: each backend just builds the source differently in its
entry file. Web (emscripten) is WIRED: web.zig mounts an IDBFS slice at
/ziglop (IndexedDB-backed, survives browser close) and builds FileSource on
that dir — same read/write code path as native, just a different dir source.

### Raylib seam

`raylib_backend.zig` stays the ONLY file that `@import("raylib")`. The texture
cache switches from `rl.loadTexture("assets/{s}.png")` (filesystem) to
`rl.loadImageFromMemory(".png", bytes)` from `FileSource.readFile` →
`rl.loadTextureFromImage` → `rl.unloadImage`. The backend asks the source for
bytes; it never touches the filesystem directly. Same pattern holds for audio
later (`loadMusicStreamFromMemory` / `loadSoundFromWave`).

`native.zig` computes the persistent path (XDG override / flag / env / default),
constructs the `FileSource`, and passes it into `main.run`. `main.zig` and all
game logic stay path-agnostic.

### Modding by shadowing (side effect, not a designed feature)

Because the read order checks the persistent dir BEFORE the embedded map, a
player can drop a file at `~/.ziglop/<shipped-path>` to shadow shipped
content, or add new paths (e.g. `~/.ziglop/assets/weapons/my_new_sword.png`)
for new sprites/campaigns. This is a side effect of the unified-source
layering, NOT a designed modding feature: no policy on which paths are
overridable, no verification, no safe-mode flag. It's accepted as-is for now;
revisit and add structure (override policy, verification, a disable-for-
troubleshooting flag) only if modding becomes a real goal.

### Migration (in flight)

Today every read/write is a relative path against `std.Io.Dir.cwd()` stored on
`GameStateHistory` as `history.directory` + `history.io`, passed in from
`native.zig`. The migration replaces that pair with a `FileSource` and swaps
every call site (~15 sites across `main.zig`, `event_handlers.zig`,
`input_handlers.zig`, `parser.zig`, `raylib_backend.zig`). Parser tests that
currently do `Dir.cwd()` + read `data/...` from disk switch to the source
(embedded), which also makes the test build hermetic.

## Config File Format

- `.txt` files with CamelCase section headers (whitelisted in parser.zig) and snake_case keys
- Values separated by space, can contain spaces: `player_name New Player`
- Blank lines separate entry groups within sections
- Enum values must match code exactly (lowercase)
- Layout sections are raw character grids, not key-value

## Architecture

- Elm-like: main (init), update (state transform), view (render)
- Event stack (LIFO) on GameState, processed one at a time. When empty, waits for player input
- **Events are generic state-mutation verbs, not skills.** Each event mutates
  one dimension of entity/level state (health: `attack`/`heal`; momentum:
  `change_momentum`; cooldowns: `change_cooldown`; position: `move_entity`/
  `swap_positions`/`knockback`/`retreat`; status: `stun`/`create_effect`/
  `end_effect`; world: `aggro_around`/`pickup_around`/`death`) — a basis set
  over the mutable fields. A skill is a recipe: its `useSkill` computes and
  emits a sequence of these generic events. All skill-specific cleverness
  (conditionals, multipliers, radius loops) lives in `useSkill`, never in a new
  event. Only add a new event when a skill must mutate a state dimension no
  existing event covers; prefer composing existing primitives. Reactive
  mechanics (e.g. Reflect) belong in the effect system, not as skill events.
  Scalar-field primitives clamp (heal to max_health; momentum/cooldown at 0 via
  functions.applySignedDelta)
- **One top-level event per player action (orchestrator convention).** Each
  player input (`handleIdleInput`) pushes exactly ONE top-level event; if the
  action needs several verbs, the event is an orchestrator whose handler
  pushes them (e.g. `player_move_action` -> `player_turn_attack` +
  `clear_highlights` + `move_entity`). This keeps the recorded `event_history`
  one-entry-per-action so a loaded session derives idle points purely from
  VIRTUAL STACK DEPTH during reconstruction (see `replayToWithIdleTracking` in
  state.zig): sibling batches can't be distinguished from drains in the flat
  stream, so they must funnel through a single orchestrator. Bonus: undo
  granularity matches a single click/key. Orchestrators carry only the
  player's intent; all mutation is in the verbs they push.
- Arena allocation for game state snapshots/checkpoints. Deep copy via comptime reflection
- Allocator model (all on `GameStateHistory`, see state.zig): `backing_allocator`
  is the gpa backing every arena. Two live lifetimes: `history_arena` — durable,
  unbounded, backs the append-only session log (`event_history` + `idle_points`)
  and holds deep-copied event payloads (event slices are the replay source of
  truth, so they must outlive `current_arena` resets); `current_arena` — owns
  all memory referenced by `current_state`, compacted at each idle point
  (`compactCurrentArena`: deepCopy into a fresh arena, free the old) so per-turn
  churn and exited levels/hubs are reclaimed. `processEvent` and the input
  handlers get their state allocator from `current_arena`; durable recording
  goes through `history.recordEvent` into `history_arena`. Never allocate live
  gameplay state into the gpa directly — it won't be reclaimed or replayed.
- Screen enum is authoritative for "where are we" — transitionScreen() handles cleanup
- PlayerData is persistent, Entity is the in-level/hub working copy. Synced via build_player_from_data / build_data_from_player events
- Player is always entity index 0
- SkillId/EffectId are comptime enums generated by build.zig from file names
- CampaignId/HubId/MissionId are runtime strings (folder names)
- Mid-turn equipment/skill changes must re-apply their side effects: boots
  change → recompute reachable tiles (`refreshMoveHighlights`); weapon change
  (swap or equip) → cancel any prepared skill (`cancelPreparedSkill`), since it
  rewrites the first three skill slots. Gear equip/unequip routes both through
  `applyGearChangeSideEffects`
- `end_level` / `end_hub` are the mandatory "leaving" lifecycle events and own
  the entity->PlayerData sync (they push `build_data_from_player{0}` on top,
  which runs while the old world is still live — before `start_level`/
  `start_mission` replaces it). Every path that leaves a level/hub MUST route
  through them, or entity changes (gear/inventory picked up in the world) are
  lost. Reverse direction (`build_player_from_data`) is pushed by `start_level`/
  `start_hub` after loading. (Note: `end_hub` used to be a no-op; the hub
  mission-exit path now pushes it before `start_mission`.)
- Gear operations use the `GearSlot` enum (types.zig). `equip_item` no-ops on
  type mismatch; `unequip_item` moves into an empty inventory slot, swaps on a
  matching filled slot, and no-ops on mismatch
- `equipped_utility_skills` is `[utility_skill_count]?SkillId` (nullable slots).
  Save format keys each filled slot by number (`slot_4`..`slot_8`); empty slots
  are omitted and reload to null — never compact/reindex on load
- Derived-from-entity data has a single source of truth: skill-bar slot
  resolution lives in `Entity.skillInSlot` / `Entity.collectSkillSlots`, not
  duplicated per caller
- `current.level.?` (and similar) force-unwraps in level/sub-level event
  handlers are intentional invariant assertions (those events only run in a
  level; the event stack is cleared on screen transition). Prefer fail-fast
  over silently returning, which would hide the logic bug the unwrap catches

## UI Framework

- `view()` builds a `ViewState` each render from a per-frame arena (reset every frame in the game loop); everything the ViewState points at lives until the next frame
- UI is a flat `[]const UiElement` (tagged union: nine_slice_panel, slot, button, text_label, fill_sprite, image), appended in back-to-front draw order — no sorting
- Builders (`buildBottomBar`, etc. in ui.zig) take a `bounds: Rectangle` and append into a shared `std.ArrayList(UiElement)`; everything positions relative to `bounds`
- Layout is Rect algebra: `Rectangle` has pure methods (`position/right/bottom/centerX/centerY`, `translate`, `inset`, and 3×3 `place*` anchors like `placeCenter`, `placeBottomCenter`, `placeCenterRight`). Plus `screenRect()`, `rowWidth()`, `Row`, `Grid` helpers in ui.zig
- Screen-space dimensions (widths/heights/sizes/offsets) are `i32` (rendering, not gameplay). Gameplay quantities (health, counts) stay `u32`
- Buttons carry an `Action` (same enum as keybinds) so clicks feed the one input path; skill buttons map slot 1-8 → `skill_slot_N`. Slots are for inventory/gear items only
- Cooldown = semi-transparent overlay image + centered number TextLabel (not a fill fraction). Health globe = `FillSprite` (two sprites: empty drawn whole, full cropped to fraction)
- `highlighted: bool` on Button/Image = reusable edge highlight (renderer outlines opaque pixels); used by the active turn-step icon, selected panel buttons, etc.
- Standard gameplay button/slot is `slot_size` (256 at 4k reference); `ui_gap` (16) between top-level items

## Zig 0.16 Gotchas

- ArrayList is unmanaged: `.empty`, pass allocator to each call
- ArrayList has no `.writer()` — use `.print(allocator, fmt, args)` and `.appendSlice(allocator, items)` directly
- PriorityQueue: `.empty`, `.push(allocator, item)`, `.pop()`, `.deinit(allocator)`
- Dir.writeFile takes an options struct: `.{ .sub_path = path, .data = data }`
- File I/O needs Io handle: `std.Io.Threaded.init(allocator, .{})`, `std.Io.Dir.cwd()`
- No `std.enums.count()` — use `@typeInfo(MyEnum).@"enum".fields.len`

## Key Files

- `src/main.zig` — platform-agnostic composition root: the uncapped game
  loop (gameLoop/run), the per-iteration `update` step that ties input + event
  processing together, and config loading (raylib-free). Tests live with the
  code they exercise (see below).
- `src/event_handlers.zig` — `processEvent` (the one-event dispatch + all
  handler arms) and handler-internal helpers (entity accessors, gear mutators,
  move-highlight refresh, prepared-skill cancel, AI min-range, tile tiebreak).
  Also the event-pushing utilities (`pushEvents`/`pushPlayerSkillUse`) shared
  with the input handlers. The round-trip reconstruction test lives here.
- `src/input_handlers.zig` — input consumption: `handleAnytimeInput`,
  `handleIdleInput`, `resolveTileCursor`, the drag lifecycle, and session-log
  dev tooling (dumpEventLog, build-version warn, timestamp formatter). The
  dragToEvent test lives here.
- `src/view.zig` — `view()` (builds ViewState each frame from GameState +
  SessionState + the per-frame arena) + world drawable builders (tiles,
  overlays, entities, flag poles) + camera math (computeCamera, tileToScreen)
  + sprite/flag frame/pivot constants.
- `src/native.zig` — native exe entry (raylib); `src/web.zig` — web (emscripten)
  exe entry (IDBFS persistence + emscripten main-loop driver);
  `src/raylib_backend.zig` — raylib window/clock/input/render backend (see Platform Seam)
- `src/state.zig` — GameState, GameStateHistory (+ SessionState, undo/redo/
  replay timeline: recordEvent/discardFutureTimeline), Screen
- `src/types.zig` — all game data types, Entity with getEffective* methods
- `src/events.zig` — event hierarchy (Meta, Super, Level, SubLevel, Editor)
- `src/parser.zig` — config file parser, all loaders, save writer
- `src/functions.zig` — pathfinding (A*), chebyshevDistance, helpers
- `src/ui.zig` — UiState, UiElement types, layout helpers (Rect algebra, Row/Grid), panel builders
- `src/input.zig` — input pipeline, translateInput, bindings
- `src/combat_log.zig` — combat-log projection (projectCombatLog + combatLogTier)
- `src/file_source.zig` — unified file I/O (FileSource: embedded map +
  persistent dir + future VFS; see File System & IO)
- `src/skills/` — one file per skill, Skill interface
- `src/effects/` — Effect interface with 16 callbacks
