//! The campaign editor's map view - the static slice-3b render (the tool
//! palette / inspector / metadata sidebar land with 3c). Renders the
//! AUTHORED graph (CampaignEditor) through the SHARED campaign geometry
//! ("one data model, two renderers" - the world-map mirror derives the
//! same shapes via campaign_geometry): all hubs LIT (no discovery dimming
//! - the editor sees everything), the background native-size centered on
//! the origin, and edges with ORPHAN GHOSTING (a mission missing an end
//! renders from its frozen ghost position at reduced alpha - selectable
//! targets are 3c/3d). Pure over its inputs; no file access.
//! See DESIGN → Campaigns & the Campaign Editor → The campaign editor
//! surface + Edge geometry.

const std = @import("std");
const types = @import("../types.zig");
const ui_element = @import("element.zig");
const campaign_geometry = @import("campaign_geometry.zig");
const ui_tooltip = @import("tooltip.zig");
const file_source = @import("../file_source.zig");

const UiElement = ui_element.UiElement;
const UiElementList = ui_element.UiElementList;
const Rectangle = types.Rectangle;
const Vector2 = types.Vector2;
const ScreenPosition = types.ScreenPosition;
const text = ui_element.text;
const spanRow = ui_tooltip.spanRow;

const mapToScreen = campaign_geometry.mapToScreen;
const deriveEdgeGeometry = campaign_geometry.deriveEdgeGeometry;
const EdgeEndpoint = campaign_geometry.EdgeEndpoint;
const ParallelSpread = campaign_geometry.ParallelSpread;
const edge_width = campaign_geometry.edge_width;
const edge_outline_width = campaign_geometry.edge_outline_width;
const black = campaign_geometry.black;
const hub_icon_size = campaign_geometry.hub_icon_size;
const hub_icon_sprite_id = campaign_geometry.hub_icon_sprite_id;

/// The ghosted (orphaned) light-stroke alpha - the visual class for a
/// mission missing an end (the world map's dimmed class is the
/// discovery mirror; this is the EDITOR's not-fully-wired cue, and the
/// values may diverge deliberately).
const orphaned_alpha: u8 = 100;

/// The mission's resolved END: the live hub's map position when the end
/// is wired, else the frozen ghost position (an orphan renders in
/// place); null when the end is neither (the dangling case). The origin
/// fallback never fires from loaded content (a missing ghost is warned +
/// defaulted at load); it covers only an in-editor mission whose hub was
/// just deleted... no - the deletion event always stores the ghost. It is
/// defensive: a hand-constructed state with a null end + null ghost
/// renders at the origin.
const MissionEnd = union(enum) {
    hub: Vector2,
    missing: void,
};

fn missionEnd(editor: types.CampaignEditor, hub_handle: ?u32, ghost_position: ?Vector2) MissionEnd {
    if (hub_handle) |handle| {
        for (editor.hubs) |hub| {
            if (hub.handle == handle) return .{ .hub = hub.position };
        }
    }
    if (ghost_position) |position| return .{ .hub = position };
    return .missing;
}

/// The mission's EFFECTIVE direction: the authored bearing, else the
/// auto-spread default - unauthored missions sharing a start anchor
/// (hub handle, or the shared ghost position when the start is gone)
/// spread evenly among THEMSELVES over the full circle (the settled
/// rule; authored ones sit where placed, no gap bookkeeping).
fn effectiveDirection(editor: types.CampaignEditor, mission: types.CampaignMissionEdit) u32 {
    if (mission.direction) |authored| return authored;
    const anchor = startAnchor(mission);
    var unauthored_index: i32 = 0;
    var unauthored_count: i32 = 0;
    for (editor.missions) |other| {
        if (!startAnchorEqual(startAnchor(other), anchor)) continue;
        if (other.direction != null) continue;
        unauthored_count += 1;
        if (other.handle <= mission.handle) unauthored_index += 1;
    }
    if (unauthored_count == 0) return 0;
    const total: u32 = @intCast(unauthored_count);
    // 0-based among the unauthored (the runtime's 360 * index / count
    // convention - four unauthored loops land at 0/90/180/270).
    const index: u32 = @intCast(unauthored_index - 1);
    return 360 * index / total;
}

/// The spread key for unauthored directions: the start hub handle, or
/// the ghost start position when orphaned (two orphans frozen at the
/// same spot spread apart).
const StartAnchor = union(enum) {
    hub: u32,
    ghost: Vector2,
    none: void,
};

fn startAnchor(mission: types.CampaignMissionEdit) StartAnchor {
    if (mission.start) |handle| return .{ .hub = handle };
    if (mission.orphan_start_position) |position| return .{ .ghost = position };
    return .none;
}

fn startAnchorEqual(a: StartAnchor, b: StartAnchor) bool {
    switch (a) {
        .hub => |handle| return b == .hub and b.hub == handle,
        .ghost => |position| return b == .ghost and vectorEqual(b.ghost, position),
        .none => return b == .none,
    }
}

fn vectorEqual(a: Vector2, b: Vector2) bool {
    return a.x == b.x and a.y == b.y;
}

/// The mission's spread among its same-pair straight siblings: pair
/// identity is the resolved END POSITIONS (both live-or-ghost, i.e. the
/// straight class) - handle pairs and shared ghost pairs group the same
/// way positions do. 1-based by handle among the count.
fn parallelSpread(editor: types.CampaignEditor, mission: types.CampaignMissionEdit) ParallelSpread {
    const from = missionEnd(editor, mission.start, mission.orphan_start_position);
    const to = missionEnd(editor, mission.destination, mission.orphan_destination_position);
    if (from != .hub or to != .hub) return .{ .index = 1, .count = 1 };
    var index: i32 = 0;
    var count: i32 = 0;
    for (editor.missions) |other| {
        const other_from = missionEnd(editor, other.start, other.orphan_start_position);
        const other_to = missionEnd(editor, other.destination, other.orphan_destination_position);
        if (other_from != .hub or other_to != .hub) continue;
        if (!vectorEqual(other_from.hub, from.hub) or !vectorEqual(other_to.hub, to.hub)) continue;
        if (other.handle <= mission.handle) index += 1;
        count += 1;
    }
    return .{ .index = index, .count = count };
}

/// Derive one mission's on-screen shape from the authored graph - the
/// editor-side resolution feeding the SHARED geometry derivation (the
/// world-map mirror resolves from the runtime edge table instead; the
/// derivation itself is one implementation). The endpoint classes:
/// both ends the same LIVE hub = the self-loop teardrop; both ends
/// resolved (live or ghost) = the straight edge; the destination end
/// missing = the dangling stub.
fn missionGeometry(editor: types.CampaignEditor, mission: types.CampaignMissionEdit) campaign_geometry.EdgeGeometry {
    const from = missionEnd(editor, mission.start, mission.orphan_start_position);
    const to = missionEnd(editor, mission.destination, mission.orphan_destination_position);

    if (mission.start != null and mission.destination != null and
        mission.start.? == mission.destination.? and
        from == .hub)
    {
        return deriveEdgeGeometry(from.hub, .self_loop, @intCast(effectiveDirection(editor, mission)), .{ .index = 1, .count = 1 });
    }
    if (to == .hub) {
        const from_position = if (from == .hub) from.hub else Vector2{ .x = 0, .y = 0 };
        return deriveEdgeGeometry(from_position, .{ .hub = to.hub }, 0, parallelSpread(editor, mission));
    }
    const from_position = if (from == .hub) from.hub else Vector2{ .x = 0, .y = 0 };
    return deriveEdgeGeometry(from_position, .dangling, @intCast(effectiveDirection(editor, mission)), .{ .index = 1, .count = 1 });
}

/// Build the campaign editor's static view (see the file header).
pub fn buildCampaignEditorView(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    screen: Rectangle,
    editor: types.CampaignEditor,
    active_theme: types.ActiveColorTheme,
) !void {
    // The surface: a full-screen dark fill that blocks input.
    try elements.append(allocator, .{ .solid_rect = .{
        .screen_position = screen.position(),
        .width = screen.width,
        .height = screen.height,
        .color = active_theme.darkest,
        .blocks_input = true,
    } });

    // The background, native size, centered on the origin (stored
    // positions never depend on the art's dimensions - see DESIGN → The
    // map coordinate model). The stem mints into the content-addressed
    // sprite id by pure string math - the load-side minting rule.
    if (editor.background_stem.len > 0) {
        if (editor.background_dims) |dims| {
            const sprite_id = file_source.customStemForContentPath(
                editor.campaign_dir,
                editor.background_stem,
                allocator,
            );
            const center = mapToScreen(.{ .x = 0, .y = 0 });
            try elements.append(allocator, .{ .image = .{
                .sprite_id = sprite_id,
                .screen_position = .{
                    .x = center.x - @divTrunc(dims.x, 2),
                    .y = center.y - @divTrunc(dims.y, 2),
                },
                .width = dims.x,
                .height = dims.y,
                .blocks_input = false,
            } });
        }
    }

    // Hubs: an icon centered on each position, ALL LIT (the editor sees
    // everything - no discovery dimming); the name rides the tooltip.
    for (editor.hubs) |hub| {
        const center = mapToScreen(hub.position);
        try elements.append(allocator, .{ .image = .{
            .sprite_id = hub_icon_sprite_id,
            .screen_position = .{
                .x = center.x - @divTrunc(hub_icon_size, 2),
                .y = center.y - @divTrunc(hub_icon_size, 2),
            },
            .width = hub_icon_size,
            .height = hub_icon_size,
            .blocks_input = false,
            .tooltip = .{ .header = try spanRow(allocator, text(hub.name)) },
        } });
    }

    // Edges: one stroke pair per mission (black outline under the
    // lightest stroke), derived through the shared geometry. An orphaned
    // mission (either end missing) renders GHOSTED (reduced light-stroke
    // alpha) from its frozen ghost positions. No click targets yet -
    // selectability is 3c/3d.
    const lightest = active_theme.lightest;
    for (editor.missions) |mission| {
        const geometry = missionGeometry(editor, mission);
        const orphaned = mission.start == null or mission.destination == null;

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
            .alpha = if (orphaned) orphaned_alpha else 255,
            .dashed = geometry.dashed,
            .arrowhead = true,
            .blocks_input = false,
        } });
    }
}

// ============================================================
// Structure tests - the predicate-scan conventions (see world_map.zig's
// test header): elements found by sprite id + tooltip name or full drawn
// geometry, never flat-list index. The geometry contracts themselves
// live in campaign_geometry.zig's tests; these assert the editor-side
// RESOLUTION (endpoint classes, ghost fallbacks, auto-spread, orphan
// ghosting) + emission.
// ============================================================

const test_theme = types.ActiveColorTheme{
    .lightest = .{ .r = 10, .g = 20, .b = 30 },
    .darkest = .{ .r = 1, .g = 2, .b = 3 },
    .world_gradient = undefined,
    .enemy_gradient = undefined,
    .player_gradient = undefined,
};

fn screenPositionEqual(a: ScreenPosition, b: ScreenPosition) bool {
    return a.x == b.x and a.y == b.y;
}

fn curveGeometryMatches(curve: ui_element.Curve, geometry: campaign_geometry.EdgeGeometry) bool {
    return screenPositionEqual(curve.start, geometry.start) and
        screenPositionEqual(curve.control_start, geometry.control_start) and
        screenPositionEqual(curve.control_end, geometry.control_end) and
        screenPositionEqual(curve.end, geometry.end) and
        curve.dashed == geometry.dashed;
}

fn findLightCurve(
    elements: []const UiElement,
    geometry: campaign_geometry.EdgeGeometry,
) !usize {
    for (elements, 0..) |element, index| {
        if (element != .curve) continue;
        if (!colorEqual(element.curve.color, test_theme.lightest)) continue;
        if (curveGeometryMatches(element.curve, geometry)) return index;
    }
    std.debug.print("predicate scan found no lightest stroke for the geometry\n", .{});
    return error.TestUnexpectedResult;
}

fn colorEqual(a: types.Color, b: types.Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}

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

fn buildFixtureEditor() types.CampaignEditor {
    return .{
        .campaign_name = "Fixture",
        .campaign_dir = "campaigns/fixture",
        .background_stem = "map",
        .background_dims = .{ .x = 1000, .y = 600 },
        .start_hub = 0,
        .hubs = &.{
            .{ .handle = 0, .uuid = "a", .name = "Alpha", .position = .{ .x = -200, .y = 0 } },
            .{ .handle = 1, .uuid = "b", .name = "Beta", .position = .{ .x = 400, .y = 300 } },
        },
        .missions = &.{
            // A self-loop on Alpha, authored north.
            .{ .handle = 2, .uuid = "m1", .name = "Loop", .start = 0, .destination = 0, .direction = 0 },
            // A straight edge Alpha -> Beta, unauthored direction.
            .{ .handle = 3, .uuid = "m2", .name = "Cross", .start = 0, .destination = 1 },
            // An end-orphan: starts at Alpha, no destination (the dangling
            // stub; unauthored direction - auto-spread with m2).
            .{ .handle = 4, .uuid = "m3", .name = "Beyond", .start = 0 },
            // A start-orphan: destination Beta live, the start frozen at its
            // ghost position (where the deleted hub was).
            .{ .handle = 5, .uuid = "m4", .name = "Salvage", .destination = 1, .orphan_start_position = .{ .x = -600, .y = -300 } },
            // Fully orphaned: both ends frozen - the complete ghost edge.
            .{ .handle = 6, .uuid = "m5", .name = "Ghost", .orphan_start_position = .{ .x = -600, .y = -300 }, .orphan_destination_position = .{ .x = -600, .y = 300 } },
        },
        .next_handle = 7,
    };
}

test "buildCampaignEditorView: surface, background, hubs, and the edge classes incl. orphans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var elements: UiElementList = .empty;
    defer elements.deinit(arena.allocator());

    const editor = buildFixtureEditor();
    try buildCampaignEditorView(&elements, arena.allocator(), ui_element.screenRect(), editor, test_theme);

    // Derived total: 1 surface + 1 background + 1 icon per hub + 2 curves
    // per mission.
    const expected_total = 1 + 1 + editor.hubs.len + 2 * editor.missions.len;
    try std.testing.expectEqual(expected_total, elements.items.len);

    // The surface blocks input (the view's only solid_rect).
    var surface_index: ?usize = null;
    for (elements.items, 0..) |element, index| {
        if (element == .solid_rect) surface_index = index;
    }
    try std.testing.expect(elements.items[surface_index.?].solid_rect.blocks_input);

    // The background: the stem minted into the content-addressed id,
    // native size, centered on the origin.
    var background_index: ?usize = null;
    for (elements.items, 0..) |element, index| {
        if (element == .image and std.mem.eql(u8, element.image.sprite_id, "custom/campaigns/fixture/map")) {
            background_index = index;
        }
    }
    const background = elements.items[background_index.?].image;
    try std.testing.expectEqual(@as(i32, 1000), background.width);
    try std.testing.expectEqual(@as(i32, 600), background.height);
    try std.testing.expectEqual(
        @divTrunc(types.reference_width, 2) - 500,
        background.screen_position.x,
    );

    // Hub icons: centered on mapToScreen(position), all lit (the editor
    // sees everything).
    const alpha_icon = elements.items[try findHubIcon(elements.items, "Alpha")].image;
    try std.testing.expectEqual(
        mapToScreen(.{ .x = -200, .y = 0 }).x - @divTrunc(hub_icon_size, 2),
        alpha_icon.screen_position.x,
    );
    try std.testing.expectEqual(@as(u8, 255), alpha_icon.alpha);

    // The self-loop: the drawn geometry IS the shared derivation for the
    // authored class + bearing (one implementation).
    const loop_geometry = campaign_geometry.deriveEdgeGeometry(
        .{ .x = -200, .y = 0 },
        .self_loop,
        0,
        .{ .index = 1, .count = 1 },
    );
    const loop_light = elements.items[try findLightCurve(elements.items, loop_geometry)].curve;
    try std.testing.expectEqual(@as(u8, 255), loop_light.alpha);
    try std.testing.expect(!loop_light.dashed);

    // The straight edge Alpha -> Beta.
    const straight_geometry = campaign_geometry.deriveEdgeGeometry(
        .{ .x = -200, .y = 0 },
        .{ .hub = .{ .x = 400, .y = 300 } },
        0,
        .{ .index = 1, .count = 1 },
    );
    const straight_light = elements.items[try findLightCurve(elements.items, straight_geometry)].curve;
    try std.testing.expectEqual(@as(u8, 255), straight_light.alpha);

    // The end-orphan: a dashed stub from Alpha, GHOSTED (reduced alpha).
    // Unauthored + sharing Alpha with m2: auto-spread among themselves -
    // m2 index 1, m3 index 2 over count 2 -> 0 and 180 degrees.
    try std.testing.expectEqual(@as(u32, 0), effectiveDirection(editor, editor.missions[1]));
    try std.testing.expectEqual(@as(u32, 180), effectiveDirection(editor, editor.missions[2]));
    const stub_geometry = campaign_geometry.deriveEdgeGeometry(
        .{ .x = -200, .y = 0 },
        .dangling,
        180,
        .{ .index = 1, .count = 1 },
    );
    const stub_light = elements.items[try findLightCurve(elements.items, stub_geometry)].curve;
    try std.testing.expect(stub_light.dashed);
    try std.testing.expectEqual(orphaned_alpha, stub_light.alpha);

    // The start-orphan: the complete edge from the frozen ghost start
    // position toward the LIVE Beta - straight, ghosted.
    const salvage_geometry = campaign_geometry.deriveEdgeGeometry(
        .{ .x = -600, .y = -300 },
        .{ .hub = .{ .x = 400, .y = 300 } },
        0,
        .{ .index = 1, .count = 1 },
    );
    const salvage_light = elements.items[try findLightCurve(elements.items, salvage_geometry)].curve;
    try std.testing.expectEqual(orphaned_alpha, salvage_light.alpha);

    // The fully-orphaned mission: the complete edge between both ghost
    // positions, ghosted.
    const ghost_geometry = campaign_geometry.deriveEdgeGeometry(
        .{ .x = -600, .y = -300 },
        .{ .hub = .{ .x = -600, .y = 300 } },
        0,
        .{ .index = 1, .count = 1 },
    );
    const ghost_light = elements.items[try findLightCurve(elements.items, ghost_geometry)].curve;
    try std.testing.expectEqual(orphaned_alpha, ghost_light.alpha);
}

test "effectiveDirection: authored bearings sit put; unauthored spread among themselves" {
    const editor = buildFixtureEditor();

    // The authored self-loop keeps its bearing.
    try std.testing.expectEqual(@as(u32, 0), effectiveDirection(editor, editor.missions[0]));

    // The two unauthored missions sharing the Alpha anchor (m2, m3) split
    // the circle: 0 and 180 - the AUTHORED self-loop on the same hub does
    // not consume a slot (spread among themselves, the settled rule).
    try std.testing.expectEqual(@as(u32, 0), effectiveDirection(editor, editor.missions[1]));
    try std.testing.expectEqual(@as(u32, 180), effectiveDirection(editor, editor.missions[2]));

    // The start-orphan anchors on its ghost position: unanchored company
    // only (the fully-orphaned mission shares the ghost start spot, but
    // it renders a full ghost edge, not a stub - direction unused; the
    // anchor grouping still holds for any future stubs frozen there).
    const ghost_editor = types.CampaignEditor{
        .hubs = &.{},
        .missions = &.{
            // Two unauthored stubs frozen at the same ghost start spot:
            // they spread between themselves (0 / 180), ignoring an
            // AUTHORED stub on the same spot.
            .{ .handle = 0, .orphan_start_position = .{ .x = -600, .y = -300 } },
            .{ .handle = 1, .orphan_start_position = .{ .x = -600, .y = -300 } },
            .{ .handle = 2, .orphan_start_position = .{ .x = -600, .y = -300 }, .direction = 90 },
        },
        .next_handle = 3,
    };
    try std.testing.expectEqual(@as(u32, 0), effectiveDirection(ghost_editor, ghost_editor.missions[0]));
    try std.testing.expectEqual(@as(u32, 180), effectiveDirection(ghost_editor, ghost_editor.missions[1]));
}
