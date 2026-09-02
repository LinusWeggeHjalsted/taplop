const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");
const functions = @import("../functions.zig");
const skill_mod = @import("skill.zig");
const helpers = @import("helpers.zig");

const Vector2 = types.Vector2;
const GameState = state.GameState;
const Event = events.Event;
const Skill = skill_mod.Skill;

/// Head Shot: the crossbow's third (off-hand) skill. Attacks a single target
/// within range and stuns it — Cleave's shape at range, with off-hand damage.
pub const skill = Skill{
    .name = "Head Shot",
    .skill_type = .weapon_skill,
    .deals_damage = true,
    .description = "Attack and stun target",
    .uses_targeting = true,
    .range = 3,
    .radius = null,
    .distance = null,
    .skill_duration = null,
    .stun_duration = 1,
    .cooldown = 4,
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

/// AI priority: 0 if on cooldown or no target in range. 3 if any in-range
/// target is unstunned (full stun + attack value); 2 when only stunned
/// targets remain (the attack still pays, the stun does not — stuns take
/// the max, never stack).
/// AI options: the stun pick (unstunned-preferred, then focus-fire —
/// helpers.stunTarget). Rated on the PICK: 3 when it is unstunned (the
/// stun pays in full — stuns take the max, never stack), else 2 (the
/// attack still pays).
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.head_shot) > 0) return &.{};

    const valid_targets = getValidTargets(caster_index, game_state, allocator);
    const target = helpers.stunTarget(caster_index, valid_targets, game_state) orelse return &.{};
    const defender_index = helpers.hostileEntityAt(caster_index, target, game_state) orelse return &.{};
    const rating: u32 = if (level.entities[defender_index].stun_duration == 0) 3 else 2;
    return helpers.singleOption(allocator, .{ .target = target, .priority = rating });
}

/// AI target selection for the stun: prefer an unstunned target, then the
/// focus-fire order (helpers.stunTarget).
fn playerPrepareSkill(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?Event {
    return helpers.highlightTargets(getValidTargets(caster_index, game_state, allocator));
}

/// Use: attack for 1x off-hand damage, then stun. Caster OUTGOING stun
/// modifiers apply here; the stun handler applies the defender's incoming
/// ones (durations add, so they stack with any ongoing stun).
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
    const damage = caster.getEffectiveOutgoingDamage(off_hand_damage);
    const stun_duration = caster.getEffectiveOutgoingStunDuration(skill.stun_duration.?);

    return helpers.ownedEvents(allocator, &.{
        .{ .sub_level_event = .{ .attack = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .outgoing_damage = damage,
        } } },
        .{ .sub_level_event = .{ .stun = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .stun_duration = stun_duration,
        } } },
    });
}
