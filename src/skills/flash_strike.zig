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

/// Flash Strike: an off-hand skill. Teleports to an empty tile within range,
/// then attacks every hostile within radius of the landing.
pub const skill = Skill{
    .name = "Flash Strike",
    .skill_type = .weapon_skill,
    .description = "Teleport then attack each target within radius",
    .uses_targeting = true,
    .range = 3,
    .radius = 1,
    .distance = null,
    .skill_duration = null,
    .stun_duration = null,
    .cooldown = 3,
    .get_valid_targets_fn = &getValidTargets,
    .priority_fn = &priority,
    .select_target_fn = &selectTarget,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

/// Valid targets are empty teleport tiles within range.
fn getValidTargets(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?[]const Vector2 {
    const caster = (game_state.level orelse return null).entities[caster_index];
    const range: i32 = @intCast(caster.getEffectiveRange(skill.range.?));
    return helpers.emptyTilesInRange(caster_index, game_state, range, allocator);
}

/// AI priority: 0 if on cooldown, else 3 (Flash Strike closes distance and
/// hits an area — the enemy wants it whenever it is available).
fn priority(caster_index: u32, game_state: GameState) u32 {
    const level = game_state.level orelse return 0;
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.flash_strike) > 0) return 0;
    return 3;
}

/// AI target selection: the empty landing tile closest to a hostile, so the
/// caster lands adjacent and the radius attack connects.
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
    for (targets) |candidate| {
        var nearest_hostile: i32 = std.math.maxInt(i32);
        for (level.entities, 0..) |entity, entity_index| {
            if (entity_index == caster_index) continue;
            if (entity.current_health == 0) continue;
            if (entity.team == caster.team) continue;
            const distance = functions.chebyshevDistance(candidate, entity.position);
            if (distance < nearest_hostile) nearest_hostile = distance;
        }
        if (nearest_hostile < best_distance) {
            best_distance = nearest_hostile;
            best = candidate;
        }
    }
    return best;
}

fn playerPrepareSkill(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?Event {
    return helpers.highlightTargets(getValidTargets(caster_index, game_state, allocator));
}

/// Use: teleport to the target tile, then attack every hostile within radius of
/// the landing for off-hand damage. Move runs first, then the attacks.
fn useSkill(
    caster_index: u32,
    target: ?Vector2,
    game_state: GameState,
    allocator: std.mem.Allocator,
) []const Event {
    const landing = target orelse return &.{};
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];

    const radius: i32 = @intCast(caster.getEffectiveRadius(skill.radius.?));
    const target_indices = helpers.hostileIndicesInRadius(caster_index, game_state, landing, radius, allocator);

    const off_hand_damage: u32 = if (caster.off_hand_weapon) |weapon| weapon.weapon_damage else 0;
    const damage = caster.getEffectiveOutgoingDamage(off_hand_damage);

    var skill_events: std.ArrayList(Event) = .empty;
    // Teleport first.
    skill_events.append(allocator, .{ .level_event = .{ .move_entity = .{
        .entity_index = caster_index,
        .destination = landing,
    } } }) catch @panic("failed to append move event");
    // Then attack each hostile around the landing.
    for (target_indices) |defender_index| {
        skill_events.append(allocator, .{ .sub_level_event = .{ .attack = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .outgoing_damage = damage,
        } } }) catch @panic("failed to append attack event");
    }

    return helpers.ownedEvents(allocator, skill_events.items);
}
