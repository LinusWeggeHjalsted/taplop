//! The full-screen browsers: the load-save browser (main menu) + the
//! editor browser with its mission-list tab (editor + main menu) - one
//! row/scrollback machinery, two surfaces (DESIGN → UI Framework). One of
//! menus.zig's per-surface splits; the shared scrollbar emitter lives in
//! emit.zig.

const std = @import("std");
const types = @import("../types.zig");
const ui_element = @import("element.zig");
const emit = @import("emit.zig");

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
            // Label: filename minus extension, centered like a panel button
            // label (horizontal via measurement, vertical via the glyph cell).
            const file = save_files[index];
            const label = file.name[0 .. file.name.len - ".txt".len];
            const label_width = font_metrics.measureSpanWidth(text(label), load_save_row_font_size);
            const label_box = cell.placeCenter(label_width, load_save_row_font_size);
            try elements.append(allocator, .{ .text_label = .{
                .text = label,
                .screen_position = label_box.position(),
                .font_size = load_save_row_font_size,
                .blocks_input = false,
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
    if (@import("builtin").os.tag == .emscripten) {
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
    };
}

/// The New button's label, derived from the ACTIVE kind - one button, not
/// one per tab (the tab row already shows the kinds; buttons for content
/// that isn't on screen would be dead buttons). Exhaustive like the tab
/// label: a new editor kind names its New button here.
fn editorBrowserNewButtonLabel(kind: types.EditorKind) []const u8 {
    return switch (kind) {
        .mission => "New Mission",
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
        .new_editor_mission,
        button_color,
        null,
    );
    // Import (web only - the load-save browser's Import discipline): opens
    // a file picker for a mission .zip; the picked zip extracts into
    // missions/ and the rescanned list shows it. Centered along the
    // bottom, between the Back and New buttons. Native has no button -
    // drop the extracted folder (or a STORE zip) into the persistent
    // missions/ dir by hand.
    if (@import("builtin").os.tag == .emscripten) {
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
            .import_editor_mission,
            button_color,
            null,
        );
    }
}

/// The editor browser's MISSION-kind content: the Your Missions /
/// Official list tabs + the mission rows + scrollbar (the pre-kind-tab
/// browser body). One content builder per editor kind - the parent
/// switch routes here. `tabs_y` is the content top (below the kind row).
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
    const content_x = screen.x + load_save_padding;
    const content_width = screen.width - 2 * load_save_padding;
    const origin = screen.position();

    // Tabs top-left (the tabs ARE the header, like the sprite picker).
    // Darkest background panels; the active tab's highlight outline is the
    // indication, no tint change (the picker's convention).
    const tab_specs = [_]struct { tab: types.EditorMissionBrowserTab, label: []const u8 }{
        .{ .tab = .local, .label = "Your Missions" },
        .{ .tab = .official, .label = "Official" },
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
            .action = .select_editor_mission_tab,
            .payload = .{ .editor_mission_tab = spec.tab },
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

    const missions = switch (tab) {
        .local => local_missions,
        .official => official_missions,
    };

    // Clamp the scroll offset (authoritative - the input handler can't know
    // max_scroll_row without the row count).
    const total_rows: usize = missions.len;
    const max_scroll_row: i32 = @intCast(total_rows -| @min(total_rows, visible_rows));
    if (scroll_offset.* < 0) scroll_offset.* = 0;
    if (scroll_offset.* > max_scroll_row) scroll_offset.* = max_scroll_row;
    const scrolls = total_rows > visible_rows;

    if (total_rows == 0) {
        const empty_text = switch (tab) {
            .local => "No saved missions yet",
            .official => "No official missions",
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
                .action = .open_editor_mission_row,
                .payload = .{ .editor_mission_row = @intCast(index) },
            } });
            const label = missions[index].name;
            const label_width = font_metrics.measureSpanWidth(text(label), load_save_row_font_size);
            const label_box = cell.placeCenter(label_width, load_save_row_font_size);
            try elements.append(allocator, .{ .text_label = .{
                .text = label,
                .screen_position = label_box.position(),
                .font_size = load_save_row_font_size,
                .blocks_input = false,
            } });
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
        .{ .r = 50, .g = 50, .b = 50 },
    );
    try std.testing.expectEqual(@as(i32, 0), scroll);
}

test "buildEditorBrowser: empty lists show per-tab placeholders, Back always emitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };

    for ([_]types.EditorMissionBrowserTab{ .local, .official }) |tab| {
        var scroll: i32 = 0;
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
