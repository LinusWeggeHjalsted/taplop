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

/// Slam: a main-hand AoE skill. Knocks back and stuns every hostile within
/// radius of the caster, dealing 1x main-hand damage on collision.
/// Self-centered — not targeted.
pub const skill = Skill{
    .name = "Slam",
    .skill_type = .weapon_skill,
    .deals_damage = true,
    .description = "Knockback and stun each target within radius, dealing 1x damage to targets on collision",
    .uses_targeting = false,
    .range = null,
    .radius = 1,
    .distance = 2,
    .skill_duration = null,
    .stun_duration = 1,
    .cooldown = 3,
    .get_valid_targets_fn = &getValidTargets,
    .ai_options_fn = &aiOptions,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

/// Self-centered — no target selection.
fn getValidTargets(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Vector2 {
    return null;
}

/// AI priority: the AoE bump convention (helpers.aoePriority) — 0 with no
/// hostile within radius, 3 with one, 4 with two or more.
/// AI options: one self-centered cast, rated by the AoE bump convention
/// (helpers.aoePriority over the hostile count in radius) — 3 with one
/// target, 4 with two or more.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.slam) > 0) return &.{};
    const radius: i32 = @intCast(caster.getEffectiveRadius(skill.radius.?));
    const target_count = helpers.hostileCountWithinRadius(caster_index, game_state, caster.position, radius);
    if (target_count == 0) return &.{};
    return helpers.singleOption(allocator, .{ .target = null, .priority = helpers.aoePriority(target_count, 3) });
}

/// Self-centered — no meaningful target.
/// Self-centered — fires immediately, no highlight step.
fn playerPrepareSkill(_: u32, _: GameState, _: std.mem.Allocator) ?Event {
    return null;
}

/// Use: knock back and stun every hostile within radius. Knockback is away
/// from the caster (the handler derives direction from attacker->defender);
/// collision damage is a raw 1x main-hand, applied by the handler on collision.
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

    const main_hand_damage: u32 = if (caster.main_hand_weapon) |weapon| weapon.weapon_damage else 0;
    // Collision damage uses the effective outgoing damage (gloves +
    // converted momentum + outgoing effects), same as an `attack` would —
    // unifying collision and attack damage on one outgoing pipeline.
    const collision_damage = caster.getEffectiveOutgoingDamage(main_hand_damage);
    const push_distance = caster.getEffectiveDistance(skill.distance.?);
    const stun_duration = caster.getEffectiveOutgoingStunDuration(skill.stun_duration.?);

    var skill_events: std.ArrayList(Event) = .empty;
    for (target_indices) |defender_index| {
        skill_events.append(allocator, .{ .sub_level_event = .{ .knockback = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .distance = push_distance,
            .knockback_damage = collision_damage,
        } } }) catch @panic("failed to append knockback event");
        skill_events.append(allocator, .{ .sub_level_event = .{ .stun = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .stun_duration = stun_duration,
        } } }) catch @panic("failed to append stun event");
    }

    return helpers.ownedEvents(allocator, skill_events.items);
}
