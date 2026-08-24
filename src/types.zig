//! All game data types: entities, levels, hubs, missions, campaigns, player
//! data, gear, items, skills/effects (via generated enums), color themes,
//! input/settings, and the view-state drawables. `Entity` carries the
//! gameplay stat accessors (`getEffective*`, `skillInSlot`, `collectSkillSlots`).
//! See AGENTS → Architecture (player always entity 0, derived-from-entity
//! single source of truth) and Entity & UI Coloring.

const std = @import("std");
const generated = @import("generated");

pub const SkillId = generated.SkillId;
pub const EffectId = generated.EffectId;

pub const utility_skill_count = 5;

/// One-shot sound effects, one variant per sfx file under `assets/audio/sfx/`.
/// Pushed onto `SessionState.pending_sounds` by event handlers (gated
/// `!replaying`) and input handlers, then drained by `frame()` and played via
/// the backend. Music is a single always-on stream, not a `SoundId`. See
/// AGENTS → Audio.
pub const SoundId = enum {
    move,
    weapon_swing,
    spell,
    damage,
    pickup,
    skip,
    equip,
    learn_skill,
    salvage,
    swap_skill,
    button_click_down,
    button_click_up,
    menu,
    defeat,
    mission_completion,
};

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
    // Tile-cursor nudging (arrow keys; see session.tile_cursor resolution).
    // When the mouse is idle, these move the logical cursor one tile. If the
    // cursor is null, it snaps to the player's tile before nudging.
    move_cursor_up,
    move_cursor_down,
    move_cursor_left,
    move_cursor_right,
    // Dump the full session event history to a config-format log file (dev
    // tooling; see parser.writeEventLog). Anytime, side-effecting.
    dump_event_log,
    // Dismiss a recoverable error popup (see SessionState.pending_error).
    // Modal — when a pending error is shown, this is the only action that
    // reaches the game; all other input is swallowed until the popup is
    // dismissed. Bound to Escape + Enter so either key clears it.
    dismiss_error,
    // Scroll the error popup body (arrows; the mouse wheel also scrolls
    // it via a redirect in the modal input gate). Only consumed while a
    // pending error is shown. Bound to the same Up/Down keys as the tile-
    // cursor nudge — the modal gate routes them to scroll, not cursor, while
    // the popup is up. See AGENTS → Error Handling.
    error_scroll_up,
    error_scroll_down,
    // Camera zoom (keyboard shortcuts; the mouse wheel also zooms via
    // scroll_delta). ctrl+I = zoom in, ctrl+O = zoom out, ctrl+0 = reset to
    // 1.0. Letters/digits are layout-stable (physical key positions), unlike
    // the +/- symbol keys whose raylib tokens are layout-labeled and degrade
    // on ISO layouts. See AGENTS → Input.
    zoom_in,
    zoom_out,
    zoom_reset,
    // Main menu commands.
    continue_game,
    new_game,
    load_save,
    open_editor,
    open_settings,
    open_credits,
};

/// The context-specific sound an action plays on button release, if any.
/// Actions without a specific sound use the generic `button_click_up`.
/// Press-down is always `button_click_down` regardless of action. See
/// AGENTS → Audio.
pub fn releaseSoundForAction(action: Action) ?SoundId {
    return switch (action) {
        .skip => .skip,
        .swap_weapons => .swap_skill,
        .toggle_inventory, .toggle_gear, .toggle_skills, .toggle_world_map, .toggle_options_menu => .menu,
        // Skill slots: suppress the generic button-up (the use_skill event
        // plays weapon_swing/spell on auto-fire; the prepare path plays
        // button_click_up explicitly). See AGENTS → Audio.
        .skill_slot_1, .skill_slot_2, .skill_slot_3, .skill_slot_4,
        .skill_slot_5, .skill_slot_6, .skill_slot_7, .skill_slot_8 => .button_click_up,
        else => null,
    };
}

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
    master_volume: f32 = 1.0, // 0.0–1.0, scales music + sfx alike
    music_volume: f32 = 0.5, // 0.0–1.0, before master
    sound_effects_volume: f32 = 0.5, // 0.0–1.0, before master
    vsync: bool = true,
    // Frames-per-second cap for rendering. 0 = no explicit cap. Ignored when
    // vsync is on (vsync paces renders to the monitor refresh rate). When
    // vsync is off and this is >0, renders are gated to 1/cap seconds; when 0
    // and vsync off, the loop renders every iteration (uncapped).
    render_fps_cap: u32 = 0,
    /// Animation frame rate for ALL sprite animations (currently the flag
    /// banner). One global rate so pacing is uniform; frame
    /// duration = 1_000_000 / animation_fps microseconds. Read by `view()`
    /// only (never by event handlers — see AGENTS → Animation). Default 8.
    animation_fps: u32 = 8,
    auto_skip_attack_step_out_of_combat: bool = true,
    auto_target_at_cursor: bool = true,
    /// Player color index into the current theme's player gradient. Read at
    /// render time to tint the player entity + UI. Default 0 (lightest).
    player_color_index: u32 = 0,
    input_bindings: []const InputBinding,
    camera_zoom: f32 = 0.5, // 1.0 = no zoom, <1 = zoomed out, >1 = zoomed in
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

/// A fully custom per-level/per-hub color theme: the 3 gradients (18 colors)
/// that `ActiveColorTheme` derives from the color wheel when
/// `color_wheel_index` is used. Stored as an OPTIONAL override on
/// Level/Hub/EditorLevel (`custom_theme: ?CustomColorTheme`); when null,
/// `activeThemeFor` derives from `color_wheel_index` as before (backward
/// compatible). `lightest`/`darkest` stay from the global
/// ColorThemeDefinitions (lightest = tile-cursor color; darkest is unused
/// since the background now comes from world_gradient[2]). See AGENTS →
/// Architecture → Level Editor → Editor UI layout (right metadata panel).
pub const CustomColorTheme = struct {
    world_gradient: ColorGradient,
    enemy_gradient: ColorGradient,
    player_gradient: ColorGradient,
};

/// One overlay layer of a decoration: a sprite drawn over the base at the same
/// position, colored independently. Must be the same pixel dimensions as the
/// base (validated at load). See AGENTS.md "Decorations & Footprint".
pub const DecorationLayer = struct {
    sprite: []const u8,
    color_index: u32,
    /// Pixel dims (validated == base pixel_dims at load; stored so view() stays
    /// pure and replay reproduces without re-reading).
    pixel_dims: Vector2,
};

pub const Decoration = struct {
    name: []const u8,
    /// World position of the anchor tile (bottom-most-then-left-most footprint
    /// tile). The layout char sits here; non-anchor footprint tiles are
    /// implicit. See AGENTS.md "Decorations & Footprint".
    position: Vector2,
    /// Footprint tile coordinates in the SPRITE's own tile-grid (top-left of
    /// the sprite bbox = (0,0)). Not anchor-relative — the list is authored
    /// by marking the solid tiles of the sprite. The anchor is DERIVED from
    /// this list (bottom-most-then-left-most).
    footprint: []const Vector2,
    /// Pixel dimensions of the BASE sprite (from the PNG IHDR). view() uses
    /// these to compute the tile bbox and per-tile source rectangles for
    /// splitting. Populated by the parser: comptime table for shipped sprites,
    /// PNG-byte parse for custom sprites. Stored on the GameState so view()
    /// stays pure (no I/O) and replay reproduces it without re-reading the PNG.
    pixel_dims: Vector2,
    /// Color index into the current theme's world gradient. Default 0
    /// (lightest world color). Tiles use 1/3, background uses 2; decorations
    /// should use 0/4/5 for distinction.
    color_index: u32 = 0,
    /// Overlay layers (same pixel dims as the base), drawn over the base in
    /// declaration order, each colored independently.
    layers: []const DecorationLayer = &.{},
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

/// The equippable gear slots on an entity. Weapons occupy main_hand/off_hand;
/// the rest map one-to-one to their gear fields.
pub const GearSlot = enum {
    main_hand,
    off_hand,
    amulet,
    coat,
    gloves,
    pants,
    boots,
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

/// One overlay layer of an entity: a sprite drawn over the base body at the
/// same frame + pivot, colored independently. Shares the entity's fixed
/// 512×640 frame (no per-layer pixel dims needed). See AGENTS → Decorations
/// & Footprint for the layer model.
pub const EntityLayer = struct {
    sprite: []const u8,
    color_index: u32,
};

pub const Entity = struct {
    name: []const u8 = &.{},
    /// Sprite identifier (asset stem under assets/entities/, e.g. "player",
    /// "skeleton_1"). Distinct from `name`, which is the display name.
    sprite: []const u8 = &.{},
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
    /// Whether weapons are drawn on this entity. Default true (humanoids);
    /// enemies like wolves set `displays_weapons false` to suppress weapon
    /// overlays. Parsed from the level file's enemy definition.
    displays_weapons: bool = true,
    /// Color index into the team's gradient (enemy → enemy_gradient, player
    /// → player_gradient). The player's index is overridden by a settings
    /// field at render time; enemies read this directly. Default 0.
    color_index: u32 = 0,
    /// Overlay sprite layers drawn over the base body, each colored
    /// independently. Same 512×640 frame + pivot as the base (no per-layer
    /// dims). Drawn after base, before weapons. See AGENTS → Decorations &
    /// Footprint for the layer model (entities reuse it).
    layers: []const EntityLayer = &.{},

    main_hand_weapon: ?Weapon = null,
    off_hand_weapon: ?Weapon = null,
    amulet: ?Amulet = null,
    coat: ?Coat = null,
    gloves: ?Gloves = null,
    pants: ?Pants = null,
    boots: ?Boots = null,

    equipped_utility_skills: [utility_skill_count]?SkillId = .{null} ** utility_skill_count,
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

    /// Resolve a skill bar slot (1-8) to a SkillId for this entity.
    /// Slots 1-2 are main-hand weapon skills, slot 3 the off-hand weapon
    /// skill, slots 4-8 the equipped utility skills (indices 0-4).
    pub fn skillInSlot(
        self: Entity,
        slot: u8,
        weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
    ) ?SkillId {
        return switch (slot) {
            1 => if (self.main_hand_weapon) |weapon| weapon_type_definitions[@intFromEnum(weapon.weapon_type)].skill_1 else null,
            2 => if (self.main_hand_weapon) |weapon| weapon_type_definitions[@intFromEnum(weapon.weapon_type)].skill_2 else null,
            3 => if (self.off_hand_weapon) |weapon| weapon_type_definitions[@intFromEnum(weapon.weapon_type)].skill_3 else null,
            4, 5, 6, 7, 8 => self.equipped_utility_skills[slot - 4],
            else => null,
        };
    }

    /// All skill bar slots (1-8) collected in order at indices 0-7.
    pub fn collectSkillSlots(
        self: Entity,
        weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
    ) [utility_skill_count + 3]?SkillId {
        var result: [utility_skill_count + 3]?SkillId = undefined;
        for (&result, 0..) |*entry, index| {
            entry.* = self.skillInSlot(@intCast(index + 1), weapon_type_definitions);
        }
        return result;
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

    main_hand_weapon: ?Weapon = null,
    off_hand_weapon: ?Weapon = null,
    amulet: ?Amulet = null,
    coat: ?Coat = null,
    gloves: ?Gloves = null,
    pants: ?Pants = null,
    boots: ?Boots = null,
    inventory: Inventory = .{},
    equipped_utility_skills: [utility_skill_count]?SkillId = .{null} ** utility_skill_count,
};

// A palette entry: a reusable entity definition (the "prefab"). Placements
// reference a type by index into Editor.entity_types. The template is a full
// Entity (reuses the type + deepCopy); runtime fields (current_health,
// is_active, momentum, stun, cooldowns, active_effects, inventory) are
// meaningless on the template and reset by instantiateEditorLevel. Editing
// the template updates every placement referencing this type — no
// propagation sweep.
pub const EntityTypeDef = struct {
    id: []const u8 = &.{}, // user-facing name, e.g. "Skeleton Warrior"
    template: Entity = .{},
};

pub const DecorationTypeDef = struct {
    id: []const u8 = &.{}, // user-facing name / sprite stem
    sprite: []const u8 = &.{},
    // Sprite-grid footprint + pixel dims; see Decoration for semantics.
    footprint: []const Vector2 = &.{},
    pixel_dims: Vector2 = .{ .x = 0, .y = 0 },
    color_index: u32 = 0,
    layers: []const DecorationLayer = &.{},
};

/// A palette entry for a loose ground item (loot not tied to an enemy).
/// The `item` carries the full Item union (weapon/amulet/.../skill_tome)
/// since the union's variety makes per-field granularity impractical — the
/// inspector edits the whole item and pushes one `editor_set_item_def`
/// event per commit. See AGENTS → Architecture → Level Editor → Editor UI
/// layout (Ground Items palette group).
pub const ItemTypeDef = struct {
    id: []const u8 = &.{}, // user-facing name, e.g. "Iron Sword"
    item: Item = .{ .weapon = .{} },
};

/// Which entity-type-like target an entity-edit event applies to. The
/// player loadout (`Editor.player_def`) is an EntityTypeDef too, just not
/// in the `entity_types` array — this union lets the entity-edit events
/// cover both without a parallel `editor_set_player_*` event set. See
/// AGENTS → Architecture → Level Editor → Editor UI layout.
pub const EntityEditTarget = union(enum) {
    entity_type: u32, // index into Editor.entity_types
    player_def: void, // the editor-global player loadout
};

// A reference-based level: placements point into the editor's palette instead
// of carrying full entity/decoration definitions. Serializes back to the
// existing inline level format (see parser.buildLevelFileText). The player
// spawn is the '!' in level_tiles (as in shipped levels); the player loadout
// is editor-global (Editor.player_def), not per-level.
pub const EditorLevel = struct {
    name: []const u8 = &.{},
    color_wheel_index: u32 = 0,
    /// Optional per-level theme override. When non-null, `activeThemeFor`
    /// builds the ActiveColorTheme from this instead of deriving from
    /// `color_wheel_index`. Backward compatible (null on older files). See
    /// AGENTS → Architecture → Level Editor → Editor UI layout.
    custom_theme: ?CustomColorTheme = null,
    level_tiles: []const Vector2 = &.{},
    player_start: Vector2 = .{ .x = 0, .y = 0 }, // the '!' position
    level_end: ?Vector2 = null,
    entity_placements: []const EntityPlacement = &.{},
    decoration_placements: []const DecorationPlacement = &.{},
    /// Loose floor items placed via the Ground Items palette (loot not tied
    /// to an enemy). Mirrors Level.ground_items but reference-based: each
    /// placement points into Editor.item_types. See AGENTS → Architecture →
    /// Level Editor → Editor UI layout (Ground Items palette group).
    item_placements: []const ItemPlacement = &.{},
};

pub const EntityPlacement = struct {
    type_id: u32, // index into Editor.entity_types
    position: Vector2,
};

pub const ItemPlacement = struct {
    type_id: u32, // index into Editor.item_types
    position: Vector2,
};

pub const DecorationPlacement = struct {
    type_id: u32, // index into Editor.decoration_types
    position: Vector2,
};

pub const EditorMode = enum {
    edit, // UI/input = editor; levels array is the source of truth
    playtest, // UI/input = gameplay; current.level is live, editor dormant
    validate, // UI/input = gameplay, forced full-mission; editor dormant
};

pub const Editor = struct {
    mission: Mission = .{}, // metadata + path (the mission being edited)
    levels: []const EditorLevel = &.{}, // all levels, reference-based
    // Palette (editor-global). Derived by dedup on open_editor from the
    // levels' inline definitions; not persisted to disk (unused types are
    // lost on editor close — accepted as cleaner). See AGENTS → Architecture
    // → Level Editor.
    entity_types: []const EntityTypeDef = &.{},
    decoration_types: []const DecorationTypeDef = &.{},
    /// Palette of loose ground-item types (loot not tied to an enemy). See
    /// AGENTS → Architecture → Level Editor → Editor UI layout (Ground Items
    /// palette group).
    item_types: []const ItemTypeDef = &.{},
    // The editor-global player start loadout. Persistent as player.txt in the
    // mission directory (so a recorded validation replay is reproducible and
    // players picking up a custom mission can see the author's loadout).
    player_def: EntityTypeDef = .{},
    active_level_index: usize = 0, // which tab is open
    mode: EditorMode = .edit,
};

pub const ReplayViewer = struct {

};

pub const Campaign = struct {
    name: []const u8 = &.{},
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

pub const TurnPhase = enum {
    player_move,
    player_attack,
};

pub const Level = struct {
    name: []const u8 = &.{},
    color_wheel_index: u32 = 0,
    /// Optional per-level theme override. When non-null, `activeThemeFor`
    /// builds the ActiveColorTheme from this instead of deriving from
    /// `color_wheel_index`. Backward compatible (null on older files).
    custom_theme: ?CustomColorTheme = null,
    level_tiles: []const Vector2 = &.{},
    entities: []const Entity = &.{},
    ground_items: []const GroundItems = &.{},
    decorations: []const Decoration = &.{},
    level_end: ?Vector2 = null,
    highlighted_tiles: []const Vector2 = &.{},
    prepared_skill: ?SkillId = null,
    turn_phase: ?TurnPhase = null,
};

pub const MissionExit = struct {
    mission_id: []const u8,
    position: Vector2,
};

pub const Hub = struct {
    name: []const u8 = &.{},
    color_wheel_index: u32 = 0,
    /// Optional per-hub theme override. Same semantics as Level.custom_theme.
    custom_theme: ?CustomColorTheme = null,
    hub_tiles: []const Vector2 = &.{},
    player: Entity = .{},
    npcs: []const NPC = &.{},
    decorations: []const Decoration = &.{},
    mission_exits: []const MissionExit = &.{},
};

pub const NPC = struct {
    entity: Entity,
};

// ============================================================
// View state — output of view(), input to renderer
// ============================================================

/// Fixed reference resolution. The view function produces coordinates
/// in this space; the renderer scales to the actual viewport.
pub const reference_width: i32 = 3840;
pub const reference_height: i32 = 2160;

/// Screen-space position in the reference resolution coordinate system.
/// Integer because we work in a fixed logical resolution.
pub const ScreenPosition = struct {
    x: i32,
    y: i32,
};

/// Horizontal or vertical alignment of a child within a parent.
pub const Align = enum { start, center, end };

/// Axis-aligned rectangle in screen space.
///
/// Layout is expressed by deriving new rectangles from existing ones:
/// shrink a panel to its content area with `inset`, slide a group with
/// `translate`, and drop a fixed-size child into a region with the
/// `place*` family (a 3\u00d73 grid of named anchors). Every method is pure
/// — it returns a new value and never mutates the receiver.
pub const Rectangle = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    // -- derived coordinates --

    pub fn position(self: Rectangle) ScreenPosition {
        return .{ .x = self.x, .y = self.y };
    }
    pub fn right(self: Rectangle) i32 {
        return self.x + self.width;
    }
    pub fn bottom(self: Rectangle) i32 {
        return self.y + self.height;
    }
    pub fn centerX(self: Rectangle) i32 {
        return self.x + @divTrunc(self.width, 2);
    }
    pub fn centerY(self: Rectangle) i32 {
        return self.y + @divTrunc(self.height, 2);
    }
    /// True when `point` lies inside the rectangle. Right/bottom edges are
    /// exclusive, matching the hit-testing convention used elsewhere.
    pub fn contains(self: Rectangle, point: ScreenPosition) bool {
        return point.x >= self.x and point.x < self.right() and
            point.y >= self.y and point.y < self.bottom();
    }

    // -- transforms --

    /// Slide the rectangle by an offset (used to scroll a group as one).
    pub fn translate(self: Rectangle, delta_x: i32, delta_y: i32) Rectangle {
        return .{ .x = self.x + delta_x, .y = self.y + delta_y, .width = self.width, .height = self.height };
    }

    /// Shrink inward on all four sides (e.g. panel border \u2192 content area).
    pub fn inset(self: Rectangle, amount: i32) Rectangle {
        return .{
            .x = self.x + amount,
            .y = self.y + amount,
            .width = self.width - 2 * amount,
            .height = self.height - 2 * amount,
        };
    }

    // -- child placement (3\u00d73 named anchors) --
    // Each drops a `child_width`\u00d7`child_height` box inside self at the
    // named anchor. `margin` insets from whichever edges are used; the
    // center axis ignores it.

    fn placeChild(
        self: Rectangle,
        child_width: i32,
        child_height: i32,
        horizontal: Align,
        vertical: Align,
        margin: i32,
    ) Rectangle {
        const x = switch (horizontal) {
            .start => self.x + margin,
            .center => self.x + @divTrunc(self.width - child_width, 2),
            .end => self.right() - child_width - margin,
        };
        const y = switch (vertical) {
            .start => self.y + margin,
            .center => self.y + @divTrunc(self.height - child_height, 2),
            .end => self.bottom() - child_height - margin,
        };
        return .{ .x = x, .y = y, .width = child_width, .height = child_height };
    }

    pub fn placeTopLeft(self: Rectangle, w: i32, h: i32, margin: i32) Rectangle {
        return self.placeChild(w, h, .start, .start, margin);
    }
    pub fn placeTopCenter(self: Rectangle, w: i32, h: i32, margin: i32) Rectangle {
        return self.placeChild(w, h, .center, .start, margin);
    }
    pub fn placeTopRight(self: Rectangle, w: i32, h: i32, margin: i32) Rectangle {
        return self.placeChild(w, h, .end, .start, margin);
    }
    pub fn placeCenterLeft(self: Rectangle, w: i32, h: i32, margin: i32) Rectangle {
        return self.placeChild(w, h, .start, .center, margin);
    }
    pub fn placeCenter(self: Rectangle, w: i32, h: i32) Rectangle {
        return self.placeChild(w, h, .center, .center, 0);
    }
    pub fn placeCenterRight(self: Rectangle, w: i32, h: i32, margin: i32) Rectangle {
        return self.placeChild(w, h, .end, .center, margin);
    }
    pub fn placeBottomLeft(self: Rectangle, w: i32, h: i32, margin: i32) Rectangle {
        return self.placeChild(w, h, .start, .end, margin);
    }
    pub fn placeBottomCenter(self: Rectangle, w: i32, h: i32, margin: i32) Rectangle {
        return self.placeChild(w, h, .center, .end, margin);
    }
    pub fn placeBottomRight(self: Rectangle, w: i32, h: i32, margin: i32) Rectangle {
        return self.placeChild(w, h, .end, .end, margin);
    }
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
    /// Mirror the sprite left-right when drawn. Used for off-hand weapons: the
    /// weapon art is authored on the left (main hand); flipping puts it on the
    /// right for the off hand.
    flip_horizontal: bool = false,
};

pub const HealthBarDrawable = struct {
    screen_position: ScreenPosition,
    width: i32,
    height: i32,
    /// 0 = empty, 1 = full. `current_health / max_health`.
    fill_fraction: f32,
    /// Depleted portion (the background drawn full). Global theme darkest.
    depleted_color: Color,
    /// Filled portion. Team gradient index 1 (player → player gradient,
    /// enemy → enemy gradient).
    fill_color: Color,
};

pub const EntityDrawable = struct {
    back_effect_sprites: []const SpriteDrawable,
    base_sprite: SpriteDrawable,
    /// Overlay body layers (armor/clothing), drawn after base, before weapons.
    /// Each colored independently. See AGENTS → Decorations & Footprint.
    layer_sprites: []const SpriteDrawable,
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
    /// Overlay layer chunks drawn over the base at the same position + source
    /// rect, each with its own sprite + color. Empty for single-sprite
    /// decorations. Drawn in slice order (base first, then layers).
    layers: []const SpriteDrawable = &.{},
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
    /// Tint for the animated banner overlay (drawn over the pole). The pole
    /// and banner are colored independently — pole = world gradient index 5,
    /// banner = index 0 (see AGENTS → Decorations & Footprint / flag pole).
    banner_color: Color = .{ .r = 255, .g = 255, .b = 255 },
    /// Source rectangle for the animated banner overlay (`world/flag`), or
    /// null when there is no banner (keeps the drawable backward-compatible).
    /// The banner is drawn over the pole at the same screen position + pivot;
    /// each frame is 256x512, advanced at `settings.animation_fps`. Computed
    /// in view() from `session.animation_clock` (looping anim — no per-instance
    /// state). See AGENTS → Animation.
    banner_source_rectangle: ?Rectangle = null,
};

pub const GroundDrawable = union(enum) {
    entity: EntityDrawable,
    decoration_piece: DecorationPieceDrawable,
    ground_items: GroundItemDrawable,
    level_end: LevelEndDrawable,
};

// -- Layer 3.5: World overlays (floating indicators above world sprites) --

/// A one-shot sprite animation tied to a gameplay moment (see AGENTS →
/// Animation). `event_index` is the index of the triggering event in
/// `event_history` (stored as `current_event_index - 1` at push time, since
/// `processEvent` increments before dispatch). `duration_us` is the display
/// duration in microseconds; `frame()` stamps `end_clock` when it moves the
/// anim from the pending queue to the active list. The kind carries the
/// payload `view()` needs to place and draw it.
/// The opaque-pixel bounding box of a sprite, in SOURCE pixels (0-based from
/// the top-left). Each edge is the coordinate of the outermost non-transparent
/// pixel on that side, or null if the sprite can't be loaded/decoded or is
/// fully transparent (the caller falls back to the frame edge). Lazily decoded
/// + cached in the backend, threaded through `RenderContext.sprite_bounds` so
/// `view()` can place overlays against an entity's actual rendered art
/// (skill icon above the top, hit flash at the vertical center, damage number
/// at a corner). See AGENTS → Animation.
pub const SpriteBounds = struct {
    top: ?i32,
    bottom: ?i32,
    left: ?i32,
    right: ?i32,
};

pub const AnimKind = union(enum) {
    /// Show a skill's icon above the casting entity for `duration_us`.
    skill_icon: struct { entity_index: u32, skill_id: SkillId },
    /// Flash the hit sprite centered on a damaged entity's rendered art
    /// for `duration_us`. Triggered by `attack`/`collision` only when the
    /// defender takes nonzero damage. See AGENTS → Animation.
    hit_flash: struct { entity_index: u32 },
    /// Float a damage number away from the defender's sprite, in the
    /// normalized attacker→defender direction (one of 8), starting from the
    /// bbox edge/corner nearest that direction and traveling 1 tile with
    /// ease-out. `value` is the incoming damage dealt (may be 0 — a
    /// fully-absorbed hit still renders a "0" so the connection is
    /// observable; only the hit flash is gated on > 0). Triggered by
    /// `attack`/`collision`. Per-entity staggered (0.125s gap) so
    /// same-entity multi-hits (e.g. Bash's attack+collision) don't
    /// overlap. See AGENTS → Animation.
    damage_number: struct {
        entity_index: u32,
        value: u32,
        /// Unit vector (-1/0/1 per axis) the number travels along.
        direction: Vector2,
    },
    /// Show the aggro indicator above an entity's head for `duration_us`
    /// when it gets aggroed (its `is_active` flips true in the `aggro_around`
    /// handler). Placed above the health bar like the skill icon, tinted with
    /// the active theme's `lightest`. See AGENTS → Animation.
    aggro_indicator: struct { entity_index: u32 },
    /// Float a heal number (`+value`) up-right from the entity's top-left
    /// bbox corner, traveling 1 tile with ease-out. Heals have no attacker,
    /// so the direction is fixed. Triggered by the `heal` event. Shares the
    /// per-entity stagger queue with damage numbers. See AGENTS → Animation.
    heal_number: struct { entity_index: u32, value: u32 },
};

/// A pending one-shot anim pushed by an event handler (gated `!replaying`,
/// same convention as `pending_sounds`). `frame()` drains the pending queue
/// after the update drain, stamps `end_clock = animation_clock + duration_us`,
/// and appends to `active_anims`. See AGENTS → Animation / Audio.
pub const PendingAnim = struct {
    event_index: u32,
    kind: AnimKind,
    duration_us: u32,
};

/// An active one-shot anim. `view()` shows it when `event_index <
/// current_event_index` (the triggering event is in the projected history —
/// same exclusive bound the combat log uses, so undo hides it) AND
/// `animation_clock < end_clock` (not yet elapsed) AND `animation_clock >=
/// start_clock` (a staggered number anim hasn't started yet → invisible).
/// No explicit clearing: elapsed anims are gated out by time, undone anims
/// by index; a screen/world transition clears the whole list (see AGENTS →
/// Animation). `start_clock` is the session-relative microsecond the anim
/// begins visibly advancing; for non-staggered anims it equals
/// `end_clock - duration_us` (starts immediately).
pub const ActiveAnim = struct {
    event_index: u32,
    kind: AnimKind,
    start_clock: u64,
    end_clock: u64,
};

/// A floating icon drawn above world sprites, after ground drawables and
/// before the UI. The `screen_position` is the top-left in reference world
/// space (camera + zoom already applied); the renderer scales `size` by
/// `world_scale`.
pub const FloatingIconDrawable = struct {
    sprite_id: []const u8,
    screen_position: ScreenPosition,
    /// Square edge length in reference-world pixels; multiplied by
    /// `world_scale` at draw time.
    size: i32,
    color: Color,
};

pub const WorldOverlayDrawable = union(enum) {
    floating_icon: FloatingIconDrawable,
    /// Floating text (damage/heal numbers). The `screen_position` is the
    /// top-left of the text's drawn bbox in reference world space (camera +
    /// zoom already applied). The renderer draws a black edge-outline band
    /// (dilation of a rasterized string, same machinery as sprite outlines)
    /// under the fill text so it reads over any art. `font_size` is the
    /// native reference font size; `world_scale` scales it at draw time.
    floating_text: struct {
        text: []const u8,
        screen_position: ScreenPosition,
        font_size: i32,
        color: Color,
    },
};

// -- Layer 4+5: UI elements --
// UI is a flat list of UiElement from ui.zig, sorted back to front.
// The view function builds and flattens the full UI layout.
// Options menu elements are included at the end when open.

// -- Top-level view state --

pub const ViewState = struct {
    background_color: Color,
    active_color_theme: ActiveColorTheme,
    /// Multiplier applied by the renderer to world sprite sizes (tiles, ground
    /// drawables, overlays), which are drawn at native texture size x this.
    /// Equals the camera zoom; world screen_positions already bake it in. UI
    /// elements are unaffected (they carry explicit reference-space sizes).
    world_scale: f32,
    tiles: []const TileDrawable,
    tile_overlays: []const TileOverlayDrawable,
    ground_drawables: []const GroundDrawable,
    /// Floating indicators (one-shot anims) drawn above world sprites, after
    /// ground drawables and before the UI. Built per-frame from
    /// `session.active_anims`; see AGENTS → Animation.
    world_overlays: []const WorldOverlayDrawable,
    ui_elements: []const @import("ui.zig").UiElement,
    /// Chronological combat-log projection of the current level's events up to
    /// the current position (empty outside a level). Built per-frame in the
    /// frame arena; the UI renders it (top-bar coarse recent + detailed log).
    combat_log: []const @import("events.zig").Event,
};

