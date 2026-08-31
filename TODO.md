# Ziglop — TODO

File roles + the open-question → DESIGN → DONE lifecycle are in
AGENTS.md → Documentation. This file holds **active + near-term + deferred
tasks** and **open/undecided design questions** only. Settled design lives
in DESIGN.md; completed history lives in DONE.md.

## Goal

Finish the game. The core loop (hub → mission → level → return) runs
end-to-end natively and on web, and combat flow is working. The end goal is
the full game: level editor, replay viewer, all planned skills, full art,
full sound design, a web database for leaderboards and custom content, and
everything else that entails. A lot is still missing — but it's reachable.
Test by running `zig build run` and clicking through.

## NEXT UP (not ordered — pick what progresses)

- **Dev tools: skip level** — DONE. ctrl+Enter skips the current level in a
  dev build (`-Ddev-mode`, defaulted to debug). Lands with the hybrid input
  precedence fix (closest chord wins, ties co-fire). History in DONE.md.
- **InputBindings per-action migration** — DONE. A user `settings.txt`
  overlays the default binding set PER-ACTION now (bindings for actions the
  file names are user-authoritative; unmentioned actions get their defaults
  injected on load, idempotent via the next debounced write). History in
  DONE.md. This also unblocks the `toggle_options_menu` rename (a renamed
  action now self-heals to its new default on existing installs) — the
  rename itself is still pending, pick it up whenever.
- **Combat-log UI** — render ViewState.combat_log (top-bar coarse recent-icons
  view + full-screen detailed log). Projection is DONE (combat_log.zig); see
  "Combat Log" below.
- **Make co-fire-by-context disambiguation explicit** — the shipped ArrowUp /
  ArrowDown bindings intentionally map one key to two actions
  (`move_cursor_*` + `error_scroll_*`); both fire on every press and the
  pending-error popup branch consumes the scroll action + `return`s first, so
  context picks which takes effect. This is handler-ordering-dependent and
  undocumented at the binding sites. Prefer making it explicit: either a
  comment at each dual-binding explaining the context gate, or restructure so
  `error_scroll_*` isn't a separate binding (the popup branch reads
  `move_cursor_*` directly and the Action enum drops `error_scroll_up/down`).
  The hybrid precedence rule (DESIGN → Input) handles chord-vs-plain
  collisions but NOT same-specificity intentional dual-binds like this —
  those still rely on the implicit context-gate. Small slice; lands with the
  binding-UI work or standalone.
- **Replay viewer** — wire the .replay_viewer screen to STEP through a loaded
  log. The `--replay <path>` CLI flag (DONE — see DONE.md) loads a session
  log and reconstructs the session to its END state (resume mid-session);
  the in-game viewer is the stepping UI on top of the same machinery. See
  "Logging & Replay" below.
- **Mission end states** — mission_complete / mission_fail screens + player
  death. See "Mission Flow" below.
- **Level editor** — major planned system, not yet broken down. The Screen
  enum has `.editor` and events.zig has EditorEvent scaffolding
  scaffolding; everything else is to be designed. See "Level Editor" below.
- **Combat readability (Phase 4b)** — entity health bars + grayscale × gradient
  tinting: entity color (player settings-driven index into player gradient,
  enemies color_index into enemy gradient) + bottom-bar UI coloring DONE;
  health bars DONE (always-on, above the entity's art top; depleted = theme
  darkest, fill = team gradient index 1; outline frame on top). Active-effect
  overlays DONE (front_effect_sprites from each effect's `effect_sprite`,
  centered on art bbox, tinted lightest; Reflect wired). Stun overlay DONE
  (persistent `effects/stun` icon above the health bar while `stun_duration
  > 0`, not an anim). See DONE.md.
- **Remaining 4b visuals** — gear + effect sprites, sprite animation (8 fps) +
  animated flag banner, ground items, decorations (footprint splitting DONE).
- **Input/camera leftovers** — tab-targeting (cycle highlighted tiles
  with Tab; reuse cursor resolution). Keyboard inspect binding (e.g.
  alt+Enter opens inspect on the tile-cursor entity): lands as an
  `Action.inspect_cursor` bool via `checkAction`, consumed in
  `handleIdleInput` where the tile cursor is resolved; right-click is the
  only inspect path today. (Right-click-drag camera pan DONE — see DONE.md.)
- **New-keybind pipeline friction** — a new keybind touches THREE places:
  the binding in `data/default_settings.txt`, the backend's key table
  (`raylib_backend.zig` `key_mappings` — only bound keys are mapped;
  unmapped keys never reach `translateInput`), and the Action/input
  plumbing. The ctrl+A select-all shipped broken because the backend
  entry was the one nobody remembers (see DONE.md, Level editor UI).
  Make the coupling visible instead: warn at startup (dev-mode console or
  the pending-error popup — advisory, not fatal) when a loaded binding
  names an input id no backend mapping can produce, and/or consider
  mapping the full W3C key set once so new bindings never need a backend
  edit (cost: a slightly bigger poll loop — it's a fixed array, likely
  negligible; verify with the input budget in mind). Either way, add a
  line to AGENTS → Dev Tools or the Input design note naming the three
  sites so the next binding doesn't rediscover this.
- **Decoration occlusion readability** — inset outline of entities / ground
  items / flag poles occluded by decoration overhang. Settled design — see
  DESIGN → Decorations & Footprint → Occlusion inset. Slices:
  - [x] Generalize `generateOutlineMask` to a `{outer,inner}` side (dual
        morphology; same separable structure, opacity test flipped by side);
        fix the stale `raylib_backend.zig:38-39` comment ("inner band" →
        outer). Add `inset_outline_cache` + `getInsetOutlineTexture` +
        `drawOcclusionInset` in raylib_backend.zig.
  - [x] `OcclusionInsetDrawable` on ViewState + occlusion test in `view()`
        (non-decoration entry vs decoration pieces with greater
        `groundEntryBefore` sort order + screen-rect overlap) →
        `occlusion_insets` slice.
  - [x] Backend: draw insets after the ground pass, before floating world
        overlays. Black, alpha 128, `outline_thickness` (8).
  - [x] Follow-up (separate slice): disk-SE outline for both outer + inner
        (smoother 45° corners; cached so the O((2t+1)²) cost is one-time per
        sprite).
- **Cross-cutting polish** — 9-slice edge/center TILING
  (corners are aspect-true — fixed, see DONE.md), `highlighted` edge
  outlines, missing art
  (ui/icon_swap, ui/momentum draw magenta). (Real TTF
  font + glyph metrics DONE — see DONE.md.) Gear-tooltip comparison
  colors are full green/red placeholders — artist to pick softer shades
  (`ui.positive_color`/`ui.negative_color`, shared by tooltip comparisons
  and combat damage/heal numbers).
- **Larger systems (beyond MVP)** — middle panels (inventory/gear/skills/enemy
  inspect) + overlays (world map, full combat log) + options/settings/top bar
  (drag-drop needs panels to be usable); NPC interaction/dialogue; audio.
- **Online services** — web database for leaderboards + custom content
  hosting/sharing. Builds on the custom-mission VFS acquisition path; see
  "Content Loading / Custom Missions" + "Online Services" below.
- **Error handling pass** — replace uniform fail-fast with the two-class
  policy (unrecoverable → panic; recoverable I/O failures → warn +
  degrade/revert via the popup). Settled design + B-simple recording in
  DESIGN → Error Handling. Slices:
  - [x] **Slice 1 — error surface:** `SessionState.pending_error` +
    `Action.dismiss_error` + `ui.buildErrorPopup` + `view()` wiring +
    modal input gate (`handleAnytimeInput` / `update()` pause). No real
    trigger yet; tests for the helpers + popup layout. History in DONE.md.
  - [x] **Slice 2 — startup-config fallback:** `session_setup.zig` loaders
    fall back to the embedded copy on shadow-parse fail + set
    `pending_error`; embedded fail still panics. `FileSource.readEmbeddedFile`
    + `loadConfigWithFallback` helper. History in DONE.md.
  - [x] **Slice 3 — in-event reconstruction reads:** the 6 handlers
    (`start_new_game` / `start_mission` / `start_level` / `start_hub` /
    `load_save` / `open_editor`) use `failReconstructionRead` on parse/load
    failure; the drain loop reverts to the last idle-point snapshot + trims
    `event_history` + surfaces `pending_error`. Replay panics (fail-fast).
    OOM still panics. History in DONE.md.
  - [x] **Slice 4 — writes/reloads:** `write_save` / `dump_event_log` →
    warn + popup + abort on failure (no crash, no revert needed — state is
    fine, just the file didn't write). Session-log `file_format_version`
    hard-gate softening deferred to the replay viewer (not user-wired yet).
    History in DONE.md.
  - [x] **Crash dump:** `@panic` writes `crashes/crash_*.txt` (a replayable
    session log) to the persistent dir before trapping, via a custom panic
    namespace in both entry files. Zig panics only (not SIGSEGV); web
    best-effort. See DESIGN → Error Handling → Crash dump. History in
    DONE.md.
- **Key validation (approach A)** — per-section key whitelists warn on
  unknown keys (the permissive parser silently drops them today; see AGENTS
  → Error Handling). Infrastructure: `parser.validateKeys` + comptime
  `std.StaticStringMap` key maps per file type. All file types wired: level,
  hub, mission, campaign, settings, color-theme, weapon-type, salvage,
  player-save, player-loadout. The `validateConfigKeys` helper
  (event_handlers.zig) centralizes the warning-collection + popup surfacing
  for in-event reads; `loadConfigWithFallback` (session_setup.zig) validates
  startup config. History in DONE.md.

KNOWN DEFERRED BUGS: (none currently — combat turn-flow issues from earlier
  playtesting are resolved.)
  chase individually — troubleshoot via the session log (logging has landed).

## Skill Logic

All 25 skills ported (no stubs); port history in DONE.md. Remaining:

- Wire weapon-type definitions (data) to reference each skill so they are
  equippable/testable (separate from the code port).
- Targeting (range, valid tiles, team filtering).
- Damage calculation with modifiers and effects.

## View Function Implementation

Phase 4 plumbing + tiles + entity base sprites DONE (history in DONE.md).
Reference notes that matter while working here (sprite/asset conventions):

- Entity + weapon assets share one 512×640 frame + pivot (0.5, 0.8)
  (normalized fraction; horizontal center, at the feet). Renderer aligns
  pivot → tile anchor; weapons register with no per-sprite offset. Source art
  is already at display resolution (512×640 single-pose, 256px/tile). Player
  bodies use weapons/<type>, enemies weapons/enemy_<type>; off-hand mirrored
  via flip_horizontal.
- Tiles: assets/world/tile.png (256×256; jagged edges overlap to outline the
  grid). Checkerboard tint per tile.
- Flag: static pole world/flag_pole.png (256×512 = 1×2, pivot 0.5/0.75) +
  animated banner world/flag.png overlaid (same frame/pivot). Same sprite
  for level-end and hub mission-start markers.
- Ground items: world/ground_items.png (256×256, centered pivot 0.5/0.5).

Open / in-progress:

- [~] TileOverlayDrawable slice (Phase 4.3): move-range HIGHLIGHTS
  (translucent fill over level.highlighted_tiles) + hover CURSOR (outline).
  Overlays have no art — renderer draws them as primitives. The cursor is
  derived in view() from the session pointer (screenToTile), replay-safe.
  range/radius outlines emitted on skill-slot hover (single bounding square,
  Chebyshev ≤ range else ≤ radius, extent = 2*N+1, theme lightest, unified
  8px thickness — see DONE.md). Radius outline also follows the tile cursor
  while a targeting+radius skill is prepared (e.g. Flash Strike). Aggro
  outline emitted while the entity-inspect panel is open (square centered
  on the inspected entity) — see DONE.md.
- [x] GroundDrawable slice: entities + flag poles + decorations + ground
  items all rendered, unified ascending (y, x) y-sort across entities +
  decoration pieces + level-end/mission-start markers (DONE — see
  DONE.md). Base sprite only (pivot 0.5/0.8).
- [~] Entity sub-layer assembly: base sprite + WEAPONS + entity LAYERS done.
  Effect overlays DONE (front_effect_sprites from each effect's
  `effect_sprite`, centered on the art bbox, tinted lightest; Reflect wired).
  Still TODO: gear sprites. Health bars DONE.
- Sprite animation (view-side, cosmetic; NEVER gameplay state, so replay-safe
  — frame is purely a function of wall-clock time, like the pointer/tooltip).
  Settled design + flag banner DONE — see DESIGN → Animation.
  - [x] `SessionState.animation_clock` (session-relative microseconds, pause-
        gated, advanced by `frame()`).
  - [x] `settings.animation_fps` (default 8) — the one global rate all anims
        read; frame duration = 1_000_000 / fps µs.
  - [x] Flag banner: `world/flag` (8 frames × 256×512) drawn over the pole
        via `LevelEndDrawable.banner_source_rectangle`, frame from the clock.
        Used for both level-end + hub mission-start markers.
  - [~] One-shot anims (attack swings, hit flashes, death dissolves):
        trigger in EVENT HANDLERS via `session.queueAnim` (gated `!replaying`,
        same shape as `queueSound`); `frame()` stamps `end_clock` from the
        live clock; `view()` gates by `event_index < current_event_index` AND
        `animation_clock < end_clock`; screen/world transition clears via
        `session.clearAnims()`. See DESIGN → Animation. Landed cases:
        skill-icon pop above the caster on `use_skill` (500ms, single-frame),
        placed above the entity's actual art top (runtime topmost-opaque-
        pixel scan, same lazy-cache shape as the outline-mask cache); hit
        flash on `attack`/`collision` (250ms, single-frame) — `world/hit_flash`
        centered on the defender's rendered art (horizontal frame center +
        vertical center of the opaque bbox via `sprite_bounds`), tinted with `active_theme.lightest`, only on
        nonzero damage; damage numbers on `attack`/`collision` (500ms) and
        heal numbers on `heal` (500ms) — float 1 tile eased with
        `tween.easeOutCubic` from the bbox edge/corner (damage: away from
        attacker; heal: up-right from top-left), `ui.positive_color`/
        `ui.negative_color` (heals green, damage red — including 0 values) +
        black text outline, per-entity 0.125s stagger.
    - [ ] Future: attack swings, death dissolves (multi-frame one-shots;
          same machinery, richer `AnimKind`).
    - [x] **Programmatic text outline** — DONE via the SDF text-outline
          pipeline (see DESIGN → Platform Seam → SDF text outline): build-
          time SDF glyph atlas + fragment shader replaces the 9-draw
          drop-shadow ring for `floating_text` + outlined UI labels. History
          in DONE.md.
  - Per-sheet frame data (count, frame size) hardcoded per builder for now
    (flag is the only animation); general per-sprite metadata table is the
    "Sprite asset metadata" item below.
- Decoration footprint splitting (per-tile pieces with source rectangles)
  DONE — see "Decoration Footprint" below.
- Sprite asset metadata (dimensions) DONE — `generated_sprite_metadata.zig`
  (build-time PNG IHDR scan, keyed by sprite id). Used by the parser to
  populate `Decoration.pixel_dims`; view splitting will read it from the
  stored field. Custom sprites resolve dims from PNG bytes at runtime.

## UI Framework — Panel Builders

Layout infrastructure + buildBottomBar + buildMainMenu + buildTooltip +
buildSkillTooltip + 9-slice + bottom-bar tooltips DONE (history in DONE.md).
Open:

- buildTopBar: options button (top-left), combat log summary.
- buildGearPanel: equipped gear slots (weapons, amulet, coat, gloves, pants,
  boots). DONE (slots + item icons + combat-stat sidebar + drag refs —
  see DONE.md).
- buildInventoryPanel: 8×12 grid, material counts on right side. DONE
  (grid + material sidebar + item icons + click/drag UX — see DONE.md).
- buildSkillsPanel: learned skills grid (draggable for swapping utility
  slots). Display slice DONE — 4-wide grid of learned skills in parsed
  order, scrollbar when overflow (wheel scrolls when the pointer is over a
  skills slot); drag refs emitted (drag-to-bar is a later slice). Sorting /
  grouping / search deferred. See DONE.md.
- buildEntityInspectPanel: entity stats, skill bar with cooldowns, active
  effects. DONE (right-click-to-inspect + read-only mirror of
  skills/effects/gear, team-gradient coloring — see DESIGN → UI Framework →
  Entity inspect).
- buildWorldMap: campaign graph visualization, clickable hubs/missions.
- buildFullCombatLog: scrollable detailed combat log (renders
  ViewState.combat_log; see Combat Log).
- **Settings screen** — settled design: DESIGN → UI Framework → Settings
  screen. Full-screen modal overlay (`UiState.settings_open`), reachable
  from the main-menu Settings button AND from a new "Settings" button in
  the options menu (level + hub; settings opens on top, Back returns to the
  options menu). Input bindings deferred. Slices:
  - [ ] **Slice 1 — overlay shell + options-menu wiring:** `settings_open`
        on `UiState`; `buildSettingsPanel` shell (full-screen `blocks_input`
        panel + Back button bottom-left, closes via `Action.open_settings`
        toggle). Gate `toggle_options_menu` (Escape) on `screen != .main_menu`
        (options menu not reachable from main menu — its exit buttons are
        nonsensical there). Add "Settings" button to `buildOptionsMenu` (all
        contexts it appears in). Main-menu `.open_settings` toggles
        `settings_open` (currently a no-op).
  - [ ] **Slice 2 — volume integer migration:** `settings_file_format_version`
        1 → 2; convert `master_volume` / `music_volume` / `sound_effects_volume`
        from f32 0.0–1.0 to u32 0–100 (loader + writer + defaults +
        `data/default_settings.txt`); parse clamps 0–100. Backend
        `applyVolumes` / `playSounds` convert `@as(f32, vol) / 100.0` at the
        raylib seam. Free pre-release migration (v1 user file → version gate
        → fallback to defaults → next write persists v2).
  - [~] **Slice 3a — toggles + choices + persistence:** `SettingId` enum
        + `SettingRef` on `Button`; `AnytimeInput.clicked_setting` for
        toggle/choice clicks (folded in main.zig release dispatch, the
        `clicked_save_row` pattern); `.change_setting` action routed through
        `options_action`. Toggles: vsync + the 2 gameplay bools. Choices:
        camera_zoom 4-button row (25/50/75/100), player_color_index 6-swatch
        row. `markSettingsDirty` on every change. DONE.
  - [x] **Slice 3b — sliders + audio live-apply:** new `slider` `UiElement`
        variant + `handleSliderDrag` (click-to-jump + drag-to-scrub, integer,
        step 1): render_fps_cap 0–256 (0 = "Uncapped" label), animation_fps
        1–16, the 3 volumes 0–100. `markSettingsDirty` on every drag step.
        Audio live-apply via `frame()` diff-and-apply
        (`SessionState.last_applied_volumes` snapshot → `backend.applyVolumes`
        on diff). VSync label shows "(change requires restart)". DONE.
  - [x] **Slice 4 — live-apply:** merged into 3b. `camera_zoom` /
        `render_fps_cap` / `animation_fps` already read live by `view()`/
        `frame()`; audio via the diff-and-apply; vsync restart-only. DONE.
  - [ ] **Deferred — text input widget:** freeform integer entry for
        `render_fps_cap` / `animation_fps` (currently sliders cover them).
        The WIDGET itself lands with the editor inspector (shared piece:
        DESIGN → UI Framework → Text input widget); this item reduces to
        wiring the two settings fields to it once it exists.
- buildOptionsMenu: settings controls (volume, gameplay toggles).
- buildMainMenu Continue availability: DONE — Continue now shows when
  PlayerData is populated OR an autosave exists; clicking it resumes (loads
  the autosave on a fresh launch, resumes from memory mid-session). See
  DONE.md (Autosave).
- buildMissionComplete: statistics, clone rewards, continue/retry. Clone
  system core DONE (uuid keying, pickup accumulator, save_clone_info,
  harvest_clones, end_level wiring) — see DESIGN → Clones (clone system).
  Panel DONE: header + left stats column (turns/tiles/skills/damage dealt/
  taken) + right clone-harvest material icons + bottom Continue/Replay/
  Overwrite Clone buttons (Overwrite Clone shown only when
  `overwrite_offered`).
- buildMissionFail: header text, exit/retry buttons.
- Middle section horizontal scroll when panels exceed width.
- Add icon_sprite_id to Skill, Item, and Effect definitions (bottom bar
  temporarily uses their name as placeholder icon id).
- Move UI sprite assets from Unity project. Done so far (in assets/):
  ui/icon_inventory,gear,skills,skip,options; ui/button_background; ui/turn_move,
  turn_attack; ui/skill_button; ui/skill_slot_empty; skills/*;
  ui/health_globe (+ _border); ui/panel; ui/salvage_tool. Still placeholder ids:
  ui/icon_swap, ui/momentum.
- Center cooldown/label text using measured text width — DONE (emitCenteredNumber
  measures the formatted number via FontMetrics; see DONE.md).
- Real font metrics — DONE: `ui.FontMetrics` (per-glyph advance table,
  UTF-8-aware) extracted from the loaded raylib `Font` by the backend and
  threaded through `RenderContext` into the builders. See DONE.md. Bold/italic
  still render as plain (only the regular face is loaded — separate follow-up).
- Author real tooltips on elements (skills: range/radius/cooldown rows;
  items; effects) using the span constructors.
- text_label hover bounds are a placeholder (boundsOf reports a font_size
  square, no measurement) — fine while no text label has a tooltip. Wire
  boundsOf for text_label to measureSpanWidth once the real font lands, if/
  when we want tooltips on text elements.
- Tooltip cross-axis clamp can still overlap the source in the degenerate
  case: `placeTooltip` (side-based, DONE — see DONE.md) picks the side with
  most clearance and aligns to the near corner, but on-screen clamping shifts
  the panel along the cross-axis; if the tooltip is larger than the available
  cross-axis space the clamp can pull it back over the source. Rare in
  practice (needs a tooltip taller/wider than the screen space on the cross
  axis); revisit if a large tooltip lands over its source.
- PLACEHOLDER ASSET: the original ui/panel.png was NOT a valid 9-slice source
  (a 176×176 rounded rect centered with a 104px transparent margin), so
  9-slicing collapsed it to thin lines. Regenerated procedurally as a proper
  edge-to-edge rounded panel. FLAGGED for the artist to produce a real 9-slice
  panel (border at the image edges, corner radius ≤ 128; a distinct opaque
  tooltip panel can be a separate sprite).

## Decoration Footprint

Settled — see DESIGN → Decorations & Footprint. WIRING progress:
- [x] Build-time sprite metadata table (`generated_sprite_metadata.zig` —
      pixel dims from PNG IHDR for every shipped `assets/**/*.png`).
- [x] `Decoration.pixel_dims` / `DecorationTypeDef.pixel_dims` field; parser
      resolves dims (comptime table for shipped, PNG-byte parse for custom via
      `?*const FileSource` on `loadLevel`/`loadHub`/`buildEditorMission`).
- [x] Parser: `footprint x y` lines (sprite-grid coords), anchor derivation
      (bottom-most-then-left-most), placement-invariant check (no tile under a
      footprint tile → `@panic`). `instantiateEditorLevel` carries `pixel_dims`.
- [x] View splitting (per-bbox-tile `DecorationPieceDrawable` with assigned
      footprint sort y + unified ground-drawable y-sort). Entities +
      decoration pieces + level-end/mission-start markers now share one
      ascending (y, x) sort. Shipped beginnings/level_1 +
      camp_at_the_crossroads carry sample decorations (ruin_*, stone_*).
- [x] Color indexing: `color_index` per decoration entry → world gradient
      color; view resolves it to the raylib tint. Default 0.
- [x] Multi-sprite layers: `layer` sub-groups (delimiter syntax) with
      sprite + color_index; validated same pixel dims as base; per-bbox-tile
      layer chunks drawn over the base. `DecorationLayer` type +
      `DecorationPieceDrawable.layers` slice.
- [x] `data/decorations.txt` registry (editor-palette prefabs — pending editor
      UI). Built + loader (`loadDecorationRegistry`) + validation wired; lands
      in the editor palette when the editor UI slice does.
- [ ] Editor custom-decoration acquisition (pick PNG → write to file source →
      resolve dims → `editor_add_decoration_type` event).
- [ ] Editor footprint editing event + UI.
- Open wiring-time details (from AGENTS): overhang sort x; tall multi-y
  footprints if such art ships.

## Input Resolution from ViewState

- Use previous_view_state to resolve screen position → tile coordinate.
- Replace direct camera math in translateInput.

(Other input resolution DONE — history in DONE.md.)

## Drag & Drop

Core lifecycle DONE (SlotRef/DragState, pointer, slotAt/slotRefAt,
handleDrag, drag ghost — history in DONE.md). The movement-threshold
click/drag disambiguation + inventory click intents (equip / salvage /
learn, with modifier + double-click UX) + drag refactor to orchestrators
are DONE — see DONE.md (inventory click+drag slice). Multi-salvage
(shift+drag a region in the inventory panel) DONE — see DONE.md. Open:

- Cancel drag / snap item back when the pointer release is lost outside the
  game (focus loss, pointer leaves window) — currently a lost mouse-up leaves
  the drag latched to the cursor.
- inventory → inventory move/swap event + handler (dragToOrchestrator
  returns null for now).
- Gear/skills panel builders must emit ref-bearing Slots before drag is
  usable in-game for those domains (buildInventoryPanel emits inventory
  refs already; buildGearPanel emits gear refs; buildSkillsPanel emits
  learned-skill refs — see UI section).
- Coordinate-space reconciliation with renderer: pointer→reference-space
  conversion and screenToTile share an unverified assumption (see rendering).

## NPC Interaction

- interact_with_npc handler (dialogue, shop, quest, etc.). The hub input
  path deliberately does NOT fire it yet — the handler is a `{}` stub and
  firing it would record a no-op undo step (clicks on NPC tiles do nothing;
  the click→push site is marked in handleIdleInput's hub branch). When the
  handler lands, re-wire that site and drop the move-blocker comment.
- NPC dialogue system
- NPC types (shopkeeper, quest giver, etc.)

## Level Editor

A custom-mission editor: mission + per-level tabs (quick swap to edit each
level) + a mission-shared palette of enemies / decorations / ground items.
Architecture is SETTLED — see DESIGN → Architecture → Level Editor for the
`Editor` type, the event family, the Option-2 framing + minimal exit guard,
the replay/cache story, AND the full UI layout + active-tool model +
`Selectable`-union selection model (tabs + viewport + bottom-bar palette +
left inspector; no dialogs; Test/Validate top-right; Upload deferred). Not
yet implemented. Remaining work:

- Types + framing event handlers DONE (`open_editor` / `close_editor` /
  `start_playtest` / `end_playtest` / `start_validation` / `end_validation` +
  `editor_set_active_level`; exit guard in `end_level` / `end_mission`;
  round-trip test). See DESIGN → Architecture → Level Editor.
- Edit-verb event structs DEFINED, handlers PENDING: every edit verb exists
  in events.zig but `handleEditorEvent` is a `@panic` stub (only
  `editor_set_active_level` is handled, inline in `processEvent`). Wiring
  the handlers is part of the UI slice.
- Editor input/UI: the settled layout/interaction design (DESIGN →
  Architecture → Level Editor → Editor UI layout — four zones: tabs,
  left inspector, viewport, right settings sidebar + bottom tool palette;
  plus the centered sprite picker, the gradient-picking level-theme model,
  and the editor drawable projection for the viewport). Build as a
  vertical slice — static shell first (tabs + viewport + bottom bar +
  inspector + settings sidebar rendering with real data, no interaction),
  then wire input per tool + the edit-verb handlers. Landed so far:
  the bottom tool palette (static shell — fixed tools + palette groups +
  plus cells + `Image.source_rectangle`), palette window scrolling
  (max 8 visible per group, wheel-over-group shifts the window — see
  DONE.md), the top row (options + undo buttons via the shared
  `buildTopBar`, plus 128px level tabs that switch the active level via
  `player_set_editor_level` — see DONE.md), the viewport world scene, and
  the first viewport-input slices: TILE PAINT (one click = one tile via
  `player_paint_editor_tile`; replaces covering decorations; tile-tool
  cursor outline drawn over empty space — see DONE.md + DESIGN → Level
  Editor → Active-tool model), ENEMY-TOOL PLACEMENT
  (`player_place_editor_entity`: occupant replacement — decorations
  deleted, missing tile placed, ground item deleted, existing enemy
  retyped in place, player start / level end never overwritten — see
  DONE.md), and DECORATION-TOOL PLACEMENT
  (`player_place_editor_decoration`: the inverse replacement — covered
  tiles erased with their occupants, overlapping decorations deleted,
  '!' / '=' never overwritten; continuous footprint-region outline
  preview — see DONE.md), and GROUND-ITEM PLACEMENT
  (`player_place_editor_item`: enemy-tool shape with the placement
  kinds' roles swapped — existing item retyped in place, enemy deleted —
  single-tile cursor — see DONE.md), the TOOL-INDEPENDENT RIGHT-CLICK
  DELETE (`player_delete_editor_at`: one thing per click — occupant,
  then covering decoration, then the bare tile; '!' / '=' / empty ground
  no-ops; clean-click-vs-pan disambiguation — see DONE.md), and the SELECT
  TOOL's plain-click selection (`types.Selectable` set on the Editor via
  the granular `editor_select`/`editor_deselect` events — undoable, see
  DESIGN → Level Editor → Selection model; lightest-color region
  outlines, hover preview, cleared on tool + level-tab change inside those
  events — see DONE.md), and the ACTIVE TOOL pointer onto the Editor
  (`Editor.active_tool` + `player_set_editor_tool`/`editor_set_tool`),
  and the INSPECTOR SIDEBAR SHELL (top-left toggle button below the
  options button + background panel, open by default; `Editor.inspector_open`
  + `player_toggle_editor_inspector` → `editor_toggle_inspector`, on the
  undo timeline — see DESIGN → Architecture → Level Editor → Editor UI
  layout). The inspector FIELD EDITOR design is settled (enemy types
  first): the coupling contract, controls per field, and event routing —
  see DESIGN → Architecture → Level Editor → Editor UI layout →
  "Inspector fields (enemy types — settled)" + DESIGN → UI Framework →
  Text input widget (the new shared widget: pure core, backend char seam,
  M2 focus semantics, commit-on-dismiss). Slices:
  - [x] **1 — text input core:** DONE — the pure `TextField` (buffer/
        caret/selection, codepoint-aware), the backend char seam
        (`pollInput` drains the platform char queue into
        `PlatformInput.text_characters`), UiState focus state
        (`text_edit` + `beginTextEdit`), routing (`routeTextInput` from
        `translateInput`: chars/keys → buffer, ALL bindings suppressed
        while focused), M2 press arbitration (`textEditPressProceeds` +
        `commitFocusedTextEdit` at the press-dispatch site), and the
        entity-name commit path end-to-end
        (`player_set_editor_entity_name` → `editor_set_entity_name`,
        no-op gate, undo). The caret/selection RENDER lands with slice 3
        (a field element must exist to draw it in).
  - [x] **2 — inspector content scaffolding:** DONE — target resolution
        (`editorInspectorEntityTarget`: the active enemy tool, else the
        empty-state hint; stale tool ids fall to the hint), the content
        plan (5 sections + 20 field rows over the full format field set,
        label-only — controls land with slices 3-5), view-relative
        windowed emission (10 fully-visible rows, the skills-panel model),
        the scrollbar (track + thumb in the right margin, only on
        overflow), `UiState.editor_inspector_scroll` + wheel routing over
        the open panel (one notch = one row; falls through when closed).
  - [x] **3 — scalar fields:** DONE (3a + 3b). 3b: the Color swatch row
        (enemy gradient, settings-screen pattern, same-value picks never
        fire), the displays_weapons toggle (shows the FORMAT's true/false
        vocabulary, highlighted while true), the four UNBOUNDED numeric
        stat fields (digits-only filter, u32-max clamp on overflow, empty
        buffer commits nothing, numeric would-change semantics so
        leading zeros don't false-positive), `Entity.textFieldValue` as
        the single value source (display + focus seed + would-change),
        and `editor_set_entity_momentum` REMOVED (not authorable).
  - [x] **4 — gear + weapons:** DONE (4a + 4b). 4b: the entries list is
        built per frame from the editor state (an equipped item adds its
        Name + stat rows after its slot row); weapon slots show the
        six-type inline row (`weapons/enemy_<type>` silhouettes on button
        backgrounds, the palette tool-cell class — pick-while-empty
        creates "New <Type>" damage 0, pick-while-equipped retypes keeping
        name/damage, Delete clears) and gear slots show Add/Delete
        ("New <Slot>" defaults); item stats clamp to the moved `max_*`
        bounds at commit. Slot controls route through three new actions
        (`.select_editor_weapon_type` / `.add_editor_item` /
        `.delete_editor_item`) with Button payloads
        (`editor_gear_slot` + `editor_weapon_type`).
  - [x] **5 — utility skills:** DONE — the utility-skill POLICY (one
        rule, five seams — see slice-5 part 1 in DONE.md) + the centered
        picker (the framework's first consumer): flat
        `utility_skills.utility_skill_ids` list + a None cell, modal
        (only its own actions run while open), close button top-right;
        the inspector's five slot rows are half-width current-skill
        buttons that open it; same-value picks close without recording.
  - [x] **Selection-inferred inspector target** — DONE: `editorInspectorTool`
        (ui.zig) resolves the inspector's tool from the active placement
        tool OR (select tool active) from the selection — every selected
        placement that references the SAME tool (kind + type_id); tiles /
        the '!' / '=' contribute nothing; ≥2 distinct tools (or mixed
        kinds) infer none → the "No tool selected" hint. `editorInspectorEntityTarget`
        is now a wrapper over it, so the inspector content AND every
        edit-action routing (input_handlers' commit sites, the skill
        picker) re-target automatically. Only enemy fields are built;
        inferred decoration/item tools fall to the hint until their
        inspector slices. History in DONE.md.
  - [ ] **6 — later: sprite picker + entity layers:** replaces the interim
        sprite-id text field; sprite resolution must PRIORITIZE `.png`s
        in the mission folder being edited (custom assets) over shipped
        sprites.
  - [x] **7 — inference: player as the fallback target:** DONE —
        `editorInspectorTarget` + `EditorInspectorTarget` (ui.zig), the
        player shell as the default inspector content, the commit-site +
        picker migration onto the target union, tests. History in
        DONE.md; settled rule in DESIGN → Selection model (Inspector
        tool-type inference).
  - [x] **8 — utility-skill row (both inspectors):** DONE — one
        `utility_skill_row` entry (label "Skill bar" + five 128×128
        slots, entity-inspect look, diamond when null, picker per slot),
        `emitInspectorUtilitySkillRow` gradient-parametrized for the
        player inspector's reuse. History in DONE.md.
  - [ ] **9 — player inspector:** entries over `player_def.template`
        with player-gradient coloring. Sections: an IMPORT button at
        the top (`player_import_editor_player` → `editor_import_player`
        — copy the session's PlayerData gear/inventory/equipped utility
        skills into player_def; NO PlayerData (fresh editor session) →
        parse `data/new_player.txt` and import that instead), gear
        (identical to the enemy section), the utility-skill row, an
        inventory placeholder (UI design open — deferred slice). NO
        name / sprite / base-stat sections — base stats are strictly
        enemy-authorable; the player template keeps the Entity
        defaults. `instantiateEditorLevel` resets inventory as a
        runtime field — entity 0 must carry
        `player_def.template.inventory` into the playtest player
        (equipped skills already survive).
  - [ ] **9b — playtest PlayerData: all skills learned + dormancy:**
        `start_playtest` / `start_validation` BUILD a playtest
        player_data from player_def (name / gear / inventory / equipped
        utility skills) with learned_skills = ALL utility skills — the
        editor player knows everything, so tome pickups read
        already-learned, skill-tome salvage is consistent, and any
        future learned-gated path is permissive (learned is NOT stored
        in player.txt — it's implied for the editor player). In-level
        events (use_skill_tome / salvage_item) mutate player_data
        DIRECTLY, so the session's real campaign data must survive:
        back it up on enter (`Editor.pre_playtest_player_data:
        ?PlayerData` — the dormancy pattern, snapshots carry it) and
        restore on `end_playtest` / `end_validation` (null backup =
        the fresh-session default).
  - [ ] **10 — player.txt format + max_player.txt:** player.txt becomes
        SAVE-SHAPED (MainHandWeapon/OffHandWeapon/Amulet/Coat/Gloves/
        Pants/Boots/Inventory/UtilitySkills + Metadata; no Info / stats
        / hubs / clones / UnlockedSkills — not authorable): rewrite
        `loadPlayerLoadout` + all four mission player.txt files
        (beginnings keeps its starter loadout). Author
        `data/max_player.txt` — a FULL player save (the future
        "start at endgame" option loads it as one): the 5 armor slots
        equipped at the `max_*` bounds, weapon slots + utility bar
        empty, Inventory = 2 of each of the 6 weapon types at
        `max_weapon_damage`, UnlockedSkills = all utility skills,
        DiscoveredHubs = every hub in main_campaign. `new_player.txt`
        stays as-is (both ship). `open_editor` load order: mission
        player.txt if present, else max_player.txt (loadout sections
        extracted from it). Future, with new-mission creation: a new
        mission's player loads max_player.txt.
  Deferred: drag-painting. Still-needed event
  structs: gradient-override setters. Default level template
  (`data/default_level.txt`). The `.editor` screen renders the top row +
  bottom tool palette + the viewport world scene (tiles, palette-resolved
  placements, `!`/`=` markers; camera centered on the active level's
  player_start, right-drag pan) — reachable via the main-menu "Editor"
  button. The shift+drag MARQUEE is DONE (select tool:
  `handleEditorMarquee` gesture + `player_select_editor_region` → granular
  `editor_select` adds skipping already-selected entries; footprint-
  intersection membership for decorations; an unpromoted shift release
  acts as a plain click — see DESIGN → Level Editor → Selection model +
  DONE.md). The selection DELETE is DONE too (Delete key →
  `player_delete_editor_selection` → `planEditorSelectionDeleteActions`:
  everything selected goes except the '!' / '=' and their tiles; a
  selected tile sweeps its occupant; per-kind high-before-low delete
  ordering; one undo step — see DESIGN → Level Editor → Selection model
  + DONE.md). Ctrl+D clear-everything DONE too (single
  `editor_clear_selection` event, gated on a nonempty selection — see
  DONE.md). Ctrl+A select-everything DONE too (`player_select_editor_all`
  → the marquee's granular-add planner with no region bound, skipping
  already-selected entries; select-tool-only, one undo step — see
  DONE.md). The selection MOVE is DONE (plain left-drag on a selected
  thing → `player_move_editor_selection` → clear phase + chained
  `editor_commit_selection_move` placement worklist via the existing
  planners; unselected occupants pin their tiles; markers move with a
  tile ensured underneath; targets on markers delete fully; deselects
  after; one undo step — see DESIGN → Level Editor → Selection model +
  DONE.md) — the selection operations are COMPLETE. The CLICK SEMANTICS
  are: plain click = REPLACE the selection with the clicked group (empty
  ground clears it — the clicky deselect-all); shift+click = TOGGLE the
  group; shift+drag = marquee add; plain drag on a selected thing = move
  (see DESIGN → Level Editor → Selection model). Remaining viewport
  INPUT: drag-paint. All tools
  have left-click input + cursor previews + the right-click delete.
  No-op clicks never fire: each tool's effect is computed by a pure
  planner (`planEditor*Actions`, event_handlers.zig) shared by the
  handler + the input layer, and an empty plan means no player action
  (no undo/replay pollution); exact-duplicate decoration placements
  (same type + anchor) no-op too. See DESIGN → Level Editor →
  Active-tool model; history in DONE.md.
- **Hook up the add-level "+" (top bar, right of the level tabs).** The
  square panel cell renders (inert, tooltip "Add level"); wiring it is a
  `player_add_editor_level` orchestrator + the `editor_add_level` handler
  (default template `data/default_level.txt` — which itself is still to
  be written) + `validatePlayerAction` arm. Same pattern as
  `player_set_editor_level`.
- **Hook up the palette "+" cells (add-new type).** Same shape: click →
  orchestrator → `editor_add_*_type` handler (currently panics).
- Validation result + replay attachment: on successful validation, attach a
  saved mission replay to the custom mission (next save writes it into the
  custom mission dir) for re-validation before uploading to the online
  database. NOT important right now — deferred with online services.
- Editor autosave: nice-to-have, not need-to-have (explicit save for now).

## Logging & Replay

Session log read/write/reconstruct + combat-log projection DONE (see AGENTS
→ Logging & Replay; history in DONE.md). Remaining:

- file_format_version: monotonic int per serialized artifact, in its Metadata
  section. Session log starts at 1; retrofit missions/saves as those formats
  stabilize (custom-mission support needs it). Also add a format_version to
  mission Metadata when custom missions land.
- Replay-viewer screen: wire .replay_viewer to STEP through a loaded log via
  reconstructFromEventLog/restoreTo at successive targets. Steps = the
  combat-log filter (derived, not idle_points). Needs the projection (DONE) +
  replay-viewer UI.
- formatSessionTimestamp is a generic time util living in main.zig — move to
  a small util/time module when the main.zig split happens.

Logging follow-ups (open):

- Replay structural whitelist + exit/skip orchestrators — DONE. A
  hand-crafted log could seed any machinery event at an idle point; now a
  two-layer gate (`isPlayerAction` structural whitelist + `validatePlayerAction`
  context legality) rejects non-player events. 5 new orchestrator events wrap
  the ambiguous exit/skip paths so the whitelist is a pure tag-check. See
  DONE.md + DESIGN → Determinism & Tiebreaking → Replay PLAYER-ACTION LEGALITY.
- Replay verification cross-session: `verifyReplayStep` now runs for
  cross-session `reconstructFromEventLog` too (a divergence is a real bug we
  want surfaced). The remaining gap is custom-mission cross-session replay
  where the mission files changed since the original session — that will
  panic until the reconstruction cache is serialized into the session log
  (`file_format_version` 2, lands with custom-mission sharing). See DESIGN →
  Determinism & Tiebreaking → Replay VERIFICATION.
- Exhaustive comptime round-trip test for the session-log writer/reader:
  inline-for over every Event category/variant, synthesize a payload (0 /
  false / first enum / "" / empty slice / null optional / recurse structs),
  write → parseConfigFile → loadEventLog → expectEqualDeep. Self-maintaining
  (new events covered automatically). Structural drift is already prevented
  by comptime + @compileError else-arms; this guards VALUE fidelity + the
  field-presence contract (writer emits every field; reader requires every
  non-optional field).
- Combat reconstruction test: extend the runToIdle harness to enter
  beginnings' level and script a few combat actions with ADAPTIVE
  targeting (read enemy position from live state), then serialize → load →
  reconstruct → expectEqualDeep. Self-referential (no golden values). Guards
  handler PURITY (state,event)→state, not AI determinism. NOTE: runToIdle
  clearing `waiting` becomes load-bearing here (enemy turns inject waits;
  replayTo clears waiting, so forward play must too, or the deep-equal
  spuriously fails).

## Combat Log (projection DONE; rendering TODO)

- Collapsed icon-based recent-history view in the top bar (coarse tier,
  last N) — buildTopBar. Maps ViewState.combat_log events to display strings
  with names from current_state.
- Expandable full-screen detailed combat log (buildFullCombatLog overlay;
  coarse + fine interleaved chronologically). Same projection drives it.

## Mission Flow

- mission_fail screen DONE — view-derived overlay (player health == 0),
  not a flag or Screen variant. See DONE.md.
- mission_complete screen DONE — SessionState flag set by end_level on last-
  level completion; overlay renders in the hub post-transition. Header +
  stats column + clone-harvest rewards + Continue/Replay/Overwrite Clone
  buttons. Clone system DONE (see DESIGN → Clones). See DONE.md.
- New Screen variants and transition events.
- Quit-to-menu and death/mission-fail exits MUST route through end_level /
  end_hub so entity changes persist into PlayerData (see DESIGN →
  Architecture). The options-menu exit paths (exit to main menu, exit
  mission, restart mission) are DONE — they route through end_level with a
  `LevelExitContinuation` override + build_data_from_player sync. The
  mission_fail + mission_complete buttons reuse the same restart/exit
  actions.

## Platform Layer (raylib)

Native + web builds DONE (history in DONE.md; seam in DESIGN → Platform Seam).
Open:

- 9-slice REFINEMENT: corners now render SQUARE 1:1 on any panel size
  (fixed — see DONE.md); remaining gap is edges + center STRETCHED, not
  tiled. Spec wants tiling — only matters once patterned panel art ships
  (current ui/panel.png is a flat fill).
- Draw offset support (decoration overhang; SpriteDrawable.draw_offset).
- Programmatic edge highlight for highlighted Button/Image (shader outline of
  opaque pixels, or fallback highlight sprite) — currently ignored.
- Real font: TTF loaded + per-glyph metrics feed the ui.zig measurement seam
  (DONE — see DONE.md). `drawTextLabel` still ignores bold/italic (only the
  regular face is loaded); honoring TextLabel bold/italic + color is a
  follow-up (needs separate bold/italic faces).
- Missing-art audit: some bottom-bar sprite ids are still placeholders
  (ui/icon_swap, ui/momentum) and will draw magenta until
  real assets land.
- Web Phase 4: asset downscaling for web download budget (the Memory & Budget
  → Asset memory levers matter more for web than native); WebGL1/WebGL2 build
  option; emrun polish.
- Web save via browser download prompt: DONE — the options-menu "Export
  Save" button writes the timestamped save to IDBFS and triggers a browser
  download of it (autosave stays IDBFS-only). See DESIGN → File System & IO
  → Web save export.
- Web save import (file picker → saves/ → load): DONE — "Import External
  Save" in the load-save browser. See DESIGN → File System & IO → Load-save
  browser + web save import.
- Load-save browser: DONE (scan/rescan/scroll/import per DESIGN → File
  System & IO → Load-save browser). It is deliberately barebones — the real
  UI treatment (columns: player name / hub / timestamp formatting, richer
  row visuals, keyboard navigation) is a future polish slice when the UI
  design settles.

## Audio

Architecture DONE — see DESIGN → Audio. Sound queue on `SessionState`,
backend sfx cache + looping music stream, `frame()` drains + updates music.
All shipped sfx wired except the two that wait for mission end-state screens.
Open:

- `defeat` DONE — wired in the `death` handler when the player dies
  (entity_index == 0), gated `!replaying`. `mission_completion` DONE — wired
  in `end_level` when the last level completes, gated `!replaying`.
  Cantrip/enchantment/curse currently reuse the `spell` sound (placeholder
  until dedicated assets ship).
- Options menu volume controls (settings fields exist; UI is the TODO
  `buildOptionsMenu`). `applyVolumes` is called at init; re-call it when the
  settings change in the options menu so volume adjusts live.
- Web autoplay policy: browsers may block audio until a user gesture. The
  stream no-ops until then by design; verify it resumes after the first click
  on the web build.
- Tune volumes / mix against real assets (current volumes are the Unity
  defaults carried over).
- Per-sfx cooldown in `playSounds` if multi-hit overlap (N `attack` events
  in one frame → N damage sounds) sounds bad. Trigger sites stay clean; the
  throttle is backend-only.

## Memory / Budget

Settled decisions + reasoning in DESIGN.md → Memory & Budget. Open work:

- Tune caps + wasm budget from real measurements: add peak-usage reporting
  via DebugAllocator (once a real level is drivable), then set the true caps +
  safety ceiling from actual numbers instead of the current estimates
  (max_entities=256, max_tiles~10k, ceiling ~256–512 MB).
- Confirm whether source sprites are animation sheets before downscaling
  (affects how far we can shrink — see DESIGN → Memory & Budget → Asset
  memory, lever 1).

## Content Loading / Custom Missions

DESIGN SETTLED — see DESIGN → Custom Missions & Online Services (dreams,
browser, content identity/hash, balance bounds, auth/server). This section
kept for active task pointers; prose moved to AGENTS.

File layer DONE (embedded map + persistent dir + FileSource; see DESIGN →
File System & IO). The VFS layer (layer 1 of the read order) is the only
piece still outstanding — it lands with custom-mission support. Forward-
looking:

- Core principle: SEPARATE acquiring a mission from reading it. Acquisition
  (upload dialog / directory scan / online fetch) is one-time, possibly
  interactive or async. Reading mission files during gameplay AND replay
  must be synchronous, silent, repeatable.
- Acquisition impls (into the VFS layer of FileSource):
  - zip upload (browser dialog): extract to in-memory VFS (path→bytes)
  - custom directory: Dir-backed at a chosen path
  - online database: fetch by immutable id/url → cache into in-memory VFS
    (see Online Services)
- Replay-safety falls out for free: dialog/fetch happens in an acquisition
  step (idle input), never in an event handler. The recorded event is
  start_mission referencing an already-resident source, so replay re-reads
  silently and never re-fires the dialog (same pattern as load_save's picker).
- Caching: acquire once, cache raw bytes; future reads (replay re-loads,
  retry, renderer asset loads) hit the cache. Real win is avoiding expensive
  re-acquisition (network re-fetch / zip re-decompress), not re-parse. Cache
  is session-scoped — a fresh session re-acquires unless persisted.
- Async wrinkle: online fetch / zip read is async on web. Acquisition must
  fully populate the source ("loading mission…") before emitting
  start_mission.
- Cross-session replay reproducibility: a shared/saved replay of a custom
  mission is only reproducible with the exact mission bytes. Mission refs
  should eventually be content-addressed (hash) or pinned to an immutable
  version id — matters for recorded-history-as-test and replay sharing.

## Online Services

Web database for leaderboards + custom content hosting/sharing. Builds on
the custom-mission online-acquisition path (Content Loading above). Not yet
designed:

- Leaderboards: what's scored (mission completion time? score? both?),
  scoring source (event_history-derived vs server-validated), anti-cheat
  considerations (server-side replay validation ties into the advisory
  game_version / future content-hash work). The client-side player-action
  legality gate is DONE — `validatePlayerAction` (state.zig) rejects
  impossible moves / unequipped or on-cooldown skills / invalid targets at
  the replay-seam; see DESIGN → Determinism & Tiebreaking → Replay
  PLAYER-ACTION LEGALITY validation. Server-side validation reuses this.
- Custom content hosting: upload/download of missions (+ replays?),
  content-addressing (hash) for reproducibility, moderation, metadata.
- Auth/identity model (if any).
- Server component: out of scope for the single-file exe — a separate
  backend. The game client only needs a thin HTTP fetch/submit seam.

## Rename to taplop + migrate to GitHub

The game's name is taplop (friends already call it that); "ziglop" is a
development codename that never should be player-facing. Rename + migrate
as ONE task at the playable-demo milestone (the data-dir rename is free
pre-release — no real players with saves yet — and the web build's
URL/filename starts mattering exactly when GitHub Pages hosting does).
Do it as a dedicated focused session, not interleaved with feature work;
do the whole sweep or don't start (a half-renamed project is worse than
either clean state).

The project is currently on sr.ht; there is no GitHub repo yet. Migrate
to GitHub as part of this task so GitHub never knows "ziglop" existed.

Steps:
1. Free the name: rename the Unity repo on GitHub `taplop` → `taplop-unity`
   (Settings → Rename; GitHub auto-redirects old URLs, so existing links
   keep working — stars/watchers/history all follow).
2. Migrate: create a new GitHub repo named `taplop`, push the sr.ht history
   up (`git remote add origin <github-url>` + push, or `git push --mirror`
   for everything). Keep sr.ht as a mirror or archive it (don't delete —
   avoid surprise 404s).
3. Code sweep, one commit on top of the migrated history:
   - `build.zig.zon` package name
   - exe name (`build.zig`)
   - web build output (`ziglop.html` → `taplop.html` or `index.html`)
   - persistent data dir `~/.ziglop/` → `~/.taplop/` (the one player-facing
     surface that's annoying to migrate later — free now, costly post-release)
   - doc references: the `https://github.com/LinusWeggeHjalsted/taplop`
     URLs in AGENTS.md + DONE.md → `taplop-unity` (those currently point at
     the Unity project, which is now at `taplop-unity` after step 1)
   - any remaining internal "ziglop" strings
4. GitHub Pages: project sites serve at
   `linusweggehjalsted.github.io/taplop/` (a SUBPATH, not repo root).
   raylib/emscripten web builds default to assuming root, so the HTML needs
   relative asset paths or a `<base>` tag / build-time base-path config.
   Solve this here, not on demo day.

Reversible throughout (GitHub renames back if needed; redirects cover the
transition). Never delete-and-recreate to shuffle names — rename always,
or GitHub's redirect gets shadowed.


## Determinism & Tiebreaking

Convention in DESIGN → Determinism & Tiebreaking. Replay is immune to
decision nondeterminism (records events), but ordering is made DEFINED for
live behavior + future input-based replay. All audit sites are now explicit
(turn_end enemy ordering breaks distance ties by entity_index;
enemy_turn_move nearest-target loop documents the lowest-entity_index
resolution; reachable-tile fallback uses `tileBefore` with the (x,y)
convention). History in DONE.md.

Already total (no action): A* comparePathNodes (f→x→y); entity draw sort
(unique positions, visual-only).

## Tech Debt / Refactoring

Done items in DONE.md. Open:

- **Frame-level player actions — keep the exception list closed.** Exactly
  one exists (the text-field keyboard resolution; see DESIGN → Architecture
  → "Frame-level player actions" for the contract it breaks + the
  obligations it carries). If a SECOND once-per-frame action ever lands,
  extract a shared push-and-record helper (push + drain +
  maybeRecordIdlePoint) so the idle-point step can't be forgotten — and
  treat any new frame-level action with suspicion: it must PROVE it can't
  run inside update().

- **Unify the panel-toggle convention into GameState.** The in-game middle
  panel toggles (inventory/gear/skills/entity-inspect, hub + level
  screens) are direct `UiState` writes — off the undo timeline — while the
  editor inspector toggle rides GameState via `editor_toggle_inspector`
  (on the timeline; required there for auto-open-on-creation + replay
  reproduction — see DESIGN → Architecture → Level Editor → Editor UI
  layout). We want ONE convention: migrate the middle-panel open/close
  flags onto GameState events (undo over panel toggles comes with it) the
  next time that subsystem is touched. The palette accordion
  (`editor_palette_collapsed`) can stay UiState — it's a pure view
  affordance with no handler-mutated state.

- [x] **Split AGENTS.md → AGENTS.md + DESIGN.md** — done; history in DONE.md.

- **`floatWorldPoint` precision loss.** `floatWorldPoint` (input.zig)
  takes `types.ScreenPosition` (i32) but its doc claims sub-tile precision
  for the camera-pan anchor. The precision is lost upstream: `translateInput`
  truncates `mouse_screen_position` (`PointerPosition`, f32) to
  `PointerInput.position` (`types.ScreenPosition`, i32) before
  `floatWorldPoint` ever sees it. So the pan anchor is at integer-pixel
  precision — may jitter at low zoom. Fix: make `PointerInput.position` a
  `PointerPosition` (f32) so the raw pointer precision flows through to
  `floatWorldPoint`; UI hit-testing sites that read `pointer.position`
  (`handleDrag`, `handleIdleInput`, `handleCameraPan`'s `blockingElementAt`
  check) call `.toScreenPosition()` at the UI seam. The rename made this
  visible (the type name now clearly says i32 where f32 was intended).

- **`WorldOverlayDrawable` variant consistency.** `floating_icon` uses a
  named `FloatingIconDrawable` type; `floating_text` is an inline anonymous
  struct. Pure consistency nit — extract a `FloatingTextDrawable` named
  type if a second text-overlay consumer lands or if the union grows.

- **`RenderContext` backend-derived-value fields are ad hoc.** Two
  precedents now thread a backend-derived value into the pure/raylib-free
  `view()`: `font_metrics` (a value struct) and `sprite_bounds` (a
  frame-arena `StringHashMap`). Different shapes, both fine on their own.
  If a third backend-derived value lands, the `RenderContext` struct starts
  reading like a grab bag — consider a small "backend-provided context"
  sub-struct or a named bundle instead of another top-level field. No
  action now; flag for the next time one is added.
- [x] **Split `parser.zig`** into a generic format layer + loaders + writers + session log — done; history in DONE.md.
- [x] **Test harness writes `saves/autosave.txt` into cwd** — fixed: the
      harness `FileSource` now uses a scratch dir
      (`zig-cache/test-harness-persistent`), and `scripts/test.sh` cleans
      `saves/` (main.zig tests still exercise write_save through cwd-backed
      sources — inert artifacts, just tree pollution). History in DONE.md.
- Test coverage for processEvent handlers: DONE across all four tiers.
  Harness: `src/test_harness.zig` (`Harness.init` + `newHistory` +
  `runToIdle` + `levelStateWithEntities`/`levelEntity` + smoke test).
  Tier 1 gear/skill mechanics (`src/handler_tests_gear.zig`, 22 tests).
  Tier 2 combat primitives + gear side effects
  (`src/handler_tests_combat.zig`, 34 tests). Tier 3 AI
  (`src/handler_tests_ai.zig`, 15 tests). Tier 4 turn-flow orchestrators
  (`src/handler_tests_turnflow.zig`, 22 tests: turn_start cooldown/effect/
  stun/branch/dead, turn_end enemy ordering by distance-then-entity_index +
  inactive/dead skip + turns_spent + non-player no-push, player_turn_move/
  attack phase + auto-skip + force override, player_move_action/skip_move/
  skip_attack/cancel_skill/use_skill orchestrator fan-out LIFO order).
  Total: 93 handler tests (161 with the pre-existing 68). All confirm-exist
  (no logic fixes). Self-referential asserts; scalar-field comparison
  (runToIdle compacts the arena — slice PTRS change, contents survive).
  Orchestrator/ordering tests call `processEvent` once + inspect
  `event_stack` (LIFO order) rather than `runToIdle`. FUTURE: keep adding
  tests when new handlers land (editor events are the next big set).
  **Coverage gap: the "boring" primitives.** Coverage is concentrated on the
  "interesting" verbs (combat, AI, turn-flow) and thin on the boring
  primitives (`swap_positions`, `retreat`, `swap_hands`, the cantrip handler
  arms). `swap_positions` had NO test before it was rewritten to compose
  `move_entity` — the rewrite changed behavior and nothing caught it either
  way. The boring verbs are exactly where sibling-drift bugs live (see
  DESIGN → Architecture → "Prefer composing"). A coverage matrix (event
  variant → has at least one test) would surface the gaps mechanically;
  `pushAndRunSub` makes adding them cheap. Prefer CONTRACT tests (player-
  visible behavior) over MECHANICS tests (implementation details) — the old
  `aggro_around` tests locked in the mover-centric bug by asserting the
  mechanic ("mover's range is used") instead of the contract ("entities
  aggro when they detect an opponent").
- Consistent slot-index bounds checking: utility-skill handlers guard
  slot_index < utility_skill_count, but equip_item/unequip_item/learn_skill/
  salvage_item index inventory.slots[...] directly (panic on out-of-range).
  Pick one convention (guard everywhere, or trust the source everywhere),
  keeping in mind events can also originate from save/replay data.
- Consider splitting processEvent handlers by scope (player/level/hub/meta)
  into separate files for readability once it grows further.
- **Duplicated rendering recipes in `buildEntityInspectPanel`.** The skill-
  button visual (frame + icon + cooldown overlay + empty-diamond marker)
  and the gear-slot visual (slot frame + item icon + tooltip) are inlined
  in the inspect panel instead of reusing `emitSkillButton` /
  `buildGearPanel`'s `emitGearSlot`, because those are hardcoded to the
  player entity + carry `Action`/`SlotRef` (interactive). The inspect panel
  is read-only. If the skill-button or gear-slot visuals change, both sites
  need updating. Refactor to a shared core taking an entity + a read-only
  flag — deferred (a deliberate cleanup slice, not urgent).
- **Test values that miss edge cases.** Three bugs this session were
  invisible to passing tests because the tests used "nice" values: (1)
  `computeHarvest` tests used cleanly-divisible ratios (10/5, 6/3) so the
  multiply-before-divide vs divide-before-multiply order didn't matter;
  (2) the `loadPlayerSave` round-trip test passed `warnings: null` so
  `validateKeys` never ran, hiding the missing `mission_uuid` whitelist;
  (3) no test covered `on_end_turn` at all, let alone the LIFO ordering
  against round-building. Recurring shape: tests exist + pass but don't
  exercise the boundary. A convention ("use awkward values" — fractional
  rates, non-null warnings, empty/edge states) or a coverage matrix would
  help. The inventory click path was the same shape — `resolveInventoryClick`
  had zero coverage, so the `>=` threshold bug (click-to-equip was dead code)
  was never caught. Not actionable as a single task; keep in mind when
  writing new tests.
- Snapshot/checkpoint ring buffers are a clean FIFO (slot = ring_index %
  size = oldest), but discardFutureTimeline nulls ahead-of-branch slots,
  leaving holes the marching ring_index won't preferentially reuse — so
  after an undo-branch we may briefly hold fewer live snapshots than
  capacity (occasional extra replay on a far undo). Harmless, never wrong.
  Deliberately left as-is: the quick "prefer a null slot" fix breaks the
  FIFO/oldest-eviction property; doing it properly means explicit victim
  selection (evict smallest event_index / a monotonic insertion counter,
  preferring nulls) in takeSnapshot + setCheckpoint. Revisit only if undo
  latency is felt once a real clock + big levels exist, and size the rings
  from real measurements then (see Memory / Budget).
- **UNDECIDED:** the ~26 `current.level.?` force-unwraps in level/sub-level
  handlers. Currently safe by invariant (those events only run in a level;
  event stack cleared on screen transition), so they act as fail-fast
  assertions. Leaving as-is for now; options if revisited: (A) keep, (B) one
  guard at dispatch that returns (risks hiding bugs), (C) a levelPtr() helper
  with a descriptive @panic. See DESIGN → Architecture note.
