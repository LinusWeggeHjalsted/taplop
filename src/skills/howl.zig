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

/// Howl: a cantrip. Aggros (activates) every entity within radius —
/// same-team (rallying the pack) and opposing. Self-centered,
/// non-turn-ending.
pub const skill = Skill{
    .name = "Howl",
    .skill_type = .cantrip,
    .deals_damage = false,
    .description = "Aggro each entity within radius",
    .uses_targeting = false,
    .range = null,
    .radius = 16,
    .distance = null,
    .skill_duration = null,
    .stun_duration = null,
    .cooldown = 10,
    .get_valid_targets_fn = &getValidTargets,
    .priority_fn = &priority,
    .select_target_fn = &selectTarget,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

/// Self-centered — no targeting.
fn getValidTargets(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Vector2 {
    return null;
}

/// AI priority (cantrip): 0 if on cooldown or no inactive entity within
/// radius (nothing to aggro), else 1.
fn priority(caster_index: u32, game_state: GameState, _: types.WeaponTypeDefinitions) u32 {
    const level = game_state.level orelse return 0;
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.howl) > 0) return 0;

    const radius: i32 = @intCast(caster.getEffectiveRadius(skill.radius.?));
    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.current_health == 0) continue;
        if (entity.is_active) continue; // already aggroed
        if (functions.chebyshevDistance(caster.position, entity.position) <= radius) return 1;
    }
    return 0;
}

/// Self-centered — no meaningful target.
fn selectTarget(_: u32, _: ?[]const Vector2, _: GameState) ?Vector2 {
    return null;
}

/// Self-centered — fires immediately.
fn playerPrepareSkill(_: u32, _: GameState, _: std.mem.Allocator) ?Event {
    return null;
}

/// Use: aggro every opposing entity within radius.
fn useSkill(
    caster_index: u32,
    _: ?Vector2,
    game_state: GameState,
    allocator: std.mem.Allocator,
) []const Event {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    const radius = caster.getEffectiveRadius(skill.radius.?);

    return helpers.ownedEvents(allocator, &.{
        .{ .sub_level_event = .{ .aggro_in_radius = .{
            .entity_index = caster_index,
            .radius = radius,
        } } },
    });
}
