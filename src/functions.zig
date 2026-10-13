//! Pure gameplay helpers: A* pathfinding (`shortestPath`, Chebyshev
//! heuristic + straightness tiebreak, entity blocking), tile reachability,
//! distance metrics,
//! the tile-list ray search (`nearestTileAlongDirection`), the signed-delta
//! saturation clamp (`applySignedDelta`), salvage-value computation from
//! `data/salvage.txt`, and world-map graph layout. All integer gameplay
//! logic; no floats, no I/O.

const std = @import("std");
const types = @import("types.zig");

const Vector2 = types.Vector2;
const Level = types.Level;

/// The A* heuristic: Chebyshev distance to the destination — the EXACT
/// remaining cost on open ground (every step, diagonal included, costs 1),
/// so it never overestimates. The old Manhattan heuristic overestimated up
/// to 2x whenever the destination sat diagonally from a node, which could
/// pop the goal via a longer route before the shorter route's nodes were
/// ever expanded (reproduced by fuzzing — see the admissibility test).
fn chebyshevHeuristic(position: Vector2, destination: Vector2) u32 {
    return @intCast(chebyshevDistance(position, destination));
}

const PathNode = struct {
    position: Vector2,
    parent: ?Vector2,
    g_cost: u32,
    h_cost: u32,
    /// Squared euclidean distance to the destination — the f-cost tiebreak
    /// key (see `comparePathNodes`).
    distance_squared: u32,

    fn fCost(self: PathNode) u32 {
        return self.g_cost + self.h_cost;
    }
};

/// Compare PathNodes for the priority queue: lower f-cost first, then
/// break ties by squared euclidean distance to the destination (with an
/// exact heuristic f-ties are common — this keeps same-row chases on the
/// row: the row node is really closer than the row-above diagonal), then
/// by position for a total deterministic order.
fn comparePathNodes(
    _: void,
    a: PathNode,
    b: PathNode,
) std.math.Order {
    const a_f = a.fCost();
    const b_f = b.fCost();
    if (a_f != b_f) return std.math.order(a_f, b_f);
    if (a.distance_squared != b.distance_squared) {
        return std.math.order(a.distance_squared, b.distance_squared);
    }
    if (a.position.x != b.position.x) return std.math.order(a.position.x, b.position.x);
    return std.math.order(a.position.y, b.position.y);
}

const neighbor_deltas = [8]Vector2{
    .{ .x = -1, .y = -1 },
    .{ .x = -1, .y = 0 },
    .{ .x = -1, .y = 1 },
    .{ .x = 0, .y = -1 },
    .{ .x = 0, .y = 1 },
    .{ .x = 1, .y = -1 },
    .{ .x = 1, .y = 0 },
    .{ .x = 1, .y = 1 },
};

/// A* shortest path over the 8-neighborhood (every step costs 1, diagonal
/// included). Heuristic: Chebyshev — the exact remaining cost on open ground
/// (`chebyshevHeuristic`); f-cost ties (common with an exact heuristic)
/// break by squared euclidean distance to the destination so ties resolve
/// to the really-closer node — a same-row chase walks the row.
///
/// Tiles occupied by entities are not traversable, except for the
/// destination tile. The mover's own position is also excluded from
/// blocking (they're standing on it).
///
/// Returns the path from start to end (excluding start, including end),
/// or null if no path exists.
pub fn shortestPath(
    level: Level,
    start_position: Vector2,
    end_position: Vector2,
    allocator: std.mem.Allocator,
) ?[]const Vector2 {
    // Build a set of walkable tiles for fast lookup
    var tile_set = std.AutoHashMap(Vector2, void).init(allocator);
    defer tile_set.deinit();
    for (level.level_tiles) |tile| {
        tile_set.put(tile, {}) catch return null;
    }

    // Build a set of occupied positions (all live entities except the
    // mover). Dead entities (current_health == 0) don't block movement — a
    // tile they died on is traversable.
    var occupied = std.AutoHashMap(Vector2, void).init(allocator);
    defer occupied.deinit();
    for (level.entities) |entity| {
        if (entity.current_health == 0) continue;
        // Skip the entity standing at start_position (the mover)
        if (entity.position.x == start_position.x and
            entity.position.y == start_position.y) continue;
        occupied.put(entity.position, {}) catch return null;
    }

    // A* search
    var open_set: std.PriorityQueue(PathNode, void, comparePathNodes) = .empty;
    defer open_set.deinit(allocator);

    var node_map = std.AutoHashMap(Vector2, PathNode).init(allocator);
    defer node_map.deinit();

    var closed_set = std.AutoHashMap(Vector2, void).init(allocator);
    defer closed_set.deinit();

    const start_node = PathNode{
        .position = start_position,
        .parent = null,
        .g_cost = 0,
        .h_cost = chebyshevHeuristic(start_position, end_position),
        .distance_squared = squaredEuclideanDistance(start_position, end_position),
    };
    open_set.push(allocator, start_node) catch return null;
    node_map.put(start_position, start_node) catch return null;

    var found = false;
    while (open_set.pop()) |current_node| {
        if (closed_set.contains(current_node.position)) continue;

        closed_set.put(current_node.position, {}) catch return null;

        if (current_node.position.x == end_position.x and
            current_node.position.y == end_position.y)
        {
            found = true;
            break;
        }

        for (&neighbor_deltas) |delta| {
            const neighbor_position = Vector2{
                .x = current_node.position.x + delta.x,
                .y = current_node.position.y + delta.y,
            };

            // Skip if already evaluated
            if (closed_set.contains(neighbor_position)) continue;

            // Skip if not a valid tile
            if (!tile_set.contains(neighbor_position)) continue;

            // Skip if occupied by an entity (unless it's the destination)
            if (!(neighbor_position.x == end_position.x and
                neighbor_position.y == end_position.y))
            {
                if (occupied.contains(neighbor_position)) continue;
            }

            // Chebyshev distance is always 1 for adjacent tiles (including diagonals)
            const new_g_cost = current_node.g_cost + 1;

            if (node_map.get(neighbor_position)) |existing| {
                if (new_g_cost < existing.g_cost) {
                    const updated = PathNode{
                        .position = neighbor_position,
                        .parent = current_node.position,
                        .g_cost = new_g_cost,
                        .h_cost = existing.h_cost,
                        .distance_squared = existing.distance_squared,
                    };
                    node_map.put(neighbor_position, updated) catch return null;
                    open_set.push(allocator, updated) catch return null;
                }
            } else {
                const new_node = PathNode{
                    .position = neighbor_position,
                    .parent = current_node.position,
                    .g_cost = new_g_cost,
                    .h_cost = chebyshevHeuristic(neighbor_position, end_position),
                    .distance_squared = squaredEuclideanDistance(neighbor_position, end_position),
                };
                node_map.put(neighbor_position, new_node) catch return null;
                open_set.push(allocator, new_node) catch return null;
            }
        }
    }

    if (!found) return null;

    // Backtrack from end to start to build the path
    var path_list: std.ArrayList(Vector2) = .empty;
    var backtrack_position = end_position;
    while (!(backtrack_position.x == start_position.x and
        backtrack_position.y == start_position.y))
    {
        path_list.append(allocator, backtrack_position) catch return null;
        const node = node_map.get(backtrack_position) orelse return null;
        backtrack_position = node.parent orelse break;
    }

    // Reverse to get start→end order
    const path = path_list.toOwnedSlice(allocator) catch return null;
    std.mem.reverse(Vector2, path);
    return path;
}

pub fn chebyshevDistance(a: Vector2, b: Vector2) i32 {
    const dx = @as(i32, if (a.x > b.x) a.x - b.x else b.x - a.x);
    const dy = @as(i32, if (a.y > b.y) a.y - b.y else b.y - a.y);
    return @max(dx, dy);
}

/// Does the tile-position list contain `position`? Editor levels keep
/// their tiles as a flat position list (no set), and the lists are small —
/// a linear scan. Shared by the editor placement orchestrators
/// (event_handlers) and the footprint preview (view).
pub fn tileListContains(tiles: []const Vector2, position: Vector2) bool {
    for (tiles) |tile| {
        if (tile.x == position.x and tile.y == position.y) return true;
    }
    return false;
}

/// The nearest tile strictly beyond `origin` along `direction` (each axis
/// -1/0/1, not both zero) — the first tile on the ray origin + k·direction
/// for k ≥ 1 — or null when no tile lies in that direction. A tile
/// qualifies when its offset from `origin` is the SAME positive integer
/// multiple of `direction` on both axes; the smallest multiple wins. Used
/// by the tile-cursor nudge to CROSS GAPS (keyboard navigation reaches
/// disconnected tile groups instead of stopping at the edge) — see
/// DESIGN → Input.
pub fn nearestTileAlongDirection(
    tiles: []const Vector2,
    origin: Vector2,
    direction: Vector2,
) ?Vector2 {
    if (direction.x == 0 and direction.y == 0) return null;
    var nearest: ?Vector2 = null;
    var nearest_steps: i32 = std.math.maxInt(i32);
    for (tiles) |tile| {
        const offset_x = tile.x - origin.x;
        const offset_y = tile.y - origin.y;
        // 0 doubles as "not on the ray": a valid step count is always ≥ 1,
        // so a zero/negative or misaligned offset is rejected by the
        // steps > 0 filter below.
        const steps: i32 = if (direction.x != 0 and direction.y != 0) blk: {
            if (@rem(offset_x, direction.x) != 0) break :blk 0;
            if (@rem(offset_y, direction.y) != 0) break :blk 0;
            const steps_x = @divTrunc(offset_x, direction.x);
            const steps_y = @divTrunc(offset_y, direction.y);
            if (steps_x != steps_y) break :blk 0;
            break :blk steps_x;
        } else if (direction.x != 0) blk: {
            if (offset_y != 0) break :blk 0;
            break :blk @divTrunc(offset_x, direction.x);
        } else blk: {
            if (offset_x != 0) break :blk 0;
            break :blk @divTrunc(offset_y, direction.y);
        };
        if (steps > 0 and steps < nearest_steps) {
            nearest_steps = steps;
            nearest = tile;
        }
    }
    return nearest;
}

/// Apply a signed delta to an unsigned scalar, saturating at 0 (never wraps).
/// Shared by the change_momentum / change_cooldown event handlers so the
/// clamping is defined and tested in one place.
pub fn applySignedDelta(value: u32, delta: i32) u32 {
    if (delta >= 0) return value + @as(u32, @intCast(delta));
    const decrease: u32 = @intCast(-delta);
    return if (decrease >= value) 0 else value - decrease;
}

test "applySignedDelta saturates at zero and adds" {
    try std.testing.expectEqual(@as(u32, 7), applySignedDelta(5, 2));
    try std.testing.expectEqual(@as(u32, 3), applySignedDelta(5, -2));
    try std.testing.expectEqual(@as(u32, 0), applySignedDelta(5, -5));
    try std.testing.expectEqual(@as(u32, 0), applySignedDelta(5, -9));
    try std.testing.expectEqual(@as(u32, 5), applySignedDelta(5, 0));
}

/// Returns all tiles reachable from start_position within max_steps,
/// using BFS with Chebyshev movement (8-directional). Entities block
/// movement (the mover's own tile is excluded from blocking).
/// The result does NOT include the start position itself.
pub fn reachableTiles(
    level: Level,
    start_position: Vector2,
    max_steps: u32,
    allocator: std.mem.Allocator,
) []const Vector2 {
    // Build a set of walkable tiles for fast lookup
    var tile_set = std.AutoHashMap(Vector2, void).init(allocator);
    defer tile_set.deinit();
    for (level.level_tiles) |tile| {
        tile_set.put(tile, {}) catch return &.{};
    }

    // Build a set of occupied positions (all live entities except the
    // mover). Dead entities (current_health == 0) don't block movement — a
    // tile they died on is traversable.
    var occupied = std.AutoHashMap(Vector2, void).init(allocator);
    defer occupied.deinit();
    for (level.entities) |entity| {
        if (entity.current_health == 0) continue;
        if (entity.position.x == start_position.x and
            entity.position.y == start_position.y) continue;
        occupied.put(entity.position, {}) catch return &.{};
    }

    // BFS
    const QueueEntry = struct {
        position: Vector2,
        steps: u32,
    };
    var queue: std.ArrayList(QueueEntry) = .empty;
    var visited = std.AutoHashMap(Vector2, void).init(allocator);
    defer visited.deinit();

    queue.append(allocator, .{
        .position = start_position,
        .steps = 0,
    }) catch return &.{};
    visited.put(start_position, {}) catch return &.{};

    var result: std.ArrayList(Vector2) = .empty;
    var queue_index: usize = 0;

    while (queue_index < queue.items.len) {
        const current = queue.items[queue_index];
        queue_index += 1;

        if (current.steps >= max_steps) continue;

        for (&neighbor_deltas) |delta| {
            const neighbor_position = Vector2{
                .x = current.position.x + delta.x,
                .y = current.position.y + delta.y,
            };

            if (visited.contains(neighbor_position)) continue;
            if (!tile_set.contains(neighbor_position)) continue;
            if (occupied.contains(neighbor_position)) continue;

            visited.put(neighbor_position, {}) catch return &.{};
            result.append(allocator, neighbor_position) catch return &.{};
            queue.append(allocator, .{
                .position = neighbor_position,
                .steps = current.steps + 1,
            }) catch return &.{};
        }
    }

    return result.toOwnedSlice(allocator) catch return &.{};
}

// ============================================================
// Tests
// ============================================================

test "shortestPath finds a direct path on an open grid" {
    const allocator = std.testing.allocator;

    // 5x5 grid of tiles, no entities blocking
    var tiles: [25]Vector2 = undefined;
    var index: usize = 0;
    for (0..5) |x| {
        for (0..5) |y| {
            tiles[index] = .{ .x = @intCast(x), .y = @intCast(y) };
            index += 1;
        }
    }

    const level = Level{
        .level_tiles = &tiles,
        .entities = &.{.{ .position = .{ .x = 0, .y = 0 } }}, // mover at start
    };

    const path = shortestPath(level, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, allocator);
    try std.testing.expect(path != null);
    defer allocator.free(path.?);

    // Chebyshev distance is 4, so path should be 4 steps
    try std.testing.expectEqual(4, path.?.len);

    // Last step should be the destination
    try std.testing.expectEqual(4, path.?[path.?.len - 1].x);
    try std.testing.expectEqual(4, path.?[path.?.len - 1].y);
}

test "shortestPath routes around blocking entities" {
    const allocator = std.testing.allocator;

    // 3x3 grid:
    //   (0,2) (1,2) (2,2)
    //   (0,1) [BLK] (2,1)
    //   (0,0) (1,0) (2,0)
    // Mover at (0,0), destination (2,2), blocker at (1,1)
    var tiles: [9]Vector2 = undefined;
    var index: usize = 0;
    for (0..3) |x| {
        for (0..3) |y| {
            tiles[index] = .{ .x = @intCast(x), .y = @intCast(y) };
            index += 1;
        }
    }

    const level = Level{
        .level_tiles = &tiles,
        .entities = &.{
            .{ .position = .{ .x = 0, .y = 0 } }, // mover
            .{ .position = .{ .x = 1, .y = 1 } }, // blocker
        },
    };

    const path = shortestPath(level, .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 2 }, allocator);
    try std.testing.expect(path != null);
    defer allocator.free(path.?);

    // Must go around the blocker — path should be longer than 2
    try std.testing.expect(path.?.len > 2);

    // None of the path steps should be the blocker position
    for (path.?) |step| {
        try std.testing.expect(!(step.x == 1 and step.y == 1));
    }
}

test "shortestPath returns null when no path exists" {
    const allocator = std.testing.allocator;

    // Mover at (0,0), destination (2,0), but (1,0) and (1,1) are blocked
    // and there's no tile at (0,1) — completely walled off
    const tiles = [_]Vector2{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 2, .y = 0 },
    };

    const level = Level{
        .level_tiles = &tiles,
        .entities = &.{
            .{ .position = .{ .x = 0, .y = 0 } }, // mover
            .{ .position = .{ .x = 1, .y = 0 } }, // blocker
        },
    };

    const path = shortestPath(level, .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 0 }, allocator);
    try std.testing.expectEqual(null, path);
}

test "shortestPath allows moving onto a tile occupied by destination entity" {
    const allocator = std.testing.allocator;

    // Mover at (0,0), target entity at (1,0) — should be able to path to it
    const tiles = [_]Vector2{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
    };

    const level = Level{
        .level_tiles = &tiles,
        .entities = &.{
            .{ .position = .{ .x = 0, .y = 0 } }, // mover
            .{ .position = .{ .x = 1, .y = 0 } }, // target
        },
    };

    const path = shortestPath(level, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, allocator);
    try std.testing.expect(path != null);
    defer allocator.free(path.?);

    try std.testing.expectEqual(1, path.?.len);
    try std.testing.expectEqual(1, path.?[0].x);
    try std.testing.expectEqual(0, path.?[0].y);
}

test "shortestPath: same-row chase walks the row" {
    const allocator = std.testing.allocator;

    // 5x3 open grid; mover at (4,1), target at (0,1) — same row. The
    // straight row walk is the path (not a diagonal staircase up a row:
    // with the exact Chebyshev heuristic the row node and the row-above
    // diagonal tie on f-cost, and the squared-euclidean tiebreak keeps
    // the chase on the row).
    var tiles: [15]Vector2 = undefined;
    var index: usize = 0;
    for (0..5) |x| {
        for (0..3) |y| {
            tiles[index] = .{ .x = @intCast(x), .y = @intCast(y) };
            index += 1;
        }
    }

    const level = Level{
        .level_tiles = &tiles,
        .entities = &.{
            .{ .position = .{ .x = 4, .y = 1 } }, // mover
            .{ .position = .{ .x = 0, .y = 1 } }, // target
        },
    };

    const path = shortestPath(level, .{ .x = 4, .y = 1 }, .{ .x = 0, .y = 1 }, allocator);
    try std.testing.expect(path != null);
    defer allocator.free(path.?);

    try std.testing.expectEqual(@as(usize, 4), path.?.len);
    for (path.?, 0..) |step, step_index| {
        try std.testing.expectEqual(@as(i32, 4) - @as(i32, @intCast(step_index + 1)), step.x);
        try std.testing.expectEqual(@as(i32, 1), step.y);
    }
}

test "shortestPath: diagonal chase walks the diagonal" {
    const allocator = std.testing.allocator;

    // Mover at (0,0), target at (4,4) — the pure diagonal is the path,
    // not an axis-hugging staircase.
    var tiles: [25]Vector2 = undefined;
    var index: usize = 0;
    for (0..5) |x| {
        for (0..5) |y| {
            tiles[index] = .{ .x = @intCast(x), .y = @intCast(y) };
            index += 1;
        }
    }

    const level = Level{
        .level_tiles = &tiles,
        .entities = &.{
            .{ .position = .{ .x = 0, .y = 0 } }, // mover
            .{ .position = .{ .x = 4, .y = 4 } }, // target
        },
    };

    const path = shortestPath(level, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, allocator);
    try std.testing.expect(path != null);
    defer allocator.free(path.?);

    try std.testing.expectEqual(@as(usize, 4), path.?.len);
    for (path.?, 0..) |step, step_index| {
        const expected: i32 = @intCast(step_index + 1);
        try std.testing.expectEqual(expected, step.x);
        try std.testing.expectEqual(expected, step.y);
    }
}

test "shortestPath: optimal path around obstacles (heuristic admissibility)" {
    const allocator = std.testing.allocator;

    // The counterexample found by fuzzing shortestPath against a reference
    // BFS (with the old Manhattan heuristic — which stays suboptimal even
    // under the new euclidean tiebreak, so this pins the HEURISTIC, not the
    // tiebreak): Manhattan overestimates the remaining cost whenever the
    // goal sits diagonally from a node, which can pop the goal via a longer
    // route (6 steps here) before the optimal route's nodes are expanded.
    // The exact Chebyshev heuristic returns the 5-step path:
    // (1,1) (2,2) (3,3) (4,4) (4,5). Tiles ('#' floor, '.' missing):
    //   x:  0 1 2 3 4 5 6
    // y=0: # # # . . # #
    // y=1: S # . # . . #
    // y=2: # . # . # # .
    // y=3: # # # # . # .
    // y=4: . . . . # # .
    // y=5: # # . G # . #
    // y=6: # # # . . . #
    const tiles = [_]Vector2{
        .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 5, .y = 0 }, .{ .x = 6, .y = 0 },
        .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 4, .y = 1 }, .{ .x = 6, .y = 1 }, .{ .x = 0, .y = 2 },
        .{ .x = 2, .y = 2 }, .{ .x = 5, .y = 2 }, .{ .x = 6, .y = 2 }, .{ .x = 0, .y = 3 }, .{ .x = 1, .y = 3 },
        .{ .x = 2, .y = 3 }, .{ .x = 3, .y = 3 }, .{ .x = 5, .y = 3 }, .{ .x = 4, .y = 4 }, .{ .x = 5, .y = 4 },
        .{ .x = 0, .y = 5 }, .{ .x = 1, .y = 5 }, .{ .x = 3, .y = 5 }, .{ .x = 4, .y = 5 }, .{ .x = 6, .y = 5 },
        .{ .x = 0, .y = 6 }, .{ .x = 1, .y = 6 }, .{ .x = 2, .y = 6 }, .{ .x = 6, .y = 6 },
    };

    const level = Level{
        .level_tiles = &tiles,
        .entities = &.{
            .{ .position = .{ .x = 0, .y = 1 } }, // mover
            .{ .position = .{ .x = 4, .y = 5 } }, // target
        },
    };

    const path = shortestPath(level, .{ .x = 0, .y = 1 }, .{ .x = 4, .y = 5 }, allocator);
    try std.testing.expect(path != null);
    defer allocator.free(path.?);

    try std.testing.expectEqual(@as(usize, 5), path.?.len);
    try std.testing.expectEqual(Vector2{ .x = 1, .y = 1 }, path.?[0]);
    try std.testing.expectEqual(Vector2{ .x = 2, .y = 2 }, path.?[1]);
    try std.testing.expectEqual(Vector2{ .x = 3, .y = 3 }, path.?[2]);
    try std.testing.expectEqual(Vector2{ .x = 4, .y = 4 }, path.?[3]);
    try std.testing.expectEqual(Vector2{ .x = 4, .y = 5 }, path.?[4]);
}

// ============================================================
// Salvage
// ============================================================

const Item = types.Item;
const Materials = types.Materials;
const MaterialType = types.MaterialType;
const SalvageDefinition = types.SalvageDefinition;
const SalvageDefinitions = types.SalvageDefinitions;

fn computeTotalValue(item: Item) u32 {
    return switch (item) {
        .weapon => |weapon| weapon.weapon_damage,
        .amulet => |amulet| amulet.spell_damage,
        .coat => |coat| coat.health_bonus + coat.defense_bonus,
        .gloves => |gloves| gloves.health_bonus + gloves.damage_bonus,
        .pants => |pants| pants.health_bonus + pants.pickup_radius_bonus,
        .boots => |boots| boots.health_bonus + boots.speed_bonus,
        .skill_tome => |skill_tome| skill_tome.value,
    };
}

fn getSalvageDefinition(
    item: Item,
    salvage_definitions: SalvageDefinitions,
) SalvageDefinition {
    return switch (item) {
        .weapon => |weapon| salvage_definitions.weapon[@intFromEnum(weapon.weapon_type)],
        .amulet => salvage_definitions.amulet,
        .coat => salvage_definitions.coat,
        .gloves => salvage_definitions.gloves,
        .pants => salvage_definitions.pants,
        .boots => salvage_definitions.boots,
        .skill_tome => salvage_definitions.skill_tome,
    };
}

fn setMaterial(
    materials: *Materials,
    material_type: MaterialType,
    value: u32,
) void {
    switch (material_type) {
        .wood => materials.wood = value,
        .metal => materials.metal = value,
        .leather => materials.leather = value,
        .cloth => materials.cloth = value,
        .knowledge => materials.knowledge = value,
    }
}

pub fn computeSalvageValue(
    item: Item,
    salvage_definitions: SalvageDefinitions,
) Materials {
    const total_value = computeTotalValue(item);
    if (total_value == 0) return .{};

    const definition = getSalvageDefinition(item, salvage_definitions);
    if (definition.splits.len == 0) return .{};

    // Sum all parts to get the denominator
    var denominator: u32 = 0;
    for (definition.splits) |split| {
        denominator += split.parts;
    }
    if (denominator == 0) return .{};

    // Compute each split's share with integer division.
    // Last split gets the remainder to guarantee no loss.
    var result: Materials = .{};
    var allocated: u32 = 0;

    for (definition.splits, 0..) |split, index| {
        if (index == definition.splits.len - 1) {
            setMaterial(&result, split.material, total_value - allocated);
        } else {
            const share = total_value * split.parts / denominator;
            setMaterial(&result, split.material, share);
            allocated += share;
        }
    }

    return result;
}

test "computeSalvageValue sword" {
    const sword_item: Item = .{ .weapon = .{
        .weapon_damage = 5,
        .weapon_type = .sword,
    } };

    const definitions = SalvageDefinitions{
        .weapon = blk: {
            var weapon_definitions: [types.weapon_type_count]SalvageDefinition = undefined;
            for (&weapon_definitions) |*entry| entry.* = .{ .splits = &.{} };
            weapon_definitions[@intFromEnum(types.WeaponType.sword)] = .{
                .splits = &.{
                    .{ .material = .wood, .parts = 1 },
                    .{ .material = .metal, .parts = 3 },
                },
            };
            break :blk weapon_definitions;
        },
        .amulet = .{ .splits = &.{} },
        .coat = .{ .splits = &.{} },
        .gloves = .{ .splits = &.{} },
        .pants = .{ .splits = &.{} },
        .boots = .{ .splits = &.{} },
        .skill_tome = .{ .splits = &.{} },
    };

    const result = computeSalvageValue(sword_item, definitions);
    try std.testing.expectEqual(@as(u32, 1), result.wood);
    try std.testing.expectEqual(@as(u32, 4), result.metal);
    try std.testing.expectEqual(@as(u32, 0), result.leather);
    try std.testing.expectEqual(@as(u32, 0), result.cloth);
    try std.testing.expectEqual(@as(u32, 0), result.knowledge);
}

test "computeSalvageValue skill tome" {
    const tome_item: Item = .{ .skill_tome = .{
        .value = 5,
    } };

    const definitions = SalvageDefinitions{
        .weapon = blk: {
            var weapon_definitions: [types.weapon_type_count]SalvageDefinition = undefined;
            for (&weapon_definitions) |*entry| entry.* = .{ .splits = &.{} };
            break :blk weapon_definitions;
        },
        .amulet = .{ .splits = &.{} },
        .coat = .{ .splits = &.{} },
        .gloves = .{ .splits = &.{} },
        .pants = .{ .splits = &.{} },
        .boots = .{ .splits = &.{} },
        .skill_tome = .{
            .splits = &.{
                .{ .material = .knowledge, .parts = 1 },
            },
        },
    };

    const result = computeSalvageValue(tome_item, definitions);
    try std.testing.expectEqual(@as(u32, 5), result.knowledge);
    try std.testing.expectEqual(@as(u32, 0), result.wood);
}

// ───────────────────────── nearestTileAlongDirection ─────────────────────────

test "nearestTileAlongDirection: orthogonal gap jump picks the first tile on the ray" {
    const tiles = [_]Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 5, .y = 0 } };
    // Right from (1,0): (2,0) is empty — the ray continues to (5,0).
    try std.testing.expectEqual(
        Vector2{ .x = 5, .y = 0 },
        nearestTileAlongDirection(&tiles, .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 0 }).?,
    );
    // Left from (1,0): the adjacent tile.
    try std.testing.expectEqual(
        Vector2{ .x = 0, .y = 0 },
        nearestTileAlongDirection(&tiles, .{ .x = 1, .y = 0 }, .{ .x = -1, .y = 0 }).?,
    );
    // Up from (1,0): no tile in that column above — null.
    try std.testing.expectEqual(
        @as(?Vector2, null),
        nearestTileAlongDirection(&tiles, .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 }),
    );
}

test "nearestTileAlongDirection: diagonal ray needs the same multiple on both axes" {
    const tiles = [_]Vector2{
        .{ .x = 2, .y = 2 },
        .{ .x = 3, .y = 3 },
        .{ .x = 3, .y = 4 }, // off the diagonal ray — ignored
    };
    try std.testing.expectEqual(
        Vector2{ .x = 2, .y = 2 },
        nearestTileAlongDirection(&tiles, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 }).?,
    );
    // Anti-diagonal from (3,4) down-left: (2,2) is not on it, (3,3) is not
    // either — nothing → null.
    try std.testing.expectEqual(
        @as(?Vector2, null),
        nearestTileAlongDirection(&tiles, .{ .x = 3, .y = 4 }, .{ .x = -1, .y = -1 }),
    );
}

test "nearestTileAlongDirection: tiles behind the origin and the origin itself are ignored" {
    const tiles = [_]Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 5, .y = 0 } };
    // Right from (2,0): (0,0) is behind, (2,0) is the origin — (5,0) wins.
    try std.testing.expectEqual(
        Vector2{ .x = 5, .y = 0 },
        nearestTileAlongDirection(&tiles, .{ .x = 2, .y = 0 }, .{ .x = 1, .y = 0 }).?,
    );
    // The origin is the ONLY tile → null (a step count of 0 is never valid).
    const lone = [_]Vector2{.{ .x = 2, .y = 0 }};
    try std.testing.expectEqual(
        @as(?Vector2, null),
        nearestTileAlongDirection(&lone, .{ .x = 2, .y = 0 }, .{ .x = 1, .y = 0 }),
    );
    // A zero direction never finds anything.
    try std.testing.expectEqual(
        @as(?Vector2, null),
        nearestTileAlongDirection(&tiles, .{ .x = 2, .y = 0 }, .{ .x = 0, .y = 0 }),
    );
}

/// Row-major (x, then y) tile order — the canonical ordering convention
/// for tile lists (editor insertions keep it) and the FINAL fallback tier
/// of `straighterTileBefore`. See DESIGN → Determinism & Tiebreaking.
pub fn tileBefore(a: types.Vector2, b: types.Vector2) bool {
    if (a.x != b.x) return a.x < b.x;
    return a.y < b.y;
}

/// Squared euclidean distance — the "real" distance as an integer (no
/// floats in gameplay logic; squaring preserves order).
fn squaredEuclideanDistance(a: types.Vector2, b: types.Vector2) u32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @abs(dx * dx + dy * dy);
}

/// Perpendicular offset of `position` from the mover→anchor line, in
/// cross-product units — 0 means the tile is ON the line. Integer-only.
fn crossLineOffset(
    position: types.Vector2,
    mover_position: types.Vector2,
    anchor_position: types.Vector2,
) u32 {
    const relative_x = position.x - mover_position.x;
    const relative_y = position.y - mover_position.y;
    const anchor_x = anchor_position.x - mover_position.x;
    const anchor_y = anchor_position.y - mover_position.y;
    return @abs(relative_x * anchor_y - relative_y * anchor_x);
}

/// Movement-destination tiebreak: when the primary metric (cluster score /
/// Chebyshev distance) ties between candidate tiles, prefer the STRAIGHTER
/// line to the anchor — first by perpendicular offset from the
/// mover→anchor line (a same-row chase stays on its row; a 45° chase walks
/// the diagonal), then by squared euclidean distance to the anchor, then
/// the (x, y) tile convention for a total deterministic order. See DESIGN →
/// Determinism & Tiebreaking.
pub fn straighterTileBefore(
    candidate: types.Vector2,
    incumbent: types.Vector2,
    mover_position: types.Vector2,
    anchor_position: types.Vector2,
) bool {
    const candidate_cross = crossLineOffset(candidate, mover_position, anchor_position);
    const incumbent_cross = crossLineOffset(incumbent, mover_position, anchor_position);
    if (candidate_cross != incumbent_cross) return candidate_cross < incumbent_cross;
    const candidate_distance = squaredEuclideanDistance(candidate, anchor_position);
    const incumbent_distance = squaredEuclideanDistance(incumbent, anchor_position);
    if (candidate_distance != incumbent_distance) return candidate_distance < incumbent_distance;
    return tileBefore(candidate, incumbent);
}

test "straighterTileBefore: same-row chase stays on the row" {
    // Mover at (2,1), anchor (target) at (0,1) — the row tile (1,1) is on
    // the mover→anchor line; the row-above/below diagonals are not.
    const mover = Vector2{ .x = 2, .y = 1 };
    const anchor = Vector2{ .x = 0, .y = 1 };
    const straight = Vector2{ .x = 1, .y = 1 };
    try std.testing.expect(straighterTileBefore(straight, .{ .x = 1, .y = 0 }, mover, anchor));
    try std.testing.expect(straighterTileBefore(straight, .{ .x = 1, .y = 2 }, mover, anchor));
}

test "straighterTileBefore: diagonal chase walks the diagonal" {
    // Mover at (0,0), anchor at (2,2) — the diagonal tile (1,1) is on the
    // line; the orthogonal neighbors are equidistant in Chebyshev but off
    // the line.
    const mover = Vector2{ .x = 0, .y = 0 };
    const anchor = Vector2{ .x = 2, .y = 2 };
    try std.testing.expect(straighterTileBefore(.{ .x = 1, .y = 1 }, .{ .x = 0, .y = 1 }, mover, anchor));
    try std.testing.expect(straighterTileBefore(.{ .x = 1, .y = 1 }, .{ .x = 1, .y = 0 }, mover, anchor));
}

test "straighterTileBefore: equal line offset falls to euclidean, then (x, y)" {
    // Mover (0,0), anchor (4,0): (1,1) and (2,1) sit equally off the row
    // line — the closer-in-euclid (2,1) orders first.
    const mover = Vector2{ .x = 0, .y = 0 };
    const anchor = Vector2{ .x = 4, .y = 0 };
    try std.testing.expect(straighterTileBefore(.{ .x = 2, .y = 1 }, .{ .x = 1, .y = 1 }, mover, anchor));
    try std.testing.expect(!straighterTileBefore(.{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, mover, anchor));
    // Fully tied (mirror tiles above/below the line) → the (x, y)
    // convention decides: lower y first.
    try std.testing.expect(straighterTileBefore(.{ .x = 2, .y = -1 }, .{ .x = 2, .y = 1 }, mover, anchor));
    // Incumbent orderings are antisymmetric under swap.
    try std.testing.expect(!straighterTileBefore(.{ .x = 2, .y = 1 }, .{ .x = 2, .y = -1 }, mover, anchor));
}
