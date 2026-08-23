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
  verifies every event without tripping the panic. (No `expectPanic` in std,
  so the tampered-history negative case is covered by the deepEqual unit
  tests + the obvious `@panic` call in verifyReplayMatch.)

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
  `AGENTS → <section>` links.
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

## Error Handling

### Slice 1 — error surface (DONE)

Settled the two-class error policy and built the player-facing surface for
recoverable failures. Settled design + B-simple recording choice in AGENTS →
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
reasoning in AGENTS → Error Handling → B-simple.

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
A names the typo directly). See AGENTS → Error Handling. Soft policy: unknown
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
reverts + surfaces the popup. See AGENTS → Error Handling → three contexts.

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
  — redo just unavailable. See AGENTS → Error Handling → B-simple.

### Slice 4 — write/reload failures (DONE)

The two write sites (`write_save` handler + `dumpEventLog` dev tool) now
recover from write failures instead of crashing. Session-log reload is not
user-wired yet (the replay viewer is TODO), so its `file_format_version`
hard-gate softening is deferred to that work. See AGENTS → Error Handling →
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

Extended approach A from level files to every config file type. See AGENTS →
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

Ported all 4 designed missions from the Unity project (~/Development/taplop)
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
built-in decoration to the tools." See AGENTS → Decorations & Footprint.

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
sprite animation). See AGENTS → Animation for the settled design; this is the
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
  AGENTS → Animation for the full one-shot design (deferred — lands with the
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
- Known caveat: drain multi-fire — see AGENTS → Input.

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
