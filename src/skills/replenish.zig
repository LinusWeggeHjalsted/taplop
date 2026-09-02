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

/// Replenish: a cantrip. Heals the caster to full health. Self-cast,
/// non-turn-ending.
pub const skill = Skill{
    .name = "Replenish",
    .skill_type = .cantrip,
    .deals_damage = false,
    .description = "Heal to full health",
    .uses_targeting = false,
    .range = null,
    .radius = null,
    .distance = null,
    .skill_duration = null,
    .stun_duration = null,
    .cooldown = 5,
    .get_valid_targets_fn = &getValidTargets,
    .priority_fn = &priority,
    .select_target_fn = &selectTarget,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

/// Self-cast — no targeting.
fn getValidTargets(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Vector2 {
    return null;
}

/// AI priority (cantrip): 0 if on cooldown or at/above half health (no need),
/// else 3 — a wounded enemy values a full heal highly.
fn priority(caster_index: u32, game_state: GameState, _: types.WeaponTypeDefinitions) u32 {
    const level = game_state.level orelse return 0;
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.replenish) > 0) return 0;
    if (caster.current_health * 2 >= caster.getEffectiveMaxHealth()) return 0;
    return 3;
}

/// Self-cast — no meaningful target.
fn selectTarget(_: u32, _: ?[]const Vector2, _: GameState) ?Vector2 {
    return null;
}

/// Self-cast — fires immediately.
fn playerPrepareSkill(_: u32, _: GameState, _: std.mem.Allocator) ?Event {
    return null;
}

/// Use: heal the caster to full (heal handler clamps to max_health).
fn useSkill(
    caster_index: u32,
    _: ?Vector2,
    game_state: GameState,
    allocator: std.mem.Allocator,
) []const Event {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];

    return helpers.ownedEvents(allocator, &.{
        .{ .sub_level_event = .{ .heal = .{
            .entity_index = caster_index,
            .amount = caster.getEffectiveMaxHealth(),
        } } },
    });
}
