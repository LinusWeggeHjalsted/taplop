//! The hub editor's UI surface (the slice-4 drill-in - DESIGN → Campaigns
//! & the Campaign Editor → The hub editor surface): the level-editor
//! mirror over one hub's grid. This file owns the always-present
//! structural UI (the top bar's return button; the tool palette,
//! inspector, and metadata sidebar land with the editing slices, each
//! mirroring its src/ui/ sibling of the mission editor). The world scene
//! (tiles + spawn + NPCs + exit markers + decorations over the hub grid)
//! lives in view.zig with the other world drawable builders.
//! See DESIGN → Campaigns & the Campaign Editor → The hub editor surface.

const std = @import("std");
const types = @import("../types.zig");
const ui_element = @import("element.zig");
const editor_shell = @import("editor_shell.zig");
const emit = @import("emit.zig");
const ui_tooltip = @import("tooltip.zig");

const UiElementList = ui_element.UiElementList;
const Rectangle = types.Rectangle;
const Color = types.Color;
const spanRow = ui_tooltip.spanRow;
const text = ui_element.text;
const Row = ui_element.Row;

/// The hub editor's top-right primary action: the world-map RETURN button
/// (back to the campaign map - the drill-in's exit; navigation is
/// side-effect-free, the settled no-autosave rule). The mission editor's
/// `buildEditorPrimaryActions` icon-button class at its cell exactly
/// (flush against the right screen edge); the icon is placeholder art
/// until an asset lands (the icon_playtest/validate precedent - the art
/// report carries it automatically). Slice 5's mission-editor
/// world-map button (the campaign-context return) is the same button
/// concept and will reuse this builder's shape.
pub fn buildHubEditorTopBar(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    active_theme: types.ActiveColorTheme,
) !void {
    const p = active_theme.player_gradient.colors;
    // Match the top-bar options/undo buttons: background = gradient[5],
    // icon = gradient[1] (the editor primary-actions treatment).
    const c_btn_bg = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const c_btn_icon = p[@min(@as(u32, 1), types.gradient_color_count - 1)];

    const return_cell: Rectangle = .{
        .x = types.reference_width - ui_element.top_bar_slot_size,
        .y = 0,
        .width = ui_element.top_bar_slot_size,
        .height = ui_element.top_bar_slot_size,
    };

    try emit.emitIconButton(
        elements,
        allocator,
        return_cell,
        emit.small_button_background_sprite_id,
        "ui/icon_world_map",
        .close_hub_editor,
        .{ .header = try spanRow(allocator, text("Return to the campaign map")) },
        c_btn_bg,
        c_btn_icon,
        false,
        null,
    );
}

/// The hub editor's tool palette (the mission editor's
/// `buildEditorBottomBar` mirror - DESIGN → The hub editor surface): the
/// FIXED pair (Select + Tile) at the bar's left edge, flush against the
/// screen's left side (left-anchored so the fixed tools stay put as the
/// groups land - the mission editor's convention). The palette groups
/// (NPCs / Missions / Decorations) join with their slices: NPCs + the
/// per-mission Missions group at 4-4 (membership live from the campaign
/// graph), the Decorations group + pickers at 4-5.
pub fn buildHubEditorBottomBar(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    screen: Rectangle,
    active_tool: types.HubEditorToolId,
    active_theme: types.ActiveColorTheme,
) !void {
    const p = active_theme.player_gradient.colors;
    const button_color = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const world = active_theme.world_gradient.colors;

    const content_width = 2 * ui_element.slot_size + ui_element.ui_gap;
    const bar = screen.placeBottomLeft(content_width, ui_element.bottom_bar_height, 0);
    var row = Row.init(bar.position(), ui_element.bottom_bar_height, ui_element.ui_gap);

    // Select: the clickable-tile highlight's look (the mission editor's
    // fixed-tool graphic - an inset square outline in the outline class,
    // so it animates with the world highlight).
    {
        const cell = row.next(ui_element.slot_size);
        try elements.append(allocator, .{ .button = .{
            .sprite_id = emit.button_background_sprite_id,
            .screen_position = cell.position(),
            .width = cell.width,
            .height = cell.height,
            .action = .select_hub_tool,
            .payload = .{ .hub_tool = .select },
            .color = button_color,
            .highlighted = active_tool == .select,
            .tooltip = .{ .header = try spanRow(allocator, text("Select")) },
        } });
        const fitted = editor_shell.scaleToFit(cell, tool_graphic_tile_size, tool_graphic_tile_size);
        const inset = @divTrunc(fitted.width, ui_element.tile_highlight_inset_divisor);
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = fitted.x + inset, .y = fitted.y + inset },
            .width = fitted.width - 2 * inset,
            .height = fitted.height - 2 * inset,
            .color = active_theme.lightest,
            .filled = false,
            .line_width = types.outline_thickness,
            .blocks_input = false,
        } });
    }

    // Tile paint: the tile art at half scale (the busy-art convention).
    {
        const cell = row.next(ui_element.slot_size);
        try elements.append(allocator, .{ .button = .{
            .sprite_id = emit.button_background_sprite_id,
            .screen_position = cell.position(),
            .width = cell.width,
            .height = cell.height,
            .action = .select_hub_tool,
            .payload = .{ .hub_tool = .tile },
            .color = button_color,
            .highlighted = active_tool == .tile,
            .tooltip = .{ .header = try spanRow(allocator, text("Tile paint")) },
        } });
        const fitted = editor_shell.scaleToFit(cell, tool_graphic_tile_size, tool_graphic_tile_size);
        const half_width = @divTrunc(fitted.width, 2);
        const half_height = @divTrunc(fitted.height, 2);
        try elements.append(allocator, .{ .image = .{
            .sprite_id = "world/tile",
            .screen_position = .{
                .x = fitted.x + @divTrunc(fitted.width - half_width, 2),
                .y = fitted.y + @divTrunc(fitted.height - half_height, 2),
            },
            .width = half_width,
            .height = half_height,
            .color = world[@min(@as(u32, 1), types.gradient_color_count - 1)],
            .blocks_input = false,
        } });
    }
}

/// The tool graphic's fitted tile size (the mission editor's fixed-tool
/// convention - the tile art is authored at 256px).
const tool_graphic_tile_size: i32 = 256;

// ============================================================
// Structure tests - predicate scans (the campaign editor's test
// conventions).
// ============================================================

test "buildHubEditorBottomBar: the fixed pair - Select + Tile cells, the active tool highlighted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    const test_theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = @splat(black) },
        .enemy_gradient = .{ .colors = @splat(black) },
        .player_gradient = .{ .colors = @splat(black) },
    };

    // The tile tool active: Tile highlighted, Select not.
    var elements: UiElementList = .empty;
    defer elements.deinit(arena.allocator());
    try buildHubEditorBottomBar(&elements, arena.allocator(), ui_element.screenRect(), .tile, test_theme);

    var select_cell: ?ui_element.Button = null;
    var tile_cell: ?ui_element.Button = null;
    for (elements.items) |element| switch (element) {
        .button => |button| switch (button.payload.?.hub_tool) {
            .select => select_cell = button,
            .tile => tile_cell = button,
        },
        else => {},
    };
    try std.testing.expect(select_cell != null);
    try std.testing.expect(tile_cell != null);
    try std.testing.expectEqual(@as(i32, 0), select_cell.?.screen_position.x);
    try std.testing.expect(tile_cell.?.highlighted);
    try std.testing.expect(!select_cell.?.highlighted);

    // The select tool active: the mirror.
    var select_elements: UiElementList = .empty;
    defer select_elements.deinit(arena.allocator());
    try buildHubEditorBottomBar(&select_elements, arena.allocator(), ui_element.screenRect(), .select, test_theme);
    for (select_elements.items) |element| switch (element) {
        .button => |button| switch (button.payload.?.hub_tool) {
            .select => try std.testing.expect(button.highlighted),
            .tile => try std.testing.expect(!button.highlighted),
        },
        else => {},
    };
}

test "buildHubEditorTopBar: one world-map return button flush top-right" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    const test_theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = @splat(black) },
        .enemy_gradient = .{ .colors = @splat(black) },
        .player_gradient = .{ .colors = @splat(black) },
    };

    var elements: UiElementList = .empty;
    defer elements.deinit(arena.allocator());
    try buildHubEditorTopBar(&elements, arena.allocator(), test_theme);

    var found: ?ui_element.Button = null;
    var button_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| {
            button_count += 1;
            if (button.action == .close_hub_editor) found = button;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), button_count);
    const button = found orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(types.reference_width - ui_element.top_bar_slot_size, button.screen_position.x);
    try std.testing.expectEqual(@as(i32, 0), button.screen_position.y);
    try std.testing.expectEqual(ui_element.top_bar_slot_size, button.width);
    try std.testing.expect(button.tooltip != null);
}
