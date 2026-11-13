//! The shared campaign-map geometry - the ONE implementation behind the
//! "one data model, two renderers" rule: buildWorldMap (the in-game
//! world-map overlay) and the campaign editor's view (slice 3) both
//! derive edge shapes through `deriveEdgeGeometry`. Owns the map-space ->
//! screen-space framing transform (`mapToScreen`), the three edge-shape
//! derivations (self-loop teardrop, straight + parallel spread, dangling
//! stub), and the shared view constants (geometry + arrow stroke style).
//! Pure over its inputs: no file access, no session state.
//! See DESIGN → Campaigns & the Campaign Editor → Edge geometry and
//! The map coordinate model.

const std = @import("std");
const types = @import("../types.zig");

const ScreenPosition = types.ScreenPosition;
const Vector2 = types.Vector2;

/// Edge endpoints anchor this far from the hub's CENTER - deliberately
/// decoupled from the hub icon's draw size (the icon can shrink without
/// dragging edge geometry along): self-loops + stubs along the exit's
/// configured direction, straight edges along the hub-position difference.
const hub_edge_anchor_radius: i32 = 64;

/// Self-loop geometry: the teardrop's reach along the exit direction (L)
/// and half-width across it (w). Fixed view constants in v1 (style
/// consistency); tweak freely.
const self_loop_length: i32 = 300;
const self_loop_half_width: i32 = 120;

/// The dangling-stub reach along the exit direction.
const stub_length: i32 = 300;

/// Perpendicular spacing between PARALLEL straight edges connecting the
/// same hub pair (spread by exit index).
const parallel_edge_spacing: i32 = 64;

/// The mission-edge stroke width + its pure-black outline (each side adds
/// `edge_outline_width`, so the under-stroke is
/// `edge_width + 2 * edge_outline_width` wide). Shared by both renderers'
/// stroke pairs AND the clickable button's hit_curve width (the hit
/// region is the drawn arrow, outline-inclusive).
pub const edge_width: i32 = 8;
pub const edge_outline_width: i32 = 8;

/// The edge stroke's outline color.
pub const black: types.Color = .{ .r = 0, .g = 0, .b = 0 };

/// Map space -> reference screen space. The default framing region IS the
/// reference resolution (both 3840x2160, centered on the origin - see
/// DESIGN → The map coordinate model), so the transform is a pure
/// translation; the framing constant and this function change together if
/// the default framing ever moves.
pub fn mapToScreen(position: Vector2) ScreenPosition {
    return .{
        .x = position.x + @divTrunc(types.reference_width, 2),
        .y = position.y + @divTrunc(types.reference_height, 2),
    };
}

/// The direction unit vector for a compass degree value (0 = north = up,
/// clockwise - the screen's y axis points down, so north is -y).
fn directionUnitVector(direction_degrees: i32) struct { x: f32, y: f32 } {
    const radians = std.math.degreesToRadians(@as(f32, @floatFromInt(direction_degrees)));
    return .{ .x = @sin(radians), .y = -@cos(radians) };
}

fn screenPoint(x: f32, y: f32) ScreenPosition {
    return .{ .x = @intFromFloat(@round(x)), .y = @intFromFloat(@round(y)) };
}

/// How an edge's destination end resolves - the three geometric classes
/// (see DESIGN → Edge geometry). The CALLER resolves its own graph's
/// references into this union, so the runtime edge table and the editor's
/// authored graph share the derivation without sharing types.
pub const EdgeEndpoint = union(enum) {
    /// The destination IS the from hub - the teardrop along the exit's
    /// direction bearing.
    self_loop,
    /// The destination hub's map position.
    hub: Vector2,
    /// Destination unplaced or unresolvable - the dashed stub along the
    /// direction bearing.
    dangling,
};

/// Where a straight edge sits among its same-pair siblings: `index` is
/// the edge's 1-based position (by exit_index) among the `count` edges
/// sharing the same (from, destination) pair. The caller scans its own
/// edge list to compute this (pair identity is the caller's vocabulary -
/// uuids at runtime, handles in the editor); only the straight class
/// consumes it.
pub const ParallelSpread = struct {
    index: i32,
    count: i32,
};

/// One derived edge shape: the four bezier points (straight edges are the
/// degenerate bezier - all controls on the segment) + the dashed flag
/// (the dangling-stub class). Both renderers draw the stroke pair from
/// this and the clickable button's hit_curve copies it, so the drawn
/// edge, its hit region, and its tooltip bounds cannot disagree.
pub const EdgeGeometry = struct {
    start: ScreenPosition,
    control_start: ScreenPosition,
    control_end: ScreenPosition,
    end: ScreenPosition,
    dashed: bool,
};

/// Derive an edge's on-screen shape. `from_position` is the from hub's
/// map position; `endpoint` resolves the destination (see EdgeEndpoint);
/// `direction_degrees` is the exit's EFFECTIVE direction (authored, else
/// the auto-spread default); `parallel` spreads same-pair straight edges
/// perpendicular (see ParallelSpread). Pure: identical inputs give
/// identical geometry.
pub fn deriveEdgeGeometry(
    from_position: Vector2,
    endpoint: EdgeEndpoint,
    direction_degrees: i32,
    parallel: ParallelSpread,
) EdgeGeometry {
    const start = mapToScreen(from_position);

    switch (endpoint) {
        .self_loop => {
            // The anchor sits on the exit's direction bearing at the
            // hub's edge; the teardrop extends from it -
            // {a, a + d*L + n*w, a + d*L - n*w, a} with a = hub + d*R.
            const direction = directionUnitVector(direction_degrees);
            const px = -direction.y;
            const py = direction.x;
            const radius: f32 = @floatFromInt(hub_edge_anchor_radius);
            const hub_x: f32 = @floatFromInt(start.x);
            const hub_y: f32 = @floatFromInt(start.y);
            const anchor_x: f32 = hub_x + direction.x * radius;
            const anchor_y: f32 = hub_y + direction.y * radius;
            const length: f32 = @floatFromInt(self_loop_length);
            const half_width: f32 = @floatFromInt(self_loop_half_width);
            return .{
                .start = screenPoint(anchor_x, anchor_y),
                .control_start = screenPoint(
                    anchor_x + direction.x * length + px * half_width,
                    anchor_y + direction.y * length + py * half_width,
                ),
                .control_end = screenPoint(
                    anchor_x + direction.x * length - px * half_width,
                    anchor_y + direction.y * length - py * half_width,
                ),
                .end = screenPoint(anchor_x, anchor_y),
                .dashed = false,
            };
        },
        .hub => |to_position| {
            // Straight edge: the direction is the HUB-POSITION difference
            // (well-defined), the endpoints displaced to each hub's
            // boundary along it. Controls on the segment at 1/3 + 2/3,
            // slid perpendicular by the parallel-spread offset for
            // same-pair edges. Coincident hubs (distinct hubs placed at
            // the same map position - legal, nothing forbids it) fall
            // back to east so the shape stays finite.
            const hub_start = start;
            const hub_end = mapToScreen(to_position);
            const hub_dx: f32 = @floatFromInt(hub_end.x - hub_start.x);
            const hub_dy: f32 = @floatFromInt(hub_end.y - hub_start.y);
            const hub_length = @sqrt(hub_dx * hub_dx + hub_dy * hub_dy);
            const radius: f32 = @floatFromInt(hub_edge_anchor_radius);
            const unit_x = if (hub_length > 0) hub_dx / hub_length else 1;
            const unit_y = if (hub_length > 0) hub_dy / hub_length else 0;
            const from_x: f32 = @floatFromInt(hub_start.x);
            const from_y: f32 = @floatFromInt(hub_start.y);
            const to_x: f32 = @floatFromInt(hub_end.x);
            const to_y: f32 = @floatFromInt(hub_end.y);
            const start_x: f32 = from_x + unit_x * radius;
            const start_y: f32 = from_y + unit_y * radius;
            const end_x: f32 = to_x - unit_x * radius;
            const end_y: f32 = to_y - unit_y * radius;
            const dx: f32 = end_x - start_x;
            const dy: f32 = end_y - start_y;
            const offset: f32 = @as(f32, @floatFromInt(parallel_edge_spacing)) *
                (@as(f32, @floatFromInt(parallel.index)) -
                    (@as(f32, @floatFromInt(parallel.count)) + 1.0) / 2.0);
            const ox = (-dy / @max(@sqrt(dx * dx + dy * dy), 1.0)) * offset;
            const oy = (dx / @max(@sqrt(dx * dx + dy * dy), 1.0)) * offset;
            return .{
                .start = screenPoint(start_x, start_y),
                .control_start = screenPoint(start_x + dx / 3.0 + ox, start_y + dy / 3.0 + oy),
                .control_end = screenPoint(start_x + 2.0 * dx / 3.0 + ox, start_y + 2.0 * dy / 3.0 + oy),
                .end = screenPoint(end_x, end_y),
                .dashed = false,
            };
        },
        .dangling => {
            // Dangling stub: along the direction bearing from the hub's
            // boundary, dashed.
            const direction = directionUnitVector(direction_degrees);
            const radius: f32 = @floatFromInt(hub_edge_anchor_radius);
            const length: f32 = @floatFromInt(stub_length);
            const hub_x: f32 = @floatFromInt(start.x);
            const hub_y: f32 = @floatFromInt(start.y);
            const anchor_x: f32 = hub_x + direction.x * radius;
            const anchor_y: f32 = hub_y + direction.y * radius;
            return .{
                .start = screenPoint(anchor_x, anchor_y),
                .control_start = screenPoint(
                    anchor_x + direction.x * length / 3.0,
                    anchor_y + direction.y * length / 3.0,
                ),
                .control_end = screenPoint(
                    anchor_x + 2.0 * direction.x * length / 3.0,
                    anchor_y + 2.0 * direction.y * length / 3.0,
                ),
                .end = screenPoint(anchor_x + direction.x * length, anchor_y + direction.y * length),
                .dashed = true,
            };
        },
    }
}

// ============================================================
// Pure geometry tests - the three classes' shape contracts, asserted
// here in isolation so the builder tests can assert "the drawn curve
// equals deriveEdgeGeometry's output" instead of restating geometry.
// ============================================================

const map_origin_on_screen = ScreenPosition{
    .x = @divTrunc(types.reference_width, 2),
    .y = @divTrunc(types.reference_height, 2),
};

fn expectScreenPositionEqual(expected: ScreenPosition, actual: ScreenPosition) !void {
    if (expected.x != actual.x or expected.y != actual.y) {
        std.debug.print("expected ({d},{d}) got ({d},{d})\n", .{ expected.x, expected.y, actual.x, actual.y });
        return error.TestUnexpectedResult;
    }
}

test "deriveEdgeGeometry: self-loop teardrop anchors on the bearing, controls mirrored" {
    // A self-loop authored north (0 degrees) on the hub at the map origin.
    const geometry = deriveEdgeGeometry(.{ .x = 0, .y = 0 }, .self_loop, 0, .{ .index = 1, .count = 1 });

    // The anchor sits `hub_edge_anchor_radius` NORTH of the hub's screen
    // center; start == end == anchor.
    const anchor = ScreenPosition{
        .x = map_origin_on_screen.x,
        .y = map_origin_on_screen.y - hub_edge_anchor_radius,
    };
    try expectScreenPositionEqual(anchor, geometry.start);
    try expectScreenPositionEqual(anchor, geometry.end);
    try std.testing.expect(!geometry.dashed);

    // The teardrop is symmetric about the direction axis: both controls
    // at the same reach along it, mirrored across it by the half-width.
    try expectScreenPositionEqual(
        .{ .x = anchor.x + self_loop_half_width, .y = anchor.y - self_loop_length },
        geometry.control_start,
    );
    try expectScreenPositionEqual(
        .{ .x = anchor.x - self_loop_half_width, .y = anchor.y - self_loop_length },
        geometry.control_end,
    );
}

test "deriveEdgeGeometry: straight edge endpoints displace to each hub boundary" {
    // Two hubs offset purely horizontally, so the pair axis is east and
    // the displacement math is exact.
    const from_position = Vector2{ .x = -400, .y = 0 };
    const to_position = Vector2{ .x = 400, .y = 0 };
    const geometry = deriveEdgeGeometry(
        from_position,
        .{ .hub = to_position },
        0,
        .{ .index = 1, .count = 1 },
    );

    const from_center = mapToScreen(from_position);
    const to_center = mapToScreen(to_position);
    try expectScreenPositionEqual(
        .{ .x = from_center.x + hub_edge_anchor_radius, .y = from_center.y },
        geometry.start,
    );
    try expectScreenPositionEqual(
        .{ .x = to_center.x - hub_edge_anchor_radius, .y = to_center.y },
        geometry.end,
    );
    try std.testing.expect(!geometry.dashed);

    // A lone edge's controls sit on the segment at 1/3 + 2/3.
    const segment_length = geometry.end.x - geometry.start.x;
    try expectScreenPositionEqual(
        .{ .x = geometry.start.x + @divTrunc(segment_length, 3), .y = from_center.y },
        geometry.control_start,
    );
    try expectScreenPositionEqual(
        .{ .x = geometry.start.x + @divTrunc(2 * segment_length, 3), .y = from_center.y },
        geometry.control_end,
    );
}

test "deriveEdgeGeometry: parallel same-pair edges spread symmetrically" {
    // Two edges sharing the pair, spread by exit index - the shape
    // official content lacks (only self-loops ship), so asserted here on
    // synthetic inputs. A horizontal pair axis makes the perpendicular
    // offsets purely vertical. Only the CONTROLS slide - the endpoints
    // stay anchored at the hub boundaries, so siblings bow apart
    // mid-segment and converge at the hubs.
    const from_position = Vector2{ .x = -400, .y = 0 };
    const to_position = Vector2{ .x = 400, .y = 0 };
    const lone = deriveEdgeGeometry(from_position, .{ .hub = to_position }, 0, .{ .index = 1, .count = 1 });
    const first = deriveEdgeGeometry(from_position, .{ .hub = to_position }, 0, .{ .index = 1, .count = 2 });
    const second = deriveEdgeGeometry(from_position, .{ .hub = to_position }, 0, .{ .index = 2, .count = 2 });

    // Both siblings' controls offset from the lone-edge axis by exactly
    // half the spacing, on OPPOSITE sides (their midpoint is the axis).
    const half_spacing = @divTrunc(parallel_edge_spacing, 2);
    try expectEqualInt(lone.control_start.y - half_spacing, first.control_start.y);
    try expectEqualInt(lone.control_start.y + half_spacing, second.control_start.y);
    try expectEqualInt(
        first.control_start.y + second.control_start.y,
        2 * lone.control_start.y,
    );
    // The endpoints are NOT offset - the hub-boundary anchors hold for
    // every sibling.
    try expectScreenPositionEqual(lone.start, first.start);
    try expectScreenPositionEqual(lone.end, second.end);
}

fn expectEqualInt(expected: i32, actual: i32) !void {
    try std.testing.expectEqual(expected, actual);
}

test "deriveEdgeGeometry: dangling stub dashes along the bearing" {
    // A stub authored south (180 degrees) from the hub at the origin.
    const geometry = deriveEdgeGeometry(.{ .x = 0, .y = 0 }, .dangling, 180, .{ .index = 1, .count = 1 });

    const center = map_origin_on_screen;
    try expectScreenPositionEqual(
        .{ .x = center.x, .y = center.y + hub_edge_anchor_radius },
        geometry.start,
    );
    try expectScreenPositionEqual(
        .{ .x = center.x, .y = center.y + hub_edge_anchor_radius + stub_length },
        geometry.end,
    );
    try std.testing.expect(geometry.dashed);
    // The controls sit on the stub's segment (at 1/3 + 2/3 of its reach).
    try std.testing.expect(geometry.control_start.y > geometry.start.y);
    try std.testing.expect(geometry.control_end.y > geometry.control_start.y);
}

test "deriveEdgeGeometry: coincident hubs fall back to east" {
    // Distinct hubs placed at the SAME map position are legal (positions
    // are unbounded, nothing forbids coincidence); the zero-length pair
    // axis would divide by zero, so the shape falls back to east and
    // stays finite.
    const position = Vector2{ .x = 100, .y = 200 };
    const geometry = deriveEdgeGeometry(position, .{ .hub = position }, 0, .{ .index = 1, .count = 1 });

    const center = mapToScreen(position);
    try expectScreenPositionEqual(.{ .x = center.x + hub_edge_anchor_radius, .y = center.y }, geometry.start);
    try expectScreenPositionEqual(.{ .x = center.x - hub_edge_anchor_radius, .y = center.y }, geometry.end);
    try std.testing.expect(!geometry.dashed);
}
