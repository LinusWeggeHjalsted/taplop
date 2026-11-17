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
const editor_pickers = @import("editor_pickers.zig");
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

/// The hub editor drill-in's centered SPRITE PICKER: the shared core
/// (renderSpritePickerGrid) over the hub-local scan + the registry - the
/// thin caller of the mission editor's machinery (the 4-5d reuse). Two
/// tabs: Hub-local (the drilled-in hub's own dir art) + Official (the
/// shipped decoration registry prefabs, rendered in their composed
/// appearance). A pick (select_hub_decoration_sprite) adopts the sprite
/// as the type's whole definition at the consumption site.
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
    if (hub_editor.picker == null) return;
    // The mode: the BASE sprite (a whole-def adoption) or a LAYER sprite
    // (the payload is the edited layer index, null = add) - the mission
    // picker's two decoration kinds over the campaign palette.
    const layer_mode = hub_editor.picker.? == .decoration_layer;
    const layer_index: ?u32 = switch (hub_editor.picker.?) {
        .decoration_sprite => null,
        .decoration_layer => |picker_layer_index| picker_layer_index,
        else => return,
    };
    const type_id = switch (hub_editor.active_tool) {
        .decoration_type => |resolved| resolved,
        else => return,
    };
    if (type_id >= campaign_editor.decoration_types.len) return;
    const type_definition = campaign_editor.decoration_types[type_id];

    // The cells: the SHARED arms - the local scan (spec-gated, untinted
    // custom art; the layer mode's base-dims match) + the registry
    // prefabs (base) or the dims-filtered shipped sprites (layer).
    var cells: std.ArrayList(editor_pickers.SpritePickerCell) = .empty;
    var hidden_count: usize = 0;
    switch (ui_state.editor_picker_sprite_tab) {
        .mission_local => {
            hidden_count += try editor_pickers.appendLocalDecorationCells(
                allocator,
                &cells,
                hub_sprites,
                if (layer_mode) type_definition.pixel_dims else null,
            );
        },
        .official => {
            if (layer_mode) {
                try editor_pickers.appendOfficialDecorationSpriteCells(
                    allocator,
                    &cells,
                    type_definition.pixel_dims,
                );
            } else {
                try editor_pickers.appendDecorationRegistryCells(allocator, &cells, decoration_registry);
            }
        },
    }

    // The mission picker's layer conventions (buildEditorSpritePicker):
    // the EDITED layer is the highlight target + tint source; ADD mode
    // highlights nothing + tints with the base; a stale index (out of
    // range) likewise falls back to the base values, and every pick
    // no-ops at the commit gate.
    const edited_layer_sprite: ?[]const u8 = blk: {
        const index = layer_index orelse break :blk null;
        if (!layer_mode or index >= type_definition.layers.len) break :blk null;
        break :blk type_definition.layers[index].sprite;
    };
    const edited_layer_color_index: ?u32 = blk: {
        const index = layer_index orelse break :blk null;
        if (!layer_mode or index >= type_definition.layers.len) break :blk null;
        break :blk type_definition.layers[index].color_index;
    };
    const current_sprite: ?[]const u8 = if (layer_mode)
        edited_layer_sprite
    else
        type_definition.sprite;

    // The shared emission core (the mission editor's own): tabs, close,
    // the 6-column grid, the prefab cells' composed appearance, the
    // notes - identical by construction.
    const world = active_theme.world_gradient.colors;
    const empty_note: []const u8 = if (ui_state.editor_picker_sprite_tab == .mission_local)
        "No hub-local sprites yet (unsaved hub, or no PNGs in its dir)"
    else
        "No sprites";
    try editor_pickers.renderSpritePickerGrid(
        elements,
        allocator,
        font_metrics,
        cells.items,
        .{
            .tab = ui_state.editor_picker_sprite_tab,
            .local_tab_label = "Hub",
            .pick_action = if (layer_mode)
                .select_editor_decoration_layer
            else
                .select_hub_decoration_sprite,
            .current_sprite = current_sprite,
            .graphic_color = world[
                @min(edited_layer_color_index orelse type_definition.color_index, types.gradient_color_count - 1)
            ],
            .gradient = world,
            .button_color = world[@min(@as(u32, 5), types.gradient_color_count - 1)],
            .hidden_count = hidden_count,
            .hidden_spec_note = if (layer_mode)
                "layer art must match the base sprite's dims"
            else
                "decoration art must be whole multiples of 256",
            .empty_note = empty_note,
        },
        active_theme,
    );
}

/// The hub editor drill-in's METADATA SIDEBAR: the mission editor's own
/// machinery (hubMetadataEntries + renderMetadataEntries - the 4-5d
/// reuse) over the drilled hub - the name field (the campaign hub-name
/// field identity, so the same commit event serves both surfaces) + the
/// three gradient rows over the authored grid's gradient keys (the level
/// metadata's exact set; see DESIGN → The hub editor surface).
pub fn buildHubEditorMetadataSidebar(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: ui_element.FontMetrics,
    campaign_editor: types.CampaignEditor,
    hub_editor: types.HubEditor,
    active_theme: types.ActiveColorTheme,
    color_theme_definitions: types.ColorThemeDefinitions,
    ui_state: *ui_state_mod.UiState,
) !void {
    const p = active_theme.player_gradient.colors;
    const button_color = p[@min(@as(u32, 5), types.gradient_color_count - 1)];

    // Toggle button: flush right, at the inspector toggle's height (the
    // mission sidebar's convention).
    const label = "Metadata";
    const label_width = font_metrics.measureSpanWidth(text(label), editor_shell.editor_group_header_font_size);
    const width = @max(label_width + 2 * ui_element.ui_gap, editor_shell.editor_header_strip_height);
    const button_cell: Rectangle = .{
        .x = types.reference_width - width,
        .y = ui_element.top_bar_height + ui_element.ui_gap,
        .width = width,
        .height = editor_shell.editor_header_strip_height,
    };
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = button_cell.position(),
        .width = width,
        .height = editor_shell.editor_header_strip_height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .sprite_id = null,
        .screen_position = button_cell.position(),
        .width = width,
        .height = editor_shell.editor_header_strip_height,
        .action = .toggle_hub_metadata_sidebar,
    } });
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = button_cell.placeCenter(label_width, editor_shell.editor_group_header_font_size).position(),
        .font_size = editor_shell.editor_group_header_font_size,
        .color = active_theme.lightest,
        .blocks_input = false,
    } });

    if (!hub_editor.metadata_open) return;

    // The drilled hub (the entries read its name + gradient keys).
    var drilled: ?types.CampaignHubEdit = null;
    for (campaign_editor.hubs) |candidate_hub| {
        if (candidate_hub.handle == hub_editor.hub) drilled = candidate_hub;
    }
    const hub = drilled orelse return;

    const entries = try editor_inspector.hubMetadataEntries(
        allocator,
        hub,
        active_theme,
        color_theme_definitions,
        &ui_state.editor_inspector_section_expanded,
    );
    try editor_inspector.renderMetadataEntries(
        elements,
        allocator,
        font_metrics,
        entries,
        button_color,
        active_theme,
        ui_state,
    );
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
    // editor's tool-driven content rule) through the mission editor's
    // OWN entries fn + renderer - spacing, section strips, row units,
    // windowing + scroll identical by construction (the 4-5d reuse).
    // The footprint + layers rows render in the mission's live shapes;
    // their picks go live for the hub surface with 4-5c(ii).
    if (hub_editor.active_tool == .decoration_type) {
        const type_id = hub_editor.active_tool.decoration_type;
        if (type_id >= campaign_editor.decoration_types.len) return;
        const type_definition = campaign_editor.decoration_types[type_id];
        const world = active_theme.world_gradient.colors;
        const decoration_button_color = world[@min(@as(u32, 5), types.gradient_color_count - 1)];
        const entries = try editor_inspector.editorInspectorDecorationEntries(
            allocator,
            type_definition,
            &ui_state.editor_inspector_section_expanded,
        );
        try editor_inspector.renderInspectorEntries(
            elements,
            allocator,
            font_metrics,
            entries,
            .{
                .decoration = .{ .type_definition = type_definition },
                .button_color = decoration_button_color,
            },
            active_theme,
            ui_state,
        );
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
    // All sections expanded by default - collapse them for the
    // strips-only case.
    ui_state.editor_inspector_section_expanded[@backingInt(types.EditorInspectorSectionId.identity)] = false;
    ui_state.editor_inspector_section_expanded[@backingInt(types.EditorInspectorSectionId.footprint)] = false;
    ui_state.editor_inspector_section_expanded[@backingInt(types.EditorInspectorSectionId.layers)] = false;
    // The decoration-type tool: the mission inspector's own structure
    // (editorInspectorDecorationEntries + renderInspectorEntries) - the
    // Identity (Sprite / Keep colors / Color) + Footprint + Layers
    // sections, identical by construction (the 4-5d reuse).
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
        try std.testing.expectEqual(@as(usize, 3), section_strips);
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

test "hub editor inspector: the decoration arm emits the mission editor's exact content (the 4-5d identity contract)" {
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
    const test_metrics = ui_element.FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
    const button_color: Color = .{ .r = 50, .g = 50, .b = 50 };

    // The SAME definition (incl. a layer - a mission-live row class)
    // through both surfaces, with the same theme + view state: the
    // mission editor's own entries fn + renderer produce the hub's
    // decoration arm, so the emitted content must be identical
    // element-for-element. Any drift in either resolve half (button
    // color, panel rect, entries) breaks here.
    const footprint = [_]types.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } };
    const layers = [_]types.DecorationLayer{.{
        .sprite = "tree_grass_back",
        .color_index = 1,
        .pixel_dims = .{ .x = 512, .y = 256 },
    }};
    const decoration_types = [_]types.DecorationTypeDef{.{
        .id = "tree_2",
        .sprite = "tree_2",
        .footprint = &footprint,
        .pixel_dims = .{ .x = 512, .y = 256 },
        .color_index = 2,
        .layers = &layers,
    }};

    var ui_state = ui_state_mod.UiState{};

    // The mission editor's panel.
    const mission_editor: types.Editor = .{
        .decoration_types = &decoration_types,
        .active_tool = .{ .decoration_type = 0 },
    };
    var mission_elements: UiElementList = .empty;
    defer mission_elements.deinit(allocator);
    try editor_inspector.buildEditorInspectorPanel(
        &mission_elements,
        allocator,
        test_metrics,
        mission_editor,
        test_theme,
        true,
        &ui_state,
    );
    try ui_element.expectNoElementStraddlesRect(
        mission_elements.items,
        editor_inspector.editorInspectorPanelRect(),
    );

    // The hub editor drill-in's panel, over the campaign palette.
    const campaign_editor = types.CampaignEditor{
        .start_hub = 0,
        .hubs = &.{
            .{ .handle = 0, .name = "Alpha", .position = .{ .x = 0, .y = 0 }, .grid = .{} },
        },
        .decoration_types = &decoration_types,
        .next_handle = 1,
    };
    var hub_elements: UiElementList = .empty;
    defer hub_elements.deinit(allocator);
    try buildHubEditorInspector(
        &hub_elements,
        allocator,
        test_metrics,
        ui_element.screenRect(),
        campaign_editor,
        .{ .hub = 0, .active_tool = .{ .decoration_type = 0 } },
        test_theme,
        button_color,
        &ui_state,
    );
    try ui_element.expectNoElementStraddlesRect(
        hub_elements.items,
        editor_inspector.editorInspectorPanelRect(),
    );

    // Both wrappers are the toggle strip (panel + button + label) + the
    // background panel - 4 elements, differing by design (the toggle
    // action name, the panel's input blocking). Everything after must
    // match exactly (expectEqualDeep: value comparison - the emissions
    // build their own slices, so pointer identity does not hold).
    try std.testing.expect(mission_elements.items.len >= 5);
    try std.testing.expectEqual(mission_elements.items.len, hub_elements.items.len);
    for (mission_elements.items[4..], hub_elements.items[4..]) |mission_element, hub_element| {
        try std.testing.expectEqualDeep(mission_element, hub_element);
    }

    // The compared span is the real content, not a vacuous empty tail:
    // the identity children render (all sections expanded by default).
    var sprite_label_seen = false;
    for (mission_elements.items[4..]) |element| switch (element) {
        .text_label => |label| {
            if (std.mem.eql(u8, label.text, "Sprite")) sprite_label_seen = true;
        },
        else => {},
    };
    try std.testing.expect(sprite_label_seen);
}

test "buildHubSpritePicker layer mode: local cells match the base dims, add mode highlights nothing" {
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
    const test_metrics = ui_element.FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };

    // A 768x768 base + two hub-local PNGs: one matching, one not (a
    // layer must equal its base's dims - the load-time invariant).
    const campaign_editor = types.CampaignEditor{
        .start_hub = 0,
        .hubs = &.{.{ .handle = 0, .name = "Alpha", .position = .{ .x = 0, .y = 0 }, .grid = .{} }},
        .decoration_types = &.{.{
            .id = "tree_1",
            .sprite = "tree_1",
            .footprint = &.{.{ .x = 0, .y = 2 }},
            .pixel_dims = .{ .x = 768, .y = 768 },
        }},
        .next_handle = 1,
    };
    const hub_sprites = [_]state.MissionSprite{
        .{ .file_name = "moss.png", .stored_id = "custom/campaigns/c/hubs/h/moss", .pixel_dims = .{ .x = 768, .y = 768 } },
        .{ .file_name = "bush.png", .stored_id = "custom/campaigns/c/hubs/h/bush", .pixel_dims = .{ .x = 512, .y = 256 } },
    };
    var ui_state = ui_state_mod.UiState{};

    // Layer-ADD mode (a null layer index): the local tab offers only the
    // matching sprite; the mismatch is counted in the hidden note;
    // nothing is highlighted (no current layer).
    {
        var elements: UiElementList = .empty;
        defer elements.deinit(allocator);
        try buildHubSpritePicker(
            &elements,
            allocator,
            test_metrics,
            campaign_editor,
            .{ .hub = 0, .active_tool = .{ .decoration_type = 0 }, .picker = .{ .decoration_layer = null } },
            &hub_sprites,
            &.{},
            test_theme,
            &ui_state,
        );
        var pick_buttons: usize = 0;
        var highlighted: usize = 0;
        var hidden_note_seen = false;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .select_editor_decoration_layer) {
                    pick_buttons += 1;
                    if (button.highlighted) highlighted += 1;
                }
            },
            .text_label => |label| {
                if (std.mem.indexOf(u8, label.text, "1 sprites hidden - layer art must match the base sprite's dims") != null) {
                    hidden_note_seen = true;
                }
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 1), pick_buttons);
        try std.testing.expectEqual(@as(usize, 0), highlighted);
        try std.testing.expect(hidden_note_seen);
    }

    // Layer-EDIT mode (index 0 over a one-layer def): the edited layer's
    // sprite is the highlight target.
    {
        const layers = [_]types.DecorationLayer{.{
            .sprite = "custom/campaigns/c/hubs/h/moss",
            .color_index = 1,
            .pixel_dims = .{ .x = 768, .y = 768 },
        }};
        var campaign_with_layer = campaign_editor;
        var types_with_layer = [_]types.DecorationTypeDef{campaign_editor.decoration_types[0]};
        types_with_layer[0].layers = &layers;
        campaign_with_layer.decoration_types = &types_with_layer;
        var elements: UiElementList = .empty;
        defer elements.deinit(allocator);
        try buildHubSpritePicker(
            &elements,
            allocator,
            test_metrics,
            campaign_with_layer,
            .{ .hub = 0, .active_tool = .{ .decoration_type = 0 }, .picker = .{ .decoration_layer = 0 } },
            &hub_sprites,
            &.{},
            test_theme,
            &ui_state,
        );
        var highlighted: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .select_editor_decoration_layer and button.highlighted) highlighted += 1;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 1), highlighted);
    }
}

test "buildHubEditorMetadataSidebar: the mission's own rows over the drilled hub - name field, three gradients, the Auto toggles" {
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
    var gradients: [3]types.ColorGradient = undefined;
    for (&gradients, 0..) |*gradient, index| {
        const value: u8 = @intCast(index * 40 + 10);
        gradient.* = .{ .colors = @splat(types.Color{ .r = value, .g = value, .b = value }) };
    }
    const definitions: types.ColorThemeDefinitions = .{
        .lightest = .{ .r = 1, .g = 1, .b = 1 },
        .darkest = black,
        .gradients = &gradients,
    };
    const test_metrics = ui_element.FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };

    // The drilled hub: name + a picked wheel (2) + a manual enemy override
    // (1); the player override stays auto (the derived one).
    const campaign_editor = types.CampaignEditor{
        .start_hub = 0,
        .hubs = &.{.{
            .handle = 0,
            .name = "Alpha",
            .position = .{ .x = 0, .y = 0 },
            .grid = .{ .color_wheel_index = 2, .enemy_gradient_index = 1 },
        }},
        .next_handle = 1,
    };
    var ui_state = ui_state_mod.UiState{};

    // Open (the default): the toggle button, the Hub section strip, the
    // name field (the campaign hub-name identity over the drilled hub),
    // and the mission's own gradient rows.
    {
        var elements: UiElementList = .empty;
        defer elements.deinit(allocator);
        try buildHubEditorMetadataSidebar(
            &elements,
            allocator,
            test_metrics,
            campaign_editor,
            .{ .hub = 0 },
            test_theme,
            definitions,
            &ui_state,
        );
        var toggle_seen = false;
        var section_strips: usize = 0;
        var name_field_seen = false;
        var pick_buttons: usize = 0;
        var auto_buttons: usize = 0;
        var world_index_seen = false;
        var enemy_index_seen = false;
        for (elements.items) |element| switch (element) {
            .button => |button| switch (button.action) {
                .toggle_hub_metadata_sidebar => toggle_seen = true,
                .toggle_editor_inspector_section => section_strips += 1,
                .open_editor_level_gradient_picker => pick_buttons += 1,
                .toggle_editor_level_gradient_auto => auto_buttons += 1,
                else => {},
            },
            .text_field => |field| {
                if (field.ref.id == .campaign_hub_name) {
                    name_field_seen = true;
                    try std.testing.expectEqualStrings("Alpha", field.text);
                }
            },
            .text_label => |label| {
                if (std.mem.eql(u8, label.text, "2")) world_index_seen = true;
                if (std.mem.eql(u8, label.text, "1")) enemy_index_seen = true;
            },
            else => {},
        };
        try std.testing.expect(toggle_seen);
        try std.testing.expectEqual(@as(usize, 1), section_strips);
        try std.testing.expect(name_field_seen);
        try std.testing.expectEqual(@as(usize, 3), pick_buttons);
        try std.testing.expectEqual(@as(usize, 2), auto_buttons);
        // The effective indices render (world = the picked wheel; enemy =
        // the manual override).
        try std.testing.expect(world_index_seen);
        try std.testing.expect(enemy_index_seen);
    }

    // Collapsed: the strip alone (the mission sidebar's rule).
    {
        var elements: UiElementList = .empty;
        defer elements.deinit(allocator);
        try buildHubEditorMetadataSidebar(
            &elements,
            allocator,
            test_metrics,
            campaign_editor,
            .{ .hub = 0, .metadata_open = false },
            test_theme,
            definitions,
            &ui_state,
        );
        var toggle_seen = false;
        var name_field_seen = false;
        for (elements.items) |element| switch (element) {
            .button => |button| {
                if (button.action == .toggle_hub_metadata_sidebar) toggle_seen = true;
            },
            .text_field => name_field_seen = true,
            else => {},
        };
        try std.testing.expect(toggle_seen);
        try std.testing.expect(!name_field_seen);
    }
}
