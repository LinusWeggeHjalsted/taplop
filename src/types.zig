const std = @import("std");
const generated = @import("generated");

pub const SkillId = generated.SkillId;
pub const EffectId = generated.EffectId;

pub const utility_skill_count = 5;

pub const Vector2 = struct {
    x: i32,
    y: i32,
};

pub const Action = enum {
    undo,
    redo,
    toggle_options_menu,
    toggle_inventory,
    toggle_gear,
    toggle_skills,
    toggle_world_map,
    confirm,
    cancel,
    skip,
    skill_slot_1,
    skill_slot_2,
    skill_slot_3,
    skill_slot_4,
    skill_slot_5,
    skill_slot_6,
    skill_slot_7,
    skill_slot_8,
    swap_weapons,
};

/// Raw input identifier — uses human-readable strings so config files
/// are legible and editable. Key codes follow the W3C KeyboardEvent.code
/// spec (e.g. "KeyA", "Space", "ShiftLeft"). Mouse buttons are "left",
/// "right", "middle". Gamepad buttons follow the Gamepad API names.
pub const RawInput = union(enum) {
    key: []const u8,
    mouse_button: []const u8,
    gamepad_button: []const u8,
};

pub const Modifiers = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
};

pub const InputBinding = struct {
    input: RawInput,
    modifiers: Modifiers = .{},
    action: Action,
};

pub const Settings = struct {
    music_volume: f32 = 0.5, // 0.0–1.0
    sound_effects_volume: f32 = 0.5, // 0.0–1.0
    vsync: bool = true,
    auto_skip_attack_step_out_of_combat: bool = true,
    auto_target_at_cursor: bool = true,
    input_bindings: []const InputBinding,
    camera_zoom: f32 = 1.0, // 1.0 = no zoom, <1 = zoomed out, >1 = zoomed in
};

pub const Camera = struct {
    position: Vector2,
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const gradient_color_count = 6;

pub const ColorGradient = struct {
    colors: [gradient_color_count]Color,
};

pub const ColorThemeDefinitions = struct {
    lightest: Color,
    darkest: Color,
    gradients: []const ColorGradient,
};

pub const ActiveColorTheme = struct {
    lightest: Color,
    darkest: Color,
    world_gradient: ColorGradient,
    enemy_gradient: ColorGradient,
    player_gradient: ColorGradient,
};

pub const DecorationId = enum {
    // TODO: generate this at compile time
    placeholder,
};

pub const Decoration = struct {
    decoration_id: ?DecorationId,
    name: []const u8,
    position: Vector2,
    footprint: []const Vector2, // position should be bottommost then leftmost in footprint
};

pub const SkillType = enum {
    weapon_skill,
    spell,
    cantrip,
    enchantment,
    curse,
};

pub const WeaponType = enum {
    sword,
    shield,
    spear,
    dagger,
    axe,
    staff,
    crossbow,
    idol,
};

pub const WeaponTypeDefinition = struct {
    skill_1: SkillId,
    skill_2: SkillId,
    skill_3: SkillId,
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

pub const Weapon = struct {
    name: []const u8 = &.{},
    weapon_type: WeaponType = .sword,
    weapon_damage: u32 = 0,
};

pub const Amulet = struct {
    name: []const u8 = &.{},
    spell_damage: u32 = 0,
};

pub const Coat = struct {
    name: []const u8 = &.{},
    health_bonus: u32 = 0,
    defense_bonus: u32 = 0,
};

pub const Gloves = struct {
    name: []const u8 = &.{},
    health_bonus: u32 = 0,
    damage_bonus: u32 = 0,
};

pub const Pants = struct {
    name: []const u8 = &.{},
    health_bonus: u32 = 0,
    pickup_radius_bonus: u32 = 0,
};

pub const Boots = struct {
    name: []const u8 = &.{},
    health_bonus: u32 = 0,
    speed_bonus: u32 = 0,
};

pub const SkillTome = struct {
    skill: SkillId = .slice,
    value: u32 = 5,
};

pub const Item = union(enum) {
    weapon: Weapon,
    amulet: Amulet,
    coat: Coat,
    gloves: Gloves,
    pants: Pants,
    boots: Boots,
    skill_tome: SkillTome,
};

pub const AdditiveEffectModifiers = struct {
    outgoing_damage: i32 = 0,
    incoming_damage: i32 = 0,
    speed: i32 = 0,
    range: i32 = 0,
    radius: i32 = 0,
    distance: i32 = 0,
    outgoing_skill_duration: i32 = 0,
    incoming_skill_duration: i32 = 0,
    outgoing_stun_duration: i32 = 0,
    incoming_stun_duration: i32 = 0,
    cooldown: i32 = 0,
    pickup_radius: i32 = 0,
    defense: i32 = 0,
};

pub const Effect = struct {
    effect_id: EffectId,
    duration: u32,
    additive_effect_modifiers: AdditiveEffectModifiers = .{},
};

pub const Entity = struct {
    name: []const u8 = &.{},
    team: u32 = 0,
    position: Vector2 = .{ .x = 0, .y = 0 },
    max_health: u32 = 20,
    current_health: u32 = 20,
    momentum: u32 = 0,
    speed: u32 = 1,
    defense: u32 = 0,
    aggro_range: u32 = 3,
    is_active: bool = false,
    stun_duration: u32 = 0,

    main_hand_weapon: ?Weapon = null,
    off_hand_weapon: ?Weapon = null,
    amulet: ?Amulet = null,
    coat: ?Coat = null,
    gloves: ?Gloves = null,
    pants: ?Pants = null,
    boots: ?Boots = null,

    equipped_utility_skills: [utility_skill_count]SkillId = .{.slice} ** utility_skill_count,
    inventory: Inventory = .{},
    skill_cooldowns: std.EnumArray(SkillId, u32) = std.EnumArray(SkillId, u32).initFill(0),
    active_effects: []const Effect = &.{},

    /// Sum a single modifier field across all active effects.
    fn sumEffectModifier(
        self: Entity,
        comptime field: std.meta.FieldEnum(AdditiveEffectModifiers),
    ) i32 {
        var total: i32 = 0;
        for (self.active_effects) |effect| {
            total += @field(effect.additive_effect_modifiers, @tagName(field));
        }
        return total;
    }

    /// Apply an additive modifier to a base u32 value, clamping to minimum 0.
    fn applyModifier(base: u32, modifier: i32) u32 {
        const result = @as(i32, @intCast(base)) + modifier;
        return @intCast(@max(0, result));
    }

    /// Floor of base-2 logarithm of momentum, or 0 if momentum is 0.
    pub fn getConvertedMomentum(self: Entity) u32 {
        if (self.momentum == 0) return 0;
        return std.math.log2(self.momentum);
    }

    pub fn getEffectiveOutgoingDamage(self: Entity, base_damage: u32) u32 {
        const gloves_bonus: u32 = if (self.gloves) |gloves| gloves.damage_bonus else 0;
        const modifier = self.sumEffectModifier(.outgoing_damage) +
            @as(i32, @intCast(gloves_bonus)) +
            @as(i32, @intCast(self.getConvertedMomentum()));
        return applyModifier(base_damage, modifier);
    }

    pub fn getEffectiveIncomingDamage(self: Entity, base_damage: u32) u32 {
        const modifier = self.sumEffectModifier(.incoming_damage) -
            @as(i32, @intCast(self.getEffectiveDefense()));
        return applyModifier(base_damage, modifier);
    }

    pub fn getEffectiveRange(self: Entity, base_range: u32) u32 {
        return applyModifier(base_range, self.sumEffectModifier(.range));
    }

    pub fn getEffectiveRadius(self: Entity, base_radius: u32) u32 {
        return applyModifier(base_radius, self.sumEffectModifier(.radius));
    }

    pub fn getEffectiveDistance(self: Entity, base_distance: u32) u32 {
        return applyModifier(base_distance, self.sumEffectModifier(.distance));
    }

    pub fn getEffectiveOutgoingSkillDuration(self: Entity, base_duration: u32) u32 {
        return applyModifier(base_duration, self.sumEffectModifier(.outgoing_skill_duration));
    }

    pub fn getEffectiveIncomingSkillDuration(self: Entity, base_duration: u32) u32 {
        return applyModifier(base_duration, self.sumEffectModifier(.incoming_skill_duration));
    }

    pub fn getEffectiveOutgoingStunDuration(self: Entity, base_duration: u32) u32 {
        return applyModifier(base_duration, self.sumEffectModifier(.outgoing_stun_duration));
    }

    pub fn getEffectiveIncomingStunDuration(self: Entity, base_duration: u32) u32 {
        return applyModifier(base_duration, self.sumEffectModifier(.incoming_stun_duration));
    }

    pub fn getEffectiveCooldown(self: Entity, base_cooldown: u32) u32 {
        return applyModifier(base_cooldown, self.sumEffectModifier(.cooldown));
    }

    pub fn getEffectiveSpeed(self: Entity) u32 {
        const boots_bonus: u32 = if (self.boots) |boots| boots.speed_bonus else 0;
        const modifier = self.sumEffectModifier(.speed) +
            @as(i32, @intCast(boots_bonus));
        return applyModifier(self.speed, modifier);
    }

    pub fn getEffectivePickupRadius(self: Entity, base_radius: u32) u32 {
        const pants_bonus: u32 = if (self.pants) |pants| pants.pickup_radius_bonus else 0;
        const modifier = self.sumEffectModifier(.pickup_radius) +
            @as(i32, @intCast(pants_bonus));
        return applyModifier(base_radius, modifier);
    }

    pub fn getEffectiveDefense(self: Entity) u32 {
        const coat_bonus: u32 = if (self.coat) |coat| coat.defense_bonus else 0;
        const modifier = self.sumEffectModifier(.defense) +
            @as(i32, @intCast(coat_bonus));
        return applyModifier(self.defense, modifier);
    }
};

pub const GroundItems = struct {
    position: Vector2,
    items: []const Item,
};

pub const MaterialType = enum {
    wood,
    metal,
    leather,
    cloth,
    knowledge,
};

pub const Materials = struct {
    wood: u32 = 0,
    metal: u32 = 0,
    leather: u32 = 0,
    cloth: u32 = 0,
    knowledge: u32 = 0,

    pub fn add(self: *Materials, other: Materials) void {
        self.wood += other.wood;
        self.metal += other.metal;
        self.leather += other.leather;
        self.cloth += other.cloth;
        self.knowledge += other.knowledge;
    }
};

pub const SalvageSplit = struct {
    material: MaterialType,
    parts: u32,
};

pub const SalvageDefinition = struct {
    splits: []const SalvageSplit,
};

pub const item_type_count = @typeInfo(ItemType).@"union".fields.len;
pub const weapon_type_count = @typeInfo(WeaponType).@"enum".fields.len;

/// Salvage definitions for all item types.
/// Non-weapon items are indexed by their position in the ItemType union
/// (skipping .weapon, which uses per-weapon-type definitions).
pub const SalvageDefinitions = struct {
    weapon: [weapon_type_count]SalvageDefinition,
    amulet: SalvageDefinition,
    coat: SalvageDefinition,
    gloves: SalvageDefinition,
    pants: SalvageDefinition,
    boots: SalvageDefinition,
    skill_tome: SalvageDefinition,
};

pub const inventory_columns = 8;
pub const inventory_rows = 12;
pub const inventory_slot_count = inventory_columns * inventory_rows;

pub const Inventory = struct {
    slots: [inventory_slot_count]?Item = .{null} ** inventory_slot_count,
};

pub const Clone = struct {
    name: []const u8 = &.{},
    turns_to_complete: u32 = 0,
    materials_collected: Materials = .{},
};

pub const PlayerData = struct {
    player_name: []const u8 = &.{},
    current_campaign: []const u8 = &.{},
    current_hub: []const u8 = &.{},
    materials: Materials = .{},
    clones: []const Clone = &.{}, // will also be used to identify completed missions - maybe per campaign also?
    discovered_hubs: []const Hub = &.{}, // change to be per campaign
    learned_skills: []const SkillId = &.{},
    turns: u32 = 0,
    deaths: u32 = 0,
    defeated_enemies: u32 = 0,
    skills_used: u32 = 0,
    // maybe more statistics later

    main_hand_weapon: ?Weapon = null,
    off_hand_weapon: ?Weapon = null,
    amulet: ?Amulet = null,
    coat: ?Coat = null,
    gloves: ?Gloves = null,
    pants: ?Pants = null,
    boots: ?Boots = null,
    inventory: Inventory = .{},
    equipped_utility_skills: [utility_skill_count]SkillId = .{.slice} ** utility_skill_count,
};

pub const Editor = struct {
    
};

pub const ReplayViewer = struct {

};

pub const HubNode = struct {
    hub_id: []const u8,
    mission_exits: []const []const u8,
};

pub const MissionEdge = struct {
    mission_id: []const u8,
    start_hub: []const u8,
    end_hub: []const u8,
};

pub const CampaignGraph = struct {
    hub_nodes: []const HubNode,
    mission_edges: []const MissionEdge,
};

pub const PositionedHubNode = struct {
    hub_node: HubNode,
    position: Vector2,
};

pub const PositionedMissionEdge = struct {
    mission_edge: MissionEdge,
    start_position: Vector2,
    end_position: Vector2,
};

pub const PositionedCampaignGraph = struct {
    // screen space
    positioned_nodes: []const PositionedHubNode,
    positioned_edges: []const PositionedMissionEdge,
};

pub const Campaign = struct {
    name: []const u8 = &.{},
    campaign_graph: CampaignGraph = .{ .hub_nodes = &.{}, .mission_edges = &.{} },
    start_hub: []const u8 = &.{},
};

pub const Mission = struct {
    name: []const u8 = &.{},
    path: []const u8 = &.{},
    level_count: u32 = 0,
    current_level_index: u32 = 0,
    start_hub: ?[]const u8 = null,
    end_hub: ?[]const u8 = null,
    turns_spent: u32 = 0,
    converted_materials_collected: Materials = .{},
    damage_dealt: u32 = 0,
    damage_taken: u32 = 0,
    skills_used: u32 = 0,
};

pub const CombatLogEntry = union(enum) {
    turn_start: struct {
        entity_name: []const u8,
    },
    move: struct {
        entity_name: []const u8,
        from: Vector2,
        to: Vector2,
    },
    skill_used: struct {
        caster_name: []const u8,
        skill_id: SkillId,
        target: ?Vector2,
    },
    attack: struct {
        attacker_name: []const u8,
        defender_name: []const u8,
        damage: u32,
    },
    death: struct {
        entity_name: []const u8,
    },
    stun: struct {
        attacker_name: []const u8,
        defender_name: []const u8,
        duration: u32,
    },
    knockback: struct {
        attacker_name: []const u8,
        defender_name: []const u8,
        distance: u32,
    },
    effect_applied: struct {
        entity_name: []const u8,
        effect_id: EffectId,
        duration: u32,
    },
    item_picked_up: struct {
        entity_name: []const u8,
        item_name: []const u8,
    },
    swap_weapons: struct {
        entity_name: []const u8,
    },
};

pub const TurnPhase = enum {
    player_move,
    player_attack,
};

pub const Level = struct {
    name: []const u8 = &.{},
    color_wheel_index: u32 = 0,
    level_tiles: []const Vector2 = &.{},
    entities: []const Entity = &.{},
    ground_items: []const GroundItems = &.{},
    decorations: []const Decoration = &.{},
    level_end: ?Vector2 = null,
    tile_cursor: ?Vector2 = null,
    highlighted_tiles: []const Vector2 = &.{},
    prepared_skill: ?SkillId = null,
    turn_phase: ?TurnPhase = null,
    combat_log: []const CombatLogEntry = &.{},
};

pub const MissionExit = struct {
    mission_id: []const u8,
    position: Vector2,
};

pub const Hub = struct {
    name: []const u8 = &.{},
    color_wheel_index: u32 = 0,
    hub_tiles: []const Vector2 = &.{},
    player: Entity = .{},
    npcs: []const NPC = &.{},
    decorations: []const Decoration = &.{},
    mission_exits: []const MissionExit = &.{},
};

pub const NPC = struct {
    entity: Entity,
    // TODO: NPC-specific fields (dialogue, behavior, etc.)
};

// ============================================================
// View state — output of view(), input to renderer
// ============================================================

/// Fixed reference resolution. The view function produces coordinates
/// in this space; the renderer scales to the actual viewport.
pub const reference_width: u32 = 3840;
pub const reference_height: u32 = 2160;

/// Screen-space position in the reference resolution coordinate system.
/// Integer because we work in a fixed logical resolution.
pub const ScreenPosition = struct {
    x: i32,
    y: i32,
};

/// Axis-aligned rectangle in screen space.
pub const Rectangle = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

// -- Layer 1: Tiles --

pub const TileDrawable = struct {
    screen_position: ScreenPosition,
    color: Color,
};

// -- Layer 2: Tile overlays --

pub const TileOverlayType = enum {
    highlight,
    range_outline,
    radius_outline,
    aggro_outline,
    cursor,
};

pub const TileOverlayDrawable = struct {
    screen_position: ScreenPosition,
    overlay_type: TileOverlayType,
    color: Color,
};

// -- Layer 3: Ground drawables --

pub const SpriteDrawable = struct {
    sprite_id: []const u8,
    screen_position: ScreenPosition,
    /// Offset from screen_position for rendering (e.g. decoration
    /// overhang drawn above the footprint tile).
    draw_offset: ScreenPosition,
    /// Region of the sprite to draw. Null means the full sprite.
    source_rectangle: ?Rectangle,
    color: Color,
};

pub const HealthBarDrawable = struct {
    screen_position: ScreenPosition,
    width: u32,
    current_health: u32,
    max_health: u32,
};

pub const EntityDrawable = struct {
    back_effect_sprites: []const SpriteDrawable,
    base_sprite: SpriteDrawable,
    weapon_sprites: [2]?SpriteDrawable,
    gear_sprites: []const SpriteDrawable,
    front_effect_sprites: []const SpriteDrawable,
    health_bar: ?HealthBarDrawable,
};

pub const DecorationPieceDrawable = struct {
    sprite_id: []const u8,
    screen_position: ScreenPosition,
    draw_offset: ScreenPosition,
    source_rectangle: Rectangle,
    color: Color,
};

pub const GroundItemDrawable = struct {
    sprite_id: []const u8,
    screen_position: ScreenPosition,
    color: Color,
    item_count: u32,
};

pub const LevelEndDrawable = struct {
    sprite_id: []const u8,
    screen_position: ScreenPosition,
    color: Color,
};

pub const GroundDrawable = union(enum) {
    entity: EntityDrawable,
    decoration_piece: DecorationPieceDrawable,
    ground_items: GroundItemDrawable,
    level_end: LevelEndDrawable,
};

// -- Layer 4+5: UI elements --
// UI is a flat list of UiElement from ui.zig, sorted back to front.
// The view function builds and flattens the full UI layout.
// Options menu elements are included at the end when open.

// -- Top-level view state --

pub const ViewState = struct {
    background_color: Color,
    active_color_theme: ActiveColorTheme,
    tiles: []const TileDrawable,
    tile_overlays: []const TileOverlayDrawable,
    ground_drawables: []const GroundDrawable,
    ui_elements: []const @import("ui.zig").UiElement,
};

