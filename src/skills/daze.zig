const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");
const functions = @import("../functions.zig");
const skill_mod = @import("skill.zig");
const helpers = @import("helpers.zig");

const Vector2 = types.Vector2;
const GameState = state.GameState;
const Event = events.Event;
const Skill = skill_mod.Skill;

/// Daze: a main-hand ranged skill. Stuns a single target and removes all of
/// its momentum. Deals no damage.
pub const skill = Skill{
    .name = "Daze",
    .skill_type = .weapon_skill,
    .description = "Stun target and remove all momentum from them",
    .uses_targeting = true,
    .range = 3,
    .radius = null,
    .distance = null,
    .skill_duration = null,
    .stun_duration = 1,
    .cooldown = 3,
    .get_valid_targets_fn = &getValidTargets,
    .priority_fn = &priority,
    .select_target_fn = &selectTarget,
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

/// AI priority: 0 if on cooldown or no target in range, else 3.
fn priority(caster_index: u32, game_state: GameState) u32 {
    const level = game_state.level orelse return 0;
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.daze) > 0) return 0;

    const range: i32 = @intCast(caster.getEffectiveRange(skill.range.?));
    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.current_health == 0) continue;
        if (entity.team == caster.team) continue;
        if (functions.chebyshevDistance(caster.position, entity.position) <= range) return 3;
    }
    return 0;
}

fn selectTarget(
    caster_index: u32,
    valid_targets: ?[]const Vector2,
    game_state: GameState,
) ?Vector2 {
    return helpers.nearestTarget(caster_index, valid_targets, game_state);
}

fn playerPrepareSkill(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?Event {
    return helpers.highlightTargets(getValidTargets(caster_index, game_state, allocator));
}

/// Use: stun the target and remove all of its momentum. No attack.
fn useSkill(
    caster_index: u32,
    target: ?Vector2,
    game_state: GameState,
    allocator: std.mem.Allocator,
) []const Event {
    const target_position = target orelse return &.{};
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];

    const defender_index = helpers.hostileEntityAt(caster_index, target_position, game_state) orelse return &.{};
    const defender = level.entities[defender_index];

    const stun_duration = caster.getEffectiveOutgoingStunDuration(skill.stun_duration.?);
    // Remove all momentum: negative delta equal to the target's current amount.
    const momentum_delta: i32 = -@as(i32, @intCast(defender.momentum));

    return helpers.ownedEvents(allocator, &.{
        .{ .sub_level_event = .{ .stun = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .stun_duration = stun_duration,
        } } },
        .{ .sub_level_event = .{ .change_momentum = .{
            .entity_index = defender_index,
            .delta = momentum_delta,
        } } },
    });
}
