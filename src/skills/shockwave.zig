const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");
const skill_mod = @import("skill.zig");
const helpers = @import("helpers.zig");

const Vector2 = types.Vector2;
const GameState = state.GameState;
const Event = events.Event;
const Skill = skill_mod.Skill;

/// Shockwave: a spell. Attacks every hostile within radius of the caster
/// for 1x effective spell damage, then knocks each back — +0.5x effective
/// spell damage on collision. Bash's attack+knockback pair, AoE'd.
/// Self-centered — not targeted.
pub const skill = Skill{
    .name = "Shockwave",
    .skill_type = .spell,
    .deals_damage = true,
    .description = "Attack and knockback each target within radius, dealing +0.5x damage on collision",
    .uses_targeting = false,
    .range = null,
    .radius = 1,
    .distance = 2,
    .skill_duration = null,
    .stun_duration = null,
    .cooldown = 5,
    .get_valid_targets_fn = &getValidTargets,
    .ai_options_fn = &aiOptions,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

/// Self-centered — no targeting.
fn getValidTargets(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Vector2 {
    return null;
}

/// AI options: one self-centered cast on the stacked-bump ladder
/// (helpers.aoeKnockbackPriority) — 3 single open-field target, +1 for a
/// cluster, +1 for any collision.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.shockwave) > 0) return &.{};

    const radius: i32 = @intCast(caster.getEffectiveRadius(skill.radius.?));
    const push_distance = caster.getEffectiveDistance(skill.distance.?);
    const target_count = helpers.hostileCountWithinRadius(caster_index, game_state, caster.position, radius);
    if (target_count == 0) return &.{};
    const colliding_count = helpers.collidingTargetCount(caster_index, game_state, caster.position, radius, push_distance);
    return helpers.singleOption(allocator, .{
        .target = null,
        .priority = helpers.aoeKnockbackPriority(target_count, colliding_count, 3),
    });
}

/// Self-centered — fires immediately.
fn playerPrepareSkill(_: u32, _: GameState, _: std.mem.Allocator) ?Event {
    return null;
}

/// Use: per hostile in radius, attack for 1x effective spell damage then
/// knock back (+0.5x effective spell damage on collision). The knockback
/// handler no-ops on dead defenders, so a killing attack doesn't push a
/// corpse.
fn useSkill(
    caster_index: u32,
    _: ?Vector2,
    game_state: GameState,
    allocator: std.mem.Allocator,
) []const Event {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];

    const radius: i32 = @intCast(caster.getEffectiveRadius(skill.radius.?));
    const target_indices = helpers.hostileIndicesInRadius(caster_index, game_state, caster.position, radius, allocator);
    if (target_indices.len == 0) return &.{};

    const damage = caster.getEffectiveSpellDamage();
    const collision_damage = damage / 2; // +0.5x effective spell damage
    const push_distance = caster.getEffectiveDistance(skill.distance.?);

    var skill_events: std.ArrayList(Event) = .empty;
    for (target_indices) |defender_index| {
        skill_events.append(allocator, .{ .sub_level_event = .{ .attack = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .outgoing_damage = damage,
        } } }) catch @panic("failed to append attack event");
        skill_events.append(allocator, .{ .sub_level_event = .{ .knockback = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .distance = push_distance,
            .knockback_damage = collision_damage,
        } } }) catch @panic("failed to append knockback event");
    }

    return helpers.ownedEvents(allocator, skill_events.items);
}
