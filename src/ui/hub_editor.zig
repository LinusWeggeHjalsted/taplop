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
    const decoration_count = campaign_editor.decoration_types.len;
    const decorations_group_width = header_font * 2 + 2 * ui_element.ui_gap + editor_shell.editor_plus_size + ui_element.ui_gap +
        @as(i32, @intCast(decoration_count)) * (ui_element.slot_size + ui_element.ui_gap);
    const content_width = 2 * ui_element.slot_size + 3 * ui_element.ui_gap +
        npc_group_width + missions_group_width + decorations_group_width;
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

    // The Decorations group: the CAMPAIGN-SHARED palette (one cell per
    // type, the base sprite tinted like the mission editor's cells) + the
    // "+" add-new cell (the default template; the sprite/footprint
    // pickers + the type inspector land with 4-5b, so a fresh type keeps
    // its default art until then).
    {
        row.advance(ui_element.ui_gap);
        const header_width = header_font * 2 + 2 * ui_element.ui_gap;
        try elements.append(allocator, .{ .text_label = .{
            .text = "Decorations",
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

        // The "+" cell (the mission palette's shape - a square panel cell
        // above the bar, adjacent to the header).
        {
            const plus_cell = Rectangle{
                .x = bar.x + row.cursor_x,
                .y = screen.bottom() - editor_shell.editor_header_strip_height,
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
            try elements.append(allocator, .{ .text_label = .{
                .text = "+",
                .screen_position = plus_cell.placeCenter(font_metrics.measureSpanWidth(text("+"), header_font), header_font).position(),
                .font_size = header_font,
                .color = active_theme.lightest,
                .blocks_input = false,
            } });
            row.advance(editor_shell.editor_plus_size);
        }

        for (campaign_editor.decoration_types, 0..) |type_definition, type_id| {
            const cell = row.next(ui_element.slot_size);
            try elements.append(allocator, .{ .button = .{
                .sprite_id = emit.button_background_sprite_id,
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .action = .select_hub_tool,
                .payload = .{ .hub_tool = .{ .decoration_type = @intCast(type_id) } },
                .color = button_color,
                .highlighted = std.meta.eql(hub_editor.active_tool, .{ .decoration_type = @intCast(type_id) }),
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

            // The delete button (the mission palette's shape: a small
            // corner cell over the tool cell, the hub_tool payload).
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
                .payload = .{ .hub_tool = .{ .decoration_type = @intCast(type_id) } },
                .tooltip = .{ .header = try spanRow(allocator, text("Delete this decoration type (and its placements in every hub)")) },
            } });
            try elements.append(allocator, .{ .text_label = .{
                .text = "X",
                .screen_position = delete_cell.placeCenter(font_metrics.measureSpanWidth(text("X"), header_font), header_font).position(),
                .font_size = header_font,
                .color = active_theme.lightest,
                .blocks_input = false,
            } });
        }
    }
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
    // editor's tool-driven content rule). The sprite row is read-only
    // text until the sprite picker lands (4-5c); the keep-colors toggle +
    // the swatches are the live granular edits.
    if (hub_editor.active_tool == .decoration_type) {
        const type_id = hub_editor.active_tool.decoration_type;
        if (type_id >= campaign_editor.decoration_types.len) return;
        const type_definition = campaign_editor.decoration_types[type_id];
        const world = active_theme.world_gradient.colors;

        var y = content.y;
        try elements.append(allocator, .{ .text_label = .{
            .text = "Decoration",
            .screen_position = .{ .x = content.x, .y = y },
            .font_size = font,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });
        y += font + ui_element.ui_gap;
        try elements.append(allocator, .{ .text_label = .{
            .text = type_definition.sprite,
            .screen_position = .{ .x = content.x, .y = y },
            .font_size = font,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });
        y += font + ui_element.ui_gap;

        // The keep-colors toggle (a plain panel-button row).
        {
            const toggle_rect = Rectangle{
                .x = content.x,
                .y = y,
                .width = content.width,
                .height = 2 * editor_shell.editor_header_strip_height,
            };
            try elements.append(allocator, .{ .nine_slice_panel = .{
                .sprite_id = "ui/panel",
                .screen_position = toggle_rect.position(),
                .width = toggle_rect.width,
                .height = toggle_rect.height,
                .color = button_color,
                .blocks_input = false,
            } });
            try elements.append(allocator, .{ .button = .{
                .sprite_id = null,
                .screen_position = toggle_rect.position(),
                .width = toggle_rect.width,
                .height = toggle_rect.height,
                .action = .toggle_hub_decoration_keep_original_colors,
            } });
            const toggle_label = if (type_definition.keep_original_colors)
                "Keep colors: on"
            else
                "Keep colors: off";
            try elements.append(allocator, .{ .text_label = .{
                .text = toggle_label,
                .screen_position = .{
                    .x = toggle_rect.x + ui_element.ui_gap,
                    .y = toggle_rect.y + @divTrunc(toggle_rect.height - font, 2),
                },
                .font_size = font,
                .color = active_theme.lightest,
                .blocks_input = false,
            } });
            y += 2 * editor_shell.editor_header_strip_height + ui_element.ui_gap;
        }

        // The swatch row (hidden while the flag is on - the mission
        // editor's rule: a dead tint control under an untinted type
        // confuses more than it informs).
        if (!type_definition.keep_original_colors) {
            try elements.append(allocator, .{ .text_label = .{
                .text = "Color",
                .screen_position = .{ .x = content.x, .y = y },
                .font_size = font,
                .color = active_theme.lightest,
                .blocks_input = false,
            } });
            y += font + ui_element.ui_gap;
            const swatch_size = editor_shell.editor_header_strip_height;
            var swatch_row = Row.init(.{ .x = content.x, .y = y }, swatch_size, ui_element.ui_gap);
            for (world, 0..) |swatch_color, color_index| {
                const swatch_cell = swatch_row.next(swatch_size);
                try elements.append(allocator, .{ .nine_slice_panel = .{
                    .sprite_id = "ui/panel",
                    .screen_position = swatch_cell.position(),
                    .width = swatch_size,
                    .height = swatch_size,
                    .color = swatch_color,
                    .blocks_input = false,
                } });
                try elements.append(allocator, .{ .button = .{
                    .sprite_id = null,
                    .screen_position = swatch_cell.position(),
                    .width = swatch_size,
                    .height = swatch_size,
                    .action = .set_hub_decoration_color,
                    .payload = .{ .editor_color = @intCast(color_index) },
                    .highlighted = type_definition.color_index == color_index,
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
        .button => |button| switch (button.payload orelse continue) {
            .hub_tool => |tool| switch (tool) {
                .select => select_cell = button,
                .tile => tile_cell = button,
                .npc => npc_cells += 1,
                .mission => mission_cells += 1,
                .decoration_type => {},
            },
            else => {},
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

    // The single selected exit marker: the read-only summary (mission
    // name + destination hub name).
    {
        var elements: UiElementList = .empty;
        defer elements.deinit(allocator);
        try buildHubEditorInspector(&elements, allocator, test_metrics, ui_element.screenRect(), campaign_editor, .{ .hub = 0, .selection = &.{.{ .exit_placement = 0 }} }, test_theme, button_color);
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
        try buildHubEditorInspector(&elements, allocator, test_metrics, ui_element.screenRect(), campaign_editor, .{ .hub = 0, .selection = &.{.{ .npc_placement = 0 }} }, test_theme, button_color);
        try std.testing.expect(findLabel(elements.items, "NPC") != null);
        try std.testing.expect(findLabel(elements.items, "Interaction semantics land with NPC interaction") != null);
    }

    // No selection (and a multi-selection): the empty default - no
    // content labels beyond the strip's own.
    {
        var elements: UiElementList = .empty;
        defer elements.deinit(allocator);
        try buildHubEditorInspector(&elements, allocator, test_metrics, ui_element.screenRect(), campaign_editor, .{ .hub = 0 }, test_theme, button_color);
        try std.testing.expect(findLabel(elements.items, "Exit Marker") == null);
        try std.testing.expect(findLabel(elements.items, "NPC") == null);
    }

    // Closed: the strip alone.
    {
        var elements: UiElementList = .empty;
        defer elements.deinit(allocator);
        try buildHubEditorInspector(&elements, allocator, test_metrics, ui_element.screenRect(), campaign_editor, .{ .hub = 0, .inspector_open = false }, test_theme, button_color);
        try std.testing.expect(findToggle(elements.items) != null);
        var panel_count: usize = 0;
        for (elements.items) |element| switch (element) {
            .nine_slice_panel => panel_count += 1,
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 1), panel_count); // the strip's own panel only
    }
}
