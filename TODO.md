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

- **Census-test sweep (the next session's task)** — apply the settled
  test design (DESIGN → Testing) to the brittle census tier, file by
  file: derive windows/counts where the constants exist, replace pinned
  windows with exhaustiveness properties, DELETE the subsumed tests
  (strength is the criterion, not count), and hoist the
  mismatch-printing census helper (`expectInspectorLabels` is the
  pattern). Motivated by the 128px top-bar change breaking ~15
  window-census tests whose semantics were unchanged (DONE.md, "Top
  bar shrunk to 128px"). The design landed this session; the sweep is
  the implementation.
  Progress: `src/test_ui_census.zig` (the shared helper) + the
  editor_inspector.zig conversion DONE (slice 1 — DONE.md); remaining
  files: handler_tests_editor, editor_shell, editor_pickers, menus,
  panels, screens, view.
- **Combat-log UI** — render ViewState.combat_log (top-bar coarse recent-icons
  view + full-screen detailed log). Projection is DONE (combat_log.zig); see
  "Combat Log" below.
- **`toggle_options_menu` rename** — unblocked by the per-action binding
  overlay (a renamed action self-heals to its new default on existing
  installs — history in DONE.md); pick up whenever.
- **Art report (machine-derived asset inventory)** — a scripts/art_report.sh
  (the sound_report.sh pattern): every sprite id the game can consume with
  shipped/placeholder/missing status, resolved against assets/ + the
  persistent dir — the artist's self-updating shopping list; replaces the
  hand-maintained missing-art notes scattered below.
- **Palette shortcut-number surfacing (polish)** — the editor 1–5
  tool/palette keybinds could show their shortcut numbers in the palette UI
  (fixed-tool labels "1 Select", group headers "Entities 3", or tooltips).
- **Replay viewer** — wire the .replay_viewer screen to STEP through a loaded
  log. The `--replay <path>` CLI flag (DONE — see DONE.md) loads a session
  log and reconstructs the session to its END state (resume mid-session);
  the in-game viewer is the stepping UI on top of the same machinery. See
  "Logging & Replay" below.
- **Mission end states** — mission_complete / mission_fail screens + player
  death. See "Mission Flow" below.
- **Remaining 4b visuals** — gear + effect sprites, sprite animation (8 fps) +
  animated flag banner, ground items, decorations (footprint splitting DONE).
- **Input/camera leftovers** — tab-targeting (cycle highlighted tiles
  with Tab; reuse cursor resolution) + keyboard inspect binding (e.g.
  alt+Enter opens inspect on the tile-cursor entity; lands as an
  `Action.inspect_cursor` bool via `checkAction`, consumed in
  `handleIdleInput` where the tile cursor is resolved; right-click is the
  only inspect path today). (Camera clamping + editor viewport framing
  DONE — DONE.md; design: DESIGN → Platform Seam → Camera clamping.)
- **Input dispatch convergence (planned refactor — design before code).**
  `translateInput` sets the `anytime`/`idle` input flags directly (~40
  `checkAction` lines), while button releases fold through
  `applyAction` — TWO hand-maintained copies of the same action→flag
  mapping. Consequences: no single consumption choke point (the button-layer
  sound wiring was a ~25-site hunt across `handleAnytimeInput`'s flag
  sections; the `options_action`/`menu_action` switches covered ~50 actions
  in one line each because they already converge), and every new keybind
  keeps the five-places pipeline above. Plan: route `translateInput`'s
  keyboard actions through `applyAction` (the one mapping) + a
  fired-actions record on `PlayerInput`, giving ONE dispatch choke point
  for per-action behavior (action sound layers now; analytics/policy
  later). Fold the `input_handlers.zig` SPLIT (2800+ lines, ten concerns)
  into this work — if the convergence lands well, the file may split
  naturally or not need it; don't split as a separate chore first.
- **New-keybind pipeline friction** — five wiring sites per keybind (the
  map: DESIGN → Input → New keybind wiring sites). Still open: warn at
  startup (dev-mode console or the pending-error popup — advisory) when a
  loaded binding names an input id no backend mapping can produce, and/or
  map the full W3C key set once so new bindings never need a backend edit
  (cost: a slightly bigger fixed poll loop — verify with the input budget
  in mind). The action↔context validity half landed with binding contexts
  (load-time warn + drop — DESIGN → Input → Action↔context validity).
- **Cross-cutting polish** — 9-slice edge/center TILING (corners are
  aspect-true — DONE.md), `highlighted` edge outlines, missing art
  (ui/icon_swap, ui/momentum, ui/icon_undo draw magenta — and the global
  top bar's redo button flips icon_undo as its glyph until icon_redo
  lands; skills/meteor icon is the renamed daze.png placeholder — artist
  to draw a real meteor icon), and
  gear-tooltip comparison colors — full green/red placeholders, artist to
  pick softer shades (`ui.positive_color`/`ui.negative_color`, shared by
  tooltip comparisons and combat damage/heal numbers).
- **Larger systems (beyond MVP)** — middle panels (inventory/gear/skills/enemy
  inspect) + overlays (world map, full combat log) + options/settings/top bar
  (drag-drop needs panels to be usable); NPC interaction/dialogue; audio.
- **Online services** — web database for leaderboards + custom content
  hosting/sharing. Builds on the custom-mission VFS acquisition path; see
  "Content Loading / Custom Missions" + "Online Services" below.
KNOWN DEFERRED BUGS: (none currently.) When one appears, troubleshoot
via the session log (logging has landed).

## Skill Logic

All 25 ported skills done (history in DONE.md). The remaining designs
(from the original Unity design doc) are triaged into tiers; each new skill
lands with AI priority + target selection + tests in `src/skill_tests.zig`.

- **Playtest-dependent: swap/blink adjacent repositioning** — swap (and
  blink) can fire a pointless ADJACENT reposition; decide from playtest
  texture whether to gate (chebyshev > 1 on the chosen target) — adjacent
  swaps might be deliberate displacement. (Non-ending pool rating audit
  DONE — DONE.md.)
- [ ] **Tier B — small engine additions** (gap → the skills it unlocks):
  - effect-kind classification (enchantment vs curse) → cleanse,
        disenchant
  - momentum-gain transform hook (intercept-style) → mark of the snail,
        deacceleration, that which accelerates
  - movement hook (on_move in move_entity) → explosive stride. OPEN:
        voluntary moves only, or forced (knockback/retreat) too?
  - event context in on_* callbacks (defender / applied damage) → that
        which splinters, that which leeches
- [ ] **Tier C — design sessions before any code**:
  - per-instance effect data (caster reference, dynamic modifiers,
        cast-time snapshots; extends create_effect + the session-log
        schema) → mark of pain, glass form, mark of the wasp,
        weightlessness, temporal anchor
  - extra-turn mechanism (round builder consumes a counter) → time walk.
    OPEN: stacking; enemy-cast semantics.
- Wire weapon-type definitions (data) + the WeaponType enum (idol,
  crossbow — "wand" in the design doc was renamed staff) so the new
  weapons' skills are equippable/testable (separate from the code port).

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
- [~] Entity sub-layer assembly: base sprite + weapons + entity layers +
  effect overlays + health bars DONE (DONE.md). Still TODO: gear sprites.
- Sprite animation (view-side, cosmetic; NEVER gameplay state, so replay-safe
  — frame is purely a function of wall-clock time, like the pointer/tooltip).
  Looping machinery DONE (animation clock, `settings.animation_fps`, the flag
  banner) — see DESIGN → Animation + DONE.md.
  - [~] One-shot anims: trigger in EVENT HANDLERS via `session.queueAnim`
        (gated `!replaying`, same shape as `queueSound`); `frame()` stamps
        `end_clock` from the live clock; `view()` gates by `event_index <
        current_event_index` AND `animation_clock < end_clock`; screen/world
        transition clears via `session.clearAnims()`. Landed: skill-icon
        pop, hit flash, damage/heal numbers, the SDF text outline (history in
        DONE.md).
    - [ ] Future: attack swings, death dissolves (multi-frame one-shots;
          same machinery, richer `AnimKind`).
  - Per-sheet frame data (count, frame size) hardcoded per builder for now
    (flag is the only animation); per-sprite pixel dims live in
    `generated_sprite_metadata.zig` (DONE).
## UI Framework — Panel Builders

Layout infrastructure + buildBottomBar + buildMainMenu + buildTooltip +
buildSkillTooltip + 9-slice + bottom-bar tooltips DONE (history in DONE.md).
Open:

- buildTopBar: options button (top-left), combat log summary.
- buildSkillsPanel: sorting / grouping / search deferred; drag-to-bar is a
  later slice (display slice + drag refs DONE — DONE.md).
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
  - [ ] **Settings numeric fields → text input:** wire freeform integer
        entry for `render_fps_cap` / `animation_fps` to the text-input
        widget (landed with the editor inspector — DESIGN → UI Framework →
        Text input widget); sliders currently cover them.
- buildOptionsMenu: settings controls (volume, gameplay toggles).
- Middle section horizontal scroll when panels exceed width.
- Add icon_sprite_id to Skill, Item, and Effect definitions (bottom bar
  temporarily uses their name as placeholder icon id).
- Move UI sprite assets from Unity project — remaining placeholder ids:
  ui/icon_swap, ui/momentum (shipped-so-far list in DONE.md; also tracked
  under Cross-cutting polish missing art).
- Author real tooltips on elements (skills: range/radius/cooldown rows;
  items; effects) using the span constructors.
- text_label hover bounds are a placeholder (boundsOf reports a font_size
  square, no measurement) — fine while no text label has a tooltip. Wire
  boundsOf for text_label to measureSpanWidth (the real font + FontMetrics
  have landed) if/when we want tooltips on text elements.
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

Settled + wired — see DESIGN → Decorations & Footprint (history in
DONE.md). Open:
- [ ] Editor custom-decoration acquisition (pick PNG → write to file source →
      resolve dims → `editor_add_decoration_type` event).
- Open wiring-time details (from AGENTS): overhang sort x; tall multi-y
  footprints if such art ships.

## Input Resolution from ViewState

- Use previous_view_state to resolve screen position → tile coordinate.
- Replace direct camera math in translateInput.

(Other input resolution DONE — history in DONE.md.)

## Drag & Drop

Core lifecycle, click/drag disambiguation, inventory click intents,
multi-salvage — all DONE (DONE.md). Open:

- Cancel drag / snap item back when the pointer release is lost outside the
  game (focus loss, pointer leaves window) — currently a lost mouse-up leaves
  the drag latched to the cursor.
- inventory → inventory move/swap event + handler (dragToOrchestrator
  returns null for now).
- Coordinate-space reconciliation with renderer: pointer→reference-space
  conversion and screenToTile share an unverified assumption (see rendering).

## NPC Interaction

- interact_with_npc handler (dialogue, shop, quest, etc.). The hub input
  path deliberately does NOT fire it yet — the handler is a `{}` stub and
  firing it would record a no-op undo step (clicks on NPC tiles do nothing;
  the click→push site is marked in handleIdleInput's hub branch). When the
  handler lands, re-wire that site and drop the move-blocker comment.
- NPC dialogue system
- NPC types (shopkeeper, quest giver, etc.). The upgrade vendor (see
  "Gear Upgrading" below) is `interact_with_npc`'s first real consumer.

## Gear Upgrading

Design SETTLED — see DESIGN → Gear Upgrading (the income model extracted
from the clone economy, the two anchors, the starter-anchored cost ladder
+ α table, drops-as-pre-bought-rungs, the tier frontier, the vendor
panel). Implementation deferred; slices when it lands:

- [ ] events + legality + handler: `player_upgrade_item` (PlayerInputEvent
      orchestrator + `validatePlayerAction` arm over a bool legality
      helper) → `upgrade_item` (PlayerEvent machinery; PlayerData mutation
      + equipped-entity gear re-sync), tests.
- [ ] config + loader + the derived mid-ladder price table (model constants;
      `s_stat` derived from new_player.txt; the floor + largest-remainder
      split rule), tests.
- [ ] vendor NPC authoring (a hub-format marker — shape decided at
      implementation) + `interact_with_npc` wiring: re-wire the hub click
      site + drop the move-blocker comment (see NPC Interaction above).
- [ ] panel builder (two-column: item list = every item with a nonempty
      `itemStatSet`, no skill tomes; per-stat rows with cost + button) +
      selection UiState + panel toggle on the unified GameState convention
      (see Tech Debt → Unify the panel-toggle convention).
- [ ] tail-price generation script (the sound_report.sh pattern) — BLOCKED
      on the boss drop table (content not yet authored).
- [ ] tuning follow-ups: re-measure R when enemy-gear richness or
      utility-skill density changes; playtest the drip feel (the α dials).

## Post-game Rewards & Cosmetics

Design SETTLED — see DESIGN → Post-game Rewards & Cosmetics (the
saturating overflow guard, central-hub decoration customization, weapon
skins incl. custom-mission-shipped art, the static tier pricing ladder).
LOW PRIORITY — the official campaign comes first; slices when it lands:

- [ ] saturating material adds (harvest + salvage clamp at u32 max) —
      small + independent of the rest; could land early.
- [ ] skin registry + PlayerData unlock/selection fields + `weaponSprite`
      resolution + the default-sprite fallback + save round-trip.
- [ ] the item skin-id flag + pickup-unlock event + unique boss-weapon
      skins (official content) + the custom-mission flag path (art under
      `custom/<mission-dir>/<stem>`, resolvable from missions/ anytime).
- [ ] decoration placement overlay on PlayerData + the hub build mode
      (the editor's decoration planner reused, placement rules: never
      cover mission exits / NPC tiles / player start).
- [ ] the shops (decoration + skin, central hub) + the tier price
      ladder config.
- [ ] OPEN: build-mode entry — NPC flow vs button vs shop segue; decide
      at implementation.
- Note: the dreamguide NPC (dreams browser entry, every hub) is already
      designed — DESIGN → Custom Missions & Online Services → Browser.
- Note: the Gear Upgrading tail-price script stays blocked on the boss
      drop table; boss weapon skins ride the same content work.

## Level Editor

A custom-mission editor: mission + per-level tabs (quick swap to edit each
level) + a mission-shared palette of enemies / decorations / ground items.
Architecture is SETTLED — see DESIGN → Architecture → Level Editor for the
`Editor` type, the event family, the Option-2 framing + minimal exit guard,
the replay/cache story, AND the full UI layout + active-tool model +
`Selectable`-union selection model (tabs + viewport + bottom-bar palette +
left inspector; no dialogs; Test/Validate top-right; Upload deferred).
Most of it is implemented (DESIGN's Level Editor section has the
Implemented paragraph; the landed-slice history is in DONE.md). Remaining
work:

- **Revalidate Mission follow-ups** (the button itself is DONE — DONE.md;
  design: DESIGN → Custom Missions & Online Services → Validation replay →
  Revalidate): consider promoting it from the options menu to the top bar
  next to Test/Validate; the success message currently rides the error
  popup — a real notification/toast surface would be the proper home.
- **Custom-sprite dims verification** — currently any positive IHDR is
  accepted (base + layer picks) and sprites beyond the 8×8 draft grid
  don't open the footprint editor; verify multiples of 256 + sane bounds
  at the pick commit + the footprint editor's open gate. Picker scroll is
  a follow-up if real content overflows 4 columns.
- **Mission metadata cleanup — derive start_hub / end_hub /
  level_count.** mission.txt's Metadata carries three fields that
  restate the campaign graph or the mission directory — drift-prone
  duplicates (a mission exit moved to another hub, or a level_4.txt
  added, leaves them stale). All three should be DERIVED, not authored;
  the editor's mission-writer slice is the natural landing point:
  - `level_count` — count the `level_N.txt` files in the mission dir.
    Needs embedded-map enumeration (FileSource lists persistent dirs
    already; embedded keys are comptime-known) or a sequential
    load-until-missing probe. Consumers reading the authored value
    today: start_mission's level loop, FileSource's mission-browser
    scan, content_hash.
  - `start_hub` — derivable from the campaign graph (the hub whose
    `mission_exits` name this mission). OPEN: a mission referenced by
    multiple hubs has no single start hub; the runtime already knows the
    entering hub (`player_data.current_hub`; the exit_mission path
    already falls back to it). Decide: always entering-hub (drop the
    field) vs keep an authored fallback for the multi-hub case.
  - `end_hub` — the return hub after completion; NOT derivable from the
    current graph shape (`mission_exits` are hub→mission only, no
    mission→hub edge). All four shipped missions start + end at the
    same hub. OPEN: (a) return-to-entering-hub semantics (drop the
    field; the `start_mission.end_hub_id` runtime override stays for
    dreams), or (b) the graph gains a return edge if progression
    missions ending at a NEW hub are wanted. Decide before the
    mission-writer slice.
  Dropping the keys: remove from the shipped files + the parser
  whitelist (an old file still carrying them would warn — free
  pre-release, official data ships embedded with the exe).
- Editor autosave: nice-to-have, not need-to-have (explicit save for now).

- **Mission browser polish** (the browser itself — two tabs, scan-on-open,
  web zip import, new-mission — is DONE — DONE.md; design: DESIGN → Level
  Editor → The mission browser): columns (author / level count / timestamp
  formatting), keyboard navigation; rides the load-save browser's polish
  slice when the UI design settles.

## Logging & Replay

Session log read/write/reconstruct + combat-log projection DONE (see AGENTS
→ Logging & Replay; history in DONE.md). Remaining:

- file_format_version: monotonic int per serialized artifact, in its Metadata
  section. Session log starts at 1; retrofit missions/saves as those formats
  stabilize (custom-mission support needs it). Also add a format_version to
  mission Metadata when custom missions land.
- Pre-release replay-compat policy: handler changes that push new child
  events (e.g. the `damage`-event split, effect pacing) break strict
  verification of OLD session logs / validation replays — re-record rather
  than migrate until release; afterwards file_format_version gates it.
- Replay-viewer screen: wire .replay_viewer to STEP through a loaded log via
  reconstructFromEventLog/restoreTo at successive targets. Steps = the
  combat-log filter (derived, not idle_points). Needs the projection (DONE) +
  replay-viewer UI.
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

- New Screen variants and transition events.

- Quit-to-menu and death/mission-fail exits MUST route through end_level /
  end_hub so entity changes persist into PlayerData (see DESIGN →
  Architecture) — the options-menu exit paths + mission-fail/complete
  buttons are DONE (DONE.md).

## Platform Layer (raylib)

Native + web builds DONE (history in DONE.md; seam in DESIGN → Platform Seam).
Open:

- **Render smoothing (native-1080p edge harshness)** — settled plan, DESIGN →
  Platform Seam (WebGL 2 + Sprite-mipmap smoothing bullets) holds the why.
  - [x] Slice 0: switch the web build to WebGL2 (`opengl_version = .gles_3`;
    SDF shader ES 3.00 variant replaces the ES 1.00 one) — DONE, see
    DONE.md.
  - [x] Slice 1: sprite mipmaps — `genTextureMipmaps` + `.trilinear` at the
    two `TextureStore` upload sites (sprites + generated masks; covers
    shipped + custom art at the one choke point). SDF atlas stays mip-free.
    DONE — see DONE.md.
  - [x] Slice 2: text unification — ALL text draws through the SDF pipeline
    (plain fill = outlineWidth 0 with a transparent outline color); the
    coverage atlas is demoted to a fallback-only load (built only when SDF
    init fails). DONE — see DONE.md.
- **Render-resolution live swap — runtime confirmation open** (browser +
  native; the platform-seam compiles-≠-runs rule). The setting itself is
  DONE (DONE.md; design: DESIGN → Platform Seam → Render target
  resolution).
- **Zig toolchain policy (settled): stay on 0.16.0** for the
  foreseeable future; migrate to 0.17.0 ONLY when it RELEASES and
  raylib_zig/zemscripten ship 0.17-compatible versions (today's
  master cannot build the project — deps fail on the removed
  `LazyPath.getPath` + the pointer-deref language change). Migrate as
  a deliberate session (the 0.16 migration shape), with the friend as
  mac runtime validator. Built-in acceptance test for that day:
  `../ziglop-mac-bisect/repro/repro2.zig` (the miscompile repro) +
  the PRE-fix tint pattern — verify the emitted IR stores the tint
  (or just that panels render) on 0.17.0. Watch for **0.16.1**: the
  STOPSIG fix (`2eda0ef8`) is on the 0.16.x branch, so 0.16.1 retires
  the web patched-stdlib hack with zero work; the aarch64 ABI fix
  (`fa3a9fcd`) is NOT on 0.16.x, but our source restructure handles
  it permanently. Rationale (two 0.16.0 bugs, both settled, both at
  platform edges): DONE.md "mac 9-slice panels — ROOT CAUSE FOUND" +
  AGENTS → Build & Test (patched stdlib).
- **Diagnostics redesign — settled design, implementation pending**
  (DESIGN → Platform Seam → Diagnostics): priority-bumped — the rendering
  session (mipmaps, SDF text, WebGL2, LOD snap) landed four platform-seam
  changes with ZERO automated coverage (src/raylib is headless-excluded by
  necessity), and the only thing that caught the WebGL2 black screen was a
  manual browser run. A release-build `--diagnostics` flag is the structural
  answer to "verify the seam without being at the machine". Scope below:
  create raylib-free `src/diagnostics.zig` (`Diagnostics` type: buffer +
  section policy + end-of-frame flush scheduling, renames every `diag_*`
  identifier); add the `--diagnostics` CLI flag (native.zig, like
  `--replay` — any build, release included; dev-mode defaults to active);
  migrate the
  boot/probe/readback sections out of src/raylib/diag.zig as thin
  value-recording call sites; keep `logs/diagnostics.txt` + whole-file-rewrite
  semantics. Composes with the raylib split item above — the split lands
  first (its slice 7 moves the diag code into `src/raylib/diag.zig`, the
  value-recording call sites the redesign then hollows out).
- **macOS native port** — cross-build + persistent dir + .app bundle landed
  (history in DONE.md; persistent-dir design in DESIGN → File System & IO →
  Persistent path; build workflow in AGENTS → Build & Test). REMAINING:
  - [ ] **Runtime validation on real hardware** (friend's Apple Silicon
        machine; compile ≠ run, the web-build lesson). Checklist: app
        launches from Finder; main menu renders with readable SDF text (the
        outline shader on a core-profile GL context — mac tops out at
        deprecated OpenGL 4.1); retina/high-DPI window: letterbox + pointer
        mapping stay in sync (reference-space input math vs pixel
        framebuffer); audio device opens + sfx/music play; a save round-trip
        into `~/Library/Application Support/ziglop/` (spaces in the path!);
        crash-dump write works; `--data-dir` flag + `$ZIGLOP_DATA` override
        still work.
  - **Upstream zig report for the 0.16.0 aarch64 miscompile — DECISION
        PENDING** — repro project + report kit in
        `../ziglop-mac-bisect/repro/` (UPSTREAM_REPORT.md; repro.zig +
        repro2.zig + per-version IR evidence). The bug itself is
        root-caused + fixed + friend-confirmed (DONE.md, "mac 9-slice
        panels — ROOT CAUSE FOUND"); the 0.16.0 avoidance rule lives in
        AGENTS → Zig 0.16 Gotchas; fixed upstream on zig master
        (fa3a9fcd / PR #35711), not in any 0.16.x release.
  - **CI candidate** — post-GitHub-migration, GitHub Actions macOS runners
        (free for public repos) give build + runtime validation without
        owning a Mac; web runtime probing in CI via node (the headless
        technique). Solves this checklist's cadence problem structurally.
  - [ ] **Window sizing / high-DPI on mac.** The diag shows window
        1920×1080 points with a 1920×1080 framebuffer — 1:1, i.e. raylib
        runs WITHOUT high-dpi (no retina upscaling — blurry on retina
        screens), and 1920×1080 points likely EXCEEDS the friend's laptop
        screen at default scaling. Follow-up: window opens sized to the
        monitor (raylib `getMonitorWidth`-bounded, not fixed half-reference),
        + consider FLAG_WINDOW_HIGHDPI (retina rendering; the letterbox /
        pointer math operates in reference points either way — verify
        GetRenderWidth vs GetScreenWidth through pollInput's transform).
  - [ ] App icon (needs art — an .icns can be generated from a square PNG;
        macOS shows the generic icon until then).
  - [ ] Deferred to the demo/distribution milestone: codesigning +
        notarization (needs an Apple Developer ID), universal binary
        (x86_64 + aarch64 via lipo), Homebrew/cask.
- 9-slice REFINEMENT: corners now render SQUARE 1:1 on any panel size
  (fixed — see DONE.md); remaining gap is edges + center STRETCHED, not
  tiled. Spec wants tiling — only matters once patterned panel art ships
  (current ui/panel.png is a flat fill).
- Draw offset support (decoration overhang; SpriteDrawable.draw_offset).
- Programmatic edge highlight for highlighted Button/Image (shader outline of
  opaque pixels, or fallback highlight sprite) — currently ignored.
- Bold/italic rendering — `drawTextLabel` ignores bold/italic (only the
  regular face is loaded); honoring TextLabel bold/italic + color needs
  separate faces. (TTF + metrics DONE — DONE.md.)
- Missing-art audit: some sprite ids are still placeholders
  (ui/icon_swap, ui/momentum, ui/icon_undo, and the editor's
  ui/icon_playtest / ui/icon_validate) and will draw magenta until
  real assets land. WRINKLE for the planned art_report: the redo button
  consumes ui/icon_undo (flipped) — icon_redo is not a code-referenced
  sprite id, so a scan of consumed ids won't surface it; the report
  needs this aliasing (or a manual note) until the dedicated icon lands
  and the button switches to it.
- Web Phase 4: asset downscaling for web download budget (the Memory & Budget
  → Asset memory levers matter more for web than native); emrun polish.
  (The WebGL1/WebGL2 build option is DONE — the web build is WebGL2-only;
  see DESIGN → Platform Seam → WebGL 2.)

- **Load-save browser polish** (the browser itself is DONE — DONE.md;
  design: DESIGN → File System & IO → Load-save browser): columns (player
  name / hub / timestamp formatting), richer row visuals, keyboard
  navigation — lands when the UI design settles.

## Audio

Architecture DONE — see DESIGN → Audio (layered cues + layered music + the
file-formats bullet). The engine side is FULLY WIRED for the layered sound
design — every family follows the `_base` / `_layer` naming (the roles are
deliberately neutral: which half is percussive vs ambient is a per-file
authoring choice): skill cues (type base + `sfx/skills/<skill_id>_layer`),
button cues (base pair + `sfx/buttons/<action>_layer`, effect-site queued),
item-action cues (`item_base` + `sfx/items/<stem>_layer` for
equip/salvage/learn), the music intensity stack (`ambient_layer_1..N`, one
per active enemy, probed generically), and all missing one-shots (heal, stun,
knockback, retreat, death, collision, level_complete, aggro). **Everything
missing is a pure ASSET DROP** — the sound designer prioritizes on his own;
`.wav` or `.ogg`, persistent-dir shadowing works mid-session for layers
(miss-not-cached). **NO FALLBACKS: a missing sound is silence**, so the
status is always honest — `scripts/sound_report.sh` regenerates
`sound_report.md`, the complete per-path inventory with statuses (shipped /
shadowed / MISSING) resolved against both the assets tree and the
persistent dir. That report IS the shopping list — don't hand-maintain a
second one here.

Open:

- **Assets themselves** — the summary (see the report for exact paths):
  6 bases (`weapon_base`, `spell_base` exist as reworked pre-layering
  placeholders; `cantrip_base`/`enchantment_base`/`curse_base`/`item_base`
  missing), the button base pair (`button_base_down`/`button_base_up` —
  renamed from the click placeholders), 44 skill layers
  (`sfx/skills/<id>_layer`), button layers (`sfx/buttons/<action>_layer` —
  optional per action), 3 item layers (`sfx/items/equip_layer`,
  `salvage_layer`, `learn_skill_layer`), the music stem set (re-export
  `ambient` as the base of a sample-aligned stem set + as many
  `ambient_layer_N` as he writes), and the new one-shots (heal/stun/
  knockback/retreat/death/collision/level_complete/aggro). Current files are
  placeholders to re-author.
- **Music authoring constraint** — identical-length, sample-aligned loop
  stems (one DAW session); a mismatch is dev-diag-warned at load.
- Deliberately unwired (feedback-noise class — a layer file for these
  won't play until a site is added, by design; they do NOT appear in the
  report, which prints the same note): zoom + cursor keys (the wheel/mouse
  paths carry no sound; keys shouldn't be noisier), error-scroll ticks,
  `dump_event_log` + `skip_level` (dev tools), `confirm` (the simulated
  tile click plays the move/skill sounds).
- Web autoplay policy: browsers may block audio until a user gesture. The
  stream no-ops until then by design; verify it resumes after the first click
  on the web build.
- **Cue-wiring test coverage** — the sound queue sites live in
  headless-testable handlers, but nothing asserts what lands on
  `pending_sounds`: the `.change_setting` double-play and the silent
  `releaseSoundForAction` entries shipped for months because only ears
  could catch them. Extend the harness (`test_harness.zig`) to drive a
  trigger and assert the drained cues (skill cast = type base + skill
  layer; skip = action layer; equip/salvage/learn = item cues; toggles =
  action layer) — pins the base-at-the-seam / layer-at-the-effect-site
  ownership rules so the double-play class can't regress.
- Tune volumes / mix against real assets (layer volumes are placeholders).
- Per-sfx cooldown in `playSounds` if multi-hit overlap (N `attack` events
  in one frame → N damage sounds) sounds bad. Trigger sites stay clean; the
  throttle is backend-only.
- **Later extensions (settled direction, not scheduled):** per-screen base
  tracks (menu/hub/level ambience); per-enemy-TYPE music stems (the current
  stack is intensity-only); a medal-stinger layer per medal type
  (author/gold/silver/bronze) for the mission-complete overlay when the
  medals work lands; player-vs-enemy sound variants (move/hit/death) if the
  designer wants them (trivial at the queue sites).

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
- **Custom-asset dimension validation** — custom (mission-shipped) sprites
  must follow the shipped asset structure: entity sprites exactly
  512x640, decoration sprites rectangles of whole 256x256 tiles (dims a
  multiple of 256). Enforce where custom PNG dims are already resolved
  (loaders.zig sprite-dims resolution): warn + reject at mission import /
  load, never silently render off-grid art. Keeps the view math (entity
  bounds, decoration footprint splitting) and the sprite scaling
  conventions (world zoom × render scale) valid for arbitrary content.

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
  Settled (see DESIGN → Custom Missions & Online Services → Auth & the
  server seam): the server ALWAYS revalidates by replaying the submitted
  validation replay + deriving turns itself, and TAS is valid by design
  (turn-based → any legal log is human-possible).
  - **OPEN — game-version upload policy (decide at the server-seam
    session):** all-versions support (player-friendly; the author lean)
    vs. latest-only (force update). All-versions means retaining a
    revalidator build per game version — replays only verify against
    the EXACT logic that recorded them (verifyReplayMatch), so every
    balance change forks verification semantics; latest-only keeps the
    server to ONE build and comparable boards, and is near-free on web
    (update = page reload) but strands native installs + mid-run patch
    shipping. Adjacent decisions riding along: boards keyed by
    (mission_uuid, content_hash) so content edits re-key the board; and
    keep-and-stamp vs wipe existing entries on balance patches.
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

## Tech Debt / Refactoring

Done items in DONE.md. Open:
- **Style pass over the Tier A session's lines — DEFERRED (owner
      undecided).** Scope discovery (cleanup session): the "~95-char wrap
      convention" isn't an enforced convention — it's in no doc, ~2,000+
      lines exceed 95 tree-wide (handler_tests_editor 344, input_handlers
      192, state.zig 183...), the skills tree (~134 long lines) isn't the
      densest offender, and zig fmt doesn't check line length so any
      one-time wrap rots immediately. Options when revisiting: (a) drop the
      item, (b) settle a going-forward wrap rule in AGENTS (no retroactive
      churn), (c) fix only egregious >120-char lines. Decide then.
- **New-skill handler-level integration coverage is thin.** The Tier A
      skills are contract-tested at the pure-fn level (useSkill/aiOptions
      asserted directly) and the verbs have handler coverage, but only
      adrenaline_surge got real processEvent-drain tests. When a new
      skill's composition is novel (shockwave's attack+knockback fan,
      drain's lifesteal), one runToIdle test through the real handler is
      the model — adrenaline's are the template.
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
- Consistent slot-index bounds checking: utility-skill handlers guard
  slot_index < utility_skill_count, but equip_item/unequip_item/learn_skill/
  salvage_item index inventory.slots[...] directly (panic on out-of-range).
  Pick one convention (guard everywhere, or trust the source everywhere),
  keeping in mind events can also originate from save/replay data.
- **Handler test coverage — the "boring" primitives gap.** The four
  tiers are DONE (DONE.md; harness `src/test_harness.zig`; tiers in
  `src/handler_tests_gear/_combat/_ai/_turnflow.zig`). Coverage concentrates
  on the interesting verbs and is thin on the boring primitives
  (`swap_positions`, `retreat`, `swap_hands`, the cantrip arms) — exactly
  where sibling-drift bugs live (see DESIGN → Architecture → "Prefer
  composing"; `swap_positions` had no test when it was rewritten to compose
  `move_entity`). `pushAndRunSub` makes adding them cheap; the per-variant
  convention (every new event variant lands with ≥1 drain test — DESIGN →
  Testing → Tiers) applies going forward, and the coverage-matrix idea is
  REJECTED (DESIGN → Testing → Rejected).
- **Optional: split `editor_inspector`'s field emitters** into
  `editor_inspector_fields.zig` (4,649 lines, ~1,700 of them tests).
- **Duplicated rendering recipes in `buildEntityInspectPanel`.** The skill-
  button visual (frame + icon + cooldown overlay + empty-diamond marker)
  and the gear-slot visual (slot frame + item icon + tooltip) are inlined
  in the inspect panel instead of reusing `emitSkillButton` /
  `buildGearPanel`'s `emitGearSlot`, because those are hardcoded to the
  player entity + carry `Action`/`SlotRef` (interactive). The inspect panel
  is read-only. If the skill-button or gear-slot visuals change, both sites
  need updating. Refactor to a shared core taking an entity + a read-only
  flag — deferred (a deliberate cleanup slice, not urgent).
- **Awkward-values convention — settled** (the "nice values hide boundary
  bugs" note from the gear session: divisible harvest ratios, `warnings:
  null`, the untested `on_end_turn`, zero-coverage
  `resolveInventoryClick`). The convention + examples live in DESIGN →
  Testing → Assertion patterns; the bug history is in DONE.md.
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
