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

/// Spinblade: a main-hand AoE skill. Attacks every hostile within radius of the
/// caster. Self-centered — not targeted.
pub const skill = Skill{
    .name = "Spinblade",
    .skill_type = .weapon_skill,
    .deals_damage = true,
    .description = "Attack each target within radius",
    .uses_targeting = false,
    .range = null,
    .radius = 1,
    .distance = null,
    .skill_duration = null,
    .stun_duration = null,
    .cooldown = 2,
    .get_valid_targets_fn = &getValidTargets,
    .priority_fn = &priority,
    .select_target_fn = &selectTarget,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

/// Self-centered — no target selection.
fn getValidTargets(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Vector2 {
    return null;
}

/// AI priority: the AoE bump convention (helpers.aoePriority) — 0 with no
/// hostile within radius, 3 with one, 4 with two or more.
fn priority(caster_index: u32, game_state: GameState, _: types.WeaponTypeDefinitions) u32 {
    const level = game_state.level orelse return 0;
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.spinblade) > 0) return 0;

    const radius: i32 = @intCast(caster.getEffectiveRadius(skill.radius.?));
    const target_count = helpers.hostileCountWithinRadius(caster_index, game_state, caster.position, radius);
    return helpers.aoePriority(target_count, 3);
}

/// Self-centered — no meaningful target.
fn selectTarget(_: u32, _: ?[]const Vector2, _: GameState) ?Vector2 {
    return null;
}

/// Self-centered — fires immediately, no highlight step.
fn playerPrepareSkill(_: u32, _: GameState, _: std.mem.Allocator) ?Event {
    return null;
}

/// Use: attack every hostile within radius of the caster.
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
    const damage = caster.getEffectiveOutgoingDamage(main_hand_damage);

    var skill_events: std.ArrayList(Event) = .empty;
    for (target_indices) |defender_index| {
        skill_events.append(allocator, .{ .sub_level_event = .{ .attack = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .outgoing_damage = damage,
        } } }) catch @panic("failed to append attack event");
    }

    return helpers.ownedEvents(allocator, skill_events.items);
}
