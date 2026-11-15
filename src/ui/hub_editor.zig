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
const editor_inspector = @import("editor_inspector.zig");
const ui_state_mod = @import("state.zig");
const state = @import("../state.zig");
const emit = @import("emit.zig");
const ui_tooltip = @import("tooltip.zig");

const UiElementList = ui_element.UiElementList;
const UiElement = ui_element.UiElement;
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

/// The hub editor's tool palette - the mission editor's
/// `buildEditorBottomBar` EXACT structural mirror: the fixed pair
/// (Select + Tile) left-anchored, then three GROUPS (NPCs / Missions /
/// Decorations), each an accordion header (expanding one collapses the
/// others - the radio semantics) with its cells in a scrollable window
/// below/flush. The "+" add-new cell exists on Decorations only (the
/// other groups' membership is fixed: the NpcType enum, the campaign
/// graph's outgoing missions). The Missions group's membership is LIVE
/// from the campaign graph (the one coupling between the surfaces).
/// See DESIGN → Campaigns & the Campaign Editor → The hub editor
/// surface + Architecture → Level Editor (the palette conventions this
/// mirrors).
pub fn buildHubEditorBottomBar(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: ui_element.FontMetrics,
    screen: Rectangle,
    campaign_editor: types.CampaignEditor,
    hub_editor: types.HubEditor,
    active_theme: types.ActiveColorTheme,
    collapsed: *[3]bool,
    scroll_offsets: *[3]i32,
) !void {
    const p = active_theme.player_gradient.colors;
    const button_color = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const world = active_theme.world_gradient.colors;

    const group_labels = [_][]const u8{ "NPCs", "Missions", "Decorations" };
    // The live group sizes: the fixed NPC pair, the outgoing missions,
    // the campaign-shared decoration types.
    var outgoing_mission_count: usize = 0;
    for (campaign_editor.missions) |mission| {
        if (mission.start != null and mission.start.? == hub_editor.hub) outgoing_mission_count += 1;
    }
    const group_sizes = [3]usize{ 2, outgoing_mission_count, campaign_editor.decoration_types.len };
    // Only Decorations authors its membership - the other groups' "+"
    // would have nothing to add.
    const group_has_plus = [3]bool{ false, false, true };

    // Per-group header widths + row footprints (the mission editor's
    // math: an expanded group's footprint is its visible cells, or the
    // header + "+" extent when narrower; a collapsed group's is the
    // header + "+" extent (or just the header for plus-less groups)).
    var header_widths: [group_labels.len]i32 = undefined;
    var footprints: [group_labels.len]i32 = undefined;
    var content_width: i32 = 2 * ui_element.slot_size;
    for (group_labels, 0..) |label, group_index| {
        header_widths[group_index] =
            font_metrics.measureSpanWidth(text(label), editor_shell.editor_group_header_font_size) + 2 * ui_element.ui_gap;
        const header_extent = header_widths[group_index] +
            @as(i32, if (group_has_plus[group_index]) ui_element.ui_gap + editor_shell.editor_plus_size else 0);
        if (collapsed[group_index] or group_sizes[group_index] == 0) {
            footprints[group_index] = header_extent;
        } else {
            const visible: i32 = @intCast(@min(group_sizes[group_index], editor_shell.editor_palette_max_tools));
            const cells_width = visible * ui_element.slot_size + (visible - 1) * ui_element.ui_gap;
            footprints[group_index] = @max(cells_width, header_extent);
        }
        content_width += footprints[group_index];
    }
    content_width += (2 + group_labels.len - 1) * ui_element.ui_gap;

    // Left-anchored (the fixed tools stay put as groups expand/collapse).
    const bar = screen.placeBottomLeft(content_width, ui_element.bottom_bar_height, 0);
    var row = Row.init(bar.position(), ui_element.bottom_bar_height, ui_element.ui_gap);

    // Fixed tools (the mission editor's graphics: the select outline, the
    // half-scale tile art).
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

    // The groups (the mission editor's emission order: header toggle +
    // optional "+", then the visible cell window).
    for (group_labels, 0..) |label, group_index| {
        const size = group_sizes[group_index];
        const group_left = bar.x + row.cursor_x;
        const footprint = footprints[group_index];
        const header_y: i32 = if (collapsed[group_index])
            screen.bottom() - editor_shell.editor_header_strip_height
        else
            bar.y - ui_element.ui_gap - editor_shell.editor_header_strip_height;

        // Header: panel-backed toggle button (the accordion), left-aligned
        // with the group.
        const header_width = header_widths[group_index];
        const header_cell: Rectangle = .{
            .x = group_left,
            .y = header_y,
            .width = header_width,
            .height = editor_shell.editor_header_strip_height,
        };
        try elements.append(allocator, .{ .nine_slice_panel = .{
            .sprite_id = "ui/panel",
            .screen_position = header_cell.position(),
            .width = header_width,
            .height = editor_shell.editor_header_strip_height,
            .color = button_color,
        } });
        try elements.append(allocator, .{ .button = .{
            .sprite_id = null,
            .screen_position = header_cell.position(),
            .width = header_width,
            .height = editor_shell.editor_header_strip_height,
            .action = .toggle_hub_palette_group,
            .payload = .{ .editor_group = @intCast(group_index) },
        } });
        try elements.append(allocator, .{ .text_label = .{
            .text = label,
            .screen_position = .{
                .x = header_cell.x + ui_element.ui_gap,
                .y = header_cell.y + @divTrunc(
                    editor_shell.editor_header_strip_height - editor_shell.editor_group_header_font_size,
                    2,
                ),
            },
            .font_size = editor_shell.editor_group_header_font_size,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });

        // The "+" (Decorations only): the square panel cell one gap right
        // of the header.
        if (group_has_plus[group_index]) {
            const plus_cell: Rectangle = .{
                .x = group_left + header_width + ui_element.ui_gap,
                .y = header_y,
                .width = editor_shell.editor_plus_size,
                .height = editor_shell.editor_plus_size,
            };
            try elements.append(allocator, .{ .nine_slice_panel = .{
                .sprite_id = "ui/panel",
                .screen_position = plus_cell.position(),
                .width = plus_cell.width,
                .height = plus_cell.height,
                .color = button_color,
                .blocks_input = false,
            } });
            try elements.append(allocator, .{ .button = .{
                .sprite_id = null,
                .screen_position = plus_cell.position(),
                .width = plus_cell.width,
                .height = plus_cell.height,
                .action = .add_hub_decoration_type,
                .tooltip = .{ .header = try spanRow(allocator, text("Add a decoration type (default art)")) },
            } });
            const plus_label = "+";
            const plus_width = font_metrics.measureSpanWidth(text(plus_label), editor_shell.editor_group_header_font_size);
            try elements.append(allocator, .{ .text_label = .{
                .text = plus_label,
                .screen_position = plus_cell.placeCenter(plus_width, editor_shell.editor_group_header_font_size).position(),
                .font_size = editor_shell.editor_group_header_font_size,
                .color = active_theme.lightest,
                .blocks_input = false,
            } });
        }

        // The cells: the visible window (skipped when collapsed).
        if (!collapsed[group_index] and size > 0) {
            const max_offset: i32 = @intCast(size -| editor_shell.editor_palette_max_tools);
            scroll_offsets[group_index] = @min(@max(scroll_offsets[group_index], 0), max_offset);
            const first_visible: usize = @intCast(scroll_offsets[group_index]);
            const visible = @min(size, editor_shell.editor_palette_max_tools);

            var ordinal: usize = 0;
            const cell_x = group_left;
            while (ordinal < visible) : (ordinal += 1) {
                const cell: Rectangle = .{
                    .x = cell_x + @as(i32, @intCast(ordinal)) * (ui_element.slot_size + ui_element.ui_gap),
                    .y = bar.y,
                    .width = ui_element.slot_size,
                    .height = ui_element.bottom_bar_height,
                };
                switch (group_index) {
                    0 => try emitHubNpcCell(elements, allocator, font_metrics, cell, hub_editor, active_theme, button_color, first_visible + ordinal),
                    1 => {
                        // The outgoing missions in authored order; the
                        // ordinal indexes into them.
                        var seen: usize = 0;
                        for (campaign_editor.missions) |mission| {
                            if (mission.start == null or mission.start.? != hub_editor.hub) continue;
                            defer seen += 1;
                            if (seen != first_visible + ordinal) continue;
                            try emitHubMissionCell(elements, allocator, font_metrics, cell, campaign_editor, hub_editor, mission, active_theme, button_color);
                            break;
                        }
                    },
                    2 => try emitHubDecorationCell(elements, allocator, font_metrics, cell, campaign_editor.decoration_types[first_visible + ordinal], @intCast(first_visible + ordinal), hub_editor, active_theme, button_color, world),
                    else => {},
                }
            }
        }
        row.advance(footprint + ui_element.ui_gap);
    }
}

/// One NPCs-group cell (the fixed NpcType pair): the button + the NPC's
/// sprite at half scale.
fn emitHubNpcCell(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: ui_element.FontMetrics,
    cell: Rectangle,
    hub_editor: types.HubEditor,
    active_theme: types.ActiveColorTheme,
    button_color: Color,
    npc_ordinal: usize,
) !void {
    _ = font_metrics;
    const npc_type: types.NpcType = switch (npc_ordinal) {
        0 => .gear_upgrader,
        else => .dream_guide,
    };
    try elements.append(allocator, .{ .button = .{
        .sprite_id = emit.button_background_sprite_id,
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .action = .select_hub_tool,
        .payload = .{ .hub_tool = .{ .npc = npc_type } },
        .color = button_color,
        .highlighted = std.meta.eql(hub_editor.active_tool, .{ .npc = npc_type }),
        .tooltip = .{ .header = try spanRow(allocator, text(try std.fmt.allocPrint(allocator, "Place a {s} NPC", .{@tagName(npc_type)}))) },
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
    _ = active_theme;
}

/// One Missions-group cell: the flag graphic + the mission's name across
/// the cell bottom.
fn emitHubMissionCell(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: ui_element.FontMetrics,
    cell: Rectangle,
    campaign_editor: types.CampaignEditor,
    hub_editor: types.HubEditor,
    mission: types.CampaignMissionEdit,
    active_theme: types.ActiveColorTheme,
    button_color: Color,
) !void {
    _ = campaign_editor;
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
    _ = font_metrics;
}

/// One Decorations-group cell: the type's base sprite (tinted like the
/// mission editor's cells) + the corner delete button.
fn emitHubDecorationCell(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: ui_element.FontMetrics,
    cell: Rectangle,
    type_definition: types.DecorationTypeDef,
    type_id: u32,
    hub_editor: types.HubEditor,
    active_theme: types.ActiveColorTheme,
    button_color: Color,
    world: [types.gradient_color_count]Color,
) !void {
    try elements.append(allocator, .{ .button = .{
        .sprite_id = emit.button_background_sprite_id,
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .action = .select_hub_tool,
        .payload = .{ .hub_tool = .{ .decoration_type = type_id } },
        .color = button_color,
        .highlighted = std.meta.eql(hub_editor.active_tool, .{ .decoration_type = type_id }),
        .tooltip = .{ .header = try spanRow(allocator, text(type_definition.id)) },
    } });
    const fitted = editor_shell.scaleToFit(cell, @max(type_definition.pixel_dims.x, 1), @max(type_definition.pixel_dims.y, 1));
    const sprite_id = try std.fmt.allocPrint(allocator, "decorations/{s}", .{type_definition.sprite});
    const color_index = @min(type_definition.color_index, types.gradient_color_count - 1);
    try elements.append(allocator, .{ .image = .{
        .sprite_id = sprite_id,
        .screen_position = .{ .x = fitted.x, .y = fitted.y },
        .width = fitted.width,
        .height = fitted.height,
        .color = if (type_definition.keep_original_colors)
            no_tint_color
        else
            world[color_index],
        .blocks_input = false,
    } });

    // The delete button (the mission palette's corner-cell shape).
    const delete_size = editor_shell.editor_plus_size;
    const delete_cell = Rectangle{
        .x = cell.x + cell.width - delete_size,
        .y = cell.y,
        .width = delete_size,
        .height = delete_size,
    };
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = delete_cell.position(),
        .width = delete_size,
        .height = delete_size,
        .color = active_theme.darkest,
        .blocks_input = false,
    } });
    try elements.append(allocator, .{ .button = .{
        .sprite_id = null,
        .screen_position = delete_cell.position(),
        .width = delete_size,
        .height = delete_size,
        .action = .delete_hub_decoration_type,
        .payload = .{ .hub_tool = .{ .decoration_type = type_id } },
        .tooltip = .{ .header = try spanRow(allocator, text("Delete this decoration type (and its placements in every hub)")) },
    } });
    const delete_label = "X";
    const delete_width = font_metrics.measureSpanWidth(text(delete_label), editor_shell.editor_group_header_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = delete_label,
        .screen_position = delete_cell.placeCenter(delete_width, editor_shell.editor_group_header_font_size).position(),
        .font_size = editor_shell.editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });
}

/// The hub editor's centered SPRITE PICKER (the mission editor's
/// buildEditorSpritePicker mirror for the decoration-base kind): the
/// shared overlay band, two tabs (Hub-local - the drilled-in hub's own
/// dir art; Official - the shipped decoration registry prefabs), a fixed
/// 6-column grid of slot cells, the active tab highlight, close top-right.
/// A pick (select_hub_decoration_sprite) adopts the sprite as the type's
/// whole definition at the consumption site.
pub fn buildHubSpritePicker(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: ui_element.FontMetrics,
    campaign_editor: types.CampaignEditor,
    hub_editor: types.HubEditor,
    hub_sprites: []const state.MissionSprite,
    decoration_registry: []const types.DecorationTypeDef,
    active_theme: types.ActiveColorTheme,
    ui_state: *ui_state_mod.UiState,
) !void {
    if (hub_editor.picker == null or hub_editor.picker.? != .decoration_sprite) return;
    const type_id = switch (hub_editor.active_tool) {
        .decoration_type => |resolved| resolved,
        else => return,
    };
    if (type_id >= campaign_editor.decoration_types.len) return;
    const type_definition = campaign_editor.decoration_types[type_id];
    const world = active_theme.world_gradient.colors;
    const button_color = world[@min(@as(u32, 5), types.gradient_color_count - 1)];

    // One cell per offered sprite (the mission picker's PickerCell shape,
    // reduced to the decoration-base needs).
    const PickerCell = struct {
        stored_id: []const u8,
        label: []const u8,
        graphic_id: []const u8,
        frame_width: i32,
        frame_height: i32,
        untinted: bool,
    };
    var cells: std.ArrayList(PickerCell) = .empty;
    var hidden_count: usize = 0;
    switch (ui_state.editor_picker_sprite_tab) {
        .mission_local => for (hub_sprites) |hub_sprite| {
            const file_name = hub_sprite.file_name;
            const stem = file_name[0 .. std.mem.lastIndexOfScalar(u8, file_name, '.') orelse file_name.len];
            const graphic_id = try std.fmt.allocPrint(allocator, "decorations/{s}", .{hub_sprite.stored_id});
            if (!types.customSpriteDimsPassGate(graphic_id, hub_sprite.pixel_dims)) {
                hidden_count += 1;
                continue;
            }
            try cells.append(allocator, .{
                .stored_id = hub_sprite.stored_id,
                .label = stem,
                .graphic_id = graphic_id,
                .frame_width = hub_sprite.pixel_dims.x,
                .frame_height = hub_sprite.pixel_dims.y,
                .untinted = true,
            });
        },
        .official => for (decoration_registry) |definition| {
            try cells.append(allocator, .{
                .stored_id = definition.sprite,
                .label = definition.sprite,
                .graphic_id = try std.fmt.allocPrint(allocator, "decorations/{s}", .{definition.sprite}),
                .frame_width = definition.pixel_dims.x,
                .frame_height = definition.pixel_dims.y,
                .untinted = false,
            });
        },
    }

    const bounds = editor_inspector.editorPickerOverlayRect();
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = bounds.position(),
        .width = bounds.width,
        .height = bounds.height,
        .color = active_theme.darkest,
        .blocks_input = true,
    } });

    // The header: the tabs top-left, close top-right.
    const origin = bounds.position();
    const tab_specs = [_]struct { tab: types.EditorSpritePickerTab, label: []const u8 }{
        .{ .tab = .mission_local, .label = "Hub" },
        .{ .tab = .official, .label = "Official" },
    };
    var tab_x = origin.x + ui_element.ui_gap;
    for (tab_specs) |spec| {
        const label_width = font_metrics.measureSpanWidth(text(spec.label), ui_element.middle_panel_header_font_size);
        const tab_width = label_width + 2 * ui_element.ui_gap;
        const active = spec.tab == ui_state.editor_picker_sprite_tab;
        try elements.append(allocator, .{ .nine_slice_panel = .{
            .sprite_id = "ui/panel",
            .screen_position = .{ .x = tab_x, .y = origin.y },
            .width = tab_width,
            .height = ui_element.middle_panel_header_height,
            .color = active_theme.darkest,
        } });
        try elements.append(allocator, .{ .button = .{
            .sprite_id = null,
            .screen_position = .{ .x = tab_x, .y = origin.y },
            .width = tab_width,
            .height = ui_element.middle_panel_header_height,
            .action = .select_editor_sprite_tab,
            .payload = .{ .editor_sprite_tab = spec.tab },
            .highlighted = active,
        } });
        try elements.append(allocator, .{ .text_label = .{
            .text = spec.label,
            .screen_position = .{
                .x = tab_x + ui_element.ui_gap,
                .y = origin.y + @divTrunc(
                    ui_element.middle_panel_header_height - ui_element.middle_panel_header_font_size,
                    2,
                ),
            },
            .font_size = ui_element.middle_panel_header_font_size,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });
        tab_x += tab_width + ui_element.ui_gap;
    }
    {
        const close_label = "Back";
        const close_width = font_metrics.measureSpanWidth(text(close_label), ui_element.middle_panel_header_font_size) + 2 * ui_element.ui_gap;
        const close_cell: Rectangle = .{
            .x = bounds.x + bounds.width - close_width - ui_element.ui_gap,
            .y = origin.y,
            .width = close_width,
            .height = ui_element.middle_panel_header_height,
        };
        try elements.append(allocator, .{ .nine_slice_panel = .{
            .sprite_id = "ui/panel",
            .screen_position = close_cell.position(),
            .width = close_width,
            .height = ui_element.middle_panel_header_height,
            .color = button_color,
        } });
        try elements.append(allocator, .{ .button = .{
            .sprite_id = null,
            .screen_position = close_cell.position(),
            .width = close_width,
            .height = ui_element.middle_panel_header_height,
            .action = .close_editor_picker,
        } });
        try elements.append(allocator, .{ .text_label = .{
            .text = close_label,
            .screen_position = close_cell.placeCenter(
                font_metrics.measureSpanWidth(text(close_label), ui_element.middle_panel_header_font_size),
                ui_element.middle_panel_header_font_size,
            ).position(),
            .font_size = ui_element.middle_panel_header_font_size,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });
    }

    // The fixed 6-column grid, centered below the header.
    const columns: i32 = 6;
    const rows: i32 = @max(@divTrunc(@as(i32, @intCast(cells.items.len)) + columns - 1, columns), 1);
    const cell_size = ui_element.slot_size;
    const grid_width = columns * cell_size + (columns - 1) * ui_element.ui_gap;
    const grid_height = rows * cell_size + (rows - 1) * ui_element.ui_gap;
    const grid_origin_x = bounds.x + @divTrunc(bounds.width - grid_width, 2);
    const grid_origin_y = origin.y + ui_element.middle_panel_header_height + ui_element.ui_gap +
        @divTrunc(@max(bounds.height - ui_element.middle_panel_header_height - 2 * ui_element.ui_gap - grid_height, 0), 2);
    for (cells.items, 0..) |picker_cell, cell_index| {
        const column: i32 = @intCast(cell_index % @as(usize, @intCast(columns)));
        const grid_row: i32 = @intCast(cell_index / @as(usize, @intCast(columns)));
        const cell: Rectangle = .{
            .x = grid_origin_x + column * (cell_size + ui_element.ui_gap),
            .y = grid_origin_y + grid_row * (cell_size + ui_element.ui_gap),
            .width = cell_size,
            .height = cell_size,
        };
        const is_current = std.mem.eql(u8, picker_cell.stored_id, type_definition.sprite);
        try elements.append(allocator, .{ .button = .{
            .sprite_id = emit.button_background_sprite_id,
            .screen_position = cell.position(),
            .width = cell.width,
            .height = cell.height,
            .action = .select_hub_decoration_sprite,
            .payload = .{ .editor_sprite = picker_cell.stored_id },
            .color = button_color,
            .highlighted = is_current,
            .tooltip = .{ .header = try spanRow(allocator, text(picker_cell.label)) },
        } });
        const fitted = editor_shell.scaleToFit(cell, @max(picker_cell.frame_width, 1), @max(picker_cell.frame_height, 1));
        const color_index = @min(type_definition.color_index, types.gradient_color_count - 1);
        try elements.append(allocator, .{ .image = .{
            .sprite_id = picker_cell.graphic_id,
            .screen_position = .{ .x = fitted.x, .y = fitted.y },
            .width = fitted.width,
            .height = fitted.height,
            .color = if (picker_cell.untinted)
                no_tint_color
            else
                world[color_index],
            .blocks_input = false,
        } });
    }

    // The empty + hidden notes (never silent).
    if (cells.items.len == 0) {
        const note = if (ui_state.editor_picker_sprite_tab == .mission_local)
            "No hub-local sprites yet (unsaved hub, or no PNGs in its dir)"
        else
            "No official decoration sprites";
        try elements.append(allocator, .{ .text_label = .{
            .text = note,
            .screen_position = .{
                .x = bounds.x + ui_element.ui_gap,
                .y = grid_origin_y + @divTrunc(cell_size - ui_element.middle_panel_header_font_size, 2),
            },
            .font_size = ui_element.middle_panel_header_font_size,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });
    } else if (hidden_count > 0) {
        const note = try std.fmt.allocPrint(allocator, "{d} sprite(s) hidden (dims not whole 256px tiles)", .{hidden_count});
        try elements.append(allocator, .{ .text_label = .{
            .text = note,
            .screen_position = .{
                .x = bounds.x + ui_element.ui_gap,
                .y = bounds.y + bounds.height - ui_element.middle_panel_header_height - ui_element.ui_gap,
            },
            .font_size = ui_element.middle_panel_header_font_size,
            .color = active_theme.darkest,
            .blocks_input = false,
        } });
    }
}

/// The hub palette group under the pointer - the `editorPaletteGroupAt`
/// mirror over the hub's groups: the hit test walks the emitted tool
/// cells (button_background buttons in the bottom bar) in emission order,
/// mapping each flat cell index to its group.
pub fn hubPaletteGroupAt(
    campaign_editor: types.CampaignEditor,
    hub_editor: types.HubEditor,
    collapsed: *const [3]bool,
    ui_elements: []const ui_element.UiElement,
    position: types.ScreenPosition,
) ?usize {
    if (position.y < types.reference_height - ui_element.bottom_bar_height) return null;
    var cell_index: usize = 0;
    for (ui_elements) |element| switch (element) {
        .button => |button| {
            const sprite_id = button.sprite_id orelse continue;
            if (!std.mem.eql(u8, sprite_id, emit.button_background_sprite_id)) continue;
            if (button.screen_position.y < types.reference_height - ui_element.bottom_bar_height) continue;
            defer cell_index += 1;
            const group = hubPaletteGroupOfCell(campaign_editor, hub_editor, collapsed, cell_index) orelse continue;
            const cell: Rectangle = .{
                .x = button.screen_position.x,
                .y = button.screen_position.y,
                .width = button.width,
                .height = button.height,
            };
            if (cell.contains(position)) return group;
        },
        else => {},
    };
    return null;
}

/// Map a flat tool-cell index (bottom-bar emission order) to its group -
/// the editorPaletteGroupOfCell mirror (the first 2 cells are the fixed
/// tools; each expanded group contributes its visible window).
fn hubPaletteGroupOfCell(
    campaign_editor: types.CampaignEditor,
    hub_editor: types.HubEditor,
    collapsed: *const [3]bool,
    cell_index: usize,
) ?usize {
    var outgoing_mission_count: usize = 0;
    for (campaign_editor.missions) |mission| {
        if (mission.start != null and mission.start.? == hub_editor.hub) outgoing_mission_count += 1;
    }
    const group_sizes = [3]usize{ 2, outgoing_mission_count, campaign_editor.decoration_types.len };
    var index = cell_index;
    if (index < 2) return null;
    index -= 2;
    for (0..3) |group_index| {
        if (collapsed[group_index]) continue;
        const segment = @min(group_sizes[group_index], editor_shell.editor_palette_max_tools);
        if (index < segment) return group_index;
        index -= segment;
    }
    return null;
}

/// The hub palette group's live size (the wheel clamp's input - the
/// editorPaletteGroupSize mirror).
pub fn hubPaletteGroupSize(
    campaign_editor: types.CampaignEditor,
    hub_editor: types.HubEditor,
    group_index: usize,
) usize {
    var outgoing_mission_count: usize = 0;
    for (campaign_editor.missions) |mission| {
        if (mission.start != null and mission.start.? == hub_editor.hub) outgoing_mission_count += 1;
    }
    return switch (group_index) {
        0 => 2,
        1 => outgoing_mission_count,
        else => campaign_editor.decoration_types.len,
    };
}

/// The hub editor's inspector sidebar (the campaign editor's EXACT shape -
/// the top-left toggle strip below the options button, the panel + content
/// only while open): the panel is EMPTY by default (no player.txt for
/// hubs), a single selected EXIT MARKER shows its READ-ONLY summary (all
/// editing stays on the campaign map - name, re-attach, and direction each
/// have exactly one editing site there), and a selected NPC shows the
/// empty-for-now placeholder (semantics arrive with NPC interaction).
pub fn buildHubEditorInspector(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: ui_element.FontMetrics,
    screen: Rectangle,
    campaign_editor: types.CampaignEditor,
    hub_editor: types.HubEditor,
    active_theme: types.ActiveColorTheme,
    button_color: Color,
    ui_state: *ui_state_mod.UiState,
) !void {
    const p = active_theme.player_gradient.colors;
    const strip_button_color = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const label = "Inspector";
    const label_width = font_metrics.measureSpanWidth(text(label), editor_shell.editor_group_header_font_size);
    const width = @max(label_width + 2 * ui_element.ui_gap, editor_shell.editor_header_strip_height);
    const button_cell = Rectangle{
        .x = screen.x,
        .y = screen.y + ui_element.top_bar_height + ui_element.ui_gap,
        .width = width,
        .height = editor_shell.editor_header_strip_height,
    };
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = button_cell.position(),
        .width = width,
        .height = editor_shell.editor_header_strip_height,
        .color = strip_button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .sprite_id = null,
        .screen_position = button_cell.position(),
        .width = width,
        .height = editor_shell.editor_header_strip_height,
        .action = .toggle_hub_inspector,
    } });
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = button_cell.placeCenter(label_width, editor_shell.editor_group_header_font_size).position(),
        .font_size = editor_shell.editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });

    if (!hub_editor.inspector_open) return;

    const panel_rect = editor_inspector.editorInspectorPanelRect();
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = panel_rect.position(),
        .width = panel_rect.width,
        .height = panel_rect.height,
        .color = active_theme.darkest,
        .blocks_input = true,
    } });
    const content = Rectangle{
        .x = panel_rect.x + ui_element.ui_gap,
        .y = panel_rect.y + ui_element.ui_gap,
        .width = panel_rect.width - 2 * ui_element.ui_gap,
        .height = panel_rect.height - 2 * ui_element.ui_gap,
    };

    // The target inference: a SINGLE-entry selection of the right kind.
    // A multi-selection (marquee) shows the empty panel - the read-only
    // summary addresses ONE marker.
    const single: ?types.Selectable = if (hub_editor.selection.len == 1)
        hub_editor.selection[0]
    else
        null;

    // Resolve the drilled-in hub (the placements index into its grid).
    var drilled: ?types.CampaignHubEdit = null;
    for (campaign_editor.hubs) |candidate_hub| {
        if (candidate_hub.handle == hub_editor.hub) drilled = candidate_hub;
    }

    const font = editor_shell.editor_group_header_font_size;
    const line = struct {
        fn at(y: i32) i32 {
            return y;
        }
    }.at;

    // The decoration-type content: the ACTIVE TOOL's type (the mission
    // editor's tool-driven content rule), structured EXACTLY like the
    // mission editor's decoration inspector - the Identity section
    // (Sprite / Keep colors / Color) + the Footprint section, the section
    // strips + two-line field rows through the shared emitters. The
    // Sprite + Footprint rows render as read-only panels until the
    // pickers land (4-5c): the layout is the mirror, the buttons
    // become live with their pickers.
    if (hub_editor.active_tool == .decoration_type) {
        const type_id = hub_editor.active_tool.decoration_type;
        if (type_id >= campaign_editor.decoration_types.len) return;
        const type_definition = campaign_editor.decoration_types[type_id];
        const world = active_theme.world_gradient.colors;
        const decoration_button_color = world[@min(@as(u32, 5), types.gradient_color_count - 1)];
        const row_height = editor_inspector.editor_inspector_row_height;

        // Identity (the strip always renders - the mission editor's
        // independent sections; only the children are conditional).
        const identity_expanded = ui_state.editor_inspector_section_expanded[@backingInt(types.EditorInspectorSectionId.identity)];
        {
            const strip: Rectangle = .{
                .x = content.x,
                .y = content.y,
                .width = content.width,
                .height = editor_shell.editor_header_strip_height,
            };
            try editor_inspector.emitInspectorSectionStrip(
                elements,
                allocator,
                strip,
                .identity,
                identity_expanded,
                decoration_button_color,
                active_theme,
            );
        }
        // The field rows: the label line + the control line (the mission
        // inspector's two-unit convention) - the identity children, only
        // while expanded.
        const row = struct {
            fn at(content_rect: Rectangle, index: i32, row_height_units: i32) Rectangle {
                return .{
                    .x = content_rect.x,
                    .y = content_rect.y + index * row_height_units * editor_inspector.editor_inspector_row_height,
                    .width = content_rect.width,
                    .height = row_height_units * editor_inspector.editor_inspector_row_height,
                };
            }
        }.at;

        if (identity_expanded) {
            // Sprite (the shared emitter - the button opens the picker
            // via the surface-polymorphic open_editor_sprite_picker).
            {
                const cell = row(content, 1, 2);
                try elements.append(allocator, .{ .text_label = .{
                    .text = "Sprite",
                    .screen_position = .{ .x = cell.x, .y = editor_inspector.inspectorLabelY(cell) },
                    .font_size = editor_shell.editor_group_header_font_size,
                    .color = active_theme.lightest,
                    .blocks_input = false,
                } });
                try editor_inspector.emitInspectorSpriteButton(
                    elements,
                    allocator,
                    font_metrics,
                    type_definition.sprite,
                    decoration_button_color,
                    editor_inspector.inspectorControlRect(cell),
                    active_theme,
                );
            }

            // Keep colors (the shared toggle emitter, the surface-polymorphic
            // mission action - the consumption site branches per screen).
            {
                const cell = row(content, 3, 2);
                try elements.append(allocator, .{ .text_label = .{
                    .text = "Keep colors",
                    .screen_position = .{ .x = cell.x, .y = editor_inspector.inspectorLabelY(cell) },
                    .font_size = editor_shell.editor_group_header_font_size,
                    .color = active_theme.lightest,
                    .blocks_input = false,
                } });
                try editor_inspector.emitInspectorToggle(
                    elements,
                    allocator,
                    font_metrics,
                    type_definition.keep_original_colors,
                    .toggle_editor_decoration_keep_original_colors,
                    decoration_button_color,
                    editor_inspector.inspectorControlRect(cell),
                    active_theme,
                );
            }

            // Color (the shared swatch emitter: the world gradient + the
            // surface-polymorphic mission action; hidden while the flag is
            // on - the mission's dead-control rule).
            if (!type_definition.keep_original_colors) {
                const cell = row(content, 5, 2);
                try elements.append(allocator, .{ .text_label = .{
                    .text = "Color",
                    .screen_position = .{ .x = cell.x, .y = editor_inspector.inspectorLabelY(cell) },
                    .font_size = editor_shell.editor_group_header_font_size,
                    .color = active_theme.lightest,
                    .blocks_input = false,
                } });
                try editor_inspector.emitInspectorColorSwatches(
                    elements,
                    allocator,
                    world,
                    type_definition.color_index,
                    .select_editor_decoration_color,
                    null,
                    editor_inspector.inspectorControlRect(cell),
                );
            }
        }

        // Footprint (the tile count; read-only until the editor). The
        // strip sits after the identity strip + its expanded children
        // (3 two-unit rows: Sprite, Keep colors, Color - Color hidden
        // while the flag is on).
        {
            const footprint_expanded = ui_state.editor_inspector_section_expanded[@backingInt(types.EditorInspectorSectionId.footprint)];
            const identity_children_units: i32 = if (!identity_expanded)
                0
            else if (type_definition.keep_original_colors)
                4
            else
                6;
            const strip_y = content.y + editor_shell.editor_header_strip_height + identity_children_units * row_height;
            const strip: Rectangle = .{
                .x = content.x,
                .y = strip_y,
                .width = content.width,
                .height = editor_shell.editor_header_strip_height,
            };
            try editor_inspector.emitInspectorSectionStrip(
                elements,
                allocator,
                strip,
                .footprint,
                footprint_expanded,
                decoration_button_color,
                active_theme,
            );
            if (footprint_expanded) {
                const cell: Rectangle = .{
                    .x = content.x,
                    .y = strip_y + editor_shell.editor_header_strip_height,
                    .width = content.width,
                    .height = 2 * row_height,
                };
                try elements.append(allocator, .{ .text_label = .{
                    .text = "Footprint",
                    .screen_position = .{ .x = cell.x, .y = editor_inspector.inspectorLabelY(cell) },
                    .font_size = editor_shell.editor_group_header_font_size,
                    .color = active_theme.lightest,
                    .blocks_input = false,
                } });
                const control_rect = editor_inspector.inspectorControlRect(cell);
                const count_label = try std.fmt.allocPrint(allocator, "{d} tiles", .{type_definition.footprint.len});
                const count_width = font_metrics.measureSpanWidth(text(count_label), editor_shell.editor_group_header_font_size);
                const count_rect: Rectangle = .{
                    .x = control_rect.x,
                    .y = control_rect.y,
                    .width = @divFloor(control_rect.width, 2),
                    .height = control_rect.height,
                };
                try elements.append(allocator, .{ .nine_slice_panel = .{
                    .sprite_id = "ui/panel",
                    .screen_position = count_rect.position(),
                    .width = count_rect.width,
                    .height = count_rect.height,
                    .color = decoration_button_color,
                    .blocks_input = false,
                } });
                try elements.append(allocator, .{ .text_label = .{
                    .text = count_label,
                    .screen_position = count_rect.placeCenter(count_width, editor_shell.editor_group_header_font_size).position(),
                    .font_size = editor_shell.editor_group_header_font_size,
                    .color = active_theme.lightest,
                    .blocks_input = false,
                } });
            }
        }
        return;
    }

    if (single != null and single.? == .exit_placement) {
        const placement_index = single.?.exit_placement;
        const hub = drilled orelse return;
        if (placement_index >= hub.grid.exit_placements.len) return;
        const placement = hub.grid.exit_placements[placement_index];

        // The mission (by handle) + its destination hub (by handle).
        var mission: ?types.CampaignMissionEdit = null;
        for (campaign_editor.missions) |candidate| {
            if (candidate.handle == placement.mission) mission = candidate;
        }
        var destination: ?types.CampaignHubEdit = null;
        if (mission) |resolved| {
            if (resolved.destination) |destination_handle| {
                for (campaign_editor.hubs) |candidate_hub| {
                    if (candidate_hub.handle == destination_handle) destination = candidate_hub;
                }
            }
        }

        var y = content.y;
        try elements.append(allocator, .{ .text_label = .{
            .text = "Exit Marker",
            .screen_position = .{ .x = content.x, .y = y },
            .font_size = font,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });
        y += font + ui_element.ui_gap;
        const mission_name = if (mission) |resolved|
            (if (resolved.name.len > 0) resolved.name else "Unsaved mission")
        else
            "Unknown mission";
        try elements.append(allocator, .{ .text_label = .{
            .text = mission_name,
            .screen_position = .{ .x = content.x, .y = line(y) },
            .font_size = font,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });
        y += font + ui_element.ui_gap;
        const destination_text = if (mission == null)
            "Dangling - no destination hub"
        else if (destination == null)
            "Dangling - no destination hub"
        else
            (if (destination.?.name.len > 0) destination.?.name else "Unnamed hub");
        try elements.append(allocator, .{ .text_label = .{
            .text = destination_text,
            .screen_position = .{ .x = content.x, .y = line(y) },
            .font_size = font,
            .color = if (destination == null) button_color else active_theme.lightest,
            .blocks_input = false,
        } });
        y += font + ui_element.ui_gap;
        try elements.append(allocator, .{ .text_label = .{
            .text = "Edit on the campaign map",
            .screen_position = .{ .x = content.x, .y = line(y) },
            .font_size = font,
            .color = active_theme.darkest,
            .blocks_input = false,
        } });
        return;
    }

    if (single != null and single.? == .npc_placement) {
        try elements.append(allocator, .{ .text_label = .{
            .text = "NPC",
            .screen_position = .{ .x = content.x, .y = content.y },
            .font_size = font,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });
        try elements.append(allocator, .{ .text_label = .{
            .text = "Interaction semantics land with NPC interaction",
            .screen_position = .{ .x = content.x, .y = content.y + font + ui_element.ui_gap },
            .font_size = font,
            .color = active_theme.darkest,
            .blocks_input = false,
        } });
        return;
    }

    // The default: empty (no player.txt for hubs).
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
        .decoration_types = &.{
            .{ .id = "tree", .sprite = "tree_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
        },
        .next_handle = 6,
    };
    var collapsed = [3]bool{ true, true, true };
    var scroll_offsets = [3]i32{ 0, 0, 0 };
    var elements: UiElementList = .empty;
    defer elements.deinit(arena.allocator());
    try buildHubEditorBottomBar(&elements, arena.allocator(), test_metrics, ui_element.screenRect(), campaign_editor, .{ .hub = 0, .active_tool = .tile }, test_theme, &collapsed, &scroll_offsets);

    var select_cell: ?ui_element.Button = null;
    var tile_cell: ?ui_element.Button = null;
    var group_headers: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| switch (button.payload orelse continue) {
            .hub_tool => |tool| switch (tool) {
                .select => select_cell = button,
                .tile => tile_cell = button,
                else => {},
            },
            .editor_group => group_headers += 1,
            else => {},
        },
        else => {},
    };
    // All groups collapsed (the accordion default): the three headers
    // render, no group cells.
    try std.testing.expectEqual(@as(usize, 3), group_headers);

    // Expanding the Decorations group: its cells render (the one type).
    collapsed[2] = false;
    var expanded_elements: UiElementList = .empty;
    defer expanded_elements.deinit(arena.allocator());
    try buildHubEditorBottomBar(&expanded_elements, arena.allocator(), test_metrics, ui_element.screenRect(), campaign_editor, .{ .hub = 0, .active_tool = .tile }, test_theme, &collapsed, &scroll_offsets);
    // One CELL (the button_background button) + its corner delete button
    // (sprite-less) - both carry the type payload; the cell is the
    // backgrounded one.
    var decoration_cells: usize = 0;
    var decoration_delete_cells: usize = 0;
    for (expanded_elements.items) |element| switch (element) {
        .button => |button| switch (button.payload orelse continue) {
            .hub_tool => |tool| switch (tool) {
                .decoration_type => {
                    if (button.sprite_id != null) {
                        decoration_cells += 1;
                    } else {
                        decoration_delete_cells += 1;
                    }
                },
                else => {},
            },
            else => {},
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), decoration_cells);
    try std.testing.expectEqual(@as(usize, 1), decoration_delete_cells);
    try std.testing.expect(select_cell != null);
    try std.testing.expect(tile_cell != null);
    try std.testing.expectEqual(@as(i32, 0), select_cell.?.screen_position.x);
    try std.testing.expect(tile_cell.?.highlighted);
    try std.testing.expect(!select_cell.?.highlighted);

    // The select tool active: the mirror.
    var select_elements: UiElementList = .empty;
    defer select_elements.deinit(arena.allocator());
    try buildHubEditorBottomBar(&select_elements, arena.allocator(), test_metrics, ui_element.screenRect(), campaign_editor, .{ .hub = 0, .active_tool = .select }, test_theme, &collapsed, &scroll_offsets);
    for (select_elements.items) |element| switch (element) {
        .button => |button| switch (button.payload orelse continue) {
            .hub_tool => |tool| switch (tool) {
                .select => try std.testing.expect(button.highlighted),
                .tile => try std.testing.expect(!button.highlighted),
                .npc, .mission, .decoration_type => {},
            },
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

test "buildHubEditorInspector: the exit summary, the NPC placeholder, the empty default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    const test_theme: types.ActiveColorTheme = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .world_gradient = .{ .colors = @splat(black) },
        .enemy_gradient = .{ .colors = @splat(black) },
        .player_gradient = .{ .colors = @splat(black) },
    };
    const button_color: Color = .{ .r = 50, .g = 50, .b = 50 };
    const test_metrics = ui_element.FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };

    // A drilled-in hub with an exit marker (wired to a destination) + an
    // NPC.
    const campaign_editor = types.CampaignEditor{
        .start_hub = 0,
        .hubs = &.{
            .{ .handle = 0, .name = "Alpha", .position = .{ .x = 0, .y = 0 }, .grid = .{
                .npc_placements = &.{.{ .npc_type = .dream_guide, .position = .{ .x = 1, .y = 0 } }},
                .exit_placements = &.{.{ .mission = 5, .position = .{ .x = 2, .y = 0 } }},
            } },
            .{ .handle = 1, .name = "Beta", .position = .{ .x = 400, .y = 0 } },
        },
        .missions = &.{.{ .handle = 5, .name = "One", .start = 0, .destination = 1 }},
        .decoration_types = &.{
            .{ .id = "tree", .sprite = "tree_1", .footprint = &.{.{ .x = 0, .y = 0 }} },
        },
        .next_handle = 6,
    };

    const findLabel = struct {
        fn at(elements: []const UiElement, needle: []const u8) ?ui_element.TextLabel {
            for (elements) |element| switch (element) {
                .text_label => |label| if (std.mem.eql(u8, label.text, needle)) return label,
                else => {},
            };
            return null;
        }
    }.at;
    const findToggle = struct {
        fn at(elements: []const UiElement) ?ui_element.Button {
            for (elements) |element| switch (element) {
                .button => |button| if (button.action == .toggle_hub_inspector) return button,
                else => {},
            };
            return null;
        }
    }.at;

    var ui_state = ui_state_mod.UiState{};
    // The shared default expands Identity - collapse it for the
    // strips-only case.
    ui_state.editor_inspector_section_expanded[@backingInt(types.EditorInspectorSectionId.identity)] = false;
    // The decoration-type tool: the mission inspector's structure - the
    // Identity section (Sprite / Keep colors / Color) + the Footprint
    // section.
    {
        var elements: UiElementList = .empty;
        defer elements.deinit(allocator);
        try buildHubEditorInspector(&elements, allocator, test_metrics, ui_element.screenRect(), campaign_editor, .{ .hub = 0, .active_tool = .{ .decoration_type = 0 } }, test_theme, button_color, &ui_state);
        var section_strips: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| switch (button.action) {
                .toggle_editor_inspector_section => section_strips += 1,
                else => {},
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 2), section_strips);
        try std.testing.expect(findLabel(elements.items, "Sprite") == null);
    }
    // Identity expanded: the Sprite / Keep colors / Color rows + the live
    // controls.
    {
        ui_state.editor_inspector_section_expanded[@backingInt(types.EditorInspectorSectionId.identity)] = true;
        ui_state.editor_inspector_section_expanded[@backingInt(types.EditorInspectorSectionId.footprint)] = false;
        var elements: UiElementList = .empty;
        defer elements.deinit(allocator);
        try buildHubEditorInspector(&elements, allocator, test_metrics, ui_element.screenRect(), campaign_editor, .{ .hub = 0, .active_tool = .{ .decoration_type = 0 } }, test_theme, button_color, &ui_state);
        try std.testing.expect(findLabel(elements.items, "Sprite") != null);
        try std.testing.expect(findLabel(elements.items, "Keep colors") != null);
        try std.testing.expect(findLabel(elements.items, "Color") != null);
        var toggle_count: usize = 0;
        var swatch_count: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| switch (button.action) {
                .toggle_editor_decoration_keep_original_colors => toggle_count += 1,
                .select_editor_decoration_color => swatch_count += 1,
                else => {},
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 1), toggle_count);
        try std.testing.expectEqual(@as(usize, types.gradient_color_count), swatch_count);
    }

    // The single selected exit marker: the read-only summary (mission
    // name + destination hub name).
    {
        var elements: UiElementList = .empty;
        defer elements.deinit(allocator);
        try buildHubEditorInspector(&elements, allocator, test_metrics, ui_element.screenRect(), campaign_editor, .{ .hub = 0, .selection = &.{.{ .exit_placement = 0 }} }, test_theme, button_color, &ui_state);
        try std.testing.expect(findToggle(elements.items) != null);
        try std.testing.expect(findLabel(elements.items, "Exit Marker") != null);
        try std.testing.expect(findLabel(elements.items, "One") != null);
        try std.testing.expect(findLabel(elements.items, "Beta") != null);
        try std.testing.expect(findLabel(elements.items, "Dangling - no destination hub") == null);
    }

    // The single selected NPC: the placeholder.
    {
        var elements: UiElementList = .empty;
        defer elements.deinit(allocator);
        try buildHubEditorInspector(&elements, allocator, test_metrics, ui_element.screenRect(), campaign_editor, .{ .hub = 0, .selection = &.{.{ .npc_placement = 0 }} }, test_theme, button_color, &ui_state);
        try std.testing.expect(findLabel(elements.items, "NPC") != null);
        try std.testing.expect(findLabel(elements.items, "Interaction semantics land with NPC interaction") != null);
    }

    // No selection (and a multi-selection): the empty default - no
    // content labels beyond the strip's own.
    {
        var elements: UiElementList = .empty;
        defer elements.deinit(allocator);
        try buildHubEditorInspector(&elements, allocator, test_metrics, ui_element.screenRect(), campaign_editor, .{ .hub = 0 }, test_theme, button_color, &ui_state);
        try std.testing.expect(findLabel(elements.items, "Exit Marker") == null);
        try std.testing.expect(findLabel(elements.items, "NPC") == null);
    }

    // Closed: the strip alone.
    {
        var elements: UiElementList = .empty;
        defer elements.deinit(allocator);
        try buildHubEditorInspector(&elements, allocator, test_metrics, ui_element.screenRect(), campaign_editor, .{ .hub = 0, .inspector_open = false }, test_theme, button_color, &ui_state);
        try std.testing.expect(findToggle(elements.items) != null);
        var panel_count: usize = 0;
        for (elements.items) |element| switch (element) {
            .nine_slice_panel => panel_count += 1,
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 1), panel_count); // the strip's own panel only
    }
}
