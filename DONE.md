# DONE.md — archived history

Archive of completed work, resolved tech debt, and the "why we did X" reasoning.
Read on demand when you need the history behind something already built — not
every session (see AGENTS.md → Documentation for the file roles).

Newest slices are appended at the bottom of their section. Entries are
historical: they're not maintained after archiving (if a design described here
changed later, the current truth lives in AGENTS.md).

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
  session-resident FileSource (see AGENTS → File System & IO).

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
  in AGENTS → Architecture.)
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

Settled design in AGENTS → Platform Seam (budget-driven drain, render
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

Ported from the Unity project (~/Development/taplop Assets/Scripts/Skills).
Pattern: C# SkillScript → Zig Skill struct + 5 fns (getValidTargets /
priority / selectTarget / playerPrepareSkill / useSkill). Skills compose
generic events (AGENTS → Architecture). Porting note: Unity inverts AI
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

Convention in AGENTS → Determinism & Tiebreaking. All audit sites made
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
  with custom-mission sharing. See AGENTS → File System & IO → Reconstruction
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
  verifies every event without tripping the panic; repro test "replay
  verification: reproduce crash against an external session log" (main.zig,
  opt-in via `session_log_repro.txt` at project root, gitignored) loads a real
  ~2700-line session log, reconstructs to the end, and undoes all the way back
  to the start — this is the test that first surfaced the flat-check
  false-positive and now confirms the natural-stack model handles it. (No
  `expectPanic` in std, so the tampered-history negative case is covered by the
  deepEqual unit tests + the obvious `@panic` call in verifyReplayMatch.)

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
  See AGENTS → Custom Missions & Online Services → Content identity.

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
  replay metadata format are DESIGNED (see AGENTS → Custom Missions → Turn
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

**Design decisions settled (AGENTS → Architecture → Level Editor):** full UI
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
