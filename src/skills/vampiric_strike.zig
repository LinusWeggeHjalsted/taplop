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

/// Vampiric Strike: a main-hand skill.
/// Attacks a single target and heals the caster for the damage dealt.
pub const skill = Skill{
    .name = "Vampiric Strike",
    .skill_type = .weapon_skill,
    .deals_damage = true,
    .description = "Attack target and heal for damage dealt",
    .uses_targeting = true,
    .range = 1,
    .radius = null,
    .distance = null,
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

/// AI priority: 0 if on cooldown, no target in range, or the caster is already
/// at full health (nothing to heal — save it). Otherwise 3.
/// AI options: the weakest hostile (focus-fire) at rating 3 — offered only
/// below full health (the lifesteal is wasted at full).
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.vampiric_strike) > 0) return &.{};
    if (caster.current_health >= caster.getEffectiveMaxHealth()) return &.{};

    const valid_targets = getValidTargets(caster_index, game_state, allocator);
    const target = helpers.weakestTarget(caster_index, valid_targets, game_state) orelse return &.{};
    return helpers.singleOption(allocator, .{ .target = target, .priority = 3 });
}

/// AI target selection: the weakest hostile (focus-fire — helpers.weakestTarget).
fn playerPrepareSkill(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?Event {
    return helpers.highlightTargets(getValidTargets(caster_index, game_state, allocator));
}

/// Use: attack for main-hand damage; heals_attacker lets the attack handler
/// heal the caster for the actual damage dealt (see the damage pipeline).
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
            .heals_attacker = true,
        } } },
    });
}
