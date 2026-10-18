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

/// Flash Strike: an off-hand skill. Teleports to an empty tile within range,
/// then attacks every hostile within radius of the landing.
pub const skill = Skill{
    .name = "Flash Strike",
    .skill_type = .weapon_skill,
    .deals_damage = true,
    .description = "Teleport then attack each target within radius",
    .uses_targeting = true,
    .range = 3,
    .radius = 1,
    .distance = null,
    .skill_duration = null,
    .stun_duration = null,
    .cooldown = 3,
    .get_valid_targets_fn = &getValidTargets,
    .ai_options_fn = &aiOptions,
    .player_prepare_skill_fn = &playerPrepareSkill,
    .use_skill_fn = &useSkill,
};

/// Valid targets are empty teleport tiles within range.
fn getValidTargets(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?[]const Vector2 {
    const caster = (game_state.level orelse return null).entities[caster_index];
    const range: i32 = @intCast(caster.getEffectiveRange(skill.range.?));
    return helpers.emptyTilesInRange(caster_index, game_state, range, allocator);
}

/// AI options: the BEST landing tile - max hostiles within radius over
/// the empty tiles in range (strict > keeps the first in scan order, the
/// (y, x) convention), rated in value units: base 2 (the teleport is a
/// hit's worth of gap-closing) + 1 per target hit.
/// The cast lands exactly where the rating was earned; the old
/// selectTarget picked the tile nearest a hostile instead - that
/// rating/landing seam is gone.
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
    _: *skill_mod.EvalFrame,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.flash_strike) > 0) return &.{};
    const range: i32 = @intCast(caster.getEffectiveRange(skill.range.?));
    const radius: i32 = @intCast(caster.getEffectiveRadius(skill.radius.?));

    var best_tile: ?Vector2 = null;
    var best_count: u32 = 0;
    var delta_y: i32 = -range;
    while (delta_y <= range) : (delta_y += 1) {
        var delta_x: i32 = -range;
        while (delta_x <= range) : (delta_x += 1) {
            if (delta_x == 0 and delta_y == 0) continue;
            const tile = Vector2{ .x = caster.position.x + delta_x, .y = caster.position.y + delta_y };
            if (!helpers.tileExists(game_state, tile)) continue;
            if (helpers.isOccupied(game_state, tile, null)) continue;
            const count = helpers.hostileCountWithinRadius(caster_index, game_state, tile, radius);
            if (count > best_count) {
                best_count = count;
                best_tile = tile;
            }
        }
    }

    const tile = best_tile orelse return &.{};
    return helpers.singleOption(allocator, .{ .target = tile, .priority = helpers.aoePriority(best_count, 2) });
}

fn playerPrepareSkill(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?Event {
    return helpers.highlightTargets(getValidTargets(caster_index, game_state, allocator));
}

/// Use: teleport to the target tile, then attack every hostile within radius of
/// the landing for off-hand damage. Move runs first, then the attacks.
fn useSkill(
    caster_index: u32,
    target: ?Vector2,
    game_state: GameState,
    allocator: std.mem.Allocator,
) []const Event {
    const landing = target orelse return &.{};
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];

    const radius: i32 = @intCast(caster.getEffectiveRadius(skill.radius.?));
    const target_indices = helpers.hostileIndicesInRadius(caster_index, game_state, landing, radius, allocator);

    const off_hand_damage: u32 = if (caster.off_hand_weapon) |weapon| weapon.weapon_damage else 0;
    const damage = caster.getEffectiveOutgoingDamage(off_hand_damage);

    var skill_events: std.ArrayList(Event) = .empty;
    // Teleport first.
    skill_events.append(allocator, .{ .level_event = .{ .move_entity = .{
        .entity_index = caster_index,
        .destination = landing,
    } } }) catch @panic("failed to append move event");
    // Then attack each hostile around the landing.
    for (target_indices) |defender_index| {
        skill_events.append(allocator, .{ .sub_level_event = .{ .attack = .{
            .attacker_index = caster_index,
            .defender_index = defender_index,
            .outgoing_damage = damage,
        } } }) catch @panic("failed to append attack event");
    }

    return helpers.ownedEvents(allocator, skill_events.items);
}
