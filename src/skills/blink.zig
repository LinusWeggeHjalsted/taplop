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
    .deals_damage = false,
    .description = "Teleport",
    .uses_targeting = true,
    .range = 3,
    .radius = null,
    .distance = null,
    .skill_duration = null,
    .stun_duration = null,
    .cooldown = 3,
    .get_valid_targets_fn = &getValidTargets,
    .ai_options_fn = &aiOptions,
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
/// AI options: blink to the empty tile closest to a hostile (closing the
/// gap) at rating 1 — the cantrip's repositioning value. With no hostiles
/// (or no empty tiles) nothing is offered; the old pair could choose
/// Blink and then cast it into a no-op.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.blink) > 0) return &.{};
    const valid_targets = getValidTargets(caster_index, game_state, allocator);
    const candidates = valid_targets orelse return &.{};
    if (candidates.len == 0) return &.{};

    var best: ?Vector2 = null;
    var best_distance: i32 = std.math.maxInt(i32);
    for (candidates) |candidate| {
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

    const target = best orelse return &.{};
    return helpers.singleOption(allocator, .{ .target = target, .priority = 1 });
}

/// AI target selection: the empty tile closest to a hostile (blink toward the
/// nearest opponent).
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
