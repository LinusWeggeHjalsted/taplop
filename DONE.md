# DONE.md — archived history

Archive of completed work, resolved tech debt, and the "why we did X" reasoning.
Read on demand when you need the history behind something already built — not
every session (see AGENTS.md → Documentation for the file roles).

Newest slices are appended at the bottom of their section. Entries are
historical: they're not maintained after archiving (if a design described here
changed later, the current truth lives in DESIGN.md for design / AGENTS.md for
working rules).

---

## Logging & Replay

### Versioning (DONE)

- `game_version` build seam: `computeGameVersion` in build.zig produces
  `YYYY.MM.<commits-this-month>[-dirty]` from build clock + git, git absent →
  `YYYY.MM.unofficial` (a true `.0` = git ran, zero commits). Exposed via a
  `b.addOptions` "build_info" module on both exe + test roots
  (`@import("build_info").game_version`). Decoupled from build.zig.zon
  `.version` (stays vestigial `0.0.0`). Advisory, warn-on-mismatch policy.
  Shape test in parser.zig.

### PR 1b — session-log writer (DONE)

- Comptime-generic serializer over the Event union (`parser.writeEventLog` /
  `writeEvent` / `writeEventField` / `appendEventScalar`). Leaf cases: ints
  decimal, bool true/false, enum→`@tagName`, `[]const u8` verbatim, struct
  (Vector2/Materials) fields space-separated, slice-of-struct (e.g.
  `highlight_tiles.tile_positions`) flattened space-separated, optional→
  omit line when null. New events serialize with no changes here.
- Metadata header: `file_format_version` (=1) + `game_version` + `created`
  (`YYYYMMDD_HHMMSS`, UTC). EventLog section (added to parser whitelist): one
  blank-line-separated entry group per event; a decorative `event_index <N>`
  header line (purely for human readability — the reader ignores it,
  hand-edited/externally-authored logs may omit it), then `event <category>
  <variant>` discriminator, then payload fields one per line. No idle_points.
  Round-trips structurally through `parseConfigFile` (unit-tested).
- ctrl+L: `Action.dump_event_log` + `KeyL`+ctrl binding in data/settings.txt;
  `handleAnytimeInput` → `dumpEventLog` writes
  `session_log_YYYYMMDD_HHMMSS.txt` to the persistent dir via the file source
  (side effect on the input path, so off the replay path; never gated).
  `formatSessionTimestamp` helper in main.zig.

### PR 2 — session-log parser (DONE)

- `loadEventLog` (parser.zig): sections → `SessionLog {
  file_format_version, game_version, created, events }`. Comptime-generic
  inverse of the writer (`parseEvent` / `parseEventFieldValue` /
  `parseEventScalar` / `parseScalarTokens`) — mirrors the writer's
  flattening, so new events deserialize with no changes.
  `file_format_version` is a hard gate (`error.UnsupportedFileFormatVersion`);
  `game_version` is returned for the caller to warn on (advisory warn wired at
  reconstruct time, PR 3).
- Tests: synthetic round-trip (`expectEqualDeep` over all field shapes incl.
  present/absent optionals, slice + empty slice, Materials, enums, bools), an
  unsupported-version rejection, and a verified byte-identical
  re-serialization of the real 153-event session log.

### PR 3 — reconstruct + step (DONE)

- `GameStateHistory.reconstructFromEventLog(events, target_index,
  apply_event)` (state.zig): deep-copies the loaded events into
  `history_arena`, then rebuilds state via `replayToWithIdleTracking` from
  `initial_state`. Call on a freshly-inited history whose `initial_state`
  matches the session start.
- `game_version` advisory warn: `warnIfSessionLogFromDifferentBuild` in
  main.zig (warn-only, never fails). `build_info` imported into main.zig.
- End-to-end harness test (main.zig): forward-plays a scripted session (main
  menu → new game → hub → hub move) into one history, serializes → parses →
  loads, reconstructs into a second history, asserts the final
  `current_state` is deep-equal (forward play == replay). `runToIdle` helper
  drives `processEvent` to stack-empty and records the idle point (mirrors the
  live gameLoop). Extended to also assert `history2.idle_points` deep-equals
  `history1.idle_points` (virtual-depth derivation matches live bookkeeping)
  and that undo walks a reconstructed session back to start.

### Combat-log projection (DONE)

- `src/combat_log.zig`: `projectCombatLog` + `combatLogTier`. Pure
  `O(events-in-level)` per-frame in `view()` into the frame arena (backward
  scan via `history.levelStartEventIndex` for the most recent `start_level`,
  forward filter to `current_event_index` — so undo truncates the future and
  crossing back to the hub shows no log). No `SessionState` cache.
  `ViewState.combat_log` is `[]const Event`; `view()` takes `event_history` +
  `level_start_index` + `current_event_index` params.
- Tier split decided: **coarse** = `move_entity`(!is_forced), `use_skill`,
  `death`; **fine** = attack, stun, knockback, retreat, heal, create_effect,
  end_effect, collision, pickup_items, `move_entity`(is_forced); **none** =
  everything else. UI resolves `entity_index`/`skill_id`/`effect_id` to
  display strings against `current_state` at render time (entity_index is
  stable within a level; dead entities keep their slot). Old
  `CombatLogEntry` union + `Level.combat_log` scaffolding DELETED.
- Headless-tested with synthetic event slices (4 tests).
- Three event refactors landed so the stream carries actual occurrences (not
  checks that might do nothing):
  1. `move_entity` gained `is_forced: bool = false`; knockback/retreat push
     sites set it true. Projection: `!is_forced` → coarse "moved to";
     `is_forced` → fine "knocked/pushed to".
  2. New `collision` sub_level_event `{ attacker_index, defender_index,
     damage }` carrying the RAW knockback_damage (mirrors `attack` carrying
     `outgoing_damage`); its handler applies defender incoming modifiers,
     fires `on_outgoing/incoming_collision` + `on_outgoing/incoming_damage`,
     and pushes `death` if killed. The knockback handler's inline collision
     block moved into the `collision` handler, pushed only when collided.
     Tier: fine.
  3. New `pickup_items` sub_level_event `{ entity_index, position }`;
     `pickup_around` is now a pure CHECK (no mutation): for each ground stack
     in range, push `pickup_items` keyed by position. The `pickup_items`
     handler finds the stack at that position, transfers items into the
     inventory (first-empty-slot), and either keeps the stack with leftovers
     or removes it. Carrying only the position (not the items) avoids needing
     Item-union support in the session-log serializer; the log shows "picked
     up at (x,y)" (no item details — pickups aren't combat). Only pushed when
     items are actually in range → log-clean on empty moves. Tier: fine.

### Reconstruction refactor — idle points from virtual stack depth (DONE)

- `replayToWithIdleTracking` derives idle points + snapshots during replay
  from virtual stack depth (depth 0 = stack-empty = idle point →
  `recordIdlePoint`), so a loaded session undoes/steps "as if played live".
  `recordIdlePoint` is shared by the live gameLoop and reconstruction.
- Required the ONE-EVENT-PER-PLAYER-ACTION convention (5 new orchestrator
  LevelEvents: `player_move_action` / `player_skip_move` /
  `player_cancel_skill` / `player_skip_attack` / `player_use_skill`) so
  sibling batches don't over-detect idle points. Round-trip test extended to
  assert `idle_points` match + undo-to-start on a reconstructed session.

---

## Foundation (done)

The load-into-a-hub → walk-into-a-mission → fight-a-level → return loop
runs end-to-end natively and on web. Original rendering + platform phases
1–7 are complete for the happy path; combat CORRECTNESS is the main gap
(deferred until logging, now landed). All foundational systems below are
DONE; settled conventions live in AGENTS.md, this is the history.

### Phases 1–7 (rendering + platform)

- **Phase 1** Platform seam + raylib: window, real GetFrameTime clock, input
  polling. main.zig raylib-free; backend in raylib_backend.zig; entry in
  native.zig.
- **Phase 2** UI renderer: all 6 UiElement types, reference-res
  RenderTexture blitted letterboxed, texture cache, magenta fallback for
  missing art. (Main menu renders + is clickable.)
- **Phase 3** Button clicks → Action (ui.buttonAt + input.applyAction) +
  world/UI click arbitration. New Game works.
- **Phase 4/5** view() world-building + world rendering (vertical slices):
  camera centered on player (computeCamera), color theme from
  color_wheel_index, checkerboard tiles, entities (base sprite + weapons,
  off-hand mirrored, player vs enemy_ variants), level-end + hub
  mission-start flag poles, move-range highlights + hover cursor.
  tile_size_pixels = 256.
- **Phase 6** Camera + tile-click movement (hub walk, level move); hub →
  mission → level transition.
- **Phase 7** Playable: move / skill / skip / enemy turns with real-time
  waits.

### Parsing (done)

- Generic config file parser (parser.zig); settings parser (loadSettings);
  weapon-type definition parser (loadWeaponTypeDefinition); color theme
  parser (loadColorTheme, data/color_themes.txt); level parser with layout
  grid (loadLevel); hub parser with layout grid (loadHub); campaign parser
  (loadCampaign); mission parser (loadMission); save file parser
  (loadPlayerSave); save file writer (writePlayerSave,
  writePlayerSaveToFile); new-game template (data/new_player.txt).

### Game state initialization (done)

- DebugAllocator in debug, page_allocator in release; load settings from
  data/settings.txt (defaults on failure); load weapon-type definitions
  from data/weapon_types/; load color themes from data/color_themes.txt;
  initial GameState with open_main_menu queued; Screen enum (main_menu,
  hub, level, editor, replay_viewer). File access now goes through the
  session-resident FileSource (see DESIGN → File System & IO).

### Event processing — Meta/Super (done)

- open_main_menu → transitionScreen(.main_menu); start_new_game → load
  new_player.txt → load campaign → queue start_hub; load_save → load save
  → load campaign → queue start_hub; save_game → write player data;
  start_hub → load hub → transitionScreen(.hub) → queue
  build_player_from_data; end_hub; start_mission → load mission → queue
  start_level (level 1); end_mission → queue start_hub (end_hub);
  start_level → load level → transitionScreen(.level) → queue
  build_player_from_data; end_level → queue next start_level or
  end_mission; build_player_from_data / build_data_from_player sync.
- end_level / end_hub own the entity→PlayerData sync (push
  build_data_from_player{0} while the old world is still live). end_hub
  activated (was no-op) + pushed on the hub mission-exit path. (Convention
  in DESIGN → Architecture.)
- save_game orchestrates: build_data_from_player (in hub/level) then
  write_save (pure file write, skipped during replay).

### Infrastructure (done)

- A* shortest path (Chebyshev distance, Manhattan heuristic, entity
  blocking); walkingDistance helper; fixed-size inventory (8×12 = 96
  slots, ?Item array); fixed-size utility skills (utility_skill_count = 5);
  PlayerData tracks current_campaign and current_hub; Mission tracks path
  and current_level_index for multi-level flow; event stack (LIFO) with
  queueEvents helper for appending; Screen.scope() + transitionScreen()
  for clean screen transitions; AGENTS.md is the session-context doc
  (formerly CLAUDE.md).
- Combat log scaffolding (CombatLogEntry union on Level) — since DELETED,
  replaced by the event projection in src/combat_log.zig.

### Event processing — Level/SubLevel (done)

- LevelEvent: turn_start, turn_end, player_turn_move, player_turn_attack,
  enemy_turn_move, enemy_turn_attack, move_entity, player_prepare_skill,
  use_skill, highlight_tiles, clear_highlights.
- SubLevelEvent: pickup_around, aggro_around, attack, stun, knockback,
  retreat, create_effect, end_effect, death.
- Turn sequencing (player → enemies sorted by distance → repeat); dead
  entity guards; auto-skip attack step out of combat; level-end check
  after player aggro_around; initial aggro_around for all entities on
  level start; event stack cleared on screen transition.
- Combat log is an event projection (not per-event entries) — see
  Logging & Replay above.

### Event processing — Player / Hub (done)

- PlayerEvent: swap_hands, learn_skill, salvage_item, equip_item.
  swap_hands swaps weapons + cancels prepared skill if in level; moved
  from LevelEvent to PlayerEvent (works in hub and level); swap_weapons
  input moved from IdleInput to AnytimeInput.InGameInput.
- HubEvent: move_player, interact_with_npc. move_player moves player,
  checks mission exits → queues start_mission. Hub idle input: click NPC
  → interact_with_npc, click tile → move_player; NPC click takes priority.

### Idle input → event translation (done)

- tile_clicked: pathfind + queue move_entity during player_move phase
  (level); move to tile or interact with NPC (hub). skill_slot_selected:
  resolve slot → SkillId, begin targeting or auto-target. confirm:
  simulated tile click at cursor. cancel: deselect skill, clear
  highlights. skip: end current turn / skip move or attack step.

### Enemy AI (done)

- Basic aggro/chase/attack (enemy_turn_move, enemy_turn_attack); enemy
  turn sequencing (sorted by distance in turn_end); movement pathfinds
  toward nearest opposing entity, respects minRange; attack uses
  non-turn-ending skills first (by priority), then best turn-ending skill.

### Turn-flow pacing (done)

Settled design in DESIGN → Platform Seam (budget-driven drain, render
 gating, CAVEAT). History:
- wait MetaEvent carries duration_milliseconds only (cosmetic,
  non-skippable). GameState.waiting (?WaitState, microseconds) drained by
  update() each tick; event processing stalls until it elapses, no skip
  path. replayTo() clears waiting after replay so reconstruction never
  lands mid-wait. update() takes delta_microseconds; anytime input
  (undo/redo/options) and drag still run mid-wait.
- Enemy turns inject waits (turn_flow_wait_milliseconds = 500): before
  each move and each skill. Real frame delta feeds update() from the
  backend clock; the placeholder frame_length/computeFrameLength alias
  are gone.
- gameLoop is UNCAPPED — one update() per iteration, rendering gated to a
  real-clock interval (vsync → monitor refresh rate; or 1/render_fps_cap;
  or 0 = render every iteration). Gameplay logic drains as fast as the
  CPU allows between renders; waits use real-clock deltas (rl.getTime,
  not getFrameTime) so turn-flow pacing is framerate-independent. Idle
  yield (rl.waitTime 0.1ms when stack empty + no wait) avoids 100% CPU
  spin. Idle AND wait states both yield; active drains spin freely.
  pollInputEvents() pumps the OS queue each iteration. render/snapshot
  throttle scaffolding removed (raylib paces the loop).
- RENDER SEMANTICS: rendering is SKIPPED while a drain is in progress
  (stack non-empty, no wait) — vsync (swapScreenBuffer) blocks the thread
  for a full refresh, so rendering every drain iteration would
  frame-lock the drain. Render only when the drain completes (stack
  empties) or pauses (a wait is active).

### Build-time lookups (done)

- Generated src/generated_lookups.zig with getEffectDefinition /
  getSkillDefinition; comptime enum + exhaustive switch, auto-wired from
  file names; skill files standardized on `pub const skill`, effect defs
  in src/effects/.

### Color theming (done)

- Color type (r, g, b), ColorGradient (6 colors), ColorTheme;
  ActiveColorTheme (lightest, darkest, world/enemy/player gradients);
  color_themes.txt with 9 gradients around a color wheel; hex parsing
  (asColor, #RRGGBB); loadColorTheme (GlobalColors + Gradients sections);
  deriveActiveColorTheme (world index → enemy/player at 1/3 offsets);
  color_wheel_index on Level and Hub; ColorTheme loaded at startup.

### View state types (done)

- ViewState struct; 3840×2160 reference resolution, ScreenPosition
  (integer); Layer 0 background; Layer 1 TileDrawable (position +
  checkerboard color); Layer 2 TileOverlayDrawable (highlight, outline,
  cursor + color); Layer 3 GroundDrawable union (entity, decoration
  piece, ground items, level end) with EntityDrawable sub-layers (back
  effects, base, weapons, gear, front effects, health bar),
  DecorationPieceDrawable (source_rectangle + draw_offset),
  SpriteDrawable (color tint); Layer 4+5 flat ui_elements slice; view()
  returns ViewState, game loop stores previous_view_state.

### UI framework — types (done)

- UiState (open panels, overlays, tooltips, scroll offsets) on
  SessionState (off the undoable GameState); MiddlePanelId (inventory,
  gear, skills, enemy_inspect); FullScreenOverlayId (world_map,
  full_combat_log); toggleMiddlePanel / toggleFullScreenOverlay with
  open-order preservation; options menu flag (separate, always on top,
  locks input + pauses game); UiState reset on screen transition (in the
  live loop on screen change, not transitionScreen).
- UI element types: NineSlicePanel, Slot, Button, TextLabel, Bar, Image;
  Button carries Action enum; UiElement tagged union; layout constants.
- Tooltip corner selection (selectTooltipCorners); tooltip content
  model (Span / TooltipRow / Tooltip with text/colored/bold/italic span
  constructors); tooltip: ?Tooltip on every variant.
- Generic hit-testing: boundsOf (geometry per variant, single source of
  truth), tooltipOf/blocksInputOf (inline else); Rectangle.contains.
- Occlusion model: blocks_input (default true) on every variant; one
  hitTest primitive walks top-to-bottom, passes through transparent
  elements, halts at the first blocker. slotAt/slotRefAt (drag) and
  tooltipAt (hover) are predicate wrappers. Decorative overlays opt out.
- TextLabel gained bold/italic; removed stale active_tooltip/TooltipState
  (tooltip is derived per-frame, view is const). Toggle inputs wired in
  handleAnytimeInput; entity inspect toggle (open/close/switch target).

### Skill logic — port (done, all 25 skills)

Ported from the Unity project (https://github.com/LinusWeggeHjalsted/taplop, Assets/Scripts/Skills).
Pattern: C# SkillScript → Zig Skill struct + 5 fns (getValidTargets /
priority / selectTarget / playerPrepareSkill / useSkill). Skills compose
generic events (DESIGN → Architecture). Porting note: Unity inverts AI
priority (lower = higher, -1 = don't use); ziglop is higher = higher, 0 =
don't use — FLIP when porting (see skill.zig priority_fn doc).

- **Primitives:** new generic events heal / change_momentum /
  change_cooldown / swap_positions (+ attack.heals_attacker lifesteal
  hook). Handlers clamp via functions.applySignedDelta. Converted
  momentum already in getEffectiveOutgoingDamage; Impale/Skewer add one
  more getConvertedMomentum in-skill.
- **Skill-helper layer** (src/skills/helpers.zig, excluded from the
  SkillId scan): hostilesInRange / nearestTarget / highlightTargets /
  hostileEntityAt / ownedEvents. ownedEvents allocates the useSkill
  result in the passed allocator (pushEvents consumes it synchronously).
- **Batch A** single-target attacks: Stab, Chop, Throw (off-hand),
  Impale, Skewer (off-hand), VampiricStrike. Doubled converted momentum
  = getEffectiveOutgoingDamage + one more getConvertedMomentum.
- **Batch B** attack + status/move: Cleave (attack+stun), Bash
  (attack+knockback + raw collision dmg, collision-aware AI priority),
  RetreatingSwipe (off-hand attack + retreat), Spark (attack + target
  -1 momentum), Toss (attack + caster +1 momentum), Daze (stun + remove
  all target momentum). Skills apply caster OUTGOING modifiers, handlers
  apply defender INCOMING. All actions grant +1 momentum (use_skill AND
  move_entity handlers); Toss's +1 is on top (nets +2).
- **Batch C** AoE: Spinblade, Blitz (off-hand dmg — Unity used main,
  corrected), Slam, FlashStrike (teleport then AoE). Event stack is LIFO
  so helpers.ownedEvents takes events in natural EXECUTION order and
  reverses them.
- **Batch D** cantrips: Blink, Swap, Replenish, Howl (new
  aggro_in_radius event), Focus (new reset_weapon_cooldowns
  orchestrator). skill_type = .cantrip; real positive priorities.
- **Batch E** enchantment effects: Reflect, StoneForm. Effect damage
  pipeline (design B): intercept_incoming_damage_fn (TRANSFORM stage)
  returning DamageInterception, distinct from the reactive on_* family.
  Reflect intercept returns {0, [attack back, triggers_effects=false]}.
  StoneForm: additive stun modifiers + on_end_turn heal. Emergent:
  VampiricStrike into Reflect heals 0; Reflect vs Reflect terminates.
- Effective stat methods on Entity; Entity.skillInSlot / collectSkillSlots
  (single source of truth); computeMinRange for enemy AI.

### View function implementation (done parts)

Phase 4 plumbing: tile_size_pixels = 256 (matches assets; screenToTile +
  renderer share it). Camera is DERIVED, centered on the player
  (computeCamera in main.zig, passed to both translateInput and view).
  view() gained camera + camera_zoom params; ViewState gained world_scale.
  Entity gained `sprite` field (asset stem); parser stores it. Minimal
  starting_village hub authored.
- Derive ActiveColorTheme (activeThemeFor); tileToScreen (exact inverse of
  screenToTile); TileDrawable with checkerboard coloring (world gradient
  indices 1 and 3). All tiles use assets/world/tile.png (source 600×600
  scaled to 256×256; jagged edges overlap to outline the grid).
- GroundDrawable y-sort (ascending tile.y = nearer = drawn later).
- Entity + weapon assets share one 512×640 frame + pivot (0.5, 0.8):
  normalized fraction, horizontal center at the feet. Renderer aligns
  pivot → tile anchor; weapons register with no per-sprite offset.
  Source 2048×1280 two-pose sheets, LEFT pose only, stored at 0.5
  (256px/tile). Player bodies use weapons/<type>, enemies
  weapons/enemy_<type>; off-hand mirrored via flip_horizontal.
- Flag poles (world/flag_pole, 256×512 = 1×2, pivot 0.5/0.75) + animated
  banner (world/flag) for level-end / hub mission-start markers.
- Ground items sprite (world/ground_items.png, 256×256, centered pivot).

### UI framework — panel builders (done parts)

- Layout infrastructure (per-frame arena, bounds Rectangle, shared
  []UiElement); Rect algebra + screenRect/rowWidth/Row/Grid; i32
  screen-space dims; FillSprite for health globe; cooldown = overlay +
  centered number.
- buildBottomBar (inventory/gear/skills buttons, health globe, weapon
  skills 1-3, swap, utility 4-8, skip); bottom-bar indicators (momentum,
  active effects grid, turn-step icons); highlighted:bool on Button/Image.
- buildMainMenu (panel-backed buttons, Continue only when resumable);
  menu buttons carry Actions; Settings distinct from in-game Options.
- buildTooltip (measures/wraps rows, clamps on screen) + buildSkillTooltip
  (name/desc/type/variable rows); bottom-bar element tooltips authored;
  9-slice drawNineSlice (corners 1:1, edges+center STRETCHED for now);
  tooltip uses shared ui/panel sprite.
- Input resolution: previous_view_state → UI slot (slotAt/slotRefAt);
  button clicks → Action via buttonAt + applyAction; world/UI
  arbitration (blockingElementAt clears world click); tooltip on hover;
  options menu locks game input.
- Drag & drop: SlotRef + DragState on UiState; PlayerInput.pointer;
  slotAt/slotRefAt; handleDrag lifecycle; dragToEvent resolver
  (item/skill domain split); drag ghost. (Open drag items stay in TODO.)

### Player events (done)

- learn_skill (consume skill tome by inventory slot); salvage_item
  (remove by slot, compute materials from data-driven splits);
  equip_item / unequip_item (GearSlot-based); salvage system
  (data/salvage.txt, SalvageDefinitions, computeSalvageValue with
  zero-loss rounding); removed salvage_conversion placeholder, added
  value field to SkillTome.

### Logging follow-ups (done)

- Idle points + snapshots DURING reconstruction: replayToWithIdleTracking
  derives idle points from virtual stack depth (depth 0 = stack-empty =
  idle point → recordIdlePoint). The live gameLoop calls recordIdlePoint
  too (was two inline calls). (Full detail in Logging & Replay above.)
- Session-log integrity: DECIDED not to add an event_count / corruption
  warning — keep files lean + hand-editable. A truncated dump is just
  corrupt and may error at parse; acceptable.
- game_version filename/timestamp is UTC (no tz db in std) — accepted
  papercut.

### Tech debt / refactoring (done)

- Enemy AI skill priority is integer (u32, 0 = don't use) not float —
  keeps gameplay logic integer-only.
- Event-stack terminology: pushEvents/pushPlayerSkillUse, "push"/"stack"
  in comments (pathfinding queues left as-is).
- Error-handling policy: fail fast via catch @panic, never silent catch.
- Replay-safety: route ALL gameplay-state mutation through events.
  Wired clear_highlights into the flow; added clear_prepared_skill;
  turn_end owns turn_phase = null. refreshMoveHighlights /
  cancelPreparedSkill left as direct writes (only run inside event
  handlers).
- Live current_state memory is arena-managed (was leaking into the gpa).
  Two lifetimes: history_arena (durable, event_history + idle_points +
  event payloads) and current_arena (live current_state, compacted at
  each idle point). backing_allocator on GameStateHistory; apply_event
  lost its allocator param.
- Replay/undo timeline correctness: processEvent records only when
  !replaying; discardFutureTimeline trims event log + idle points +
  frees snapshots/checkpoints ahead of a branch. Covered by 3 state.zig
  tests.
- Moved transient view/input state out of the undoable GameState:
  state.SessionState { input_state, ui_state, tile_cursor } on
  GameStateHistory. Screen-transition UI reset in the live loop.
  tile_cursor resolved per-frame in update() (resolveTileCursor).
- setCheckpoint moved to AFTER the start_level/start_hub handler so it
  captures post-transition scope (was capturing pre-transition, panicking
  on undo across a level boundary).

### Platform layer (done)

- Raylib integration (windowing + input + frame clock); raylib input →
  PlatformInputEvent; GetFrameTime → delta_microseconds; ViewState UI
  layer render (all six variants); reference→viewport letterbox blit +
  inverse pointer mapping (viewTransform); grayscale × Color via
  DrawTexturePro tint; sprite source-rect cropping; FillSprite rendering;
  texture cache (magenta fallback).
- Web build (wasm32-emscripten, route B): emcc packaging + emrun;
  src/web.zig (c_allocator, IDBFS at /ziglop, FileSource,
  emscripten_set_main_loop_arg drives frame()); frame() split from
  gameLoop; read-edges-then-pump pollInput; renderInterval 0 on web;
  custom shell HTML; emcc settings (FORCE_FILESYSTEM,
  ALLOW_MEMORY_GROWTH, STACK_SIZE=8mb, -lidbfs.js).
- Patched-stdlib workflow (Zig 0.16.0 std/os/emscripten.zig STOPSIG bug)
  carried at ~/.local/zig-patched-lib; native + tests use normal zig.
- The old freestanding-wasm + JS-renderer target was REMOVED.

### Web Phase 3 — IDBFS flush (done)

- FileSource.writeFile calls `FS.syncfs(false, …)` after each write on
  emscripten (best-effort; callback logs errors). web.zig runs a syncfs
  LOAD on startup (restores persisted state) and registers a beforeunload
  listener that fires a final flush. Writes persist to IndexedDB across
  browser restarts (verified: a session_log saved to the virtual FS
  survived a restart).

### Determinism & Tiebreaking — full audit (done)

Convention in DESIGN → Determinism & Tiebreaking. All audit sites made
explicit (was: deterministic-but-implicit, flagged for commenting/sign-off):

- turn_end enemy ordering: std.mem.sort (unstable) comparator breaks
  distance ties by entity_index (was genuinely arbitrary — the one real bug).
- enemy_turn_move nearest-target loop: strict `<` over an index-ordered scan
  keeps the lowest entity_index on ties; documented with a comment.
- nearestTarget helper (skills/helpers.zig): first target in slice order
  (lowest index); documented by structure.
- enemy_turn_attack skill selection: first skill in slot order per bucket;
  documented.
- enemy_turn_move reachable-tile fallback: uses `tileBefore` to break
  distance ties by the (x,y) tile convention — this was the one flagged for
  sign-off (changes which tile a stuck enemy picks on ties); landed.
- Already total (no action): A* comparePathNodes (f→x→y); entity draw sort
  (unique positions, visual-only).

### Combat turn-flow (resolved)

The earlier enemy/combat turn-flow issues seen in playtesting are gone —
no longer a deferred bug. (Logging landed first to troubleshoot them, as
planned; combat flow is now working.)

### Reconstruction cache (done — within-session)

Reconstruction-read event handlers (`start_level` / `start_hub` /
`start_mission` / `load_save`) now read through
`GameStateHistory.readReconstructionFile`, which caches the bytes in
`history_arena` keyed by `(event_index, path)`. Live reads cache; replay
serves from the cache so the bytes a reconstruction-read event applies are a
pure function of its position in history — deterministic regardless of later
file changes (the editor-saves-overwrite-mid-session case).

- All 6 reconstruction-read call sites in event_handlers.zig swapped from
  `parseConfigFileFromPath(file_source, …)` to `parseConfigFile(readReconstructionFile(path), …)`.
- `reconstruction_cache` field on GameStateHistory (append-only list,
  history_arena-backed); trimmed in `discardFutureTimeline` (monotonic by
  event index).
- Cache-miss: `@panic` for in-session undo/redo (live always cached — a
  miss is a bug); `cross_session_replay` flag makes `reconstructFromEventLog`
  fall back to `file_source` + cache retroactively (the cache starts empty
  when no live play ran).
- Test: "reconstruction cache: undo replay reads original bytes after the
  file is overwritten" (main.zig) — writes v1, live-reads+caches, overwrites
  with v2, replays, asserts v1.
- NOT serialized yet (within-session only). Cross-session serialization
  (session-log `ReconstructionCache` section, `file_format_version` 2) lands
  with custom-mission sharing. See DESIGN → File System & IO → Reconstruction
cache.

### Camera pan (right-drag) + render-camera snap fix (done)

- **Render-camera snap fix:** `frame()` now recomputes the render camera
  from the POST-update `current_state` (before `view()`), separate from the
  pre-update input camera. Without this, a move completed this frame drew
  the player at the new position under a camera still centered on the old
  one — a one-frame glitch where the player appeared jumped before the
  camera caught up. `computeCamera` is cheap; both reads go through it so
  input and render never drift.
- **Right-click-drag pan (levels/hubs):** grab the world point under the
  cursor and drag it so it stays under the cursor (sub-tile precision via a
  float world anchor — `floatWorldPoint` in input.zig, the float inverse of
  the camera transform, beside `screenToTile`). Pan offset lives on
  `SessionState.camera_pan` (transient view state, replay-safe by
  construction); `computeCamera(state, zoom, pan)` applies it so both the
  input camera and the render camera pick it up. Pan-start is suppressed
  over blocking UI (`blockingElementAt`, same occlusion as the tile cursor).
  Pan clears on player move (recenter) and on screen transition. `handleCameraPan`
  runs anytime (mid-wait / mid-turn), like `handleDrag`.
- **Cancel rebind:** right mouse no longer cancels (it's the pan button now);
  cancel is Backspace only. Right-click entity inspection is a future item
  (noted in TODO → Larger systems), not wired yet.
- **Shared drag threshold:** `input.drag_threshold_pixels` (0 = any move is a
  drag) centralizes the click-vs-drag movement threshold for inventory drag
  (once it gains disambiguation) and camera pan. Referenced by handleCameraPan;
  inventory drag will reference it when its click-vs-drag split lands.

### Editor building blocks — reference model (done)

The editor's data model is reference-based (palette + placements), not n
concrete Level copies. A palette entry (`EntityTypeDef`/`DecorationTypeDef`)
is a reusable prefab; placements store `(type_id, position)`. Editing a type
updates every placement referencing it — no propagation sweep. The player
loadout is editor-global (`player.txt`), not per-level.

- Types: `EditorMode` (`edit`/`playtest`/`validate`), `Editor` (mission +
  `levels: []EditorLevel` + `entity_types`/`decoration_types` palette +
  `player_def`), `EditorLevel` (reference-based: tiles + `player_start` +
  `entity_placements`/`decoration_placements`), `EntityPlacement`/
  `DecorationPlacement` (`type_id` + `position`).
- `parseEntityDefinition` extracted from `loadLevel`'s inline enemy parsing —
  shared by enemy definitions, `EntityTypeDef.template`, and the player loadout.
- `loadPlayerLoadout` + `player.txt` format (`PlayerLoadout` section,
  whitelisted; entity-definition keys, `slot_4`..`slot_8` for utility skills).
  All official missions ship one (`first_mission/player.txt` added).
- `buildEditorMission` (pure, no I/O): dedups the levels' inline entity/decor
  definitions into the palette (`entityDefinitionsEqual` compares definition
  fields only, not runtime/position; `decorationFootprintEqual` for decor).
  Unused types lost on close (save flattens to inline — accepted).
- `instantiateEditorLevel(editor, N)`: builds a concrete `Level` (entity 0
  from `player_def` at `player_start`, enemies from palette types at
  placements, runtime fields reset via `resetRuntimeFields`). Gameplay engine
  runs on the result unmodified.
- `open_editor` reads mission.txt + player.txt + all level_N.txt via
  `history.readReconstructionFile` (cache-deterministic), then calls
  `buildEditorMission`.
- `start_playtest`/`start_validation` call `instantiateEditorLevel` (was
  `deepCopy(Level)`); `pushGameplayStartEvents(sync_player=false)` — the player
  sync is skipped because the player is already fully instantiated from
  `player_def` (normal `build_player_from_data` would clobber it with the
  campaign's PlayerData).
- Round-trip test: open → playtest → end → close; asserts palette (1 enemy
  type), player_def (name/sprite), instantiated entities (player + skeleton),
  discard on end, clear on close.
- `first_mission/mission.txt` gained `level_count 1` (was missing; editor
  needs the real count).
- Single mission file format: no on-disk palette file (palette is transient,
  deduped on load, lost on close if unused); save flattens back to the existing
  inline level format. `player.txt` is the only new on-disk file.

### Decoration footprint — sprite metadata + parser (done)

- **Build-time sprite metadata table:** `build.zig` emits
  `generated_sprite_metadata.zig` (gitignored) with pixel dimensions from each
  PNG's IHDR (big-endian u32 width/height at byte offset 16/20) for every
  `assets/**/*.png`, keyed by sprite id (asset path minus `assets/` prefix and
  `.png` suffix). Wired as the `generated_sprite_metadata` module into exe +
  web + test roots. Zero author burden, zero drift (re-generated every build).
  This is the "Sprite asset metadata" TODO item.
- **`pixel_dims` on Decoration / DecorationTypeDef:** `view()` needs pixel
  dims to compute bbox + per-tile source rects, and `view()` is pure (no I/O).
  So dims are stored on the GameState: `Decoration.pixel_dims` and
  `DecorationTypeDef.pixel_dims`, populated by the parser at load. Shipped
  sprites resolve from the comptime table (zero I/O); custom sprites read the
  PNG via `file_source` and parse the IHDR. Stored on GameState → replay
  reproduces without re-reading the PNG.
- **`?*const FileSource` on loadLevel / loadHub / buildEditorMission:** needed
  for custom-sprite dims resolution at parse time. Tests pass `null` and use
  shipped sprite ids (resolve from comptime table). All call sites in
  `event_handlers.zig` updated to pass `history.file_source`.
- **Footprint parsing:** `footprint x y` lines in decoration entries, stored
  as sprite-grid coords on `Decoration.footprint` (flipped from the old
  anchor-relative comment). `parseDecorationDefinitions` pre-parses into a
  hashmap keyed by char code (like enemies/items), replacing the old
  `decoration_codes` list + inline section re-lookup.
- **Anchor derivation:** `decorationAnchor` = bottom-most-then-left-most of
  the footprint list (derived, not stored). The layout char sits at the
  anchor; non-anchor footprint tiles are implicit (space = no tile).
- **Placement invariant:** `validateDecorationFootprint` runs after the
  layout walk — checks footprint within sprite bbox, and no world footprint
  tile overlaps a level/hub tile. Violations `@panic` (fail fast).
- `instantiateEditorLevel` carries `pixel_dims` from `DecorationTypeDef`.
- Tests: updated decoration test to use shipped sprite `decorations/stone_1`
  with `footprint 0 0` + asserts on footprint/pixel_dims; added multi-tile
  test with `decorations/tree_1` (3×3 bbox, `footprint 1 2` trunk-only).

### Decoration footprint — view splitting (done)

- **Per-bbox-tile `DecorationPieceDrawable`:** `buildDecorationPieces` splits
  a decoration's sprite into 256px chunks, one per bbox tile (derived from
  `pixel_dims / 256`). Each chunk carries a `source_rectangle` =
  `(grid_x*256, grid_y*256, 256, 256)` and a `screen_position` at the chunk's
  world tile (`anchor_world + (grid - anchor)`).
- **Overhang-to-footprint assignment:** overhang bbox tiles (art but not
  footprint) are assigned to their nearest footprint tile by Chebyshev
  distance (`nearestFootprint`); the piece sorts at that footprint tile's
  world y, not its own. This prevents wide entities from clipping through a
  decoration (the `!T` canopy example from the design discussion). Footprint
  tiles sort at their own world y; horizontal tiebreak uses the piece's own
  world x.
- **Unified ground-drawable y-sort:** `view()` now collects entities +
  decoration pieces + level-end/mission-start markers into one
  `[]GroundEntry` list and sorts by `(sort_y, sort_x)` ascending, replacing
  the old separate entity sort + marker-prepend. `buildEntities`/
  `buildHubEntities` replaced by `collectEntityEntries`; `entityDrawsBefore`
  removed (superseded by `groundEntryBefore`).
- **Anchor derivation in view:** `decorationAnchor` (bottom-most-then-left-
  most) duplicated from parser.zig to keep view.zig free of a parser import.
- **Sample content:** `first_mission/level_1.txt` carries a `tree_1` (3×3
  bbox, `footprint 1 2` trunk-only); `starting_village/hub.txt` carries a
  `stone_1` (1×1). Both render via the new split path.

### Layout y-axis inversion fix (done)

The parser was inverting the layout grid's y axis: `y = row_count - 1 -
raw_y`, so the FIRST row in a level/hub text file (top) mapped to the HIGHEST
y, which the renderer draws at the BOTTOM of the screen (higher y = lower on
screen). So the top of the text file appeared at the bottom of the game —
inverted from natural reading order.

Fix: `y = raw_y` (top row = y=0 = top/back of screen, bottom row = high y =
front/bottom). Affects `loadLevel` + `loadHub` (both had the flip). The
`row_count` local became unused and was removed. Test assertions + comments
in all four layout tests updated to the new (natural) y values. Tile counts
were unaffected (only y mapping changed, not which positions are tiles).

### Decoration color + multi-sprite layers (done)

- **Color indexing:** `color_index: u32` on `Decoration` +
  `DecorationTypeDef` (default 0). Parsed from `color_index N` in the
  decoration entry group. `view()` resolves it via
  `worldGradientColor(active_theme, color_index)` →
  `world_gradient.colors[idx]` and passes it as the raylib tint on each
  `DecorationPieceDrawable`. Tiles use gradient indices 1/3, background 2;
  decorations should use 0/4/5 for distinction. Per-char-code (all placements
  of a char code share the color; a level wanting two colorings uses two char
  codes).
- **Multi-sprite layers:** `DecorationLayer = { sprite, color_index,
  pixel_dims }` on `Decoration`/`DecorationTypeDef`. Config uses a `layer`
  delimiter line: the following `sprite`/`color_index` pairs belong to that
  layer until the next `layer` or end of entry. The base's own `sprite`/
  `color_index` are top-level keys (backward compatible). Layer pixel dims
  validated == base dims at load (`@panic` on mismatch). `DecorationPieceDrawable`
  gained `layers: []const SpriteDrawable`; `view()` builds the same per-bbox-
  tile source rect for each layer (same position + rect, different sprite +
  color). Renderer draws base then iterates layers in order.
- **Dedup:** `decorationDefinitionsEqual` + new `decorationLayersEqual` now
  compare color_index + layers, so the editor palette dedups by full visual
  identity. `buildEditorMission` dupes the layers slice into the type def;
  `instantiateEditorLevel` copies color_index + layers to concrete decorations.
- **Tests:** stone_1 decoration test gained `color_index 4` + assertion; new
  "loadLevel decoration with layers" test (base + layer, same sprite, asserts
  color_index + layer sprite/color/dims). Sample content (level_1 tree,
  hub stone) gained `color_index`.

### Entity + UI coloring (done)

- **Entity `color_index` + `layers`:** `Entity` gained `color_index: u32`
  (default 0) and `layers: []const EntityLayer`. `EntityLayer = { sprite,
  color_index }` — same layer model as decorations but no pixel_dims (entities
  share the fixed 512×640 frame, so no bbox validation). Parser reads
  `color_index N` + `layer` sub-groups (same delimiter syntax as decorations)
  in `parseEntityDefinition`; `loadPlayerLoadout` + the enemy parse site pass
  the allocator the new signature requires. `entityDefinitionsEqual` compares
  color_index + layers (new `entityLayersEqual`).
- **Entity rendering:** `entityDrawable` takes `active_theme` +
  `player_color_index`. Player (team 0) → `player_gradient.colors[
  settings.player_color_index]` (settings-driven, overrides the entity field);
  enemies → `enemy_gradient.colors[entity.color_index]`. Layers resolve into
  the same team gradient as their base. New `EntityDrawable.layer_sprites`
  slice drawn after base, before weapons (order: back effects → base → layers
  → weapons → gear → front effects). `playerColor`/`enemyColor` helpers
  mirror `worldGradientColor`.
- **`EntityDrawable` gained `layer_sprites`:** the body-overlay slot (was
  only `gear_sprites`, which draws after weapons). Renderer updated.
- **Settings:** `player_color_index: u32` (default 0) in the Gameplay section;
  `data/settings.txt` carries `player_color_index 0`.
- **UI coloring:** `buildBottomBar` takes `active_theme` + `player_color_index`.
  Fixed player-gradient indices (independent of the player's chosen body
  color): inventory/gear/skills buttons = 4; health globe bg = 5, fill = 1,
  border = 3; skill slot bg = 3, skill icon = 1; skip bg = 5, skip icon = 1;
  turn-step indicators = 3; momentum = 3; weapon swap = 3. Colors threaded
  through `emitSkillButton`/`emitIconButton` (new color params).
- **`view()` signature:** gained `settings: types.Settings` param (for
  `player_color_index`); `main.zig` call site passes `history.settings`.
- **Sample content:** skeleton in level_1 carries `color_index 3`.

### Weapon coloring + displays_weapons (done)

- **`displays_weapons: bool`** on `Entity` (default true). Parsed from
  `displays_weapons true|false` in the enemy definition. `entityDrawable`
  suppresses weapon sprites when false (for non-humanoid enemies like wolves).
  Compared in `entityDefinitionsEqual`.
- **Weapon color = team gradient index 1:** player →
  `player_gradient.colors[1]`, enemy → `enemy_gradient.colors[1]`.
  `weaponSprite` takes a `color` param (was hardcoded `world_white`);
  `entityDrawable` computes it from the team.

### Cleanup: test free helpers, entity ownership, view() context (done)

Three quality-of-life cleanups from a mid-session reflection:

**1. Test free helpers (`freeLevel`/`freeHub`/`freeEntity`/`freeDecoration`/
`freeItem`).** Every test that loads a level/hub had a manual defer block
freeing owned slices. Adding a new heap field (footprint, layers) meant
updating every test's defer or leaking. Now `freeLevel`/`freeHub` deep-free
everything; tests call one line (`defer freeLevel(level, allocator)`). The
helpers live in parser.zig (pub) alongside the loaders.

**2. Entity/decoration ownership: fully owned per-placement.** The layout walk
now `cloneEntityOwned`/`cloneDecorationOwned`/`cloneItemOwned` each placed
entity/decoration/item so the level fully owns its data (strings + arrays),
with no sharing with the definition hashmaps. `parseEntityDefinition` and
`parseDecorationDefinitions` still return borrowed strings + owned arrays
(unchanged); the clone happens in the layout walk. Hashmap cleanup
(`freeEnemyDefinitions`/`freeDecorationDefinitions`) frees the owned arrays
(footprint/layers) before `deinit`, so tests don't leak from the hashmaps
either. The hub player's name/sprite (was string literals) and mission exits'
mission_id strings (was borrowed from pairs) are now duped too, so `freeHub`
can free everything uniformly. In production, the arena absorbs all of this —
the clones are a few extra arena allocations freed on arena reset.

**3. `view()` RenderContext struct.** `view()` had grown to 11 parameters.
Bundled the 6 per-frame render params (camera, camera_zoom, event_history,
level_start_index, current_event_index, frame_allocator) into a
`RenderContext` struct, reducing the signature to 6 params. The body uses
local aliases (`const camera = render.camera;` etc.) so no body code changed.
Call site in main.zig updated to pass an anonymous struct literal.

### Sprite id convention: bare stems everywhere (done)

Config `sprite` values were inconsistent: entities/weapons/skills stored the
bare stem (`skeleton_1`), decorations stored the full path
(`decorations/tree_1`). Standardized on BARE STEMS everywhere — decorations
now use `tree_1`, `tree_1_canopy`, `stone_1` in config, matching the entity
convention. Code prepends the asset folder uniformly: `entities/{s}`,
`decorations/{s}`, `weapons/{s}`, `skills/{s}`.

- `decorationSpriteIdFromName` simplified: always prepends `decorations/`
  (removed the `/` passthrough check).
- `resolveDecorationSpriteDimensions` added to parser: prepends `decorations/`
  before the comptime sprite-metadata dims lookup (the table is keyed by full
  asset-relative path `decorations/tree_1`, but config stores the bare stem).
- Sample content (level_1, hub) + test fixtures updated to bare stems.

### file_format_version on all config files (done)

`file_format_version` was only on session logs. Added it to EVERY config file
type: levels, hubs, missions, campaigns, player saves, settings, color themes,
player loadouts. Each file's first section (Metadata / Info / Audio /
GlobalColors / PlayerLoadout) carries `file_format_version 1`.

- Per-type version constants in parser.zig: `level_file_format_version`,
  `hub_file_format_version`, `mission_file_format_version`,
  `campaign_file_format_version`, `player_save_file_format_version`,
  `settings_file_format_version`, `color_themes_file_format_version`,
  `player_loadout_file_format_version` (all 1).
- `validateFileFormatVersion(sections, header, expected)` shared helper: reads
  the version from the section's first entry group, returns
  `error.UnsupportedFileFormatVersion` on mismatch or absence (required — hard
  gate). Validate-and-discard: the version is NOT stored on the parsed type
  (it's a parse-time check, not runtime state).
- Each loader calls it after `validateSections`. `loadPlayerLoadout` changed
  from `types.Entity` to `!types.Entity` to propagate the error.
- `writePlayerSave` emits `file_format_version` in the Info section.
- All shipped data files + test fixtures updated to carry `file_format_version 1`.

### Metadata section unification (done)

Every config file type now has a `Metadata` first-section before its
type-specific sections. Previously, `file_format_version` lived in the first
type-specific section of each file (Info for saves, Audio for settings,
GlobalColors for color themes, PlayerLoadout for player.txt) — which read
wrong (version isn't player info / audio config). Now all file types use the
same shape: `Metadata` (with `file_format_version`) first, then type sections.

- `Metadata` added to the section whitelists for settings, player save, color
  themes. (Levels/hubs/missions/campaigns already had it.)
- `validateFileFormatVersion` calls unified on `"Metadata"` for all types.
- `writePlayerSave` emits a `Metadata` section before `Info`.
- All shipped data files (settings, color_themes, new_player, autosave,
  player.txt) + test fixtures updated.

### Replay verification — natural-stack replay + verifyReplayMatch (DONE)

- The replay loops (`replayTo` / `replayToWithIdleTracking`; `restoreTo`'s
  slow path delegates to `replayTo`) use the **natural stack** to drive replay
  + verification. Instead of force-feeding each recorded event and discarding
  handler outputs (the old model, which was robust to nondeterminism but
  couldn't validate), `processEvent`'s pop/push machinery runs naturally:
  before each dispatch, the stack top is the event that should run next, and
  `verifyReplayMatch` confirms it equals `history[current_event_index]`.
  Handler-pushed children interleave with their own subtrees in the recorded
  stream, and the stack tracks that interleaving for free (it IS the DFS
  cursor). When the stack drains, the loop seeds the next recorded top-level
  event (top-level events come from player input, not handlers, so the
  recording is authoritative there and the check is trivial). This replaced
  the earlier `verifyReplayStep` (a flat slice comparison of handler-pushed
  children against the next N recorded entries), which was STRUCTURALLY WRONG:
  a handler's children are interleaved with their own subtrees in the stream,
  so `history[i+1 .. i+1+N]` is not the N children — it's child[0] followed by
  child[0]'s subtree. The flat check false-positived on the first real session
  log (`move_player` pushing `[start_mission, end_hub]` with `end_hub` pushing
  `build_data_from_player`). The natural-stack model is both correct AND
  simpler.
- Comparison via `deep_copy.deepEqual` (comptime-generic, mirrors `deepCopy`:
  slices/optionals/tagged unions/structs/arrays/scalars; no floats in event
  payloads so exact `==` is correct) + `deep_copy.firstDiffField` (names the
  first differing field, recursing through union payloads into the payload
  struct, for the panic message). Both auto-track new fields via reflection.
- Mismatch = fail-fast `@panic` (per error policy) naming the recorded event
  index, both variant tags (`eventName` helper), and the first differing
  payload field.
- Runs for ALL replay origins including cross-session
  (`reconstructFromEventLog`) — a divergence is a nondeterminism bug we want
  surfaced, not silently rebuilt state. (Cross-session replay of a custom
  mission whose files changed since the original session WILL panic — accepted
  as fail-fast; the reconstruction cache is deterministic for shipped content
  and within-session replay. Closing the custom-mission cross-session gap
  lands with cache serialization into the session log, planned
  `file_format_version` 2.) This is also the primitive Online Services wants
  for server-side replay validation (leaderboard anti-cheat).
- **Semantic shift:** replay is now strict-verification, not robust-rebuild —
  a nondeterministic handler panics instead of the state silently staying
  correct via force-fed recorded events. Idle-point derivation in
  `replayToWithIdleTracking` simplified: the real `event_stack.len` replaces
  the old virtual-depth bookkeeping (idle = stack empties).
- Tests: `deepEqual`/`firstDiffField` unit tests (deep_copy.zig) covering
  equal/differing scalar, slice len + element, optional, union tag mismatch,
  union payload field recursion; integration test "replay verification: clean
  replay through the slow path passes" (main.zig) forward-plays a session,
  evicts all snapshots + checkpoints to force `restoreTo`'s slow path on every
  undo/redo (full replay from initial_state), and confirms a clean replay
  verifies every event without tripping the panic. (No `expectPanic` in std,
  so the tampered-history negative case is covered by the deepEqual unit
  tests + the obvious `@panic` call in verifyReplayMatch.)

### Replay player-action legality validation (DONE)

`verifyReplayMatch` (above) is a STRUCTURAL check — does the handler-pushed
event match the recording? For TOP-LEVEL player events it's trivially true
because the replay loop SEEDS them from the recording, so the recording is
authoritative for WHAT the player did but nothing checked it was LEGAL. A
hand-crafted replay can inject `player_use_skill{skill_not_equipped}` or
`player_move_action{tile_20_squares_away}` and the handlers would execute
it (they trust their inputs; the live input path is the only gate, and
replay bypasses it). `GameStateHistory.validatePlayerAction` closes that gap.

- **Seam:** called in `replayTo` / `replayToWithIdleTracking` right BEFORE
  seeding a top-level event from the recording — the one site where the
  recording becomes authoritative. Handler-pushed children are never seeded
  (they're already on the stack from the handler push), so they never reach
  this gate; their legality is enforced by the parent handler's own logic +
  `verifyReplayMatch` structurally.
- **Validated orchestrators:**
  - `player_move_action{destination}` — destination must be in
    `functions.reachableTiles(level, player.pos, getEffectiveSpeed())` (full
    BFS over walkable tiles, entity-blocking respected; matches live legality
    exactly, catches both "moved too far" and "moved through a wall").
  - `player_use_skill{skill_id, target}` + `player_skip_move_to_skill`
    (when `!prepare`) + `player_prepare_skill{skill_id}` — skill must be in
    `player.collectSkillSlots()` AND `player.skill_cooldowns.get == 0`; for
    use/skip-to-use of a `uses_targeting` skill, the target must be in the
    skill's `getValidTargets(0, current_state)` (e.g. hostile within range,
    empty tile for teleport skills).
  - `player_skip_move` / `player_skip_attack` / `player_cancel_skill` — no
    payload to validate. Non-level / non-player events — no-op.
- **Testability split:** the legality LOGIC lives in bool-returning helpers
  (`isPlayerMoveLegal`, `skillOnBarAndOffCooldown`, `skillTargetLegal`);
  the `validate*` wrappers are a thin panic-policy layer that formats a
  message + `@panic`s on false. Zig 0.16 has no `expectPanics`, so the bool
  helpers are tested directly (state.zig): reachable vs. unreachable move,
  on-bar vs. off-bar skill, off-cooldown vs. on-cooldown, valid vs. invalid
  vs. null target, non-targeting skill accepts null. The panic path itself
  isn't unit-tested (same stance as `verifyReplayMatch`).
- **Failure mode:** fail-fast `@panic` for now (malicious replay = reject).
  A future viewer-facing load may soften to the error popup (DESIGN → Error
  Handling); server-side leaderboard validation keeps it hard. This is the
  primitive Online Services wants for server-side replay validation.
- **Cost:** one BFS + one `getValidTargets` per player move/skill event
  during replay (current_arena-backed, reclaimed on arena reset). Negligible.
- The existing legal round-trip test (main.zig) still passes — the validator
  doesn't false-positive on legal play.

### Mission content hash (DONE — computation primitive, no wiring yet)

- `src/content_hash.zig`: `computeMissionHash(file_source, allocator,
  mission_path, level_count) !ContentHash` — SHA-256 over the mission's raw
  file bytes, canonicalized (paths sorted lexicographically; each file fed as
  `<path>\n<bytes>` so identical-content files at different paths hash
  differently). `ContentHash = [32]u8`; `hashToHex` → 64 lowercase hex chars
  for display/session-log storage. NO line-ending normalization for v1.
- File set v1: CONFIG files only — `mission.txt` (required), `player.txt`
  (optional, skipped if absent), `level_1..level_{count}.txt` (required
  within the declared count). Custom assets (sprites/audio under the mission
  folder) are NOT yet hashed: FileSource has no directory-listing API and
  custom assets don't exist yet. The canonicalization scheme is stable for
  an arbitrary file set, so the extension is additive when the VFS lands.
- Missing required file → `error.FileNotFound` (fail fast). Missing optional
  (`player.txt`) → skipped.
- Tests (4, all via the REAL FileSource persistent-dir read path, writing
  scratch files under `zig-cache/test-content-hash-*` cleaned up with
  `deleteTree`): determinism (same set → same hash), content-sensitivity
  (mutating a level file changes the hash), missing-required-file errors,
  `hashToHex` encodes correctly.
- NOT wired yet (computation primitive only). Session-log recording of the
  mission content hash (for replay pinning) + reading it on
  cross-session replay lands with the VFS / custom-mission replay work.
  See DESIGN → Custom Missions & Online Services → Content identity.

### Turn counters (DONE)

- `Mission.turns_spent` (per-mission) and `PlayerData.turns` (cumulative
  lifetime) are both incremented in the player's `turn_end` handler
  (entity_index 0 branch, event_handlers.zig). The per-mission counter
  increments in all modes; the cumulative counter is SKIPPED in editor
  playtest/validate (guard: `current.editor == null`) so the editor session
  doesn't inflate the player's real turn count. Both were pre-existing
  fields that were never written; now wired.
- Replay-safe: both are direct GameState writes inside an event handler →
  reproduced on replay. `PlayerData.turns` is NOT synced through
  `build_data_from_player` (it's a direct PlayerData field, not an entity
  field).
- Test: "turn counters: per-mission increments, cumulative skipped in
  editor mode" (main.zig) — enters a playtest, skips move + attack (one
  full player turn), asserts `turns_spent == 1` and `player_data.turns == 0`
  (editor mode guard).
- Medal derivation (gold/silver/bronze from author turns) and the validation
  replay metadata format are DESIGNED (see DESIGN → Custom Missions → Turn
  counters + author medals) but NOT yet implemented — they land with the
  validation replay format (session-log + reconstruction cache,
  `file_format_version` 2) and the browser/mission-complete UI.

### listCustomMissions + custom-mission folder convention (DONE)

- `FileSource.listCustomMissions(allocator) -> []CustomMissionEntry`
  (file_source.zig): enumerates `custom_missions/` in the persistent dir,
  one entry per subdirectory. Each entry carries `id` (folder name), `name`
  + `level_count` (parsed from the folder's mission.txt in a throwaway
  arena), `has_custom_assets` (true if the folder has any file beyond
  mission.txt / player.txt / level_*.txt, detected via directory iteration),
  and `author_turns: ?u32` (null — unvalidated — until the validation replay
  format lands). Folders without a readable mission.txt are skipped (broken
  / half-installed missions aren't offered). Returns an empty list when
  `custom_missions/` doesn't exist (fresh install). Caller owns the slice +
  all strings.
- **Folder convention settled:** `custom_missions/<id>/` where `<id>` is the
  folder name. Editor-generated + online-downloaded missions use
  `<uuid>_<slug>` (UUID at creation, stored in `mission_uuid` in mission.txt,
  stable across re-saves). Hand-placed folders with any name are ALSO
  accepted — generation/download follow the convention, reading tolerates
  anything (two authors with the same display name get different UUIDs → no
  collision). `mission_uuid` is NOT yet a Mission field / parser key — it
  lands with the editor save flow.
- `matchesLevelFile` helper: matches `level_<N>.txt` for 1 <= N <=
  level_count, used by `folderHasCustomAssets` to know which level files are
  expected config vs custom assets.
- Tests (file_source.zig, scratch dirs under `zig-cache/test-list-custom-*`
  cleaned with `deleteTree`): empty-when-absent; populated (plain-folder
  mission with no custom assets + UUID_slug mission with a custom sprite +
  a broken mission that's skipped) — asserts id/name/level_count/
  has_custom_assets/author_turns per entry.
- NOT wired into UI yet (the browser overlay is the next chunk). The read
  path (`start_mission` against `custom_missions/<id>`) already works via
  the existing FileSource persistent-dir layer.

### Editor event + type scaffolding (DONE — definitions only, handlers pending)

The full editor event set and supporting types are defined; handlers are the
next slice.

**New types (types.zig):**
- `CustomColorTheme` — 3 gradients (world/enemy/player), the optional per-
  level/per-hub theme override. `Level`/`Hub`/`EditorLevel` each gained
  `custom_theme: ?CustomColorTheme = null` (backward compatible — null on
  older files, `activeThemeFor` checks null → derive from `color_wheel_index`
  as before, non-null → build from the override).
- `ItemTypeDef` — palette entry for loose ground items (`{ id, item: Item }`).
  The Item union's variety makes per-field granularity impractical, so the
  inspector edits the whole item (one `editor_set_item_def` event per
  commit).
- `EntityEditTarget` — tagged union `{ entity_type: u32, player_def: void }`,
  so the entity-edit events cover both palette enemy types AND the editor-
  global player loadout without a parallel `editor_set_player_*` set.
- `ItemPlacement` — `{ type_id, position }` into `Editor.item_types`;
  `EditorLevel` gained `item_placements`; `Editor` gained `item_types`.

**Event variants (events.zig):** the full `EditorEvent` set (~50 variants)
covering level management (`editor_add_level`/`editor_delete_level`/
`editor_set_active_level`), tiles (`editor_set_tile` per cell), level +
mission metadata (name, color wheel, custom theme), player start + level
end (move-only), palette type management (`editor_add_*_type`/
`editor_delete_type` with `EditorTypeKind`), placement (per-kind place/
delete/move for entity/decoration/item), entity type editing (per-field
dedicated variants for name/sprite/color/displays_weapons/stats/gear/
utility skills/layers, each carrying `EntityEditTarget`), decoration type
editing (per-field), and item type editing (`editor_set_item_def` whole-item
+ `editor_set_item_name`). `SubEditorEvent` holds the placement-deletion
verbs pushed by `editor_delete_type`'s orchestrator. `EditorTypeKind` enum
for the three palette groups.

**One-orchestrator-per-action convention:** most editor events are single
verbs (the action IS the verb). The one orchestrator is `editor_delete_type`
(pushes `editor_delete_*_placement` sub-events for each referencing
placement, then removes the type). Per-field granularity by design (one
field = one undo); the Item union is the sole exception (whole-item event)
due to its variety.

**Session-log serializer extended (parser.zig):** `appendEventScalar` +
`parseScalarTokens` gained `.array` (fixed-size arrays like `[6]Color`,
flattened space-separated) and `.@"union"` (tagged unions as
`<tag> <payload-fields...>`, void payload = just the tag) support. Also
`parseScalarTokens` gained `.pointer` for `[]const u8` fields inside
flattened structs/unions (e.g. `Weapon.name`), duped via the caller's
allocator — threaded `allocator` through `parseScalarTokens` for this. New
editor events with Weapon/EntityLayer/CustomColorTheme payloads now
round-trip.

**Handlers (event_handlers.zig):** `handleEditorEvent` + `handleSubEditorEvent`
are placeholder stubs that `@panic("not yet implemented")` — the `.editor_event`
arm dispatches `editor_set_active_level` inline (existing) and routes the rest
to `handleEditorEvent`. Implementation is the next slice (mechanical — each
sets a field on `current.editor.?.levels[]` or the palette).

**Design decisions settled (DESIGN → Architecture → Level Editor):** full UI
layout spec (tabs/viewport/bottom-bar palette/left inspector/right metadata
panel), active-tool model (fully modal), `Selectable` union + multi-select +
type-inference rule, no-dialogs (inline inspector selectors), commit-on-blur/
Enter for field edits, Test/Validate top-right, Upload deferred, panel toggles
as 128×128 edge-sticking icons (SessionState, not events), save as input-path
side effect (not an event).

### SubEditorEvent dropped (DONE — cleanup)

`SubEditorEvent` was a wrong abstraction. The gameplay `SubLevelEvent` split
exists because `attack`/`stun`/`death` are engine-pushed consequences, never
direct player actions — a real category. In the editor, placement deletion is
BOTH a direct player action (select + Delete) AND a sub-action pushed by
`editor_delete_type` — same verb, same handler, two contexts. Duplicating it
into a second union was redundant. Removed `SubEditorEvent`, its three
variants, the `sub_editor_event` arm on `Event`, the dispatch arm in
`processEvent`, and the `handleSubEditorEvent` stub. `editor_delete_type`'s
handler (when implemented) will push `EditorEvent.editor_delete_*_placement`
values directly — same as how `player_move_action` pushes `move_entity` (both
LevelEvents). The placement-deletion variants now live only in `EditorEvent`.
Also removed the `sub_editor_event` references in `combat_log.zig` (tier
none) and `state.zig` (`eventName`).

### Comment convention + drift cleanup (DONE)

Settled the in-code comment convention (now in AGENTS → Code Style → Code
Comments): comments describe the code as-is, TODO.md owns all forward-looking
notes, no `TODO`/`FIXME`/`HACK` markers or "lands later"/"for now" prose in
code. File-level `//!` headers on files with a distinct architectural role
(`raylib_backend.zig` is the model); skill/effect files self-document via
`///` on their defining const. Link to AGENTS instead of restating settled
designs inline.

Cleanup pass under that convention:
- **Dead code removed:** the duplicate `skill_slot_selected`/`cancel` stubs
  at the tail of `handleIdleInput` (the real handlers live in the
  `.player_attack` case; the tail blocks never fired); the unused
  `computeFrameLength` + its `Settings` import in `functions.zig`; the
  vestigial `DecorationId` enum (only a `placeholder` variant), the
  `Decoration.decoration_id` field, and its three `null` initializers.
- **Comment drift fixed:** ~25 comments across `raylib_backend.zig`,
  `view.zig`, `ui.zig`, `state.zig`, `file_source.zig`, `content_hash.zig`,
  `types.zig`, `events.zig`, `input.zig`, `input_handlers.zig`, `main.zig`,
  `web.zig`, `event_handlers.zig`, and the skill/effect files that described
  done work as "future"/"later" (world drawing, entity weapons/layers,
  FillSprite/health-globe tints, arrow-key cursor nudging) or pointed at the
  old `TODO.txt` (now `TODO.md`) — reworded to as-is descriptions or
  `DESIGN → <section>` links.
- **`//!` headers added** to the 10 core files lacking one (`main.zig`,
  `state.zig`, `types.zig`, `events.zig`, `functions.zig`, `input.zig`,
  `parser.zig`, `ui.zig`, `combat_log.zig`, `deep_copy.zig`);
  `///` const docs added to the two `that_which_lingers` outliers (skill +
  effect) to match their siblings' self-documenting style.

### Architecture cleanup: main.zig split + test harness + minimize-pub (DONE)

Follow-up to the codebase review, three pieces:

**`main.zig` split.** The composition root held three responsibilities
(game loop, `update`, *and* all startup config loading). Extracted the
config-loading half into `src/session_setup.zig`: `loadSettingsFromDisk` /
`loadColorThemeDefinitionsFromDisk` / `loadWeaponTypeDefinitions` /
`loadSalvageDefinitionsFromDisk` + `SessionSetup` / `createSessionSetup` /
`fixupPointers` + `FrameState` (moved here so the module is a leaf:
`main → session_setup`, never the reverse). The cleaner separation: the
entry files (`native.zig`, `web.zig`) now call `session_setup.createSessionSetup`
→ `fixupPointers` → `main.run(&backend, &setup)`; `main.run` no longer builds
the setup itself. `main.zig` keeps the loop (`gameLoop`/`frame`/`run`),
`update`, `runToIdle`, and the tests. `weapon_type_count` exposed `pub` from
`session_setup` so the harness can name the array type.

**Test harness.** `src/test_harness.zig` (test build only): `Harness.init(arena)`
loads the four configs + a cwd-backed FileSource into the test's backing arena;
`harness.newHistory(starting)` spins a fresh `GameStateHistory` against them;
`runToIdle` drives event processing to stack-empty with the live idle-point
bookkeeping. A smoke test confirms the bootstrap loads + a fresh history
reaches the main menu. The existing main.zig tests keep their own `runToIdle`
(still `fn` there). TODO updated: the handler-coverage item now points at the
harness as the reusable primitive, with a prioritized list of first targets
(equip/unequip, utility-skill slots, boots move-range, prepared-skill cancel,
combat death/loot, enemy AI tiebreaks).

**Minimize-pub rule.** Added to AGENTS → Code Style: mark a symbol `pub` only
if another file imports it; everything else file-private. The compiler errors
on unused file-private symbols, so this is a free dead-code detector — the
class of dead `pub` scaffolding the cleanup removed (`computeFrameLength`,
`DecorationId`) survives precisely because `pub` symbols aren't checked. No
Zig tool reliably detects unused `pub`; the discipline is the lever.

**Small fixes folded in:** the orphaned `computeMinRange` doc (lived in
`input_handlers.zig` above `resolveTileCursor`; the function is in
`event_handlers.zig`) moved to its function; five `\u2014` literal escapes
(`ui.zig`, `skills/reflect.zig` ×2, `skills/stone_form.zig`, `types.zig`)
replaced with real em dashes; the dead world-map graph scaffolding
(`worldMapSpaceGraph`/`relaxGraphEdges` in `functions.zig`; `HubNode`/
`MissionEdge`/`CampaignGraph`/`PositionedHubNode`/`PositionedMissionEdge`/
`PositionedCampaignGraph` + `Campaign.campaign_graph` in `types.zig`) removed
— unused since first written; revisit when the world-map UI lands.

### Handler test coverage — Tier 1 (gear/skill mechanics) (DONE)

First tier of `processEvent` handler tests, in `src/handler_tests_gear.zig`
(22 tests, picked up by the automatic test-root scan). Uses the
`test_harness.zig` harness: each test builds a hub-context player (no level
needed — the gear side effects early-return without one), sets up known
inventory/gear directly on the entity, pushes one `PlayerEvent`, runs to idle,
and asserts on `current_state`.

Coverage (branch-complete per handler):
- `equip_item`: empty-slot no-op, type-mismatch no-op, into-empty-gear, swap-
  with-filled (old piece drops back into the SAME inventory slot).
- `unequip_item`: empty-gear no-op, into-empty-slot, swap-on-fit, swap-on-
  mismatch no-op.
- `learn_skill`: empty-slot no-op, non-tome no-op, already-learned no-op (tome
  stays), valid consume+add.
- `salvage_item`: empty-slot no-op, valid remove + material yield (asserts
  materials == before + `computeSalvageValue`).
- `equip_utility_skill`: out-of-range no-op, valid set, overwrite-filled.
- `swap_utility_skills`: either-index-out-of-range no-op, valid swap, two-null
  swap (no crash).
- `unequip_utility_skill`: out-of-range no-op, valid clear.

Key testing lesson: `runToIdle` → `recordIdlePoint` → `compactCurrentArena`
  deep-copies `current_state` into a fresh arena, so `[]const u8` slice
  POINTERS change (contents survive). `testing.expectEqual` on structs with
  slices compares slice headers (ptr+len) → fails on pointer inequality. The
  tests identify items by unique scalar fields (`weapon_damage`, `speed_bonus`,
  `spell_damage`) via small helpers (`expectWeapon`/`expectBoots`/
  `inventoryWeaponDamage`/`inventoryBootsSpeed`) rather than struct equality.
  Future tiers follow the same pattern.

### Handler test coverage — Tier 2 (combat primitives + gear side effects) (DONE)

Second tier, in `src/handler_tests_combat.zig` (34 tests). The harness gained
`levelStateWithEntities(arena, entities, tiles)` + `levelEntity(history, i)`
for level-context fixtures (entities allocated as `[]Entity` in the backing
arena, handed to the level as `[]const Entity` — handlers mutate via
`@constCast`, matching the live `getLevelEntity` path). A shared 3x3 tile grid
(`three_by_three`) gives combat room without crowding.

Coverage (branch-complete per handler):
- `heal`: clamp-to-max, dead-no-revive, partial.
- `change_momentum` / `change_cooldown`: add + saturate-at-zero, dead-no-op.
- `attack`: dead-attacker/dead-defender no-ops, defense subtraction, kill→
  pushes death, `heals_attacker` lifesteal.
- `death`: non-player drops equipped gear + inventory + skill tomes (one stack);
  merges into an existing stack at the same position; player (entity 0) drops
  nothing.
- `pickup_items`: full transfer (stack removed), leftovers when inventory
  full (stack stays), first-empty-slot placement.
- `stun`: dead-no-op, applies duration, zero-effective (StoneForm
  `incoming_stun_duration = -5` clamps a 2-stun to 0) adds nothing.
- `knockback`: moves defender away, edge collision applies `knockback_damage`,
  dead-no-op.
- `collision`: applies damage + can kill, dead-defender no-op.
- `retreat`: moves away from target, dead-no-op.
- `create_effect`: adds new, extends existing (no duplicate), dead-receiver
  no-op.
- `end_effect`: removes the named effect (others stay).
- Gear side effects (level context): equip-boots during `player_move` →
  `refreshMoveHighlights` (speed 2 from center of 3x3 → 8 reachable tiles);
  equip-weapon → `cancelPreparedSkill` (prepared `.slice` cleared).

All confirm-exist (no logic fixes): the handlers already behave per the
`events.zig` doc comments; the tests pin them against regressions. The
deep-copy/`expectEqual` pattern from Tier 1 carried over (scalar-field
comparison; for ground stacks and active_effects, assert `.len` + enum/
duration scalars rather than struct equality).

### Handler test coverage — Tier 3 (AI + determinism) (DONE)

Third tier, in `src/handler_tests_ai.zig` (15 tests). The harness's
`levelStateWithEntities` + `levelEntity` cover the fixture needs; AI tests use
a 5x5 tile grid (`five_by_five`) for movement room. Enemies get weapon skills
via `main_hand_weapon = .{ .weapon_type = .dagger }` (skill_1 = stab, range 1,
turn-ending, 1.5x above half health).

Coverage (branch-complete per handler):
- `aggro_around`: activates opposing entities within `aggro_range`; out-of-
  range stay inactive; same-team skipped; dead skipped; already-active stay
  active (no deactivation).
- `pickup_around`: pure check (no mutation) — pushes one `pickup_items` per
  in-range ground stack; radius-0 reaches only the entity's own tile.
- `enemy_turn_move`: nearest-target tiebreak resolves to the lowest
  `entity_index` (strict-< scan in index order — the determinism convention);
  already-within-min-range holds position (skips to attack); no opposing
  entities → `turn_end`; moves up to `speed` steps along the path toward the
  target without entering its tile.
- `enemy_turn_attack`: no usable skills → `turn_end`; turn-ending weapon skill
  fires when a target is in range (stab 1.5x above-half: 5 + 5/2 = 7 dmg);
  on-cooldown skill skipped; out-of-range target → priority 0 → skipped.

One assertion fix (test bug, not code bug): stab's 1.5x bonus is integer
math (`damage + damage / 2` = 7, not 7.5), so 20 - 7 = 13, not the 15 I first
expected. The handler/skill were correct; my expected value was wrong. This
is the determinism-critical tier (the audit found one real bug here); the
tests now pin the tiebreak + selection rules against regressions.

### Handler test coverage — Tier 4 (turn-flow orchestrators) (DONE)

Fourth and final tier, in `src/handler_tests_turnflow.zig` (22 tests). New
technique: orchestrator/ordering tests call `processEvent` once and inspect
`event_stack` (LIFO order) rather than `runToIdle` — this pins the exact
push order without the pushed events running and obscuring the structure.

Coverage (branch-complete per handler):
- `turn_start`: reduces all skill cooldowns by 1; decrements effect durations
  + pushes `end_effect` for expired (the active_effects list is rebuilt before
  end_effect runs, so expired effects are already gone); stunned entity skips
  turn (pushes `turn_end`, not the move event, and decrements stun); player
  (entity 0) pushes `player_turn_move`; enemy pushes `enemy_turn_move`; dead
  entity is a no-op.
- `turn_end` (player): pushes the next round — player `turn_start` at the
  bottom, enemies sorted by distance ascending with ties broken by
  `entity_index` (lowest first = closest to stack top = processed first — the
  determinism convention); inactive enemies skipped; dead enemies skipped;
  increments `mission.turns_spent`; non-player `turn_end` pushes nothing
  (the next `turn_start` is already on the stack).
- `player_turn_move`: sets `turn_phase = .player_move` + refreshes highlights.
- `player_turn_attack`: auto-skips to `turn_end` when no active enemies
  (default setting on); enters `player_attack` when enemies exist;
  `force_attack_step` overrides auto-skip.
- Orchestrator fan-out (LIFO order pinned): `player_move_action` → [player_
  turn_attack, clear_highlights, move_entity] (move runs first); `player_skip_
  move` → [player_turn_attack, clear_highlights]; `player_skip_attack` →
  [turn_end, clear_highlights, clear_prepared_skill]; `player_cancel_skill`
  → [clear_highlights, clear_prepared_skill]; `player_use_skill` turn-ending
  → [turn_end, use_skill, clear_highlights, clear_prepared_skill];
  non-turn-ending → [use_skill, clear_highlights, clear_prepared_skill] (no
  turn_end).

All confirm-exist (no logic fixes). The two `turn_end` ordering tests pin
the distance-then-entity_index rule — the other determinism-critical
behavior beyond Tier 3's AI tiebreaks.

**Handler test coverage complete:** 93 tests across 4 files (gear, combat,
AI, turn-flow), 161 total with the pre-existing 68. The `processEvent` rules
are now pinned against regressions — especially valuable for the editor UI
+ drag-drop work coming next, which will push many events through these same
handlers.

### Test workflow: scripts/test.sh + Build & Test note (DONE)

`zig build test` exits 0 on success but can print a `failed command: .../test
...` line whenever a test writes to stderr (advisory warnings, etc.) — that
line looks like failure. `scripts/test.sh` is the fix: runs
`zig build test`, labels advisory output `[advisory, non-fatal]`, surfaces
only real failures (with expected/found), dedupes the summary line, and ends
with an unambiguous `PASS (exit 0)` / `FAIL (exit N)`. Verified both paths
(injected a failing assertion → FAIL with the failure surfaced; restored →
PASS). `--raw` prints the full verbatim output if needed.

AGENTS → Build & Test now documents the workflow: prefer `scripts/test.sh`,
trust the exit code not the text, don't fish for binaries in `.zig-cache/o/`.

### Cross-project conventions in APPEND_SYSTEM.md + AGENTS.md drift sweep (DONE)

The AGENTS/TODO/DONE trio + lifecycle, the code-comment rules (no in-code
`TODO`/`FIXME`/`HACK`, file-level `//!` headers, link-don't-restate), the
collaboration style, and the "stay inside the cwd" boundary are cross-project
working conventions. Added them to `~/.pi/agent/APPEND_SYSTEM.md` (loaded as
system context each session, so they apply to every project without
restating). Also added a "Using the `edit` tool" section there (raw-literal
`oldText`, prefer small unique edits, re-read on no-match, exact indentation)
to mitigate the edit-tool retry friction seen this session.

**These stay in ziglop's AGENTS.md too** — AGENTS.md must be self-contained
for anyone working in the repo (a different harness, a contributor reading it
on GitHub, a fresh checkout without `~/.pi`). The .md trio + lifecycle and the
Code Comments subsection describe how *this project* is organized, so they're
project conventions regardless of also being the cross-project default. Only
the collaboration *style* (small steps, checkpoints, tradeoffs, cwd boundary)
is APPEND-only — that's working style, not project structure, and a
blockquote pointer in AGENTS.md notes where it lives.

Net: AGENTS.md keeps Documentation + Code Comments (self-contained), drops
the duplicated Collaboration section (pointer to APPEND_SYSTEM). Forward-
looking prose sweep fixed two drift cases: "future emscripten build" →
"emscripten build" (web build is done), "lands when custom-mission support
does" → "not wired" (VFS layer). The rest of the "future"/"deferred" mentions
are legitimate settled-deferral scope notes (AGENTS.md's job), left as-is.

### Prepared-skill toggle — same-slot re-activation (DONE)

**The bug.** With a skill prepared (targeting, awaiting a tile),
re-activating the same skill's slot re-fired `player_prepare_skill`:
the handler re-set `level.prepared_skill` to the value it already held
and re-pushed the same `highlight_tiles` event — recorded events, zero
state change. Undo consumed a step and nothing visibly changed (the same
no-op-undo pollution shape as the editor click gate, but here the fix is a
behavior change rather than a gate: the press should DO something).

**The fix.** `resolveSkillSlotAction` (input_handlers.zig — the pure
use/prepare resolver both turn phases share) gained a third case:
when the pressed slot's skill is already the prepared skill, it resolves
to `.unprepare`, and the input branches push the EXISTING
`player_cancel_skill` orchestrator (clear_highlights +
clear_prepared_skill). No new events, no handler changes, no
replay-whitelist or `validatePlayerAction` changes — the press is now a
real undo step (restores both the preparation and its highlight), and the
log reads honestly ("player cancelled skill" rather than a prepare whose
effect was unpreparing). Precedence: auto-target-at-cursor still wins —
if the tile cursor sits on a valid target, the press fires the skill
there (same as clicking the highlighted tile); the toggle only claims the
press that would otherwise re-prepare identically. The move-phase
consumption site gained a matching (unreachable-by-invariant — a skill is
only prepared during the attack phase) `.unprepare` arm so the shared
union switch stays total. `button_click_up` plays on the toggle (same as
the prepare path — feedback that targeting ended; DESIGN → Audio).

Tests: `resolveSkillSlotAction` had zero direct coverage — added decision-
level tests (same-skill → `.unprepare`; cursor-on-valid-target → `.use`
at that target; different prepared skill → `.prepare`), plus an
end-to-end contract test (attack phase, prepared Flash Strike in utility
slot 4 + highlight set, slot re-activation → `player_cancel_skill` →
preparation + highlight cleared, one undo restores both). Fixture:
`preparedSkillToggleHistory` (Flash Strike: targeting, range 3 — empty
reachable tiles are valid targets).

### Input no-op sweep — every player action changes something (DONE)

**The audit.** After the editor click gate and the prepared-skill toggle,
the remaining `PlayerInputEvent` orchestrators were swept handler-by-handler
plus fire-site, looking for player actions that fire, get recorded, and
change nothing (each creates an idle point — a dead undo step, and a dead
step for a future replay viewer). Settled principle now in DESIGN →
Architecture ("A player action that would change nothing never fires").

**The seven cases found + fixed (all input-side gates, handlers untouched
except sound ordering):**

1. Hub own-tile click → `move_player` (same-position reassign). Gate:
  destination != player position. (Player never overlaps a mission exit —
  hubs spawn at the layout's `!` — so an own-tile click can't be an intended
  mission entry.)
2. Shift-drag over an all-empty region →
  `player_salvage_inventory_region` (empty slots are deliberately valid
  region corners). Gate: `salvageRegionOccupiedSlots(...).len > 0`.
3. Drag item → unfitting gear slot → `player_equip_to_gear` (`equip_item`'s
  fit guard no-ops the whole click). Gate: `itemFitsGearSlot` at the drop.
4. Drag gear → inventory slot holding an unfitting item →
  `player_unequip_from_gear` (mirror fit guard). Same gate.
5. Drag learned skill → bar slot already holding it →
  `player_assign_utility_skill` (same value, `max(cd, cd)` unchanged).
6. `swap_hands` with both hands empty (the binding still fired + clicked).
  Gate: any weapon or an active preparation (the handler cancels one — a
  real change).
7. `interact_with_npc` — handler is a literal `{}` stub and the hub click
  path fired it on any NPC tile. The push is gone; the scan stays as a
  MOVE BLOCKER (an NPC's tile is walkable, so removing it entirely let the
  player walk onto the NPC — the hub gate test caught the regression in
  review; a click addressed to the NPC must not move).

**Shared predicates, no drift.** `itemFitsGearSlot` (event_handlers) made
pub — the machinery and the gate call the same one definition of "fits".
`salvageRegionOccupiedSlots` extracted from the region handler so the
handler and the release gate read the same slot list. New
`dragActionWouldChange` (input_handlers, pure over the player entity)
mirrors the drag family's machinery guards — including the
`skill_prepared` parameter: the utility-skill handlers also cancel a
preparation, which IS a change, so e.g. a same-skill re-assign with a
preparation active still fires. Sound ordering fixed alongside:
`equip_item`/`salvage_item` now queue their click sounds AFTER the
empty-slot/fit guards (a no-op must not click).

**Verified clean (no action needed):** level `player_move_action`
(`reachableTiles` excludes the start tile + input gates on highlights),
`player_cancel_skill` (all fire sites gated on a preparation), inventory
clicks (press gated on occupied slots; modifier combos → `.none`),
utility/inventory swaps (self-drop gated in `dragToOrchestrator`; drags
start only on occupied slots), `player_clear_utility_skill`, the editor
family (prior slice), and the exit/skip/replay/overwrite/continue
orchestrators (buttons gated on their precondition state).

Tests: `dragActionWouldChange` decision-level (equip/unequip fit matrix,
assign/swap same-skill ± preparation), handleDrag wiring (unfitting equip
drop, unequip-onto-unfitting, re-assign same skill — all fire nothing,
state untouched), hub clicks (own tile / NPC tile / non-walkable fire
nothing; walkable tile moves), swap binding (both-empty fires nothing,
weapon fires). 377 total pass.

## Error Handling

### Slice 1 — error surface (DONE)

Settled the two-class error policy and built the player-facing surface for
recoverable failures. Settled design + B-simple recording choice in DESIGN →
Error Handling; active slice tracking in TODO → Error handling pass.

- **`SessionState.pending_error: ?[]const u8`** (state.zig): message duped
  into `history_arena` (durable across frames; overwrite leaks the prior
  bytes — accepted, same unbounded-arena tradeoff as `event_history`).
  Helpers `setPendingError(allocator, msg)` / `clearPendingError()` /
  `pendingError()`. Off the undoable GameState → replay-safe by
  construction, like the other SessionState fields.
- **`Action.dismiss_error`** (types.zig): explicit, modal-only action.
- **Input wiring** (input.zig): `AnytimeInput.dismiss_error`, `applyAction`
  arm, `checkAction` call. Bound to Escape + Enter in `data/settings.txt`
  (both keep their existing bindings — list-style bindings allow a key to
  map to multiple actions).
- **`ui.buildErrorPopup`** (ui.zig): centered modal 9-slice panel + "Error"
  header + wrapped body (reuses the tooltip `wrapRow` / `measureRowWidth` /
  `lineHeight` machinery) + a Dismiss button (`emitPanelButton` carrying
  `.dismiss_error`). `blocks_input = true` halts hit-testing within the
  panel. Sizing constants: `error_popup_max_width` 1280, padding 32, header
  72 / body 56 font sizes.
- **`view()`** (view.zig): appends the popup last (topmost draw) when
  `session.pendingError()` is non-null. Pure over SessionState, no file
  access.
- **Modal input gate:** `handleAnytimeInput` (input_handlers.zig) checks
  `pending_error` first — only `dismiss_error` gets through, everything else
  (including undo/redo + options toggle) swallowed. `update()` (main.zig)
  mirrors the options-menu pause with `if (pending_error != null) return;`,
  blocking drag/camera/wait/idle. Dismiss releases the modal in the same
  frame.
- **Tests:** `SessionState pending error: set/read/clear` + `overwrite
  replaces the message` (state.zig); `buildErrorPopup emits a modal panel,
  header, body, and a Dismiss button` (ui.zig — asserts the first element is
  a modal `nine_slice_panel` and a `.dismiss_error` button is present).
- **No real trigger yet** — nothing populates `pending_error` from a real
  load path. Slices 2 (startup-config fallback) + 3 (in-event handlers →
  `!void` + revert) wire the triggers. Visual end-to-end verification lands
  with slice 3.

### Scrollable error popup (DONE)

Upgraded the error popup from a fixed-size panel to a scrollable one so many
warnings (e.g. a mission with many broken keys) display without clipping.

- **`UiElement.solid_rect`** (ui.zig): new variant — a plain filled
  rectangle (no sprite), used for the scrollbar track + thumb. `boundsOf` /
  `tooltipOf` / `blocksInputOf` work via the existing `inline else` arms
  (the struct carries a `tooltip: ?Tooltip = null` field to satisfy
  `tooltipOf`). Renderer arm: `rl.drawRectangleRec` (raylib_backend.zig).
  `blocks_input` defaults false (decorative).
- **`SessionState.error_scroll_offset: i32`** (state.zig): scroll position
  in reference-space pixels. Reset to 0 in `setPendingError` (new error →
  top of content). Clamped to `[0, max_scroll]` in `buildErrorPopup` (the
  view is the only place that knows `max_scroll`, which depends on the
  wrapped line count).
- **`Action.error_scroll_up` / `error_scroll_down`** (types.zig): bound to
  Up/Down arrows in `data/settings.txt` (same keys as `move_cursor_*` — the
  modal gate routes them to scroll, not cursor, while the popup is up; no
  collision thanks to list-style bindings).
- **`handleAnytimeInput` modal gate** (input_handlers.zig): when
  `pending_error != null`, routes `error_scroll_up`/`down` (step = 3 line
  heights) + `scroll_delta` (mouse wheel redirected from camera zoom to
  scroll) to `error_scroll_offset`, and swallows everything else except
  `dismiss_error`. No zoom-while-scrolling: the gate returns before the
  zoom code runs.
- **`buildErrorPopup` rewrite** (ui.zig): takes `*SessionState` (for the
  scroll-offset clamp). Wraps the body, computes `body_content_height` /
  `visible_height` (capped at `error_popup_max_body_height` 1600px) /
  `max_scroll`. Emits only lines within `[scroll_offset, scroll_offset +
  visible_height]` (skips off-screen lines → small element list + clean
  hit-test set). Draws a scrollbar (track + proportional thumb) on the
  right edge only when content overflows. Header + Dismiss button are
  outside the scroll region (always visible).
- **`view()` signature** (view.zig): `session` param changed from
  `*const SessionState` to `*SessionState` for the scroll-offset clamp.
  This is transient view-state housekeeping (not gameplay mutation / I/O),
  consistent with view()'s purity rule.
- **Tests:** short message (no scrollbar, offset clamped to 0) + long
  message (scrollbar present = ≥2 `solid_rect`, offset 0 at top) + offset
  clamped to `max_scroll` on a long message with a huge offset.
- **`error_scroll_line_height`** = 56 (synced with
  `lineHeight(error_body_font_size)`); arrow-key scroll step = 3 lines.
  `error_popup_max_body_height` = 1600 (leaves room for header + button +
  padding within the 2160px reference height). Scrollbar: 12px wide, 16px
  gap from body text.

### B-simple vs transactional recording (decision, DONE)

Chose **B-simple** (per-dispatch recording, accept the redo-loss edge case)
over transactional (defer append + `discardFutureTimeline` to transaction
commit). The transactional model's independent benefits (transaction-
consistent session logs on crash-mid-action; a try/commit/abort primitive)
are marginal with no current consumer beyond the error-handling edge case,
and its costs land in replay-verification code (the reconstruction cache's
`current_event_index - 1` keying would need rework; `current_event_index`
semantics shift ripples to combat-log projection, `levelStartEventIndex`,
replay seeding) where a subtle bug reintroduces silent replay divergence —
the worst class. The current model's "always-committed, always-consistent
index" is a genuinely good property. The edge case (redo unavailable after a
failed post-undo action — no crash, no corruption) is accepted; the
transactional fix remains available if it ever bites in playtesting. Full
reasoning in DESIGN → Error Handling → B-simple.

### Slice 2 — startup-config fallback (DONE)

The four startup loaders (`loadSettingsFromDisk` / `loadColorThemeDefinitionsFromDisk`
/ `loadWeaponTypeDefinitions` / `loadSalvageDefinitionsFromDisk`) now fall back
to the embedded copy when the first read (persistent-dir shadow → embedded)
fails at any stage — read, parse, or `load_fn`. Embedded-copy failure panics
(shipped content is broken, a real bug). A warning is appended per fallback
and surfaced as a single `pending_error` popup after the history is created.

- **`FileSource.readEmbeddedFile(allocator, path) ![]u8`** (file_source.zig):
  reads ONLY from the embedded map, skipping the persistent dir. Used by the
  fallback to bypass a broken persistent shadow.
- **`loadConfigWithFallback(T, file_source, allocator, path, load_fn, warnings)`**
  (session_setup.zig): the shared read+parse+load+fallback helper. `load_fn`
  has shape `fn ([]const Section, std.mem.Allocator) anyerror!T`; a small
  `loadWeaponTypeDefinitionWrapped` adapter covers `loadWeaponTypeDefinition`
  (which takes only sections). Bytes from the successful attempt are leaked
  into `allocator` (process-lifetime on both platforms) — same lifetime
  contract as the existing `parseConfigFileFromPath` path.
- **Settings fallback changed:** was "hardcoded defaults on any failure"; now
  "embedded copy on parse failure, hardcoded defaults only if the embedded
  copy is missing entirely (panic)." The embedded copy is a better fallback
  (preserves keybindings + authored values); uniform policy across all four
  loaders.
- **`createSessionSetup`** collects warnings from all four loaders, creates
  the history, then if any warnings exist, concatenates them into one message
  via `setPendingError(history.history_arena.allocator(), message)`. The
  popup is modal on the main menu until dismissed.
- **Tests:** "broken persistent shadow falls back to embedded + warns" (writes
  a broken `data/settings.txt` to a scratch persistent dir, asserts embedded
  settings loaded + 1 warning mentioning the path) + "no shadow uses embedded
  directly, no warning" (empty persistent dir, asserts embedded loaded + 0
  warnings). Both wrapped in an arena (the helper intentionally leaks config
  bytes into the allocator — process-lifetime in production, arena-reclaimed
  in tests).
- **The popup is now reachable at startup:** malforming a shipped config file
  in the persistent dir (e.g. `~/.ziglop/data/color_themes.txt`) and starting
  the game triggers the popup with a "Failed to parse ...; using built-in
  default" message. Visual end-to-end verification is now possible.

### Key validation — approach A (DONE — infrastructure + level files)

Per-section key whitelists that warn on unknown keys, catching the typo'd-key
class (e.g. `chracter_code` → the permissive parser silently drops the entry;
A names the typo directly). See DESIGN → Error Handling. Soft policy: unknown
keys warn but don't reject (forward-compatible — a newer file still loads on
an older parser with an advisory warning).

- **`parser.validateKeys(sections, key_map, file_path, allocator, warnings)`**
  (parser.zig): walks all sections, looks up each section's header in
  `key_map`, checks every key in every entry group against the whitelist.
  Unknown keys → warning (`"Unknown key 'X' in Section of file"`). Sections
  not in the map are skipped (raw-grid sections like Layout, or sections
  without a defined key set yet). Advisory — never errors, never rejects.
- **`parser.level_key_map`** (parser.zig): comptime
  `std.StaticStringMap([]const []const u8)` for level files — Metadata,
  Enemies, Decorations, Items sections + their valid keys. Layout is excluded
  (raw char grid, no key-value pairs). The Enemies key set is the full
  `parseEntityDefinition` key set + `character_code` + utility-skill
  `slot_4`..`slot_8` + `layer`.
- **Wired into `start_level` handler** (event_handlers.zig): after parse,
  before load. Collects key warnings, and if any, sets `pending_error` with
  the concatenated message. Gated on `!history.replaying` so undo/redo
  doesn't re-surface warnings from the recording. The load continues
  (unknown keys are advisory — the file is valid, just noisy).
- **Tests:** "warns on unknown keys in level file sections" (3 unknown keys
  across Metadata/Enemies/Decorations → 3 warnings naming the key + section +
  file) + "no warnings for valid keys" (clean file → 0 warnings). Both
  arena-wrapped (sections are arena-allocated in production).
- **Incremental expansion:** the infrastructure (`validateKeys` + comptime
  key maps) is file-type-agnostic. Adding hub/mission/save/etc. key maps +
  wiring into their load paths is additive — each file type is a separate
  addition. The user's original case (typo in a level file's Enemies section)
  is now caught at `start_level` time.

### wrapRow: path-splitting + character-wrap fallback (DONE)

`wrapRow` (ui.zig) was space-only: a long path with no spaces (e.g.
`data/campaigns/main_campaign/missions/first_mission/level_1.txt`) was one
giant "word" that overflowed the panel and got clipped. Extended the wrapper
to handle long tokens uniformly (benefits both the error popup and tooltips):

- **Break on `/`**: `/` is now a soft break point (like spaces). The `/`
  stays with the preceding segment (`data/campaigns/` is one piece), so
  paths wrap at separators and stay readable.
- **Character-wrap fallback**: if a token (path segment, long key, etc.)
  is still wider than `content_width` after splitting on spaces and `/`,
  it's split into char-chunks that each fit, each on its own line. No token
  ever overflows.
- **Existing space-wrapping unchanged**: the regression test confirms
  space-based wrapping still works identically.
- **Tests**: breaks on `/` (path wraps at a separator, `/` stays with the
  preceding segment), char-wraps a token wider than content width
  (`abcdefgh` at 4-chars-per-line → 2 lines), and the existing space-wrap
  regression. All arena-wrapped where needed.

### Slice 3 — in-event reconstruction read failures (DONE)

The 6 handlers that do reconstruction reads (`start_new_game` / `start_mission`
/ `start_level` / `start_hub` / `load_save` / `open_editor` — `start_new_game`
+ `load_save` share `loadCampaignAndPushHub` which reads the campaign file)
now recover from parse/load failures instead of crashing. The handler sets a
flag + descriptive error, returns from `processEvent`, and the drain loop
reverts + surfaces the popup. See DESIGN → Error Handling → three contexts.

- **`GameStateHistory.load_error: bool`** (state.zig): set by a handler when
  its reconstruction read fails during LIVE play. Distinct from
  `pending_error` (the user-facing message, which can also be set
  advisorially by key validation without triggering a revert).
- **`failReconstructionRead(history, message)`** (event_handlers.zig): the
  shared helper. During replay → `@panic` (fail-fast — a reconstruction-read
  failure during replay is unexpected: in-session replay has cached bytes;
  cross-session replay of changed content is the known accepted fail-fast).
  During live play → `setPendingError` (duped into `history_arena`, survives
  the revert) + `load_error = true`.
- **Handler conversions:** each `catch @panic("failed to parse X")` on a
  reconstruction read/parse/load became `catch { failReconstructionRead(...);
  return; }`. OOM allocation panics stay (unrecoverable). The other ~90
  handlers stay `void` (invariant unwraps, gameplay logic — bugs → panic).
  `loadCampaignAndPushHub` (shared by `start_new_game` + `load_save`) also
  converted; callers check `if (history.load_error) return;` after the call.
- **Drain loop revert** (main.zig `frame()`): after each `update()`, checks
  `history.load_error`. If set: `restoreTo(last_idle_event_index)` (guaranteed
  exact — the snapshot was just taken at the last idle point, no snapshots
  since — fast path, no replay; stack-empty by construction) +
  `event_history.shrinkRetainingCapacity(current_event_index)` (trims the
  failed transaction's recorded events) + `break` (exit drain). The popup
  message survives (SessionState is off GameState, not touched by restoreTo).
  `pending_error` is treated as a drain pause (like a wait) in the drain
  loop condition + idle frame + render gate, so the popup renders and the
  drain doesn't spin (the bug that caused the lockup before this fix).
- **`runToIdle` (test harness, both copies):** panics on `load_error` (test
  content should be valid — a load_error in a test is a bug).
- **`restoreTo` made `pub`** (state.zig): main.zig's drain loop now calls it
  directly for the revert. Justified by the minimize-pub rule (another file
  imports it).
- **Test:** "reconstruction read failure: handler sets load_error, drain loop
  reverts state + trims history" (main.zig) — writes a broken mission.txt to
  a scratch persistent dir, pushes start_mission, calls processEvent, asserts
  load_error + pending_error set + state unchanged, then simulates the drain
  loop's revert and asserts state restored + event_history trimmed + popup
  message survived.
- **B-simple edge case** (accepted): if the player undoes, then triggers a
  failing load, `discardFutureTimeline` already trimmed the redo future. The
  revert restores state but the redo future is gone. No crash, no corruption
  — redo just unavailable. See DESIGN → Error Handling → B-simple.

### Slice 4 — write/reload failures (DONE)

The two write sites (`write_save` handler + `dumpEventLog` dev tool) now
recover from write failures instead of crashing. Session-log reload is not
user-wired yet (the replay viewer is TODO), so its `file_format_version`
hard-gate softening is deferred to that work. See DESIGN → Error Handling →
three contexts.

- **`write_save` handler** (event_handlers.zig): `writePlayerSaveToFile`
  `catch` → `setPendingError("failed to write save file")` + `return`. No
  `load_error` / revert needed — a failed write doesn't mutate `current_state`
  (the state is already correct; only the file write failed). The replay gate
  stays (undo/redo doesn't rewrite). Mid-drain, `pending_error` pauses the
  drain (the slice-3 drain-pause fix), so the popup renders and the player
  dismisses; the drain then continues with remaining events.
- **`dumpEventLog`** (input_handlers.zig): `writeEventLog` + `writeFile`
  each `catch` → `setPendingError` + `return`. Runs from the input path (not
  an event), so no drain/replay concern.
- **`buildEditorMission` in `open_editor`**: also converted to
  `failReconstructionRead` (it calls `loadLevel` internally, which can fail on
  `validateFileFormatVersion` — same class as the other reconstruction reads).
  Caught a `Metadta` section-header typo in `level_1.txt` during testing
  (another manual test artifact, like the `chracter_code` key typo).
- **`FileSource.writeFile` shipped-path guard stays a `@panic`**: it's a
  programming error (writing to `data/`/`assets/`), not a runtime I/O
  failure. The recoverable path is for genuine I/O failures (permissions,
  disk full, parent-not-a-dir), not programming bugs.
- **Test:** "write_save failure: sets pending_error, no crash, no state
  corruption" — creates a scratch persistent dir with a *file* at the `saves`
  path (so `ensureParentDirs` fails when trying to create the `saves` dir),
  pushes `write_save`, asserts `pending_error` set + `load_error` NOT set +
  `player_data` intact. (Using a file-as-dir blocker is more portable than
  chmod read-only.)
- **Session-log `file_format_version` hard-gate:** stays a hard error
  (`error.UnsupportedFileFormatVersion` from `loadEventLog`) for now. It only
  fires in tests (session-log reload isn't user-wired). Softening to
  warn-and-abort lands with the replay viewer.

### Key validation — all file types (DONE)

Extended approach A from level files to every config file type. See DESIGN →
Error Handling → key validation. Each file type has a comptime
`StaticStringMap([]const []const u8)` key map; `validateKeys` checks every
key in every entry group against the map and warns on unknowns.

- **Key maps added** (parser.zig): `hub_key_map`, `mission_key_map`,
  `campaign_key_map`, `settings_key_map`, `color_theme_key_map`,
  `weapon_type_key_map`, `salvage_key_map`, `player_save_key_map`,
  `player_loadout_key_map`. The Metadata section's keys (`file_format_version`
  + `name`) are shared via `level_metadata_keys` where applicable. Hub
  Decorations reuse `level_decorations_keys` (same format). Player loadout
  uses the `parseEntityDefinition` key set (minus `character_code` — the
  player isn't placed by char code). Salvage sections use `MaterialType` enum
  values as keys (wood, metal, leather, cloth, knowledge).
- **`validateConfigKeys` helper** (event_handlers.zig): centralizes the
  warning-collection + `setPendingError` surfacing for in-event reads.
  Gated on `!replaying`. Replaced the inline block in `start_level` and was
  added to `start_mission`, `start_hub`, `start_level`, `load_save`,
  `start_new_game`, `loadCampaignAndPushHub` (campaign), and `open_editor`
  (mission.txt + player.txt + all level_N.txt).
- **`loadConfigWithFallback`** (session_setup.zig): gained a `key_map`
  parameter; validates both the first-attempt (persistent-dir) sections and
  the embedded-fallback sections. All four startup loaders pass their key map.
- **Smoke test** (test_harness.zig): asserts `pending_error` is null after
  bootstrap — the shipped startup config has no unknown keys. The handler
  tests (which load levels/hubs via the event path) implicitly cover the
  shipped level/hub content.

### Global shipped-content validation test (DONE)

`src/content_validation_tests.zig`: a test that iterates every `.txt` in the
embedded-asset map, classifies each by path pattern, and runs its loader +
key validation. Catches shipped-content bugs (malformed syntax, unknown keys,
bad file_format_version, semantic errors) that the permissive parser would
otherwise silently drop.

- **Classification by path pattern**: `data/settings.txt` → loadSettings +
  settings_key_map; `data/color_themes.txt` → loadColorThemeDefinitions +
  color_theme_key_map; `data/salvage.txt` → loadSalvageDefinitions +
  salvage_key_map; `data/weapon_types/*.txt` → loadWeaponTypeDefinition +
  weapon_type_key_map; `data/new_player.txt` / `data/autosave.txt` →
  loadPlayerSave + player_save_key_map; `*/campaign.txt` → loadCampaign +
  campaign_key_map; `*/hub.txt` → loadHub + hub_key_map; `*/mission.txt` →
  loadMission + mission_key_map; `*/player.txt` → loadPlayerLoadout +
  player_loadout_key_map; `*/level_*.txt` → loadLevel + level_key_map.
- **Full load, not just parse**: the test runs the complete loader (type
  construction), not just `parseConfigFile` — catches semantic errors (bad
  enum values, missing required fields) that parse-only would miss. The
  loaded types are discarded (arena-allocated).
- **Self-maintaining**: new files added under `data/` are picked up
  automatically by the embedded-asset map iteration (the build step re-runs
  every build). No manual wiring when a new config file ships.
- **Asserts zero key-validation warnings** across all shipped config. On
  failure, prints every warning (key + section + file) so the author sees
  exactly what to fix. Verified: reintroducing the `chracter_code` typo in
  `level_1.txt` fails the test with `Unknown key 'chracter_code' in Enemies
  section of data/.../level_1.txt`.
- **Sanity check**: asserts at least 16 config files are present (the current
  count), so a broken build step that drops the embedded map is caught.

This test would have caught both manual-test typos (`chracter_code`,
`Metadata`) this session before they leaked into the working tree.

### Skill activation during the move step (DONE)

Pressing a skill slot during the `player_move` phase now skips the move step
and acts in the attack step instead of being silently ignored — so the
player doesn't have to manually skip the move when they don't intend to move
(matching the original Unity feel).

- **New orchestrator** `player_skip_move_to_skill` (LevelEvent): carries the
  RESOLVED intent `{skill_id, target, prepare}`. Targeting resolution depends
  on the transient `tile_cursor` (SessionState, off GameState), so it happens
  in the input path and the orchestrator carries the result — replay doesn't
  re-resolve input (same convention as the other player-action orchestrators).
  The handler always forces `player_turn_attack.force_attack_step = true` so
  `auto_skip_attack_step_out_of_combat` can't end the turn before the skill
  fires (the player explicitly asked to act); the cost is an out-of-combat
  weapon-skill press enters the attack phase with a prepared skill but no
  valid targets (player cancels/skips) — accepted edge case. Composes the
  existing verbs: `clear_highlights` (drop move highlights) →
  `player_turn_attack` (forced) → `player_prepare_skill` or `player_use_skill`
  (the nested orchestrator owns turn_end / clear / use_skill).
- **Shared resolution helper** `resolveSkillSlotAction` (input_handlers.zig):
  returns `SkillSlotAction { use | prepare }` from a slot press, factoring out
  the cooldown / targeting / auto-target-at-cursor logic that was inline in
  the `.player_attack` case. Both `.player_move` (skip-to-skill) and
  `.player_attack` (in-phase) now call it; `.player_move` wraps the result in
  `player_skip_move_to_skill`, `.player_attack` pushes
  `player_prepare_skill` / `player_use_skill` directly (unchanged behavior).
  Returns null on empty slot / cooldown / missing definition → the caller
  drops the input silently (matches the prior inline behavior).
- Tests: two tier-4 ordering tests pinning the LIFO fan-out for both branches
  (prepare + use) and asserting `force_attack_step` is true on the pushed
  `player_turn_attack`.

### Ported the designed Unity levels (DONE)

Ported all 4 designed missions from the Unity project (https://github.com/LinusWeggeHjalsted/taplop)
+ the single hub (Camp at the Crossroads) into ziglop's config format. They
live alongside the existing dev/sample `first_mission` + `starting_village`
(which stay — referenced by editor dev entry + tests).

- **Missions:** `beginnings` (3 levels), `forest` (4), `wetlands` (3),
  `seatown` (3) — 13 levels total. Each has `mission.txt` + `player.txt`
  (shared starter loadout, from Unity's `New Game.txt`) + `level_N.txt`.
- **Hub:** `camp_at_the_crossroads/hub.txt` with 4 exits (one per mission).
  `campaign.txt` `start_hub` repointed to it.
- **Conversion** via `scripts/port_unity_levels.py` (one-off, kept for
  reference): Unity `Enemy Info`/`Decoration Info`/`Item Info`/`Exit Info` →
  ziglop `Enemies`/`Decorations`/`Items`/`Exits`; CamelCase sprite names →
  bare snake_case stems (`Skeleton1`→`skeleton_1`, `GiantCrab`→
  `giant_crab`); Unity field names → ziglop (`maxHealth`→`max_health`,
  `armor`→`defense`, `usesWeapons 0`→`displays_weapons false`, `mainHandX`→
  `main_hand_weapon_X`, `colorCode`→`color_index`); weapon types (`Wand`→
  `staff`); utility skills (`utilitySkill X` lines → `slot_{4+i}` keys);
  items (`type Weapon`/`Boots` → `item_type weapon`/`boots`).
- **Decoration footprints:** Unity had no footprint field (decorations were
  non-blocking visual props). Authored a single-tile footprint per sprite,
  derived from each Unity sprite's pivot (the pivot maps to the anchor grid
  tile). Minimal — only the anchor cell is reserved (no floor-tile conflicts,
  since the layout char IS the anchor and is non-floor by definition);
  the rest of the bbox is overhang. Decorations don't block movement
  (pathfinding ignores them), so single-tile footprints are purely cosmetic
  on the reserved area. `tree_1` uses `footprint 1 2` (bottom-center) to
  match the existing sample convention.
- **Converter bug fixed:** empty sections (`Decorations`/`Items` with no
  entries) were emitted without a trailing blank line, so the next section
  header wasn't recognized (the parser requires a blank line before a
  section header) and its entries leaked into the empty section → a
  decoration entry with no `sprite` → sprite-dims panic. Fixed by always
  emitting a blank line after each section header.
- **Tests:** the global shipped-content validation test loads every ported
  file (parser + key validation); a new main.zig integration test enters
  each ported mission via `start_mission` through the event path and asserts
  it reaches `.level` with entities + a mission loaded.

### Removed dev/sample first_mission + starting_village (DONE)

The original dev/sample content (`first_mission`, `starting_village`) was
removed now that the real designed missions are ported. The campaign starts
at Camp at the Crossroads with the 4 designed missions reachable via hub
exits.

- **Deleted:** `data/campaigns/main_campaign/missions/first_mission/` +
  `data/campaigns/main_campaign/hubs/starting_village/`.
- **`new_player.txt` + `autosave.txt`:** `current_hub` repointed
  `starting_village` → `camp_at_the_crossroads` (this was why a new game
  still started in the old hub after the campaign `start_hub` was repointed).
- **Editor dev entry** (`input_handlers.zig`, `ui.zig`) + the main.zig editor
  tests repointed `first_mission` → `beginnings`. Test assertions updated:
  the editor palette is mission-wide, so `beginnings` (3 levels) has 2 enemy
  types (Skeleton Warrior + Javelineer) not 1; level 0 has 3 enemy placements
  (char '1' × 3); instantiated level has 4 entities (player + 3 skeletons).
- **Turn-counters test** made phase-aware: `beginnings/level_1`'s enemies are
  out of aggro range, so `auto_skip_attack_step_out_of_combat` completes the
  turn during `player_skip_move`'s drain. The old test pushed
  `player_skip_attack` unconditionally (a second `turn_end` → turns_spent=2);
  now it only pushes `skip_attack` if the turn is still in the attack phase.
- **Reconstruction-read-failure test:** the broken-mission writeFile path
  repointed `first_mission` → `beginnings` to match the `start_mission` path
  (a mismatch meant the scratch dir had a broken `first_mission/mission.txt`
  while `start_mission` read the valid embedded `beginnings/mission.txt` →
  no load_error).
- parser.zig test fixtures that use `first_mission`/`starting_village` as
  inline string literals are self-contained (not file reads) — left as-is.

### Decoration registry file + loader (DONE)

Built `data/decorations.txt` (the registry of official decoration prefabs)
and `parser.loadDecorationRegistry`, the editor-palette primitive for "add a
built-in decoration to the tools." See DESIGN → Decorations & Footprint.

- **`data/decorations.txt`:** `Metadata` + `Decorations` section, one
  entry per shipped decoration sprite (23 entries: tree_1 + 11 ruins + 5
  statues + 6 stones). Same entry shape as a level's Decorations entry MINUS
  `character_code` — registry entries are prefabs identified by sprite stem,
  not placed by layout char. Each carries a default `color_index` (ruins /
  statues = 0, stones = 5, tree = 4) + `footprint` (single-tile, derived
  from the Unity sprite pivots, same values the port script wrote inline into
  level files). `tree_1` carries its `tree_1_canopy` layer (color 2).
- **`loadDecorationRegistry(sections, file_source, allocator)
  ![]DecorationTypeDef`:** validates sections + file_format_version, parses
  each Decorations entry group via the shared `parseDecorationEntry` helper,
  returns `[]DecorationTypeDef` with `id = sprite` (matching
  `buildEditorMission`'s convention). Skips empty groups (no `sprite`).
- **Refactor:** extracted `parseDecorationEntry` (one entry's pairs →
  `DecorationDefinition`) + `finishLayer` (pending layer sub-group →
  `DecorationLayer` + validate dims) from `parseDecorationDefinitions`, so
  the per-level inline parser and the registry parser share one entry-parsing
  path. Behavior unchanged for levels/hubs (the existing decoration tests
  + content validation cover the refactor).
- **Validation wiring:** `decorations_file_format_version` (= 1),
  `decoration_registry_sections` (`Metadata` + `Decorations`),
  `decoration_registry_key_map` (Decorations keys = level decorations keys
  minus `character_code`). Added to `content_validation_tests.zig`
  classification (`data/decorations.txt` → `loadDecorationRegistry` +
  `decoration_registry_key_map`).
- **`freeDecorationRegistry`:** frees the owned `footprint` + `layers`
  arrays per entry (string fields are borrowed from the parsed sections,
  freed by `freeParsedSections`). For tests; production uses arenas.
- **Tests:** dedicated loader test reads the shipped `data/decorations.txt`
  via the real FileSource, asserts 23 entries, and checks tree_1 (3x3, layer,
  footprint 1 2, color 4) + stone_6 (1x2, footprint 0 1, color 5) in detail.
  The global shipped-content validation test covers it too.
- **Not wired into the editor yet** (the editor UI slice is pending). The
  primitive is ready; `editor_add_decoration_type` will consume it when the
  palette's "add new" button lands.

### Animation foundation + flag banner (DONE)

Settled the animation design and wired the looping flag banner (the first
sprite animation). See DESIGN → Animation for the settled design; this is the
implementation record.

- **`SessionState.animation_clock: u64`** — accumulated session-relative
  microseconds, off the undoable GameState → never in snapshots → replay-safe
  by construction (replay doesn't render anyway). Advanced by `frame()`
  **pause-gated**: when the world is paused (options menu / pending_error
  open), the clock freezes too, so anims freeze in place and resume cleanly.
  A fresh session starts at 0 so looping anims begin at frame 0 (raw
  wall-clock mod would start mid-loop).
- **`settings.animation_fps: u32 = 8`** (Display section) — the ONE global
  rate all anims share; frame duration = `1_000_000 / animation_fps` µs.
  Read by `view()` only. A `0` fps is treated as 8 (divide-by-zero guard).
  Added to `settings_display_keys` whitelist + `data/settings.txt`.
- **Flag banner:** `world/flag.png` (2048×512 = 8 frames of 256×512, same
  pivot as the pole) drawn over `world/flag_pole` at the same screen
  position. `LevelEndDrawable` gained `banner_source_rectangle: ?Rectangle`;
  `levelEndDrawable` (view.zig) computes it from `session.animation_clock` +
  `settings.animation_fps` (`frame = (clock / frame_duration) % 8`). Both
  call sites (level-end + hub mission-start markers) pass the clock + fps.
  The renderer's `.level_end` arm draws the pole, then the banner via
  `drawSpriteDrawable` (source rect + world_scale). Constants
  (`flag_banner_frame_count`, `_frame_width`, `_frame_height`) in view.zig.
- **The replay-purity invariant (settled, documented):** event handlers must
  NOT read `animation_clock` (or any wall-clock time). `verifyReplayMatch`
  compares events, not GameState fields, so a handler that read the clock and
  wrote a timestamp into GameState would be impure and diverge silently during
  replay (the clock is on SessionState, off the snapshot timeline → holds the
  undo-time value, not the original-fire-time value → the anim would re-play
  on undo, nondeterministically). One-shot anim triggers therefore live in
  the LIVE DRAIN (`frame()`/`update()`, gated `!replaying`), never handlers —
  the drain never runs during replay (undo/redo go through `restoreTo` →
  `replayTo` with `replaying=true`, calling `processEvent` directly). See
  DESIGN → Animation for the full one-shot design (deferred — lands with the
  first one-shot anim).
- **Test:** headless `view.zig` test asserts frame 0 at t=0, frame 4 at
  t=500ms, wraps to frame 0 at t=1000ms (fps=8), plus fps=16 (no divide-by-
  zero, valid frame) and fps=0 (treated as 8).

### Crash dump (panic → session log) (DONE)

A `@panic` now writes `crashes/crash_YYYYMMDD_HHMMSS.txt` (a replayable
session log) to the persistent dir before trapping, so a crash leaves behind
a full event history up to the failure — enough to reconstruct the session.

- **`src/crash_dump.zig`** — a custom panic namespace (`pub const panic =
  crash_dump.panic;` in both native.zig and web.zig, replacing web's prior
  `std.debug.simple_panic`). Mirrors simple_panic's full safety-check helper
  set; `call` prints the message to stderr, attempts the dump, then `@trap`s.
- **Global crash pointer:** `crash_history: ?*GameStateHistory`, `install`ed
  by `main.run` (native, `defer uninstall`) and `web.main` (web, no uninstall
  — tab close is shutdown). null outside a session → skip the dump.
- **Emergency allocator:** the dump uses `std.heap.page_allocator` for its
  output buffer, never the game's arenas (which may be inconsistent at panic
  time). Reads `event_history.items` (history_arena-backed — a panic is
  almost always a logic error, not heap corruption, so arenas are normally
  intact). io handle + persistent dir are entry-file-owned, safe to reuse.
  Every failure swallowed — the dump is best-effort, never a cascade.
- **Scope: Zig panics ONLY** (not SIGSEGV signal handlers — deferred; the
  arena/integer-only model makes wild-pointer segfaults rare). Web is
  best-effort (IDBFS syncfs may not flush before tab close); native is the
  reliable path.
- **Output = standard session-log format** (via `parser.writeEventLog`),
  loadable by `parser.loadEventLog` + `reconstructFromEventLog` — a crash
  file IS a replayable session log, just named `crash_*` and filed under
  `crashes/` (distinct from manual ctrl+L `session_log_*` in `logs/`).
- **Tests:** `dump` writes a parseable crash file to a scratch persistent dir
  (reuses the harness for configs, repoints `history.file_source` at the
  scratch dir, asserts one file under `crashes/` that round-trips to the same
  event count via `loadEventLog`); `install`/`uninstall` compile-test (the
  pointer's effect is only observable via `panic.call`, which traps — not
  unit-testable).

### Decoration footprint data correction (done)

The `data/decorations.txt` registry had been authored under two wrong
assumptions: (1) each decoration carries a single footprint coordinate,
and (2) sprite-grid coords use a bottom-left (y-up) origin. Both are
wrong — the implemented + AGENTS-documented convention is top-left
(y-down, matching PNG pixel layout), and multi-tile decorations need one
`footprint x y` line per reserved bbox tile.

`data/decorations.txt` was corrected to the artist's intended footprints
under the top-left convention. Single-base-tile decorations (statues,
stone_6) keep footprint = the base tile only; the art above it is
overhang, not reservation (entities can walk behind/around the upper
tiles). Ruins with broken corners list only the solid tiles.

The 9 shipped level/hub files that carry inline decoration footprints
(`beginnings/level_1..3`, `forest/level_1..3`, `wetlands/level_1`,
`wetlands/level_3`, `camp_at_the_crossroads/hub.txt`) were regenerated
from the registry so each entry matches its canonical footprint. Change
is purely additive (36 new `footprint` lines; no other edits). The
`validateDecorationFootprint` placement-invariant check (no footprint
tile overlaps a level/hub tile) passes for every shipped placement — the
Unity-authored placements were already overlap-free, and the corrected
footprints are <= the alpha coverage, so no new overlaps were introduced.
`forest/level_4` + `wetlands/level_2` were already correct (only
single-tile decorations present) and untouched.

The `loadDecorationRegistry` test (parser.zig) already asserted
stone_6's footprint as the single tile `(0,1)` at HEAD, so no test
change was needed for the registry correction.

### Programmatic edge-highlight outlines (done)

A precomputed outline-mask primitive powers two highlights: the tile cursor
(outline hugging the `world/tile` silhouette instead of a plain rectangle)
and highlighted UI elements (the move/attack step indicators above the
bottom bar ring the icon silhouette). All outlines tint with the active
theme's `lightest` color (the artist's slightly-off-white).

- `outline_thickness: i32 = 8` constant in `raylib_backend.zig` (tuned from
  in-game viewing; the one knob to adjust).
- `outline_cache: sprite_id -> ?rl.Texture2D` on `RaylibBackend`, freed in
  `deinit` alongside `texture_cache`.
- `generateOutlineMask`: an OUTER band — transparent pixels within
  `outline_thickness` (Chebyshev) of an opaque pixel become white, opaque
  pixels stay transparent. The band sits just outside the silhouette, so the
  sprite's own art is never overpainted (an earlier inner-band design
  overlapped the art's own edges). Dilation by a square is SEPARABLE: a
  horizontal pass into `opaque_h_mask`, then a vertical pass straight into
  the RGBA upload buffer — O(w·h·(2t+1)) instead of O(w·h·(2t+1)²), ~8.5x
  faster at t=8.
- LAZY generation: `ensureSpriteLoaded` loads the main texture only (no
  outline cost at level load — entity/weapon/decoration sheets never
  generate masks). `ensureOutlineLoaded` builds the mask on the first
  `getOutlineTexture` request (re-reading the asset bytes; outlined sprites
  are few, so a second read is cheaper than holding decoded images for every
  sprite). Fixed a debug-build stall where loading a level took multiple
  seconds because outlines were eagerly generated for every sprite.
- Band is clipped at the canvas border (a sprite filling its canvas
  edge-to-edge gets no halo on that side); current art ships with enough
  margin that this never shows. Canvas expansion (pad by t per side + grow
  the dest rect) is the robust fix if such art ever ships.
- `drawTileOverlay` is now a method; `.cursor` draws the `world/tile` mask
  tinted with the cursor color (rectangle-line fallback if the mask is
  missing). `.range_outline`/`.radius_outline`/`.aggro_outline` keep the
  rectangle (they outline tile regions, not sprite art).
- `drawUiElement` takes `highlight_color`; `.button`/`.image` draw the
  sprite's mask over it when `highlighted`, via `drawHighlightOutline`.
  `render()` passes `view_state.active_color_theme.lightest`.

### Input binding modifier match: subset, not exact (done)

`checkAction` matched bindings by EXACT modifier equality
(`binding.modifiers.ctrl != modifiers.ctrl`), so a plain binding (no
modifier requirement) would NOT fire while ctrl was held. That broke
ctrl+Space skip: the `skip` binding is plain `Space`, so holding ctrl
suppressed it entirely — even though `handleIdleInput` reads `modifiers.ctrl`
to set `force_attack_step` (override the auto-skip-attack-out-of-combat
setting). The skip BUTTON worked (UI clicks go through `applyAction`, which
sets `skip` directly with no modifier filtering); only the keyboard chord
was broken.

Fix: a binding's modifiers are now REQUIREMENTS, not an exact match. A plain
binding fires regardless of held modifiers (so ctrl+key works for any
plain-bound action); a ctrl binding fires only when ctrl is held. Skip only
when a REQUIRED modifier is NOT held.

Behavior widening: holding ctrl and pressing any plain-bound key now fires
that action (ctrl+g toggles gear, ctrl+1 fires skill slot 1, etc.) —
previously those did nothing. No current conflict: the only ctrl bindings
are z/y/l, none of which share a key with a plain binding. If an exclusive
chord need ever shows up (plain X vs ctrl+X doing different things),
most-specific-wins can be layered on top; not needed today.

### Synthetic key repeat (done)

A held bound key now repeats after a delay: first repeat at 300ms, then every
40ms. Effect: holding Right arrow moves the cursor one tile, then keeps
moving; holding ctrl+z keeps undoing. The cadence is owned by the engine
(`key_repeat_initial_delay_microseconds` / `key_repeat_interval_microseconds`
constants in `input.zig`), NOT the OS — so players cannot gain a real-time
advantage by twiddling OS key-repeat settings (the motivation for choosing
our-own-logic over raylib's `IsKeyPressedRepeat`).

- `InputState.key_repeat_state`: per-held-key `KeyRepeatEntry` (held
  microseconds + next-repeat threshold), parallel to `keys_held`. Created on
  a key_down edge (`addRepeat`), removed on key_up (`removeRepeat`), advanced
  each tick by `advanceKeyRepeats(delta)` which fires synthetic edges into a
  `keys_repeated` list. A large delta (stall) catches up by ONE repeat, not a
  burst (next_repeat_at is set to held + interval, skipping backlog).
- `translateInput` gained a `delta_microseconds` param; `main.frame()`
  computes the real-clock delta before calling it (moved from after to before
  translateInput) so the repeat cadence is framerate-independent.
- `checkAction` gained a `keys_repeated` param; a binding fires on a real
  edge OR a synthetic edge. The REPEAT WHITELIST is enforced at the call
  site: whitelisted actions (undo, redo, skip, move_cursor_*, error_scroll_*)
  pass `&keys_repeated`; everyone else passes an empty slice so a held key
  never repeats them (skill slots, toggles, confirm/cancel, dump_event_log,
  dismiss_error).
- Replay-safe by construction: repeat state is on `InputState` (off
  GameState), and the resulting events are identical to a single press —
  replay records events, not input timing.
- Known caveat: drain multi-fire — see DESIGN → Input.

### Diagonal cursor nudge: coalesce from held keys (done)

Holding two arrow keys (e.g. Down+Left) to move the cursor diagonally was
inconsistent: sometimes it worked, sometimes only one axis moved. Root cause:
the nudge read four independent edge/repeat-triggered bools and applied all
true axes at once. Two physical presses edges rarely land in the same tick
(press Down → nudge down; press Left next frame → nudge left — two single-
axis steps, not one diagonal), and per-key synthetic-repeat timers drift
(each key repeats on its own schedule), so even while holding both, the two
axes fired in the same frame only sometimes. On a checkerboard where only the
diagonal is a valid tile, a single-axis nudge targets an invalid intermediate
tile and is rejected entirely (the all-or-nothing tile clamp), so a diagonal-
only path was traversable only when both axes happened to fire together.

Fix: separate TRIGGER from VECTOR. The four `move_cursor_*` bools remain the
trigger ("a nudge should fire this frame"), but the nudge vector is derived
from HELD cursor keys (`InGameInput.cursor_direction`, new field computed in
`translateInput` via `isActionHeld`). So a diagonal nudge fires when ANY one
of the two held keys edges/repeats: hold Down, press Left → Left edges
(trigger) + Down held (direction) → nudge down+left. Opposite keys on one
axis cancel (sensible). Replay-safe by construction (cursor state stays off
GameState; the resulting events are identical to a single press).

- `isActionHeld` in input.zig mirrors `checkAction` but reads held state;
  same subset modifier semantics.

### Hover highlight on UI buttons (done)

All `Button` UI elements get an edge-outline highlight when the mouse pointer
is over them, reusing the precomputed outline-mask system built for the
turn-step indicators. The outline tint is the active theme's `lightest` (same
as the active-state highlight — one outline system, one color; split later if
hover-vs-active contrast is wanted).

- The hover pass lives in `view()`, right after all UI elements are built
  (bottom bar, main menu, error popup) and before the combat-log projection.
  view() already reads `session.input_state.mouse_screen_position` for the
  tooltip hover pass, so the seam was already there.
- `ui.buttonIndexAt` (new) returns the index of the topmost button under the
  pointer (occlusion-aware via the shared `hitTest` walk); view() mutates
  `ui_elements.items[i].button.highlighted = true` in place. `buttonAt`
  returns a copy, which can't be written back, hence the index variant.
- `hitTest` refactored to return `?usize` (index) instead of `?UiElement`
  (copy); `buttonAt`/`blockingElementAt`/`slotAt`/`tooltipAt` dereference by
  index. One walk primitive, same occlusion semantics.
- Suppressed while dragging (mirrors tooltip suppression — the pointer is
  dragging, not hovering). Modal popups shield buttons behind them naturally
  (hitTest respects `blocks_input`).

### Settings persistence (done)

Player preferences (camera zoom first; other tunable fields as their UI
lands) now persist across sessions via a user `settings.txt` in the
persistent dir, overlaid on the shipped `data/default_settings.txt`.

**Rename + overlay:**
- `data/settings.txt` → `data/default_settings.txt` (embedded shipped
  defaults, read-only). The user's `~/.ziglop/settings.txt` is the SAME
  FORMAT, overlaid at startup: scalars per-field (user value wins, missing
  keeps default); InputBindings, if present, REPLACE the default binding set
  entirely (the user's bindings are authoritative — changing official
  defaults only affects players with no user file, preserving their flow).
- `parser.loadSettings` gained an optional `base: ?Settings` param: when
  provided, `loadSettings` starts from the base (defaults) and overlays
  present fields. The binding replacement frees the base's bindings (no
  leak). `loadSettingsWrapped` (2-param) bridges to `loadConfigWithFallback`
  for the default-load path.
- `session_setup.overlayUserSettings` reads `settings.txt` from the
  persistent dir, parses it with defaults as the base, and returns the merged
  settings. Missing/unparseable user file → keep defaults + warn.

**Writer:**
- `parser.writeSettings(Settings) → []const u8` serializes the full settings
  (Metadata + Audio + Display + Gameplay + InputBindings) in the same format
  as `default_settings.txt`. Full-format write so the user file is always
  the same shape as the defaults.

**Debounced persistence (`PendingWrite`):**
- `SessionState.session_clock: u64` — non-pause-gated monotonic clock (unlike
  `animation_clock` which freezes during pause), advanced by `frame()` every
  tick. Used for write deadlines so writes fire even while the options menu
  is open.
- `SessionState.pending_writes: [4]?PendingWrite` — a small fixed array keyed
  by tag. `markWriteDirty(tag, write_fn, now)` coalesces by tag (a burst of
  zoom changes → one write). Debounce 1s + max-wait 5s: fires after 1s of
  quiet, or immediately if dirty for >5s (a continuous stream can't starve
  the write). `fireElapsedWrites` scans and fires elapsed entries each tick.
  `flushPendingWrites` flushes all on shutdown.
- `frame()` advances `session_clock` before the drain (so `markWriteDirty`
  sees an up-to-date clock), fires elapsed writes after all updates. `frame()`
  is the live path — replay goes through `restoreTo`/`replayTo`, not here —
  so the `!replaying` gate is automatic.
- Native `run` defer flushes on clean exit. Web `beforeunload` only does
  `FS.syncfs` (no Zig callback); a change-then-immediate-tab-close may lose
  the last debounced write (same best-effort limitation as the crash dump).
- `input_handlers.writeSettingsToFile` is the settings writer fn: serializes
  via `parser.writeSettings`, writes to `~/.ziglop/settings.txt` via
  `FileSource.writeFile`, swallows errors (a failed preferences write is not
  critical). `markSettingsDirty` is called after any actual zoom change
  (guarded by `new != current` so a clamped no-op scroll doesn't queue a
  write).

### Reflection fixes (done)

Two small hardenings from a mid-session reflection:

**`max_events_per_frame` made update-proof.** Was `key_mappings.len +
mouse_mappings.len + 1 + 1` with two unexplained magic `+1`s; adding a new
mapping array (gamepad, touch) or a new non-edge event source needed a
manual bump (a missed bump = silent runtime buffer overflow, no compile
error). Now `key_mappings.len + mouse_mappings.len + non_edge_events_per_frame`
where `non_edge_events_per_frame = 2` (mouse-move + mouse-scroll) is a named
constant. Adding a mapping array only needs `+ new_mappings.len` in the sum;
adding a non-edge source bumps the one named constant. The formula
self-documents the "at most one edge per mapped source per frame" invariant.

**Convention comment in `data/decorations.txt`.** The footprint coordinate
convention (sprite-grid, top-left origin, y-down) was documented in AGENTS
but invisible at the authoring point — a previous session authored ruins
1-3 under a bottom-left (y-up) assumption and the mismatch only surfaced on
review. Added a `#`-comment block at the top of the file (after Metadata)
stating the convention. The parser treats `#` lines as raw content in
non-Layout sections (ignored by loaders), so comments are safe outside
Layout sections. Layout sections cannot have comments (a `#` line becomes a
grid row), so the y-down grid convention stays AGENTS-only.

**AGENTS "Zig 0.16 Gotchas" expanded** with the two I hit this session: no
default parameter values, `///` doc comments invalid inside function bodies,
`opaque` is a reserved keyword.

### Settings persistence use-after-free fix

`overlayUserSettings` (session_setup.zig) freed the user `settings.txt` bytes
with `defer allocator.free(user_bytes)` as the function returned — but
`parseConfigFile` slices `KeyValuePair.value` directly into the raw file
buffer (no duping), and `loadSettings` stores those `input_name` slices into
the returned `Settings.input_bindings`. So every merged binding's
`input_name` dangled into freed memory. The next debounced `writeSettings`
read freed/overwritten bytes and emitted garbage `input_name` fields (the
mangled `~/.ziglop/settings.txt`). Only manifested on the SECOND launch
(launch 1 had no user file → only the leaked-defaults path, whose bytes stay
valid; launch 2 overlaid the user file → dangle).

Fix: match the established `loadConfigWithFallback` contract — leak
`user_bytes` into the session allocator on the success path (the merged
bindings borrow from it for process lifetime); free it explicitly only on the
two error paths (parse/load failure) where nothing borrows yet. Comment
added documenting the lifetime. `freeParsedSections` (containers only) stays
as a defer — it frees the section arrays, not the borrowed text.

Regression test: `overlayUserSettings: merged bindings survive past
user_bytes free` drives the overlay path under a `PoisonAllocator` (a wrapper
that fills freed memory with 0xAA before forwarding free to a backing arena —
turns a use-after-free into a deterministic equality-assertion failure without
segfaulting or tripping leak detection). Fails on the old code (input_name
reads as 0xAA); passes on the fix. Scratch dir under `zig-cache/` so no
`settings.txt` lands in the project root.

### Prepared-skill highlight on the bottom bar

When the player prepares a skill that awaits target confirmation
(`player_prepare_skill` sets `Level.prepared_skill`; confirm/cancel/
`clear_prepared_skill` clears it), the matching skill slot in the bottom bar
now carries the `highlighted` outline so it's visually clear which skill is
prepared. Implemented in `ui.zig`: `buildBottomBar` reads `prepared_skill`
from `game_state.level` (null in hub / when none prepared) and threads it
into `emitSkillButton`, which sets `highlighted` on the emitted Button when
the slot's `skillId` matches. `emitIconButton` gained a `highlighted: bool`
param (passed `false` by the skip button, the only other caller). No `view()`
signature change — `buildBottomBar` already receives `game_state`.

### Anytime swap_weapons: idle undo stop + wait interjection

Two bugs in the anytime `swap_weapons` path (handleAnytimeInput), fixed together:

1. **Idle swap not undoable.** Swapping while the event stack was empty
   processed `swap_hands` and advanced `current_event_index`, but `frame()`'s
   idle branch never called `recordIdlePoint()` — so the swap had no undo stop
   until the next action's drain absorbed it. Fix: `frame()`'s idle branch now
   records an idle point when `update()` advanced the index AND the stack is
   empty AND no wait is active (mirroring the drain loop's
   `had_events/!has_events` check, measured by index advancement since the
   idle branch starts with an empty stack). The `waiting == null` gate avoids
   a spurious idle point if a wait was pushed at an empty stack.

2. **Swap during a wait delayed ~500ms.** `handleAnytimeInput` pushed
   `swap_hands` onto the stack, but `update()`'s wait branch decremented the
   timer and returned before `processEvent` ran — the swap sat on the stack
   until the wait elapsed. Fix: `WaitState` gained `baseline_stack_depth`
   (set by the `wait` handler to the post-pop stack length = the remaining
   enemy-turn events). `update()`'s wait branch now drains anytime-interjected
   events down to that baseline before returning, so the swap is handled
   immediately. No idle point is recorded (the wait hasn't ended; the
   surrounding enemy-turn drain owns the next one). When the wait elapses, the
   interjection is already processed and the baseline events run in the normal
   path.

The two fixes compose: a mid-drain swap (stack non-empty, no wait) is still
handled by the drain loop and absorbed into its idle point (unchanged). A
mid-wait swap is drained to baseline inside `update()` and also absorbed (no
idle point in the idle branch — the stack is at baseline, non-empty during an
enemy turn). Only a truly-idle swap (empty stack, no wait) gets its own undo
stop.

`WaitState.baseline_stack_depth` lives on GameState (not SessionState): it's a
property of the specific wait, set where `waiting` is set, travels with it,
dies when it clears. Snapshot-safe: idle points are stack-empty moments, a
wait implies the drain paused mid-turn, so no snapshot carries a WaitState.
Replay clears `waiting` after streaming and never reads the baseline (only the
live drain reads it, and the live drain doesn't run during replay).

Assumption documented at the drain site: interjection events don't push nested
waits or reconstruction reads (true for `swap_hands`, the only anytime
event-pusher today — a leaf that swaps hands + cancels a prepared skill). A
`load_error` break guards the drain regardless.

Tests (main.zig): "anytime swap_weapons while idle" — swap via `update()`,
assert weapons swapped + index advanced + stack empty + not waiting, replicate
the `frame()` idle-branch condition + `recordIdlePoint()`, then `undo()`
restores the original weapon arrangement. "anytime swap_weapons during a wait"
— set `waiting` with `baseline_stack_depth=1` + one baseline event on the
stack, swap via `update()` with a delta smaller than the wait remaining,
assert weapons swapped this tick (not delayed) + wait still active (remaining
reduced by exactly delta) + baseline event still on stack + no idle point
recorded. The wait test fails on the old code (weapons not swapped — the
interjection sat on the stack); passes with the drain.

### Fix: idle-branch idle-point recording duplicated on undo/redo (cycling)

The idle-branch idle-point recording (from the swap_weapons fix above) fired
for ANY `current_event_index` change inside `update()`, including undo/redo —
which are themselves anytime actions handled in `handleAnytimeInput`. undo/
redo set `current_idle_index` and `restoreTo` sets `current_event_index` to
that idle point, so after `update()` the position was already indexed. The
idle branch then recorded a DUPLICATE idle point at the navigated-to position,
growing `idle_points` with near-duplicate entries. Undo/redo walked the
corrupted list, cycling between two adjacent states instead of going further
back/forward.

Fix: added one clause to the idle-branch condition — only record when
`idle_points[current_idle_index] != current_event_index`. This is true only
for genuine new forward progress (processEvent advances the index without
touching `current_idle_index`, leaving them unequal) and false for navigation
(undo/redo leave them equal — the position is already indexed). Safe via
short-circuit: the indexing only evaluates when the index advanced, which
implies events were processed, which implies `idle_points` is non-empty.

Regression test (main.zig): "undo/redo via anytime input does not record
duplicate idle points (no cycling)" — two idle swaps (idle points 1 + 2),
then undo via anytime input (back to swap1), assert `idle_points` did NOT
grow, then undo again (back to swap0, not cycling forward to swap2), assert
no-op undo at earliest, then redo twice forward without duplicates. Uses a
shared `runIdleUpdate` helper that replicates `frame()`'s idle-branch
condition exactly. Fails on the old condition (first undo grows
`idle_points`); passes with the `!= current_event_index` clause.

### Reflection followups: idle-point helper, settings ownership, leak-checked tests, crash cleanup

Four items from a mid-session reflection:

**Idle-point detection factored into `maybeRecordIdlePoint` (state.zig).** The
drain loop and the idle branch in `frame()` both record idle points after
`update()`, with subtly different conditions (drain: `had_events/!has_events`;
idle: index-advanced + stack-empty + not-already-indexed). The idle branch
condition was where the undo/redo cycling bug lived (it fired for undo/redo
too, recording duplicate idle points). Factored the shared condition into
`GameStateHistory.maybeRecordIdlePoint(events_processed)` — one place for
"events ran this update, stack is empty, and the position isn't already an
idle point (excludes navigation)." Both `frame()` sites and the test helper
`runIdleIdleUpdate` call it. The `waiting == null` defensive gate was dropped
(the case it guarded — a wait pushed at an empty stack — doesn't exist today,
and if it did, recording an idle point there is fine).

**`loadSettings` is self-owned (dupes `input_name`).** The durable fix for the
mangled-settings bug class: `loadSettings` now dupes each `input_name` into
the passed allocator, so the returned `Settings` owns its `InputBindings`
strings and doesn't borrow from the raw file buffer. `overlayUserSettings`
frees `user_bytes` + the parsed sections eagerly on every path (no more
leak-on-success contract mismatch). When `loadSettings` replaces a base's
bindings (overlay), it frees the base's owned strings + slice — so re-overlay
doesn't leak the old names. Added `parser.freeSettings` (frees bindings
strings + slice) for test cleanup. `loadConfigWithFallback` still leaks raw
bytes + sections for process lifetime (generic over T, can't selectively
free); after the ownership fix the `Settings` it returns no longer references
those bytes. The other loaders (levels, hubs, themes) still borrow — same
ownership direction, deferred. Settled in DESIGN → File System & IO → Settings
ownership.

**Leak-checked test under `testing.allocator` (session_setup.zig).** Replaced
the `PoisonAllocator` regression test (which tested a use-after-free bug class
that the ownership fix removed by construction) with a `testing.allocator`-
backed test that leak-checks the overlay path: builds self-owned defaults via
`readEmbeddedFile` (bypassing `loadConfigWithFallback`'s intentional leak),
overlays a user file, round-trips through `writeSettings`, frees via
`freeSettings`. `testing.allocator`'s leak detection catches a forgotten free
(the remaining risk after the ownership fix) — the arena-wrapped tests can't
see those. Verified the test fails (reports a leak) when `overlayUserSettings`
forgets to free `user_bytes`. Settled as the testing-discipline convention in
AGENTS → Build & Test → Testing discipline: self-owned loaders get leak-
checked tests; arena-wrapping masks leaks + use-after-free; the ownership fix
is the prerequisite for leak-checked testing.

**`scripts/test.sh` cleans `crashes/`.** A panicking test triggers the custom
panic namespace, which writes `crashes/crash_*.txt` into the cwd before
trapping — polluting the tree. The script now `rm -rf crashes` before running
and after a passing run, so a prior run's leftovers don't linger and a passing
run leaves none.

### Fix: maybeRecordIdlePoint crashed the exe on the first frame (out-of-bounds)

`maybeRecordIdlePoint` reads `idle_points[current_idle_index]` to check "not
already an idle point." At startup `idle_points` is empty and
`current_idle_index` is 0, so that read was out of bounds → the exe crashed
immediately on the first `frame()` (the `open_main_menu` drain called
`maybeRecordIdlePoint(true)` with an empty list). The old `recordIdlePoint`/
`takeSnapshot` appended to `idle_points` before ever indexing (set
`current_idle_index = len - 1` after append), so it never indexed into an
empty list; the new check did, and the empty-list case (the very first idle
point) was unguarded.

Fix: guard the "not already indexed" check with `idle_points.items.len == 0 or
...`. When empty, the position can't already be indexed → record (gated by the
other conditions). When non-empty, the check runs as before.

Why the tests missed it: every test calls `runToIdle` first, which populates
`idle_points` via `recordIdlePoint` before any `maybeRecordIdlePoint` call —
so the empty-list path was never exercised. Added a regression test that
drives `maybeRecordIdlePoint` directly on a fresh history with empty
`idle_points` (push swap_hands, processEvent, call maybeRecordIdlePoint →
records the first idle point, no crash). Verified the test reproduces the
exact `index out of bounds: index 0, len 0` panic on the unguarded code.

Lesson: when factoring out a helper called from the production loop, add a
test that exercises it from the *initial* state (empty collections, index 0),
not just from the states existing tests reach. The `runToIdle`-first pattern
in the test harness systematically skips startup invariants.

### TTF font (FreeZilla) wired into the raylib backend (done)

Replaced raylib's built-in bitmap font (`getFontDefault`) with the artist's
TrueType font (`assets/fonts/freezilla.ttf`, copied from the Unity project's
`Assets/Resources/FreeZilla-Regular.ttf` — a Calligraphr handwriting face).
The default font blurred when scaled up (it's a small bitmap atlas); the TTF
rasterizes crisp at all sizes in use.

- `build.zig`'s asset walk (`collectContentFiles`) has no extension filter,
  so dropping the `.ttf` under `assets/fonts/` embedded it into the
  single-file exe automatically (~12 KB binary cost). No build changes.
- `raylib_backend.zig`: a `loadFont` helper reads the bytes through the
  `FileSource` (`assets/fonts/freezilla.ttf`) and rasterizes via
  `rl.loadFontFromMemory(".ttf", bytes, font_base_size, null)` at
  `font_base_size = 128`. The atlas texture is set to bilinear filtering so
  downscaling to smaller `font_size`s is smooth (matches the reference→window
  blit). `font_base_size` covers the largest size in use (96, menu buttons)
  with a modest supersample; atlas is GPU/texture memory (off the wasm heap),
  not binary size.
- Fallback: on read/decode failure, logs to stderr and falls back to
  `getFontDefault` (keeps the game playable). A `font_is_default` flag tracks
  the fallback so `deinit` skips `unloadFont` on raylib-owned the default.
  Surfacing a `pending_error` popup from backend init is awkward (no
  `SessionState` yet), so stderr is the diagnostic channel — honest, not
  silent. The recoverable-error policy motivation: a persistent-dir shadow
  (`~/.ziglop/assets/fonts/freezilla.ttf`) can break the read at runtime.
- Character set: `null` → raylib's 95 printable ASCII glyphs. The Calligraphr
  font covers only 76 of those (raylib logs `Requested codepoints glyphs
  found: [76/95]`); missing characters render as the missing-glyph box. ASCII
  letters/digits/punctuation used by current UI text are mostly covered;
  revisit if a screen hits a gap (fill the glyphs in Calligraphr or keep a
  fallback face).
- `drawTextLabel` comment updated (no longer claims the default font blurs);
  bold/italic still ignored (no bold/italic faces loaded — the measurement
  seam in ui.zig still uses the fixed-advance placeholder, separate concern).

Follow-ups (not in this slice): real per-glyph metrics exported from the font
to replace the `measureSpanWidth`/`lineHeight` placeholder in ui.zig (TODO →
UI Framework → Real font metrics); honoring TextLabel bold/italic + color.

### Real glyph metrics wired into the text measurement seam (done)

Replaced the fixed-advance placeholder (`0.5em per byte`, bold inflated 5%)
in `ui.zig` with real per-glyph advances from the loaded font, so laid-out
text fits panels the way the renderer actually draws it. Pairs with the
FreeZilla TTF slice above (the font is loaded; this makes layout measure it).

- **`ui.FontMetrics`** — a raylib-free value type: `base_size` + `advances:
  [95]i32` (advance at base size for ASCII codepoint `i + 32`). Methods
  `measureSpanWidth` / `measureRowWidth` scale per-glyph advances by
  `font_size / base_size`. UTF-8-aware: ASCII bytes index `advances` directly
  (one byte = one codepoint); a multibyte lead byte skips its full byte
  length (clamped to the slice end) and uses a 0.5em fallback — its codepoint
  is always > 126, so it never indexes `advances`, and no actual decode is
  needed (keeps it panic-free on malformed bytes). `lineHeight` stays a free
  function (a 1.2em layout factor; raylib doesn't expose hhea/OS·2 line
  metrics, so it isn't font data).
- **Backend extraction:** `RaylibBackend.fontMetrics()` scans
  `font.glyphs[0..glyphCount]`, fills `advances[value - 32] = advanceX` for
  codepoints 32..126 (missing glyphs keep zero-init; the 0.5em fallback
  covers them in `measureSpanWidth`). Uniform for the TTF and the default-
  font fallback, so layout matches whichever font is active.
- **Per-glyph spacing (the fit fix):** raylib's `DrawTextEx` advances the
  cursor by `advanceX * (font_size/base_size) + spacing` per glyph, where
  `spacing = font_size/10`. The first cut of `measureSpanWidth` summed only
  `advanceX * (font_size/base_size)` — no spacing — so the measured width
  was smaller than the rendered width by `spacing × glyph_count`, and text
  overflowed panel right edges. Fix: `measureSpanWidth` now mirrors
  `DrawTextEx`'s cursor exactly — `advanceX * scaleFactor + spacing` per
  glyph, float-accumulated — so the measure matches where the renderer's
  cursor lands and multi-span emit (`x += measureSpanWidth`) flows like one
  continuous string. The spacing divisor lives once as
  `ui.glyph_spacing_font_divisor = 10`, shared by `measureSpanWidth` and
  `drawTextLabel` (replacing its hardcoded `font_size/10`) — one source of
  truth. Zero-advance glyphs (not in the font / blank) fall back to 0.5em +
  spacing, approximating raylib's `recs.width` fallback.
- **Threading:** `RenderContext` gained `font_metrics: ui.FontMetrics`;
  `frame()` reads `backend.fontMetrics()` into it; `view()` passes it to
  `buildBottomBar` / `buildMainMenu` / `buildTooltip` / `buildErrorPopup`,
  which thread it down to `wrapRow` / `emitPanelButton` / `emitSkillButton` /
  `emitCenteredNumber`. ~7 builder signatures gained a `font_metrics` param
  (mechanical).
- **`emitCenteredNumber` fixed:** was centering on a `font_size` square
  (placeholder); now measures the formatted number's width and centers on
  that + line height, so multi-digit cooldown/momentum/effect-duration
  numbers sit truly centered (the TODO "Center cooldown/label text using
  measured text width" item).
- **Tests:** the `ui.zig` measurement/wrapping tests build a synthetic
  `FontMetrics{ base_size=100, advances=[50]*95 }` (reproduces the old 0.5em
  arithmetic so the wrapping assertions stay deterministic and font-
  agnostic). The "bold is wider" assertion flipped to "bold equals plain" —
  only the regular face is loaded, so bold renders identical and the metrics
  reflect that honestly (no bold inflation). No test calls `view()`, so the
  `RenderContext`/signature changes don't ripple into the test build.

Deliberately deferred (called out in TODO):
- `boundsOf(text_label)` stays a `font_size`-square placeholder — no text
  label has a tooltip today and they're all `blocks_input = false` (the
  button behind wins hit-tests). Wire when a text label needs a tooltip.
- Bold/italic faces — only the regular face is loaded, so bold/italic render
  as plain. Loading separate faces is a separate follow-up.
- Non-ASCII glyphs use the 0.5em fallback advance; the Calligraphr font only
  covers 76/95 ASCII anyway (the gap flagged in the TTF slice).

### Tooltip placement: side-based (shared edge) instead of corner-point (done)

Tooltips used to anchor a tooltip *corner* to a source *corner* — they touched
at a single diagonal point (e.g. tooltip's bottom-left at the source's
top-right), so the tooltip floated off to a diagonal with no shared edge.
Replaced the corner-pair model with a **side-based** one: the tooltip sits
flush against one *side* of the source, sharing an edge segment.

- **`Side` enum** (`right`/`below`/`left`/`above`) replaces `Corner`.
- **`placeTooltip`** replaces `selectTooltipCorners` + `cornerPoint`. It
  tries sides in a fixed preference order — above, below, right, left — and
  uses the first that fits on screen without clamping; if none fit fully it
  falls back to the top preference (above) and clamps. This makes tooltips
  prefer going above an element (the natural direction, especially for the
  bottom bar, where the earlier max-clearance picker chose `right` because the
  space to the screen edge beat the space above) and only fall sideways when
  there's no vertical room. It places the panel flush on the chosen side
  (`panel.x = source.right` for the right side, etc.) and aligns it to the
  near corner *along* the side — e.g. above + source in the left half →
  left-aligned, so the shared edge runs from the source's top-left corner
  rightward. Clamping shifts the panel along the cross-axis (shrinking the
  shared edge but keeping the sides flush), only degenerating to a point if
  the tooltip is larger than the available cross-axis space (rare).
- `buildTooltip` now calls `placeTooltip` directly for `panel_x`/`panel_y`
  (the corner/clamp math is gone from it).

The old "Tooltip can overlap its own source" TODO is resolved for the common
case (the preference order + flush placement naturally avoids the source)
and narrowed to the degenerate cross-axis-clamp case (see TODO).

### Reflection follow-ups: docs, comment sweep, placement tests (done)

Three cleanups from a session reflection:

- **DESIGN → UI Framework:** added the "text measurement seam" rule —
  `ui.FontMetrics`'s contract is to mirror the renderer's cursor advance
  exactly (`advanceX × font_size/base_size + spacing`, float-accumulated, with
  the shared `glyph_spacing_font_divisor` as the one source of truth for any
  draw parameter layout must know), and the vertical rule "center on the
  `font_size` glyph cell, stack on `lineHeight`." Captures the two bugs fixed
  this session (the spacing drift and the top-heavy centering) as a general
  principle so the next draw-parameter addition doesn't re-drift.
- **Imagined-future / stale comment sweep:** removed "temporary — the artist
  will finalize", "placeholder until text measurement lands" (stale — it
  landed), "for a future count badge … for now", "when their UI lands",
  "future editor autosave" (3 sites), "future entity/effect anims", and
  softened two panic messages from "not yet …" to present tense. The
  `boundsOf(text_label)` comment now states the real reason it's still a
  `font_size` square (no text label needs measured hit-bounds today, none has
  a tooltip) instead of pointing at a missing feature. Kept accurate
  "future"-worded comments (the "future timeline" term of art, the
  load-bearing "temporary pointer" invariant in session_setup, swap `temp`).
- **`placeTooltip` tests + latent-bug fix:** added 6 pure-geometry tests
  (each quadrant, the above/below/right preference fall-through, near-corner
  alignment, the shared-edge invariant, and the degenerate oversized case).
  The oversized case surfaced a real bug: the fallback path did
  `clamp(x, 0, screen - tooltip)` and crashed with "reached unreachable"
  when the tooltip was larger than the reference screen (screen - tooltip < 0
  → clamp with lo > hi). Fixed with `@max(0, screen - tooltip)` so an
  oversized tooltip pins to the top-left instead of panicking. A tooltip with
  enough wrapped rows could exceed screen height, so this wasn't purely
  theoretical.

## Audio

### Slice 1–4 — architecture + vertical-slice sounds (DONE)

Sound is a side effect, gated `!replaying` (same rule as file writes). The
architecture mirrors `PendingWrite`:

- **`SoundId` enum** (types.zig) — one variant per sfx file under
  `assets/audio/sfx/` (15 shipped). Music is a single always-on stream, not a
  `SoundId`.
- **`SessionState.pending_sounds`** — `std.ArrayListUnmanaged(SoundId)` on
  `backing_allocator`, off the undoable GameState → replay-safe by
  construction. `queueSound` appends (callers gate `!replaying`);
  `drainPendingSounds` returns the slice + `clearRetainingCapacity`. Freed
  in `run`'s defer chain.
- **Backend (`raylib_backend.zig`):** `initAudio(settings)` opens the audio
  device, loads all sfx via `loadWaveFromMemory` + `loadSoundFromWave` from
  the `FileSource` (never the filesystem — same seam as textures), loads the
  music via `loadMusicStreamFromMemory`, sets it looping, starts it. A sound
  cache (`AutoHashMap(SoundId, ?rl.Sound)`) holds loaded sounds; missing
  audio caches null and skips play. `deinitAudio` (from `deinit`) unloads
  everything + closes the device. If the audio device can't open,
  `audio_ready` stays false and ALL audio methods no-op — the game runs
  silent, never crashes.
- **Per-frame:** `frame()` calls `backend.updateMusic()` at the top (raylib
  requires it for streaming) + `backend.playSounds(drained, settings)` after
  the update drain. Sfx volume = `sound_effects_volume * master_volume`;
  music volume = `music_volume * master_volume` (set via `applyVolumes`).
- **Assets:** ported the Unity project's 16 WAVs to OGG via ffmpeg (Ambient
  34 MB → 3.3 MB; SFX 2.2 MB → 220 KB). Music: `assets/audio/music/ambient.ogg`
  (looping). SFX: `assets/audio/sfx/*.ogg`. All embedded via
  `generated_assets.zig` (build walks `assets/**`).
- **Settings:** added `master_volume: f32 = 1.0` (scales music + sfx alike);
  `music_volume` + `sound_effects_volume` already existed. Parser + writer +
  `data/default_settings.txt` updated; key whitelist updated.
- **Entry files:** `native.zig` / `web.zig` call `backend.initAudio(settings)`
  after `createSessionSetup` + `fixupPointers`.
- **Wired sounds (vertical slice):** `move` (level `move_entity` + hub
  `move_player`), `attack` (`attack` sub-level event), `pickup` (`pickup_items`),
  `button_click_down` (UI button press in `update`). All gated `!replaying`.

### Remaining (open — see TODO → Audio)

Wire the rest of the sfx (spell/damage/skip/equip/learn_skill/salvage/
swap_skill/menu/button_click_up; defeat + mission_completion land with the
mission end-state screens), the spell-vs-attack split (skill-type lookup in
the `use_skill` handler), live volume re-apply from the options menu, and web
autoplay verification.

### Slice 6 — full event→sound map + naming alignment (DONE)

Settled the trigger-placement approach: **one sound per semantic event,
triggered in the event handler** (not in skill `useSkill` functions, not on
orchestrators). Skills compose events; events carry sounds; the map lives in
one place. AI gets sounds for free (enemies push the same events).

- **Naming alignment:** renamed `attack` sound → `weapon_swing` so `attack`
  refers to exactly one thing (the damage-primitive event). `damage` is fired
  by `attack` + `collision` (many-to-one, no `damage` event → no clash). Asset
  file renamed `attack.ogg` → `weapon_swing.ogg`.
- **`use_skill` split by skill_type:** weapon_skill → `weapon_swing` (the
  swing); spell/cantrip/enchantment/curse → `spell` (the cast; cantrip/
  enchantment/curse assets are TODO, `spell` is the placeholder). One switch
  arm in the handler — not 25 per-skill trigger sites.
- **Full map wired:** move_entity/move_player→move, use_skill(weapon)→
  weapon_swing, use_skill(spell-type)→spell, attack→damage, collision→damage,
  pickup_items→pickup, equip_item→equip, learn_skill→learn_skill,
  salvage_item→salvage. UI: button_click_down on press (input path).
- **Multi-hit:** each `attack` fires one `damage` (N hits → N impacts). If
  overlapping same-sfx-in-one-frame becomes an audio mess, throttle in the
  backend's `playSounds` (per-sfx cooldown) — NOT at trigger sites.

### Slice 7 — remaining sfx, button press/release model, queue fix (DONE)

**Sound queue bug fix.** `drainPendingSounds` used `clearRetainingCapacity`,
which does `@memset(self.items, undefined)` before resetting the length —
clobbering the slice the caller just received. SFX loaded valid, `playSound`
was called, but the slice held garbage `SoundId` values that matched nothing
in the cache → silent no-op. Fixed by resetting `items.len = 0` directly
(leaving the backing bytes intact for the caller to read). Regression tests
added (state.zig): queue+drain order, drained-slice-stays-valid-after-clear,
reuse after drain.

**Button press/release model.** Button actions now fire on mouse RELEASE, not
press (standard UI behavior; drag-off cancels). `SessionState.pressed_button:
?Action` records the button under the press; release fires the action only if
the release is over the same button. Cleared on screen transition alongside
`ui_state`/`tile_cursor`/`camera_pan` (was missing initially — a press that
spanned a screen transition would fire on the new screen's UI).

**Sound routing.** `releaseSoundForAction` (types.zig) maps an Action to its
specific release sound (skip, swap_weapons→swap_skill, panel
toggles→menu) or null (generic `button_click_up`). Skill slots suppress the
generic up on release: auto-fire lets the `use_skill` event's
weapon_swing/spell play alone; the prepare (targeting) path plays
`button_click_up` explicitly. Keybind-triggered actions queue their specific
sound at the input-handler site (no click sounds).

**Remaining sfx wired:** skip (`player_skip_move`/`player_skip_attack` events),
swap_weapons (swap_skill), panel toggles inventory/gear/skills/world_map/
options_menu (menu). `defeat` + `mission_completion` wait for the mission
end-state screens.

**Music-load-order gotcha:** SFX must load AFTER the music stream starts, or
`LoadSoundFromWave`'s format conversion targets a stale device state and
sounds silently never play (no error, no log). `initAudio` order: open device
→ load+start music → load sfx. Documented in DESIGN → Audio.

## Animation

### One-shot anim infrastructure + skill-icon pop (DONE)

First one-shot animation, establishing the one-shot machinery. Design converges
with Audio (DESIGN → Animation): the trigger lives in EVENT HANDLERS via
`session.queueAnim` (gated `!replaying`, same shape as `queueSound`), NOT in
the live drain as the original design had it. `frame()` drains
`session.pending_anims` after the update drain (alongside `drainPendingSounds`),
stamps `end_clock = animation_clock + duration_us` from the LIVE clock, and
appends to `session.active_anims`. This keeps the replay-purity invariant a
bright line — handlers never read `animation_clock`; the clock is read in
exactly one place (`frame()`). The `!replaying` gate at the push site is what
prevents re-fire on undo/redo (replay queues nothing). The only anim-specific
machinery vs. Audio is the `end_clock` stamp (a sound is done at push; an anim
is temporal) and the `view()` event-index + time gating.

- **Types (types.zig):** `AnimKind` union (first variant `skill_icon{entity_index,
  skill_id}`), `PendingAnim{event_index, kind, duration_us}`, `ActiveAnim{
  event_index, kind, end_clock}`, `FloatingIconDrawable{sprite_id,
  screen_position, size, color}`, `WorldOverlayDrawable` union. `ViewState`
  gained `world_overlays: []const WorldOverlayDrawable` (new layer 3.5 — drawn
  after ground drawables, before UI; does NOT participate in the ground y-sort).
- **SessionState (state.zig):** `pending_anims` + `active_anims`
  (ArrayListUnmanaged, backing_allocator-backed) mirroring `pending_sounds`;
  `queueAnim`/`drainPendingAnims` (same no-memset drain as sounds) +
  `clearAnims` (transition reset). Deinit wired in `main.run` defer.
- **Push site (event_handlers.zig, `use_skill`):** right next to the existing
  `queueSound`, same `!replaying` gate, `event_index = current_event_index - 1`
  (processEvent increments before dispatch, so this is the `use_skill` event's
  index), `duration_us = 500_000`, kind `skill_icon{caster_index, skill_id}`.
  Applies to ALL entities (player + enemy) — enemy casts show their icon too
  (informative; enemies can't overlap themselves, 0.5s wait between actions).
- **`frame()` (main.zig):** drains pending anims → stamps `end_clock` → appends
  to `active_anims`, right after the sounds drain. Both screen/world-transition
  reset blocks (drain branch + idle branch) call `session.clearAnims()` so an
  anim never outlives its level/hub (level-to-level, hub-to-level, etc.).
- **`view()` (view.zig):** `buildWorldOverlays` filters `active_anims` by
  `event_index < current_event_index` (exclusive bound, matching the combat
  log's `event_history[0..current_event_index]` — so undo hides the anim
  exactly when its event leaves the projected history) AND
  `animation_clock < end_clock` (not elapsed). Skill icons track the entity
  (resolved from the CURRENT level each frame — if the entity moves during the
  500ms the icon follows), skip dead entities (`current_health == 0`) and
  out-of-range indices. Position: centered horizontally over the entity's
  512×640 frame, above the frame top by a fixed native gap
  (`skill_icon_gap_native`). `entityFrameTopLeft` extracted from `entityDrawable`
  so the icon and the body share one pivot-aligned-top-left computation.
  Later-pushed anims append later → draw later → stack on top (most recent
  skill use on top).
- **Renderer (raylib_backend.zig):** `drawWorldOverlay` draws a floating icon
  as a square (`size * world_scale`) via `drawTexturePro`, full-texture source,
  tinted. Rendered in the world layer loop after ground drawables, before UI.
  White tint for now (raw icon art); tune later.
- **Gating semantics:** `event_index < current_event_index` (NOT `<=`) matches
  the combat log's exclusive upper bound. The AGENTS design text said `<=`
  loosely; the precise version stores the actual triggering event's index and
  gates with `<`.
- **Deferred (TODO):** replace the fixed head-gap with the topmost
  non-transparent pixel of the entity's rendered sprite (runtime scan), so the
  icon sits just above the actual art regardless of sprite. Future one-shots
  (attack swings, hit flashes, death dissolves) reuse the machinery with
  richer `AnimKind` variants + multi-frame source rects.

### Skill-icon placement via runtime topmost-pixel scan (DONE)

Replaced the fixed head-gap (`icon_y = frame_top - size - gap`) with the
entity's actual art top: the y-coordinate of the topmost non-transparent pixel
of the entity's sprite, found at runtime. Same lazy-decode-and-cache shape as
the edge-outline mask cache (`outline_cache` in raylib_backend.zig):

- **Backend (`raylib_backend.zig`):** `sprite_top_y_cache:
  StringHashMapUnmanaged(?i32)` (sprite_id -> topmost-opaque y, or null on
  miss/failure). `getSpriteTopY(sprite_id)` lazily populates via
  `ensureSpriteTopYLoaded` (re-reads bytes, `loadImageFromMemory`,
  `loadImageColors`, scans top-down for the first pixel with alpha > 16 — same
  threshold as the outline mask). `entitySpriteTopY(allocator, bare_stem)`
  prefixes `entities/` so callers don't know the asset-path format. Cache
  deinits alongside `outline_cache`. Caches null on miss (caller falls back to
  the frame top).
- **Seam (view.zig `RenderContext`):** `sprite_top_y:
  std.StringHashMapUnmanaged(?i32)` keyed by bare sprite stem. Built by
  `frame()` (the one place with backend access) by querying the backend for
  each entity in the current world (level entities OR hub player + NPCs), into
  the frame arena. `view()` stays pure / raylib-free — it just reads the map.
  Mirrors the `FontMetrics` precedent (backend-derived value precomputed in
  `frame()`, passed into `view()`), not a callback — because `main.zig` is
  raylib-free and can't import the backend, and method-pointer-via-`anytype`
  doesn't bind cleanly in Zig 0.16. The map is tiny (~one entry per distinct
  entity sprite) and the backend cache makes per-sprite cost zero after first
  load.
- **Placement (view.zig `buildWorldOverlays`):** `art_top_y = top_left.y +
  (top_y / entity_frame_height) * draw_height` (maps the source-space topmost
  pixel into the drawn, zoomed frame), then `icon_y = art_top_y - size - gap`.
  Falls back to the frame top (`top_left.y`) if the sprite isn't in the map or
  returned null (e.g. missing art). The small `skill_icon_gap_native` (16px)
  stays as the gap above the art top.
- **Icon size doubled** (`skill_icon_size_native` 128 -> 256) per playtesting.

Why a runtime scan over a build-time comptime table: `view()` is pure (no
I/O), so the value must be available without reading files at render time. A
build-time table (like `generated_sprite_metadata.zig` dims) would need a full
PNG decode (zlib inflate + unfilter) in `build.zig` — notably more build-step
code than the IHDR-only dims scan — and couldn't serve custom runtime sprites.
The runtime lazy-cache handles any sprite the backend can load (shipped or
custom), uniform with the outline-mask precedent, at the cost of one decode
per sprite on first request (amortized by the cache).

### Entity health bars (DONE)

Always-on health bars above each entity's head, the Phase 4b combat-readability
piece. Placed above the entity's actual art top (same runtime `sprite_top_y`
scan as the skill-icon anim — topmost non-transparent pixel, lazily decoded +
cached in the backend, mirroring the outline-mask cache). The skill-icon anim
sits above the health bar (offset by the bar height + gap) so the two don't
overlap.

- **Assets:** cropped from the Unity project's `EntityHealthBarBackground.png`
  (the white bar) and `EntityHealthBars.png` left-most frame (the outline
  frame) to the outline's opaque bbox (310×62 at (37,33)), downscaled 0.5x →
  155×31 each. Shipped at `assets/world/entity_health_bar_background.png` +
  `entity_health_bar_outline.png` (world-space drawables that move with the
  entity, like `flag_pole`). Both share the same 155×31 canvas so they
  auto-register (drawn at the same rect).
- **Type (`types.zig`):** `HealthBarDrawable` redesigned from the old
  `{position, width, current_health, max_health}` scaffolding to
  `{position, width, height, fill_fraction, depleted_color, fill_color}` —
  the renderer needs the fraction + colors, not raw health (view computes the
  fraction; the renderer is dumb). `EntityDrawable.health_bar: ?HealthBarDrawable`
  populated for alive entities (null for dead / `max_health == 0`).
- **Colors:** depleted = `active_theme.darkest` (global, not team-specific —
  reads as "empty" regardless of team); fill = team gradient index 1 (player →
  player gradient, enemy → enemy gradient — consistent with the weapon-color
  convention). Outline frame tinted with the same team gradient index 1 as
  the fill (the border matches the entity's team color).
- **Builder (`view.zig`):** `buildHealthBar` computes the bar rect: centered
  horizontally over the entity's 512×640 frame, `art_top_y - bar_height - gap`
  vertically. `entityDrawable` now takes `sprite_top_y` (threaded through
  `collectEntityEntries` from `render.sprite_top_y`) to resolve the art top,
  and a `show_health_bar` bool (levels only — the hub call site passes false).
  Constants: `health_bar_native_width/height` (155/31), `health_bar_gap_native`
  (8) — tunable, eyeball in `zig build run`.
- **Renderer (`raylib_backend.zig`):** `drawHealthBar` — three passes at the
  same rect: (1) depleted background full (`drawSprite`, darkest tint), (2)
  fill cropped to `fill_fraction` from the left (`drawTexturePro` with
  `source.width = tex_w * fraction`, `dest.width = dest_w * fraction` — same
  source-rect technique as `drawFillSprite`, keeping the left portion so the
  bar depletes from the right), (3) outline frame full (`drawSprite`, fill-color
  tint). Drawn in the entity arm of `drawGroundDrawable`, after front effects.
- **Skill-icon offset:** `buildWorldOverlays` offsets the icon by
  `health_bar_native_height + health_bar_gap_native` beyond the art top, so
  the icon sits above the bar. Both use the same constants → they agree.
- **Scope:** levels only (hub NPCs don't show bars — `show_health_bar` false
  on the hub path).

### Hit flash one-shot anim (DONE)

The second landed one-shot anim: the `world/hit_flash` sprite flashed over a
damaged entity's rendered art center for 250ms when it takes nonzero damage.
Reuses the skill-icon one-shot machinery (`queueAnim` → `frame()` stamps
`end_clock` → `view()` gates by event-index + time) with a new `AnimKind`
variant and a new `sprite_bottom_y` lookup for the real vertical center.

- **Asset:** the Unity project's 512×512 `Assets/Resources/Hit.png`
  downscaled 0.5x → 256×256 RGBA at `assets/world/hit_flash.png` (renamed
  from `Hit` to match the code's `hit_flash` identifier; picked up by the
  generated assets + sprite-metadata tables on rebuild). Single-frame, no
  sheet.
- **`AnimKind.hit_flash`** (`types.zig`): `{ entity_index: u32 }` alongside
  `skill_icon`.
- **`sprite_bottom_y`** (`raylib_backend.zig`): mirror of `sprite_top_y` —
  the bottommost-opaque-pixel y. `ensureSpriteTopYLoaded` refactored into
  `ensureSpriteBoundsLoaded`, which decodes the sprite ONCE and fills BOTH
  caches (`sprite_top_y_cache` + new `sprite_bottom_y_cache`). New
  `scanBottommostOpaqueY` (bottom-up scan, same `>16` alpha threshold). New
  `getSpriteBottomY` / `entitySpriteBottomY` wrappers. `frame()` (main.zig)
  populates a parallel `sprite_bottom_y` map in the same entity loops (second
  call is a cache hit) and threads it through `RenderContext.sprite_bottom_y`.
  No second decode per sprite.
- **Placement** (`view.zig` `buildWorldOverlays`, new `.hit_flash` arm):
  horizontal center = the entity frame's horizontal center (entities are
  always horizontally centered in the 512×640 frame); vertical center =
  midpoint of `sprite_top_y` and `sprite_bottom_y` (the opaque-art bbox),
  falling back to the frame's vertical center on a miss/transparent sprite.
  Drawn at `hit_flash_size_native` (256) × `world_scale`, tinted with
  `active_theme.lightest` (the artist's offwhite). A killing blow still
  flashes — only bounds-checked (not `current_health == 0`, which the
  skill-icon path uses to skip dead casters); `death` zeroes health but
  leaves the slot in the array.
- **Trigger** (`event_handlers.zig`): in both the `attack` and `collision`
  handlers, inside the `if (incoming_damage > 0)` block right after the
  health subtraction, `queueAnim` with `entity_index = defender`,
  `duration_us = 250_000`, `event_index = current_event_index - 1`, gated
  `!history.replaying`. Only nonzero-damage hits flash (a Reflect-zeroed or
  0-damage hit does not), matching the spec. The existing `queueSound(.damage)`
  at the top of each handler is unchanged (still fires unconditionally).
  Replay-safety holds by construction: the anim is a `SessionState` side
  effect gated `!replaying`, the clock read stays in `frame()`, and undo
  hides it via the `event_index < current_event_index` bound.

### Sprite bounding-box cache refactor (DONE)

Generalized the per-entity opaque-pixel edge lookups from two separate
single-edge caches (`sprite_top_y_cache` + `sprite_bottom_y_cache`) into one
full-bbox cache, ahead of damage numbers needing `left`/`right` edges too.
Pure refactor — no behavior change to the skill-icon or hit-flash placement.

- **`types.SpriteBounds`** = `{ top, bottom, left, right: ?i32 }` (SOURCE
  pixels, 0-based from the top-left; each edge null on miss/transparent).
- **Backend (`raylib_backend.zig`):** `sprite_bounds_cache:
  StringHashMapUnmanaged(?SpriteBounds)` replaces the two caches.
  `ensureSpriteBoundsLoaded` decodes once and calls a single new
  `scanOpaqueBounds` (one pass over the pixels tracking min/max x and y of
  pixels with alpha > 16; returns null for a fully transparent image).
  `getSpriteBounds`/`entitySpriteBounds` replace the four
  `getSprite*Y`/`entitySprite*Y` getters. `deinit` frees one cache.
- **`main.zig` `frame()`:** populates one `sprite_bounds` map (one backend
  query per entity) instead of two, threaded through `RenderContext`.
- **`view.zig`:** `RenderContext.sprite_bounds` replaces the two fields;
  `buildWorldOverlays`, `collectEntityEntries`, `entityDrawable`, and
  `buildHealthBar` all take the one map and read `.top` / `.bottom` from it.
  The hit-flash and skill-icon placement is identical (just reads
  `bounds.top.?` / `bounds.bottom.?` instead of the prior `?i32`);
  `scanOpaqueBounds` guarantees all four edges non-null when it returns
  non-null, so the `.?` unwraps are safe.

### Text outline via the dilation machinery (DONE — then REVERTED)

Extended the sprite-outline dilation to floating text so damage/heal numbers
get a black edge-outline band under the fill. Slice 3 of the damage-number
feature; no trigger sites wired yet (the `floating_text` drawable is ready
for slice 4 to emit).

> **Reverted.** The dilation-mask approach was replaced by an 8-direction
> drop-shadow ring (see the "Damage + heal numbers" entry below). Root
> cause: `rl.imageTextEx` fails for our TTF font — `LoadFontFromMemory`
> populates per-glyph CPU `image`s, but `ImageTextEx`'s internal
> `MeasureTextEx` at `baseSize` returns a degenerate `textSize.y` (~0) for
> our font, so the resize-to-`fontSize` step scales by ~0 → an invalid
> (0-width) image. A GPU readback path (`DrawTextEx` to a
> `RenderTexture2D` → `LoadImageFromTexture` → dilate) was tried next but
> perturbed the main render target mid-pass (a visible screen flash on each
> damage event). The 9-draw drop-shadow avoids both issues. The
> `generateOutlineMask(image, thickness)` parameterization landed here is
> KEPT (sprite callers use it); only the text-specific `text_outline_cache`/
> `getTextOutlineTexture`/`ensureTextOutlineLoaded` were removed. A proper
> programmatic text outline (one dilated mask texture per string) is a
> deferred TODO — needs a working CPU font raster (custom rasterizer, or
> fixing why `imageTextEx` mis-measures our font, or pre-rasterizing at
> load time outside the render pass).

Extended the sprite-outline dilation to floating text so damage/heal numbers
get a black edge-outline band under the fill. Slice 3 of the damage-number
feature; no trigger sites wired yet (the `floating_text` drawable is ready
for slice 4 to emit).

- **Parameterized `generateOutlineMask(image, thickness)`** (`raylib_backend.zig`):
  was hardcoded to the `outline_thickness` const (8). Sprite callers now pass
  `outline_thickness` explicitly (no behavior change); text callers pass the
  new `text_outline_thickness` const (also 8, tunable separately since text
  glyphs are much smaller than sprites and a thick band reads differently).
- **`text_outline_cache: StringHashMapUnmanaged(?rl.Texture2D)`** keyed by
  `"{text}\x1f{font_size}\x1f{thickness}"` (unit separator avoids collisions).
  `getTextOutlineTexture(text, font_size)` lazily populates via
  `ensureTextOutlineLoaded`: rasterizes the string with `rl.imageTextEx`
  (white opaque glyphs on transparent -- the dilation only cares about
  alpha, so the tint is irrelevant; the band is drawn tinted black by the
  caller), normalizes to RGBA, and runs `generateOutlineMask(image,
  text_outline_thickness)` unchanged. Caches null on failure (renderer draws
  the fill without an outline). `deinit` unloads + frees the cache. Tiny
  cache (damage numbers are 1-3 digits at one font size).
- **`WorldOverlayDrawable.floating_text`** (`types.zig`): `{ text,
  screen_position, font_size, color }`. `drawWorldOverlay`'s new arm draws
  the band (black, `drawTexturePro` scaled by `world_scale`) then the fill
  (`drawTextEx` at the same top-left, lightest color) -- both originate at
  `screen_position` so they auto-align. The band texture is sized to the
  text's bbox, so scaling it by `world_scale` matches the fill's drawn size.

### Damage + heal numbers (DONE)

The third one-shot anim class and the first to move + carry a dynamic text
payload. Floats the damage/heal value away from the entity's sprite, eased
with `tween.easeOutCubic` (fast then slow), 1 tile over 500ms, tinted
`active_theme.lightest` + a black edge-outline (8-direction drop-shadow
ring — see the reverted slice 3 entry above).
Reuses the one-shot anim pipeline (`queueAnim` → `frame()` stamps clocks →
`view()` gates by event-index + time) with two additions: `start_clock` for
per-entity stagger and `tween.zig` for easing. Slice 4 of the damage-number
feature.

- **`AnimKind`** (`types.zig`): `damage_number { entity_index, value,
  direction: Vector2 }` (direction = normalized attacker→defender delta, one
  of 8) + `heal_number { entity_index, value }` (no direction — fixed
  up-right from the top-left bbox corner).
- **`ActiveAnim.start_clock: u64`** (`types.zig`): when the anim begins
  visibly advancing. Non-number anims get `start = end - duration` (start
  immediately); `view()` adds a `animation_clock >= start_clock` gate (a
  staggered number is invisible before its start).
- **Per-entity stagger** (`state.zig` + `main.zig`): `SessionState.
  last_number_start_by_entity: AutoHashMapUnmanaged(u32, u64)` (backing-
  allocator-backed). `frame()`'s drain stamps `start_clock =
  max(animation_clock, last_for_entity + 125ms)` for number kinds and
  updates the map; cleared on screen/world transition via `clearAnims`. So
  Bash's attack+collision on one defender space their numbers 0.125s apart
  instead of overlapping. Constant `number_stagger_gap_microseconds` (main).
- **`tween.zig`**: `easeOutCubic` (1 - (1-t)³), pure `fn(f32) f32`. `view()`
  computes `progress = (clock - start) / duration` clamped to [0, 1], eases
  it, interpolates position. Unit tests for endpoints, monotonicity, and
  front-loaded shape.
- **Placement** (`view.zig` `buildWorldOverlays`, new `.damage_number`/
  `.heal_number` arms + `numberAnimPosition` helper): resolves the sprite's
  opaque bbox in screen space (via `sprite_bounds`, falling back to frame
  edges); picks the start point = the bbox edge/corner nearest the travel
  direction (pure-vertical → horizontal center; pure-horizontal → vertical
  center); travels `number_travel_tiles` (1) along the NORMALIZED direction
  (diagonal → magnitude 1, not √2, so the visual distance is consistent
  across the 8 directions); offsets the text top-left so it grows AWAY from
  the sprite (left-going → right edge at anchor; up-going → bottom at
  anchor; pure-vertical → horizontally centered). Font size =
  `ui.tooltip_body_font_size` (56). The number tracks the entity (resolved
  from the live level each frame, like the skill icon). Travel distance is
  half a tile (`number_travel_tiles = 0.5`); font size is `number_font_size`
  (112, ~2× the tooltip body, independently tunable).
- **Rendering**: `WorldOverlayDrawable.floating_text` (slice 3) — an
  8-direction black drop-shadow ring (8 `DrawTextEx` calls at ±
  `text_outline_thickness` offset) then the fill (`drawTextEx`, lightest) at
  the eased screen position. `font_metrics` threaded into
  `buildWorldOverlays` to measure text width for centering/offset.
- **Triggers** (`event_handlers.zig`): `attack` and `collision` queue a
  `damage_number` (carrying `incoming_damage` + `sign(defender - attacker)`
  direction) alongside the hit flash, inside `if (incoming_damage > 0)`;
  `heal` queues a `heal_number` (carrying the APPLIED amount, so a full-
  health heal shows nothing). All gated `!replaying`. New file-private
  `sign` + `damageNumberDirection` helpers (the latter falls back to
  top-right `{1,-1}` for self-damage where the attacker→defender delta is
  `(0,0)`, avoiding a divide-by-zero NaN in the unit-vector math) + `number_anim_duration_microseconds` constant (matches
  `view.number_anim_duration_microseconds`).
- **Replay safety** holds by construction: the anim is a `SessionState` side
  effect gated `!replaying`; the clock read + stagger math stay in `frame()`;
  the direction is a deterministic gameplay value (computed from positions);
  undo hides via `event_index < current_event_index`.

### Active-effect overlays on entities (DONE)

Effect sprites now render on top of an entity while an effect is active. The
`EntityDrawable.front_effect_sprites` slot (empty scaffolding since the
drawable type was introduced) is now populated from each active effect's
declared overlay sprite.

- **`Effect.effect_sprite: ?[]const u8`** (new field on the `Effect` struct in
  `effects/effect.zig`, default `null`): the bare sprite stem under
  `assets/effects/` for an overlay drawn while the effect is active. Each
  effect self-declares its visual (same self-defining pattern as modifiers +
  callbacks); `view()` stays effect-agnostic via `getEffectDefinition`.
- **Reflect** sets `effect_sprite = "reflect"`. The asset was moved from the
  Unity project (`Assets/Resources/ReflectEffect.png`, 180×180) and scaled
  0.5x → `assets/effects/reflect.png` (90×90). StoneForm / ThatWhichLingers
  leave it null (no art yet). `Skills/Reflect.png` (256×256) is the separate
  skill-icon concern (bottom bar), not moved here.
- **Rendering** (`entityDrawable` in `view.zig`): one `SpriteDrawable` per
  active effect with a non-null `effect_sprite`, centered on the entity's
  opaque-art bbox (horizontal = frame center; vertical = midpoint of
  `sprite_bounds` top/bottom, frame-center fallback on a miss/transparent
  sprite — same resolution as the hit-flash one-shot). Native size
  `effect_overlay_size_native = 90`, scaled by `zoom`. Tinted with
  `active_theme.lightest`. Drawn as a front_effect_sprite (above weapons/gear,
  below the health bar, which sits above the art top so no overlap).
- **Replay safety** is free: `view()` reads `active_effects` from `GameState`
  (already on the snapshot timeline). Pure rendering — no new events, no side
  effects, no `queueAnim`/`queueSound`. Deterministic function of `GameState`.
- **Back vs front:** all overlays default to `front_effect_sprites` for now
  (Unity draws Reflect in front of the body). A `behind: bool` / draw-layer
  enum is a localized add if a future effect wants to sit behind the body; no
  current effect needs it. Animation (looping sheet) is likewise a localized
  extension (`frame_count` + reuse `animation_clock`) when an effect ships a
  sheet — the static-sprite field doesn't paint us into a corner.

### Stun overlay above the health bar (DONE)

A persistent `effects/stun` icon now renders above the health bar of any
entity with `stun_duration > 0`. Stun isn't an `Effect`-system effect — it's
just a duration checked at turn start to decide skip — so this is a direct
GameState read, not an `active_anims` entry.

- **Asset:** `Assets/Resources/StunEffect.png` (128×128) moved from the Unity
  project at full size → `assets/effects/stun.png` (128×128). Same
  `assets/effects/` folder as the reflect overlay.
- **Rendering** (`buildWorldOverlays` in `view.zig`): a second loop after the
  one-shot anim drain iterates `level.entities`; any entity with
  `stun_duration > 0` and `current_health > 0` emits a `floating_icon`
  `WorldOverlayDrawable` at the skill-icon's placement (horizontally centered
  on the frame; vertically `art_top_y - health_bar_total - drawn_size - gap`,
  i.e. above the always-on health bar). Native size `stun_icon_size_native =
  128` (1:1 with the art, no upscaling), scaled by `zoom`. Tinted with
  `active_theme.lightest`.
- **Not an anim:** no `queueAnim`, no `active_anims` entry, no clock, no
  duration. Pure rendering — `view()` reads `stun_duration` from `GameState`
  (already on the snapshot timeline) → replay-safe by construction. Visible
  for as long as the entity is stunned; vanishes the frame `stun_duration`
  hits 0.
- **Position sharing with skill-icon pop:** a stunned entity skips its turn
  (no skill use), and the skill-icon pop is on the caster, so the stun icon
  and a skill icon never co-occur on the same entity — the shared
  above-health-bar position is safe.
### Fix: undo during a mid-drain reverts to the current idle point (DONE)

**Symptom:** pressing undo while enemy turns are draining (a mid-drain state
with the event stack non-empty and/or a wait active) reverted the gamestate
one idle point FURTHER BACK than expected — past the attack step the player
was just at, back to the move phase.

**Root cause:** idle points (undo stops) are recorded only when the event
stack EMPTIES — a player action's full subtree completing. During a drain
(e.g. `player_skip_attack` → `turn_end` → enemy turns with waits → next
round's `turn_start`), no idle point is recorded until the ENTIRE round
completes. So `current_idle_index` still points at the idle point BEFORE the
drain started (the state the player was just at). The old `undo()`
unconditionally decremented `current_idle_index` before restoring — correct
when idle (the index points at where you sit, decrement goes to the previous
state), but mid-drain it decremented PAST the "current" position, skipping
the state the player expected to land on.

**Fix:** `undo()` detects mid-drain (`event_stack.len > 0` or `waiting != null`)
and reverts TO the current idle point WITHOUT decrementing, then calls
`discardFutureTimeline()` to trim the partial drain's recorded events (the
action never completed, so there's nothing to redo). When idle, the old
decrement-then-restore path is unchanged. Guard: if `idle_points` is empty
(no idle point to revert to — only possible during the very first drain
before any stack-empty), returns false.

**Behavior after fix:**
- 1st undo (mid-drain): cancel the enemy-turn drain, revert to the attack
  step (the current idle point). No redo (partial drain discarded).
- 2nd undo (now idle): revert to the move phase (previous idle point). Redo
  available (back to the attack step).

**Safety:** `maybeRecordIdlePoint`'s "not already an idle point" guard
already excludes undo/redo from recording duplicates — after mid-drain undo
lands on an existing idle point, the drain loop's `had_events && !has_events`
recording is skipped. `restoreTo` finds a snapshot at every idle point
(`takeSnapshot` via `recordIdlePoint`); the fast path restores directly and
clears `waiting`. `discardFutureTimeline` trims `event_history` to target,
`idle_points` to `current_idle_index + 1`, frees snapshots/checkpoints/cache
ahead. `redo()` is unaffected (only meaningful when idle). Test in main.zig.

### Bash collision: 0-damage number + outgoing-damage unification (DONE)

Two fixes from one troubleshooting session. Symptom: Bash into a wall showed
only one damage number (the attack's), not the collision's — looked like the
collision did nothing.

**Root cause:** the collision event fired correctly (verified via the session
log: `attack` then `knockback` then `collision`), but dealt 0 damage. Bash's
collision damage was `main_hand_damage / 2` (raw, integer-truncated) = 3/2 =
1, and the skeleton's coat defense bonus (1) fully absorbed it:
`getEffectiveIncomingDamage(1) = max(0, 1 − 1) = 0`. The damage-number + hit-
flash were both gated on `incoming_damage > 0`, so a 0-damage hit showed
nothing — the collision looked like a whiff.

**Fix 1 — 0 renders as a number (observability):** the `damage_number` queue
moved OUT of the `if (incoming_damage > 0)` guard in both the `attack` and
`collision` handlers, so a fully-absorbed hit floats a "0" — a connecting hit
is always observable. The `hit_flash` stays inside the guard (a flash reads
as "damage was dealt"; a 0 shouldn't flash). Damage application, death,
lifesteal, and `on_*_damage` callbacks remain gated on `> 0`. Docs synced:
DESIGN → Animation + the `AnimKind.damage_number` doc comment.

**Fix 2 — unify collision + attack outgoing damage (balance):** collision
damage now goes through `getEffectiveOutgoingDamage` (gloves + converted
momentum + outgoing effects) at the SKILL SITE, then scales — same pipeline
as `attack`. Before, `knockback_damage` was the raw weapon damage.
- `bash.zig`: `collision_damage = damage / 2` (half the effective outgoing,
  reusing the already-computed `damage`), was `main_hand_damage / 2`.
- `slam.zig`: `knockback_damage = caster.getEffectiveOutgoingDamage(
  main_hand_damage)`, was raw `main_hand_damage`.
- `event_handlers.zig` collision-handler comment corrected (no longer claims
  "no attacker outgoing damage modifiers apply" — they apply at the skill
  site now). Collision still does NOT go through damage intercepts (Reflect
  doesn't reflect collision damage — by design, unchanged).

The balance quirk that produced the original 0 (`main_hand_damage / 2`
truncating dagger collision to 1, cancelable by any defense ≥ 1) is accepted
as fine; the unification is about consistency, not changing that edge case.

### Aggro indicator one-shot anim (DONE)

A new one-shot anim showing the `world/aggro` sprite (128×128, ported from the
Unity project's `EnemyAggro.png`) above an entity's health bar for 500ms when
it gets aggroed. Mirrors the skill-icon pop placement (above the always-on
health bar, offset by the bar height + gap from the entity's art top via
`sprite_bounds`), tinted with `active_theme.lightest` (not the team gradient —
aggro is a neutral status, not team-coded). Triggered in the `aggro_around`
handler when an entity's `is_active` flips true (gated `!replaying`, same
shape as `queueSound`/the skill-icon anim); once per entity per level (the
handler skips already-active entities). Skips dead entities at render time.
Non-number anim → `start_clock = end_clock - duration` (starts immediately).

- `AnimKind.aggro_indicator { entity_index }` (types.zig).
- `aggro_around` handler queues the anim on the `is_active` flip
  (event_handlers.zig).
- `buildWorldOverlays` `.aggro_indicator` arm + `aggro_indicator_size_native`
  (128) constant (view.zig).
- Asset: `assets/world/aggro.png` (128×128, ported 1:1 — no downscale).

### Text color inherits theme lightest (DONE)

All UI text now defaults to the active theme's `lightest` (the artist's
offwhite) instead of pure white. Single change in the renderer's
`drawTextLabel`: it receives `view_state.active_color_theme.lightest` (already
passed to `drawUiElement` as `highlight_color`) and substitutes it when a
`TextLabel`'s `color` is `ui.default_tint` (pure white). `default_tint` becomes
the "unset" sentinel for text; explicitly colored spans (`ui.colored(...)`)
pass a non-`default_tint` color and are unaffected. Sprite tints
(Button/Slot/Image) keep `default_tint` = "no tint" — the substitution is
text-only. Damage/heal numbers (`floating_text`) already passed
`active_theme.lightest` explicitly, so they're unchanged. The old
`default_tint` doc comment ("until colors are wired to the active color
theme") is resolved — the wiring is the renderer-side sentinel substitution
(`default_tint` is comptime; `lightest` is runtime per level, so the
substitution must be at draw time, not in the struct default).

### Howl aggros all entities, not just opponents (DONE)

Howl (wolf cantrip) was filtered to opposing-team entities only — so a wolf
howling to rally its pack (same-team wolves in the other pack) found nothing
to aggro and returned priority 0, never firing. The expected behavior is that
a wolf uses Howl ASAP to activate nearby same-team wolves.

Fix: removed the team filter in both the `aggro_in_radius` handler
(event_handlers.zig) and Howl's `priority` (skills/howl.zig). Howl now aggros
every entity within radius regardless of team. Aggroing the player (team 0)
is harmless — `is_active` on the player is ignored by the loops that skip
entity 0 (enemy turn ordering, auto-skip-attack). Description + doc comments
updated.

### Aggro + level-end decoupling (DONE)

Two bugs in one fix:

**Bug 1 — aggro was mover-centric, not self-centric.** The old `aggro_around`
event carried an `entity_index` and used the MOVER's `aggro_range` to scan for
inactive opponents. So after the player (aggro_range 3) moved, only entities
within 3 of the *player* aggroed — a wolf with aggro_range 6 never detected the
player from 6; it only aggroed at level start (where `aggro_around` fired
per-entity) or on its own move. The fix makes aggro self-centric: the renamed
`aggro_check` (no payload) scans every inactive entity and activates it if IT
sees an opposing entity within ITS OWN `aggro_range`. One event covers the whole
level. Pushed at level start (single event, replacing the per-entity loop) and
after every `move_entity`.

**Bug 2 — level-end check only fired after moves.** The old `aggro_around`
handler carried the level-end win condition (player on `level_end` + no active
enemies → `end_level`), so it only ran after moves. Killing the last enemy while
standing on the exit (ranged skill, Reflect, etc.) did nothing until the player
moved again. The fix extracts the win condition into `check_level_end` (no
payload), pushed after `aggro_check` (LIFO → runs after, so newly-aggroed
enemies are counted) AND after `death` (the only event that changes the
alive-enemy count). Not pushed at level start (spawn and exit are always
different tiles).

Events: `aggro_around { entity_index }` → `aggro_check {}` (renamed + field
dropped); new `check_level_end {}`. Session-log format changes (renamed event +
new variant) but pre-release with no real saved sessions — the comptime
serializer/deserializer adapts automatically. 5 AI handler tests rewritten for
the new self-centric semantics.

### Skill range/radius outline on slot hover (DONE)

Hovering a skill button on the bottom bar previews that skill's reach as a
single square outline centered on the player — a geometric preview (Chebyshev
≤ N), not pathfinding reachability. `buildSkillRangeOutline` (view.zig) is
pure and off SessionState (off the undoable GameState) → replay-safe by
construction, same shape as the cursor/tooltip/drag-ghost hover passes.

- **Resolution:** hover point → `ui.buttonAt` → `button.action` →
  `ui.actionSkillSlot` (new pub inverse of the file-private `skillSlotAction`)
  → `player.skillInSlot` → `lookups.getSkillDefinition`. `ui.playerEntity`
  made pub (view.zig needs the player entity to resolve the slot).
- **Shape:** N = `definition.range` if non-null, else `definition.radius`;
  if neither, no overlay. `overlay_type` = `.range_outline` when range drove,
  `.radius_outline` when radius drove. One `TileOverlayDrawable` with
  `extent = 2*N + 1`, screen position at the top-left tile
  `(player.x - N, player.y - N)`. Drawn in full (may extend past level edges /
  over gaps). Tinted `active_theme.lightest` (same as the cursor).
- **Gating:** suppressed while dragging (same gate as the other hover passes).
  Works in levels AND hubs — skill slots appear on the bottom bar in both,
  and the preview is useful even when the skill isn't usable in a hub.
- **`TileOverlayDrawable.extent`** (new field, default 1): square side in
  tiles. Existing per-tile overlays (highlight, cursor) keep extent 1
  (unchanged). The renderer sizes the rectangle by `extent * tile_size`.
- **Unified outline thickness:** `drawTileOverlay` (raylib_backend.zig) now
  uses the shared `outline_thickness` (8 source px) × `world_scale` for ALL
  outline arms — the cursor's rectangle-lines fallback (was ad-hoc
  6×world_scale) and the range/radius/aggro arms (also 6×world_scale). The
  cursor's silhouette-mask fast path is unchanged. aggro_outline stays in the
  same renderer arm (picks up `extent`, default 1) but no builder emits it
  yet.
- **Test** (view.zig): range (Slice, range 1 → extent 3, .range_outline),
  radius (Slam, radius 1 → extent 3, .radius_outline), neither (Focus → no
  overlay), drag-suppressed (range skill + active drag → no overlay).
  Headless; asserts overlay_type, extent, color, and absence.

### Prepared-skill radius outline follows the tile cursor (DONE)

While a targeting skill WITH a radius is prepared (e.g. Flash Strike:
teleport to a target within range, then attack within radius of the
landing), a `.radius_outline` follows the tile cursor — previewing the AoE
that will hit around the landing tile the player is aiming at. The
valid-target highlights already mark where the player can land; this
previews the sweep as the cursor moves.

- `buildPreparedSkillRadiusOutline` (view.zig), called in the level branch
  right after `buildCursorOverlay`. Levels only (`prepared_skill` is null
  in a hub by construction). Pure over SessionState → replay-safe.
- **Condition:** `level.prepared_skill` set → resolve definition →
  `uses_targeting == true && radius != null` → `session.tile_cursor` set.
  Non-targeting radius skills (Spinblade, Slam, Blitz, Howl) don't qualify —
  their radius is their own reach, not a cursor-following preview. Today
  only Flash Strike matches; the condition is general.
- **Shape:** one `.radius_outline`, `extent = 2*radius + 1`, top-left tile =
  `(cursor.x - radius, cursor.y - radius)`, color `active_theme.lightest`.
  Drawn in full (may extend past level edges / over gaps), Chebyshev ≤ radius.
- **No validity gating:** shows wherever the cursor is, not only over valid
  target tiles. The valid-target highlights already mark valid landings;
  the outline previews AoE scale as the cursor moves.
- **Not drag-suppressed:** this is a prepared-skill state, not a hover pass.
- **Test** (view.zig): Flash Strike prepared + cursor set → radius_outline
  extent 3; no skill prepared → none; Spinblade (non-targeting radius)
  prepared → none; cursor null → none.

## Documentation

### Split AGENTS.md → AGENTS.md + DESIGN.md (DONE)

AGENTS.md had grown to ~122 KB / ~1950 lines, overwhelmingly settled design
prose (subsystem architecture, invariants, the "why X is shaped this way"),
not the "how to work here" rules the "read AGENTS at the start of every
session" contract assumes. Factored the settled-design sections into a new
DESIGN.md (read on demand, like DONE.md); AGENTS.md is now thin (Documentation,
Build & Test + Testing discipline + Commit policy, Code Style, Config File
Format, Zig 0.16 Gotchas, Key Files) + a new **Subsystem Map** — one line per
subsystem pointing into DESIGN (`Replay & side effects — see DESIGN → Replay
& Side Effects`).

Moved to DESIGN.md (16 sections, original order kept): Platform Seam, Audio,
Animation, Replay & Side Effects, Versioning, Logging & Replay, Determinism &
Tiebreaking, Input, Error Handling, File System & IO, Custom Missions &
Online Services, Architecture, Decorations & Footprint, Entity & UI Coloring,
Memory & Budget, UI Framework. (Versioning + Logging & Replay were not in the
original TODO list of sections to move but are settled design — moved too.)

Lifecycle adapted to four files: open question → TODO; settles → move prose
to DESIGN.md (not AGENTS); task completes → DONE. Bright line unchanged — a
fact lives in ONE place; AGENTS never restates design, it points; DESIGN never
restates a working rule, it links to AGENTS.

Cross-reference sweep done in ONE pass across all five surfaces (a half-split
leaves broken pointers, which is worse than either clean state — matches the
rename-to-taplop philosophy):
- **DESIGN.md:** internal `AGENTS → <design-section>` → `DESIGN →`; the two
  cross-refs to staying sections became `AGENTS → Build & Test` (web-build
  workflow) and `AGENTS → Build & Test → Testing discipline`.
- **AGENTS.md:** the Build & Test / Code Style / Key Files refs to design
  sections → `DESIGN →`; Code Style's comment convention now links via
  `DESIGN → <section>` and notes "the design lives in DESIGN.md"; the
  Documentation section rewritten to the four-file model.
- **TODO.md (21 refs) + DONE.md (31 refs):** design-section refs → `DESIGN →`;
  the 4 DONE refs to staying sections (Code Style ×2, Build & Test ×2) kept
  as `AGENTS →`; the TODO tech-debt entry for the split checked off.
- **Source code comments (169 refs across `src/**/*.zig`):** `AGENTS →` →
  `DESIGN →` blanket, then the 2 refs to staying sections (`Config File
  Format` in parser.zig, `Build & Test` in test_harness.zig) fixed back to
  `AGENTS →`. Comments only — zero build risk.

No prose edits to the moved design content — pure relocation + ref-target
rewriting. Content drift is a separate follow-up. `scripts/test.sh` confirmed
no breakage (the build generates files from `src/`, not the `.md`s, so the
split is a no-op build-wise; the code-comment sweep is comments-only).

### Split parser.zig into parser + loaders + writers + session_log (DONE)

parser.zig had grown to ~4784 lines, mixing five jobs. Split into four files
along the natural seams (the TODO proposed three; the read/write split added a
fourth at the user's request):

- **`src/parser.zig`** (1073 lines) — the generic config-file format layer:
  `Section`/`EntryGroup`/`KeyValuePair`/`ParsedConfigFile` types,
  `parseConfigFile`/`parseConfigFileFromPath`, section/key whitelists +
  `validateSections`/`validateFileFormatVersion`/`validateKeys`, value
  coercion (`asU32`/`asI32`/`asF32`/`asBool`/`asColor`/`parseEnum`),
  `findSection`/`findValue`, `freeParsedSections`, and the shared
  `file_format_version` constants (shared by loaders + writers). `findSection`,
  `findValue`, `parseEnum`, `validateSections`, `validateFileFormatVersion`,
  and the 9 `*_sections` arrays became `pub` so the other three files can use
  them.
- **`src/loaders.zig`** (2700 lines) — game-content loaders (config sections
  → typed `types.*`): `loadLevel`/`loadHub`/`loadMission`/`loadCampaign`/
  `loadPlayerSave`/`loadSettings`/`loadWeaponTypeDefinition`/
  `loadColorThemeDefinitions`/`loadSalvageDefinitions`/`loadDecorationRegistry`/
  `loadPlayerLoadout`/`parseEntityDefinition`, decoration footprint/anchor
  validation, editor dedup (`buildEditorMission`)/instantiation
  (`instantiateEditorLevel`), the `free*`/`clone*`/equality helpers, balance
  bounds (`boundedU32` + `max_*`), custom-sprite PNG dim resolution. Salvage
  (which had been misplaced AFTER the tests in the old file) now lives with
  the other loaders.
- **`src/writers.zig`** (508 lines) — save/settings writers (typed objects →
  config text): `writePlayerSave`/`writeWeapon`/`writeInventoryItem`/
  `writeSettings`/`writePlayerSaveToFile`. The inverse of `loaders.zig`; the
  round-trip tests import `loaders.zig` for read-back (one-way dependency,
  no cycle).
- **`src/session_log.zig`** (522 lines) — session-log serializer/deserializer
  (`writeEventLog`/`loadEventLog`/`SessionLog`), comptime-generic over the
  `Event` union.

Dependency graph (no cycles): `loaders.zig` → `parser.zig`; `writers.zig` →
`parser.zig` + `loaders.zig` (round-trip tests); `session_log.zig` →
`parser.zig` + `events.zig`. Call sites across 9 files updated to import the
right new file. AGENTS → Key Files updated to describe all four.

Pure code movement + import wiring + a few `fn`→`pub fn` visibility widenings;
no behavior change. Also fixed a stale comment in `types.zig` referencing a
non-existent `parser.buildLevelFileText` (editor save-to-disk is still
pending). Mechanical; tests pass throughout (each stage green before the next).

### Decoration occlusion — slice 1: inner outline mask infrastructure

Settled design: DESIGN → Decorations & Footprint → Occlusion inset. The
occlusion inset draws a thin INNER outline of an occluded entity/item/marker
over the decoration that draws in front of it, so the silhouette reads
through without the decoration receding. Slice 1 is the backend mask +
draw infrastructure (dormant — nothing calls it yet; slices 2+3 wire it).

- `generateOutlineMask` generalized with an `OutlineSide` enum (`outer`/
  `inner`). The INNER band is the morphological dual of the OUTER: instead
  of dilating the opaque silhouette and marking transparent pixels in the
  band, it dilates the transparent mask and marks opaque pixels. Same
  separable structure (horizontal then vertical), one `dilate_val`/
  `band_val` pair flips the opacity test by side. The outer call site
  (`ensureOutlineLoaded`) passes `.outer`; behavior unchanged for existing
  highlight outlines.
- New `inset_outline_cache` (same lazy/dupe-key shape as `outline_cache`) +
  `ensureInsetOutlineLoaded` + `getInsetOutlineTexture` + `drawOcclusionInset`
  (draws the inner mask tinted pure black at a caller-chosen alpha, over the
  full sprite rect — no scissor; the unoccluded overlap is self-subtle
  because it merges into the art's own black outline). `deinit` frees the
  new cache.
- Fixed a stale comment: `outline_thickness` was documented as "inner band
  hugging the silhouette" but the code produced an OUTER band; corrected to
  say outer, and noted it's reused by the inset.
- Reuses `outline_thickness` (8 source px) and pure-black tint per the
  settled design (matches the art's own drawn outline so the inset's
  unoccluded portion merges into the existing rim).

All view-side by construction in later slices → off GameState → replay-safe.
Tests pass.

### Decoration occlusion — slices 2+3: occlusion test + inset draw pass

Wires the slice-1 inner-outline mask into a live render pass. When a
decoration piece (overhang) draws in front of an entity / ground items /
flag pole, a thin black inner outline of the occluded thing is drawn over
the decoration so the silhouette reads through. The decoration stays fully
opaque and visually in front — "something continues behind here," not "the
tree faded." Settled design: DESIGN → Decorations & Footprint → Occlusion inset.

**`view()` — the occlusion test (`buildOcclusionInsets`).** After the unified
ground-entry y-sort, for each non-decoration entry E, emit one
`OcclusionInsetDrawable` if any decoration piece D at a higher sort index
(drawn after E — greater in the `groundEntryBefore` (sort_y, sort_x) order)
has a screen rect overlapping E's screen rect. O(entries × decoration_pieces)
per frame; fine at current caps. Only decorations are occluders (entities
over entities is deferred; the test generalizes). The inset draws ONLY when
occluded — an entity fully in the open gets nothing; a partially-hidden
entity gets the ring; a fully-hidden entity gets a full silhouette ring on
the decoration.

**Screen rects.** `groundEntryScreenRect` computes a float bounding rect per
entry. Entities use the opaque-art bbox (tight, via `sprite_bounds` keyed by
the bare stem — `GroundEntry.entity_sprite` carries it from
`collectEntityEntries`) so an entity standing NEXT TO a decoration doesn't
falsely trigger an inset; falls back to the full 512×640 frame when bounds
are unavailable. Decoration pieces (256×256 chunks), ground items (256×256),
and flag poles (256×512) use their full sprite frame — single-sprite
drawables whose frame is tight enough.

**Draw model (no scissor).** The inset mask is drawn over the occluded thing's
FULL sprite rect, tinted pure black at alpha 128 (50%), in a post-ground pass
after `drawGroundDrawable` and before floating world overlays:
- over the decoration (occluded region): 50% black on the decoration's color
  → a dark trace of the entity's inner silhouette edge. The cue.
- over the visible art (unoccluded region): 50% black just inside the
  silhouette → a subtle extra darkening that merges into the art's own black
  outline (the art ships with a drawn black outline, so the unoccluded
  overlap reinforces it rather than adding a competing rim).
No clipping is needed because the unoccluded overlap is self-subtle and the
decoration stays fully opaque.

**`OcclusionInsetDrawable`** on ViewState: `{ sprite_id, screen_position,
alpha }`. The backend's `drawOcclusionInset` resolves the mask texture dims
(= the sprite's own dims) and computes the destination rect from
`screen_position` × `world_scale` — same shape as `drawHighlightOutline`.
Built from the entity's BASE sprite only (weapons/gear/effects extending
beyond the base aren't traced — acceptable for the body-mass occlusion case;
ground items and flag poles are single-sprite, so exact).

All view-side → off GameState → replay-safe by construction. Native build +
tests green; game runs without crashing.

### Decoration occlusion — follow-up: disk-SE outline

Replaced the square (Chebyshev) structuring element in `generateOutlineMask`
with a DISK (Euclidean) SE for both the OUTER (highlight halo) and INNER
(occlusion inset) bands. The square SE was separable (horizontal then
vertical, O(w·h·2t)) but its band was uniformly thick in Chebyshev distance
→ ~√2 thicker along diagonals in Euclidean terms, giving slightly blocky
45° corners. The disk SE (offsets with dx²+dy² ≤ t²) is not separable — a
single 2D pass, O(|band pixels| × |disk|) (~217 offsets at t=8) — but the
mask is cached per sprite (built once), so the higher cost is amortized and
the payoff is smoother corners.

- `DiskOffset = struct { dx, dy }` + a one-per-call `std.ArrayList(DiskOffset)`
  built from the dx²+dy² ≤ t² test (the (0,0) offset is skipped — a
  band-eligible pixel matches `band_val`, so it can never itself be a
  `dilate_val` source hit). The band-output loop scans the disk per
  band-eligible pixel, breaks on the first source hit.
- Updated the function doc + DESIGN → Decorations & Footprint → Occlusion
  inset prose (was "Chebyshev/separable"; now "Euclidean disk, single 2D
  pass, cached").
- Changes the appearance of the EXISTING outer highlight outlines (UI
  buttons, tile cursor) too — intentionally; the smoother corners apply to
  both outline uses. Revert the commit if the disk look reads worse than the
  square.

Native build + tests green.

### Decoration occlusion — composited silhouette (weapons + flag banner)

The occlusion inset now traces the FULL rendered silhouette of the occluded
thing, not just the base sprite. For an entity: base + body layers + weapons
(main + off-hand, off-hand flipped) composited into one 512×640 opaque mask
before dilating. For a flag: pole + the current animated banner frame
composited into one 256×512 mask, so an occluded flag shows the ANIMATED
banner's silhouette, not just the static pole. Ground items stay a single-
sprite stack (the degenerate case).

**Why composite-then-dilate (not composite individual masks).** Dilation
distributes over union: `dilate(A ∪ B) = dilate(A) ∪ dilate(B)`. So for an
OUTER band you could composite dilated silhouettes. But the INNER band is
`sil ∩ dilate(¬sil)`, and `¬(A ∪ B) = ¬A ∩ ¬B`, and dilation does NOT
distribute over intersection. So inner requires the union silhouette FIRST.
Since we want inner (occlusion inset), we composite-then-dilate. (This also
keeps one code path for both inner and outer if outer-composite is ever
needed.)

**Backend refactor.** Extracted the dilation core from `generateOutlineMask`
into `dilateToMask(opaque_mask, w, h, thickness, side) -> []u8` (RGBA buffer),
shared by the single-sprite path (Image → opaque_mask → dilate) and the new
composite path (sprite stack → opaque_mask → dilate). `rgbaBufToTexture` wraps
the buffer into a texture (shared). Replaced `inset_outline_cache` (keyed by
single sprite_id) with `composite_inset_cache` (keyed by a stack-composition
string: frame size + per-sprite `id|flip|source-rect`). `getCompositeInsetTexture`
builds the key, looks up / fills the cache. `generateCompositeOutlineMask`
decodes each sprite, ORs its alpha (alpha > 16) into a frame-sized opaque
mask via `blitSpriteAlpha` (honoring `flip_horizontal` — mirrors source columns
within the region — and `source_rectangle` for the banner frame slice), then
dilates. A missing sprite contributes nothing; the rest of the stack still
composites.

**View side.** `OcclusionInsetDrawable` changed from `{ sprite_id }` to
`{ sprite_stack: []const StackSprite, frame_width, frame_height, ... }`.
`InsetTarget`/`occlusionInsetTarget` now builds the stack: `entityInsetTarget`
(base + layers + weapons), `flagInsetTarget` (pole + banner_source_rectangle),
`singleStack` (ground items). Gear and effect sprites are excluded (gear is a
separate concern; effects are transient — including them would make the
outline flicker and balloon the cache). `StackSprite = { sprite_id,
source_rectangle, flip_horizontal }` added to types.zig.

**Cache growth.** Composite masks are keyed by loadout (not bounded by shipped
sprite count like the asset caches), but the number of *occluded* distinct
stacks is small (you don't hide every entity type behind a tree every frame),
so it fills slowly. The flag animates → 8 cached masks per flag (one per
banner frame), ~4 MB. Started unbounded (matching the existing caches'
philosophy); eviction is a deferred lever if a real session shows growth. The
first occlusion of a given stack has a one-time ~50-100ms hitch (decode N PNGs
+ 512×640×217 dilation); amortized after. Optimization is deferred until felt.

Native build + tests green; game runs without crashing.

## UI

### Top bar — options + undo buttons

Two buttons in a top-anchored row mirroring the bottom bar's conventions
(`Row`, `ui_gap`, `slot_size`): the options button (`ui/icon_options`,
`.toggle_options_menu`) flush in the top-left corner, then `ui_gap`, then the
undo button (`ui/icon_undo`, `.undo`). The rest of the row width is reserved
for the combat-log region (not yet rendered). `top_bar_height` bumped 100 →
256 to fit full `slot_size` buttons. `buildTopBar` is called from `view()` for
`.level` and `.hub` (same branch as `buildBottomBar`), before the bottom bar
so the bottom bar's hover-highlight pass wins ties.

No new input plumbing: `Action.undo` already existed and `applyAction` already
routed it to `anytime.undo` → `history.undo` (the same path as Ctrl+Z). The
button is just an alternate trigger. `history.undo` no-ops at the earliest
idle point, so no disabled state is needed — the only context with nothing to
undo is a fresh main menu, where the top bar isn't shown. `releaseSoundForAction`
got `.undo, .redo => .menu` (placeholder until a dedicated sfx ships). Buttons
draw magenta placeholders until real `ui/icon_options.png` / `ui/icon_undo.png`
art lands (project missing-art convention).

### Options menu — slice 1 (surface + Continue + Save)

Full-screen modal 9-slice panel (`ui/panel`) with a centered button stack
reusing `emitPanelButton` / `menu_button_*` constants (same design as the
main menu). Context-specific button list; today both hub and level emit
Continue (`.toggle_options_menu` — the toggle closes the menu) + Save
(`.save_game`). Level-only tier-2 buttons (restart mission, exit mission,
exit to main menu) are deferred to slice 2 — they need the `end_level`
continuation override (TODO → Mission Flow).

**Input plumbing.** New `AnytimeInput.options_action: ?Action` (one field
scaling to slice 2's exit buttons). `applyAction` routes `.save_game` there.
`handleAnytimeInput` dispatches `options_action` **before** the modal gate
(the `if (options_menu_open) return;` that pauses the game), so the action
takes effect immediately despite the menu freezing the world. For `.save_game`:
compute a timestamped path `saves/save_YYYYMMDD_HHMMSS.txt` (reuses
`formatSessionTimestamp`, distinguishable from a future `autosave.txt`),
capture `event_stack.len` as baseline, push the existing `save_game` meta
event (orchestrates `build_data_from_player` sync + `write_save` file write),
then drain back to baseline. The baseline is the stack depth when the menu
opened — nothing drains while the menu is open (`update()` returns at the
gate), so it's unchanged.

**Idle-point recording: no special case.** The normal `maybeRecordIdlePoint`
in `gameLoop` handles both cases: if the menu opened from idle (stack empty),
the save's events drain empty and an undo stop is recorded; if mid-enemy-turn,
the save bundles into that drain's existing idle point. Mirrors the
wait-interjection drain's "no idle point" stance for the mid-drain case, but
without hardcoding it — the general mechanism does the right thing.

**Save path + web.** `saves/` at the persistent root is not prefix-rejected
(only `data/`/`assets/` are), so no `FileSource` change needed. The existing
`writePlayerSaveToFile` writes to IDBFS on web (persists across refreshes).
Browser-download save is a future slice (TODO → Platform Layer → Web save via
browser download prompt). The `save_game` event's `!replaying` guard prevents
undo/redo scrubbing from rewriting the file or spamming download prompts.

**Render order.** `buildOptionsMenu` is called from `view()` after tooltips
but before the error popup, so the error popup stays the most-modal surface
(a save failure surfaces over the options menu). The full-screen panel is
`blocks_input: true`, so `hitTest` shields the bottom/top bar buttons behind
it — no hover leaks through.

`Action.save_game` added to the enum; `releaseSoundForAction` got
`.save_game => .menu` (placeholder). Native build + tests green; game runs
without crashing.

### Options menu — slice 2 (exit paths)

The three level exit-path buttons (restart mission, exit mission, exit to main
menu) plus exit-to-main-menu in hubs. The core change: `end_level` went from
`void` to `struct { continuation: LevelExitContinuation = .default }`,
mirroring the editor exit-guard pattern. The new `LevelExitContinuation` enum
(`.default`, `.restart_mission`, `.exit_mission`, `.exit_to_menu`) selects the
continuation; `.default` preserves the existing next-level / end-mission flow.

**Handler.** `end_level` now branches on `end.continuation` after the editor
guard: `.restart_mission` pushes `start_mission` on the same path (player
keeps their gear — `build_data_from_player` syncs before `start_mission`
runs, LIFO); `.exit_mission` pushes `end_mission` with `mission.start_hub`
(fallback `player_data.current_hub`) — abandoning the mission returns to the
hub the player entered from, not the completion hub; `.exit_to_menu` pushes
`open_main_menu`. `build_data_from_player` is still pushed last (runs first,
LIFO) for all paths, syncing the player entity into PlayerData before the
screen transition clears the level scope. The no-enemies level-completion
push site updated to `.{ .continuation = .default }`.

**Hub exit-to-menu.** In a hub, there's no `end_level` to route through — the
dispatch pushes `end_hub` + `open_main_menu` (LIFO: `end_hub` syncs the hub
player entity first, then `open_main_menu` transitions the screen and clears
the hub scope). The dispatch branches on `current.screen`.

**Input plumbing.** New Actions `.restart_mission`, `.exit_mission`,
`.exit_to_menu` routed to `anytime.options_action` (same field as save). The
`handleAnytimeInput` dispatch pushes `end_level` (or `end_hub`+`open_main_menu`
for hub exit-to-menu) and drains to baseline, same shape as save. Level-only
actions (`restart_mission`, `exit_mission`) guard on `current.screen == .level`
— the buttons are only emitted in the level options menu, but the guard is
defensive against an action reaching the handler in the wrong context.

**Menu closes automatically.** The screen transition (`.exit_to_menu` →
`.main_menu`, `.exit_mission` → `.hub`) or world_generation bump
(`.restart_mission` → new `start_level`) is detected by `gameLoop`, which
resets `ui_state = .{}` (clearing `options_menu_open`). If a reconstruction
read fails (load_error), the drain breaks, `gameLoop` reverts to the last idle
point, and the error popup surfaces over the still-open menu.

**Event shape change.** `end_level: void` → `end_level: struct { continuation
}` changes the session-log format for that event. The comptime-generic
serializer/deserializer handles it automatically (void → struct with fields).
Cross-session log reload isn't wired yet (replay viewer is the TODO), so no
existing logs break. The comptime round-trip test in session_log.zig covers
the new shape automatically.

**buildOptionsMenu.** Level: Continue + Restart Mission + Exit Mission + Save
Game + Exit to Main Menu. Hub: Continue + Save Game + Exit to Main Menu. Same
`emitPanelButton` / `menu_button_*` design as the main menu.

`releaseSoundForAction` got `.restart_mission, .exit_mission, .exit_to_menu =>
.menu` (placeholder). Native build + tests green; game runs without crashing.
TODO → Mission Flow updated: the options-menu exit paths are DONE; remaining
is death/mission-fail exits (need the end-state screens).

### Mission-fail overlay

Full-screen modal shown when the player dies in a level. Large "Defeat" text
centered above a two-button stack: Restart Mission + Exit Mission (reusing
the existing `.restart_mission` / `.exit_mission` actions from the options
menu — same `options_action` dispatch path, same `end_level` continuation
override).

**View-derived, not a flag or Screen variant.** `view_mod.playerDead` checks
`level.entities[0].current_health == 0`. This is the key design decision: the
overlay is a pure function of undoable GameState, so it's automatically
undo-safe. If the player undoes past their death, health is restored in the
reconstructed state and the overlay disappears — no flag to clear, no
`SessionState` side effect, no replay concern. This is different from the
options menu (user-toggled flag) and the error popup (handler-set flag), both
of which have explicit clear semantics. Player death is already in the
undoable GameState, so deriving from it is cleaner.

**Pause machinery.** Three sites cooperate:
- `update()`: a player-dead gate after the options-menu gate returns early,
  blocking event processing + idle input. Button clicks and `options_action`
  dispatch still run (they're in `handleAnytimeInput`, before the gate).
- `gameLoop` drain loop: `!playerDead(...)` in the condition so it doesn't
  spin on unprocessable enemy-turn events (which would burn the drain budget).
- `gameLoop` idle frame: `playerDead(...)` in the condition so `update()`
  still runs once per frame (for button clicks + the options_action drain).

**`check_level_end` fix.** Added a player-dead early return before the win
check. Without it, a dead player on the exit tile with no remaining enemies
would falsely trigger level completion (the win check only tests position +
enemy count, not player health). Now: player dead → skip win check → the
mission_fail overlay shows instead.

**`death` handler.** When `entity_index == 0`, plays the `.defeat` sound
(gated `!replaying`). This is the audio trigger the TODO was waiting for.

**Options menu blocked during death.** `handleAnytimeInput` skips the
`toggle_options_menu` flip when the player is dead — the mission_fail overlay
is the only modal that should show. Undo/redo still works (processed before
the gate) as an escape from the fail state — the player can undo past the
death instead of clicking restart.

**Render order.** `buildMissionFail` is called from `view()` after the
options menu but before the error popup, so: death takes precedence over a
manually opened options menu (the fail overlay draws on top), but a
reconstruction-read failure still surfaces its error popup on top of
everything. The full-screen panel is `blocks_input: true`, shielding the
top/bottom bar buttons behind it.

Native build + tests green; game runs without crashing.

### Mission-fail overlay — freeze-frame fix

Initial implementation had two bugs (no sound, no overlay rendered) with one
root cause: when the player died mid-enemy-turn, the `death` event (pushed by
the `attack` handler) sat on the stack unprocessed. The drain loop exited
early on `!playerDead(...)` before reaching it, and the `playerDead` gate in
`update()` blocked the idle-frame `update()` from processing it. Worse, the
unprocessed event kept `event_stack.len > 0`, so the render gate's
`drain_in_progress` check skipped `view()`/`render()` entirely — the overlay
was never built.

**Fix: freeze-frame policy in the death handler.** When `entity_index == 0`,
the death handler plays `.defeat` and clears `event_stack = &.{}`. The death
event is already on top of the stack (LIFO) and already popped by
`processEvent` before the handler runs, so `event_stack` at that point holds
the remaining enemy-turn events. Clearing them → drain exits (stack empty) →
idle pause kicks in → overlay renders. The moment of death is the last thing
the player sees; remaining enemies don't act (Into the Breach style).

**Why skipping the rest is safe for player death:** item drops are guarded
`if (entity_index != 0)` (no-op for the player — they keep their gear);
`onOpponentDeath` callbacks fire on enemies when the player dies (irrelevant,
mission over); `check_level_end` early-returns for a dead player. The only
meaningful effect of the death event for player death is the sound, which we
keep.

**Drain-loop + gate adjustment.** Removed `!playerDead(...)` from the drain-
loop condition (let the drain reach the `death` event — the handler clears
the stack itself). Kept the `playerDead` gate in `update()`: after the
freeze-frame the stack is empty, so the gate blocks idle input/drag/camera-
pan (modal overlay) without blocking events (there are none). Undo/redo and
the restart/exit buttons still work (handleAnytimeInput, before the gate).

**Replay consistency.** The `death` event is recorded in the session log
(processEvent records before dispatching). During replay the death handler
runs, clears the stack (harmless — replay processes events one at a time
from the log, no cascades to clear for player death). The log reads:
`...attack (kill), death`. Undo reconstructs to the pre-enemy-turn idle
point; the death state is derivable from health == 0. No cosmetic-wait
skipping needed — the stack clear removes remaining enemy events AND their
intervening 500ms waits; the drain exits in <1ms after the death.

### Mission-fail overlay — remove the playerDead gate

The freeze-frame fix alone wasn't enough: the `playerDead` gate in `update()`
(return early before `processEvent`) blocked the `death` event from ever
processing. The death handler's stack-clear never ran; the `death` event sat
on the stack; the render gate's `drain_in_progress` (event_stack.len > 0)
skipped `view()`/`render()` entirely — so no overlay, no sound.

Analysis: the gate protected drag, camera-pan, and idle input for a dead
player. But all three are already self-gating: idle input only runs in
`player_move`/`player_attack` turn phases (the death happened mid-enemy-turn,
so no player phase is active; and even if one were, handlers check
`current_health == 0` and return early); drag/camera-pan behind the overlay
are a minor cosmetic leak (the overlay's full-screen `blocks_input` panel
shields them next frame via `previous_view_state`). Not worth a gate that
breaks the death handler.

Fix: removed the `playerDead` gate from `update()` and the
`playerDead` term from the idle-frame condition. `processEvent` now reaches
the `death` event, which plays the sound + clears the stack; the drain exits;
the render gate fires; the overlay renders. The freeze-frame (death handler
clears event_stack) + existing idle-input self-gating + the overlay's own
`blocks_input` panel cover everything the gate was trying to.

### Mission-complete overlay

Full-screen modal shown in the hub after the player completes the last level
of a mission. Header "{mission_name} completed" + Continue + Replay Mission
buttons. Stats / leaderboard position / clone rewards are deferred — the
header + buttons are the MVP surface.

**Trigger: SessionState flag, not view-derived.** Unlike mission_fail (derived
from player health), mission_complete happens at a screen transition (end_level
→ end_mission → start_hub), and the mission is discarded when start_hub runs.
So `end_level`'s `.default` last-level branch stashes the mission name + path
onto `SessionState.pending_mission_complete` (a `MissionCompleteInfo` struct,
duped into `history_arena` like `pending_error`) before pushing `end_mission`.
The flag survives the level→hub screen transition (it's on SessionState
directly, not `ui_state` — the gameLoop's `ui_state = .{}` reset on screen
change doesn't touch it). The cascade runs normally (end_mission → start_hub →
hub); the overlay renders in the hub post-transition. Gated `!replaying` so
undo/redo scrubbing doesn't pause or show the overlay.

**Why not pause mid-drain (Option C)?** Pausing the drain before the cascade
(keeping the level loaded) was considered, but it needs drain-pausing +
undo-flag-clearing machinery. Stashing + showing post-transition is simpler:
no drain-pausing, no gate in the drain loop, the cascade completes normally,
and the overlay shows in the hub the player returns to — arguably better
(back at base, ready to choose the next mission).

**Buttons.** Continue (`.continue_after_mission`) just clears the flag — the
player is already in the hub. Replay Mission (`.replay_mission`) clears the
flag + pushes `end_hub` + `start_mission` on the stashed path (LIFO: end_hub
syncs the hub player entity into PlayerData first, then start_mission reloads
the mission). Same `options_action` dispatch path as the options menu /
mission_fail buttons — pushed + drained before the `update()` gate.

**Gate.** `update()` returns early when `pending_mission_complete != null`
(same position as the options-menu gate), blocking idle input / drag /
camera-pan in the hub while the overlay is up. `handleAnytimeInput` runs
before the gate, so the Continue / Replay buttons work. The options-menu
toggle is blocked while the overlay is up (one modal at a time).

**Audio.** `.mission_completion` sound wired in `end_level`'s last-level
branch (gated `!replaying`), alongside the flag stash. The last audio TODO
item is done.

Native build + tests green; game runs without crashing.

### Mission-complete overlay — remove the gate (same bug as mission_fail)

The `pending_mission_complete` gate in `update()` (return early before
`processEvent`) blocked the end_mission → start_hub cascade from completing.
The flag is set inside `end_level`'s handler (before pushing `end_mission`);
on the next `update()` call the gate fired, `end_mission` never processed,
`start_hub` never ran — the player was stuck in the level with the flag set
but no overlay (screen still `.level`, not `.hub`).

Same class of bug as the `playerDead` gate, same fix: remove the gate. The
cascade completes normally (end_mission → start_hub → hub); the flag survives
on SessionState; the overlay renders in the hub. The overlay's full-screen
`blocks_input` panel shields drag/camera-pan/idle-input behind it; idle input
is self-gating (stack empty after the cascade; hub clicks are harmless behind
the panel anyway). No gate needed.

### Mission-complete overlay — undo-safe via GameState field

Replaced the `SessionState.pending_mission_complete` flag (off the undo
timeline, survived undo — the overlay stayed open on undo, needing manual
cleanup) with `GameState.last_completed_mission: ?MissionCompleteInfo` (on
the undo timeline, captured by snapshots). The overlay now renders when the
field is non-null, derenders when null — undo/redo handles both directions
naturally.

**Info flow through events.** The info rides the end_level → end_mission →
start_hub cascade:
- `end_mission` gained `completed_mission: ?MissionCompleteInfo = null`
- `start_hub` gained the same field
- `end_level`'s completion branch sets it on the `end_mission` it pushes
- `end_mission` passes it through to `start_hub`
- `start_hub` sets `current.last_completed_mission = start.completed_mission`
  (info or null — a normal hub entry clears any stale value)

`exit_mission` pushes `end_mission` with `completed_mission = null`, so
abandoning doesn't show the overlay. A normal hub entry (new game, load save)
also passes null, clearing stale values.

**Dismiss via event.** Continue pushes a new `dismiss_mission_complete: void`
meta event (handler sets `current.last_completed_mission = null`). On the
undo timeline: undo re-shows the overlay, redo dismisses it — falls out
naturally. Replay re-enters the mission (end_hub + start_mission); the overlay
disappears on the screen transition (renders only in the hub), and undo from
the level back to the hub re-shows it (the snapshot has the field set).

**`MissionCompleteInfo`** moved to types.zig (from SessionState) since
GameState + events reference it.

**Removed:** `SessionState.pending_mission_complete`,
`setPendingMissionComplete`/`clearPendingMissionComplete`. The options-toggle
guard now checks `current.last_completed_mission == null` instead of the
SessionState flag. No `update()` gate (same reasoning as mission_fail: the
overlay's `blocks_input` panel shields input; idle input is self-gating).

Native build + tests green; game runs without crashing.

### Mission-complete overlay — clear on replay

The overlay persisted after clicking Replay Mission because
`last_completed_mission` was never cleared in the replay path. The overlay
renders whenever the field is non-null (not gated on `screen == .hub`), so
it showed over the level too.

Fix: `start_mission` now clears `current.last_completed_mission = null` when
entering a mission (new game or replay). A mission attempt retires any prior
completion info. On the undo timeline via GameState, so undo from the level
back to the hub re-shows the overlay (the snapshot has the field set).

## Dev Tools

### Skip level (ctrl+Enter) + hybrid input precedence (DONE)

Two slices landed together because the keybind depended on the precedence fix.

**Slice 1 — hybrid input precedence.** `checkAction`/`isActionHeld` previously
used pure subset modifier matching: every binding whose required modifiers
were a subset of the held set fired, so a plain binding fired even when a
more-specific chord on the same key was the intent. This made ctrl+Enter
(before skip_level even existed) fire every plain-Enter binding (`confirm`,
`dismiss_error`) alongside any ctrl+Enter binding — three actions on one edge.

The fix is a hybrid model (not pure "one action per key", which would regress
shipped behavior): for a pressed input, among all matching bindings (subset
match), a binding is SUPPRESSED only if another binding on the SAME input
matches the held modifiers with strictly MORE required modifiers
(`modifierSpecificity` = count of ctrl+shift+alt). Equal-specificity ties
CO-FIRE — disambiguation stays with handler context downstream. This preserves
the shipped ArrowUp → `move_cursor_up` + `error_scroll_up` pair (both plain,
both fire; the pending-error popup branch consumes the scroll action and
returns) and the plain-Enter → `confirm` + `dismiss_error` pair, while making
ctrl+Enter beat plain Enter. `isSuppressed`/`sameInput`/`modifierSpecificity`
helpers in input.zig; 5 `checkAction` unit tests cover chord-suppression,
plain-fires-when-chord-modifier-not-held, equal-specificity co-fire, and a
3-level specificity ladder.

The "one combo → one action (uniqueness validated at load, collisions
warn-and-drop)" claim in DESIGN → Input was inaccurate — the loader appends
every binding with no uniqueness check. Corrected the prose to match reality
(equal-specificity ties co-fire by design; collision detection deferred — a
same-combo different-action pair is a tie, not an error, until a warning is
worth building).

**Slice 2 — skip_level.** New `Action.skip_level` + `IdleInput.skip_level`
field, bound to ctrl+Enter in `data/default_settings.txt` (press-only). The
handler arm in `handleIdleInput` pushes `end_level` with the default
continuation (`.{}`) — the normal next-level / mission-end cascade, the same
path the options-menu exit reuses. Gated to dev builds via
`@import("build_info").dev_mode` AND `current.screen == .level`. Idle placement
(handleIdleInput only runs with an empty stack + no active wait) means it never
interleaves with a draining enemy turn — no mid-drain multi-fire, no
cascade-interleaving with leftover enemy-turn events, no wait-branch
special-casing. Replay-safe by construction (a normal recorded event).

The dev-mode gate is a build option, not a runtime flag: `-Ddev-mode` in
build.zig, defaulted to `optimize == .Debug` (`zig build run` gets it for
free; release/web default clean). Threaded through the shared `build_info`
module already used by `game_version`. The binding ships in the settings file
regardless (one source of truth); the gate is at the handler site, so
`translateInput` stays build-agnostic and a non-dev build's flag is never
consumed (no-op). See AGENTS → Dev Tools.

Tests: `handler_tests_devtools.zig` — skip_level pushes end_level in a level;
skip_level is a no-op on the main menu (level-only gate). The dev-mode gate is
comptime, so the test build (Debug) exercises the live path; the
no-op-in-release path is the same branch with the condition inverted, not
separately tested.

### Replay structural whitelist + exit/skip orchestrators (DONE)

**The problem.** During replay, when the event stack drains, the replay loop
seeds the next recorded event as a fresh top-level event — assuming it's a
player-pushed event from an idle point. But nothing checked that assumption:
`validatePlayerAction` only ran inner legality checks (move reachable, skill
off cooldown) on 4 level events, with `else => {}` allowing everything else.
So a hand-crafted log could seed any handler-internal machinery event
(`attack`, `turn_end`, `end_level`, `start_mission`, ...) at an idle point
and the handlers would execute it — a replay spoof.

**The fix — two-layer validation at the seed site.**
1. **Structural whitelist (`isPlayerAction`)** — a fail-closed `switch` in
   state.zig that returns true only for event variants a player can push at
   an idle point, `else => false` for everything else. Runs before
   `validatePlayerAction` at both seed sites (`replayTo` +
   `replayToWithIdleTracking`). Rejects non-player machinery events by name.
2. **Context legality (`validatePlayerAction`)** — extended from level-only
   to also cover meta exit/skip orchestrators (screen must match: e.g.
   `player_restart_mission` only legal at `.level`, `player_exit_to_menu` at
   `.level`/`.hub`, `player_replay_mission` requires
   `last_completed_mission != null`).

**The orchestrator refactor.** The whitelist is a pure tag-check (no
continuation inspection) because every user action now maps 1:1 to a single
orchestrator event, and machinery events are never whitelisted. The exit/skip
paths used to push machinery directly (`end_level{continuation}`,
`end_hub` + `open_main_menu`, `start_mission` + `end_hub`) — those were
ambiguous (player-pushed AND handler-pushed), which would have forced
continuation inspection to disambiguate. Instead, 5 new meta orchestrator
events wrap them: `player_skip_level` (dev-only), `player_restart_mission`,
`player_exit_mission`, `player_exit_to_menu`, `player_replay_mission`. Each
orchestrator handler pushes the machinery events as children;
`end_level`/`end_hub`/`open_mission`/`start_mission` are now machinery-only
(never whitelisted, never seeded at an idle point). The input-handler push
sites were updated to push orchestrators instead of machinery.

`player_skip_level` is gated on `build_info.dev_mode` in `isPlayerAction` —
a non-dev replay that seeds it is rejected by name (not by a fragile
continuation rule). `end_level` spoofed at an idle point is rejected (it's
machinery, not whitelisted) — but `player_skip_level` (dev) and
`player_exit_mission` (any build) ARE whitelisted and produce the same
end-level effect, which is fine: exiting a level is a legitimate player
action in any build.

Tests: `isPlayerAction` whitelisted + rejected coverage in state.zig (bool
helper, directly testable — no panic-catching needed); `handler_tests_devtools`
updated to expect `player_skip_level` (the orchestrator) instead of
`end_level`. DESIGN → Determinism & Tiebreaking → Replay PLAYER-ACTION
LEGALITY updated with the two-layer model + orchestrator convention.

### Autosave — write on transitions + main-menu Continue (DONE)

Persistent autosave at `saves/autosave.txt` (path constant `writers.autosave_path`).
Two halves:

- **Write on transitions:** `end_level` and `end_hub` each push
  `write_save{autosave_path}` alongside their existing `build_data_from_player`
  sync, ordered so LIFO runs sync first, then the write (reads synced
  PlayerData), then the continuation. The editor `end_level` early-returns
  before this push, so playtest/validate never autosave (discard semantics —
  the real PlayerData is unchanged). Reuses the existing `write_save` handler
  (`!replaying`-gated, recorded in the session log as a no-op on replay,
  recoverable popup on write failure) — no new side-effect machinery.
- **Write on manual save:** the `save_game` handler (Save Player File button)
  pushes a second `write_save{autosave_path}` alongside the timestamped
  write, so a mid-mission save then quit then Continue doesn't lose loot
  picked up since the last hub/level transition. Same LIFO: sync first, then
  timestamped write, then autosave write.
- **Main-menu Continue:** new `PlayerInputEvent.player_continue` (whitelisted
  by `isPlayerAction` auto; `validatePlayerAction` arm: screen == .main_menu).
  Two branches by PlayerData state: populated (mid-session exit-to-menu) →
  `loadCampaignAndPushHub` resumes from in-memory data, no file read (also
  fixes the previously-broken no-op Continue in that case); empty (fresh
  launch) → `load_save{autosave_path}` loads the file then resumes at
  `player_data.current_hub`. Mid-mission resume is out of scope — Continue
  always resumes at the last visited hub.
- **Showing the button when PlayerData is empty:** `session.autosave_available`
  (SessionState, off the undoable GameState) detected ONCE at startup in
  `createSessionSetup` via `FileSource.fileExists` (a stat, no alloc —
  `view()` is pure, no file access). `continue_available = player_data
  .current_campaign.len > 0 or session.autosave_available`.

Tests: `handler_tests_autosave.zig` (5) — populated-continue resumes to hub,
empty-continue pushes `load_save` on the autosave path, `end_level`/`end_hub`
push sync-then-autosave, `save_game` pushes timestamped + autosave writes
(stack inspected, no disk write). `isPlayerAction` test covers
`player_continue`. Session-log serializer auto-handles the new variant
(comptime-generic). TODO → buildMainMenu Continue availability checked off.

### Reconstruction live-read miss is recoverable (not a crash) (DONE)

`readReconstructionFile` previously did `file_source.readFile(...) catch
@panic("failed to read reconstruction file")` on the LIVE path — so a
missing/unreadable file crashed before the handler's `catch` could turn it
into `failReconstructionRead` (popup + revert). This was an accidental
asymmetry: a CORRUPT file (read succeeds, parse fails) already went through
the recoverable path, but a MISSING one (read fails) hit the hard panic.
DESIGN → Error Handling → context 2 already lists `load_save` etc. as
recoverable, so the implementation had drifted from the design.

Fix: `readReconstructionFile` now returns `![]const u8` and PROPAGATES live
read errors. The ~6 reconstruction-read handlers (`load_save`, `start_level`,
`start_hub`, `start_mission` x2, `open_editor` x3, `start_new_game` via
`loadCampaignAndPushHub`) each catch the read error with
`failReconstructionRead(history, "failed to read <file>")` + return, the same
shape they already used for parse errors. The drain loop reverts to the last
idle-point snapshot + surfaces the popup (existing machinery, unchanged).

Replay path unchanged: in-session cache miss still `@panic` (a bug — live
always caches first); cross-session replay cache-miss + file-read-fail still
`@panic` (genuinely unrecoverable — the log references files that no longer
exist). The cache-miss `@panic` policy and the live-read-miss-recoverable
policy are SEPARATE; DESIGN prose now says so explicitly so the two don't get
re-conflated.

Autosave-specific: when `load_save` fails reading the autosave path,
`session.autosave_available` is cleared so the main-menu Continue button
disappears after the user dismisses the popup (no dead retry into the same
error). Generalizes the same latent bug for shipped-content reads (a broken
persistent-dir shadow of a level/hub/campaign file now popups instead of
crashing — "shipped content can't fail at runtime is false by construction"
per the recoverable class definition).

Tests: `handler_tests_autosave` gained "player_continue: missing autosave is
recoverable (popup + hide Continue)" — the harness FileSource uses cwd, no
`saves/autosave.txt` in the project root, so the read fails and the test
asserts `load_error` + `pending_error` + `autosave_available` cleared + screen
still main_menu, no panic. DESIGN → Error Handling → context 2 + the
`readReconstructionFile` prose updated.

## UI (additional)

### Inventory panel — grid display slice (DONE)

First slice of `buildInventoryPanel` (TODO → UI Framework → Panel Builders):
display the 8×12 inventory grid as colored slot backgrounds inside a 9-slice
panel, with the material-sidebar region reserved but empty (counts land in a
follow-up slice).

- **Asset:** ported the Unity `ItemSlot.png` (256×256) to
  `assets/ui/item_slot.png` at 0.5x → 128×128. Auto-embedded by
  `generated_assets.zig` (no build wiring). Slot sprite id: `ui/item_slot`.
- **Layout constants** (`ui.zig`): `inventory_slot_size = 128` (half
  `slot_size`), `inventory_panel_width = 1200`, `inventory_panel_height =
  1568`. Panel = `ui_gap` clearance (16) + flush 8×12 grid (1024×1536) +
  `ui_gap` + 128-wide sidebar + `ui_gap`. Slots are flush (no inter-slot
  gap) per the agreed spec; only the panel-edge clearance uses `ui_gap`.
  The old placeholder `inventory_panel_width = 1100` was replaced.
- **`buildInventoryPanel`** (`ui.zig`): emits one `nine_slice_panel`
  (`ui/panel`, `blocks_input = true`) + 96 `Slot` elements via the `Grid`
  helper (gap 0, columns = `types.inventory_columns`). Each slot renders
  `ui/item_slot` tinted with **player-gradient color index 5**
  (`active_theme.player_gradient.colors[5]`, clamped to
  `gradient_color_count - 1` like the bottom bar does). No `ref` / no item
  icons yet — drag/drop + item rendering are later slices. The 128-wide
  sidebar region is reserved by the panel width but nothing is drawn there
  this slice.
- **Multi-panel wiring** (`view.zig`): `buildMiddlePanels` dispatches each
  open `MiddlePanelId` to its builder, stacking built panels left-to-right
  flush against the left edge of the screen (x=0), vertically centered in
  the middle section (the band between the top and bottom bars, height =
  `reference_height - top_bar_height - bottom_bar_height` = 1648; the
  1568-tall inventory panel centers with 80px to spare). `ui_gap` separates
  consecutive built panels. Panels without a builder yet (gear / skills /
  enemy_inspect) reserve no space — they `continue`, so they slot in
  without disturbing the layout when their builders land. Called from the
  level/hub branch of `view()` after the bottom bar. Horizontal scroll
  (`ui_state.middle_section_scroll_offset`) is a later slice.

### Inventory panel — material sidebar slice (DONE)

Second slice of `buildInventoryPanel`: the right-hand 128-wide sidebar
showing the player's five material counts as a bottom-aligned stack of
tinted icons, each with an outlined count label in its bottom-right corner.

- **Assets:** ported the five Unity `{Material}Salvage.png` sprites (already
  128×128 RGBA, no rescale needed) to `assets/ui/material_{wood,metal,
  leather,cloth,knowledge}.png`. Sprite ids: `ui/material_*`. Auto-embedded.
- **Outlined UI text:** added `outlined: bool` to `ui.TextLabel`. When set,
  `RaylibBackend.drawTextLabel` draws a pure-black 8-direction drop-shadow
  ring (offset radius `text_outline_thickness` = 8 source px) under the fill
  — the same machinery as floating damage numbers (see DESIGN → Animation),
  reused in the UI draw path. UI is drawn 1:1 at reference resolution into
  the render target, so no `world_scale`; the thickness constant is used
  directly. 9 draws per outlined label; cheap for the rare outlined UI text
  (material counts today). This is the first UI text to use the outline; the
  `floating_text` world-overlay path remains the other consumer.
- **Sidebar layout** (`buildInventoryPanel`): the 128-wide sidebar sits
  `ui_gap` right of the grid (x = origin + ui_gap + 1024 + ui_gap). Five
  material icons stack **bottom-aligned** — the stack's bottom edge meets
  the grid's bottom edge (top of stack = grid_bottom − 5×128). Order
  top-to-bottom with fixed player-gradient color indices:
  wood (5), metal (2), leather (5), cloth (2), knowledge (0) — the spec'd
  alternation. Each icon is an `Image` (128×128, `blocks_input = false` so
  the panel behind it keeps the hit-test). Each carries a `TextLabel` count
  (`material_count_font_size` = 48) in its bottom-right corner, inset
  `material_count_inset` = 8px, `outlined = true`. The count is measured via
  the font-metrics seam so it's truly right-aligned (label_x = icon_right −
  measured_width − inset).
- **Data source:** `current_state.player_data.materials` (the `Materials`
  struct: wood/metal/leather/cloth/knowledge, all `u32`). Materials live on
  `PlayerData`, not on the in-level `Entity` (entities carry `inventory`
  items only), so the sidebar reads the same field in level and hub.
- `buildInventoryPanel` now takes `font_metrics` + `materials` params;
  `buildMiddlePanels` (view.zig) threads both through from `view()`.

### Inventory panel — item icons slice (DONE)

Third slice of `buildInventoryPanel`: render the items actually in the
player's inventory slots on top of the slot frames.

- **Assets:** ported the 12 Unity `Resources/Items/*.png` sprites (already
  128×128 RGBA, no rescale) to a new `assets/items/` folder:
  `sword, shield, spear, dagger, axe, staff, amulet, coat, gloves, pants,
  boots, skill_tome`. Unity's `WandItem` maps to our `WeaponType.staff`
  (the enum name differs; the art is the wand). Auto-embedded by
  `generated_assets.zig` + `generated_sprite_metadata.zig` (no build
  wiring — new folder picked up automatically).
- **`itemIconSpriteId(item: Item) []const u8`** (`ui.zig`, `pub` so the gear
  panel reuses it): maps an `Item` to its `items/<id>` sprite. Weapons
  resolve per `WeaponType`; gear types one each; `skill_tome` uses the
  single generic tome icon (the taught skill is separate info — a per-skill
  tome icon is a later slice).
- **Slot rendering:** each non-null inventory slot now emits the `Slot`
  frame (`ui/item_slot`, color index 5, the hit-test surface) followed by an
  `Image` of the item icon on top (128×128, `blocks_input = false` so the
  slot beneath stays the single interaction target). Item icons render at
  **player-gradient color index 1** per the current spec (per-item coloring
  is a later slice). Empty slots render just the frame, unchanged.
- **Data source:** the live inventory rides on the player entity
  (`ui.playerEntity(current_state).inventory`) — in-level pickups land on
  `entity.inventory`; `player_data.inventory` is the persistent copy synced
  only on `build_data_from_player` at exit, so reading it mid-level would be
  stale. Materials still read from `player_data.materials` (entities carry
  no materials field). `buildInventoryPanel` now takes an `inventory` param;
  `buildMiddlePanels` resolves it from the player entity (defaulting to an
  empty `Inventory` if there's no player, e.g. a degenerate hub).

### Inventory click + drag UX slice (DONE)

Modal click UX on inventory items + movement-threshold drag/click
disambiguation + full drag refactor onto orchestrators (player input never
pushes machinery events anymore).

**Click UX (the spec):** modifier + double-click intents on a content
inventory slot, anytime (not gated on the event stack — salvaging/equipping/
learning during enemy turns is allowed; the pushed orchestrator drains
mid-wait like `swap_hands`):

| trigger | intent |
|---|---|
| double left / ctrl+left / alt+right | equip-main (weapon→main hand; gear→its slot; tome→learn or salvage if learned) |
| double right / ctrl+right / alt+left | equip-off (weapon→off hand; gear/tome→same as equip-main) |
| shift+left | salvage |
| shift+right / modifier combos (2+) | no-op |
| plain single left/right | none (seeds a pending double) |

Precedence: shift > ctrl > alt > plain-double; combos (≥2 modifiers) = no-op.

- **`PointerInput.modifiers`** (input.zig): surfaced the held modifiers on
  the pointer so slot-click handlers resolve modifier-keyed intents without
  reaching into `InputState`. Filled by `translateInput` from `getModifiers`.
- **Movement-threshold drag/click** (ui.zig + input_handlers.zig):
  `PendingSlotPress` on `UiState` records a press (source, icon, press
  position, button). Move ≥ `drag_threshold_pixels` (8 ref px) promotes it to
  `DragState` (ghost appears); release within threshold over the SAME slot =
  click, elsewhere = cancel. Right-button presses never drag (right-drag is
  camera pan on the world; panels block it, so right-press on a slot is a
  click only). Replaces the old press=starts-drag-immediately model.
- **Double-click detection:** `LastItemClick` on `UiState` (off the undo
  timeline → replay-safe) records the last plain single click (slot + button
  + `session_clock` time). A second plain click on the same slot+button
  within `double_click_threshold_us` (400ms) fires the double-click intent.
  Only plain (no-modifier) single clicks that didn't fire seed a pending
  double; modifier-clicks fire immediately and clear it (so a ctrl+click
  can't pair with a later plain click into a spurious double).
- **`resolveItemClick(button, modifiers, is_double) ItemIntent`** — pure
  intent resolver (tested). `resolveInventoryClick` does the double-click
  bookkeeping + pushes the orchestrator.
- **Inventory slots now carry `ref = .{ .inventory = index }`** so
  `slotAt`/`slotRefAt` resolve them.

**Drag refactor (principle: player input only pushes PlayerInputEvents):**
the old `dragToEvent` returned machinery `PlayerEvent`s (`equip_item`,
`unequip_item`, `equip_utility_skill`, `swap_utility_skills`,
`unequip_utility_skill`) directly from the input path — a latent replay-
whitelist violation (dead code today, but a violation regardless). Replaced
with `dragToOrchestrator` returning `PlayerInputEvent`s, and new orchestrator
handlers in `handlePlayerInputEvent` that push the machinery as children:

- `player_use_inventory_item { slot, off_hand }` — the "activate" intent.
  Handler resolves item type: weapon → `equip_item` (main/off per flag);
  other gear → `equip_item` (its own slot); skill tome → `learn_skill` if
  not yet learned, else `salvage_item`. The learn-vs-salvage decision reads
  live `player_data.learned_skills` → deterministic across live/replay.
- `player_salvage_inventory_item { slot }` → `salvage_item`.
- `player_equip_to_gear { slot, gear_slot }` → `equip_item` (drag inventory→gear).
- `player_unequip_from_gear { gear_slot, slot }` → `unequip_item` (drag gear→inventory).
- `player_assign_utility_skill { skill_id, slot_index }` → `equip_utility_skill`.
- `player_swap_utility_skills { a, b }` → `swap_utility_skills`.
- `player_clear_utility_skill { slot_index }` → `unequip_utility_skill`.

`isPlayerAction` (replay whitelist) accepts these automatically (they're
`PlayerInputEvent`s). `validatePlayerAction` gained arms
(`validateInventoryScreenAndSlot` / `validateUtilitySlot`) for the replay
anti-cheat seam: screen must be level/hub, slot indices in range. The
item-type→machinery resolution is in the handler (deterministic from state),
so no deeper check there.

**Helpers:** `isSkillLearned` (pub, event_handlers.zig) — extracted from the
tome branch so the learn-vs-salvage decision is testable. `slotRefsEqual`
(input_handlers.zig) — slot identity for click vs drag-off-cancel.

**Tests:** `dragToOrchestrator` mapping (replaces the old `dragToEvent`
test), `resolveItemClick` modifier precedence + double-click, `isSkillLearned`.

### Inventory item tooltips slice (DONE)

Item-specific tooltips on inventory slots, reusing the existing tooltip
framework (`Tooltip`/`spanRow`/`buildTooltip`).

- **`buildItemTooltip(item, learned_skills)`** (`ui.zig`, `pub`):
  - **weapon:** header = name; body = weapon type name + "Damage {n}".
  - **other gear:** header = name; body = item type name + one row per
    stat ("Health {n}", "Defense {n}", "Spell Damage {n}", "Damage {n}",
    "Pickup Radius {n}", "Speed {n}" — only the stats the gear type carries).
  - **skill tome:** header = "{Skill Name} Tome"; body = "Activate to learn
    {Skill Name}" if not learned, "Already learned" if learned. The learned
    check reads `player_data.learned_skills` (passed through from `view()`).
- **Helpers:** `weaponTypeName` / `itemTypeName` for display names. The
  skill name comes from `lookups.getSkillDefinition(tome.skill).name`.
- **Wiring:** the tooltip rides on the `Slot` frame (the blocking surface
  that wins `tooltipAt` — the item `Image` on top is non-blocking, so
  `tooltipAt` falls through to the Slot). Empty slots get no tooltip.
  `buildInventoryPanel` now takes `learned_skills`; `buildMiddlePanels`
  (view.zig) threads it from `current_state.player_data.learned_skills`.
- **Tests:** weapon (name/type/damage), coat (name/type/health/defense),
  tome not-learned (learn prompt), tome already-learned (learned line).

### Drag ghost: content icon + size, not the slot frame (DONE)

The drag ghost showed a 256×256 slot-frame sprite (`ui/item_slot`) under the
cursor instead of the item being dragged, and empty slots were draggable.

**Root cause:** `handleDrag` copied the `Slot` element's `icon_sprite_id`
(the always-present frame background, rendered at `slot_size` = 256) into
`DragState`. The item `Image` on top of the frame is non-blocking (so the
slot stays the single hit-test/tooltip target), so the drag never consulted
it. The `if (slot.icon_sprite_id) |icon|` press guard was always true (the
frame sprite is always present), so empty slots started drags too.

**Fix — resolve content from the ref, not the frame from the element:**
- `slotContentIcon(state, ref) ?[]const u8` (ui.zig) — resolves a `SlotRef`
  to its content icon against the live player entity: inventory/gear/skill-
  bar contents, or the `SkillId` tag for the learned-skill pool. Returns
  null for an empty slot. This is the "what is actually being dragged"
  lookup, distinct from a slot element's frame sprite.
- `slotContentSize(ref) i32` (ui.zig) — render size by domain: inventory +
  gear → `inventory_slot_size` (128); skill-bar + learned-skill →
  `slot_size` (256).
- `skillIconSpriteId(skill_id)` (ui.zig) — comptime-built per-`SkillId`
  table → `"skills/<tag>"`, no allocation. Replaced the `allocPrint` in
  `emitSkillButton` (the only other skill-icon-id site).
- `DragState` gained `size: i32`; `handleDrag` captures the content icon +
  size at press time (left + right press both gated on non-null content, so
  empty slots are no longer draggable/clickable). `view()` renders the ghost
  at `drag.size` instead of hardcoded `slot_size`.

The settled slot-as-hit-test-target design (item Image = decoration on top,
tooltip falls through to the Slot) is preserved — the drag just reads the
right source now. The view stays stateless about content resolution (icon +
size captured at press, same `DragState` shape the view test constructs
directly). Gear/skill-bar panel builders don't emit refs yet, so those arms
of the resolver are reachable but currently unused; covered for when they
land.

**Follow-up — ghost tint + hide dragged item in its slot (DONE):** the drag
ghost now tints with the same player-gradient index 1 the inventory panel
uses for item icons (DESIGN → Entity & UI Coloring — `view()` resolves
`active_theme.player_gradient.colors[1]` and passes it as the ghost's
`.color`); previously the ghost drew with `default_tint` (white / no tint),
off the convention entirely. And the item `Image` is now suppressed on the
drag-source slot (`buildInventoryPanel` takes a `drag_source: ?SlotRef`;
when a slot's index matches an inventory-source drag, the frame + tooltip
still emit but the item icon doesn't, so the item reads as "in flight" —
shown only as the ghost following the pointer). Ref-general: non-inventory
refs return false from the source-match check, so a gear/skill-source drag
won't blank an inventory slot (and gear/skill builders reuse the pattern
when they land).

### Inventory drag: move/swap items (DONE)

Dragging an inventory item onto another inventory slot now reorders the
grid (was a no-op — `dragToOrchestrator` returned null for
inventory→inventory).

- **`swap_inventory_items`** machinery event (PlayerEvent): swaps two
  inventory slots. A swap with an empty target IS a move (item → empty,
  null → source), so one event covers move-to-empty + swap-with-occupied.
  Bounds-checks both indices; no gear side-effects (unlike equip/unequip).
- **`player_swap_inventory_items`** orchestrator (PlayerInputEvent):
  `{ slot_a_index, slot_b_index }`. `dragToOrchestrator` now maps
  inventory→inventory to it; `handlePlayerInputEvent` pushes the machinery
  child; `validatePlayerAction` checks both indices via the existing
  `validateInventoryScreenAndSlot`.
- **Same-slot no-op guard:** `dragToOrchestrator` returns null when
  `from == to` (via `slotRefsEqual`), uniformly for ALL domains — a drop
  back on the source pushes nothing. Also fixes a latent skill_bar→skill_bar
  same-slot case that pushed a no-op `player_swap_utility_skills` with
  `a == b`.
- No sound (no asset for a reorder; deferred to the audio pass).
- `deepCopy`/`deepEqual` + the session-log serializer are comptime-generic
  over the Event union, so the two new simple-struct variants are covered
  automatically — no per-variant wiring.
- Test: `dragToOrchestrator` inventory→inventory now asserts
  `player_swap_inventory_items` (was asserting null); added same-slot
  no-op assertions for inventory + skill_bar.

### Skill-bar drag (utility slots 4-8) (DONE)

Dragging a utility-skill slot on the bottom bar now reorders it (was a
no-op — skill slots emitted `.button` elements with no ref, invisible to
the drag lifecycle). The drag logic for `skill_bar → skill_bar` (swap) +
`skill_bar → learned_skill` (clear) was already wired end-to-end
(`dragToOrchestrator` + orchestrators + handlers + validation); the gap
was purely view/hit-test.

**Dual-role elements — `Button` gained `ref: ?SlotRef`:** skill-bar slots
are buttons (click = activate the skill via the rich `resolveSkillSlotAction`
prepare/confirm/target flow) AND drag sources/drop targets (drag =
reorder/clear). The ref is null for action-only buttons. Only utility slots
4-8 get a ref (`.{ .skill_bar = slot - 4 }`); weapon-skill slots 1-3 are
derived from the equipped weapon, not reorderable, ref null. `emitIconButton`
+ `emitSkillButton` thread the ref through.

**Unified ref lookup — `refAt`:** the drag lifecycle needs to see refs on
both `.slot` (inventory) and `.button` (skill bar) elements. `refAt` walks
all ref-bearing elements via the shared `hitTest` primitive (occlusion-
respecting), backed by `isRefElement`/`refOf` helpers. `handleDrag` uses
`refAt` for press + drop-target + click-resolution (replacing `slotAt`/
`slotRefAt` there). `slotAt`/`slotRefAt` stay for their existing callers.

**Button-click model yields to an in-flight drag:** `main.zig`'s release
block (button-press/release model) now skips `applyAction` when
`ui_state.drag != null`, so `handleDrag` owns the release. Separation:
plain click (not promoted) → `drag` null → button-click fires → skill
activates; drag drop (promoted) → `drag` set → button-click yields →
`handleDrag` resolves the drop (or no-op for drag-back-to-source via the
same-slot guard). The press-side click-down sound still plays on press
(can't know at press time if it'll promote to a drag) — a minor audio
artifact if it does; flagged for the audio pass.

**Sound:** `swap_utility_skills` machinery handler queues `.swap_skill`
(gated `!replaying`) — reuses the existing weapon-swap sfx for skill-slot
reordering. `unequip_utility_skill` (drag-clear) stays silent for now (no
fitting asset; deferred to the audio pass).

`skill_bar → learned_skill` (clear) is wired in `dragToOrchestrator` but
unreachable until `buildSkillsPanel` emits learned-skill refs — lands with
that panel.

### Skill-bar drag polish: empty-slot drop target + button ghost + hide source (DONE)

Three issues with the utility-skill drag (landed last commit):

1. **Empty utility slots weren't drop targets.** The empty-slot branch in
   `emitSkillButton` emitted a plain `.image` (the diamond) with no ref, so
   `refAt` returned null over it → a drop on an empty slot cancelled
   instead of landing. Fixed: empty UTILITY slots now emit a `.slot`
   carrying the ref (icon = `ui/skill_slot_empty`, same diamond render) so
   they're drop targets. A `.slot` isn't a `.button`, so the button-click
   model ignores them (no spurious skill activation on an empty slot), and
   `slotContentIcon` returns null for an empty skill_bar → no drag STARTS
   from an empty slot. Weapon slots (ref null) and the drag source stay
   plain `.image` (inert).

2. **Ghost showed only the icon, not the button background.** The
   skill-bar slot is a composite (`ui/skill_button` bg + skill icon);
   `DragState` stores only the icon. Fixed in `view()`: skill-bar /
   learned-skill drags render the button background (player-gradient
   index 3, matching the bar's `c_border`) under the icon (index 1);
   inventory/gear drags stay icon-only (index 1). No `DragState` change —
   the view picks the domain from `drag.source` and resolves colors from
   `active_theme` (rendering decisions stay in the view, per convention).

3. **Dragged skill was left behind in the source slot.** Same fix as the
   inventory hide: `buildBottomBar` + `emitSkillButton` take a
   `drag_source: ?SlotRef`; when a slot's ref matches the drag source it
   renders empty (diamond) so the skill reads as "in flight" (ghost only).
   The source becomes inert (plain image) — a same-slot drop is already a
   no-op via the guard.

**Refactor — `SlotRef.eql`:** equality moved from the file-private
`slotRefsEqual` (input_handlers.zig) to a `pub fn eql` on `SlotRef` (ui.zig),
so view + builder code can compare refs without a duplicate. `slotRefsEqual`
is now a thin wrapper (kept for the input-handler call sites);
`dragToOrchestrator`'s same-slot guard calls `SlotRef.eql` directly.

**Bugfix — weapon skills vanished during a utility drag:** the
`is_drag_source` check used `src.eql(drag_ref orelse return)`, and the
`orelse return` escaped `emitSkillButton` entirely — so when a utility drag
was active (`drag_source` set) and a weapon slot was emitted (`drag_ref`
null), the function bailed early and slots 1-3 disappeared. A ref-less slot
can never be the drag source, so the check now resolves to `false` when
either side is null (a two-line `blk:` instead of the `orelse return` trap).

### Effective max health from gear (DONE)

`max_health` is now derived from equipped gear, not mutated on every gear
swap. Gear `health_bonus` (coat/gloves/pants/boots) was previously never
applied to max health at all — the health bar, heals, and skill thresholds
all read raw `entity.max_health` (base). Now they read
`getEffectiveMaxHealth()`.

**`Entity.getEffectiveMaxHealth()`** (types.zig): base `max_health` + sum of
equipped `health_bonus` (coat/gloves/pants/boots). No effect modifier field
exists for max health, so gear-only — same shape as the other
`getEffective*` accessors. Derived on every read.

**Invariant — `current_health ≤ getEffectiveMaxHealth()`:** maintained at
the mutation point, not at every read site. `applyGearChangeSideEffects`
(event_handlers.zig) clamps `current_health = @min(current, effectiveMax)`
on every equip/unequip. Equipping a +health piece raises the cap without
healing (current stays, more headroom); unequipping drops current to the
new cap if it was above. Replays deterministically re-clamp (same state →
same clamp), so no separate clamp event is needed.

**Enter at full effective:** entity creation (`parseEntityDefinition`,
`instantiateEditorLevel`) and player level-entry (`build_player_from_data`)
now set `current_health = getEffectiveMaxHealth()` after gear is applied —
covers both player and enemies. Previously `current_health = max_health`
(base), which would have left a player with +health gear entering below
full. `current_health` never persists across levels (no PlayerData field),
so this is the only entry point.

**Read sites swapped to effective:** health bar fill (view.zig) + zero-check;
bottom-bar health globe fill + tooltip "X / Y" (ui.zig); heal capacity
(event_handlers.zig `heal` handler); `stone_form` effect heal amount
(max/5); skill thresholds — `replenish` (50% gate + full-heal amount),
`chop`/`stab` (>50% branches), `slice` (<50% branches), `vampiric_strike`
(full-health gate), `stone_form` (full-health gate).

**Kept on base `.max_health`:** `entityDefinitionsEqual` (loaders.zig —
compares *definitions*, not runtime; base stats are the definition). Test
harness entity literals (no gear, so base == effective).

### Gear panel + getEffectiveSpellDamage (DONE)

The gear middle panel (`buildGearPanel`): equipped weapons (main/off hand)
top-left, then amulet → coat → gloves → pants → boots stacked below, then
combat stats. Shares `inventory_panel_height` with the other middle panels;
width = 3×128 + 4×ui_gap = 448. All slots + item icons 128×128.

**Slots carry `ref = .{ .gear = ... }`** so drag to/from inventory works
out of the box — the orchestrator mapping (`dragToOrchestrator`:
inventory→gear = equip, gear→inventory = unequip) + `slotContentIcon` +
`slotContentSize` were already wired from the earlier drag slice. The item
icon is suppressed on the drag source ("in flight"), same pattern as
inventory/skill-bar. Tooltips ride the slot frame (`buildItemTooltip`),
same fall-through as inventory.

**Stats section:** effective values from the `getEffective*` accessors:
main/off hand damage (`getEffectiveOutgoingDamage(weapon_damage)` — gloves
+ momentum + outgoing_damage modifier), spell damage (`getEffectiveSpellDamage`
— new), max health (`getEffectiveMaxHealth`), defense, pickup radius
(`getEffectivePickupRadius(0)` — base 0 for now, gear-only), speed. Outlined
text labels (font 56), `default_tint` → renderer substitutes theme `lightest`.

**`getEffectiveSpellDamage()`** (types.zig): mirrors
`getEffectiveOutgoingDamage` — amulet `spell_damage` base + gloves
`damage_bonus` + converted momentum + `outgoing_damage` effect modifier.
No amulet = base 0.

**`gearSlotItem(player, gear_slot)`** (ui.zig, pub): the Item in a gear slot
or null — mirrors the handler-side `gearSlotItem`. Used by the panel builder
for item icons + tooltips.

**`gear_panel_width`** raised from placeholder 200 to 448 (3 slots + margins).

**Gear panel width follow-up — measured from stats, no outline (DONE):**
- Removed the black text outline on the gear-panel stat lines (`.outlined =
  true` dropped — the panel background is solid, so the outline isn't
  needed for readability).
- Panel width is now derived from the longest stat line via
  `gearPanelWidth(font_metrics)`, mirroring the tooltip/error-popup
  approach (`measureSpanWidth` → content width + padding). Measures each
  label in `gear_stat_labels` + a 4-digit value gutter (" 9999") at
  `gear_stat_font_size` (56), takes the max, never shrinks below the
  2-slot column width (weapon row), adds `ui_gap` side margins. Width is
  stable as stat values change (measured against the template, not live
  values). Replaced the hardcoded `gear_panel_width = 448` const (deleted).
  `buildMiddlePanels` computes the width before laying out the gear panel
  and passes it as the bounds width.
- Extracted `gear_stat_labels` (shared const array) + `gear_stat_font_size`
  (pub const) so the width function and the builder reference one set of
  labels — no drift.

**Gear panel layout — stats beside gear (DONE):** moved the combat stats
from below the gear stack to a column on the RIGHT, starting flush under
the off-hand weapon (same row as the amulet). Eliminates the empty space
to the right of the gear slots. Gear stack (amulet→boots) stays a single
column under the main-hand; weapon row (main+off) spans the top.
`gearPanelWidth` updated to match the new layout: 2 slots + 2 gaps to the
stats column + stats text + 2 side margins. Panel is wider but shorter,
and the "what you're wearing / what it gives you" split reads cleanly.

### Skills browser panel — display slice (done)

`buildSkillsPanel` (ui.zig): a 9-slice `ui/panel` background at the same
height as inventory/gear (`inventory_panel_height`), width = 4 × `slot_size`
(256) + `ui_gap` (16) on each side = 1056 (`skills_panel_width`, replacing
the stale 800 placeholder). Inside: a 4-wide flush grid of skill slots
filling downward, one per learned skill in `learned_skills` order (parsed
order — no sorting/grouping/search yet). Each slot is a `ui/skill_button`
frame (player-gradient index 3) carrying `ref = .{ .learned_skill = ... }`
+ a non-blocking `skills/<tag>` icon overlay (index 1), mirroring the skill
bar. No `action` — clicking a browser entry doesn't fire a skill (it's not
on the bar); interaction is drag-to-bar, a later slice. The drag source's
icon is suppressed ("in flight"), matching inventory/gear; the frame keeps
its ref so the slot stays a drop target.

Vertical overflow cuts at a full skill's bottom (no half-skills): only
whole rows within the visible grid height (`bounds.height - 2*ui_gap`,
`visible_rows = floor(grid_height / slot_size)`) are emitted, drawn at the
TOP of the grid region (view-relative positions — the scrollbar thumb
conveys position, same pattern as `buildErrorPopup`'s body window). A
scrollbar (`solid_rect` track + proportional thumb) sits in the right
`ui_gap` margin (12px centered in 16px) when the skill count overflows.

`skills_scroll_offset` (rows, not pixels) lives on `UiState` (off the undo
timeline, like the other scrolls). The builder clamps it to
`[0, max_scroll_row]` authoritatively (only the view knows `max_scroll_row`,
which depends on the learned-skill count); the lower bound is also clamped
in the handler so downward-scroll-past-0 doesn't accumulate negative drift.

Wired into `buildMiddlePanels` (view.zig): the `.skills` arm (previously
`continue` — reserved no space) now lays out + builds the panel, vertically
centered like inventory/gear. `skills_panel_width` is the arm's width.

Wheel routing: `handleAnytimeInput` gained `pointer_position` +
`ui_elements` params (the call site in `main.zig` already had both —
`previous_view_state.ui_elements` + `player_input.pointer.position`).
When the pointer is over a skills-browser slot (`skillsSlotUnderPointer` —
a `refAt` hit whose ref is `.learned_skill`; the panel's slots are only
emitted when open, so a hit implies the panel is open), the wheel scrolls
the browser one row per notch instead of zooming the camera. Keyboard
arrows + scrollbar drag are deferred (wheel-only this slice). The redirect
is domain-scoped (only over a `.learned_skill` slot), so it never steals
zoom over inventory/gear panels that are open simultaneously.

Tests (ui.zig): few-skills (no scrollbar, offset clamped to 0), overflow
(scrollbar present, only fully-visible rows emitted, no slot bottom exceeds
the grid bottom, offset clamped to `max_scroll_row`), drag-source icon
suppression with slot ref retained. `skillsSlotUnderPointer` test lives in
input_handlers.zig (avoids a circular import ui.zig → input_handlers.zig).

### Skill bar no-duplicate rule — drag learned skill onto bar (done)

The skill bar never holds duplicate utility skills. Enforced at the
`player_assign_utility_skill` orchestrator handler (event_handlers.zig): when
a learned skill is dragged onto a utility slot, the handler searches
`equipped_utility_skills` for that skill. If found in another slot, it pushes
`swap_utility_skills` (target ↔ existing) instead of `equip_utility_skill`
(the latter would create a second copy). The swap moves the skill to the
target slot and lands the displaced target contents where the skill was —
so "I want this skill in slot 6 instead of slot 4" works as a drag. A drop
onto the slot that already holds the skill is a no-op (no self-swap pushed).
Out-of-range slot_index is a guarded no-op (defensive — added the
`utility_skill_count` guard that the orchestrator previously lacked).

Placement: the check lives in the handler, not `dragToOrchestrator`, because
`dragToOrchestrator` is a pure function of two SlotRefs with no state access;
the handler has the live `equipped_utility_skills`. This keeps the
"no duplicates" policy in the state-aware handler layer and the input mapping
pure. Replay-safe by construction: the check reads GameState, which
reconstructs identically on replay, so the same swap-vs-assign decision is
reproduced (the recorded orchestrator event is unchanged; the pushed
machinery child is verified by `verifyReplayStep`).

Scope: utility slots (indices 0-4 / bar slots 4-8) only. The drag target is
always a utility slot, `swap_utility_skills` only works utility-to-utility,
and shipped content separates weapon skills from learnable skills (the 7
non-weapon skills are the learnable ones), so a learned skill can't duplicate
a weapon skill in practice. Save loading does NOT deduplicate — a
hand-edited / pre-rule save with duplicates is preserved as-is (the rule is
enforced at the drag path, the only way duplicates enter live play).

Tests (handler_tests_gear.zig): fresh assign, duplicate-in-another-slot
swaps (asserts the move + displaced contents + no second copy), drop onto
own slot no-op, swap-to-empty-target, out-of-range no-op.

### Drag a skill off the bar → clear slot (done)

Dragging a utility skill off the bar now nulls its slot. Implemented in
`handleDrag`'s release branch (input_handlers.zig): when a `.skill_bar` drag
ends and no orchestrator resolved (the drop missed any valid target), the
handler pushes `player_clear_utility_skill{slot_index = from_index}` —
unless the release is back on the source slot (self-drop), which stays a
no-op. "Off the bar" covers every non-resolving drop: empty space, a non-ref
surface (panel background), and cross-domain refs (an inventory or gear
slot, where `dragToOrchestrator` returns null). A drop onto the skills menu
or another bar slot still routes through `dragToOrchestrator` (clear / swap
respectively) — the fallback only fires when nothing else resolves.

The carve-out is self-drop: `dragToOrchestrator` already returns null for a
same-slot drop, so the fallback must distinguish "missed everything" from
"released back on the source." The release branch computes `is_self_drop`
(target ref equals source ref) and suppresses the clear in that case —
dropping a skill back on its own slot does nothing, matching the
inventory/gear drag-back-cancel convention.

Item/gear drags off to empty space are unchanged (just cancel — no
destroy-on-missdrop for items; the off-bar clear is skill-bar-specific since
a cleared utility slot is genuinely empty, not a destroyed item).

Tests (handler_tests_gear.zig, drive `handleDrag` with synthetic pointer
ticks against a harness history): drag to empty space clears the slot; drag
onto a cross-domain inventory ref clears the slot; release back on the
source slot is a no-op; drag onto another bar slot swaps (regression — the
fallback doesn't fire when `dragToOrchestrator` resolves).

## Gameplay balance

### Cooldown inheritance on skill/weapon swap (DONE)

Restricts the player to their 5 equipped utility skills at a time by closing
the "rotate fresh skills in, use them all" bypass: equipping a skill or
weapon onto the bar sets the incoming skill cooldowns to `@max(outgoing,
incoming)` — never lower, so a fresh swap can't reset a cooldown that was
ticking on the displaced skill. Settled design + rationale (why the outgoing
cd is PRESERVED, not cleared; why `turn_start` ticking every SkillId makes
preservation self-enforcing; why `swap_hands` is excluded) in DESIGN →
Architecture (Cooldown inheritance on skill/weapon swap).

Two handler sites in `event_handlers.zig`:
- `equip_utility_skill` — snapshots the old slot skill's cd and the incoming
  skill's cd, assigns the slot, sets the incoming cd to `@max(old, incoming)`.
  The outgoing skill's cd stays in `skill_cooldowns` (keyed by SkillId, not
  slot), still ticking down each `turn_start`.
- `equip_item` (main_hand/off_hand) — captures the displaced weapon BEFORE
  the gear-slot swap, then `transferWeaponCooldowns` sets all THREE of the
  new weapon's skill cds to `@max(old weapon's corresponding cd, new
  weapon's corresponding cd)`, paired positionally (skill_1↔skill_1, etc.).
  The hidden skill's cd is set even though only slots 1-2 (main) or slot 3
  (off) are exposed for that hand — it surfaces later if the player
  `swap_hands`. Both old+new cds are snapshotted before any `set` so a
  degenerate SkillId overlap between weapon types can't double-decrement.

No new event or session-log field: cooldowns are entity state mutated
directly in the handler (same shape as `applyGearChangeSideEffects`
clamping health), so it's replay-safe by construction — replay rebuilds
the same `skill_cooldowns` from the same events, no clock or side effect
involved.

Deliberately NOT applied to: `swap_utility_skills` (both skills already on
the bar, cds travel by SkillId — a pure slot swap changes nothing),
`unequip_utility_skill` / `unequip_item` (no incoming skill to inherit),
`swap_hands` (changes which skills are accessible, not which are equipped —
a used skill stays on cd when it reappears in the other hand, no bypass).

Tests (7 new in `handler_tests_gear.zig`, contract-level): utility equip
inherits @max(old, incoming); into empty slot preserves incoming cd;
outgoing skill cd preserved (not cleared); main_hand weapon inherits @max
for all 3 skills (incl. hidden skill_3); off_hand weapon inherits @max for
all 3; weapon into empty hand preserves own cds. Suite now 244 (was 237).

### Autosave backup on new game (DONE)

Starting a new game while an autosave is present no longer silently destroys
the old save. `start_new_game` now pushes a `backup_autosave` MetaEvent
(handler-gated `!replaying`, same side-effect convention as `write_save`)
before the new-player load. When an autosave exists at `saves/autosave.txt`,
the handler copies it to `saves/autosave-YYYYMMDD_HHMMSS.txt` (timestamp
inlined — mirrors `formatSessionTimestamp` / `crash_dump.formatTimestamp`;
inlining avoids a circular import since `input_handlers` imports
`event_handlers`). Best-effort: a backup failure surfaces the error popup
but does NOT abort the new game (the backup is preservation, not a
prerequisite). No autosave present → no-op. The backup is a pure file copy
(read bytes → write at timestamped path), no PlayerData decode/encode, so it
can't corrupt. Settled design in DESIGN → File System & IO (Autosave).

No new session-log machinery: the comptime-generic serializer picks up the
new `backup_autosave` MetaEvent variant automatically; `isPlayerAction`
only whitelists `PlayerInputEvent`, so it's never player-seedable at an
idle point (it's always handler-pushed by `start_new_game`).

Tests (3 new in `handler_tests_autosave.zig`, suite 244 → 247):
- `backup_autosave: copies existing autosave to a timestamped backup` —
  seeds a fake autosave in a temp-dir-backed FileSource, pushes the event,
  scans `saves/` for a matching `autosave-*.txt`, verifies contents match.
- `backup_autosave: no autosave present is a no-op` — no autosave seeded,
  verifies no backup file appears.
- `start_new_game: pushes backup_autosave before the new-player load` —
  inspects the event stack after one `processEvent` to confirm the
  orchestrator pushed `backup_autosave` (the wiring contract).

The disk-touching tests use a temp-dir-backed `FileSource` (reassigned on
the harness after init, since `newHistory` reads `&self.file_source` at
call time and the config arrays are already loaded from embedded data) so
no files leak into the project root — the pattern from `file_source.zig`'s
own tests, applied to handler tests for the first time. This also informs
the AGENTS latent-bug note about the harness writing `saves/autosave.txt`
into cwd: the temp-dir reassignment is the clean fix for any future
disk-touching handler test.

### Autosave backup: transitionScreen stack-clear fix (DONE)

The initial implementation pushed `backup_autosave` at the TOP of the
`start_new_game` handler, before `loadCampaignAndPushHub`. That left it
BELOW `start_hub` on the event stack (LIFO → `start_hub` pops first).
`start_hub`'s handler calls `transitionScreen(.hub)`, which does
`self.event_stack = &.{}` — clearing the entire stack, wiping
`backup_autosave` before it ever ran. The backup was silently never
created.

Fix: push `backup_autosave` AFTER `loadCampaignAndPushHub` so it lands ON
TOP of `start_hub` (LIFO → runs first, before the screen transition clears
the stack). The backup reads the autosave file (independent of GameState),
so running before `start_hub` is semantically correct.

The full-flow test (`start_new_game: backs up existing autosave before
start_hub clears the stack`) catches this: it runs the full orchestrator to
idle against a temp-dir FileSource seeded with a fake autosave, then scans
for a backup file. Verified by reverting the fix (test fails — no backup
found) and re-applying (test passes). DESIGN note updated to record the
push-ordering constraint.

## Clones (clone system)

### Mission UUIDs + clone scaffolding wiring (DONE)

- Added a required `uuid` field to `types.Mission`; the mission Metadata
  whitelist + `loadMission` enforce it (`error.MissingMissionUuid`). All 4
  shipped missions get a v4 uuid; `mission_file_format_version` bumped to 2.
  `MissionCompleteInfo` carries `uuid` through the end_mission → start_hub
  cascade. This is the clone key (DESIGN → Clones) and the foundation for
  custom-mission identity (DESIGN → Custom Missions & Online Services →
  Content identity already called for `mission_uuid` in mission.txt).
- `pickup_items` now adds `computeSalvageValue(item, salvage_definitions)` to
  `Mission.converted_materials_collected` for each item the player
  (entity_index 0) actually places into inventory. Leftovers that don't fit
  don't count; non-player pickups don't accumulate. 3 handler tests.
- `Clone` gained `mission_uuid` (the key); `Clone.name` kept as a display
  label. Save writer/loader emit+parse `mission_uuid` per clone group;
  `player_save_file_format_version` bumped to 2; `data/new_player.txt` +
  `data/autosave.txt` updated. Writer/loader tests updated.
- `save_clone_info` SuperEvent implemented: replace-by-uuid if a clone for
  that mission exists, else append. Payload extended with `mission_uuid`.
- `harvest_clones` SuperEvent added + implemented: per material
  `rate * turns_spent` summed over all existing clones, added to
  `player_data.materials`. Gated on `turns_spent > 0` (div-by-zero guard for
  dev skip-through). Skips clones with `turns_to_complete == 0`.
- `cloneIsStrictlyBetter` pure helper: Pareto-strict per-material rate
  comparison (>= for all, > for at least one). 4 table tests.
- `end_level` last-level `.default` branch wired: computes the clone
  decision, conditionally pushes `harvest_clones` + `save_clone_info` in the
  trailing exit-event block (LIFO: harvest → save run before write_save, and
  before the end_mission pushed earlier). `MissionCompleteInfo` extended with
  `turns_spent`, `converted_materials`, `overwrite_offered` so the hub-side
  overlay + future manual-overwrite orchestrator can reconstruct the save
  payload from the timeline alone (the Mission is gone in the hub).
- DESIGN → Clones (clone system) section added with the full settled design.
- 7 new turnflow tests (cloneIsStrictlyBetter table, save_clone_info
  append/replace/preserve-others, harvest_clones payout/zero-turns-guard/
  zero-turns_to_complete-skip). Session-log round-trip test fixture updated
  for the new save_clone_info payload. Total: 259 tests pass.

Slice 3 (UI: conditional Overwrite Clone button + `player_overwrite_clone`
orchestrator + stats display) deferred — waiting on the user's panel design.

### Mission-complete panel + Overwrite Clone orchestrator (DONE)

- `buildMissionComplete` rewritten: full-screen 9-slice panel with a centered
  header at the top, a left flush-left stats column (Turns Spent, Tiles Moved,
  Skills Used, Damage Dealt, Damage Taken — outlined, player-gradient tinted),
  a right flush-right clone-harvest rewards column (the five material icons at
  `inventory_slot_size`, bottom-aligned, each with an outlined count label
  showing the summed payout from all old clones this run), and Continue +
  Replay Mission (+ Overwrite Clone when `overwrite_offered`) buttons side by
  side at the bottom. Signature now takes `MissionCompleteInfo` + the active
  theme (for material-icon tinting); `view()` call site updated. Medals +
  leaderboards deferred (will become a tabbed view).
- `player_overwrite_clone` PlayerInputEvent added + handled: reads
  `last_completed_mission` and pushes `save_clone_info` from the snapshot
  (uuid/name/turns/converted_materials), replacing the existing clone.
  Whitelisted by `isPlayerAction` automatically (it's a PlayerInputEvent);
  `validatePlayerAction` checks `last_completed_mission != null &&
  overwrite_offered`. Input dispatch + `Action.overwrite_clone` +
  `applyAction` + `releaseSoundForAction` wired.
- 2 new turnflow tests (overwrite replaces / no-op-without-completed-mission).
  270 tests pass.

## Art migration

### Options icon + cooldown overlay (DONE)

- Copied `Assets/Sprites/Options.png` (256×256 RGBA) from the Unity project
  to `assets/ui/icon_options.png` — the sprite id the top-bar options button
  already references (`ui.zig` `buildTopBar`). Was drawing magenta; now real
  art. No code change (the id was already wired).
- Replaced the `ui/cooldown_overlay` placeholder (was drawing magenta) with a
  reuse of `ui/skill_button`: the skill-button frame is drawn over the icon
  tinted `active_theme.darkest` at alpha 128 (50% transparent), so a
  on-cooldown skill reads as dimmed/locked while the remaining-turns number
  sits on top. `Image` UiElement gained an `alpha: u8 = 255` field;
  `drawSprite` gained an `alpha: u8` param (6 existing callers pass 255, the
  `.image` arm reads `image.alpha`). `emitSkillButton` gained a
  `cooldown_overlay_color: Color` param (both call sites pass
  `active_theme.darkest`).
- Remaining placeholder ids: `ui/icon_swap`, `ui/momentum` (no assets exist
  yet — truly missing, not migrated).

### Multi-salvage (shift-drag region) + salvage-tool indicator (DONE)

Shift+left-drag in the inventory panel marks a rectangular region (lightest
outline around the bounding box of the start + end slots); on release with
Shift still held, all occupied slots in the box salvage into materials at
once. Releasing Shift before the mouse cancels. Existing shift+left-click
(single salvage) is preserved — the movement threshold disambiguates click
vs region-drag, same as the plain click-vs-item-drag split.

- **Asset:** `SalvageTool.png` (256×256) copied from the Unity project to
  `assets/ui/salvage_tool.png`.
- **Salvage-tool indicator:** display-only `Image` at the top of the
  inventory panel's material-sidebar column (materials are bottom-aligned,
  so the column top is empty). Tooltip: "Hold Shift to salvage items into
  materials - hold and drag to multi-salvage". `highlighted` (programmatic
  sprite-silhouette outline) while `session.held_modifiers.shift` so the
  player sees the mode is active. Non-blocking (display only, no action —
  a future toggle is possible but not wired).
- **Held modifiers:** `SessionState.held_modifiers` (transient view state,
  replay-safe by construction) copied from `player_input.modifiers` each
  tick in `update()` so `view()` can render modifier-keyed feedback.
- **Region state:** `UiState.salvage_region: ?SalvageRegion` (`start_slot` +
  `end_slot`, order-independent). `end_slot` updates live each frame to the
  inventory slot under the pointer; when the pointer is off-grid the
  previous end slot is kept (release salves the last valid region). Cleared
  on release + on screen transition (whole-UiState reset).
- **Outline:** `SolidRect` UiElement gained `filled: bool = true` +
  `line_width: i32 = 8`; the backend strokes via `drawRectangleLinesEx`
  (same primitive as the world range/radius outlines) when `!filled`. The
  region is one stroked rect around the bounding box (lightest, non-
  blocking).
- **Event:** `player_salvage_inventory_region` PlayerInputEvent (`start_slot`
  + `end_slot: u32`). Handler computes the bounding box from the two corners
  and pushes one `salvage_item` per occupied slot (ArrayList of events,
  single `pushEvents`). One player action → one undo/idle point (all
  children drain before the next idle point). `validatePlayerAction` checks
  both slots in range + level/hub screen. Auto-whitelisted by
  `isPlayerAction` (it's a PlayerInputEvent).
- **Input (`handleDrag`):** `PendingSlotPress` gained `shift_held: bool`.
  Shift+left press on an inventory slot (occupied OR empty — empty slots are
  valid region corners) records a pending press with `shift_held = true`;
  moving past the threshold promotes it to `salvage_region` instead of an
  item drag. Non-shift presses keep the existing occupied-only gate. Release
  with `salvage_region` active: push the orchestrator if Shift is still
  held, else cancel; clear the region either way.
- 2 new gear tests (region salves occupied + skips empty; empty-box no-op).
  272 tests pass.

### Material-icon sites deduplicated (DONE)

The five-material icon set (sprite / color_index / name) was defined in
THREE separate array literals (inventory sidebar, mission-complete harvest
column, new-clone summary row) — the third (`emitMaterialRowHorizontal`)
used its own inline anonymous struct that didn't even share `MaterialEntry`.
Add/reorder a material → three edit sites with no compile-time guarantee
they agree.

Unified to one source of truth: `MaterialKind` (static parts) + a shared
`material_kinds` array + `materialCount(materials, index)` (switch, so a
new kind is a compile error until wired) + `emitMaterialIcons(...)` (one
body, parameterized by `MaterialIconDirection` `.vertical`/`.horizontal`).
All three sites now call `emitMaterialIcons` with their own origin /
icon_size / direction / `Materials` value. `emitMaterialRowHorizontal`
deleted (single caller folded in); `MaterialEntry` deleted. Behavior
unchanged (icon blocking + `{count} {name}` tooltip + non-blocking outlined
count label bottom-right, same as before).

### CloneData mission_uuid missing from save key whitelist (DONE)

Symptom: loading an autosave (Continue at game start) surfaced a spurious
"unknown uuid key in CloneData" popup. Root cause: `save_clone_data_keys`
in parser.zig (the per-section key whitelist for `CloneData`) omitted
`mission_uuid`, so `validateKeys` flagged it even though the writer emits it
and the loader reads it. The `loadPlayerSave` round-trip test passed `warnings:
null`, so it never exercised `validateKeys` and missed the regression when the
clone system landed.

Fix: added `mission_uuid` to `save_clone_data_keys` + a regression test that
runs `validateKeys` against a save with a CloneData section and asserts zero
warnings.

### Clone harvest paid 0 for fractional-rate clones (DONE)

Symptom: a Beginnings clone (wood 11, metal 25, leather 19, cloth 19,
turns_to_complete 49) harvested all-0 on every later mission completion.
Root cause: `computeHarvest` computed `(materials / turns_to_complete) *
turns_spent` — dividing FIRST truncated the per-turn rate to 0 whenever
materials < turns_to_complete (true for every material on that clone: max 25
< 49), so `0 * turns_spent` = 0 forever. The DESIGN "known limitation" note
had rationalized this as accepted integer-division loss, but the arithmetic
order was simply wrong.

Fix: rearrange to `(materials * turns_spent) / turns_to_complete` with a u64
intermediate (overflow guard on the multiply). One truncating divide at the
end instead of truncating the rate up front: a 30-turn Forest completion now
harvests wood `(11*30)/49 = 6`, metal `(25*30)/49 = 15` (was 0 for both).
Loss is now `< 1 per material per harvest` (the fractional remainder) instead
of possibly 100%. Existing tests use cleanly-divisible values (10/5, 6/3) so
their asserted payouts are unchanged; added a regression test mirroring the
real Beginnings clone. Updated the DESIGN note + the `computeHarvest`/
`harvest_clones` handler doc comments.

### Entity inspect panel (DONE)

Right-click an entity in a level to open the enemy-inspect middle panel — a
read-only mirror of the player's skill bar + active effects + gear panel,
tinted with the inspected entity's TEAM gradient. See DESIGN → UI Framework
→ Entity inspect for the settled design.

- `buildEnemyInspectPanel` (ui.zig): 4×2 skill grid (slots 1-4 top, 5-8
  bottom, `slot_size` 256, empty-marker + cooldown overlay + number from
  `collectSkillSlots`) → active effects (`small_icon_size` 128, max 8 cols,
  left→right then down, OMITTED when no effects) → gear mirror (weapons row
  + gear stack + combat-stat column, same layout as `buildGearPanel`).
- **Read-only by construction:** every slot is an `.image`, never `.slot` or
  `.button` — no `SlotRef` (not draggable from/to), no `Action` (not
  clickable). Tooltips still work (`.image` carries `tooltip`).
- **Team-gradient coloring:** player gradient for team 0, enemy gradient
  otherwise, at the same fixed indices the bottom bar + gear panel use.
- `handleRightClickInspect` (input_handlers.zig, levels only): movement-
  threshold disambiguation reusing `drag_threshold_pixels` — a clean right-
  click inspects, a right-drag past the threshold cancels (became a camera
  pan). Coexists with `handleCameraPan` (a no-movement right-press sets both
  the pan anchor + a pending right-click; on release the anchor clears with
  no offset and the pending right-click fires the inspect). Suppressed over
  blocking UI (`blockingElementAt`). Hubs excluded by design.
- `UiState.pending_right_click` + `PendingRightClick` struct for the
  threshold lifecycle.
- `inventory_panel_height` → `middle_panel_height` (rename — the shared
  middle-panel height was misnamed after gear/skills/enemy-inspect adopted
  it).
- `weapon_type_definitions` threaded into `buildMiddlePanels` (the inspect
  panel needs it for `collectSkillSlots`).
- `enemy_inspect_panel_width` set to the real value (4 × `slot_size` + 2 ×
  `ui_gap` = 1056; was a 600 placeholder).
- 4 tests: player entity (read-only `.image`-only, player-gradient tint),
  enemy entity (enemy-gradient tint), cooldown overlay present, active-
  effects 128px icons. All pass (`PASS (exit 0)`, 283 tests total).

**Fixes landed in the same slice (follow-up):**

- **Right-click never opened the panel** (threshold bug). The movement-
  threshold cancellation used `>=`, but `drag_threshold_pixels` is 0, so
  `dx²+dy² >= 0` is always true — `pending_right_click` was cancelled on
  the very next held frame even with zero movement, so by release it was
  always `null`. Fixed with `>` (strict): `0 > 0` is false, so a clean
  no-movement click survives; any actual movement still cancels (became a
  pan). Confirmed via debug-print tracing (press found the entity, release
  saw `pending=null`).
- **Effect icons were magenta boxes.** The bottom-bar active-effects grid
  + the inspect panel used `definition.name` ("Reflect") as the sprite id,
  but the shipped asset is `skills/reflect` (the skill icon), not
  `effects/Reflect`. New `effectIconSpriteId` helper: effects that share a
  tag with a skill (EffectId/SkillId overlap: `reflect`, `stone_form`,
  `that_which_lingers`) resolve to `skills/<tag>`; future non-skill effects
  fall back to the `effect_sprite` path or a magenta placeholder until
  dedicated UI art ships. Applied to both the bottom-bar effects grid and
  the inspect panel. Test updated to expect `skills/reflect`/
  `skills/stone_form`.

### Reflection cleanup: dead input field, threshold comparator, test-values note (DONE)

Mid-session reflection surfaced four issues:

1. **Dead `InGameInput.toggle_entity_inspect` field.** Declared as `?u32` in
   `InGameInput` and read in `handleAnytimeInput`, but never written by
   `translateInput` — the binding layer maps bindings→bool flags, and an
   entity index needs tile-cursor resolution (consumption layer). The
   `handleAnytimeInput` arm was dead code (always null). Removed the field +
   the dead arm; left a note on the future keyboard binding approach
   (`Action.inspect_cursor` bool → `checkAction` → consumed in
   `handleIdleInput` where the tile cursor lives, mirroring the
   `confirm`-folds-into-`tile_clicked` pattern). Right-click remains the only
   inspect path.
2. **Inventory drag `>=` threshold was a latent bug.** With
   `drag_threshold_pixels = 0`, `0 >= 0` is always true, so a left-press
   promoted to a drag on the press frame itself (promotion runs right after
   the press block in the same `handleDrag` call). That made `pending_slot_press`
   always consumed before release, so the `else if (pending_slot_press)` click
   branch (`resolveInventoryClick` → equip/salvage/double-click) was DEAD CODE
   for left clicks — a quick click always became a self-drop no-op drag.
   Click-to-equip never worked; only drag-to-gear did. Fixed by changing `>=`
   to `>` (strict: `0 > 0` is false, so a no-movement click survives as a
   pending press → reaches the click branch; movement > 0 still promotes to
   drag). Same `>` convention as `handleRightClickInspect`. Added comments at
   both sites explaining the comparator choice.
3. **Duplicated rendering recipes in `buildEnemyInspectPanel`** (skill-button
   + gear-slot visuals inlined instead of reusing `emitSkillButton`/
   `emitGearSlot`). Noted in TODO → Tech Debt; deferred (a deliberate cleanup
   slice).
4. **Test values that miss edge cases.** Three bugs this session were
   invisible to passing tests using "nice" values. Noted in TODO → Tech Debt
   as a process reminder; not actionable as a single task.


### Middle-panel headers + close buttons (done)

The four middle panels (inventory, gear, skills, enemy inspect) gained a
header strip at the top: a title `text_label` on the left + a close `button`
flush in the top-right corner. The close button carries the panel's toggle
action (firing it while open closes the panel); enemy inspect needed a new
`Action.toggle_enemy_inspect` (button-only, no keybind) since its close path
also clears `UiState.inspected_entity_index` (the right-click close did both;
the handler in `handleAnytimeInput` mirrors it).

Layout math: middle section = `reference_height − top_bar − bottom_bar` =
1648. The inventory grid (12×128 + 2×16 margin = 1568) is the height
constraint, so the header is sized to the remaining slack: 1648 − 1568 = 80.
`middle_panel_height` grew 1568 → 1648 so panels fill the section exactly
(centering offset is now 0); `middle_panel_header_height = 80`,
`close_button_size = 80` (matches the header), `middle_panel_header_font_size
= 56` (centered in the 80px strip). A shared `emitPanelHeader` helper emits
the title + close button and returns the content bounds (area below the
header) so each builder positions its body within it.

Close-button art (`ui/close_button`) doesn't exist yet → magenta fallback. The
hover outline (`highlighted` → `drawHighlightOutline`) previously no-op'd on a
missing sprite (no silhouette mask to dilate); added a rect-outline fallback
in `drawHighlightOutline` so the hover highlight rings the magenta box with
the theme lightest now, and works for any highlighted missing-sprite button/
image. The view() hover pass (`buttonIndexAt`) already sets `highlighted` on
the topmost button under the pointer, so no input-side change was needed.

Tests: skills-panel element-count assertions updated (header adds a text_label
+ button: 7 → 9 in the few-skills test; grid_top shifted by
`middle_panel_header_height`); enemy-inspect read-only test's `.button` panic
loosened to allow the close button specifically.

### `--replay <path>` CLI flag — session reconstruction from a log file (done)

A native runtime flag that loads a session log from disk and reconstructs the
session from its event history, resuming at the END of the log (the game
continues from wherever the original session was — mid-hub, mid-level, etc.).
The stepping replay-viewer UI (the `.replay_viewer` screen) is a separate
future slice; this is the "resume at end" path.

- **Flag:** `--replay <path>` / `--replay=<path>` in `native.zig`, parsed
  alongside `--data-dir` by a generalized `parseStringFlag(args, allocator,
  name)` (replaces the old `parseDataDirFlag`). The path is cwd-relative or
  absolute (same semantics as `--data-dir`). Web has no argv — a URL-param /
  file-picker path is a future item.
- **Glue:** `main.loadAndReconstructSession(history, path, io)` — raylib-free
  (unit-testable), reads the file via `std.Io.Dir.cwd().readFileAlloc`,
  `parser.parseConfigFile` → `session_log.loadEventLog` →
  `warnIfSessionLogFromDifferentBuild` (advisory stderr, same as the round-trip
  test) → `history.reconstructFromEventLog(events, events.len, processEvent)`.
  Called after `fixupPointers()` and before `game.run`, so crash_dump (installed
  in `run`) captures the reconstructed history.
- **Recoverable errors:** a bad path / corrupt file / unsupported
  `file_format_version` sets a dismissible `pending_error` popup (the existing
  machinery) and returns without reconstructing — the game falls back to the
  seeded main-menu state. Reconstruction divergence (the log doesn't match
  this build's shipped content) still panics per the replay-verification
  policy — that's a real bug, not a bad flag.
- **Pre-existing limitation (not introduced here):** a custom-mission replay
  whose files changed since the original session panics until the
  reconstruction cache is serialized into the session log
  (`file_format_version` 2, deferred with custom-mission sharing). Shipped-
  content replays work today. See DESIGN → File System & IO → Reconstruction
  cache + Determinism & Tiebreaking → Replay VERIFICATION.
- **Tests:** two in main.zig — (1) forward-play a session, serialize, write to
  a temp file, `loadAndReconstructSession` into a fresh history, assert
  `expectEqualDeep` against forward play + idle points match; (2) a missing
  file sets `pending_error` and leaves the history at the seeded main-menu
  state. Temp files under `zig-cache/test-recon-load/` (cleaned up).

### `--replay` / `--data-dir` tilde expansion (done)

Bash doesn't expand `~` after `=` in command arguments, so
`--replay=~/.ziglop/...` arrived with a literal `~` and failed with
FileNotFound. `parseStringFlag` now expands a leading `~/` (or a bare `~`) to
`$HOME` before duping, so both `--replay=~/.ziglop/...` and
`--data-dir=~/.foo` work as users naturally write them. If `$HOME` is unset,
the value is duped unchanged (the read then fails with a clear FileNotFound
rather than a cryptic env error). `std.c.getenv` is native-only (libc via
raylib; native.zig is excluded from the headless test build).

### Reconstruction: clear `waiting` during replay loop (bug fix)

`replayToWithIdleTracking` left `current_state.waiting` set during its replay
loop. A `wait` MetaEvent sets `waiting`, but replay is instant (no real-time
timer drain like the live loop has), so `waiting` persisted through subsequent
events. Snapshots taken at stack-empty moments after any wait event captured
`waiting = true`, breaking the live-loop invariant (idle-point snapshots never
carry `waiting`).

Symptom: after `--replay` reconstruction, undo appeared "swallowed" — most
undo signals did nothing. `restoreTo`'s fast path restored the buggy snapshot
(with `waiting = true`), then `undo`'s mid-drain special case (`waiting !=
null` → restore to the SAME idle point, no progress) spun on the same index,
and `discardFutureTimeline` ate redo history on each spin. The player had to
"wait a bit" between undos for one to occasionally land.

Fix: clear `waiting = null` inside the `replayToWithIdleTracking` loop after
each `apply_event` (before the idle-point check). Replay never honors waits,
so `waiting` should never persist during replay — this is replay's equivalent
of the live loop's wait-timer drain. The post-loop `waiting = null` is kept
for parity with `replayTo` (belt-and-suspenders).

Regression test: "reconstruction with wait events: undo/redo reversible, no
stale waiting" — forward-plays a session through the real game flow (new game
→ hub → walk onto a mission exit → level → walk player toward enemy to aggro
→ skip turn → enemy turns with wait events), serializes, reconstructs, and
asserts: (1) no stale `waiting` after reconstruction, (2) undo advances the
idle index each step (not stuck), (3) redo returns to the start (reversible).
The test uses only player-pushable top-level events so reconstruction's
`isPlayerAction` gate accepts the stream.

### SDF text outline (replaces the drop-shadow ring)

Outlined text (damage/heal numbers via `floating_text`, outlined UI labels)
now renders through a signed-distance-field pipeline: ONE shader-driven
`drawTextEx` per string instead of the 8-direction black drop-shadow ring
(9 draws). Settled design in DESIGN → Platform Seam → SDF text outline;
history of the approach here.

- Why SDF: the atlas texels encode distance-to-glyph-edge instead of
  coverage, so the fragment shader can threshold the field at any width —
  fill at `d >= 0`, outline band at `[-w, 0)`. A mathematically uniform,
  antialiased outline computed per fragment at draw time; no per-string CPU
  raster (the old `imageTextEx` blocker), no GPU readback (the old
  render-target perturbation blocker), no dilation cache. Reference:
  raylib's text_font_sdf example.
- Build-time atlas: runtime SDF generation measured ~1.4s (release) / ~7s
  (debug) at startup — unacceptable, so the atlas is BAKED at build time
  (`tools/sdf_atlas_generator.zig`, a host tool linking raylib as a
  library, calling the same `loadFontData(.sdf)` + `genImageFontAtlas` the
  runtime used → zero metric drift). The blob embeds via the
  `generated_sdf_font` module; runtime parse is microseconds. Startup SDF
  cost amortized to zero (debug init: 8s → 0.25s).
- Encoding: raylib's SDF defaults (±2px range, 4px padding) can't carry an
  8px outline, so the generator compiles with
  `-DFONT_SDF_CHAR_PADDING=22 -DFONT_SDF_PIXEL_DIST_SCALE=6.0` (±21 atlas
  px — covers 8px at the smallest outlined size, 48px drawn from the 128px
  base). Constants kept in lockstep via `@compileError` + blob validation
  (mismatch → warning + ring fallback).
- Two bugs hit during bring-up, both instructive: (1) WHITE BOXES — the
  blob serialized only the alpha channel and the runtime rebuilt a
  GRAYSCALE texture, but raylib swizzles GRAYSCALE to `(r,r,r,1)` on
  desktop GL so the shader's `.a` sample was constant 1.0 → every glyph
  rect rendered solid. Fix: rebuild GRAY_ALPHA (swizzle `(r,r,r,g)`), the
  format `genImageFontAtlas` itself produces. (2) BLACK SCREENSHOT — the
  spike's `takeScreenshot` ran before `endDrawing()` flushed the draw
  batch (SUPPORT_CUSTOM_FRAME_CONTROL moves the flush there), so it read
  an empty framebuffer. Fix: flush → screenshot → swap. Both found via a
  temporary `--sdf-spike` comparison-card harness (removed after the
  visual verdict).
- Fallback: any init failure (blob invalid, upload, shader compile) logs
  once and flips the whole session to the old ring — decided at init, not
  per frame. The ring code lives on in `drawOutlinedText`'s else branch.

### Web black screen: page_allocator is unusable on emscripten (bug fix)

The web build segfaulted at startup (black screen, `Aborted(segmentation
fault)`) inside `loadFont` → stbtt `ttUSHORT` — a pre-existing regression
from the TTF wiring (136 commits untested on web), surfaced by SDF web
verification.

Root cause: `std.heap.page_allocator` on wasm32-emscripten is BrkAllocator,
which grows wasm memory via the RAW `@wasmMemoryGrow` intrinsic. Emscripten
only refreshes its JS heap views + SAFE_HEAP bounds when growth goes
through ITS allocator (emmalloc sbrk → emscripten_resize_heap). Raw growth
leaves the JS side stale: views detach (JS access to wasm memory aborts)
and SAFE_HEAP keeps the old memory size, so wasm access to the freshly
grown region reports a segfault — `loadFont`'s page_allocator dupe put the
TTF bytes in grown memory and the first stbtt read tripped SAFE_HEAP.

Diagnosis without a browser: reproduced under `node ziglop.js` (emcc output
runs there; the debug block ran the font flow before GL/IDBFS init). A raw
`page_allocator.alloc` probe faults on first access; a `@wasmMemoryGrow`
probe detaches the views mid-print. Fixes:

- `src/transient_allocator.zig`: c_allocator on emscripten,
  page_allocator on native, for the three transient-buffer call sites
  (loadFont, content_hash.fileExists, crash_dump.dump). Rule recorded in
  DESIGN → Platform Seam → Allocator rule for emscripten.
- Test-suite self-pollution fixed as collateral: handler tests draining
  `end_level`/`write_save` plant real `saves/autosave.txt` in the project
  root (harness FileSource used cwd), which broke the "missing autosave is
  recoverable" test on every run after the first. The harness now uses a
  scratch dir; `scripts/test.sh` also cleans `saves/` (main.zig tests
  still write there via their own cwd sources — inert, just pollution).

### Gear-tooltip stat comparisons (done)

Inventory/inspect item tooltips now show how each stat compares to the
player's equipped gear: `Damage 4 (+1, 0)` for weapons (first number vs
equipped main hand, second vs off hand), `Defense 1 (-1)` for other gear
(vs the same slot's equipped item). Differences are colored spans —
`+d` full green, `-d` full red, `0` uncolored (theme lightest via the
default-tint substitution in `drawTextLabel`). Raw gear stats only (the
tooltip number itself is raw; `getEffective*` values stay in the stat
sidebars).

- `ui.EquippedGear` (snapshot of an entity's 7 gear fields) +
  `equippedGearFromEntity`; view.zig builds it from `ui.playerEntity`
  (entity 0 in a level, the hub player in a hub — works in both screens).
- `buildItemTooltip` gained `equipped: ?EquippedGear`; null suppresses
  comparisons. Rows built by `statRow` (plain / one baseline / two
  baselines) with `comparisonSpan` per number; empty equipped slot
  compares against 0.
- Call sites: inventory panel (comparisons on), gear panel (null — an
  equipped item compared to itself is all zeros), enemy inspect panel
  (player's gear as baseline, unless inspecting the player itself —
  entity index 0 — where it's null; dropped enemy gear is directly
  usable, so the comparison is actionable there).
- Tests: both-hands weapon row span-by-span (text + colors + `0`
  uncolored), negative/empty-off-hand baselines, per-stat coat
  comparison, empty-slot-vs-zero.

### Combat damage/heal numbers use the stat-feedback colors (done)

Floating damage numbers in combat are now red and heal numbers green
(including 0 values), replacing the previous `active_theme.lightest`
tint. The tooltip comparison colors were renamed
`comparison_positive_color`/`comparison_negative_color` → pub
`ui.positive_color`/`ui.negative_color` since they now serve both
consumers (gear-tooltip comparisons + combat numbers) — one artist-pass
shade change updates both.

### Web save export: browser download + "Export Save" rename (done)

On web, the options-menu save button (renamed "Save Game" → "Export Save" for
clarity) now also triggers a browser download of the just-written timestamped
save — a file on disk without digging through IndexedDB. The autosave stays
IDBFS-only (smooth resume; a download per autosave would be noise), and the
timestamped save still lands in IDBFS as redundancy.

- `file_source.triggerBrowserDownload(allocator, path)`: comptime-gated on
  emscripten (no-op on native, extern never linked outside web builds — same
  pattern as the IDBFS flush). Reads the file back from the emscripten
  in-memory FS via `FS.readFile`, then anchor-clicks a `text/plain` Blob with
  the file's basename; URL revoked + anchor removed after 1s.
- Hook: the `write_save` handler, after a successful non-autosave write. The
  replay gate upstream already covered it ("doesn't spam download prompts on
  web" was written into that comment when the gate landed).
- `persistent_mount_path` ("/ziglop") moved from web.zig to file_source.zig —
  one source of truth shared by the IDBFS mount and the JS absolute paths.
- Design + the browser user-gesture caveat recorded in DESIGN → File System
  & IO → Web save export. Verified: native tests + build + `scripts/web.sh`
  compile + live in a browser — download fires from the options menu and the
  saved file round-trips correctly (user-confirmed).

### Load-save browser + web save import (done)

The main-menu "Load Save" button (previously a no-op stub in
`handleIdleInput` — "needs a file picker") now opens a full-screen modal
browser: `saves/*.txt` listed newest-first (mtime desc, name tiebreak;
autosave included), Back bottom-left, and on web "Import External Save"
bottom-right. Clicking a row loads it through the ordinary `load_save` path
(a failed load → recoverable popup, browser stays open). Barebones by
design — richer UI when the design settles (see TODO).

- `FileSource.listSaveFiles`/`freeSaveFiles` + `SaveFileEntry` (scan lives
  in the input path; `view()` stays file-free — list on
  `SessionState.save_files`, backing-allocator owned, replaced per rescan).
  Rescan on open + every 500ms while open, so externally dropped files
  appear live. The rescan runs AFTER the menu-action switch — a row click's
  index refers to the list its button was rendered from.
- `SlotRef.save_file` (row index) carries the click payload (Action can't);
  main.zig folds it into `IdleInput.clicked_save_row` at release dispatch.
  Save rows are never drag sources (slotContentIcon → null), so the drag
  machinery ignores them — the compiler-guided variant arms document this.
- New event `player_load_save{path}` (PlayerInputEvent → replay whitelist
  stays a tag check; legality arm: main_menu screen only; handler = thin
  push of meta `load_save`). Session-log round-trip test auto-covers it.
- Scroll in whole rows: offset on UiState, clamped in the builder; only the
  visible window emits; scrollbar (error-popup pattern). One wheel notch =
  one row pitch → identical text placement at every offset.
- Web import: `triggerBrowserUpload` (static JS — file picker, sanitized
  filename, writes into saves/ + `.import_marker` at the persistent root).
  Zig polls the marker while the browser is open (idle input — the
  acquisition-step rule from DESIGN → Custom Missions), deletes it, loads
  via the normal path. Native: no button; drop files into the persistent
  saves/ dir by hand (the periodic rescan picks them up).
- Tests: listSaveFiles (empty dir, .txt filter, newest-first with forced
  distinct mtimes — the naive sequential-write version failed on mtime
  ties), buildLoadSavePanel (refs+actions, scroll window/clamp, empty
  state + Back), player_load_save orchestrator stack test. Native + web
  compile verified; NOT yet click-tested live (browser import flow needs a
  user gesture) — playtest `scripts/web.sh emrun` → Load Save → Import.

## Settings screen

### camera_zoom integer migration (u32 25/50/75/100)

`Settings.camera_zoom` migrated from f32 (0.25–1.0, freeform) to u32
hundredths (25–100, a 4-choice 25/50/75/100). Default 50 (= 0.5×). The f32
lives at the render/input seam only: `main.zig` and `input.zig` convert
`@as(f32, @floatFromInt(zoom)) / 100.0` at each read site before threading
into `computeCamera`/`update`/`screenToTile`/`floatWorldPoint`; the
rendering math (`view()` builders, `RenderContext.camera_zoom`) is
unchanged — it still receives an f32. So the on-screen result is identical;
only the storage type moved to u32.

This completes the "Settings is all-integer for scalar fields" property
started by the volume migration: every scalar field is now u32 or bool
except none — `camera_zoom` was the last f32 and it's gone. The 4-choice
values (25/50/75/100) are the only valid ones; the zoom in/out/keyboard
shortcuts step by 25 and clamp to [25, 100], so they land exactly on a
choice. Parse clamps out-of-range user values silently (preferences, not
gameplay).

Constants: `camera_zoom_step`/`min_camera_zoom`/`max_camera_zoom`/
`default_camera_zoom` in input_handlers.zig are u32 (25/25/100/50);
min/max duplicated in loaders.zig (loaders must not import the input
layer — the 4-choice values are the source of truth in DESIGN).

Dead code removed: `input.zig` had a `const zoom = settings.camera_zoom`
that was actually used (at the `screenToTile` call) — not dead, my mistake
in the first pass; restored as the f32 conversion.

DESIGN fix: the stale `types.zig` comment "1.0 = no zoom, <1 = zoomed out,
>1 = zoomed in" is replaced — default is 0.5, 1.0 is zoomed in (the
previous comment described an older freeform-zoom model).

### Slice 3a — toggles + choices + persistence

The settings screen now has 5 working controls (toggles + choices); sliders
land in 3b. Binding mechanism:

- `SettingId` enum (types.zig, one per editable field) + `SettingRef` struct
  `{ id, choice_value: ?u32 }`. Lives in types.zig (alongside `Action`)
  because input.zig needs it but doesn't import ui.zig.
- `Button.setting_ref: ?types.SettingRef` — a new optional field, separate
  from `ref: ?SlotRef` (settings controls aren't draggable, so they don't
  touch the drag machinery).
- `Action.change_setting` — routed through `applyAction` →
  `anytime.options_action` (same path as `.open_settings`, so one handler
  serves both main-menu and in-game contexts).
- `AnytimeInput.clicked_setting: ?types.SettingRef` — folded in main.zig's
  button-release dispatch alongside `applyAction` (the `clicked_save_row`
  pattern: Action can't carry a payload, so the ref rides in a sibling
  field, same-frame only).
- `handleAnytimeInput`'s `options_action` switch: `.change_setting` arm
  reads `anytime.clicked_setting`, mutates `history.settings` directly
  (settings are off the undo timeline — a direct write, like `ui_state`
  toggles — so replay-safe by construction), queues a click sound, and
  calls `markSettingsDirty` for debounced persistence.

Controls (5 rows, centered between header and Back button):
- VSync: toggle button (On/Off).
- Camera Zoom: 4 buttons (25%/50%/75%/100%), active highlighted.
- Player Color: 6 color swatches (player gradient indices 0–5), colored
  fill + invisible hit-test button, active highlighted.
- Auto-skip Attack Step: toggle.
- Auto-target at Cursor: toggle.

`emitSettingButton` helper (like `emitPanelButton` but with `setting_ref` +
`highlighted` instead of just an action). The 5 slider fields (3 volumes +
render_fps_cap + animation_fps) are not shown yet — 3b adds the slider rows.

### Slice 3b — sliders + audio live-apply

New `slider` `UiElement` variant for integer slider controls. The settings
screen now shows all 10 editable fields: 5 sliders (master_volume 0–100,
music_volume 0–100, sound_effects_volume 0–100, render_fps_cap 0–256 with
0 = "Uncapped" label, animation_fps 1–16) + 3 toggles (vsync, auto-skip,
auto-target) + 2 choices (camera_zoom 4-button, player_color_index 6-swatch).

**Slider widget:**
- `Slider` struct (`{ setting_id, min, max, value, screen_position, width,
  height }`) + `slider` variant in `UiElement`. Backend renders a dark track
  + lightest fill (proportional) + lightest thumb square at the fill end.
  The value label is a separate `text_label` emitted by the builder (rebuilt
  each frame from the live settings value, so it tracks the drag in real
  time).
- `PointerInput.held: bool` added (primary button held state — previously
  only `right_held` existed; the slider drag needs left-held).
- `UiState.active_slider: ?SettingId` — the in-progress slider drag. Set on
  left-press over a slider, cleared on left-release.
- `handleSliderDrag` (input_handlers.zig) runs before the options-menu gate
  in `update()` (sliders must work while the settings overlay is open on top
  of the options menu). Left-press over a slider → begin drag + jump to
  pointer; left-held → scrub (find the slider for the active setting in the
  current UI + apply the value from the pointer x); left-release → end drag.
  `sliderValueFromPointer` computes the integer value from the pointer x
  over the track (clamp to [min,max], round to nearest step).
- `applySliderValue` mutates `history.settings` directly (off the undo
  timeline) + `markSettingsDirty` on every drag step (the debounce coalesces
  — the write fires 1s after the last scrub).
- `sliderAt` + `findSlider` hit-test functions in ui.zig (same `hitTest`
  primitive as buttons; `findSlider` is a linear scan by setting_id, used
  during an active drag to find the slider matching `active_slider` in the
  rebuilt UI).

**Audio live-apply (frame diff-and-apply):**
- `SessionState.last_applied_volumes: { master, music, sfx }` — snapshot of
  the 3 volume fields the last time `frame()` applied them.
- `frame()` compares `history.settings` volumes against the snapshot; on
  diff, calls `backend.applyVolumes(settings)` + updates the snapshot. This
  keeps input handlers pure (no backend pointer) — the slider mutates
  `history.settings` directly, and the diff fires next frame (≤16ms latency,
  imperceptible). The first frame after init does one redundant apply
  (snapshot starts at 0,0,0; init already called `applyVolumes`) — harmless.
- VSync does NOT live-apply (`rl.setConfigFlags` may not take effect without
  a window recreate); the VSync row label shows "(change requires restart)"
  and `applyVsync` stays init-only. camera_zoom / render_fps_cap /
  animation_fps are read live each frame by `view()`/`frame()` — no apply
  step needed.

### Web IDBFS boot race — two-phase boot (settings overlay + autosave)

`web.zig:main()` used to run `createSessionSetup` immediately after
`mountPersistentDir()`, which fires `FS.syncfs(true, cb)` — ASYNC (IndexedDB
has no sync API). The callback that populates the in-memory IDBFS layer fires
on the event loop, AFTER `createSessionSetup`'s startup reads. So every web
launch raced: `overlayUserSettings` read `settings.txt` from an empty layer
→ `FileNotFound` → fell back to defaults (the user's persisted settings were
never applied); the autosave `fileExists` check likewise missed. The
`mountPersistentDir` comment even rationalized the race as "correct for a
first run" — but a returning user lost their settings/autosave every launch.

Autosave had a point-fix: a per-frame lazy recheck in `handleIdleInput` on
the main menu (re-stat `saves/autosave.txt` while `!autosave_available`, flip
the flag when syncfs landed → Continue appeared a few frames late). Settings
had no such fix and never worked on web.

Root-cause fix: TWO-PHASE boot. `main()` now does only window + IDBFS mount +
FileSource/Backend construction, then registers `frameCallback` and returns.
The callback polls `window.__ziglopSyncfsLoaded` (set in the `syncfs(true, …)`
callback) each rAF; until set, returns without rendering (a few brief blank
frames — syncfs is typically <50ms; GL clear color shows). On the first rAF
after the flag, it runs `createSessionSetup` + `initAudio` +
`crash_dump.install` + `fixupPointers` ONCE (gated `!booted`), then drives
`game.frame` every call. New extern `emscripten_run_script_int` for the flag
poll. `WebSession` gained `setup: ?SessionSetup`, `file_source`/`io`/
`allocator` pointers, `booted: bool`.

This fixed both reads at the source, so the lazy autosave recheck became
dead code and was DELETED from `input_handlers.handleIdleInput` — Continue
now shows on the first rendered frame (no late-flicker), and settings
overlay applies on web. Native is untouched (sync I/O, no race). The
headless `node zig-out/web/ziglop.js` probe can't exercise this path (needs
`window`/`FS`/rAF), so runtime verification is browser-only.

### Render target resolution (decoupled from 4K design space)

The offscreen `RenderTexture` was 3840×2160 (same as the reference/design
space). Fill rate at 4K dominated the uncapped render cost: a level-visible
scene (dozens of tiles + multi-layer entities + decorations + a full bottom
bar = hundreds of textured quads rasterized into 8.3MP) capped an old
integrated laptop GPU at ~60fps even in a `--release=fast` native build,
while the sparse main menu hit 200fps. Fill rate, not draw-call count, was
the ceiling (raylib already batches same-texture draws; an atlas wouldn't
help).

Fix: DECOUPLE the render target from the design space. All layout/view/UI
math stays in 4K reference space (`types.reference_width/height`, unchanged).
The backend creates its `RenderTexture` at a separate, smaller resolution
(`types.render_width/height`, build options `-Drender-width`/`-Drender-
height`, default 1920×1080) and wraps all draws in `beginMode2D(Camera2D)`
with `zoom = render_scale` (`render_width / reference_width`, comptime).
raylib's 2D camera auto-scales every `drawTexturePro`/`drawRectangleRec`/
`drawTextEx` destination down — NO per-call-site changes in the ~30 draw
sites. `clearBackground` is camera-independent (clears the full target), so
it runs before the camera block.

The blit to the window uses a new `blitTransform()` (render-dims → window,
letterboxed), SEPARATE from the pointer's `viewTransform()` (reference 4K →
window, unchanged). The game still thinks in 4K design space; clicks map
window→4K via `viewTransform`, independent of the render target size. The
on-screen content is identical because render + reference share 16:9 — a
comptime aspect-ratio guard in `types.zig` rejects a mismatched render
aspect with `@compileError` (the camera zoom is uniform; a mismatched
aspect would squish content).

1080p is 4× less fill than 4K → expect a large FPS jump on fill-rate-
limited GPUs. Opt back to 4K with `-Drender-width=3840 -Drender-height=2160`
for crispness on high-DPI displays. The build option lets A/B testing
without code changes. Verified: native build (both 1080p + 4K), tests
(headless, unaffected — no raylib), web compile. Runtime perf needs a
browser/native click-test with a level visible.

**Bilinear on sprite textures.** The initial 1080p build showed hard
nearest-neighbor edges on downscaled sprites: `ensureSpriteLoaded` loaded
each sprite texture with raylib's default point filter, and the render
target itself was bilinear (only the target→window blit was smooth). At a
4K target (the old default) sprites drew 1:1 so the sprite filter didn't
matter; at 1080p with a 0.5× camera zoom, every sprite sampled with hard
edges. Fix: `setTextureFilter(tex, .bilinear)` in `ensureSpriteLoaded` +
`rgbaBufToTexture` (outline masks, also drawn scaled). Smooths the
downscale at no per-frame cost; a no-op visually at a 1:1 render target.

**Premultiplied alpha (the dark-halo fix).** Bilinear downscale then
surfaced dark pixels around sprites' transparent edges (tiles especially).
Cause: PNGs store black RGB at alpha=0 edge pixels; bilinear blends that
black RGB into visible edge pixels → a dark halo. A first attempt (Option B:
bleeding opaque neighbor colors into transparent-edge pixels at load) did
NOT fix it — the halo persists because PNG edges also carry PARTIAL-alpha
pixels with dark RGB (anti-aliased edge coverage), which a bleed can't touch
without changing the visible color. The robust fix is Option A: PREMULTIPLY.

- Every composited texture is premultiplied at load (`r = r*a/255`):
  `ensureSpriteLoaded` (all sprites, normalized to RGBA8 first) and the font
  atlas (GPU readback via `loadImageFromTexture` → premultiply →
  `updateTexture`; also the default-font fallback). Outline masks are binary
  (alpha 0/255) — already effectively premultiplied, no-op. The SDF atlas is
  only sampled by its shader (never blended directly) — untouched.
- The render pass composites under `beginBlendMode(.alpha_premultiply)`
  (ONE, ONE_MINUS_SRC_ALPHA) inside `beginTextureMode`. With premultiplied
texels, bilinear sampling blends in premultiplied space: a transparent
  edge pixel contributes EXACTLY zero color, killing the halo at every
  scale — including partial-alpha anti-aliased edges.
- The SDF outline shaders (GLSL 330 + GLSL ES 100) now output PREMULTIPLIED
  RGB: the straight-alpha `/max(outA, 1/255)` division is gone; the weighted
  sum `fragColor.rgb*fa + outlineColor.rgb*ba*(1-fa)` IS the premultiplied
  RGB.
- Translucent PRIMITIVE draws premultiply their color via the new
  `toPremultipliedColor` helper (RGB scaled by alpha): the tile-highlight
  rectangle fallback (alpha 90), `drawSprite` partial-alpha tints
  (`UiElement.image.alpha`), and the occlusion-inset black tint (a no-op for
  black, kept for the invariant's uniformity). `toRaylibColor` stays for
  opaque (255) tints, where both are identical.
- Invariant: EVERYTHING composited inside the premult-blend pass must be
  premultiplied — straight-alpha textures render too bright under it. New
  texture sources must call `premultiplyAlpha` (or be binary) or they'll
  render washed out.

**Font atlas format bug (fixed same session).** The first premultiply pass
converted the font readback to RGBA8 before `updateTexture` — but raylib
font atlases are `GRAY_ALPHA` (2bpp), and `updateTexture` uploads bytes
assuming the TEXTURE's format. Uploading 4bpp data to a 2bpp texture
reinterpreted the first half of the atlas bytes as gray-alpha pairs → all
panel/button/tooltip text garbled into wrong-sized sliced fragments. Fix:
premultiply in the texture's NATIVE format (gray = gray*alpha/255 for
GRAY_ALPHA; RGBA8 via the shared helper), NO format conversion, then
re-upload. The premult-blend math for a premultiplied gray-alpha glyph is
exactly right: fragment rgb = coverage*tint.rgb, fragment a = coverage, and
(ONE, ONE_MINUS_SRC_ALPHA) composites coverage*tint over the destination —
the straight-alpha result.

**Web font atlas readback bug (fixed same session).** The native-format
readback fix still broke text ON WEB: raylib's GL texture readback
(`loadImageFromTexture` → `glReadPixels` with GL_RGBA) ALWAYS returns an
RGBA image regardless of the texture's GRAY_ALPHA format, so on web the
switch took the RGBA arm and `updateTexture` re-uploaded 4bpp data to the
2bpp texture — same garbling class (blank/garbled glyphs in panels).
Robust fix: stop reading back entirely. `loadFont` now builds the atlas
ENTIRELY ON THE CPU (`loadFontData` → `genImageFontAtlas`, mirroring
LoadFontFromMemory: 95 default ASCII glyphs, padding 4, pack method 0),
premultiplies the GRAY_ALPHA atlas image before upload, and hand-assembles
the `rl.Font` (glyphs/recs/texture all C-allocated by the raylib calls, so
`rl.unloadFont` frees them correctly). Identical code path on every
platform, no GPU round-trip. The default-font fallback is left
straight-alpha (renders too bright under premult blend) — acceptable for
the near-unreachable fallback; its atlas is raylib-owned and can't be
rebuilt on the CPU. The per-glyph sub-image refresh from
LoadFontFromMemory is skipped (only needed for ImageDrawText, unused).

**Dead-code cleanup:** the tile-highlight renderer arm still had the
pre-animation-sheet shape — an `else` rectangle-fill branch for
`source_rectangle == null`, which no producer emits
(`buildHighlightOverlays` always sets it). Deleted; the texture-load-miss
fallback rectangle (defensive degrade for a corrupt/missing asset) stays.

### Show FPS setting + diagnostic overlay

`Settings.show_fps: bool` (default off) + `SettingId.show_fps` toggle row in
the settings panel (row 10, same shape as the other toggle rows; row_count
bumped 10 → 11). Persisted in `data/default_settings.txt` Gameplay section
(`show_fps false`); loader/writer/key-whitelist wired.

The on-screen FPS counter is an EMA over the ACTUAL rendered frame interval:
`frame()`'s render gate already computes `since_last_render` (real-clock µs
between consecutive renders), so inside the gate an EMA (`alpha = 0.1`,
cold-start seeded with the first instant FPS, `since_last_render > 0` guard)
updates `SessionState.fps_smoothed` (f32). `view()` reads `session.fps_smoothed`
+ `settings.show_fps` and emits a non-blocking, outlined `text_label`
(`"FPS <N>"`, rounded) at `(16, 16)` — appended last so it draws on top of
all UI regardless of screen. The clock read stays in `frame()` only (never
in handlers / `view()`), so the replay-purity invariant holds; the field is
off the undoable GameState, so replay-safe by construction. Visible on all
screens (main menu / level / hub / overlays), not just where the top bar is.

## Escape overlay chain

Escape is now a generic "close the topmost overlay" chain
(`handleEscapeKey` in input_handlers.zig, reached via the
`toggle_options_menu` anytime arm) instead of a bare options-menu toggle.
Ordered to mirror the view's z-order: settings (closes alone — the in-game
drill-in steps back to the options menu underneath, replacing the old
close-both cascade) → mission fail (Exit Mission orchestrator) → mission
complete (Continue's `dismiss_mission_complete`) → load-save browser →
credits → options menu (leaves any full-screen overlay beneath it open) →
topmost full-screen overlay (world map / full combat log) → else open the
options menu (level/hub only, no-op at the main menu). Middle panels are
deliberately not in the chain. The error popup never reaches it (the
`pending_error` modal gate consumes `dismiss_error` first). Design + the
layered-close rationale: DESIGN → Input → Escape overlay chain.

Supporting changes:

- **`pushPlayerActionAndDrain`** (input_handlers.zig): extracted the
  push-orchestrator-then-drain loop that was copy-pasted ×7 in the
  `options_action` dispatch (save/restart/exit×2/continue/replay/overwrite);
  the escape chain's mission fail/complete arms reuse it. Carries the
  drain-baseline prose (overlay opened in a previous frame → entry
  `event_stack.len` IS the baseline; drains down to it, leaving a mid-drain
  enemy turn intact; aborts on `load_error`).
- Every escape step that does something queues the `.menu` sound
  (`queueMenuSound`) — the keybind path has no button, so the input-handler
  site queues the feedback sound (the established audio convention).
- `Action.toggle_options_menu` / `AnytimeInput.toggle_options_menu` doc
  comments now record the broader Escape meaning + why it ISN'T renamed:
  the InputBindings full-replace gap would strand existing installs on the
  old action (see TODO → InputBindings per-action migration).
- Tests: `src/input_tests_escape.zig` (6 tests via the harness +
  `handleAnytimeInput` directly): layered settings close, options open on
  level, main-menu no-op + credits/load-save close, topmost full-screen
  overlay close, mission-fail exit (full cascade to the hub, asserting the
  recorded `player_exit_mission`), mission-complete dismiss (recorded on
  the timeline).

## UI rendering

### 9-slice corner aspect fix (square corners on short panels)

`drawNineSlice` clamped the destination corner size PER-AXIS
(`corner_width = min(slice, dest_w/2)`, `corner_height = min(slice, dest_h/2)`),
so any panel shorter than two source slices got corners squashed along y —
e.g. a 160px-tall `ui/panel` button (128px slices) drew 128×80 corners,
visibly wider than tall. Panels at or above 2×slice height (main menu,
1024×256) were exactly at the boundary and looked fine, which is why only
short panels (panel-backed buttons, single-row tooltips) showed it.

Fix: one square corner size `corner = min(slice_w, slice_h, dest_w/2,
dest_h/2)`, with the SOURCE cropped to match in corners + edges, so nothing
is ever drawn non-1:1 in the cross-axis; a short panel gets proportionally
smaller corners instead of squashed ones. Degenerate pieces (zero-size
center on a panel smaller than 2×corner) are skipped by the renderer.

The rect math moved out of the backend into the pure, headless-tested
`ui.nineSlicePieces(texture_width, texture_height, destination) ->
[9]NineSlicePiece{source, destination}` (row-major grid; the bool-logic /
testability convention — the renderer is a thin loop over the pairs). Four
tests: full-size slices on a large panel, the 160px regression case
(square 80×80 corners), tiny-panel clamp, and exact tiling of the
destination + sources within texture bounds. Also corrected the
`NineSlicePanel` doc comment, which claimed edges/center are TILED (they
stretch; tiling is the deferred TODO refinement — only matters once
patterned panel art ships, the current flat-fill art is identical either
way).

### Entity inspect: rename + live-state stat rows

Renamed enemy-inspect → entity-inspect across the codebase — the panel has
always been able to show ANY entity (right-click inspect works on the player
and allied entities too), so the name was wrong. Mechanical rename, no
behavior change: `Action.toggle_enemy_inspect` → `toggle_entity_inspect`
(not a keybinding in any settings file, so no config compatibility concern),
`InGameInput` field, `MiddlePanelId.enemy_inspect` → `entity_inspect`,
`buildEnemyInspectPanel` → `buildEntityInspectPanel`,
`enemy_inspect_panel_width` → `entity_inspect_panel_width`, doc comments +
DESIGN/TODO pointers. DONE.md history entries left as-written (archive
policy).

The inspect panel's combat-stat column now LEADS with the entity's live
combat state: `Current Health` (raw `entity.current_health`) and `Aggro
Range` (raw `entity.aggro_range`), before the shared gear-stat tail. The
player gear panel keeps its own label set untouched — aggro range is a
monster property, meaningless in the player's gear panel. Layout note: the
inspect stat column is now 9 rows (~144px taller); with 9+ active effects
(displayed as 2+ icon rows) the column can extend past the panel bottom —
read-only display, acceptable until the panel grows scrolling.

### Entity inspect: aggro-range world outline

While the entity-inspect panel is open, `view()` emits an `aggro_outline`
tile overlay around the inspected entity — a Chebyshev square of extent
`2*aggro_range + 1` centered on the entity, exactly mirroring the
skill-range/radius outline conventions (theme lightest, unified 8px
thickness, drawn in full — may cross level edges/gaps, geometric not
pathfinding). This is the first producer of the `aggro_outline` overlay
type: the type + renderer arm existed since the outline family landed but
nothing emitted it ("aggro outline still not emitted" in TODO).

New `buildInspectedAggroOutline` (view.zig, called in the level branch
beside `buildPreparedSkillRadiusOutline`), guarded on
`UiState.isMiddlePanelOpen(.entity_inspect)` + `inspected_entity_index`
valid (stale index after entity removal → no outline, no crash). New
`UiState.isMiddlePanelOpen` helper — the read-side companion of
`toggleMiddlePanel` (previously every consumer walked `open_middle_panels`
by hand). Pure over SessionState + GameState reads → replay-safe by
construction. Test: 4 cases (emitted square, panel closed, no inspected
entity, stale index).

### Unified panel-button height constant

The 13 `emitPanelButton` call sites drew their heights from five per-screen
constants that were all 160 except the main-menu one (256):
`menu_button_height`, `error_dismiss_button_height`,
`load_save_button_height`, `credits_button_height`,
`settings_button_height`. Replaced with one shared
`ui.panel_button_height = 160` — a single tuning knob for the whole
panel-button class. Widths stay per-screen (they carry per-screen meaning:
Import label is long, Dismiss is compact, menu buttons are wide heroes).

Visual change: main-menu + mission end-screen buttons shrink 256 → 160
(their 96px font keeps the same 32px top/bottom glyph margin the secondary
buttons have, so the class reads uniform). Everything else is unchanged
(they were already 160).

### Main-menu title ("taplop")

`buildMainMenu` now emits a large "taplop" `text_label` above the button
stack, with the title + buttons centered VERTICALLY TOGETHER as one block
(one `placeCenter` over title gap + title height + stack height, so the
block is screen-centered; the buttons no longer center independently).
Title: measured width via the FontMetrics seam, 256px font (largest in the
UI), theme lightest via the `default_tint` substitution, plain fill (no
outline), non-blocking. Constants: `main_menu_title_font_size` (256) +
`main_menu_title_gap` (96). Caveat: 256 is 2× the 128px font atlas base
size, so the title glyphs upscale (slightly soft); bumping `font_base_size`
in the backend is the fix if it bothers.

### Export Save tooltip (options menu)

The options-menu Export Save button carries a hover tooltip describing
where the export goes: native → "Saves to {persistent dir}/saves/", web →
"Triggers a file download".

- `emitPanelButton` gained a `?Tooltip` param (the panel-button primitive
  had no tooltip path; the tooltip attaches to the hit-test `.button`
  element). All other call sites pass null.
- `buildOptionsMenu` gained a `persistent_dir_path: ?[]const u8` param —
  NULL MEANS WEB by construction: the web entry never sets a path (the
  export is a browser download, no user-visible location), so the tooltip
  branch is a plain null check, fully testable headless (no comptime
  platform gate in ui.zig).
- New `SessionState.persistent_dir_path: ?[]const u8` — set once by the
  NATIVE entry (process-lifetime allocation) from the resolved path
  (--data-dir / $ZIGLOP_DATA / $HOME/.ziglop); null on web. Off the undo
  timeline → replay-safe, like `autosave_available`.
- native.zig: `openPersistentDir` split — path resolution now happens in
  main (the path must outlive the Dir handle), the helper just
  mkdir -p + opens.
- Test: both tooltip variants + other buttons stay tooltip-free.

### InputBindings per-action migration (full-set + inject)

Root cause fixed: a user `settings.txt` with an InputBindings section
REPLACED the default binding set entirely, so any NEW official binding
(skip_level, future editor keys, renames) was invisible to existing
installs — the root cause of skip_level not working until the user file
was deleted. DESIGN always intended per-action overlay; the implementation
never did it.

Fix (settled "full-set + migrate" design): `loadSettings`'s InputBindings
branch, when a base is provided (the `overlayUserSettings` path), appends
the base's bindings for every action the user file doesn't mention. The
user file stays authoritative for the actions it names (rebind = replace,
not additive). Idempotent by construction — the next debounced settings
write (always full-format) persists the injected bindings, so later loads
see those actions as mentioned; no write-on-load. A user file WITHOUT an
InputBindings section keeps the defaults untouched (injection lives in the
bindings branch only).

Rename behavior falls out for free: an old-name binding for a renamed
action parses to nothing (unknown enum value, dropped) → the renamed
action counts as unmentioned → its new default is injected; the next write
drops the stale line. Custom bindings under the old name are NOT migrated
(no alias map — pre-release, one existing install). If a rename ever
touches a heavily customized action, the design notes a one-time
old→new alias step at load (DESIGN → Input → Binding overlay semantics).
This unblocks the `toggle_options_menu` rename.

Tests: `loadSettings injects default bindings for actions the user file
doesn't mention` (user rebinding wins verbatim, unmentioned defaults
injected with modifiers, mentioned action NOT additive) + idempotence
(file mentioning every action → no injection) + no-section case (defaults
untouched). The session_setup `overlayUserSettings` leak-clean test updated
to the new semantics (user undo/redo bindings win; merged set > 2 with the
injected defaults). Test-ownership note: `loadSettings` CONSUMES the base's
bindings (frees on replace, aliases otherwise) — tests free the merged
result only.

## Level editor UI

### Editor bottom bar (tool palette, static shell)

First slice of the editor UI vertical slice: the bottom tool palette
renders on the `.editor` screen. `ui.buildEditorBottomBar` mirrors
`buildBottomBar` (Row of `slot_size` cells, `placeBottomCenter`,
`bottom_bar_height`): fixed tools first (Select, Tile), then three groups
(Enemies, Decorations, Ground Items) — a header label, one cell per
palette type, and an inert "+" add-new cell per group.

Every tool cell = `ui/button_background` tinted player-gradient index 5
(the button convention) + the tool's graphic scaled to fit
(aspect-preserved, centered — `scaleToFit`; non-positive dims fall back
to full cell so missing art still shows magenta at cell size):
- Select: `world/tile_highlight` frame 0 via the new `Image.source_rectangle`
  (the sheet is 1024×256, 4 frames; frame 0 = the leftmost 256×256).
- Tile: `world/tile` tinted world-gradient index 1 (as tiles read in-game).
- Enemy: `entities/{sprite}` tinted enemy-gradient at the template's
  color_index; dims are the universal 512×640 entity frame.
- Decoration: `decorations/{sprite}` tinted world-gradient at the type's
  color_index; dims from `DecorationTypeDef.pixel_dims`.
- Ground item: `itemIconSpriteId` tinted player-gradient index 1 (items
  render as the shared ground bag in-world; the icon is for authoring
  distinction).

Interaction (active-tool state, group collapse, horizontal scroll, click
handling) is deliberately NOT wired — tool cells are tooltip-carrying
inert images, not buttons, since the active-tool model needs a payloadful
input path (`editor_set_tool` + an input-struct field, the
`clicked_save_row` pattern) that belongs to the input slice.

Supporting seams: `ui.Image` gained `source_rectangle: ?Rectangle`
(passed through the raylib backend's `.image` arm into `drawSprite`,
which already supported sources); `view()` gained an `.editor` branch
(editor non-null by invariant); `activeThemeFor` derives the theme from
the ACTIVE level tab's `color_wheel_index` when no live level/hub exists
(playtest/validate keep the instantiated level's theme — the level branch
takes precedence).

Zig 0.16 diagnostic gotcha hit here: `zig ast-check`'s "unused capture"
error points at the LAST capture in a multi-object `for`, not the unused
one — `size` was unused but `group_index` got the caret.

Tests: `scaleToFit` (tall/wide/degenerate) + `buildEditorBottomBar`
(element count, background cells at screen bottom, per-tool sprite +
tint + fitted size, frame-0 source rectangle, headers + "+"
non-blocking). Visual check pending a manual click-through (Editor
button on the main menu, dev build).

### Editor tool palette scrolling (8-cell window)

Editor palette groups clamp to 8 visible type cells
(`editor_palette_max_tools`); groups with more types scroll horizontally —
wheel over the group shifts the window one cell per notch (wheel-up =
earlier tools, matching the skills panel's wheel-up = earlier rows).
State: `UiState.editor_palette_scroll: [3]i32` (per group, off the undo
timeline like `skills_scroll_offset`), clamped in place by the builder
(authoritative) and on write in the wheel handler. The header and "+" cells
stay fixed while the window scrolls.

Wheel routing without refs: tool cells carry no `SlotRef` (inert until
tool selection is wired), so `editorPaletteGroupAt` detects the group
GEOMETRICALLY — on the editor screen the only `ui/button_background`
images in the bottom-bar band are the tool cells, emitted in a
deterministic order (2 fixed tools, then per group `min(size, 8)` type
cells + one "+"). Segmenting that sequence maps the pointer to its group.
The emission order is a contract between `buildEditorBottomBar` and
`editorPaletteGroupAt` (both in ui.zig, adjacent); it will fold into real
element identity when the tool-selection click wiring lands.

Tests: window clamp (12 decorations → offset 99 clamps to 4; 8 cells
emitted; window shows types 4..11 — first absent, last present) +
geometric detection (decoration cell → group 1, fixed tool → null,
above the bar → null).

### Editor palette headers moved above the bar

Group headers no longer occupy a cell in the tool row — they sit in the
strip ABOVE the bottom bar (the same strip the in-game indicators use:
`bar.y - ui_gap - header_font_size`), left-aligned with their group's
first cell. The row is pure cells now (fixed tools, then per group
`min(size, 8)` type cells + "+"), which also simplifies the width math
and the emission-order contract behind `editorPaletteGroupAt` (headers
were never backgrounds, so detection is unchanged).

### Editor palette group collapse + header/plus restyle

Group headers became interactive: a 128-high panel-backed button
(`ui/panel` 9-slice + spriteless Button + centered label) in the strip
above the bar, left-aligned with its group. Clicking toggles
collapse/expand. Payload routing follows the settings-button pattern:
`Action.toggle_editor_palette_group` routes through `options_action`,
the group index rides in `Button.editor_group` → folded in main.zig's
release dispatch into `AnytimeInput.clicked_editor_group` (same-frame
payload), and the handler flips
`UiState.editor_palette_collapsed[group]` (view-side state, off the
undo timeline).

The per-group "+" moved out of the tool row into the header strip:
128x128, rightmost over the group (right-aligned with the group's row
extent, clamped to not overlap the header on narrow groups). Still an
inert tooltip image — add-new needs the edit-verb handlers.

Collapsed groups emit no type cells and reserve a row footprint equal
to their header + "+" extent, so headers never overlap; expanded
groups' footprint is their visible cells. The emission-order contract
behind `editorPaletteGroupAt` updated: bar-band backgrounds are now 2
fixed tools + per EXPANDED group `min(size, 8)` cells (collapsed groups
and the relocated pluses contribute none).

### Editor palette: accordion, flush plus, tool selection + outlines

Four iteration refinements:
- **"+" flush against the header button** — the per-group add-new button
  sits directly adjacent to the header's right edge (was right-aligned
  over the group's row extent), reading as tied to the group.
- **Accordion groups** — expanding a group collapses the others (one
  open group at a time); collapsing just closes the clicked one.
  Handler-side policy in the `.toggle_editor_palette_group` arm.
- **Tile tool icon at half size** — `emitEditorToolCell` gained a
  `graphic_scale` multiplier applied to the fitted icon rect (1.0
  everywhere, 0.5 for the tile tool; the tile art is busy at full cell
  scale).
- **Tool selection + hover/selected outlines** — tool cells became real
  Buttons (background sprite carries action + payload; icon image on
  top, non-blocking). `Action.select_editor_tool` +
  `Button.editor_tool: ?EditorToolId` (new union in types.zig:
  select/tile/entity_type/decoration_type/item_type) → folded into
  `AnytimeInput.clicked_editor_tool` → handler sets
  `UiState.editor_active_tool` (default `.select`). The active tool's
  button is built `highlighted = true` (lightest edge outline — same
  path as the turn-step indicator); hovered tools get the outline from
  the generic hover pass in `view()` (topmost button under the pointer),
  which tool cells now participate in for free.

The active tool is view-side state (`UiState`) for now — it migrates
onto the Editor via the `editor_set_tool` event when the edit-verb
handlers land (TODO). The `editorPaletteGroupAt` emission-order contract
updated again: bar-band `button_background` BUTTONS (was images) are
the tool cells; header buttons are spriteless and contribute nothing.

### Fix: tile tool icon scale was a no-op

`graphic_scale` was applied to the sprite's SOURCE dims before
`scaleToFit` — but scale-to-fit grows or shrinks to fill the cell, so a
uniform pre-scale of a square source changed nothing (256×256 at 0.5 →
scaleToFit scales 128 back up to 256). Fix: fit at native dims, then
shrink the fitted rect by the multiplier and re-center.

### Editor palette: collapsed by default + left-anchored bar

`editor_palette_collapsed` defaults to all-true (the bar starts minimal
— fixed tools + three headers), and the editor bar is flush against the
screen's LEFT edge instead of bottom-centered: the content width changes
as groups expand/collapse, and centering would slide the fixed Select/
Tile tools around. Left-anchoring keeps them stable (same reasoning as
the middle panels stacking from the left edge).

### Editor load: ground items parsed into the item palette + placements

`buildEditorMission` now parses each level's ground-item stacks (the Items
section + layout chars, already parsed by `loadLevel`) into the reference
model — closing the last gap in the editor's mission-load path. Entities +
decorations already deduped into placements; items were dropped (`item_types`
stayed empty, so the Ground Items palette group rendered nothing).

- **Level files author one item per stack** (one layout char per item —
  `loadLevel` allocates each stack with exactly 1 item), matching the
  settled rule that files can't predefine multi-item stacks. Runtime
  multi-item stacks (death drops merging, pickup leftovers) never
  round-trip through the editor. The parse loop walks `stack.items` anyway
  so the model stays total.
- **Dedup**: full-item equality via `deep_copy.deepEqual(types.Item, …)` —
  the shared comparison primitive, already handles the Item union
  (inventory uses it in snapshots), auto-tracks new fields. Palette id via
  new `itemDisplayName` (the item's `name`; skill tomes format "<Skill>
  Tome" via `generated_lookups` — no cycle: the skills chain doesn't import
  loaders).
- **`instantiateEditorLevel`** regroups placements by position into
  `GroundItems` stacks (first-seen position order, items in placement
  order) — co-located placements share a stack (the editor UI can stack
two item types on one tile), and playtests now carry the loot (was
  `.ground_items = &.{}`).
- **Tests**: editor round-trip test extended (beginnings → 2 mission-wide
  item types: Comfortable Boots + Bamboo Spear; level 0 placement at the
  'a' char (3,6); playtest level carries the boots stack); focused
  `instantiateEditorLevel` test pins the co-located regroup (2 placements
  same tile → one 2-item stack, first-seen order).

### Editor viewport scene (view projection)

The `.editor` screen now renders the world scene, not just the tool palette.
`view()` gained an editor world branch (after the level/hub branches — during
playtest/validate the live `current.level` takes precedence) that projects
the ACTIVE `EditorLevel` into the same drawable kinds the in-game view
builds, without ever building a concrete `Level`. See DESIGN → Architecture
→ Level Editor → Editor viewport rendering.

- **`buildEditorScene` (view.zig):** tiles from `level_tiles`; the player
  template standing at `player_start` (the `!` marker — you see the actual
  `player_def` sprite at the spawn); entity placements resolved through
  `entity_types` (shallow struct copies with the placement position, frame-
  arena lifetime); decoration placements resolved through `decoration_types`
  into `buildDecorationPieces` (footprint split + layers); ground-item bags
  (`groundItemsDrawable`) grouped by position with count = co-located
  placements; the level-end flag (`levelEndDrawable`, animated banner) as
  the `=` marker. Health bars are hidden — runtime state, not definition
  state (max health is inspector info).
- **Camera: `playerPosition` editor arm** — in edit mode the camera centers
  on the active level's `player_start` (the editor's "player position"
  analog; level/hub take precedence during playtest). Pan + zoom apply
  unchanged through the existing `computeCamera` seam, so right-drag pan +
  the zoom setting work in the editor for free.
- **`frame()` sprite_bounds editor arm (main.zig):** populates the backend-
  derived opaque-art-bbox map from `player_def` + the entity palette types
  (mission-wide — palette sizes are small, no per-active-level filtering).
  Feeds health-bar-less overlays + the occlusion-inset rects, which now work
  in the editor (entities behind decoration overhang get insets — same
  `buildOcclusionInsets` pass over the unified ground entries).
- **Tests:** view test drives the full `view()` on a synthetic editor state
  (6 tiles, player + enemy placement + decoration + 2 co-located item
  placements + level end) — asserts the camera centers on player_start, the
  exact unified y-sort order of all 5 ground drawables, sprite ids resolved
  through the palette, the co-located item bag grouping (ONE bag, count 2),
  and null health bars.

### Editor camera pan (right-drag)

Right-click-drag pans the editor viewport, same as levels/hubs. The gate in
`handleCameraPan` (input_handlers.zig) was the only exclusion — the editor
screen is now in the allowed set. Everything else already worked through the
shared seams: the pan solver's `player_centered` recompute goes through
`computeCamera` → `playerPosition`'s editor arm (active level's
`player_start`), so the offset is relative to the spawn-centered camera;
pan-start suppression over blocking UI covers the tool palette (cells are
blocking buttons); screen transitions clear the pan via the existing reset.
`handleRightClickInspect` keeps its own level-only gate (no right-click
consumer conflict on the editor screen). DESIGN → Platform Seam → Camera pan
updated.

### Editor top row: options/undo + level tabs

The editor screen gained its top row. Options + undo buttons render in the
SAME locations as levels/hubs — the editor branch of `view()` now calls the
shared `ui.buildTopBar` (the escape chain already opens the options menu on
any non-main-menu screen, and `player_exit_to_menu` gained an editor arm
pushing `close_editor` — it owns the teardown AND the
`transitionScreen(.main_menu)`, so no sibling `open_main_menu` is needed).
`validatePlayerAction` accepts the editor screen for `player_exit_to_menu`.

**Level tabs** (`ui.buildEditorLevelTabs`): one 128-high panel-backed
button per level (`editor_header_strip_height` — the palette group-header
visual class), laid out to the right of the undo button
(`2 * (slot_size + ui_gap)`), vertically centered in the 256-tall top bar
strip. Label = the level's `name` or "Level N" if unnamed; width = measured
label + padding with a square floor (never narrower than 128). The ACTIVE
tab carries `highlighted` (lightest edge outline — the same path as tool
cells).

**Click routing** follows the payload-carrying-button pattern:
`Action.select_editor_level` + `Button.editor_level` → folded in main.zig's
release dispatch into `AnytimeInput.clicked_editor_level` → the
`.select_editor_level` arm pushes **`player_set_editor_level`** (new
PlayerInputEvent orchestrator) via `pushPlayerActionAndDrain` → its handler
pushes `EditorEvent.editor_set_active_level` (the existing inline handler
sets `active_level_index`, range-guarded). Player input never pushes the
EditorEvent directly (the replay whitelist convention — `isPlayerAction`
accepts only PlayerInputEvents, so a directly-pushed editor event would
fail replay seeding). `validatePlayerAction` arm: screen == .editor +
editor non-null + index in range. Tab switches ride the undo timeline (the
Editor is part of GameState) — undo after switching tabs walks back.

Tests: ui (element structure, payloads, active-only highlight, unnamed
fallback, layout position/height), new `src/handler_tests_editor.zig`
(switch + undo revert; out-of-range index no-op).

### Editor viewport input slice 1 — tile paint + tile-tool cursor

The first viewport interaction: clicking with the TILE tool active draws a
floor tile at the clicked level position. One click = one tile (drag-paint
and right-click erase are deliberately deferred; each lands as its own
gesture — see TODO → Level Editor).

**Click semantics** (per user decision, superseding the earlier DESIGN text
that said the editor "blocks" a tile under a footprint — painting now
REPLACES, which saves clicks):
- tile already at the position → no-op (the orchestrator pushes nothing;
  entities / items / the `!` / `=` all sit ON tiles, so they never block).
- decoration footprint covering the position → every covering placement is
  deleted, then the tile is placed.
- nothing there → tile placed.

**Event path** (replay/undo-correct by construction): new PlayerInputEvent
orchestrator `player_paint_editor_tile { position }` — player input never
pushes EditorEvents directly (the replay whitelist convention, same as
`player_set_editor_level`). Its handler computes the effect from state and
pushes `editor_delete_decoration_placement` (per covering placement) +
`editor_set_tile` as children. Two subtleties:
- `pushEvents` is LIFO-drained, so the push array (set_tile first, deletes
  in ascending placement order) processes the deletes in DESCENDING
  placement order — required for index-stable removal (deleting a lower
  index first shifts the pending higher indices).
- All sub-events land between two idle points, so one undo reverts the
  whole click (delete + place) — verified by test.
`validatePlayerAction` arm: structural only (screen == .editor, editor
non-null, ≥1 level); the position is unrestricted because a no-op click
(tile already present) is legal in a recorded session.

**Handlers**: `handleEditorEvent` gained its first real arms —
`editor_set_tile` (add keeps `tileBefore` row-major canonical order,
idempotent both directions; erase arm implemented though no UI pushes it
yet) and `editor_delete_decoration_placement` (order-preserving removal —
placement indices are the identity the move/delete events address). The
remaining edit verbs still `@panic` (fail fast, not silent no-op). New
helper `decorationFootprintCovers` (event_handlers.zig) reuses
`loaders.decorationAnchor` (made pub) — footprint world tile =
`placement.position + (fp − anchor)`, same math as
`validateDecorationFootprint`.

**Input wiring**: `handleIdleInput` gained an editor arm — screen ==
.editor + tile tool + `idle.tile_clicked` → push the orchestrator; it
`return`s unconditionally (no other idle input applies on the editor
screen yet). The press-side world/UI arbitration in `update()` already
consumes clicks over blocking UI, and Enter folds into `tile_clicked` at
the top of `handleIdleInput`, so the keyboard paints at the tile cursor
for free.

**Cursor**: `resolveTileCursor` gained an editor arm
(`resolveEditorTileCursor`, tile tool only — other tools clear the
cursor): mouse-follow to ANY tile position (no tile-membership check —
cleared over blocking UI like levels/hubs), arrow-nudge WITHOUT the
clamp-to-real-tile (painting empty space is the point), null-snap to the
active level's `player_start`. `view()`'s editor world branch emits the
cursor `TileOverlayDrawable` unconditionally (over empty space too — the
affordance that a tile can go there; `buildEditorCursorOverlay`), gated on
the tile tool.

Tests: `handler_tests_editor.zig` +5 (paint sorted-insert; existing-tile
no-op; decoration replace + one-undo reverts both; multi-decoration
coverage with index-stability; erase arm + delete-placement order), view
test (unconditional overlay, non-tile tool suppressed), input test
(mouse-follow, UI occlusion, non-tile tool null, nudge unclamped from
player_start snap).

### Editor bar restyle — collapsed groups flush bottom, square panel pluses

Three visual changes to the editor chrome, all in `ui.zig`:

**Collapsed groups sit flush bottom.** A palette group's header + "+" used
to hover in the strip above the bar even when collapsed — a floating orphan
with nothing to label. Now an EXPANDED group keeps the hovering strip
(header labels the cells below it), while a COLLAPSED (or empty) group's
header + "+" drop to `screen.bottom - editor_header_strip_height` — flush
against the bottom of the screen, in the bar band's x range (which the row
cursor already skips via the group's footprint). This also resolves the
old "collapsed-group visuals UNDECIDED" open question: the flush-bottom
header + "+" ARE the visible content-to-expand cue (no peeking-stack
gadget needed) — the TODO item is gone. The drop condition is the same
`collapsed or size == 0` the footprint math already used, so the header
never overlaps the strip placement of expanded groups.

**"+" cells are square ui/panel cells.** The palette add-new buttons were
`ui/button_background` images; they're now `ui/panel` nine-slice cells
(the level-tab visual class), 128×128, tooltip-carrying, still inert (the
`editor_add_*_type` handlers aren't wired). Shared `emitEditorPlusCell`
helper (panel + centered non-blocking "+" glyph).

**Add-level "+" in the top bar.** `buildEditorLevelTabs` now emits a
square `ui/panel` "+" to the right of the last level tab (top-aligned,
`ui_gap` after), tooltip "Add level", inert — its wiring
(`player_add_editor_level` orchestrator + `editor_add_level` handler +
the default level template) is a TODO item.

Wheel routing (`editorPaletteGroupAt`) is unaffected: it matches
button_background tool cells only — headers are spriteless buttons and
pluses are panels, neither matches (doc comment updated to say so).

Tests: level-tabs test extended (11 elements, + panel square/top-aligned/
tooltip/inert), new collapsed-layout test (expanded header hovers,
collapsed headers + glyphs flush bottom, no type cells from collapsed
groups, 3 square plus panels).

### Editor viewport input slice 2 — enemy-tool placement (occupant replacement)

Clicking with an ENEMY palette tool active places that entity type at the
clicked level position, replacing whatever occupies the tile. Left click
only; the decoration / item tools mirror this orchestrator later.

**Occupant semantics** (all computed from state in the orchestrator
handler, `player_place_editor_entity { type_id, position }`):
- player start (`!`) or level end (`=`) at the position → no-op; the
  singletons are movable, never overwritten.
- covering decoration footprint(s) → deleted (all of them, descending
  index order — same LIFO-drain index-stability reasoning as tile paint).
- no tile there → one is placed (the enemy stands ON a tile).
- co-located ground item → deleted (order-preserving removal).
- existing enemy → RETYPED in place via the new
  `editor_set_entity_placement_type` event (index + position stable —
  nothing referencing the placement shifts; no delete/re-append reordering);
  same type already there → nothing pushed (no do-nothing undo step).
- otherwise → `editor_place_entity` (append).

**One thing per placed tile is now an invariant** (user decision): there
is no path that stacks entities / ground items on one tile, and
`editor_place_entity` ENFORCES it — it panics if the target tile already
carries an entity or item placement (the orchestrator clears occupants
first, so reaching the place occupied is a logic bug — fail-fast, not
silent corruption). Decoration/item placement events get the same guard
when they land; future move/drag handlers must preserve the invariant.
Recorded in DESIGN → Level Editor → Active-tool model (placement tools).

**Why the type_id rides in the event payload:** handlers can't read
`UiState` for event semantics — it lives on SessionState, which replay
doesn't reconstruct (the live session's UI state would leak into replay).
Same reasoning as `player_set_editor_level`. `validatePlayerAction` arm:
screen/editor/levels + type_id in palette range (an out-of-range id would
create a placement the view can't resolve; the live path can't produce
one, a hand-crafted log could).

**Input:** `handleIdleInput`'s editor arm became a tool switch — `.tile`
→ paint, `.entity_type` → place; select/decoration/item are no-ops until
their slices. Enter still folds into `tile_clicked`, but the tile cursor
currently resolves only under the tile tool (cursor-follow for placement
tools is a TODO).

**Handler arms added** to `handleEditorEvent` (rest still panic):
`editor_place_entity` (occupancy-guarded append),
`editor_set_entity_placement_type` (in-place retype),
`editor_delete_item_placement` (order-preserving removal, same shape as
the decoration delete).

Tests: `handler_tests_editor.zig` +7 (empty-tile place; missing-tile
place; decoration + missing tile + one-undo reverts all three; player
start / level end no-ops; retype in place + same-type no-op; ground item
deleted + enemy placed; direct retype + item-delete arms) with a shared
two-type palette fixture (`placementTestEditor`).

### Editor: tile cursor extended to the enemy tools

The enemy placement tools now show the same tile cursor outline as the
tile tool (mouse-follow to any position, unclamped arrow nudge, snap to
player_start, outline drawn over empty space). The gate moved from a
hardcoded `!= .tile` check (duplicated at the resolution site in
input_handlers and the overlay site in view) to one shared predicate,
`EditorToolId.showsTileCursor` (types.zig, beside the union it describes)
— the two gates can't drift, and the next tool joins by editing one
switch arm. Decoration tools are deliberately excluded (they'll want a
footprint-shaped preview, not a single-tile outline); item tools join
when they land; selection has its own affordances.

Tests: the cursor-resolution test gained an enemy-tool mouse-follow case
(after the nudge case — leaving the cursor set mid-test broke the
snap-from-null assertion ordering), and the view overlay test gained an
enemy-tool overlay case.

### Editor viewport input slice 3 — decoration-tool placement + footprint region preview

Clicking with a DECORATION palette tool active places that type with its
ANCHOR tile (bottom-most-then-left-most footprint tile) at the clicked
position — the INVERSE occupant replacement of the enemy tool: a
decoration's footprint tiles are TILE-FREE, so covered tiles are ERASED
rather than placed. Left click only; the item tools mirror the enemy
orchestrator later.

**Occupant semantics** (computed from state in the
`player_place_editor_decoration { type_id, position }` orchestrator):
- '!' / '=' under ANY footprint tile → no-op (checked via the non-anchor
  tiles too — a 2-wide footprint can cover the player start with its
  right tile while the anchor sits free).
- tiles under footprint tiles → erased (`editor_set_tile` is_floor=false),
  along with the entities / ground items standing on them
  (`editor_delete_entity_placement` — arm added — +
  `editor_delete_item_placement`).
- other decorations whose footprints overlap ANY footprint tile → deleted
  (set intersection; checking "existing covers any new tile" is complete).
- then `editor_place_decoration` lands.

**Footprint exclusivity invariant** (extends one-thing-per-tile):
`editor_place_decoration` panics if any covered world tile carries a level
tile, an entity/item placement, or another decoration's footprint at
place time — the orchestrator clears occupants first, so a violation is a
logic bug (fail-fast). DESIGN → Decorations & Footprint → Placement
invariant updated: BOTH directions replace (tile-over-footprint deletes
the decoration; decoration-over-tile erases the tiles) — the old
"blocks placing a decoration onto a tile" text is superseded.

**Footprint region preview.** `region_edge`, a new `TileOverlayType`: one
overlay per BOUNDARY edge of the footprint region (a tile side whose
neighbor is outside the region), carrying which edge via the new
`TileOverlayDrawable.edge` field. The backend strokes each as a thin
filled bar (outline_thickness, offset half a thickness outward to center
on the boundary like the square outlines); bars span the full tile side,
so adjacent segments join seamlessly and ANY region shape — L-shapes,
disjoint footprints — renders as one closed outline. The preview anchors
so the decoration's ANCHOR tile sits at the cursor ("the rest extends
away from the pointer"): since the anchor is bottom-most-then-left-most,
the region always extends up/right of the cursor tile.
`showsTileCursor` renamed `usesTileCursor` (the decoration tool resolves
the tile cursor like the others — it just renders the footprint outline
instead of the single-tile one; the item tools join later).

**Single source of the anchor math:** new
`loaders.decorationFootprintWorldTiles` (sprite-grid footprint → world
tiles with the anchor at a position); `validateDecorationFootprint`
(parse path) and `event_handlers.decorationFootprintCovers` (editor
orchestrators) now delegate to it instead of carrying three inline copies
of the formula. The helper allocates (linear lists, small), and
`validateDecorationFootprint` frees — the loaders tests run under
`testing.allocator` (self-owned loaders) and caught the missing free.
Also `functions.tileListContains` (flat position-list membership — the
editor's tile/placement lists are linear scans), shared by
event_handlers + view instead of two private copies.

Tests: handler +5 (empty-ground place at anchor; '!' / '=' no-op via the
non-anchor footprint tile; covered tiles + entity + item cleared with
one-undo reverting all; overlapping decoration deleted + survivor order;
direct `editor_delete_entity_placement`), view +1 (2-wide footprint → 6
boundary edges, no interior edge between region tiles, left edge at the
anchor tile), cursor-resolution test + decoration-tool case.

### Editor viewport input slice 4 — ground-item-tool placement

The last placement tool: clicking with a GROUND ITEM palette tool active
places that item type at the clicked tile. It is the enemy tool's
orchestrator with the two placement kinds' roles swapped —
`player_place_editor_item { type_id, position }` computes:
- '!' / '=' at the position → no-op (never overwritten).
- covering decoration → deleted; missing tile → placed (the item sits ON
  a tile).
- enemy on the tile → DELETED (`editor_delete_entity_placement`, landed
  with the decoration slice) — an item can't coexist with it.
- existing ground item → RETYPED in place via the new
  `editor_set_item_placement_type` (same identity-stability reasoning as
  the entity retype; same type already there → nothing pushed).
- otherwise → `editor_place_item` (append, carrying the same
  one-thing-per-tile panic guard as `editor_place_entity`: entity or item
  already on the tile = logic bug, fail fast).

Cursor: the single-tile square outline, same as tile/enemy —
`usesTileCursor` now flips to "everything but selection" (`.select` is the
only excluded tool, so the switch lists it instead of the inclusions).
`validatePlayerAction` arm mirrors the others (screen/editor/levels +
type_id in the item palette range). `handleIdleInput`'s tool switch gained
the `.item_type` arm — every placement tool now has left-click input;
what's left for the viewport is selection, right-click erase, and
drag-painting.

Tests: handler +7 (missing tile → tile + item; empty tile → item;
decoration → deleted + tile + item with one-undo revert; '!' / '='
no-ops; enemy deleted + item placed; retype in place + same-type no-op;
direct retype arm), view + item-tool single-tile overlay case,
cursor-resolution + item-tool case.

### Editor viewport input slice 5 — tool-independent right-click delete

The right-click approach changed per user decision: instead of a
per-tool erase gesture, right-click is ONE delete action that works with
any active tool. One clean click deletes ONE thing at the pressed tile —
priority (state-computed in the `player_delete_editor_at { position }`
orchestrator):
- enemy / ground-item occupant → deleted (the tile survives — progressive
  delete: the occupant goes first, the tile on the next click);
- covering decoration → deleted (ALL covering placements, consistent with
  every other editor flow; overlapping footprints are a degenerate
  hand-authored case);
- bare tile → erased (`editor_set_tile` is_floor=false);
- '!' / '=' → no-op — checked FIRST, before the bare-tile erase, because
  they sit ON tiles (a naive tile-erase would delete the tile under the
  player spawn);
- empty ground → no-op.

**Gesture machinery:** `PendingRightClick` generalized from a flat struct
into a tagged union — `inspect` (levels, the entity right-click) and
`editor_delete` (editor screen, carrying the pressed world tile + press
position). One right-press gesture state, two owners by kind: each
handler touches only its own kind (`clearPendingRightClick` helper), so
they can't fight over the shared field across screens. The new
`handleRightClickEditorDelete` mirrors the inspect lifecycle: press over
non-blocking UI records the pending; movement beyond
`drag_threshold_pixels` cancels it (the press became a camera pan — the
editor's right-drag pan coexists unchanged); a clean release pushes the
event. The pressed tile is recorded at PRESS — a clean click acts on what
was under the pointer when the button went down, not where sub-threshold
drift left it at release. Called from `update()` right after the inspect
handler.

`validatePlayerAction` arm: screen/editor/levels; position unrestricted
(no-op clicks are legal in a recording). One delete = one undo step by
construction. This also resolves the old TODO open question "right-click
gesture split" — the disambiguation landed with the slice.

Tests: handler +2 covering all five rules (occupant-before-tile
progression on one fixture; '!' / '=' tile survival; decoration delete),
input +1 for the gesture lifecycle (clean click pushes targeting the
pressed tile; drag-cancel; blocking-UI press no-ops).

### Editor viewport input slice 6 — select tool: plain-click selection + white outlines

The select tool's left click. `types.Selectable` (the union sketched in
DESIGN → Level Editor → Selection model) is now real: tile /
entity_placement / decoration_placement / ground_item_placement /
player_start / level_end, with u32 placement indices.

**Selection state lives on UiState** (`editor_selection`), not GameState:
selecting is a UI affordance, not a mission edit — off the undo timeline,
replay-safe by construction (same class as the active tool), mutated
directly by the input handlers via the session's backing allocator. No
new events (so no validatePlayerAction arms either). Cleared when the
active tool CHANGES (re-selecting the active tool keeps it — std.meta.eql
tool comparison, unions don't support ==), and by the existing
screen/world-transition UiState reset (editor close, playtest
enter/exit).

**Click resolution** (`selectAtEditorPosition`, input_handlers): the '!'
/ '=' singletons are selectable (selection is the only way they'll ever
be moved — there is no placing/deleting them); a covering decoration
selects the FIRST covering placement (exactly what the hover preview
shows — preview ≡ click; the delete-all-covering convention is
deliberately NOT used here so the preview never lies); otherwise the
click selects the tile INCLUDING the entity / ground item standing on it
(one click adds up to three Selectables). Already-selected entries are
skipped (a full no-op when nothing new); empty ground selects nothing
(there is no tile to select — the single-tile hover outline is the
cursor, not a promise).

**Rendering:** the selection draws WHITE outlines (explicit pure white,
not theme lightest) around every selected region — a single-tile outline
per tile / singleton / placement position (a tile + its occupant outline
the same rect; opaque redraw is invisible, no dedup needed) and a
continuous `region_edge` region outline per decoration placement. The
edge-emission loop was extracted into `appendRegionOutline`, now shared
by the decoration preview, the select hover preview, and the selection
overlay. Stale entries (a selected placement later right-click-deleted —
indices shift) are bounds-checked and skipped.

**Cursor:** every tool now resolves the tile cursor — the
`EditorToolId.usesTileCursor` predicate is deleted (it had excluded
selection; with selection joining, it was `return true`). The select
tool's outline previews the click: a covering decoration's footprint
region, else the single tile.

**Shared footprint check:** `decorationFootprintCovers` moved from
event_handlers (private) to loaders (pub) — the select click resolution
and the hover preview (input_handlers + view) need it alongside the
orchestrators.

Tests: input +2 (click resolution covering all cases incl. no-ops +
tool-change clearing / same-tool retention), view +2 (select hover
preview: footprint region over a decoration, single tile elsewhere;
selection overlay: 4 white tile outlines + 6 region edges on a
kitchen-sink selection), and the two existing cursor tests updated for
select now resolving the cursor.

### Fix: editor selection outlines rendered black (Color channels are u8)

The selection overlay's first cut asked for "white" outlines but passed
`types.Color{ .r = 1, .g = 1, .b = 1 }` — and `types.Color` channels are
u8 0-255, not floats 0-1, so that is 1/255 ≈ BLACK. The test didn't catch
it because it asserted the literal `{1,1,1}` (tautological against the
constant) instead of a theme-derived value. Per user preference the
selection now uses the active theme's LIGHTEST — the same color as every
other world outline (cursor, range/radius, region previews) instead of a
separate white. The test derives the expected color via `activeThemeFor`
(the real harness theme), so a constant-vs-theme drift fails there again.

### Editor selection: click toggles; deletes prune + remap the selection

Two selection-behavior refinements per user decision:

**Click is a TOGGLE, not an add.** A click resolves its GROUP (the tile
INCLUDING the entity / ground item standing on it, the covering
decoration, or the '!' / '=' singleton — same resolution as before) and
toggles it: anything from the group already selected → every present
entry is removed (clicking a selected tile deselects the tile AND its
occupant, per the group model); nothing present → the whole group is
added. `selectAtEditorPosition` restructured around a small fixed group
buffer + `selectionContains` / `removeSelectable` (orderedRemove)
helpers; `addSelectable` is gone.

**Deletes keep the selection consistent.** The placement-removal
`handleEditorEvent` arms (`editor_delete_entity_placement` /
`_decoration_` / `_item_`, and `editor_set_tile`'s erase direction) now
maintain the selection via `reconcileSelectionAfterPlacementDelete`: the
deleted entry is pruned and the selected indices ABOVE it are
DECREMENTED — this is the important half, since a removal shifts later
placements down and skipping-only-stale would leave surviving entries
pointing at the WRONG placements (a real latent bug from slice 6: select
entity 3, delete entity 1 → entry 3 survived the bounds check and
outlined whatever placement took its place). A tile erased by ANY flow
leaves the selection with it (`selectionRemoveTile`) — covers the
right-click delete AND the decoration placement's cascaded footprint
erases. `handleEditorEvent` takes the selection as a parameter
(`processEvent` passes the session's UiState list) so every current and
future mutation path maintains it uniformly — pruning runs unconditionally
(replaying a delete via redo prunes again, which is the correct
semantics; full-session replay has an empty selection anyway).

Tests: the click test rewritten for toggles (group on/off/on, singleton
toggle, decoration toggle, empty ground), handler +3 (prune + remap
keeps entries pointing at the same placements; selected tile + decoration
prunes; the decoration-placement cascade erases a selected tile).

### Editor no-op click gate + click planners (DONE)

**The problem.** Every editor click fired its `player_input_event`
orchestrator unconditionally; when the click would change nothing (tile
paint on an existing tile, place on the '!' / '=', same-type retype with
nothing to clear, right-click delete on empty ground) the handler returned
early but the event was already recorded — `current_event_index` advanced
and `maybeRecordIdlePoint` marked a new idle point whose before/after
states were identical. Undo consumed a step and nothing visibly changed
(polluted undo history); a future replay viewer would step through dead
points too.

**The fix: pure per-tool planners shared by handler + input.** Each click's
sub-event list is computed by a pure `pub fn planEditor*Actions` in
event_handlers.zig (`TilePaint` / `EntityPlacement` /
`DecorationPlacement` / `ItemPlacement` / `Delete` — plus the private
`activeEditorLevel` guard helper and `singleEditorDeletePlan` for the
delete cascade's early-return arms). The five `processEvent` handler arms
became thin wrappers (`pushEvents(plan)` — `pushEvents` no-ops an empty
plan, the defensive path for crafted or pre-change logs that contain a
redundant click). The input layer (`handleIdleInput`'s editor branch +
`handleRightClickEditorDelete`'s release arm) computes the same plan and
fires the player action only when it is nonempty — a no-op click never
reaches the event log. Single source of truth on both sides (no
duplicated no-op conditions to drift); no TOCTOU because idle input and
the drain run against unmutated state in the same frame. This is the same
convention as `isPlayerMoveLegal` (AGENTS → Testing discipline: the
decision logic lives in one directly-testable pure helper; fire site and
handler are thin over it). Design: DESIGN → Level Editor → Active-tool
model ("No-op clicks never fire").

**Exact-duplicate decoration placements no-op.** Placing a decoration
where an identical placement (same type + same anchor → identical
footprint) already exists previously pushed `editor_place_decoration` —
an invisible duplicate stacking into the saved mission (right-click
delete removes all covering duplicates at once, so it self-healed
visually, but the file carried the dup). The decoration planner now
treats the duplicate as already satisfying the placement: no place, and
the duplicate is excluded from the overlap deletes; other overlapping
decorations still get deleted, so a duplicate-plus-overlap click cleans
up the overlap without churning the duplicate (net final state identical
to the old delete-and-replace, minus the redundant events).

Tests: planner unit tests pinning every no-op condition at the plan level
(paint-on-existing-tile, entity/item on '!' / '=', same-type occupant +
present tile, same-type occupant + missing tile still placing the tile,
delete on '!' / '=' / empty ground, decoration exact-duplicate empty +
different-type-same-anchor replacing); handler tests for the duplicate
rule (pure no-op; duplicate kept + overlapping other deleted); input-gate
tests (a no-op tool click and a no-op right-click push nothing, positive
controls fire). The pre-existing
`handleRightClickEditorDelete: clean click fires…` gesture test was
retargeted — it pressed on the player-start tile of an empty level, which
is now (correctly) a no-op; its "fires" case now targets a bare tile and
processes both the action and its sub-event. All 365 tests pass.

### Tile-cursor gap crossing (DONE)

**The behavior.** In levels/hubs, arrow-key cursor nudging used to stop at
gaps: a nudge onto empty space left the cursor where it was, so disconnected
tile groups were unreachable by keyboard. Now the nudge crosses the gap —
the cursor jumps to the FIRST tile on the ray in the nudge direction
(`functions.nearestTileAlongDirection`: a tile qualifies when its offset
from the origin is the same positive integer multiple of the direction on
both axes; smallest multiple wins; single O(n) pass over the tile list).
Diagonals follow the combined diagonal ray (per the design discussion —
a staircase edge where the pure diagonal finds nothing simply doesn't move,
the player presses a single-axis key instead; per-axis fallback was
rejected as surprising L-shaped teleports). No tile in the direction at all
→ the cursor stays. The editor cursor is unchanged — it always moves one
step with no clamp (acting over empty space is the point there).

Implementation: `nearestTileAlongDirection` (functions.zig, pure +
unit-tested), `resolveTileCursor`'s level/hub nudge arm (fast path: the
nudged position is a tile → move there; else ray search from the
PRE-nudge origin). Tests: helper unit tests (orthogonal gap jump,
diagonal same-multiple alignment, behind-origin and origin-tile exclusion,
zero direction) + a `resolveTileCursor` behavior test (cross right over a
gap, stay at the edge, cross back left). DESIGN → Input's tile-cursor
bullet carries the rule.

### Editor tool pointer onto the Editor (selection-undoability slice 1)

**Why.** The select tool's selection is about to become undoable
GameState (so group-move events can depend on it replay-safely and
undo/redo shows what was selected at the time). The active tool pointer
was the same kind of state living the same wrong place: on `UiState`
(off the undo timeline), so a tool switch's selection clear could not ride
the timeline either. Migrating the tool FIRST keeps every intermediate
commit coherent — once the selection lands on GameState, the clear rides
the `editor_set_tool` event from day one instead of being a temporary
off-timeline write. Design discussion (granular select/deselect events,
per-click undo steps accepted): session log, this entry's siblings.

**What landed.** `Editor.active_tool: EditorToolId` (GameState, deepCopy-
snapshot territory) set only via the `player_set_editor_tool` →
`editor_set_tool` event pair; `UiState.editor_active_tool` deleted.
`validatePlayerAction` arm (screen + editor + palette-index range; the
handler defensively ignores an out-of-range tool the same way
`editor_set_active_level` ignores a bad index). The tool-cell click in
`handleAnytimeInput` reroutes from a direct UiState write to
`pushPlayerActionAndDrain` (level-tab pattern). Invariant now stated in
events.zig + types.zig: selection nonempty ⇔ active tool is select — the
handler clears the UiState selection (still UiState this slice) inside
the same event, so a tool switch + its clear revert together on undo.
Session-log round-trip: the `EditorToolId` nested tagged-union payload
(void + u32 tags) is covered in session_log.zig's shapes test with a
write → parse → load → expectEqualDeep tail (loaded log in an arena — no
per-event free helper exists; leak-checked loading is the pending
exhaustive round-trip TODO).

Intermediate state (one slice only): the selection is still on UiState,
so undo restores the TOOL but not a cleared selection. The next slice
(selection onto the Editor) closes this — its undo test asserts the
selection restoration.

Tests: the tool-change test in input_handlers.zig now drives the full
input → event → handler path and asserts undo reverts the tool; the
planner/cursor/view tests read `editor.?.active_tool`. All tests pass.

### Editor selection onto the Editor (selection-undoability slice 2)

**Why.** The upcoming selection operations (group move / delete) have
handlers whose effect depends on the selection — so the selection must be
reconstructable from the event log, and undo/redo across edits should show
what was selected at that time. Off-timeline (UiState), a group-move event
would either break replay or need a selection snapshot embedded in every
selection-dependent payload. Design decisions from the session discussion:
granular `editor_select`/`editor_deselect` events (log readability; a
group click / future marquee batch shares one idle point, so it is one
undoable step), per-click undo granularity ACCEPTED (undoing a misclicked
selection is a feature), and the `Selectable` union rides in the event
payload rather than 12 per-kind variants (kind is pure addressing here —
identical semantics — unlike the placement family where kind picks
different invariants).

**What landed.** `Editor.selection: []const Selectable` (GameState),
mutated only via events; `UiState.editor_selection` deleted — event
handlers no longer reach into UiState at all (`handleEditorEvent` dropped
its selection parameter). `player_toggle_editor_selection { position }`
carries just the click (matching `player_delete_editor_at`); the handler
is thin over `planEditorSelectionActions` (the group-resolution + toggle
logic extracted from the old direct-write `selectAtEditorPosition` — the
planner is the single source for the input no-op gate and the handler).
The planner pushes the group REVERSED (the event stack is LIFO — same
reason the delete planner pushes high-before-low) so entries process and
log in group order: tile, entity, item.

Consistency now rides the timeline atomically: the placement-delete arms
prune + remap `editor.selection` within the same event (rebuilt slices,
never in-place mutation, so deepCopy snapshots stay sound — the old
`reconcileSelectionAfterPlacementDelete`/`selectionRemoveTile` became
pure slice-returning helpers); a tile erased by any flow prunes its entry;
`editor_set_tool` to a non-select tool and `editor_set_active_level`
clear the selection inside their own events. Two latent-bug fixes that the
migration exposed: level-tab switches previously LEFT the selection
(indices are active-level-relative — stale indices pointed into the new
level's lists); the delete-arm reconcile previously ran regardless of
`delete.level_index` (a non-active-level delete would have remapped the
wrong indices — now gated on `level_index == active_level_index`).

`validatePlayerAction` arm: screen + editor + levels + the select tool
active; the handler additionally bounds-checks placement indices and
no-ops on a non-select tool or duplicate entry (defensive paths for
crafted machinery events; a redundant player toggle replays gracefully —
empty plan, nothing pushed). Session-log shapes test extended: Selectable
payloads in all three shapes (struct tag `tile 3 4`, index tag, void tag)
write + parse + load round-trip.

Tests: the toggle test drives the REAL input path (`handleIdleInput` →
runToIdle) and asserts undo/redo restores the selection; the tool-change
test now asserts one undo reverts the switch together with its selection
clear (the slice-1 intermediate state is closed). Test-harness gotchas
hit along the way: `runToIdle` records idle points unconditionally, so a
no-op click must skip the drain (a duplicate idle point at the same index
makes undo appear to no-op); off-timeline test seeding must happen BEFORE
the first `runToIdle` or the earlier snapshot reverts it on undo. All 381
tests pass.

### Editor select-tool marquee (shift+left-drag region add)

**Why.** Multi-select by clicking one group at a time doesn't scale to the
selection operations (group move/delete) — the marquee is the bulk path.
Built on the slice-2 selection events: the marquee is just a batch of
`editor_select` additions, so it inherited undo/redo, replay, and the
no-op discipline with zero new state on the timeline.

**Semantics (settled in the session discussion).** A press with Shift held
starts the gesture (Shift acquired mid-drag does not — inventory salvage
precedent); the drag threshold promotes it (rectangle renders, end corner
tracks the pointer live, keeping the LAST VALID corner while over blocking
UI — release over a panel fires the last valid region); release with Shift
STILL held adds everything inside the inclusive rectangle, SKIPPING
already-selected entries (an add, never a remove). Shift released
mid-drag cancels. Decoration membership is FOOTPRINT-INTERSECTION (any
footprint tile inside grabs it — matching the click hit-testing: "if you
can click it, you can marquee it"; chosen over the anchor rule). An
UNPROMOTED release (no drag) acts as a plain click: the toggle the press
would have fired had Shift not been held — fired from the gesture handler
with the same no-op gate, since `handleIdleInput`'s select arm defers to
the gesture while Shift is held (a shift press never toggles). This gives
the TODO's "shift-click add-vs-replace" behavior as a degenerate case:
plain click toggles, shift+click adds, shift+drag adds a region.

**What landed.** `UiState.editor_marquee` (`EditorMarquee`: corners +
press px + promoted flag — off the timeline, a view affordance exactly
like the inventory `salvage_region`); `handleEditorMarquee` (anytime
handler in input_handlers, called in `update()` beside
`handleRightClickEditorDelete`); `player_select_editor_region {
start_position, end_position }` → `planEditorRegionSelectActions` (pure
planner: tiles/entities/items by position, decorations by footprint
intersection via `decorationFootprintWorldTiles`, the '!' / '=' by their
tile; deterministic order — tiles, entities, items, decorations,
singletons, each in stored order — reversed before returning per the LIFO
convention so processing + log read in plan order); the
`validatePlayerAction` arm (same structural checks as the toggle);
`buildEditorMarqueeOverlay` (lightest region outline via the shared
`appendRegionOutline`, rendered only once promoted).

No-op gates at every layer: an empty or all-already-selected region never
fires the player action (no dead undo step); the handler's empty plan
replays a crafted redundant event gracefully (idempotent — the
editor_select arm skips duplicates); the unpromoted-release toggle uses
the click planner's gate (empty ground never fires).

Tests: planner test (region membership incl. the anchor-outside/
footprint-pokes-in decoration, skip-present, empty region; asserts the
REVERSED slice per the LIFO convention), integration test (one undo step
reverts the whole batch; the redundant event is idempotent), gesture test
(promotion threshold incl. a sub-threshold probe, live end tracking,
release-fires, unpromoted-release-toggles, shift-release-cancels,
no-shift-press-never-starts). Test-writing gotcha: a "sub-threshold"
probe point must move along ONE axis from the press — a diagonal probe
tile silently exceeds the threshold and promotes. All 384 tests pass.

### Editor selection delete (Delete key)

**Why.** The first of the selection OPERATIONS — the reason selection was
moved onto the undo timeline. The handler reads `editor.selection` from
reconstructable state with NO payload on the orchestrator event
(`player_delete_editor_selection: void`), which is the payoff of the
slice-2 design: replay reproduces the deletion from the recorded
selection events alone.

**Semantics.** Everything selected goes EXCEPT the '!' / '=' entries and
the tiles under them (mirroring the right-click delete's marker
protection — a marker needs its ground). A selected tile takes its
OCCUPANT with it: an entity/item placement standing on it is deleted even
when unselected (unreachable via today's UI — clicks and marquees always
grab tile + occupants together — but craftable in a log and reachable
once deselect features land; an occupant can't stand on nothing).

**Index stability — the subtle part.** The delete set is computed from
the ORIGINAL state (selected placement indices + swept occupant indices,
deduped per kind — duplicates in a crafted selection would otherwise
panic the delete arm's bounds check after the first removal), and the
processing order (the reversed LIFO push) runs each placement kind
HIGH-BEFORE-LOW so a removal never shifts an index a later event still
addresses — the same reasoning as the covering-decoration deletes in
`planEditorDeleteActions`. Tile erases are position-keyed (safe any
time) and process last. The selection reconcile inside each delete arm
keeps the selection consistent mid-batch; the protected remainder (the
markers + their surviving tiles) stays selected after the deletion.

**Wiring.** `Action.delete_editor_selection` (press-only, rebindable —
the `skip_level` pattern: the binding ships in default_settings.txt
regardless and no-ops on every other screen) → `IdleInput` field →
`handleIdleInput`'s editor arm (no-op gate: an empty or all-marker
selection never fires) → `validatePlayerAction` arm (screen + editor +
levels + select tool). New key mapping `Delete` in raylib_backend's
key_mappings (W3C code "Delete" → raylib `.delete`) — web build verified
compiling after the platform-seam touch (`scripts/web.sh`).

Tests: contract-level integration (mixed selection — selected + swept
occupants, markers + marker tiles protected, plan order asserted per the
LIFO convention, selection remainder = exactly the protected entries,
ONE undo step reverts the whole deletion incl. the selection) + the
no-op gate + the positive input path through handleIdleInput. Hit the
recorded test-harness gotcha again (seed before the first runToIdle or
undo restores the pre-seed snapshot). All 386 tests pass.

### Editor selection clear (ctrl+D)

`Action.clear_editor_selection` (ctrl+D, press-only, rebindable — the
`skip_level` shipping pattern) → `IdleInput` field → `handleIdleInput`'s
editor arm, gated on a NONEMPTY selection (the user's spec — an empty
selection never records, no dead undo step) → `player_clear_editor_selection`
→ the single `editor_clear_selection` machinery event (`editor.selection =
&.{}`).

**Granularity call:** ONE clear event, not a per-entry `editor_deselect`
fan-out. The granular add/remove events exist for click + marquee
semantics, where the entries carry meaning; a clear is a single operation,
and a 100-entry marquee clearing as 100 deselect lines would be log noise.
(Deliberate counterpart to the selection-delete fan-out, where each
per-entry delete names a different machinery verb with its own
invariants.) The tool-switch + level-tab clears remain side effects of
their own events; this is the explicit user action. `validatePlayerAction`
arm: screen + editor (no levels check — clearing needs no level; a
crafted event over an empty selection is an idempotent no-op).

New key mapping `KeyD` in raylib_backend's key_mappings (ctrl+D chord;
no collision with the existing ctrl chords — Z/Y/L/Enter). Tests: empty
selection never fires; nonempty fires the orchestrator; the clear empties
the selection; ONE undo step restores it. All 387 tests pass.

### Editor selection move (plain left-drag on a selected thing)

**Why.** The last selection operation — the reason the selection went onto
the undo timeline in the first place. The handler reads `editor.selection`
from reconstructable state; only the delta rides in the payload
(`player_move_editor_selection { delta }`), so replay reproduces a move
purely from the recorded selection events.

**Gesture** (`handleEditorMoveDrag`, mirroring the marquee): a plain left
press claims the drag when the press tile hits the selection — a selected
tile / entity / item, a selected decoration's FOOTPRINT, or a selected
marker (`editorSelectionContainsPosition`, the hit-test mirroring the
click group resolution). Threshold promotes; the view translates the
selection OUTLINES by the live delta (the world stays put — only the
preview moves). Release: nonzero delta → the move; zero delta → nothing
(no dead undo step); unpromoted → the plain-click toggle at the press tile
(the select arm defers to the gesture while it holds the press — a press
on a selected thing no longer toggles on press). Shift+press is the
marquee's; the two gestures clear each other's stale state on press.

**Commit — the two-phase + chained design.** The player handler backs the
selection up as concrete things (`types.EditorSelectionMoveEntry` — kind +
type_id + TARGET position; the clear phase destroys the placements, so the
type ids must survive in the payload), then pushes [commit link 0, …clear
plan] — LIFO runs the clear first. The clear plan is
`planEditorSelectionMoveDeleteActions`: the Delete key's plan refactored
to a mode (`delete_key` sweeps occupants; `selection_move` instead has an
UNSELECTED occupant PIN its tile — the ground stays under it and the moved
tile lands at the target; a selected occupant is deleted via its own
entry, so the erase proceeds under it). The commit is a CHAIN
(`editor_commit_selection_move { entries, next_index }`): each link plans
ONE entry against the live post-clear state via the existing placement
planners (the current placement rules, zero rule duplication) and pushes
[next link, …plan]. The chain exists because up-front planning of the
whole worklist breaks when two entries' targets share a covering
decoration (duplicate delete → stale index → panic) or an item entry's
enemy-delete shifts an index a later retype still addresses — proven by
the dedicated chain test (two entities moved under one wide decoration).
The exhausted link CLEARS the selection: a move deselects, nothing is
reselected (the user's call — most uses would ctrl+D right after anyway,
and it skips the new-index bookkeeping entirely).

**Markers:** the '!' / '=' move via the newly-implemented
`editor_set_player_start` / `editor_set_level_end` handler arms (previously
@panic stubs) with a tile ENSURED under the new position (paint plan). A
thing whose target overlaps a marker plans empty (the placement rules
never overwrite markers) and is therefore deleted fully — the user's drop
rule, falling out of the planners for free.

Session-log: the commit's `entries` field is the first slice-of-tagged-
unions payload — variable arity per tag (struct tags 3 tokens, Vector2
tags 2); the reader's top-level slice loop regroups by parsing until
tokens run out, so it round-trips (proven in the shapes test with entity +
tile + player_start entries).

Tests: full-move integration (placements/tiles/markers translate, sources
clear, deselect after, ONE undo reverts everything incl. the selection);
pinned-tile (unselected occupant keeps its ground, moved tile lands at
target); marker-target drop (entity + tile moving onto the '!' vanish,
marker + its tile intact); the chain-collision case; gesture (press
claims + same-frame tile_clicked defers, promote + live delta + release
fires with delta, zero-delta wobble never fires, unpromoted release
toggles, unselected press never claims). Two fixture lessons: a legal
level never has a tile under a decoration footprint (a selected decoration
never has a selected tile beneath it — the conflict can't arise), and a
stale re-seeded selection must reference things that still exist after a
prior move deleted them. All 392 tests pass.

### Selection move fix: a moved marker takes its ground with it

**The report.** Selecting the '!' / '=' and moving it left the old tile
behind. The user's hypothesis (the tile entry moving "before" the marker
and failing) pointed at the right area — the actual mechanism was one step
earlier, in the CLEAR phase: `planSelectionDelete`'s marker-tile protection
("the '!' / '=' need their ground") applied unconditionally, a rule built
for the DELETE key where the marker STAYS. In a move the marker LEAVES —
nothing hosts the old position anymore, so protecting its tile just strands
a orphaned tile there. (The click-select shape made it visible: a plain
click on a marker selects the singleton only — no tile entry — so nothing
else in the plan touched the old tile at all.)

**The fix.** In `selection_move` mode, a selected marker entry now erases
the tile it stands on — subject to the same guards as any erase: the tile
must exist, the OTHER marker must not be staying on it (both selected →
both moving → neither remains), and an unselected occupant pins it
(defensive — the tools never place on marker tiles). The delete-key mode is
untouched (markers + their tiles still survive Delete). The tile arm's
marker-tile protection and the marker arm's erase are disjoint by position
(marker positions vs non-marker positions), so no duplicate erases; the
extracted `selectionMoveOccupantPinsTile` helper now serves both the tile
arm and the marker arm (was inline in the tile arm).

Regression tests: the exact repro (singleton-selected '!' on a real tile →
moved → old tile GONE, target tile ensured, one undo restores both) + the
marquee shape (tile + marker both selected — the tile entry is skipped by
the protection, the marker entry drives the single erase). All 393 pass.

### Select-tool click semantics inversion: plain click replaces, shift+click toggles

**The change.** Plain left click (no Shift) now REPLACES the selection with
the clicked group (`player_replace_editor_selection` →
`planEditorReplaceSelectionActions`: clear everything, then select the
group — one player action, one undo step). Clicking EMPTY GROUND clears
the selection — the clicky deselect-all the user wanted as a side effect.
Shift+left click (no drag) is now the TOGGLE path (the semantics the plain
click used to have — group toggle, shift+clicking a selected thing
deselects it). Shift+drag marquee and plain-drag move are unchanged.

**Wiring.** The click-group resolution was extracted from
`planEditorSelectionActions` into `editorClickGroup` (shared by the toggle
+ replace planners). The replace plan composes the existing
`editor_clear_selection` + granular `editor_select` events (processing
order: clear first, then the group — built forward, reversed for LIFO).
No-op discipline: a click that would change nothing (the selection already
IS the group, or empty ground with an empty selection) plans empty and
never fires. Three press paths updated: `handleIdleInput`'s select arm
(plain click → replace), the move-drag's unpromoted release (mirrors the
plain click → replace — usually a no-op since the pressed thing is
selected, but it collapses the selection when other things were selected
too), and the marquee's unpromoted shift release (IS the toggle now, not
"acts as a plain click"). `validatePlayerAction` arm mirrors the toggle's.

Tests: the toggle test now drives the player event directly (it is the
shift+click path; its empty-ground case asserts the planner gate since a
direct push always records); a new replace test drives plain clicks
through `handleIdleInput` (group select on empty selection, replace on
click elsewhere, exact-selection no-op with nothing recorded, empty-ground
clear, empty-ground-with-empty-selection no-op, one-step undo); the
move-drag test's unpromoted case expects the replace (and its re-seeded
selection must now contain MORE than the clicked group or the replace
no-ops). All 395 tests pass.

### Inspector sidebar — toggle shell (DONE)

The inspector's open/close plumbing + static shell (the field editors are
the next slices; the panel is empty for now).

**Mechanism.** The open flag lives on the Editor (`Editor.inspector_open`,
default true) — NOT UiState like the in-game middle-panel toggles or the
palette accordion. Two reasons, both settled in DESIGN → Architecture →
Level Editor → Editor UI layout: the auto-open-on-new-type behavior must
mutate it from the `editor_add_*_type` handlers (handler purity — events
can't write session-side UiState), and replay must reproduce it. Full
pair: `player_toggle_editor_inspector` (orchestrator;
`validatePlayerAction` arm = editor screen + editor present) →
`editor_toggle_inspector` (the flip). Undo flips it back with the edit
history — same posture as `editor_set_tool`. The button click routes
`.toggle_editor_inspector` through `options_action` (payload-free, so no
main.zig release-dispatch rider); release sound `.menu` via
`releaseSoundForAction`, matching the in-game panel toggles.

**Layout** (the level-tab / group-header visual class): a top-left
"Inspector" toggle button flush below the options button — `ui/panel`
9-slice tinted player-gradient[5], 128 high (`editor_header_strip_height`),
label + 2×`ui_gap` wide with a 128 floor, spriteless button overlay
carrying the action + tooltip, text in theme lightest, highlighted while
open (mirrors the active level tab). While open, a background panel sits
beneath it: flush left, 1024 wide (`editor_inspector_width`, placeholder
until the field layout settles), from below the button (y 416) down to
the expanded palette groups' header strip (y 1760 — stopping short keeps
the bottom-bar headers off the inspector background), theme-darkest tint
(the background-panel class), `blocks_input` so viewport clicks don't
fall through it.

Tests: handler test (flip + undo/redo round trip), builder test (button
always present + tab-shaped, panel only when open, layout constants).
Follow-up tracked in TODO → Tech Debt: unify the in-game middle-panel
toggles onto the same GameState convention.

### Editor select-all — ctrl+A (DONE)

Select everything in the active level with one keypress. Same shape as
the marquee region-select: `Action.select_editor_all` (binding ctrl+A in
`default_settings.txt`, beside ctrl+D) → `IdleInput.select_editor_all` →
consumed in `handleIdleInput`'s editor arm → `player_select_editor_all`
(no payload — the handler reads state) →
`planEditorSelectAllActions` pushes one granular `editor_select` per
selectable thing in the active level: every tile, entity / item /
decoration placement, and the '!' / '=' singletons. That's the marquee's
membership rule with no region bound; the shared
`appendSelectEntryIfNew` helper (renamed from
`appendRegionSelectEntryIfNew` — it now serves both planners) skips
entries already in the selection, so an all-selected level plans empty.

No-op gates at the input site (no dead undo steps): the plan must be
nonempty, AND the select tool must be active — every selection op is
select-tool-only (`validatePlayerAction` panics otherwise; the same arm
shape as the region select). All adds share the player action's idle
point, so one undo step reverts the whole batch to the prior selection.

Tests: select-all over a 9-thing level from a 2-entry partial (batch
fires once, all 9 present, undo restores the partial — note the test
seeds the selection BEFORE `runToIdle` so the idle-point snapshot
captures it); no-op cases (tile tool active; everything already
selected). 398 tests pass.

### Inspector field editor — design settled + text input core (DONE, part 1 of slice 1)

**Design settled** (recorded in DESIGN → Architecture → Level Editor →
Editor UI layout → "Inspector fields (enemy types — settled)" + DESIGN →
UI Framework → Text input widget): the parser is the coupling contract
(every `parseEntityDefinition` key ↔ exactly one inspector control,
bounds single-sourced from the loaders `max_*` constants); thin
PlayerInputEvent wrappers per field verb → the existing
`editor_set_entity_*` events; base stats UNBOUNDED by design (gear bounds
exist for player-pickup balance — enemies are allowed to be unbalanced,
validation guarantees completability); momentum NOT authorable
(`editor_set_entity_momentum` to be removed — transient combat stat);
weapon types as an INLINE row (create-on-pick-while-null / retype /
delete) rather than the centered picker (the picker's first consumer is
the 25-skill utility picker); color_index as an inline swatch row; sprite
id as a plain text field in v1 (the sprite picker later, with resolution
prioritizing mission-folder .pngs); text-field focus semantics M2 +
commit-on-dismiss (Enter/OK commit, Escape discards, click a sibling
inspector control = commit + proceed, click elsewhere = commit +
consumed — Undo-while-focused eats the click so the next click undoes
the just-committed value).

**Text input core landed:** `TextField` (ui.zig, beside FontMetrics) —
a fixed 128-byte UTF-8 buffer with byte-index caret + selection anchor.
Pure methods only: `loadValue` (seed from the field's current value),
`insertText` (replaces the selection, truncates to capacity),
`deleteBackward`/`deleteForward` (selection or one codepoint),
`moveCaretTo(index, select)` — the ONE movement primitive (false = plain
move clearing the selection, i.e. a click; true = plant-the-anchor
selection move, i.e. shift+arrow / drag), `moveCaretLeft/Right`,
`selectionRange` (min/max, anchor==caret is no selection), and
`caretIndexAtX` (pure click-x → boundary mapping via FontMetrics —
multibyte uses the same 0.5em fallback the measurement seam uses). All
indices are codepoint boundaries: `codepointStartBefore` (returns 0 at
the buffer start — a move-left there no-ops) / `codepointEndAfter` /
mid-index rounds FORWARD. Character filtering (digits-only for numeric
fields) is deliberately NOT core — the routing layer knows the field
kind and filters before insert. Six unit tests cover capacity
truncation, both delete directions with/without selection, the movement
primitive's select/clear/flip math, insert-replaces-selection in both
anchor directions, UTF-8 navigation, and click-x mapping. 404 tests
pass.

One test-writing lesson worth keeping: the UTF-8 nav test's expected
caret path was wrong on the first pass (byte-index arithmetic done in
my head instead of walking the actual byte layout) — the CODE was
right, the EXPECTATION was wrong. Self-referential asserts are only as
good as the walk that derives them.

### Text input widget — seam, routing, M2 arbitration, entity-name commit (DONE, slice 1 complete)

The full input path for the text widget, headless-tested end-to-end; the
first real consumer (the inspector's rendered fields) is slice 3.

**Backend seam.** `pollInput` drains the platform char queue
(`rl.getCharPressed`, read before the pump like the wheel) into a 64-byte
scratch buffer, UTF-8-encoded, exposed as `PlatformInput.text_characters`
(valid one frame, like `event_buffer`). Out-of-range codepoints are
skipped, not fatal — `@intCast` to u21 would panic on platform junk.
Headless tests inject the field directly.

**Focus state + routing.** `UiState.text_edit: ?TextEditState`
(`TextEditState` = `TextFieldRef` (types: `TextFieldId` +
`EntityEditTarget`) + the private `TextField` buffer; `beginTextEdit`
seeds it from the field's current value). `translateInput` gained a
`?*ui.TextEditState` param: while set it calls `ui.routeTextInput`
(chars → buffer, Backspace/Delete/arrows(+shift) → edits, Enter/Escape →
`TextEditOutcome`), populates pointer facts + wheel + cursor-resolution
inputs, and returns WITHOUT any binding translation — chords suppressed
too (ctrl+Z included; Escape discards first). Edit keys accept synthetic
repeat edges (hold-backspace); resolver keys ignore them. Numeric
filtering lives in `routeTextInput` (`textFieldIsNumeric`), not the core
buffer. `pointerFacts` was extracted so the focused early-return builds
the identical pointer state. `PlayerInput.text_edit_outcome` carries the
resolution.

**M2 + commit-on-dismiss.** `main.frame` resolves the outcome ONCE per
frame (before the drain — `update()` re-runs per drain iteration).
`main.update`'s press dispatch: a left press while focused calls
`commitFocusedTextEdit`, then `ui.textEditPressProceeds` decides — inside
the OPEN inspector panel or on the toggle button → proceed (one-click
sibling switching); anywhere else → consume as pure dismissal (the
Undo-while-focused corollary: the next click performs the undo).
`editorInspectorPanelRect` is now the single source for the builder's
panel geometry AND the arbitration (the builder test cross-checks them),
so the two can't drift. Idempotent across drain re-calls (commit clears
focus). `commitFocusedTextEdit` (input_handlers) is the field-kind
switch: dupes the buffer into current_arena BEFORE dropping focus (the
payload must not point into UiState), would-change gate (an unchanged
value records nothing), pushes
`player_set_editor_entity_name` → `editor_set_entity_name`
(`editorEntityTemplate` shared pub helper — the target-resolution
switch exists once). `validatePlayerAction` arm: editor screen + editor +
target index in range.

**Tests (408 pass).** translateInput: focused suppresses Enter→confirm /
Escape→options bindings (with an unfocused control case) + chars insert +
outcome; routeTextInput: chars/edges/repeats/shift-select/resolvers;
textEditPressProceeds region cases; end-to-end: focus → type → Enter →
name changed + focus dropped + one undo restores, no-op gate, cancel.
Web build compiles (the seam change is in pollInput).

Three test-writing misses this slice, same shape as last time: the
caret-math expectations (selection range on a 14-char buffer) and the
seed-vs-fixture value (beginTextEdit seeds from the CURRENT value — the
test's seed must BE the fixture's name) were wrong on paper while the
code was right. Also: undo after an action pushed via
`pushPlayerActionAndDrain` needs `runToIdle` to record the idle point
(idle-point recording is main.zig's job in the live loop; tests must call
it explicitly).

### Inspector content scaffolding — sections, rows, scrollbar (DONE, slice 2)

The inspector's content surface (the open panel is no longer empty); the
field CONTROLS land with slices 3-5.

**Target resolution.** `ui.editorInspectorEntityTarget`: the active enemy
tool → its palette index; every other tool (select/tile, and decoration/
item until their slices) → the empty state — a hint label ("Select an
enemy tool to edit its type"). Stale tool ids (the type deleted while its
tool was active) fall to the hint too, not a panic.

**Content plan.** `editorInspectorEntityEntries` lists the full enemy-type
field set as 5 sections (Identity / Stats / Weapons / Gear / Utility
skills) + 20 field rows — the coupling contract made visible: one row per
field `parseEntityDefinition` reads. Rows are LABEL-ONLY in this slice
(control columns are filled by the field slices); the labels are the
stable part. Section headers render as panel-backed strips (the group-
header visual class, gradient[5] + lightest label); field rows are
lightest labels in a fixed label column (`editor_inspector_label_width`
384) at the 128-high row pitch.

**Scrolling.** `UiState.editor_inspector_scroll` (rows — the whole-row
convention). Windowed emission is the skills-panel model: only FULLY
visible rows are emitted at view-relative positions at the top of the
content region (nothing half-draws or overflows the panel; the thumb
conveys position). 25 entries vs 10 visible rows → the scrollbar (track +
proportional thumb in the right ui_gap margin, skills geometry) shows.
The builder's clamp is authoritative; the wheel handler (inserted in
handleAnytimeInput's scroll chain: open panel + pointer inside the panel
rect — the wheel over the panel belongs to the panel, never the camera)
clamps the lower bound on write. Panel closed → the routing falls
through. Wheel still flows while a text field is focused (only KEY
bindings are suppressed).

Tests: builder (window at scroll 0/3/max-clamp, negative clamp, element
counts incl. scrollbar rects, stale-id empty state resetting the scroll),
wheel routing (inside → ±1 row with top clamp; outside + closed →
untouched). 410 pass. One more expectation-index slip caught by the test
run (scroll 3 starts at entry 3 = "Color", not "Sprite" — comment
arithmetic, code was right).

### Inspector text fields — element, focus-on-click, caret render (DONE, slice 3a)

The first live controls: the Name + Sprite rows are real text inputs,
end-to-end (click → focus → type → Enter → event → undo). The sprite id
is the settled v1 plain-text field (the centered picker replaces it in
slice 6).

**The element.** `text_field: TextFieldUi` — the builder computes ALL
render data (it owns the metrics + the focused buffer): frame rect,
display text (the current value, or the live buffer while THIS field is
focused), caret bar + selection highlight geometry measured from the
buffer. The backend arm just draws (9-slice frame → selection @128 alpha
under the text → text → 8px caret). Element conventions: `blocks_input`
+ `tooltip` fields (tooltipOf/blocksInputOf's inline-else forces them),
a `boundsOf` arm, and `ui.textFieldAt` (the hitTest pattern). Display
text is duped into the frame allocator — element slices never point into
UiState (the previous frame's elements are hit-tested a frame later,
after the buffer has mutated).

**Focus-on-click.** `SessionState.pressed_text_field` mirrors the
pressed_button press/release model: release over the SAME field focuses
it (`beginFocusedTextEdit`: reads the field's current value via the
shared editorEntityTemplate + seeds the buffer) or, when it is already
the focused field, positions the caret (`ui.placeCaretFromClick` —
caretIndexAtX against the field's text origin, metrics read off
`ViewState.font_metrics`, the one backend-derived value the input side
needs; view() now sets it). Drag-off cancels. Press arbitration refined:
pressing the FOCUSED field itself does NOT commit (caret click) — any
other press commits first, then M2 proceeds/consumes. A field press
tracks `pressed_text_field` and leaves `pressed_button` null (a field is
not a button).

**Sprite commit path.** `player_set_editor_entity_sprite` →
`editor_set_entity_sprite` (the event already existed), same shape as
the name: would-change gate, `editorEntityTemplate` shared resolution,
validate arm (editor screen + editor + target in range).
`commitFocusedTextEdit` now switches both string ids through one arm.
`TextFieldId.entity_sprite` + the digits-filter map gained the case.

**Tests (415 pass).** Builder: unfocused fields show current values
(ref + control-column rect asserted); focused field shows the buffer +
selection/caret geometry (expected values computed via the metrics' own
measureSpanWidth — per-glyph arithmetic drifts because the accumulation
truncates once at the end). placeCaretFromClick: click-x mapping +
selection-clearing. Sprite commit: edit + undo, name untouched. NEW: a
main.zig integration test drives the REAL press/release dispatch
(update() with a synthetic previous_view_state): press tracks the field,
release focuses with the seeded value, click-inside-focused-field moves
the caret, pressing another field commits (unchanged → records nothing)
+ focuses it on release, and drag-off — which exposed a test-expectation
bug worth remembering: the M2 commit fires on PRESS, so a drag-off after
pressing a different field leaves NO field focused (the old one was
committed by the press, the new one cancelled by the miss). The code was
right; "focus unchanged" was the wrong mental model.

Backend render arm = platform seam → web build compile-checked (WEB OK).
Runtime eyeball pending (the caret/selection draws are new) — next
`scripts/web.sh emrun` or native run should confirm the fields render.

### Inspector layout — label line above the editable value (DONE)

Layout revision per author feedback: a field entry is now TWO row units —
the label ("header") on its own line, the editable value full-width BELOW
it (Name's text field sits under the word "Name"). Section headers stay
one unit. The old single-line label-left/control-right column layout
(`editor_inspector_label_width`) is gone — one thing per line reads
better at this width.

Windowing + scrolling reworked for variable-height entries: scroll and
the window are in 128px row UNITS (section = 1, field = 2; 45 units total
vs 10 visible), and an entry is emitted only when it FULLY fits the
window (partially-visible entries are skipped — same no-half-drawing
rule, now per-entry instead of per-row). The scrollbar thumb is
proportional over units. Wheel notch = one unit.

### Inspector scalar controls — swatches, toggle, numeric stats (DONE, slice 3b)

The Identity + Stats sections are now fully live; the enemy-type
inspector's scalar set is complete (weapons/gear/utility skills are
slices 4/5).

**Controls.** Color: a six-swatch row in the ENEMY gradient (the settings
screen's player-color pattern — colored solid_rect fill + invisible
payload button + highlighted selection), committing via
`.select_editor_entity_color` (the index rides in
`AnytimeInput.clicked_editor_color` + a new `Button.editor_color`
payload); same-value picks never fire. Displays weapons: a full-width
panel-backed toggle showing the FORMAT's own vocabulary ("true"/"false" —
the exact tokens `asBool` parses), highlighted while true, flipping via
`.toggle_editor_entity_displays_weapons` (a flip always changes — no
gate). The four stat fields are numeric text inputs riding the slice-1/3a
machinery: digits-only filter (`textFieldIsNumeric`), commit parses with
u32-max clamp on overflow (base stats UNBOUNDED by design), an EMPTY
buffer commits nothing, and the would-change gate compares PARSED values
(so "025" vs 25 records nothing — a string compare would false-positive).
`editor_set_entity_momentum` REMOVED (transient combat stat, never
authorable — level files can't set it).

**Single value source.** `Entity.textFieldValue(allocator, field_id)`
(types.zig): strings verbatim, numbers decimal-formatted — shared by the
builder's display text, `beginFocusedTextEdit`'s seed, and the commit
gate, so the three can't drift. Six thin player wrappers
(color/displays_weapons/4 stats) → the pre-existing editor events; the
six validate arms share `validateInspectorScalarCommit` (Zig can't
multi-case-capture distinct payload struct types — separate arms, one
helper).

**A REAL bug the tests caught** (worth the pattern note): the leading-
zero test scenario — seed "25", caret to start, type "0" — produced
"022". `TextField.insertText` shifted the tail with `copyForwards`, but
insertion shifts the tail RIGHT (dst > src, overlapping regions) where a
forward copy reads already-overwritten bytes; every prior test inserted
at the end or replaced a selection with a SHORTER string, so the
mid-string case had never run. Fixed with `copyBackwards` (safe in both
directions) + a dedicated mid-string insert test (start, middle, and
longer-than-selection replace). The DONE convention from slice 1 keeps
paying off: derive expectations by walking the actual state, and the
failures that survive THAT scrutiny are real bugs.

Tests (417): builder (stat fields formatted "20"/"0"/"1"/"3", swatch
count/payload/highlight, toggle label + highlight), clicks (swatch
commit + same-value no-op + undo-per-edit, toggle flip, no-tool no-ops),
numeric commits (parse, overflow clamp, empty no-op, leading-zero
no-op).

### Fix: text-field commits now record their own undo stop

Author-reported: committing a text field (e.g. Sprite) updated the state
but undo stepped PAST the edit and redo lost it — the commit recorded
its EVENT but never an idle point (the undo stop).

Root cause: the keyboard-resolution path (Enter) commits from
`main.frame()` BEFORE the drain loop, and the only idle-point recordings
live in the drain loop / the idle update() call — both of which see an
empty stack + no input afterward, so `events_processed` comes up false.
The M2 click-away path was fine (it commits inside update(), where the
idle branch's events_processed check catches the index advance). The
unit tests masked the bug: they called `runToIdle` after resolving (its
unconditional recordIdlePoint was the missing stop) — noted as a
"harness gotcha" in the slice-1 entry without recognizing it was the
LIVE path's gap.

Fix: `commitFocusedTextEdit` calls `maybeRecordIdlePoint(true)` after
its push+drain — the invariant "a committed edit is one undo step" now
lives with the commit, not the call site. Safe everywhere:
maybeRecordIdlePoint's own guards skip a non-empty stack (a mid-drain
commit absorbs into the surrounding drain's idle point) and an
already-recorded position (the M2 path's later recording dedupes). The
masking `runToIdle` calls are removed from the commit tests — their undo
assertions now pass on the commit's own recording — and the name test
gained an explicit undo→redo→undo round trip (the exact reported
symptom).

### Inspector item data layer — TextFieldId union, slot events, bounds single-sourced (DONE, slice 4a)

The plumbing under the Weapons + Gear sections (their UI is 4b): item
sub-fields are now addressable, committable, and bounded.

**TextFieldId became a union** (it only flows through UiState + the
commit switch — never serialized into events — so the reshape was
cheap): `entity_name` / `entity_sprite` /
`entity_stat: EntityStatField` (the four base stats) /
`item_name: GearSlot` / `item_stat: { slot, stat: ItemStatField }`.
Payload-less cases keep their `.entity_name` literal construction, so
pre-existing call sites barely churned.

**Item addressing.** `Entity.gearSlotItem(slot) ?Item` is the single
slot→item mapping (types.zig; ui.zig's gear-panel fn is now a delegate —
it had the identical switch). Item accessors in types.zig: `itemName` /
`itemWithName` (a skill tome carries no name — unchanged/empty),
`itemStatValue` (null when the item kind doesn't carry the stat — a coat
has no weapon_damage), `itemWithStat`, `itemStatMax`.

**Bounds moved to types.zig.** The gear-stat `max_*` constants
(max_weapon_damage 10 … max_boots_speed 2) lived in loaders.zig, which
types.zig can't import — the coupling contract ("the parser's clamp and
the UI's commit clamp read the same constants") required the move;
loaders' 56 internal references now point at types.max_*. The commit
paths: base stats UNBOUNDED (overflow → u32 max), item stats clamped to
`itemStatMax` (parseBoundedStatValue).

**Events.** Seven thin wrappers (player_set_editor_entity_main_hand_
weapon … _boots) carrying whole nullable items → the pre-existing
per-slot EditorEvents. One event per slot means create / retype /
field-edit / delete are all one undo step. `editorSlotItemAction`
(input_handlers) builds the wrapper from the Item union — the ONE
union→typed conversion site, shared with 4b's click handlers.
`validateInspectorEntityEdit` (renamed from validateInspectorScalarCommit
— it now covers item commits too) checks screen/editor/target for all 13
inspector entity-edit arms. Commit no-op gates: empty slot, wrong-stat-
for-kind, would-change (numeric semantics for stats, string for names).

Tests (420): weapon name edit rides the whole-item event (type + damage
intact, one undo), weapon damage clamps to max_weapon_damage, wrong-stat
and empty-slot no-ops. UI-side churn: the Stats entries + tests now
construct `.entity_stat` payload ids; findTextField compares via
std.meta.eql (unions have no ==).

### Inspector weapons + gear UI — slot rows, type cells, item fields (DONE, slice 4b)

The Weapons + Gear sections are live; the enemy-type inspector now covers
every field the level format carries except utility skills (slice 5) and
layers (slice 6).

**State-dependent entries.** `editorInspectorEntityEntries` is now BUILT
per frame (frame arena) instead of a static table: each weapon/gear slot
row is followed by the equipped item's Name + stat rows (nothing when
empty — `gearSlotStatSet` gives each slot's stat fields in display
order). Unit accounting: every slot row is 2 units like a field; with no
items equipped the plan occupies the same 45 units as before, so the
existing window/clamp tests held unchanged.

**Slot rows.** Weapons: the six types as cells — the
`weapons/enemy_<type>` silhouette (what the entity will actually wield),
aspect-fitted on the shared `ui/button_background` (the palette tool-cell
visual class), enemy-tinted, the equipped type highlighted, a tooltip with
the type's display name — plus a Delete button in the row's remaining
width while equipped. Gear: a full-width Add (empty) / Delete (equipped)
panel button (the toggle's visual class). New actions
`.select_editor_weapon_type` / `.add_editor_item` / `.delete_editor_item`
route through `options_action` with Button payloads (`editor_gear_slot`,
`editor_weapon_type`) riding in AnytimeInput.

**Click semantics** (handleAnytimeInput arms, all via
`editorSlotItemAction` / `editorSlotClearAction` from 4a): a type pick on
an EMPTY hand creates the default weapon ("New <Type>" via the shared
`weaponTypeLabel` table, damage 0); on an EQUIPPED hand it retypes in
place (name/damage stable — identity survives, the same reasoning as
placement retype); same-type picks never fire. Gear Add creates "New
<Slot>" (zero stats) — only on an empty slot, and never on the weapon
hands (their creation path is the type row). Delete clears to null,
empty slots no-op. One whole-item event = one undo step for any of them.

Tests (421): builder (equipped main hand → type row + Delete + Name/
Damage fields with values, empty off hand → no fields/no Delete; gear
Add vs Delete per occupancy; highlighted type cell) and clicks (create +
undo, retype keeps identity, same-type no-op, delete + empty no-op, gear
add + present no-op, weapon-hand add gate). Window-arithmetic slips in
the test expectations (section headers start AT the boundary; the Add/
Delete buttons carry their own labels into the label list) were the only
failures — the code was right each time.

### Inspector visual polish (author feedback round)

Six adjustments before the utility-skill picker:
- Weapon-type cells show the ITEM ICON (`items/<type>`, the inventory's
  art, palette item-icon tint) instead of the entity weapon silhouette —
  the author picks an item, not an overlay.
- Item sub-field headers carry the slot: "Main hand name" / "Coat health
  bonus" (stat labels became lowercase-first since they always follow
  the slot name; never standalone).
- The full-width buttons (displays-weapons toggle, gear Add/Delete) are
  now HALF the control width — full-width read as section headers.
- No highlight outline on the Inspector toggle while open, nor on the
  displays-weapons toggle while true — the labels carry the state.
- Field headers sit CLOSE to their fields: labels are bottom-flush
  against the control line and the control inset halved
  (`editor_inspector_control_gap` 8, shared `inspectorControlRect` /
  `inspectorLabelY` helpers — the three entry arms can't drift).

### Inspector visual polish, round 2 (author feedback)

- Weapon-type cells now sit on the inventory's `ui/item_slot` graphic
  (same gradient[5] tint the inventory grid uses) instead of the shared
  button background — they read as item slots, matching the item icons
  they carry.
- Text fields read as editable paper strips: the frame is the theme
  LIGHTEST and the text is PURE black — literal {0,0,0}, not theme
  darkest (the contrast is the point). `TextFieldUi` gained `text_color`
  and the backend draws the caret + selection in the SAME color (solid
  caret, 128-alpha selection) — the theme-lightest accents the backend
  previously used would have vanished on the light frame. Platform seam
  touched → web compile-checked (WEB OK).

### Inspector section-break spacers (author feedback, round 3)

One blank row unit before every section header except the first (a
`spacer` entry kind, rendered as nothing) — the section break now reads
as a break instead of an adjacent differently-styled strip. The spacer
rides the unit grid, so scrolling stays line-aligned. Total content: 45
→ 49 units (max scroll 39). Test windows recomputed (the failures were
all expectation arithmetic — the Stats/Gear headers landing in or out of
windows by one unit).

### Utility-skill policy — one rule, five seams (DONE, slice 5 part 1)

The rule (author-settled): only UTILITY skills — spells, cantrips,
enchantments, curses — may sit on the utility bar; weapon skills belong
to the equipped weapon's three slots. Previously the rule existed
NOWHERE: the parser accepted any SkillId in slot_4..8 (entity defs AND
player saves), skill tomes could teach weapon skills, and the player
equip path only gated on "learned". Census for the record: 18 weapon
skills, 5 cantrips, 2 enchantments, 0 spells/curses — 7 eligible today.

**Single source:** `src/utility_skills.zig` — `isUtilitySkill` (reads the
generated skill definitions, so new skills classify automatically) +
`utility_skill_ids` (the comptime eligible list — the picker's options).
Its own module because functions.zig would cycle (skills import
functions; lookups import skills).

**Seams:**
1. Parser, entity definitions (level files + player.txt loadouts): a
   weapon skill in slot_4..8 → WARN + DROP the slot (the level loads).
2. Parser, player saves, UtilitySkills section: same.
3. Parser, player saves, inventory: a weapon-skill TOME is disallowed —
   warn + drop the ITEM (a tome feeding a bar weapon skills can't reach).
   (Level-file Items don't support tomes — one site.) A shared
   `appendWarning` helper factors the boundedU32 message shape.
4. Editor: `player_set_editor_entity_utility_skill` → the existing
   `editor_set_entity_utility_skill` (nullable SkillId — None clears);
   validation rejects weapon skills + out-of-range slots; the handler
   no-ops defensively.
5. Player path: `equip_utility_skill` no-ops on a weapon skill, and
   `player_assign_utility_skill` (the learned-skill drag — the learned
   list CAN contain weapon-skill tomes) gains the validation check.

Tests (424): the policy census; level-file slot drop + keep with the
warning; save-side slot drop + tome drop with two warnings; the editor
commit set/clear/undo + weapon-skill + bad-slot no-ops. The save
round-trip fixture itself carried `slot_4 slice` — legal-by-accident for
months, now swapped for `.swap` (learned list still carries slice, which
is FINE: learning a weapon skill is legal, bar-equipping it is not).

### The centered skill picker (DONE, slice 5 part 2)

The picker framework's first consumer; the enemy-type inspector now
covers every scalar + slot field the format carries (layers remain,
slice 6).

**The picker.** `buildEditorSkillPicker` — a modal centered panel
(darkest, `emitPanelHeader` with the middle-panel close button): a None
cell (the empty-slot diamond frame) + one skill-button cell per
utility-eligible skill (the flat comptime list — 7 today; icons
centered, names at the cell bottom, skill tooltips), the currently
assigned pick highlighted, header "Assign Slot N". `UiState.editor_picker:
?EditorPickerTarget` (a union — the sprite picker joins later); opening
is an affordance (off the timeline), the PICK records via
`player_set_editor_entity_utility_skill`. The None cell carries no
`editor_skill` payload (null = clear). MODAL: a gate at the top of
handleAnytimeInput runs only the picker's own actions while open
(everything else — including Escape→options-menu — is swallowed; the
panel itself blocks the world element-wise). Same-value picks (incl.
None-on-empty) close without recording.

**The slot rows.** The five utility entries are half-width buttons
showing the current skill's name (or "None") via a new `skill_slot`
control kind; clicking opens the picker for that slot
(`.open_editor_skill_picker` + the slot payload).

One build hiccup worth remembering: a python replace anchored on the
M2-arbitration doc comment silently no-opped (its first line had been
eaten by an earlier slice's edit — the comment started mid-sentence).
The tell was "inserted" printing while nothing landed; the fix restored
the lost doc line. Python .replace never fails loudly — anchor on text
you've just SEEN, and verify after.

Tests (427): the picker builder (26 elements: header/close/None/7 cells,
blink highlighted when assigned, no weapon-skill payload anywhere) and
the full interaction (open → modal gate swallows other actions → pick
assigns + closes + one undo → same-value no-op → None clears → close
button). The picker arm commits inside handleAnytimeInput — the NORMAL
path (update()'s recording covers it live) — so directly-driven tests
need runToIdle, unlike the frame-level text-commit case.

### Picker + inspector overhaul (author feedback)

- **Full modality fixed** — the picker previously leaked the idle/viewport
  path: enemy placement still fired under it (my anytime gate covered
  button actions only — hence the tell "can place an enemy but can't
  collapse a palette group"). The picker now joins the options-menu gate
  in main.update() (after handleAnytimeInput — which runs the picker's
  own arms — before the idle/drag/viewport path): everything is blocked
  while it's open.
- **Picker cells**: real skills are ICON-ONLY at full cell size (the icon
  is the identity; the tooltip carries the name); the None cell keeps its
  text label. Coloring follows the entity-inspect panel's skill
  convention on the ENEMY gradient: frame index 3, icon index 1.
- **The inspector slot rows**: an occupied slot shows the actual skill
  (square skill-button cell, frame enemy[3] + full icon enemy[1], skill
  tooltip — the entity-inspect look); an empty slot keeps the half-width
  "None" text button.
- **The whole inspector now uses the enemy gradient** (it edits enemy
  types — the entity-inspect team-gradient reasoning): section headers,
  the top-left toggle, weapon cells (+ their item icons), the
  displays-weapons toggle, gear Add/Delete, and the skill slots all
  switched from the player gradient. Unchanged by design: the swatch row
  (already enemy-gradient fills), text fields (lightest/black), and the
  darkest background panel.

### The picker de-modaled — a dropdown, not a dialog (author feedback)

The modal gates are gone (both the handleAnytimeInput special-case —
its arms moved into the main options_action switch, guarded by "picker
must be open" — and the update() idle gate). The picker now blocks
input only where it physically sits (element-wise); everything around
it stays live — placing enemies, collapsing palette groups, undo all
work while it's open — and it stays open until a skill is picked or
the close button is pressed (no outside-click dismiss).

Why this is sound (and why the modal was overreach): the view is
rebuilt per frame from live state, so nothing under the picker can go
stale — its highlight follows undo/redo automatically; and the picker's
target (the slot being assigned) is UiState that no other action
invalidates. The options menu was the wrong template: it's modal
because it PAUSES the game; the picker is a transient affordance.

One real seam the dropdown exposed: a picker press while a text field
is focused fell outside the inspector rect, so the M2 commit-on-press
rule would eat the click (pick twice to fire).
`textEditPressProceeds` now treats the picker's surfaces (a skill cell
or its close button) as PROCEEDS — the field commits and the pick
fires in the same click. Escape → options menu stacks ABOVE the picker
(it builds after the screen branches), no special-casing.

Tests: the interaction test's modal assertion flipped (the inspector
toggle now fires under the picker AND the picker survives it); the M2
test gained the picker-surface cases.

### Inspector selection-inferred target (DONE)

The inspector now shows while SELECTING: `editorInspectorTool` (ui.zig)
resolves the tool the inspector should edit — the active placement tool
passes through, and while the SELECT tool is active the selection is
scanned: each selected placement resolves to its palette tool (kind +
type_id against the ACTIVE level's placement lists; out-of-range indices
ignored, defensive only), while tiles / `player_start` / `level_end`
contribute nothing (nothing to inspect on them). Exactly one distinct
referenced tool → that tool's fields; zero or ≥2 distinct (mixed kinds
count as distinct: an enemy placement and a ground-item placement are
different tools even at equal indices) → the "No tool selected" hint
(simplified from "Select an enemy tool to edit its type" — same meaning,
shorter).

`editorInspectorEntityTarget` became a thin wrapper
(`editorInspectorTool` → entity arm, palette-range-guarded), so the
inspector content AND every edit-action routing site — the input_handlers
commit paths, the centered skill picker — re-target automatically with
zero call-site changes. This is why the inference lives inside the
existing resolution seam rather than a parallel function: display and
commits can't disagree about what's being edited.

The return type is `?EditorToolId` for now; the future
player-start→loadout inspection (the '!' isn't a palette tool) lands by
widening to a target union that also carries `player_loadout` — noted in
DESIGN → Selection model (Inspector tool-type inference), which this
slice rewrote to the implemented rule (the old text had tiles/markers
DISQUALIFYING inference; the author's rule is that they're IGNORED —
a selection of tiles + identical enemies should still show the enemy).

Only enemy fields are built; an inferred decoration/item tool falls to
the hint until those inspector slices land — the inference itself is
already general over all three placement kinds.

Tests: four unit tests on the pure function (active-tool passthrough;
same-type + mixed-with-tiles/markers inference; two-types and
mixed-kinds nulling; stale-index ignoring) plus the stale-entity-target
wrapper case; the content test's hint string updated.

### Inspector slice 7 — player as the fallback target (DONE)

The inference widened to its final shape: `editorInspectorTarget`
(ui.zig) returns a non-optional `EditorInspectorTarget = { entity_type |
player }` where the PLAYER is the fallback — the active enemy tool (valid
index) wins; the tile tool, the decoration/item tools (no content yet),
an empty selection, and every ambiguous resolution land on the player.
Under the select tool the scan now treats the '!' as a `.player`
REFERENCE (so the spawn alone — or mixed with an enemy — resolves to the
player, fixing the old behavior where player-start + enemy showed the
enemy), keeps tiles / the '=' as legitimately-uninspectable nothing
(mixing them with enemies still shows the enemy), and treats
out-of-range placement indices, stale palette type ids, and
decoration/ground-item placements as unresolvable references that force
the fallback. The "No tool selected" hint is GONE — the player shell
(a "Player" header strip in the player gradient + the loadout name line)
is the inspector's default content; the section-strip emission was
extracted into `emitInspectorSectionStrip` shared by both contents.

Why the target union instead of keeping `?EditorToolId`: the player
loadout isn't a palette tool at all (`player_def`, reached by the '!',
never a palette entry), so it needs its own arm — and a non-optional
return makes "fallback" structural rather than a null-check every
consumer must remember.

The commit routing migrated with it: a new `editorEntityEditTarget`
helper (input_handlers) maps the target to `EntityEditTarget` (player →
`.player_def`), replacing the six two-line
`editorInspectorEntityTarget` resolutions — the entity-edit events
already carried `.player_def`, so the player arm of every commit
(swatches, gear add/delete/retype, utility-skill picks) works with zero
new event plumbing. The picker's current-skill resolution reads the
full target too. `editorInspectorEntityTarget` survives as a
file-private entity-arm helper for the content builder (no longer pub —
its input-side callers are gone, per the minimize-pub discipline).

One shape note: the enemy prong of the selection scan CONTRIBUTES via a
labeled block (`break :blk`) rather than returning — an early `return`
on the valid path would have resolved a two-enemy-types selection to
whichever came first, silently breaking the ambiguity rule. The
fallback paths (unresolvable references) return early on purpose.

Tests: the four inference tests rewritten to the new semantics (active
tool passthrough + tile/decoration/item fallback; shared-type wins with
tiles/'=' mixed in; the '!' reference rules; unresolvable-reference
fallbacks + the entity-arm wrapper), the two panel tests updated for the
player shell (7 elements, header strip at index 4), and the picker test
gained a player-target case (stone_form highlighted from player_def).
DESIGN → Selection model (Inspector tool-type inference) rewritten to
the settled rule.

### Inspector slice 8 — the utility-skill row (DONE)

The five per-slot field rows ("Slot 4".."Slot 8", half-width None
buttons) are replaced by ONE `utility_skill_row` entry: the label line
("Skill bar") + five adjacent 128×128 skill slots pitched 128 + ui_gap,
the entity-inspect skill look — occupied = `ui/skill_button` frame +
full-size icon + the skill tooltip, empty = the `ui/skill_slot_empty`
diamond with a "None" tooltip. Every slot (occupied or empty) is a
picker button carrying its slot index, so the interaction is unchanged:
click → the centered picker opens on that slot.

`emitInspectorUtilitySkillRow` takes the team gradient as a PARAMETER
(frame = index 3, icon = index 1) instead of reading
`active_theme.enemy_gradient` — the one change that makes the row
reusable by the player inspector (slice 9 passes the player gradient).
The old `emitInspectorSkillSlot` and the
`EditorInspectorControl.skill_slot` variant are deleted; the entry union
gains `.utility_skill_row` (2 row-units like every label+control entry,
the slot row occupying the full lower unit so the slots are exactly
128×128 rather than the control-line inset).

Unit math: the utility section drops from 11 units (header + 5×2) to 3
(header + row) — the full enemy entries list is now 41 units, max scroll
31. The windowing test's bottom window now lands on the last three gear
slots + the utility section + the skill row; a new test covers the
occupied/empty mix (blink in slot 1: skill button + icon at 128×128,
the other four diamonds) and the slot pitch.

### Inspector slice 9 — the player inspector (DONE, 9a + 9b)

9a — the player fallback target renders FULL content through the same
windowed pipeline as the enemy type. The six content emitters (text
field, swatches, toggle, weapon slot, gear slot, utility row) were
generalized onto an `InspectorEntityContext` — the resolved template +
the `EntityEditTarget` its commits carry + the team gradient — so both
targets share them; the Weapons/Gear entry lists were extracted into
`appendInspectorGearSections` (the enemy + player plans differ only in
their headers). Player content: "Player" header, READ-ONLY name line,
the shared gear sections, the utility-skill row, a read-only inventory
item count. NO Identity/Stats/sprite/color sections — base stats are
strictly enemy-authorable; the player template keeps its `player.txt`
stats. The interim player shell (slice 7) is deleted. Text-field refs
carry `.player_def`, so every commit routes to the player loadout
through the slice-7 `editorEntityEditTarget` mapping with zero new
event plumbing.

9b — the Import button (`import_editor_player` action →
`player_import_editor_player` → `editor_import_player`, handled INLINE
in processEvent next to `editor_set_active_level` because the
default-save read needs the reconstruction cache). The handler copies
the session's PlayerData loadout — exactly `build_player_from_data`'s
field set (name, gear, inventory, utility skills; PlayerData carries no
base stats) — as a DEEP copy via the generic `deepCopy` (the source's
name slices stay owned by their own graph). With no session data (the
detection: an empty `player_name` — a fresh editor launch has none,
every started/loaded game has one) it parses `data/new_player.txt`
through `readReconstructionFile` — the import event is recorded, so
replay re-reads the same bytes; the parsed default is a READ source,
the session's empty player_data is untouched. A `validatePlayerAction`
arm gates the orchestrator (editor screen + editor present). And
`instantiateEditorLevel` now keeps `player_def.template.inventory` for
entity 0 — the inventory is loadout data (imported or authored), not a
combat-runtime field; `resetRuntimeFields` still clears it for enemies.

Tests: the two panel tests re-windowed for the player content (the
import row shifts the unit math: 31 units, max scroll 21); a dedicated
player-content test (equipped loadout: Delete on the occupied hand,
item fields with `.player_def` refs, blink in the skill row, inventory
count 2); and two handler tests — the session-data import (fields
copied, undo reverts, redo + start_playtest carries the inventory into
entity 0) and the empty-session fallback (imports the real
`data/new_player.txt`: "New Player", Starter Sword, replenish; the
session's player_data stays empty).

### Playtest PlayerData — all skills learned + dormancy (DONE, TODO slice 9b)

Playtests now carry their OWN player_data. The seam that forced this:
`use_skill_tome` and skill-tome salvage read + mutate
`current.player_data` DIRECTLY during a level (not the entity), so a
playtest sharing the session's real data would corrupt campaign
progress — and an empty player_data (the fresh-editor-launch case)
would leave tome pickups writing into a ghost save.

`start_playtest` / `start_validation` (entering from `.edit` only — see
below) back the session's real data up onto the Editor
(`pre_playtest_player_data`, on the undo timeline with the rest of it)
and BUILD the run's from `player_def`'s loadout: the
`build_player_from_data` field set (name, gear, inventory, utility
skills) as deep copies, plus `learned_skills` = every utility skill —
learned is IMPLIED for the editor player (player.txt never carries it),
so tome pickups read already-learned and any learned-gated path is
permissive. `end_playtest` / `end_validation` restore the backup and
clear it (null backup = the fresh-session default, defensive).

The mode guard is the subtle part: a VALIDATION run chains its later
levels through `start_playtest` (end_level's exit guard) while
`editor.mode == .validate`, so the backup/build must fire only on the
`.edit` → run transition — a re-back-up mid-run would capture the run's
own mutated data and the campaign backup would be lost. The guard
piggybacks on the existing `if (editor.mode == .edit)` shape the mode
flip already used.

Tests: the playtest build (name from the loadout, learned = every
utility skill via `isSkillLearned`, the campaign backup held on the
Editor, a simulated in-level mutation, end_playtest restoring the
campaign data + clearing the backup) and the validation chain
(start_validation builds; a mid-run mutation SURVIVES the chained
level's start_playtest — no rebuild — and the backup still holds the
campaign data; end_validation restores).

### Slice 10 — save-shaped player.txt + max_player.txt (DONE)

player.txt is now SAVE-SHAPED: the loadout sections of a player save
(MainHandWeapon .. Boots, Inventory, UtilitySkills; version 2; no
Info/stats/hubs/clones/UnlockedSkills — base stats aren't authorable,
the template keeps the Entity defaults, learned is implied). The
save/loadout section parsing was EXTRACTED from loadPlayerSave into
`parsePlayerLoadoutFields` (shared by both loaders — the formats can't
drift), and `playerLoadoutEntity` maps the parsed PlayerData onto the
editor player template via the `build_player_from_data` field set. The
old `parseEntityDefinition`-based player.txt (with base stats +
PlayerLoadout section) is gone; a v1 file is rejected at the section
whitelist. All four mission player.txt files rewritten in the new
format (identical starter loadouts, so nothing shifts behaviorally).

`data/max_player.txt` — the maxed default, a full player save: the
five armor slots equipped at the max_* bounds, weapon slots + utility
bar EMPTY, two of each weapon type at max_weapon_damage in the
inventory (12 items), every utility skill learned, every hub in the
campaign discovered. It's the open_editor fallback (a mission without
player.txt — the custom/new-mission case), the future "start at
endgame" save, and the seed for new-mission creation. `new_player.txt`
stays as-is; both ship.

The open_editor load order: mission player.txt if present, else
max_player.txt — the fallback triggers on `error.FileNotFound`
SPECIFICALLY (readReconstructionFile propagates the FileSource error
verbatim, verified); a present-but-corrupt player.txt still errors
(fail-fast popup + revert) rather than silently becoming the maxed
loadout, so an authoring typo isn't masked.

Riding along: `loadPlayerSave` now PARSES DiscoveredHubs — the writer
emitted it since the save writer landed but no loader ever read it, so
hub discovery silently dropped on every save/load round trip (the
asymmetry surfaced because max_player.txt actually needs the section).
And a format gotcha worth remembering: UnlockedSkills/DiscoveredHubs
entries are BLANK-LINE-separated groups — consecutive `name x` lines
collapse into one group and the parser keeps only the first (the
initial max_player.txt shipped that way until the learned-count test
caught it: 1 instead of 7).

Tests: loadPlayerLoadout parses the new format (loadout fields, default
stats, name defaulting to "Player") + rejects v1; the shipped beginnings
player.txt loads; max_player.txt parses with every maxed property
asserted (equipped-at-max armor, empty hands + bar, the 12-weapon
arsenal at 2-per-type, 7 learned, 1 discovered hub, the
playerLoadoutEntity mapping); and an end-to-end open_editor fallback
test — a scratch-dir mission without player.txt (written through the
harness's own FileSource) yields the maxed player_def.

### Collapsible inspector sections (DONE, author request)

Every inspector section header is now an expand/collapse toggle: the
whole strip is clickable (panel + spriteless button + label, the
palette-group-header class), a "+ "/"- " marker prefix on the label
carries the state (ASCII — no arrow glyphs ship in the font atlas; art
can replace the marker later). ALL SECTIONS COLLAPSED by default — the
panel opens as a compact list of headers; the entries builders guard
each section's children on the expansion state, so the windowing, unit
math, scrollbar, and scroll clamp all adapt automatically.

State: `UiState.editor_inspector_section_expanded`, keyed by the new
`types.EditorInspectorSectionId` (identity / stats / weapons / gear /
utility_skills / inventory / player). The id — not the label string —
is the section's identity: the entries carry it, the label is a lookup,
and expansion is SHARED across the enemy + player contents (Weapons
expanded on an enemy stays expanded on the player). Independent
toggles, deliberately NOT the palette's accordion: sections are
per-topic and often wanted together (Weapons + Gear). A direct UiState
write in the options_action arm (`.toggle_editor_inspector_section` +
`AnytimeInput.clicked_editor_section`, payload riding the button like
`editor_group`) — off the undo timeline, the palette-accordion class.

Riding along on the payload plumbing: a `Button.editor_section` field
+ the main.zig release-dispatch filler, mirroring the editor_group
pattern exactly.

Known-harmless edge: collapsing a section while one of its text fields
is focused leaves the focus state live — the field isn't rendered, but
the commit path reads GameState (the field's target), so a keyboard
commit still lands correctly. Not worth auto-unfocusing.

Tests: a dedicated toggle test (default all-collapsed, expand via
handleAnytimeInput with the payload, independence, no event recorded)
and the default-collapsed rendering (headers only, 19 elements, "+ "
labels) in the panel test; every content test now seeds
`allInspectorSectionsExpanded()` (pub for main.zig's focus-on-click
test) and expects "- " prefixed section labels.

### The centered sprite picker — enemy base sprite (DONE, slice 6)

The picker framework's second consumer: the inspector's Sprite row (a
button showing the current stem — the interim v1 sprite-id TEXT FIELD is
removed, along with its TextFieldId arm, commit path, and text-field
tests) opens the centered picker with two TABS top-left (Mission /
Official, panel-backed, the active one highlighted; tab state is UiState,
reset to Mission on every open — custom assets take priority) and close
top-right. Dropdown semantics like the skill picker: blocks only where
it sits, stays open until a pick or close; picking commits through the
EXISTING `player_set_editor_entity_sprite` event (already on the undo
timeline + replay-validated), same-value picks close without recording.
The M2 arbitration treats sprite cells + tabs + close as picker
surfaces (commit + pick in one click).

**Official tab**: comptime from the sprite-metadata table's keys
(`entities/*` minus `entities/player` — the player body isn't an enemy
option; 9 shipped sprites), sorted via comptime insertion (a comptime
slice's elements are const — no in-place sort). Cells draw the sprite
aspect-fit at the 512×640 entity-frame convention, enemy-gradient tint
at the type's color_index, current highlighted.

**Mission tab**: a flat `.png` scan of the mission directory —
`FileSource.listPersistentPngFiles` (new; `openDir` needs
`.{ .iterate = true }` in 0.16 — iterating a default-opened dir is
Illegal Behavior and surfaced as EBADF). The scan runs at the
picker-OPEN site (idle input — interactive IO lives there, never in
view()/handlers), cached on `SessionState.editor_mission_sprites` with
the save_files ownership pattern (each scan frees the previous). A
picked `boss.png` in mission `artists_den` stores the namespaced stem
`custom/artists_den/boss` (no collision with official stems,
self-describing in the level file); resolution rule documented in
DESIGN (`custom/<mission>/` → the mission dir, else embedded
`entities/{stem}`). The art isn't renderable until custom-asset
rendering lands — mission-local cells show the stem as a text label.

`open_editor` now sets `editor.mission.path` (the payload-slice borrow,
same as start_mission) — the scan's source; empty for editors built
without a mission, degrading to an empty Mission tab.

Tests: a builder test (official: 9 cells, player excluded, bear
highlighted + its graphic; mission: namespaced payloads + text cells;
tab highlight) and a handler test (open → scan lands on SessionState
with the .txt filtered, tab reset; pick → namespaced id on the
timeline, one undo reverts; same-value no-op; tab switch + close).
Zig-notes along the way: `openDir(.{ .iterate = true })`, and an
assignment can't be an if-expression body in a switch prong.

### Decoration inspector (DONE)

The decoration tool's inspector surface — the sprite picker, world-
gradient color swatches, and the whole-definition commit with the
placement prune. Two commits: the verbs (events + validation + handlers
+ prune + handler tests), then the surface (target inference + content +
picker + input routing + tests).

- **Target resolution**: `EditorInspectorTarget` widened with
  `decoration_type` — the active decoration tool wins; under the select
  tool, decoration placements contribute their type (same defensive
  oor/stale posture as entities); enemy+decoration mixed → the player
  fallback. The input-side `editorEntityEditTarget` maps decoration →
  null (the entity controls don't render for it — callers bail on
  crafted clicks).
- **No name field**: a decoration's name IS its sprite path — the
  palette label (`id`) tracks `sprite` by handler invariant, so the
  superseded `editor_set_decoration_name`/`editor_set_decoration_sprite`
  per-field events were REMOVED rather than wired.
- **Event shape**: `editor_set_decoration_def` carries the whole
  definition (sprite, footprint, pixel_dims, color_index, layers),
  FLATTENED to top-level fields — the session-log reader can't regroup
  nested non-u8 slices (parseScalarTokens compileErrors by design), and
  the writer/reader pair round-trips top-level struct slices. The
  `editor_set_item_def` precedent. Color commits separately
  (`editor_set_decoration_color_index` — color never affects placement
  validity).
- **Prefab adoption**: an Official-tab pick = "loading a prefab" — the
  whole registry entry adopts (authored footprint, dims, color, layers —
  tree_1 without its canopy layer is half the art, and picking a tree
  with a ruin's color_index looks wrong). A Mission-tab pick stores the
  namespaced stem, resolves dims from the PNG IHDR at the commit site
  (a vanished/corrupt file commits nothing — the next open re-scans),
  and derives a default single-tile footprint at the sprite grid's
  bottom-left corner. Custom picks keep the current color + layers.
- **Placement prune**: the def handler deletes any placement of the type
  whose translated NEW footprint covers a level tile or another
  decoration's footprint — the `editor_place_decoration` invariant. The
  author's rule: never delete the things under the new footprint, delete
  the decoration itself. Entities/items are subsumed by the tile check
  (they always sit ON level tiles). Runs across every level; the
  selection is reconciled per removed active-level index (descending, so
  the remaps compose); one undo step covers retype + prune.
- **Registry residency**: `data/decorations.txt` loads onto
  `SessionState.editor_decoration_registry` at open_editor (gated
  `!replaying` — the registry feeds input/view only, like
  `editor_mission_sprites`), as an owned deep copy in the backing
  allocator (`loadDecorationRegistry` returns section-borrowed strings,
  so every string + array is duped before the event arena dies). A
  registry failure degrades to empty + popup — the editor stays usable,
  the Official tab shows "No sprites".
- **Picker routing**: one open action; the input site resolves the
  inspector target → `.entity_sprite` vs `.decoration_sprite` picker
  kind. The decoration Official tab lists the REGISTRY prefabs (not the
  raw assets dir — tree_1_canopy.png is a layer, not a base) with
  world-gradient tint; cells aspect-fit at each prefab's own dims
  (decoration art has no fixed frame convention, unlike the 512×640
  entity frame). `emitInspectorSpriteCell` gained action + frame params;
  the entity + decoration swatch/sprite-button emitters were
  parametrized (gradient, current value, action) instead of duplicated.
- **The empty-footprint gate already existed** — the placement planner
  no-ops on zero footprint tiles, so the "custom picks must stay
  placeable" concern was already handled by construction (the def
  handler ALSO defensively ignores an empty-footprint payload; no pick
  path can produce one anymore).
- Tests: handler tests (color commit + oor guard; whole-def adopt +
  id-tracks-sprite + one-undo revert; tile-overlap prune across two
  levels; other-decoration-overlap prune; selection drop + remap;
  crafted empty-footprint/oor no-ops), ui tests (decoration content
  labels + swatches + placeholder; picker registry cells + namespaced
  mission cells; inference: active decoration tool, selection inference,
  stale-id fallbacks), input tests (open routing, prefab adopt, same-def
  no-op via event-count, entity-picker gate; custom pick dims +
  bottom-left footprint via a minimal 24-byte PNG header + vanished-file
  no-op).

Why deferred (tracked in TODO → Level editor → the layer-editor item):
the footprint EDITOR UI (the placeholder row shows the tile count; the
event + prune helper are ready), custom-dims verification (any positive
IHDR accepted today), and the load-side resolution for
`custom/<mission>/` decoration stems (saving a custom-sprite decoration
produces a mission that panics on reload — part of the deferred
custom-asset acquisition slice; entities don't hit it because they carry
no pixel_dims).

### Layer editors (DONE)

The Layers sections for enemy + decoration types — the deferred "entity +
decoration layer editors" item. No player layers (the player loadout has
none — the section is enemy content only, and a player_def layer target
is rejected at the replay seam, the utility-skill posture). Two commits:
the verbs (six events + validation + handler tests), then the surface
(sections + picker modes + commit paths + tests).

- **The six verbs were already defined** — `editor_add/remove/set_entity_layer`
  + `editor_add/remove/set_decoration_layer` existed as panic-stub arms;
  wiring them was pure implementation. Layer-list mutation is
  copy-and-reassign through three tiny generic helpers
  (`layerListAppend/RemoveAt/ReplaceAt` over a `*[]const T` field — both
  Entity.layers and DecorationTypeDef.layers are `[]const`).
- **The dims invariant shaped everything**: the level parser PANICS on a
  decoration layer whose pixel dims differ from its base, so the editor
  must never author one. Three layers of defense: the picker's Official
  tab FILTERS to matching dims (mismatched art is never offered), the
  commit site resolves custom-stem dims from the PNG and a mismatch
  keeps the picker OPEN with nothing recorded (the pick visibly didn't
  take — better feedback than closing silently), and the handler +
  validatePlayerAction both reject mismatched payloads. Entity layers
  have no dims constraint (the fixed 512×640 frame) — no checks.
- **Authored layer colors**: a NEW decoration layer adopts a registry
  prefab's authored layer color when the picked stem is one (tree_1's
  canopy is color 2) — a registry-layers scan at the commit site, else 0.
  A re-pick KEEPS the layer's color (the weapon-retype semantics). A
  color swap commits the WHOLE layer via the set event (one event, one
  undo step).
- **Picker restructure**: `buildEditorSpritePicker` now takes the picker
  TARGET and resolves a four-way kind (entity/decoration × base/layer).
  The per-tab cell list became a per-frame `PickerCell` array (stored id,
  label, graphic, aspect-fit frame) — the old switch-in-loop couldn't
  express per-kind lists (registry prefabs / entity stems / dims-filtered
  decoration stems / namespaced mission files). A comptime
  `official_decoration_sprites` list (stems + dims from the metadata
  table; needed `@setEvalBranchQuota` for the comptime parseInt) feeds
  the layer-mode Official tab + its filter.
- **Stale-open posture**: the picker is a dropdown that stays open while
  the tool/target switches, so the builder treats a kind/target mismatch
  or out-of-range layer index defensively — base-tint, nothing
  highlighted, "No sprites" for the dims filter — and every pick no-ops
  at the commit gate (kind + target must match).
- Tests: handler tests (add/set/remove ordering + compaction, player
  target ignored, oor guards, dims-mismatch add/set ignored, undo), ui
  tests (the Layers sections' rows/swatches/add for both contents; the
  picker layer modes — entity stems with layer highlight, dims-filtered
  decoration cells), input tests (entity: add → color 0, color swap,
  edit re-pick keeps color, same-sprite no-op via event count, delete +
  undo; decoration: registry-authored color on add, custom pick dims
  from a 24-byte PNG header, mismatched custom pick keeps the picker
  open + records nothing, edit re-pick, color swap, delete).

Zig note along the way: comptime `std.fmt.parseInt` inside a comptime
build block needs an explicit `@setEvalBranchQuota` (the default 1000
backwards branches don't cover even ~23 table entries).

### Footprint editor (DONE)

The decoration inspector's footprint editor — the centered tile-grid
picker, replacing the read-only `<N> tiles` placeholder. One commit.

- **The picker**: a centered panel (`buildEditorFootprintEditor`, the
  `.decoration_footprint` kind on `EditorPickerTarget`) showing the
  type's sprite FULL-SIZE — 1:1, so one sprite-grid tile is a 256×256
  screen cell — with one invisible toggle button per cell. A continuous
  WHITE outline marks the draft-selected region: per boundary side (the
  neighbor across it unselected or off-grid) an 8px bar centered on the
  boundary — the editor's `region_edge` placement-preview outline,
  reproduced with `solid_rect` UI elements so corners join seamlessly
  for any shape. Custom-stem art isn't renderable yet — those cells get
  a dark fill so the grid stays visible. Confirm (bottom-center) +
  close (top-right, discard).
- **The draft** is transient view state, NOT GameState: a fixed 64-bool
  grid on UiState (`editor_footprint_draft` — 8×8 tiles / 2048px
  sprites; shipped art is 3×3 max), seeded from the current footprint at
  open, flipped per cell click (direct UiState writes off the undo
  timeline — the confirm is what records, the text-buffer model). The
  picker target CARRIES THE TYPE ID it was opened on: the panel, the
  toggles, and the confirm all address the stored id, so a mid-edit tool
  switch (the pickers are dropdowns — everything else stays live) can
  never silently retarget the user's in-progress draft.
- **Confirm semantics**: commit `player_set_editor_decoration_footprint`
  (row-major grid coords — canonical order, stable for serialization) IF
  the draft differs; unchanged closes without recording; an EMPTY draft
  stays open (the load-time invariant — a footprint must reserve ≥1
  tile, so the confirm visibly doesn't take).
- **The handler adopts + prunes**: an edited footprint re-anchors (the
  anchor is derived bottom-most-then-left-most, not stored), so a
  placement's world tiles can shift onto level tiles or other
  decorations exactly like a sprite retype — the def handler's shared
  `pruneDecorationPlacementsForType` runs, one undo step covering
  footprint + prune. Defensive guards (crafted logs): bad type id, empty
  footprint, tiles outside the sprite grid (the parser's
  footprint-in-bbox invariant) are ignored.
- Tests: handler (adopt + prune + one-undo, empty/oob/bad-type ignored),
  input (open seeds the draft + carries the type id, toggle flips +
  out-of-range no-op, unchanged confirm closes without recording, empty
  draft stays open, changed draft commits + undoes), ui (the panel:
  2×1 grid → 2 toggle cells, shipped-sprite graphic, a 4-bar outline
  around a lone selected cell; custom stem → 2 dark fills + a 6-bar
  block outline; the inspector row's open button).

Why the first handler-test draft failed (worth remembering): the prune
scenario used the 2-tall `tall_footprint` against the test editor's
512×256 type — a 2×1 grid — so the handler's out-of-bounds guard
correctly rejected it. The guard isn't test friction; it's the parser's
footprint-in-bbox invariant doing its job. The scenario was rebuilt on
a 512×512 (2×2-grid) type.

## Level editor settings sidebar — slice 1: gradient-override model

The settings sidebar's data model (the slice that DESIGN → Level Editor →
Level theme called for): the per-role gradient overrides land and the dead
`CustomColorTheme` scaffolding goes.

- **Removed:** `types.CustomColorTheme`, the `custom_theme` fields on
  Level/EditorLevel/Hub, and `editor_set_level_custom_theme`. The
  scaffolding was never wired (nothing outside types.zig/events.zig read
  it) — the index model supersedes it by design.
- **Added:** `enemy_gradient_index` / `player_gradient_index: ?u32` on
  Level + EditorLevel (null = auto-derive). Level-file Metadata keys
  `enemy_gradient_index` / `player_gradient_index` (absent/unparsable =
  null); a level-only metadata key list in parser.zig (the shared
  `level_metadata_keys` is used by settings/saves/themes too, so the keys
  can't go there — hubs + those types never carry them). Hubs keep
  wheel-only derivation.
- **`deriveActiveColorTheme`** now takes the two optional overrides
  (modulo-wrapped like the world index); `activeThemeFor` threads them
  from the live level / the editor's ACTIVE TAB — so the editor viewport
  now previews the active level's full theme (enemy/player tinting
  included), not just the world gradient.
- **Events:** `editor_set_level_enemy_gradient` /
  `editor_set_level_player_gradient` (null payload = revert to auto) +
  the five settings-sidebar player wrappers
  (`player_set_editor_mission_name` / `player_set_editor_level_name` /
  `player_set_editor_level_color_wheel` / the two gradient wrappers).
  Handlers for all five EditorEvent arms (level-index guards match
  `editor_set_level_end`'s panic convention); thin player-arm forwards;
  `validatePlayerAction` arms (editor screen + level-index bounds via a
  shared `validateEditorLevelMetadataCommit` helper — the multi-variant
  switch capture doesn't typecheck across the different payload structs,
  so it's four one-line arms).
- The session-log writer/reader + deep_copy are comptime-generic over the
  Event union, so the new events + the removed one needed no serializer
  edits.
- Tests: derive (auto spacing + overrides + wrap), level-file parse
  (override keys, absent keys, loadLevel → buildEditorMission →
  instantiateEditorLevel round trip), handler (all five commits via the
  wrappers, null revert, five undos walk back to the start).

## Level editor settings sidebar — slice 2: shell + name fields

The right-bar shell + the mission/level name fields (see DESIGN → Level
Editor → Editor UI layout → Settings sidebar).

- **Toggle:** `Editor.settings_sidebar_open` (open by default, the
  inspector's convention — on the Editor so the toggle rides the undo
  timeline + replay reproduces it) + `editor_toggle_settings_sidebar` /
  `player_toggle_editor_settings_sidebar` + handler + validatePlayerAction
  arm + `.toggle_editor_settings_sidebar` Action routed through
  `options_action`. Button: top-right, at the inspector toggle's height,
  flush to the right screen edge, the inspector toggle's visual class.
- **Panel:** `editorSettingsSidebarPanelRect()` — the inspector rect
  mirrored to the right edge (width 1024 placeholder, same top/bottom
  bounds); darkest-tinted background. Single source for layout + the M2
  press arbitration, like the inspector's.
- **TextFieldRef widening:** `TextEditTarget` union
  (`entity: EntityEditTarget` / `mission` / `level: u32`) replaces the
  bare `EntityEditTarget` on `TextFieldRef.target`; new ids
  `.mission_name` / `.level_name`. The level index rides the target so a
  mid-edit tab switch can't retarget the commit (the commit addresses the
  tab the field was focused on). Fallout: the commit/focus sites
  (input_handlers), `Entity.textFieldValue` (exhaustive-switch arms
  returning ""), `textFieldIsNumeric` (the new ids are non-numeric), the
  ref constructions + tests. `emitInspectorTextField` refactored: the
  element construction extracted into a shared `emitTextFieldUi` (ref +
  current value params) so the sidebar's name fields reuse it.
- **Content:** Mission section (plain strip + name field) + Level section
  (plain strip + name field, the ACTIVE tab's). Strips are the
  group-header visual class but NOT collapsible (two fixed sections); the
  field entries use the inspector's two-unit geometry (label line above,
  paper-strip control below).
- **Commits:** `commitFocusedTextEdit` arms — would-change gates (same
  value records nothing), out-of-range level index commits nothing (a
  stale focus), `queueSound` on real commits.
- **M2 arbitration:** `textEditPressProceeds` takes the sidebar's open
  state + rect too (a press inside the open sidebar, or on its toggle,
  proceeds after committing — the sibling-control rule).
- Tests: handler (toggle + undo), input (mission + level commits
  end-to-end through routeTextInput/resolveTextEditOutcome, one undo per
  commit, no-op gate, stale-index no-op), ui (toggle always + flush
  right, panel only when open + the shared rect fn, both fields with the
  right refs + seeded names, active-tab targeting).

## Level editor settings sidebar — slice 3: gradient rows + theme picker

The Level section's three gradient rows + the centered theme picker (see
DESIGN → Level Editor → Level theme + Editor UI layout → the centered
panels note).

- **Rows:** SINGLE-LINE (the settings-screen row pattern — role label,
  then the Auto button, then the swatch) because the inspector's
  two-unit field-entry geometry overflows the panel bottom by ~2 rows
  (1248px used of 1328 with single-line rows). The swatch is the
  EFFECTIVE gradient (the active theme already resolves it from the
  active level's settings — no re-derivation in the builder); the whole
  strip is ONE invisible button (`.open_editor_level_gradient_picker`,
  role payload). The enemy/player AUTO buttons are highlighted while
  deriving; a click while manual commits the null revert, while auto is
  a no-op (the same-value-picks-never-fire rule).
- **Theme picker:** the `.level_gradient` EditorPickerTarget (level
  index + role snapshot at open — the footprint editor's
  mid-edit-can't-retarget convention) + `buildEditorThemePicker`: one
  bare full-width strip per gradient, close top-right, dropdown
  semantics. The current index (world = the wheel index; enemy/player =
  the override, or the DERIVED index while auto) gets a visible
  lightest 8px frame — Button.highlighted still renders nothing (the
  tracked TODO). `loaders.autoDerivedGradientIndex` extracted as the
  single source of the spacing rule (deriveActiveColorTheme refactored
  onto it).
- **Input:** three options_action arms — open (UiState picker write),
  pick (routes by role to the slice-1 player wrappers; same-value picks
  close without recording; an auto-role pick flips to manual in the same
  commit — null→index records even when the derived gradient was
  visually identical), Auto (null revert, no-op while auto). Payloads:
  `editor_gradient_role` / `editor_gradient` Button fields folding into
  `AnytimeInput`.
- Tests: picker interaction end-to-end (open target snapshot, per-role
  commits, auto flip + revert, no-ops proven via event_history LENGTH —
  runToIdle's idle points don't dedupe, so undo-step counting can't
  distinguish a dead step from a duplicate point at an unchanged state),
  picker builder (strips, frame on the current row, derived-index
  highlight on an auto role), sidebar row shape (label column, narrowed
  enemy/player swatches, highlighted Auto buttons).

## Level editor metadata sidebar — slice 4: mirror the inspector UI (author request)

The author playtested slice 3 and asked for the sidebar to mirror the
inspector exactly, plus renames. Changes:

- **Renames:** "Settings" → "Metadata" everywhere (the toggle button's
  label, `Editor.metadata_sidebar_open`, `editor_toggle_metadata_sidebar`
  / `player_toggle_editor_metadata_sidebar`, the
  `.toggle_editor_metadata_sidebar` action, the builder + rect fns), and
  the second section's header "Level" → "Current level".
- **Collapsible sections:** the two sections ride the inspector's shared
  machinery — `EditorInspectorSectionId` grew `.mission` /
  `.current_level` (one expansion-state array, one toggle action, one
  label lookup — the section-id-keyed model), so the strips are
  `emitInspectorSectionStrip` verbatim: +/- marker, whole-strip click,
  COLLAPSED by default, view-affordance state off the undo timeline.
- **Windowed content + scrollbar + wheel:** the content is now the
  inspector's exact model — a per-frame `EditorMetadataEntry` list over
  the expansion state, unit math (section/spacer = 1, field entries = 2),
  view-relative windowed emission (only fully-visible rows),
  `UiState.editor_metadata_scroll` clamped authoritatively in the
  builder, the inspector's scrollbar geometry, and a wheel-routing branch
  over the open panel rect in handleAnytimeInput. Replaced the
  hand-rolled cursor layout (which had hardcoded the no-overflow
  assumption — both sections expanded overflow the panel by ~3 rows,
  which is exactly what the windowing exists for).
- **Gradient rows back to two-unit entries** (the slice-3 single-line
  rows were a workaround for that overflow): the role label line above,
  AUTO toggle + full-gradient swatch on the control line below — the
  inspector's field-entry convention, per the author's "swatches on
  their own line below the descriptor".
- Tests: the sidebar builder test rewritten for the model (collapsed
  default = two headers only; expanded = windowed rows + scrollbar;
  scrolled-to-bottom windowing), a metadata wheel-routing test, the
  section-count assertions updated (9 → 11 sections).

## Level editor — the fixed picker overlay (author request)

The author asked for all pickers to render as a centered overlay that
"fits exactly between the two sidebars, full height of a sidebar, full
width minus the panels minus the ui_gaps" — mirroring the gameplay
middle-panel band — with fixed-size contents.

- **`ui.editorPickerOverlayRect`**: the ONE fixed rect every centered
  picker renders in — x = sidebar width + ui_gap, full sidebar-panel
  height (416..1744), width 3840 − 2×1024 − 2×16 = 1760. CONSTANT:
  independent of the sidebars' open state AND of the picker's content —
  pickers no longer size their panel to their rows (the old skill/sprite
  pickers computed width from column count; the theme picker was
  hardcoded 2048; the footprint editor sized to the sprite).
- **Contents stay FIXED-SIZE**, centered in the area below the header
  (top-aligned when they outgrow it): skill + sprite pickers are
  6-column grids of `slot_size` cells (was 4 — the wide overlay earns
  two more columns per row); the theme picker's gradient strips are
  fixed 6 × `slot_size` (1536×256) rows; the footprint editor keeps 1:1
  for whatever fits and SCALES DOWN (never up) for oversized custom art
  (cells + image + outline all at the scaled tile; the earlier draft
  left the toggle buttons at 256 — caught on review), Confirm pinned
  bottom-center of the overlay.
- Tests: the skill-picker/theme-picker/footprint tests assert the
  overlay rect verbatim (the panel IS `editorPickerOverlayRect`), the
  fixed strip size, 1:1 for small sprites, and a 4096×256 sprite scaling
  to 108px cells.

## Level editor metadata sidebar — small author revisions

- **Closed on editor open** (`Editor.metadata_sidebar_open` defaults
  false): the metadata is a reference panel, not the first thing an
  author needs — the inspector stays open-by-default (auto-open-on-new-
  type behavior lives there). The wheel-routing test now opens the panel
  explicitly; the toggle test's expectations flipped.
- **Row renames:** "World" / "Enemy" / "Player" → "World colors" /
  "Enemy colors" / "Player colors" (the gradient rows' labels), and the
  theme picker's title follows ("Pick World colors" — was "Pick World
  Gradient").

## Level editor metadata sidebar — the two-way Auto toggle (author request)

The Auto button was one-way (manual → revert; auto → no-op) and the
author wanted a true toggle with the outline following the mode:

- **Auto → manual now commits**: the toggle FREEZES the currently-derived
  index as the explicit override (visually identical — the point is the
  mode change; a later pick replaces the frozen index). Manual → auto
  keeps the null-revert. Both directions are always real state changes,
  so both record one undo step.
- **The outline marks the mode:** the AUTO button stays outlined while
  deriving; when manual, the SWATCH button is outlined instead (the
  backend's lightest stroked rect for highlighted spriteless buttons —
  the same mechanism that was drawing the Auto outline). The world row's
  swatch is ALWAYS outlined (its index is always an explicit pick —
  there's no Auto state to carry the outline).
- Tests: the input test's auto-while-auto case now expects the freeze
  (derived index 0 at wheel 2 / 3 gradients) + one undo; the sidebar
  builder test covers both outline modes (enemy auto → Auto outlined,
  player manual → swatch outlined) and the always-outlined world swatch.

## Level editor item inspector (the Items palette group) — slice 12

The bottom-bar "Ground Items" group renamed to **Items**, and the
inspector grew its item-type content (the third real target arm —
`EditorInspectorTarget.item_type`):

- **Target resolution**: the active item tool + selected ground-item
  placements now resolve to their palette type (the defensive
  stale-index/stale-type-id fallbacks mirror the entity/decoration
  arms); two distinct referenced types still fall back to the player.
  The selection-inference tests were updated (a lone ground item used to
  assert the player fallback).
- **Content** (`editorInspectorItemEntries`): one collapsible "Item"
  section (`EditorInspectorSectionId.item`) — a "Type" label + TWO pick
  rows (the six weapon types, then the five non-weapon kinds; SKILL TOMES
  EXCLUDED — not authorable in the level-file `Items` section, the
  coupling contract), then the Name field + one numeric field per stat
  the kind carries (`itemStatSet`; `itemTextFieldValue` is the item
  content's single value source — display, focus seed, would-change —
  mirroring `Entity.textFieldValue`). Item content tints with the PLAYER
  gradient, matching the palette group. The pick cells reuse the
  weapon-slot visual class (`ui/item_slot` + `items/<type>` icon).
- **Reset-everything pick semantics (author decision)**: any pick that
  differs from the current item replaces it with "New <Kind>" (weapons:
  "New <WeaponType>") zeroed stats — NO retype-keeps-identity case
  (deliberately unlike the entity weapon slots); an identical pick never
  fires. Routed via the new `Action.select_editor_item_type` with the
  kind on `AnytimeInput.clicked_editor_item_kind` (+ the existing
  weapon-type field on weapon cells).
- **Events — `editor_set_item_def` redefined FLATTENED**: the previously
  defined-but-unhandled event carried a nested `Item`; its name string
  can't round-trip the session log once it contains a space (nested
  strings serialize as one space-separated token — see the new TODO
  tech-debt item for the pre-existing instances of this bug class). The
  redefined event (and its `player_set_editor_item_def` wrapper) carries
  kind + weapon_type + name + the seven stat fields at top level — the
  `editor_set_decoration_def` precedent. Name commits ride
  `editor_set_item_name` (a top-level string, spaces fine). Both got
  handlers (the def handler clamps stats to the `max_*` bounds so the
  editor never holds a state its own load path would clamp away, and
  syncs the palette label `id` to `itemDisplayName` — the
  decoration id-tracks-the-sprite rule) + validation arms
  (`validateInspectorItemEdit`).
- **Text-field machinery**: `TextFieldId` += `item_def_name` /
  `item_def_stat`, `TextEditTarget` += `item_type` (the palette index
  rides the ref so a mid-edit tool switch can't retarget the commit);
  commit arms + `beginFocusedTextEdit` seeding + the digits-only filter
  follow the entity-field pattern.
- **Tests**: target resolution (item arms + stale-id fallbacks), content
  emission (11 pick cells, payloads, highlights, name/stat fields, the
  per-kind field set, the defensive bare-rows tome case), pick handlers
  (reset + no-op + undo + id tracking), text commits (end-to-end +
  no-op gates + clamp), the handler's out-of-range/clamp guards, and a
  session-log round-trip case locking the flattened multi-word name
  ("New Sword" as a top-level `name` line).

## Session-log nested-string fix — the unified equipped-slot event

The item-inspector slice surfaced a pre-existing bug: the session-log
serializer flattens NESTED struct/union fields as space-separated tokens,
so a string inside a nested payload can't contain spaces — and the
equipped-slot commits (`player_set_editor_entity_main_hand_weapon` etc.)
carried `?Weapon`/`?Amulet`... whose names routinely do ("New Sword", the
weapon-slot create default). Writing such an event produced a log that
`loadEventLog` rejected as malformed (`name="New"`, then `"Sword"` fails
the weapon_type enum parse) — only reachable via `--replay` / crash-dump
restore, so it sat unnoticed.

**The fix — unify, don't per-variant-flatten.** Instead of flattening each
of the 14 variants (7 editor + 7 player) in place, they became ONE
slot-parameterized pair — `editor_set_entity_gear` /
`player_set_editor_entity_gear` — sharing `EntityGearPayload`
(`target`, `slot`, `equipped`, then the item's fields FLATTENED:
`weapon_type`/`name`/the seven stats, defaulted; `equipped: false` = the
Delete/clear). This is the exact `editor_set_item_def` /
`editor_set_decoration_def` whole-definition shape the codebase had
already converged on — the per-slot variants were the last per-field event
family. Net: 14 event definitions → 2, one handler arm (rebuilds the
slot's item with the `max_*` clamps, the item-def posture), one
validation arm, a verbatim forward in the orchestrator (shared payload
type), and the input side's 7-way `editorSlotItemAction` switch +
`editorSlotClearAction` deleted in favor of one `editorGearSlotAction`
(null item = clear; kind-vs-slot mismatch records nothing, the old gate).
`types.gearSlotItemKind` is the slot→kind single source.

Old logs are unreadable after this (the variants are gone) — free
pre-release: session logs are session-scoped, none persist.

Tests: the session-log round-trip case now carries the exact payload that
used to break reload (a multi-word weapon name through
`player_set_editor_entity_gear` + an `equipped false` clear) with
write→parse→load→deep-equal; the null-optional-omits assertion was made
precise (adjacency-scoped to the use_skill pair — the bare `\ntarget `
count can't prove it with more target-carrying events in the log). All
existing slot-path handler tests pass unchanged (they assert template
state through the input path, not event shapes).

Remaining instance of the class (filed in TODO → Tech Debt): the LAYER
events carry a nested `sprite` string — only breaks if a mission
directory name contains a space (the `custom/<mission>/<stem>` namespace),
low risk until custom-mission acquisition lands.

## Session-log string safety — the layer events + the indexed slice encoding

Follow-up to the equipped-slot fix, completing "spaces in mission
directories / custom asset stems":

- **The layer events flattened**: the eight layer-carrying variants
  (`editor_add/set_entity_layer` + `editor_add/set_decoration_layer`,
  editor + player layers) dropped their nested
  `layer: EntityLayer/DecorationLayer` payload for top-level
  `sprite` / `color_index` (+ `pixel_dims` on decoration) — the
  `editor_set_entity_gear` pattern. Handlers/validation/input sites
  rebuild or read the flattened fields;
  `validateInspectorDecorationLayerEdit` now takes the dims directly.
- **The def event's `layers` slice — the case flattening can't cover**: a
  slice of structs with sprite strings has no top-level flatten (the
  token stream can't regroup variable-length strings at all), and a
  custom base-sprite pick commits the type's CURRENT layers — which,
  after the layer fix, can carry space-y custom stems. The serializer
  gained the INDEXED multi-line encoding for exactly this class
  (`isStringBearingStructSlice` comptime-detects it):
  `layers_count 2` + `layers_0_sprite custom/My Mission/canopy` +
  `layers_0_color_index 2` + `layers_0_pixel_dims 512 768` + … — each
  string on its own line. Writer (`writeIndexedSliceField`) and reader
  (`parseIndexedSliceField`) mirror each other;
  `appendEventScalar` compile-errors if a string-bearing slice ever
  reaches the one-line path, and the indexed writer compile-errors on
  elements nested too deep to encode — the class is structurally closed.
  The def event keeps its atomic one-event/one-undo shape (the
  alternative — splitting layer re-authoring into orchestrator children —
  would have needed a registry read inside a handler, breaking
  cross-session replay purity: the registry is session-resident and
  empty during reconstruction).
- **Tests**: the session-log round-trip now carries space-y payloads
  through every path — a layer event with
  `custom/My Mission/canopy`, and a decoration def whose `layers` slice
  mixes a space-y custom stem with an official one — write → parse →
  load → deep-equal, plus exact output-line assertions for the indexed
  encoding. The layer handler tests were reshaped onto the flat payloads
  (same coverage: order, dims-match invariant, crafted-log guards).

The standing rule (TODO → Tech Debt + DESIGN → Logging & Replay → String
safety): strings inside single nested values flatten to top level;
string-bearing struct slices take the indexed encoding; the comptime
guards enforce both for future events.

## Level editor — the palette "+" cells (add-new type)

The three bottom-bar palette groups' "+" cells are wired: clicking one
appends a new type to that group built from the SHIPPED DEFAULTS, makes
it the active tool, opens the inspector, and (enemies + decorations)
opens the base-sprite picker on the new type. Three slices:

- **data/editor_defaults.txt (new shipped file)**: one entry per kind in
  the level-file section formats (Enemies / Decorations / Items entries,
  no character_code — the data/decorations.txt precedent; no Layout —
  nothing is placed). Author decision: the decoration default DUPLICATES
  the stone_1 prefab (footprint 0 0, color 5) rather than referencing
  the registry — the defaults file is self-contained, mirroring the
  level config exactly. Parsed by the new `loaders.loadEditorDefaults`:
  the enemy via the shared `parseEntityDefinition` (team 1; the absent
  keys are exactly the "no weapons / gear / utility skills / layers"
  defaults), the decoration via the shared `parseDecorationEntry`, the
  item via `parseItemEntry` — EXTRACTED from loadLevel's inline Items
  parse so level files and the defaults file share one code path.
  Validation reuses the level key map + a new `editor_defaults_sections`
  whitelist (the level sections minus Layout) + its own
  `editor_defaults_file_format_version` (1). A missing section or entry
  is `error.MissingDefaultEntry` — the file is shipped content, so a
  missing default is a content error surfaced at the read site, never a
  silent fallback.
- **Events + handlers**: three thin player wrappers
  (`player_add_editor_*_type`, void payloads) → the existing
  `editor_add_*_type` events, handled INLINE in processEvent
  (`addEditorPaletteType` — the `editor_import_player` pattern) because
  the defaults read needs the reconstruction cache: the add events are
  recorded, so replay re-reads the same bytes and reproduces the
  creation. A read/parse failure takes the recoverable in-event-read
  path (`failReconstructionRead` → revert + popup). The handler appends
  the type, sets the active tool to it (carrying the `editor_set_tool`
  selection-clear invariant), and opens the inspector — one undo step
  reverts the whole creation. `validatePlayerAction` arms: editor screen
  + editor present.
- **UI + input**: the "+" cells are buttons now (spriteless over the
  `ui/panel` cell, the group-header visual class) carrying the new
  `Action.add_editor_palette_type` + the group index on the EXISTING
  `editor_group` payload — main.zig's release dispatch needed no change.
  The input arm pushes + drains the per-kind orchestrator, then opens
  the base-sprite picker for enemies (`.entity_sprite`) and decorations
  (`.decoration_sprite`) — mission rescan + Mission-tab-first, the
  inspector Sprite row's open path; the picker's commit targets the new
  type through the active tool the handler set. Items open nothing (no
  sprite to pick). Any already-open picker CLOSES first: the tool switch
  retargets the inspector, so a stale picker is a mismatched-target
  hazard. The add-level "+" stays inert (its own TODO).
- **Tests**: a shipped-file loader test (the registry-test read-the-real-
  file pattern — guards the file against drift, asserts every default
  field), loader error paths (missing entries / version gate /
  unexpected section), handler tests (per-kind creation + defaults +
  tool + inspector + undo; auto-open from closed + the selection clear),
  and the anytime-input arm end-to-end (creation + per-group picker
  routing + the stale-picker close + the crafted out-of-range group
  no-op).

## Level editor — palette tool-cell delete buttons

Every palette tool cell (the Enemies / Decorations / Items groups — not
the fixed Select/Tile tools) carries a small delete button flush in its
top-right corner: the shared close-button visual (`ui/close_button`,
80×80 — the picker-panel / in-game middle-panel close class). Clicking it
deletes the palette type AND every placement referencing it across ALL
levels (the palette is mission-shared). Two slices:

- **Events + handler**: the wrapper `player_delete_editor_type
  { type_kind, type_id }` → the previously-defined-but-panicking
  `editor_delete_type`, now handled in `handleEditorEvent` as the
  editor set's one orchestrator: it fans out into
  `editor_delete_*_placement` sub-events for every referencing
  placement (pushed ascending, so the LIFO stack processes them
  high-before-low within each level — every planned index is valid at
  its turn; the arms own the order-preserving removal + the
  active-level selection prune/remap), then removes the type
  (`layerListRemoveAt` on the palette array), decrements every
  same-kind placement type_id above it (palette indices shift down),
  and reconciles the active tool (the deleted type → `.select`; a
  higher same-kind index → decremented — a dangling tool pointer is
  never created). All the events share the player action's idle point:
  ONE undo step restores the type, every placement, the tool, and the
  selection. `validatePlayerAction` arm: editor screen + editor + type
  id in range (the handler ignores out-of-range ids defensively — the
  `editor_set_tool` posture).
- **UI + input**: `emitEditorToolDeleteButton` after each palette
  `emitEditorToolCell` — emitted AFTER the cell so hit-testing
  (last-wins) prefers it where the two overlap; carries the new
  `Action.delete_editor_palette_type` with the cell's tool on the
  EXISTING `editor_tool` payload (no main.zig change, the
  `editor_group` trick again). The input arm maps the EditorToolId →
  (kind, id) and pushes + drains; a crafted select/tile-targeted click
  does nothing (the fixed tools have no delete button).
- **Tests**: handler tests per kind (multi-level placement removal, id
  remap, active-tool reset + decrement, selection prune, one-step undo,
  out-of-range guard), the input arm end-to-end (delete + undo + the
  fixed-tool no-op), and the bottom-bar emission test (per-cell delete
  button with the close visual, flush top-right, tool payload).

## Level editor — level-tab × buttons + the wired add-level "+"

Level management is wired: the top-bar "+" appends a new level from the
shipped template and switches to it; each level tab carries a × (the
shared `ui/close_button` class, flush top-right) that deletes the level.
The template `data/default_level.txt` was authored in the same slice —
it was specified in DESIGN since the beginning but never written. Two
slices:

- **Template + handlers**: `data/default_level.txt` is the minimal `!=`
  layout ('!' at (0,0), '=' at (1,0)) — the markers carry their own
  ground (the layout walk tiles under '!' and '='; DESIGN's "no floor"
  means no ADDITIONAL floor), unnamed so a new tab reads "Level N".
  `loaders.loadEditorDefaultLevel` wraps `loadLevel` with a STRICT
  template contract: a level end must be present and no
  enemies/decorations/items may be authored into it (placements belong
  to the palette + viewport — anything more is a content error surfaced
  at the read site, never silently dropped). `editor_add_level` is
  handled inline in `processEvent` (the `addEditorPaletteType` pattern:
  reconstruction-cache read, recoverable failure → revert + popup);
  it appends the level, SWITCHES the active tab to it (the author lands
  on the thing they just created), clears the selection
  (the `editor_set_active_level` semantics), and syncs
  `mission.level_count = levels.len`. `editor_delete_level` lives in
  `handleEditorEvent`: order-preserving removal + level_count sync +
  active-tab adjustment (a delete below shifts the tab down; deleting
  the ACTIVE level clamps + clears the selection). Its guards PANIC
  (fail-fast): the ≥1-level invariant is the event's documented
  contract, and the UI, the input layer, and `validatePlayerAction`
  (screen + editor + index range + ≥1 level) all gate it first — a
  crafted log that reaches the panics has bypassed three gates.
  One undo step reverts each operation (the delete restores levels,
  tabs, and selection).
- **UI + input**: the × per tab (only while `levels.len > 1` — a
  mission always keeps ≥1) with the tab index on the EXISTING
  `editor_level` payload (no main.zig change, the established trick);
  the "+" cell is a button now (`.add_editor_level`, spriteless over
  the panel). The input arms push + drain the orchestrators; the
  delete arm re-gates (single-level or out-of-range → no-op) so a
  crafted click can never reach the handler's invariant panic.
- **Tests**: the add handler (template shape asserted field-by-field —
  one correction mid-flight: the test first asserted "no floor tiles"
  but the markers carry their own ground, so the minimal layout has
  exactly the two marker tiles), the delete handler (all three
  active-tab adjustment cases + level_count + selection + two-step
  undo), the input arms end-to-end (add → switch, delete → shift, the
  single-level gate), and the tabs emission test (× per tab with
  payload/visual/flush position, no × on a single-level mission, the
  "+" as a button).

## Level editor — fresh-mission open (the main-menu Editor button)

The main-menu Editor button no longer opens the hardcoded `beginnings`
mission — it opens a FRESH empty mission:

- **Payload**: `open_editor.mission_path` became `?[]const u8` — null =
  fresh mission, a path = open that mission directory. The path-open
  branch is intact (no UI reaches it yet — the deferred mission browser
  will — and the beginnings round-trip test keeps exercising it). The
  session-log generic serializer already handles `?[]const u8`
  (present-writes / absent-reads-null).
- **Mission identity (uuid) — settled with the author, deferred
  implementation**: the uuid is NOT generated at open (the first design
  — uuid at the input site riding the payload — was rejected: no newly
  randomly generated things held in state, ever). Mission uuids are file
  content; identity is minted at SAVE time, which is gated `!replaying`
  so randomness is safe there. The mint is WRITE-ONLY (never written
  back into GameState — a random value in state diverges from the
  replayed log; `verifyReplayMatch` would catch it), read-modify-write
  preserves an existing file's uuid across repeated saves, and a renamed
  mission saves into a NEW directory. Recorded in DESIGN → Level Editor
  → Mission identity; lands with the save-to-disk slice. Empty-uuid
  sessions are safe: the only runtime consumer of `mission.uuid` is the
  clone keying in the end_mission / mission-complete paths, which the
  editor's exit guard redirects before they run.
- **Fresh shape**: `New Mission` at `missions/New Mission`
  (persistent-dir-relative — anchors the sprite picker's mission-local
  scan + the `custom/<mission>/` stem namespace; a missing dir scans as
  empty, and an author can drop pngs there pre-save), one
  default-template level, empty palettes, `player_def` seeded from
  `data/max_player.txt` (the settled load-order fallback).
- **Refactor**: `readEditorDefaultLevel` (the template read, shared with
  addEditorLevel) + `loadMaxPlayerLoadout` (the max-player fallback,
  shared with the path-open's missing-player.txt branch) extracted in
  event_handlers.zig; the fresh branch is `openFreshEditorMission`.
- **Tests**: a fresh-open round-trip test in main.zig (mission shape,
  template level field-by-field, empty palettes, max-player seed name,
  playtest instantiation of the bare template level, close round-trip).

## Level editor — save + export (the mission writer)

The editor can save its mission to the persistent dir and export it as a
.zip. Three slices, all landed:

- **The pure writer (writers.zig)**: `writeEditorMission(editor, uuid,
  allocator)` — the inverse of the load path, deterministic and
  side-effect-free. mission.txt (uuid + name + level_count; the hub
  fields stay unloaded/absent — the loader treats them as optional),
  player.txt (the PlayerLoadout format; the loadout-section emitters were
  EXTRACTED from writePlayerSave into a shared `writeLoadoutSections` —
  one vocabulary, two files), and one level_N.txt per level. Per level:
  the layout is TRANSLATED to the bounding box over everything placed
  (tiles, placements, whole decoration footprints, '!', '=') with each
  row trimmed to its own last used column — the written grid is minimal,
  and positions shift by the translation on reload (the in-memory editor
  is untouched; only the file is normalized). Tools get PER-LEVEL char
  codes (a level file only defines the tools it places — an enemy that
  only appears in level 2 is absent from level 1's file): assigned in
  palette order from digits → lowercase → uppercase → remaining
  printable ASCII (91 codes; '!', '.', '=', ' ' reserved); a level
  needing more fails the write with `error.TooManyLayoutCodes` (surfaced
  as the recoverable popup). Enemy/item chars imply their tile on reload
  (the parser tiles under them — one char per cell round-trips); a
  decoration's code sits at its anchor only, the footprint stays
  tile-free. Tests are self-referential round-trips through
  `buildEditorMission` with a SEMANTIC compare (reload dedup rebuilds the
  palette in layout-encounter order, so palette order/type-ids are
  compared as definitions + translated positions, not deep-equal) —
  including exact-layout-line assertions and the code-exhaustion
  boundary. Mid-flight fixes worth remembering: a fixture fn returning
  an Editor borrowing its own locals (dangling palette pointers → garbage
  strings in the writer's output; the fixture became a file-scope
  comptime const), and Zig 0.16 has no `{c}` format specifier (a u8
  prints as a 1-byte slice with `{s}`).
- **The save (input_handlers.saveEditorMission)**: uuid resolution per
  the settled identity rules — opened-from-disk → in-memory uuid, else
  the SESSION MEMO (`SessionState.editor_saved_mission` — this session's
  last save's uuid + dir; re-saves reuse it so identity never churns),
  else a v4 mint (CSPRNG seeded from the wall clock — never enters
  GameState). Target dir ALWAYS `missions/<uuid>_<sanitized name>/`
  (rename → new dir; official mission → persistent-dir copy). The save
  is the DUMP_EVENT_LOG class, not the save_game class: a pure
  input-layer side effect with NO recorded event — there is no GameState
  component to record, an event would mint dead undo steps (the bug
  class the same-level-tab fix addressed), and replay never runs the
  input layer. Wired to ctrl+S (a shipped binding — KeyS was already in
  the backend key table) + the options menu's Save Mission button (the
  editor context's replacement for the hidden Export Save). Failures
  take the recoverable popup path.
- **The export (input_handlers.exportEditorMission + zip_writer.zig)**:
  save first (the bundle is always the current state), then bundle the
  saved configs + the CURRENT mission dir's custom sprites (a fresh
  mission's pre-save pngs sit in the placeholder dir — they bundle even
  though the save writes elsewhere) + a validation_replay.txt when one
  exists (the file itself lands with the validation slice) into a
  STORE-method zip — std.zip has no writer in 0.16, so zip_writer.zig is
  a hand-rolled ~100-line local-header/central-directory/EOCD writer
  (Crc32, UTF-8 name flags, fixed 1980 mtime), structurally verified by
  a central-directory-walk test. Lands at
  `exported_missions/<uuid>_<name>.zip`; on web the file is also offered
  as a browser download via the existing Export Save seam
  (triggerBrowserDownload — comptime no-op on native).

## Level editor — the mission browser (open existing missions)

The editor can open an EXISTING mission: a full-screen modal browser over
the editor (options-menu Open Mission button + ctrl+O), two tabs at the
top (Your Missions / Official), one row per mission, Back bottom-left. The
web-only Import button (zip upload) is the remaining slice — see TODO.
Design: DESIGN → Architecture → Level Editor → The mission browser.

- **The scan layer (file_source.zig).** `listCustomMissions` →
  `listMissions`, retargeted from `custom_missions/` to `missions/` — the
  author is unifying on `missions/` as THE persistent mission dir (the
  dream browser later reuses the same scan; DESIGN's folder convention
  updated in the same pass). `CustomMissionEntry` → `MissionEntry`, which
  gained a `path` field ("missions/<id>", exactly what `open_editor` /
  `start_mission` consume — rows carry their identity). New
  `listOfficialMissions`: the shipped campaign missions as a comptime
  path list scanned from the embedded map (the
  `official_entity_sprite_stems` precedent in ui.zig) + a runtime parse of
  each embedded mission.txt for name + level_count (scan-once per
  session; the embedded map is immutable per build).
- **The browser UI (ui.zig / view.zig).** `buildEditorMissionBrowser`
  mirrors `buildLoadSavePanel` (same metrics, whole-row scrolling,
  builder-authoritative upper clamp) with the sprite picker's tab-button
  pattern on top. `UiState.editor_mission_browser_open` + `_tab` +
  `_scroll_offset`; emitted from `view()` above the options menu, under
  the error popup. Editor-screen-only.
- **Input plumbing.** `Action.toggle_editor_mission_browser` (button +
  keybind, consumed in handleAnytimeInput — scan-on-open, view-state
  reset, no periodic rescan: nothing can add a local mission while the
  modal is up), `.select_editor_mission_tab` + `.open_editor_mission_row`
  (options_action routing, payload via the Button-field convention —
  `editor_mission_tab` / `editor_mission_row` — not SlotRef; rows are
  never drag sources). A row pushes the ordinary `open_editor` with the
  row's path through `pushPlayerActionAndDrain` — the loading path was
  already DONE (the beginnings round-trip test); the browser is pure UI +
  scan on top. On a failed open the revert restores world_generation so
  no UI reset fires: the browser stays open + the popup surfaces (the
  load-save browser's exact failure shape).
- **`open_editor` bumps `world_generation`** (both branches). The
  driver's transition UI reset fires on screen-change OR generation-bump;
  an editor→editor open changes neither — without the bump the browser
  (a UiState flag) and stale view state (scrolls, open panels) would
  survive the mission swap. start_level/start_hub bump for the same
  reason. Undo across the swap restores the previous mission (accepted
  as a feature; tested).
- **Modal semantics.** While open: its own button clicks dispatch
  (anytime/options_action run before the gates), the wheel scrolls its
  rows (handled before the options gate — the browser opens ON TOP of
  the options menu, the settings-screen stacking), and update()'s
  options pause gate extends to the browser (drag/camera-pan/viewport
  gestures + idle input blocked). Escape steps back one layer (browser
  closes, the options menu beneath stays).
- **Bindings (the three-site rule).** ctrl+O →
  `toggle_editor_mission_browser`; camera zoom rebinds from ctrl+I/O to
  PgUp (zoom out — "up = the camera moves away", author's call) / PgDn
  (zoom in), ctrl+0 unchanged. PageUp/PageDown added to the backend
  key table. ctrl+I → mission import lands with the zip-import slice.
  Existing installs keep their user-overlay bindings (pre-release, free).
- **Three latent bugs fixed en route** (found while mirroring the
  load-save patterns; none were covered by tests):
  1. `listCustomMissions`' error arm did `allocator.free(mission_id)` +
     `return err` under an active `errdefer` — a DOUBLE-FREE on the
     unreadable-mission.txt path (errdefer fires on the return; manual
     frees belong only on `continue` paths, where errdefers are
     discarded). Verified with a standalone repro before fixing.
  2. The load-save row click passed the session list's path to
     `player_load_save` BORROWED: the housekeeping rescan could free the
     list in the same frame while the pushed event isn't deep-copied into
     history until the next frame's drain — a use-after-free on the
     recorded path. Fixed by duping into the current arena at push (and
     the mission rows do the same by construction).
  3. The fresh-open branch of `open_editor` never bumped anything for an
     editor→editor path (impossible before the browser; covered by the
     world_generation bump above).
- **Tests.** file_source: retargeted scan tests (+ the new `path` field,
  `freeMissions`), the official list (exact four stems + paths +
  metadata). ui: browser tabs/payloads/windowing/clamp + per-tab empty
  states. input/handlers: the toggle (open/reset/editor-only no-op),
  escape layering, tab switch + wheel routing, and the end-to-end row
  click (scan → click → drain → editor holds the opened mission,
  world_generation bumped, undo restores). main.zig: the
  open-from-editor swap test.

## Level editor — the mission zip import (browser slice 3)

The mission browser can import a mission .zip on web: the Import button
(ctrl+I) opens a file picker, the zip extracts into `missions/`, the
rescanned list shows the row. Design: DESIGN → Architecture → Level
Editor → The mission browser (the zip import paragraph).

- **zip_reader.zig** — the buffer-based sibling of zip_writer: EOCD
  backward scan (comment-tolerant, last occurrence wins), central-
  directory walk, per-entry local-header data offset (the LOCAL name/
  extra lengths, never the CD's), STORE verbatim + DEFLATE via
  std.compress.flate (raw container, `.fixed` reader → `streamRemaining`
  into a pre-sized buffer), CRC-32 verification on every entry regardless
  of method, uniform ownership (names + bytes from the caller's allocator,
  `freeZipArchive`), descriptive rejections for zip64 / encryption /
  unsupported methods. std.zip was considered and passed over: its
  iterator is File-seek-based (awkward for our in-memory bytes, untested
  on the IDBFS mount); the buffer reader keeps the whole pipeline pure
  and arena-friendly.
- **The upload seam** — `triggerBrowserMissionUpload` (the save import's
  JS shape, `.zip` accept + `imported_missions/` staging +
  `.mission_import_marker`), polled while the browser is open
  (`pollMissionImportMarker` in the browser's input block). The trigger is
  comptime-dead on native; the button is never emitted there and the
  ctrl+I binding parses + no-ops (the skip_level discipline).
- **The extraction** (`importMissionFromZip`) — junk skip (directory
  markers, `__MACOSX/`, `._*`, `.DS_Store`), single-common-root strip (an
  OS "compress folder" zip; mixed shapes strip nothing and fail the
  mission.txt lookup with the popup), validation-before-write (absolute /
  `..` / backslash / empty-segment names fail the WHOLE import — never
  half-imported), the save-convention target dir
  `missions/<uuid>_<sanitized name>/` from the zip's mission.txt (no
  uuid → the name alone; re-import is idempotent overwrite), zip deleted
  on success / kept on failure, entry-count cap 1024 as the hostile-
  archive bound on the scratch arena.
- **Tests (513 total)** — zip_reader: STORE round-trip vs zip_writer, a
  hand-assembled DEFLATE archive (stored-block stream — exercises the
  method-8 path through the real inflater without needing a compressor),
  missing-EOCD / unsupported-method / CRC-mismatch rejections. Import
  flow: the full marker → extract → rescan → row pipeline (files
  spot-checked, marker + zip cleaned up), the OS-zip root-strip + junk
  skip, unsafe-name fail-whole (popup, nothing written, marker consumed,
  zip kept), a zip without mission.txt.
- Known web-only residual: the file-picker → marker → row-appears flow
  compiles + the native-side pipeline is fully tested, but the browser
  upload itself needs an in-browser eyeball (`scripts/web.sh emrun`) —
  the "web compiles ≠ web runs" rule.

## Mission browser — web fixes (IDBFS listing + import ENOENT)

First in-browser test of the mission browser surfaced two IDBFS issues
(the documented "web compiles ≠ web runs" class — the pipeline was
fully green natively):

- **Both tabs came up empty.** Root cause was COMPOUND: (1) Zig's
  `Dir.iterate` fails with `error.Unexpected` on the IDBFS mount (the
  exact reason `listSaveFiles` has a JS enumeration path — the new
  `listMissions` had no such path), and (2) `rescanEditorMissionsNow`
  early-`return`ed on the local-scan error BEFORE the official scan, so
  the failure blanked BOTH tabs. Fixes: `listMissions` was refactored to
  a platform-split ENUMERATION (`listMissionFolderNames`: native
  iterates, web enumerates via `FS.lookupPath` + `Object.keys` +
  `FS.isDir` + a temp listing file — the `listSaveFilesWeb` pattern,
  generalized as `listPersistentDirNamesWeb` and also used for the
  per-mission has-custom-assets check) with the whole per-mission loop
  (mission.txt probe + parse + entry assembly) SHARED between platforms;
  and the two scans in `rescanEditorMissionsNow` are now independent —
  a failure keeps that tab's previous list and never blocks the other.
  A JS-embeddability check (`isSafeForJsEmbedding`) skips pathological
  folder names from the per-mission JS listing (the flags degrade, the
  mission still lists).
- **The zip import did nothing** (console: `ErrnoError 44` — ENOENT):
  the upload JS wrote into `imported_missions/` which didn't exist —
  `FS.writeFile` creates no parent dirs. Both upload scripts now
  `FS.mkdirTree` their target first (the SAVE import had the same latent
  bug on a fresh install with no `saves/` yet — fixed in the same pass).
- Also caught while wiring the listing script: `std.fmt.allocPrint`
  needs JS braces escaped (`{{`/`}}`) — comptime-dead code on native, so
  only the web build surfaces it (the build gate works; the format
  string was corrected before it ever reached a browser).

## Player inventory editing (the inspector's Inventory section)

The player inspector's Inventory section went from a read-only item count
to the full editable inventory (TODO → Level editor → slice 13). Design
decisions settled with the author up front:

- **16 rows × 6 slots** — the same 96 `inventory_slot_count` indices the
  in-game 8×12 grid shows; the 6-wide arrangement is presentational,
  chosen because six 128px cells fit the 1024px inspector panel.
  Capacity is intentionally identical — no data model change.
- **Selection** is pure UiState (`editor_inventory_selected_slot`), a
  direct write at the slot-cell click site (the section-expansion
  discipline: navigation, not authored content — off the undo timeline,
  replay-safe by construction). A repeat click on the selected slot
  deselects (the detail block collapses).
- **The detail block inserts BELOW the selected slot's row** — the
  inspector's first in-section expansion. It works because the entries
  list is rebuilt per frame: the insert is a conditional append in
  `editorInspectorPlayerEntries`, and the windowed emission/scrollbar
  machinery needed no changes. No scroll-on-select (the offset stays).
- **Empty slot → Add only** (author decision): the Add/Delete entry is
  always first below the row; the type rows + name + stats follow ONLY
  while an item exists. Add creates the default sword ("New Sword",
  sword, damage 0 — the `data/editor_defaults.txt` Items entry, the
  palette "+" default, hard-coded like `defaultItemForSlot`).

Event routing mirrors the item tool (slice 12) exactly:

- `editor_add_inventory_item` / `editor_delete_inventory_item` (index
  only — the player loadout is the sole owner, no palette lookup).
- `editor_set_inventory_item_def` — FLATTENED (the
  `editor_set_item_def` shape: nested Item names can't round-trip the
  session log once they contain a space, and the defaults carry spaces
  by design). Covers the type picks (reset-everything semantics — a
  differing pick replaces with "New <Kind>", zeroed stats) AND the stat
  text commits (one event, one undo step). Handler clamps stats via the
  shared `itemFromDefSet` (single-sourced `max_*`).
- `editor_set_inventory_item_name` — its own event (top-level string).
- Player wrappers + `validatePlayerAction` arms
  (`validateInspectorInventoryEdit`: editor screen + index range) on all
  four.
- Text fields: new `TextFieldId.inventory_item_name/_stat` ids +
  `TextEditTarget.inventory_slot` (the index rides the ref target — the
  level-name pattern — so a mid-edit selection change can't retarget the
  commit); `itemTextFieldValue` arms; `beginFocusedTextEdit` seeding;
  commit arms in `commitFocusedTextEdit` mirroring the item_def gates
  (would-change, empty slot, wrong stat, tome, bounds).
- Input: `.select_editor_inventory_slot` (UiState toggle),
  `.add_editor_inventory_item` / `.delete_editor_inventory_item` (slot
  index rides `AnytimeInput.clicked_editor_inventory_slot`),
  `.select_editor_inventory_item_type` (the type cells address the
  SELECTED slot — reset semantics, gated on occupied).
- `emitInspectorItemTypeRows` was generalized (item + action params) so
  the item tool and the inventory detail block share the exact rows.

Tests: handler arms (add/retype/rename/delete + undo walks, crafted-log
guards, selection toggle, input-arm no-ops incl. same-pick and
empty-selection), ui content (grid windowing, insert-below-row, Add vs
Delete by occupancy, selected-cell + amulet-cell highlights, field
targets), text commits end-to-end (multi-word rename, stat clamp,
leading-zero/wrong-stat/stale-index/empty-slot no-ops). Two pre-existing
ui tests updated for the taller player content (the summary's 2 units
became 16+ units — the scroll clamps moved; the player-fallback window
now lands on slot rows).

## Max player import (the player inspector's second Import button)

The player content's Import row grew a second button: **Player data**
(the session's data, or `data/new_player.txt` with none — unchanged) and
**Max player** (the shipped `data/max_player.txt` — the author's tool for
setting author times on official missions). Both are half-width buttons
on the same control line.

- `importEditorPlayer` was refactored to an `EditorPlayerImportSource`
  (`session` / `max_player`): both sources now map onto a loadout Entity
  (`loaders.playerLoadoutEntity` for the session data — replacing the
  hand-copied PlayerData field list — and the existing
  `loadMaxPlayerLoadout` helper for the file, which the open_editor
  fallback already used) and share one deepCopy-apply into the template.
  The max path surfaces balance warnings via the shared `surfaceWarnings`
  (the open_editor posture) and ignores the session's data entirely — the
  file is the source.
- Event routing: new `editor_import_max_player` / 
  `player_import_editor_max_player` (a separate event pair, not a payload
  on the existing one — zero churn on the recorded-event shape) + the
  `.import_editor_max_player` action, all with the same replay-validation
  structural legality (one multi-case arm).
- The open_editor default (mission-player.txt → max_player.txt fallback)
  is untouched — the fresh-mission editor still SEEDS from the max
  loadout; the button is the explicit re-import after edits.
- Side effect of the new event fields: the session-log comtime parser
  (`parseEvent`'s inline category/variant/payload-field walks) outgrew
  Zig's default 1000-branch eval budget — `@setEvalBranchQuota(10000)`
  at the fn head.

Tests: the max import end-to-end via the input arm (equipped gear with
authored stats, empty weapon slots + utility bar per the file, inventory
slots 0 + 11, session data untouched, undo reverts) + a ui assertion that
both buttons render.

## Editor Test/Validate buttons (the playtest/validate surface)

The editor's top-right primary actions, wired end to end. The machinery
(`start_playtest` / `end_playtest` / `start_validation` /
`end_validation`, PlayerData dormancy, the `end_level` editor exit guard)
was already landed from the framing slices — this session built the player
surface + fixed one real behavioral gap the buttons would have exposed.

- **Player orchestrators:** `player_start_playtest` /
  `player_start_validation` PlayerInputEvents (the machinery events are
  MetaEvents, which the replay structural whitelist rejects at idle
  points). Thin handlers: `start_playtest{editor.active_level_index}` /
  `start_validation`. `validatePlayerAction` arms gate editor screen +
  editor present + `mode == .edit` (the buttons only exist there; a
  crafted log seeding them mid-run panics).
- **Exit-abort fix (the gap):** `end_level`'s editor guard previously
  IGNORED the continuation and switched purely on mode — during a
  validation run, a death + "restart mission"/"exit mission" click (both
  route through `end_level` with a non-default continuation) would have
  advanced to the NEXT level. Now: `.playtest` + any continuation →
  `end_playtest` (the run is bracketed, no in-run restart); `.validate` +
  non-default continuation → `end_validation{success=false}` (abort —
  the future validation-replay flow only cares about successful runs);
  default continuation → next `start_playtest` or
  `end_validation{success=true}`. All exits drop back to the editor.
- **Buttons:** `buildEditorPrimaryActions` (ui.zig) — two
  `emitIconButton` cells (the options/undo class: button background +
  icon, `slot_size` square, flush at the top-right corner), reading
  Test, Validate. Placeholder sprite ids `ui/icon_playtest` /
  `ui/icon_validate` (magenta until assets land — AGENTS missing-art
  audit). Actions `.test_editor_level` / `.validate_editor_mission`
  route through the payload-less `options_action` anytime pattern.
  A click while a text field is focused is pure dismissal
  (deliberately NOT added to `textEditPressProceeds` — the top bar is
  not a sibling control of either panel).
- **Tab-row scroll window (a consequence of the corner buttons):** the
  tab row was unbounded; many/long-named tabs would run under the new
  buttons. Now bounded by `editor_primary_actions_width` (the shared
  const: two slots + gap), with a wheel-scroll window when tabs overflow
  (one notch = one tab, `UiState.editor_level_tab_scroll`, the palette
  window model), an authoritative builder clamp (max offset = smallest
  offset whose tab suffix fits), an active-tab follow (the add-level
  flow switches to the new LAST tab — "the author lands on the thing
  they just created" — so the builder scrolls the minimum distance to
  keep the active tab visible; a follow past the clamp is impossible by
  construction), and the add-level "+" PINNED flush at the row's right
  edge (always reachable while scrolled, one `ui_gap` clear of the
  buttons). `editorLevelTabScrollRegion()` is the wheel-routing region,
  sharing the same bound.

Tests: the two orchestrators end-to-end (active-level playtest + full
mission chain + exits), the validation abort on a non-default
continuation, and the tab-window clamp/pin/follow behavior in the ui
builder tests.

## Editor runs: restart semantics + run-context UI (options menu / mission fail)

Follow-up to the Test/Validate buttons. Two asks — hide Export Save during
a run, relabel Restart/Exit Mission for the run — plus the semantic fix
the relabel forced: restart previously didn't restart (slice-1 decision:
any non-default continuation aborted/exited to the editor), and a button
labeled "Restart Playtest" that drops you in the editor would lie.

- **Restart now genuinely re-runs.** Playtest restart: the SAME level,
  fresh; validation restart: the whole run from level 1, fresh. The
  run's teardown (restore real player data + `mode = .edit`) happens
  INLINE in `end_level`'s editor guard, then a single fresh
  `start_playtest` / `start_validation` is pushed and takes the normal
  enter-from-edit path (backup + rebuild from `player_def`). An
  end+start EVENT pair can't ride the stack: `end_playtest` /
  `end_validation` call `transitionScreen`, which CLEARS the event
  stack — the queued re-entry would be eaten (caught by the handler
  tests: the screen ended on `.editor`). Normal `end_level` never
  transitions itself for exactly this reason; the guard now matches
  that discipline. Gotcha hit on the way: `if (current.editor) |editor|`
  captures the Editor BY VALUE — the inline `mode = .edit` must go
  through `current.editor.?`.
- **Run-context UI.** `editor_run: ?types.EditorMode` threaded into
  `buildOptionsMenu` + `buildMissionFail` (computed in view): the
  restart/exit buttons name the RUN (Restart/Exit Playtest or
  Validation — the mission-fail overlay shows the same nouns on a
  mid-run death), and the campaign Export Save is HIDDEN during a run —
  the run's player_data is temporary (rebuilt from the editor loadout,
  discarded on exit), so an export mid-run would write throwaway data as
  a campaign save. `save_game` is button-only, so hiding removes the
  path entirely (the editor-screen precedent).

Tests: playtest restart re-enters the same level with rebuilt run data
+ intact backup; validation restart returns to level 1 fresh; the ui
pair-test covers both builders' run labels + the absent Export Save.
Open (surfaced, not changed): the options menu's "Exit to Main Menu"
during a run lands in the EDITOR, not the main menu (the guard swallows
the continuation) — decide whether to hide it during runs or make it
chain `end_playtest` + `close_editor`.

## Editor runs: Exit to Main Menu goes to the main menu

Resolves the open question from the run-context UI session: during a
playtest/validate, the options menu's "Exit to Main Menu" landed in the
EDITOR (the `end_level` guard swallowed the continuation like every other
exit) — a lying button.

Now an `.exit_to_menu` continuation during a run tears the run down INLINE
(restore the real player data + `mode = .edit` — the same
transitionScreen-clears-the-stack constraint as the restart paths, and the
restore must precede `close_editor`, whose scope swap discards the Editor
that carries the backup) and chains a single `close_editor` event: main
menu, editor session gone, campaign player data intact. No
`end_playtest`/`end_validation` event fires on this path — the teardown
work is inline in the guard (deterministic, replayed identically), and
`close_editor`'s transition replaces the run-end transition. Normal
(non-editor) gameplay's exit-to-menu path is untouched (the guard only
runs when an editor is active).

Tests: both run modes (playtest + validate) exit to `.main_menu` with the
editor/level/mission cleared and the campaign player data restored.

## Bug fix: the level-tab scroll window fought manual scrolling

The tab scroll window (from the Test/Validate session) was broken in
play: scrolling "didn't work" and the reachable band depended on the
active tab's position. Root cause: the ACTIVE-TAB FOLLOW ran on every
build. `view()` rebuilds the tab row each frame, and the follow
unconditionally pulled the window back until the active tab was visible —
so with the active tab at index 0 any scroll snapped back to 0, with it
at the end the window was pinned to the last-tab band, and mid-row you
could only scroll within the band that kept the active tab in view.

The follow's only job was the add-level flow ("land on the newly created
last tab"). Fix: it now fires exactly once per CHANGE of the active tab,
tracked via `UiState.editor_level_tab_last_active` (default -1). A tab
click, add-level switch, delete-level shift, or undo across a tab switch
triggers it; frames where the active index didn't change leave the offset
alone, so manual scrolling sticks anywhere in the clamp range. (Side
effect, a good one: undoing a tab switch scrolls the window back to the
tab you land on.)

Test: a manual scroll away from the active tab now persists (the
regression case), plus the existing clamp/pin/follow cases.

## Codebase split: event_handlers.zig (slices 1–4)

The codebase doubled during the editor work and the two largest files had
become many-jobs-in-one. event_handlers.zig (6,636 lines) was split into a
thin dispatch + scoped handler files, one slice per commit, each
`scripts/test.sh` green. Decisions settled with the author up front:
facade/vocabulary vs direct imports (mix: shared vocabulary re-exported,
specifics imported directly at call sites), subdirectories where coherent,
processEvent prongs extracted into per-category handler fns (recording/
replay/checkpoint bookkeeping stays in the dispatch), and coherence of
file contents over line-count targets.

- **`src/editor/planning.zig`** (~1,140) — the pure `planEditor*Actions`
  click planners + selection algebra + `activeEditorLevel`. The seam was
  already drawn (planners are pure and shared with the input-side no-op
  gate); input_handlers + handler_tests_editor import it directly.
- **`src/event_push.zig`** (~80) — pushEvents/pushPlayerSkillUse/
  pushPlayerAction, the input-side compile-time gate. Consumers (main,
  input_handlers, crash_dump, the test files) import it directly;
  event_handlers aliases them (the pre-existing deepCopy-alias pattern).
- **`src/editor/handlers.zig`** (~1,600) — handleEditorEvent (the editor
  arm's state transform; the cache-needing framing events stay inline in
  the dispatch) + editor session helpers (playtest data, player import,
  palette defaults, fresh-mission open, decoration registry) +
  selection-mutation + template/layer edit helpers.
- **`src/handlers/shared.zig`** (~200) — cross-category helpers: entity
  accessors, failReconstructionRead, validateConfigKeys/surfaceWarnings,
  loadCampaignAndPushHub, pushGameplayStartEvents,
  refreshMoveHighlights/cancelPreparedSkill. Seeded BEFORE the editor
  handlers moved so the import graph stayed one-directional at every
  slice (the alternative — a temporary mutual import between the dispatch
  and editor handlers until the category files landed — was rejected).
- **`src/handlers/player_input.zig`** (~1,000) — handlePlayerInputEvent.
- **`src/handlers/player.zig`** (~500) — the player_event + super_event
  arms + gear/salvage helpers + clone-harvest math + isSkillLearned.
- **`src/handlers/level.zig`** (~1,550) — the level_event + sub_level_event
  arms (turn flow + combat primitives) + AI/anim helpers. No hub file —
  there is no HubEvent; hub input flows through player-input orchestrators
  and hub state through meta events.
- **`src/handlers/meta.zig`** (~650) — the meta_event arm (session flow).
- **event_handlers.zig is now the thin dispatch** (~185): pop + record/
  replay bookkeeping, the start_level/start_hub checkpoint policy, the
  editor arm's inline cache cases, routing to the category handlers.

Mechanics worth remembering: boundary-asserted python extractions (exact
line anchors verified before cutting), arm bodies de-indented by 8 into
handler fns, the compiler driving the missed-reference fixes, and manual
import-usage greps afterward (Zig doesn't flag unused container-level
consts, so pruned imports must be checked by hand). Two pre-existing
doc-comment jumbles were found and repaired during the move (docs for
failReconstructionRead + pushGameplayStartEvents had merged into one ///
run above buildPlaytestPlayerData; loadCampaignAndPushHub's doc had lost
its head) — `tileBefore` also moved to functions.zig (the row-major tile
order convention, Determinism & Tiebreaking domain).

Consumer re-points were part of each slice (input_handlers, test_harness,
the handler_tests_* files). AGENTS Key Files updated per slice. The ui.zig
split (slices 5+) remains open in TODO.

## Codebase split: ui.zig (slices 1–6)

The second half of the event_handlers/ui.zig split (same settled
decisions — facade for shared vocabulary, direct imports for specifics,
coherence over line counts; see the event_handlers entry above for the
full rationale). ui.zig went 15,015 → 256 lines: a pure facade re-exporting
every pub symbol of `src/ui/`, so all 10 consumer files (main, view, input,
input_handlers, state, types, raylib_backend, the tests) kept their `ui.X`
call sites unchanged. Six slices, one commit each, `scripts/test.sh` green:

- **element.zig** (1,304) — UiElement + variants, Rect algebra, layout
  constants, FontMetrics, hit-testing, wrapRow (+ its scattered tests,
  reunited), SlotRef (an element payload type, not interaction state).
- **state.zig** (461) — UiState + drag/press/marquee/picker-target types.
- **text_input.zig** (598) — TextField + TextEditState + routing. The
  state↔text_input import pair is a cycle (UiState holds a TextEditState;
  beginTextEdit takes *UiState) — compiles fine under Zig's lazy
  resolution; the alternative (merging them) was worse.
- **tooltip.zig** (685) — placeTooltip + the tooltip content builders +
  the positive/negative comparison colors.
- **emit.zig** (535) — shared builder primitives + sprite-id resolution
  (skillIconSpriteId/itemIconSpriteId/effectIconSpriteId) + material icons.
- **editor_chrome.zig** (1,676 — since renamed
  `editor_shell.zig`; same session, the author preferred "shell" over
  "chrome") — tool palette, level tabs, primary
  actions, palette group math.
- **editor_inspector.zig** (4,649) — the inspector + metadata sidebar +
  field emitters + target inference + M2 arbitration (+ ~1,700 lines of
  tests). Largest file in src/ui/ — a further field-emitter split stays
  optional (TODO).
- **editor_pickers.zig** (1,742) — the centered pickers + the comptime
  official-sprite tables.
- **bottom_bar.zig** (329), **panels.zig** (1,243), **screens.zig** (633),
  **menus.zig** (1,588) — the in-game surfaces.

Notable mechanics: the generated_sprite_metadata import must stay BARE
(`@import("generated_sprite_metadata")` — it's a build-provided named
module, not a file, so the ../ path form breaks from subdirectories);
`element`/`tooltip`/`ui_state` collide with common local variable names
in builder code, so the module aliases are ui_element/ui_tooltip/
ui_state_mod; the slice-3 chrome extraction briefly left a DUPLICATE
material-icons block in ui.zig (the extraction added the emit.zig copy
but missed the remove-set entry) — caught and deduplicated before any
drift; two more stale/jumbled doc-comment fragments were repaired during
the moves (an old buildInventoryPanel doc fused into the material-count
const doc; buildErrorPopup's banner). Unused top-level aliases are
invisible to the compiler — each slice ended with a scripted usage-count
prune of the alias blocks.

## Codebase split: input_handlers.zig

The third split of the cleanup, same method (boundary-asserted extractions,
compiler-driven rewiring, one commit, tests green). input_handlers.zig went
5,740 → 3,900:

- **`src/input_gestures.zig`** (1,149) — pointer gesture resolution: the
  drag lifecycle (dragToOrchestrator + the click intents), camera pan,
  settings sliders, right-click inspect, and the editor viewport gestures
  (right-click delete, marquee, selection move drag) + the pure gesture
  tests. Consumers call it directly (main.zig's update loop +
  handler_tests_gear/editor); input_handlers aliases the two fns its
  remaining code touches (skillsSlotUnderPointer for wheel routing, the
  gesture fns for the idle-input-driven integration tests). The
  handleIdleInput-driven integration tests (right-click delete,
  shift+click toggle, plain-click replace) stayed in input_handlers —
  they exercise the whole input path, not the gesture predicates.
- **`src/editor/mission_io.zig`** (552) — the editor mission save/export/
  import machinery: uuid resolution + dir naming, the STORE zip bundling,
  the web import marker poll + extraction (junk filter, root-strip, path
  safety), and the mission-list/sprite rescans. Side-effect paths off the
  undo timeline; input_handlers' anytime path calls into it (one-way).
- What stayed: handleAnytimeInput, handleIdleInput, resolveTileCursor,
  the text-field commit sites (per DESIGN → UI Framework → Text input
  widget, the field-kind commit switch lives in the input layer), the
  settings persistence fns (markSettingsDirty is pub — gestures' slider
  apply uses it), and the session-log dev tooling. The camera zoom consts
  stayed too (only handleAnytimeInput's wheel/zoom bindings read them).

Comment references in zip_writer/zip_reader/types.zig re-pointed at
editor/mission_io.zig.

## Validation replay: slice 1 — pure machinery (validation_replay.zig)

The first slice of the validation-replay design (settled this session —
see DESIGN → Custom Missions & Online Services → Validation replay + the
amended DESIGN → Level Editor framing/exit-guard paragraphs; the full
slice plan lives in TODO → Level Editor → "Validation replay + file-based
validation"). Decision recap: validation will run the SAVED artifact
(the start_mission shape) rather than the in-memory editor, so the replay
slice is self-contained given the mission files; restarts are cut by
slicing from the LAST player_start_validation (the validate-restart
re-entry will ride the orchestrator, not the machinery event, so the last
one is always the final attempt's start — restarts excluded by
construction); turns are DERIVED at read time, never stored (supersedes
the old "author time lives in the replay's metadata" line); the
personal-best guard auto-writes on absent/unreadable/hash-mismatch/
strictly-faster and otherwise stashes + offers manual overwrite.

What landed (all pure, no consumers yet — slices 2-5 are the consumers):

- `src/validation_replay.zig`: `loadValidationReplay` (config sections →
  `ValidationReplay`; bracket checks — first event
  `player_start_validation`, last `end_validation{success=true}`, ≥2
  events; requires `mission_uuid` + `content_hash` Metadata keys),
  `deriveValidationTurns` (count `turn_end{entity_index = 0}` — mirrors
  the turn_end handler's `mission.turns_spent` increment; equality with
  the reconstructed state is asserted by the slice-5 crown test),
  `medalTargets` (integer-form gold/silver/bronze via ceilRatio — the
  settled ×1.2/×2.0/×5.0 multipliers, incl. the author_turns=1
  gold==silver collision edge), and `replayOverwriteDecision` (the PB
  guard as a pure enum decision: write vs keep_offer_overwrite, ties keep
  the old file — first-validated wins).
- `session_log.writeEventLogWithMetadata` + `MetadataPair`: the writer
  gains optional extra Metadata lines (validation replays carry
  mission_uuid + content_hash); the reader is permissive on unknown
  Metadata keys (findValue-based, no key whitelist on session logs), so
  no reader change. `writeEventLog` delegates with an empty slice —
  same format, generic session logs unaffected.
- 6 tests: turn derivation (player vs enemy indices), a full
  write→parse→load→derive round trip, four non-bracket rejections (too
  short / wrong first / wrong last variant / success=false), the
  missing-metadata rejection (a plain session log is not a validation
  replay), the PB decision table (null/hash-mismatch/faster/slower/tie),
  and medal targets incl. the collision + a non-divisible ceil case.

The module's pub surface has no external consumer yet by design — the
TODO slices 2-5 (file-based validation, the slice write, the stats
screen, the crown test) land next and consume it.

## Validation replay: slice 2 — file-based validation (the run certifies the saved artifact)

The handler restructure at the core of the validation-replay design (see
DESIGN → Level Editor → Playtest/validate framing + the exit guard, both
rewritten this slice; DESIGN → Custom Missions & Online Services →
Validation replay). Playtest keeps its in-memory quick-iteration role;
validation now runs the SAVED mission dir:

- **`player_start_validation` / `start_validation` gain `mission_path`**
  (top-level string payloads — session-log verbatim, spaces-safe). The
  input layer's Validate button saves FIRST via the editor-save flow and
  aborts on failure; the payload borrows the memo's durable dir string.
- **`start_validation` is the `start_mission` shape**: reads mission.txt +
  player.txt from the dir via the reconstruction cache (+ key
  validation), sets `current.mission` from the files with
  `validation_run = true`, builds the run's player data from the FILE
  loadout (loadPlayerLoadout → buildPlaytestPlayerData, all-skills-
  learned), dormancy backup + mode flip only when an editor exists, then
  chains `start_level{path, 1}`. The chained levels ride the campaign's
  own start_level path (turns accumulate on the mission across levels);
  the player sync round-trips the loadout because playerLoadoutEntity
  maps the same field set build_player_from_data maps.
- **`Mission.validation_run`** (new runtime working-copy field): the
  no-editor marker. Live runs have editor.mode == .validate AND the
  flag; a cross-session replay of a validation replay has only the flag
  (no Editor exists) — end_level's guard reads it there, replay
  reproduces it, and the end_validation transition discards it with the
  mission. Self-cleaning: no manual clearing across abort paths.
- **The exit guard hoists a `validation_run` branch** before the editor
  block: restart → inline teardown (editor only) + re-entry via the
  ORCHESTRATOR `player_start_validation{path}` (every attempt begins
  with a seedable top-level action — the slice rule); exit-to-menu →
  teardown + close_editor / open_main_menu (no editor); Exit Mission →
  `end_validation{success=false}`; default → next `start_level{path,N+1}`
  (mission level_count from the file, not editor.levels.len) or
  `end_validation{success=true}` on the last level. The editor switch
  keeps only the playtest arm. end_mission's defensive guard extends to
  validation_run.
- **`end_validation` dual-context**: editor present → restore + .editor;
  absent (cross-session replay) → .main_menu. `validatePlayerAction`'s
  player_start_validation arm relaxes to "no active level/mission"
  (fresh state + editor-idle both satisfy; player_start_playtest keeps
  its editor/edit-mode arm) — this is what lets a validation replay seed
  its first event on a fresh state.
- **Bug fix riding along: `saveEditorMission` returns `?[]const u8`**
  (the saved dir, borrowed from the memo) instead of void. Consumers
  previously read `session.editor_saved_mission` after calling it — but
  the memo survives a FAILED save pointing at the PREVIOUS save's dir,
  so validate/export could have used a stale dir (e.g. save-once, rename,
  failed re-save → validate runs the old name's dir). Export now gates
  on the return value; the bare save button ignores it (popup inside).
- **Tests**: the five in-memory validation tests reworked onto an
  on-disk two-level fixture (`missions/validation_fixture` — levels with
  distinct '!' positions, player.txt with a distinctive damage-7 sword;
  the in-memory editor deliberately differs so asserts prove the run
  read the FILES): file-based start (level name/positions/loadout from
  the files, editor untouched, all-skills-learned, dormancy), chaining
  (file level_count, turns accumulate, no re-back-up, mutation
  survives), completion restore, exit abort, orchestrator restart
  (fresh mission, turns reset, loadout rebuilt), exit-to-menu loop. NEW
  crown-precursor test: a NO-EDITOR run driven entirely by whitelisted
  orchestrators (skip_move / move_action), sliced from the last
  player_start_validation, serialized, and reconstructed
  cross-session into fresh histories — replay-reproduced turns_spent ==
  derived turns, and the full slice lands on the main menu. That test is
  the client-side prototype of the future server-side check.
- Discovered semantics (documented in the test): stepping onto the level
  end cuts the final turn short — check_level_end → end_level runs
  before the pending attack step/turn_end (the transition clears the
  stack) — so a beeline finish contributes no turn_end;
  turns_spent counts COMPLETED turns. deriveValidationTurns mirrors the
  turn_end handler exactly, so the two agree either way.

## Validation replay: slice 3 (+ slice 5 early) — the slice write + personal-best guard + the crown test

`end_validation{success=true}` now writes the mission-dir artifact
(mission_io.writeValidationReplay, called from the handler gated
`!replaying` — the save_game class: a recorded event owns the side
effect, replay never re-fires, undo past the run doesn't rewrite):

- **The slice** = event_history from the LAST `player_start_validation`
  through the closing `end_validation` — a backwards scan; unambiguous
  because the orchestrator is pushed only by the edit-mode button and the
  restart re-entry, both attempt starts. Restarts/failed attempts fall
  outside by construction (any restart inside a candidate slice would
  have produced a later orchestrator, which then IS the start).
- **Metadata**: `mission_uuid` (from the file-loaded mission) +
  `content_hash` (computeMissionHash over the saved dir) + the shared
  `created` stamp — writeEventLogWithMetadata.
- **The personal-best guard** (the clone auto-save pattern):
  replayOverwriteDecision over {existing file's turns + hash, new turns,
  new hash} — auto-write on absent/unreadable/hash-mismatch/strictly-
  faster; ties keep the old file (first-validated wins); otherwise keep
  the old file + `session.pending_validation_replay` (backing-owned
  stash — the Overwrite Replay button writes the STASHED bytes, never a
  re-slice) + `validation_replay_overwrite_offered`. The stash + flag are
  retired at start_validation (gated — replay scrubbing can't eat a
  pending offer) and cleared by any auto-write. Turn count is DERIVED
  from the events, never stored.
- **formatSessionTimestamp moved input_handlers → session_log.zig** (its
  natural home — the `created` stamp of session-log-shaped artifacts;
  the TODO's "move to a util module" item done). Consumers updated: the
  session dump, the autosave backup naming (meta's inline copy
  collapsed onto the shared fn — the format was the only difference),
  the validation replay write. crash_dump keeps its own fallible/
  transient variant.
- **Tests (crown test = slice 5, landed early)**: the Validate-button
  path end-to-end — editor save → validate (real input path, payload =
  the saved dir) → scripted completion (skip + move per level) →
  `validation_replay.txt` next to the mission files with the minted uuid
  + matching content hash + derived turns 2 → cross-session
  reconstructFromEventLog from the WRITTEN FILE: replay-reproduced
  turns_spent == derived, full slice lands on the main menu. Plus the PB
  sequence on the fixture: first run auto-writes; the beeline (0 turns —
  each level ends before its pending attack step runs) strictly-faster
  auto-overwrites; a slower re-run keeps the 0-turn file + stashes its
  own 2-turn slice + sets the offer; an edited level (hash mismatch)
  auto-overwrites DESPITE being slower, clearing the stash/offer.
- A test-shape gotcha worth remembering: driving runs via the
  start_validation MACHINERY skips the orchestrator, and the slice scan
  keys on `player_start_validation` — the helper now pushes the
  orchestrator (the realistic button shape; the machinery event is
  never a slice start).

## Validation replay: slice 4 — the validation stats screen (the overlay over the editor)

The mission-complete overlay doubles as the post-validation stats
screen — one surface, context-branched:

- **`MissionCompleteInfo.validation: bool`** (new field, on the timeline):
  `end_validation{success=true}` populates `last_completed_mission` with
  the run's stats (name/uuid/path from the file-loaded mission,
  turns/tiles/skills/damage, clone fields zeroed — discard semantics).
  A pure GameState write, replay-reproduced; the overlay itself renders
  view-side (view() draws it whenever the info is set — no hub gating,
  which is what makes the editor reuse free). Undo/redo across the run
  end re-shows/dismisses naturally (the info is in snapshots).
- **`buildMissionComplete` gains a `?ValidationCompleteContext` param**:
  the campaign branch is byte-identical (regression-tested); the
  validation branch swaps the "New clone:" icon line for a "Validated in
  N turns — Personal best: M turns" summary, the clone-harvest column for
  the "Author medals" column (gold/silver/bronze derived at display time
  via medalTargets), and the buttons for Continue / Validate Again /
  Overwrite Replay (offered only). Validate Again REUSES the
  `.validate_editor_mission` action — the same dispatch that saves first
  then re-runs; no new action for it.
- **The session-side context** (`validation_personal_best_turns` on
  SessionState): captured at the write site in BOTH guard branches (the
  kept old file's turns or the just-written run's), so the PB line +
  medal targets always derive from the FILE's turns (view stays
  file-free); medal targets fall back to this run's turns when no replay
  landed.
- **The manual Overwrite Replay path**: new Action
  `.overwrite_validation_replay` → options_action dispatch (offer-gated;
  a stale click no-ops) → `mission_io.overwritePendingValidationReplay`.
  Mid-implementation correction: the write target was first derived from
  the session memo — wrong, because a run doesn't require a save this
  session (hand-authored mission dirs, imported missions). The stash is
  SELF-DESCRIBING (its first event carries the mission dir), so the
  overwrite writes there — no memo dependency, and the bytes provably
  return to the dir they came from. Consumes the offer, updates the PB
  line; a write failure keeps the offer (re-clickable).
- **Tests**: the overlay builder's two variants (validation: "validated"
  header + medal lines from medalTargets(3) + the three buttons, NO
  clone content; campaign regression: unchanged); the handler-side flow
  (info populated + flagged with the run's data, PB captured, the stale
  overwrite click no-ops, Continue dismisses on the timeline, the slower
  run offers, the manual overwrite writes the stash + follows the PB
  line + consumes the offer).

## Editor save via ctrl+S (missing translateInput dispatch) + ctrl+E export binding

ctrl+S didn't save a mission in the editor — only the options-menu Save
button worked. Root cause: the keybind pipeline has FOUR sites and the
save slice wired three of them (the binding in `data/default_settings.txt`,
the `KeyS` backend key-table entry, and the `Action`/`AnytimeInput` +
`applyAction` + `handleAnytimeInput` consumption). The fourth — the
`translateInput` `checkAction` dispatch line that sets
`anytime.save_editor_mission` from a KEYPRESS — was never added, so the
flag was only ever set by `applyAction` (the button path). Same bug class
as the ctrl+A select-all (that one forgot the backend key-table entry);
TODO's "New-keybind pipeline friction" item now names all four sites and
both instances.

Changes:

- `src/input.zig`: the two missing dispatch lines
  (`save_editor_mission` + `export_editor_mission`, press-only/`no_repeat`,
  the dump_event_log discipline).
- `data/default_settings.txt`: new default binding ctrl+KeyE →
  `export_editor_mission` (was button-only; the per-action overlay
  migration injects it into existing user settings on next load).
- `src/raylib_backend.zig`: `KeyE` added to `key_mappings` (the ctrl+A
  lesson — the backend entry is the site nobody remembers; not covered by
  the test build since the backend is excluded from it, verified via
  `zig build`).
- Regression test at the `translateInput` level (not just `checkAction`
  — the bug was precisely that `checkAction` was never called): ctrl held
  + KeyS + KeyE edges set both anytime flags, and the plain KeyS
  `toggle_skills` binding on the same key is suppressed by the chord
  (hybrid precedence).

## Editor tooltip pass: "+" tooltips reworded, self-explanatory tooltips removed

The "+" cells already carried tooltips (panel-level in `emitEditorPlusCell`
— `tooltipAt` picks the topmost tooltip-BEARING element, so the tooltip
shows through the spriteless button on top); they said "Add level" /
"Add new <Plural> type". Reworded to the requested exact strings: "Add
Level", "Add Enemy Tool", "Add Decoration Tool", "Add Item Tool" (a
parallel `group_plus_tooltips` array — the group labels are plural names,
the tooltips are singular tool-shaped).

Removed the tooltip-noise surfaces (each already labeled itself):
level-tab buttons, palette group-header toggles (dropped the
"{label} (collapsed)" allocPrint with it), the inspector toggle, and the
metadata-sidebar toggle. The tab × "Delete level" tooltip STAYS — it
warns of a destructive action rather than restating a visible label.

`emitEditorPlusCell` cleanup while there: `action` was `?types.Action`
with an "inert until its edit verb lands" null branch + stale comments,
but both call sites (add-level + palette pluses) pass an action — made
the param required and dropped the dead branch + the stale prose.

## Bug fix: editor "+" tooltips never showed (hitTest shields panel-level tooltips)

The reworded "+" tooltips still didn't appear: `emitEditorPlusCell` carried
the tooltip on the `nine_slice_panel`, with the spriteless interactive
button emitted on top covering the exact same rect. `hitTest` (element.zig)
walks top-to-bottom and HALTS at the first blocking element that fails the
predicate — the button (no tooltip, blocks input) shielded the panel's
tooltip underneath, so it could never spawn. The tooltip now rides the
BUTTON (the convention every working tooltip already used — tool cells,
level tabs, group headers), pinned by the add-level test asserting the
button's header text "Add Level" and the panel carrying none.

Swept the tree for other victims of the same pattern: none (the
entity-inspect skill grid's image-carried tooltip sits topmost; slot
tooltips are on the interactive slot itself). The doc comment on
`emitEditorPlusCell` records the rule: a tooltip on an element drawn under
a blocking element never shows.

## Editor palette: an expanded EMPTY group's header rises to the strip too

Expanding a tool group with no tools left its header + "+" pinned flush
against the bottom of the screen — the placement condition was
`collapsed or size == 0`, so "empty" read as "collapsed" for placement.
Now `header_y` keys off `collapsed` only: an expanded group rises to the
strip above the bar whether or not it has cells to label. The footprint
math KEEPS its `or size == 0` (an empty group's row extent is still just
the header + "+", so the neighboring group's header can't overlap it) —
the two conditions are now intentionally different, noted in the comment.
Test: the collapsed/expanded placement test gains an empty-Decorations
expanded build asserting header + "+" both sit at the hovering y.

## Editor palette: adding a tool expands its group + scrolls to the new cell

The palette "+" (add-new type) left the accordion alone — a new tool could
land in a collapsed group (invisible until expanded) or beyond the group's
8-cell window (invisible until scrolled). The `.add_editor_palette_type`
input arm now, after a successful add (post load_error revert gate):
expands the target group with the header-toggle accordion discipline (the
others collapse), and scrolls the group's window to
`size -| editor_palette_max_tools` — the new type (always appended last by
the handler) becomes the window's last visible cell, which is also the
MINIMAL scroll that shows it. View-side display state, off the undo
timeline (the toggle branch's class); a failed/reverted add touches
nothing.

Tests: the add-path test now drives all-groups-expanded going in and
asserts the accordion after each of the three "+" clicks (one group open,
the other two collapsed); a new test with 9 preset enemy types asserts
offset 10 -| 8 = 2 with the accordion.

## Mission browser: the Your Missions tab sorts newest first (max file mtime)

The local tab had NO explicit sort — entries rendered in `Dir.iterate`
order (filesystem-implementation-defined; looked alphabetical on the
author's machine by coincidence). Now `listMissions` sorts NEWEST FIRST,
keyed by `MissionEntry.mtime_ns` = the MAX mtime across the mission
folder's files — the settled semantics: ANY file change is an update
(editor save, custom png drop, zip import, validation-replay write all
count), matching the load-save browser's proven ordering + tiebreak
discipline (mtime descending, name ascending). Considered and rejected:
a persisted `last_modified` stamp in mission.txt (travels through zips
but needs an mtime fallback for every non-editor-authored mission
anyway, and starts the mission file-format-version clock TODO defers).

`hasMissionCustomAssets` folded into `scanMissionFolder` returning both
flags + the stamp (the custom-asset check already enumerates the folder's
files platform-safely — the stat pass rides it; web stats each file
through the persistent dir, the `listSaveFilesWeb`-proven pattern).
Official entries keep `mtime_ns = 0` (embedded, no filesystem) and the
Official tab keeps its comptime order. Web branch verified by compile
(`scripts/web.sh` — emrun spot-check unnecessary: the per-file stat
pattern is the save-listing's, already running on the mount).

Tests: the populated scan test now asserts the defined order + mtime
sanity (sleep between missions per the save-test tie discipline); a new
recency test (png dropped into the OLDER mission bumps it to the front —
max-across-files, not mission.txt-only); a comparator unit test pinning
the name tiebreak + mtime-0-last.
