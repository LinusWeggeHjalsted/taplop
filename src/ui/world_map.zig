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
const emit = @import("emit.zig");
const campaign_geometry = @import("campaign_geometry.zig");

const UiElement = ui_element.UiElement;
const UiElementList = ui_element.UiElementList;
const Rectangle = types.Rectangle;
const ScreenPosition = types.ScreenPosition;
const FontMetrics = ui_element.FontMetrics;
const Vector2 = types.Vector2;
const Color = types.Color;
const text = ui_element.text;

const spanRow = ui_tooltip.spanRow;
const top_bar_height = ui_element.top_bar_height;
const ui_gap = ui_element.ui_gap;

/// The campaign button's metrics - smaller than a panel button (the
/// nameplate shares the map's corner with the world, it is not a primary
/// action). Font size is the round step down at roughly the menu buttons'
/// 0.6 height/font ratio (128 * 0.6 = 76.8 -> 72).
const campaign_button_height: i32 = 128;
const campaign_button_font_size: i32 = 72;

/// The hub icon's draw size (reference px, centered on the hub's map
/// position). A dedicated icon ships eventually; until then the id is
/// MISSING and draws the magenta placeholder (the art_report shopping list
/// carries it automatically).
pub const hub_icon_size: i32 = 64;

/// The placeholder sprite id for the hub icon + its art_report home.
const hub_icon_sprite_id = "world/hub_icon";

/// Dimmed (undiscovered) draw alpha - the simple-mirror dimming class.
const dimmed_alpha: u8 = 100;

// The shared campaign-map geometry (the map->screen transform, the three
// edge-shape derivations, the view constants) lives in
// campaign_geometry.zig - the ONE implementation behind "one data model,
// two renderers": the campaign editor's view (slice 3) renders the same
// graph through the same `deriveEdgeGeometry`.
const mapToScreen = campaign_geometry.mapToScreen;
const deriveEdgeGeometry = campaign_geometry.deriveEdgeGeometry;
const EdgeEndpoint = campaign_geometry.EdgeEndpoint;
const ParallelSpread = campaign_geometry.ParallelSpread;
const edge_width = campaign_geometry.edge_width;
const edge_outline_width = campaign_geometry.edge_outline_width;
const black = campaign_geometry.black;

/// The edge's position among its same-pair siblings (straight edges
/// connecting the same hub pair): 1-based by exit_index, over the count
/// of same-pair edges. Pair identity is uuid equality here - the
/// caller-side scan feeding `deriveEdgeGeometry`'s spread (the editor's
/// authored graph computes the same shape from its own pair identity).
fn parallelSpread(edges: []const types.CampaignEdgeEntry, edge: types.CampaignEdgeEntry) ParallelSpread {
    var index: i32 = 0;
    var count: i32 = 0;
    for (edges) |other| {
        const same_pair = std.mem.eql(u8, other.from, edge.from) and
            std.mem.eql(u8, other.destination, edge.destination);
        if (!same_pair) continue;
        if (other.exit_index <= edge.exit_index) index += 1;
        count += 1;
    }
    return .{ .index = index, .count = count };
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
    button_color: Color,
) !void {
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

    // The campaign button (top-left, immediately below the global top
    // bar): opens the campaign browser (the full-screen picker overlay).
    // The label is the VIEWED campaign's name, no prefix - the button is
    // the nameplate of whatever the map is showing.
    const campaign_label = if (campaign.name.len > 0) campaign.name else "Campaign";
    const campaign_label_width = font_metrics.measureSpanWidth(text(campaign_label), campaign_button_font_size);
    try emit.emitPanelButton(
        elements,
        allocator,
        font_metrics,
        .{
            .x = screen.x + ui_gap,
            .y = screen.y + top_bar_height + ui_gap,
            .width = campaign_label_width + 4 * ui_gap,
            .height = campaign_button_height,
        },
        campaign_label,
        campaign_button_font_size,
        .toggle_campaign_browser,
        button_color,
        null,
    );

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
    // The name rides the tooltip (no map labels). Each LIT hub icon gets a
    // spriteless button (the clickable travel target): discovered-or-start
    // is exactly the travel-legality rule, so what the map lights is what
    // is clickable - an undiscovered hub is not a target (backtrack-only).
    for (campaign.hubs, 0..) |hub, hub_index| {
        const center = mapToScreen(hub.position);
        const lit = hubDiscovered(discovered_hubs, campaign.start_hub, hub.uuid);
        const icon_rect = Rectangle{
            .x = center.x - @divTrunc(hub_icon_size, 2),
            .y = center.y - @divTrunc(hub_icon_size, 2),
            .width = hub_icon_size,
            .height = hub_icon_size,
        };
        try elements.append(allocator, .{ .image = .{
            .sprite_id = hub_icon_sprite_id,
            .screen_position = icon_rect.position(),
            .width = hub_icon_size,
            .height = hub_icon_size,
            .alpha = if (lit) 255 else dimmed_alpha,
            .blocks_input = false,
            .tooltip = .{ .header = try spanRow(allocator, text(hub.name)) },
        } });
        if (lit) {
            // The travel target's tooltip carries the hub name (the same
            // read the icon gives) - the click resolves the hub uuid +
            // the campaign identity (viewing's cross-campaign branch) at
            // the consumption site.
            try elements.append(allocator, .{ .button = .{
                .sprite_id = null,
                .screen_position = icon_rect.position(),
                .width = hub_icon_size,
                .height = hub_icon_size,
                .action = .travel_to_map_hub,
                .payload = .{ .map_hub = @intCast(hub_index) },
                .tooltip = .{ .header = try spanRow(allocator, text(hub.name)) },
            } });
        }
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
    for (campaign.edges, 0..) |edge, edge_index| {
        var from_hub: ?types.CampaignHub = null;
        var to_hub: ?types.CampaignHub = null;
        for (campaign.hubs) |hub| {
            if (std.mem.eql(u8, hub.uuid, edge.from)) from_hub = hub;
            if (edge.destination.len > 0 and std.mem.eql(u8, hub.uuid, edge.destination)) to_hub = hub;
        }
        const origin = from_hub orelse continue;

        // Resolve the destination into the geometric endpoint class + the
        // parallel-spread position, then derive the shape through the
        // shared helper - the campaign editor's view renders the same
        // graph through the same derivation ("one data model, two
        // renderers").
        var endpoint: EdgeEndpoint = .dangling;
        if (edge.destination.len > 0 and std.mem.eql(u8, edge.destination, edge.from)) {
            endpoint = .self_loop;
        } else if (to_hub) |destination| {
            endpoint = .{ .hub = destination.position };
        }
        const geometry = deriveEdgeGeometry(
            origin.position,
            endpoint,
            edge.direction_degrees,
            parallelSpread(campaign.edges, edge),
        );

        const lit = hubDiscovered(discovered_hubs, campaign.start_hub, edge.from);
        const tooltip: ?ui_element.Tooltip = if (edge.mission_name.len > 0)
            .{ .header = try spanRow(allocator, text(edge.mission_name)) }
        else
            null;

        // The clickable edge: a spriteless button whose hit region is the
        // DRAWN ARROW's sampled stroke (the hit_curve seam - distance to
        // the polyline, not the bounds rect), emitted BEFORE the stroke
        // pair so the hover-highlight rim (drawn by the backend from the
        // same curve, wider) renders BENEATH the black outline + lightest
        // stroke (painter order; the curves are hit-test-transparent, so
        // emission order only affects paint). The hit_curve carries the
        // drawn arrow's OUTLINE-INCLUSIVE width (black outline + inner
        // stroke) + the dashed/arrowhead flags - hit-testing, the tooltip
        // bounds (curveBounds), and the highlight rim all derive from it.
        // Clickable exactly when the edge is lit (its start hub
        // discovered-or-start = the mission-entry legality); the mission
        // tooltip rides the button too (containsPoint respects hit_curve,
        // so the tooltip shows exactly where a click would work - a
        // bounds-rect hover on the decorative stroke would cover the whole
        // bezier bbox). An edge with no resolvable mission is never
        // clickable (the consumption site's popup names the broken exit) -
        // a dangling DESTINATION is still clickable (it is a placed hub +
        // mission, only the to-end forward reference is missing).
        if (lit and edge.mission_dir.len > 0) {
            const hit_curve = ui_element.Curve{
                .start = geometry.start,
                .control_start = geometry.control_start,
                .control_end = geometry.control_end,
                .end = geometry.end,
                .width = edge_width + 2 * edge_outline_width,
                .dashed = geometry.dashed,
                .arrowhead = true,
            };
            const bounds = ui_element.curveBounds(hit_curve);
            try elements.append(allocator, .{ .button = .{
                .sprite_id = null,
                .screen_position = bounds.position(),
                .width = bounds.width,
                .height = bounds.height,
                .action = .start_mission_from_map_edge,
                .payload = .{ .map_edge = @intCast(edge_index) },
                .hit_curve = hit_curve,
                .tooltip = tooltip,
            } });
        }

        // The outline stroke (painter order), then the lightest stroke on
        // top - both carry the same geometry, and the hit region (above)
        // samples the SAME curve, so the drawn edge and its click target
        // agree by construction.
        try elements.append(allocator, .{ .curve = .{
            .start = geometry.start,
            .control_start = geometry.control_start,
            .control_end = geometry.control_end,
            .end = geometry.end,
            .width = edge_width + 2 * edge_outline_width,
            .color = black,
            .dashed = geometry.dashed,
            .arrowhead = true,
            .blocks_input = false,
        } });
        try elements.append(allocator, .{ .curve = .{
            .start = geometry.start,
            .control_start = geometry.control_start,
            .control_end = geometry.control_end,
            .end = geometry.end,
            .width = edge_width,
            .color = lightest,
            .alpha = if (lit) 255 else dimmed_alpha,
            .dashed = geometry.dashed,
            .arrowhead = true,
            .blocks_input = false,
        } });
    }
}

// ============================================================
// Structure tests - elements are found by PREDICATE SCAN (action +
// payload, sprite id + tooltip name, drawn geometry), never by
// flat-list index: the 2d/2e sessions re-indexed these tests four
// times on emission-order changes (icon resize, clickable buttons,
// emission reorder), each pass slow and error-prone. A predicate scan
// survives any reorder; edge curves are found by their FULL geometry,
// derived through the SAME shared helper the builder uses - so the
// tests assert the builder draws exactly deriveEdgeGeometry's output
// (the one-implementation contract), not restated geometry math.
// ============================================================

const test_font_metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };

const test_theme = types.ActiveColorTheme{
    .lightest = .{ .r = 10, .g = 20, .b = 30 },
    .darkest = .{ .r = 1, .g = 2, .b = 3 },
    .world_gradient = undefined,
    .enemy_gradient = undefined,
    .player_gradient = undefined,
};

const test_button_color = Color{ .r = 50, .g = 50, .b = 50 };

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

/// The fixture's expected edge geometry, edge-indexed - derived through
/// the same shared helper the builder uses, with the fixture's endpoint
/// CLASSES spelled out per edge (so the builder's classification is
/// under test, not just its emission).
fn fixtureEdgeGeometry(campaign: types.Campaign, edge_index: usize) campaign_geometry.EdgeGeometry {
    const edge = campaign.edges[edge_index];
    const from_position = if (edge_index == 2) campaign.hubs[1].position else campaign.hubs[0].position;
    const endpoint: campaign_geometry.EdgeEndpoint = switch (edge_index) {
        0 => .self_loop,
        1 => .{ .hub = campaign.hubs[1].position },
        2 => .dangling,
        else => unreachable,
    };
    return deriveEdgeGeometry(from_position, endpoint, edge.direction_degrees, parallelSpread(campaign.edges, edge));
}

fn screenPositionEqual(a: ScreenPosition, b: ScreenPosition) bool {
    return a.x == b.x and a.y == b.y;
}

fn colorEqual(a: Color, b: Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}

fn curveGeometryMatches(curve: ui_element.Curve, geometry: campaign_geometry.EdgeGeometry) bool {
    return screenPositionEqual(curve.start, geometry.start) and
        screenPositionEqual(curve.control_start, geometry.control_start) and
        screenPositionEqual(curve.control_end, geometry.control_end) and
        screenPositionEqual(curve.end, geometry.end) and
        curve.dashed == geometry.dashed;
}

/// Find the first element matching `matches`, failing loudly (naming
/// what was being looked for) when nothing does - the scan helpers'
/// shared back end for parameterless predicates.
fn findFirst(elements: []const UiElement, context: []const u8, matches: fn (element: UiElement) bool) !usize {
    for (elements, 0..) |element, index| {
        if (matches(element)) return index;
    }
    std.debug.print("predicate scan found no {s}\n", .{context});
    return error.TestUnexpectedResult;
}

/// The hub icon for `hub_name` (the name rides the icon's tooltip).
fn findHubIcon(elements: []const UiElement, hub_name: []const u8) !usize {
    for (elements, 0..) |element, index| {
        if (element != .image) continue;
        const image = element.image;
        if (!std.mem.eql(u8, image.sprite_id, hub_icon_sprite_id)) continue;
        if (image.tooltip == null or image.tooltip.?.header == null) continue;
        if (std.mem.eql(u8, image.tooltip.?.header.?[0].text, hub_name)) return index;
    }
    std.debug.print("predicate scan found no hub icon named {s}\n", .{hub_name});
    return error.TestUnexpectedResult;
}

/// The travel button for hub `hub_index` (action + payload).
fn findHubTravelButton(elements: []const UiElement, hub_index: u32) !usize {
    for (elements, 0..) |element, index| {
        if (element != .button) continue;
        const button = element.button;
        if (button.action != .travel_to_map_hub) continue;
        if (button.payload == null or button.payload.? != .map_hub) continue;
        if (button.payload.?.map_hub == hub_index) return index;
    }
    std.debug.print("predicate scan found no travel button for hub {d}\n", .{hub_index});
    return error.TestUnexpectedResult;
}

/// The clickable edge button for edge `edge_index` (action + payload).
fn findEdgeButton(elements: []const UiElement, edge_index: u32) !usize {
    for (elements, 0..) |element, index| {
        if (element != .button) continue;
        const button = element.button;
        if (button.action != .start_mission_from_map_edge) continue;
        if (button.payload == null or button.payload.? != .map_edge) continue;
        if (button.payload.?.map_edge == edge_index) return index;
    }
    std.debug.print("predicate scan found no edge button for edge {d}\n", .{edge_index});
    return error.TestUnexpectedResult;
}

/// The lightest-colored stroke drawing `geometry`.
fn findLightCurve(elements: []const UiElement, geometry: campaign_geometry.EdgeGeometry) !usize {
    for (elements, 0..) |element, index| {
        if (element != .curve) continue;
        if (!colorEqual(element.curve.color, test_theme.lightest)) continue;
        if (curveGeometryMatches(element.curve, geometry)) return index;
    }
    std.debug.print("predicate scan found no lightest stroke for the edge geometry\n", .{});
    return error.TestUnexpectedResult;
}

/// The black outline stroke drawing `geometry`.
fn findBlackCurve(elements: []const UiElement, geometry: campaign_geometry.EdgeGeometry) !usize {
    for (elements, 0..) |element, index| {
        if (element != .curve) continue;
        if (!colorEqual(element.curve.color, black)) continue;
        if (curveGeometryMatches(element.curve, geometry)) return index;
    }
    std.debug.print("predicate scan found no black stroke for the edge geometry\n", .{});
    return error.TestUnexpectedResult;
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
        test_button_color,
    );

    // Derived expectations: 1 surface + 1 background + the campaign
    // button's 3 elements (panel + button + label - emitPanelButton) +
    // per hub 1 icon + 1 clickable button (BOTH fixture hubs are lit:
    // the start hub by the start rule, Beta by the discovered set) +
    // per LIT edge 2 curves + 1 clickable button (all three fixture
    // edges have a resolvable mission_dir + lit start hubs). Derived
    // from the fixture lists, not a magic number snapshot.
    var lit_hub_count: usize = 0;
    for (campaign.hubs) |hub| {
        if (std.mem.eql(u8, hub.uuid, campaign.start_hub) or
            std.mem.eql(u8, hub.uuid, "b")) lit_hub_count += 1;
    }
    const expected_total = 1 + @as(usize, if (campaign.background_dims != null) 1 else 0) +
        3 + 2 * lit_hub_count + 3 * campaign.edges.len;
    try std.testing.expectEqual(expected_total, elements.items.len);

    // The surface blocks input (the map's only solid_rect); everything
    // else is decorative.
    const surface = elements.items[
        try findFirst(elements.items, "surface solid_rect", struct {
            fn matches(element: UiElement) bool {
                return element == .solid_rect;
            }
        }.matches)
    ].solid_rect;
    try std.testing.expect(surface.blocks_input);

    // The background: native size, centered on the map's origin (screen
    // center, since the framing region equals the reference resolution).
    const background = elements.items[
        try findFirst(elements.items, "background image", struct {
            fn matches(element: UiElement) bool {
                return element == .image and
                    std.mem.eql(u8, element.image.sprite_id, "custom/campaigns/fixture/map");
            }
        }.matches)
    ].image;
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

    // The campaign button (the nameplate) fires the browser toggle; the
    // label is the campaign's name.
    _ = try findFirst(elements.items, "campaign browser button", struct {
        fn matches(element: UiElement) bool {
            return element == .button and
                element.button.action == .toggle_campaign_browser;
        }
    }.matches);
    _ = try findFirst(elements.items, "campaign nameplate label", struct {
        fn matches(element: UiElement) bool {
            return element == .text_label and
                std.mem.eql(u8, element.text_label.text, "Fixture");
        }
    }.matches);

    // Hub icons: centered on mapToScreen(position); the name rides the
    // tooltip, not a label. Both fixture hubs are lit (the start-hub
    // rule + the discovered set).
    const alpha_icon = elements.items[try findHubIcon(elements.items, "Alpha")].image;
    try std.testing.expectEqual(mapToScreen(.{ .x = -200, .y = 0 }).x - @divTrunc(hub_icon_size, 2), alpha_icon.screen_position.x);
    try std.testing.expectEqual(@as(u8, 255), alpha_icon.alpha);
    try std.testing.expectEqual(@as(u8, 255), elements.items[try findHubIcon(elements.items, "Beta")].image.alpha);

    // Both lit hubs carry a spriteless travel button over their icon,
    // with the hub's index in the payload.
    const alpha_travel = elements.items[try findHubTravelButton(elements.items, 0)].button;
    try std.testing.expect(alpha_travel.sprite_id == null);
    _ = try findHubTravelButton(elements.items, 1);

    // Edge 0: the self-loop on a (authored north). The drawn strokes ARE
    // deriveEdgeGeometry's output (the scan matches the full geometry);
    // the emission-level facts are the stroke pair's colors + widths.
    const loop_geometry = fixtureEdgeGeometry(campaign, 0);
    const loop_light = elements.items[try findLightCurve(elements.items, loop_geometry)].curve;
    const loop_black = elements.items[try findBlackCurve(elements.items, loop_geometry)].curve;
    try std.testing.expectEqual(test_theme.lightest, loop_light.color);
    try std.testing.expectEqual(edge_width, loop_light.width);
    try std.testing.expect(loop_light.arrowhead);
    try std.testing.expectEqual(black, loop_black.color);
    try std.testing.expectEqual(edge_width + 2 * edge_outline_width, loop_black.width);
    // The decorative strokes carry NO tooltip (their bounds-rect hover
    // would cover the whole bezier bbox); the mission tooltip rides the
    // clickable button, whose hit region is the stroke's samples - the
    // tooltip shows exactly where a click would work.
    try std.testing.expect(loop_light.tooltip == null);
    // The button's hit_curve carries the drawn arrow's geometry at the
    // outline-inclusive width + the arrowhead flag, and its rect is the
    // drawn arrow's bbox (curveBounds) - the tooltip anchors to the FULL
    // arrow, not a corner on the start point.
    const loop_button = elements.items[try findEdgeButton(elements.items, 0)].button;
    try std.testing.expectEqualStrings("Loop", loop_button.tooltip.?.header.?[0].text);
    try std.testing.expectEqual(loop_geometry.start, loop_button.hit_curve.?.start);
    try std.testing.expectEqual(loop_geometry.control_start, loop_button.hit_curve.?.control_start);
    try std.testing.expectEqual(loop_geometry.control_end, loop_button.hit_curve.?.control_end);
    try std.testing.expectEqual(loop_geometry.end, loop_button.hit_curve.?.end);
    try std.testing.expectEqual(edge_width + 2 * edge_outline_width, loop_button.hit_curve.?.width);
    try std.testing.expect(loop_button.hit_curve.?.arrowhead);
    const loop_bounds = ui_element.curveBounds(loop_button.hit_curve.?);
    try std.testing.expectEqual(loop_bounds, Rectangle{
        .x = loop_button.screen_position.x,
        .y = loop_button.screen_position.y,
        .width = loop_button.width,
        .height = loop_button.height,
    });

    // Edge 1: the straight edge a -> b - solid, lit (its start hub 'a'
    // is the start hub).
    const straight_geometry = fixtureEdgeGeometry(campaign, 1);
    const straight_light = elements.items[try findLightCurve(elements.items, straight_geometry)].curve;
    try std.testing.expect(!straight_light.dashed);
    try std.testing.expectEqual(@as(u8, 255), straight_light.alpha);
    const straight_button = elements.items[try findEdgeButton(elements.items, 1)].button;
    try std.testing.expect(straight_button.screen_position.x <= straight_light.start.x);

    // Edge 2: the dangling stub from b (direction 180 = south) - dashed,
    // lit ('b' is in the discovered set; the dimming case is asserted in
    // the dedicated test below).
    const stub_geometry = fixtureEdgeGeometry(campaign, 2);
    const stub_light = elements.items[try findLightCurve(elements.items, stub_geometry)].curve;
    try std.testing.expect(stub_light.dashed);
    try std.testing.expect(stub_light.arrowhead);
    try std.testing.expectEqual(@as(u8, 255), stub_light.alpha);
    _ = try findEdgeButton(elements.items, 2);
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
        test_button_color,
    );

    // Beta's icon dims (found by tooltip name, not index).
    try std.testing.expectEqual(
        dimmed_alpha,
        elements.items[try findHubIcon(elements.items, "Beta")].image.alpha,
    );
    // The a -> b edge (start hub 'a' is the start hub) stays lit; the
    // stub from b ('b' undiscovered) dims - both found by geometry.
    try std.testing.expectEqual(
        @as(u8, 255),
        elements.items[try findLightCurve(elements.items, fixtureEdgeGeometry(campaign, 1))].curve.alpha,
    );
    try std.testing.expectEqual(
        dimmed_alpha,
        elements.items[try findLightCurve(elements.items, fixtureEdgeGeometry(campaign, 2))].curve.alpha,
    );
}
