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

- **Campaign editor + world map** — the next major work: design SETTLED
  (DESIGN → Campaigns & the Campaign Editor — the hub/mission graph,
  discovery + travel, the world-map mirror, the campaign view + hub
  drill-in + mission hand-off). Slices + open questions (map position
  units, hub rename, the Editor-state split, the mission-editor campaign
  context) in Level Editor → campaign editor below.
- **Combat-log UI** — render ViewState.combat_log (top-bar coarse recent-icons
  view + full-screen detailed log). Projection is DONE (combat_log.zig); see
  "Combat Log" below.
- [x] `toggle_options_menu` rename — DONE: the action is `escape` now (see
      DONE.md; existing installs self-heal via the warn+drop at load).
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
- **Gear sprites** — the last unlanded entity sub-layer (effect overlays,
  sprite animation, ground items, decorations all DONE — history in
  DONE.md): needs both the `gear_sprites` wiring in view() and the gear art.
- **Input/camera leftovers** — tab-targeting (cycle highlighted tiles
  with Tab; reuse cursor resolution) + keyboard inspect binding (e.g.
  alt+Enter opens inspect on the tile-cursor entity; lands as an
  `Action.inspect_cursor` bool — the applyAction arm + the AnytimeInput
  field + the consumption site are the whole wiring (the dispatch fires
  it automatically — DESIGN → Input → New keybind wiring sites) —
  consumed in `handleIdleInput` where the tile cursor is resolved;
  right-click is the only inspect path today). (Camera clamping + editor viewport framing
  DONE — DONE.md; design: DESIGN → Platform Seam → Camera clamping.)
- **Keybind editor (settings → Keybinds tab)** — in-game rebinding UI.
  Settled design: contexts are DERIVED from `actionBindingContexts` (the
  binding `context` file line becomes informational — loader ignores it,
  writer emits the derived value; the load-time action↔context validity
  layer is deleted; the accidental editor-actions-{editor, menu}
  classification fallthrough was fixed — every editor action is editor-only
  for keys, the browser still opens from the main menu via its buttons).
  Conflict rule: one combo (input +
  required modifiers) → one action per context; UI prevents, load-time
  warn + drop the later entry + the repair write cleans the file, engine
  first-match-wins replaces equal-specificity co-fire. UI: the settings
  screen gains Settings/Keybinds tabs; left column = bindings one row
  per binding, sorted by action (9-slice key panels + action panel with
  derived context tag, NO group headers — the action name rides in every
  row + scroll); right column = full scrollable action picker. Edits go through
  an obvious listening state → a pending state with Confirm/Cancel + a
  steal warning ("Enter currently fires Confirm (game) — confirming will
  remove it") when the combo would remove an existing binding; steal
  applies on confirm. Slices:
  - [x] 1. Full key table in `input_poll` (the full W3C id set — retires
        the backend-edit wiring site; unmapped-id startup warn stays open
        under New-keybind pipeline friction) — DONE
  - [x] 2. Context derivation + conflict rule (engine gating, loader
        ignores the context line, load-time conflict warn+drop + repair
        write, first-match-wins tiebreak, delete the validity layer) — DONE
        (see DONE.md, keybind editor slice 2)
  - [x] 3. Keybinds tab read-only (tabs, grouped rows, key/action panels,
        context tags, scroll) — DONE (see DONE.md, keybind editor slice 3;
        the Settings tab's 12 rows went two-column to fit)
  - [x] 4. Editing flows (listening state, pending confirm/cancel +
        steal warning, right-column action picker, add/remove/reset) — DONE
        (see DONE.md, keybind editor slice 4; the rebuild-ownership
        follow-up test is DONE too — DONE.md, keybind rebuild-ownership
        test).
- **Console input (stdin — a scripted/TAS input channel)** — the game
  reads stdin while it runs: always-on, native only; piped scripts drive
  the game, launching from a terminal gives terminal control. Mirrors the
  engine's own synthetic-input model: one command per frame merged into
  the frame's PlatformInput (raw inputs — press/release/move/scroll/type
  through the identical pipeline); actions via applyAction (the button
  path). Console sessions produce ordinary session logs → valid
  `--replay` fixtures. Full settled design: DESIGN → Input → Console
  input. Slices:
  - [x] 1. `src/console.zig` (raylib-free): command parser, queue (SPSC
        ring — no Io-free mutex in 0.16 std), merge helper, applyAction
        injection, dump projections + unit tests (`src/input_tests_console.zig`
        holds the handler-level regression pins: press Escape end-to-end;
        scroll with the options menu open moves the keybind offset) — DONE
        (see DONE.md, console input slice 1).
  - [x] 2. Native wiring: the reader thread (spawns + reads stdin lines,
        EOF-safe, detached), the stdout dump writer on the queue, always-on
        (no flag) — DONE (see DONE.md, console input slice 2; includes the
        wasm32 u32-atomic counter fix). Console input is COMPLETE.
- [x] **UI surface state unification** — DONE (all six slices; see DONE.md,
      "UI surface state unification", + DESIGN → UI Framework → UI state
      classification).
- **Input dispatch convergence.** Design DONE (see DESIGN → Input →
  Dispatch convergence + New keybind wiring sites): `translateInput` is
  one pass over the bindings — a binding that passes `bindingFires`'
  gates folds through `applyAction`, the one action→PlayerInput mapping
  shared by button releases + console commands; every action is uniformly
  keybindable (menu commands included — dead bindings became live);
  same-frame degeneracies resolve first-listed-wins. Remaining slices:
  - [x] 1. The dispatch pass (bindingFires + actionRepeats + the
        skill-slot guard + the applyAction bridge arms + the comptime
        context table) — DONE (see DONE.md, input dispatch convergence
        slice 1).
  - [x] 2. `fired_actions` record + the per-action sound choke point
        (`dispatchFiredActionSounds`; the ~25 per-flag sound sites
        collapsed, the `.change_setting`-class double-play FIXED; the
        unwired + outcome-gated exclusions documented at the choke point
        — DONE, see DONE.md, input dispatch convergence slice 2).
  - [x] 3. The no-op-proof count assertions in `handler_tests_editor.zig`
        → assert WHAT recorded — DONE (see DONE.md, input dispatch
        convergence slice 3: `expectLastEvents` + the open/close pair
        consts; the six GROWING deltas converted, the == no-op gates keep
        their count equality — they assert nothing was recorded).
  - [x] 4. EVALUATE only — DECIDED: no split now (see DONE.md, input
        dispatch convergence slice 4). The dispatcher switches are
        intrinsically large (they enumerate the actions' consumption);
        splitting switch arms is mechanical churn; the per-topic helper
        blocks (keybinds / text edit / editor item) are cohesive +
        heavily cross-referenced via file-private helpers. REVISIT WHEN
        the hub/campaign editor arms land — if the file crosses ~7k
        lines or the arms stop fitting one scan, the hub/campaign arms
        split out alongside the editor arms (a real seam, not a chore
        split).
- [x] **New-keybind pipeline friction** — DONE. The wiring-site map
      shrank (four sites — DESIGN → Input → New keybind wiring sites; the
      backend key table + the derived `context` line are no longer sites),
      and the dead-binding startup warn landed after the missing-Escape
      regression exposed the class (a binding naming an id no platform
      table can produce warns + is kept; a comptime lockstep guard pins
      the tables to `types.producible_key_ids` — see DONE.md, dead-binding
      advisory).
- **UI outline readability (shader animation)** — the highlighted-tile /
  region outlines draw with the theme's `lightest` (the artist's offwhite
  — view.zig), which reads weakly against the background; want a SHADER
  animation (pulse / marching-ants style) so outlines stand out. Lands at
  the platform seam (`src/raylib/`, the SDF-text-outline pipeline's
  neighborhood); pure-view change (no state, no replay impact).
- **Enemy pathing straightness** — an enemy on the player's row steps
  DIAGONALLY up-and-back instead of walking the row: `shortestPath`
  (functions.zig) breaks f-cost ties by position (x-then-y —
  `comparePathNodes`), and chebyshev-equal paths can't see that the row
  walk is straighter. Fix direction: prefer by REAL (euclidean) distance
  to the target (same-row chases walk the row), keeping the tiebreak
  deterministic (replay). Also note while there: the heuristic is
  MANHATTAN while diagonal steps cost 1 — chebyshev is the true metric
  (an overestimating heuristic can even return non-shortest-by-steps
  paths). Update DESIGN → Determinism & Tiebreaking when it lands (a
  rules change → old session logs re-record, pre-release policy).
- **Cross-cutting polish** — 9-slice edge/center TILING (corners are
  aspect-true — DONE.md; `highlighted` edge outlines DONE), missing art
  (ui/icon_swap, ui/momentum, ui/icon_undo draw magenta — and the global
  top bar's redo button flips icon_undo as its glyph until icon_redo
  lands), the color wheel's two REPEATED colors across gradients (artist to
  correct: `#c1cde8` — color_0 of both gradient 8 (330° spoke) and gradient 9
  (315°); `#d89656` — color_3 of both gradient 20 (150°) and gradient 21
  (135°); shipped as-sent until the corrected wheel arrives), and
  gear-tooltip comparison colors — full green/red placeholders, artist to
  pick softer shades (`ui.positive_color`/`ui.negative_color`, shared by
  tooltip comparisons, the inventory icon stat numbers, and combat
  damage/heal numbers).
- **Larger systems (beyond MVP)** — the world-map overlay (the campaign
  view's read-side mirror — DESIGN → Campaigns & the Campaign Editor;
  campaign-editor slice 2) + NPC interaction/dialogue (see "NPC
  Interaction" below). Middle panels
  (inventory/gear/skills/inspect), options/settings/top bar, drag-drop, and
  the audio architecture are DONE (history in DONE.md); the full combat-log
  overlay is the Combat-log UI item above.
- **Online services** — web database for leaderboards + custom content
  hosting/sharing. Builds on the custom-mission VFS acquisition path; see
  "Content Loading / Custom Missions" + "Online Services" below.
KNOWN DEFERRED BUGS: (none currently.) When one appears, troubleshoot
via the session log (logging has landed).

## Skill Logic

All 44 shipped skills done — the 25 original ports + the Tier A reworks
(crossbow / idol / spell, cantrips, enchantments; history in DONE.md). The
remaining designs (from the original Unity design doc) are triaged into
tiers; each new skill lands with AI priority + target selection + tests in
`src/skill_tests.zig`.

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

Open:

- Gear sprites — the one unlanded EntityDrawable sub-layer (`gear_sprites`
  is emitted empty; no gear art has shipped). Base + weapons + entity
  layers + effect overlays + health bars all DONE — DONE.md.
- Multi-frame one-shot anims: attack swings, death dissolves — same
  machinery as the landed one-shots (skill-icon pop, hit flash,
  damage/heal numbers — DONE.md; design: DESIGN → Animation), richer
  `AnimKind` per event. Per-sheet frame data (count, frame size) stays
  hardcoded per builder for now; per-sprite pixel dims live in
  `generated_sprite_metadata.zig` (DONE).

## UI Framework — Panel Builders

Layout infrastructure + buildBottomBar + buildMainMenu + buildTooltip +
buildSkillTooltip + 9-slice + bottom-bar tooltips DONE (history in DONE.md).
Open:

- buildTopBar: the combat-log summary (options + undo buttons DONE —
  DONE.md).
- buildSkillsPanel: sorting / grouping / search deferred (display slice +
  drag-to-bar DONE — DONE.md).
- buildWorldMap: the campaign view's READ-side mirror (DESIGN → Campaigns
  & the Campaign Editor → Discovery + travel): background + all hubs +
  edges, undiscovered hubs / unavailable missions dimmed; hub click
  travels (backtrack to discovered), edge click starts the mission (the
  start hub discovered) — deliberately equivalent to the exit tile.
  Rides campaign-editor slice 2.
- buildFullCombatLog: scrollable detailed combat log (renders
  ViewState.combat_log; see Combat Log).
- **Settings screen** — settled design: DESIGN → UI Framework → Settings
  screen. Full-screen modal overlay (`UiState.settings_open`), reachable
  from the main-menu Settings button AND from a new "Settings" button in
  the options menu (level + hub; settings opens on top, Back returns to the
  options menu). Input bindings deferred. Slices 1–3 DONE (the overlay
  shell + options-menu wiring; the volume u32 0–100 migration,
  `settings_file_format_version` 2; toggles + choices + sliders with audio
  live-apply — history in DONE.md). Open:
  - **Settings numeric fields → text input:** wire freeform integer
        entry for `render_fps_cap` / `animation_fps` to the text-input
        widget (landed with the editor inspector — DESIGN → UI Framework →
        Text input widget); sliders currently cover them.
- Middle section horizontal scroll when panels exceed width.
- Per-skill skill-tome icons: `skill_tome` items use one generic tome icon
  (item/skill/effect icons otherwise DERIVE from ids —
  `skillIconSpriteId` / `itemIconSpriteId` / `effectIconSpriteId` in
  emit.zig; no config field needed).
- Move UI sprite assets from Unity project — remaining placeholder ids:
  ui/icon_swap, ui/momentum (also tracked under Cross-cutting polish
  missing art).
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
- [x] Tree + tent prefab registration — DONE (see DONE.md, art delivery
      2026-09-29): footprints + layer composition in `data/decorations.txt`.
- [x] `grass_back` behind-the-base rendering — DONE: the `behind`
      decoration-layer flag (config key + the back-layer render slot; see
      DESIGN → Decorations & Footprint + DONE.md).
- Open wiring-time details (from AGENTS): overhang sort x; tall multi-y
  footprints if such art ships.

## Drag & Drop

Core lifecycle, click/drag disambiguation, inventory click intents,
multi-salvage — all DONE (DONE.md). Open:

- Cancel drag / snap item back when the pointer release is lost outside the
  game (focus loss, pointer leaves window) — currently a lost mouse-up leaves
  the drag latched to the cursor.

## NPC Interaction

- interact_with_npc handler (dialogue, shop, quest, etc.). The hub input
  path deliberately does NOT fire it yet — the handler is a `{}` stub and
  firing it would record a no-op undo step (clicks on NPC tiles do nothing;
  the click→push site is marked in handleIdleInput's hub branch). When the
  handler lands, re-wire that site and drop the move-blocker comment.
- NPC dialogue system
- NPC types — SETTLED (see DESIGN → Campaigns & the Campaign Editor →
  File formats): `NpcType = { gear_upgrader, dream_guide }` — the whole
  cast for the foreseeable future; NPCs are `{ npc_type, position }`
  (NOT entities — the entity-ness is stale scaffolding, removed in
  campaign-editor slice 1), sprite derived from the type (the shipped
  assets/npcs/ files). `interact_with_npc` routes on the type; the
  upgrade vendor (see "Gear Upgrading" below) is its first real
  consumer, the dream guide is the dreams-browser entry.

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
- [ ] vendor NPC authoring (SETTLED: a `gear_upgrader` NPC placed in a
      hub — DESIGN → Campaigns & the Campaign Editor; no extra hub-format
      marker) + `interact_with_npc` wiring: re-wire the hub click site +
      drop the move-blocker comment (see NPC Interaction above).
- [ ] panel builder (two-column: item list = every item with a nonempty
      `itemStatSet`, no skill tomes; per-stat rows with cost + button) +
      selection UiState + panel toggle on the unified GameState convention
      (see DESIGN → UI Framework → UI state classification).
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

- **OPEN (playtest-watch) — a selection move that crosses a marker
      DELETES the crossing thing.** An entity/item/tile whose move target
      is the '!' / '=' cell plans empty and is removed by the move
      (documented, intended — DESIGN → Level Editor → the commit chain's
      per-entry re-planning). But dragging a large marquee selection ACROSS
      a marker silently eats its members — a UX trap. Options when it
      bites: veto the whole move (the marker-overlap veto's shape —
      planning.editorSelectionMoveVetoed), or make the drag ghost surface
      the loss (the view already draws the translated outlines). The
      marker-on-marker case is already vetoed; this is the non-marker
      members' case. Decide from playtest texture.
- **Campaign editor (hub editing inside) — design SETTLED, build not
  started.** TWO editors, not three (see DESIGN → Campaigns & the
  Campaign Editor for the full model): the mission editor (built) + the
  campaign editor — the campaign view (background, freely-placed
  draggable hubs, rendered mission edges, dangling ends tolerated);
  click a hub → the hub editor drill-in (tile/decoration/spawn reuse,
  exit + NPC tools, no entity tooling, no player.txt, no playtest); click
  an edge → the mission editor hand-off. The in-game world map is the
  READ-side mirror of the same view (discovery + travel semantics
  settled in DESIGN). OPEN questions (inline, decide at the
  corresponding slices):
  - map position units — normalized (0–1, survives a background
    re-skin; the lean) vs background pixels;
  - hub rename — rewrite references (destination_hub values +
    start_hub; the mission editor's stem-normalization precedent; the
    lean) vs no rename in v1;
  - the Editor-state split — `Editor` + content union (mission /
    campaign payloads on the shared spine; the lean) vs a parallel
    CampaignEditor state; UNDECIDED — settle with a dedicated design
    spike against the real `Editor` code BEFORE slice 3 (it shapes
    slices 3–5; cheap to revisit on paper, expensive in code);
  - what the mission editor's campaign context changes beyond the
    options-menu return (the "slightly different setup" — e.g. no
    standalone-dream export surface while campaign-owned).
  Future surfaces riding this work: the pre-mission briefing overlay
  (leaderboards, clone info + medal — before ANY mission start, map
  edge / exit tile / re-run alike); fog-of-war hiding as a possible
  refinement of the dim-undiscovered mirror.
  Artist dependency: a plain world-map background image for the official
  campaign (a placeholder unblocks the editor meanwhile).
  Slices (rough, re-cut at implementation):
  - [ ] 1. Formats + model: campaign.txt gains `background` + a `Hubs`
        section (version bump); hub.txt exits gain `destination_hub`,
        NPCs become `npc_type` (+ position; the NPC entity-ness removed
        — types.zig, loadHub, view, the hub-click path) (version bump);
        hub bundled custom decoration art (the mission-bundle pattern);
        mission.txt drops `start_hub`/`end_hub` (the campaign graph owns
        the edge; dreams = entering-hub fallback) + `level_count`
        becomes derived (writer/loader round-trip + tests; consumers:
        start_mission's level loop, the mission-browser scan,
        content_hash). RIDERS while the load layer is open:
        - `loadHub` + `loadCampaign` become SELF-OWNED (the
          arena-blind-spots policy — AGENTS → Build & Test: the ownership
          fix is the prerequisite for leak-checked tests, deferred until
          a load change lands; THIS is the load change) so the new
          format tests run leak-checked from the start, not
          arena-wrapped with the blind spot inherited.
        - Campaign graph INTEGRITY checks at load (dangling
          destination names, exits naming missing missions, no start
          hub placed, unreachable hubs — warn, the loader convention):
          the dangling format is save-legal BY DESIGN, so the catch
          belongs at load/validation time from day one, not as a
          trailing afterthought (a hand-edited campaign must not
          silently misresolve).
  - [ ] 2. Runtime: discovery (PlayerData discovered-hub set, seeded at
        new_game, discovered on arrival), `start_mission.end_hub_id`
        populated from the exit's destination_hub by the exit-click
        path, world-map travel (backtrack to discovered) + mission
        starts (edge clickable when the start hub is discovered) —
        buildWorldMap renders the mirror (dim undiscovered hubs /
        unavailable missions).
  - [ ] 3. The campaign editor state + framing + the editor browser's
        Campaign tab (scan `campaigns/`, New Campaign) + the campaign
        view (background, hub place/free-move/drag, edge rendering,
        dangling rendering).
  - [ ] 4. The hub editor drill-in: the reused viewport machinery +
        exit + NPC tools with inspector fields (mission pick / import
        COPY-AT-PICK / new blank mission; destination picks placed hubs
        or a free-typed name).
  - [ ] 5. The mission-editor hand-off (campaign context) + campaign
        save/export bundling (the STORE-zip pattern).
- **Revalidate Mission follow-ups** (the button itself is DONE — DONE.md;
- **Revalidate Mission follow-ups** (the button itself is DONE — DONE.md;
  design: DESIGN → Custom Missions & Online Services → Validation replay →
  Revalidate): consider promoting it from the options menu to the top bar
  next to Test/Validate; the success message currently rides the error
  popup — a real notification/toast surface would be the proper home.
- **Custom-sprite dims verification** — DONE across all layers (load
  warn+degrade, render magenta gate, picker filter, pick-commit backstops,
  Revalidate report — see DESIGN → Custom Missions & Online Services →
  Custom-asset dimensions; history in DONE.md).
- **Mission metadata cleanup — SETTLED** (see DESIGN → Campaigns & the
  Campaign Editor → The graph model): mission.txt DROPS `start_hub` and
  `end_hub` outright (no authored copy, no derivation — the campaign
  graph owns the edge: the from-hub is the exit's file, the to-hub
  rides `start_mission.end_hub_id` from the exit's `destination_hub`;
  dreams = the existing entering-hub fallback); `level_count` becomes
  DERIVED (count the mission dir's `level_N.txt` files). Lands as
  campaign-editor slice 1 (formats + model, above) — one version bump
  + writer/loader round-trip, not a standalone slice.
- Editor autosave: nice-to-have, not need-to-have (explicit save for now).

- **Editor browser polish** (the browser itself — kind tabs + New
  button, two list tabs, scan-on-open, web zip import, main-menu entry
  — is DONE — DONE.md; design: DESIGN → Level
  Editor → The editor browser): columns (author / level count / timestamp
  formatting), keyboard navigation; rides the load-save browser's polish
  slice when the UI design settles.

## Logging & Replay

Session log read/write/reconstruct + combat-log projection DONE (see AGENTS
→ Logging & Replay; history in DONE.md). Remaining:

- [x] file_format_version now rides every config file's Metadata section
      (wiring DONE, DONE.md). Policy: bump the relevant per-type constant
      in parser.zig whenever a serialized format changes shape. The session
      log's v2 (ReconstructionCache manifest + `content/` copies — the
      session-log BUNDLE) is DONE — see DONE.md, "session-log bundle".
- Pre-release replay-compat policy: handler changes that push new child
  events (e.g. the `damage`-event split, effect pacing) break strict
  verification of OLD session logs / validation replays — re-record rather
  than migrate until release; afterwards file_format_version gates it.
- Replay-viewer screen: wire .replay_viewer to STEP through a loaded log via
  reconstructFromEventLog/restoreTo at successive targets. Steps = the
  combat-log filter (derived, not idle_points). Needs the projection (DONE) +
  replay-viewer UI.
- [x] Replay verification cross-session: natural-stack verification
      (`verifyReplayMatch`) runs on cross-session `reconstructFromEventLog`
      reconstructions too, and the replay CHECKING mode
      (`reconstructFromEventLogChecking`) makes the same check catchable for
      revalidate / server validation (DONE.md). The custom-mission
      cross-session gap is CLOSED — session-log bundles embed the content
      (see DONE.md, "session-log bundle").
- Exhaustive comptime round-trip test for the session-log writer/reader:
  inline-for over every Event category/variant, synthesize a payload (0 /
  false / first enum / "" / empty slice / null optional / recurse structs),
  write → parseConfigFile → loadEventLog → expectEqualDeep. Self-maintaining
  (new events covered automatically). Structural drift is already prevented
  by comptime + @compileError else-arms; this guards VALUE fidelity + the
  field-presence contract (writer emits every field; reader requires every
  non-optional field). CONCRETE CASE (the ui-surface session): "comptime-
  generic" has SEAMS you only discover by instantiating — optionals were
  handled at the struct-field layer (writeEventField/parseEventFieldValue)
  but NOT at the union-variant layer (appendEventScalar/parseScalarTokens),
  so the first event with an optional union-variant payload
  (`EditorPickerTarget.entity_layer: ?u32`) hit a compile error in generic
  code nobody thought they were touching; the representative-shapes test
  only covers what a human thought to add. The exhaustive variant walk
  catches the whole class for free.
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

## Platform Layer (raylib)

Native + web builds DONE (history in DONE.md; seam in DESIGN → Platform Seam).
Open:

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
- [x] **Diagnostics redesign** — DONE (history in DONE.md; settled design:
      DESIGN → Platform Seam → Diagnostics).
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
  headless-testable handlers, but little asserts what lands on
  `pending_sounds` (the `.change_setting` double-play shipped for months
  because only ears could catch it — the fired-actions choke point fixed
  it + pinned it headless; see DONE.md, input dispatch convergence slice
  2). Remaining: extend the harness (`test_harness.zig`) to drive a
  trigger and assert the drained cues (skill cast = type base + skill
  layer; skip = action layer; equip/salvage/learn = item cues) — pins
  the base-at-the-seam / layer-at-the-effect-site ownership rules for
  the event-level cue sites too.
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
  via DebugAllocator (debug builds; release uses c_allocator), then set the
  true caps + safety ceiling from actual numbers instead of the current
  estimates (max_entities=256, max_tiles~10k, ceiling ~256–512 MB). Levels
  are drivable end-to-end now — this is unblocked, just unscheduled.
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
- [x] Cross-session replay reproducibility: session-log bundles embed the
      exact bytes the session read (manifest + `content/` copies; see
      DESIGN → Logging & Replay → Session-log bundle) — DONE. The sharing/
      download packaging lands with the database.
- **Custom-asset dimension validation** — DONE, all layers (load
  warn+degrade, render magenta gate, picker filter + commit backstops,
  Revalidate art report). Settled design + the layer inventory: DESIGN →
  Custom Missions & Online Services → Custom-asset dimensions; history in
  DONE.md.

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
- **Vestigial `!replaying` gates at input-layer sound sites.** The
      `queueActionSound`/`queueSound` call sites gate on
      `!history.replaying`, but the input handlers (`handleAnytimeInput` /
      `handleIdleInput`) appear to run ONLY in the live path (replay drives
      `processEvent` directly on recorded events) — making the gates dead
      defense. Confirm once, then either drop them or record WHY the
      convention stands at the choke point (`dispatchFiredActionSounds`
      kept its gate for convention) so the gate isn't cargo-culted onto new
      sites. Do NOT churn the per-site gates on their own — fold into the
      next touch of each site.
- **Doc-symbol staleness checker (machine-walked truth for doc prose).**
      DESIGN/AGENTS name code symbols (`main.dumpEventLog`,
      `parser.writeEventLog`, ...) and drift silently when symbols move —
      two stale refs were found + fixed during the session-log bundle work
      (nobody re-reads settled prose), and two more surfaced by accident
      during the dispatch-convergence session (the stale "blocked on NPC
      art" line; a "silent gap in seven" vs 8 picker arms). The
      sound_report / art_report pattern applied to docs: a script that
      extracts backtick-quoted dot-paths from DESIGN/AGENTS/TODO and flags
      the ones no src file contains (`rg -F` per candidate). Cheap to
      build, self-maintaining, catches the whole class. Wire into scripts/
      alongside test.sh; run manually or in CI-if-ever. Build it BEFORE the
      campaign editor work — that work adds a wave of new symbols + doc
      prose, and the checker's value compounds from the first new line.
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
  `src/handler_tests_gear/_combat/_ai/_turnflow.zig`). Most of the named
  primitives have since gained drain tests (`swap_positions`, `retreat`,
  the combat verbs), but `swap_hands` still has none — exactly the class
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
