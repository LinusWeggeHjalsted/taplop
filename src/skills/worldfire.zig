const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");
const skill_mod = @import("skill.zig");
const helpers = @import("helpers.zig");

const Vector2 = types.Vector2;
const GameState = state.GameState;
const Event = events.Event;
const Skill = skill_mod.Skill;

/// Worldfire: a spell. Attacks every hostile within a large radius of the
/// caster for 1x effective spell damage (amulet-based — see
/// Entity.getEffectiveSpellDamage). Self-centered — not targeted. The long
/// cooldown makes it the "save it for clusters" nuke: the AoE bump rating
/// encodes that posture for the AI for free (a single-target cast ties the
/// basic attack at 3 and loses to slot order; a cluster rates 4).
pub const skill = Skill{
    .name = "Worldfire",
    .skill_type = .spell,
    .deals_damage = true,
    .description = "Attack each target within radius",
    .uses_targeting = false,
    .range = null,
    .radius = 5,
    .distance = null,
    .skill_duration = null,
    .stun_duration = null,
    .cooldown = 10,
    .get_valid_targets_fn = &getValidTargets,
    .ai_options_fn = &aiOptions,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

/// Self-centered — no targeting.
fn getValidTargets(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Vector2 {
    return null;
}

/// AI options: one self-centered cast, rated by the AoE bump convention
/// (helpers.aoePriority over the hostile count in radius) — 3 with one
/// target, 4 with two or more.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.worldfire) > 0) return &.{};

    const radius: i32 = @intCast(caster.getEffectiveRadius(skill.radius.?));
    const target_count = helpers.hostileCountWithinRadius(caster_index, game_state, caster.position, radius);
    if (target_count == 0) return &.{};
    return helpers.singleOption(allocator, .{
        .target = null,
        .priority = helpers.aoePriority(target_count, 3),
    });
}

/// Self-centered — fires immediately.
fn playerPrepareSkill(_: u32, _: GameState, _: std.mem.Allocator) ?Event {
    return null;
}

/// Use: attack every hostile within radius for 1x effective spell damage.
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

    const damage = caster.getEffectiveSpellDamage();

    var skill_events: std.ArrayList(Event) = .empty;
    for (target_indices) |defender_index| {
        skill_events.append(allocator, .{ .sub_level_event = .{ .attack = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .outgoing_damage = damage,
        } } }) catch @panic("failed to append attack event");
    }

    return helpers.ownedEvents(allocator, skill_events.items);
}
