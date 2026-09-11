const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");
const skill_mod = @import("../skill.zig");
const helpers = @import("../skill_helpers.zig");

const Vector2 = types.Vector2;
const GameState = state.GameState;
const Event = events.Event;
const Skill = skill_mod.Skill;

/// Drain: the idol's third (off-hand) skill. Attacks every hostile within
/// radius of the caster and heals for the damage dealt — each hit
/// lifesteals (the heals_attacker flag heals the POST-DEFENSE applied
/// amount, which the skill cannot know ahead of the handler). Self-centered
/// — not targeted.
pub const skill = Skill{
    .name = "Drain",
    .skill_type = .weapon_skill,
    .deals_damage = true,
    .point_blank_area_of_effect = true,
    .description = "Attack each target within radius and heal for damage dealt",
    .uses_targeting = false,
    .range = null,
    .radius = 1,
    .distance = null,
    .skill_duration = null,
    .stun_duration = null,
    .cooldown = 5,
    .get_valid_targets_fn = &getValidTargets,
    .ai_options_fn = &aiOptions,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

/// Self-centered — no targeting.
fn getValidTargets(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Vector2 {
    return null;
}

/// AI options: one self-centered cast in value units — 1 per target hit
/// (helpers.hostileCountWithinRadius), +1 more when the caster is below
/// half health (the per-hit lifesteal then pays ~a hit's worth). Priority
/// note: threatened + below half, Absorb's 4 wins (and ties resolve to
/// Absorb by slot order) — prevention first, per the threat model.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
    _: *skill_mod.EvalFrame,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.drain) > 0) return &.{};
    const radius: i32 = @intCast(caster.getEffectiveRadius(skill.radius.?));
    const target_count = helpers.hostileCountWithinRadius(caster_index, game_state, caster.position, radius);
    if (target_count == 0) return &.{};
    // Value units: 1 per target hit, +1 more when the caster is below half
    // health (the per-hit lifesteal then pays ~a hit's worth).
    const lifesteal_bonus: u32 = @intFromBool(caster.current_health * 2 < caster.getEffectiveMaxHealth());
    return helpers.singleOption(allocator, .{ .target = null, .priority = target_count + lifesteal_bonus });
}

/// Self-centered — fires immediately.
fn playerPrepareSkill(_: u32, _: GameState, _: std.mem.Allocator) ?Event {
    return null;
}

/// Use: attack every hostile within radius for 1x off-hand damage, each hit
/// lifestealing the applied damage (the heal handler clamps to max).
fn useSkill(
    caster_index: u32,
    _: ?Vector2,
    game_state: GameState,
    allocator: std.mem.Allocator,
) []const Event {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];

    const radius: i32 = @intCast(caster.getEffectiveRadius(skill.radius.?));
    const target_indices = helpers.hostileIndicesInRadius(caster_index, game_state, caster.position, radius, allocator);
    if (target_indices.len == 0) return &.{};

    const off_hand_damage: u32 = if (caster.off_hand_weapon) |weapon| weapon.weapon_damage else 0;
    const damage = caster.getEffectiveOutgoingDamage(off_hand_damage);

    var skill_events: std.ArrayList(Event) = .empty;
    for (target_indices) |defender_index| {
        skill_events.append(allocator, .{ .sub_level_event = .{ .attack = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .outgoing_damage = damage,
            .heals_attacker = true,
        } } }) catch @panic("failed to append attack event");
    }

    return helpers.ownedEvents(allocator, skill_events.items);
}
