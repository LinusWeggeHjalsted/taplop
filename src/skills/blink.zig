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

/// Blink: a cantrip. Teleports to an empty tile within range. Non-turn-ending.
pub const skill = Skill{
    .name = "Blink",
    .skill_type = .cantrip,
    .description = "Teleport",
    .uses_targeting = true,
    .range = 3,
    .radius = null,
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

/// AI priority (cantrip, competes only with other non-turn-ending skills):
/// 0 if on cooldown, else 1.
fn priority(caster_index: u32, game_state: GameState) u32 {
    const level = game_state.level orelse return 0;
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.blink) > 0) return 0;
    return 1;
}

/// AI target selection: the empty tile closest to a hostile (blink toward the
/// nearest opponent).
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

/// Use: teleport to the target tile.
fn useSkill(
    caster_index: u32,
    target: ?Vector2,
    _: GameState,
    allocator: std.mem.Allocator,
) []const Event {
    const destination = target orelse return &.{};
    return helpers.ownedEvents(allocator, &.{
        .{ .level_event = .{ .move_entity = .{
            .entity_index = caster_index,
            .destination = destination,
        } } },
    });
}
