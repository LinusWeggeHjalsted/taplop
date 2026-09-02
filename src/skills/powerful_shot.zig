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

/// Powerful Shot: the crossbow's second (main-hand) skill. Attacks a single
/// target within range and knocks it back, dealing +0.5x main-hand damage on
/// collision — Bash's shape at range.
pub const skill = Skill{
    .name = "Powerful Shot",
    .skill_type = .weapon_skill,
    .deals_damage = true,
    .description = "Attack and knockback target, dealing +0.5x damage on collision",
    .uses_targeting = true,
    .range = 3,
    .radius = null,
    .distance = 2,
    .skill_duration = null,
    .stun_duration = null,
    .cooldown = 2,
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

/// AI priority: 0 if on cooldown or no target in range. Otherwise 3 if ANY
/// in-range target's push would collide (into a wall/edge/entity — collision
/// adds damage), else 2. Target-agnostic by design: the collide preference
/// is reflected per-target by selectTarget (knockbackTarget), so priority
/// and selection stay in sync without coupling them.
/// AI options: the knockback pick (collide-preferring, then focus-fire —
/// helpers.knockbackTarget). Rated on the PICK: 3 when that target's push
/// would collide (the collision adds damage), else 2.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.powerful_shot) > 0) return &.{};
    const push_distance = caster.getEffectiveDistance(skill.distance.?);

    const valid_targets = getValidTargets(caster_index, game_state, allocator);
    const target = helpers.knockbackTarget(caster_index, valid_targets, push_distance, game_state) orelse return &.{};
    const defender_index = helpers.hostileEntityAt(caster_index, target, game_state) orelse return &.{};
    const rating: u32 = if (helpers.knockbackWouldCollide(caster_index, defender_index, push_distance, game_state)) 3 else 2;
    return helpers.singleOption(allocator, .{ .target = target, .priority = rating });
}

/// AI target selection for the knockback: prefer a target the push will
/// collide, then the focus-fire order (helpers.knockbackTarget).
fn playerPrepareSkill(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?Event {
    return helpers.highlightTargets(getValidTargets(caster_index, game_state, allocator));
}

/// Use: attack for 1x main-hand damage, then knock back. Collision damage is
/// +0.5x the effective outgoing main-hand damage (same outgoing modifiers as
/// the attack; the knockback handler applies it only on collision and runs
/// the defender's incoming modifiers).
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

    const main_hand_damage: u32 = if (caster.main_hand_weapon) |weapon| weapon.weapon_damage else 0;
    // Both attack and collision damage derive from the effective outgoing
    // damage (gloves + converted momentum + outgoing effects), then scale —
    // collision is half. Mirrors how `attack` applies outgoing modifiers at
    // the skill site; the collision handler still applies only the
    // defender's incoming modifiers.
    const damage = caster.getEffectiveOutgoingDamage(main_hand_damage);
    const collision_damage = damage / 2; // +0.5x effective outgoing
    const push_distance = caster.getEffectiveDistance(skill.distance.?);

    return helpers.ownedEvents(allocator, &.{
        .{ .sub_level_event = .{ .attack = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .outgoing_damage = damage,
        } } },
        .{ .sub_level_event = .{ .knockback = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .distance = push_distance,
            .knockback_damage = collision_damage,
        } } },
    });
}
