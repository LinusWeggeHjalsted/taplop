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

/// Spark: a main-hand ranged skill. Attacks a single target and removes 1
/// momentum from it.
pub const skill = Skill{
    .name = "Spark",
    .skill_type = .weapon_skill,
    .description = "Attack target and remove 1 momentum from them",
    .uses_targeting = true,
    .range = 3,
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

fn getValidTargets(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?[]const Vector2 {
    const caster = (game_state.level orelse return null).entities[caster_index];
    const range: i32 = @intCast(caster.getEffectiveRange(skill.range.?));
    return helpers.hostilesInRange(caster_index, game_state, range, allocator);
}

/// AI priority: 0 if on cooldown or no target in range, else 2.
fn priority(caster_index: u32, game_state: GameState) u32 {
    const level = game_state.level orelse return 0;
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.spark) > 0) return 0;

    const range: i32 = @intCast(caster.getEffectiveRange(skill.range.?));
    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.current_health == 0) continue;
        if (entity.team == caster.team) continue;
        if (functions.chebyshevDistance(caster.position, entity.position) <= range) return 2;
    }
    return 0;
}

/// AI target selection: the weakest hostile (focus-fire — helpers.weakestTarget).
fn selectTarget(
    caster_index: u32,
    valid_targets: ?[]const Vector2,
    game_state: GameState,
) ?Vector2 {
    return helpers.weakestTarget(caster_index, valid_targets, game_state);
}

fn playerPrepareSkill(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?Event {
    return helpers.highlightTargets(getValidTargets(caster_index, game_state, allocator));
}

/// Use: attack for main-hand damage, then remove 1 momentum from the target.
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
    const damage = caster.getEffectiveOutgoingDamage(main_hand_damage);

    return helpers.ownedEvents(allocator, &.{
        .{ .sub_level_event = .{ .attack = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .outgoing_damage = damage,
        } } },
        .{ .sub_level_event = .{ .change_momentum = .{
            .entity_index = defender_index,
            .delta = -1,
        } } },
    });
}
