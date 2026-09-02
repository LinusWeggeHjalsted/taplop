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
    .deals_damage = false,
    .description = "Stun target and remove all momentum from them",
    .uses_targeting = true,
    .range = 3,
    .radius = null,
    .distance = null,
    .skill_duration = null,
    .stun_duration = 1,
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

/// AI priority: Daze deals no damage, so its value is control only.
/// 3 if any in-range target is unstunned (the stun pays in full — stuns
/// take the max, never stack). 2 if all in-range targets are stunned but
/// one still has momentum (the drain still pays). 0 otherwise — a stunned,
/// momentumless target gains nothing from Daze.
/// AI options: unstunned hostiles in range at 3 (the stun pays in full —
/// stuns take the max, never stack); if none, stunned hostiles still
/// carrying momentum at 2 (the drain still pays). A stunned, momentumless
/// target offers nothing and emits no option. Within a class the
/// focus-fire tail order applies (health, distance, entity index).
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.daze) > 0) return &.{};
    const range: i32 = @intCast(caster.getEffectiveRange(skill.range.?));

    var best_unstunned: ?u32 = null;
    var best_unstunned_health: u32 = std.math.maxInt(u32);
    var best_unstunned_distance: i32 = std.math.maxInt(i32);
    var best_momentful: ?u32 = null;
    var best_momentful_health: u32 = std.math.maxInt(u32);
    var best_momentful_distance: i32 = std.math.maxInt(i32);
    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.current_health == 0) continue;
        if (entity.team == caster.team) continue;
        const distance = functions.chebyshevDistance(caster.position, entity.position);
        if (distance > range) continue;
        const entity_index_u32: u32 = @intCast(entity_index);
        if (entity.stun_duration == 0) {
            if (entity.current_health < best_unstunned_health or
                (entity.current_health == best_unstunned_health and distance < best_unstunned_distance))
            {
                best_unstunned_health = entity.current_health;
                best_unstunned_distance = distance;
                best_unstunned = entity_index_u32;
            }
        } else if (entity.momentum > 0) {
            if (entity.current_health < best_momentful_health or
                (entity.current_health == best_momentful_health and distance < best_momentful_distance))
            {
                best_momentful_health = entity.current_health;
                best_momentful_distance = distance;
                best_momentful = entity_index_u32;
            }
        }
    }

    if (best_unstunned) |defender_index| {
        return helpers.singleOption(allocator, .{ .target = level.entities[defender_index].position, .priority = 3 });
    }
    if (best_momentful) |defender_index| {
        return helpers.singleOption(allocator, .{ .target = level.entities[defender_index].position, .priority = 2 });
    }
    return &.{};
}

/// AI target selection for the stun: prefer an unstunned target, then the
/// focus-fire order (helpers.stunTarget).
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
