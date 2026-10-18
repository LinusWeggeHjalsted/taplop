const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");
const skill_mod = @import("../skill.zig");
const helpers = @import("../skill_helpers.zig");

const Vector2 = types.Vector2;
const GameState = state.GameState;
const Event = events.Event;
const Skill = skill_mod.Skill;

/// Promise of Death: an enchantment. Grants the Promise of Death effect -
/// if an enemy dies while it holds, the caster resets every cooldown and
/// heals to full. Lasts one round.
pub const skill = Skill{
    .name = "Promise of Death",
    .skill_type = .enchantment,
    .deals_damage = false,
    .description = "Reset all cooldowns and gain full health if an enemy dies",
    .uses_targeting = false,
    .range = null,
    .radius = null,
    .distance = null,
    .skill_duration = 1,
    .stun_duration = null,
    .cooldown = 10,
    .get_valid_targets_fn = &getValidTargets,
    .ai_options_fn = &aiOptions,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

/// Self-cast - no targeting.
fn getValidTargets(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Vector2 {
    return null;
}

/// AI options: one self-cast at rating 1, offered when any active hostile
/// exists (a live enemy is the payday's precondition; the pool's ratings
/// only order the non-ending skills).
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
    _: *skill_mod.EvalFrame,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.promise_of_death) > 0) return &.{};

    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.current_health == 0) continue;
        if (entity.team == caster.team) continue;
        if (!entity.is_active) continue;
        return helpers.singleOption(allocator, .{ .target = null, .priority = 1 });
    }
    return &.{};
}

/// Self-cast - fires immediately.
fn playerPrepareSkill(_: u32, _: GameState, _: std.mem.Allocator) ?Event {
    return null;
}

/// Use: apply the effect to the caster for skill_duration turns (one round).
fn useSkill(
    caster_index: u32,
    _: ?Vector2,
    game_state: GameState,
    allocator: std.mem.Allocator,
) []const Event {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];

    return helpers.ownedEvents(allocator, &.{
        .{ .sub_level_event = .{ .create_effect = .{
            .caster_index = caster_index,
            .receiver_index = caster_index,
            .effect_id = .promise_of_death,
            .duration = caster.getEffectiveOutgoingSkillDuration(skill.skill_duration.?),
        } } },
    });
}
