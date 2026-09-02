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

/// Heal: the idol's first (main-hand) skill. Heals the caster for 20% of its
/// max health. Self-cast, no targeting; turn-ending (a weapon skill).
pub const skill = Skill{
    .name = "Heal",
    .skill_type = .weapon_skill,
    .deals_damage = false,
    .description = "Heal for 20% of max health",
    .uses_targeting = false,
    .range = null,
    .radius = null,
    .distance = null,
    .skill_duration = null,
    .stun_duration = null,
    .cooldown = null,
    .get_valid_targets_fn = &getValidTargets,
    .ai_options_fn = &aiOptions,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

/// Self-cast — no targeting.
fn getValidTargets(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Vector2 {
    return null;
}

/// AI options: one self-cast at 2 (a 20% heal ≈ one bonus-hit of
/// value) — offered only below half health (a scratch heal isn't worth a
/// turn; a flat below-full rating would tie the plain attacks at 1, where
/// slot order would make Heal win and the caster would heal every turn
/// instead of attacking).
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.heal) > 0) return &.{};
    if (caster.current_health * 2 >= caster.getEffectiveMaxHealth()) return &.{};
    return helpers.singleOption(allocator, .{ .target = null, .priority = 2 });
}

/// Self-cast — no meaningful target.
/// Self-cast — fires immediately.
fn playerPrepareSkill(_: u32, _: GameState, _: std.mem.Allocator) ?Event {
    return null;
}

/// Use: heal the caster for 20% of max health (integer division; the heal
/// handler clamps to max).
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
            .amount = caster.getEffectiveMaxHealth() / 5,
        } } },
    });
}
