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
const editor_shell = @import("editor_shell.zig");
const editor_inspector = @import("editor_inspector.zig");
const emit = @import("emit.zig");
const text_input = @import("text_input.zig");
const file_source = @import("../file_source.zig");

const UiElement = ui_element.UiElement;
const UiElementList = ui_element.UiElementList;
const Rectangle = types.Rectangle;
const Vector2 = types.Vector2;
const ScreenPosition = types.ScreenPosition;
const Color = types.Color;
const FontMetrics = ui_element.FontMetrics;
const text = ui_element.text;
const spanRow = ui_tooltip.spanRow;
const inspector = editor_inspector;

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

/// The sidebars' width (the editor inspector/metadata placeholder width
/// mirrored).
const sidebar_width: i32 = 1024;

/// The tool-cell graphic's native tile size (the editor shell's
/// convention).
const tool_graphic_tile_size: i32 = 256;

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

fn missionEnd(
    editor: types.CampaignEditor,
    hub_handle: ?u32,
    ghost_position: ?Vector2,
    drag_override: ?HubPositionOverride,
) MissionEnd {
    if (hub_handle) |handle| {
        if (drag_override) |override| {
            if (override.hub == handle) return .{ .hub = override.position };
        }
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
fn parallelSpread(
    editor: types.CampaignEditor,
    mission: types.CampaignMissionEdit,
    drag_override: ?HubPositionOverride,
) ParallelSpread {
    const from = missionEnd(editor, mission.start, mission.orphan_start_position, drag_override);
    const to = missionEnd(editor, mission.destination, mission.orphan_destination_position, drag_override);
    if (from != .hub or to != .hub) return .{ .index = 1, .count = 1 };
    var index: i32 = 0;
    var count: i32 = 0;
    for (editor.missions) |other| {
        const other_from = missionEnd(editor, other.start, other.orphan_start_position, drag_override);
        const other_to = missionEnd(editor, other.destination, other.orphan_destination_position, drag_override);
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
fn missionGeometry(
    editor: types.CampaignEditor,
    mission: types.CampaignMissionEdit,
    drag_override: ?HubPositionOverride,
) campaign_geometry.EdgeGeometry {
    const from = missionEnd(editor, mission.start, mission.orphan_start_position, drag_override);
    const to = missionEnd(editor, mission.destination, mission.orphan_destination_position, drag_override);

    if (mission.start != null and mission.destination != null and
        mission.start.? == mission.destination.? and
        from == .hub)
    {
        return deriveEdgeGeometry(from.hub, .self_loop, @intCast(effectiveDirection(editor, mission)), .{ .index = 1, .count = 1 });
    }
    if (to == .hub) {
        const from_position = if (from == .hub) from.hub else Vector2{ .x = 0, .y = 0 };
        return deriveEdgeGeometry(from_position, .{ .hub = to.hub }, 0, parallelSpread(editor, mission, drag_override));
    }
    const from_position = if (from == .hub) from.hub else Vector2{ .x = 0, .y = 0 };
    return deriveEdgeGeometry(from_position, .dangling, @intCast(effectiveDirection(editor, mission)), .{ .index = 1, .count = 1 });
}

/// Build the campaign editor's static view (see the file header).
/// The transient hub-drag preview: a promoted drag renders the pressed
/// hub (its icon + every edge deriving from its position) at the pointer's
/// live map position. Computed by view() from the session drag state +
/// pointer; pure view-side, never state.
pub const HubPositionOverride = struct {
    hub: u32,
    position: Vector2,
};

/// The transient map-view pan (the right-drag seam's offset, reference
/// px) applied to the fixed framing.
fn pannedMapToScreen(position: Vector2, pan: ?types.Vector2) ScreenPosition {
    const base = mapToScreen(position);
    const offset = pan orelse types.Vector2{ .x = 0, .y = 0 };
    return .{ .x = base.x + offset.x, .y = base.y + offset.y };
}

/// Build the campaign editor's view: the static map render (see the file
/// header) + the 3c surface shell - the tool palette (bottom), the hub
/// inspector (left), the metadata sidebar (right), the hub select buttons
/// (over the icons), and the transient pan offset. Pure over its inputs;
/// the pan + text-edit states are session-side (replay-irrelevant).
pub fn buildCampaignEditorView(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: ui_element.FontMetrics,
    screen: Rectangle,
    editor: types.CampaignEditor,
    active_theme: types.ActiveColorTheme,
    button_color: Color,
    pan: ?types.Vector2,
    text_edit: ?*const text_input.TextEditState,
    drag_override: ?HubPositionOverride,
    background_stems: []const []const u8,
) !void {
    // The surface: a full-screen dark fill - NON-blocking (a screen
    // background, not an overlay: map clicks must fall through to the
    // world-press path so `idle.map_clicked` survives; the panels +
    // buttons consume their own clicks).
    try elements.append(allocator, .{ .solid_rect = .{
        .screen_position = screen.position(),
        .width = screen.width,
        .height = screen.height,
        .color = active_theme.darkest,
        .blocks_input = false,
    } });

    // The background, native size, centered on the origin (panned with
    // the view). The stem mints into the content-addressed sprite id by
    // pure string math - the load-side minting rule.
    if (editor.background_stem.len > 0) {
        if (editor.background_dims) |dims| {
            const sprite_id = file_source.customStemForContentPath(
                editor.campaign_dir,
                editor.background_stem,
                allocator,
            );
            const center = pannedMapToScreen(.{ .x = 0, .y = 0 }, pan);
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

    // Hubs: an icon centered on each position (panned), ALL LIT (the
    // editor sees everything - no discovery dimming); the name rides the
    // tooltip. A spriteless button over each icon selects the hub - the
    // select + hub tools share the target (a hub-tool click on an
    // existing hub selects, never places; placing is the empty-canvas
    // click, resolved by the input layer).
    for (editor.hubs) |hub| {
        const hub_position = if (drag_override) |override|
            (if (override.hub == hub.handle) override.position else hub.position)
        else
            hub.position;
        const center = pannedMapToScreen(hub_position, pan);
        const icon_rect = Rectangle{
            .x = center.x - @divTrunc(hub_icon_size, 2),
            .y = center.y - @divTrunc(hub_icon_size, 2),
            .width = hub_icon_size,
            .height = hub_icon_size,
        };
        const tooltip: ?ui_element.Tooltip = .{ .header = try spanRow(allocator, text(hub.name)) };
        try elements.append(allocator, .{ .image = .{
            .sprite_id = hub_icon_sprite_id,
            .screen_position = icon_rect.position(),
            .width = hub_icon_size,
            .height = hub_icon_size,
            .blocks_input = false,
            .tooltip = tooltip,
        } });
        try elements.append(allocator, .{ .button = .{
            .sprite_id = null,
            .screen_position = icon_rect.position(),
            .width = hub_icon_size,
            .height = hub_icon_size,
            .action = .select_editor_campaign_hub,
            .payload = .{ .editor_campaign_hub = hub.handle },
            .highlighted = editor.selection == hub.handle,
            .tooltip = tooltip,
        } });
    }

    // Edges: one stroke pair per mission (black outline under the
    // lightest stroke), derived through the shared geometry (panned).
    // An orphaned mission (either end missing) renders GHOSTED (reduced
    // light-stroke alpha) from its frozen ghost positions. No click
    // targets yet - the mission inspector is 3d.
    const lightest = active_theme.lightest;
    for (editor.missions) |mission| {
        const geometry = missionGeometry(editor, mission, drag_override);
        const orphaned = mission.start == null or mission.destination == null;
        const pan_offset = pan orelse types.Vector2{ .x = 0, .y = 0 };

        try elements.append(allocator, .{ .curve = .{
            .start = .{ .x = geometry.start.x + pan_offset.x, .y = geometry.start.y + pan_offset.y },
            .control_start = .{ .x = geometry.control_start.x + pan_offset.x, .y = geometry.control_start.y + pan_offset.y },
            .control_end = .{ .x = geometry.control_end.x + pan_offset.x, .y = geometry.control_end.y + pan_offset.y },
            .end = .{ .x = geometry.end.x + pan_offset.x, .y = geometry.end.y + pan_offset.y },
            .width = edge_width + 2 * edge_outline_width,
            .color = black,
            .dashed = geometry.dashed,
            .arrowhead = true,
            .blocks_input = false,
        } });
        try elements.append(allocator, .{ .curve = .{
            .start = .{ .x = geometry.start.x + pan_offset.x, .y = geometry.start.y + pan_offset.y },
            .control_start = .{ .x = geometry.control_start.x + pan_offset.x, .y = geometry.control_start.y + pan_offset.y },
            .control_end = .{ .x = geometry.control_end.x + pan_offset.x, .y = geometry.control_end.y + pan_offset.y },
            .end = .{ .x = geometry.end.x + pan_offset.x, .y = geometry.end.y + pan_offset.y },
            .width = edge_width,
            .color = lightest,
            .alpha = if (orphaned) orphaned_alpha else 255,
            .dashed = geometry.dashed,
            .arrowhead = true,
            .blocks_input = false,
        } });
    }

    // The tool palette (bottom-left, the editor shell's visual class):
    // the campaign editor's map tools - select + hub (the mission tool
    // lands with 3d). One button cell per tool (ui/button_background
    // tinted, the ACTIVE tool highlighted), the graphic on top passing
    // hover through.
    {
        const bar_top = screen.y + screen.height - ui_element.bottom_bar_height;
        const cell_y = bar_top + @divFloor(ui_element.bottom_bar_height - ui_element.slot_size, 2);
        var cell_x = screen.x + ui_element.ui_gap;
        const cell = Rectangle{
            .x = cell_x,
            .y = cell_y,
            .width = ui_element.slot_size,
            .height = ui_element.slot_size,
        };
        // The select tool: the outlined-square graphic (the mission
        // editor's select cell).
        try elements.append(allocator, .{ .button = .{
            .sprite_id = emit.button_background_sprite_id,
            .screen_position = cell.position(),
            .width = cell.width,
            .height = cell.height,
            .action = .select_editor_campaign_tool,
            .payload = .{ .editor_campaign_tool = .select },
            .color = button_color,
            .highlighted = editor.active_tool == .select,
            .tooltip = .{ .header = try spanRow(allocator, text("Select")) },
        } });
        const fitted = editor_shell.scaleToFit(cell, tool_graphic_tile_size, tool_graphic_tile_size);
        const inset = @divFloor(fitted.width, 2 * 2);
        try elements.append(allocator, .{ .solid_rect = .{
            .screen_position = .{ .x = fitted.x + inset, .y = fitted.y + inset },
            .width = fitted.width - 2 * inset,
            .height = fitted.height - 2 * inset,
            .color = lightest,
            .filled = false,
            .line_width = types.outline_thickness,
            .blocks_input = false,
        } });
        cell_x += ui_element.slot_size + ui_element.ui_gap;
        // The hub tool: the hub-icon graphic.
        const hub_cell = Rectangle{
            .x = cell_x,
            .y = cell_y,
            .width = ui_element.slot_size,
            .height = ui_element.slot_size,
        };
        try elements.append(allocator, .{ .button = .{
            .sprite_id = emit.button_background_sprite_id,
            .screen_position = hub_cell.position(),
            .width = hub_cell.width,
            .height = hub_cell.height,
            .action = .select_editor_campaign_tool,
            .payload = .{ .editor_campaign_tool = .hub },
            .color = button_color,
            .highlighted = editor.active_tool == .hub,
            .tooltip = .{ .header = try spanRow(allocator, text("Place Hub")) },
        } });
        const hub_graphic = editor_shell.scaleToFit(hub_cell, tool_graphic_tile_size, tool_graphic_tile_size);
        try elements.append(allocator, .{ .image = .{
            .sprite_id = hub_icon_sprite_id,
            .screen_position = hub_graphic.position(),
            .width = hub_graphic.width,
            .height = hub_graphic.height,
            .blocks_input = false,
        } });
    }

    // The hub inspector (left sidebar): the selected hub's name field +
    // the start-hub toggle; empty when nothing is selected (no player
    // content - the hub editor is slice 4).
    {
        const panel = inspector.editorInspectorPanelRect();
        try elements.append(allocator, .{ .nine_slice_panel = .{
            .sprite_id = "ui/panel",
            .screen_position = panel.position(),
            .width = panel.width,
            .height = panel.height,
            .color = active_theme.darkest,
            .blocks_input = true,
        } });
        const content_x = panel.x + ui_element.ui_gap;
        const content_width = panel.width - 2 * ui_element.ui_gap;
        var row_y = panel.y + ui_element.ui_gap;
        try elements.append(allocator, .{ .text_label = .{
            .text = "Hub",
            .screen_position = .{ .x = content_x, .y = row_y },
            .font_size = editor_shell.editor_group_header_font_size,
            .color = lightest,
            .blocks_input = false,
        } });
        row_y += editor_shell.editor_header_strip_height;

        const selected_hub: ?types.CampaignHubEdit = blk: {
            const handle = editor.selection orelse break :blk null;
            for (editor.hubs) |hub| {
                if (hub.handle == handle) break :blk hub;
            }
            break :blk null;
        };

        if (selected_hub) |hub| {
            // The name field (a two-unit entry: label line + control).
            try elements.append(allocator, .{ .text_label = .{
                .text = "Name",
                .screen_position = .{
                    .x = content_x,
                    .y = row_y + editor_shell.editor_header_strip_height - editor_shell.editor_group_header_font_size,
                },
                .font_size = editor_shell.editor_group_header_font_size,
                .color = lightest,
                .blocks_input = false,
            } });
            const field_rect = Rectangle{
                .x = content_x,
                .y = row_y + editor_shell.editor_header_strip_height,
                .width = content_width,
                .height = editor_shell.editor_header_strip_height,
            };
            try inspector.emitTextFieldUi(
                elements,
                allocator,
                font_metrics,
                text_edit,
                .{ .id = .campaign_hub_name, .target = .{ .campaign_hub = hub.handle } },
                hub.name,
                field_rect,
                active_theme,
            );
            row_y += 2 * editor_shell.editor_header_strip_height;
            // The start-hub toggle: highlighted when this hub IS the
            // start hub (radio semantics; untoggling the current start
            // hub is vetoed at the consumption site).
            const toggle_rect = Rectangle{
                .x = content_x,
                .y = row_y,
                .width = content_width,
                .height = editor_shell.editor_header_strip_height,
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
                .action = .set_editor_campaign_start_hub,
                .payload = .{ .editor_campaign_hub = hub.handle },
                .highlighted = editor.start_hub == hub.handle,
            } });
            const is_start = editor.start_hub == hub.handle;
            try elements.append(allocator, .{ .text_label = .{
                .text = if (is_start) "Start Hub" else "Set as Start Hub",
                .screen_position = .{
                    .x = content_x + ui_element.ui_gap,
                    .y = row_y + @divFloor(
                        editor_shell.editor_header_strip_height - editor_shell.editor_group_header_font_size,
                        2,
                    ),
                },
                .font_size = editor_shell.editor_group_header_font_size,
                .color = .{ .r = 0, .g = 0, .b = 0 },
                .blocks_input = false,
            } });
        } else {
            try elements.append(allocator, .{ .text_label = .{
                .text = "No hub selected",
                .screen_position = .{ .x = content_x, .y = row_y },
                .font_size = editor_shell.editor_group_header_font_size,
                .color = lightest,
                .blocks_input = false,
            } });
        }
    }

    // The metadata sidebar (right): the campaign name field + the
    // background picker button.
    {
        const top = ui_element.top_bar_height + ui_element.ui_gap +
            editor_shell.editor_header_strip_height + ui_element.ui_gap;
        const bottom = screen.y + screen.height -
            ui_element.bottom_bar_height - 2 * ui_element.ui_gap -
            editor_shell.editor_header_strip_height;
        const panel = Rectangle{
            .x = screen.x + screen.width - sidebar_width,
            .y = top,
            .width = sidebar_width,
            .height = bottom - top,
        };
        try elements.append(allocator, .{ .nine_slice_panel = .{
            .sprite_id = "ui/panel",
            .screen_position = panel.position(),
            .width = panel.width,
            .height = panel.height,
            .color = active_theme.darkest,
            .blocks_input = true,
        } });
        const content_x = panel.x + ui_element.ui_gap;
        const content_width = panel.width - 2 * ui_element.ui_gap;
        var row_y = panel.y + ui_element.ui_gap;
        try elements.append(allocator, .{ .text_label = .{
            .text = "Campaign",
            .screen_position = .{ .x = content_x, .y = row_y },
            .font_size = editor_shell.editor_group_header_font_size,
            .color = lightest,
            .blocks_input = false,
        } });
        row_y += editor_shell.editor_header_strip_height;
        try elements.append(allocator, .{ .text_label = .{
            .text = "Name",
            .screen_position = .{
                .x = content_x,
                .y = row_y + editor_shell.editor_header_strip_height - editor_shell.editor_group_header_font_size,
            },
            .font_size = editor_shell.editor_group_header_font_size,
            .color = lightest,
            .blocks_input = false,
        } });
        const field_rect = Rectangle{
            .x = content_x,
            .y = row_y + editor_shell.editor_header_strip_height,
            .width = content_width,
            .height = editor_shell.editor_header_strip_height,
        };
        try inspector.emitTextFieldUi(
            elements,
            allocator,
            font_metrics,
            text_edit,
            .{ .id = .campaign_name, .target = .campaign },
            editor.campaign_name,
            field_rect,
            active_theme,
        );
        row_y += 2 * editor_shell.editor_header_strip_height;
        // The background button: opens the picker (the centered-picker
        // pattern); the label names the current stem (None when unset).
        const background_label = if (editor.background_stem.len > 0)
            try std.fmt.allocPrint(allocator, "Background: {s}", .{editor.background_stem})
        else
            "Background: None";
        try emit.emitPanelButton(
            elements,
            allocator,
            font_metrics,
            .{
                .x = content_x,
                .y = row_y,
                .width = content_width,
                .height = editor_shell.editor_header_strip_height,
            },
            background_label,
            editor_shell.editor_group_header_font_size,
            .open_campaign_background_picker,
            button_color,
            null,
        );
    }

    // The centered background picker (modal - emitted LAST, above every
    // editor surface): the None cell + one row per scanned stem, the
    // current stem highlighted. Rows are payload-carrying buttons (the
    // stem string) over tinted panels.
    if (editor.picker == .background) {
        const panel = inspector.editorPickerOverlayRect();
        try elements.append(allocator, .{ .nine_slice_panel = .{
            .sprite_id = "ui/panel",
            .screen_position = panel.position(),
            .width = panel.width,
            .height = panel.height,
            .color = active_theme.darkest,
            .blocks_input = true,
        } });
        try elements.append(allocator, .{ .text_label = .{
            .text = "Background",
            .screen_position = .{
                .x = panel.x + ui_element.ui_gap,
                .y = panel.y + ui_element.ui_gap,
            },
            .font_size = editor_shell.editor_group_header_font_size,
            .color = lightest,
            .blocks_input = false,
        } });

        // The None row first (clears the background - an empty payload),
        // then one row per scanned stem.
        var rows: std.ArrayList([]const u8) = .empty;
        rows.append(allocator, "") catch @panic("failed to append the picker's None row");
        rows.appendSlice(allocator, background_stems) catch @panic("failed to append the picker's stem rows");
        var row_y = panel.y + ui_element.ui_gap + editor_shell.editor_header_strip_height + ui_element.ui_gap;
        for (rows.items) |stem| {
            const row_rect = Rectangle{
                .x = panel.x + ui_element.ui_gap,
                .y = row_y,
                .width = panel.width - 2 * ui_element.ui_gap,
                .height = editor_shell.editor_header_strip_height,
            };
            const is_current = std.mem.eql(u8, stem, editor.background_stem);
            try elements.append(allocator, .{ .nine_slice_panel = .{
                .sprite_id = "ui/panel",
                .screen_position = row_rect.position(),
                .width = row_rect.width,
                .height = row_rect.height,
                .color = button_color,
                .blocks_input = false,
            } });
            try elements.append(allocator, .{ .button = .{
                .sprite_id = null,
                .screen_position = row_rect.position(),
                .width = row_rect.width,
                .height = row_rect.height,
                .action = .select_editor_campaign_background,
                .payload = .{ .editor_campaign_background = stem },
                .highlighted = is_current,
            } });
            try elements.append(allocator, .{ .text_label = .{
                .text = if (stem.len == 0) "None" else stem,
                .screen_position = .{
                    .x = row_rect.x + ui_element.ui_gap,
                    .y = row_rect.y + @divFloor(
                        editor_shell.editor_header_strip_height - editor_shell.editor_group_header_font_size,
                        2,
                    ),
                },
                .font_size = editor_shell.editor_group_header_font_size,
                .color = .{ .r = 0, .g = 0, .b = 0 },
                .blocks_input = false,
            } });
            row_y += editor_shell.editor_header_strip_height + ui_element.ui_gap;
        }

        // Back (close without picking).
        const back_rect = Rectangle{
            .x = panel.x + ui_element.ui_gap,
            .y = panel.y + panel.height - ui_element.ui_gap - editor_shell.editor_header_strip_height,
            .width = panel.width - 2 * ui_element.ui_gap,
            .height = editor_shell.editor_header_strip_height,
        };
        try emit.emitPanelButton(
            elements,
            allocator,
            font_metrics,
            back_rect,
            "Back",
            editor_shell.editor_group_header_font_size,
            .close_campaign_picker,
            button_color,
            null,
        );
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

const test_font_metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
const test_button_color = Color{ .r = 50, .g = 50, .b = 50 };
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
    try buildCampaignEditorView(
        &elements,
        arena.allocator(),
        test_font_metrics,
        ui_element.screenRect(),
        editor,
        test_theme,
        test_button_color,
        null,
        null,
        null,
        &.{},
    );

    // Derived total: the map (1 surface + 1 background + per hub an icon
    // + a select button + per mission 2 curves) + the tool palette (2
    // cells: button + graphic each) + the empty inspector (panel + header
    // + placeholder) + the metadata sidebar (panel + header + name label
    // + field + the 3-element background button).
    const selected_hub_content: usize = 0; // the fixture selects nothing
    const expected_total = 1 + 1 + 2 * editor.hubs.len + 2 * editor.missions.len +
        4 + (3 + selected_hub_content) + 7;
    try std.testing.expectEqual(expected_total, elements.items.len);

    // The map surface is the FIRST solid_rect - NON-blocking by design
    // (a screen background, not an overlay: map clicks fall through to
    // the press path; the select tool's outline graphic is an unfilled
    // solid_rect too). The PANELS block input instead.
    var surface_index: ?usize = null;
    for (elements.items, 0..) |element, index| {
        if (element == .solid_rect) {
            surface_index = index;
            break;
        }
    }
    try std.testing.expect(!elements.items[surface_index.?].solid_rect.blocks_input);
    var blocking_panels: usize = 0;
    for (elements.items) |element| switch (element) {
        .nine_slice_panel => |panel| {
            if (panel.blocks_input) blocking_panels += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 3), blocking_panels); // inspector + metadata + the background button's panel

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

test "buildCampaignEditorView: the selected-hub inspector - name field, start-hub toggle; the pan offset shifts the map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Selected hub 0 (Alpha - also the start hub): the inspector shows the
    // name field bound to the hub's handle + the highlighted start toggle.
    var editor = buildFixtureEditor();
    editor.selection = 0;
    var elements: UiElementList = .empty;
    defer elements.deinit(arena.allocator());
    try buildCampaignEditorView(
        &elements,
        arena.allocator(),
        test_font_metrics,
        ui_element.screenRect(),
        editor,
        test_theme,
        test_button_color,
        null,
        null,
        null,
        &.{},
    );

    var field_refs: usize = 0;
    var hub_name_field: ?ui_element.TextFieldUi = null;
    for (elements.items) |element| switch (element) {
        .text_field => |field| {
            field_refs += 1;
            if (field.ref.id == .campaign_hub_name) hub_name_field = field;
        },
        else => {},
    };
    // Two fields total (the hub name + the campaign name); the hub field
    // is bound to the selected hub's handle.
    try std.testing.expectEqual(@as(usize, 2), field_refs);
    try std.testing.expectEqual(@as(u32, 0), hub_name_field.?.ref.target.campaign_hub);

    // The start-hub toggle: highlighted on the start hub (radio readback).
    var start_toggle: ?ui_element.Button = null;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .set_editor_campaign_start_hub) {
            start_toggle = button;
        },
        else => {},
    };
    try std.testing.expect(start_toggle.?.highlighted);
    try std.testing.expectEqual(@as(u32, 0), start_toggle.?.payload.?.editor_campaign_hub);

    // The tool palette: two cells carrying the campaign tool payloads,
    // the active tool highlighted.
    var select_cell: ?ui_element.Button = null;
    var hub_cell: ?ui_element.Button = null;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .select_editor_campaign_tool) {
            if (button.payload.?.editor_campaign_tool == .select) select_cell = button;
            if (button.payload.?.editor_campaign_tool == .hub) hub_cell = button;
        },
        else => {},
    };
    try std.testing.expect(select_cell.?.highlighted);
    try std.testing.expect(!hub_cell.?.highlighted);

    // The hub select buttons: one per hub, the selected one highlighted.
    var hub_buttons: usize = 0;
    var highlighted_hubs: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .select_editor_campaign_hub) {
            hub_buttons += 1;
            if (button.highlighted) highlighted_hubs += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(editor.hubs.len, hub_buttons);
    try std.testing.expectEqual(@as(usize, 1), highlighted_hubs);

    // The pan offset shifts the whole map render: the same fixture with a
    // pan moves Alpha's icon by exactly the offset.
    var panned_elements: UiElementList = .empty;
    defer panned_elements.deinit(arena.allocator());
    try buildCampaignEditorView(
        &panned_elements,
        arena.allocator(),
        test_font_metrics,
        ui_element.screenRect(),
        editor,
        test_theme,
        test_button_color,
        .{ .x = 64, .y = -32 },
        null,
        null,
        &.{},
    );
    const alpha_icon = elements.items[try findHubIcon(elements.items, "Alpha")].image;
    const panned_alpha_icon = panned_elements.items[try findHubIcon(panned_elements.items, "Alpha")].image;
    try std.testing.expectEqual(alpha_icon.screen_position.x + 64, panned_alpha_icon.screen_position.x);
    try std.testing.expectEqual(alpha_icon.screen_position.y - 32, panned_alpha_icon.screen_position.y);
}

test "buildCampaignEditorView: the background picker - None + stems, current highlighted, Back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var editor = buildFixtureEditor();
    editor.picker = .background;
    editor.background_stem = "map";
    const stems = [_][]const u8{ "map", "sketch" };

    var elements: UiElementList = .empty;
    defer elements.deinit(arena.allocator());
    try buildCampaignEditorView(
        &elements,
        arena.allocator(),
        test_font_metrics,
        ui_element.screenRect(),
        editor,
        test_theme,
        test_button_color,
        null,
        null,
        null,
        &stems,
    );

    // One payload-carrying pick row per stem PLUS the None row (empty
    // payload); the current stem ("map") is highlighted, None + the other
    // are not.
    var pick_rows: usize = 0;
    var highlighted: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .select_editor_campaign_background) {
            pick_rows += 1;
            const stem = button.payload.?.editor_campaign_background;
            const is_current = std.mem.eql(u8, stem, "map");
            if (is_current != button.highlighted) return error.TestUnexpectedResult;
            if (button.highlighted) highlighted += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1 + stems.len), pick_rows);
    try std.testing.expectEqual(@as(usize, 1), highlighted);

    // Back fires the picker close.
    var back_buttons: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .close_campaign_picker) {
            back_buttons += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), back_buttons);
}
