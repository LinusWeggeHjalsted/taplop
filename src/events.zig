//! The event hierarchy: a single `Event` tagged union over Meta, Super,
//! Level, SubLevel, Player, Hub, and Editor event categories. Events are
//! generic state-mutation verbs (a skill is a recipe composing them); each
//! player action pushes one orchestrator that fans out into verbs. The event
//! stack is LIFO and `event_history` is the linearized replay source of truth.
//! See DESIGN → Architecture (Events are generic verbs, one orchestrator per
//! action) and Replay & Side Effects.

const types = @import("types.zig");

const Vector2 = types.Vector2;
const SkillId = types.SkillId;
const GearSlot = types.GearSlot;
const Materials = types.Materials;
const EffectId = types.EffectId;
const DecorationLayer = types.DecorationLayer;
const EntityEditTarget = types.EntityEditTarget;
const ItemKind = types.ItemKind;
const WeaponType = types.WeaponType;

/// The flattened equipped-slot item payload, shared by
/// `editor_set_entity_gear` + `player_set_editor_entity_gear` (the player
/// wrapper forwards it verbatim). `equipped: false` = the clear; only the
/// slot's kind's fields are meaningful while equipped - the defaults
/// carry the rest (writer emits all, reader requires all - the
/// session-log field-presence contract; the defaults keep construction
/// sites clean).
pub const EntityGearPayload = struct {
    target: EntityEditTarget,
    slot: GearSlot,
    equipped: bool,
    weapon_type: WeaponType = .sword,
    name: []const u8 = &.{},
    weapon_damage: u32 = 0,
    spell_damage: u32 = 0,
    health_bonus: u32 = 0,
    defense_bonus: u32 = 0,
    damage_bonus: u32 = 0,
    pickup_radius_bonus: u32 = 0,
    speed_bonus: u32 = 0,
};
const MissionCompleteInfo = types.MissionCompleteInfo;

/// How `end_level` continues after syncing the player entity back into
/// PlayerData. The options-menu exit paths use the non-default values.
pub const LevelExitContinuation = enum {
    default,
    restart_mission,
    exit_mission,
    exit_to_menu,
};

pub const MetaEvent = union(enum) {
    // scope: all
    // transitions between game scopes and file io
    // Pause turn flow for a fixed real-time duration (cosmetic pacing, not
    // skippable). Handled by update() stalling on GameState.waiting; a no-op
    // during replay (see GameStateHistory.replayTo).
    wait: struct {
        duration_milliseconds: u32,
    },
    // The intra-effect pacing wait - same stall machinery as `wait`, but the
    // duration is COMPUTED at pop time: `effect_step_wait_milliseconds`
    // decayed by 3/4 per prior accelerating wait in the chain
    // (`GameState.wait_acceleration`, reset by `use_skill`). Carries no
    // payload because the duration is a pure function of state - which is
    // what keeps it replay-safe (the counter is event-driven GameState,
    // recomputed identically on replay/undo). See DESIGN → Architecture →
    // Skill pacing.
    accelerating_wait: struct {},
    // Switch the ACTIVE campaign (the world-map acting path's cross-
    // campaign branch): load the target campaign's graph through the
    // reconstruction cache (the load_save / start_level precedent - a
    // recorded read, so replay is deterministic) + install it on
    // GameState, updating the PlayerData identity fields
    // (current_campaign_uuid / current_campaign). NO screen transition -
    // the event rides INSIDE a map-acting cascade beneath the real
    // arrival/entry (a transitionScreen would clear the event stack and
    // eat it; see player_travel_to_hub / player_start_mission_from_map).
    // The campaign's start hub is always act-legal even when the
    // campaign was never entered (no discovered group yet) - see
    // DESIGN → Campaigns & the Campaign Editor → Discovery + travel.
    install_campaign: struct {
        campaign_dir: []const u8,
        campaign_uuid: []const u8,
    },
    open_main_menu: void,
    close_main_menu: void,
    load_save: struct {
        save_path: []const u8,
    },
    // The pure file write. Persists current.player_data as-is; expects any
    // needed entity->PlayerData sync to have already run (see save_game).
    write_save: struct {
        save_path: []const u8,
    },
    // Copy the current autosave to a timestamped backup path, so starting a
    // new game doesn't silently destroy an existing autosave. No-op when no
    // autosave is present. Best-effort: a failure surfaces the error popup
    // but does not abort the new game. See DESIGN → File System & IO (Autosave).
    backup_autosave: void,
    start_mission: struct {
        mission_path: []const u8,
        // The mission's return destination (the exit's destination_hub -
        // the campaign edge) or null = return to the entering hub (the
        // dream story). The event, not a completion-time lookup, is the
        // replay-safe record of the edge. See DESIGN → Campaigns & the
        // Campaign Editor → The graph model.
        end_hub_id: ?[]const u8,
        // The hub the mission is ENTERED FROM (the world-map entry path:
        // the edge's start hub - current_hub on the way in, so abandoning
        // the mission returns there; DESIGN → Campaigns & the Campaign
        // Editor → Discovery + travel). Null = unchanged (the exit-tile
        // + restart paths stand in the hub already; current_hub is
        // already the entering hub).
        enter_hub_id: ?[]const u8 = null,
    },
    end_mission: struct {
        hub_id: ?[]const u8,
        // Non-null when the mission was completed (last level done) - carries
        // the info for the mission-complete overlay through to start_hub.
        // Null when abandoning (exit_mission). See DESIGN → Architecture.
        completed_mission: ?MissionCompleteInfo = null,
    },
    start_level: struct {
        mission_path: []const u8,
        level_index: u32,
        sets_checkpoint: bool = true,
    },
    // The continuation to take after ending the level. `.default` is the
    // normal next-level / end-mission flow; the others are the options-menu
    // exit paths (restart mission, abandon to hub, quit to main menu). See
    // DESIGN → Architecture.
    end_level: struct {
        continuation: LevelExitContinuation = .default,
        // The map-acting override for `.exit_mission`: suppress the exit's
        // own hub return (end_mission -> start_hub) - the world-map
        // travel / mission-entry cascades queue their REAL arrival
        // (start_hub / start_mission) beneath the end_level, and the
        // return's transitionScreen would clear the stack and eat it
        // (the state.transitionScreen contract). Null/normal = the
        // entering-hub return, the options-menu Exit Mission shape.
        suppress_return_hub: bool = false,
    },
    start_hub: struct {
        hub_id: []const u8,
        sets_checkpoint: bool = true,
        // Non-null when this hub entry follows a mission completion - sets
        // GameState.last_completed_mission so the overlay renders. Null on
        // a normal hub entry (clears any stale value). See DESIGN →
        // Architecture.
        completed_mission: ?MissionCompleteInfo = null,
    },
    end_hub: void,
    // Editor framing (see DESIGN → Architecture → Level Editor). open_editor
    // reads a mission from disk into an Editor session; start_playtest /
    // end_playtest bracket a single-level playtest (in-memory, the editor
    // draft); start_validation / end_validation bracket a full-mission
    // validation run of the SAVED mission dir (file-based - the artifact a
    // player receives; the handler reads the dir's files through the
    // reconstruction cache). The gameplay events stay pristine - end_level's
    // guard defers to these.
    close_editor: void,
    // Campaign-editor framing (the close_editor pattern: a plain scope
    // swap back to the main menu discards campaign_editor - see DESIGN
    // → Campaigns & the Campaign Editor → The editor-state split). The
    // HUB drill-in and the mission hand-off are in-editor screen states,
    // not separate framings.
    close_campaign_editor: void,
    // Close the hub editor drill-in and return to the campaign map. The
    // handler only transitions (the scope rule clears hub_editor - old
    // scope .hub_editor, new scope .campaign_editor lacks it); the
    // campaign graph was never left. The world-map return button fires
    // it. Edits already landed in the authored graph; navigation is
    // side-effect-free (the settled no-autosave rule).
    close_hub_editor: void,
    start_playtest: struct {
        level_index: u32, // 0-based into editor.levels
    },
    end_playtest: void,
    start_validation: struct {
        /// The saved mission dir the run certifies (the input layer saves
        /// first and passes the dir here). A top-level string field -
        /// verbatim in the session log, spaces-safe.
        mission_path: []const u8,
    },
    end_validation: struct {
        success: bool,
    },
    // UI surface toggles (class-1 semantic surface state - see DESIGN →
    // UI Framework → UI state classification). The state lives on
    // GameState.ui_surfaces so it rides the undo timeline and replays -
    // which is what lets validatePlayerAction gate gameplay orchestrators
    // on the surface that supplies their trigger. Flip one surface (the
    // keyboard / menu-button semantics; the entity-inspect toggle also
    // drops the panel's target).
    toggle_ui_surface: struct {
        surface: types.UiSurfaceId,
    },
    // The right-click entity-inspect verb: a non-null index OPENS (or
    // retargets) the entity-inspect panel on that entity, null CLOSES it.
    // The gesture resolves same/different/none against current state and
    // pushes the resolved intent - the event itself is unconditional.
    inspect_entity: struct {
        entity_index: ?u32,
    },
    // The remaining MetaEvent variants are machinery-only (handler-pushed,
    // never seeded at an idle point). Player-pushable events that used to
    // live here (start_new_game, save_game, open_editor,
    // dismiss_mission_complete, player_skip_level, player_restart_mission,
    // player_exit_mission, player_exit_to_menu, player_replay_mission) moved
    // to `PlayerInputEvent`. See DESIGN → Determinism & Tiebreaking → Replay
    // PLAYER-ACTION LEGALITY.
};

pub const SuperEvent = union(enum) {
    // scope: all
    // player data synchronization
    build_player_from_data: struct {
        entity_index: u32,
    },
    build_data_from_player: struct {
        entity_index: u32,
    },

    save_clone_info: struct {
        mission_uuid: []const u8,
        mission_name: []const u8,
        total_turns: u32,
        total_materials: Materials,
    },
    // Harvest materials from all saved clones at mission completion. Each
    // clone pays out `rate * turns_spent` per material, where
    // `rate = clone.materials_collected / clone.turns_to_complete`. Gated on
    // `turns_spent > 0` (div-by-zero guard for dev skip-through). See DESIGN
    // → Clones (clone system).
    harvest_clones: struct {
        turns_spent: u32,
    },
};

pub const EditorEvent = union(enum) {
    // scope: editor
    // One EditorEvent per player action (the orchestrator convention - see
    // DESIGN → Architecture). Most editor edits are a single verb, so they
    // live directly here as their own variant. The exception is
    // editor_delete_type, an orchestrator that pushes editor_delete_*_placement
    // sub-events (SubEditorEvent) for each referencing placement before
    // removing the type. All editor events mutate current.editor.?.levels[]
    // or the palette directly - pure state transforms captured by deepCopy,
    // so undo/redo works by construction. See DESIGN → Architecture → Level
    // Editor → Editor UI layout for the full design.

    // ── Active tool ──
    // Switch the active tool (a palette cell click). The select tool's
    // selection is cleared in the same event whenever the new tool is not
    // `.select` (invariant: selection nonempty ⇔ active tool is select),
    // so a tool switch + its selection clear revert together on undo.
    editor_set_tool: struct {
        tool: types.EditorToolId,
    },

    // ── Inspector panel ──
    // Flip the inspector sidebar's open state (the top-left toggle button,
    // below options; open by default - see `Editor.inspector_open` for why
    // the flag lives on the Editor). Undo flips it back with the edit
    // history, same posture as `editor_set_tool`.
    editor_toggle_inspector: void,
    // Flip the metadata sidebar's open state (the top-right toggle - same
    // convention as `editor_toggle_inspector`: the flag lives on the
    // Editor, the toggle rides the undo timeline).
    editor_toggle_metadata_sidebar: void,
    // Open the centered picker on a target - class-1 surface state (the
    // picker is a modal surface; see DESIGN → UI Framework → UI state
    // classification). Sets `Editor.picker`, REPLACING any stale picker
    // still open (the palette-group dropdown semantics - the open event is
    // the close of whatever it replaces, one action).
    editor_open_picker: struct {
        target: types.EditorPickerTarget,
    },
    // Close the centered picker. Pushed by the picker's Close button / a
    // no-change pick AND as a child of every picker-commit orchestrator
    // (the commit's own handler pushes it - pick+close is one undo step).
    // Closing a closed picker is a graceful no-op (crafted logs).
    editor_close_picker: void,
    // Import a loadout into the editor player (the player inspector's
    // Import buttons): the session's player data, or the new-game default
    // save when the session has none. Handled INLINE in processEvent -
    // the default-save read needs the reconstruction cache.
    editor_import_player: void,
    // The Max player import (data/max_player.txt - the author-times tool
    // for official missions): same inline handling + same reason.
    editor_import_max_player: void,

    // ── Selection (the select tool) ──
    // Granular by design: a click toggles a GROUP (up to tile + entity +
    // item), pushing one event per entry - they share the click's idle
    // point, so one undo step reverts the whole click, and a future
    // marquee / shift-click batch reads as a run of additions. Entries
    // address the ACTIVE level (see `types.Selectable`).
    editor_select: struct {
        entry: types.Selectable,
    },
    editor_deselect: struct {
        entry: types.Selectable,
    },
    // Clear the whole selection (ctrl+D). One event, not a per-entry
    // fan-out: a clear is a single operation, and a large marquee's
    // worth of deselect lines would be log noise, not readability (the
    // granular add/remove events exist for the click + marquee semantics,
    // where the entries carry meaning). The tool-switch and level-tab
    // clears are side effects of THEIR events; this is the explicit
    // user action.
    editor_clear_selection: void,
    // Commit ONE link of a selection move's placement worklist (see
    // `player_move_editor_selection`). Chained by necessity: each entry is
    // planned against the LIVE post-delete state via the placement
    // planners - up-front planning of the whole worklist breaks when two
    // entries' targets share a covering decoration (duplicate delete →
    // stale index) or an item entry's enemy-delete shifts an index a
    // later retype still addresses. Each link plans `entries[next_index]`,
    // pushes `[next link, ...plan]` (LIFO: the plan processes first), and the
    // exhausted link clears the selection (a move deselects - nothing is
    // reselected). Recorded once per link; replay reproduces the chain.
    editor_commit_selection_move: struct {
        entries: []const types.EditorSelectionMoveEntry,
        next_index: u32,
    },

    // ── Level management ──
    // Switch the active level tab. Pure state on editor.active_level_index.
    editor_set_active_level: struct {
        level_index: u32,
    },
    // Append a new level built from data/default_level.txt (the minimal `!=`
    // template). No payload - the template is fixed; the author renames /
    // re-themes via the metadata events below. The same handler switches the
    // active tab to the new level (the author lands on the thing they just
    // created - the add-type behavior) and syncs mission.level_count.
    editor_add_level: void,
    // Delete a level. Handler removes it, shifts later indices down, syncs
    // mission.level_count, adjusts active_level_index (a delete BELOW the
    // active tab shifts it down; deleting the ACTIVE level clamps + clears
    // the selection - the editor_set_active_level semantics; the selection
    // is active-level-relative). Gated on levels.len > 1 (a mission always
    // has ≥1 level - the handler panics if violated; the UI shouldn't offer
    // the × on the last tab, but the event enforces the invariant).
    editor_delete_level: struct {
        level_index: u32,
    },

    // ── Level tiles ──
    // Set a single tile (paint floor / erase). One event per cell: the
    // drag-paint gesture pushes one per tile the pointer enters (see
    // handleEditorTileDrag), and undo granularity is per tile by design.
    editor_set_tile: struct {
        level_index: u32,
        position: Vector2,
        is_floor: bool,
    },

    // ── Level + mission metadata ──
    editor_set_level_name: struct {
        level_index: u32,
        name: []const u8,
    },
    // Set the level's world gradient index (the role `color_wheel_index`
    // plays in the level file). Enemy/player gradients auto-derive from it
    // unless overridden below. See DESIGN → Architecture → Level Editor →
    // Level theme (gradient picking).
    editor_set_level_color_wheel: struct {
        level_index: u32,
        color_wheel_index: u32,
    },
    // Set a per-role gradient override, or null to revert to auto-deriving
    // from the world index (world + N/3 / world + 2·N/3).
    editor_set_level_enemy_gradient: struct {
        level_index: u32,
        gradient_index: ?u32,
    },
    editor_set_level_player_gradient: struct {
        level_index: u32,
        gradient_index: ?u32,
    },
    editor_set_mission_name: struct {
        name: []const u8,
    },

    // ── Player start + level end (move-only, non-deletable) ──
    editor_set_player_start: struct {
        level_index: u32,
        position: Vector2,
    },
    editor_set_level_end: struct {
        level_index: u32,
        position: Vector2,
    },

    // ── Palette type management ──
    // Append a new type to the corresponding palette group, built from the
    // shipped defaults (data/editor_defaults.txt - one entry per kind in
    // the level-file formats). No payload - the default is fixed shipped
    // content; the handler reads it through the reconstruction cache so
    // replay reproduces the creation. The same handler makes the new type
    // the active tool and opens the inspector (the auto-open-on-creation
    // behavior), so one undo step reverts the whole creation.
    editor_add_entity_type: void,
    editor_add_decoration_type: void,
    editor_add_item_type: void,
    // Delete a palette type AND every placement referencing it, across ALL
    // levels (the palette is mission-shared). The handler fans out into
    // `editor_delete_*_placement` sub-events for every referencing
    // placement (they own the order-preserving removal + the active-level
    // selection prune/remap), then removes the type and decrements every
    // same-kind type id above it (palette indices shift down) - the one
    // orchestrator in this set. The active tool is reconciled in the same
    // event: the deleted type → select, a higher same-kind index →
    // decremented. All the events share the triggering player action's
    // idle point - one undo step restores the type and every placement.
    editor_delete_type: struct {
        type_kind: EditorTypeKind,
        type_id: u32,
    },

    // ── Placement (viewport clicks with a placement tool active) ──
    // Per-kind variants (not a Selectable-carrying generic event) so the
    // exported log reads self-describing: `editor_place_entity { ... }` over
    // `editor_place { kind entity, ... }`.
    editor_place_entity: struct {
        level_index: u32,
        type_id: u32,
        position: Vector2,
    },
    editor_place_decoration: struct {
        level_index: u32,
        type_id: u32,
        position: Vector2,
    },
    editor_place_item: struct {
        level_index: u32,
        type_id: u32,
        position: Vector2,
    },
    editor_delete_entity_placement: struct {
        level_index: u32,
        placement_index: u32,
    },
    editor_delete_decoration_placement: struct {
        level_index: u32,
        placement_index: u32,
    },
    editor_delete_item_placement: struct {
        level_index: u32,
        placement_index: u32,
    },
    // Retype an entity placement to another palette type in place (the
    // entity-tool click on an occupied tile): identity (index) and position
    // stay stable - nothing referencing the placement shifts. Preferred
    // over delete + re-place for exactly that reason.
    editor_set_entity_placement_type: struct {
        level_index: u32,
        placement_index: u32,
        type_id: u32,
    },
    // Retype an item placement to another palette type in place (the
    // ground-item-tool click on an occupied tile): identity (index) and
    // position stay stable - same reasoning as
    // `editor_set_entity_placement_type`.
    editor_set_item_placement_type: struct {
        level_index: u32,
        placement_index: u32,
        type_id: u32,
    },

    // ── Entity type editing (per-field, target covers entity_type | player_def) ──
    // Dedicated variants (not a generic field+value event) so the log reads
    // `editor_set_entity_name { target entity_type 0, name Skeleton Warrior }`
    // - the variant name carries the field. Each is one field = one undo.
    editor_set_entity_name: struct {
        target: EntityEditTarget,
        value: []const u8,
    },
    // Base-sprite pick commit. `keep_original_colors` rides the pick - the
    // pick-time default follows the art source (official stem → false,
    // mission-local custom art → true; see DESIGN → Entity & UI Coloring,
    // keep_original_colors). One event = one undo step. Defaults false so
    // pre-field session logs replay unchanged.
    editor_set_entity_sprite: struct {
        target: EntityEditTarget,
        value: []const u8,
        keep_original_colors: bool = false,
    },
    editor_set_entity_color_index: struct {
        target: EntityEditTarget,
        value: u32,
    },
    editor_set_entity_displays_weapons: struct {
        target: EntityEditTarget,
        value: bool,
    },
    // The untinted-render toggle (see DESIGN → Entity & UI Coloring,
    // keep_original_colors) - the displays_weapons toggle's shape.
    editor_set_entity_keep_original_colors: struct {
        target: EntityEditTarget,
        value: bool,
    },
    editor_set_entity_max_health: struct {
        target: EntityEditTarget,
        value: u32,
    },
    editor_set_entity_speed: struct {
        target: EntityEditTarget,
        value: u32,
    },
    editor_set_entity_defense: struct {
        target: EntityEditTarget,
        value: u32,
    },
    editor_set_entity_aggro_range: struct {
        target: EntityEditTarget,
        value: u32,
    },
    // Team is ENEMY-authorable only: 0 = the player's team (helpers the
    // player doesn't control), 1+ = mutually hostile enemy teams. The
    // player_def target is rejected at the replay seam - the player's
    // team is definitionally 0.
    editor_set_entity_team: struct {
        target: EntityEditTarget,
        value: u32,
    },
    // Gear: ONE slot-parameterized event (equip/unequip/retype/field
    // edit - the whole-definition commit, the editor_set_item_def /
    // editor_set_decoration_def shape). The item's fields are FLATTENED
    // onto the payload: a nested `?Weapon`-style value can't round-trip
    // the session log once its name contains a space (nested strings
    // serialize as one space-separated token - see session_log.zig
    // parseScalarTokens), and the editor's own defaults ("New Sword")
    // carry spaces. `equipped: false` = the clear (Delete); only the
    // slot's kind's fields are meaningful while equipped (the handler
    // ignores the rest). Shared payload type: the player wrapper forwards
    // it verbatim.
    editor_set_entity_gear: EntityGearPayload,
    // Utility skills: per-slot (slot_index 0..utility_skill_count-1), nullable.
    editor_set_entity_utility_skill: struct {
        target: EntityEditTarget,
        slot_index: u32,
        value: ?SkillId,
    },
    // Entity sprite layers (base + overlays). Add/remove/set per layer.
    // The layer's fields are FLATTENED to top level (a nested layer's
    // sprite string can't round-trip the session log once it contains a
    // space - mission-dir names carry spaces; see session_log.zig).
    editor_add_entity_layer: struct {
        target: EntityEditTarget,
        sprite: []const u8,
        color_index: u32,
    },
    editor_remove_entity_layer: struct {
        target: EntityEditTarget,
        layer_index: u32,
    },
    editor_set_entity_layer: struct {
        target: EntityEditTarget,
        layer_index: u32,
        sprite: []const u8,
        color_index: u32,
    },

    // ── Decoration type editing ──
    // The whole definition commits in ONE event (the editor_set_item_def
    // precedent): the inspector's sprite pick adopts a full prefab (sprite,
    // footprint, pixel dims, color index, layers) or a custom stem with a
    // derived default footprint, and a footprint change can invalidate the
    // type's placements - one event = one undo step covering the retype +
    // the placement prune. The fields are FLATTENED to top level (the
    // session-log reader doesn't regroup nested non-u8 slices - see
    // session_log.zig parseScalarTokens). The palette label (`id`) always
    // tracks the sprite (a decoration's name IS its sprite path). Per-field
    // events remain for the verbs that don't retype: color_index (the
    // swatch) and footprint (the future footprint editor; shares the prune
    // helper).
    editor_set_decoration_def: struct {
        type_id: u32,
        sprite: []const u8,
        footprint: []const Vector2,
        pixel_dims: Vector2,
        color_index: u32,
        // Whole-def commits carry the full visual identity incl. the
        // untinted-render flag (official picks adopt the prefab's false;
        // mission-local picks carry true - see DESIGN → Entity & UI
        // Coloring, keep_original_colors). Defaults false for pre-field
        // logs.
        keep_original_colors: bool = false,
        layers: []const DecorationLayer,
    },
    editor_set_decoration_color_index: struct {
        type_id: u32,
        value: u32,
    },
    // The decoration content's untinted-render toggle (the displays_weapons
    // toggle's decoration counterpart; granular like the color_index event -
    // the flag never affects placement validity, no prune).
    editor_set_decoration_keep_original_colors: struct {
        type_id: u32,
        value: bool,
    },
    editor_set_decoration_footprint: struct {
        type_id: u32,
        value: []const Vector2,
    },
    editor_add_decoration_layer: struct {
        type_id: u32,
        sprite: []const u8,
        color_index: u32,
        /// Draws behind the base - the picker commit adopts the registry
        /// prefab's authored draw side for the stem (tree_*_grass_back is
        /// true), else false (an overlay). Defaults false for pre-field logs.
        behind: bool = false,
        pixel_dims: Vector2,
    },
    editor_remove_decoration_layer: struct {
        type_id: u32,
        layer_index: u32,
    },
    editor_set_decoration_layer: struct {
        type_id: u32,
        layer_index: u32,
        sprite: []const u8,
        color_index: u32,
        /// The layer's draw side, kept from the replaced layer at the
        /// picker commit (a re-pick edits the visual identity, not the
        /// placement). Defaults false for pre-field logs.
        behind: bool = false,
        pixel_dims: Vector2,
    },

    // ── Item type editing ──
    // The whole definition commits in ONE event per edit (a type pick, a
    // stat change - one undo step each). The item's fields are FLATTENED
    // to top level (the `editor_set_decoration_def` precedent): a nested
    // `Item` payload's name string can't round-trip the session log once
    // it contains a space (nested strings serialize as one space-separated
    // token - see session_log.zig parseScalarTokens), and the default
    // names ("New Sword") carry spaces by design. `item_kind` picks the
    // variant; only its fields are meaningful (the handler ignores the
    // rest). Skill tomes are NOT expressible (not authorable as ground
    // items - the level-file Items section has no tome kind); `name`
    // commits ride `editor_set_item_name` instead (a top-level string,
    // spaces fine). Stats are clamped to the `max_*` bounds by the live
    // path AND the handler (the editor never holds a state its own load
    // path would clamp away).
    editor_set_item_def: struct {
        type_id: u32,
        item_kind: ItemKind,
        // Only the picked kind's fields are meaningful (writer emits all,
        // reader requires all - the session-log field-presence contract;
        // the defaults just keep construction sites clean).
        weapon_type: WeaponType = .sword,
        name: []const u8 = &.{},
        weapon_damage: u32 = 0,
        spell_damage: u32 = 0,
        health_bonus: u32 = 0,
        defense_bonus: u32 = 0,
        damage_bonus: u32 = 0,
        pickup_radius_bonus: u32 = 0,
        speed_bonus: u32 = 0,
    },
    editor_set_item_name: struct {
        type_id: u32,
        value: []const u8,
    },

    // ── Player loadout inventory editing ──
    // The player-def inspector's Inventory section (the 16×6 slot grid -
    // the same 96 `inventory_slot_count` indices the in-game 8×12 grid
    // shows, arranged to fit the panel). Same conventions as the item
    // type editing above: the def commit is FLATTENED (nested Item names
    // can't round-trip the session log - same why), covers type picks
    // (reset-everything semantics) AND stat edits (one undo step each),
    // and the handler clamps stats; name commits ride their own event
    // (top-level string, spaces fine). Add creates the default sword
    // ("New Sword", the editor_defaults.txt Items entry - the palette
    // "+" default); Delete clears to null.
    editor_add_inventory_item: struct {
        index: u32,
    },
    editor_delete_inventory_item: struct {
        index: u32,
    },
    editor_set_inventory_item_def: struct {
        index: u32,
        item_kind: ItemKind,
        weapon_type: WeaponType = .sword,
        name: []const u8 = &.{},
        weapon_damage: u32 = 0,
        spell_damage: u32 = 0,
        health_bonus: u32 = 0,
        defense_bonus: u32 = 0,
        damage_bonus: u32 = 0,
        pickup_radius_bonus: u32 = 0,
        speed_bonus: u32 = 0,
    },
    editor_set_inventory_item_name: struct {
        index: u32,
        value: []const u8,
    },
};

/// Which palette group a type belongs to (for editor_delete_type). Matches
/// the three palette groups in the bottom bar.
pub const EditorTypeKind = enum {
    entity,
    decoration,
    item,
};

pub const PlayerEvent = union(enum) {
    // scope: hub or level
    // Player-inventory/gear/skill mutations pushed by the drag handler
    // (machinery - not player-input events). `swap_hands` moved to
    // `PlayerInputEvent` (it's a keybind/click, not a drag).
    learn_skill: struct {
        inventory_slot_index: u32,
    },
    salvage_item: struct {
        inventory_slot_index: u32,
    },
    // Equip an inventory item into a gear slot. The previously equipped piece
    // (if any) drops back into the same inventory slot. No-op if the item does
    // not fit the target slot.
    equip_item: struct {
        inventory_slot_index: u32,
        gear_slot: GearSlot,
    },
    // Move a gear piece into an inventory slot. Empty target: plain unequip.
    // Filled target: swap only if the inventory item fits the gear slot,
    // otherwise no-op.
    unequip_item: struct {
        gear_slot: GearSlot,
        inventory_slot_index: u32,
    },
    // Assign a learned skill to a utility bar slot (0-4), overwriting whatever
    // was there. Skills come from the learned pool, so nothing is swapped back.
    equip_utility_skill: struct {
        skill_id: SkillId,
        slot_index: u32,
    },
    // Reorder two utility bar slots by swapping their contents.
    swap_utility_skills: struct {
        slot_a_index: u32,
        slot_b_index: u32,
    },
    // Clear a utility bar slot (drag a skill off the bar).
    unequip_utility_skill: struct {
        slot_index: u32,
    },
    // Swap two inventory slots. Also covers move-to-empty: a swap with an
    // empty target is a move (item → empty, null → source). No gear
    // side-effects (unlike equip/unequip).
    swap_inventory_items: struct {
        slot_a_index: u32,
        slot_b_index: u32,
    },
};

/// Campaign-editor events - the campaign editor's own category (the
/// EditorEvent sibling, mirroring the parallel-state settle: these mutate
/// `current.campaign_editor.?`, never `current.editor`). One event per
/// player action (the orchestrator convention); pushed by the input
/// consumption sites as children of orchestrators, pure state transforms
/// captured by deepCopy, so undo/redo works by construction. The one
/// non-pure exception is `editor_campaign_set_background` (the PNG dims
/// read - live, deterministic, the open path's posture). See DESIGN →
/// Campaigns & the Campaign Editor → The campaign editor surface.
pub const CampaignEditorEvent = union(enum) {
    // scope: campaign_editor

    // ── Active tool ──
    // Switch the active tool (the palette click). A switch away from
    // select clears the selection in the same event (the mission
    // editor's editor_set_tool invariant).
    editor_campaign_set_tool: struct {
        tool: types.CampaignEditorToolId,
    },

    // ── Selection ──
    // Select a hub (null deselects). Single-select v1; placing a hub
    // selects it (the inspector's "or the last placed object" rule).
    // A selection is non-null only while the active tool is select (the
    // tool-switch clear keeps the invariant in one undo step).
    editor_campaign_select_hub: struct {
        hub: ?u32,
    },

    // ── Hubs ──
    // Place a hub at a map position (the hub tool's click on empty
    // canvas): the default template - name "New Hub", the
    // single-'!' grid - minted handle, selected. Clicks landing on an
    // existing hub never place (the input layer resolves them to a
    // select instead).
    editor_campaign_place_hub: struct {
        position: Vector2,
    },
    // Move a hub (the select tool's drag commit - one event on release,
    // the preview is transient drag state off the timeline).
    editor_campaign_set_hub_position: struct {
        hub: u32,
        position: Vector2,
    },
    // Rename a hub (the inspector's name field). Free: references are
    // handles + uuids, never names.
    editor_campaign_set_hub_name: struct {
        hub: u32,
        name: []const u8,
    },
    // Set the campaign's start hub (the radio toggle: overwrites the
    // single slot). Untoggling the CURRENT start hub never fires (the
    // input layer vetoes + surfaces the message).
    editor_campaign_set_start_hub: struct {
        hub: u32,
    },
    // Delete a hub. Never fires for the start hub (the input layer
    // vetoes). The missions it touches become ORPHANS frozen in place:
    // each touching mission's dead end nulls + stores the hub's position
    // as its ghost; the hub's exit placements die with it (no marker
    // cleanup); handles stay stable. Files are removed only at the full
    // campaign save (3e).
    editor_campaign_delete_hub: struct {
        hub: u32,
    },

    // ── Campaign metadata ──
    // Rename the campaign (the metadata sidebar's name field; free -
    // identity is the uuid).
    editor_campaign_set_campaign_name: struct {
        name: []const u8,
    },
    // Set the campaign background (the metadata picker's pick): the bare
    // stem; the handler re-resolves the PNG dims live (deterministic on
    // replay - same files).
    editor_campaign_set_background: struct {
        stem: []const u8,
    },
    // Open the centered picker (the metadata sidebar's background
    // button). The open state rides the undo timeline (the picker's
    // list acquisition is session-side - replay never opens a picker).
    editor_campaign_open_picker: struct {
        picker: types.CampaignEditorPicker,
    },
    // Close the centered picker (the panel's Back button; the COMMIT
    // handler also pushes this as a child of the pick - one undo step).
    editor_campaign_close_picker: void,
    // Toggle the inspector sidebar (the top-left strip; open by default -
    // the editor_toggle_inspector convention: the flag rides the undo
    // timeline).
    editor_campaign_toggle_inspector: void,
    // Toggle the metadata sidebar (the top-right strip; closed by
    // default).
    editor_campaign_toggle_metadata_sidebar: void,

    // ── Missions ──
    // Select a mission (an edge click under the select tool). The
    // selection is a hub-or-mission union; this arm sets the mission arm.
    editor_campaign_select_mission: struct {
        mission: u32,
    },
    // Place a mission + its edge in ONE gesture (the mission tool's
    // click-start-hub / click-end-hub draw; start == destination = a
    // self-loop). The handler mints the handle + the "New Mission"
    // template (name + a unique temp anchor dir) and selects it.
    editor_campaign_place_mission: struct {
        start: u32,
        destination: u32,
    },
    // Rename a mission (the mission inspector's name field).
    editor_campaign_set_mission_name: struct {
        mission: u32,
        name: []const u8,
    },
    // Set a mission's authored direction (self-loops + dangling stubs;
    // null = clear to the auto-spread default).
    editor_campaign_set_mission_direction: struct {
        mission: u32,
        direction: ?u32,
    },
    // Re-attach one end of a mission to a hub (the mission inspector's
    // re-attach pick-mode: click the button, then click a hub). The
    // re-attached end's ghost position clears; a re-attached START also
    // drops the mission's exit marker from the old start hub (the marker
    // is re-placed in the new hub via the hub editor - a salvaged mission
    // shows as unstartable until then, the validation finding).
    editor_campaign_reattach_mission: struct {
        mission: u32,
        end: types.CampaignMissionEnd,
        hub: u32,
    },
    // Delete a mission (the right-click on an edge): the entry + its exit
    // placement in its start hub go together (the mission IS the edge).
    // Files are removed only at the full campaign save (3e).
    editor_campaign_delete_mission: struct {
        mission: u32,
    },
    // An import landed (the mission inspector's Import picker - the
    // copy-at-pick already happened at the input layer; this event
    // carries the copied mission's resolved identity and adds the entry
    // UNWIRED (an orphan - the author re-attaches it). Duplicate-uuid
    // imports are refused at the pick site, never pushed.
    editor_campaign_import_mission: struct {
        uuid: []const u8,
        dir: []const u8,
        name: []const u8,
    },
};

/// One hub-editor edit (the slice-4 drill-in's event family - scope:
/// hub_editor; replay validates screen == .hub_editor + hub_editor != null,
/// the campaign_editor/hub_handlers arms). The TARGET hub is the drill-in's
/// own handle (HubEditor.hub) - never carried per event, the drill-in IS
/// the address; every arm resolves it against the live authored graph and
/// no-ops on a dead handle (the crafted-log convention). All events write
/// through into current.campaign_editor.?.hubs[] by handle (the grid is
/// never copied) - pure state transforms captured by deepCopy, so undo/redo
/// and replay work by construction. One event per player action (the
/// orchestrator convention); the exception is hub_commit_selection_move,
/// the self-chaining worklist (the editor_commit_selection_move mirror).
/// The shapes mirror EditorEvent one-for-one minus the mission-only verbs
/// (entities, items, level tabs, level_end): a hub grid is an EditorLevel
/// with tiles + player start + decorations (+ NPC/exit placements, whose
/// verbs land with 4-4).
pub const HubEditorEvent = union(enum) {
    // ── Active tool ──
    // Switch the active tool (the palette cell click / the Tab cycle). A
    // switch away from select clears the selection in the same event (the
    // editor_set_tool invariant).
    hub_set_tool: struct {
        tool: types.HubEditorToolId,
    },

    // ── Inspector ──
    // Toggle the inspector sidebar (the editor_campaign_toggle_inspector
    // convention: the flag rides the undo timeline).
    hub_toggle_inspector: void,
    // Toggle the metadata sidebar (the inspector field's own convention).
    hub_toggle_metadata: void,

    // ── Tiles + decorations ──
    // Paint/erase one floor tile (the tile tool's click / the move chain's
    // ground-ensuring paint). Idempotent on the current state (an erase of
    // an absent tile no-ops); an erase prunes a selected tile entry at the
    // same position.
    hub_set_tile: struct {
        position: Vector2,
        is_floor: bool,
    },
    // Place a palette decoration with its ANCHOR tile at `position` (the
    // decoration tool at 4-5 + the move chain's decoration re-placement).
    // Enforces footprint-tile exclusivity (panic on a covered placement -
    // the delete-first ordering is the planners' contract).
    hub_place_decoration: struct {
        type_id: u32,
        position: Vector2,
    },
    // Order-preserving removal (placement indices are the identity the
    // move/delete events address); reconciles the selection (a higher
    // selected index shifts down, a selected index leaves).
    hub_delete_decoration_placement: struct {
        placement_index: u32,
    },

    // ── NPCs + exit markers (the 4-4 kinds) ──
    // Place an NPC of `npc_type` at `position` (the NPC tool / the move
    // chain's re-placement). Enforces the one-thing-per-cell exclusivity
    // (panic on an occupied cell - the delete-first ordering is the
    // planner's contract); the tile under it is a separate set_tile.
    hub_place_npc: struct {
        npc_type: types.NpcType,
        position: Vector2,
    },
    // Order-preserving NPC removal; reconciles the selection like the
    // decoration removal.
    hub_delete_npc_placement: struct {
        placement_index: u32,
    },
    // UPSERT the mission's exit marker at `position` (the mission tool's
    // click): creates the marker or MOVES the mission's existing one,
    // wherever it was (one marker per mission - the layout format's one
    // digit per cell). The mission is a campaign HANDLE.
    hub_set_exit_marker: struct {
        mission: u32,
        position: Vector2,
    },
    // Remove the mission's exit marker (the right-click delete's marker
    // tier). The mission becomes unstartable - a validation finding, a
    // deliberate act; the graph wiring is untouched.
    hub_delete_exit_marker: struct {
        mission: u32,
    },

    // ── The campaign-shared decoration palette (4-5) ──
    // Append a new decoration type from the default template (the "+"
    // cell - the editor_add_decoration_type convention over the
    // CAMPAIGN-shared palette: every hub's placements index into it).
    hub_add_decoration_type: void,
    // Remove a decoration type + prune its placements across EVERY hub
    // (the editor_delete_type cascade, inline: the whole fan-out is one
    // atomic event - the hub-addressed placement-delete sub-events cannot
    // cross hubs, so the cascade rebuilds each hub's placement list
    // itself) + decrement the higher type ids (palette indices shift).
    // The active tool reconciles (the deleted tool -> select, higher ->
    // decremented).
    hub_delete_decoration_type: struct {
        type_id: u32,
    },
    // The decoration type's tint (the swatch row) - granular, no prune
    // (the editor_set_decoration_color_index convention).
    hub_set_decoration_color_index: struct {
        type_id: u32,
        value: u32,
    },
    // The decoration type's untinted-render toggle (the
    // editor_set_decoration_keep_original_colors convention).
    hub_set_decoration_keep_original_colors: struct {
        type_id: u32,
        value: bool,
    },
    // A gradient key commit on the drilled hub's grid (the hub metadata
    // sidebar's rows; the level editor's player_set_editor_level_*
    // analogue - the null index = the auto-derivation revert).
    hub_set_gradient: struct {
        role: types.LevelGradientRole,
        gradient_index: ?u32,
    },
    // The WHOLE-DEF commit (a sprite-picker pick): the full visual
    // identity, FLATTENED to top level (the session-log reader doesn't
    // regroup nested non-u8 slices - the editor_set_decoration_def
    // convention). The handler prunes the type's placements whose
    // position the new footprint invalidates, across EVERY hub.
    hub_set_decoration_def: struct {
        type_id: u32,
        sprite: []const u8,
        footprint: []const Vector2,
        pixel_dims: Vector2,
        color_index: u32,
        keep_original_colors: bool = false,
        layers: []const DecorationLayer,
    },
    // Open the centered picker (the editor_open_picker convention; the
    // close rides the pick commit as a child - one undo step).
    hub_open_picker: struct {
        target: types.EditorPickerTarget,
    },
    hub_close_picker: void,

    // ── The spawn ──
    // Move the player-spawn marker ('!'). Singleton by construction - a
    // hub grid has no level_end, so the mission editor's marker-overlap
    // veto never applies.
    hub_set_player_start: struct {
        position: Vector2,
    },

    // ── Selection ──
    // The select tool's granular ops (one entry per event - the selection
    // model). Entries address the hub grid: tile, decoration placement,
    // player start (NPC/exit arms join at 4-4).
    hub_select: struct {
        entry: types.Selectable,
    },
    hub_deselect: struct {
        entry: types.Selectable,
    },
    hub_clear_selection: void,

    // ── The move chain ──
    // The selection-move worklist (the editor_commit_selection_move
    // mirror): backs the selection up as concrete things
    // (`EditorSelectionMoveEntry` - the shared entry type; its hub-relevant
    // arms are tile / player_start / decoration), then the clear phase's
    // deletes run before the first link processes. Each link plans ONE
    // entry against the live post-delete state (the placement planners are
    // the current rules) and pushes the next link - the chain exists so
    // each entry sees the fully-processed state. The final link clears the
    // selection (nothing is reselected).
    hub_commit_selection_move: struct {
        entries: []const types.EditorSelectionMoveEntry,
        next_index: u32,
    },
};

/// Player-input events - the ONLY events input handlers can push (via
/// `pushPlayerAction`). Each maps 1:1 to a user action (keybind/click).
/// The replay whitelist (`isPlayerAction`) is just `activeTag ==
/// .player_input_event` - the type IS the whitelist, so it can't drift from
/// the push side. `player_skip_level` is additionally dev-gated in
/// `isPlayerAction`. Handlers for these orchestrators push machinery events
/// (`end_level`, `start_mission`, `move_entity`, `use_skill`, `turn_end`,
/// ...) as children via `pushEvents` - those live in the machinery unions
/// (MetaEvent/LevelEvent/etc.) and are never seeded at an idle point.
/// See DESIGN → Determinism & Tiebreaking → Replay PLAYER-ACTION LEGALITY.
pub const PlayerInputEvent = union(enum) {
    // --- Meta: scope transitions + save + overlay dismiss ---
    start_new_game: void,
    // Open the editor. Null mission_path = create a FRESH empty mission
    // ("New Mission", one default-template level, empty palettes - the
    // New Mission buttons; the mission uuid is minted at SAVE time,
    // never held in state - see DESIGN → Level Editor → Mission
    // identity). A path = open that mission directory (the editor
    // browser's rows + the round-trip tests).
    open_editor: struct {
        mission_path: ?[]const u8,
    },
    // Open the campaign editor (see DESIGN → Campaigns & the Campaign
    // Editor → The editor-state split / The campaign editor surface).
    // Null campaign_dir = New Campaign (a fresh in-memory campaign: one
    // start hub at 0 0 with the single-'!'-tile default grid; files only
    // at save - the campaign uuid is minted then, never held in state).
    // A dir = open that campaign dir (the browser's Campaign tab rows):
    // the campaign's CONTENT dir, "campaigns/<id>" - the row's dir
    // verbatim (the mission-row full-path convention; resolving through
    // readFile's persistent-then-embedded bridge).
    // Legal from the main menu's editor browser, from the mission
    // editor (switching content), and from the campaign editor itself
    // (switching campaigns - the open_editor open-from-the-editor
    // precedent: the world_generation bump resets stale view state).
    open_campaign_editor: struct {
        campaign_dir: ?[]const u8,
    },
    // Drill into the hub editor (the hub inspector's Open Hub Editor
    // button): `hub` is the target hub's CampaignEditor handle. The
    // handler resolves it against the live authored graph (a crafted
    // dead handle no-ops), snapshots the camera clamp over the hub
    // grid, loads the spawn-preview template through the reconstruction
    // cache (the open_editor convention - the orchestrator is recorded,
    // so replay re-reads the same bytes), and transitions to the
    // .hub_editor screen (whose scope keeps campaign_editor alive -
    // DESIGN → The editor-state split).
    open_hub_editor: struct {
        hub: u32,
    },
    // Orchestrates a save: syncs PlayerData from the working entity (in a
    // hub/level) via build_data_from_player, then writes via write_save.
    save_game: struct {
        save_path: []const u8,
    },
    // Export Game's autosave half: a game in progress (not during an
    // editor run - throwaway run data) syncs PlayerData via
    // build_data_from_player, then writes the AUTOSAVE so mid-level
    // progress is in the exported zip (the zip + download themselves are
    // an input-path side effect, the reset-to-defaults class). See
    // game_zip.zig + DESIGN → File System & IO → Web storage model.
    export_game: void,
    // Dismiss the mission-complete overlay (the Continue button). Clears
    // GameState.last_completed_mission. On the undo timeline so undo re-shows
    // the overlay, redo dismisses it. See DESIGN → Architecture.
    dismiss_mission_complete: void,
    // Main-menu Continue button. Two branches by PlayerData state (handler):
    // populated → resume directly from in-memory data via
    // loadCampaignAndPushHub (the mid-session exit-to-menu case); empty →
    // load_save the autosave then resume (the fresh-launch case). See DESIGN
    // → File System & IO (autosave).
    player_continue: void,
    // Main-menu load-save browser: load the save at `save_path` (a row
    // click, or the picked file from the web import). Handler pushes the
    // meta `load_save` event - the normal load path, so replay re-reads the
    // file silently. The path references a file already resident in the
    // persistent dir (acquisition happened in idle input - see DESIGN →
    // Custom Missions for why that split matters).
    player_load_save: struct {
        save_path: []const u8,
    },
    // Level-tab click in the editor: switch the active level. The handler
    // pushes the EditorEvent; `active_level_index` lives on the Editor
    // (GameState), so tab switches ride the undo timeline.
    player_set_editor_level: struct {
        level_index: u32,
    },
    // Editor palette tool-cell click: make the clicked tool active. The
    // handler pushes `editor_set_tool`; the tool pointer lives on the
    // Editor (GameState), so tool switches ride the undo timeline and any
    // event whose effect depends on the active tool can read it from
    // reconstructable state.
    player_set_editor_tool: struct {
        tool: types.EditorToolId,
    },
    // Inspector toggle-button click (editor top-left, below options): flip
    // the inspector sidebar. The handler pushes `editor_toggle_inspector`;
    // the open flag lives on the Editor (GameState), so it rides the undo
    // timeline. See DESIGN → Architecture → Level Editor → Editor UI
    // layout (inspector).
    player_toggle_editor_inspector: void,
    // Settings-sidebar toggle-button click (editor top-right, at the
    // inspector toggle's height, flush to the right screen edge): flip the
    // metadata sidebar. The handler pushes `editor_toggle_metadata_sidebar`.
    player_toggle_editor_metadata_sidebar: void,
    // Surface-toggle orchestrator (the escape chain, panel keybinds, modal
    // Back/Settings buttons): push the meta `toggle_ui_surface`. The open
    // state rides GameState (`ui_surfaces`), so a toggle fired while idle
    // is its own undo step; fired mid-drain it rides the surrounding
    // subtree (the anytime-interjection pattern). See DESIGN → UI Framework
    // → UI state classification.
    player_toggle_ui_surface: struct {
        surface: types.UiSurfaceId,
    },
    // Right-click entity inspect (levels only): the RESOLVED intent -
    // non-null opens/retargets the entity-inspect panel, null closes it.
    // The handler pushes the meta `inspect_entity` verb.
    player_inspect_entity: struct {
        entity_index: ?u32,
    },
    // Editor picker open/close (the picker's own buttons, the rows that
    // open it, a no-change pick's close): thin - the handler pushes
    // `editor_open_picker` / `editor_close_picker`. The picker state
    // rides GameState (`Editor.picker`), so it rides the undo timeline.
    // See DESIGN → UI Framework → UI state classification.
    player_open_editor_picker: struct {
        target: types.EditorPickerTarget,
    },
    player_close_editor_picker: void,
    // Top-bar Test/Validate button clicks: start a single-level playtest
    // of the active level / a full-mission validation run of the SAVED
    // mission dir (the input layer saves first and passes the dir).
    // Thin orchestrators - the machinery handlers (start_playtest /
    // start_validation) own instantiation, PlayerData dormancy, and the
    // screen transition; end_level's editor guard owns the return path.
    // player_start_validation also serves as the validate-RESTART
    // re-entry (handler-pushed by end_level's guard): every attempt in
    // the linear stream begins with this seedable orchestrator, which is
    // what lets the validation replay slice start at the last one (see
    // DESIGN → Custom Missions & Online Services → Validation replay).
    player_start_playtest: void,
    player_start_validation: struct {
        /// The saved mission dir to run (borrowed from the push site;
        /// deep-copied when the event is recorded).
        mission_path: []const u8,
    },
    // Options-menu Revalidate Mission: re-certify the stored validation
    // replay against the CURRENT saved content. The checking-mode replay
    // (GameStateHistory.reconstructFromEventLogChecking) re-runs the
    // recorded events against the mission files as they are NOW; any
    // divergence or illegality invalidates. On success the handler
    // rewrites validation_replay.txt with the same events + the NEW
    // content hash (the original created stamp is kept - same run,
    // re-certified). The consumption site saves first (the Validate
    // contract - the check certifies the saved files). See DESIGN →
    // Custom Missions & Online Services → Validation replay.
    player_revalidate_mission: struct {
        /// The saved mission dir whose replay is re-certified (borrowed
        /// from the push site; deep-copied when the event is recorded).
        mission_path: []const u8,
    },
    // Player inspector Import-button click: copy the session's player data
    // (or, with none, the new-game default save) into the editor player
    // loadout. The handler pushes `editor_import_player` - the loadout
    // fields ride GameState, so the import is on the undo timeline.
    player_import_editor_player: void,
    // Player inspector Max-player Import-button click (the shipped
    // data/max_player.txt loadout): pushes `editor_import_max_player`.
    player_import_editor_max_player: void,
    // Palette group "+" click: append a new type to that group's palette
    // (Entities / Decorations / Items). Thin orchestrator - the handler for
    // the `editor_add_*_type` event builds the type from the shipped
    // defaults (data/editor_defaults.txt, read through the reconstruction
    // cache), makes it the active tool, and opens the inspector. No payload
    // - the group is named by the event variant.
    player_add_editor_entity_type: void,
    player_add_editor_decoration_type: void,
    player_add_editor_item_type: void,
    // Palette tool-cell delete-button click: delete that palette type and
    // every placement referencing it across all levels. Thin orchestrator
    // - the `editor_delete_type` handler owns the fan-out (per-placement
    // deletes + the type removal + id remap + active-tool reconciliation),
    // all on the undo timeline as one step.
    player_delete_editor_type: struct {
        type_kind: EditorTypeKind,
        type_id: u32,
    },
    // Add-level "+" click (top bar, right of the level tabs): append a new
    // level from the shipped template (data/default_level.txt) and switch
    // to it. Thin orchestrator - the `editor_add_level` handler reads the
    // template through the reconstruction cache (replay reproduces the
    // creation), appends it, makes it the active tab, and syncs
    // mission.level_count; one undo step reverts the whole creation.
    player_add_editor_level: void,
    // Level-tab × click: delete that level (gated on more than one - a
    // mission always keeps ≥1). Thin orchestrator - the
    // `editor_delete_level` handler removes it, shifts later levels down,
    // syncs mission.level_count, and adjusts the active tab. One undo step
    // restores the level.
    player_delete_editor_level: struct {
        level_index: u32,
    },
    // Settings-sidebar commits (mission + active-level metadata - see
    // DESIGN → Architecture → Level Editor → Editor UI layout (Settings
    // sidebar)). Thin orchestrators: the EditorEvents own the mutations.
    player_set_editor_mission_name: struct {
        name: []const u8,
    },
    // The campaign editor's name-field commits (the same convention: the
    // commit is a recorded player action pushing the campaign-editor
    // event). The hub arm carries the hub handle so a mid-edit selection
    // change can't retarget it (the level-name pattern).
    player_set_campaign_name: struct {
        name: []const u8,
    },
    player_set_campaign_hub_name: struct {
        hub: u32,
        name: []const u8,
    },
    player_set_editor_level_name: struct {
        level_index: u32,
        name: []const u8,
    },
    player_set_editor_level_color_wheel: struct {
        level_index: u32,
        color_wheel_index: u32,
    },
    // A gradient pick for the enemy/player row (or the row's Auto toggle
    // reverting to null). Picking while the role is on auto flips it to
    // manual in the same commit - one undo step per pick.
    player_set_editor_level_enemy_gradient: struct {
        level_index: u32,
        gradient_index: ?u32,
    },
    player_set_editor_level_player_gradient: struct {
        level_index: u32,
        gradient_index: ?u32,
    },
    // Select-tool click in the editor viewport: toggle the clicked thing's
    // group in the selection (see the selection-tool bullet in DESIGN →
    // Architecture → Level Editor → Active-tool model). The SHIFT+CLICK
    // path (the marquee gesture's unpromoted release). The handler
    // computes the granular editor_select / editor_deselect plan from
    // state (the group + its toggle direction); a click that selects
    // nothing (empty ground) never fires.
    player_toggle_editor_selection: struct {
        position: Vector2,
    },
    // Select-tool PLAIN click (no Shift): REPLACE the selection with the
    // clicked thing's group - clear everything, then select the group.
    // Clicking empty ground clears the selection (the clicky deselect-
    // all). A click that would change nothing (the selection already IS
    // the group) never fires. Fired from handleIdleInput's select arm and
    // the move-drag gesture's unpromoted release (a plain click on a
    // selected thing - the press was claimed by the gesture).
    player_replace_editor_selection: struct {
        position: Vector2,
    },
    // Select-tool shift+drag release in the editor viewport: ADD every
    // selectable thing inside the rectangle spanned by the two corner
    // tiles (order-independent, inclusive) - skipping entries already in
    // the selection (an add, never a remove; the plain click toggles). A
    // decoration is in the region when ANY of its footprint tiles is. The
    // handler computes the granular editor_select plan from state; an
    // empty region (or an all-already-selected one) never fires.
    player_select_editor_region: struct {
        start_position: Vector2,
        end_position: Vector2,
    },
    // ctrl+A: add EVERY selectable thing in the active level
    // (tiles, entity / item / decoration placements, the '!' / '=').
    // Tool-agnostic - when another tool is active the action also switches
    // to select (the selection ⇔ select-tool invariant; the switch shares
    // this action's idle point, so one undo restores the previous tool +
    // the empty selection). No
    // payload - the handler computes the granular editor_select plan from
    // state (the marquee's membership rule with no region bound); entries
    // already in the selection are skipped, so an all-selected level never
    // fires. All the adds share this action's idle point - one undo step.
    player_select_editor_all: void,
    // Select-tool Delete key: delete the current selection. No payload -
    // the handler reads `editor.selection` from reconstructable state (the
    // whole point of the selection living on the timeline) and fans out
    // into the per-entry delete events (`planEditorSelectionDeleteActions`).
    // The '!' / '=' entries and the tiles under them are never deleted -
    // everything else in the selection goes. All the deletes share this
    // action's idle point, so one undo step reverts the whole deletion.
    player_delete_editor_selection: void,
    // Select-tool ctrl+D: clear the whole selection. No payload - the
    // handler pushes the single `editor_clear_selection`. The input layer
    // gates on a nonempty selection (no dead undo step on an empty one).
    player_clear_editor_selection: void,
    // Select-tool move drag release: move the whole selection by `delta`
    // (release tile − press tile). No payload beyond the delta - the
    // handler is thin over the shared planner
    // (planning.planEditorSelectionMoveActions), which reads
    // `editor.selection` from reconstructable state, backs it up as
    // concrete things (`EditorSelectionMoveEntry`), and pushes the delete
    // plan + the chained `editor_commit_selection_move` worklist. A move
    // that would land a MARKER on the other marker is VETOED whole (empty
    // plan; the input gate never fires it - see
    // planning.editorSelectionMoveVetoed): '!' and '=' take one cell each
    // in the layout format, so `player_start == level_end` has no file
    // representation. The delete phase does NOT sweep occupants of selected
    // tiles (unlike the Delete key): an unselected occupant pins its tile
    // - the tile stays underneath it and the moved tile lands at the
    // target instead. A selected MARKER takes its old ground with it (the
    // tile it stood on is erased - nothing hosts it there anymore; the
    // Delete key keeps marker tiles because the marker isn't moving
    // there). Things whose target overlaps the '!' / '=' plan
    // empty and are deleted fully. After the move the selection is
    // CLEARED (nothing reselected). One undo step reverts the whole move.
    player_move_editor_selection: struct {
        delta: Vector2,
    },
    // Tile-paint click in the editor viewport (tile tool active): one click
    // = one tile. The handler computes the effect from state - no-op when a
    // tile is already there; every decoration whose footprint covers the
    // position is deleted first (replace, not block - see DESIGN →
    // Decorations & Footprint → Placement invariant). Erase is the
    // tool-independent right-click (`player_delete_editor_at`);
    // drag-painting is `handleEditorTileDrag` (press-drag paints per
    // tile).
    player_paint_editor_tile: struct {
        position: Vector2,
    },
    // --- Campaign editor viewport verbs (the campaign editor's idle +
    // click arms; the handlers push the CampaignEditorEvent children) ---
    // Switch the campaign editor's active tool (the palette cell click).
    player_set_campaign_tool: struct {
        tool: types.CampaignEditorToolId,
    },
    // Select a campaign hub (a hub-icon click; null deselects - the
    // select tool's empty-canvas click). Placing selects too, but that
    // rides the place event's handler (one event, one undo step).
    player_select_campaign_hub: struct {
        hub: ?u32,
    },
    // Place a hub at a map position (the hub tool's empty-canvas click,
    // resolved by the idle arm from the click's screen position against
    // the framing + pan).
    player_place_campaign_hub: struct {
        position: Vector2,
    },
    // Move a hub (the select tool's drag commit - one event on release,
    // the preview is transient drag state off the timeline).
    player_move_campaign_hub: struct {
        hub: u32,
        position: Vector2,
    },
    // Set the start hub (the inspector toggle's radio write; the
    // untoggle-the-current-start case is vetoed at the click site with a
    // message, never pushed).
    player_set_campaign_start_hub: struct {
        hub: u32,
    },
    // Delete a hub (the right-click; orphaning + ghost freezing ride the
    // handler). The start hub is vetoed at the click site, never pushed.
    player_delete_campaign_hub: struct {
        hub: u32,
    },
    // Open the campaign editor's centered picker (the background button).
    // The list acquisition (the campaign dir's PNG scan) happens at the
    // click site - session-side, replay never opens a picker.
    player_open_campaign_picker: struct {
        picker: types.CampaignEditorPicker,
    },
    // Close the centered picker (the panel's Back button).
    player_close_campaign_picker: void,
    // The background picker's pick (the stem; empty = None/clear). The
    // handler pushes set_background + close_picker as children - one undo
    // step for pick + close (the editor-picker convention).
    player_set_campaign_background: struct {
        stem: []const u8,
    },
    // Toggle the campaign editor's inspector / metadata sidebars (the
    // top corner strips - the player_toggle_editor_inspector
    // convention: the flags ride the undo timeline).
    player_toggle_campaign_inspector: void,
    player_toggle_campaign_metadata_sidebar: void,
    // Select a mission (an edge click under the select tool).
    player_select_campaign_mission: struct {
        mission: u32,
    },
    // Place a mission + edge in one gesture (the mission tool's draw).
    player_place_campaign_mission: struct {
        start: u32,
        destination: u32,
    },
    // The mission name-field commit (the handle rides the payload - the
    // level-name retargeting protection).
    player_set_campaign_mission_name: struct {
        mission: u32,
        name: []const u8,
    },
    // The mission direction-field commit (null = clear to auto-spread).
    player_set_campaign_mission_direction: struct {
        mission: u32,
        direction: ?u32,
    },
    // The re-attach pick-mode's hub click (the end + target hub).
    player_reattach_campaign_mission: struct {
        mission: u32,
        end: types.CampaignMissionEnd,
        hub: u32,
    },
    // Delete a mission (the edge right-click).
    player_delete_campaign_mission: struct {
        mission: u32,
    },
    // An import landed (the copy-at-pick happened at the input layer;
    // the event carries the copied identity).
    player_import_campaign_mission: struct {
        uuid: []const u8,
        dir: []const u8,
        name: []const u8,
    },
    // Enemy-tool click in the editor viewport: place the palette entity
    // type at the clicked tile. The handler computes the full effect from
    // state (see the placement-tools bullet in DESIGN → Architecture →
    // Level Editor → Active-tool model): occupant replacement - covering
    // decorations are deleted, a missing tile is placed, a co-located
    // ground item is deleted, an existing enemy is RETYPED in place (not
    // delete + re-place), and the player start / level end are never
    // overwritten (no-op). One thing per placed tile is an invariant -
    // `editor_place_entity` panics on an occupied tile. `type_id` rides in
    // the payload (handlers can't read UiState - replay doesn't
    // reconstruct it). Decoration/item tools land as their own slices.
    player_place_editor_entity: struct {
        type_id: u32,
        position: Vector2,
    },
    // Decoration-tool click: place the palette decoration type with its
    // ANCHOR tile (bottom-most-then-left-most footprint tile) at the
    // clicked position. The handler computes occupant replacement (see
    // DESIGN → Level Editor → Active-tool model, placement tools): the
    // '!' / '=' under ANY footprint tile → no-op; tiles under footprint
    // tiles are erased along with anything standing on them (entities /
    // ground items); other decorations whose footprints overlap are
    // deleted; then the decoration is placed. `type_id` rides in the
    // payload (handlers can't read UiState - replay doesn't reconstruct
    // it).
    player_place_editor_decoration: struct {
        type_id: u32,
        position: Vector2,
    },
    // Ground-item-tool click: place the palette item type at the clicked
    // tile. Same occupant-replacement shape as the entity tool (see DESIGN →
    // Architecture → Level Editor → Active-tool model, placement tools):
    // missing tile → placed; covering decoration → deleted; '!' / '=' →
    // no-op; enemy on the tile → deleted; existing ground item → RETYPED
    // in place. `type_id` rides in the payload (handlers can't read
    // UiState - replay doesn't reconstruct it).
    player_place_editor_item: struct {
        type_id: u32,
        position: Vector2,
    },
    // Editor right-click: the TOOL-INDEPENDENT delete. One clean click
    // deletes ONE thing at the pressed tile - priority: enemy / ground
    // item occupant, then covering decoration, then the bare tile; the
    // '!' / '=' and empty ground are no-ops (all computed from state in
    // the handler). The gesture (click-vs-pan disambiguation) lives in
    // `handleRightClickEditorDelete`.
    player_delete_editor_at: struct {
        position: Vector2,
    },

    // --- Hub editor viewport verbs (the slice-4 drill-in; the handlers
    // re-plan from live state and push the HubEditorEvent children - the
    // mission editor's orchestrator convention, one mirror per verb) ---
    // Switch the hub editor's active tool (the palette cell click / the
    // Tab cycle).
    player_set_hub_tool: struct {
        tool: types.HubEditorToolId,
    },
    // The inspector toggle (the player_toggle_campaign_inspector mirror).
    player_toggle_hub_inspector: void,
    // The metadata sidebar toggle (the inspector field's own convention).
    player_toggle_hub_metadata_sidebar: void,
    // A gradient row commit from the hub editor's metadata sidebar (the
    // player_set_editor_level_* mirror over the drilled hub's grid; the
    // null index = the auto-derivation revert).
    player_set_hub_gradient: struct {
        role: types.LevelGradientRole,
        gradient_index: ?u32,
    },
    // Decoration-tool click over the hub grid (the
    // player_place_editor_decoration contract over the campaign palette).
    player_place_hub_decoration: struct {
        type_id: u32,
        position: Vector2,
    },
    // The Decorations group's "+" cell (the player_add_editor_palette_type
    // convention): the handler pushes hub_add_decoration_type.
    player_add_hub_decoration_type: void,
    // A palette cell's delete button (the player_delete_editor_type
    // convention): the handler pushes hub_delete_decoration_type.
    player_delete_hub_decoration_type: struct {
        type_id: u32,
    },
    // A sprite-picker pick's whole-def commit (the
    // player_set_editor_decoration_def mirror; the payload is
    // deep-copied at the push site).
    player_set_hub_decoration_def: struct {
        type_id: u32,
        sprite: []const u8,
        footprint: []const Vector2,
        pixel_dims: Vector2,
        color_index: u32,
        keep_original_colors: bool = false,
        layers: []const DecorationLayer,
    },
    player_open_hub_picker: struct {
        target: types.EditorPickerTarget,
    },
    player_close_hub_picker: void,
    // Tile-paint click over the hub grid (the tile tool): one click = one
    // tile, covering decorations replaced (the player_paint_editor_tile
    // contract).
    player_paint_hub_tile: struct {
        position: Vector2,
    },
    // NPC-tool click over the hub grid (the player_place_editor_entity
    // contract over the hub kinds).
    player_place_hub_npc: struct {
        npc_type: types.NpcType,
        position: Vector2,
    },
    // Mission-tool click over the hub grid: upsert that mission's exit
    // marker at the position (the move-or-create rule).
    player_place_hub_exit_marker: struct {
        mission: u32,
        position: Vector2,
    },
    // Select-tool plain click over the hub grid: REPLACE the selection
    // with the clicked thing's group (the player_replace_editor_selection
    // contract).
    player_replace_hub_selection: struct {
        position: Vector2,
    },
    // Select-tool shift+click: TOGGLE the clicked thing's group (the
    // player_toggle_editor_selection contract).
    player_toggle_hub_selection: struct {
        position: Vector2,
    },
    // Select-tool shift+drag release: ADD everything inside the rectangle
    // (the player_select_editor_region contract).
    player_select_hub_region: struct {
        start_position: Vector2,
        end_position: Vector2,
    },
    // ctrl+A over the hub grid: add every selectable thing (the
    // player_select_editor_all contract).
    player_select_hub_all: void,
    // Select-tool Delete key: delete the hub selection (the
    // player_delete_editor_selection contract).
    player_delete_hub_selection: void,
    // Select-tool ctrl+D: clear the hub selection.
    player_clear_hub_selection: void,
    // Select-tool move-drag release: move the hub selection by `delta`
    // (the player_move_editor_selection contract - the chained
    // hub_commit_selection_move worklist; a hub grid has no level_end, so
    // the marker-overlap veto never fires).
    player_move_hub_selection: struct {
        delta: Vector2,
    },
    // The tool-independent right-click delete over the hub grid (the
    // player_delete_editor_at contract).
    player_delete_hub_at: struct {
        position: Vector2,
    },

    // --- Editor: inspector field edits ---
    // One thin wrapper per field verb (the orchestrator convention; the
    // EditorEvent owns the mutation - see DESIGN → Architecture → Level
    // Editor → Editor UI layout → "Inspector fields"). The text-input
    // widget commits on Enter / OK / M2 click-away (DESIGN → UI Framework
    // → Text input widget); the input layer gates on would-change (an
    // unchanged value records nothing - no dead undo step).
    player_set_editor_entity_name: struct {
        target: EntityEditTarget,
        value: []const u8,
    },
    player_set_editor_entity_sprite: struct {
        target: EntityEditTarget,
        value: []const u8,
        keep_original_colors: bool = false,
    },
    player_set_editor_entity_color_index: struct {
        target: EntityEditTarget,
        value: u32,
    },
    player_set_editor_entity_displays_weapons: struct {
        target: EntityEditTarget,
        value: bool,
    },
    player_set_editor_entity_keep_original_colors: struct {
        target: EntityEditTarget,
        value: bool,
    },
    player_set_editor_entity_max_health: struct {
        target: EntityEditTarget,
        value: u32,
    },
    player_set_editor_entity_defense: struct {
        target: EntityEditTarget,
        value: u32,
    },
    player_set_editor_entity_speed: struct {
        target: EntityEditTarget,
        value: u32,
    },
    player_set_editor_entity_aggro_range: struct {
        target: EntityEditTarget,
        value: u32,
    },
    // Team: enemy-authorable only (see editor_set_entity_team) - the
    // player_def target is rejected at the replay seam.
    player_set_editor_entity_team: struct {
        target: EntityEditTarget,
        value: u32,
    },
    // Equipped-slot commit (weapons + gear): ONE slot-parameterized
    // event carrying the FLATTENED item (see the editor_set_entity_gear
    // comment for why flat + the shared payload type) - create / retype /
    // field-edit / clear all push it, so one event covers each (one undo
    // step either way).
    player_set_editor_entity_gear: EntityGearPayload,
    // Inspector utility-skill commit (the picker's pick, or its None
    // option). Only UTILITY skills are legal on the bar - the picker
    // never offers weapon skills and validation rejects them (see
    // src/utility_skills.zig, the single source).
    player_set_editor_entity_utility_skill: struct {
        target: EntityEditTarget,
        slot_index: u32,
        value: ?SkillId,
    },
    // Inspector decoration commits (the decoration tool's fields - see the
    // editor_set_decoration_* block for the whole-def shape). The def
    // commit carries the resolved definition (prefab adopt or custom stem
    // with derived footprint); the color commit is the swatch pick.
    player_set_editor_decoration_def: struct {
        type_id: u32,
        sprite: []const u8,
        footprint: []const Vector2,
        pixel_dims: Vector2,
        color_index: u32,
        keep_original_colors: bool = false,
        layers: []const DecorationLayer,
    },
    player_set_editor_decoration_color_index: struct {
        type_id: u32,
        value: u32,
    },
    player_set_editor_decoration_keep_original_colors: struct {
        type_id: u32,
        value: bool,
    },
    // Inspector item-type commits (the Items palette group's content -
    // see the editor_set_item_def block for the flattened shape + why).
    // The def commit covers type picks (reset-to-default semantics) and
    // stat edits; the name commit is its own event (a top-level string).
    player_set_editor_item_def: struct {
        type_id: u32,
        item_kind: ItemKind,
        weapon_type: WeaponType = .sword,
        name: []const u8 = &.{},
        weapon_damage: u32 = 0,
        spell_damage: u32 = 0,
        health_bonus: u32 = 0,
        defense_bonus: u32 = 0,
        damage_bonus: u32 = 0,
        pickup_radius_bonus: u32 = 0,
        speed_bonus: u32 = 0,
    },
    player_set_editor_item_name: struct {
        type_id: u32,
        value: []const u8,
    },
    // Inspector inventory-slot commits (the player loadout's Inventory
    // section - see the editor_add_inventory_item block for the shape +
    // why). The player loadout is the only inventory owner, so these
    // carry just the slot index.
    player_add_editor_inventory_item: struct {
        index: u32,
    },
    player_delete_editor_inventory_item: struct {
        index: u32,
    },
    player_set_editor_inventory_item_def: struct {
        index: u32,
        item_kind: ItemKind,
        weapon_type: WeaponType = .sword,
        name: []const u8 = &.{},
        weapon_damage: u32 = 0,
        spell_damage: u32 = 0,
        health_bonus: u32 = 0,
        defense_bonus: u32 = 0,
        damage_bonus: u32 = 0,
        pickup_radius_bonus: u32 = 0,
        speed_bonus: u32 = 0,
    },
    player_set_editor_inventory_item_name: struct {
        index: u32,
        value: []const u8,
    },
    // The footprint editor's confirm (the centered tile-grid picker -
    // see DESIGN → Level Editor → Editor UI layout, the footprint
    // editor): the resolved footprint in sprite-grid coords, row-major.
    // The EditorEvent owns the mutation + the placement prune.
    player_set_editor_decoration_footprint: struct {
        type_id: u32,
        value: []const Vector2,
    },
    // Inspector layer commits (the Layers sections - enemy types +
    // decoration types; the player loadout has NO layers). The EditorEvents
    // own the mutations; set carries the WHOLE layer value (a sprite re-pick
    // or a color swap - one event, one undo step). The layer's fields are
    // FLATTENED like the editor events' (spaces-safe sprite strings).
    player_add_editor_entity_layer: struct {
        target: EntityEditTarget,
        sprite: []const u8,
        color_index: u32,
    },
    player_remove_editor_entity_layer: struct {
        target: EntityEditTarget,
        layer_index: u32,
    },
    player_set_editor_entity_layer: struct {
        target: EntityEditTarget,
        layer_index: u32,
        sprite: []const u8,
        color_index: u32,
    },
    player_add_editor_decoration_layer: struct {
        type_id: u32,
        sprite: []const u8,
        color_index: u32,
        behind: bool = false,
        pixel_dims: Vector2,
    },
    player_remove_editor_decoration_layer: struct {
        type_id: u32,
        layer_index: u32,
    },
    player_set_editor_decoration_layer: struct {
        type_id: u32,
        layer_index: u32,
        sprite: []const u8,
        color_index: u32,
        behind: bool = false,
        pixel_dims: Vector2,
    },

    // --- Meta: exit/skip orchestrators ---
    // Dev-only skip (ctrl+Enter). Gated to dev builds in `isPlayerAction`;
    // the handler pushes end_level with the default continuation.
    player_skip_level: void,
    // Options-menu "restart mission" button. Handler pushes
    // end_level{.restart_mission}.
    player_restart_mission: void,
    // Options-menu "exit mission" button. Handler pushes
    // end_level{.exit_mission}.
    player_exit_mission: void,
    // World-map travel (a hub click on the map): jump to a DISCOVERED
    // hub (backtrack-only - see DESIGN → Campaigns & the Campaign
    // Editor → Discovery + travel). From a hub: start_hub + end_hub
    // (the exit-tile shape); mid-level: end_level{.exit_mission} with
    // the return suppressed (the abandon ride - pickups kept, no
    // clone). The hub uuid rides the event; the handler resolves the
    // dir through the loaded campaign's table (state, never the
    // filesystem - replay-safe). The campaign identity (dir + uuid,
    // click-time resolved from the VIEWED graph) names the campaign
    // being acted on: null = the active campaign; non-null = the
    // cross-campaign branch (install_campaign rides the cascade - see
    // DESIGN → Campaigns & the Campaign Editor → Campaign switching).
    player_travel_to_hub: struct {
        hub_uuid: []const u8,
        campaign_uuid: ?[]const u8 = null,
        campaign_dir: ?[]const u8 = null,
    },
    // World-map mission entry (an edge click on the map): equivalent to
    // standing on the exit in the edge's start hub. The payload is the
    // click-time RESOLVED edge (the mission-browser-row precedent):
    // the mission path + the campaign edge's to-end destination (null =
    // dangling, the entering-hub fallback) + the edge's start hub (the
    // mission's enter hub - current_hub on the way in, DESIGN → Campaigns
    // & the Campaign Editor → Discovery + travel). The campaign identity
    // names the campaign being acted on (null = active; non-null = the
    // cross-campaign branch - install_campaign rides the cascade).
    player_start_mission_from_map: struct {
        mission_path: []const u8,
        end_hub_id: ?[]const u8,
        start_hub_id: []const u8,
        campaign_uuid: ?[]const u8 = null,
        campaign_dir: ?[]const u8 = null,
    },
    // Options-menu "exit to menu" button. Handler branches on screen:
    // level → end_level{.exit_to_menu}; hub → end_hub + open_main_menu.
    player_exit_to_menu: void,
    // Mission-complete overlay "Replay Mission" button. Handler reads
    // current_state.last_completed_mission for the path, pushes start_mission
    // + end_hub (LIFO: end_hub syncs the hub player first).
    player_replay_mission: void,
    // Mission-complete overlay "Overwrite Clone" button (shown only when
    // `MissionCompleteInfo.overwrite_offered` is set - a clone exists AND the
    // just-completed run was not strictly faster). Handler reads
    // last_completed_mission and pushes save_clone_info with the run's data,
    // replacing the existing clone. See DESIGN → Clones (clone system).
    player_overwrite_clone: void,

    // --- Player: swap weapons ---
    swap_hands: void,

    // --- Hub: movement + NPC interaction ---
    move_player: struct {
        destination: Vector2,
    },
    interact_with_npc: struct {
        npc_index: u32,
    },

    // --- Level: player-action orchestrators ---
    // Each player input pushes exactly ONE of these as the top-level event;
    // the handler composes the verb events (player_turn_attack,
    // clear_highlights, move_entity, use_skill, turn_end, ...). One recorded
    // event per player action so undo granularity matches a single click/key.
    player_move_action: struct {
        destination: Vector2,
        // Carries the player's click-time intent (ctrl held) through to the
        // handler so it can forward it to player_turn_attack's
        // force_attack_step (ctrl overrides auto_skip_attack_step_out_of_combat).
        force_attack_step: bool = false,
    },
    player_skip_move: struct {
        force_attack_step: bool = false,
    },
    // Pressing a skill slot during the player_move phase: skip the move step
    // and act in the attack step instead. The payload is the RESOLVED intent
    // (prepare vs. use-with-target) - targeting resolution depends on the
    // transient tile_cursor (SessionState, off GameState), so it must happen
    // in the input path, not the handler (replay doesn't re-resolve input).
    // `prepare = true` → begin targeting; `prepare = false` → use now (target
    // is non-null only for auto-targeted / no-targeting skills). The handler
    // forces the attack step on so auto_skip_attack_step_out_of_combat can't
    // end the turn before the skill fires.
    player_skip_move_to_skill: struct {
        skill_id: SkillId,
        target: ?Vector2 = null,
        prepare: bool,
    },
    player_cancel_skill: void,
    player_skip_attack: void,
    player_use_skill: struct {
        skill_id: SkillId,
        target: ?Vector2,
    },
    // Prepare a skill for targeting (from the attack phase). Also handler-
    // pushed as a child of player_skip_move_to_skill - dual-nature, but that's
    // fine: the type marks it as player-pushable (passes the whitelist);
    // the handler-pushed form runs mid-drain and is verified by
    // verifyReplayMatch, never seeded at an idle point.
    player_prepare_skill: struct {
        caster_index: u32,
        skill_id: SkillId,
    },

    // --- Inventory/gear/skill: click + drag orchestrators ---
    // Player input ONLY pushes PlayerInputEvents; the machinery events
    // (equip_item, unequip_item, learn_skill, salvage_item,
    // equip_utility_skill, swap_utility_skills, unequip_utility_skill) are
    // always handler-pushed children of these. So the replay whitelist
    // (isPlayerAction = "is a PlayerInputEvent") can't be bypassed by the
    // input path. See DESIGN → Determinism & Tiebreaking → Replay
    // PLAYER-ACTION LEGALITY (orchestrator convention).
    //
    // Click "activate" an inventory item (double-click / ctrl / alt). The
    // handler resolves the item type: weapon → equip_item (main or off per
    // off_hand); other gear → equip_item (its own slot); skill tome →
    // learn_skill if not yet learned, else salvage_item. The learn-vs-
    // salvage decision is made from live player_data.learned_skills, so it
    // is deterministic across live/replay.
    player_use_inventory_item: struct {
        inventory_slot_index: u32,
        off_hand: bool = false,
    },
    // Click "salvage" an inventory item (shift+left). Handler pushes
    // salvage_item.
    player_salvage_inventory_item: struct {
        inventory_slot_index: u32,
    },
    // Shift-drag a region in the inventory panel. The two slot indices are
    // opposite corners (order-independent); the handler computes the
    // bounding box and pushes one salvage_item per occupied slot inside it.
    // One player action → one undo/idle point (all children drain before the
    // next idle point).
    player_salvage_inventory_region: struct {
        start_slot: u32,
        end_slot: u32,
    },
    // Drag inventory → gear slot. Handler pushes equip_item.
    player_equip_to_gear: struct {
        inventory_slot_index: u32,
        gear_slot: GearSlot,
    },
    // Drag gear → inventory slot. Handler pushes unequip_item.
    player_unequip_from_gear: struct {
        gear_slot: GearSlot,
        inventory_slot_index: u32,
    },
    // Drag learned skill → utility bar slot. Handler pushes
    // equip_utility_skill.
    player_assign_utility_skill: struct {
        skill_id: SkillId,
        slot_index: u32,
    },
    // Drag utility bar slot → utility bar slot. Handler pushes
    // swap_utility_skills.
    player_swap_utility_skills: struct {
        slot_a_index: u32,
        slot_b_index: u32,
    },
    // Drag utility bar slot → skills menu. Handler pushes
    // unequip_utility_skill.
    player_clear_utility_skill: struct {
        slot_index: u32,
    },
    // Drag inventory → inventory slot. Handler pushes swap_inventory_items
    // (covers move-to-empty + swap-with-occupied).
    player_swap_inventory_items: struct {
        slot_a_index: u32,
        slot_b_index: u32,
    },
};

pub const LevelEvent = union(enum) {
    // scope: level
    // turn logic, movement, skill usage
    turn_start: struct {
        entity_index: u32,
    },
    turn_end: struct {
        entity_index: u32,
    },
    player_turn_move: void,
    // The `force_attack_step` flag carries the player's click-time intent
    // (ctrl held) through to the handler so auto_skip_attack_step_out_of_combat
    // can be overridden. Set by the orchestrators that push this event.
    player_turn_attack: struct {
        force_attack_step: bool = false,
    },
    enemy_turn_move: struct {
        entity_index: u32,
    },
    enemy_turn_attack: struct {
        entity_index: u32,
    },

    highlight_tiles: struct {
        tile_positions: []const Vector2,
    },
    clear_highlights: void,
    clear_prepared_skill: void,

    move_entity: struct {
        entity_index: u32,
        destination: Vector2,
        // True when this move was caused by knockback/retreat rather than a
        // voluntary step. Lets the combat-log projection label forced moves
        // distinctly (and suppress them from the coarse "moved" tier) without
        // needing parent-context tracking.
        is_forced: bool = false,
    },

    use_skill: struct {
        caster_index: u32,
        skill_id: SkillId,
        target: ?Vector2,
    },

    // --- player-action orchestrators ---
    // These moved to `PlayerInputEvent` (player_move_action, player_skip_move,
    // player_skip_move_to_skill, player_cancel_skill, player_skip_attack,
    // player_use_skill, player_prepare_skill). The remaining LevelEvent
    // variants are machinery (turn_start, turn_end, player_turn_move,
    // player_turn_attack, enemy_turn_*, move_entity, use_skill,
    // highlight_tiles, clear_highlights, clear_prepared_skill).
};

pub const SubLevelEvent = union(enum) {
    // scope: level
    // individual in-level effects - pickup, aggro, attack, other skill effects
    pickup_around: struct {
        entity_index: u32,
    },
    /// Scan every inactive entity; for each, if any opposing entity is
    /// within ITS OWN `aggro_range`, activate it (+ aggro indicator anim).
    /// Self-centric - one event covers the whole level. Pushed at level
    /// start and after every `move_entity`. See DESIGN → Architecture.
    aggro_check: struct {},
    /// Win-condition check: if the player is on `level_end` and no active
    /// enemies remain, push `end_level`. Decoupled from `aggro_check` so it
    /// can also fire after `death` (killing the last enemy while standing on
    /// the exit ends the level without an extra move). Pushed AFTER
    /// `aggro_check` on the stack (LIFO → runs after) so newly-aggroed
    /// enemies are counted. See DESIGN → Architecture.
    check_level_end: struct {},
    attack: struct {
        attacker_index: u32,
        defender_index: u32,
        outgoing_damage: u32,
        triggers_effects: bool = true,
        // Lifesteal hook (e.g. Vampiric Strike): after the damage pipeline
        // resolves the applied damage, the handler emits a `heal` for the
        // attacker of that amount.
        heals_attacker: bool = false,
    },
    stun: struct {
        attacker_index: u32,
        defender_index: u32,
        stun_duration: u32,
    },
    knockback: struct {
        attacker_index: u32,
        defender_index: u32,
        distance: u32,
        knockback_damage: u32,
    },
    retreat: struct {
        entity_index: u32,
        target_position: Vector2,
        distance: u32,
    },
    // Collision damage from a knockback that ran into an obstacle (tile edge
    // or another entity). Mirrors `attack`: carries the raw outgoing damage
    // (the knockback's knockback_damage); the handler applies only the
    // defender's incoming modifiers (no attacker outgoing - collision isn't a
    // weapon hit), fires the collision + damage effect callbacks, and pushes
    // death if killed. Exists as its own event so the combat-log projection
    // sees collisions as first-class occurrences (the knockback handler used
    // to do this inline, invisible to the stream).
    collision: struct {
        attacker_index: u32,
        defender_index: u32,
        damage: u32,
    },
    // Applied damage from a resolved `attack` or `collision`. The pusher
    // arm owns the RESOLUTION differences (attack runs the damage-intercept
    // stage + defense; collision applies defense only - no intercepts, the
    // deliberate Reflect counterplay) and pushes the resolved post-defense
    // amount here; this arm owns the shared apply pipeline (health, mission
    // stats, hit flash, damage number, damage callbacks, death, lifesteal).
    // Splitting apply from resolve puts an event boundary between a hit's
    // resolution and its damage landing, so pacing waits can be inserted
    // between them (see TODO → Effect pacing). Combat-log tier `.none`: the
    // attack/collision entries already represent the hit.
    damage: struct {
        attacker_index: u32,
        defender_index: u32,
        // Resolved post-defense amount (intercepts + defense already applied
        // by the pusher arm).
        amount: u32,
        // Mirrors `attack.triggers_effects` at the push site: gates the
        // damage-stage effect callbacks (a reflected attack does not
        // re-trigger). Collisions pass the default (true) - their damage
        // callbacks were ungated.
        triggers_effects: bool = true,
        heals_attacker: bool = false,
    },
    // --- generic scalar-field mutation primitives (composed by skills) ---
    // Heal an entity, clamped to max_health.
    heal: struct {
        entity_index: u32,
        amount: u32,
    },
    // Adjust momentum by a signed delta, clamped at 0.
    change_momentum: struct {
        entity_index: u32,
        delta: i32,
    },
    // Adjust one skill's cooldown by a signed delta, clamped at 0. Focus
    // resets equipped weapon skills by emitting one per skill.
    change_cooldown: struct {
        entity_index: u32,
        skill_id: SkillId,
        delta: i32,
    },
    // Atomically exchange two entities' positions (Swap). Not a pair of
    // move_entity (they can't pass through each other).
    swap_positions: struct {
        entity_a_index: u32,
        entity_b_index: u32,
    },
    // Activate all opposing entities within an explicit radius (Howl).
    // Distinct from aggro_check, which uses each entity's own aggro_range.
    // aggro_in_radius uses an explicit radius and activates ALL entities
    // (no team filter - Howl rallies same-team entities).
    aggro_in_radius: struct {
        entity_index: u32,
        radius: u32,
    },
    // Focus: reset the entity's equipped weapon-skill (slots 1-3) cooldowns.
    // Orchestrator - the handler resolves the weapon skills (needs
    // weapon_type_definitions from GameStateHistory, unreachable from a skill)
    // and emits a change_cooldown per skill.
    reset_weapon_cooldowns: struct {
        entity_index: u32,
    },
    // Adrenaline Surge: reset the DEFENDER's on-bar cooldowns (all skills of
    // both equipped weapons - the swap-available thirds included - plus the
    // equipped utility skills; Entity.onBarSkillIds is the shared
    // enumeration) and the attacker strikes the defender once per cooldown
    // reset this way. Machinery for the same reason as
    // reset_weapon_cooldowns (the enumeration needs the definitions); the
    // skill's aiOptions - which does receive them - computes the same
    // count for its rating. The handler resets FIRST, then attacks, so the
    // resets land even when the attacks kill.
    adrenaline_surge: struct {
        attacker_index: u32,
        defender_index: u32,
    },
    // Items actually picked up from a ground stack. `pickup_around` is a pure
    // CHECK: it scans ground items in the entity's radius and, for each in-range
    // stack (one per position), pushes this event with just the stack's
    // position. The handler looks up the stack at that position and transfers
    // items into the inventory until full or the stack is empty. Carrying only
    // the position (not the items) keeps this event simple-fielded - the
    // session-log serializer never has to handle the Item union - while still
    // giving the combat log a loggable "picked up at (x,y)" occurrence. An
    // empty-tile move pushes no pickup_items, so the log stays clean.
    pickup_items: struct {
        entity_index: u32,
        position: Vector2,
    },
    create_effect: struct {
        caster_index: u32,
        receiver_index: u32,
        effect_id: EffectId,
        duration: u32,
    },
    end_effect: struct {
        entity_index: u32,
        effect_id: EffectId,
    },
    death: struct {
        entity_index: u32,
    },
};

pub const ReplayViewerEvent = union(enum) {
    // scope: replay viewer
};

pub const Event = union(enum) {
    meta_event: MetaEvent,
    super_event: SuperEvent,
    editor_event: EditorEvent,
    campaign_editor_event: CampaignEditorEvent,
    hub_editor_event: HubEditorEvent,
    player_input_event: PlayerInputEvent,
    player_event: PlayerEvent,
    level_event: LevelEvent,
    sub_level_event: SubLevelEvent,
    replay_viewer_event: ReplayViewerEvent,
};
