const std = @import("std");
const types = @import("types.zig");

const Settings = types.Settings;
const Vector2 = types.Vector2;
const CampaignGraph = types.CampaignGraph;
const PositionedCampaignGraph = types.PositionedCampaignGraph;
const Level = types.Level;

pub fn computeFrameLength(settings: Settings) u32 {
    if (settings.vsync) {
        // vsync calculation
        return 16; // ~60fps placeholder
    } else {
        // calculate from fps setting
        return 16;
    }
}

fn manhattanDistance(a: Vector2, b: Vector2) u32 {
    const dx: u32 = @intCast(@abs(a.x - b.x));
    const dy: u32 = @intCast(@abs(a.y - b.y));
    return dx + dy;
}

const PathNode = struct {
    position: Vector2,
    parent: ?Vector2,
    g_cost: u32,
    h_cost: u32,

    fn fCost(self: PathNode) u32 {
        return self.g_cost + self.h_cost;
    }
};

/// Compare PathNodes for the priority queue: lower f-cost first,
/// then break ties by position to ensure deterministic ordering.
fn comparePathNodes(
    _: void,
    a: PathNode,
    b: PathNode,
) std.math.Order {
    const a_f = a.fCost();
    const b_f = b.fCost();
    if (a_f != b_f) return std.math.order(a_f, b_f);
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

/// A* shortest path with Chebyshev distance for movement cost and
/// Manhattan distance as heuristic (to prefer orthogonal movement
/// when multiple paths have the same Chebyshev length).
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

    // Build a set of occupied positions (all entities except the mover)
    var occupied = std.AutoHashMap(Vector2, void).init(allocator);
    defer occupied.deinit();
    for (level.entities) |entity| {
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
        .h_cost = manhattanDistance(start_position, end_position),
    };
    open_set.push(allocator,start_node) catch return null;
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
                    };
                    node_map.put(neighbor_position, updated) catch return null;
                    open_set.push(allocator,updated) catch return null;
                }
            } else {
                const new_node = PathNode{
                    .position = neighbor_position,
                    .parent = current_node.position,
                    .g_cost = new_g_cost,
                    .h_cost = manhattanDistance(neighbor_position, end_position),
                };
                node_map.put(neighbor_position, new_node) catch return null;
                open_set.push(allocator,new_node) catch return null;
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

/// Returns the walking distance between two positions (number of steps),
/// or null if no path exists.
pub fn walkingDistance(
    level: Level,
    start_position: Vector2,
    end_position: Vector2,
    allocator: std.mem.Allocator,
) ?u32 {
    const path = shortestPath(level, start_position, end_position, allocator) orelse return null;
    defer allocator.free(path);
    return @intCast(path.len);
}

pub fn worldMapSpaceGraph(campaign_graph: CampaignGraph) PositionedCampaignGraph {
    // convert campaign graph to world map space graph with iterated relaxation
    _ = campaign_graph;
    return undefined;
}

pub fn relaxGraphEdges(positioned_campaign_graph: PositionedCampaignGraph) PositionedCampaignGraph {
    _ = positioned_campaign_graph;
    return undefined;
}

pub fn chebyshevDistance(a: Vector2, b: Vector2) i32 {
    const dx = @as(i32, if (a.x > b.x) a.x - b.x else b.x - a.x);
    const dy = @as(i32, if (a.y > b.y) a.y - b.y else b.y - a.y);
    return @max(dx, dy);
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

    // Build a set of occupied positions (all entities except the mover)
    var occupied = std.AutoHashMap(Vector2, void).init(allocator);
    defer occupied.deinit();
    for (level.entities) |entity| {
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
