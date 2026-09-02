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

/// Stone Form: an enchantment. Grants the Stone Form effect on the caster —
/// reduced incoming stun, increased outgoing stun, and an end-of-turn heal.
/// Non-turn-ending.
pub const skill = Skill{
    .name = "Stone Form",
    .skill_type = .enchantment,
    .deals_damage = false,
    .description = "Reduce incoming stun durations by 1, increase outgoing stun durations by 1, and heal 20% of max health at end of turn",
    .uses_targeting = false,
    .range = null,
    .radius = null,
    .distance = null,
    .skill_duration = 5,
    .stun_duration = null,
    .cooldown = 10,
    .get_valid_targets_fn = &getValidTargets,
    .ai_options_fn = &aiOptions,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

/// Self-cast — no targeting.
fn getValidTargets(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Vector2 {
    return null;
}

/// AI options: one self-cast at 2 — offered once damaged (the stun
/// resistance + heal-over-time pay below full health).
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.stone_form) > 0) return &.{};
    if (caster.current_health >= caster.getEffectiveMaxHealth()) return &.{};
    return helpers.singleOption(allocator, .{ .target = null, .priority = 2 });
}

/// Self-cast — no meaningful target.
/// Self-cast — fires immediately.
fn playerPrepareSkill(_: u32, _: GameState, _: std.mem.Allocator) ?Event {
    return null;
}

/// Use: apply the Stone Form effect to the caster for skill_duration turns.
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
            .effect_id = .stone_form,
            .duration = caster.getEffectiveOutgoingSkillDuration(skill.skill_duration.?),
        } } },
    });
}
