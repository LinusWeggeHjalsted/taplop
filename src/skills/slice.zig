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
    .priority_fn = &priority,
    .select_target_fn = &selectTarget,
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

/// AI priority for using Slice.
/// Returns 0 if on cooldown or no targets in range.
/// Returns 3 normally, 2 if target (nearest hostile) is below half health
/// (prefer a different finisher skill for wounded targets).
fn priority(caster_index: u32, game_state: GameState, _: types.WeaponTypeDefinitions) u32 {
    const level = game_state.level orelse return 0;
    const caster = level.entities[caster_index];

    // Check cooldown
    if (caster.skill_cooldowns.get(.slice) > 0) return 0;

    const range: i32 = @intCast(caster.getEffectiveRange(skill.range.?));

    // Find hostiles in range; note whether any is below half health (integer
    // compare: current * 2 < max), which is when Slice's 1.5x bonus pays off.
    var found_target = false;
    var found_wounded_target = false;
    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.current_health == 0) continue;
        if (entity.team == caster.team) continue;
        if (functions.chebyshevDistance(caster.position, entity.position) <= range) {
            found_target = true;
            if (entity.current_health * 2 < entity.getEffectiveMaxHealth()) {
                found_wounded_target = true;
            }
        }
    }

    if (!found_target) return 0;

    // Higher priority when a target is wounded — that's when Slice's bonus kicks in.
    if (found_wounded_target) return 3;
    return 2;
}

/// AI target selection: the weakest hostile (focus-fire — helpers.weakestTarget).
fn selectTarget(
    caster_index: u32,
    valid_targets: ?[]const Vector2,
    game_state: GameState,
) ?Vector2 {
    return helpers.weakestTarget(caster_index, valid_targets, game_state);
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

    // Damage: 1.5x if the target is below half health (integer math).
    const base_damage: u32 = if (caster.main_hand_weapon) |weapon| weapon.weapon_damage else 0;
    var damage: u32 = caster.getEffectiveOutgoingDamage(base_damage);
    if (defender.current_health * 2 < defender.getEffectiveMaxHealth()) {
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

