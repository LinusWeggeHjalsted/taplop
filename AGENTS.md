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
- Web is deferred: it will be a `wasm32-emscripten` exe reusing the SAME raylib
  backend + gameLoop (route B). The old `wasm32-freestanding` + JS-renderer
  target was removed — do not reintroduce it.
- Test discovery is automatic: build.zig generates `src/generated_test_root.zig`
  (gitignored) importing every `src/**/*.zig`, and `addTest` uses it as root. Any
  `test` block in any src file is picked up with no manual wiring. Note this
  means the test build compiles the whole tree, including files main.zig may not
  reach directly. EXCEPTION: `native.zig` and `raylib_backend.zig` are excluded
  from the scan because they link raylib and the test build must stay headless.

## Platform Seam (raylib)

- raylib is linked ONLY into the native exe. Keep it out of the test build (and
  the future emscripten build's shared code) by never importing raylib from any
  file the test-root scan pulls in.
- `src/main.zig` stays raylib-free. The game loop is platform-agnostic:
  `gameLoop(backend: anytype, ...)` drives a duck-typed backend with
  `shouldClose()`, `deltaMicroseconds()`, `pollInput() PlatformInput`, and
  `render(ViewState, ViewportSize)`. Entry is `pub fn run(backend, allocator,
  directory, io)`.
- `src/raylib_backend.zig` is the ONLY file that `@import("raylib")` (plus
  `native.zig`, which imports the backend). It owns the window, the frame clock
  (GetFrameTime → microseconds), input polling, and rendering.
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
  window, then calls `main.run` with a `RaylibBackend`.
- Both files are excluded from the test-root scan in `build.zig`
  (`collectZigFiles`). If you add another raylib-linked file, exclude it too.
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
  `state.SessionState` (`input_state`, `ui_state`) hangs on `GameStateHistory`
  next to `settings` — never deep-copied into snapshots, never touched by
  replay. Clean rule: **in `GameState` → change via events; in `SessionState`
  → change directly in the input/update path.** The screen-transition UI reset
  lives in the live loop (`gameLoop` clears `session.ui_state` when `screen`
  changes across `update()`, covering both event transitions and undo/redo
  across a screen boundary), NOT in `transitionScreen`. `input_state` is never
  reset — it is live hardware state.
- **Replay must not create events; new actions branch the timeline.**
  `processEvent` records into `event_history` only when `!replaying` (via
  `GameStateHistory.recordEvent`); the event index still advances so
  `replayTo`'s loop progresses. Taking a new action after an undo discards the
  stale future first (`discardFutureTimeline`: trims `event_history` +
  `idle_points`, frees snapshots/checkpoints ahead of the branch), so the new
  action continues a fresh timeline from the undone position.

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

- `src/main.zig` — platform-agnostic game loop (gameLoop/run), processEvent,
  handleIdleInput, view, init/config loading (raylib-free)
- `src/native.zig` — native exe entry (raylib); `src/raylib_backend.zig` —
  raylib window/clock/input/render backend (see Platform Seam)
- `src/state.zig` — GameState, GameStateHistory (+ SessionState, undo/redo/
  replay timeline: recordEvent/discardFutureTimeline), Screen
- `src/types.zig` — all game data types, Entity with getEffective* methods
- `src/events.zig` — event hierarchy (Meta, Super, Level, SubLevel, Editor)
- `src/parser.zig` — config file parser, all loaders, save writer
- `src/functions.zig` — pathfinding (A*), chebyshevDistance, helpers
- `src/ui.zig` — UiState, UiElement types, layout helpers (Rect algebra, Row/Grid), panel builders
- `src/input.zig` — input pipeline, translateInput, bindings
- `src/skills/` — one file per skill, Skill interface
- `src/effects/` — Effect interface with 16 callbacks
