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

/// Chain Lightning: a spell. Attacks the target and every hostile connected
/// to it via neighboring hostiles - the connected component (by the
/// skill's EFFECTIVE radius, Chebyshev) containing the target. Allies are
/// not chain nodes, so a hostile line broken by an ally does not conduct:
/// lightning arcs between enemies only.
pub const skill = Skill{
    .name = "Chain Lightning",
    .skill_type = .spell,
    .deals_damage = true,
    .description = "Attack target and each target connected to it via neighboring entities",
    .uses_targeting = true,
    .range = 1,
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

fn getValidTargets(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?[]const Vector2 {
    const caster = (game_state.level orelse return null).entities[caster_index];
    const range: i32 = @intCast(caster.getEffectiveRange(skill.range.?));
    return helpers.hostilesInRange(caster_index, game_state, range, allocator);
}

/// AI options: the initial target whose connected component is LARGEST
/// (ties by the focus-fire tail - health, distance, entity index), rated
/// in value units: 1 per chained enemy (helpers.aoePriority over the
/// component size). A 1-link chain rates like a plain attack; a 3-web
/// rates 3.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
    _: *skill_mod.EvalFrame,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.chain_lightning) > 0) return &.{};

    const radius: i32 = @intCast(caster.getEffectiveRadius(skill.radius.?));
    const valid_targets = getValidTargets(caster_index, game_state, allocator) orelse return &.{};
    if (valid_targets.len == 0) return &.{};

    var best: ?Vector2 = null;
    var best_size: u32 = 0;
    var best_health: u32 = std.math.maxInt(u32);
    var best_distance: i32 = std.math.maxInt(i32);
    var best_entity_index: u32 = std.math.maxInt(u32);
    for (valid_targets) |position| {
        const entity_index = helpers.hostileEntityAt(caster_index, position, game_state) orelse continue;
        const entity = level.entities[entity_index];
        const component = chainComponentIndices(caster_index, position, radius, game_state, allocator);
        const size: u32 = @intCast(component.len);
        const distance = functions.chebyshevDistance(caster.position, position);
        if (best == null or size > best_size or
            (size == best_size and entity.current_health < best_health) or
            (size == best_size and entity.current_health == best_health and distance < best_distance) or
            (size == best_size and entity.current_health == best_health and distance == best_distance and entity_index < best_entity_index))
        {
            best = position;
            best_size = size;
            best_health = entity.current_health;
            best_distance = distance;
            best_entity_index = entity_index;
        }
    }

    const target = best orelse return &.{};
    return helpers.singleOption(allocator, .{
        .target = target,
        .priority = helpers.aoePriority(best_size, 1),
    });
}

fn playerPrepareSkill(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?Event {
    return helpers.highlightTargets(getValidTargets(caster_index, game_state, allocator));
}

/// Use: attack the target and every hostile in its connected component for
/// 1x effective spell damage.
fn useSkill(
    caster_index: u32,
    target: ?Vector2,
    game_state: GameState,
    allocator: std.mem.Allocator,
) []const Event {
    const target_position = target orelse return &.{};
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];

    const radius: i32 = @intCast(caster.getEffectiveRadius(skill.radius.?));
    const component = chainComponentIndices(caster_index, target_position, radius, game_state, allocator);
    if (component.len == 0) return &.{};

    const damage = caster.getEffectiveSpellDamage();

    var skill_events: std.ArrayList(Event) = .empty;
    for (component) |defender_index| {
        skill_events.append(allocator, .{ .sub_level_event = .{ .attack = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .outgoing_damage = damage,
        } } }) catch @panic("failed to append attack event");
    }

    return helpers.ownedEvents(allocator, skill_events.items);
}

/// The connected component of hostiles containing the hostile at
/// `start_position`: flood fill over hostiles where two hostiles within
/// `radius` (Chebyshev) of each other are connected, transitively. Allies
/// are not nodes - they cannot conduct, so two hostiles only bridge if
/// they are within radius of each other themselves. Discovery order is
/// BFS from the start (deterministic). Empty if no hostile stands at the
/// start.
fn chainComponentIndices(
    caster_index: u32,
    start_position: Vector2,
    radius: i32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) []const u32 {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];

    var start_index: ?u32 = null;
    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.current_health == 0) continue;
        if (entity.team == caster.team) continue;
        if (entity.position.x == start_position.x and entity.position.y == start_position.y) {
            start_index = @intCast(entity_index);
            break;
        }
    }
    const start = start_index orelse return &.{};

    const visited = allocator.alloc(bool, level.entities.len) catch
        @panic("failed to allocate chain visited set");
    @memset(visited, false);
    visited[start] = true;

    var component: std.ArrayList(u32) = .empty;
    component.append(allocator, start) catch @panic("failed to allocate chain component");

    // Append-only queue with a marching cursor (no removal needed).
    var cursor: usize = 0;
    while (cursor < component.items.len) : (cursor += 1) {
        const current_position = level.entities[component.items[cursor]].position;
        for (level.entities, 0..) |entity, entity_index| {
            if (visited[entity_index]) continue;
            if (entity_index == caster_index) continue;
            if (entity.current_health == 0) continue;
            if (entity.team == caster.team) continue;
            if (functions.chebyshevDistance(current_position, entity.position) <= radius) {
                visited[entity_index] = true;
                component.append(allocator, @intCast(entity_index)) catch
                    @panic("failed to allocate chain component");
            }
        }
    }

    return component.items;
}
