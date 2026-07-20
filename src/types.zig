const std = @import("std");

pub const Vec2 = struct {
    x: i32,
    y: i32,
};

pub const DecorationInfo = struct {
    position: Vec2,
    footprint: []const Vec2,
    sprite_id: u32 = 0,
};

pub const SkillType = enum {
    weapon_skill,
    spell,
    cantrip,
    enchantment,
    curse,
};

pub const SkillId = enum {
    // weapon skills
    slice,
    spinblade,
    flash_strike,
    bash,
    slam,
    reflect,

    // spells

    // cantrips
    replenish,

    // enchantments

    // curses
};

pub const WeaponType = union(enum) {
    sword: struct {
        skill_1: SkillId.slice,
        skill_2: SkillId.spinblade,
        skill_3: SkillId.flash_strike,
    },
    shield: struct {
        skill_1: SkillId.bash,
        skill_2: SkillId.slam,
        skill_3: SkillId.reflect,
    }
    spear,
    dagger,
    axe,
    staff,
    crossbow,
    idol,
};

pub const ItemType = union(enum) {
    weapon: WeaponType,
    amulet: void,
    coat: void,
    gloves: void,
    pants: void,
    boots: void,
    skill_tome: SkillId,
};

pub const WeaponInfo = struct {
    name: []const u8,
    weapon_type: WeaponType,
    weapon_damage: u32,
    salvage_conversion: MaterialsInfo,
};

pub const AmuletInfo = struct {
    name: []const u8,
    spell_damage: u32,
    salvage_conversion: MaterialsInfo,
};

pub const CoatInfo = struct {
    name: []const u8,
    health_bonus: u32,
    defense_bonus: u32,
    salvage_conversion: MaterialsInfo,
};

pub const GlovesInfo = struct {
    name: []const u8,
    health_bonus: u32,
    damage_bonus: u32,
    salvage_conversion: MaterialsInfo,
};

pub const PantsInfo = struct {
    name: []const u8,
    health_bonus: u32,
    pickup_radius_bonus: u32,
    salvage_conversion: MaterialsInfo,
};

pub const BootsInfo = struct {
    name: []const u8,
    health_bonus: u32,
    speed_bonus: u32,
    salvage_conversion: MaterialsInfo,
};

pub const SkillTomeInfo = struct {
    skill: SkillId,
    salvage_conversion: MaterialsInfo,
};

pub const ItemInfo = union(enum) {
    weapon_info: WeaponInfo,
    amulet_info: AmuletInfo,
    coat_info: CoatInfo,
    gloves_info: GlovesInfo,
    pants_info: PantsInfo,
    boots_info: BootsInfo,
};

pub const EntityInfo = struct {
    name: []const u8,
    team: u32,
    position: Vec2,
    max_health: u32,
    current_health: u32,
    momentum: u32,
};

pub const GroundItemsInfo = struct {
    position: Vec2,
    items: []const ItemInfo,
};

pub const MaterialsInfo = struct {
    wood: u32,
    metal: u32,
    leather: u32,
    cloth: u32,
    knowledge: u32,
};

pub const MissionInfo = struct {
    mission_name: []const u8,
    level_count: u32,
    start_hub: ?HubId,
    end_hub: ?HubId,
    turns_spent: u32,
    converted_materials_collected: MaterialsInfo,
    damage_dealt: u32,
    damage_taken: u32,
    skills_used: u32,

};

pub const CloneInfo = struct {
    mission_name: []const u8,
    turns_to_complete: u32,
    materials_collected: Materials,
};

pub const PlayerData = struct {
    materials: MaterialsInfo,
    clones: []const CloneInfo,
    discovered_hubs: []const HubInfo,

};

pub const LevelInfo = struct {
    level_tiles: []const Vec2,
    entities: []const EntityInfo,
    ground_items: []const GroundItemsInfo,
    decorations: []const DecorationInfo,
    level_end: Vec2,
    highlighted_tiles: []const Vec2,

}

pub const GameState = struct {
    entities: []const EntityInfo,
    level_tiles: []const Vec2,
    ground_items: []const GroundItemsInfo,
    decorations: []const DecorationInfo,
    highlighted_tiles: []const Vec2,
    level_complete: bool,
};
