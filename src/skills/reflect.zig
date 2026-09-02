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

/// Reflect: an off-hand skill. Grants the Reflect effect on the caster — while
/// active, incoming attack damage is prevented and dealt back to the attacker.
/// Collision damage from knockback is NOT reflected — it's the counterplay
/// around the shield. Turn-ending (weapon skill).
pub const skill = Skill{
    .name = "Reflect",
    .skill_type = .weapon_skill,
    .deals_damage = false,
    .description = "Incoming damage is prevented and dealt to the attacker",
    .uses_targeting = false,
    .range = null,
    .radius = null,
    .distance = null,
    .skill_duration = 1,
    .stun_duration = null,
    .cooldown = 4,
    .get_valid_targets_fn = &getValidTargets,
    .ai_options_fn = &aiOptions,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

/// Self-cast — no targeting.
fn getValidTargets(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Vector2 {
    return null;
}

/// AI options: one self-cast — offered only when a hostile can reach and
/// attack the caster next turn (the threat model, skills/threat.zig).
/// Rated 2 when threatened, 4 when threatened AND below half health.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.reflect) > 0) return &.{};
    if (!threat.hostileCanAttackNextTurn(caster_index, game_state, weapon_type_definitions)) return &.{};
    const rating: u32 = if (caster.current_health * 2 < caster.getEffectiveMaxHealth()) 4 else 2;
    return helpers.singleOption(allocator, .{ .target = null, .priority = rating });
}

/// Self-cast — no meaningful target.
/// Self-cast — fires immediately.
fn playerPrepareSkill(_: u32, _: GameState, _: std.mem.Allocator) ?Event {
    return null;
}

/// Use: apply the Reflect effect to the caster for skill_duration turns.
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
            .effect_id = .reflect,
            .duration = caster.getEffectiveOutgoingSkillDuration(skill.skill_duration.?),
        } } },
    });
}
