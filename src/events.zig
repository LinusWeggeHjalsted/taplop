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
    save_game: struct {
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
    player_turn_attack: void,
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
    
    move_entity: struct {
        entity_index: u32,
        destination: Vector2,
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
