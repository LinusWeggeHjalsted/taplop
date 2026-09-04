const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");
const functions = @import("../functions.zig");
const skill_mod = @import("../skill.zig");
const helpers = @import("../skill_helpers.zig");

const Vector2 = types.Vector2;
const GameState = state.GameState;
const Event = events.Event;
const Skill = skill_mod.Skill;

/// Retreating Swipe: an off-hand skill. Attacks a single target for 1.5x
/// off-hand damage, then retreats away from it.
pub const skill = Skill{
    .name = "Retreating Swipe",
    .skill_type = .weapon_skill,
    .deals_damage = true,
    .description = "Attack target for 1.5x damage and retreat",
    .uses_targeting = true,
    .range = 1,
    .radius = null,
    .distance = 2,
    .skill_duration = null,
    .stun_duration = null,
    .cooldown = 3,
    .get_valid_targets_fn = &getValidTargets,
    .ai_options_fn = &aiOptions,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

fn getValidTargets(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?[]const Vector2 {
    const caster = (game_state.level orelse return null).entities[caster_index];
    const range: i32 = @intCast(caster.getEffectiveRange(skill.range.?));
    return helpers.hostilesInRange(caster_index, game_state, range, allocator);
}

/// AI options: the weakest hostile (focus-fire) at rating 2 — one
/// significant bonus (1.5x; the retreat is a minor rider).
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.retreating_swipe) > 0) return &.{};

    const valid_targets = getValidTargets(caster_index, game_state, allocator);
    const target = helpers.weakestTarget(caster_index, valid_targets, game_state) orelse return &.{};
    return helpers.singleOption(allocator, .{ .target = target, .priority = 2 });
}

fn playerPrepareSkill(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?Event {
    return helpers.highlightTargets(getValidTargets(caster_index, game_state, allocator));
}

/// Use: attack for 1.5x off-hand damage, then retreat away from the target
/// (the retreat handler steps away from target_position, stopping at obstacles).
fn useSkill(
    caster_index: u32,
    target: ?Vector2,
    game_state: GameState,
    allocator: std.mem.Allocator,
) []const Event {
    const target_position = target orelse return &.{};
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];

    const defender_index = helpers.hostileEntityAt(caster_index, target_position, game_state) orelse return &.{};

    const off_hand_damage: u32 = if (caster.off_hand_weapon) |weapon| weapon.weapon_damage else 0;
    const base_damage = off_hand_damage + off_hand_damage / 2; // 1.5x, integer math
    const damage = caster.getEffectiveOutgoingDamage(base_damage);
    const retreat_distance = caster.getEffectiveDistance(skill.distance.?);

    return helpers.ownedEvents(allocator, &.{
        .{ .sub_level_event = .{ .attack = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .outgoing_damage = damage,
        } } },
        .{ .sub_level_event = .{ .retreat = .{
            .entity_index = caster_index,
            .target_position = target_position,
            .distance = retreat_distance,
        } } },
    });
}
