const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");
const skill_mod = @import("../skill.zig");
const helpers = @import("../skill_helpers.zig");
const threat = @import("../ai_threat.zig");

const Vector2 = types.Vector2;
const GameState = state.GameState;
const Event = events.Event;
const Skill = skill_mod.Skill;
const WeaponTypeDefinitions = types.WeaponTypeDefinitions;

/// That Which Explodes: an enchantment. Grants the That Which Explodes
/// effect - when the holder is dealt attack damage, it attacks every
/// hostile within radius for 1x effective spell damage. The skill itself
/// deals no damage (the effect's attacks are reactive); deals_damage is
/// false because the threat model measures proactive reach.
pub const skill = Skill{
    .name = "That Which Explodes",
    .skill_type = .enchantment,
    .deals_damage = false,
    .description = "Attack each enemy within radius when dealt damage",
    .uses_targeting = false,
    .range = null,
    .radius = 1,
    .distance = null,
    .skill_duration = 2,
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

/// AI options: one self-cast, offered only when a hostile can reach and
/// attack the caster next turn (the threat model - exploding with nobody
/// able to hit you wastes the cooldown), rated 2 (prevention + retaliation
/// ≈ two hits of swing).
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
    _: *skill_mod.EvalFrame,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.that_which_explodes) > 0) return &.{};
    if (!threat.hostileCanAttackNextTurn(caster_index, game_state, weapon_type_definitions)) return &.{};
    return helpers.singleOption(allocator, .{ .target = null, .priority = 2 });
}

/// Self-cast - fires immediately.
fn playerPrepareSkill(_: u32, _: GameState, _: std.mem.Allocator) ?Event {
    return null;
}

/// Use: apply the effect to the caster for skill_duration turns.
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
            .effect_id = .that_which_explodes,
            .duration = caster.getEffectiveOutgoingSkillDuration(skill.skill_duration.?),
        } } },
    });
}
