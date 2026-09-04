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

/// Meteor: a main-hand staff skill. Attacks every hostile within radius of
/// the target tile for main-hand damage. The target is the strike's CENTER,
/// not a destination — every existing tile within range is legal, including
/// occupied tiles and the caster's own tile (a point-blank cast).
pub const skill = Skill{
    .name = "Meteor",
    .skill_type = .weapon_skill,
    .deals_damage = true,
    .description = "Attack each target within radius of target tile",
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

/// Valid targets: every existing tile within range — the strike center, so
/// occupancy doesn't matter (contrast Flash Strike's empty-tile constraint,
/// which exists because it teleports).
fn getValidTargets(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?[]const Vector2 {
    const caster = (game_state.level orelse return null).entities[caster_index];
    const range: i32 = @intCast(caster.getEffectiveRange(skill.range.?));

    var positions: std.ArrayList(Vector2) = .empty;
    var delta_y: i32 = -range;
    while (delta_y <= range) : (delta_y += 1) {
        var delta_x: i32 = -range;
        while (delta_x <= range) : (delta_x += 1) {
            const position = Vector2{ .x = caster.position.x + delta_x, .y = caster.position.y + delta_y };
            if (helpers.tileExists(game_state, position)) {
                positions.append(allocator, position) catch @panic("failed to append target tile");
            }
        }
    }
    if (positions.items.len == 0) return null;
    return positions.items;
}

/// AI options: the tile with the MOST hostiles within radius — the best
/// strike center over every tile in range, occupied tiles included (a
/// hostile ON the tile is a direct hit at distance 0). Strict > keeps the
/// first tile in (y, x) scan order, the tiebreak convention. Rated in value
/// units (helpers.aoePriority): 1 per target hit — a single-target cast ties
/// the plain attack and loses to slot order, so the staff saves it for
/// clusters (the Worldfire posture at a third of the cooldown).
fn aiOptions(
    caster_index: u32,
    game_state: GameState,
    _: types.WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) []const skill_mod.AiOption {
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];
    if (caster.skill_cooldowns.get(.meteor) > 0) return &.{};
    const range: i32 = @intCast(caster.getEffectiveRange(skill.range.?));
    const radius: i32 = @intCast(caster.getEffectiveRadius(skill.radius.?));

    var best_tile: ?Vector2 = null;
    var best_count: u32 = 0;
    var delta_y: i32 = -range;
    while (delta_y <= range) : (delta_y += 1) {
        var delta_x: i32 = -range;
        while (delta_x <= range) : (delta_x += 1) {
            const tile = Vector2{ .x = caster.position.x + delta_x, .y = caster.position.y + delta_y };
            if (!helpers.tileExists(game_state, tile)) continue;
            const count = helpers.hostileCountWithinRadius(caster_index, game_state, tile, radius);
            if (count > best_count) {
                best_count = count;
                best_tile = tile;
            }
        }
    }

    const tile = best_tile orelse return &.{};
    return helpers.singleOption(allocator, .{
        .target = tile,
        .priority = helpers.aoePriority(best_count, 1),
    });
}

fn playerPrepareSkill(
    caster_index: u32,
    game_state: GameState,
    allocator: std.mem.Allocator,
) ?Event {
    return helpers.highlightTargets(getValidTargets(caster_index, game_state, allocator));
}

/// Use: attack every hostile within radius of the target tile for
/// main-hand damage (the Spark damage model).
fn useSkill(
    caster_index: u32,
    target: ?Vector2,
    game_state: GameState,
    allocator: std.mem.Allocator,
) []const Event {
    const center = target orelse return &.{};
    const level = game_state.level orelse return &.{};
    const caster = level.entities[caster_index];

    const radius: i32 = @intCast(caster.getEffectiveRadius(skill.radius.?));
    const target_indices = helpers.hostileIndicesInRadius(caster_index, game_state, center, radius, allocator);
    if (target_indices.len == 0) return &.{};

    const main_hand_damage: u32 = if (caster.main_hand_weapon) |weapon| weapon.weapon_damage else 0;
    const damage = caster.getEffectiveOutgoingDamage(main_hand_damage);

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
