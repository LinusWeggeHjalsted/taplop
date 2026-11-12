//! The world-map overlay's UI surface (the read-side mirror of the campaign
//! graph - see DESIGN → Campaigns & the Campaign Editor → The map surface +
//! Discovery + travel). Renders the ACTIVE campaign's derived edge table +
//! hubs as pure state reads: background (native size, centered on the
//! origin), hub icons, mission edges as `curve` pairs (a pure-black outline
//! stroke under a theme-lightest stroke). No hub/mission name labels - names
//! live in tooltips only. Visuals are decorative; the clickable surface
//! (travel + mission start) lands with slice 2d riding the spriteless-Button
//! + `hit_curve` seam.

const std = @import("std");
const types = @import("../types.zig");
const ui_element = @import("element.zig");
const ui_tooltip = @import("tooltip.zig");

const UiElement = ui_element.UiElement;
const UiElementList = ui_element.UiElementList;
const Rectangle = types.Rectangle;
const ScreenPosition = types.ScreenPosition;
const FontMetrics = ui_element.FontMetrics;
const Vector2 = types.Vector2;
const Color = types.Color;
const text = ui_element.text;

const spanRow = ui_tooltip.spanRow;

/// The hub icon's draw size (reference px, centered on the hub's map
/// position). A dedicated icon ships eventually; until then the id is
/// MISSING and draws the magenta placeholder (the art_report shopping list
/// carries it automatically).
pub const hub_icon_size: i32 = 128;

/// The placeholder sprite id for the hub icon + its art_report home.
const hub_icon_sprite_id = "world/hub_icon";

/// The mission-edge stroke width + its pure-black outline (each side adds
/// `edge_outline_width`, so the under-stroke is
/// `edge_width + 2 * edge_outline_width` wide).
const edge_width: i32 = 8;
const edge_outline_width: i32 = 8;

/// Dimmed (undiscovered) draw alpha - the simple-mirror dimming class.
const dimmed_alpha: u8 = 100;

/// Self-loop geometry: the teardrop's reach along the exit direction (L)
/// and half-width across it (w) - see DESIGN → Edge geometry. Fixed view
/// constants in v1 (style consistency); tweak freely.
const self_loop_length: i32 = 300;
const self_loop_half_width: i32 = 120;

/// The dangling-stub reach along the exit direction.
const stub_length: i32 = 300;

/// Edge endpoints anchor this far from the hub's CENTER (64 = half the
/// hub icon, so edges start at the icon's boundary): self-loops + stubs
/// along the exit's configured direction, straight edges along the
/// hub-position difference.
const hub_edge_anchor_radius: i32 = 64;

/// Perpendicular spacing between PARALLEL straight edges connecting the
/// same hub pair (spread by exit index - see DESIGN → Edge geometry).
const parallel_edge_spacing: i32 = 64;

pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };

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

/// Build the world-map overlay for `campaign` (the active campaign's derived
/// graph - hubs with names, the edge table; see `types.Campaign`). Pure
/// over its inputs: no file access, no session state. `discovered` is the
/// player's discovered-hubs groups (the active campaign's group is looked
/// up by uuid); a hub is LIT when discovered or the campaign's start hub
/// (the travel-legality rule applied to the view - a fresh campaign shows
/// its start hub + edges lit with everything else dimmed).
pub fn buildWorldMap(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    campaign: types.Campaign,
    discovered: []const types.DiscoveredCampaignHubs,
    active_theme: types.ActiveColorTheme,
) !void {
    _ = font_metrics;

    // The overlay surface: a full-screen dark fill that blocks input (the
    // world + panels behind must not receive clicks through the map).
    try elements.append(allocator, .{ .solid_rect = .{
        .screen_position = screen.position(),
        .width = screen.width,
        .height = screen.height,
        .color = active_theme.darkest,
        .blocks_input = true,
    } });

    // The background, native size, centered on the origin (a 1000x1000
    // image is an island in the middle - stored positions never depend on
    // the art's dimensions; see DESIGN → The map coordinate model). Dims
    // are resolved at campaign load; no background dims, no background.
    if (campaign.background_dims) |dims| {
        const center = mapToScreen(.{ .x = 0, .y = 0 });
        try elements.append(allocator, .{ .image = .{
            .sprite_id = campaign.background,
            .screen_position = .{
                .x = center.x - @divTrunc(dims.x, 2),
                .y = center.y - @divTrunc(dims.y, 2),
            },
            .width = dims.x,
            .height = dims.y,
            .blocks_input = false,
        } });
    }

    // The active campaign's discovered group.
    var discovered_hubs: []const []const u8 = &.{};
    for (discovered) |group| {
        if (std.mem.eql(u8, group.campaign_uuid, campaign.uuid)) {
            discovered_hubs = group.hub_uuids;
            break;
        }
    }
    const hubDiscovered = struct {
        fn check(hubs: []const []const u8, start_hub: []const u8, uuid: []const u8) bool {
            if (std.mem.eql(u8, uuid, start_hub)) return true;
            for (hubs) |hub_uuid| {
                if (std.mem.eql(u8, hub_uuid, uuid)) return true;
            }
            return false;
        }
    }.check;

    // Hubs: an icon centered on each position, dimmed when undiscovered.
    // The name rides the tooltip (no map labels).
    for (campaign.hubs) |hub| {
        const center = mapToScreen(hub.position);
        const lit = hubDiscovered(discovered_hubs, campaign.start_hub, hub.uuid);
        try elements.append(allocator, .{ .image = .{
            .sprite_id = hub_icon_sprite_id,
            .screen_position = .{
                .x = center.x - @divTrunc(hub_icon_size, 2),
                .y = center.y - @divTrunc(hub_icon_size, 2),
            },
            .width = hub_icon_size,
            .height = hub_icon_size,
            .alpha = if (lit) 255 else dimmed_alpha,
            .blocks_input = false,
            .tooltip = .{ .header = try spanRow(allocator, text(hub.name)) },
        } });
    }

    // Edges: one curve pair per edge (black outline under the lightest
    // stroke). Lit iff the edge's start hub is lit (the clickable rule
    // applied to the view). Three geometric classes:
    //   self-loop (destination == from): the teardrop control placement;
    //   straight (destination placed): the degenerate bezier, parallel
    //     same-pair edges spread perpendicular by exit index;
    //   dangling stub (destination unplaced/empty): a dash along the
    //     direction bearing.
    const lightest = active_theme.lightest;
    for (campaign.edges) |edge| {
        var from_hub: ?types.CampaignHub = null;
        var to_hub: ?types.CampaignHub = null;
        for (campaign.hubs) |hub| {
            if (std.mem.eql(u8, hub.uuid, edge.from)) from_hub = hub;
            if (edge.destination.len > 0 and std.mem.eql(u8, hub.uuid, edge.destination)) to_hub = hub;
        }
        const origin = from_hub orelse continue;

        var start = mapToScreen(origin.position);
        var control_start: ScreenPosition = start;
        var control_end: ScreenPosition = start;
        var end: ScreenPosition = start;
        var dashed = false;

        if (edge.destination.len > 0 and std.mem.eql(u8, edge.destination, edge.from)) {
            // Self-loop: the anchor sits on the exit's direction bearing
            // at the hub's edge; the teardrop extends from it -
            // {a, a + d*L + n*w, a + d*L - n*w, a} with a = hub + d*R.
            const direction = directionUnitVector(edge.direction_degrees);
            const px = -direction.y;
            const py = direction.x;
            const radius: f32 = @floatFromInt(hub_edge_anchor_radius);
            const hub_x: f32 = @floatFromInt(start.x);
            const hub_y: f32 = @floatFromInt(start.y);
            const anchor_x: f32 = hub_x + direction.x * radius;
            const anchor_y: f32 = hub_y + direction.y * radius;
            const length: f32 = @floatFromInt(self_loop_length);
            const half_width: f32 = @floatFromInt(self_loop_half_width);
            start = screenPoint(anchor_x, anchor_y);
            control_start = screenPoint(
                anchor_x + direction.x * length + px * half_width,
                anchor_y + direction.y * length + py * half_width,
            );
            control_end = screenPoint(
                anchor_x + direction.x * length - px * half_width,
                anchor_y + direction.y * length - py * half_width,
            );
            end = start;
        } else if (to_hub) |destination| {
            // Straight edge: the direction is the HUB-POSITION difference
            // (well-defined), the endpoints displaced to each hub's
            // boundary along it. Controls on the segment at 1/3 + 2/3,
            // slid perpendicular by the parallel-spread offset for
            // same-pair edges (the exit's index among its pair).
            const hub_start = start;
            const hub_end = mapToScreen(destination.position);
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
            start = screenPoint(start_x, start_y);
            end = screenPoint(end_x, end_y);
            var parallel_index: i32 = 0;
            var parallel_count: i32 = 0;
            for (campaign.edges) |other| {
                const same_pair = std.mem.eql(u8, other.from, edge.from) and
                    std.mem.eql(u8, other.destination, edge.destination);
                if (!same_pair) continue;
                if (other.exit_index <= edge.exit_index) parallel_index += 1;
                parallel_count += 1;
            }
            const dx: f32 = end_x - start_x;
            const dy: f32 = end_y - start_y;
            const offset: f32 = @as(f32, @floatFromInt(parallel_edge_spacing)) *
                (@as(f32, @floatFromInt(parallel_index)) -
                    (@as(f32, @floatFromInt(parallel_count)) + 1.0) / 2.0);
            const ox = (-dy / @max(@sqrt(dx * dx + dy * dy), 1.0)) * offset;
            const oy = (dx / @max(@sqrt(dx * dx + dy * dy), 1.0)) * offset;
            control_start = screenPoint(start_x + dx / 3.0 + ox, start_y + dy / 3.0 + oy);
            control_end = screenPoint(start_x + 2.0 * dx / 3.0 + ox, start_y + 2.0 * dy / 3.0 + oy);
        } else {
            // Dangling stub: along the direction bearing from the hub's
            // boundary, dashed.
            const direction = directionUnitVector(edge.direction_degrees);
            const radius: f32 = @floatFromInt(hub_edge_anchor_radius);
            const length: f32 = @floatFromInt(stub_length);
            const hub_x: f32 = @floatFromInt(start.x);
            const hub_y: f32 = @floatFromInt(start.y);
            const anchor_x: f32 = hub_x + direction.x * radius;
            const anchor_y: f32 = hub_y + direction.y * radius;
            start = screenPoint(anchor_x, anchor_y);
            end = screenPoint(anchor_x + direction.x * length, anchor_y + direction.y * length);
            control_start = screenPoint(
                anchor_x + direction.x * length / 3.0,
                anchor_y + direction.y * length / 3.0,
            );
            control_end = screenPoint(
                anchor_x + 2.0 * direction.x * length / 3.0,
                anchor_y + 2.0 * direction.y * length / 3.0,
            );
            dashed = true;
        }

        const lit = hubDiscovered(discovered_hubs, campaign.start_hub, edge.from);
        const tooltip: ?ui_element.Tooltip = if (edge.mission_name.len > 0)
            .{ .header = try spanRow(allocator, text(edge.mission_name)) }
        else
            null;

        // The outline stroke first (painter order), then the lightest
        // stroke on top - both carry the same geometry, so the drawn edge
        // and the (future, slice 2d) hit region agree.
        try elements.append(allocator, .{ .curve = .{
            .start = start,
            .control_start = control_start,
            .control_end = control_end,
            .end = end,
            .width = edge_width + 2 * edge_outline_width,
            .color = black,
            .dashed = dashed,
            .arrowhead = true,
            .blocks_input = false,
        } });
        try elements.append(allocator, .{ .curve = .{
            .start = start,
            .control_start = control_start,
            .control_end = control_end,
            .end = end,
            .width = edge_width,
            .color = lightest,
            .alpha = if (lit) 255 else dimmed_alpha,
            .dashed = dashed,
            .arrowhead = true,
            .blocks_input = false,
            .tooltip = tooltip,
        } });
    }
}

// ============================================================
// Structure tests
// ============================================================

const test_font_metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };

const test_theme = types.ActiveColorTheme{
    .lightest = .{ .r = 10, .g = 20, .b = 30 },
    .darkest = .{ .r = 1, .g = 2, .b = 3 },
    .world_gradient = undefined,
    .enemy_gradient = undefined,
    .player_gradient = undefined,
};

/// Euclidean distance between two screen positions, rounded to an i32
/// (test helper for displacement contracts).
fn screenDistance(a: ScreenPosition, b: ScreenPosition) i32 {
    const dx: f32 = @floatFromInt(a.x - b.x);
    const dy: f32 = @floatFromInt(a.y - b.y);
    return @intFromFloat(@round(@sqrt(dx * dx + dy * dy)));
}

fn buildFixtureCampaign() types.Campaign {
    return .{
        .name = "Fixture",
        .uuid = "camp",
        .dir = "fixture",
        .start_hub = "a",
        .background = "custom/campaigns/fixture/map",
        .background_dims = .{ .x = 1000, .y = 600 },
        .hubs = &.{
            .{ .uuid = "a", .dir = "hub_a", .position = .{ .x = -200, .y = 0 }, .name = "Alpha" },
            .{ .uuid = "b", .dir = "hub_b", .position = .{ .x = 400, .y = 300 }, .name = "Beta" },
        },
        .edges = &.{
            // Self-loop on the start hub, authored north.
            .{ .from = "a", .destination = "a", .mission_uuid = "m1", .mission_dir = "missions/m1", .mission_name = "Loop", .direction_degrees = 0, .exit_index = 0 },
            // Straight edge a -> b.
            .{ .from = "a", .destination = "b", .mission_uuid = "m2", .mission_dir = "missions/m2", .mission_name = "Cross", .direction_degrees = 90, .exit_index = 0 },
            // Dangling stub from b (destination names nothing).
            .{ .from = "b", .destination = "zzz", .mission_uuid = "m3", .mission_dir = "missions/m3", .mission_name = "Beyond", .direction_degrees = 180, .exit_index = 0 },
        },
    };
}

test "buildWorldMap: surface, background, hubs, and the three edge classes" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var elements: UiElementList = .empty;
    defer elements.deinit(arena.allocator());

    const campaign = buildFixtureCampaign();
    try buildWorldMap(
        &elements,
        arena.allocator(),
        test_font_metrics,
        ui_element.screenRect(),
        campaign,
        &.{.{ .campaign_uuid = "camp", .hub_uuids = &.{"b"} }},
        test_theme,
    );

    // Derived expectations: 1 surface + 1 background + 2 hub icons +
    // 2 curves per edge (3 edges) = 10 elements total. Derived from the
    // fixture lists, not a magic number snapshot.
    const expected_total = 1 + @as(usize, if (campaign.background_dims != null) 1 else 0) +
        campaign.hubs.len + 2 * campaign.edges.len;
    try std.testing.expectEqual(expected_total, elements.items.len);

    // The surface blocks input; everything else is decorative.
    try std.testing.expect(elements.items[0].solid_rect.blocks_input);

    // The background: native size, centered on the map's origin (screen
    // center, since the framing region equals the reference resolution).
    const background = elements.items[1].image;
    try std.testing.expectEqualStrings("custom/campaigns/fixture/map", background.sprite_id);
    try std.testing.expectEqual(@as(i32, 1000), background.width);
    try std.testing.expectEqual(@as(i32, 600), background.height);
    try std.testing.expectEqual(
        @divTrunc(types.reference_width, 2) - 500,
        background.screen_position.x,
    );
    try std.testing.expectEqual(
        @divTrunc(types.reference_height, 2) - 300,
        background.screen_position.y,
    );

    // Hub icons: centered on mapToScreen(position); Alpha lit (start hub
    // discovered-or-start + 'b' in the discovered set), Beta lit; the name
    // rides the tooltip, not a label.
    const alpha_icon = elements.items[2].image;
    try std.testing.expectEqualStrings("world/hub_icon", alpha_icon.sprite_id);
    try std.testing.expectEqual(mapToScreen(.{ .x = -200, .y = 0 }).x - 64, alpha_icon.screen_position.x);
    try std.testing.expectEqual(@as(u8, 255), alpha_icon.alpha);
    try std.testing.expectEqualStrings("Alpha", alpha_icon.tooltip.?.header.?[0].text);
    const beta_icon = elements.items[3].image;
    try std.testing.expectEqual(@as(u8, 255), beta_icon.alpha);

    // Edge curves arrive as pairs (black outline, then lightest stroke).
    // Pair 0: the self-loop - start == end == the anchor 64px NORTH of
    // hub a's screen center (direction 0, the hub icon's boundary), the
    // controls at the teardrop offsets beyond the anchor.
    const loop_black = elements.items[4].curve;
    const loop_light = elements.items[5].curve;
    const loop_center = mapToScreen(.{ .x = -200, .y = 0 });
    const loop_anchor: ScreenPosition = .{
        .x = loop_center.x,
        .y = loop_center.y - hub_edge_anchor_radius,
    };
    try std.testing.expectEqual(loop_anchor, loop_black.start);
    try std.testing.expectEqual(loop_anchor, loop_black.end);
    try std.testing.expectEqual(black, loop_black.color);
    try std.testing.expectEqual(edge_width + 2 * edge_outline_width, loop_black.width);
    try std.testing.expect(loop_black.arrowhead);
    try std.testing.expectEqual(test_theme.lightest, loop_light.color);
    try std.testing.expectEqual(edge_width, loop_light.width);
    try std.testing.expect(loop_light.arrowhead);
    try std.testing.expectEqualStrings("Loop", loop_light.tooltip.?.header.?[0].text);
    try std.testing.expect(loop_light.control_start.y < loop_anchor.y);
    try std.testing.expect(loop_light.control_end.y < loop_anchor.y);
    // The teardrop is symmetric about the direction axis (north): both
    // controls at the same reach along the axis, mirrored across it.
    try std.testing.expectEqual(loop_light.control_start.y, loop_light.control_end.y);
    try std.testing.expectEqual(loop_anchor.x + self_loop_half_width, loop_light.control_start.x);
    try std.testing.expectEqual(loop_anchor.x - self_loop_half_width, loop_light.control_end.x);
    try std.testing.expectEqual(loop_anchor.y - self_loop_length, loop_light.control_start.y);

    // Pair 1: the straight edge a -> b - endpoints displaced to each
    // hub's boundary along the hub-position difference (64px from each
    // center), solid, lit (its start hub 'a' is the start hub).
    const straight_light = elements.items[7].curve;
    const a_center = mapToScreen(.{ .x = -200, .y = 0 });
    const b_center = mapToScreen(.{ .x = 400, .y = 300 });
    try std.testing.expectEqual(@as(i32, 64), screenDistance(straight_light.start, a_center));
    try std.testing.expectEqual(@as(i32, 64), screenDistance(straight_light.end, b_center));
    // The displacement is ALONG the hub line: start sits between the two
    // centers (positive scalar projection onto a->b, less than the full
    // distance).
    try std.testing.expect(straight_light.start.x > a_center.x and straight_light.start.y > a_center.y);
    try std.testing.expect(straight_light.end.x < b_center.x and straight_light.end.y < b_center.y);
    try std.testing.expect(!straight_light.dashed);
    try std.testing.expect(straight_light.arrowhead);
    try std.testing.expectEqual(@as(u8, 255), straight_light.alpha);

    // Pair 2: the dangling stub from b - dashed, pointing south
    // (direction 180) from the hub's boundary anchor, lit ('b' is in the
    // discovered set, so its start hub is lit; the dimming case is
    // asserted in the dedicated test below).
    const stub_light = elements.items[9].curve;
    try std.testing.expect(stub_light.dashed);
    try std.testing.expect(stub_light.arrowhead);
    try std.testing.expectEqual(b_center.y + hub_edge_anchor_radius, stub_light.start.y);
    try std.testing.expectEqual(b_center.x, stub_light.start.x);
    try std.testing.expectEqual(b_center.y + hub_edge_anchor_radius + stub_length, stub_light.end.y);
    try std.testing.expect(stub_light.control_start.y > stub_light.start.y);
}

test "buildWorldMap: undiscovered hubs + edges dim; a fresh campaign shows only the start hub lit" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var elements: UiElementList = .empty;
    defer elements.deinit(arena.allocator());

    const campaign = buildFixtureCampaign();
    // No discovered group at all - a fresh campaign: every hub lit only via
    // the start-hub rule, so Alpha lit, Beta dimmed, and only the edges
    // FROM the start hub lit.
    try buildWorldMap(
        &elements,
        arena.allocator(),
        test_font_metrics,
        ui_element.screenRect(),
        campaign,
        &.{},
        test_theme,
    );

    const beta_icon = elements.items[3].image;
    try std.testing.expectEqual(dimmed_alpha, beta_icon.alpha);
    // Pair 1 (a -> b): start hub 'a' is the start hub - lit.
    try std.testing.expectEqual(@as(u8, 255), elements.items[7].curve.alpha);
    // Pair 2 (the stub from b): 'b' undiscovered - dimmed.
    try std.testing.expectEqual(dimmed_alpha, elements.items[9].curve.alpha);
}
