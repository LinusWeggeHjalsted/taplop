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

/// Blitz: an off-hand AoE skill. Attacks and stuns every hostile within radius
/// of the caster. Self-centered — not targeted.
pub const skill = Skill{
    .name = "Blitz",
    .skill_type = .weapon_skill,
    .deals_damage = true,
    .point_blank_area_of_effect = true,
    .description = "Attack and stun each target within radius",
    .uses_targeting = false,
    .range = null,
    .radius = 1,
    .distance = null,
    .skill_duration = null,
    .stun_duration = 1,
    .cooldown = 5,
    .get_valid_targets_fn = &getValidTargets,
    .ai_options_fn = &aiOptions,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

/// Self-centered — no target selection.
fn getValidTargets(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Vector2 {
    return null;
}

/// AI options: one self-centered cast in value units — 1 per target hit
/// + 1 per target the stun actually pays on (unstunned; stuns take the
/// max, never stack): rating = count + unstunned count.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.blitz) > 0) return &.{};

    const radius: i32 = @intCast(caster.getEffectiveRadius(skill.radius.?));
    var target_count: u32 = 0;
    var unstunned_count: u32 = 0;
    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.current_health == 0) continue;
        if (entity.team == caster.team) continue;
        if (functions.chebyshevDistance(caster.position, entity.position) > radius) continue;
        target_count += 1;
        if (entity.stun_duration == 0) unstunned_count += 1;
    }
    if (target_count == 0) return &.{};
    return helpers.singleOption(allocator, .{ .target = null, .priority = target_count + unstunned_count });
}

/// Self-centered — fires immediately, no highlight step.
fn playerPrepareSkill(_: u32, _: GameState, _: std.mem.Allocator) ?Event {
    return null;
}

/// Use: attack and stun every hostile within radius of the caster.
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

    const off_hand_damage: u32 = if (caster.off_hand_weapon) |weapon| weapon.weapon_damage else 0;
    const damage = caster.getEffectiveOutgoingDamage(off_hand_damage);
    const stun_duration = caster.getEffectiveOutgoingStunDuration(skill.stun_duration.?);

    var skill_events: std.ArrayList(Event) = .empty;
    for (target_indices) |defender_index| {
        skill_events.append(allocator, .{ .sub_level_event = .{ .attack = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .outgoing_damage = damage,
        } } }) catch @panic("failed to append attack event");
        skill_events.append(allocator, .{ .sub_level_event = .{ .stun = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .stun_duration = stun_duration,
        } } }) catch @panic("failed to append stun event");
    }

    return helpers.ownedEvents(allocator, skill_events.items);
}
