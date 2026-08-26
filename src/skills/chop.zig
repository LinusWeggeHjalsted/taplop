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

/// Chop: a basic sword skill.
/// Attacks a single target within range.
/// Deals 1.5x main hand damage if the CASTER is above half health.
pub const skill = Skill{
    .name = "Chop",
    .skill_type = .weapon_skill,
    .description = "Attack target, dealing 1.5x damage if you have more than half health",
    .uses_targeting = true,
    .range = 1,
    .radius = null,
    .distance = null,
    .skill_duration = null,
    .stun_duration = null,
    .cooldown = null,
    .get_valid_targets_fn = &getValidTargets,
    .priority_fn = &priority,
    .select_target_fn = &selectTarget,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

/// Positions of all hostile entities within range of the caster.
fn getValidTargets(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?[]const Vector2 {
    const caster = (game_state.level orelse return null).entities[caster_index];
    const range: i32 = @intCast(caster.getEffectiveRange(skill.range.?));
    return helpers.hostilesInRange(caster_index, game_state, range, allocator);
}

/// AI priority: 0 if on cooldown or no targets in range. Otherwise keyed on the
/// caster's own health (Chop's 1.5x bonus applies while above half health):
/// 3 if the caster is above half health, else 2.
fn priority(caster_index: u32, game_state: GameState) u32 {
    const level = game_state.level orelse return 0;
    const caster = level.entities[caster_index];

    if (caster.skill_cooldowns.get(.chop) > 0) return 0;

    const range: i32 = @intCast(caster.getEffectiveRange(skill.range.?));

    var found_target = false;
    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.current_health == 0) continue;
        if (entity.team == caster.team) continue;
        if (functions.chebyshevDistance(caster.position, entity.position) <= range) {
            found_target = true;
            break;
        }
    }

    if (!found_target) return 0;
    if (caster.current_health * 2 > caster.getEffectiveMaxHealth()) return 3;
    return 2;
}

/// AI target selection: nearest hostile from valid targets.
fn selectTarget(
    caster_index: u32,
    valid_targets: ?[]const Vector2,
    game_state: GameState,
) ?Vector2 {
    return helpers.nearestTarget(caster_index, valid_targets, game_state);
}

/// Player prepare: highlight all valid target positions.
fn playerPrepareSkill(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?Event {
    return helpers.highlightTargets(getValidTargets(caster_index, game_state, allocator));
}

/// Use: attack the target, dealing 1.5x damage if the caster is above half health.
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

    // Damage: 1.5x if the caster is above half health (integer math).
    const base_damage: u32 = if (caster.main_hand_weapon) |weapon| weapon.weapon_damage else 0;
    var damage: u32 = caster.getEffectiveOutgoingDamage(base_damage);
    if (caster.current_health * 2 > caster.getEffectiveMaxHealth()) {
        damage = damage + damage / 2;
    }

    return helpers.ownedEvents(allocator, &.{
        .{ .sub_level_event = .{ .attack = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .outgoing_damage = damage,
        } } },
    });
}
