const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");
const skill_mod = @import("../skill.zig");
const helpers = @import("../skill_helpers.zig");

const Vector2 = types.Vector2;
const GameState = state.GameState;
const Event = events.Event;
const Skill = skill_mod.Skill;

/// Focus: a cantrip. Resets each equipped weapon-skill cooldown. Self-cast,
/// non-turn-ending.
pub const skill = Skill{
    .name = "Focus",
    .skill_type = .cantrip,
    .deals_damage = false,
    .description = "Reset each equipped weapon skill cooldown",
    .uses_targeting = false,
    .range = null,
    .radius = null,
    .distance = null,
    .skill_duration = null,
    .stun_duration = null,
    .cooldown = 10,
    .get_valid_targets_fn = &getValidTargets,
    .ai_options_fn = &aiOptions,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

/// Self-cast — no targeting.
fn getValidTargets(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Vector2 {
    return null;
}

/// AI options: one self-cast rated by the RESET COUNT — the number of
/// ticking cooldowns among slots 1-3 (the same skillInSlot resolution the
/// reset_weapon_cooldowns handler resets; a ticking cantrip alone offers
/// nothing). Rate = reset count mirrors the meditate/adrenaline convention.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
    _: *skill_mod.EvalFrame,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.focus) > 0) return &.{};
    var reset_count: u32 = 0;
    var slot: u8 = 1;
    while (slot <= 3) : (slot += 1) {
        const skill_id = caster.skillInSlot(slot, weapon_type_definitions) orelse continue;
        if (caster.skill_cooldowns.get(skill_id) > 0) reset_count += 1;
    }
    if (reset_count == 0) return &.{};
    return helpers.singleOption(allocator, .{ .target = null, .priority = reset_count });
}

/// Self-cast — no meaningful target.
/// Self-cast — fires immediately.
fn playerPrepareSkill(_: u32, _: GameState, _: std.mem.Allocator) ?Event {
    return null;
}

/// Use: reset the caster's equipped weapon-skill cooldowns (the handler
/// resolves the weapon skills and emits a change_cooldown per skill).
fn useSkill(
    caster_index: u32,
    _: ?Vector2,
    _: GameState,
    allocator: std.mem.Allocator,
) []const Event {
    return helpers.ownedEvents(allocator, &.{
        .{ .sub_level_event = .{ .reset_weapon_cooldowns = .{
            .entity_index = caster_index,
        } } },
    });
}
