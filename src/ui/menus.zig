//! Full-screen menus + browsers: the options menu, main menu, the
//! load-save browser, the editor mission browser, the credits panel, and
//! the settings panel (toggles/choices/sliders — see DESIGN → UI
//! Framework → Settings screen).

const std = @import("std");
const types = @import("../types.zig");
const ui_element = @import("element.zig");
const emit = @import("emit.zig");
const ui_tooltip = @import("tooltip.zig");
const state = @import("../state.zig");

const Action = types.Action;
const Rectangle = types.Rectangle;
const Color = types.Color;
const weapon_type_count = @typeInfo(types.WeaponType).@"enum".fields.len;
const Tooltip = ui_element.Tooltip;
const TooltipRow = ui_element.TooltipRow;
const text = ui_element.text;
const FontMetrics = ui_element.FontMetrics;
const UiElement = ui_element.UiElement;
const UiElementList = ui_element.UiElementList;
const Button = ui_element.Button;
const Slider = ui_element.Slider;
const SlotRef = ui_element.SlotRef;
const rowWidth = ui_element.rowWidth;
const Row = ui_element.Row;
const ui_gap = ui_element.ui_gap;
const panel_button_height = ui_element.panel_button_height;
const menu_button_width = ui_element.menu_button_width;
const menu_button_font_size = ui_element.menu_button_font_size;
const main_menu_title_font_size = ui_element.main_menu_title_font_size;
const main_menu_title_gap = ui_element.main_menu_title_gap;
const middle_panel_header_height = ui_element.middle_panel_header_height;
const middle_panel_header_font_size = ui_element.middle_panel_header_font_size;
const lineHeight = ui_element.lineHeight;
const buildMissionFail = @import("screens.zig").buildMissionFail;
const spanRow = ui_tooltip.spanRow;
const emitPanelButton = emit.emitPanelButton;


/// Build the options menu: a full-screen 9-slice panel background with a
/// centered stack of `menu_button_width` buttons (same design as the main
/// menu). Context-specific: the button list depends on the current screen.
/// Continue carries `.toggle_options_menu` (the toggle closes the menu);
/// Save carries `.save_game`. Rendered on top of the bottom bar when
/// `options_menu_open` is set, like the error popup. See DESIGN → UI
/// Framework.
pub fn buildOptionsMenu(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    current_screen: state.Screen,
    /// The active editor run, if any (.playtest / .validate while the
    /// editor sits dormant behind the level screen). Relabels the level
    /// screen's restart/exit buttons for the run ("Restart Playtest" etc.)
    /// and hides the campaign Export Save path — the run's player_data is
    /// temporary, rebuilt from the editor loadout (see DESIGN → Level
    /// Editor → Playtest/validate framing).
    editor_run: ?types.EditorMode,
    button_color: Color,
    /// Where the exported save lands, for the Export Save tooltip. Native:
    /// the resolved persistent dir (tooltip: "Saves to <dir>/saves/"). Web:
    /// null — the export IS a browser download (tooltip: "Triggers a file
    /// download"). Threaded from `SessionState.persistent_dir_path` (set
    /// once by the entry file; see its doc).
    persistent_dir_path: ?[]const u8,
) !void {
    // Full-screen panel background.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = screen.position(),
        .width = screen.width,
        .height = screen.height,
    } });

    const MenuButton = struct { label: []const u8, action: Action, tooltip: ?Tooltip = null };
    var buttons: [8]MenuButton = undefined;
    var button_count: usize = 0;

    buttons[button_count] = .{ .label = "Continue", .action = .toggle_options_menu };
    button_count += 1;

    // Level-only exit paths (restart / exit mission). Hub has no mission in
    // progress to restart or abandon. During an editor run the buttons
    // name the RUN, not the mission — and restart genuinely re-runs it
    // (end_level's editor guard chains a fresh start on the restart
    // continuation; an exit drops back to the editor).
    if (current_screen == .level) {
        const run_noun: []const u8 = if (editor_run) |run_mode| switch (run_mode) {
            .playtest => "Playtest",
            .validate => "Validation",
            .edit => "Mission",
        } else "Mission";
        buttons[button_count] = .{
            .label = try std.fmt.allocPrint(allocator, "Restart {s}", .{run_noun}),
            .action = .restart_mission,
        };
        button_count += 1;
        buttons[button_count] = .{
            .label = try std.fmt.allocPrint(allocator, "Exit {s}", .{run_noun}),
            .action = .exit_mission,
        };
        button_count += 1;
    }

    // Where the exported save goes: on native, the timestamped save lands
    // in <persistent dir>/saves/ (the autosave update is a side effect); on
    // web it's offered as a browser download (no user-visible path).
    // Hidden in the editor — the save the player expects there is the
    // MISSION being edited (a separate future slice), not the campaign
    // save — and hidden during an editor run (playtest/validate): the
    // run's player_data is temporary (rebuilt from the editor loadout,
    // restored on exit), so an export mid-run would write the throwaway
    // run data as a campaign save. `save_game` is button-only (no
    // keybind), so hiding the button removes the path entirely.
    if (current_screen != .editor and editor_run == null) {
        const export_save_body = if (persistent_dir_path) |dir|
            try std.fmt.allocPrint(allocator, "Saves to {s}/saves/", .{dir})
        else
            "Triggers a file download";
        buttons[button_count] = .{
            .label = "Export Save",
            .action = .save_game,
            .tooltip = .{ .body = try allocator.dupe(TooltipRow, &.{try spanRow(allocator, text(export_save_body))}) },
        };
        button_count += 1;
    }

    // The editor's own save (the mission being edited) — replaces the
    // campaign Export Save path above, which is hidden in the editor.
    // Also on ctrl+S (the binding ships in default_settings.txt).
    if (current_screen == .editor) {
        const save_body = if (persistent_dir_path) |dir|
            try std.fmt.allocPrint(allocator, "Ctrl+S — saves to {s}/missions/", .{dir})
        else
            "Ctrl+S — saves to the browser's persistent storage";
        buttons[button_count] = .{
            .label = "Save Mission",
            .action = .save_editor_mission,
            .tooltip = .{ .body = try allocator.dupe(TooltipRow, &.{try spanRow(allocator, text(save_body))}) },
        };
        button_count += 1;

        // The mission export: a .zip of the saved mission (save happens
        // first as part of the export). Native: the file lands in
        // <persistent dir>/exported_missions/; web: it's offered as a
        // browser download.
        const export_body = if (persistent_dir_path) |dir|
            try std.fmt.allocPrint(allocator, "Zips the saved mission to {s}/exported_missions/", .{dir})
        else
            "Downloads the saved mission as a .zip";
        buttons[button_count] = .{
            .label = "Export Mission",
            .action = .export_editor_mission,
            .tooltip = .{ .body = try allocator.dupe(TooltipRow, &.{try spanRow(allocator, text(export_body))}) },
        };
        button_count += 1;

        // Open an EXISTING mission into the editor (the mission browser):
        // your saved/imported missions + the official campaign ones, two
        // tabs. Opening replaces the mission being edited (no unsaved-
        // changes confirm — save first if in doubt; ctrl+S is cheap).
        // Also on ctrl+O (the binding ships in default_settings.txt).
        buttons[button_count] = .{
            .label = "Open Mission",
            .action = .toggle_editor_mission_browser,
            .tooltip = .{ .body = try allocator.dupe(TooltipRow, &.{try spanRow(allocator, text(
                "Ctrl+O — browse your saved missions and the official ones",
            ))}) },
        };
        button_count += 1;

        // The fresh-mission open: the main-menu Editor button's action
        // from inside the editor — replaces the mission being edited
        // with a new one-level template mission (no unsaved-changes
        // confirm, same as an open — save first if in doubt). Also on
        // ctrl+N (the binding ships in default_settings.txt).
        buttons[button_count] = .{
            .label = "New Mission",
            .action = .new_editor_mission,
            .tooltip = .{ .body = try allocator.dupe(TooltipRow, &.{try spanRow(allocator, text(
                "Ctrl+N — replaces the mission being edited with a fresh one",
            ))}) },
        };
        button_count += 1;
    }

    // Settings: opens the settings overlay on top of this one (drill-in).
    // Present in every context the options menu appears in (level + hub).
    buttons[button_count] = .{ .label = "Settings", .action = .open_settings };
    button_count += 1;

    buttons[button_count] = .{ .label = "Exit to Main Menu", .action = .exit_to_menu };
    button_count += 1;

    const total_height = rowWidth(@intCast(button_count), panel_button_height, ui_gap);
    const origin = screen
        .placeCenter(menu_button_width, total_height)
        .position();

    for (buttons[0..button_count], 0..) |menu_button, index| {
        const cell: Rectangle = .{
            .x = origin.x,
            .y = origin.y + @as(i32, @intCast(index)) * (panel_button_height + ui_gap),
            .width = menu_button_width,
            .height = panel_button_height,
        };
        try emitPanelButton(
            elements,
            allocator,
            font_metrics,
            cell,
            menu_button.label,
            menu_button_font_size,
            menu_button.action,
            button_color,
            menu_button.tooltip,
        );
    }
}

/// Build the main-menu button stack: fixed-size buttons centered as a group
/// on `screen`, spaced by `ui_gap`, each with a centered text label. The
/// Continue button is emitted only when `continue_available` (there is a game
/// to resume — populated PlayerData).
pub fn buildMainMenu(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    continue_available: bool,
    button_color: Color,
) !void {
    const MenuButton = struct { label: []const u8, action: Action };
    var buttons: [6]MenuButton = undefined;
    var button_count: usize = 0;
    if (continue_available) {
        buttons[button_count] = .{ .label = "Continue", .action = .continue_game };
        button_count += 1;
    }
    buttons[button_count] = .{ .label = "New Game", .action = .new_game };
    button_count += 1;
    buttons[button_count] = .{ .label = "Load Save", .action = .toggle_load_save_menu };
    button_count += 1;
    // Dev entry point (hardcoded beginnings mission).
    buttons[button_count] = .{ .label = "Editor", .action = .open_editor };
    button_count += 1;
    buttons[button_count] = .{ .label = "Settings", .action = .open_settings };
    button_count += 1;
    buttons[button_count] = .{ .label = "Credits", .action = .open_credits };
    button_count += 1;

    const total_height = rowWidth(@intCast(button_count), panel_button_height, ui_gap);
    // The title + button stack center together as one block: title band on
    // top of the stack, both centered by one `placeCenter` over the combined
    // height. Gap between title and first button = `main_menu_title_gap`.
    const title = "taplop";
    const title_width = font_metrics.measureSpanWidth(text(title), main_menu_title_font_size);
    const block_height = main_menu_title_gap + main_menu_title_font_size + total_height;
    const origin = screen
        .placeCenter(menu_button_width, block_height)
        .position();

    try elements.append(allocator, .{ .text_label = .{
        .text = title,
        .screen_position = .{
            .x = origin.x + @divTrunc(menu_button_width - title_width, 2),
            .y = origin.y,
        },
        .font_size = main_menu_title_font_size,
        .blocks_input = false,
    } });
    const buttons_origin_y = origin.y + main_menu_title_gap + main_menu_title_font_size;

    for (buttons[0..button_count], 0..) |menu_button, index| {
        const cell: Rectangle = .{
            .x = origin.x,
            .y = buttons_origin_y + @as(i32, @intCast(index)) * (panel_button_height + ui_gap),
            .width = menu_button_width,
            .height = panel_button_height,
        };
        try emitPanelButton(
            elements,
            allocator,
            font_metrics,
            cell,
            menu_button.label,
            menu_button_font_size,
            menu_button.action,
            button_color,
            null,
        );
    }
}

// --- Load-save browser (main menu, full screen) ---

pub const load_save_header_font_size: i32 = 72;
pub const load_save_header_gap: i32 = 32;
pub const load_save_row_font_size: i32 = 56;
/// One save row's height. The scroll unit is the full row PITCH (height +
/// gap) so scrolled text sits at identical y positions at every offset.
pub const load_save_row_height: i32 = 112;
pub const load_save_row_gap: i32 = 8;
pub const load_save_padding: i32 = 48;
pub const load_save_button_gap: i32 = 48; // gap between rows region and bottom buttons
pub const load_save_scrollbar_width: i32 = 12;
pub const load_save_scrollbar_gap: i32 = 16;
/// Import/Back button size (bottom corners). Import label is long, so the
/// buttons are wider than tall menu buttons but reuse the menu font.
pub const load_save_button_width: i32 = 768;

/// Build the load-save browser: a full-screen modal panel listing
/// `save_files` (newest first — the slice arrives pre-sorted from
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
    // Full-screen modal background — blocks input to the main-menu buttons
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

    // Clamp the scroll offset (authoritative — the input handler can't know
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
            content_width - load_save_scrollbar_width - load_save_scrollbar_gap
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
                .ref = .{ .save_file = @intCast(index) },
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

        // Scrollbar: track + proportional thumb along the rows region, same
        // fixed grays as the error popup's scrollbar.
        if (scrolls) {
            const scrollbar_x = content_x + content_width - load_save_scrollbar_width;
            const track_color: types.Color = .{ .r = 80, .g = 80, .b = 80 };
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = scrollbar_x, .y = rows_y },
                .width = load_save_scrollbar_width,
                .height = rows_height,
                .color = track_color,
            } });
            const visible_span_rows: i32 = @intCast(@min(total_rows, visible_rows));
            const track_travel = rows_height - visible_span_rows * row_pitch;
            const thumb_height = @max(@as(i32, 40), visible_span_rows * row_pitch);
            const thumb_y = rows_y + if (max_scroll_row == 0)
                0
            else
                @divTrunc(scroll_offset.* * track_travel, max_scroll_row);
            const thumb_color: types.Color = .{ .r = 180, .g = 180, .b = 180 };
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = scrollbar_x, .y = thumb_y },
                .width = load_save_scrollbar_width,
                .height = thumb_height,
                .color = thumb_color,
            } });
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

// --- Editor mission browser (editor, full screen) ---

/// Build the editor's mission browser: a full-screen modal panel mirroring
/// the load-save browser — two tab buttons top-left (Your Missions /
/// Official — the sprite picker's tab pattern), one clickable row per
/// mission (display name; a click opens it in the editor via `open_editor`,
/// replacing the mission being edited), a Back button bottom-left. The
/// web-only Import button (zip upload) lands with the import slice.
/// Overflowing lists scroll with the load-save browser's whole-row model;
/// the scroll offset clamps here (authoritative — the view is the only
/// place that knows the max). Barebones like the load-save browser (same
/// polish slice owns richer row visuals). See DESIGN → Architecture →
/// Level Editor → The mission browser.
pub fn buildEditorMissionBrowser(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    local_missions: []const @import("../file_source.zig").FileSource.MissionEntry,
    official_missions: []const @import("../file_source.zig").FileSource.MissionEntry,
    tab: types.EditorMissionBrowserTab,
    scroll_offset: *i32,
    button_color: Color,
) !void {
    // Full-screen modal background — blocks input to the editor UI behind
    // it. Reuses the load-save browser's metrics (same visual class).
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = screen.position(),
        .width = screen.width,
        .height = screen.height,
        .blocks_input = true,
    } });

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
            .screen_position = .{ .x = tab_x, .y = origin.y + load_save_padding },
            .width = tab_width,
            .height = middle_panel_header_height,
            .color = button_color,
        } });
        try elements.append(allocator, .{ .button = .{
            .screen_position = .{ .x = tab_x, .y = origin.y + load_save_padding },
            .width = tab_width,
            .height = middle_panel_header_height,
            .action = .select_editor_mission_tab,
            .editor_mission_tab = spec.tab,
            .highlighted = active,
        } });
        try elements.append(allocator, .{ .text_label = .{
            .text = spec.label,
            .screen_position = .{
                .x = tab_x + ui_gap,
                .y = origin.y + load_save_padding + @divFloor(
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
    const rows_y = origin.y + load_save_padding + middle_panel_header_height + load_save_header_gap;
    const rows_bottom = screen.y + screen.height - load_save_padding -
        panel_button_height - load_save_button_gap;
    const rows_height = rows_bottom - rows_y;
    const row_pitch = load_save_row_height + load_save_row_gap;
    const visible_rows: usize = @intCast(@max(0, @divTrunc(rows_height, row_pitch)));

    const missions = switch (tab) {
        .local => local_missions,
        .official => official_missions,
    };

    // Clamp the scroll offset (authoritative — the input handler can't know
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
            content_width - load_save_scrollbar_width - load_save_scrollbar_gap
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
            // SlotRef pattern, via the newer Button-payload convention —
            // rows are never drag sources, so no SlotRef).
            try elements.append(allocator, .{ .button = .{
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .action = .open_editor_mission_row,
                .editor_mission_row = @intCast(index),
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

        // Scrollbar: track + proportional thumb, the load-save browser's
        // exact model.
        if (scrolls) {
            const scrollbar_x = content_x + content_width - load_save_scrollbar_width;
            const track_color: types.Color = .{ .r = 80, .g = 80, .b = 80 };
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = scrollbar_x, .y = rows_y },
                .width = load_save_scrollbar_width,
                .height = rows_height,
                .color = track_color,
            } });
            const visible_span_rows: i32 = @intCast(@min(total_rows, visible_rows));
            const track_travel = rows_height - visible_span_rows * row_pitch;
            const thumb_height = @max(@as(i32, 40), visible_span_rows * row_pitch);
            const thumb_y = rows_y + if (max_scroll_row == 0)
                0
            else
                @divTrunc(scroll_offset.* * track_travel, max_scroll_row);
            const thumb_color: types.Color = .{ .r = 180, .g = 180, .b = 180 };
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = .{ .x = scrollbar_x, .y = thumb_y },
                .width = load_save_scrollbar_width,
                .height = thumb_height,
                .color = thumb_color,
            } });
        }
    }

    // Bottom-left: Back (closes the browser — same toggle action that
    // opens it).
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
        .toggle_editor_mission_browser,
        button_color,
        null,
    );
    // Bottom-right: Import (web only — the load-save browser's Import
    // discipline): opens a file picker for a mission .zip; the picked zip
    // extracts into missions/ and the rescanned list shows it. Native has
    // no button — drop the extracted folder (or a STORE zip) into the
    // persistent missions/ dir by hand.
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
            .import_editor_mission,
            button_color,
            null,
        );
    }
}

// --- Credits screen (main menu, full screen) ---

pub const credits_header_font_size: i32 = 96;
pub const credits_header_gap: i32 = 80;
/// Name line font size — larger than the roles line so each person reads
/// as a heading above their credits.
pub const credits_name_font_size: i32 = 72;
/// Roles line font size — the credit detail under each name.
pub const credits_role_font_size: i32 = 48;
/// Gap between a person's name and their roles line.
pub const credits_name_to_role_gap: i32 = 16;
/// Gap between each person block (name + roles).
pub const credits_person_gap: i32 = 64;
pub const credits_padding: i32 = 48;
pub const credits_button_gap: i32 = 48;
/// Back button size (bottom-left). Matches the load-save Back button so the
/// two main-menu overlays feel consistent.
pub const credits_button_width: i32 = 768;

/// Build the credits screen: a full-screen modal panel with a centered
/// "Credits" header, three person blocks (name in a larger font above their
/// roles in a smaller font, gaps between each person), and a Back button in
/// the bottom-left. The panel blocks input to the main-menu buttons behind
/// it. The Back button reuses the `.open_credits` action (toggle semantics —
/// same pattern as the load-save browser's Back button).
pub fn buildCreditsPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    button_color: Color,
) !void {
    // Full-screen modal background — blocks input to the main-menu buttons
    // behind it.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = screen.position(),
        .width = screen.width,
        .height = screen.height,
        .blocks_input = true,
    } });

    const content_x = screen.x + credits_padding;
    const content_width = screen.width - 2 * credits_padding;

    // Header, centered horizontally near the top.
    const header_text = "Credits";
    const header_width = font_metrics.measureSpanWidth(text(header_text), credits_header_font_size);
    const header_x = content_x + @divTrunc(content_width - header_width, 2);
    const header_y = screen.y + credits_padding;
    try elements.append(allocator, .{ .text_label = .{
        .text = header_text,
        .screen_position = .{ .x = header_x, .y = header_y },
        .font_size = credits_header_font_size,
        .blocks_input = false,
    } });

    // Each person is a block: name (larger font) on its own line, roles
    // (smaller font) on the next line. A gap separates each person block.
    const Credit = struct { name: []const u8, roles: []const u8 };
    const credits = [_]Credit{
        .{ .name = "Linus W. Hjalsted", .roles = "game director, game design, program design, UI/UX design, level design" },
        .{ .name = "Cille R. K. Abildhauge", .roles = "art director, graphics, world building" },
        .{ .name = "Victor H. B. Willaredt", .roles = "sound director, sound design, music" },
    };
    const name_height = lineHeight(credits_name_font_size);
    const role_height = lineHeight(credits_role_font_size);
    const person_height = name_height + credits_name_to_role_gap + role_height;
    const block_height = rowWidth(credits.len, person_height, credits_person_gap);
    // Vertically center the credit block in the space between the header
    // and the bottom buttons.
    const buttons_top = screen.y + screen.height - credits_padding -
        panel_button_height - credits_button_gap;
    const block_y = header_y + lineHeight(credits_header_font_size) +
        @divTrunc(buttons_top - (header_y + lineHeight(credits_header_font_size)) - block_height, 2);
    for (credits, 0..) |credit, index| {
        const person_y = block_y + @as(i32, @intCast(index)) * (person_height + credits_person_gap);

        const name_width = font_metrics.measureSpanWidth(text(credit.name), credits_name_font_size);
        const name_x = content_x + @divTrunc(content_width - name_width, 2);
        try elements.append(allocator, .{ .text_label = .{
            .text = credit.name,
            .screen_position = .{ .x = name_x, .y = person_y },
            .font_size = credits_name_font_size,
            .blocks_input = false,
        } });

        const role_width = font_metrics.measureSpanWidth(text(credit.roles), credits_role_font_size);
        const role_x = content_x + @divTrunc(content_width - role_width, 2);
        const role_y = person_y + name_height + credits_name_to_role_gap;
        try elements.append(allocator, .{ .text_label = .{
            .text = credit.roles,
            .screen_position = .{ .x = role_x, .y = role_y },
            .font_size = credits_role_font_size,
            .blocks_input = false,
        } });
    }

    // Back button, bottom-left.
    const button_y = screen.y + screen.height - credits_padding - panel_button_height;
    try emitPanelButton(
        elements,
        allocator,
        font_metrics,
        .{
            .x = content_x,
            .y = button_y,
            .width = credits_button_width,
            .height = panel_button_height,
        },
        "Back",
        menu_button_font_size,
        .open_credits,
        button_color,
        null,
    );
}

// --- Settings screen (full screen, overlay) ---

pub const settings_padding: i32 = 48;
pub const settings_header_font_size: i32 = 96;
pub const settings_header_gap: i32 = 64;
pub const settings_row_font_size: i32 = 56;
pub const settings_row_height: i32 = 120;
pub const settings_row_gap: i32 = 32;
pub const settings_label_to_control_gap: i32 = 48;
pub const settings_button_gap: i32 = 48;
/// Back button size (bottom-left). Matches the load-save / credits Back
/// buttons so the main-menu overlays feel consistent.
pub const settings_button_width: i32 = 768;
/// Toggle button (On/Off) width — sits in the control area of a row.
pub const settings_toggle_width: i32 = 400;
/// Camera-zoom choice button width (one of 4).
pub const settings_choice_button_width: i32 = 240;
/// Player-color swatch size (one of 6).
pub const settings_swatch_size: i32 = 120;
pub const settings_swatch_gap: i32 = 16;
/// Slider track width.
pub const settings_slider_width: i32 = 800;
pub const settings_slider_value_gap: i32 = 32;

/// Emit a settings control button: a tinted 9-slice panel + a button
/// carrying `setting_ref` (the field identity) + a centered text label.
/// Like `emitPanelButton` but for the settings binding (setting_ref on the
/// button, not a SlotRef) with a `highlighted` flag for the active choice.
fn emitSettingButton(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell: Rectangle,
    label: []const u8,
    font_size: i32,
    sref: types.SettingRef,
    highlighted: bool,
    button_color: Color,
) !void {
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .action = .change_setting,
        .setting_ref = sref,
        .highlighted = highlighted,
    } });
    const label_width = font_metrics.measureSpanWidth(text(label), font_size);
    const label_box = cell.placeCenter(label_width, font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = label_box.position(),
        .font_size = font_size,
        .blocks_input = false,
    } });
}

/// Build the settings screen: a full-screen modal panel with a centered
/// "Settings" header, a column of control rows (toggle/choice — sliders
/// land in slice 3b), and a Back button in the bottom-left. The panel
/// blocks input to the surface behind it (main menu or the options menu).
/// See DESIGN → UI Framework → Settings screen.
pub fn buildSettingsPanel(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    settings: types.Settings,
    player_gradient: types.ColorGradient,
    button_color: Color,
) !void {
    // Full-screen modal background — blocks input to the surface behind it.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = screen.position(),
        .width = screen.width,
        .height = screen.height,
        .blocks_input = true,
    } });

    const content_x = screen.x + settings_padding;
    const content_width = screen.width - 2 * settings_padding;

    // Header, centered horizontally near the top.
    const header_text = "Settings";
    const header_width = font_metrics.measureSpanWidth(text(header_text), settings_header_font_size);
    const header_x = content_x + @divTrunc(content_width - header_width, 2);
    const header_y = screen.y + settings_padding;
    try elements.append(allocator, .{ .text_label = .{
        .text = header_text,
        .screen_position = .{ .x = header_x, .y = header_y },
        .font_size = settings_header_font_size,
        .blocks_input = false,
    } });

    // Control rows. Each row: label (left) + control (right, flush
    // against the label — measured per-row so the control sits right after
    // the label text, not at a fixed column). Vertically stacked below the
    // header, centered as a group between header and Back button.

    // 11 rows (5 toggle/choice + 5 slider + 1 fps toggle):
    //   0. Master Volume (slider 0–100)
    //   1. Music Volume (slider 0–100)
    //   2. Sound Effects Volume (slider 0–100)
    //   3. Render FPS Cap (slider 0–256, 0 = Uncapped)
    //   4. Animation FPS (slider 1–16)
    //   5. VSync (toggle)
    //   6. Camera Zoom (4-button choice)
    //   7. Player Color (6-swatch choice)
    //   8. Auto-skip attack step (toggle)
    //   9. Auto-target at cursor (toggle)
    //  10. Show FPS (toggle)
    const row_count: i32 = 11;
    const rows_total_height = rowWidth(row_count, settings_row_height, settings_row_gap);
    const buttons_top = screen.y + screen.height - settings_padding -
        panel_button_height - settings_button_gap;
    const rows_y_start = header_y + lineHeight(settings_header_font_size) + settings_header_gap +
        @divTrunc(buttons_top - (header_y + lineHeight(settings_header_font_size) + settings_header_gap) - rows_total_height, 2);

    // Helper: emit a row label at content_x, vertically centered in the row,
    // and return the x position flush after the label (label_width + gap).
    const emitLabel = struct {
        fn run(
            elems: *UiElementList,
            alloc: std.mem.Allocator,
            fm: FontMetrics,
            label_text: []const u8,
            x: i32,
            y: i32,
        ) i32 {
            const label_width = fm.measureSpanWidth(text(label_text), settings_row_font_size);
            elems.append(alloc, .{ .text_label = .{
                .text = label_text,
                .screen_position = .{ .x = x, .y = y + @divTrunc(settings_row_height - settings_row_font_size, 2) },
                .font_size = settings_row_font_size,
                .blocks_input = false,
            }}) catch @panic("failed to append settings label");
            return x + label_width + settings_label_to_control_gap;
        }
    }.run;

    // Helper: emit a slider row — label (flush left) + slider control +
    // value text (right of the slider). Returns nothing. The slider value
    // is read from `settings` via the setting id, so it tracks the drag live
    // (the panel is rebuilt each frame).
    const emitSliderRow = struct {
        fn run(
            elems: *UiElementList,
            alloc: std.mem.Allocator,
            fm: FontMetrics,
            label_text: []const u8,
            id: types.SettingId,
            min: u32,
            max: u32,
            value: u32,
            value_label: []const u8,
            x: i32,
            y: i32,
        ) void {
            const ctrl_x = emitLabel(elems, alloc, fm, label_text, x, y);
            elems.append(alloc, .{ .slider = .{
                .setting_id = id,
                .min = min,
                .max = max,
                .value = value,
                .screen_position = .{ .x = ctrl_x, .y = y },
                .width = settings_slider_width,
                .height = settings_row_height,
            }}) catch @panic("failed to append slider");
            // Value text right of the slider.
            const value_x = ctrl_x + settings_slider_width + settings_slider_value_gap;
            elems.append(alloc, .{ .text_label = .{
                .text = value_label,
                .screen_position = .{ .x = value_x, .y = y + @divTrunc(settings_row_height - settings_row_font_size, 2) },
                .font_size = settings_row_font_size,
                .blocks_input = false,
            }}) catch @panic("failed to append slider value");
        }
    }.run;

    var row_index: i32 = 0;

    // ── Slider rows (0–4) ──

    // Row 0: Master Volume (0–100).
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const value_label = std.fmt.allocPrint(allocator, "{d}%", .{settings.master_volume}) catch @panic("failed to format slider value");
        emitSliderRow(elements, allocator, font_metrics, "Master Volume", .master_volume, 0, 100, settings.master_volume, value_label, content_x, r_y);
    }
    row_index += 1;

    // Row 1: Music Volume (0–100).
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const value_label = std.fmt.allocPrint(allocator, "{d}%", .{settings.music_volume}) catch @panic("failed to format slider value");
        emitSliderRow(elements, allocator, font_metrics, "Music Volume", .music_volume, 0, 100, settings.music_volume, value_label, content_x, r_y);
    }
    row_index += 1;

    // Row 2: Sound Effects Volume (0–100).
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const value_label = std.fmt.allocPrint(allocator, "{d}%", .{settings.sound_effects_volume}) catch @panic("failed to format slider value");
        emitSliderRow(elements, allocator, font_metrics, "Sound Effects Volume", .sound_effects_volume, 0, 100, settings.sound_effects_volume, value_label, content_x, r_y);
    }
    row_index += 1;

    // Row 3: Render FPS Cap (0–256, 0 = Uncapped).
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const value_label: []const u8 = if (settings.render_fps_cap == 0)
            "Uncapped"
        else
            std.fmt.allocPrint(allocator, "{d}", .{settings.render_fps_cap}) catch @panic("failed to format slider value");
        emitSliderRow(elements, allocator, font_metrics, "Render FPS Cap", .render_fps_cap, 0, 256, settings.render_fps_cap, value_label, content_x, r_y);
    }
    row_index += 1;

    // Row 4: Animation FPS (1–16).
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const value_label = std.fmt.allocPrint(allocator, "{d}", .{settings.animation_fps}) catch @panic("failed to format slider value");
        emitSliderRow(elements, allocator, font_metrics, "Animation FPS", .animation_fps, 1, 16, settings.animation_fps, value_label, content_x, r_y);
    }
    row_index += 1;

    // ── Toggle / choice rows (5–9) ──

    // Row 5: VSync toggle. Label is platform-specific: on web the setting
    // is a no-op — the browser's requestAnimationFrame paces rendering to
    // the display refresh regardless (rAF IS vsync on web; no page code can
    // out-run it). On native it's a real GLFW swap-interval toggle that only
    // applies at window creation, hence the restart note.
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const vsync_label = if (@import("builtin").os.tag == .emscripten)
            "VSync (always on in browser)"
        else
            "VSync (change requires restart)";
        const ctrl_x = emitLabel(elements, allocator, font_metrics, vsync_label, content_x, r_y);
        try emitSettingButton(
            elements,
            allocator,
            font_metrics,
            .{ .x = ctrl_x, .y = r_y, .width = settings_toggle_width, .height = settings_row_height },
            if (settings.vsync) "On" else "Off",
            settings_row_font_size,
            .{ .id = .vsync },
            false,
            button_color,
        );
    }
    row_index += 1;

    // Row 6: Camera Zoom — 4 buttons (25/50/75/100 hundredths → display as %).
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const ctrl_x = emitLabel(elements, allocator, font_metrics, "Camera Zoom", content_x, r_y);
        const zoom_values = [_]u32{ 25, 50, 75, 100 };
        const zoom_labels = [_][]const u8{ "25%", "50%", "75%", "100%" };
        for (zoom_values, zoom_labels, 0..) |value, label, i| {
            try emitSettingButton(
                elements,
                allocator,
                font_metrics,
                .{
                    .x = ctrl_x + @as(i32, @intCast(i)) * (settings_choice_button_width + settings_swatch_gap),
                    .y = r_y,
                    .width = settings_choice_button_width,
                    .height = settings_row_height,
                },
                label,
                settings_row_font_size,
                .{ .id = .camera_zoom, .choice_value = value },
                settings.camera_zoom == value,
                button_color,
            );
        }
    }
    row_index += 1;

    // Row 7: Player Color — 6 swatches (player gradient indices 0–5).
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const ctrl_x = emitLabel(elements, allocator, font_metrics, "Player Color", content_x, r_y);
        const swatch_y = r_y + @divTrunc(settings_row_height - settings_swatch_size, 2);
        for (0..types.gradient_color_count) |i| {
            const sx = ctrl_x + @as(i32, @intCast(i)) * (settings_swatch_size + settings_swatch_gap);
            const swatch_rect: Rectangle = .{ .x = sx, .y = swatch_y, .width = settings_swatch_size, .height = settings_swatch_size };
            // Colored fill (the swatch itself).
            try elements.append(allocator, .{ .solid_rect = .{
                .screen_position = swatch_rect.position(),
                .width = swatch_rect.width,
                .height = swatch_rect.height,
                .color = player_gradient.colors[i],
            } });
            // Invisible hit-test button over the swatch.
            try elements.append(allocator, .{ .button = .{
                .screen_position = swatch_rect.position(),
                .width = swatch_rect.width,
                .height = swatch_rect.height,
                .action = .change_setting,
                .setting_ref = .{ .id = .player_color_index, .choice_value = @intCast(i) },
                .highlighted = settings.player_color_index == i,
            } });
        }
    }
    row_index += 1;

    // Row 8: Auto-skip attack step toggle.
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const ctrl_x = emitLabel(elements, allocator, font_metrics, "Auto-skip Attack Step", content_x, r_y);
        try emitSettingButton(
            elements,
            allocator,
            font_metrics,
            .{ .x = ctrl_x, .y = r_y, .width = settings_toggle_width, .height = settings_row_height },
            if (settings.auto_skip_attack_step_out_of_combat) "On" else "Off",
            settings_row_font_size,
            .{ .id = .auto_skip_attack_step_out_of_combat },
            false,
            button_color,
        );
    }
    row_index += 1;

    // Row 9: Auto-target at cursor toggle.
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const ctrl_x = emitLabel(elements, allocator, font_metrics, "Auto-target at Cursor", content_x, r_y);
        try emitSettingButton(
            elements,
            allocator,
            font_metrics,
            .{ .x = ctrl_x, .y = r_y, .width = settings_toggle_width, .height = settings_row_height },
            if (settings.auto_target_at_cursor) "On" else "Off",
            settings_row_font_size,
            .{ .id = .auto_target_at_cursor },
            false,
            button_color,
        );
    }
    row_index += 1;

    // Row 10: Show FPS toggle.
    {
        const r_y = rows_y_start + row_index * (settings_row_height + settings_row_gap);
        const ctrl_x = emitLabel(elements, allocator, font_metrics, "Show FPS", content_x, r_y);
        try emitSettingButton(
            elements,
            allocator,
            font_metrics,
            .{ .x = ctrl_x, .y = r_y, .width = settings_toggle_width, .height = settings_row_height },
            if (settings.show_fps) "On" else "Off",
            settings_row_font_size,
            .{ .id = .show_fps },
            false,
            button_color,
        );
    }

    // Back button, bottom-left.
    const button_y = screen.y + screen.height - settings_padding - panel_button_height;
    try emitPanelButton(
        elements,
        allocator,
        font_metrics,
        .{
            .x = content_x,
            .y = button_y,
            .width = settings_button_width,
            .height = panel_button_height,
        },
        "Back",
        menu_button_font_size,
        .open_settings,
        button_color,
        null,
    );
}

test "buildLoadSavePanel: rows carry refs + actions, scroll window + clamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
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
            const ref = button.ref.?;
            if (first_ref_index == null) first_ref_index = ref.save_file;
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
            last_ref_index = button.ref.?.save_file;
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

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
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

test "buildEditorMissionBrowser: tabs, rows carry payloads + actions, window + clamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    const MissionEntry = @import("../file_source.zig").FileSource.MissionEntry;

    // Enough rows to overflow the visible window (the load-save browser's
    // geometry — ~14 visible rows).
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
    try buildEditorMissionBrowser(
        &elements,
        allocator,
        metrics,
        screen,
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
            if (button.editor_mission_tab == .local) {
                found_local_tab = true;
                try std.testing.expect(button.highlighted);
            }
            if (button.editor_mission_tab == .official) {
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
            if (first_row_index == null) first_row_index = button.editor_mission_row;
        },
        else => {},
    };
    try std.testing.expect(row_buttons > 0);
    try std.testing.expect(row_buttons < missions.len); // window, not all rows
    try std.testing.expectEqual(@as(u32, 0), first_row_index.?);

    // Scroll past the end clamps to the last window; the last row is visible.
    scroll = 999;
    var elements_end: UiElementList = .empty;
    try buildEditorMissionBrowser(
        &elements_end,
        allocator,
        metrics,
        screen,
        &missions,
        &.{},
        .local,
        &scroll,
        .{ .r = 50, .g = 50, .b = 50 },
    );
    var last_row_index: u32 = 0;
    for (elements_end.items) |element| switch (element) {
        .button => |button| if (button.action == .open_editor_mission_row) {
            last_row_index = button.editor_mission_row.?;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(u32, missions.len - 1), last_row_index);
    const max_scroll_row: i32 = @intCast(missions.len - row_buttons);
    try std.testing.expectEqual(max_scroll_row, scroll);

    // Negative scroll clamps to 0.
    scroll = -5;
    var elements_neg: UiElementList = .empty;
    try buildEditorMissionBrowser(
        &elements_neg,
        allocator,
        metrics,
        screen,
        &missions,
        &.{},
        .local,
        &scroll,
        .{ .r = 50, .g = 50, .b = 50 },
    );
    try std.testing.expectEqual(@as(i32, 0), scroll);
}

test "buildEditorMissionBrowser: empty lists show per-tab placeholders, Back always emitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };

    for ([_]types.EditorMissionBrowserTab{ .local, .official }) |tab| {
        var scroll: i32 = 0;
        var elements: UiElementList = .empty;
        try buildEditorMissionBrowser(
            &elements,
            allocator,
            metrics,
            screen,
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
            .button => |button| if (button.action == .toggle_editor_mission_browser) {
                found_back = true;
            },
            else => {},
        };
        try std.testing.expect(found_placeholder);
        try std.testing.expect(found_back);
    }
}

test "buildOptionsMenu: Export Save tooltip reflects the save destination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    const button_color: Color = .{ .r = 50, .g = 50, .b = 50 };

    // Native (a persistent dir path is known): "Saves to <dir>/saves/".
    {
        var elements: UiElementList = .empty;
        try buildOptionsMenu(&elements, allocator, metrics, screen, .level, null, button_color, "/home/tester/.ziglop");
        const button = (for (elements.items) |element| switch (element) {
            .button => |b| if (b.action == .save_game) break b,
            else => {},
        } else @panic("no Export Save button"));
        const tooltip = button.tooltip orelse @panic("Export Save button has no tooltip");
        try std.testing.expectEqual(@as(usize, 1), tooltip.body.len);
        try std.testing.expectEqual(@as(usize, 1), tooltip.body[0].len);
        try std.testing.expectEqualStrings("Saves to /home/tester/.ziglop/saves/", tooltip.body[0][0].text);
    }

    // Web (null path): the export is a browser download.
    {
        var elements: UiElementList = .empty;
        try buildOptionsMenu(&elements, allocator, metrics, screen, .level, null, button_color, null);
        const button = (for (elements.items) |element| switch (element) {
            .button => |b| if (b.action == .save_game) break b,
            else => {},
        } else @panic("no Export Save button"));
        const tooltip = button.tooltip orelse @panic("Export Save button has no tooltip");
        try std.testing.expectEqual(@as(usize, 1), tooltip.body.len);
        try std.testing.expectEqualStrings("Triggers a file download", tooltip.body[0][0].text);
    }

    // Other buttons stay tooltip-free.
    {
        var elements: UiElementList = .empty;
        try buildOptionsMenu(&elements, allocator, metrics, screen, .level, null, button_color, "/x");
        for (elements.items) |element| switch (element) {
            .button => |b| if (b.action != .save_game) {
                try std.testing.expect(b.tooltip == null);
            },
            else => {},
        };
    }

    // Editor context: no Export Save button (the editor's save target is
    // the mission being edited — a future slice). Continue + Settings +
    // Exit to Main Menu remain.
    {
        var elements: UiElementList = .empty;
        try buildOptionsMenu(&elements, allocator, metrics, screen, .editor, null, button_color, "/home/tester/.ziglop");
        for (elements.items) |element| switch (element) {
            .button => |b| try std.testing.expect(b.action != .save_game),
            else => {},
        };
        // The editor context carries its OWN save instead: the Save Mission
        // button (ctrl+S), with the persistent-dir tooltip.
        var save_mission_button: ?Button = null;
        for (elements.items) |element| switch (element) {
            .button => |b| {
                if (b.action == .save_editor_mission) save_mission_button = b;
            },
            else => {},
        };
        try std.testing.expect(save_mission_button != null);
        // The tooltip names the keybind + the destination dir.
        const save_tooltip = save_mission_button.?.tooltip orelse @panic("Save Mission button has no tooltip");
        const save_tooltip_text = save_tooltip.body[0][0].text;
        try std.testing.expectEqualStrings("Ctrl+S — saves to /home/tester/.ziglop/missions/", save_tooltip_text);

        // The New Mission button (ctrl+N): the fresh-mission open from
        // inside the editor, with the keybind tooltip.
        var new_mission_button: ?Button = null;
        for (elements.items) |element| switch (element) {
            .button => |b| {
                if (b.action == .new_editor_mission) new_mission_button = b;
            },
            else => {},
        };
        try std.testing.expect(new_mission_button != null);
        const new_tooltip = new_mission_button.?.tooltip orelse @panic("New Mission button has no tooltip");
        const new_tooltip_text = new_tooltip.body[0][0].text;
        try std.testing.expectEqualStrings("Ctrl+N — replaces the mission being edited with a fresh one", new_tooltip_text);
    }
}

test "buildOptionsMenu + buildMissionFail during an editor run: run labels, no Export Save" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metrics = FontMetrics{ .base_size = 100, .advances = [_]i32{50} ** 95 };
    const screen = Rectangle{ .x = 0, .y = 0, .width = 3840, .height = 2160 };
    const button_color: Color = .{ .r = 50, .g = 50, .b = 50 };

    for ([_]types.EditorMode{ .playtest, .validate }) |run_mode| {
        const restart_label = if (run_mode == .playtest) "Restart Playtest" else "Restart Validation";
        const exit_label = if (run_mode == .playtest) "Exit Playtest" else "Exit Validation";

        // The options menu names the RUN on the restart/exit buttons and
        // offers NO campaign Export Save (the run's player_data is
        // temporary — rebuilt from the editor loadout, discarded on exit).
        {
            var elements: UiElementList = .empty;
            try buildOptionsMenu(&elements, allocator, metrics, screen, .level, run_mode, button_color, "/dir");
            try expectMenuButtonLabel(elements.items, .restart_mission, restart_label);
            try expectMenuButtonLabel(elements.items, .exit_mission, exit_label);
            for (elements.items) |element| switch (element) {
                .button => |b| try std.testing.expect(b.action != .save_game),
                else => {},
            };
        }

        // The mission-fail overlay uses the same run nouns.
        {
            var fail_elements: UiElementList = .empty;
            try buildMissionFail(&fail_elements, allocator, metrics, screen, run_mode, button_color);
            try expectMenuButtonLabel(fail_elements.items, .restart_mission, restart_label);
            try expectMenuButtonLabel(fail_elements.items, .exit_mission, exit_label);
        }
    }
}

/// Assert that a panel-button list (emitPanelButton: panel, button, label
/// triplets) contains a button with `action` and its label reads `expected`.
fn expectMenuButtonLabel(elements: []const UiElement, action: Action, expected: []const u8) !void {
    var found = false;
    for (elements, 0..) |element, index| switch (element) {
        // The label follows its spriteless button (the triplet's third
        // element) — match the immediately-preceding button's action.
        .text_label => |label| {
            if (index > 0) {
                switch (elements[index - 1]) {
                    .button => |b| {
                        if (b.action == action) {
                            try std.testing.expectEqualStrings(expected, label.text);
                            found = true;
                        }
                    },
                    else => {},
                }
            }
        },
        else => {},
    };
    try std.testing.expect(found);
}
