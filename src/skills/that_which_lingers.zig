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

// Re-export effect definition from effects directory
pub const effect = @import("../effects/that_which_lingers.zig").effect;

// --- Skill interface ---

/// That Which Lingers: an enchantment that applies the matching effect
/// (all outgoing skill durations +1). No targeting.
pub const skill = Skill{
    .name = "That Which Lingers",
    .skill_type = .enchantment,
    .deals_damage = false,
    .description = "Increase all skill durations by 1",
    .uses_targeting = false,
    .range = null,
    .radius = null,
    .distance = null,
    .skill_duration = 2,
    .stun_duration = null,
    .cooldown = 5,
    .get_valid_targets_fn = &getValidTargets,
    .ai_options_fn = &aiOptions,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

/// Self-cast — no targeting needed.
fn getValidTargets(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Vector2 {
    return null;
}

/// AI priority: 0 if on cooldown, otherwise low priority (cast when nothing better to do).
/// AI options: one self-cast at 1 (the enchantment's slot value; the
/// duration extension on recast is handled by create_effect).
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.that_which_lingers) > 0) return &.{};
    return helpers.singleOption(allocator, .{ .target = caster.position, .priority = 1 });
}

/// Self-cast — target is the caster's own position.
/// Self-cast enchantment — no tile highlighting, just push the effect creation.
fn playerPrepareSkill(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?Event {
    _ = allocator;
    const level = game_state.level orelse return null;
    const caster = level.entities[caster_index];

    return .{ .sub_level_event = .{ .create_effect = .{
        .caster_index = caster_index,
        .receiver_index = caster_index,
        .effect_id = .that_which_lingers,
        .duration = caster.getEffectiveOutgoingSkillDuration(skill.skill_duration.?),
    } } };
}

/// Push the create_effect event on the caster.
fn useSkill(
    caster_index: u32,
    _: ?Vector2,
    game_state: GameState,
    _: std.mem.Allocator,
) []const Event {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];

    return &.{.{ .sub_level_event = .{ .create_effect = .{
        .caster_index = caster_index,
        .receiver_index = caster_index,
        .effect_id = .that_which_lingers,
        .duration = caster.getEffectiveOutgoingSkillDuration(skill.skill_duration.?),
    } } }};
}
