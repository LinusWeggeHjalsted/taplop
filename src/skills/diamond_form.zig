const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");
const skill_mod = @import("skill.zig");
const helpers = @import("helpers.zig");
const threat = @import("threat.zig");

const Vector2 = types.Vector2;
const GameState = state.GameState;
const Event = events.Event;
const Skill = skill_mod.Skill;
const WeaponTypeDefinitions = types.WeaponTypeDefinitions;

/// Diamond Form: an enchantment. Stuns the caster for the full duration,
/// then grants the Diamond Form effect — invulnerable to attack damage and
/// healing 10% of max health at the end of each (skipped) turn. The
/// desperation button: it trades every action for survival.
pub const skill = Skill{
    .name = "Diamond Form",
    .skill_type = .enchantment,
    .deals_damage = false,
    .description = "Stun yourself, then become invulnerable and heal 10% of max health at end of turn",
    .uses_targeting = false,
    .range = null,
    .radius = null,
    .distance = null,
    .skill_duration = 5,
    .stun_duration = 5,
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

/// AI options: the desperation gate — offered only when threatened AND
/// below half health (it costs the whole duration's actions; casting it
/// while healthy or unthreatened is throwing the fight), rated 2.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.diamond_form) > 0) return &.{};
    if (!threat.hostileCanAttackNextTurn(caster_index, game_state, weapon_type_definitions)) return &.{};
    if (caster.current_health * 2 >= caster.getEffectiveMaxHealth()) return &.{};
    return helpers.singleOption(allocator, .{ .target = null, .priority = 2 });
}

/// Self-cast — fires immediately.
fn playerPrepareSkill(_: u32, _: GameState, _: std.mem.Allocator) ?Event {
    return null;
}

/// Use: stun the caster (a fresh max-semantics stun — the caster cannot be
/// already stunned at its own turn), then apply the Diamond Form effect
/// for the same duration.
fn useSkill(
    caster_index: u32,
    _: ?Vector2,
    game_state: GameState,
    allocator: std.mem.Allocator,
) []const Event {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];

    return helpers.ownedEvents(allocator, &.{
        .{ .sub_level_event = .{ .stun = .{
            .attacker_index = caster_index,
            .defender_index = caster_index,
            .stun_duration = caster.getEffectiveOutgoingStunDuration(skill.stun_duration.?),
        } } },
        .{ .sub_level_event = .{ .create_effect = .{
            .caster_index = caster_index,
            .receiver_index = caster_index,
            .effect_id = .diamond_form,
            .duration = caster.getEffectiveOutgoingSkillDuration(skill.skill_duration.?),
        } } },
    });
}
