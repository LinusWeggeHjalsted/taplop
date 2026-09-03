//! AI movement-mode selection: the per-turn decision of HOW a non-player
//! entity moves — which reachable tile it seeks, and why. Pure functions
//! over (caster, game state); the `enemy_turn_move` handler wires them
//! into the turn flow (approach keeps its pathfinding there). Excluded
//! from the SkillId scan (see build.zig scanDir, with skill.zig /
//! helpers.zig / threat.zig). See DESIGN → Architecture (AI movement
//! modes).

const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const functions = @import("../functions.zig");
const lookups = @import("../generated_lookups.zig");
const helpers = @import("helpers.zig");
const threat = @import("threat.zig");

const Vector2 = types.Vector2;
const GameState = state.GameState;
const Entity = types.Entity;
const SkillId = types.SkillId;
const WeaponTypeDefinitions = types.WeaponTypeDefinitions;

/// How an entity moves on its turn. Selected fresh each `enemy_turn_move`,
/// off the CURRENT cooldown state — a point-blank skill on cooldown does
/// not shape that turn's movement (the entity kites or approaches instead,
/// and clusters again once the skill is ready).
pub const MovementMode = enum {
    /// Converge on the nearest hostile up to `computeMinRange` (the
    /// historical behavior, pathfinding in the handler).
    approach,
    /// Seek the reachable tile with the most hostiles inside an
    /// off-cooldown offensive point-blank skill's effective radius.
    point_blank_cluster,
    /// Open distance from the nearest hostile while staying able to act
    /// (some hostile within `computeMinRange`): stand-off kiting for
    /// entities whose whole kit outranges melee.
    keep_range,
};

/// Whether the entity has an OFF-COOLDOWN offensive point-blank area skill
/// on its combat bar — the trigger for cluster-seeking movement.
fn hasReadyOffensivePointBlankSkill(
    caster: Entity,
    weapon_type_definitions: WeaponTypeDefinitions,
) bool {
    const skill_ids = caster.collectSkillSlots(weapon_type_definitions);
    for (skill_ids) |maybe_skill_id| {
        const skill_id = maybe_skill_id orelse continue;
        if (caster.skill_cooldowns.get(skill_id) > 0) continue;
        const skill_definition = lookups.getSkillDefinition(skill_id) orelse continue;
        if (skill_definition.point_blank_area_of_effect and skill_definition.deals_damage) return true;
    }
    return false;
}

/// The movement mode for this entity's current turn. Priority: an
/// off-cooldown offensive point-blank skill makes the entity cluster-seek;
/// otherwise a kit whose minimum effective reach exceeds melee range
/// (> 1) kites at that reach; everything else approaches. Cooldown
/// dependent by design — see `MovementMode`.
pub fn selectMovementMode(
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: WeaponTypeDefinitions,
) MovementMode {
    const level = game_state.level orelse return .approach;
    const caster = level.entities[caster_index];
    if (hasReadyOffensivePointBlankSkill(caster, weapon_type_definitions)) {
        return .point_blank_cluster;
    }
    const min_range = threat.computeMinRange(caster, weapon_type_definitions) orelse
        return .approach;
    if (min_range > 1) return .keep_range;
    return .approach;
}

/// Most hostiles any of the ready point-blank skills' effective radii
/// would hit from `center`. Allocation-free per call.
fn pointBlankClusterScore(
    caster_index: u32,
    game_state: GameState,
    center: Vector2,
    radii: []const i32,
) u32 {
    var best: u32 = 0;
    for (radii) |radius| {
        const count = helpers.hostileCountWithinRadius(caster_index, game_state, center, radius);
        if (count > best) best = count;
    }
    return best;
}

/// The best cluster tile for the entity's off-cooldown offensive
/// point-blank skills: the reachable tile (current tile included) that has
/// the most hostiles within one of those skills' effective radius.
/// Null when no candidate has ANY hostile in radius (the caller should
/// approach instead — there is nothing to cluster around yet). The
/// current tile wins ties — an equal-count candidate never displaces it;
/// stay put unless a strictly more-targeted tile exists. Ties between
/// reachable tiles break by the (x, y) tile convention. A destination
/// equal to the caster's position means "stand and cast from here".
pub fn pointBlankClusterDestination(
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) ?Vector2 {
    const level = game_state.level orelse return null;
    const caster = level.entities[caster_index];

    // The ready skills' effective radii (bounded by the combat bar size).
    const skill_ids = caster.collectSkillSlots(weapon_type_definitions);
    var radii: [skill_ids.len]i32 = undefined;
    var radius_count: usize = 0;
    for (skill_ids) |maybe_skill_id| {
        const skill_id = maybe_skill_id orelse continue;
        if (caster.skill_cooldowns.get(skill_id) > 0) continue;
        const skill_definition = lookups.getSkillDefinition(skill_id) orelse continue;
        if (!skill_definition.point_blank_area_of_effect) continue;
        if (!skill_definition.deals_damage) continue;
        radii[radius_count] = @intCast(caster.getEffectiveRadius(skill_definition.radius.?));
        radius_count += 1;
    }

    const reachable = functions.reachableTiles(
        level,
        caster.position,
        caster.getEffectiveSpeed(),
        allocator,
    );

    // Current tile first so it wins score ties: an equal candidate NEVER
    // displaces the current tile (stay put unless a strictly better tile
    // exists — shuffling between equal clusters reads as noise to the
    // player); tileBefore only orders reachable-vs-reachable ties.
    var best_tile: Vector2 = caster.position;
    var best_score: u32 = pointBlankClusterScore(
        caster_index,
        game_state,
        caster.position,
        radii[0..radius_count],
    );
    for (reachable) |tile| {
        const tile_score = pointBlankClusterScore(
            caster_index,
            game_state,
            tile,
            radii[0..radius_count],
        );
        const incumbent_is_current = best_tile.x == caster.position.x and
            best_tile.y == caster.position.y;
        const is_better = tile_score > best_score or
            (tile_score == best_score and tile_score > 0 and
                !incumbent_is_current and functions.tileBefore(tile, best_tile));
        if (is_better) {
            best_score = tile_score;
            best_tile = tile;
        }
    }

    if (best_score == 0) return null;
    return best_tile;
}

/// Chebyshev distance from `center` to the nearest living hostile
/// (maxInt when none exist).
fn nearestHostileDistance(
    caster_index: u32,
    game_state: GameState,
    center: Vector2,
) i32 {
    const level = game_state.level orelse return std.math.maxInt(i32);
    const caster = level.entities[caster_index];
    var nearest: i32 = std.math.maxInt(i32);
    for (level.entities, 0..) |entity, entity_index| {
        if (entity_index == caster_index) continue;
        if (entity.current_health == 0) continue;
        if (entity.team == caster.team) continue;
        const distance = functions.chebyshevDistance(center, entity.position);
        if (distance < nearest) nearest = distance;
    }
    return nearest;
}

/// The stand-off tile for a kiting entity: among the reachable tiles
/// (current included) from which the entity can still act (some hostile
/// within `computeMinRange`), the one FARTHEST from its nearest hostile —
/// approach converges on min range from outside, kiting opens to it from
/// inside; both modes meet at the same distance. Null when no candidate
/// is act-capable (opponents beyond reach — the caller should approach).
/// The current tile wins ties — an equal-distance candidate never
/// displaces it; stay put unless a strictly farther act-capable tile
/// exists. Ties between reachable tiles break by the (x, y) tile
/// convention. A destination equal to the caster's position means
/// "stand and act from here" (cornered, or already at the standoff).
pub fn keepRangeDestination(
    caster_index: u32,
    game_state: GameState,
    weapon_type_definitions: WeaponTypeDefinitions,
    allocator: std.mem.Allocator,
) ?Vector2 {
    const level = game_state.level orelse return null;
    const caster = level.entities[caster_index];
    const min_range = threat.computeMinRange(caster, weapon_type_definitions) orelse return null;
    const standoff: i32 = @intCast(min_range);

    const reachable = functions.reachableTiles(
        level,
        caster.position,
        caster.getEffectiveSpeed(),
        allocator,
    );

    var best_tile: ?Vector2 = null;
    var best_distance: i32 = -1;

    // Current tile first so it wins distance ties.
    const current_distance = nearestHostileDistance(caster_index, game_state, caster.position);
    if (current_distance <= standoff) {
        best_tile = caster.position;
        best_distance = current_distance;
    }

    for (reachable) |tile| {
        const distance = nearestHostileDistance(caster_index, game_state, tile);
        // Act-capable only: some hostile within min range of the tile.
        if (distance > standoff) continue;
        // An equal candidate NEVER displaces the current tile (stay put
        // unless a strictly farther act-capable tile exists); tileBefore
        // only orders reachable-vs-reachable ties.
        const incumbent_is_current = best_tile != null and
            best_tile.?.x == caster.position.x and
            best_tile.?.y == caster.position.y;
        const is_better = best_tile == null or
            distance > best_distance or
            (distance == best_distance and !incumbent_is_current and
                functions.tileBefore(tile, best_tile.?));
        if (is_better) {
            best_tile = tile;
            best_distance = distance;
        }
    }

    return best_tile;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const test_harness = @import("../test_harness.zig");

/// Comptime rectangular tile grid (x in [0, width), y in [0, height)).
fn tileGrid(comptime width: i32, comptime height: i32) [width * height]types.Vector2 {
    var tiles: [width * height]types.Vector2 = undefined;
    var index: usize = 0;
    var y: i32 = 0;
    while (y < height) : (y += 1) {
        var x: i32 = 0;
        while (x < width) : (x += 1) {
            tiles[index] = .{ .x = x, .y = y };
            index += 1;
        }
    }
    return tiles;
}

/// Corridor grid: only column x = 1, y in [0, height) — movement is
/// forced along one axis, so stand-off distances are unambiguous.
fn corridorGrid(comptime height: i32) [height]types.Vector2 {
    var tiles: [height]types.Vector2 = undefined;
    for (0..height) |y| tiles[y] = .{ .x = 1, .y = @intCast(y) };
    return tiles;
}

fn setCooldown(game_state: GameState, entity_index: usize, skill_id: SkillId, cooldown: u32) void {
    @constCast(game_state.level.?.entities)[entity_index].skill_cooldowns.set(skill_id, cooldown);
}

test "selectMovementMode: off-cooldown point-blank skill cluster-seeks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    // Staff kit: spark (range 3) + daze (range 3) exposed on the main
    // hand, plus blitz (radius 1, point-blank, cooldown 5) exposed as the
    // OFF hand's third skill — the exposed-slot shape (collectSkillSlots,
    // the same pool enemy_turn_attack casts from).
    const nine_by_nine = tileGrid(9, 9);
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{.{
            .team = 1,
            .position = .{ .x = 4, .y = 4 },
            .main_hand_weapon = .{ .weapon_type = .staff },
            .off_hand_weapon = .{ .weapon_type = .staff },
        }},
        &nine_by_nine,
    );

    // Blitz ready -> cluster.
    try testing.expectEqual(
        MovementMode.point_blank_cluster,
        selectMovementMode(0, game_state, definitions),
    );

    // Blitz on cooldown -> no point-blank skill ready, and the kit's min
    // range is 3 (spark, never on cooldown) -> kite at that range.
    const cooldown_state = game_state;
    setCooldown(cooldown_state, 0, .blitz, 5);
    try testing.expectEqual(
        MovementMode.keep_range,
        selectMovementMode(0, cooldown_state, definitions),
    );
}

test "selectMovementMode: melee fallbacks approach" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    const nine_by_nine = tileGrid(9, 9);

    // Sword kit: slice (range 1) + spinblade (radius 1, point-blank).
    const sword_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{.{
            .team = 1,
            .position = .{ .x = 4, .y = 4 },
            .main_hand_weapon = .{ .weapon_type = .sword },
        }},
        &nine_by_nine,
    );
    try testing.expectEqual(
        MovementMode.point_blank_cluster,
        selectMovementMode(0, sword_state, definitions),
    );
    // Spinblade on cooldown -> slice's range 1 is the min range -> close in.
    const cooldown_state = sword_state;
    setCooldown(cooldown_state, 0, .spinblade, 2);
    try testing.expectEqual(
        MovementMode.approach,
        selectMovementMode(0, cooldown_state, definitions),
    );

    // No weapon at all -> nothing usable -> approach (computeMinRange null).
    const bare_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{.{ .team = 1, .position = .{ .x = 4, .y = 4 } }},
        &nine_by_nine,
    );
    try testing.expectEqual(
        MovementMode.approach,
        selectMovementMode(0, bare_state, definitions),
    );
}

test "pointBlankClusterDestination: seeks the tile hitting the most hostiles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    // Spinblade (radius 1, exposed as the sword's second skill): three
    // hostiles stacked around (0,4)-(0,5); the tile (1,4) is within radius 1
    // of all three, reachable in 3 steps from (4,4).
    const nine_by_nine = tileGrid(9, 9);
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{
            .{ .team = 1, .position = .{ .x = 4, .y = 4 }, .speed = 3, .main_hand_weapon = .{ .weapon_type = .sword } },
            .{ .team = 0, .position = .{ .x = 0, .y = 3 }, .current_health = 10, .max_health = 10 },
            .{ .team = 0, .position = .{ .x = 0, .y = 4 }, .current_health = 10, .max_health = 10 },
            .{ .team = 0, .position = .{ .x = 0, .y = 5 }, .current_health = 10, .max_health = 10 },
        },
        &nine_by_nine,
    );
    try testing.expectEqual(
        Vector2{ .x = 1, .y = 4 },
        pointBlankClusterDestination(0, game_state, definitions, arena.allocator()).?,
    );

    // Already at the best cluster tile: the current tile wins ties, so the
    // entity stands and casts (destination == own position).
    const placed_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{
            .{ .team = 1, .position = .{ .x = 1, .y = 4 }, .speed = 3, .main_hand_weapon = .{ .weapon_type = .sword } },
            .{ .team = 0, .position = .{ .x = 0, .y = 3 }, .current_health = 10, .max_health = 10 },
            .{ .team = 0, .position = .{ .x = 0, .y = 4 }, .current_health = 10, .max_health = 10 },
            .{ .team = 0, .position = .{ .x = 0, .y = 5 }, .current_health = 10, .max_health = 10 },
        },
        &nine_by_nine,
    );
    try testing.expectEqual(
        Vector2{ .x = 1, .y = 4 },
        pointBlankClusterDestination(0, placed_state, definitions, arena.allocator()).?,
    );
}

test "pointBlankClusterDestination: no hostiles in any radius -> null (approach)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    // The hostile is far outside the reachable tiles' spinblade radius —
    // clustering has nothing to cluster around.
    const fifteen_by_fifteen = tileGrid(15, 15);
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{
            .{ .team = 1, .position = .{ .x = 0, .y = 0 }, .speed = 2, .main_hand_weapon = .{ .weapon_type = .sword } },
            .{ .team = 0, .position = .{ .x = 14, .y = 14 }, .current_health = 10, .max_health = 10 },
        },
        &fifteen_by_fifteen,
    );
    try testing.expectEqual(
        @as(?Vector2, null),
        pointBlankClusterDestination(0, game_state, definitions, arena.allocator()),
    );
}

test "keepRangeDestination: retreats to exactly the standoff distance" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    // Staff kit: spark + daze (both range 3) exposed — min range 3, so the
    // entity kites. Corridor: the entity at (1,4), the hostile at (1,3)
    // (distance 1 — too close). Reachable retreat tiles: (1,2) distance 1,
    // (1,5) distance 2, (1,6) distance 3 — the farthest act-capable tile is
    // the standoff.
    const corridor = corridorGrid(9);
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{
            .{ .team = 1, .position = .{ .x = 1, .y = 4 }, .speed = 2, .main_hand_weapon = .{ .weapon_type = .staff } },
            .{ .team = 0, .position = .{ .x = 1, .y = 3 }, .current_health = 10, .max_health = 10 },
        },
        &corridor,
    );
    try testing.expectEqual(
        Vector2{ .x = 1, .y = 6 },
        keepRangeDestination(0, game_state, definitions, arena.allocator()).?,
    );

    // Already AT the standoff: no reachable tile is farther while staying
    // act-capable, and the current tile wins ties -> stand and act.
    const at_standoff = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{
            .{ .team = 1, .position = .{ .x = 1, .y = 6 }, .speed = 2, .main_hand_weapon = .{ .weapon_type = .staff } },
            .{ .team = 0, .position = .{ .x = 1, .y = 3 }, .current_health = 10, .max_health = 10 },
        },
        &corridor,
    );
    try testing.expectEqual(
        Vector2{ .x = 1, .y = 6 },
        keepRangeDestination(0, at_standoff, definitions, arena.allocator()).?,
    );
}

test "keepRangeDestination: cornered -> stands; hostile beyond reach -> null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    const corridor = corridorGrid(9);

    // Dead end: the entity is at the corridor's end (1,8), the hostile at
    // (1,6) (distance 2, act-capable at min range 3). The only reachable
    // tile (1,7) is CLOSER — the current tile stands.
    const cornered = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{
            .{ .team = 1, .position = .{ .x = 1, .y = 8 }, .speed = 2, .main_hand_weapon = .{ .weapon_type = .staff } },
            .{ .team = 0, .position = .{ .x = 1, .y = 6 }, .current_health = 10, .max_health = 10 },
        },
        &corridor,
    );
    try testing.expectEqual(
        Vector2{ .x = 1, .y = 8 },
        keepRangeDestination(0, cornered, definitions, arena.allocator()).?,
    );

    // Hostile far beyond min range: no reachable tile (nor the current
    // one) is act-capable -> null, the caller approaches instead.
    const long_corridor = corridorGrid(30);
    const distant = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .speed = 2, .main_hand_weapon = .{ .weapon_type = .staff } },
            .{ .team = 0, .position = .{ .x = 1, .y = 29 }, .current_health = 10, .max_health = 10 },
        },
        &long_corridor,
    );
    try testing.expectEqual(
        @as(?Vector2, null),
        keepRangeDestination(0, distant, definitions, arena.allocator()),
    );
}

test "pointBlankClusterDestination: an equal-count tile never displaces the current tile" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    // Spinblade (radius 1). The caster at (2,2) already covers both
    // hostiles (score 2) — and the UP-LEFT reachable tile (2,1) covers
    // exactly the same two (score 2). The (x, y) tile convention must NOT
    // lure the entity into shuffling there: as good as = stay.
    const nine_by_nine = tileGrid(9, 9);
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{
            .{ .team = 1, .position = .{ .x = 2, .y = 2 }, .speed = 2, .main_hand_weapon = .{ .weapon_type = .sword } },
            .{ .team = 0, .position = .{ .x = 1, .y = 2 }, .current_health = 10, .max_health = 10 },
            .{ .team = 0, .position = .{ .x = 3, .y = 2 }, .current_health = 10, .max_health = 10 },
        },
        &nine_by_nine,
    );
    try testing.expectEqual(
        Vector2{ .x = 2, .y = 2 },
        pointBlankClusterDestination(0, game_state, definitions, arena.allocator()).?,
    );

    // A strictly better tile DOES move: one step up covers both hostiles
    // PLUS a third one above — 3 beats 2.
    const better_exists = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{
            .{ .team = 1, .position = .{ .x = 2, .y = 2 }, .speed = 2, .main_hand_weapon = .{ .weapon_type = .sword } },
            .{ .team = 0, .position = .{ .x = 1, .y = 2 }, .current_health = 10, .max_health = 10 },
            .{ .team = 0, .position = .{ .x = 3, .y = 2 }, .current_health = 10, .max_health = 10 },
            .{ .team = 0, .position = .{ .x = 2, .y = 0 }, .current_health = 10, .max_health = 10 },
        },
        &nine_by_nine,
    );
    try testing.expectEqual(
        Vector2{ .x = 2, .y = 1 },
        pointBlankClusterDestination(0, better_exists, definitions, arena.allocator()).?,
    );
}

test "keepRangeDestination: an equal-distance tile never displaces the current tile" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var harness = test_harness.Harness.init(arena.allocator());
    const definitions = &harness.weapon_type_definitions;

    // Staff kit, standoff 3. The caster at (4,4) already sits at the
    // standoff from the hostile at (4,1) — and the LEFT reachable tile
    // (2,4) is also at distance 3. The (x, y) tile convention must NOT
    // shuffle it sideways: as good as = stay.
    const nine_by_nine = tileGrid(9, 9);
    const game_state = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{
            .{ .team = 1, .position = .{ .x = 4, .y = 4 }, .speed = 2, .main_hand_weapon = .{ .weapon_type = .staff } },
            .{ .team = 0, .position = .{ .x = 4, .y = 1 }, .current_health = 10, .max_health = 10 },
        },
        &nine_by_nine,
    );
    try testing.expectEqual(
        Vector2{ .x = 4, .y = 4 },
        keepRangeDestination(0, game_state, definitions, arena.allocator()).?,
    );

    // A strictly farther act-capable tile DOES move: hostile at distance 1
    // (too close); the row 2 tiles up opens it to 3. Five reachable tiles
    // sit at distance 3 ((2,6)..(6,6)) — the reachable-vs-reachable tie
    // breaks by the (x, y) convention to the leftmost.
    const too_close = test_harness.levelStateWithEntities(
        arena.allocator(),
        &.{
            .{ .team = 1, .position = .{ .x = 4, .y = 4 }, .speed = 2, .main_hand_weapon = .{ .weapon_type = .staff } },
            .{ .team = 0, .position = .{ .x = 4, .y = 3 }, .current_health = 10, .max_health = 10 },
        },
        &nine_by_nine,
    );
    try testing.expectEqual(
        Vector2{ .x = 2, .y = 6 },
        keepRangeDestination(0, too_close, definitions, arena.allocator()).?,
    );
}
