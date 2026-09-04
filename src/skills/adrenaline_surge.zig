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
const WeaponTypeDefinitions = types.WeaponTypeDefinitions;

/// Adrenaline Surge: a spell. Resets the target's on-bar cooldowns (all
/// skills of both its equipped weapons — swap-available thirds included —
/// plus its equipped utility skills) and attacks it once per cooldown reset
/// this way. A well-timed finisher: the more the enemy has on cooldown, the
/// harder it is hit — at the cost of re-arming it if it survives.
pub const skill = Skill{
    .name = "Adrenaline Surge",
    .skill_type = .spell,
    .deals_damage = true,
    .description = "Reset all target's skill cooldowns and attack target for each skill cooldown reset this way",
    .uses_targeting = true,
    .range = 1,
    .radius = null,
    .distance = null,
    .skill_duration = null,
    .stun_duration = null,
    .cooldown = 5,
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

/// The number of the entity's on-bar skills currently on cooldown —
/// Adrenaline Surge's reset (and attack) count. Shared enumeration with
/// the handler (Entity.onBarSkillIds) so rating and effect cannot drift.
fn tickingOnBarCooldownCount(
    entity: types.Entity,
    weapon_type_definitions: WeaponTypeDefinitions,
) u32 {
    var count: u32 = 0;
    for (entity.onBarSkillIds(weapon_type_definitions)) |maybe_skill_id| {
        const skill_id = maybe_skill_id orelse continue;
        if (entity.skill_cooldowns.get(skill_id) > 0) count += 1;
    }
    return count;
}

/// AI options: the target with the MOST on-bar cooldowns ticking (ties by
/// the focus-fire tail), rated = the reset count in value units — one
/// plain hit per reset. No option when nothing ticks (the cast would do
/// nothing). The re-arm cost if the target survives is a balance matter,
/// not a rating one.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.adrenaline_surge) > 0) return &.{};

    const valid_targets = getValidTargets(caster_index, game_state, allocator) orelse return &.{};
    if (valid_targets.len == 0) return &.{};

    var best: ?Vector2 = null;
    var best_count: u32 = 0;
    var best_health: u32 = std.math.maxInt(u32);
    var best_distance: i32 = std.math.maxInt(i32);
    var best_entity_index: u32 = std.math.maxInt(u32);
    for (valid_targets) |position| {
        const entity_index = helpers.hostileEntityAt(caster_index, position, game_state) orelse continue;
        const entity = level.entities[entity_index];
        const count = tickingOnBarCooldownCount(entity, weapon_type_definitions);
        if (count == 0) continue;
        const distance = @as(i32, @intCast(functions.chebyshevDistance(caster.position, position)));
        if (best == null or count > best_count or
            (count == best_count and entity.current_health < best_health) or
            (count == best_count and entity.current_health == best_health and distance < best_distance) or
            (count == best_count and entity.current_health == best_health and distance == best_distance and entity_index < best_entity_index))
        {
            best = position;
            best_count = count;
            best_health = entity.current_health;
            best_distance = distance;
            best_entity_index = entity_index;
        }
    }

    const target = best orelse return &.{};
    return helpers.singleOption(allocator, .{ .target = target, .priority = best_count });
}

fn playerPrepareSkill(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?Event {
    return helpers.highlightTargets(getValidTargets(caster_index, game_state, allocator));
}

/// Use: delegate to the adrenaline_surge machinery event — the reset
/// enumeration (and therefore the attack count) needs the session's
/// weapon-type definitions, which useSkill cannot reach (the
/// reset_weapon_cooldowns precedent). The handler resets first, then
/// attacks once per reset.
fn useSkill(
    caster_index: u32,
    target: ?Vector2,
    game_state: GameState,
    allocator: std.mem.Allocator,
) []const Event {
    const target_position = target orelse return &.{};

    const defender_index = helpers.hostileEntityAt(caster_index, target_position, game_state) orelse return &.{};

    return helpers.ownedEvents(allocator, &.{
        .{ .sub_level_event = .{ .adrenaline_surge = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
        } } },
    });
}

