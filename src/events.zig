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
const Item = types.Item;
const Materials = types.Materials;
const EffectId = types.EffectId;
const Weapon = types.Weapon;
const Amulet = types.Amulet;
const Coat = types.Coat;
const Gloves = types.Gloves;
const Pants = types.Pants;
const Boots = types.Boots;
const EntityLayer = types.EntityLayer;
const DecorationLayer = types.DecorationLayer;
const CustomColorTheme = types.CustomColorTheme;
const EntityEditTarget = types.EntityEditTarget;
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
        start_hub_id: ?[]const u8,
        end_hub_id: ?[]const u8,
    },
    end_mission: struct {
        hub_id: ?[]const u8,
        // Non-null when the mission was completed (last level done) — carries
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
    },
    start_hub: struct {
        hub_id: []const u8,
        sets_checkpoint: bool = true,
        // Non-null when this hub entry follows a mission completion — sets
        // GameState.last_completed_mission so the overlay renders. Null on
        // a normal hub entry (clears any stale value). See DESIGN →
        // Architecture.
        completed_mission: ?MissionCompleteInfo = null,
    },
    end_hub: void,
    // Editor framing (see DESIGN → Architecture → Level Editor). open_editor
    // reads a mission from disk into an Editor session; start_playtest /
    // end_playtest bracket a single-level playtest; start_validation /
    // end_validation bracket a forced full-mission playthrough. The gameplay
    // events stay pristine — end_level's guard defers to these.
    close_editor: void,
    start_playtest: struct {
        level_index: u32, // 0-based into editor.levels
    },
    end_playtest: void,
    start_validation: void,
    end_validation: struct {
        success: bool,
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
    // One EditorEvent per player action (the orchestrator convention — see
    // DESIGN → Architecture). Most editor edits are a single verb, so they
    // live directly here as their own variant. The exception is
    // editor_delete_type, an orchestrator that pushes editor_delete_*_placement
    // sub-events (SubEditorEvent) for each referencing placement before
    // removing the type. All editor events mutate current.editor.?.levels[]
    // or the palette directly — pure state transforms captured by deepCopy,
    // so undo/redo works by construction. See DESIGN → Architecture → Level
    // Editor → Editor UI layout for the full design.

    // ── Level management ──
    // Switch the active level tab. Pure state on editor.active_level_index.
    editor_set_active_level: struct {
        level_index: u32,
    },
    // Append a new level built from data/default_level.txt (the minimal `!=`
    // template). No payload — the template is fixed; the author renames /
    // re-themes via the metadata events below.
    editor_add_level: void,
    // Delete a level. Handler removes it, shifts later indices down,
    // decrements mission.level_count, clamps active_level_index. Gated on
    // levels.len > 1 (a mission always has ≥1 level — the handler panics
    // if violated; the UI shouldn't offer the × on the last tab, but the
    // event enforces the invariant).
    editor_delete_level: struct {
        level_index: u32,
    },

    // ── Level tiles ──
    // Set a single tile (paint floor / erase). One event per cell — drag-
    // painting pushes one editor_set_tile per cell crossed (per-field undo
    // granularity by design).
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
    // Switch the level's theme source to the color wheel (clears
    // custom_theme → null; activeThemeFor derives from color_wheel_index).
    editor_set_level_color_wheel: struct {
        level_index: u32,
        color_wheel_index: u32,
    },
    // Set a fully custom per-level theme (or null to revert to the wheel).
    // See DESIGN → Architecture → Level Editor → Level theme (gradient
    // picking).
    editor_set_level_custom_theme: struct {
        level_index: u32,
        custom_theme: ?CustomColorTheme,
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
    // Append an empty type to the corresponding palette group. No payload —
    // the author populates it via the inspector (field-edit events below).
    editor_add_entity_type: void,
    editor_add_decoration_type: void,
    editor_add_item_type: void,
    // Delete a palette type AND every placement referencing it (the handler
    // pushes editor_delete_*_placement sub-events for each referencing
    // placement, then removes the type — the one orchestrator in this set).
    editor_delete_type: struct {
        type_kind: EditorTypeKind,
        type_id: u32,
    },

    // ── Placement (viewport clicks with a placement tool active) ──
    // Per-kind variants (not a Selectable-carrying generic event) so the
    // exported log reads self-describing: `editor_place_entity { … }` over
    // `editor_place { kind entity, … }`.
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
    editor_move_entity_placement: struct {
        level_index: u32,
        placement_index: u32,
        new_position: Vector2,
    },
    editor_move_decoration_placement: struct {
        level_index: u32,
        placement_index: u32,
        new_position: Vector2,
    },
    editor_move_item_placement: struct {
        level_index: u32,
        placement_index: u32,
        new_position: Vector2,
    },

    // ── Entity type editing (per-field, target covers entity_type | player_def) ──
    // Dedicated variants (not a generic field+value event) so the log reads
    // `editor_set_entity_name { target entity_type 0, name Skeleton Warrior }`
    // — the variant name carries the field. Each is one field = one undo.
    editor_set_entity_name: struct {
        target: EntityEditTarget,
        value: []const u8,
    },
    editor_set_entity_sprite: struct {
        target: EntityEditTarget,
        value: []const u8,
    },
    editor_set_entity_color_index: struct {
        target: EntityEditTarget,
        value: u32,
    },
    editor_set_entity_displays_weapons: struct {
        target: EntityEditTarget,
        value: bool,
    },
    editor_set_entity_max_health: struct {
        target: EntityEditTarget,
        value: u32,
    },
    editor_set_entity_momentum: struct {
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
    // Gear: nullable (equip/unequip). Each slot its own event = one undo.
    editor_set_entity_main_hand_weapon: struct {
        target: EntityEditTarget,
        value: ?Weapon,
    },
    editor_set_entity_off_hand_weapon: struct {
        target: EntityEditTarget,
        value: ?Weapon,
    },
    editor_set_entity_amulet: struct {
        target: EntityEditTarget,
        value: ?Amulet,
    },
    editor_set_entity_coat: struct {
        target: EntityEditTarget,
        value: ?Coat,
    },
    editor_set_entity_gloves: struct {
        target: EntityEditTarget,
        value: ?Gloves,
    },
    editor_set_entity_pants: struct {
        target: EntityEditTarget,
        value: ?Pants,
    },
    editor_set_entity_boots: struct {
        target: EntityEditTarget,
        value: ?Boots,
    },
    // Utility skills: per-slot (slot_index 0..utility_skill_count-1), nullable.
    editor_set_entity_utility_skill: struct {
        target: EntityEditTarget,
        slot_index: u32,
        value: ?SkillId,
    },
    // Entity sprite layers (base + overlays). Add/remove/set per layer.
    editor_add_entity_layer: struct {
        target: EntityEditTarget,
        layer: EntityLayer,
    },
    editor_remove_entity_layer: struct {
        target: EntityEditTarget,
        layer_index: u32,
    },
    editor_set_entity_layer: struct {
        target: EntityEditTarget,
        layer_index: u32,
        layer: EntityLayer,
    },

    // ── Decoration type editing (per-field) ──
    editor_set_decoration_name: struct {
        type_id: u32,
        value: []const u8,
    },
    editor_set_decoration_sprite: struct {
        type_id: u32,
        value: []const u8,
    },
    editor_set_decoration_color_index: struct {
        type_id: u32,
        value: u32,
    },
    editor_set_decoration_footprint: struct {
        type_id: u32,
        value: []const Vector2,
    },
    editor_add_decoration_layer: struct {
        type_id: u32,
        layer: DecorationLayer,
    },
    editor_remove_decoration_layer: struct {
        type_id: u32,
        layer_index: u32,
    },
    editor_set_decoration_layer: struct {
        type_id: u32,
        layer_index: u32,
        layer: DecorationLayer,
    },

    // ── Item type editing ──
    // The Item union's variety (weapon/amulet/.../skill_tome, each with
    // different fields) makes per-field granularity impractical — the
    // inspector edits the whole item and pushes one event per commit. The
    // log still reads cleanly (the serializer flattens the union).
    editor_set_item_def: struct {
        type_id: u32,
        value: Item,
    },
    editor_set_item_name: struct {
        type_id: u32,
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
    // (machinery — not player-input events). `swap_hands` moved to
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

/// Player-input events — the ONLY events input handlers can push (via
/// `pushPlayerAction`). Each maps 1:1 to a user action (keybind/click).
/// The replay whitelist (`isPlayerAction`) is just `activeTag ==
/// .player_input_event` — the type IS the whitelist, so it can't drift from
/// the push side. `player_skip_level` is additionally dev-gated in
/// `isPlayerAction`. Handlers for these orchestrators push machinery events
/// (`end_level`, `start_mission`, `move_entity`, `use_skill`, `turn_end`,
/// ...) as children via `pushEvents` — those live in the machinery unions
/// (MetaEvent/LevelEvent/etc.) and are never seeded at an idle point.
/// See DESIGN → Determinism & Tiebreaking → Replay PLAYER-ACTION LEGALITY.
pub const PlayerInputEvent = union(enum) {
    // --- Meta: scope transitions + save + overlay dismiss ---
    start_new_game: void,
    open_editor: struct {
        mission_path: []const u8,
    },
    // Orchestrates a save: syncs PlayerData from the working entity (in a
    // hub/level) via build_data_from_player, then writes via write_save.
    save_game: struct {
        save_path: []const u8,
    },
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
    // meta `load_save` event — the normal load path, so replay re-reads the
    // file silently. The path references a file already resident in the
    // persistent dir (acquisition happened in idle input — see DESIGN →
    // Custom Missions for why that split matters).
    player_load_save: struct {
        save_path: []const u8,
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
    // Options-menu "exit to menu" button. Handler branches on screen:
    // level → end_level{.exit_to_menu}; hub → end_hub + open_main_menu.
    player_exit_to_menu: void,
    // Mission-complete overlay "Replay Mission" button. Handler reads
    // current_state.last_completed_mission for the path, pushes start_mission
    // + end_hub (LIFO: end_hub syncs the hub player first).
    player_replay_mission: void,
    // Mission-complete overlay "Overwrite Clone" button (shown only when
    // `MissionCompleteInfo.overwrite_offered` is set — a clone exists AND the
    // just-completed run was not strictly better). Handler reads
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
    // (prepare vs. use-with-target) — targeting resolution depends on the
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
    // pushed as a child of player_skip_move_to_skill — dual-nature, but that's
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
    /// Self-centric — one event covers the whole level. Pushed at level
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
    // defender's incoming modifiers (no attacker outgoing — collision isn't a
    // weapon hit), fires the collision + damage effect callbacks, and pushes
    // death if killed. Exists as its own event so the combat-log projection
    // sees collisions as first-class occurrences (the knockback handler used
    // to do this inline, invisible to the stream).
    collision: struct {
        attacker_index: u32,
        defender_index: u32,
        damage: u32,
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
    // (no team filter — Howl rallies same-team entities).
    aggro_in_radius: struct {
        entity_index: u32,
        radius: u32,
    },
    // Focus: reset the entity's equipped weapon-skill (slots 1-3) cooldowns.
    // Orchestrator — the handler resolves the weapon skills (needs
    // weapon_type_definitions from GameStateHistory, unreachable from a skill)
    // and emits a change_cooldown per skill.
    reset_weapon_cooldowns: struct {
        entity_index: u32,
    },
    // Items actually picked up from a ground stack. `pickup_around` is a pure
    // CHECK: it scans ground items in the entity's radius and, for each in-range
    // stack (one per position), pushes this event with just the stack's
    // position. The handler looks up the stack at that position and transfers
    // items into the inventory until full or the stack is empty. Carrying only
    // the position (not the items) keeps this event simple-fielded — the
    // session-log serializer never has to handle the Item union — while still
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
    player_input_event: PlayerInputEvent,
    player_event: PlayerEvent,
    level_event: LevelEvent,
    sub_level_event: SubLevelEvent,
    replay_viewer_event: ReplayViewerEvent,
};
