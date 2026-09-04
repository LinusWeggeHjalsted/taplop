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

/// Focus: a cantrip. Resets each equipped weapon-skill cooldown. Self-cast,
/// non-turn-ending.
pub const skill = Skill{
    .name = "Focus",
    .skill_type = .cantrip,
    .deals_damage = false,
    .description = "Reset each equipped weapon skill cooldown",
    .uses_targeting = false,
    .range = null,
    .radius = null,
    .distance = null,
    .skill_duration = null,
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

/// AI options: one self-cast at 2 — offered only while some cooldown is
/// ticking (nothing to reset otherwise).
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.focus) > 0) return &.{};
    for (caster.skill_cooldowns.values) |cooldown| {
        if (cooldown > 0) return helpers.singleOption(allocator, .{ .target = null, .priority = 2 });
    }
    return &.{};
}

/// Self-cast — no meaningful target.
/// Self-cast — fires immediately.
fn playerPrepareSkill(_: u32, _: GameState, _: std.mem.Allocator) ?Event {
    return null;
}

/// Use: reset the caster's equipped weapon-skill cooldowns (the handler
/// resolves the weapon skills and emits a change_cooldown per skill).
fn useSkill(
    caster_index: u32,
    _: ?Vector2,
    _: GameState,
    allocator: std.mem.Allocator,
) []const Event {
    return helpers.ownedEvents(allocator, &.{
        .{ .sub_level_event = .{ .reset_weapon_cooldowns = .{
            .entity_index = caster_index,
        } } },
    });
}
