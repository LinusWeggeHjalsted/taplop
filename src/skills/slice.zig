const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");
const functions = @import("../functions.zig");
const skill_mod = @import("skill.zig");

const Vector2 = types.Vector2;
const Entity = types.Entity;
const GameState = state.GameState;
const Event = events.Event;
const Skill = skill_mod.Skill;

/// Slice: a basic sword skill.
/// Attacks a single target within range.
/// Deals 1.5x main hand damage if the target is below half health.
pub const skill = Skill{
    .name = "Slice",
    .skill_type = .weapon_skill,
    .description = "Attack target, dealing 1.5x damage if they have less than half health",
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

/// Returns positions of all hostile entities within range of the caster.
fn getValidTargets(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?[]const Vector2 {
    const level = game_state.level orelse return null;
    const caster = level.entities[caster_index];
    const range: i32 = @intCast(caster.getEffectiveRange(skill.range.?));

    // Count hostile entities in range
    var count: usize = 0;
    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.team == caster.team) continue;
        if (functions.chebyshevDistance(caster.position, entity.position) <= range) {
            count += 1;
        }
    }

    if (count == 0) return null;

    // Allocate and fill
    const targets = allocator.alloc(Vector2, count) catch @panic("failed to allocate valid targets");
    var target_index: usize = 0;
    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.team == caster.team) continue;
        if (functions.chebyshevDistance(caster.position, entity.position) <= range) {
            targets[target_index] = entity.position;
            target_index += 1;
        }
    }

    return targets;
}

/// AI priority for using Slice.
/// Returns 0 if on cooldown or no targets in range.
/// Returns 3 normally, 2 if target (nearest hostile) is below half health
/// (prefer a different finisher skill for wounded targets).
fn priority(caster_index: u32, game_state: GameState) f32 {
    const level = game_state.level orelse return 0;
    const caster = level.entities[caster_index];

    // Check cooldown
    if (caster.skill_cooldowns.get(.slice) > 0) return 0;

    const range: i32 = @intCast(caster.getEffectiveRange(skill.range.?));

    // Find nearest hostile in range
    var found_target = false;
    var nearest_health_ratio: f32 = 1.0;
    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.team == caster.team) continue;
        if (functions.chebyshevDistance(caster.position, entity.position) <= range) {
            found_target = true;
            const ratio = @as(f32, @floatFromInt(entity.current_health)) /
                @as(f32, @floatFromInt(entity.max_health));
            if (ratio < nearest_health_ratio) {
                nearest_health_ratio = ratio;
            }
        }
    }

    if (!found_target) return 0;

    // Higher priority when target is wounded — that's when Slice's 1.5x bonus kicks in
    if (nearest_health_ratio < 0.5) return 3;
    return 2;
}

/// AI target selection: pick the nearest hostile entity from valid targets.
fn selectTarget(
    caster_index: u32,
    valid_targets: ?[]const Vector2,
    game_state: GameState,
) ?Vector2 {
    const targets = valid_targets orelse return null;
    if (targets.len == 0) return null;

    const level = game_state.level orelse return null;
    const caster = level.entities[caster_index];

    var best: ?Vector2 = null;
    var best_distance: i32 = std.math.maxInt(i32);
    for (targets) |position| {
        const distance = functions.chebyshevDistance(caster.position, position);
        if (distance < best_distance) {
            best_distance = distance;
            best = position;
        }
    }
    return best;
}

/// Player prepare: returns a highlight_tiles event for all valid target positions.
fn playerPrepareSkill(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?Event {
    const targets = getValidTargets(caster_index, game_state, allocator) orelse return null;

    return .{ .level_event = .{ .highlight_tiles = .{
        .tile_positions = targets,
    } } };
}

/// Use the skill: queue an attack event against the target.
/// Deals 1.5x main hand damage if target is below half health.
fn useSkill(
    caster_index: u32,
    target: ?Vector2,
    game_state: GameState,
    _: std.mem.Allocator,
) []const Event {
    const target_position = target orelse return &.{};
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];

    // Find the entity at target position
    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.team == caster.team) continue;
        if (entity.position.x == target_position.x and entity.position.y == target_position.y) {
            // Calculate damage: 1.5x if target below half health
            const base_damage: u32 = if (caster.main_hand_weapon) |weapon| weapon.weapon_damage else 0;
            var damage: u32 = caster.getEffectiveOutgoingDamage(base_damage);
            if (entity.current_health * 2 < entity.max_health) {
                damage = damage + damage / 2; // 1.5x, integer math
            }

            const attack_event = Event{ .sub_level_event = .{ .attack = .{
                .attacker_index = caster_index,
                .defender_index = @intCast(entity_index),
                .outgoing_damage = damage,
            } } };

            // Return as a single-element slice using a comptime-known array
            return &.{attack_event};
        }
    }

    return &.{};
}

