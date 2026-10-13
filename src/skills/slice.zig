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

/// Slice: a basic sword skill.
/// Attacks a single target within range.
/// Deals 1.5x main hand damage if the target is below half health.
pub const skill = Skill{
    .name = "Slice",
    .skill_type = .weapon_skill,
    .deals_damage = true,
    .description = "Attack target, dealing 1.5x damage if they have less than half health",
    .uses_targeting = true,
    .range = 1,
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

/// Returns positions of all hostile entities within range of the caster.
fn getValidTargets(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?[]const Vector2 {
    const caster = (game_state.level orelse return null).entities[caster_index];
    const range: i32 = @intCast(caster.getEffectiveRange(skill.range.?));
    return helpers.hostilesInRange(caster_index, game_state, range, allocator);
}

/// AI options: the weakest hostile (focus-fire). Rated 2 when the pick is
/// wounded (below half — the 1.5x bonus is worth ~a hit), else 1 (value units).
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
    _: *skill_mod.EvalFrame,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.slice) > 0) return &.{};

    const valid_targets = getValidTargets(caster_index, game_state, allocator);
    const target = helpers.weakestTarget(caster_index, valid_targets, game_state) orelse return &.{};
    const defender_index = helpers.hostileEntityAt(caster_index, target, game_state) orelse return &.{};
    const defender = level.entities[defender_index];
    const rating: u32 = if (defender.current_health * 2 < defender.getEffectiveMaxHealth()) 2 else 1;
    return helpers.singleOption(allocator, .{ .target = target, .priority = rating });
}

/// Player prepare: returns a highlight_tiles event for all valid target positions.
fn playerPrepareSkill(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?Event {
    return helpers.highlightTargets(getValidTargets(caster_index, game_state, allocator));
}

/// Use the skill: push an attack event against the target.
/// Deals 1.5x main hand damage if target is below half health.
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
    const defender = level.entities[defender_index];

    // Damage: 1.5x if the target is below half health.
    const base_damage: u32 = if (caster.main_hand_weapon) |weapon| weapon.weapon_damage else 0;
    var damage: u32 = caster.getEffectiveOutgoingDamage(base_damage);
    if (defender.current_health * 2 < defender.getEffectiveMaxHealth()) {
        damage = helpers.damageTimesOneAndAHalf(damage);
    }

    return helpers.ownedEvents(allocator, &.{
        .{ .sub_level_event = .{ .attack = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .outgoing_damage = damage,
        } } },
    });
}
