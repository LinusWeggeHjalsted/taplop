const types = @import("types.zig");

const Vec2 = types.Vec2;
const SkillId = types.SkillId;

pub const MetaGameEvent = union(enum) {
    // scope: all
    // transitions between game scopes and file io
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
        start_hub_id: ?HubId,
        end_hub_id: ?HubId,
    },
    end_mission: struct {
        hub_id: ?HubId,
    },
    start_level: struct {
        mission_path: []const u8,
        level_index: u32,
    },
    end_level: void,
    start_hub: struct {
        hub_id: HubId,
    },
    end_hub: void,
    open_editor: void,
    close_editor: void,
};

pub const SuperGameEvent = union(enum) {
    // scope: all
    // player data syncronization
    build_data_from_save: struct {
        file_path: []const u8,
    },
    build_save_from_data: struct {
        file_path: []const u8,
    },
    build_player_from_data: struct {
        player_entity: EntityInfo,
    },
    build_data_from_player: struct {
        player_entity: EntityInfo,
    },

    save_clone_info: struct {
        mission_name: []const u8,
        total_turns: u32,
        total_materials: MaterialsInfo,
    },
};

pub const EditorGameEvent = union(enum) {
    // scope: editor
    // main editor actions
};

pub const SubEditorGameEvent = union(enum) {
    // scope: editor
};

pub const LevelGameEvent = union(enum) {
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
        tile_positions: []const Vec2,
    },
    clear_highlights: void,
    
    move_entity: struct {
        entity_index: u32,
        destination: Vec2,
    },

    player_prepare_skill: struct {
        caster_index: u32,
        skill_id: SkillId,
    },
    use_skill: struct {
        caster_index: u32,
        skill_id: SkillId,
        target: ?Vec2,
    },

    player_swap_hands: struct {
        main_hand_weapon: ?WeaponInfo,
        off_hand_weapon: ?WeaponInfo,
    },

};

pub const SubLevelGameEvent = union(enum) {
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
        target_position: Vec2,
        distance: u32,
    },
    create_skill_effect: struct {
        entity_index: u32,
        skill_id: SkillId,
        skill_duration: u32,
    },
    death: struct {
        entity_index: u32,
    },
};

pub const ReplayViewerGameEvent = union(enum) {
    // scope: replay viewer
};

pub const GameEvent = union(enum) {
    meta_game_event: MetaGameEvent,
    super_game_event: SuperGameEvent,
    editor_game_event: EditorGameEvent,
    sub_editor_game_event: SubEditorGameEvent,
    level_game_event: LevelGameEvent,
    sub_level_game_event: SubLevelGameEvent,
    replay_viewer_game_event: ReplayViewerGameEvent,
};
