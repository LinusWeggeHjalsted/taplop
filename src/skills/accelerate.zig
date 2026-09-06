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

/// Accelerate: a cantrip. Gains 2 momentum for each enemy within radius of
/// the caster. Self-centered, non-turn-ending, deals no damage (momentum
/// is a rider stat — its damage conversion is log2-sublinear).
pub const skill = Skill{
    .name = "Accelerate",
    .skill_type = .cantrip,
    .deals_damage = false,
    .description = "Gain 2 momentum for each enemy within radius",
    .uses_targeting = false,
    .range = null,
    .radius = 3,
    .distance = null,
    .skill_duration = null,
    .stun_duration = null,
    .cooldown = 3,
    .get_valid_targets_fn = &getValidTargets,
    .ai_options_fn = &aiOptions,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

/// Self-centered — no targeting.
fn getValidTargets(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Vector2 {
    return null;
}

/// AI options: one self-centered cast, rated = the enemy count (a direct
/// count per the author's call — the cantrip pool's ratings only order
/// the non-ending skills, all worthwhile ones fire regardless). No option
/// with no enemy in radius.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.accelerate) > 0) return &.{};

    const radius: i32 = @intCast(caster.getEffectiveRadius(skill.radius.?));
    const enemy_count = helpers.hostileCountWithinRadius(caster_index, game_state, caster.position, radius);
    if (enemy_count == 0) return &.{};
    return helpers.singleOption(allocator, .{ .target = null, .priority = enemy_count });
}

/// Self-centered — fires immediately.
fn playerPrepareSkill(_: u32, _: GameState, _: std.mem.Allocator) ?Event {
    return null;
}

/// Use: gain 2 momentum per enemy within radius (one change_momentum of
/// twice the counted amount; the use_skill handler's universal +1 lands
/// on top).
fn useSkill(
    caster_index: u32,
    _: ?Vector2,
    game_state: GameState,
    allocator: std.mem.Allocator,
) []const Event {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];

    const radius: i32 = @intCast(caster.getEffectiveRadius(skill.radius.?));
    const enemy_count = helpers.hostileCountWithinRadius(caster_index, game_state, caster.position, radius);
    if (enemy_count == 0) return &.{};

    return helpers.ownedEvents(allocator, &.{
        .{ .sub_level_event = .{ .change_momentum = .{
            .entity_index = caster_index,
            .delta = @intCast(enemy_count * 2),
        } } },
    });
}
