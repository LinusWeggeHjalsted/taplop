const types = @import("types.zig");

const Vector2 = types.Vector2;
const SkillId = types.SkillId;
const GearSlot = types.GearSlot;
const Item = types.Item;
const Materials = types.Materials;
const EffectId = types.EffectId;

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
    start_new_game: void,
    load_save: struct {
        save_path: []const u8,
    },
    // Orchestrates a save: syncs PlayerData from the working entity (in a
    // hub/level) via build_data_from_player, then writes via write_save.
    save_game: struct {
        save_path: []const u8,
    },
    // The pure file write. Persists current.player_data as-is; expects any
    // needed entity->PlayerData sync to have already run (see save_game).
    write_save: struct {
        save_path: []const u8,
    },
    start_mission: struct {
        mission_path: []const u8,
        start_hub_id: ?[]const u8,
        end_hub_id: ?[]const u8,
    },
    end_mission: struct {
        hub_id: ?[]const u8,
    },
    start_level: struct {
        mission_path: []const u8,
        level_index: u32,
        sets_checkpoint: bool = true,
    },
    end_level: void,
    start_hub: struct {
        hub_id: []const u8,
        sets_checkpoint: bool = true,
    },
    end_hub: void,
    open_editor: void,
    close_editor: void,
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
        mission_name: []const u8,
        total_turns: u32,
        total_materials: Materials,
    },
};

pub const EditorEvent = union(enum) {
    // scope: editor
    // main editor actions
};

pub const SubEditorEvent = union(enum) {
    // scope: editor
    // individual editor events
};

pub const PlayerEvent = union(enum) {
    // scope: hub or level
    swap_hands: void,
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
};

pub const HubEvent = union(enum) {
    // scope: hub
    move_player: struct {
        destination: Vector2,
    },
    interact_with_npc: struct {
        npc_index: u32,
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

    player_prepare_skill: struct {
        caster_index: u32,
        skill_id: SkillId,
    },
    use_skill: struct {
        caster_index: u32,
        skill_id: SkillId,
        target: ?Vector2,
    },

    // --- player-action orchestrators ---
    // Each player input pushes exactly ONE of these as the top-level event;
    // the handler then composes the existing verb events (player_turn_attack,
    // clear_highlights, move_entity, use_skill, turn_end, ...). This keeps one
    // recorded event per player action so a reconstructed session derives idle
    // points purely from virtual stack depth (see reconstructFromEventLog) and
    // undo granularity matches a single click/key. These carry no state of
    // their own beyond the player's intent — all mutation is in the verbs they
    // push.
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
    player_cancel_skill: void,
    player_skip_attack: void,
    player_use_skill: struct {
        skill_id: SkillId,
        target: ?Vector2,
    },

};

pub const SubLevelEvent = union(enum) {
    // scope: level
    // individual in-level effects - pickup, aggro, attack, other skill effects
    pickup_around: struct {
        entity_index: u32,
    },
    aggro_around: struct {
        entity_index: u32,
    },
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
    // Distinct from aggro_around, which uses the entity's own aggro_range and
    // carries level-end coupling.
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
    sub_editor_event: SubEditorEvent,
    player_event: PlayerEvent,
    hub_event: HubEvent,
    level_event: LevelEvent,
    sub_level_event: SubLevelEvent,
    replay_viewer_event: ReplayViewerEvent,
};
