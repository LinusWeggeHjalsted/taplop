//! The full-screen browsers: the load-save browser (main menu) + the
//! editor browser with its mission-list tab (editor + main menu) - one
//! row/scrollback machinery, two surfaces (DESIGN → UI Framework). One of
//! menus.zig's per-surface splits; the shared scrollbar emitter lives in
//! emit.zig.

const std = @import("std");
const types = @import("../types.zig");
const ui_element = @import("element.zig");
const emit = @import("emit.zig");
const session_log = @import("../session_log.zig");

const Rectangle = types.Rectangle;
const Color = types.Color;
const text = ui_element.text;
const FontMetrics = ui_element.FontMetrics;
const UiElementList = ui_element.UiElementList;
const emitPanelButton = emit.emitPanelButton;
const Button = ui_element.Button;
const SlotRef = ui_element.SlotRef;
const ui_gap = ui_element.ui_gap;
const panel_button_height = ui_element.panel_button_height;
const top_bar_height = ui_element.top_bar_height;
const menu_button_font_size = ui_element.menu_button_font_size;
const middle_panel_header_height = ui_element.middle_panel_header_height;
const middle_panel_header_font_size = ui_element.middle_panel_header_font_size;
const lineHeight = ui_element.lineHeight;

// --- Load-save browser (main menu, full screen) ---

const load_save_header_font_size: i32 = 72;
const load_save_header_gap: i32 = 32;
const load_save_row_font_size: i32 = 56;
/// One save row's height. The scroll unit is the full row PITCH (height +
/// gap) so scrolled text sits at identical y positions at every offset.
const load_save_row_height: i32 = 112;
const load_save_row_gap: i32 = 8;
const load_save_padding: i32 = 48;
const load_save_button_gap: i32 = 48; // gap between rows region and bottom buttons
/// Scrollbar geometry, aliased from the shared constants in `element.zig`
/// (one tuning knob for every scrollbar surface).
const scrollbar_width = ui_element.scrollbar_width;
const scrollbar_gap = ui_element.scrollbar_gap;

/// Import/Back button size (bottom corners). Import label is long, so the
/// buttons are wider than tall menu buttons but reuse the menu font.
const load_save_button_width: i32 = 768;

/// Build the load-save browser: a full-screen modal panel listing
/// `save_files` (newest first - the slice arrives pre-sorted from
/// `FileSource.listSaveFiles`), one clickable row per save, a Back button
/// bottom-left and (web only) an Import button bottom-right.
/// Overflowing lists scroll: only the visible row window is emitted and a
/// scrollbar is drawn. `scroll_offset` is in rows and clamped here to
/// `[0, max_scroll_row]` (the view is the only place that knows the max,
/// which depends on the row count). Barebones by design (see TODO →
/// Platform Layer for the future polish slice).
pub fn buildLoadSavePanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    save_files: []const @import("../file_source.zig").SaveFileEntry,
    scroll_offset: *i32,
    button_color: Color,
) !void {
    // Full-screen modal background - blocks input to the main-menu buttons
    // behind it.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = screen.position(),
        .width = screen.width,
        .height = screen.height,
        .blocks_input = true,
    } });

    const content_x = screen.x + load_save_padding;
    const content_width = screen.width - 2 * load_save_padding;

    // Header.
    const header_y = screen.y + load_save_padding;
    try elements.append(allocator, .{ .text_label = .{
        .text = "Load Save",
        .screen_position = .{ .x = content_x, .y = header_y },
        .font_size = load_save_header_font_size,
        .blocks_input = false,
    } });

    // Rows region: from below the header to above the bottom buttons.
    const rows_y = header_y + lineHeight(load_save_header_font_size) + load_save_header_gap;
    const rows_bottom = screen.y + screen.height - load_save_padding -
        panel_button_height - load_save_button_gap;
    const rows_height = rows_bottom - rows_y;
    const row_pitch = load_save_row_height + load_save_row_gap;
    const visible_rows: usize = @intCast(@max(0, @divTrunc(rows_height, row_pitch)));

    // Clamp the scroll offset (authoritative - the input handler can't know
    // max_scroll_row without the row count).
    const total_rows: usize = save_files.len;
    const max_scroll_row: i32 = @intCast(total_rows - @min(total_rows, visible_rows));
    if (scroll_offset.* < 0) scroll_offset.* = 0;
    if (scroll_offset.* > max_scroll_row) scroll_offset.* = max_scroll_row;
    const scrolls = total_rows > visible_rows;

    if (total_rows == 0) {
        try elements.append(allocator, .{ .text_label = .{
            .text = "No save files",
            .screen_position = .{ .x = content_x, .y = rows_y },
            .font_size = load_save_row_font_size,
            .blocks_input = false,
        } });
    } else {
        // Rows widen right up to the scrollbar gutter when one is drawn.
        const rows_width = if (scrolls)
            content_width - scrollbar_width - scrollbar_gap
        else
            content_width;

        const first: usize = @intCast(scroll_offset.*);
        const last_exclusive = @min(total_rows, first + visible_rows);
        for (first..last_exclusive) |index| {
            const cell: Rectangle = .{
                .x = content_x,
                .y = rows_y + @as(i32, @intCast(index - first)) * row_pitch,
                .width = rows_width,
                .height = load_save_row_height,
            };
            try elements.append(allocator, .{ .nine_slice_panel = .{
                .sprite_id = "ui/panel",
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
            } });
            try elements.append(allocator, .{ .button = .{
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .action = .load_save_row,
                .payload = .{ .save_row = @intCast(index) },
            } });
            // The name sits LEFT (filename minus extension); the file's
            // mtime (UTC - the session-log convention) sits right-aligned
            // in the zone left of the delete button's reserve.
            const file = save_files[index];
            const label = file.name[0 .. file.name.len - ".txt".len];
            try elements.append(allocator, .{ .text_label = .{
                .text = label,
                .screen_position = .{
                    .x = cell.x + ui_gap,
                    .y = cell.y + @divFloor(load_save_row_height - load_save_row_font_size, 2),
                },
                .font_size = load_save_row_font_size,
                .blocks_input = false,
            } });
            if (file.mtime_ns > 0) {
                const stamp = session_log.formatMtimeTimestamp(allocator, file.mtime_ns);
                const stamp_width = font_metrics.measureSpanWidth(text(stamp), load_save_row_font_size);
                const stamp_zone_width = cell.width - ui_element.close_button_size - 3 * ui_gap;
                if (stamp_width <= stamp_zone_width) {
                    try elements.append(allocator, .{ .text_label = .{
                        .text = stamp,
                        .screen_position = .{
                            .x = cell.x + cell.width - ui_element.close_button_size - 2 * ui_gap - stamp_width,
                            .y = cell.y + @divFloor(load_save_row_height - load_save_row_font_size, 2),
                        },
                        .font_size = load_save_row_font_size,
                        .blocks_input = false,
                    } });
                } else {
                    allocator.free(stamp);
                }
            }

            // The x delete button (every row - saves are all local): the
            // shared close-button visual, flush right + vertically
            // centered, emitted LAST so hit-testing prefers it over the
            // full-row button.
            const delete_cell: Rectangle = .{
                .x = cell.x + cell.width - ui_element.close_button_size - ui_gap,
                .y = cell.y + @divFloor(load_save_row_height - ui_element.close_button_size, 2),
                .width = ui_element.close_button_size,
                .height = ui_element.close_button_size,
            };
            try elements.append(allocator, .{ .button = .{
                .sprite_id = ui_element.close_button_sprite_id,
                .screen_position = delete_cell.position(),
                .width = delete_cell.width,
                .height = delete_cell.height,
                .action = .delete_save,
                .payload = .{ .save_row = @intCast(index) },
                .tooltip = .{ .body = try allocator.dupe(ui_element.TooltipRow, &.{try @import("tooltip.zig").spanRow(allocator, text(
                    "Deletes this save - moves the file to deleted/ in the game folder (recoverable by hand)",
                ))}) },
            } });
        }

        // Scrollbar: track + thumb along the rows region, the shared
        // emission.
        if (scrolls) {
            try emit.emitScrollbar(
                elements,
                allocator,
                content_x + content_width - scrollbar_width,
                rows_y,
                rows_height,
                visible_rows,
                total_rows,
                scroll_offset.*,
            );
        }
    }

    // Bottom corners: Back (always) + Import (web only).
    const button_y = screen.y + screen.height - load_save_padding - panel_button_height;
    try emitPanelButton(
        elements,
        allocator,
        font_metrics,
        .{
            .x = content_x,
            .y = button_y,
            .width = load_save_button_width,
            .height = panel_button_height,
        },
        "Back",
        menu_button_font_size,
        .toggle_load_save_menu,
        button_color,
        null,
    );
    if (@import("builtin").target.os.tag == .emscripten) {
        try emitPanelButton(
            elements,
            allocator,
            font_metrics,
            .{
                .x = screen.x + screen.width - load_save_padding - load_save_button_width,
                .y = button_y,
                .width = load_save_button_width,
                .height = panel_button_height,
            },
            "Import",
            menu_button_font_size,
            .import_save,
            button_color,
            null,
        );
    }
}

// --- Editor browser (editor + main menu, full screen) ---

/// The editor-browser kind tab row's spec - DERIVED at comptime from
/// `types.EditorKind` + `editorBrowserKindLabel` (the generated-lookup
/// pattern: the builder's tab row and its tests both walk this list, so a
/// new editor kind appears as a tab by adding the enum member - the
/// exhaustive label switch is the compile error until it's named).
const EditorBrowserKindSpec = struct {
    kind: types.EditorKind,
    label: []const u8,
};
const editor_kind_count = @typeInfo(types.EditorKind).@"enum".field_names.len;
const editor_browser_kind_specs: [editor_kind_count]EditorBrowserKindSpec = blk: {
    var specs: [editor_kind_count]EditorBrowserKindSpec = undefined;
    for (@typeInfo(types.EditorKind).@"enum".field_names, 0..) |field_name, index| {
        const kind: types.EditorKind = @field(types.EditorKind, field_name);
        specs[index] = .{ .kind = kind, .label = editorBrowserKindLabel(kind) };
    }
    break :blk specs;
};

/// The kind tab's label - one per editor kind, exhaustive by construction
/// (no else-arm: a new EditorKind member is a compile error until named).
fn editorBrowserKindLabel(kind: types.EditorKind) []const u8 {
    return switch (kind) {
        .mission => "Mission",
        .campaign => "Campaign",
    };
}

/// The New button's label, derived from the ACTIVE kind - one button, not
/// one per tab (the tab row already shows the kinds; buttons for content
/// that isn't on screen would be dead buttons). Exhaustive like the tab
/// label: a new editor kind names its New button here.
fn editorBrowserNewButtonLabel(kind: types.EditorKind) []const u8 {
    return switch (kind) {
        .mission => "New Mission",
        .campaign => "New Campaign",
    };
}

/// The New button's ACTION, derived from the active kind like its label:
/// the mission kind fires the mission open, the campaign kind the
/// campaign open (each a recorded player action with a null payload - a
/// fresh instance). Exhaustive like the label.
fn editorBrowserNewButtonAction(kind: types.EditorKind) types.Action {
    return switch (kind) {
        .mission => .new_editor_mission,
        .campaign => .new_editor_campaign,
    };
}

/// The Import button's ACTION, derived from the active kind like the
/// New button's: the mission kind uploads a mission .zip, the campaign
/// kind a campaign .zip (web-only either way - native never emits the
/// button). Exhaustive like the label.
fn editorBrowserImportAction(kind: types.EditorKind) types.Action {
    return switch (kind) {
        .mission => .import_editor_mission,
        .campaign => .import_campaign,
    };
}

/// Build the editor browser: a full-screen modal panel mirroring the
/// load-save browser - the editor-kind tab row (Mission today; Hub /
/// Campaign tabs append when those editors land) with a New button
/// derived from the active kind, and the active kind's content. The
/// mission content mirrors the load-save browser: two tab buttons
/// top-left (Your Missions / Official - the sprite picker's tab
/// pattern), one clickable row per mission (display name; a click opens
/// it in the editor via `open_editor`), a Back button bottom-left. The
/// web-only Import button (zip upload) lands with the import slice.
/// Overflowing lists scroll with the load-save browser's whole-row model;
/// the scroll offset clamps here (authoritative - the view is the only
/// place that knows the max). Barebones like the load-save browser (same
/// polish slice owns richer row visuals). See DESIGN → Architecture →
/// Level Editor → The editor browser.
pub fn buildEditorBrowser(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    kind: types.EditorKind,
    local_missions: []const @import("../file_source.zig").FileSource.MissionEntry,
    official_missions: []const @import("../file_source.zig").FileSource.MissionEntry,
    tab: types.EditorMissionBrowserTab,
    scroll_offset: *i32,
    local_campaigns: []const @import("../file_source.zig").FileSource.CampaignEntry,
    official_campaigns: []const @import("../file_source.zig").FileSource.CampaignEntry,
    campaign_tab: types.CampaignBrowserTab,
    campaign_scroll_offset: *i32,
    button_color: Color,
) !void {
    // Full-screen modal background - blocks input to the editor UI behind
    // it. Reuses the load-save browser's metrics (same visual class).
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = screen.position(),
        .width = screen.width,
        .height = screen.height,
        .blocks_input = true,
    } });

    const origin = screen.position();

    // KIND TAB ROW (top-left): one tab per editor kind, derived from
    // `editor_browser_kind_specs` (Mission today; Hub / Campaign append
    // with their editors) - the tabs ARE the window's identity. Sits BELOW
    // the global top bar (the always-on-top layer would cover the tabs -
    // everything in the window hangs off this row's y). Same
    // emission shape as the content tabs: darkest background panels, the
    // active tab's highlight outline is the indication, no tint change
    // (the picker's convention).
    const kind_tabs_y = origin.y + top_bar_height + load_save_padding;
    var kind_tab_x = origin.x + ui_gap;
    for (editor_browser_kind_specs) |spec| {
        const label_width = font_metrics.measureSpanWidth(text(spec.label), middle_panel_header_font_size);
        const kind_tab_width = label_width + 2 * ui_gap;
        const active = spec.kind == kind;
        try elements.append(allocator, .{ .nine_slice_panel = .{
            .sprite_id = "ui/panel",
            .screen_position = .{ .x = kind_tab_x, .y = kind_tabs_y },
            .width = kind_tab_width,
            .height = middle_panel_header_height,
            .color = button_color,
        } });
        try elements.append(allocator, .{ .button = .{
            .screen_position = .{ .x = kind_tab_x, .y = kind_tabs_y },
            .width = kind_tab_width,
            .height = middle_panel_header_height,
            .action = .select_editor_kind_tab,
            .payload = .{ .editor_kind = spec.kind },
            .highlighted = active,
        } });
        try elements.append(allocator, .{ .text_label = .{
            .text = spec.label,
            .screen_position = .{
                .x = kind_tab_x + ui_gap,
                .y = kind_tabs_y + @divFloor(
                    middle_panel_header_height - middle_panel_header_font_size,
                    2,
                ),
            },
            .font_size = middle_panel_header_font_size,
            .blocks_input = false,
        } });
        kind_tab_x += kind_tab_width + ui_gap;
    }

    // Content per kind - the kind row above is kind-independent chrome.
    // Exhaustive switch: a new EditorKind member is a compile error
    // until its content builder is routed here.
    switch (kind) {
        .mission => try buildMissionBrowserContent(
            elements,
            allocator,
            font_metrics,
            screen,
            kind_tabs_y + middle_panel_header_height + load_save_header_gap,
            local_missions,
            official_missions,
            tab,
            scroll_offset,
            button_color,
        ),
        .campaign => try buildEditorCampaignBrowserContent(
            elements,
            allocator,
            font_metrics,
            screen,
            kind_tabs_y + middle_panel_header_height + load_save_header_gap,
            local_campaigns,
            official_campaigns,
            campaign_tab,
            campaign_scroll_offset,
            button_color,
        ),
    }

    // Bottom-left: Back (closes the browser - same toggle action that
    // opens it).
    const button_y = screen.y + screen.height - load_save_padding - panel_button_height;
    try emitPanelButton(
        elements,
        allocator,
        font_metrics,
        .{
            .x = screen.x + load_save_padding,
            .y = button_y,
            .width = load_save_button_width,
            .height = panel_button_height,
        },
        "Back",
        menu_button_font_size,
        .toggle_editor_browser,
        button_color,
        null,
    );
    // Bottom-right: the New button, derived from the ACTIVE kind (one
    // button, not one per tab - the tab row already shows the kinds),
    // mirroring the Back button's metrics. Fires the same recorded
    // open_editor{null} as ctrl+N / the options-menu New Mission button;
    // from the main menu it opens the editor directly.
    try emitPanelButton(
        elements,
        allocator,
        font_metrics,
        .{
            .x = screen.x + screen.width - load_save_padding - load_save_button_width,
            .y = button_y,
            .width = load_save_button_width,
            .height = panel_button_height,
        },
        editorBrowserNewButtonLabel(kind),
        menu_button_font_size,
        editorBrowserNewButtonAction(kind),
        button_color,
        null,
    );
    // Import (web only - the load-save browser's Import discipline): opens
    // a file picker for the ACTIVE kind's .zip (a mission zip extracts
    // into missions/, a campaign zip into campaigns/); the picked zip
    // extracts and the rescanned list shows it. Centered along the
    // bottom, between the Back and New buttons. Native has no button -
    // drop the extracted folder (or a STORE zip) into the persistent
    // dir by hand.
    if (@import("builtin").target.os.tag == .emscripten) {
        try emitPanelButton(
            elements,
            allocator,
            font_metrics,
            .{
                .x = screen.x + @divTrunc(screen.width - load_save_button_width, 2),
                .y = button_y,
                .width = load_save_button_width,
                .height = panel_button_height,
            },
            "Import",
            menu_button_font_size,
            editorBrowserImportAction(kind),
            button_color,
            null,
        );
    }
}

/// The per-surface configuration of the shared list-browser body (the
/// mission list + the campaign browser - one machinery, N surfaces).
/// `Entry` needs a `name: []const u8` field (the row label); `Tab` is a
/// local/official pair.
const ListBrowserConfig = struct {
    Entry: type,
    Tab: type,
    tab_action: types.Action,
    row_action: types.Action,
    /// The ButtonPayload variants the tab + row buttons carry.
    tab_payload_tag: types.ButtonPayloadTag,
    row_payload_tag: types.ButtonPayloadTag,
    local_tab_label: []const u8,
    official_tab_label: []const u8,
    empty_local_text: []const u8,
    empty_official_text: []const u8,
    /// The row's x delete button (LOCAL rows only - official content is
    /// embedded + read-only): moves the entry into `deleted/` under the
    /// persistent dir (the recoverable delete). The row index rides the
    /// same payload as `row_action`.
    delete_action: types.Action,
    /// The x tooltip's noun ("mission" / "campaign") - names what the
    /// button moves.
    delete_noun: []const u8,
};

/// The shared LIST-BROWSER body: the two list tabs + the rows +
/// scrollbar (the pre-kind-tab browser body, now serving the mission
/// list AND the campaign browser). `tabs_y` is the content top (below
/// the kind row on the editor browser, below the top bar on the campaign
/// browser).
fn buildListBrowserContent(
    comptime config: ListBrowserConfig,
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    tabs_y: i32,
    local_entries: []const config.Entry,
    official_entries: []const config.Entry,
    tab: config.Tab,
    scroll_offset: *i32,
    button_color: Color,
) !void {
    const content_x = screen.x + load_save_padding;
    const content_width = screen.width - 2 * load_save_padding;
    const origin = screen.position();

    // Tabs top-left (the tabs ARE the header, like the sprite picker).
    // Darkest background panels; the active tab's highlight outline is the
    // indication, no tint change (the picker's convention).
    const tab_specs = [_]struct { tab: config.Tab, label: []const u8 }{
        .{ .tab = .local, .label = config.local_tab_label },
        .{ .tab = .official, .label = config.official_tab_label },
    };
    var tab_x = origin.x + ui_gap;
    for (tab_specs) |spec| {
        const label_width = font_metrics.measureSpanWidth(text(spec.label), middle_panel_header_font_size);
        const tab_width = label_width + 2 * ui_gap;
        const active = spec.tab == tab;
        try elements.append(allocator, .{ .nine_slice_panel = .{
            .sprite_id = "ui/panel",
            .screen_position = .{ .x = tab_x, .y = tabs_y },
            .width = tab_width,
            .height = middle_panel_header_height,
            .color = button_color,
        } });
        try elements.append(allocator, .{ .button = .{
            .screen_position = .{ .x = tab_x, .y = tabs_y },
            .width = tab_width,
            .height = middle_panel_header_height,
            .action = config.tab_action,
            .payload = @unionInit(types.ButtonPayload, @tagName(config.tab_payload_tag), spec.tab),
            .highlighted = active,
        } });
        try elements.append(allocator, .{ .text_label = .{
            .text = spec.label,
            .screen_position = .{
                .x = tab_x + ui_gap,
                .y = tabs_y + @divFloor(
                    middle_panel_header_height - middle_panel_header_font_size,
                    2,
                ),
            },
            .font_size = middle_panel_header_font_size,
            .blocks_input = false,
        } });
        tab_x += tab_width + ui_gap;
    }

    // Rows region: from below the tabs to above the Back button.
    const rows_y = tabs_y + middle_panel_header_height + load_save_header_gap;
    const rows_bottom = screen.y + screen.height - load_save_padding -
        panel_button_height - load_save_button_gap;
    const rows_height = rows_bottom - rows_y;
    const row_pitch = load_save_row_height + load_save_row_gap;
    const visible_rows: usize = @intCast(@max(0, @divTrunc(rows_height, row_pitch)));

    const entries = switch (tab) {
        .local => local_entries,
        .official => official_entries,
    };

    // Clamp the scroll offset (authoritative - the input handler can't know
    // max_scroll_row without the row count).
    const total_rows: usize = entries.len;
    const max_scroll_row: i32 = @intCast(total_rows -| @min(total_rows, visible_rows));
    if (scroll_offset.* < 0) scroll_offset.* = 0;
    if (scroll_offset.* > max_scroll_row) scroll_offset.* = max_scroll_row;
    const scrolls = total_rows > visible_rows;

    if (total_rows == 0) {
        const empty_text = switch (tab) {
            .local => config.empty_local_text,
            .official => config.empty_official_text,
        };
        try elements.append(allocator, .{ .text_label = .{
            .text = empty_text,
            .screen_position = .{ .x = content_x, .y = rows_y },
            .font_size = load_save_row_font_size,
            .blocks_input = false,
        } });
    } else {
        // Rows widen right up to the scrollbar gutter when one is drawn.
        const rows_width = if (scrolls)
            content_width - scrollbar_width - scrollbar_gap
        else
            content_width;

        const first: usize = @intCast(scroll_offset.*);
        const last_exclusive = @min(total_rows, first + visible_rows);
        for (first..last_exclusive) |index| {
            const cell: Rectangle = .{
                .x = content_x,
                .y = rows_y + @as(i32, @intCast(index - first)) * row_pitch,
                .width = rows_width,
                .height = load_save_row_height,
            };
            try elements.append(allocator, .{ .nine_slice_panel = .{
                .sprite_id = "ui/panel",
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
            } });
            // The row identity rides in the Button payload (the save-row
            // SlotRef pattern, via the newer Button-payload convention -
            // rows are never drag sources, so no SlotRef).
            try elements.append(allocator, .{ .button = .{
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .action = config.row_action,
                .payload = @unionInit(types.ButtonPayload, @tagName(config.row_payload_tag), @as(u32, @intCast(index))),
            } });
            // The name sits LEFT-aligned; the recency timestamp (the
            // entry's max mtime, UTC - the session-log convention) sits
            // right-aligned in the zone left of the delete button's
            // reserve (the x lands with the delete slice; the timestamp
            // keeps its final position from the start). Official entries
            // carry mtime 0 - no timestamp.
            const label = entries[index].name;
            try elements.append(allocator, .{ .text_label = .{
                .text = label,
                .screen_position = .{
                    .x = cell.x + ui_gap,
                    .y = cell.y + @divFloor(load_save_row_height - load_save_row_font_size, 2),
                },
                .font_size = load_save_row_font_size,
                .blocks_input = false,
            } });
            if (entries[index].mtime_ns > 0) {
                const stamp = session_log.formatMtimeTimestamp(allocator, entries[index].mtime_ns);
                const stamp_width = font_metrics.measureSpanWidth(text(stamp), load_save_row_font_size);
                const stamp_zone_width = cell.width - ui_element.close_button_size - 3 * ui_gap;
                if (stamp_width <= stamp_zone_width) {
                    try elements.append(allocator, .{ .text_label = .{
                        .text = stamp,
                        .screen_position = .{
                            .x = cell.x + cell.width - ui_element.close_button_size - 2 * ui_gap - stamp_width,
                            .y = cell.y + @divFloor(load_save_row_height - load_save_row_font_size, 2),
                        },
                        .font_size = load_save_row_font_size,
                        .blocks_input = false,
                    } });
                } else {
                    allocator.free(stamp);
                }
            }

            // The x delete button on LOCAL rows (official content is
            // embedded + read-only): the shared close-button visual,
            // flush right + vertically centered. Emitted LAST so
            // hit-testing prefers it over the full-row button (the
            // palette-cell convention). One click - the move to deleted/
            // is recoverable, so no confirm step.
            if (tab == .local) {
                const delete_cell: Rectangle = .{
                    .x = cell.x + cell.width - ui_element.close_button_size - ui_gap,
                    .y = cell.y + @divFloor(load_save_row_height - ui_element.close_button_size, 2),
                    .width = ui_element.close_button_size,
                    .height = ui_element.close_button_size,
                };
                try elements.append(allocator, .{ .button = .{
                    .sprite_id = ui_element.close_button_sprite_id,
                    .screen_position = delete_cell.position(),
                    .width = delete_cell.width,
                    .height = delete_cell.height,
                    .action = config.delete_action,
                    .payload = @unionInit(types.ButtonPayload, @tagName(config.row_payload_tag), @as(u32, @intCast(index))),
                    .tooltip = .{ .body = try allocator.dupe(ui_element.TooltipRow, &.{try @import("tooltip.zig").spanRow(allocator, text(
                        try std.fmt.allocPrint(allocator, "Deletes this {s} - moves its folder to deleted/ in the game folder (recoverable by hand)", .{config.delete_noun}),
                    ))}) },
                } });
            }
        }

        // Scrollbar: track + thumb, the shared emission.
        if (scrolls) {
            try emit.emitScrollbar(
                elements,
                allocator,
                content_x + content_width - scrollbar_width,
                rows_y,
                rows_height,
                visible_rows,
                total_rows,
                scroll_offset.*,
            );
        }
    }
}

/// The editor browser's MISSION-kind content configuration (the shared
/// list-browser body; the parent switch routes here).
const mission_list_browser_config = ListBrowserConfig{
    .Entry = @import("../file_source.zig").FileSource.MissionEntry,
    .Tab = types.EditorMissionBrowserTab,
    .tab_action = .select_editor_mission_tab,
    .row_action = .open_editor_mission_row,
    .tab_payload_tag = .editor_mission_tab,
    .row_payload_tag = .editor_mission_row,
    .local_tab_label = "Your Missions",
    .official_tab_label = "Official",
    .empty_local_text = "No saved missions yet",
    .empty_official_text = "No official missions",
    .delete_action = .delete_editor_mission,
    .delete_noun = "mission",
};

/// The campaign browser's content configuration.
const campaign_list_browser_config = ListBrowserConfig{
    .Entry = @import("../file_source.zig").FileSource.CampaignEntry,
    .Tab = types.CampaignBrowserTab,
    .tab_action = .select_campaign_browser_tab,
    .row_action = .view_campaign_row,
    .tab_payload_tag = .campaign_browser_tab,
    .row_payload_tag = .campaign_row,
    .local_tab_label = "Your Campaigns",
    .official_tab_label = "Official",
    .empty_local_text = "No saved campaigns yet",
    .empty_official_text = "No official campaigns",
    .delete_action = .delete_campaign,
    .delete_noun = "campaign",
};

/// The editor browser's CAMPAIGN content configuration - the campaign
/// list with EDITOR semantics: rows OPEN the campaign in the campaign
/// editor (a recorded `open_campaign_editor`), vs the world-map browser's
/// view-only rows (one machinery, N surfaces - the ListBrowserConfig
/// pattern).
const editor_campaign_list_browser_config = ListBrowserConfig{
    .Entry = @import("../file_source.zig").FileSource.CampaignEntry,
    .Tab = types.CampaignBrowserTab,
    .tab_action = .select_editor_campaign_tab,
    .row_action = .open_editor_campaign_row,
    .tab_payload_tag = .campaign_browser_tab,
    .row_payload_tag = .campaign_row,
    .local_tab_label = "Your Campaigns",
    .official_tab_label = "Official",
    .empty_local_text = "No saved campaigns yet",
    .empty_official_text = "No official campaigns",
    .delete_action = .delete_campaign,
    .delete_noun = "campaign",
};

fn buildMissionBrowserContent(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    tabs_y: i32,
    local_missions: []const @import("../file_source.zig").FileSource.MissionEntry,
    official_missions: []const @import("../file_source.zig").FileSource.MissionEntry,
    tab: types.EditorMissionBrowserTab,
    scroll_offset: *i32,
    button_color: Color,
) !void {
    return buildListBrowserContent(
        mission_list_browser_config,
        elements,
        allocator,
        font_metrics,
        screen,
        tabs_y,
        local_missions,
        official_missions,
        tab,
        scroll_offset,
        button_color,
    );
}

/// The editor browser's campaign content: the shared list-browser body
/// with the EDITOR campaign config (rows open campaigns in the campaign
/// editor).
fn buildEditorCampaignBrowserContent(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    tabs_y: i32,
    local_campaigns: []const @import("../file_source.zig").FileSource.CampaignEntry,
    official_campaigns: []const @import("../file_source.zig").FileSource.CampaignEntry,
    tab: types.CampaignBrowserTab,
    scroll_offset: *i32,
    button_color: Color,
) !void {
    return buildListBrowserContent(
        editor_campaign_list_browser_config,
        elements,
        allocator,
        font_metrics,
        screen,
        tabs_y,
        local_campaigns,
        official_campaigns,
        tab,
        scroll_offset,
        button_color,
    );
}

/// The CAMPAIGN browser (the world map's campaign picker - see DESIGN →
/// Campaigns & the Campaign Editor → Campaign switching): the shared
/// list-browser body with the campaign lists + a Back button, the editor
/// browser's shape minus the kind row / New / Import (campaign creation
/// rides the campaign editor). Rows VIEW the campaign on the map (the
/// pick mutates the session-side graph cache, never a recorded event).
pub fn buildCampaignBrowser(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    local_campaigns: []const @import("../file_source.zig").FileSource.CampaignEntry,
    official_campaigns: []const @import("../file_source.zig").FileSource.CampaignEntry,
    tab: types.CampaignBrowserTab,
    scroll_offset: *i32,
    button_color: Color,
) !void {
    // Full-screen modal background - blocks input to the world map behind
    // it. Reuses the editor browser's metrics (same visual class).
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = screen.position(),
        .width = screen.width,
        .height = screen.height,
        .blocks_input = true,
    } });

    // Tabs top-left, BELOW the global top bar (the always-on-top layer
    // would cover them - the editor browser's kind-row placement).
    const origin = screen.position();
    const tabs_y = origin.y + top_bar_height + load_save_padding;
    try buildListBrowserContent(
        campaign_list_browser_config,
        elements,
        allocator,
        font_metrics,
        screen,
        tabs_y,
        local_campaigns,
        official_campaigns,
        tab,
        scroll_offset,
        button_color,
    );

    // Bottom-left: Back (closes the browser - the same toggle action that
    // opens it from the map's campaign button).
    const button_y = screen.y + screen.height - load_save_padding - panel_button_height;
    try emitPanelButton(
        elements,
        allocator,
        font_metrics,
        .{
            .x = screen.x + load_save_padding,
            .y = button_y,
            .width = load_save_button_width,
            .height = panel_button_height,
        },
        "Back",
        menu_button_font_size,
        .toggle_campaign_browser,
        button_color,
        null,
    );
    // Import (web only): the editor browser's Import discipline over the
    // player-facing surface - campaigns are player acquisitions too (the
    // settled slice-5c placement: the Import button lives in BOTH
    // campaign browsers). The picked campaign .zip extracts into
    // campaigns/ and the rescanned list shows it. Native has no button -
    // drop the extracted folder (or a STORE zip) into the persistent
    // campaigns/ dir by hand.
    if (@import("builtin").target.os.tag == .emscripten) {
        try emitPanelButton(
            elements,
            allocator,
            font_metrics,
            .{
                .x = screen.x + @divTrunc(screen.width - load_save_button_width, 2),
                .y = button_y,
                .width = load_save_button_width,
                .height = panel_button_height,
            },
            "Import",
            menu_button_font_size,
            .import_campaign,
            button_color,
            null,
        );
    }
}

test "buildLoadSavePanel: rows carry refs + actions, scroll window + clamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };

    // Enough rows to overflow the visible window (rows region is roughly
    // 2160 - 2*48 - header(~86) - 32 - 160 - 48 ≈ 1700px → ~14 visible rows).
    var files: [20]@import("../file_source.zig").SaveFileEntry = undefined;
    for (&files, 0..) |*file, i| {
        file.* = .{
            .name = try std.fmt.allocPrint(allocator, "save_{d}.txt", .{i}),
            .path = try std.fmt.allocPrint(allocator, "saves/save_{d}.txt", .{i}),
            .mtime_ns = @intCast(1000 - i),
        };
    }

    var scroll: i32 = 0;
    var elements: UiElementList = .empty;
    try buildLoadSavePanel(&elements, allocator, metrics, screen, &files, &scroll, .{ .r = 50, .g = 50, .b = 50 });

    // The scroll offset was clamped... 20 rows vs ~14 visible → max > 0, but
    // offset 0 stays 0. Rows emitted: only the visible window.
    var row_buttons: usize = 0;
    var first_ref_index: ?u32 = null;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .load_save_row) {
            row_buttons += 1;
            const payload = button.payload.?;
            if (first_ref_index == null) first_ref_index = payload.save_row;
        },
        else => {},
    };
    try std.testing.expect(row_buttons > 0);
    try std.testing.expect(row_buttons < files.len); // window, not all rows
    try std.testing.expectEqual(@as(u32, 0), first_ref_index.?); // starts at scroll 0

    // Scroll to the end: clamp to max_scroll_row, last row visible.
    scroll = 999;
    var elements_end: UiElementList = .empty;
    try buildLoadSavePanel(&elements_end, allocator, metrics, screen, &files, &scroll, .{ .r = 50, .g = 50, .b = 50 });
    var last_ref_index: u32 = 0;
    for (elements_end.items) |element| switch (element) {
        .button => |button| if (button.action == .load_save_row) {
            last_ref_index = button.payload.?.save_row;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(u32, files.len - 1), last_ref_index);
    // Clamped to exactly the last window start.
    const max_scroll_row: i32 = @intCast(files.len - row_buttons);
    try std.testing.expectEqual(max_scroll_row, scroll);

    // Negative scroll clamps to 0.
    scroll = -5;
    var elements_neg: UiElementList = .empty;
    try buildLoadSavePanel(&elements_neg, allocator, metrics, screen, &files, &scroll, .{ .r = 50, .g = 50, .b = 50 });
    try std.testing.expectEqual(@as(i32, 0), scroll);
}

test "buildLoadSavePanel: empty list shows placeholder, Back always emitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };

    var scroll: i32 = 0;
    var elements: UiElementList = .empty;
    try buildLoadSavePanel(&elements, allocator, metrics, screen, &.{}, &scroll, .{ .r = 50, .g = 50, .b = 50 });

    var found_placeholder = false;
    var found_back = false;
    for (elements.items) |element| switch (element) {
        .text_label => |label| if (std.mem.eql(u8, label.text, "No save files")) {
            found_placeholder = true;
        },
        .button => |button| if (button.action == .toggle_load_save_menu) {
            found_back = true;
        },
        else => {},
    };
    try std.testing.expect(found_placeholder);
    try std.testing.expect(found_back);
}

test "buildEditorBrowser: tabs, rows carry payloads + actions, window + clamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    const MissionEntry = @import("../file_source.zig").FileSource.MissionEntry;

    // Enough rows to overflow the visible window (the load-save browser's
    // geometry - ~14 visible rows).
    var missions: [20]MissionEntry = undefined;
    for (&missions, 0..) |*mission, i| {
        mission.* = .{
            .id = "mission_id",
            .path = "missions/mission_id",
            .name = try std.fmt.allocPrint(allocator, "Mission {d}", .{i}),
            .level_count = 1,
            .has_custom_assets = false,
            .author_turns = null,
        };
    }

    var scroll: i32 = 0;
    var campaign_scroll: i32 = 0;
    var elements: UiElementList = .empty;
    try buildEditorBrowser(
        &elements,
        allocator,
        metrics,
        screen,
        .mission,
        &missions,
        &.{},
        .local,
        &scroll,
        &.{},
        &.{},
        .local,
        &campaign_scroll,
        .{ .r = 50, .g = 50, .b = 50 },
    );

    // Both tabs emitted with their payloads; the active one highlighted.
    var found_local_tab = false;
    var found_official_tab = false;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .select_editor_mission_tab) {
            if (button.payload.?.editor_mission_tab == .local) {
                found_local_tab = true;
                try std.testing.expect(button.highlighted);
            }
            if (button.payload.?.editor_mission_tab == .official) {
                found_official_tab = true;
                try std.testing.expect(!button.highlighted);
            }
        },
        else => {},
    };
    try std.testing.expect(found_local_tab);
    try std.testing.expect(found_official_tab);

    // Rows: only the visible window, starting at scroll 0, each carrying its
    // index + the open action.
    var row_buttons: usize = 0;
    var first_row_index: ?u32 = null;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .open_editor_mission_row) {
            row_buttons += 1;
            if (first_row_index == null) first_row_index = button.payload.?.editor_mission_row;
        },
        else => {},
    };
    try std.testing.expect(row_buttons > 0);
    try std.testing.expect(row_buttons < missions.len); // window, not all rows
    try std.testing.expectEqual(@as(u32, 0), first_row_index.?);

    // Scroll past the end clamps to the last window; the last row is visible.
    scroll = 999;
    var elements_end: UiElementList = .empty;
    try buildEditorBrowser(
        &elements_end,
        allocator,
        metrics,
        screen,
        .mission,
        &missions,
        &.{},
        .local,
        &scroll,
        &.{},
        &.{},
        .local,
        &campaign_scroll,
        .{ .r = 50, .g = 50, .b = 50 },
    );
    var last_row_index: u32 = 0;
    for (elements_end.items) |element| switch (element) {
        .button => |button| if (button.action == .open_editor_mission_row) {
            last_row_index = button.payload.?.editor_mission_row;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(u32, missions.len - 1), last_row_index);
    const max_scroll_row: i32 = @intCast(missions.len - row_buttons);
    try std.testing.expectEqual(max_scroll_row, scroll);

    // Negative scroll clamps to 0.
    scroll = -5;
    var elements_neg: UiElementList = .empty;
    try buildEditorBrowser(
        &elements_neg,
        allocator,
        metrics,
        screen,
        .mission,
        &missions,
        &.{},
        .local,
        &scroll,
        &.{},
        &.{},
        .local,
        &campaign_scroll,
        .{ .r = 50, .g = 50, .b = 50 },
    );
    try std.testing.expectEqual(@as(i32, 0), scroll);
}

test "buildEditorBrowser: local rows carry the x delete, official rows never" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    const MissionEntry = @import("../file_source.zig").FileSource.MissionEntry;
    const CampaignEntry = @import("../file_source.zig").FileSource.CampaignEntry;

    const missions = [_]MissionEntry{
        .{ .id = "m", .path = "missions/m", .name = "One", .level_count = 1, .has_custom_assets = false, .author_turns = null, .mtime_ns = 1794681933 * std.time.ns_per_s },
    };
    const campaigns = [_]CampaignEntry{.{ .uuid = "u", .dir = "campaigns/c", .name = "One" }};

    // The mission kind, local tab: every row's x rides the row payload.
    {
        var scroll: i32 = 0;
        var campaign_scroll: i32 = 0;
        var elements: UiElementList = .empty;
        defer elements.deinit(allocator);
        try buildEditorBrowser(&elements, allocator, metrics, screen, .mission, &missions, &.{}, .local, &scroll, &.{}, &.{}, .local, &campaign_scroll, .{ .r = 50, .g = 50, .b = 50 });
        var delete_buttons: usize = 0;
        var saw_timestamp = false;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .delete_editor_mission) {
                delete_buttons += 1;
                try std.testing.expectEqual(@as(u32, 0), button.payload.?.editor_mission_row);
                try std.testing.expect(button.tooltip != null);
            },
            // The recency label (the entry carries a nonzero mtime).
            .text_label => |label| if (label.text.len > 0 and label.text[0] == '2') {
                saw_timestamp = true;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 1), delete_buttons);
        try std.testing.expect(saw_timestamp);
    }

    // The campaign kind, local tab: the shared delete_campaign action.
    {
        var scroll: i32 = 0;
        var campaign_scroll: i32 = 0;
        var elements: UiElementList = .empty;
        defer elements.deinit(allocator);
        try buildEditorBrowser(&elements, allocator, metrics, screen, .campaign, &.{}, &.{}, .local, &scroll, &campaigns, &.{}, .local, &campaign_scroll, .{ .r = 50, .g = 50, .b = 50 });
        var delete_buttons: usize = 0;
        for (elements.items) |element| switch (element) {
            .button => |button| if (button.action == .delete_campaign) {
                delete_buttons += 1;
                try std.testing.expectEqual(@as(u32, 0), button.payload.?.campaign_row);
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 1), delete_buttons);
    }

    // The official tabs: NO delete button (embedded + read-only).
    {
        var scroll: i32 = 0;
        var campaign_scroll: i32 = 0;
        var elements: UiElementList = .empty;
        defer elements.deinit(allocator);
        try buildEditorBrowser(&elements, allocator, metrics, screen, .mission, &.{}, &missions, .official, &scroll, &.{}, &.{}, .local, &campaign_scroll, .{ .r = 50, .g = 50, .b = 50 });
        for (elements.items) |element| switch (element) {
            .button => |button| try std.testing.expect(button.action != .delete_editor_mission),
            else => {},
        };
    }
}

test "buildEditorBrowser: empty lists show per-tab placeholders, Back always emitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };

    for ([_]types.EditorMissionBrowserTab{ .local, .official }) |tab| {
        var scroll: i32 = 0;
        var campaign_scroll: i32 = 0;
        var elements: UiElementList = .empty;
        try buildEditorBrowser(
            &elements,
            allocator,
            metrics,
            screen,
            .mission,
            &.{},
            &.{},
            tab,
            &scroll,
            &.{},
            &.{},
            .local,
            &campaign_scroll,
            .{ .r = 50, .g = 50, .b = 50 },
        );

        const expected_text = switch (tab) {
            .local => "No saved missions yet",
            .official => "No official missions",
        };
        var found_placeholder = false;
        var found_back = false;
        for (elements.items) |element| switch (element) {
            .text_label => |label| if (std.mem.eql(u8, label.text, expected_text)) {
                found_placeholder = true;
            },
            .button => |button| if (button.action == .toggle_editor_browser) {
                found_back = true;
            },
            else => {},
        };
        try std.testing.expect(found_placeholder);
        try std.testing.expect(found_back);
    }
}

test "buildEditorBrowser: kind tabs derived from the enum, one New button derived from the active kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };

    var scroll: i32 = 0;
    var campaign_scroll: i32 = 0;
    var elements: UiElementList = .empty;
    try buildEditorBrowser(
        &elements,
        allocator,
        metrics,
        screen,
        .mission,
        &.{},
        &.{},
        .local,
        &scroll,
        &.{},
        &.{},
        .local,
        &campaign_scroll,
        .{ .r = 50, .g = 50, .b = 50 },
    );

    // The kind tab row walks the same comptime spec list this test walks
    // (derived expectations - a new editor kind can't appear as a tab
    // without appearing here too): one tab per spec, in spec order, each
    // carrying its kind payload + the kind-switch action, the active
    // kind highlighted, and its label text emitted.
    var kind_tab_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .select_editor_kind_tab) {
            const spec = editor_browser_kind_specs[kind_tab_count];
            kind_tab_count += 1;
            try std.testing.expectEqual(spec.kind, button.payload.?.editor_kind);
            try std.testing.expectEqual(spec.kind == .mission, button.highlighted);
        },
        else => {},
    };
    try std.testing.expectEqual(editor_browser_kind_specs.len, kind_tab_count);
    for (editor_browser_kind_specs) |spec| {
        var found_label = false;
        for (elements.items) |element| switch (element) {
            .text_label => |label| if (std.mem.eql(u8, label.text, spec.label)) {
                found_label = true;
            },
            else => {},
        };
        try std.testing.expect(found_label);
    }

    // ONE New button (not one per tab), labeled from the active kind,
    // firing the fresh-mission open.
    var new_button_count: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .new_editor_mission) {
            new_button_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), new_button_count);
    var found_new_label = false;
    for (elements.items) |element| switch (element) {
        .text_label => |label| if (std.mem.eql(
            u8,
            label.text,
            editorBrowserNewButtonLabel(.mission),
        )) {
            found_new_label = true;
        },
        else => {},
    };
    try std.testing.expect(found_new_label);
}

test "buildCampaignBrowser: tabs, rows carry view payloads, Back fires the toggle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };

    const local = [_]@import("../file_source.zig").FileSource.CampaignEntry{
        .{ .uuid = "zeta-uuid", .dir = "campaigns/zeta_lands", .name = "Zeta Lands" },
    };
    const official = [_]@import("../file_source.zig").FileSource.CampaignEntry{
        .{ .uuid = "main-uuid", .dir = "campaigns/main_campaign", .name = "Main Campaign" },
    };

    for ([_]types.CampaignBrowserTab{ .local, .official }) |tab| {
        var scroll: i32 = 0;
        var elements: UiElementList = .empty;
        try buildCampaignBrowser(
            &elements,
            allocator,
            metrics,
            screen,
            &local,
            &official,
            tab,
            &scroll,
            .{ .r = 50, .g = 50, .b = 50 },
        );

        // The full-screen modal background blocks input (shields the map).
        try std.testing.expect(elements.items[0].nine_slice_panel.blocks_input);

        var found_row = false;
        var found_row_label = false;
        var found_back = false;
        const expected_name = switch (tab) {
            .local => "Zeta Lands",
            .official => "Main Campaign",
        };
        for (elements.items) |element| switch (element) {
            .button => |button| switch (button.action) {
                .view_campaign_row => {
                    found_row = true;
                    try std.testing.expectEqual(@as(u32, 0), button.payload.?.campaign_row);
                },
                .toggle_campaign_browser => found_back = true,
                else => {},
            },
            .text_label => |label| {
                if (std.mem.eql(u8, label.text, expected_name)) found_row_label = true;
            },
            else => {},
        };
        try std.testing.expect(found_row);
        try std.testing.expect(found_row_label);
        try std.testing.expect(found_back);
    }
}

test "buildEditorBrowser: the campaign kind lists campaigns, rows open the campaign editor, New Campaign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };

    const campaigns = [_]@import("../file_source.zig").FileSource.CampaignEntry{
        .{ .uuid = "u1", .dir = "campaigns/one", .name = "One" },
        .{ .uuid = "u2", .dir = "campaigns/two", .name = "Two" },
    };

    var scroll: i32 = 0;
    var campaign_scroll: i32 = 0;
    var elements: UiElementList = .empty;
    try buildEditorBrowser(
        &elements,
        allocator,
        metrics,
        screen,
        .campaign,
        &.{},
        &.{},
        .local,
        &scroll,
        &campaigns,
        &.{},
        .local,
        &campaign_scroll,
        .{ .r = 50, .g = 50, .b = 50 },
    );

    // One row per campaign, each carrying the editor ROW action (not the
    // world-map browser's view action) + the campaign_row payload.
    var row_count: usize = 0;
    var view_rows: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .open_editor_campaign_row) {
            row_count += 1;
            _ = button.payload.? == .campaign_row;
        } else if (button.action == .view_campaign_row) {
            view_rows += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(campaigns.len, row_count);
    try std.testing.expectEqual(@as(usize, 0), view_rows);

    // The New button fires the CAMPAIGN open (the mission open must not
    // fire from the campaign kind), labeled "New Campaign".
    var new_campaign_buttons: usize = 0;
    var new_mission_buttons: usize = 0;
    for (elements.items) |element| switch (element) {
        .button => |button| if (button.action == .new_editor_campaign) {
            new_campaign_buttons += 1;
        } else if (button.action == .new_editor_mission) {
            new_mission_buttons += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), new_campaign_buttons);
    try std.testing.expectEqual(@as(usize, 0), new_mission_buttons);
    var found_label = false;
    for (elements.items) |element| switch (element) {
        .text_label => |label| if (std.mem.eql(u8, label.text, "New Campaign")) {
            found_label = true;
        },
        else => {},
    };
    try std.testing.expect(found_label);
}
