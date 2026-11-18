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
const ui_state_mod = @import("state.zig");

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
const UiState = ui_state_mod.UiState;

const mapToScreen = campaign_geometry.mapToScreen;
const deriveEdgeGeometry = campaign_geometry.deriveEdgeGeometry;
const EdgeEndpoint = campaign_geometry.EdgeEndpoint;
const ParallelSpread = campaign_geometry.ParallelSpread;
const edge_width = campaign_geometry.edge_width;
const edge_outline_width = campaign_geometry.edge_outline_width;
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

/// The mission tool's palette graphic: the drawn-edge arrow's length
/// (reference px, horizontal, pointing right - the preview's arrow at
/// rest).
const mission_tool_arrow_length: i32 = 128;

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
/// The campaign editor's top-right primary action: the Validate button
/// (save first, then certify the saved files - the graph findings +
/// every mission's validation replay). The mission editor's
/// `buildEditorPrimaryActions` pattern at its Validate cell exactly
/// (flush against the right screen edge, the options/undo icon class);
/// no Test button - there is nothing to play in a campaign, and no Save
/// button (ctrl+S + the options menu are the save paths). The global
/// top bar hides its tips `?` button on this screen for the same reason
/// as on the mission editor: the top-right corner is the primary-actions
/// spot. See DESIGN → The campaign editor surface (Validation).
pub fn buildCampaignEditorPrimaryActions(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    active_theme: types.ActiveColorTheme,
) !void {
    const p = active_theme.player_gradient.colors;
    // Match the top-bar options/undo buttons: background = gradient[5],
    // icon = gradient[1] (the mission editor's primary-actions treatment).
    const c_btn_bg = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
    const c_btn_icon = p[@min(@as(u32, 1), types.gradient_color_count - 1)];

    const validate_cell: Rectangle = .{
        .x = types.reference_width - ui_element.top_bar_slot_size,
        .y = 0,
        .width = ui_element.top_bar_slot_size,
        .height = ui_element.top_bar_slot_size,
    };

    try emit.emitIconButton(
        elements,
        allocator,
        validate_cell,
        emit.small_button_background_sprite_id,
        "ui/icon_validate",
        .validate_campaign,
        .{ .header = try spanRow(allocator, text("Validate (save + check the whole campaign)")) },
        c_btn_bg,
        c_btn_icon,
        false,
        null,
    );
}

/// The hub inspector's entries: the Hub section (collapsed by default -
/// the mission editor's convention) holding the selected hub's name
/// field, the start-hub radio, and the hub-editor drill-in. Rendered by
/// the shared renderInspectorEntries (windowing + scroll + scrollbar).
fn campaignHubInspectorEntries(
    allocator: std.mem.Allocator,
    editor: types.CampaignEditor,
    hub: types.CampaignHubEdit,
    section_expanded: []const bool,
) ![]const editor_inspector.EditorInspectorEntry {
    var entries: std.ArrayList(editor_inspector.EditorInspectorEntry) = .empty;
    errdefer entries.deinit(allocator);
    try entries.append(allocator, .{ .section = .campaign_hub });
    if (!section_expanded[@backingInt(types.EditorInspectorSectionId.campaign_hub)]) {
        return entries.toOwnedSlice(allocator);
    }
    // The name field (the sidebar's two-unit entry: label line +
    // control).
    try entries.append(allocator, .{ .field = .{
        .label = "Name",
        .control = .{ .text_field = .{
            .ref = .{ .id = .campaign_hub_name, .target = .{ .campaign_hub = hub.handle } },
            .value = hub.name,
        } },
    } });
    // The start-hub radio: the label carries the start state (the radio
    // readback); the untoggle case is vetoed at the consumption site.
    const toggle_label: []const u8 = if (editor.start_hub == hub.handle)
        "Start Hub (toggle another to move)"
    else
        "Set as Start Hub";
    try entries.append(allocator, .{ .field = .{
        .label = "Start Hub",
        .control = .{ .action_button = .{
            .label = toggle_label,
            .action = .set_editor_campaign_start_hub,
            .payload = .{ .editor_campaign_hub = hub.handle },
        } },
    } });
    // The drill-in (the slice-4 open): the handle rides the payload.
    try entries.append(allocator, .{ .field = .{
        .label = "Drill-in",
        .control = .{ .action_button = .{
            .label = "Open Hub Editor",
            .action = .open_hub_editor,
            .payload = .{ .editor_campaign_hub = hub.handle },
        } },
    } });
    return entries.toOwnedSlice(allocator);
}

/// The mission inspector's entries: the Mission section holding the
/// selected mission's name + direction fields, the two re-attach rows,
/// the import affordance, and the mission-editor drill-in (the
/// hand-off - DESIGN → The mission-editor hand-off). Rendered by the
/// shared renderInspectorEntries.
fn campaignMissionInspectorEntries(
    allocator: std.mem.Allocator,
    editor: types.CampaignEditor,
    mission: types.CampaignMissionEdit,
    reattach_end: ?types.CampaignMissionEnd,
    section_expanded: []const bool,
) ![]const editor_inspector.EditorInspectorEntry {
    var entries: std.ArrayList(editor_inspector.EditorInspectorEntry) = .empty;
    errdefer entries.deinit(allocator);
    try entries.append(allocator, .{ .section = .campaign_mission });
    if (!section_expanded[@backingInt(types.EditorInspectorSectionId.campaign_mission)]) {
        return entries.toOwnedSlice(allocator);
    }
    try entries.append(allocator, .{ .field = .{
        .label = "Name",
        .control = .{ .text_field = .{
            .ref = .{ .id = .campaign_mission_name, .target = .{ .campaign_mission = mission.handle } },
            .value = mission.name,
        } },
    } });
    // The direction field (self-loops + dangling stubs; empty = the
    // auto-spread default).
    const direction_value: []const u8 = if (mission.direction) |direction|
        try std.fmt.allocPrint(allocator, "{d}", .{direction})
    else
        "";
    try entries.append(allocator, .{ .field = .{
        .label = "Direction",
        .control = .{ .text_field = .{
            .ref = .{ .id = .campaign_mission_direction, .target = .{ .campaign_mission = mission.handle } },
            .value = direction_value,
        } },
    } });
    // The re-attach rows: each end's control button names the attached
    // hub (or Unattached); entering the pick-mode prompts for the hub
    // click.
    for ([_]struct {
        end: types.CampaignMissionEnd,
        label: []const u8,
        action: types.Action,
    }{
        .{ .end = .start, .label = "Start Hub", .action = .reattach_campaign_mission_start },
        .{ .end = .destination, .label = "End Hub", .action = .reattach_campaign_mission_destination },
    }) |row| {
        const attached: ?u32 = if (row.end == .start) mission.start else mission.destination;
        var attached_name: []const u8 = "Unattached - click to attach";
        if (attached) |handle| {
            for (editor.hubs) |candidate_hub| {
                if (candidate_hub.handle == handle) attached_name = candidate_hub.name;
            }
        }
        if (reattach_end) |armed_end| {
            if (armed_end == row.end) attached_name = "Click a hub on the map...";
        }
        try entries.append(allocator, .{ .field = .{
            .label = row.label,
            .control = .{ .action_button = .{
                .label = attached_name,
                .action = row.action,
                .payload = null,
            } },
        } });
    }
    // The hand-off entry (the Open Hub Editor twin): the return button +
    // the save target are the only differences (DESIGN → The
    // mission-editor hand-off). ABOVE the import affordance - the
    // more-used action reads first when scrolled.
    try entries.append(allocator, .{ .field = .{
        .label = "Drill-in",
        .control = .{ .action_button = .{
            .label = "Open Mission Editor",
            .action = .open_mission_editor,
            .payload = .{ .editor_campaign_mission = mission.handle },
        } },
    } });
    // The import affordance (a picked import lands UNWIRED and selected -
    // the author re-attaches it).
    try entries.append(allocator, .{ .field = .{
        .label = "Import",
        .control = .{ .action_button = .{
            .label = "Import Mission",
            .action = .open_campaign_import_picker,
            .payload = null,
        } },
    } });
    return entries.toOwnedSlice(allocator);
}

/// The session-side inputs to buildCampaignEditorView - everything the
/// pure builder reads beyond the authored state. An options struct (the
/// settled no-default-params answer - see TODO → Tech Debt, the
/// GameStateHistory.init item) so test call sites pass `.{}`-shaped
/// literals instead of eight positional nulls.
pub const CampaignEditorViewOptions = struct {
    /// The transient right-drag pan offset (session-side,
    /// replay-irrelevant).
    pan: ?types.Vector2 = null,
    /// The focused text field, if one is being edited (the metadata
    /// sidebar reads it; the inspector's shared renderer re-derives its
    /// own from `ui_state`).
    text_edit: ?*const text_input.TextEditState = null,
    /// The hub-drag preview override (the pointer gesture's live state).
    drag_override: ?HubPositionOverride = null,
    /// The campaign's own PNG stems, for the background picker's rows
    /// (session-side scan).
    background_stems: []const []const u8 = &.{},
    /// The mission tool's armed draw (the start hub handle), for the
    /// arrow preview.
    mission_draw: ?u32 = null,
    /// The pointer's live map position (the preview's target end).
    pointer_map_position: ?Vector2 = null,
    /// The active re-attach pick's end (the button labels' hint state).
    reattach_end: ?types.CampaignMissionEnd = null,
    /// The local-mission list (the import picker's rows - session-side
    /// scan).
    local_missions: []const file_source.FileSource.MissionEntry = &.{},
    /// The session's UI state - the shared inspector renderer's inputs
    /// (scroll offset + section expansion); it clamps the scroll in
    /// place.
    ui_state: *UiState,
};

pub fn buildCampaignEditorView(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: ui_element.FontMetrics,
    screen: Rectangle,
    editor: types.CampaignEditor,
    active_theme: types.ActiveColorTheme,
    button_color: Color,
    options: CampaignEditorViewOptions,
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
            const center = pannedMapToScreen(.{ .x = 0, .y = 0 }, options.pan);
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
        const hub_position = if (options.drag_override) |override|
            (if (override.hub == hub.handle) override.position else hub.position)
        else
            hub.position;
        const center = pannedMapToScreen(hub_position, options.pan);
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
            .highlighted = editor.selection != null and
                editor.selection.? == .hub and
                editor.selection.?.hub == hub.handle,
            .tooltip = tooltip,
        } });
    }

    // Edges: one baked-arrow arrow per mission (the outline baked into
    // the texture), derived through the shared geometry (panned).
    // An orphaned mission (either end missing) renders GHOSTED (reduced
    // alpha) from its frozen ghost positions. The edge
    // click targets + the selection rim live in the loop below.
    const lightest = active_theme.lightest;
    for (editor.missions) |mission| {
        const geometry = missionGeometry(editor, mission, options.drag_override);
        const orphaned = mission.start == null or mission.destination == null;
        const pan_offset = options.pan orelse types.Vector2{ .x = 0, .y = 0 };
        const panned = campaign_geometry.EdgeGeometry{
            .start = .{ .x = geometry.start.x + pan_offset.x, .y = geometry.start.y + pan_offset.y },
            .control_start = .{ .x = geometry.control_start.x + pan_offset.x, .y = geometry.control_start.y + pan_offset.y },
            .control_end = .{ .x = geometry.control_end.x + pan_offset.x, .y = geometry.control_end.y + pan_offset.y },
            .end = .{ .x = geometry.end.x + pan_offset.x, .y = geometry.end.y + pan_offset.y },
        };

        // The select tool's click target over the DRAWN arrow (the world
        // map's hit_arrow seam: the hit region IS the drawn stroke, so
        // they cannot disagree). Emitted under the select tool (the
        // mission tool's surface is the draw gesture; the hub tool's is
        // placement), PLUS for the SELECTED mission under any tool: the
        // selection rim is what shows the inspector's focus on the map,
        // and placement selects (the last-placed-object rule) - a
        // just-placed edge must highlight immediately, mid-mission-tool.
        const selected_mission = editor.selection != null and
            editor.selection.? == .mission and
            editor.selection.?.mission == mission.handle;
        if (editor.active_tool == .select or selected_mission) {
            const hit_arrow = ui_element.Arrow{
                .start = panned.start,
                .control_start = panned.control_start,
                .control_end = panned.control_end,
                .end = panned.end,
                .width = edge_width + 2 * edge_outline_width,
            };
            const bounds = ui_element.arrowBounds(hit_arrow);
            try elements.append(allocator, .{ .button = .{
                .sprite_id = null,
                .screen_position = bounds.position(),
                .width = bounds.width,
                .height = bounds.height,
                .action = .select_editor_campaign_mission,
                .payload = .{ .editor_campaign_mission = mission.handle },
                .highlighted = selected_mission,
                .hit_arrow = hit_arrow,
                .tooltip = .{ .header = try spanRow(allocator, text(mission.name)) },
            } });
        }

        // The drawn edge: ONE arrow at the outline-inclusive width
        // carrying the color + orphan-ghost state (the baked-arrow
        // rendering - see campaign_geometry's baked-arrow section; the
        // backend falls back to the per-segment draw outside the cache
        // families).
        try elements.append(allocator, .{ .arrow = .{
            .start = panned.start,
            .control_start = panned.control_start,
            .control_end = panned.control_end,
            .end = panned.end,
            .width = edge_width + 2 * edge_outline_width,
            .color = lightest,
            .alpha = if (orphaned) orphaned_alpha else 255,
            .blocks_input = false,
        } });
    }

    // The mission tool's arrow PREVIEW: an armed draw renders the arrow
    // from the armed start hub toward the pointer's live map position
    // (transient, view-side - the stroke pair, no click target).
    if (options.mission_draw) |start_handle| {
        if (options.pointer_map_position) |cursor| {
            if (editor.active_tool == .mission) {
                var start_position = Vector2{ .x = 0, .y = 0 };
                for (editor.hubs) |hub| {
                    if (hub.handle == start_handle) start_position = hub.position;
                }
                const preview_geometry = deriveEdgeGeometry(
                    start_position,
                    .{ .hub = cursor },
                    0,
                    .{ .index = 1, .count = 1 },
                );
                const pan_offset = options.pan orelse types.Vector2{ .x = 0, .y = 0 };
                // One baked-arrow arrow (the drag preview re-bakes per
                // 8px length bucket - a straight bake is ~3 segments of
                // pixel math, trivially cheap).
                try elements.append(allocator, .{ .arrow = .{
                    .start = .{ .x = preview_geometry.start.x + pan_offset.x, .y = preview_geometry.start.y + pan_offset.y },
                    .control_start = .{ .x = preview_geometry.control_start.x + pan_offset.x, .y = preview_geometry.control_start.y + pan_offset.y },
                    .control_end = .{ .x = preview_geometry.control_end.x + pan_offset.x, .y = preview_geometry.control_end.y + pan_offset.y },
                    .end = .{ .x = preview_geometry.end.x + pan_offset.x, .y = preview_geometry.end.y + pan_offset.y },
                    .width = edge_width + 2 * edge_outline_width,
                    .color = lightest,
                    .blocks_input = false,
                } });
            }
        }
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
        const hub_graphic = hub_cell.placeCenter(128, 128);
        try elements.append(allocator, .{ .image = .{
            .sprite_id = hub_icon_sprite_id,
            .screen_position = hub_graphic.position(),
            .width = hub_graphic.width,
            .height = hub_graphic.height,
            .blocks_input = false,
        } });
        cell_x += ui_element.slot_size + ui_element.ui_gap;
        // The mission tool: the EDGE ARROW graphic - the drawn-edge visual
        // (a 128px-long stroke pair pointing right, the preview's arrow at
        // rest), not a sprite: the flag sheet renders as broken lines in
        // a cell.
        const mission_cell = Rectangle{
            .x = cell_x,
            .y = cell_y,
            .width = ui_element.slot_size,
            .height = ui_element.slot_size,
        };
        try elements.append(allocator, .{ .button = .{
            .sprite_id = emit.button_background_sprite_id,
            .screen_position = mission_cell.position(),
            .width = mission_cell.width,
            .height = mission_cell.height,
            .action = .select_editor_campaign_tool,
            .payload = .{ .editor_campaign_tool = .mission },
            .color = button_color,
            .highlighted = editor.active_tool == .mission,
            .tooltip = .{ .header = try spanRow(allocator, text("Draw Mission Edge")) },
        } });
        const arrow_center_x = mission_cell.x + @divFloor(mission_cell.width, 2);
        const arrow_center_y = mission_cell.y + @divFloor(mission_cell.height, 2);
        const arrow_start = types.ScreenPosition{
            .x = arrow_center_x - @divFloor(mission_tool_arrow_length, 2),
            .y = arrow_center_y,
        };
        const arrow_end = types.ScreenPosition{
            .x = arrow_center_x + @divFloor(mission_tool_arrow_length, 2),
            .y = arrow_center_y,
        };
        // A straight arrow: the control points on the segment at thirds.
        const arrow_control_start = types.ScreenPosition{
            .x = arrow_start.x + @divFloor(mission_tool_arrow_length, 3),
            .y = arrow_center_y,
        };
        const arrow_control_end = types.ScreenPosition{
            .x = arrow_start.x + @divFloor(2 * mission_tool_arrow_length, 3),
            .y = arrow_center_y,
        };
        // The palette cell's graphic (the map edge's look): one
        // baked-arrow arrow, the arrowhead at the right end.
        try elements.append(allocator, .{ .arrow = .{
            .start = arrow_start,
            .control_start = arrow_control_start,
            .control_end = arrow_control_end,
            .end = arrow_end,
            .width = edge_width + 2 * edge_outline_width,
            .color = lightest,
            .blocks_input = false,
        } });
    }

    // The hub inspector (left): the mission editor's EXACT shape - the
    // top-left toggle strip (always emitted, below the options button),
    // the panel + content only while open (open by default, the mission
    // editor's default). Content = the selected hub's or mission's
    // entries through the shared windowed renderer (below - the entries
    // builders); the panel is empty when nothing is selected.
    {
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
            .action = .toggle_campaign_inspector,
        } });
        try elements.append(allocator, .{ .text_label = .{
            .text = label,
            .screen_position = button_cell.placeCenter(label_width, editor_shell.editor_group_header_font_size).position(),
            .font_size = editor_shell.editor_group_header_font_size,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });

        if (editor.inspector_open) {
            const panel_rect = inspector.editorInspectorPanelRect();
            try elements.append(allocator, .{ .nine_slice_panel = .{
                .sprite_id = "ui/panel",
                .screen_position = panel_rect.position(),
                .width = panel_rect.width,
                .height = panel_rect.height,
                .color = active_theme.darkest,
                .blocks_input = true,
            } });

            const selected_hub: ?types.CampaignHubEdit = blk: {
                const selection = editor.selection orelse break :blk null;
                if (selection != .hub) break :blk null;
                for (editor.hubs) |hub| {
                    if (hub.handle == selection.hub) break :blk hub;
                }
                break :blk null;
            };

            const selected_mission: ?types.CampaignMissionEdit = blk: {
                const selection = editor.selection orelse break :blk null;
                if (selection != .mission) break :blk null;
                for (editor.missions) |mission| {
                    if (mission.handle == selection.mission) break :blk mission;
                }
                break :blk null;
            };

            const entries: []const editor_inspector.EditorInspectorEntry =
                if (selected_hub) |hub|
                    try campaignHubInspectorEntries(
                        allocator,
                        editor,
                        hub,
                        &options.ui_state.editor_inspector_section_expanded,
                    )
                else if (selected_mission) |mission|
                    try campaignMissionInspectorEntries(
                        allocator,
                        editor,
                        mission,
                        options.reattach_end,
                        &options.ui_state.editor_inspector_section_expanded,
                    )
                else
                    &[_]editor_inspector.EditorInspectorEntry{};
            // The shared windowed renderer (the mission editor's
            // inspector - the hub editor drill-in's precedent): row-unit
            // math + scroll clamp, windowed emission, the overflow
            // scrollbar.
            try inspector.renderInspectorEntries(
                elements,
                allocator,
                font_metrics,
                entries,
                .{ .button_color = strip_button_color },
                active_theme,
                options.ui_state,
            );
        }
    }

    // The metadata sidebar (right): the mission editor's EXACT shape - the
    // top-right toggle strip, the panel + content only while open (CLOSED
    // by default, the mission editor's default). Content = one collapsible
    // "Campaign" section holding the campaign name field + the background
    // picker button.
    {
        const p = active_theme.player_gradient.colors;
        const strip_button_color = p[@min(@as(u32, 5), types.gradient_color_count - 1)];
        const label = "Metadata";
        const label_width = font_metrics.measureSpanWidth(text(label), editor_shell.editor_group_header_font_size);
        const width = @max(label_width + 2 * ui_element.ui_gap, editor_shell.editor_header_strip_height);
        const button_cell = Rectangle{
            .x = screen.x + screen.width - width,
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
            .action = .toggle_campaign_metadata_sidebar,
        } });
        try elements.append(allocator, .{ .text_label = .{
            .text = label,
            .screen_position = button_cell.placeCenter(label_width, editor_shell.editor_group_header_font_size).position(),
            .font_size = editor_shell.editor_group_header_font_size,
            .color = active_theme.lightest,
            .blocks_input = false,
        } });

        if (!editor.metadata_sidebar_open) {
            // The picker overlay sits between the sidebar PANELS - a
            // constant rect (the pickers keep it regardless of open state,
            // the mission editor's rule); nothing else to emit.
        } else {
            const panel_rect = inspector.editorMetadataSidebarPanelRect();
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
            const campaign_section_expanded =
                options.ui_state.editor_inspector_section_expanded[@backingInt(types.EditorInspectorSectionId.campaign_metadata)];
            try inspector.emitInspectorSectionStrip(
                elements,
                allocator,
                .{ .x = content.x, .y = content.y, .width = content.width, .height = editor_shell.editor_header_strip_height },
                .campaign_metadata,
                campaign_section_expanded,
                strip_button_color,
                active_theme,
            );
            if (campaign_section_expanded) {
                try inspector.emitSidebarNameField(
                    elements,
                    allocator,
                    font_metrics,
                    options.text_edit,
                    .{ .id = .campaign_name, .target = .campaign },
                    editor.campaign_name,
                    .{
                        .x = content.x,
                        .y = content.y + editor_shell.editor_header_strip_height,
                        .width = content.width,
                        .height = 2 * editor_shell.editor_header_strip_height,
                    },
                    active_theme,
                );
                // The background button (a two-unit entry: label +
                // control): opens the picker; the label names the current
                // stem (None when unset).
                const background_entry_y = content.y + 3 * editor_shell.editor_header_strip_height;
                try elements.append(allocator, .{ .text_label = .{
                    .text = "Background",
                    .screen_position = .{
                        .x = content.x,
                        .y = background_entry_y + editor_shell.editor_header_strip_height -
                            editor_shell.editor_group_header_font_size,
                    },
                    .font_size = editor_shell.editor_group_header_font_size,
                    .color = active_theme.lightest,
                    .blocks_input = false,
                } });
                const background_label = if (editor.background_stem.len > 0)
                    try std.fmt.allocPrint(allocator, "{s}", .{editor.background_stem})
                else
                    "None";
                const background_rect = inspector.inspectorControlRect(.{
                    .x = content.x,
                    .y = background_entry_y,
                    .width = content.width,
                    .height = 2 * editor_shell.editor_header_strip_height,
                });
                try emit.emitPanelButton(
                    elements,
                    allocator,
                    font_metrics,
                    background_rect,
                    background_label,
                    editor_shell.editor_group_header_font_size,
                    .open_campaign_background_picker,
                    button_color,
                    null,
                );
            }
        }
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
        rows.appendSlice(allocator, options.background_stems) catch @panic("failed to append the picker's stem rows");
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
                .color = lightest,
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

    // The centered IMPORT picker (the second picker kind - the mission
    // inspector's Import): the player's local missions as rows (copy-at-
    // pick with the duplicate-uuid refusal at the consumption site), one
    // payload-carrying button per row (the mission dir), + Back. No
    // scroll v1 - the local collection is typically small (the windowing
    // machinery can ride the polish pass).
    if (editor.picker == .import_mission) {
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
            .text = "Import Mission",
            .screen_position = .{
                .x = panel.x + ui_element.ui_gap,
                .y = panel.y + ui_element.ui_gap,
            },
            .font_size = editor_shell.editor_group_header_font_size,
            .color = lightest,
            .blocks_input = false,
        } });
        var row_y = panel.y + ui_element.ui_gap + editor_shell.editor_header_strip_height + ui_element.ui_gap;
        for (options.local_missions) |entry| {
            const row_rect = Rectangle{
                .x = panel.x + ui_element.ui_gap,
                .y = row_y,
                .width = panel.width - 2 * ui_element.ui_gap,
                .height = editor_shell.editor_header_strip_height,
            };
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
                .action = .select_editor_campaign_import,
                .payload = .{ .editor_campaign_import = entry.id },
            } });
            const row_label = if (entry.name.len > 0) entry.name else entry.id;
            try elements.append(allocator, .{ .text_label = .{
                .text = row_label,
                .screen_position = .{
                    .x = row_rect.x + ui_element.ui_gap,
                    .y = row_rect.y + @divFloor(
                        editor_shell.editor_header_strip_height - editor_shell.editor_group_header_font_size,
                        2,
                    ),
                },
                .font_size = editor_shell.editor_group_header_font_size,
                .color = lightest,
                .blocks_input = false,
            } });
            row_y += editor_shell.editor_header_strip_height + ui_element.ui_gap;
        }
        const import_back_rect = Rectangle{
            .x = panel.x + ui_element.ui_gap,
            .y = panel.y + panel.height - ui_element.ui_gap - editor_shell.editor_header_strip_height,
            .width = panel.width - 2 * ui_element.ui_gap,
            .height = editor_shell.editor_header_strip_height,
        };
        try emit.emitPanelButton(
            elements,
            allocator,
            font_metrics,
            import_back_rect,
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

const test_section_count = @typeInfo(types.EditorInspectorSectionId).@"enum".field_names.len;

/// The sections' all-collapsed default (the mission editor's default).
const test_sections_collapsed = @as([test_section_count]bool, @splat(false));

/// The campaign sections expanded (the field-level assertions' state).
const test_sections_expanded: [test_section_count]bool = blk: {
    var sections: [test_section_count]bool = @splat(false);
    sections[@backingInt(types.EditorInspectorSectionId.campaign_hub)] = true;
    sections[@backingInt(types.EditorInspectorSectionId.campaign_metadata)] = true;
    sections[@backingInt(types.EditorInspectorSectionId.campaign_mission)] = true;
    break :blk sections;
};
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

fn arrowGeometryMatches(arrow: ui_element.Arrow, geometry: campaign_geometry.EdgeGeometry) bool {
    return screenPositionEqual(arrow.start, geometry.start) and
        screenPositionEqual(arrow.control_start, geometry.control_start) and
        screenPositionEqual(arrow.control_end, geometry.control_end) and
        screenPositionEqual(arrow.end, geometry.end);
}

fn findLightArrow(
    elements: []const UiElement,
    geometry: campaign_geometry.EdgeGeometry,
) !usize {
    for (elements, 0..) |element, index| {
        if (element != .arrow) continue;
        if (!colorEqual(element.arrow.color, test_theme.lightest)) continue;
        if (arrowGeometryMatches(element.arrow, geometry)) return index;
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

test "buildCampaignEditorPrimaryActions: one Validate button, flush top-right at the mission editor's cell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var elements: UiElementList = .empty;
    defer elements.deinit(arena.allocator());
    try buildCampaignEditorPrimaryActions(&elements, arena.allocator(), test_theme);

    // Exactly one button (no Test - nothing to play in a campaign, no
    // Save - ctrl+S + the options menu are the paths), at the shared
    // validate cell: flush against the right edge, top bar's height.
    var found: ?ui_element.Button = null;
    var button_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| {
            button_count += 1;
            if (button.action == .validate_campaign) found = button;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), button_count);
    const button = found orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(types.reference_width - ui_element.top_bar_slot_size, button.screen_position.x);
    try std.testing.expectEqual(@as(i32, 0), button.screen_position.y);
    try std.testing.expectEqual(ui_element.top_bar_slot_size, button.width);
    try std.testing.expectEqual(ui_element.top_bar_slot_size, button.height);
    try std.testing.expect(button.tooltip != null);
}

test "buildCampaignEditorView: surface, background, hubs, and the edge classes incl. orphans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var elements: UiElementList = .empty;
    defer elements.deinit(arena.allocator());

    const editor = buildFixtureEditor();
    var ui_state: UiState = .{ .editor_inspector_section_expanded = test_sections_collapsed };
    try buildCampaignEditorView(
        &elements,
        arena.allocator(),
        test_font_metrics,
        ui_element.screenRect(),
        editor,
        test_theme,
        test_button_color,
        .{ .ui_state = &ui_state },
    );
    // The panel-bounds guard: nothing that blocks input may straddle the
    // inspector panel (the overflow class this surface's windowing
    // renderer exists to prevent).
    try ui_element.expectNoElementStraddlesRect(elements.items, inspector.editorInspectorPanelRect());

    // Derived total: the map (1 surface + 1 background + per hub an icon
    // + a select button + per mission 1 arrow + 1 edge button - the
    // select tool is the fixture's default) + the tool palette (the
    // select + hub cells x button + graphic, the mission cell's button +
    // the one-arrow arrow graphic) + the inspector (toggle strip 3 + open
    // panel 1 - NOTHING selected: no section strip, the panel is empty)
    // + the metadata (toggle strip 3; CLOSED by default - the mission
    // editor's default).
    const expected_total = 1 + 1 + 2 * editor.hubs.len + 2 * editor.missions.len +
        6 + (3 + 1) + 3;
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
    try std.testing.expectEqual(@as(usize, 3), blocking_panels); // the two toggle strips + the open inspector panel (nothing selected - no section strip)

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
    const loop_light = elements.items[try findLightArrow(elements.items, loop_geometry)].arrow;
    try std.testing.expectEqual(@as(u8, 255), loop_light.alpha);

    // The straight edge Alpha -> Beta.
    const straight_geometry = campaign_geometry.deriveEdgeGeometry(
        .{ .x = -200, .y = 0 },
        .{ .hub = .{ .x = 400, .y = 300 } },
        0,
        .{ .index = 1, .count = 1 },
    );
    const straight_light = elements.items[try findLightArrow(elements.items, straight_geometry)].arrow;
    try std.testing.expectEqual(@as(u8, 255), straight_light.alpha);

    // The end-orphan: a stub from Alpha, GHOSTED (reduced alpha) - the
    // fade IS the incomplete marker.
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
    const stub_light = elements.items[try findLightArrow(elements.items, stub_geometry)].arrow;
    try std.testing.expectEqual(orphaned_alpha, stub_light.alpha);

    // The start-orphan: the complete edge from the frozen ghost start
    // position toward the LIVE Beta - straight, ghosted.
    const salvage_geometry = campaign_geometry.deriveEdgeGeometry(
        .{ .x = -600, .y = -300 },
        .{ .hub = .{ .x = 400, .y = 300 } },
        0,
        .{ .index = 1, .count = 1 },
    );
    const salvage_light = elements.items[try findLightArrow(elements.items, salvage_geometry)].arrow;
    try std.testing.expectEqual(orphaned_alpha, salvage_light.alpha);

    // The fully-orphaned mission: the complete edge between both ghost
    // positions, ghosted.
    const ghost_geometry = campaign_geometry.deriveEdgeGeometry(
        .{ .x = -600, .y = -300 },
        .{ .hub = .{ .x = -600, .y = 300 } },
        0,
        .{ .index = 1, .count = 1 },
    );
    const ghost_light = elements.items[try findLightArrow(elements.items, ghost_geometry)].arrow;
    try std.testing.expectEqual(orphaned_alpha, ghost_light.alpha);

    // The hit-arrow bounds-coherence contract, across every edge button
    // (the world-map test's rider, here over the editor's select-tool
    // buttons): a button's rect == arrowBounds of its hit_arrow.
    for (elements.items) |element| {
        if (element != .button) continue;
        const hit_arrow = element.button.hit_arrow orelse continue;
        const bounds = ui_element.arrowBounds(hit_arrow);
        try std.testing.expectEqual(bounds, Rectangle{
            .x = element.button.screen_position.x,
            .y = element.button.screen_position.y,
            .width = element.button.width,
            .height = element.button.height,
        });
    }
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
    editor.selection = .{ .hub = 0 };
    editor.metadata_sidebar_open = true;
    var elements: UiElementList = .empty;
    defer elements.deinit(arena.allocator());
    var ui_state: UiState = .{ .editor_inspector_section_expanded = test_sections_expanded };
    try buildCampaignEditorView(
        &elements,
        arena.allocator(),
        test_font_metrics,
        ui_element.screenRect(),
        editor,
        test_theme,
        test_button_color,
        .{ .ui_state = &ui_state },
    );
    try ui_element.expectNoElementStraddlesRect(elements.items, inspector.editorInspectorPanelRect());

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
    // The two-unit entry convention: the Start Hub entry's label sits
    // BELOW the name field's control line (the overlap regression - the
    // label once rendered inside the field).
    var start_hub_label: ?ui_element.TextLabel = null;
    for (elements.items) |element| switch (element) {
        .text_label => |label| if (std.mem.eql(u8, label.text, "Start Hub")) {
            start_hub_label = label;
        },
        else => {},
    };
    try std.testing.expect(start_hub_label.?.screen_position.y >=
        hub_name_field.?.screen_position.y + hub_name_field.?.height);

    // The start-hub toggle: a standard panel-button row (the exact
    // mission-editor control formatting); the start state reads from the
    // LABEL ("Start Hub ..." vs "Set as Start Hub") - the radio readback.
    var start_toggle: ?ui_element.Button = null;
    var start_toggle_label: ?[]const u8 = null;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .set_editor_campaign_start_hub) {
            start_toggle = button;
        },
        .text_label => |label| if (std.mem.startsWith(u8, label.text, "Start Hub")) {
            start_toggle_label = label.text;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(u32, 0), start_toggle.?.payload.?.editor_campaign_hub);
    try std.testing.expect(start_toggle_label.?.len > "Start Hub".len); // "(toggle another to move)" rides the label

    // The drill-in entry: the Open Hub Editor button (units 5-6, below
    // the toggle), the hub handle riding the editor_campaign_hub
    // payload.
    var open_button: ?ui_element.Button = null;
    var open_label: ?[]const u8 = null;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .open_hub_editor) {
            open_button = button;
        },
        .text_label => |label| if (std.mem.eql(u8, label.text, "Open Hub Editor")) {
            open_label = label.text;
        },
        else => {},
    };
    try std.testing.expect(open_button != null);
    try std.testing.expectEqual(@as(u32, 0), open_button.?.payload.?.editor_campaign_hub);
    try std.testing.expect(open_label != null);

    // The toggle's CONTROL text is theme lightest (the row shipped
    // literal black once - the entry label above was already lightest).
    for (elements.items) |element| switch (element) {
        .text_label => |label| {
            if (std.mem.startsWith(u8, label.text, "Start Hub (toggle") or
                std.mem.eql(u8, label.text, "Set as Start Hub"))
            {
                try std.testing.expectEqual(test_theme.lightest, label.color);
            }
        },
        else => {},
    };

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

    // The hub cell's graphic: the hub icon drawn 128x128 - half the cell,
    // not edge to edge (the map icons stay 64).
    var palette_hub_icon: ?ui_element.Image = null;
    for (elements.items) |element| switch (element) {
        .image => |image| {
            if (std.mem.eql(u8, image.sprite_id, hub_icon_sprite_id) and
                image.width == 128 and image.height == 128)
            {
                palette_hub_icon = image;
            }
        },
        else => {},
    };
    try std.testing.expect(palette_hub_icon != null);

    // The mission cell's graphic: the 128px baked-arrow arrow pointing
    // right - one arrow at the outline-inclusive width, lightest-colored
    // (the outline is baked into the texture; the drawn-edge visual, not
    // a sprite).
    var palette_arrows: usize = 0;
    for (elements.items) |element| switch (element) {
        .arrow => |arrow| {
            const is_palette_arrow = arrow.start.y == arrow.end.y and
                arrow.end.x - arrow.start.x == mission_tool_arrow_length;
            if (!is_palette_arrow) continue;
            palette_arrows += 1;
            try std.testing.expectEqual(edge_width + 2 * edge_outline_width, arrow.width);
            try std.testing.expectEqual(test_theme.lightest, arrow.color);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), palette_arrows);

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

    ui_state.editor_inspector_section_expanded = test_sections_collapsed;
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
        .{ .pan = .{ .x = 64, .y = -32 }, .ui_state = &ui_state },
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
    var ui_state: UiState = .{ .editor_inspector_section_expanded = test_sections_collapsed };
    try buildCampaignEditorView(
        &elements,
        arena.allocator(),
        test_font_metrics,
        ui_element.screenRect(),
        editor,
        test_theme,
        test_button_color,
        .{ .background_stems = &stems, .ui_state = &ui_state },
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

    // The row text is theme lightest - the game's regular-text color
    // (the picker rows shipped literal black once; every other list row
    // in the game is lightest).
    for (elements.items) |element| switch (element) {
        .text_label => |label| {
            const is_row_text = std.mem.eql(u8, label.text, "None") or
                std.mem.eql(u8, label.text, "map") or
                std.mem.eql(u8, label.text, "sketch");
            if (is_row_text) try std.testing.expectEqual(test_theme.lightest, label.color);
        },
        else => {},
    };

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

test "buildCampaignEditorView: the mission inspector + edge buttons + the draw preview" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A selected mission (m2 "Cross", Alpha -> Beta) + expanded sections:
    // the mission section shows the name + direction fields (bound to the
    // handle) + the re-attach rows (naming the attached hubs) + Import.
    var editor = buildFixtureEditor();
    editor.selection = .{ .mission = 3 };
    editor.metadata_sidebar_open = true;
    var elements: UiElementList = .empty;
    defer elements.deinit(arena.allocator());
    var ui_state: UiState = .{ .editor_inspector_section_expanded = test_sections_expanded };
    try buildCampaignEditorView(
        &elements,
        arena.allocator(),
        test_font_metrics,
        ui_element.screenRect(),
        editor,
        test_theme,
        test_button_color,
        .{ .ui_state = &ui_state },
    );
    try ui_element.expectNoElementStraddlesRect(elements.items, inspector.editorInspectorPanelRect());

    var mission_name_field: ?ui_element.TextFieldUi = null;
    var direction_field: ?ui_element.TextFieldUi = null;
    for (elements.items) |element| switch (element) {
        .text_field => |field| {
            if (field.ref.id == .campaign_mission_name) mission_name_field = field;
            if (field.ref.id == .campaign_mission_direction) direction_field = field;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(u32, 3), mission_name_field.?.ref.target.campaign_mission);
    try std.testing.expectEqual(@as(u32, 3), direction_field.?.ref.target.campaign_mission);

    // The hand-off entry (the slice-5 open) sits ABOVE Import - the
    // more-used action reads first. The section's 13 units overflow the
    // panel's 11 visible rows, so at scroll 0 the hand-off IS in the
    // window while the Import affordance below it is WINDOWED OUT (the
    // shared renderer skips entries that don't fully fit; the scrollbar
    // marks the overflow).
    var open_mission_button: ?ui_element.Button = null;
    var import_button: ?ui_element.Button = null;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .open_mission_editor) {
            open_mission_button = button;
        } else if (button.action == .open_campaign_import_picker) {
            import_button = button;
        },
        else => {},
    };
    try std.testing.expect(open_mission_button != null);
    try std.testing.expectEqual(@as(u32, 3), open_mission_button.?.payload.?.editor_campaign_mission);
    try std.testing.expect(import_button == null);
    var scrollbar_tracks: usize = 0;
    for (elements.items) |element| switch (element) {
        .solid_rect => |rect| if (std.meta.eql(rect.color, ui_element.scrollbar_track_color)) {
            scrollbar_tracks += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), scrollbar_tracks);

    // Scrolled to the bottom (a seeded out-of-range offset clamps to
    // max_scroll = 13 - 11 = 2): the import button enters the window
    // under the hand-off (the swapped order: the hand-off above).
    ui_state.editor_inspector_scroll = 99;
    var scrolled_elements: UiElementList = .empty;
    defer scrolled_elements.deinit(arena.allocator());
    try buildCampaignEditorView(
        &scrolled_elements,
        arena.allocator(),
        test_font_metrics,
        ui_element.screenRect(),
        editor,
        test_theme,
        test_button_color,
        .{ .ui_state = &ui_state },
    );
    try std.testing.expectEqual(@as(i32, 2), ui_state.editor_inspector_scroll);
    // The windowed-in bottom rows still fit the panel - the guard holds
    // at every scroll offset, not just the top.
    try ui_element.expectNoElementStraddlesRect(scrolled_elements.items, inspector.editorInspectorPanelRect());
    open_mission_button = null;
    for (scrolled_elements.items) |element| switch (element) {
        .button => |button| if (button.action == .open_mission_editor) {
            open_mission_button = button;
        },
        else => {},
    };
    try std.testing.expect(open_mission_button != null);
    try std.testing.expectEqual(@as(u32, 3), open_mission_button.?.payload.?.editor_campaign_mission);

    // The swapped order at the scrolled window: the hand-off entry sits
    // ABOVE the import affordance (the more-used action first).
    import_button = null;
    for (scrolled_elements.items) |element| switch (element) {
        .button => |button| if (button.action == .open_campaign_import_picker) {
            import_button = button;
        },
        else => {},
    };
    try std.testing.expect(import_button != null);
    try std.testing.expect(open_mission_button.?.screen_position.y < import_button.?.screen_position.y);

    var reattach_buttons: usize = 0;
    var alpha_row = false;
    var beta_row = false;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .reattach_campaign_mission_start or
            button.action == .reattach_campaign_mission_destination)
        {
            reattach_buttons += 1;
        },
        .text_label => |label| {
            if (std.mem.eql(u8, label.text, "Alpha")) alpha_row = true;
            if (std.mem.eql(u8, label.text, "Beta")) beta_row = true;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), reattach_buttons);
    try std.testing.expect(alpha_row); // m2's start hub named on the start row
    try std.testing.expect(beta_row); // its destination on the end row

    // The re-attach rows' control text is theme lightest (the rows
    // shipped literal black once).
    for (elements.items) |element| switch (element) {
        .text_label => |label| {
            if (std.mem.eql(u8, label.text, "Alpha") or std.mem.eql(u8, label.text, "Beta") or
                std.mem.startsWith(u8, label.text, "Unattached"))
            {
                try std.testing.expectEqual(test_theme.lightest, label.color);
            }
        },
        else => {},
    };

    // The select tool's edge buttons: one per mission, handle payloads;
    // the SELECTED mission's button carries the animated highlight (the
    // hub icons' selection treatment).
    var edge_buttons: usize = 0;
    var highlighted_edges: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .select_editor_campaign_mission) {
            edge_buttons += 1;
            const is_selected = button.payload.?.editor_campaign_mission == 3;
            if (is_selected != button.highlighted) return error.TestUnexpectedResult;
            if (button.highlighted) highlighted_edges += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(editor.missions.len, edge_buttons);
    try std.testing.expectEqual(@as(usize, 1), highlighted_edges);

    // The selection follows ACROSS tools: under the mission tool the
    // unselected edges lose their buttons (the draw gesture owns the
    // surface), but the SELECTED edge keeps its button + rim - a
    // just-placed edge highlights immediately, mid-mission-tool (the
    // placement-selects rule).
    {
        editor.active_tool = .mission;
        var mission_tool_elements: UiElementList = .empty;
        defer mission_tool_elements.deinit(arena.allocator());
        try buildCampaignEditorView(
            &mission_tool_elements,
            arena.allocator(),
            test_font_metrics,
            ui_element.screenRect(),
            editor,
            test_theme,
            test_button_color,
            .{ .ui_state = &ui_state },
        );
        var mission_tool_edge_buttons: usize = 0;
        for (mission_tool_elements.items) |element| switch (element) {
            .button => |button| if (button.action == .select_editor_campaign_mission) {
                mission_tool_edge_buttons += 1;
                try std.testing.expectEqual(@as(u32, 3), button.payload.?.editor_campaign_mission);
                try std.testing.expect(button.highlighted);
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 1), mission_tool_edge_buttons);
        editor.active_tool = .select;
    }

    // The draw preview: an armed mission tool renders TWO extra arrows
    // (the stroke pair) from the armed hub toward the pointer position.
    editor.active_tool = .mission;
    editor.selection = null;
    ui_state.editor_inspector_section_expanded = test_sections_collapsed;
    ui_state.editor_inspector_scroll = 0;
    var preview_elements: UiElementList = .empty;
    defer preview_elements.deinit(arena.allocator());
    try buildCampaignEditorView(
        &preview_elements,
        arena.allocator(),
        test_font_metrics,
        ui_element.screenRect(),
        editor,
        test_theme,
        test_button_color,
        .{
            .mission_draw = 0,
            .pointer_map_position = .{ .x = 600, .y = -400 },
            .ui_state = &ui_state,
        },
    );
    // Derived total for the preview build: the map (1 surface + 1
    // background + 2/hub + 1 arrow/mission - NO edge buttons under the
    // mission tool - + 1 preview arrow) + palette 6 + the inspector
    // (toggle strip 3 + open panel 1 - nothing selected, empty) + the
    // metadata (open, collapsed: strip 3 + panel 1 + section strip 3).
    const expected_preview_total = 1 + 1 + 2 * editor.hubs.len + 1 * editor.missions.len + 1 +
        6 + 4 + 7;
    try std.testing.expectEqual(expected_preview_total, preview_elements.items.len);
}
