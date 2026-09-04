const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");
const functions = @import("../functions.zig");
const skill_mod = @import("../skill.zig");
const helpers = @import("../skill_helpers.zig");

const Vector2 = types.Vector2;
const GameState = state.GameState;
const Event = events.Event;
const Skill = skill_mod.Skill;

/// Swap: a cantrip. Swaps positions with a target within range. Non-turn-ending.
pub const skill = Skill{
    .name = "Swap",
    .skill_type = .cantrip,
    .deals_damage = false,
    .description = "Swap positions with target",
    .uses_targeting = true,
    .range = 3,
    .radius = null,
    .distance = null,
    .skill_duration = null,
    .stun_duration = null,
    .cooldown = 3,
    .get_valid_targets_fn = &getValidTargets,
    .ai_options_fn = &aiOptions,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

fn getValidTargets(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?[]const Vector2 {
    const caster = (game_state.level orelse return null).entities[caster_index];
    const range: i32 = @intCast(caster.getEffectiveRange(skill.range.?));
    return helpers.hostilesInRange(caster_index, game_state, range, allocator);
}

/// AI options: the NEAREST hostile (not focus-fire — swapping with the
/// nearest enemy is the sensible tactical read; helpers.nearestTarget) at
/// rating 1.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.swap) > 0) return &.{};

    const valid_targets = getValidTargets(caster_index, game_state, allocator);
    const target = helpers.nearestTarget(caster_index, valid_targets, game_state) orelse return &.{};
    return helpers.singleOption(allocator, .{ .target = target, .priority = 1 });
}

fn playerPrepareSkill(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?Event {
    return helpers.highlightTargets(getValidTargets(caster_index, game_state, allocator));
}

/// Use: swap positions with the target entity.
fn useSkill(
    caster_index: u32,
    target: ?Vector2,
    game_state: GameState,
    allocator: std.mem.Allocator,
) []const Event {
    const target_position = target orelse return &.{};
    const defender_index = helpers.hostileEntityAt(caster_index, target_position, game_state) orelse return &.{};

    return helpers.ownedEvents(allocator, &.{
        .{ .sub_level_event = .{ .swap_positions = .{
            .entity_a_index = caster_index,
            .entity_b_index = defender_index,
        } } },
    });
}
