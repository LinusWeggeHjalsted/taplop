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

/// Meditate: a cantrip. Resets the cooldown of each OTHER equipped
/// utility skill (Meditate itself excluded). Self-cast, non-turn-ending.
/// Simpler than Focus: utility slots live on the entity itself, so useSkill
/// composes change_cooldown directly - no defs, no machinery event.
pub const skill = Skill{
    .name = "Meditate",
    .skill_type = .cantrip,
    .deals_damage = false,
    .description = "Reset each other equipped utility skill cooldown",
    .uses_targeting = false,
    .range = null,
    .radius = null,
    .distance = null,
    .skill_duration = null,
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

/// The number of OTHER equipped utility skills currently ticking -
/// Meditate's reset count (and, in value units, its rating).
fn otherTickingUtilityCount(caster: types.Entity) u32 {
    var count: u32 = 0;
    for (caster.equipped_utility_skills) |maybe_skill_id| {
        const skill_id = maybe_skill_id orelse continue;
        if (skill_id == .meditate) continue;
        if (caster.skill_cooldowns.get(skill_id) > 0) count += 1;
    }
    return count;
}

/// AI options: one self-cast, rated = the reset count in value units.
/// Non-ending pool: the rating only orders the cantrips. No option when
/// nothing else is ticking (the cast would do nothing).
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
    _: *skill_mod.EvalFrame,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.meditate) > 0) return &.{};

    const count = otherTickingUtilityCount(caster);
    if (count == 0) return &.{};
    return helpers.singleOption(allocator, .{ .target = null, .priority = count });
}

/// Self-cast - fires immediately.
fn playerPrepareSkill(_: u32, _: GameState, _: std.mem.Allocator) ?Event {
    return null;
}

/// Use: reset each other equipped utility skill's cooldown (composes the
/// change_cooldown primitive; slot order).
fn useSkill(
    caster_index: u32,
    _: ?Vector2,
    game_state: GameState,
    allocator: std.mem.Allocator,
) []const Event {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];

    var skill_events: std.ArrayList(Event) = .empty;
    for (caster.equipped_utility_skills) |maybe_skill_id| {
        const skill_id = maybe_skill_id orelse continue;
        if (skill_id == .meditate) continue;
        const current_cooldown = caster.skill_cooldowns.get(skill_id);
        if (current_cooldown == 0) continue;
        skill_events.append(allocator, .{ .sub_level_event = .{ .change_cooldown = .{
            .entity_index = caster_index,
            .skill_id = skill_id,
            .delta = -@as(i32, @intCast(current_cooldown)),
        } } }) catch @panic("failed to append meditate reset");
    }

    return helpers.ownedEvents(allocator, skill_events.items);
}
