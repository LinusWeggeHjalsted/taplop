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
const no_tint_color: Color = .{ .r = 255, .g = 255, .b = 255 };

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
    font_metrics: ui_element.FontMetrics,
    screen: Rectangle,
    campaign_editor: types.CampaignEditor,
    hub_editor: types.HubEditor,
    active_theme: types.ActiveColorTheme,
) !void {
    _ = font_metrics; // the group cells measure their labels from the
    // mission entries directly (the names render at the header font); the
    // metrics ride along for the 4-5 decoration group's cell sizing.
    const p = active_theme.player_gradient.colors;
    const button_color = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const world = active_theme.world_gradient.colors;

    // The Missions group's live membership: the outgoing missions (start
    // == this hub), in authored order - the one live coupling between
    // the two surfaces (re-wiring on the map changes the palette).
    var outgoing_mission_count: usize = 0;
    for (campaign_editor.missions) |mission| {
        if (mission.start != null and mission.start.? == hub_editor.hub) outgoing_mission_count += 1;
    }

    const header_font = editor_shell.editor_group_header_font_size;
    const npc_group_width = header_font * 2 + 2 * ui_element.slot_size + 3 * ui_element.ui_gap;
    const missions_group_width = header_font * 2 + 2 * ui_element.ui_gap +
        @as(i32, @intCast(outgoing_mission_count)) * (ui_element.slot_size + ui_element.ui_gap);
    const content_width = 2 * ui_element.slot_size + 3 * ui_element.ui_gap +
        npc_group_width + missions_group_width;
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
            .highlighted = hub_editor.active_tool == .select,
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
            .highlighted = hub_editor.active_tool == .tile,
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

    // The NPCs group: two FIXED tools (gear_upgrader, dream_guide - the
    // NpcType enum's members; the sprites derive from the types). A plain
    // header label + the cells (no collapse toggle - the group is fixed
    // and small; the mission editor's header-toggle convention can ride
    // later if the palette grows).
    {
        row.advance(ui_element.ui_gap);
        const header_width = header_font * 2 + 2 * ui_element.ui_gap;
        try elements.append(allocator, .{ .text_label = .{
            .text = "NPCs",
            .screen_position = .{
                .x = bar.x + row.cursor_x,
                .y = screen.bottom() - editor_shell.editor_header_strip_height +
                    @divTrunc(editor_shell.editor_header_strip_height - header_font, 2),
            },
            .font_size = header_font,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });
        row.advance(header_width);
        inline for (@typeInfo(types.NpcType).@"enum".field_names) |field_name| {
            const npc_type: types.NpcType = @field(types.NpcType, field_name);
            const cell = row.next(ui_element.slot_size);
            try elements.append(allocator, .{ .button = .{
                .sprite_id = emit.button_background_sprite_id,
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .action = .select_hub_tool,
                .payload = .{ .hub_tool = .{ .npc = npc_type } },
                .color = button_color,
                .highlighted = std.meta.eql(hub_editor.active_tool, .{ .npc = npc_type }),
                .tooltip = .{ .header = try spanRow(allocator, text("Place a " ++ field_name ++ " NPC")) },
            } });
            const fitted = editor_shell.scaleToFit(cell, tool_graphic_tile_size, 2 * tool_graphic_tile_size);
            try elements.append(allocator, .{ .image = .{
                .sprite_id = npc_type.spriteId(),
                .screen_position = .{
                    .x = fitted.x + @divTrunc(fitted.width - @divTrunc(fitted.width, 2), 2),
                    .y = fitted.y + @divTrunc(fitted.height - @divTrunc(fitted.height, 2), 2),
                },
                .width = @divTrunc(fitted.width, 2),
                .height = @divTrunc(fitted.height, 2),
                .color = no_tint_color,
                .blocks_input = false,
            } });
        }
    }

    // The Missions group: ONE tool per outgoing mission (live membership),
    // each cell placing/moving that mission's exit marker. The flag
    // graphic (the mission-start banner's world sprite) + the mission's
    // name across the cell bottom.
    {
        row.advance(ui_element.ui_gap);
        const header_width = header_font * 2 + 2 * ui_element.ui_gap;
        try elements.append(allocator, .{ .text_label = .{
            .text = "Missions",
            .screen_position = .{
                .x = bar.x + row.cursor_x,
                .y = screen.bottom() - editor_shell.editor_header_strip_height +
                    @divTrunc(editor_shell.editor_header_strip_height - header_font, 2),
            },
            .font_size = header_font,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });
        row.advance(header_width);
        for (campaign_editor.missions) |mission| {
            if (mission.start == null or mission.start.? != hub_editor.hub) continue;
            const cell = row.next(ui_element.slot_size);
            try elements.append(allocator, .{ .button = .{
                .sprite_id = emit.button_background_sprite_id,
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .action = .select_hub_tool,
                .payload = .{ .hub_tool = .{ .mission = mission.handle } },
                .color = button_color,
                .highlighted = std.meta.eql(hub_editor.active_tool, .{ .mission = mission.handle }),
                .tooltip = .{ .header = try spanRow(allocator, text("Place the exit marker for this mission")) },
            } });
            const fitted = editor_shell.scaleToFit(cell, tool_graphic_tile_size, 2 * tool_graphic_tile_size);
            try elements.append(allocator, .{ .image = .{
                .sprite_id = "world/flag",
                .screen_position = .{
                    .x = fitted.x + @divTrunc(fitted.width - @divTrunc(fitted.width, 2), 2),
                    .y = fitted.y,
                },
                .width = @divTrunc(fitted.width, 2),
                .height = fitted.height,
                .color = no_tint_color,
                .blocks_input = false,
            } });
            const name = if (mission.name.len > 0) mission.name else "Unsaved mission";
            const name_font = editor_shell.editor_group_header_font_size;
            try elements.append(allocator, .{ .text_label = .{
                .text = name,
                .screen_position = .{
                    .x = cell.x + ui_element.ui_gap,
                    .y = cell.y + cell.height - name_font - ui_element.ui_gap,
                },
                .font_size = name_font,
                .color = active_theme.lightest,
                .blocks_input = false,
            } });
        }
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

    // The tile tool active: Tile highlighted, Select not. The campaign
    // fixture carries one outgoing mission (the Missions group's live
    // membership).
    const test_metrics = ui_element.FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
    const campaign_editor = types.CampaignEditor{
        .start_hub = 0,
        .hubs = &.{.{ .handle = 0, .name = "Alpha", .position = .{ .x = 0, .y = 0 } }},
        .missions = &.{.{ .handle = 5, .name = "One", .start = 0, .destination = 0 }},
        .next_handle = 6,
    };
    var elements: UiElementList = .empty;
    defer elements.deinit(arena.allocator());
    try buildHubEditorBottomBar(&elements, arena.allocator(), test_metrics, ui_element.screenRect(), campaign_editor, .{ .hub = 0, .active_tool = .tile }, test_theme);

    var select_cell: ?ui_element.Button = null;
    var tile_cell: ?ui_element.Button = null;
    var npc_cells: usize = 0;
    var mission_cells: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| switch (button.payload.?.hub_tool) {
            .select => select_cell = button,
            .tile => tile_cell = button,
            .npc => npc_cells += 1,
            .mission => mission_cells += 1,
        },
        else => {},
    };
    // The groups: two fixed NPC cells + one per outgoing mission.
    try std.testing.expectEqual(@as(usize, 2), npc_cells);
    try std.testing.expectEqual(@as(usize, 1), mission_cells);
    try std.testing.expect(select_cell != null);
    try std.testing.expect(tile_cell != null);
    try std.testing.expectEqual(@as(i32, 0), select_cell.?.screen_position.x);
    try std.testing.expect(tile_cell.?.highlighted);
    try std.testing.expect(!select_cell.?.highlighted);

    // The select tool active: the mirror.
    var select_elements: UiElementList = .empty;
    defer select_elements.deinit(arena.allocator());
    try buildHubEditorBottomBar(&select_elements, arena.allocator(), test_metrics, ui_element.screenRect(), campaign_editor, .{ .hub = 0, .active_tool = .select }, test_theme);
    for (select_elements.items) |element| switch (element) {
        .button => |button| switch (button.payload.?.hub_tool) {
            .select => try std.testing.expect(button.highlighted),
            .tile => try std.testing.expect(!button.highlighted),
            else => {},
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
