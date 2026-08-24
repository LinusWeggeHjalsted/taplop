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

/// Bash: a main-hand skill. Attacks and knocks back a single target, dealing
/// +0.5x main-hand damage on collision.
pub const skill = Skill{
    .name = "Bash",
    .skill_type = .weapon_skill,
    .description = "Attack and knockback target, dealing +0.5x damage on collision",
    .uses_targeting = true,
    .range = 1,
    .radius = null,
    .distance = 1,
    .skill_duration = null,
    .stun_duration = null,
    .cooldown = null,
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

fn sign(value: i32) i32 {
    return if (value > 0) 1 else if (value < 0) @as(i32, -1) else 0;
}

/// AI priority: 0 if no target in range. Otherwise prefer a knockback that will
/// collide (into a wall/edge/entity), since collision adds damage: 3 if the
/// push would collide, else 2.
fn priority(caster_index: u32, game_state: GameState) u32 {
    const level = game_state.level orelse return 0;
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.bash) > 0) return 0;

    const range: i32 = @intCast(caster.getEffectiveRange(skill.range.?));

    // Nearest hostile in range.
    var target_index: ?u32 = null;
    var target_position: Vector2 = undefined;
    var best_distance: i32 = std.math.maxInt(i32);
    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.current_health == 0) continue;
        if (entity.team == caster.team) continue;
        const distance = functions.chebyshevDistance(caster.position, entity.position);
        if (distance <= range and distance < best_distance) {
            best_distance = distance;
            target_index = @intCast(entity_index);
            target_position = entity.position;
        }
    }
    const defender_index = target_index orelse return 0;

    // Would the knockback collide within its distance? Step from the target
    // away from the caster; a missing tile (edge) or an occupant is a collision.
    const direction = Vector2{
        .x = sign(target_position.x - caster.position.x),
        .y = sign(target_position.y - caster.position.y),
    };
    const push_distance = caster.getEffectiveDistance(skill.distance.?);
    var position = target_position;
    var step: u32 = 0;
    while (step < push_distance) : (step += 1) {
        position = .{ .x = position.x + direction.x, .y = position.y + direction.y };
        if (!helpers.tileExists(game_state, position) or
            helpers.isOccupied(game_state, position, defender_index))
        {
            return 3;
        }
    }
    return 2;
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

/// Use: attack for main-hand damage, then knock back. Collision damage is
/// +0.5x the effective outgoing main-hand damage (same outgoing modifiers
/// as the attack; the knockback handler applies it only on collision and
/// runs the defender's incoming modifiers).
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

    const main_hand_damage: u32 = if (caster.main_hand_weapon) |weapon| weapon.weapon_damage else 0;
    // Both attack and collision damage derive from the effective outgoing
    // damage (gloves + converted momentum + outgoing effects), then scale —
    // collision is half. Mirrors how `attack` applies outgoing modifiers at
    // the skill site; the collision handler still applies only the
    // defender's incoming modifiers.
    const damage = caster.getEffectiveOutgoingDamage(main_hand_damage);
    const collision_damage = damage / 2; // +0.5x effective outgoing
    const push_distance = caster.getEffectiveDistance(skill.distance.?);

    return helpers.ownedEvents(allocator, &.{
        .{ .sub_level_event = .{ .attack = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .outgoing_damage = damage,
        } } },
        .{ .sub_level_event = .{ .knockback = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .distance = push_distance,
            .knockback_damage = collision_damage,
        } } },
    });
}
