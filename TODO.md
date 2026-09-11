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
- **Make co-fire-by-context disambiguation explicit** — DONE. Replaced by
  binding contexts: every binding carries a required `context`
  (`anytime`/`game`/`editor`/`menu`/`error_popup`), `translateInput` gates on
  the frame's active context set, and the ArrowUp/ArrowDown dual-binds now
  resolve upstream (popup up → only `error_scroll_*`; down → only
  `move_cursor_*`) instead of via handler ordering. History in DONE.md.
- **Editor tool/palette keybinds (1–5)** — DONE (slice 2 of the
  binding-contexts work). Digit1 = select tool, Digit2 = tile tool,
  Digit3/4/5 = expand/collapse the entity/decoration/item palette groups —
  context-`editor` bindings (Digit1–8 stay the in-game skill slots; the
  first shipped same-combo cross-context pair). Five payload-less actions
  bridged in `translateInput` onto the click paths' `options_action` +
  payload pairs, so clicks and keys share consumption sites exactly.
  Design: DESIGN → Input (Binding contexts) + DESIGN → Level Editor →
  Editor UI layout (tool palette); history in DONE.md. Optional polish
  follow-up: surface the shortcut numbers in the palette UI (fixed-tool
  labels "1 Select" / group headers "Entities 3", or tooltips).
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
  **Camera clamping** DONE — level-flush bounds (pan included, no void past
  edges, small levels centered as a whole) + 2-tile player margin for the
  automatic camera, over the bars/panels view region with a fully-covered
  fallback; levels/hubs only. See DESIGN → Platform Seam → Camera clamping;
  history in DONE.md. Editor viewport framing: DONE (same clamp over the
  full-width band — sidebars ignored, completely free pan, tab switches
  recenter via cameraRecenterKey; clamp bounds are a level-switch-time
  snapshot so mid-edit tile changes never reframe — see DESIGN → Platform
  Seam → Camera clamping).
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
- **New-keybind pipeline friction** — a new keybind touches FIVE places
  (the list + the reason it's easy to forget one: see DESIGN → Input →
  New keybind wiring sites — the doc line this item asked for has landed):
  the binding in `data/default_settings.txt` (including its `context` line),
  the backend's key table (`key_mappings` in src/raylib/input_poll.zig — only bound
  keys are mapped; unmapped keys never reach `translateInput`), the Action
  enum + its `actionBindingContexts` case, the Action/input plumbing
  (`AnytimeInput`/`IdleInput` field + `applyAction` + the consumption site),
  AND the `translateInput` `checkAction` dispatch line for the action. Two
  instances of a site being forgotten: ctrl+A select-all shipped broken on
  the missing backend entry, and ctrl+S save-mission shipped broken on the
  missing dispatch line (see DONE.md, “Editor save via ctrl+S”).
  Still open from this item: warn at startup (dev-mode console or the
  pending-error popup — advisory, not fatal) when a loaded binding names an
  input id no backend mapping can produce, and/or consider mapping the full
  W3C key set once so new bindings never need a backend edit (cost: a
  slightly bigger poll loop — it's a fixed array, likely negligible; verify
  with the input budget in mind). The action↔context + unknown-action
  warning half landed with binding contexts (load-time, warn + drop — see
  DESIGN → Input → Action↔context validity).
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
  (ui/icon_swap, ui/momentum draw magenta; skills/meteor icon is the
  renamed daze.png placeholder — artist to draw a real meteor icon). (Real TTF
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
  (handlers/shared.zig) centralizes the warning-collection + popup surfacing
  for in-event reads; `loadConfigWithFallback` (session_setup.zig) validates
  startup config. History in DONE.md.

KNOWN DEFERRED BUGS: (none currently — combat turn-flow issues from earlier
  playtesting are resolved.)
  chase individually — troubleshoot via the session log (logging has landed).

## Skill Logic

All 25 ported skills done (history in DONE.md). The remaining designs
(from the original Unity design doc) are triaged into tiers; each new skill
lands with AI priority + target selection + tests in `src/skill_tests.zig`.
Targeting/damage are done (part of the port — those old TODO lines were
stale).

- [x] **AI rating scale re-anchored to VALUE UNITS (the tuning
      interjection).** Priority ≈ cast value in units of a plain 1x hit:
      0 = don't cast, 1 = plain attack, +1 per significant bonus
      (conditional multiplier, stun-on-unstunned, collision, control worth
      a hit; lifesteal only below half health). AoE sums per target
      (aoePriority = base + count − 1; aoeKnockbackPriority adds +1 per
      colliding target); blitz = count + unstunned count; flash strike
      base 2 (teleport rider). Full retune table in DONE.md; design: DESIGN
      → Architecture (AI rating scale). Resolves "1-target AoE ties
      conditional singles and slot order picks the worse cast". History in
      DONE.md.
- [x] **Unified AI options (priority + selectTarget → ai_options_fn).**
      One decision instead of two: each skill enumerates its meaningful
      casts as (target, rating) pairs best-first; the handler picks
      (priority, option order, slot order). The four documented seams are
      closed: stab rates its actual pick (not any-healthy), daze emits
      unstunned-3 / momentful-2 classes with focus-fire picks, flash
      strike's option target IS the max-hit landing tile, blink no longer
      casts into a no-op. Design: DESIGN → Architecture (AI options);
      interface + PORTING NOTE in skill.zig. History in DONE.md.
- [x] **AoE priority bump (the drain interjection)** — every radius skill
      rates +1 when two or more hostiles would be hit
      (helpers.aoePriority + hostileCountWithinRadius). Retrofitted:
      spinblade/slam (3→4), blitz (4→5), howl (1→2, counts inactive
      entities of any team), flash_strike (best-landing-tile max count;
      also fixes its old flat-3 whenever-available rating that let it
      flash into empty space). Design: DESIGN → Architecture (AoE priority
      bump). History in DONE.md.
- [x] **AI threat model + deals_damage (the absorb interjection)** —
      `Skill.deals_damage` (required — every skill declares it);
      `priority_fn` widened to receive `weapon_type_definitions` (the
      alias `types.WeaponTypeDefinitions`); `ai_threat.zig` (computeMinRange
      moved there + computeMaxDamageRange + hostileCanAttackNextTurn: alive
      + active + unstunned + within speed + max damaging reach).
      Reflect's flat within-2 heuristic replaced with the same 0/2/4 tiers.
      Design: DESIGN → Architecture (AI threat model). History in DONE.md.
- [x] **Stun rule fix — max, not sum (anti-stunlock).** A new stun takes
      the max of current vs incoming duration, never stacks — multiple
      stunning enemies can't mega-stunlock the player. Stun skills' AI
      mirrors it: rate up only with an unstunned target in reach
      (cleave/head_shot 3→2, daze 3/2/0 by momentum), select unstunned
      targets first (new helpers.stunTarget — preference key in front of
      the focus-fire tail, the knockbackTarget pattern). Rule: DESIGN →
      Architecture (the stun rule). History in DONE.md.
- [x] **Focus-fire target selection (the convention interjection)** — every
      hostile-targeting single-target offensive skill now picks the
      lowest-health hostile (ties: Chebyshev distance, then entity index) via
      `helpers.weakestTarget`; 13 skills updated (daze included — uniform
      rule for all hostile-targeting single-target skills), Swap keeps
      `nearestTarget`. Convention: DESIGN → Determinism & Tiebreaking.
      History in DONE.md.
- [ ] **Tier A — pure composition, no engine changes** (one at a time):
  - [x] crossbow shoot (skill 1, main, no cd) — attack + retreat, range 3,
        distance 1. Priority 2 (the toss precedent).
  - [x] crossbow powerful shot (2, main, cd 2) — attack + knockback +
        collision damage, range 3, distance 2 (bash shape). Lands with the
        knockback-target-selection convention (see the focus-fire entry
        above) applied to bash too. History in DONE.md.
  - [x] crossbow head shot (3, off, cd 4) — attack + stun, range 3 (cleave
        shape, off-hand damage). Priority 3 unstunned / 2 stunned-only;
        stunTarget selection (see the stun-rule interjection below).
  - [x] idol heal (1, main, no cd) — heal 20% max health. Gated below
        half / 0 otherwise (the replenish threshold logic — a flat
        below-full rating would make it heal every turn). Ratings were
        re-anchored in the later value-unit retune (cleanup session — see
        DONE.md).
  - [x] idol absorb (2, main, cd 5) — interceptor: incoming damage →
        healing (reflect shape). Priority on the threat model (0/2/4);
        effect_sprite null until art ships. Lands with the threat-model
        interjection below. History in DONE.md.
  - [x] idol drain (3, off, cd 5) — AoE attack + lifesteal. Per-target heal
        via heals_attacker (post-defense applied damage — a "total"
        interpretation would need new post-batch machinery); priority on the
        AoE bump (3/4). Lands with the bump interjection below. History in
        DONE.md.
  - [x] spell worldfire — AoE attack, radius 5, cd 10. First spell: damage
        is getEffectiveSpellDamage (amulet-based — the number the curse
        designs reference); born on the unified ai_options interface;
        priority on the AoE bump (3/4 — base 3 encodes "save it for
        clusters": singles lose to slot order, clusters fire). History in
        DONE.md.
  - [x] spell shockwave — AoE attack + knockback + collision, radius 1,
        distance 2, cd 5 (slam shape minus stun, spell damage). Lands with
        the stacked-bump ladder (aoeKnockbackPriority: base + AoE bump +
        collision bump); slam retrofitted onto it. History in DONE.md.
  - [x] spell charged bolt (renamed from piston bolt) — attack with triple
        converted momentum, range 3, cd 3 (impale shape, spell damage + the
        extra getConvertedMomentum). Priority 3, weakestTarget pick. History
        in DONE.md.
  - [x] spell chain lightning — attack target + each hostile connected
        via neighboring hostiles (connected component by the skill's
        EFFECTIVE radius, Chebyshev; allies are not chain nodes — a hostile
        line broken by an ally does not conduct). Option = the
        largest-component target (focus-fire tail ties), rated
        aoePriority(component, 1) — 1-link chains rate like plain attacks.
        History in DONE.md.
  - [x] spell adrenaline surge — reset the target's on-bar cooldowns
        (both weapons' full sets incl. swap-available thirds + utility —
        Entity.onBarSkillIds, shared by handler + rating) + one attack per
        reset. Machinery event (the reset_weapon_cooldowns precedent —
        enumeration needs defs); options rate = reset count. Lands with
        Entity.onBarSkillIds. History in DONE.md.
  - [x] cantrip burst — AoE attack, radius 1, cd 10 (mini worldfire,
        non-turn-ending cantrip pool).
  - [x] cantrip meditate — reset each other equipped utility skill
        cooldown, cd 10 (composes change_cooldown directly — utility
        slots live on the entity, no machinery needed). Rating = reset
        count.
  - [x] cantrip accelerate — +2 momentum per enemy within radius 3, cd 3.
        Rating = direct enemy count (cantrip-pool ratings only ORDER the
        non-ending skills — all worthwhile ones fire before the
        turn-ender). History in DONE.md.
  - [x] enchantment that which reaches — range/radius +1 modifiers.
  - [x] enchantment bull form — distance +10 modifier.
  - [x] enchantment that which rushes — cooldown −1 + speed +1 modifiers.
  - [x] enchantment that which explodes — on_incoming_damage AoE attack
        (spell damage — the utility rule), options gated on the threat
        model (2 when threatened).
  - [x] enchantment promise of death — on_opponent_death: FULL-sweep
        reset (incl. off-bar preserved cds — self-buff, no exploit;
        contrast adrenaline's on-bar scope) + heal to full. Flat 1 when
        any active hostile exists.
  - [x] enchantment diamond form — IMPLEMENTED then REMOVED (design
        rejected: built-in downside + forced stalling — see DESIGN →
        Architecture → Skill design principles + DONE.md). History in
        DONE.md.

**TIER A COMPLETE — 19 skills, 0 engine changes** (20 designed;
        Diamond Form removed after implementation). Remaining new-design
        work is Tier B (four small engine gaps) and Tier C (two design
        sessions).

- [x] **Non-ending pool rating audit — COMPLETE.** SETTLED (see DESIGN →
      Architecture, AI rating scale — the four new bullets): the value-unit
      anchors (20% heal = 1, full heal = 2), the enhancement-enchantment
      rule (rate = best LIVE beneficiary + 1 — live = only casts that will
      actually fire this turn; fallback gate otherwise), the pass-scoped
      EvalFrame (`skill.zig` + `ai_select.optionsFor` — memoized once per
      pass, consultation cycles cut mechanically), and the virtual-effect
      sim differential (reaches, bull form — gating modifiers). Landed:
      idol heal 1, replenish 2, focus (weapon-skill reset count — fixed a
      wasted-cast gate bug), stone form / lingers / reaches / rushes /
      bull form (all on the beneficiary rule; reaches + bull form with
      the sim differential), and the sanity pass (howl/burst/accelerate/
      meditate coherent; blink/swap kept at 1). PLAYTEST-DEPENDENT
      follow-up: swap (and blink) can fire a pointless ADJACENT
      reposition — decide from playtest texture whether to gate
      (chebyshev > 1 on the chosen target); adjacent swaps might be
      deliberate displacement. History in DONE.md.

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
- [x] Editor footprint editing event + UI — DONE (the centered
      tile-grid picker; see DESIGN → Level Editor → Editor UI layout →
      the footprint editor).
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
left inspector; no dialogs; Test/Validate top-right; Upload deferred).
Most of it is implemented (see the slices below + DESIGN's Implemented
paragraph). Remaining work:

- Types + framing event handlers DONE (`open_editor` / `close_editor` /
  `start_playtest` / `end_playtest` / `start_validation` / `end_validation` +
  `editor_set_active_level`; exit guard in `end_level` / `end_mission`;
  round-trip test). See DESIGN → Architecture → Level Editor.
- **Revalidate Mission button** — DONE (the editor's options menu, under
  New Mission: re-certifies the stored validation replay against the
  current saved content — see DESIGN → Custom Missions & Online Services
  → Validation replay → Revalidate). OPEN: consider promoting it to the
  top bar next to Test/Validate (the options menu is where it landed for
  now); also the success message currently rides the error popup — a
  real notification/toast surface would be the proper home.
- **Test/Validate buttons DONE** — the top-right icon buttons
  (`player_start_playtest` / `player_start_validation` orchestrators +
  `validatePlayerAction` arms) + the exit rules (restart continuation
  RE-RUNS the run fresh — inline teardown + re-entry, since a
  transitionScreen clears the stack; any exit continuation drops back to
  the editor with `end_validation{success=false}` on validate) + the
  run-context UI (options menu + mission-fail overlay label their
  restart/exit buttons for the run; campaign Export Save hidden mid-run;
  Exit to Main Menu ends the run + closes the editor)
  + the tab-row scroll window against the new corner bound. History in
  DONE.md; design in DESIGN → Level Editor → Editor UI layout (primary
  actions + tabs) + the exit guard + run-context UI.
- Edit-verb events: DONE — every verb's struct in events.zig is handled
  (`handleEditorEvent` or the cache-needing inline cases in the dispatch);
  the never-pushed `editor_move_*_placement` trio was REMOVED (superseded
  by the selection move's chained `editor_commit_selection_move`; a future
  identity-preserving single-placement move re-adds the verb WITH its
  handler + planner in one slice). History in DONE.md.
- Editor input/UI: the settled layout/interaction design (DESIGN →
  Architecture → Level Editor → Editor UI layout — four zones: tabs,
  left inspector, viewport, right metadata sidebar + bottom tool palette;
  plus the centered sprite picker, the gradient-picking level-theme model,
  and the editor drawable projection for the viewport). Build as a
  vertical slice — static shell first (tabs + viewport + bottom bar +
  inspector + metadata sidebar rendering with real data, no interaction),
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
        (`editorInspectorEntityTarget`: the active entity tool, else the
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
        picker) re-target automatically. Only enemy fields were built at
        the time; the decoration + item contents have since landed (see
        their slices). History in DONE.md.
  - [x] **Collapsible inspector sections (author request):** DONE —
        every section header is a toggle (whole strip clickable, +/-
        marker prefix), ALL COLLAPSED by default, INDEPENDENT toggles (no
        accordion), `UiState.editor_inspector_section_expanded` keyed by
        `EditorInspectorSectionId` (shared across enemy + player
        contents) — a direct UiState write off the undo timeline. History
        in DONE.md; design in DESIGN → Level Editor → Editor UI layout
        (inspector).
  - [x] **6 — sprite picker (enemy base sprite):** DONE — the centered
        picker's second consumer: Mission / Official tabs top-left
        (mission-local scan at open time via
        `FileSource.listPersistentPngFiles`, cached on SessionState;
        official = comptime from the metadata table, player excluded),
        256×256 cells, pick commits through the existing
        `player_set_editor_entity_sprite`; the interim sprite-id text
        field is REMOVED. Mission-local ids are namespaced
        `custom/<mission-dir>/<stem>` with the resolution rule in DESIGN.
        Entity LAYERS remain deferred (below).
  - [x] **Decoration inspector + decoration sprite picker** — DONE:
        the `decoration_type` arm on `EditorInspectorTarget` (active
        decoration tool + selection inference; see DESIGN → Level Editor
        → Selection model), the Identity section (sprite row + WORLD-
        gradient color swatches) + the minimal Footprint placeholder
        (read-only tile count), the `editor_set_decoration_def` whole-
        definition commit (official pick = adopt the whole registry
        prefab; mission pick = custom stem + PNG-derived dims +
        bottom-left default footprint) with the placement PRUNE (see
        DESIGN → Level Editor → the centered sprite picker), the
        registry session-resident at open_editor, and the picker
        routing (kind by inspector target). History in DONE.md.
  - [x] **Layer editors (enemy + decoration)** — DONE: the shared
        Layers section (per layer: "Layer N" sprite-row + Delete,
        "Layer N color" swatches; an Add row), the picker's layer modes
        (`.entity_layer` / `.decoration_layer` on the picker target, null
        = add), the six layer verbs with the decoration dims-match
        invariant (official tab filters to matching dims; a mismatched
        custom pick keeps the picker open), registry-authored layer
        colors on add, re-pick-keeps-color, and no player layers (the
        player content has no Layers section; player_def layer targets
        are rejected at the replay seam). See DESIGN → Level Editor →
        Editor UI layout (the Layers sections) + the centered sprite
        picker. History in DONE.md.
  - [x] **The footprint editor** — DONE: the centered tile-grid picker
        (full-size sprite, toggleable 256×256 cells, white region
        outline, confirm-commits-if-changed + the shared placement
        prune; the draft on UiState, the type id on the picker target).
        See DESIGN → Level Editor → Editor UI layout (the footprint
        editor). History in DONE.md.
  - [ ] **Remaining layer-adjacent opens:**
        - custom-sprite DIMS verification (multiples of 256, sane
          bounds) at the pick commit + the footprint editor's open gate
          — currently any positive IHDR is accepted (base + layer picks)
          and sprites beyond the 8×8 draft grid don't open the editor;
        - picker scroll is a follow-up if real content overflows 4
          columns. (The LOAD-side dims resolution for `custom/<mission>/`
          decoration stems is DONE — see DESIGN → Level Editor → the
          centered sprite picker.)
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
  - [x] **9 — player inspector:** DONE (9a + 9b). 9a: the player
        fallback target renders full content through the shared windowed
        pipeline — Player header, read-only name line, the shared
        Weapons/Gear sections, the utility-skill row, a read-only
        inventory count; the six content emitters generalized onto an
        `InspectorEntityContext` (template + EntityEditTarget + team
        gradient); player-gradient coloring; text-field refs carry
        `.player_def`. NO name-editing/base stats (enemy-authorable only).
        9b: the IMPORT button (`player_import_editor_player` →
        `editor_import_player`, inline in processEvent — deep-copies the
        session PlayerData loadout (name/gear/inventory/utility skills,
        `build_player_from_data`'s set); empty session → parses
        `data/new_player.txt` via the reconstruction cache) +
        `instantiateEditorLevel` keeps `player_def.template.inventory` for
        entity 0 (loadout data, not runtime). History in DONE.md; design
        in DESIGN → Selection model (Inspector tool-type inference).
  - [x] **9b — playtest PlayerData: all skills learned + dormancy:**
        DONE — `Editor.pre_playtest_player_data` + the enter-from-edit
        backup/build (the run's data from the loadout with
        learned_skills = every utility skill) + restore on
        end_playtest / end_validation; the chained validation level
        starts never re-back-up (mode guard). History in DONE.md;
        design in DESIGN → Level Editor → Playtest/validate framing.
  - [x] **10 — player.txt format + max_player.txt:** DONE — save-shaped
        player.txt (v2, loadout sections only; `parsePlayerLoadoutFields`
        shared with `loadPlayerSave`, `playerLoadoutEntity` mapping), all
        four mission files rewritten (starter loadout kept),
        `data/max_player.txt` authored (max armor equipped, weapons +
        utility bar empty, 2 of each weapon type at max damage, all
        utility skills learned, all hubs discovered), open_editor load
        order mission-player.txt → max_player.txt (FileNotFound-specific
        fallback; a corrupt present file still errors). Includes the
        `DiscoveredHubs` parse in `loadPlayerSave` (was written but never
        read — discovery silently dropped on every save/load round
        trip). History in DONE.md; design in DESIGN → Level Editor →
        Player loadout.
  - [x] **11 — metadata sidebar (right bar), slice 1 — gradient-override
        model:** DONE — `CustomColorTheme`/`custom_theme` removed (dead
        scaffolding), `enemy_gradient_index`/`player_gradient_index: ?u32`
        on Level + EditorLevel, level-file Metadata keys + parser
        whitelist, `deriveActiveColorTheme` overrides (editor viewport
        previews the active level's full theme now), the two gradient
        EditorEvents + five player wrappers + handlers +
        `validatePlayerAction` arms, tests. History in DONE.md.
  - [x] **11 — metadata sidebar (right bar), slice 2 — shell + name
        fields:** DONE — `Editor.metadata_metadata_sidebar_open` +
        `editor_toggle_metadata_sidebar` (top-right toggle at the
        inspector toggle's height, flush right), right-edge panel,
        `TextEditTarget` union widening + shared `emitTextFieldUi`,
        mission + level name fields with would-change gates, M2
        arbitration extended, tests. History in DONE.md.
  - [x] **11 — metadata sidebar (right bar), slice 3 — gradient rows +
        theme picker:** DONE — the three single-line gradient rows
        (label + Auto + full-gradient swatch strip, one button opening
        the picker), the `.level_gradient` picker target (level + role
        snapshot), `buildEditorThemePicker` (bare strips, framed current
        index incl. derived-while-auto), `autoDerivedGradientIndex` as
        the spacing-rule single source, per-role pick commits with
        auto→manual flip + same-value no-ops, tests. History in DONE.md.
        (Superseded within the session: the rows are two-unit field
        entries now — see slice 4.)
  - [x] **11 — metadata sidebar (right bar), slice 4 — mirror the
        inspector UI exactly (author request):** DONE — renamed Settings →
        METADATA (events, flags, builder, action) + the section header
        "Current level"; the two sections are the shared collapsible
        strips (`EditorInspectorSectionId` += `.mission` /
        `.current_level`, collapsed by default, the existing toggle
        action + expansion array); the content is the inspector's exact
        entry/windowing/scrollbar model (`EditorMetadataEntry` +
        `editor_metadata_scroll` + wheel routing over the open panel);
        the gradient rows are two-unit entries (label line above, AUTO +
        swatch on the control line below). History in DONE.md.
        The picker OVERLAY question settled same-session: every centered
        picker renders in ONE fixed rect — the band BETWEEN the sidebars
        (full sidebar-panel height, a ui_gap each side), constant
        regardless of open state; fixed-size contents (6-column grids,
        fixed theme strips), the footprint editor scaling down oversized
        art. See DESIGN → Level Editor → Editor UI layout (the picker
        overlay). Landed with slice 4's follow-up commit.
  - [x] **12 — item inspector (the Items palette group):** DONE — the
        group rename, the real `EditorInspectorTarget.item_type` arm
        (active tool + ground-item selection inference), the "Item"
        section (Type rows + name + stats), reset-everything pick
        semantics, the flattened `editor_set_item_def` +
        `editor_set_item_name` with wrappers + validation arms, id
        tracking, the text-field machinery extension, tests (content
        emission, pick/commit handlers, session-log round-trip with a
        multi-word name). Design: DESIGN → Level Editor → Editor UI
        layout (Inspector fields, item types); history in DONE.md.
  - [x] **13 — player inventory editing (the player inspector's
        Inventory section):** the full 16×6 slot grid (the same 96
        `inventory_slot_count` indices the in-game 8×12 grid shows,
        arranged 6-wide to fit the panel — intentionally identical
        capacity). Selecting a slot (pure UiState, off the undo timeline)
        inserts the detail rows directly BELOW that slot's row: the
        Add/Delete button first (Add creates the default sword — the
        editor_defaults Items entry; Delete clears to null), then — ONLY
        while an item exists in the slot (author decision: no type rows
        while empty) — the item tool inspector's rows mirrored exactly
        (type pick rows with reset-everything semantics, name, per-stat
        fields). No scroll-on-select (the scroll offset stays). Slices:
        - [x] **1 — events + handlers + validation:**
              `editor_add_inventory_item` / `editor_delete_inventory_item` /
              `editor_set_inventory_item_def` (flattened — the
              `editor_set_item_def` shape; covers type picks AND stat
              edits) / `editor_set_inventory_item_name` +
              player wrappers + `validatePlayerAction` arms + tests
              (add/retype/rename/delete + undo walks, crafted-log
              guards).
        - [x] **2 — inspector content + input routing:** the slot grid
              (16 one-unit `inventory_slot_row` entries), the UiState
              selection (+ repeat-click deselect), the insert-below-row
              detail block (Add/Delete entry, then the type rows + name +
              stats only while occupied), selected-cell highlighting,
              replacing `inventory_summary`; the four new actions +
              payload plumbing (`AnytimeInput.clicked_editor_inventory_slot`).
        - [x] **3 — text-field commits:** `TextFieldId.inventory_item_*`
              + `TextEditTarget.inventory_slot` (index rides the ref —
              the level-name pattern), the commit sites mirroring the
              item_def arms, tests. History in DONE.md.
  Drag-painting is DONE (tile tool — `handleEditorTileDrag`: press paints
  the tile under the cursor immediately, held + move paints each
  newly-visited tile; see DESIGN → Level Editor → Active-tool model +
  DONE.md). The `.editor` screen renders the top row +
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
  already-selected entries; tool-agnostic — a non-select tool switches
  to select in the same action, one undo step restores tool + selection
  — see DESIGN → Level Editor → Selection model + DONE.md). The selection MOVE is DONE (plain left-drag on a selected
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
  INPUT: none — the tile tool's drag-paint landed (see above). All tools
  have left-click input + cursor previews + the right-click delete.
  No-op clicks never fire: each tool's effect is computed by a pure
  planner (`planEditor*Actions`, editor/planning.zig) shared by the
  handler + the input layer, and an empty plan means no player action
  (no undo/replay pollution); exact-duplicate decoration placements
  (same type + anchor) no-op too. See DESIGN → Level Editor →
  Active-tool model; history in DONE.md.
- **Hook up the add-level "+" (top bar, right of the level tabs).** DONE —
  `player_add_editor_level` orchestrator → the `editor_add_level` handler
  reading the template through the reconstruction cache, + the tab ×
  buttons (`player_delete_editor_level` → `editor_delete_level`). The
  template `data/default_level.txt` is written (the minimal `!=` layout).
  History in DONE.md.
- **Hook up the palette "+" cells (add-new type).** DONE — click →
  `player_add_editor_*_type` orchestrator → the `editor_add_*_type`
  handler building the type from `data/editor_defaults.txt` (the shipped
  defaults, level-format sections), making it the active tool, opening
  the inspector, and opening the base-sprite picker for enemies +
  decorations. History in DONE.md.
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
- [x] **Validation replay + file-based validation** — DONE (all five
  slices: pure machinery, file-based validation, the slice write +
  personal-best guard, the validation stats screen, the crown test).
  History in DONE.md; design in DESIGN → Custom Missions & Online
  Services → Validation replay + DESIGN → Level Editor
  (playtest/validate framing + exit guard).
- Editor autosave: nice-to-have, not need-to-have (explicit save for now).
- **Editor save-to-disk + export — DONE.** The mission writer
  (writers.writeEditorMission — the pure projection), the save
  (input_handlers.saveEditorMission: uuid resolution — opened-from-disk →
  in-memory, else the session memo, else a v4 mint; dir
  `missions/<uuid>_<name>/`; ctrl+S + the options-menu Save Mission
  button; a dump_event_log-class side effect — no recorded event, no undo
  step) and the export (save first, then bundle configs + the mission
  dir's pngs + a future validation_replay.txt into a STORE zip at
  `exported_missions/<uuid>_<name>.zip`; browser download on web). See
  DONE.md + DESIGN → Level Editor (the save/export flow). The
  mission-metadata derivation cleanup below is still OPEN.
- **Mission browser — DONE.** The full-screen modal over the editor
  (options-menu Open Mission button / ctrl+O), two tabs (Your Missions =
  persistent `missions/` via `listMissions`; Official = embedded campaign
  via `listOfficialMissions`), scan-on-open, row click → `open_editor` with
  the path, no unsaved-changes confirm (deliberate), `open_editor` bumps
  `world_generation` (the editor→editor UI reset). The WEB ZIP IMPORT is
  landed too (the Import button / ctrl+I → `zip_reader.zig` STORE+DEFLATE,
  marker poll, extraction into `missions/`). The options-menu NEW MISSION
  button / ctrl+N is DONE too (`new_editor_mission` → `open_editor` null
  path — the main-menu Editor button's action from inside the editor,
  undo restores the swapped-out mission; see DESIGN → Level Editor → The
  fresh-mission open). Design + history: DESIGN →
  Architecture → Level Editor → The mission browser + DONE.md.
  Browser polish (columns: author / level count / timestamp formatting,
  keyboard navigation) rides the load-save browser's polish slice when the
  UI design settles.

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
- [x] formatSessionTimestamp moved to session_log.zig (its natural home —
      the `created` stamp of session-log-shaped artifacts); consumers: the
      session dump, the autosave backup naming (meta's inline copy
      collapsed), the validation replay write. crash_dump keeps its own
      fallible/transient variant.

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

- [x] **Render resolution setting (runtime live-apply)** — DONE. The
      offscreen target resolution moved from the `-Drender-width`/
      `-Drender-height` build options (removed) to a `render_resolution`
      setting (720p/1080p/1440p/2160p, default 1080p), applied live via the
      frame diff-and-apply; a failed apply (GPU texture-size limits)
      reverts to the running preset + popup. Design: DESIGN → Platform Seam
      → Render target resolution; history in DONE.md. OPEN: browser + native
      runtime confirmation of the live swap (the platform-seam
      compiles-≠-runs rule).

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
- **raylib_backend.zig split — IN PROGRESS (this session):** the file
  owned rendering + audio + input polling + texture cache + SDF text +
  diagnostics and was the largest file in the tree (~2,700 lines). The
  single-seam design is right (one place to exclude from the headless
  test build, one place raylib can be imported — it made the miscompile
  hunt tractable); the split keeps the SAME module boundary, stronger:
  `src/raylib/` is a directory excluded WHOLESALE by the test-root scan
  (build.zig collectZigFiles) + asserted by scripts/test.sh (raylib may
  only be imported from src/raylib/). Design constraint: DESIGN →
  Platform Seam. Slices (each a commit; validation = scripts/test.sh +
  `zig build` + `zig build run` to the main menu, `scripts/web.sh`
  compile per the platform-seam compiles-≠-runs rule):
  - [x] 1. Pure move — `src/raylib_backend.zig` → `src/raylib/backend.zig`,
        import updates (native.zig/web.zig), directory-level exclusion,
        boundary assert in scripts/test.sh, doc sweep (AGENTS/DESIGN/TODO/
        build.zig + sdf_atlas_generator comments).
  - [x] 2. `src/raylib/input_poll.zig` — key/mouse mapping tables + the
        pollInput body (free fn over the backend's scratch buffers;
        ViewTransform stays in backend.zig — window math with the window
        owner).
  - [x] 3. `src/raylib/audio.zig` — `Audio` sub-struct owning the music
        stack + the four cue caches; RaylibBackend keeps thin pub
        wrappers (initAudio/playSounds/updateMusic — main.zig's `anytype`
        backend surface unchanged; deinitAudio dropped, deinit calls
        audio.deinit directly). Path building moved off the frame_arena
        onto fixed stack buffers; the init-time music phase-lock warning
        flows through a diag-sink callback (the backend formats it into
        the dev diag log).
  - [x] 4. `src/raylib/textures.zig` — `TextureStore` sub-struct owning
        the texture/outline/inset/sprite-bounds caches + all
        mask-generation math; `premultiplyAlpha` shared with the font
        loader; path building on fixed stack buffers. Draw sites go
        through `self.textures.*`; `entitySpriteBounds` keeps a pub
        wrapper (main.zig's RenderContext build).
  - [ ] 5. `src/raylib/text.zig` — font loading + the SDF outline
        pipeline + text drawing (`TextRenderer` sub-struct).
  - [ ] 6. `src/raylib/draw.zig` — world + UI element drawing (free fns
        over the backend, the handlers/ pattern); leaves backend.zig the
        thin driver.
  - [ ] 7. `src/raylib/diag.zig` — dev diag buffer + probes moved as-is
        (the pending diagnostics REDESIGN then has a clean landing spot).
- **Diagnostics redesign — settled design, implementation pending**
  (DESIGN → Platform Seam → Diagnostics): create raylib-free
  `src/diagnostics.zig` (`Diagnostics` type: buffer + section policy +
  end-of-frame flush scheduling, renames every `diag_*` identifier);
  add the `--diagnostics` CLI flag (native.zig, like `--replay` — any
  build, release included; dev-mode defaults to active); migrate the
  boot/probe/readback sections out of src/raylib/diag.zig as thin
  value-recording call sites; keep `logs/diag.txt` + whole-file-rewrite
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
  - [x] **Ctrl bindings → Command (mac convention):** DONE — the backend
        key table (`mac_key_mappings`, comptime `.macos`) maps
        left/right_super to `ControlLeft`/`ControlRight`, so every ctrl
        chord fires on Cmd with physical ctrl unchanged; one binding set
        still ships. Design: DESIGN → Input (macOS: Command reports as the
        Control ids); history in DONE.md.
  - [x] **mac 9-slice panel bug — SOLVED** (root cause found via a
        local IR diff; fix landed + IR-verified + friend-confirmed;
        audit clean). Optimized aarch64-macos builds passed
        UNINITIALIZED stack memory as drawNineSlice's DrawTexturePro
        tint: a Zig 0.16.0 compiler bug — the caller-side lowering of a
        by-value extern-struct parameter loads 8 bytes from the 4-byte
        Color object (IR-level poison), licensing LLVM to delete the
        stores that build the tint; any READ of the tint value (every
        diag variant) re-materialized it — which is why dev builds
        rendered and non-dev builds didn't. Full story + evidence:
        DONE.md, "mac 9-slice panels — ROOT CAUSE FOUND" + the
        consolidated experiment matrix entry. The 0.16.0 avoidance
        rule lives in AGENTS → Zig 0.16 Gotchas. Upstream zig report:
        DECISION PENDING — the repro project + report kit are in
        `../ziglop-mac-bisect/repro/` (see UPSTREAM_REPORT.md there;
        repro.zig + repro2.zig + per-version IR evidence).
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
- Real font: TTF loaded + per-glyph metrics feed the ui measurement seam (ui/element.zig `FontMetrics`)
  (DONE — see DONE.md). `drawTextLabel` still ignores bold/italic (only the
  regular face is loaded); honoring TextLabel bold/italic + color is a
  follow-up (needs separate bold/italic faces).
- Missing-art audit: some sprite ids are still placeholders
  (ui/icon_swap, ui/momentum, and the editor's ui/icon_playtest /
  ui/icon_validate) and will draw magenta until
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
- [x] **aiOptions allocation churn — RESOLVED by the EvalFrame** (the
      rating audit's follow-through): every option evaluation goes through
      `ai_select.optionsFor`, so each skill's aiOptions runs AT MOST ONCE
      per re-evaluation pass regardless of how consultation-dense the bar
      gets (enhancer scans + sim differentials consult freely). History in
      DONE.md (the pass-scoped EvalFrame).
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

- [x] **`floatWorldPoint` precision loss — RESOLVED** (cleanup session):
      `PointerInput.position` is a `PointerPosition` (f32) end-to-end; UI
      hit-testing truncates via `.toScreenPosition()` at the seam; the
      camera-pan anchor + tile resolution use the float directly. History
      in DONE.md.

- **Nested string fields in session-log payloads — RESOLVED.**
  `appendEventScalar` flattens nested struct/union fields as
  space-separated tokens, so a `[]const u8` INSIDE a nested payload can't
  contain spaces. Both live instances fixed (history in DONE.md): the
  equipped-slot events (unified into the flattened
  `editor_set_entity_gear` pair) and the LAYER events (flattened
  top-level `sprite`/`color_index`/`pixel_dims`) — mission directories +
  custom asset stems may carry spaces now. The def event's `layers`
  SLICE (which can't flatten) takes the serializer's indexed multi-line
  encoding — see DESIGN → Logging & Replay (String safety). The standing
  rule for FUTURE events: no string inside a single nested value
  (flatten to top level), no string-bearing struct slice outside the
  indexed encoding (the comptime guards enforce both).
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
- **Codebase split: ui.zig + event_handlers.zig — COMPLETE.** The two
  files grew to 15k + 6.6k lines and mix many jobs. Decisions settled:
  facade model for shared vocabulary (types + hit-testing + layout consts
  re-exported from ui.zig; `processEvent` stays in event_handlers.zig),
  DIRECT imports for specific builders/planners at call sites;
  subdirectories where coherent (`src/ui/`, `src/handlers/`, `src/editor/`);
  coherence of contents over line-count targets. `processEvent`'s inline
  switch prongs extract into per-category handler fns (recording/replay/
  checkpoint logic stays in the dispatch). Slices, each a commit +
  `scripts/test.sh` green:
  - [x] 1. `src/editor/planning.zig` — the pure `planEditor*Actions`
        planners + selection algebra + `activeEditorLevel` out of
        event_handlers.zig; input_handlers + handler_tests_editor import it
        directly.
  - [x] 2. `src/editor/handlers.zig` — `handleEditorEvent` + editor session
        helpers (import player, palette types, defaults, registry) +
        selection-mutation helpers out of event_handlers.zig.
  - [x] 3. `event_push.zig` — pushEvents/pushPlayerSkillUse/pushPlayerAction.
  - [x] 4. `src/handlers/` — meta / player / player_input / level handler
        files; processEvent prongs became handler fns; event_handlers.zig
        is the thin dispatch (183 lines). No hub file — hub state flows
        through meta + player-input events (no HubEvent exists).
  - [x] 5+. `src/ui/` — DONE in 6 slices (element/state/text_input →
        tooltip/emit → editor_chrome → editor_inspector → editor_pickers
        → bottom_bar/panels/screens/menus). ui.zig is the pure facade
        (256 lines). Tests moved with their subjects; consumers unchanged
        via the `ui.X` re-exports. Optional later: split
        editor_inspector's field emitters into editor_inspector_fields.zig
        (4,649 lines, ~1,700 of them tests).
  - [x] Follow-up: input_handlers.zig split — `src/input_gestures.zig`
        (drag/click/pan/slider/inspect + editor viewport gestures, with the
        pure gesture tests) + `src/editor/mission_io.zig` (save/export/import
        zip machinery + rescans). input_handlers.zig: 5,740 → 3,900
        (handleAnytimeInput/handleIdleInput + commits, its coherent core).
        The text-field commit sites STAY here by design (DESIGN → UI
        Framework → Text input widget: the field-kind commit switch lives
        in the input layer).
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
