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

/// Stab: a basic sword skill.
/// Attacks a single target within range.
/// Deals 1.5x main hand damage if the target is above half health.
pub const skill = Skill{
    .name = "Stab",
    .skill_type = .weapon_skill,
    .deals_damage = true,
    .description = "Attack target, dealing 1.5x damage if they have more than half health",
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

/// Positions of all hostile entities within range of the caster.
fn getValidTargets(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?[]const Vector2 {
    const caster = (game_state.level orelse return null).entities[caster_index];
    const range: i32 = @intCast(caster.getEffectiveRange(skill.range.?));
    return helpers.hostilesInRange(caster_index, game_state, range, allocator);
}

/// AI priority: 0 if on cooldown or no targets in range. Otherwise prefer a
/// healthy target (Stab's 1.5x bonus applies above half health): 3 if any
/// in-range hostile is above half health, else 2.
/// AI options: the weakest hostile (focus-fire). Rated on the PICK: 3 when
/// it is above half health (Stab's 1.5x bonus applies there), else 2. The
/// old priority summarized "any healthy target in range" — it could rate 3
/// while selection attacked a wounded target the bonus doesn't pay on.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.stab) > 0) return &.{};

    const valid_targets = getValidTargets(caster_index, game_state, allocator);
    const target = helpers.weakestTarget(caster_index, valid_targets, game_state) orelse return &.{};
    const defender_index = helpers.hostileEntityAt(caster_index, target, game_state) orelse return &.{};
    const defender = level.entities[defender_index];
    const rating: u32 = if (defender.current_health * 2 > defender.getEffectiveMaxHealth()) 3 else 2;
    return helpers.singleOption(allocator, .{ .target = target, .priority = rating });
}

/// AI target selection: the weakest hostile (focus-fire — helpers.weakestTarget).
/// Player prepare: highlight all valid target positions.
fn playerPrepareSkill(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?Event {
    return helpers.highlightTargets(getValidTargets(caster_index, game_state, allocator));
}

/// Use: attack the target, dealing 1.5x damage if it is above half health.
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

    // Damage: 1.5x if the target is above half health (integer math).
    const base_damage: u32 = if (caster.main_hand_weapon) |weapon| weapon.weapon_damage else 0;
    var damage: u32 = caster.getEffectiveOutgoingDamage(base_damage);
    if (defender.current_health * 2 > defender.getEffectiveMaxHealth()) {
        damage = damage + damage / 2;
    }

    return helpers.ownedEvents(allocator, &.{
        .{ .sub_level_event = .{ .attack = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .outgoing_damage = damage,
        } } },
    });
}
